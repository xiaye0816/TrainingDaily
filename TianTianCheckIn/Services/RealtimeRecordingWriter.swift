@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import Foundation
import UIKit

struct RecordingOverlaySnapshot: Equatable, Sendable {
    var timeText: String?
    var count: Int?
}

struct RecordingFinish: Sendable {
    let url: URL
    let recordedDuration: TimeInterval
}

enum RealtimeRecordingWriterError: LocalizedError {
    case cannotCreateWriter(Error)
    case cannotAddInput
    case missingVideoFrame
    case pixelBufferUnavailable
    case appendFailed(Error?)

    var errorDescription: String? {
        switch self {
        case let .cannotCreateWriter(error): error.localizedDescription
        case .cannotAddInput: "无法创建实时录像输入。"
        case .missingVideoFrame: "录像未收到有效画面。"
        case .pixelBufferUnavailable: "无法处理录像画面。"
        case let .appendFailed(error): error?.localizedDescription ?? "实时录像写入失败。"
        }
    }
}

enum WorkoutAudioLevelPolicy {
    static let peakLimit: Float = 0.95
    static let speechMicrophoneGain: Float = 0.18

    static func mixedSample(original: Float, speech: Float, ducking: Float) -> Float {
        guard ducking > 0 else { return original }
        let microphoneGain = 1 - ducking * (1 - speechMicrophoneGain)
        let mixed = original * microphoneGain + speech
        return peakLimit * tanh(mixed / peakLimit)
    }
}

private struct ScheduledSpeechClip {
    let clip: SpeechClip
    let startUptime: TimeInterval
    let volume: Float
}

/// Encodes the finished 720p movie while the workout is happening. All append
/// methods are called on CameraRecorder's serial media queue.
final class RealtimeRecordingWriter: @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let snapshotLock = NSLock()

    private var outputURL: URL?
    private var includeMicrophone = false
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstVideoPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var latestSnapshot = RecordingOverlaySnapshot(timeText: nil, count: nil)
    private var renderedSnapshot: RecordingOverlaySnapshot?
    private var renderedSize = CGSize.zero
    private var overlayImage: CIImage?
    private var speechClips: [ScheduledSpeechClip] = []
    private var syntheticAudioCursor: TimeInterval?
    private var isArmed = false
    private var isFinishing = false

    func arm(url: URL, includeMicrophone: Bool) {
        reset()
        outputURL = url
        self.includeMicrophone = includeMicrophone
        isArmed = true
    }

    func updateOverlay(_ snapshot: RecordingOverlaySnapshot) {
        snapshotLock.lock()
        latestSnapshot = snapshot
        snapshotLock.unlock()
    }

    func scheduleSpeechClip(_ clip: SpeechClip, atUptime uptime: TimeInterval, volume: Float) {
        speechClips.append(ScheduledSpeechClip(clip: clip, startUptime: uptime, volume: volume))
        speechClips.sort { $0.startUptime < $1.startUptime }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isArmed, !isFinishing,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        do {
            if assetWriter == nil {
                try configureWriter(width: CVPixelBufferGetWidth(sourceBuffer), height: CVPixelBufferGetHeight(sourceBuffer))
                guard let assetWriter else { return }
                guard assetWriter.startWriting() else {
                    throw RealtimeRecordingWriterError.appendFailed(assetWriter.error)
                }
                assetWriter.startSession(atSourceTime: pts)
                firstVideoPTS = pts
            }
            guard let assetWriter, assetWriter.status == .writing,
                  let videoInput,
                  videoInput.isReadyForMoreMediaData,
                  let pixelBufferAdaptor,
                  let pool = pixelBufferAdaptor.pixelBufferPool else { return }

            var destination: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                  let destination else {
                throw RealtimeRecordingWriterError.pixelBufferUnavailable
            }
            let width = CVPixelBufferGetWidth(destination)
            let height = CVPixelBufferGetHeight(destination)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            if image.extent.size != bounds.size {
                let scaleX = bounds.width / image.extent.width
                let scaleY = bounds.height / image.extent.height
                image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            }
            image = image.cropped(to: bounds)
            if let overlay = resolvedOverlay(size: bounds.size) {
                image = overlay.composited(over: image)
            }
            ciContext.render(image, to: destination, bounds: bounds, colorSpace: colorSpace)
            guard pixelBufferAdaptor.append(destination, withPresentationTime: pts) else {
                throw RealtimeRecordingWriterError.appendFailed(assetWriter.error)
            }
            lastVideoPTS = pts
            if !includeMicrophone {
                appendSyntheticAudio(upTo: CMTimeGetSeconds(pts))
            }
        } catch {
            assetWriter?.cancelWriting()
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isArmed, !isFinishing, includeMicrophone,
              let assetWriter, assetWriter.status == .writing,
              let firstVideoPTS,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstVideoPTS,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        processAudioInPlace(sampleBuffer)
        if !audioInput.append(sampleBuffer) {
            assetWriter.cancelWriting()
        }
    }

    func finish(
        completionQueue: DispatchQueue? = nil,
        completion: @escaping @Sendable (Result<RecordingFinish, Error>) -> Void
    ) {
        guard isArmed, !isFinishing else {
            completion(.failure(RealtimeRecordingWriterError.missingVideoFrame))
            return
        }
        isFinishing = true
        if !includeMicrophone, let lastVideoPTS {
            appendSyntheticAudio(upTo: CMTimeGetSeconds(lastVideoPTS) + 1.0 / 30.0)
        }
        guard let assetWriter, let outputURL, let firstVideoPTS else {
            completion(.failure(RealtimeRecordingWriterError.missingVideoFrame))
            reset()
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let recordedDuration: TimeInterval = {
            guard let lastVideoPTS else { return 0 }
            return max(0, CMTimeGetSeconds(CMTimeSubtract(lastVideoPTS, firstVideoPTS)) + 1.0 / 30.0)
        }()
        let writerReference = SendableRealtimeAssetWriter(assetWriter)
        writerReference.value.finishWriting { [weak self] in
            guard let self else { return }
            let complete = {
                let result: Result<RecordingFinish, Error>
                if writerReference.value.status == .completed {
                    result = .success(RecordingFinish(url: outputURL, recordedDuration: recordedDuration))
                } else {
                    result = .failure(RealtimeRecordingWriterError.appendFailed(writerReference.value.error))
                }
                self.reset()
                completion(result)
            }
            if let completionQueue {
                completionQueue.async(execute: complete)
            } else {
                complete()
            }
        }
    }

    private func configureWriter(width: Int, height: Int) throws {
        guard let outputURL else { throw RealtimeRecordingWriterError.missingVideoFrame }
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_500_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
            )
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                throw RealtimeRecordingWriterError.cannotAddInput
            }
            writer.add(videoInput)
            writer.add(audioInput)
            self.assetWriter = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            pixelBufferAdaptor = adaptor
        } catch let error as RealtimeRecordingWriterError {
            throw error
        } catch {
            throw RealtimeRecordingWriterError.cannotCreateWriter(error)
        }
    }

    private func resolvedOverlay(size: CGSize) -> CIImage? {
        snapshotLock.lock()
        let snapshot = latestSnapshot
        snapshotLock.unlock()
        if renderedSnapshot == snapshot, renderedSize == size { return overlayImage }
        renderedSnapshot = snapshot
        renderedSize = size
        guard snapshot.timeText != nil || snapshot.count != nil else {
            overlayImage = nil
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let shortEdge = min(size.width, size.height)
            let marginX = shortEdge * 0.045
            let marginY = shortEdge * 0.05
            let height = shortEdge * 0.07
            let font = UIFont.monospacedDigitSystemFont(ofSize: height * 0.45, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
                    shadow.shadowBlurRadius = 2
                    shadow.shadowOffset = CGSize(width: 0, height: 1)
                    return shadow
                }()
            ]
            if let timeText = snapshot.timeText {
                drawCapsule(timeText, originX: marginX, alignRight: false, top: marginY, height: height, attributes: attributes, context: context.cgContext)
            }
            if let count = snapshot.count {
                drawCapsule("\(count) 次", originX: size.width - marginX, alignRight: true, top: marginY, height: height, attributes: attributes, context: context.cgContext)
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        overlayImage = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: size.height))
        return overlayImage
    }

    private func drawCapsule(
        _ text: String,
        originX: CGFloat,
        alignRight: Bool,
        top: CGFloat,
        height: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        context: CGContext
    ) {
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = textSize.width + height * 0.72
        let x = alignRight ? originX - width : originX
        let frame = CGRect(x: x, y: top, width: width, height: height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: height * 0.08), blur: height * 0.12, color: UIColor.black.withAlphaComponent(0.25).cgColor)
        UIColor(white: 0.13, alpha: 0.48).setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: height / 2).fill()
        context.restoreGState()
        UIColor.white.withAlphaComponent(0.22).setStroke()
        let border = UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: height / 2)
        border.lineWidth = 1
        border.stroke()
        let textFrame = CGRect(x: x, y: top + (height - textSize.height) / 2, width: width, height: textSize.height)
        (text as NSString).draw(in: textFrame, withAttributes: attributes)
    }

    private func processAudioInPlace(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              asbdPointer.pointee.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var totalLength = 0
        var rawPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &rawPointer) == kCMBlockBufferNoErr,
              let rawPointer else { return }
        let asbd = asbdPointer.pointee
        let startPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        let isInt16 = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && asbd.mBitsPerChannel == 16
        if isFloat {
            let samples = UnsafeMutableRawPointer(rawPointer).bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
            process(
                samples: samples,
                count: totalLength / MemoryLayout<Float>.size,
                sampleRate: asbd.mSampleRate,
                channels: max(1, Int(asbd.mChannelsPerFrame)),
                startPTS: startPTS
            )
        } else if isInt16 {
            let samples = UnsafeMutableRawPointer(rawPointer).bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
            process(
                samples: samples,
                count: totalLength / MemoryLayout<Int16>.size,
                sampleRate: asbd.mSampleRate,
                channels: max(1, Int(asbd.mChannelsPerFrame)),
                startPTS: startPTS
            )
        }
    }

    private func process(samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double, channels: Int, startPTS: TimeInterval) {
        guard count > 0 else { return }
        for index in 0..<count {
            let uptime = startPTS + Double(index / channels) / sampleRate
            let mix = speechMix(atUptime: uptime)
            samples[index] = WorkoutAudioLevelPolicy.mixedSample(
                original: samples[index],
                speech: mix.sample,
                ducking: mix.ducking
            )
        }
    }

    private func process(samples: UnsafeMutablePointer<Int16>, count: Int, sampleRate: Double, channels: Int, startPTS: TimeInterval) {
        guard count > 0 else { return }
        for index in 0..<count {
            let uptime = startPTS + Double(index / channels) / sampleRate
            let mix = speechMix(atUptime: uptime)
            let original = Float(samples[index]) / Float(Int16.max)
            let mixed = WorkoutAudioLevelPolicy.mixedSample(
                original: original,
                speech: mix.sample,
                ducking: mix.ducking
            )
            samples[index] = Int16(mixed * Float(Int16.max))
        }
    }

    private func speechMix(atUptime uptime: TimeInterval) -> (sample: Float, ducking: Float) {
        var mixed: Float = 0
        var ducking: Float = 0
        for scheduled in speechClips {
            let frame = Int((uptime - scheduled.startUptime) * SpeechClip.sampleRate)
            guard frame >= 0, frame < scheduled.clip.samples.count else { continue }
            mixed += scheduled.clip.samples[frame] * scheduled.volume
            let fadeFrames = max(1, Int(SpeechClip.sampleRate * 0.01))
            let fadeIn = min(1, Float(frame) / Float(fadeFrames))
            let fadeOut = min(1, Float(scheduled.clip.samples.count - frame) / Float(fadeFrames))
            ducking = max(ducking, min(fadeIn, fadeOut))
        }
        return (mixed, ducking)
    }

    private func appendSyntheticAudio(upTo endUptime: TimeInterval) {
        guard let assetWriter, assetWriter.status == .writing,
              let audioInput else { return }
        let sampleRate: Int32 = 48_000
        var cursor = syntheticAudioCursor ?? firstVideoPTS.map(CMTimeGetSeconds) ?? endUptime
        let chunkFrames = 480
        while cursor < endUptime, audioInput.isReadyForMoreMediaData {
            let remainingFrames = Int((endUptime - cursor) * Double(sampleRate))
            let frameCount = min(chunkFrames, remainingFrames)
            guard frameCount > 0 else { break }
            var samples = [Int16](repeating: 0, count: frameCount)
            for index in samples.indices {
                let uptime = cursor + Double(index) / Double(sampleRate)
                let sample = speechMix(atUptime: uptime).sample
                let limited = WorkoutAudioLevelPolicy.peakLimit * tanh(sample / WorkoutAudioLevelPolicy.peakLimit)
                samples[index] = Int16(limited * Float(Int16.max))
            }
            guard let buffer = Self.makeAudioSampleBuffer(
                samples: samples,
                sampleRate: sampleRate,
                presentationTime: cursor
            ), audioInput.append(buffer) else {
                assetWriter.cancelWriting()
                return
            }
            cursor += Double(frameCount) / Double(sampleRate)
            syntheticAudioCursor = cursor
        }
    }

    private static func makeAudioSampleBuffer(samples: [Int16], sampleRate: Int32, presentationTime: TimeInterval) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func reset() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        firstVideoPTS = nil
        lastVideoPTS = nil
        renderedSnapshot = nil
        renderedSize = .zero
        overlayImage = nil
        speechClips.removeAll()
        syntheticAudioCursor = nil
        isArmed = false
        isFinishing = false
        outputURL = nil
    }
}

private final class SendableRealtimeAssetWriter: @unchecked Sendable {
    let value: AVAssetWriter

    init(_ value: AVAssetWriter) {
        self.value = value
    }
}
