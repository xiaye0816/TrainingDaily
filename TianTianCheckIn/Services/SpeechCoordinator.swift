@preconcurrency import AVFAudio
import Foundation

struct SpeechAnnouncementArbiter {
    enum ActiveAnnouncement: Equatable {
        case priority(UUID)
        case count(UUID)

        var token: UUID {
            switch self {
            case let .priority(token), let .count(token):
                return token
            }
        }
    }

    private(set) var activeAnnouncement: ActiveAnnouncement?

    var isPriorityActive: Bool {
        guard case .priority = activeAnnouncement else { return false }
        return true
    }

    mutating func beginPriority(token: UUID) {
        activeAnnouncement = .priority(token)
    }

    mutating func beginCount(token: UUID) -> Bool {
        guard activeAnnouncement == nil else { return false }
        activeAnnouncement = .count(token)
        return true
    }

    mutating func finish(token: UUID) {
        guard activeAnnouncement?.token == token else { return }
        activeAnnouncement = nil
    }

    mutating func reset() {
        activeAnnouncement = nil
    }
}

@MainActor
final class SpeechCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var arbiter = SpeechAnnouncementArbiter()
    private var utteranceTokens: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Priority announcements (countdown and time) replace anything currently
    /// speaking and discard every queued count announcement.
    func speakPriority(_ text: String) {
        _ = synthesizer.stopSpeaking(at: .immediate)

        let token = UUID()
        let utterance = makeUtterance(text)
        arbiter.beginPriority(token: token)
        utteranceTokens[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    /// Count announcements are intentionally never queued. If another count or
    /// a priority announcement is in progress, this count is considered stale.
    @discardableResult
    func speakCount(_ text: String) -> Bool {
        guard !synthesizer.isSpeaking, !synthesizer.isPaused else { return false }

        let token = UUID()
        guard arbiter.beginCount(token: token) else { return false }

        let utterance = makeUtterance(text)
        utteranceTokens[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        arbiter.reset()
        utteranceTokens.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        utterance.volume = 1
        return utterance
    }

    private func finishUtterance(with identifier: ObjectIdentifier) {
        guard let token = utteranceTokens.removeValue(forKey: identifier) else { return }
        arbiter.finish(token: token)
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
