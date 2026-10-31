import Foundation
@preconcurrency import Shared

struct IOSConversationCompact: Codable, Equatable {
    let id: String
    let conversationId: String
    let summary: String
    let level: Int
    let sourceStartIndex: Int
    let sourceEndIndex: Int
    let sourceMessageIds: [String]
    let tokenEstimate: Int
    let createdAt: Int64
    let updatedAt: Int64
    let status: String
    var timelineAnchorMessageId: String? = nil
}

struct IOSCompactPolicy {
    let enabled: Bool
    let notifyOnly: Bool
    /// 自动压缩的唯一门槛。iOS 在上传前同步压缩，没有可异步“预压”的窗口；
    /// 另设 0.70 预压只会更早丢弃上下文，所以这里固定等于 `forceRatio`。
    let triggerRatio: Double
    /// 强制压缩后的目标占用上限，也用于标记 force_threshold。
    let forceRatio: Double
    let keepRecentTurns: Int
    let maxSummaryTokens: Int

    init(_ setting: ContextCompactionSetting) {
        enabled = setting.enabled
        notifyOnly = setting.notifyOnly
        triggerRatio = Double(setting.forceRatio)
        forceRatio = Double(setting.forceRatio)
        keepRecentTurns = Int(setting.keepRecentTurns)
        maxSummaryTokens = Int(setting.maxSummaryTokens)
    }
}

struct IOSCompactPlan {
    let shouldCompact: Bool
    let reason: String
    let estimatedTokens: Int
    let contextWindowTokens: Int
    let sourceStartIndex: Int
    let sourceEndIndex: Int
    let sourceMessageIds: [String]

    var sourceMessageCount: Int {
        shouldCompact ? sourceMessageIds.count : 0
    }
}

enum IOSContextCompactionEvent {
    case idle
    case planning
    case compacting
    case completed(summary: String)
    case failed(message: String)
}

enum ChatContextCompactEventRouter {
    static func shouldApply(
        event: IOSContextCompactionEvent,
        eventRunId: String,
        currentRunId: String?
    ) -> Bool {
        currentRunId == eventRunId
    }
}

@MainActor
final class IOSContextCompactionCoordinator {
    static let shared = IOSContextCompactionCoordinator()

    private let store = IOSConversationCompactStore()
    private var activeCompactionTasks: [String: Task<IOSConversationCompact?, Error>] = [:]
    /// History length at the last failed pass. Every tool round re-prepares the request,
    /// so without this a broken summarizer would be retried (at full input size) each round.
    private var failedCompactionHistoryCount: [String: Int] = [:]

    private let textProvider: any IOSAgentTextProvider

    init(textProvider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter()) {
        self.textProvider = textProvider
    }

    /// Deleting a conversation deletes its summaries too; an in-flight pass is cancelled
    /// so it cannot recreate the file afterwards.
    func removeCompacts(conversationIds: [String]) throws {
        var firstError: Error?
        for conversationId in conversationIds {
            activeCompactionTasks[conversationId]?.cancel()
            failedCompactionHistoryCount[conversationId] = nil
            do {
                try store.remove(conversationId: conversationId)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    #if DEBUG
    /// 测试支撑：写入一个 completed compact，用于验证 history_* 的 stale 标记。
    /// 生产路径只由压缩流程写入；调用方负责用 removeCompacts 清理。
    func insertTestCompact(_ compact: IOSConversationCompact) throws {
        var compacts = store.load(conversationId: compact.conversationId)
        compacts.removeAll { $0.id == compact.id }
        compacts.append(compact)
        try store.save(compacts, conversationId: compact.conversationId)
    }
    #endif

    static func estimatedTokensForRequest(_ messages: [UIMessage]) -> Int {
        estimateTokens(messages)
    }

    func timelineBoundaries(conversationId: KotlinUuid?, messages: [UIMessage]) -> [ChatContextCompactBoundary] {
        guard let conversationId else { return [] }
        let ids = Set(messages.map(Self.messageId))
        return Self.validCompletedCompacts(store.load(conversationId: String(describing: conversationId)), existingMessageIds: ids)
            .compactMap { compact in
                let covered = Set(compact.sourceMessageIds)
                guard let anchor = compact.timelineAnchorMessageId
                    ?? messages.last(where: { covered.contains(Self.messageId($0)) }).map(Self.messageId),
                      ids.contains(anchor) else { return nil }
                return ChatContextCompactBoundary(
                    id: compact.id, afterMessageId: anchor, coveredMessageIds: covered,
                    state: ChatContextCompactState(status: .completed,
                        summary: Self.timelineSummary(compact.summary) ?? "上下文已压缩。",
                        updatedAt: Date(timeIntervalSince1970: Double(compact.createdAt) / 1_000))
                )
            }
    }

    /// Tokens the next send is expected to load: last fresh usage (prompt+completion)
    /// when it is newer than the latest compact, otherwise a compact-aware estimate.
    func nextTurnOccupancyTokens(
        messages: [UIMessage],
        conversationId: KotlinUuid?,
        draftText: String,
        extraWeightedChars: Int = 0,
        systemOverheadText: String = ""
    ) -> Int {
        let compacts: [IOSConversationCompact]
        if let conversationId {
            compacts = store.load(conversationId: String(describing: conversationId))
        } else {
            compacts = []
        }
        return Self.nextTurnOccupancyTokens(
            messages: messages,
            activeCompacts: compacts,
            draftText: draftText,
            extraWeightedChars: extraWeightedChars,
            systemOverheadText: systemOverheadText
        )
    }

    func prepareMessagesForRequest(
        uploadMessages: [UIMessage],
        conversationId: KotlinUuid?,
        settings: Settings,
        params: TextGenerationParams,
        fallbackProvider: ProviderSetting,
        promptOverheadTokens: Int = 0,
        additionalHistoryOverhead: (([UIMessage]) -> Int)? = nil,
        onEvent: ((IOSContextCompactionEvent) -> Void)? = nil
    ) async throws -> [UIMessage] {
        // Request-only: older tool-result images become placeholders before any budgeting,
        // so compaction plans against what is actually uploaded. Storage is unchanged.
        let uploadMessages = IOSToolImageRequestBudget.apply(uploadMessages)
        let policy = IOSCompactPolicy(settings.agentRuntime.contextCompaction)
        let contextMessageSize = Int(settings.resolveSessionDefaults(
            assistant: settings.getCurrentAssistant(),
            model: params.model
        ).contextMessageSize)
        let systemMessages = uploadMessages.filter { $0.role == MessageRole.system }
        let historyMessages = uploadMessages.filter { $0.role != MessageRole.system }
        let baseOverhead = Self.estimateTokens(systemMessages) + Self.requestOverheadTokens(
            params: params,
            promptOverheadTokens: promptOverheadTokens
        )
        func overhead(for history: [UIMessage]) -> Int {
            baseOverhead + max(additionalHistoryOverhead?(systemMessages + history) ?? 0, 0)
        }
        var overheadEstimate = overhead(for: historyMessages)

        let edited: (messages: [UIMessage], removedToolResults: Int)
        if policy.enabled {
            let keepRecentMessages = max(policy.keepRecentTurns * 2, 4)
            edited = Self.editPreparedContext(
                messages: uploadMessages,
                keepRecentMessages: keepRecentMessages,
                retainedToolCallIds: IOSJevToolRetentionService.shared.retainedToolCallIds(
                    messages: uploadMessages,
                    conversationId: conversationId?.toHexDashString(),
                    keepRecentMessages: keepRecentMessages
                )
            )
        } else {
            edited = (uploadMessages, 0)
        }
        let removedToolResults = edited.removedToolResults

        // Request-only system instructions retain their identity and budget, but are not durable history.
        let editedMessages = edited.messages.filter { $0.role != MessageRole.system }
        guard policy.enabled, let conversationId else {
            return systemMessages + Self.limitContext(editedMessages, size: contextMessageSize)
        }

        let conversationKey = String(describing: conversationId)
        var compacts = store.load(conversationId: conversationKey)
        let resolvedModelWindow = ChatContextSnapshot.resolvedContextWindowTokens(
            modelWindow: Self.intValue(params.model.contextWindowTokens), modelId: params.model.modelId
        )
        let plan = Self.planCompaction(
            messages: editedMessages,
            activeCompacts: compacts,
            policy: policy,
            modelContextWindowTokens: resolvedModelWindow,
            extraTokenEstimate: overheadEstimate
        )

        // A failed summary never blocks the send: the local budget fit below still
        // trims (with a visible notice) and `assertFitsRequest` stays the hard gate.
        // After a failure, retry only once a kept window's worth of new messages arrived.
        let inFailureCooldown = failedCompactionHistoryCount[conversationKey].map {
            historyMessages.count < $0 + max(policy.keepRecentTurns * 2, 2)
        } ?? false
        var compactFailed = false
        func compactOrDegrade(
            policy: IOSCompactPolicy,
            reason: String,
            force: Bool,
            extraTokenEstimate: Int
        ) async throws -> IOSConversationCompact? {
            compactFailed = false
            do {
                let compact = try await compactConversation(
                    messages: historyMessages,
                    conversationKey: conversationKey,
                    settings: settings,
                    policy: policy,
                    model: params.model,
                    fallbackProvider: fallbackProvider,
                    reason: reason,
                    force: force,
                    extraTokenEstimate: extraTokenEstimate
                )
                if compact != nil {
                    failedCompactionHistoryCount[conversationKey] = nil
                } else {
                    failedCompactionHistoryCount[conversationKey] = historyMessages.count
                }
                return compact
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                failedCompactionHistoryCount[conversationKey] = historyMessages.count
                NSLog("[ContextCompact] \(reason) failed, falling back to budget fit: \(error.localizedDescription)")
                onEvent?(.failed(message: "上下文压缩失败，已改为省略较早消息：\((error as NSError).localizedDescription)"))
                compactFailed = true
                return nil
            }
        }

        var ranCompactionPass = false
        if plan.shouldCompact && !policy.notifyOnly && !inFailureCooldown {
            ranCompactionPass = true
            onEvent?(.planning)
            onEvent?(.compacting)
            let result = try await compactOrDegrade(
                policy: policy,
                reason: "auto_precompact",
                force: false,
                extraTokenEstimate: overheadEstimate
            )
            if let result {
                onEvent?(.completed(summary: Self.timelineSummary(result.summary) ?? "上下文已压缩。"))
            } else if !compactFailed {
                onEvent?(.idle)
            }
            compacts = store.load(conversationId: conversationKey)
        }

        var preparedMessages = Self.prepareMessagesWithCompacts(
            messages: editedMessages,
            activeCompacts: compacts,
            policy: policy,
            contextMessageSize: contextMessageSize,
            removedToolResults: removedToolResults
        )
        let contextWindow = Self.estimateContextWindow(resolvedModelWindow)
        let forceBudget = max(Int(Double(contextWindow) * policy.forceRatio), 1)
        let softTotalBudget = max(forceBudget, 4_000)
        // Compaction folds covered prompt transitions into a checkpoint. Recompute
        // their cost instead of reserving the now-removed history indefinitely.
        overheadEstimate = overhead(for: preparedMessages)
        var estimate = Self.estimateTokens(preparedMessages) + overheadEstimate

        // At most one summary cycle per request unless regular compaction left us over forceBudget;
        // check planForceCompaction before entering so we never spin when nothing is compactable.
        if !policy.notifyOnly && estimate > forceBudget && !inFailureCooldown && !compactFailed {
            let fitPolicy = IOSCompactPolicy(
                enabled: policy.enabled,
                notifyOnly: policy.notifyOnly,
                triggerRatio: policy.triggerRatio,
                forceRatio: policy.forceRatio,
                keepRecentTurns: max(policy.keepRecentTurns / 2, 2),
                maxSummaryTokens: policy.maxSummaryTokens
            )
            let forcePlan = Self.planForceCompaction(
                messages: editedMessages,
                activeCompacts: compacts,
                policy: fitPolicy,
                modelContextWindowTokens: resolvedModelWindow,
                extraTokenEstimate: overheadEstimate
            )
            if forcePlan.shouldCompact && !ranCompactionPass && plan.reason != "already_compacted" {
                onEvent?(.compacting)
                let compact = try await compactOrDegrade(
                    policy: fitPolicy,
                    reason: "auto_fit_model_window",
                    force: true,
                    extraTokenEstimate: overheadEstimate
                )
                compacts = store.load(conversationId: conversationKey)
                if let compact {
                    onEvent?(.completed(summary: Self.timelineSummary(compact.summary) ?? "上下文已压缩。"))
                } else if !compactFailed {
                    // No new summary: the budget fit below trims instead; do not replay an old one as "completed".
                    onEvent?(.idle)
                }
                preparedMessages = Self.prepareMessagesWithCompacts(
                    messages: editedMessages,
                    activeCompacts: compacts,
                    policy: fitPolicy,
                    contextMessageSize: contextMessageSize,
                    removedToolResults: removedToolResults
                )
                overheadEstimate = overhead(for: preparedMessages)
                estimate = Self.estimateTokens(preparedMessages) + overheadEstimate
            } else if !forcePlan.shouldCompact {
                failedCompactionHistoryCount[conversationKey] = historyMessages.count
            }
        }

        if estimate > forceBudget {
            preparedMessages = Self.fitMessagesToTokenBudget(
                preparedMessages,
                maxTokens: max(softTotalBudget - overheadEstimate, 1_000)
            )
            overheadEstimate = overhead(for: preparedMessages)
        }
        try Self.assertFitsRequest(
            messages: preparedMessages,
            overheadTokens: overheadEstimate,
            forceBudget: forceBudget
        )
        return systemMessages + preparedMessages
    }

    func finalizedMessagesForRequest(
        _ messages: [UIMessage],
        settings: Settings,
        params: TextGenerationParams,
        additionalOverheadTokens: Int = 0,
        preserveMessageOrder: Bool = false
    ) throws -> [UIMessage] {
        let policy = IOSCompactPolicy(settings.agentRuntime.contextCompaction)
        let toolOverhead = Self.requestOverheadTokens(params: params) + max(additionalOverheadTokens, 0)
        let contextWindow = Self.estimateContextWindow(
            ChatContextSnapshot.resolvedContextWindowTokens(
                modelWindow: Self.intValue(params.model.contextWindowTokens), modelId: params.model.modelId
            )
        )
        let forceBudget = max(Int(Double(contextWindow) * policy.forceRatio), 1)
        let estimate = Self.estimateTokens(messages) + toolOverhead
        guard estimate > forceBudget else { return messages }
        // A native transcript's system updates have historical positions. The
        // ordinary fitter groups system messages at the front, so it must never
        // rewrite a prepared transcript. Its caller fits the canonical copy first.
        if preserveMessageOrder {
            try Self.assertFitsRequest(messages: messages, overheadTokens: toolOverhead, forceBudget: forceBudget)
            return messages
        }
        let softTotalBudget = max(forceBudget, 4_000)
        let targetMessageBudget = max(softTotalBudget - toolOverhead, 1_000)
        let fitted = Self.fitMessagesToTokenBudget(messages, maxTokens: targetMessageBudget)
        try Self.assertFitsRequest(
            messages: fitted,
            overheadTokens: toolOverhead,
            forceBudget: forceBudget
        )
        return fitted
    }

    private func compactConversation(
        messages: [UIMessage],
        conversationKey: String,
        settings: Settings,
        policy: IOSCompactPolicy,
        model: Model,
        fallbackProvider: ProviderSetting,
        reason: String,
        force: Bool,
        extraTokenEstimate: Int = 0
    ) async throws -> IOSConversationCompact? {
        while let task = activeCompactionTasks[conversationKey] {
            do {
                _ = try await task.value
            } catch {
                NSLog("[ContextCompact] previous compact task failed before \(reason): \(error.localizedDescription)")
            }
        }
        let task = Task<IOSConversationCompact?, Error> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.activeCompactionTasks[conversationKey] = nil }
            return try await self.compactConversationLocked(
                messages: messages,
                conversationKey: conversationKey,
                settings: settings,
                policy: policy,
                model: model,
                fallbackProvider: fallbackProvider,
                reason: reason,
                force: force,
                extraTokenEstimate: extraTokenEstimate
            )
        }
        activeCompactionTasks[conversationKey] = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func compactConversationLocked(
        messages: [UIMessage],
        conversationKey: String,
        settings: Settings,
        policy: IOSCompactPolicy,
        model: Model,
        fallbackProvider: ProviderSetting,
        reason: String,
        force: Bool,
        extraTokenEstimate: Int = 0
    ) async throws -> IOSConversationCompact? {
        var compacts = store.load(conversationId: conversationKey)
        let resolvedModelWindow = ChatContextSnapshot.resolvedContextWindowTokens(
            modelWindow: Self.intValue(model.contextWindowTokens), modelId: model.modelId
        )
        let plan = force
            ? Self.planForceCompaction(
                messages: messages,
                activeCompacts: compacts,
                policy: policy,
                modelContextWindowTokens: resolvedModelWindow,
                extraTokenEstimate: extraTokenEstimate
            )
            : Self.planCompaction(
                messages: messages,
                activeCompacts: compacts,
                policy: policy,
                modelContextWindowTokens: resolvedModelWindow,
                extraTokenEstimate: extraTokenEstimate
            )
        guard plan.shouldCompact else { return nil }

        let preferredCompressionModel = settings.findModelById(uuid: settings.compressModelId)
            ?? settings.getCurrentChatModel()
        let preferredProvider = preferredCompressionModel.flatMap {
            ChatProviderConfiguration.provider(for: $0, providers: settings.providers)
        }
        let canUsePreferred = preferredProvider.map(Self.supportsTextGeneration) ?? false
        var compressionModel = canUsePreferred ? (preferredCompressionModel ?? model) : model
        var rawProvider = canUsePreferred ? (preferredProvider ?? fallbackProvider) : fallbackProvider

        let planIds = Set(plan.sourceMessageIds)
        let candidates = messages.filter { planIds.contains(Self.messageId($0)) }
        let existingMessageIds = Set(messages.map(Self.messageId))
        let previousCompacts = Self.selectCompactsForInjection(
            activeCompacts: compacts,
            existingMessageIds: existingMessageIds
        )
        let offeredCompactIds = previousCompacts.map(\.id)
        let previousCompactContext = previousCompacts
            .map { Self.injectionText($0) }
            .joined(separator: "\n\n")
        let createdAt = Self.nowMillis()

        // The summary request must fit the model that actually runs it, not the chat
        // model that triggered the plan. Oldest messages go first; the rest stay raw
        // and are picked up by a later pass.
        let candidateInputs = candidates.map { Self.buildCompressionInput([$0]) }
        func fittingInputs(for candidateModel: Model) -> (inputs: [String], truncated: Bool) {
            let window = Self.estimateContextWindow(ChatContextSnapshot.resolvedContextWindowTokens(
                modelWindow: Self.intValue(candidateModel.contextWindowTokens), modelId: candidateModel.modelId
            ))
            let base = Self.buildCompressionPrompt(
                basePrompt: settings.compressPrompt, content: "", targetTokens: policy.maxSummaryTokens,
                additionalPrompt: Self.compactionRetryPrompt, coveredCompactIds: offeredCompactIds,
                previousCompactContext: previousCompactContext
            )
            // The fidelity block is added after this sizing pass; reserve its
            // worst case so a small summarizer window is not overrun on attempt 1.
            var remaining = Int(Double(window) * Self.compressionInputRatio)
                - max(policy.maxSummaryTokens, 1_024) - Self.estimatePromptTokens(base)
                - Self.compactionFidelityReserveTokens
            var selected: [String] = []
            var truncated = false
            for input in candidateInputs {
                let cost = Self.estimatePromptTokens(input) + 1
                guard cost <= remaining else {
                    // An oversized oldest message would otherwise block every later pass.
                    // Budget tokens ≥ weighted chars / 4, so this many chars always fits.
                    if selected.isEmpty, remaining >= 1_000 {
                        selected.append(input.takeMiddle(maxChars: remaining))
                        truncated = true
                    }
                    break
                }
                remaining -= cost
                selected.append(input)
            }
            return (selected, truncated)
        }
        var fitting = fittingInputs(for: compressionModel)
        var sourceInputs = fitting.inputs
        var sourceWasTruncated = fitting.truncated
        if sourceInputs.count < min(candidates.count, 2), compressionModel.id != model.id {
            // The configured summarizer is too small for even the oldest turns; use the chat model.
            let chatFitting = fittingInputs(for: model)
            if chatFitting.inputs.count > sourceInputs.count {
                sourceInputs = chatFitting.inputs
                sourceWasTruncated = chatFitting.truncated
                compressionModel = model
                rawProvider = fallbackProvider
            }
        }
        guard !sourceInputs.isEmpty else {
            throw NSError(
                domain: "AmberAgent.ContextCompaction", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "压缩模型的上下文窗口不足以容纳待压缩的历史。"]
            )
        }
        let sourceMessageIds = candidates.prefix(sourceInputs.count).map(Self.messageId)
        let sourceContent = sourceInputs.joined(separator: "\n\n")
        // A middle-truncated giant message was not fully visible to the model; requiring
        // entities from its dropped head/tail would guarantee a false rejection.
        let mustNotLose = sourceWasTruncated
            ? []
            : IOSContextCompactionFidelity.extract(from: Array(candidates.prefix(sourceInputs.count)))

        func summarize(additionalPrompt: String) async throws -> String? {
            let prompt = Self.buildCompressionPrompt(
                basePrompt: settings.compressPrompt,
                content: sourceContent,
                targetTokens: policy.maxSummaryTokens,
                additionalPrompt: additionalPrompt,
                coveredCompactIds: offeredCompactIds,
                previousCompactContext: previousCompactContext,
                mustNotLose: mustNotLose
            )
        let raw = try await generateCompactSummary(
                provider: rawProvider,
                model: compressionModel,
                prompt: prompt,
                conversationId: conversationKey
            )
            return Self.normalizedPayload(
                raw,
                sourceMessageIds: sourceMessageIds,
                offeredCompactIds: offeredCompactIds,
                createdAt: createdAt,
                mustNotLose: mustNotLose
            )
        }
        // A summary that fails the gate is never saved: it would replace real history.
        var acceptedSummary = try await summarize(additionalPrompt: "")
        if acceptedSummary == nil {
            acceptedSummary = try await summarize(additionalPrompt: Self.compactionRetryPrompt)
        }
        guard let normalizedSummary = acceptedSummary else {
            throw NSError(
                domain: "AmberAgent.ContextCompaction", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "压缩模型没有返回可用的交接摘要。"]
            )
        }

        let sourceIdSet = Set(sourceMessageIds)
        let sourceIndices = messages.indices.filter { sourceIdSet.contains(Self.messageId(messages[$0])) }
        let compactId = UUID().uuidString.lowercased()
        let compact = IOSConversationCompact(
            id: compactId,
            conversationId: conversationKey,
            summary: normalizedSummary,
            level: 1,
            sourceStartIndex: sourceIndices.first ?? 0,
            sourceEndIndex: sourceIndices.last ?? 0,
            sourceMessageIds: sourceMessageIds,
            tokenEstimate: Self.estimateTokens([
                UIMessage.companion.system(prompt: Self.injectionText(
                    id: compactId,
                    summary: normalizedSummary,
                    sourceMessageIds: sourceMessageIds
                ))
            ]),
            createdAt: createdAt,
            updatedAt: Self.nowMillis(),
            status: "completed",
            timelineAnchorMessageId: messages.last.map(Self.messageId)
        )
        // A cancelled pass (request cancelled or conversation deleted) must not write.
        try Task.checkCancellation()
        compacts = store.load(conversationId: conversationKey)
        if !compacts.contains(where: { $0.id == compact.id }) {
            compacts.append(compact)
        }
        try store.save(compacts, conversationId: conversationKey)
        NSLog("[ContextCompact] \(reason) compacted \(sourceMessageIds.count) messages into \(compact.id)")
        return compact
    }

    private func generateCompactSummary(
        provider rawProvider: ProviderSetting,
        model: Model,
        prompt: String,
        conversationId: String
    ) async throws -> String {
        let provider = try await IOSGrokWebProviderResolver.resolved(
            try await IOSCodexProviderResolver.resolved(rawProvider)
        )
        let params = IOSGrokWebProviderResolver.augmentParamsForGrok(
            IOSCodexProviderResolver.augmentParamsForCodex(
                TextGenerationParams(
                    model: model,
                    temperature: nil,
                    topP: nil,
                    maxTokens: nil,
                    tools: [],
                    reasoningLevel: ReasoningLevel.off,
                    customHeaders: ChatProviderConfiguration.requestHeaders(
                        for: provider,
                        model: model.customHeaders,
                        conversationId: conversationId
                    ),
                    customBody: []
                ),
                provider: provider
            ),
            provider: provider
        )
        let chunk = try await textProvider.generateText(
            providerSetting: provider,
            messages: [UIMessage.companion.user(prompt: prompt)],
            params: params
        )
        return chunk.choices.first?.message?.toText()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension IOSCompactPolicy {
    init(
        enabled: Bool,
        notifyOnly: Bool,
        triggerRatio: Double,
        forceRatio: Double,
        keepRecentTurns: Int,
        maxSummaryTokens: Int
    ) {
        self.enabled = enabled
        self.notifyOnly = notifyOnly
        self.triggerRatio = triggerRatio
        self.forceRatio = forceRatio
        self.keepRecentTurns = keepRecentTurns
        self.maxSummaryTokens = maxSummaryTokens
    }
}

private final class IOSConversationCompactStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [String: [IOSConversationCompact]] = [:]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = documents.appendingPathComponent("conversation-compacts", isDirectory: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func load(conversationId: String) -> [IOSConversationCompact] {
        if let cached = cache[conversationId] {
            return cached
        }

        let url = fileURL(conversationId: conversationId)
        var compacts: [IOSConversationCompact] = []
        if let data = try? Data(contentsOf: url) {
            do {
                compacts = try decoder.decode([IOSConversationCompact].self, from: data)
            } catch {
                // Keep the unreadable file for recovery instead of letting the next save overwrite it.
                let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                NSLog("[ContextCompact] unreadable compact file moved aside: \(error.localizedDescription)")
            }
        }
        cache[conversationId] = compacts
        return compacts
    }

    func remove(conversationId: String) throws {
        cache[conversationId] = nil
        let url = fileURL(conversationId: conversationId)
        // Includes files moved aside by `load` as unreadable: they hold the same summaries.
        let asidePrefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name == url.lastPathComponent || name.hasPrefix(asidePrefix) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func save(_ compacts: [IOSConversationCompact], conversationId: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sanitized = compacts.map { compact in
            IOSConversationCompact(
                id: compact.id,
                conversationId: compact.conversationId,
                summary: IOSContextCompactionFidelity.redactCredentials(compact.summary),
                level: compact.level,
                sourceStartIndex: compact.sourceStartIndex,
                sourceEndIndex: compact.sourceEndIndex,
                sourceMessageIds: compact.sourceMessageIds,
                tokenEstimate: compact.tokenEstimate,
                createdAt: compact.createdAt,
                updatedAt: compact.updatedAt,
                status: compact.status,
                timelineAnchorMessageId: compact.timelineAnchorMessageId
            )
        }
        let data = try encoder.encode(sanitized)
        try data.write(to: fileURL(conversationId: conversationId), options: .atomic)
        cache[conversationId] = sanitized
    }

    private func fileURL(conversationId: String) -> URL {
        let safe = conversationId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }
}

extension IOSContextCompactionCoordinator {
    static let clearMinOutputChars = 2_000

    /// Jev 压缩保留的候选口径：移出保留窗口后会被清空的结果（与 clearToolResult 同条件）。
    static func wouldClearToolResult(_ tool: UIMessagePart.Tool, in message: UIMessage) -> Bool {
        !messageHasMultimodalPart(message)
            && canEditPreparedResult(tool)
            && safeToClearPreparedResult(tool)
            && outputChars(tool.output) > clearMinOutputChars
    }

    static func toolOutputCharacterCount(_ tool: UIMessagePart.Tool) -> Int {
        outputChars(tool.output)
    }
}

#if DEBUG
@MainActor
enum ChatGenerationRequestPreparationTestSupport {
    static func finalizedUploadMessagesForTesting(
        uploadMessages: [UIMessage],
        maxTokens: Int,
        messagesByInjectingRuntimeContext: ([UIMessage]) -> [UIMessage]
    ) -> [UIMessage] {
        let runtimeInjectedMessages = messagesByInjectingRuntimeContext(uploadMessages)
        let fitted = IOSContextCompactionCoordinator.fitMessagesToTokenBudget(
            runtimeInjectedMessages,
            maxTokens: maxTokens
        )
        return ChatRuntimeContextBuilder.coalescingSystemMessages(fitted)
    }
}
#endif

#if DEBUG
/// G9 契约测试支撑:把 coordinator 的私有静态入口暴露给 iosAppTests,验证占位标记、
/// 移除计数与截尾注记的真实行为(不经过 provider/存储)。
@MainActor
enum ContextCompactionEditTestSupport {
    static func automaticPlan(
        messages: [UIMessage], coveredIds: [String], overheadTokens: Int = 0
    ) -> (shouldCompact: Bool, estimatedTokens: Int) {
        let compact = IOSConversationCompact(
            id: "compact-test", conversationId: "conv", summary: "A short handoff.", level: 1,
            sourceStartIndex: 0, sourceEndIndex: coveredIds.count - 1, sourceMessageIds: coveredIds,
            tokenEstimate: 20, createdAt: 1, updatedAt: 1, status: "completed"
        )
        let plan = IOSContextCompactionCoordinator.planCompaction(
            messages: messages, activeCompacts: coveredIds.isEmpty ? [] : [compact],
            policy: IOSCompactPolicy(enabled: true, notifyOnly: false, triggerRatio: 0.9,
                                     forceRatio: 0.9, keepRecentTurns: 2, maxSummaryTokens: 200),
            modelContextWindowTokens: 10_000, extraTokenEstimate: overheadTokens
        )
        return (plan.shouldCompact, plan.estimatedTokens)
    }

    /// Source ids the next automatic pass would summarize, given saved compacts
    /// `(id, sourceIds, coveredCompactIds)` created in array order.
    static func plannedSourceIds(
        messages: [UIMessage], compacts: [(id: String, sources: [String], covered: [String])]
    ) -> [String] {
        // Forced-pass helper: trigger 0 is intentionally not a pair settings can produce.
        IOSContextCompactionCoordinator.planCompaction(
            messages: messages, activeCompacts: testCompacts(compacts),
            policy: IOSCompactPolicy(enabled: true, notifyOnly: false, triggerRatio: 0,
                                     forceRatio: 0.9, keepRecentTurns: 1, maxSummaryTokens: 200),
            modelContextWindowTokens: 10_000, extraTokenEstimate: 0
        ).sourceMessageIds
    }

    static func validCompactIds(
        messages: [UIMessage], compacts: [(id: String, sources: [String], covered: [String])]
    ) -> [String] {
        IOSContextCompactionCoordinator.validCompletedCompacts(
            testCompacts(compacts),
            existingMessageIds: Set(messages.map { String(describing: $0.id) })
        ).map(\.id)
    }

    /// Nil means the summary is rejected and must not be saved.
    static func normalizedSummary(_ raw: String, offeredCompactIds: [String] = []) -> String? {
        IOSContextCompactionCoordinator.normalizedPayload(
            raw, sourceMessageIds: ["m1"], offeredCompactIds: offeredCompactIds, createdAt: 1
        )
    }

    private static func testCompacts(
        _ specs: [(id: String, sources: [String], covered: [String])]
    ) -> [IOSConversationCompact] {
        specs.enumerated().map { index, spec in
            let covered = spec.covered.map { "\"\($0)\"" }.joined(separator: ",")
            return IOSConversationCompact(
                id: spec.id, conversationId: "conv",
                summary: ##"{"schema_version":2,"handoff_markdown":"# Goal\nx","covered_compact_ids":["## + covered + "]}",
                level: 1, sourceStartIndex: 0, sourceEndIndex: 0, sourceMessageIds: spec.sources,
                tokenEstimate: 20, createdAt: Int64(index + 1), updatedAt: Int64(index + 1), status: "completed"
            )
        }
    }

    static func editedMessagesWithCount(
        messages: [UIMessage],
        keepRecentMessages: Int,
        retainedToolCallIds: Set<String> = []
    ) -> (messages: [UIMessage], removedToolResults: Int) {
        IOSContextCompactionCoordinator.editPreparedContext(
            messages: messages,
            keepRecentMessages: keepRecentMessages,
            retainedToolCallIds: retainedToolCallIds
        )
    }

    static func injectedHandoffText(
        id: String,
        summary: String,
        sourceMessageIds: [String],
        removedToolResults: Int
    ) -> String {
        IOSContextCompactionCoordinator.injectionText(
            id: id,
            summary: summary,
            sourceMessageIds: sourceMessageIds,
            removedToolResults: removedToolResults
        )
    }

    static func fittedMessagesWithBudget(messages: [UIMessage], maxTokens: Int) -> [UIMessage] {
        IOSContextCompactionCoordinator.fitMessagesToTokenBudget(messages, maxTokens: maxTokens)
    }

    static let compactedToolOutputMarker = IOSContextCompactionCoordinator.compactedToolOutputMarker

    static func nextTurnOccupancyTokens(
        messages: [UIMessage],
        compactSourceIds: [String],
        compactCreatedAt: Int64,
        compactSummary: String = "handoff",
        draftText: String = "",
        extraWeightedChars: Int = 0,
        systemOverheadText: String = ""
    ) -> Int {
        let compacts: [IOSConversationCompact]
        if compactSourceIds.isEmpty {
            compacts = []
        } else {
            compacts = [
                IOSConversationCompact(
                    id: "compact-test",
                    conversationId: "conv",
                    summary: compactSummary,
                    level: 1,
                    sourceStartIndex: 0,
                    sourceEndIndex: max(compactSourceIds.count - 1, 0),
                    sourceMessageIds: compactSourceIds,
                    tokenEstimate: 256,
                    createdAt: compactCreatedAt,
                    updatedAt: compactCreatedAt,
                    status: "completed"
                ),
            ]
        }
        return IOSContextCompactionCoordinator.nextTurnOccupancyTokens(
            messages: messages,
            activeCompacts: compacts,
            draftText: draftText,
            extraWeightedChars: extraWeightedChars,
            systemOverheadText: systemOverheadText
        )
    }

    static func estimatedTokens(_ messages: [UIMessage]) -> Int {
        IOSContextCompactionCoordinator.estimateTokens(messages)
    }
}
#endif

/// 每轮请求准备都要对整段对话估算多遍 token（注入前后、压缩规划、最终校验），
/// 逐个 Unicode 标量扫描桥接自 Kotlin 的字符串，在主线程上与发送动画抢帧。
/// KMP 消息 part 不可变，按对象身份缓存其加权字符数：同一 part 只扫描一次，
/// 弱引用键随 part 释放自动清理。会话载入时在后台预热，首轮发送也只剩查表。
final class ContextTokenEstimateMemo: @unchecked Sendable {
    static let shared = ContextTokenEstimateMemo()

    private let lock = NSLock()
    private let charsByPart = NSMapTable<UIMessagePart, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory
    )

    func estimatedChars(_ part: UIMessagePart) -> Int {
        if let cached = lock.withLock({ charsByPart.object(forKey: part) }) {
            return cached.intValue
        }
        let chars = computeEstimatedChars(part)
        lock.withLock { charsByPart.setObject(NSNumber(value: chars), forKey: part) }
        return chars
    }

    func warm(_ messages: [UIMessage]) {
        for message in messages {
            for part in message.parts { _ = estimatedChars(part) }
        }
    }

    private func computeEstimatedChars(_ part: UIMessagePart) -> Int {
        switch part {
        case let text as UIMessagePart.Text:
            return text.text.weightedTokenChars
        case let reasoning as UIMessagePart.Reasoning:
            return reasoning.reasoning.weightedTokenChars
        case let tool as UIMessagePart.Tool:
            return tool.input.weightedTokenChars + tool.output.reduce(0) { $0 + estimatedChars($1) }
        case let document as UIMessagePart.Document:
            return document.fileName.count + 80
        case let miniApp as UIMessagePart.MiniApp:
            return miniApp.title.weightedTokenChars + miniApp.description_.weightedTokenChars + 120
        case let image as UIMessagePart.Image:
            // A missing-blob 1x1 stand-in is not a screenshot; it is sent as short text.
            if IOSToolImageRequestBudget.isMissingBlobPlaceholder(image) {
                return IOSToolImageRequestBudget.missingBlobText.weightedTokenChars
            }
            // Chars are tokens x 4 throughout this estimator.
            return IOSImageTokenEstimate.estimatedTokens(url: image.url) * 4
        case is UIMessagePart.Video, is UIMessagePart.Audio:
            return 4_500
        default:
            return String(describing: part).count
        }
    }
}

extension String {
    var weightedTokenChars: Int {
        unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.isCJK ? 4 : 1)
        }
    }

    func takeMiddle(maxChars: Int) -> String {
        guard count > maxChars else { return self }
        let half = max((maxChars - 40), 16) / 2
        return "\(prefix(half))\n... [\(count - half * 2) chars omitted] ...\n\(suffix(half))"
    }
}

private extension UnicodeScalar {
    var isCJK: Bool {
        switch value {
        case 0x4E00...0x9FFF,
             0x3400...0x4DBF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0xF900...0xFAFF,
             0x2F800...0x2FA1F:
            true
        default:
            false
        }
    }
}
