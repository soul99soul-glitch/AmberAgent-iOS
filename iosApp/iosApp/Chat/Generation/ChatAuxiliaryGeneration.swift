import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

/// Suggestions have a single cancellable request for the visible composer.
@MainActor
final class ChatSuggestionRequestOwner {
    private(set) var token: UUID?
    var task: Task<Void, Never>?
    var host = "local"
    var source: ChatSuggestionSource?
    var sourceIsCurrent: (@MainActor () -> Bool)?
    var cached: (source: ChatSuggestionSource, suggestions: [String], modelID: String)?
    var feedback = ChatSuggestionFeedbackSession()

    func begin(source: ChatSuggestionSource? = nil) -> UUID {
        task?.cancel()
        let next = UUID()
        token = next
        self.source = source
        return next
    }

    func invalidate() {
        task?.cancel()
        task = nil
        token = nil
        source = nil
        sourceIsCurrent = nil
    }

    func finish(ifCurrent requestToken: UUID) -> Bool {
        guard token == requestToken else { return false }
        task = nil
        token = nil
        return true
    }
}

extension ChatViewModel {

    // MARK: - Auxiliary generation (title + chat suggestions + list preview)

    /// 一轮生成完成后触发:总是尝试生成对话建议与列表浓缩预览;首轮(仅 1 条用户消息)再生成标题。
    /// 工具审批暂停期间(有 pending approval)不触发;最后一条非助手消息也不触发。
    func onGenerationCompleted(state: ChatConversationRunState) {
        guard state.pendingMemoryApproval == nil, state.pendingSearchApproval == nil,
              state.pendingWebMountApproval == nil, state.pendingWorkspaceApproval == nil,
              state.pendingIshHandoffApproval == nil,
              state.pendingMcpApproval == nil,
              state.pendingCouncilApproval == nil,
              state.pendingAskUser == nil,
              state.pendingRecipeApproval == nil else { return }
        if let conversationId = state.conversationId {
            let compactSummary = state.contextCompactState.status == .completed
                ? state.contextCompactState.summary
                : nil
            conversationStore?.recapGenerator.schedule(
                conversationID: conversationId,
                messages: state.messages,
                settings: sharedSettings,
                compactSummary: compactSummary
            )
        }
        guard let last = state.messages.last, last.role == MessageRole.assistant,
              !last.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        syncSoulFromCompletedTurnIfNeeded(messages: state.messages)

        if isCurrentConversation(state.conversationId) { generateChatSuggestions(state: state) }
        let userMessageCount = state.messages.filter { $0.role == MessageRole.user }.count
        if userMessageCount >= 1 { generateConversationTitle(state: state) }
        // 与标题共用 titleModelId；后台成功路径走同一 generator。
        generateConversationListPreview(state: state)
    }

    func finishCompletionFeedback(
        state: ChatConversationRunState, runID: String, succeeded: Bool, messages: [UIMessage]
    ) {
        guard succeeded, isCurrentConversation(state.conversationId),
              !state.isOrchestratedChild, state.waitingForChildRunId == nil,
              let last = messages.last, last.role == MessageRole.assistant else {
            state.completionFeedback.finishWithoutFeedback(runID: runID)
            return
        }
        let textParts: [Int: String] = Dictionary(uniqueKeysWithValues: last.parts.enumerated().compactMap { index, part in
            guard let text = part as? UIMessagePart.Text,
                  !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (index, text.text)
        })
        state.completionFeedback.complete(
            runID: runID, messageID: last.id.toHexDashString(), textParts: textParts
        )
    }

    /// 兜底：若用户在本轮明确要求改人设/写入 soul，但模型仅在回复中答应而漏调 `agent_soul_update`，
    /// 自动把新设定同步进 `AgentSoulStore.shared`，确保顶部形象人设立即生效。
    private func syncSoulFromCompletedTurnIfNeeded(messages: [UIMessage]) {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == MessageRole.user }) else { return }
        let trailingSlice = messages[lastUserIdx...]
        let didCallSoulUpdateTool = trailingSlice.contains { msg in
            msg.parts.contains { part in
                guard let tool = part as? UIMessagePart.Tool else { return false }
                return tool.toolName == AgentSoulToolCatalog.updateToolName
            }
        }
        guard !didCallSoulUpdateTool else { return }
        let userText = messages[lastUserIdx].toText().trimmingCharacters(in: .whitespacesAndNewlines)
        let assistantText = trailingSlice
            .filter { $0.role == MessageRole.assistant }
            .map { $0.toText().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let recentContext = messages.prefix(lastUserIdx).suffix(4)
            .map { $0.toText().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        _ = AgentSoulCloudBridge.syncFromTurnIfNeeded(
            userText: userText,
            assistantText: assistantText,
            recentConversationContext: recentContext,
            store: AgentSoulStore.shared
        )
    }

    /// 辅助模型:优先用指定的辅助模型,未设置时回退当前聊天模型(对齐 Android resolveTaskChatModel)。
    func resolveAuxModel(_ auxId: KotlinUuid) -> Model? {
        sharedSettings.snapshot.findModelById(uuid: auxId) ?? sharedSettings.snapshot.getCurrentChatModel()
    }

    /// 最近 [maxMessages] 条消息拼成带角色前缀的文本,填入提示词的 {content}。
    private func auxConversationText(maxMessages: Int, messages source: [UIMessage]? = nil) -> String {
        (source ?? messages).suffix(maxMessages).compactMap { message -> String? in
            let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role: String
            switch message.role {
            case MessageRole.user: role = "User"
            case MessageRole.assistant: role = "Assistant"
            default: return nil
            }
            return "\(role): \(text)"
        }.joined(separator: "\n\n")
    }

    func auxLocaleName() -> String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
    }

    /// 用辅助模型跑一次单轮文本生成(OpenAIKmpProviderAdapter 内部按服务商类型分发 OpenAI/Claude)。
    func runAuxModel(model: Model, prompt: String, conversationId: KotlinUuid?) async -> String? {
        let snapshot = sharedSettings.snapshot
        guard let provider = ChatProviderConfiguration.provider(
            for: model,
            providers: snapshot.providers
        ), ChatProviderConfiguration.issue(for: model, provider: provider) == nil else { return nil }
        let assistant = snapshot.getCurrentAssistant()
        let params = Self.makeAuxiliaryTextGenerationParams(
            model: model,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: conversationId?.toHexDashString()
            ),
            assistantBodies: assistant.customBodies
        )
        do {
            let chunk = try await auxiliaryTextProvider.generateText(
                providerSetting: provider,
                messages: [UIMessage.companion.user(prompt: prompt)],
                params: params
            )
            return chunk.choices.first?.message?.toText().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func makeAuxiliaryTextGenerationParams(
        model: Model,
        assistantHeaders: [CustomHeader],
        assistantBodies: [CustomBody]
    ) -> TextGenerationParams {
        TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: ReasoningLevel.off,
            customHeaders: assistantHeaders,
            customBody: assistantBodies + model.customBodies
        )
    }

    private func generateConversationTitle(state: ChatConversationRunState) {
        let snapshot = sharedSettings.snapshot
        guard let model = resolveAuxModel(snapshot.titleModelId),
              let conversationId = state.conversationId,
              let conversationStore,
              let expectedTitle = (conversationStore.currentConversation?.id == conversationId
                  ? conversationStore.currentConversation?.title
                  : nil) ?? conversationStore.summaries.first(where: { $0.id == conversationId })?.title else { return }
        let activeMessages = ChatEpisodeStore.shared.unsealedNonSystemMessages(
            for: conversationId.toHexDashString(),
            in: state.messages
        )
        let sourceMessages = activeMessages.isEmpty ? state.messages : activeMessages
        let content = auxConversationText(maxMessages: 4, messages: sourceMessages)
        guard !content.isEmpty else { return }
        let baseline = conversationStore.writeBaseline(for: conversationId)
        // 标题 LLM 顺带选 icon key：列表优先用它，避免事后猜标题关键词。
        let prompt = snapshot.titlePrompt
            .replacingOccurrences(of: "{locale}", with: auxLocaleName())
            .replacingOccurrences(of: "{content}", with: content)
            + HomeConversationIcon.llmIconInstructionBlock()
        Task { [weak self] in
            guard let self else { return }
            guard let raw = await self.runAuxModel(model: model, prompt: prompt, conversationId: conversationId) else { return }
            guard conversationStore.canApplyAuxiliaryResult(since: baseline) else { return }
            let parsed = Self.parseTitleAndIcon(raw)
            let title = Self.sanitizeTitle(parsed.title)
            // Title rename is optional (LLM may return only icon:). Icon write follows
            // rename success when a title is present — never after user rename mismatch.
            if !title.isEmpty {
                let renamed = await conversationStore.renameConversation(
                    id: conversationId,
                    title: title,
                    ifCurrentTitleMatches: expectedTitle
                )
                guard renamed else { return }
            }
            guard conversationStore.canApplyAuxiliaryResult(since: baseline) else { return }
            if let iconKey = parsed.iconKey {
                conversationStore.setListIconKey(id: conversationId, key: iconKey)
            }
        }
    }

    /// 列表浓缩预览：复用标题辅助模型（titleModelId → 当前聊天模型回退）。
    private func generateConversationListPreview(state: ChatConversationRunState) {
        guard let conversationId = state.conversationId,
              let conversationStore else { return }
        ConversationListPreviewGenerator.schedule(
            conversationId: conversationId,
            messages: state.messages,
            store: conversationStore,
            settings: sharedSettings
        )
    }

    func fillInputFromSuggestion(_ suggestion: String) {
        recordSuggestionFeedback(suggestionRequests.feedback.accept(suggestion))
        suggestionRequests.invalidate()
        inputText = suggestion
        chatSuggestions = []
    }

    func beginSuggestionRequest() -> UUID {
        suggestionRequests.begin()
    }

    func invalidateSuggestionRequest(reason: String = "context_changed", preserveCached: Bool = false) {
        recordSuggestionFeedback(suggestionRequests.feedback.dismiss(reason: reason))
        suggestionRequests.invalidate()
        if !preserveCached { suggestionRequests.cached = nil }
        chatSuggestions = []
    }

    func applySuggestions(
        _ suggestions: [String],
        requestToken: UUID,
        conversationId: KotlinUuid?
    ) {
        guard suggestionRequests.token == requestToken,
              inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let source = suggestionRequests.source
        if let source {
            guard source.host == suggestionRequests.host else { return }
            if source.host == "local" {
                guard isCurrentConversation(conversationId), !isGenerationActive,
                      messages.last.map({ String(describing: $0.id) }) == source.turn else { return }
            } else {
                guard suggestionRequests.sourceIsCurrent?() == true else { return }
            }
        } else {
            guard isCurrentConversation(conversationId), !isGenerationActive else { return }
        }
        _ = suggestionRequests.finish(ifCurrent: requestToken)
        publishSuggestions(Array(suggestions.prefix(ChatSuggestionFilter.maximumCount)), source: source,
                           modelID: suggestionRequests.cached?.modelID ?? "")
    }

    /// 清洗标题:取首行、去引号/首尾标点、限长。
    static func sanitizeTitle(_ raw: String) -> String {
        var title = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.lowercased().hasPrefix("icon:") })
            ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”『』「」《》 "))
        if title.count > 24 { title = String(title.prefix(24)) }
        return title
    }

    /// 解析标题 LLM 两行输出：`标题` + 可选 `icon:<key>`。
    static func parseTitleAndIcon(_ raw: String) -> (title: String, iconKey: String?) {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var iconKey: String?
        var titleLines: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("icon:") {
                let key = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                // 只存 catalog 规范化 slug，避免 lower 后的 camelCase 回读失败。
                if let canonical = HomeConversationIcon.canonicalLLMKey(key) {
                    iconKey = canonical
                }
                continue
            }
            titleLines.append(line)
        }
        return (titleLines.first ?? "", iconKey)
    }

    /// 清洗列表浓缩预览：与 `ConversationListPreviewGenerator.sanitize` 同源。
    static func sanitizeListPreview(_ raw: String) -> String {
        ConversationListPreviewGenerator.sanitize(raw)
    }

}
