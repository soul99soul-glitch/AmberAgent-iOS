import Foundation
@preconcurrency import Shared

/// KMP RecallResult 未声明 Sendable；并行任务只跨边界传 Void，结果留在主 actor。
@MainActor
private final class JevRecallResultBox {
    var value: ChatMemoryContextBuilder.RecallResult?
}

@MainActor
final class ChatRunUploadPreparation {
    let runId: String
    let conversationId: KotlinUuid?
    let settings: Settings
    let toolExposureBridge: IosToolExposureBridge
    let mcpEnabled: () -> Bool
    let bindings: ChatGenerationBindings
    let isCurrentRun: () -> Bool
    let onPreparedUpload: (ProviderSetting, TextGenerationParams, [UIMessage]) throws -> Void
    var requirement: IOSGenerativeUiRequirement = .none
    var fallbackAttempted = false
    var retryIssue: String?

    init(
        runId: String,
        conversationId: KotlinUuid?,
        settings: Settings,
        toolExposureBridge: IosToolExposureBridge,
        mcpEnabled: @escaping () -> Bool,
        bindings: ChatGenerationBindings,
        isCurrentRun: @escaping () -> Bool,
        onPreparedUpload: @escaping (ProviderSetting, TextGenerationParams, [UIMessage]) throws -> Void
    ) {
        self.runId = runId
        self.conversationId = conversationId
        self.settings = settings
        self.toolExposureBridge = toolExposureBridge
        self.mcpEnabled = mcpEnabled
        self.bindings = bindings
        self.isCurrentRun = isCurrentRun
        self.onPreparedUpload = onPreparedUpload
    }

    private func messagesByInjectingRuntimeContext(
        _ messages: [UIMessage],
        memoryRecallOverride: ChatMemoryContextBuilder.RecallResult? = nil
    ) -> [UIMessage] {
        bindings.messagesByInjectingRuntimeContextForRun?(messages, mcpEnabled(), memoryRecallOverride)
            ?? bindings.messagesByInjectingRuntimeContext(messages)
    }

    /// 每轮上传前的完整准备。压缩失败抛错,沿引擎
    /// 通用 catch 以 providerFailure 收口(CG-C 压缩失败 → presentStreamError
    /// 语义),错误串带「上下文压缩失败：」前缀。
    func prepareUploadMessages(
        _ messages: [UIMessage],
        provider: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> [UIMessage] {
        var prepareInterval = ChatPerfTrace.begin("PrepareUpload")
        defer { ChatPerfTrace.end(&prepareInterval) }
        guard isCurrentRun() else { return messages }
        let effectiveParams = params.replacingTools(
            toolExposureBridge.visibleTools()
        )
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: settings.agentRuntime.generativeUi,
            messages: messages,
            params: effectiveParams,
            suppressForMiniApp: settings.agentRuntime.miniApp.enabled
                && ChatRuntimeContextBuilder.miniAppTurnContext(in: messages) != nil
        )
        if !fallbackAttempted {
            requirement = plan.requirement
        }
        let requestMessages: [UIMessage]
        if let issue = retryIssue {
            requestMessages = IOSGenerativeUiRequestPolicy.retryMessages(
                plan.uploadMessages,
                requirement: requirement,
                issue: issue
            )
        } else {
            requestMessages = plan.uploadMessages
        }
        // 记忆候选只依赖本轮 canonical 用户输入；尽早启动，使网络等待与
        // 压缩、上下文投影、图片准备重叠。本轮选择仍只在注入前读取一次。
        let recallBox = JevRecallResultBox()
        let memoryRecallTask = Task { @MainActor in
            recallBox.value = await bindings.prepareJevMemoryRecall(requestMessages, runId)
        }
        defer { memoryRecallTask.cancel() }

        // 基线注入只用于压缩预算估算，先算一次召回结果给它；最终注入在下方
        // 按原时机（压缩与投影的 await 之后）现算，保证读到注入前最新的记忆。
        let fallbackMemoryRecallResult = bindings.memoryRecallResultForRun(requestMessages)

        // 注入开销估算基于 canonical 输入（无投影），保证压缩预算口径与
        // 原行为一致（等价于 Phase 1 之前 Host 的估算方式）。
        let runtimeBaseline = messagesByInjectingRuntimeContext(
            requestMessages,
            memoryRecallOverride: fallbackMemoryRecallResult
        )
        let transcriptCapabilities = PromptTranscriptCapabilities.companion.resolve(
            setting: provider,
            model: effectiveParams.model
        )
        let runtimeOverheadTokens = max(
            IOSContextCompactionCoordinator.estimatedTokensForRequest(runtimeBaseline) -
                IOSContextCompactionCoordinator.estimatedTokensForRequest(requestMessages),
            0
        )
        let requestSystemIds = Set(requestMessages.filter { $0.role == MessageRole.system }.map { $0.id })
        let runtimeFragments = runtimeBaseline.filter {
            $0.role == MessageRole.system && !requestSystemIds.contains($0.id)
        }
        let historyOverhead: (([UIMessage]) -> Int)? = transcriptCapabilities.systemUpdates ? { retained in
            let fresh = runtimeFragments + retained
            let replayed = PromptTranscript.shared.prepare(
                canonicalMessages: messages, preparedMessages: fresh, tools: effectiveParams.tools
            ).messages
            return max(IOSContextCompactionCoordinator.estimatedTokensForRequest(replayed)
                - IOSContextCompactionCoordinator.estimatedTokensForRequest(fresh), 0)
        } : nil

        let preparedUploadMessages: [UIMessage]
        do {
            preparedUploadMessages = try await IOSContextCompactionCoordinator.shared.prepareMessagesForRequest(
                uploadMessages: requestMessages,
                conversationId: conversationId,
                settings: settings,
                params: effectiveParams,
                fallbackProvider: provider,
                promptOverheadTokens: runtimeOverheadTokens,
                additionalHistoryOverhead: historyOverhead,
                onEvent: { [weak self] event in
                    guard let self,
                          ChatContextCompactEventRouter.shouldApply(
                            event: event,
                            eventRunId: runId,
                            currentRunId: self.isCurrentRun() ? self.runId : nil
                          ) else { return }
                    self.applyCompactEvent(event)
                }
            )
        } catch {
            if isCurrentRun() {
                applyCompactEvent(.failed(message: (error as NSError).localizedDescription))
            }
            throw Self.uploadPrepError(IOSAppLocalization.formatted(
                "上下文压缩失败：%@",
                defaultValue: "上下文压缩失败：%@",
                arguments: [(error as NSError).localizedDescription]
            ))
        }
        guard isCurrentRun() else { return messages }
        let promptedUploadMessages = Self.messagesByInjectingImageGenerationPromptIfNeeded(
            preparedUploadMessages,
            params: effectiveParams
        )

        // Jev Phase 2（上下文筛选）：投影放在压缩之后——压缩摘要的来源始终是
        // canonical 原文（P0），且压缩的预算截断不会伤及省略 marker；同时投影
        // 只作用于请求副本，canonical 历史/持久化不受影响。off/shadow/失败
        // 返回原数组。
        let projectedMessages = await IOSJevContextSelectionService.shared.projectedMessages(
            promptedUploadMessages,
            identity: IOSJevContextSelectionService.RunIdentity(
                runId: runId,
                conversationId: conversationId?.toHexDashString()
            )
        )

        // 每轮组装前刷新编排链接缓存(CG-C :2022-2024)。
        await bindings.refreshOrchestrationLinks()

        // Jev Phase 1（记忆召回）：在注入前计算本轮统一选中集合，显式持有并
        // 传给后续两次注入与 usage marking——中途的 await（图片识别等）不会
        // 导致注入与标记各拿一份结果。off/shadow 返回 nil，走同步原行为。
        await memoryRecallTask.value
        // Jev 未给出结果时在注入时刻现算（与原行为同一时机与输入），并复用给
        // usage marking，使标记的记忆与实际注入的一致。
        let memoryRecallOverride = recallBox.value ?? bindings.memoryRecallResultForRun(projectedMessages)
        let runtimePreparedMessages = try await bindings.prepareImageAttachments(
            messagesByInjectingRuntimeContext(projectedMessages, memoryRecallOverride: memoryRecallOverride),
            effectiveParams.model,
            settings,
            conversationId
        )
        try Task.checkCancellation()
        guard isCurrentRun() else { throw CancellationError() }
        let selectedMemoryIds = bindings.memoryRecordIdsForRuntimeContext(
            promptedUploadMessages,
            memoryRecallOverride
        )
        let finalizedUploadMessages: [UIMessage]
        do {
            let transcriptMessages = transcriptCapabilities.systemUpdates
                ? PromptTranscript.shared.prepare(
                    canonicalMessages: messages,
                    preparedMessages: runtimePreparedMessages,
                    tools: effectiveParams.tools
                ).messages
                : runtimePreparedMessages
            let transitionOverhead = max(
                IOSContextCompactionCoordinator.estimatedTokensForRequest(transcriptMessages)
                    - IOSContextCompactionCoordinator.estimatedTokensForRequest(runtimePreparedMessages), 0
            )
            finalizedUploadMessages = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
                runtimePreparedMessages,
                settings: settings,
                params: effectiveParams,
                additionalOverheadTokens: transitionOverhead
            )
            if transcriptCapabilities.systemUpdates {
                // Rebuild after fitting so covered transitions become a checkpoint.
                // Validate without allowing the fitter to move inline system events.
                _ = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
                    PromptTranscript.shared.prepare(
                        canonicalMessages: messages,
                        preparedMessages: finalizedUploadMessages,
                        tools: effectiveParams.tools
                    ).messages,
                    settings: settings,
                    params: effectiveParams,
                    preserveMessageOrder: true
                )
            }
        } catch {
            if isCurrentRun() {
                applyCompactEvent(.failed(message: (error as NSError).localizedDescription))
            }
            throw Self.uploadPrepError(IOSAppLocalization.formatted(
                "上下文压缩失败：%@",
                defaultValue: "上下文压缩失败：%@",
                arguments: [(error as NSError).localizedDescription]
            ))
        }
        // Native transcript endpoints need named system sections intact so the
        // engine can emit only the changed section. Legacy/custom endpoints
        // keep the historical single-system-message shape.
        let finalUploadMessages = transcriptCapabilities.systemUpdates
            ? finalizedUploadMessages
            : ChatRuntimeContextBuilder.coalescingSystemMessages(finalizedUploadMessages)
        // 召回标记(P2-b):不 force,去抖生效(CG-C :2049-2050)。
        bindings.recordMemoryUsage(selectedMemoryIds, false)
        try onPreparedUpload(provider, effectiveParams, finalUploadMessages)
        return finalUploadMessages
    }

    private static func uploadPrepError(_ message: String) -> NSError {
        NSError(
            domain: "AmberAgent.ChatKernelRunHost",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// CG-C :2098-2118 同款:generate_image 在目录时前置路由指引系统消息。
    private static func messagesByInjectingImageGenerationPromptIfNeeded(
        _ messages: [UIMessage],
        params: TextGenerationParams
    ) -> [UIMessage] {
        guard params.tools.contains(where: { $0.name == "generate_image" }) else {
            return messages
        }
        let prompt = ChatImageGenerationReference.routingGuidancePrompt
        let systemMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.system,
            parts: [UIMessagePart.Text(text: prompt, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        return [systemMessage] + messages
    }

    /// CG-C applyCompactEvent :2067-2096 同款映射。
    private func applyCompactEvent(_ event: IOSContextCompactionEvent) {
        switch event {
        case .planning:
            bindings.setContextCompactState(ChatContextCompactState(status: .planning, summary: "", updatedAt: Date()))
        case .compacting:
            bindings.setContextCompactState(ChatContextCompactState(status: .compacting, summary: "", updatedAt: Date()))
        case .completed(let summary):
            bindings.setContextCompactState(ChatContextCompactState(status: .completed, summary: summary, updatedAt: Date()))
        case .failed(let message):
            bindings.setContextCompactState(ChatContextCompactState(status: .failed, summary: message, updatedAt: Date()))
        case .idle:
            bindings.setContextCompactState(.idle)
        }
    }

}
