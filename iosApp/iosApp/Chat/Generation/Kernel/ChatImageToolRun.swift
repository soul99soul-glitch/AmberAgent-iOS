import Foundation
@preconcurrency import Shared

/// Owns the direct image tool's execution task and one-shot tool ledger terminal.
/// The Host remains the sole run identity and run-terminal claimant.
@MainActor
final class ChatImageToolRun {
    enum TerminalClaimResult: Equatable {
        case recorded, alreadyClaimed, failed
    }

    struct Run {
        let runId: String
        let startedAt: Int64
        let inputDigest: String
        let conversationId: KotlinUuid?
        let snapshot: [UIMessage]
    }

    let toolCall: UIMessagePart.Tool
    private let bindings: ChatGenerationBindings
    private let toolRuntime: ChatToolRuntime
    private let toolLedger: IOSAgentRunLedgering
    private let dependencies: ChatGenerationDependencies
    private(set) var didStart = false
    private(set) var terminalClaimed = false
    private var activeExecutionTask: Task<[UIMessage], Never>?
    private var activeExecutionToken: UUID?
#if DEBUG
    var executionOverrideForTesting: (@MainActor (UIMessagePart.Tool, [UIMessage]) async -> [UIMessage])?
#endif

    var isExecuting: Bool { activeExecutionTask != nil }
    func cancelExecution() { activeExecutionTask?.cancel() }

    init(
        toolCall: UIMessagePart.Tool,
        bindings: ChatGenerationBindings,
        toolRuntime: ChatToolRuntime,
        toolLedger: IOSAgentRunLedgering,
        dependencies: ChatGenerationDependencies
    ) {
        self.toolCall = toolCall
        self.bindings = bindings
        self.toolRuntime = toolRuntime
        self.toolLedger = toolLedger
        self.dependencies = dependencies
    }

    static func beginActivity(
        runId: String,
        conversationId: KotlinUuid?,
        modelDisplayName: String,
        bindings: ChatGenerationBindings,
        backgroundExecution: BackgroundGenerationKeepAlive,
        onExpire: @escaping () -> Void
    ) {
        let imagePresentation = AgentActivityPresentation.runningTool(toolName: "generate_image")
        bindings.startLiveActivity(runId, conversationId, imagePresentation)
        backgroundExecution.begin(
            runId,
            title: IOSAppLocalization.string(
                "Amber 正在生成图片",
                defaultValue: "Amber 正在生成图片"
            ),
            subtitle: modelDisplayName,
            onExpire: onExpire,
            onSystemTaskExpiration: onExpire
        )
        backgroundExecution.updateProgress(
            runId,
            completed: 0,
            total: 3,
            subtitle: IOSAppLocalization.string("准备图片请求", defaultValue: "准备图片请求")
        )

    }

    func execute(run: Run, host: ChatKernelRunHost) async {
        let runId = run.runId
        let startedAt = run.startedAt
        let inputDigest = run.inputDigest
        let conversationId = run.conversationId
        let snapshot = run.snapshot
        let toolCall = self.toolCall
            guard host.isImageRunCurrent(runId) else { return }
            if host.isImageRunCancelled(runId) {
                await host.finalizeTerminal(runId: runId)
                return
            }
            let didRecordRun = await bindings.recordRun(
                runId,
                startedAt,
                .running,
                inputDigest,
                conversationId?.toHexDashString(),
                nil
            )
            guard didRecordRun else {
                if host.isImageRunCancelled(runId) {
                    await host.finalizeTerminal(runId: runId)
                    return
                }
                await failBeforeExecution(
                    host: host,
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存任务状态，图片生成未开始。",
                        defaultValue: "无法保存任务状态，图片生成未开始。"
                    )
                )
                return
            }
            guard host.isImageRunActive(runId) else {
                await host.finalizeTerminal(runId: runId)
                return
            }

            let argsDigest = chatInputDigest(for: toolCall.input)
            let preparation = await toolLedger.recordToolCallPrepared(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: .sideEffect
            )
            guard host.isImageRunActive(runId) else {
                _ = await toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "cancelled_before_execution"
                )
                await host.finalizeTerminal(runId: runId)
                return
            }
            guard preparation == .ready else {
                _ = await toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "not_executed_prepare_failed"
                )
                await failBeforeExecution(
                    host: host,
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let baseline = bindings.capturePersistMessagesBaseline(conversationId)
            let didPersistBeforeExecution = await bindings.persistMessagesSnapshot(
                snapshot,
                conversationId,
                baseline
            )
            guard host.isImageRunActive(runId) else {
                _ = await toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "cancelled_before_execution"
                )
                await host.finalizeTerminal(runId: runId)
                return
            }
            guard didPersistBeforeExecution else {
                _ = await toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "not_executed_persist_failed"
                )
                await failBeforeExecution(
                    host: host,
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let didRecordStarted = await toolLedger.recordToolCallStarted(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: .sideEffect
            )
            didStart = didRecordStarted
            guard host.isImageRunActive(runId) else {
                if didRecordStarted {
                    let terminalClaim = await recordTerminalIfNeeded(
                        host: host,
                        runId: runId,
                        toolCall: toolCall,
                        outcome: "cancelled_before_execution",
                        resultPayload: nil
                    )
                    if terminalClaim == .failed {
                        await host.failImageToolDurability(runId: runId)
                        return
                    }
                    guard terminalClaim == .recorded else { return }
                } else {
                    await reconcileStartFailure(
                        runId: runId,
                        toolCallId: toolCall.toolCallId,
                        outcome: "cancelled_before_execution"
                    )
                }
                await host.finalizeTerminal(runId: runId)
                return
            }
            guard didRecordStarted else {
                await reconcileStartFailure(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    outcome: "not_executed_start_failed"
                )
                await failBeforeExecution(
                    host: host,
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let executionToken = UUID()
#if DEBUG
            let imageToolExecutionOverrideForTesting = executionOverrideForTesting
            let executionTask = Task { @MainActor [toolRuntime = toolRuntime] in
                if let imageToolExecutionOverrideForTesting {
                    return await imageToolExecutionOverrideForTesting(toolCall, snapshot)
                }
                return await toolRuntime.messagesByExecutingImageToolCall(toolCall, in: snapshot)
            }
#else
            let executionTask = Task { @MainActor [toolRuntime = toolRuntime] in
                await toolRuntime.messagesByExecutingImageToolCall(toolCall, in: snapshot)
            }
#endif
            activeExecutionToken = executionToken
            activeExecutionTask = executionTask
            let resumed = await executionTask.value
            if activeExecutionToken == executionToken {
                activeExecutionToken = nil
                activeExecutionTask = nil
            }
            let failureReason = ChatToolOutputFormatter.imageFailureReason(in: resumed, matching: toolCall)
            let resultParts = resumed
                .flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output
            guard host.isImageRunCurrent(runId) else { return }
            if host.isImageRunCancelled(runId) {
                let terminalClaim = await markOutcomeUnknownIfNeeded(
                host: host,                     runId: runId,
                    toolCall: toolCall,
                    outcome: "cancelled_during_execution"
                )
                if terminalClaim == .failed {
                    await host.failImageToolDurability(runId: runId)
                    return
                }
                guard terminalClaim == .recorded else { return }
                await host.finalizeTerminal(runId: runId)
                return
            }
            let terminalClaim = await recordTerminalIfNeeded(
                host: host,                 runId: runId,
                toolCall: toolCall,
                outcome: failureReason == nil ? "completed" : "failed",
                resultPayload: resultParts.map { IosToolOutputJsonBridge.shared.encode(parts: $0) }
            )
            if terminalClaim == .failed {
                await host.failImageToolDurability(runId: runId)
                return
            }
            guard terminalClaim == .recorded else { return }
            guard host.isImageRunCurrent(runId) else { return }
            if host.isImageRunCancelled(runId) {
                await host.finalizeTerminal(runId: runId)
                return
            }
            guard host.claimImageTerminal(runId) else { return }

            bindings.setMessages(resumed)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
            let conversationHex = conversationId?.toHexDashString()
            let didPersist = await bindings.persistMessages(conversationId)
            if didPersist {
                await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
            }
            let succeeded = failureReason == nil && didPersist
            let terminalStatus: AgentRunStatus = didPersist
                ? (failureReason == nil ? .completed : .failed)
                : .recoveryPending
            let didRecordTerminalRun = await bindings.recordRun(
                runId,
                startedAt,
                terminalStatus,
                inputDigest,
                conversationHex,
                nil
            )
            guard didRecordTerminalRun else {
                host.releaseLocalRunAfterTerminalRecordFailure(runId: runId)
                return
            }
            if succeeded {
                WatchTaskCoordinator.shared.publishCompleted(
                    runId: runId,
                    conversationId: conversationHex,
                    summary: ChatGenerationSupport.watchSummary(from: resumed),
                    kind: .imageGeneration
                )
            } else {
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: conversationHex,
                    presentation: .failed(),
                    summary: WatchTaskText.clipped(
                        failureReason ?? IOSAppLocalization.string(
                            "图片已生成，但结果保存失败。",
                            defaultValue: "图片已生成，但结果保存失败。"
                        ),
                        maxLength: 200
                    )
                )
            }
            await dependencies.liveActivityController.end(
                runId: runId,
                presentation: succeeded ? .completed(toolTitle: "图片生成") : .failed()
            )
            host.teardownRun(
                runId: runId,
                terminalEvent: succeeded ? .generationCompleted : .generationFailed,
                terminalStatus: terminalStatus
            )
            if succeeded {
                bindings.generationSucceeded()
            }
    }

    private func failBeforeExecution(
        host: ChatKernelRunHost,
        _ toolCall: UIMessagePart.Tool,
        in snapshot: [UIMessage],
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        reason: String
    ) async {
        guard host.claimImageFailureTerminal(runId) else { return }
        let failure = ChatToolOutputFormatter.toolFailureJSON(
            toolName: toolCall.toolName,
            reason: reason,
            cancelled: false
        )
        let failedMessages = toolRuntime.messagesByFinishingToolCall(
            toolCall,
            outputText: failure,
            in: snapshot
        )
        bindings.setMessages(failedMessages)
        bindings.bumpMessageRevision(.toolResultAppended, 1)
        let conversationHex = conversationId?.toHexDashString()
        let didPersist = await bindings.persistMessages(conversationId)
        let terminalStatus: AgentRunStatus = didPersist ? .failed : .recoveryPending
        let didRecordRun = await bindings.recordRun(
            runId,
            startedAt,
            terminalStatus,
            inputDigest,
            conversationHex,
            nil
        )
        guard didRecordRun else {
            host.releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: .failed(),
            summary: WatchTaskText.clipped(reason, maxLength: 200)
        )
        await dependencies.liveActivityController.end(runId: runId, presentation: .failed())
        host.teardownRun(runId: runId, terminalEvent: .generationFailed, terminalStatus: terminalStatus)
    }

    func recordTerminalIfNeeded(
        host: ChatKernelRunHost,
        runId: String,
        toolCall: UIMessagePart.Tool,
        outcome: String,
        resultPayload: String?
    ) async -> TerminalClaimResult {
        guard host.isImageRunCurrent(runId),
              didStart else { return .failed }
        guard !terminalClaimed else { return .alreadyClaimed }
        terminalClaimed = true
        return await toolLedger.recordToolCallTerminal(
            runId: runId,
            toolCallId: toolCall.toolCallId,
            outcome: outcome,
            resultPayload: resultPayload
        ) ? .recorded : .failed
    }

    func markOutcomeUnknownIfNeeded(
        host: ChatKernelRunHost,
        runId: String,
        toolCall: UIMessagePart.Tool,
        outcome: String
    ) async -> TerminalClaimResult {
        guard host.isImageRunCurrent(runId),
              didStart else { return .failed }
        guard !terminalClaimed else { return .alreadyClaimed }
        terminalClaimed = true
        return await toolLedger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCall.toolCallId,
            expected: .started,
            to: .outcomeUnknown,
            outcome: outcome
        ) ? .recorded : .failed
    }

    func reconcileStartFailure(
        runId: String,
        toolCallId: String,
        outcome: String
    ) async {
        let closedStarted = await toolLedger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCallId,
            expected: .started,
            to: .reconciled,
            outcome: outcome
        )
        if !closedStarted {
            _ = await toolLedger.recordToolCallRecoveryTransition(
                runId: runId,
                toolCallId: toolCallId,
                expected: .prepared,
                to: .reconciled,
                outcome: outcome
            )
        }
    }

}
