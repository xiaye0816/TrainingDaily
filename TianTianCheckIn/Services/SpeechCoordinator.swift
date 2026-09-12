@preconcurrency import AVFAudio
import Foundation

enum AppAudioSession {
    static func activateVideoPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

struct SpeechMixPolicy {
    static let primaryVolume: Float = 1
    static let overlappingVolume: Float = 0.65

    static func volume(activeClipCount: Int) -> Float {
        activeClipCount == 0 ? primaryVolume : overlappingVolume
    }
}

enum MandarinSpeechVoice {
    static func preferred() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { isTingting(identifier: $0.identifier, name: $0.name, language: $0.language) }
            .sorted { qualityRank($0.quality) > qualityRank($1.quality) }
            .first
            ?? AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.zh-CN.Tingting")
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        default: 1
        }
    }

    static func isTingting(identifier: String, name: String, language: String) -> Bool {
        guard language.replacingOccurrences(of: "_", with: "-").lowercased().hasPrefix("zh-cn") else {
            return false
        }
        let identifier = identifier.lowercased()
        let name = name.lowercased()
        return identifier.contains("tingting") || name.contains("tingting") || name.contains("婷婷")
    }
}

struct SpeechClip: Sendable {
    static let sampleRate = 48_000.0
    let text: String
    let samples: [Float]

    var duration: TimeInterval {
        TimeInterval(samples.count) / Self.sampleRate
    }
}

private final class SpeechRenderSession: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var samples: [Float] = []
    private var sourceSampleRate = SpeechClip.sampleRate
    private var continuation: CheckedContinuation<(samples: [Float], sampleRate: Double), Never>?

    static func render(_ utterance: AVSpeechUtterance) async -> (samples: [Float], sampleRate: Double) {
        await withCheckedContinuation { continuation in
            let session = SpeechRenderSession()
            session.continuation = continuation
            session.synthesizer.write(utterance) { [session] audioBuffer in
                session.consume(audioBuffer)
            }
        }
    }

    private func consume(_ audioBuffer: AVAudioBuffer) {
        guard let buffer = audioBuffer as? AVAudioPCMBuffer else { return }
        guard buffer.frameLength > 0 else {
            continuation?.resume(returning: (samples, sourceSampleRate))
            continuation = nil
            return
        }

        sourceSampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        if let channel = buffer.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))
        } else if let channel = buffer.int16ChannelData?[0] {
            samples.reserveCapacity(samples.count + frameCount)
            for index in 0..<frameCount {
                samples.append(Float(channel[index]) / Float(Int16.max))
            }
        }
    }
}

private actor SpeechClipRenderer {
    private var cache: [String: SpeechClip] = [:]

    func preload(_ texts: [String]) async {
        var seen: Set<String> = []
        for text in texts where seen.insert(text).inserted {
            _ = await clip(for: text)
        }
    }

    func clip(for text: String) async -> SpeechClip? {
        if let cached = cache[text] { return cached }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = MandarinSpeechVoice.preferred()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        let rendered = await SpeechRenderSession.render(utterance)
        guard !rendered.samples.isEmpty, rendered.sampleRate > 0 else { return nil }

        let resampled = Self.resample(rendered.samples, from: rendered.sampleRate, to: SpeechClip.sampleRate)
        let processed = Self.trimAndNormalize(resampled)
        guard !processed.isEmpty else { return nil }
        let clip = SpeechClip(text: text, samples: processed)
        cache[text] = clip
        return clip
    }

    private static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, abs(sourceRate - targetRate) > 0.5 else { return samples }
        let outputCount = max(1, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * sourceRate / targetRate
            let lower = min(Int(sourcePosition), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    private static func trimAndNormalize(_ samples: [Float]) -> [Float] {
        let threshold: Float = 0.001
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else { return [] }
        let padding = Int(SpeechClip.sampleRate * 0.012)
        let lower = max(0, first - padding)
        let upper = min(samples.count - 1, last + padding)
        var result = Array(samples[lower...upper])

        let active = result.filter { abs($0) >= threshold }
        let meanSquare = active.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, active.count))
        let rms = Float(sqrt(meanSquare))
        let peak = result.reduce(Float.zero) { max($0, abs($1)) }
        guard rms > 0, peak > 0 else { return [] }

        // Normalize the rendered system voice before it reaches either the
        // speaker or the movie mixer. This avoids the low output level of the
        // compact Tingting voice while retaining headroom for overlapping
        // time and count announcements.
        let targetRMS = Float(pow(10.0, -14.0 / 20.0))
        let peakLimit = Float(pow(10.0, -0.5 / 20.0))
        let gain = min(targetRMS / rms, peakLimit / peak, 6)
        for index in result.indices { result[index] *= gain }

        let fadeFrames = min(Int(SpeechClip.sampleRate * 0.01), result.count / 2)
        if fadeFrames > 0 {
            for index in 0..<fadeFrames {
                let envelope = Float(index) / Float(fadeFrames)
                result[index] *= envelope
                result[result.count - 1 - index] *= envelope
            }
        }
        return result
    }
}

@MainActor
final class SpeechCoordinator {
    typealias ClipStartedHandler = @MainActor (SpeechClip, TimeInterval, Float) -> Void
    typealias ClipRequestedHandler = @MainActor (String, TimeInterval) -> Void

    var clipStartedHandler: ClipStartedHandler?
    var clipRequestedHandler: ClipRequestedHandler?

    private let renderer = SpeechClipRenderer()
    private let engine = AVAudioEngine()
    private var activePlayers: [UUID: AVAudioPlayerNode] = [:]
    private var generation = 0

    func preload(_ texts: [String]) {
        Task { await renderer.preload(texts) }
    }

    func preloadAndWait(_ texts: [String]) async {
        await renderer.preload(texts)
    }

    func prepareEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    @discardableResult
    func speakPriority(_ text: String) -> Bool {
        clipRequestedHandler?(text, ProcessInfo.processInfo.systemUptime)
        enqueue(text)
        return true
    }

    @discardableResult
    func speakCount(_ text: String) -> Bool {
        clipRequestedHandler?(text, ProcessInfo.processInfo.systemUptime)
        enqueue(text)
        return true
    }

    @discardableResult
    func speakPriorityAndWait(_ text: String) async -> Bool {
        clipRequestedHandler?(text, ProcessInfo.processInfo.systemUptime)
        let expectedGeneration = generation
        guard let clip = await renderer.clip(for: text), generation == expectedGeneration else {
            return false
        }
        play(clip)
        try? await Task.sleep(nanoseconds: UInt64((clip.duration + 0.04) * 1_000_000_000))
        return generation == expectedGeneration
    }

    func stop() {
        generation += 1
        let players = activePlayers.values
        activePlayers.removeAll()
        players.forEach {
            $0.stop()
            engine.detach($0)
        }
        engine.stop()
    }

    private func enqueue(_ text: String) {
        let expectedGeneration = generation
        Task { [weak self] in
            guard let self,
                  let clip = await renderer.clip(for: text),
                  generation == expectedGeneration else { return }
            play(clip)
        }
    }

    private func play(_ clip: SpeechClip) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpeechClip.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(clip.samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: clip.samples.count)
            }
        }

        let token = UUID()
        let player = AVAudioPlayerNode()
        let volume = SpeechMixPolicy.volume(activeClipCount: activePlayers.count)
        player.volume = volume
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            engine.detach(player)
            return
        }

        activePlayers[token] = player
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishPlayer(token) }
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        player.play()
        clipStartedHandler?(clip, startedAt, volume)
    }

    private func finishPlayer(_ token: UUID) {
        guard let player = activePlayers.removeValue(forKey: token) else { return }
        player.stop()
        engine.detach(player)
    }
}
