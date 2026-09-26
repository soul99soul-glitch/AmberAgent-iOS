import Foundation
import Observation
@preconcurrency import Shared

/// Owns recap requests for the lifetime of the conversation store, so a panel
/// disappearing or a conversation switch does not cancel a result for its owner.
@MainActor
@Observable
final class ConversationRecapGenerator {
    private(set) var loadingConversationIDs: Set<String> = []
    private(set) var errorsByConversationID: [String: String] = [:]

    @ObservationIgnored private unowned let conversationStore: IOSConversationStore
    @ObservationIgnored private let recapStore: IOSConversationRecapStore
    @ObservationIgnored private let textProvider: any IOSAgentTextProvider
    @ObservationIgnored private var activeRequestTokens: [String: UUID] = [:]
    @ObservationIgnored private var pendingTasks: [String: Task<Void, Never>] = [:]

    init(
        conversationStore: IOSConversationStore,
        recapStore: IOSConversationRecapStore,
        textProvider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter()
    ) {
        self.conversationStore = conversationStore
        self.recapStore = recapStore
        self.textProvider = textProvider
    }

    func invalidate(conversationIDs: [String], reason: String? = nil) {
        conversationIDs.forEach { invalidate(conversationID: $0, reason: reason) }
    }

    func recap(for conversationID: String, messages: [UIMessage]) -> ConversationRecap? {
        recapStore.recap(for: conversationID)?.projectingMessageReferences(to: messages)
    }

    func isLoading(for conversationID: String) -> Bool { loadingConversationIDs.contains(conversationID) }

    func error(for conversationID: String) -> String? {
        errorsByConversationID[conversationID]
    }

    /// A manual request reports an eligibility/configuration/provider failure
    /// to the panel. It starts immediately and replaces only a pending debounce.
    func request(
        conversationID: KotlinUuid,
        messages: [UIMessage],
        settings: IOSSharedSettingsStore,
        compactSummary: String? = nil
    ) async {
        let key = conversationID.toHexDashString()
        guard activeRequestTokens[key] == nil else { return }
        pendingTasks.removeValue(forKey: key)?.cancel()
        guard ConversationRecapLogic.eligible(messages: messages) else {
            errorsByConversationID[key] = "至少需要 3 条用户消息才能生成回顾。"
            return
        }
        let token = beginRequest(for: key)
        defer { finishRequest(for: key, token: token) }
        await generate(
            conversationID: conversationID,
            key: key,
            messages: messages,
            settings: settings,
            compactSummary: compactSummary,
            token: token
        )
    }

    /// Called after successful completion. Repeated completions for the same
    /// conversation while a recap request is active share that single request.
    func schedule(
        conversationID: KotlinUuid,
        messages: [UIMessage],
        settings: IOSSharedSettingsStore,
        compactSummary: String? = nil
    ) {
        let key = conversationID.toHexDashString()
        guard ConversationRecapLogic.eligible(messages: messages), activeRequestTokens[key] == nil else { return }
        loadingConversationIDs.insert(key)
        errorsByConversationID.removeValue(forKey: key)
        pendingTasks[key]?.cancel()
        pendingTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingTasks.removeValue(forKey: key)
            guard self.activeRequestTokens[key] == nil else { return }
            let token = self.beginRequest(for: key)
            defer { self.finishRequest(for: key, token: token) }
            await self.generate(
                conversationID: conversationID,
                key: key,
                messages: messages,
                settings: settings,
                compactSummary: compactSummary,
                token: token
            )
        }
    }

    func invalidate(conversationID: String, reason: String? = nil) {
        let hadRequest = activeRequestTokens[conversationID] != nil || pendingTasks[conversationID] != nil
        let hadRecap = recapStore.recap(for: conversationID) != nil
        pendingTasks.removeValue(forKey: conversationID)?.cancel()
        activeRequestTokens.removeValue(forKey: conversationID)
        loadingConversationIDs.remove(conversationID)
        errorsByConversationID.removeValue(forKey: conversationID)
        if let reason, hadRequest || hadRecap {
            errorsByConversationID[conversationID] = reason
        }
    }

    private func beginRequest(for key: String) -> UUID {
        let token = UUID()
        activeRequestTokens[key] = token
        loadingConversationIDs.insert(key)
        errorsByConversationID.removeValue(forKey: key)
        return token
    }

    private func finishRequest(for key: String, token: UUID) {
        guard activeRequestTokens[key] == token else { return }
        activeRequestTokens.removeValue(forKey: key)
        loadingConversationIDs.remove(key)
    }

    private func setError(_ error: String, for key: String, token: UUID) {
        guard activeRequestTokens[key] == token else { return }
        errorsByConversationID[key] = error
    }

    private func generate(
        conversationID: KotlinUuid,
        key: String,
        messages: [UIMessage],
        settings: IOSSharedSettingsStore,
        compactSummary: String?,
        token: UUID
    ) async {
        let conversationStore = self.conversationStore
        // Capture before async branch lookup so restore/delete that overlaps the
        // lookup also fences this request from writing into the new owner state.
        let baseline = conversationStore.writeBaseline(for: conversationID)
        guard let branchID = await conversationStore.branchIdentifier(for: conversationID, messages: messages) else {
            setError("无法读取当前对话分支，请重试。", for: key, token: token)
            return
        }
        guard activeRequestTokens[key] == token else { return }
        let previousRecap = recapStore.recap(for: key)
        let providedCompactSummary = compactSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableCompactSummary = providedCompactSummary.flatMap { $0.isEmpty ? nil : $0 }
            ?? IOSContextCompactionCoordinator.shared.timelineBoundaries(
                conversationId: conversationID,
                messages: messages
            ).last?.state.summary
        guard let input = ConversationRecapLogic.makeInput(
            previousRecap: previousRecap,
            messages: messages,
            conversationID: key,
            branchID: branchID,
            compactSummary: availableCompactSummary
        ) else {
            setError("当前对话没有可用于回顾的消息。", for: key, token: token)
            return
        }

        let snapshot = settings.snapshot
        guard let model = snapshot.findModelById(uuid: snapshot.titleModelId)
                ?? snapshot.getCurrentChatModel() else {
            setError("请先配置聊天模型后再生成回顾。", for: key, token: token)
            return
        }
        guard let provider = ChatProviderConfiguration.provider(for: model, providers: snapshot.providers) else {
            setError("当前模型没有可用的服务商配置，请检查设置后重试。", for: key, token: token)
            return
        }
        if let issue = ChatProviderConfiguration.issue(for: model, provider: provider) {
            setError(issue.message, for: key, token: token)
            return
        }

        let assistant = snapshot.getCurrentAssistant()
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: ReasoningLevel.off,
            customHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: key
            ),
            customBody: assistant.customBodies + model.customBodies
        )

        let raw: String
        do {
            let chunk = try await textProvider.generateText(
                providerSetting: provider,
                messages: [UIMessage.companion.user(prompt: input.prompt)],
                params: params
            )
            guard let text = chunk.choices.first?.message?.toText()
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                setError(ConversationRecapLogic.ParseError.invalidJSON.localizedDescription, for: key, token: token)
                return
            }
            raw = text
        } catch {
            setError(error.localizedDescription, for: key, token: token)
            return
        }

        guard activeRequestTokens[key] == token else { return }
        let recap: ConversationRecap
        do {
            recap = try ConversationRecapLogic.parse(
                raw,
                messageIDsByReference: input.messageIDsByReference,
                conversationID: key,
                coveredThroughMessageID: input.coveredThroughMessageID,
                branchID: input.branchID
            )
        } catch {
            setError(error.localizedDescription, for: key, token: token)
            return
        }
        do {
            // canApplyAuxiliaryResult fences restore and deletion, while allowing
            // a newer message to coexist with an older recap marked stale.
            guard conversationStore.canApplyAuxiliaryResult(since: baseline) else {
                setError("对话已删除或恢复，回顾未写入，请重新生成。", for: key, token: token)
                return
            }
            try recapStore.save(recap)
        } catch {
            setError(error.localizedDescription, for: key, token: token)
        }
    }
}
