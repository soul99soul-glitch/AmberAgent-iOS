import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

private let chatLedgerLogger = Logger(subsystem: "app.amber.ios", category: "chat-ledger")

extension ChatViewModel {

    /// Each conversation retains its existing Host until its run has finished.
    func makeKernelRunHost(state: ChatConversationRunState) -> ChatKernelRunHost {
        var textProviderOverride: (any IOSAgentTextProvider)?
#if DEBUG
        textProviderOverride = kernelTextProviderOverrideForTesting
#endif
        return ChatKernelRunHost(
            dependencies: makeGenerationDependencies(),
            bindings: makeGenerationBindings(state: state),
            toolLedger: chatRunLedger,
            textProvider: textProviderOverride,
            phoneControl: phoneControl
        )
    }

    private func makeGenerationDependencies() -> ChatGenerationDependencies {
        ChatGenerationDependencies(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor,
            searchTransport: searchTransport,
            liveActivityController: liveActivityController,
            autoGenerateResponses: autoGenerateResponses,
            mcpManager: mcpManager,
            orchestrationToolService: orchestrationToolService,
            memoryPollutionMarker: memoryPollutionMarker,
            conversationStoreProvider: { [weak self] in self?.conversationStore }
        )
    }

    func makeGenerationBindings(state: ChatConversationRunState) -> ChatGenerationBindings {
        ChatGenerationBindings(
                getMessages: {
                    state.messages
                },
                setMessages: { messages in
                    state.messages = messages
                },
                bumpMessageRevision: { [weak self] reason, lagAllowance in
                    guard let self else { return }
                    if reason != .streamDelta && reason != .toolDelta { self.runActivityRevision &+= 1 }
                    if self.isCurrentConversation(state.conversationId) {
                        self.bumpMessageRevision(reason: reason, lagAllowance: lagAllowance)
                    }
                },
                setIsLoading: { isLoading in
                    if isLoading { state.clearChildResultWait() }
                    state.isLoading = isLoading
                },
                setPendingMemoryApproval: { [weak self] request in
                    state.pendingMemoryApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: "memory_tool",
                        actionSummary: "action=\(request?.action ?? "unknown"), kind=\(request?.kind ?? "unknown")"
                    )
                },
                setPendingSearchApproval: { [weak self] request in
                    state.pendingSearchApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: request?.toolName ?? "search",
                        actionSummary: "provider=\(request?.providerName ?? "unknown")",
                        parameterSummary: IOSJevApprovalTriageService.parameterSummary(fields: [
                            "target": request?.target ?? "",
                            "provider_type": request?.providerType ?? "",
                        ])
                    )
                },
                setPendingWebMountApproval: { [weak self] request in
                    state.pendingWebMountApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: request?.toolName ?? "webmount",
                        actionSummary: request.map { "action=\($0.action)" } ?? ""
                    )
                },
                setPendingWorkspaceApproval: { [weak self] request in
                    state.pendingWorkspaceApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: request?.toolName ?? "workspace",
                        actionSummary: "action=\(request?.action ?? "unknown")",
                        parameterSummary: IOSJevApprovalTriageService.parameterSummary(fields: ["target": request?.target ?? ""]),
                        staticFacts: request.map { .workspace(isWrite: $0.isWrite) }
                    )
                },
                setPendingIshHandoffApproval: { [weak self] request in
                    state.pendingIshHandoffApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: "ish_handoff",
                        actionSummary: "mode=\(request?.mode.rawValue ?? "unknown")",
                        parameterSummary: IOSJevApprovalTriageService.parameterSummary(fields: ["filename": request?.filename ?? ""])
                    )
                },
                setPendingMcpApproval: { [weak self] request in
                    state.pendingMcpApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: request.map { $0.serverName == "local" ? $0.toolName : "\($0.serverName)/\($0.toolName)" } ?? "mcp",
                        actionSummary: "",
                        parameterSummary: request.flatMap { IOSJevApprovalTriageService.parameterSummary(fromJSON: $0.argumentsPreview) },
                        invocationArgumentsJSON: request?.argumentsPreview,
                        requiresParameterSummary: true
                    )
                },
                setPendingCouncilApproval: { [weak self] request in
                    state.pendingCouncilApproval = request
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: "model_council_run",
                        actionSummary: "",
                        parameterSummary: IOSJevApprovalTriageService.parameterSummary(fields: ["objective": request?.objectivePreview ?? ""])
                    )
                },
                setPendingAskUser: { request in
                    state.pendingAskUser = request
                },
                setPendingRecipeApproval: { [weak self] request in
                    state.pendingRecipeApproval = request
                    let parameterPreview: String?
                    switch request?.payload {
                    case .step(let payload): parameterPreview = payload.argumentsPreview
                    case .pluginInvocation(let payload): parameterPreview = payload.argumentsPreview
                    case .recipeImport, .none: parameterPreview = nil
                    }
                    self?.triagePendingApproval(
                        state,
                        requestId: request?.id,
                        toolName: "recipe",
                        actionSummary: request.map { "recipe=\($0.recipeName), version=\($0.recipeVersion)" } ?? "",
                        parameterSummary: IOSJevApprovalTriageService.parameterSummary(fromJSON: parameterPreview),
                        requiresParameterSummary: true
                    )
                },
                setContextCompactState: { [weak self, runState = state] state in
                    withAnimation(.easeOut(duration: 0.22)) {
                        runState.contextCompactState = state
                        if state.status == .completed, self?.isCurrentConversation(runState.conversationId) == true {
                            self?.refreshContextCompactBoundaries()
                        }
                    }
                },
                persistMessages: { [weak self] conversationId in
                    guard let self else { return false }
                    return await self.persistMessagesSnapshot(
                        state.messages,
                        targetConversationId: conversationId,
                        pendingRegeneration: state.pendingAssistantRegeneration,
                        store: self.conversationStore,
                        writeBaseline: conversationId.flatMap { self.conversationStore?.writeBaseline(for: $0) },
                        state: state
                    )
                },
                capturePersistMessagesBaseline: { [weak self] conversationId in
                    guard let store = self?.conversationStore,
                          let targetConversationId = conversationId ?? state.conversationId else {
                        return nil
                    }
                    return store.writeBaseline(for: targetConversationId)
                },
                persistMessagesSnapshot: { [weak self] snapshot, conversationId, writeBaseline in
                    guard let self else { return false }
                    return await self.persistMessagesSnapshot(
                        snapshot,
                        targetConversationId: conversationId,
                        pendingRegeneration: state.pendingAssistantRegeneration,
                        store: self.conversationStore,
                        writeBaseline: writeBaseline,
                        state: state
                    )
                },
                recordRun: { [weak self] runId, startedAt, status, inputDigest, conversationId, protocolContext in
                    guard let self else { return false }
                    return await self.recordRun(
                        runId: runId,
                        startedAt: startedAt,
                        status: status,
                        inputDigest: inputDigest,
                        conversationId: conversationId,
                        protocolContext: protocolContext
                    )
                },
                markRunAwaitingPermission: { [weak self] runId, toolCallId in
                    guard let self else { return false }
                    return await self.markRunAwaitingPermission(
                        runId: runId,
                        toolCallId: toolCallId
                    )
                },
                resumeRunAfterPermission: { [weak self] runId in
                    guard let self else { return false }
                    return await self.resumeRunAfterPermission(runId: runId)
                },
                startLiveActivity: { [weak self] runId, conversationId, presentation in
                    self?.startLiveActivity(
                        runId: runId,
                        conversationId: conversationId,
                        presentation: presentation
                    )
                },
                saveMiniAppIfPresent: { [weak self] messages, conversationId in
                    self?.applyMiniAppOutputIfPresentPublic(to: messages, conversationId: conversationId)
                },
                messagesByInjectingRuntimeContext: { [weak self] messages in
                    self?.messagesByInjectingRuntimeContext(messages, state: state) ?? messages
                },
                messagesByInjectingRuntimeContextForRun: { [weak self] messages, mcpEnabled, memoryRecallOverride in
                    self?.messagesByInjectingRuntimeContext(
                        messages,
                        mcpEnabledOverride: mcpEnabled,
                        state: state,
                        memoryRecallOverride: memoryRecallOverride
                    ) ?? messages
                },
                prepareImageAttachments: { [weak self] messages, model, settings, conversationId in
                    guard let self else { throw CancellationError() }
                    return try await self.prepareImageAttachments(
                        messages,
                        model: model,
                        settings: settings,
                        conversationId: conversationId
                    )
                },
                userFacingGenerationError: { rawMessage, modelId in
                    ChatViewModel.userFacingGenerationError(rawMessage, modelId: modelId)
                },
                memoryRecordIdsForRuntimeContext: { [weak self] messages, override in
                    self?.memoryRecordIdsForRuntimeContext(messages, override: override) ?? []
                },
                prepareJevMemoryRecall: { [weak self] messages, runId in
                    guard let self else { return nil }
                    return await self.prepareJevMemoryRecallSelection(messages, runId: runId)
                },
                memoryRecallResultForRun: { [weak self] messages in
                    self?.memoryRecallResultForRun(messages) ?? ChatMemoryContextBuilder.RecallResult(prompt: nil, records: [])
                },
                recordMemoryUsage: { [weak self] ids, force in
                    self?.recordMemoryUsage(ids, force: force, state: state)
                },
                generationSucceeded: { [weak self] in
                    self?.onGenerationCompleted(state: state)
                },
                scheduleMemoryExtraction: { conversationId, baseline, completed in
                    IOSMemoryExtractionCoordinator.shared.enqueue(
                        conversationId: conversationId, baseline: baseline, completed: completed
                    )
                },
                drainSteerQueue: { [weak self] conversationId in
                    self?.drainSteerQueue(state: state) ?? []
                },
                drainMailbox: { [weak self] conversationId in
                    await self?.drainMailbox(state: state) ?? []
                },
                handleSteerQueueAtTerminal: { [weak self] conversationId, autoContinue in
                    self?.handleSteerQueueAtRunTerminal(state: state, autoContinue: autoContinue)
                },
                restoreSteerQueueLeftover: { [weak self] conversationId in
                    self?.restoreSteerQueueLeftoverToComposer(state: state)
                },
                onForegroundYield: { runId in
                    state.waitingForChildRunId = runId
                },
                onRunTerminal: { [weak self] conversationId, runId, terminalStatus, finalMessages, displayBaseline in
                    guard let self else { return }
                    self.observeYieldedChildResults(state: state, runId: runId)
                    if let conversationId {
                        self.refreshIntelligentUIReceipts(messages: finalMessages, conversationID: conversationId.toHexDashString())
                    }
                    // 只是在等子代理的前台让出不是最终答复。
                    if terminalStatus.wireName == AgentRunStatus.completed.wireName,
                       state.waitingForChildRunId != runId {
                        Self.checkCompletionClaim(state: state, runId: runId, messages: finalMessages)
                    }
                    let terminal = try? await self.runStore.snapshot(runId: runId)
                    await self.orchestrationToolService.notifyRunTerminal(
                        conversationId: conversationId,
                        runId: runId,
                        finalMessages: finalMessages,
                        displayBaseline: displayBaseline,
                        terminalStatus: terminalStatus,
                        terminalReason: terminal?.terminalReason
                    )
                },
                setToolOutcomeUnknown: { [weak self] descriptor in
                    guard let self,
                          !self.toolOutcomeUnknownDescriptors.contains(descriptor) else { return }
                    self.toolOutcomeUnknownDescriptors.append(descriptor)
                },
                refreshOrchestrationLinks: { [weak self] in
                    await self?.refreshOrchestratedStatus(state: state)
                }
        )
    }

#if DEBUG
    func finishedToolCallMessagesForTesting(
        _ targetToolCall: UIMessagePart.Tool,
        outputText: String,
        in messages: [UIMessage]
    ) -> [UIMessage] {
        kernelRunHost.toolRuntimeForTesting.finishedToolCallMessagesForTesting(
            targetToolCall,
            outputText: outputText,
            in: messages
        )
    }

    func failingPendingToolCallMessagesForTesting(
        outputText: String,
        in messages: [UIMessage]
    ) -> [UIMessage] {
        kernelRunHost.toolRuntimeForTesting.messagesByFailingPendingToolCalls(
            in: messages,
            outputText: outputText
        )
    }

    func memoryToolOutputForTesting(input: String) -> String {
        kernelRunHost.toolRuntimeForTesting.memoryToolOutputForTesting(input: input)
    }

    func memoryApprovalRequestForTesting(input: String) -> MemoryToolApprovalRequest? {
        kernelRunHost.toolRuntimeForTesting.memoryApprovalRequestForTesting(input: input)
    }

    func memoryToolApprovalOutputForTesting(input: String, allow: Bool) -> String {
        kernelRunHost.toolRuntimeForTesting.memoryToolApprovalOutputForTesting(input: input, allow: allow)
    }

    func webMountToolOutputForTesting(
        toolName: String,
        input: String,
        isUserInitiated: Bool = false
    ) async -> String {
        await kernelRunHost.toolRuntimeForTesting.webMountToolOutputForTesting(
            toolName: toolName,
            input: input,
            isUserInitiated: isUserInitiated
        )
    }

    func webMountApprovalRequestForTesting(
        toolName: String,
        input: String
    ) async -> WebMountToolApprovalRequest? {
        await kernelRunHost.toolRuntimeForTesting.webMountApprovalRequestForTesting(toolName: toolName, input: input)
    }

    func webMountToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        await kernelRunHost.toolRuntimeForTesting.webMountToolApprovalOutputForTesting(
            toolName: toolName,
            input: input,
            allow: allow
        )
    }

    func searchApprovalRequestForTesting(
        toolName: String,
        input: String
    ) -> SearchToolApprovalRequest? {
        kernelRunHost.toolRuntimeForTesting.searchApprovalRequestForTesting(toolName: toolName, input: input)
    }

    func searchToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        await kernelRunHost.toolRuntimeForTesting.searchToolApprovalOutputForTesting(
            toolName: toolName,
            input: input,
            allow: allow
        )
    }
#endif

    func startLiveActivity(
        runId: String,
        conversationId: KotlinUuid?,
        presentation: AgentActivityPresentation,
        publishToWatch: Bool = true
    ) {
        let conversationHex = conversationId?.toHexDashString()
        if publishToWatch {
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: conversationHex,
                presentation: presentation
            )
        }
        guard liveActivityPreferenceEnabled else { return }
        // 只在 conversationId 匹配当前会话时传标题，避免审批恢复/后台 handoff
        // 时用户已切会话导致灵动岛显示错误标题。
        let isCurrentConversation = conversationId == currentConversationId
        liveActivityController.start(
            runId: runId,
            conversationId: conversationHex,
            conversationTitle: isCurrentConversation
                ? conversationStore?.currentConversation?.title
                : nil,
            presentation: presentation
        )
    }

    static func promptText(
        userText: String,
        selectedFilePreview: SelectedDocumentReadResult?
    ) -> String {
        guard let selectedFilePreview else { return userText }
        let status = selectedFilePreview.statusSummary
        return """
        \(userText)

        [文件上下文]
        来源文件：\(selectedFilePreview.fileName)
        类型：\(selectedFilePreview.fileType)
        大小：\(selectedFilePreview.totalBytes) bytes
        已读取：\(selectedFilePreview.bytesRead) bytes
        文本字符：\(selectedFilePreview.characterCount)
        状态：\(status)
        内容：
        \(selectedFilePreview.preview)
        [/文件上下文]
        """
    }

    func recordRun(
        runId: String,
        startedAt: Int64,
        status: AgentRunStatus,
        inputDigest: String,
        conversationId: String?,
        protocolContext: AgentRunProtocolContext?
    ) async -> Bool {
        do {
            if status == .running {
                if let protocolContext {
                    return try await runStore.startChatRun(
                        runId: runId,
                        startedAt: startedAt,
                        inputDigest: inputDigest,
                        conversationId: conversationId,
                        protocolContext: protocolContext
                    )
                }
                return try await runStore.startChatRun(
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId
                )
            } else {
                let didRecord = try await runStore.transitionFromAnyActiveOrMatchingState(
                    runId: runId,
                    to: status,
                    detail: status == .interrupted ? "background_interruption" : nil
                )
                if !didRecord {
                    conversationStore?.publishUserVisibleError(
                        IOSUserVisibleError(
                            title: IOSAppLocalization.string(
                                "运行状态记录失败",
                                defaultValue: "运行状态记录失败"
                            ),
                            message: IOSAppLocalization.string(
                                "运行终态发生冲突，任务已保留等待恢复。",
                                defaultValue: "运行终态发生冲突，任务已保留等待恢复。"
                            ),
                            severity: .error
                        )
                    )
                }
                return didRecord
            }
        } catch {
            // agent_run 是强杀恢复（applyToolCallLedgerRecovery）依赖的账本，
            // 写失败必须走用户可见错误通道，不能只 print 静默吞掉。
            let detail = IOSAppLocalization.formatted(
                "未能写入运行账本：%@",
                defaultValue: "未能写入运行账本：%@",
                arguments: [String(describing: error)]
            )
            if let conversationStore {
                conversationStore.publishUserVisibleError(
                    IOSUserVisibleError(
                        title: IOSAppLocalization.string(
                            "运行状态记录失败",
                            defaultValue: "运行状态记录失败"
                        ),
                        message: detail,
                        severity: .error
                    )
                )
            } else {
                chatLedgerLogger.error("\(detail)")
            }
            return false
        }
    }

    private func markRunAwaitingPermission(runId: String, toolCallId: String) async -> Bool {
        (try? await runStore.transition(
            runId: runId,
            expected: .running,
            to: .awaitingPermission,
            inputSnapshotRef: "tool_call:\(toolCallId)"
        )) == true
    }

    private func resumeRunAfterPermission(runId: String) async -> Bool {
        (try? await runStore.transition(
            runId: runId,
            expected: .awaitingPermission,
            to: .running,
            inputSnapshotRef: nil,
            detail: nil
        )) == true
    }

}
