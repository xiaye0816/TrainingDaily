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

/// Pure policy used by the live speech mixer and unit tests. A clip keeps the
/// gain assigned when it starts; an older clip is never ducked by a new one.
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
            .sorted {
                qualityRank($0.quality) > qualityRank($1.quality)
            }
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
        guard isMandarin(language) else { return false }
        let identifier = identifier.lowercased()
        let name = name.lowercased()
        return identifier.contains("tingting") || name.contains("tingting") || name.contains("婷婷")
    }

    private static func isMandarin(_ language: String) -> Bool {
        language.replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .hasPrefix("zh-cn")
    }
}

private struct ActiveSpeech {
    let synthesizer: AVSpeechSynthesizer
    let utteranceID: ObjectIdentifier
}

/// One synthesizer is used per active announcement. This permits a time
/// announcement and a rep announcement to really play at the same time.
/// Nothing is queued and an active clip is never interrupted by a later clip.
@MainActor
final class SpeechCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private var active: [UUID: ActiveSpeech] = [:]
    private var utteranceTokens: [ObjectIdentifier: UUID] = [:]

    @discardableResult
    func speakPriority(_ text: String) -> Bool {
        speak(text)
    }

    @discardableResult
    func speakCount(_ text: String) -> Bool {
        speak(text)
    }

    func stop() {
        let synthesizers = active.values.map(\.synthesizer)
        active.removeAll()
        utteranceTokens.removeAll()
        synthesizers.forEach { $0.stopSpeaking(at: .immediate) }
    }

    @discardableResult
    private func speak(_ text: String) -> Bool {
        let token = UUID()
        let volume = SpeechMixPolicy.volume(activeClipCount: active.count)
        let utterance = makeUtterance(text, volume: volume)
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self

        let identifier = ObjectIdentifier(utterance)
        active[token] = ActiveSpeech(synthesizer: synthesizer, utteranceID: identifier)
        utteranceTokens[identifier] = token
        synthesizer.speak(utterance)
        return true
    }

    private func makeUtterance(_ text: String, volume: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = MandarinSpeechVoice.preferred()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1
        utterance.volume = volume
        return utterance
    }

    private func finishUtterance(with identifier: ObjectIdentifier) {
        guard let token = utteranceTokens.removeValue(forKey: identifier),
              active[token]?.utteranceID == identifier else { return }
        active.removeValue(forKey: token)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishUtterance(with: identifier)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishUtterance(with: identifier)
        }
    }
}
