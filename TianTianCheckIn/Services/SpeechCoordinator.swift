@preconcurrency import AVFAudio
import Foundation

@MainActor
final class SpeechCoordinator {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, interrupt: Bool = false) {
        if interrupt, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
