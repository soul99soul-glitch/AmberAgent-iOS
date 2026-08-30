import AVFoundation
import Observation

/// iOS system TTS player using AVSpeechSynthesizer.
///
/// HONESTY: only system TTS is supported (AVSpeechSynthesizer). Cloud TTS
/// providers (MiniMax/Gemini/etc.) require network API calls — not implemented.
/// The speak() method uses the iOS system voice to read text aloud, proving
/// the TTS playback chain works on iOS.
@MainActor
@Observable
final class IOSTTSPlayer: NSObject, AVSpeechSynthesizerDelegate {
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking = false
    var lastError: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The BCP-47 voice language tag for the app's selected language.
    ///
    /// `IOSAppLanguage.system` is resolved against the preferred language list
    /// before the tag is passed to AVFoundation.
    nonisolated static func resolvedAppLanguageCode(
        selectedLanguage: IOSAppLanguage = IOSAppLanguagePreference.selected(),
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let resolvedLanguage = selectedLanguage.resolvedLanguage(preferredLanguages: preferredLanguages)
        switch resolvedLanguage {
        case .system:
            preconditionFailure("resolvedLanguage never returns .system")
        case .english:
            return "en-US"
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .japanese:
            return "ja-JP"
        case .korean:
            return "ko-KR"
        case .russian:
            return "ru-RU"
        }
    }

    /// Speak text using the iOS system voice.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - language: An explicit BCP-47 tag (e.g. "zh-CN"). Defaults to the
    ///     app's selected and resolved language.
    ///   - rate: Speed multiplier (0...1, where AVSpeechUtteranceDefaultSpeechRate ≈ 0.5).
    func speak(
        text: String,
        language: String? = nil,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) {
        guard !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let speechLanguage = language ?? Self.resolvedAppLanguageCode()
        if let voice = AVSpeechSynthesisVoice(language: speechLanguage) {
            utterance.voice = voice
        }
        utterance.rate = rate
        isSpeaking = true
        lastError = nil
        synthesizer.speak(utterance)
    }

    /// Stop any current speech.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // isSpeaking already set in speak()
    }
}
