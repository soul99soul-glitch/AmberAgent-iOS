import AVFoundation
import NaturalLanguage

/// User-started read-aloud. The long-form audio policy routes speech to
/// Bluetooth headphones (the system offers a picker), never the Watch speaker.
@MainActor
final class WatchSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingText: String?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        guard speakingText != text else { stop(); return }
        stop()
        speakingText = text
        Task {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
                guard try await session.activate(options: []), speakingText == text else {
                    // Stopped while the route picker was up: release the session too.
                    if speakingText == nil { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
                    return finish(text)
                }
            } catch { return finish(text) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(for: text))
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        guard speakingText != nil else { return }
        speakingText = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finish(_ text: String) {
        guard speakingText == text else { return }
        stop()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in self.finish(text) }
    }

    /// Voices use region codes; map the detected script to the common region.
    static func voiceLanguage(for text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        default: return language.rawValue
        }
    }
}
