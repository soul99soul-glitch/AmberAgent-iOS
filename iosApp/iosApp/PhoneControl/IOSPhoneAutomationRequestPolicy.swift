import Foundation
@preconcurrency import Shared

/// Request-only guidance and automatic effort for an already active phone task.
/// The canonical conversation and the user's saved reasoning choice stay unchanged.
enum IOSPhoneAutomationRequestPolicy {
    static let sectionName = "phone_execution"
    static let planningPrompt = """
    For phone tasks, understand the current screen once, then execute the known work:
    - When the order, semantic targets and observable postconditions are known, prefer one short phone_run_flow over separate phone_act calls. Each step still uses a fresh tree and verifies its postcondition.
    - For an exercise, decide only the displayed question's answer. Batch its known answer selection/input and checking steps when they have verifiable conditions. A visible Check button alone does not prove an answer was selected; use enabled or a changed value where appropriate. Continue only after known expected feedback is verified.
    - Stop the flow at a new question, unexpected/wrong feedback, an unknown page or a new visual decision. Do not invent future answers, targets or feedback labels. Shorten the flow when evidence is insufficient.
    - Known ordered steps need no Jev choice. Use phone_run_goal only to choose among an explicit finite set of actions. Use phone_act for isolated or visual actions and actions requiring separate confirmation.
    - Reuse the fresh tree returned by an action; do not add phone_observe unless fresh evidence is missing. Do not repeat task planning or progress narration between routine buttons. Preserve authorization, unknown-result stops and completed-step receipts.
    """

    static func isPlanningMessage(_ message: UIMessage) -> Bool {
        message.role == .system && message.parts.contains {
            IosToolOutputJsonBridge.shared.metadataString(part: $0, key: "amber_prompt_section") == sectionName
        }
    }

    static func requestMessages(_ messages: [UIMessage], tools: [Tool]) -> [UIMessage] {
        let retained = messages.compactMap(removingPlanningMessage)
        guard tools.contains(where: { $0.name == "phone_run_flow" }) else { return retained }
        return [PromptTranscript.shared.sectionMessage(name: sectionName, text: planningPrompt)] + retained
    }

    private static func removingPlanningMessage(_ message: UIMessage) -> UIMessage? {
        guard message.role == .system else { return message }
        var changed = false
        let parts = message.parts.compactMap { part -> UIMessagePart? in
            if IosToolOutputJsonBridge.shared.metadataString(part: part, key: "amber_prompt_section") == sectionName {
                changed = true
                return nil
            }
            // Legacy endpoints coalesce system sections before handoff and lose
            // section metadata. Remove only our exact text from that merged part.
            guard let text = part as? UIMessagePart.Text, text.text.contains(planningPrompt) else { return part }
            changed = true
            let retained = text.text.replacingOccurrences(of: planningPrompt, with: "")
            return retained.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : PromptTranscript.shared.doCopyText(part: text, text: retained)
        }
        guard changed else { return message }
        guard !parts.isEmpty else { return nil }
        return UIMessage(
            id: message.id, role: message.role, parts: parts, annotations: message.annotations,
            createdAt: message.createdAt, finishedAt: message.finishedAt, modelId: message.modelId,
            usage: message.usage, translation: message.translation)
    }

    static func requestParams(
        _ params: TextGenerationParams,
        provider: ProviderSetting,
        automaticReasoning: Bool,
        activePhoneSession: Bool
    ) -> TextGenerationParams {
        guard automaticReasoning, activePhoneSession,
              params.tools.contains(where: { IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name) }),
              params.model.abilities.contains(.reasoning),
              params.model.reasoningOptions(provider: provider).contains(where: { $0.level == .low }),
              params.reasoningLevel != .off, params.reasoningLevel != .low else { return params }
        return TextGenerationParams(
            model: params.model, temperature: params.temperature, topP: params.topP,
            maxTokens: params.maxTokens, tools: params.tools, reasoningLevel: .low,
            customHeaders: params.customHeaders, customBody: params.customBody
        )
    }
}
