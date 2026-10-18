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

    func begin() -> UUID {
        task?.cancel()
        let next = UUID()
        token = next
        return next
    }

    func invalidate() {
        task?.cancel()
        task = nil
        token = nil
    }

    func finish(ifCurrent requestToken: UUID) -> Bool {
        guard token == requestToken else { return false }
        task = nil
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

        // 完成触觉：单次刚性轻触。iOS 本地偏好（默认开）；不复用 KMP
        // enableMessageGenerationHapticEffect——那是 Android-only 接线且默认关，
        // 动它会改变 Android 默认行为。
        let hapticKey = IOSDisplayPreferenceKeys.completionHaptic
        let defaults = UserDefaults.standard
        let hapticEnabled = defaults.object(forKey: hapticKey) == nil
            ? true
            : defaults.bool(forKey: hapticKey)
        if hapticEnabled {
            AmberHaptics.trigger(.rigidImpact)
        }

        if isCurrentConversation(state.conversationId) { generateChatSuggestions() }
        let userMessageCount = state.messages.filter { $0.role == MessageRole.user }.count
        if userMessageCount == 1 { generateConversationTitle(state: state) }
        // 与标题共用 titleModelId；后台成功路径走同一 generator。
        generateConversationListPreview(state: state)
    }

    /// 辅助模型:优先用指定的辅助模型,未设置时回退当前聊天模型(对齐 Android resolveTaskChatModel)。
    private func resolveAuxModel(_ auxId: KotlinUuid) -> Model? {
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

    private func auxLocaleName() -> String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
    }

    /// 用辅助模型跑一次单轮文本生成(OpenAIKmpProviderAdapter 内部按服务商类型分发 OpenAI/Claude)。
    private func runAuxModel(model: Model, prompt: String, conversationId: KotlinUuid?) async -> String? {
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
              let expectedTitle = conversationStore.summaries.first(where: { $0.id == conversationId })?.title else { return }
        let content = auxConversationText(maxMessages: 4, messages: state.messages)
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
        invalidateSuggestionRequest()
        inputText = suggestion
        chatSuggestions = []
    }

    private func generateChatSuggestions() {
        let snapshot = sharedSettings.snapshot
        guard let model = resolveAuxModel(snapshot.suggestionModelId) else { return }
        let content = auxConversationText(maxMessages: 8)
        guard !content.isEmpty else { return }
        let prompt = snapshot.suggestionPrompt
            .replacingOccurrences(of: "{locale}", with: auxLocaleName())
            .replacingOccurrences(of: "{content}", with: content)
        let conversationId = currentConversationId
        let requestToken = beginSuggestionRequest()
        suggestionRequests.task = Task { [weak self] in
            guard let self else { return }
            guard let raw = await self.runAuxModel(model: model, prompt: prompt, conversationId: conversationId) else { return }
            guard !Task.isCancelled else { return }
            let suggestions = raw
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(5)
            self.applySuggestions(
                Array(suggestions),
                requestToken: requestToken,
                conversationId: conversationId
            )
        }
    }

    func beginSuggestionRequest() -> UUID {
        suggestionRequests.begin()
    }

    func invalidateSuggestionRequest() {
        suggestionRequests.invalidate()
    }

    func applySuggestions(
        _ suggestions: [String],
        requestToken: UUID,
        conversationId: KotlinUuid?
    ) {
        guard suggestionRequests.token == requestToken,
              isCurrentConversation(conversationId),
              !isGenerationActive else { return }
        _ = suggestionRequests.finish(ifCurrent: requestToken)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            chatSuggestions = suggestions
        }
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
