import AVFoundation
import Foundation
import Observation

struct DesktopSpeechVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
}

struct DesktopSpeechRequest: Equatable, Sendable {
    let id: UUID
    let text: String
    let voiceIdentifier: String?
    let rate: Double
}

enum DesktopSpeechCompletion: Sendable { case finished, cancelled }

@MainActor protocol DesktopSpeechBackend {
    func voices() async -> [DesktopSpeechVoice]
    func speak(_ request: DesktopSpeechRequest,
        completion: @escaping @MainActor @Sendable (UUID, DesktopSpeechCompletion) -> Void) throws
    func stop()
}

@MainActor final class DesktopSystemSpeechBackend: NSObject, DesktopSpeechBackend, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var active: (utterance: ObjectIdentifier, id: UUID,
        completion: @MainActor @Sendable (UUID, DesktopSpeechCompletion) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func voices() async -> [DesktopSpeechVoice] {
        await Task.detached {
            AVSpeechSynthesisVoice.speechVoices().map {
                DesktopSpeechVoice(id: $0.identifier, name: $0.name, language: $0.language)
            }.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        }.value
    }

    func speak(_ request: DesktopSpeechRequest,
        completion: @escaping @MainActor @Sendable (UUID, DesktopSpeechCompletion) -> Void) throws {
        let utterance = AVSpeechUtterance(string: request.text)
        if let identifier = request.voiceIdentifier {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
                throw DesktopRuntimeError.message("所选系统声音不可用，请重新选择声音。")
            }
            utterance.voice = voice
        }
        utterance.rate = Float(request.rate)
        active = (ObjectIdentifier(utterance), request.id, completion)
        synthesizer.speak(utterance)
    }

    func stop() {
        active = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(identifier, outcome: .finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(identifier, outcome: .cancelled) }
    }

    private func complete(_ utterance: ObjectIdentifier, outcome: DesktopSpeechCompletion) {
        guard let request = active, request.utterance == utterance else { return }
        active = nil
        request.completion(request.id, outcome)
    }
}

@MainActor @Observable final class DesktopSpeechPlayer {
    private(set) var currentMessageID: UUID?
    private(set) var availableVoices: [DesktopSpeechVoice] = []
    private(set) var isLoadingVoices = false
    private(set) var error: String?
    var isSpeaking: Bool { requestID != nil }
    @ObservationIgnored private let settings: DesktopSettings
    @ObservationIgnored private let backend: any DesktopSpeechBackend
    private var requestID: UUID?

    init(settings: DesktopSettings, backend: (any DesktopSpeechBackend)? = nil) {
        self.settings = settings
        self.backend = backend ?? DesktopSystemSpeechBackend()
    }

    func loadVoices() async {
        guard !isLoadingVoices else { return }
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        let voices = await backend.voices()
        guard !Task.isCancelled else { return }
        if availableVoices != voices { availableVoices = voices }
    }

    @discardableResult func speak(text: String, messageID: UUID) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = "这条消息没有可朗读的文字。"; return false }
        stop()
        let id = UUID()
        requestID = id; currentMessageID = messageID; error = nil
        let voice = settings.speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try backend.speak(DesktopSpeechRequest(id: id, text: value,
                voiceIdentifier: voice.isEmpty ? nil : voice, rate: settings.speechRate)) { [weak self] completedID, _ in
                    guard let self, self.requestID == completedID else { return }
                    self.requestID = nil; self.currentMessageID = nil
                }
            return true
        } catch {
            if requestID == id { requestID = nil; currentMessageID = nil }
            self.error = "无法开始朗读，请检查所选系统声音后重试。"
            return false
        }
    }

    func stop() {
        requestID = nil; currentMessageID = nil
        backend.stop()
    }
}
