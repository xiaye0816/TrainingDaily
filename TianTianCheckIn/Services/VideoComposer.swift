@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import UIKit

enum VideoComposerError: LocalizedError {
    case missingVideoTrack
    case cannotCreateTrack
    case cannotCreateExporter
    case exportFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack: "没有找到可合成的视频轨道。"
        case .cannotCreateTrack: "无法创建视频合成轨道。"
        case .cannotCreateExporter: "当前设备无法导出该视频。"
        case let .exportFailed(error): error?.localizedDescription ?? "视频合成失败。"
        }
    }
}

enum VideoComposer {
    static func compose(
        rawURL: URL,
        trimStart: TimeInterval,
        actualDuration: TimeInterval,
        config: WorkoutConfig,
        events: [WorkoutEvent]
    ) async throws -> URL {
        let asset = AVURLAsset(url: rawURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoComposerError.missingVideoTrack
        }

        let assetDuration = try await asset.load(.duration)
        let start = CMTime(seconds: max(0, trimStart), preferredTimescale: 600)
        let requestedDuration = CMTime(seconds: max(0.1, actualDuration), preferredTimescale: 600)
        let availableDuration = CMTimeSubtract(assetDuration, start)
        let duration = CMTimeMinimum(requestedDuration, availableDuration)
        let sourceRange = CMTimeRange(start: start, duration: duration)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoComposerError.cannotCreateTrack
        }
        try compositionVideo.insertTimeRange(sourceRange, of: sourceVideo, at: .zero)

        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: .zero)
        }

        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = sourceRect.applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        let normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedRect.minX,
                y: -transformedRect.minY
            )
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)

        let containingLayer = CALayer()
        containingLayer.frame = videoLayer.frame
        containingLayer.addSublayer(videoLayer)

        let resolvedDuration = CMTimeGetSeconds(duration)
        let segments = OverlayTimelineBuilder.build(
            actualDuration: resolvedDuration,
            configuredDuration: TimeInterval(config.durationSeconds),
            timerEnabled: config.timerEnabled,
            counterEnabled: config.counterEnabled,
            events: events
        )
        addOverlayLayers(segments, duration: resolvedDuration, renderSize: renderSize, to: containingLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: containingLayer
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiantiandaka-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoComposerError.cannotCreateExporter
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        exporter.videoComposition = videoComposition

        try await export(exporter)
        return outputURL
    }

    private static func addOverlayLayers(
        _ segments: [OverlaySegment],
        duration: TimeInterval,
        renderSize: CGSize,
        to containingLayer: CALayer
    ) {
        guard duration > 0 else { return }

        let shortEdge = min(renderSize.width, renderSize.height)
        let overlayHeight = shortEdge * 0.13
        let overlayWidth = min(renderSize.width * 0.82, shortEdge * 1.25)
        let margin = shortEdge * 0.055
        let frame = CGRect(
            x: (renderSize.width - overlayWidth) / 2,
            y: renderSize.height - overlayHeight - margin,
            width: overlayWidth,
            height: overlayHeight
        )

        for segment in segments where !segment.label.isEmpty {
            let textLayer = CATextLayer()
            textLayer.frame = frame
            textLayer.string = segment.label
            textLayer.alignmentMode = .center
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.62).cgColor
            textLayer.cornerRadius = overlayHeight * 0.28
            textLayer.masksToBounds = true
            textLayer.contentsScale = 2
            textLayer.font = UIFont.systemFont(ofSize: overlayHeight * 0.35, weight: .semibold)
            textLayer.fontSize = overlayHeight * 0.35
            textLayer.opacity = 0

            let animation = CAKeyframeAnimation(keyPath: "opacity")
            let startRatio = max(0, min(1, segment.start / duration))
            let endRatio = max(startRatio, min(1, segment.end / duration))
            if startRatio < 0.000_1 {
                animation.values = [1, 0]
                animation.keyTimes = [0, NSNumber(value: endRatio)]
            } else {
                animation.values = [0, 1, 0]
                animation.keyTimes = [0, NSNumber(value: startRatio), NSNumber(value: endRatio)]
            }
            animation.calculationMode = .discrete
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.duration = duration
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            textLayer.add(animation, forKey: "visibility")
            containingLayer.addSublayer(textLayer)
        }
    }

    private static func export(_ exporter: AVAssetExportSession) async throws {
        let reference = SendableExportSession(exporter)
        try await withCheckedThrowingContinuation { continuation in
            reference.value.exportAsynchronously {
                switch reference.value.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: VideoComposerError.exportFailed(reference.value.error))
                default:
                    continuation.resume(throwing: VideoComposerError.exportFailed(reference.value.error))
                }
            }
        }
    }
}

private final class SendableExportSession: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}
