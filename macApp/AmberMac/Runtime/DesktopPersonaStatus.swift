import Foundation
import Observation

/// One volatile status per running reply, including parallel replies in the same conversation.
@MainActor @Observable final class DesktopPersonaStatus {
    let owner = PersonaStatusOwner()
    private(set) var toolActive = false
    private var waiting = false
    @ObservationIgnored private var lastText = ""
    private let generate: @MainActor (String) async -> String?

    init(generate: @escaping @MainActor (String) async -> String?) { self.generate = generate }

    var phrase: String? { waiting && !toolActive ? owner.phrase : nil }

    func refresh(soul: DesktopAgentSoulStore, systemPrompt: String, history: [DesktopMessage],
                 latest: String, isAddition: Bool) {
        guard !latest.isEmpty else { clear(); return }
        waiting = true
        let recent = history.reversed().lazy.compactMap { message -> String? in
            guard message.role == .user || message.role == .assistant else { return nil }
            let text = message.textForEditing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(message.role.rawValue): \(text)"
        }.prefix(4).reversed()
        let persona = [soul.tagline, soul.soulMarkdown, systemPrompt].filter { !$0.isEmpty }.joined(separator: "\n")
        owner.refresh(assistant: soul.displayName, persona: persona, recent: Array(recent), latest: latest,
                      isAddition: isAddition, generate: generate)
    }

    func received(text: String, tools: [DesktopToolCall]) {
        let hasTool = tools.contains { $0.status == .running || $0.status == .pending }
        if toolActive != hasTool { toolActive = hasTool }
        if waiting, !text.isEmpty, lastText != text { clear() }
        lastText = text
    }

    func clear() {
        waiting = false
        owner.clear()
    }
}

extension DesktopWorkspace {
    func makePersonaStatus(configuration: DesktopProviderConfiguration, apiKey: String) -> DesktopPersonaStatus? {
        guard let statusProvider else { return nil }
        return DesktopPersonaStatus { [weak self] prompt in
            guard let self, !Task.isCancelled else { return nil }
            var request = (configuration, apiKey)
            if let title = settings.configuredAuxiliaryModel(for: .title) {
                guard let resolved = try? validatedRequest(title) else { return nil }
                request = resolved
            }
            guard let index = request.0.models.firstIndex(where: { $0.id == request.0.selectedModel?.id }) else { return nil }
            request.0.models[index].maxOutputTokens = 24
            request.0.models[index].temperature = 0.6
            request.0.models[index].reasoning = .off
            request.0.models[index].customBody = nil
            let input = [DesktopMessage(role: .user, text: prompt)]
            guard let run = try? statusProvider.start(configuration: request.0, apiKey: request.1,
                                                      messages: input, responseID: UUID()) else { return nil }
            return await run.firstStatusLine()
        }
    }
}
