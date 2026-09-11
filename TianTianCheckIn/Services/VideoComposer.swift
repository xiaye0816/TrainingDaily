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
            presetName: AVAssetExportPreset1280x720
        ) else {
            throw VideoComposerError.cannotCreateExporter
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
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
        let overlayHeight = shortEdge * 0.07
        let marginX = shortEdge * 0.045
        let marginY = shortEdge * 0.05
        let y = renderSize.height - overlayHeight - marginY

        for segment in segments {
            if let remaining = segment.remainingSeconds {
                let width = shortEdge * 0.25
                addPillLayer(
                    text: remaining.clockText,
                    frame: CGRect(x: marginX, y: y, width: width, height: overlayHeight),
                    segment: segment,
                    duration: duration,
                    to: containingLayer
                )
            }
            if let count = segment.count {
                let width = shortEdge * 0.21
                addPillLayer(
                    text: "\(count) 次",
                    frame: CGRect(x: renderSize.width - marginX - width, y: y, width: width, height: overlayHeight),
                    segment: segment,
                    duration: duration,
                    to: containingLayer
                )
            }
        }
    }

    private static func addPillLayer(
        text: String,
        frame: CGRect,
        segment: OverlaySegment,
        duration: TimeInterval,
        to containingLayer: CALayer
    ) {
        let textLayer = CATextLayer()
        textLayer.frame = frame
        textLayer.string = text
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.backgroundColor = UIColor(white: 0.13, alpha: 0.48).cgColor
        textLayer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        textLayer.borderWidth = 1
        textLayer.cornerRadius = frame.height / 2
        textLayer.masksToBounds = true
        textLayer.contentsScale = 2
        textLayer.font = UIFont.monospacedDigitSystemFont(ofSize: frame.height * 0.45, weight: .semibold)
        textLayer.fontSize = frame.height * 0.45
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
