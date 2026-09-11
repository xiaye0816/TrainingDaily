@preconcurrency import AVFAudio
import Foundation

/// Pure policy used by the live speech mixer and unit tests. A clip keeps the
/// gain assigned when it starts; an older clip is never ducked by a new one.
struct SpeechMixPolicy {
    static let primaryVolume: Float = 0.75
    static let overlappingVolume: Float = 0.45

    static func volume(activeClipCount: Int) -> Float {
        activeClipCount == 0 ? primaryVolume : overlappingVolume
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
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
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
