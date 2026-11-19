import Foundation
@preconcurrency import Shared

/// Request-only guidance and automatic effort for an already active phone task.
/// Adds no canonical system message and preserves the user's saved reasoning choice.
enum IOSPhoneAutomationRequestPolicy {
    static let sectionName = "phone_execution"
    static let planningPrompt = """
    For phone tasks, understand the current screen once, then execute the known work:
    - For multi-step taps within the same page (such as selecting one or more options/word chips/particles and tapping Check on the current question, toggling filters, or choosing among dynamic/same-name candidates), prefer one phone_run_goal call (goal, bundle_id, completion, and page_anchor for the current prompt/header) over separate phone_act calls, even if an older note/skill suggests step-by-step phone_act taps.
    - When a short sequence has unique, unambiguous targets and each step has an independent observable postcondition (including text typing), use phone_run_flow instead of separate phone_act calls.
    - For an exercise, decide only the displayed question's target subgoal. A visible Check button alone does not prove an answer was selected; use enabled or a changed value/feedback control where appropriate. Continue only after known expected feedback is verified.
    - Hand back at a new question, page semantic change, unexpected/wrong feedback, an unknown page, final commit, or a new visual decision. Do not invent future answers, targets or feedback labels.
    - Use phone_act only for isolated single actions (such as app launch or a single Continue tap), visual coordinate taps, or withheld final commits requiring explicit confirmation.
    - Reuse the fresh tree returned by an action; when truncated=false, omitted counts only unlabeled empty layout containers, so do not repeat phone_observe (max_nodes, include_screenshot, or include_screen_text) when the prompt and options are already displayed. Do not repeat task planning or waiting filler between routine steps. Preserve authorization, unknown-result stops and completed-step receipts.
    """

    static let flowPlanningPrompt = """
    For phone tasks, understand the current screen once, then execute the known work:
    - Jev goal routing is currently inactive: do not call phone_run_goal. When a short sequence has unique, unambiguous targets and each step has an independent observable postcondition (including multi-step taps or text typing), use phone_run_flow instead of separate phone_act calls.
    - For dynamic or ambiguous multi-step pages where targets depend on intermediate screen changes, observe the current state and use phone_run_flow for deterministic sub-sequences or phone_act for single actions.
    - For an exercise, decide only the displayed question's target subgoal. A visible Check button alone does not prove an answer was selected; use enabled or a changed value/feedback control where appropriate. Continue only after known expected feedback is verified.
    - Hand back at a new question, page semantic change, unexpected/wrong feedback, an unknown page, final commit, or a new visual decision. Do not invent future answers, targets or feedback labels.
    - Use phone_act only for isolated single actions (such as app launch or a single Continue tap), visual coordinate taps, or withheld final commits requiring explicit confirmation.
    - Reuse the fresh tree returned by an action; when truncated=false, omitted counts only unlabeled empty layout containers, so do not repeat phone_observe (max_nodes, include_screenshot, or include_screen_text) when the prompt and options are already displayed. Do not repeat task planning or waiting filler between routine steps. Preserve authorization, unknown-result stops and completed-step receipts.
    """

    nonisolated(unsafe) static var liveGoalPlanningActiveProvider: @Sendable () -> Bool = { true }

    static let presentationPrompt = """
    - Keep the user informed at meaningful milestones. After capturing the requested content or detecting a relevant change, use phone_return_to_amber before substantial analysis, writing or presenting results. Write a concise assistant update with the finding and next step, then continue the requested work in the conversation. Do this even when the user is not watching; do not leave the useful output hidden behind another app.
    - For monitoring, capture the relevant evidence, return to Amber to process and show it, then launch the target app again only when another observation is needed. Choose app switches at task boundaries, not between routine taps. Respect an explicit user request to leave a target app visible: finish phone control with phone_stop(return_to_amber=false) so automatic terminal return will not override it. Do not claim indefinite monitoring: this is a local run subject to iOS background limits.
    - phone_return_to_amber verifies foreground and opens this run's conversation. Its activation receipt alone is not proof that Amber is visible. After a switch, old refs and screenshots are invalid; use the fresh observation from launch before acting again. An unknown result stops all further phone actions, including app switching.
    - Use phone_system to inspect system UI or return Home when the task needs it; system permission buttons still require the user's authorization. Read copied text with phone_clipboard only when needed for this task, with Amber in the foreground; a missing value can mean access was denied, not an empty clipboard.
    """

    static func isPlanningMessage(_ message: UIMessage) -> Bool {
        message.role == .system && message.parts.contains {
            IosToolOutputJsonBridge.shared.metadataString(part: $0, key: "amber_prompt_section") == sectionName
        }
    }

    static func requestMessages(
        _ messages: [UIMessage],
        tools: [Tool],
        goalPlanningActive: Bool = true
    ) -> [UIMessage] {
        let retained = messages.compactMap(removingPlanningMessage)
        guard tools.contains(where: { $0.name == "phone_run_flow" }) else { return retained }
        let names = Set(tools.map(\.name))
        let hasPresentationTools = Set(["phone_return_to_amber", "phone_clipboard", "phone_system"]).isSubset(of: names)
        let selectedPlanningPrompt = (goalPlanningActive && names.contains("phone_run_goal"))
            ? planningPrompt
            : flowPlanningPrompt
        let text = selectedPlanningPrompt + (hasPresentationTools ? "\n" + presentationPrompt : "")
        return [PromptTranscript.shared.sectionMessage(name: sectionName, text: text)] + retained
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
            guard let text = part as? UIMessagePart.Text else { return part }
            let retained = [planningPrompt, flowPlanningPrompt, presentationPrompt].reduce(text.text) {
                $0.replacingOccurrences(of: $1, with: "")
            }
            guard retained != text.text else { return part }
            changed = true
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
