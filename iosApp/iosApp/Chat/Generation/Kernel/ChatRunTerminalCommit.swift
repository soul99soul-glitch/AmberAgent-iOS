import Foundation
@preconcurrency import Shared

/// Persists a claimed run's terminal snapshot before publishing system completion.
/// ChatKernelRunHost alone claims finalization and clears run identity.
@MainActor
final class ChatRunTerminalCommit {
    struct Run {
        let runId: String
        let startedAt: Int64
        let inputDigest: String
        let conversationId: KotlinUuid?
        let displayBaseline: [UIMessage]
        let citationTracker: IOSMemoryCitationTracker?
        let streamClock: ChatGenerationSpeedClock
        let failureMessage: String?
        let modelId: String
        let cancelCause: ChatKernelRunHost.CancellationCause?
        let cancelBaseline: IOSConversationWriteBaseline?
        let outcomeUnknownSignal: IOSToolOutcomeUnknownSignal?
    }

    enum Result {
        case recordRejected
        case recorded(event: ChatMessageUpdateReason, status: AgentRunStatus, succeeded: Bool, cancelled: Bool)
    }

    private let bindings: ChatGenerationBindings
    private let dependencies: ChatGenerationDependencies
    private let phoneControl: IOSPhoneControlController
    private let projection: ChatKernelProjection
    private let toolRuntime: ChatToolRuntime
    private let backgroundExecution: BackgroundGenerationKeepAlive

    init(
        bindings: ChatGenerationBindings,
        dependencies: ChatGenerationDependencies,
        phoneControl: IOSPhoneControlController,
        projection: ChatKernelProjection,
        toolRuntime: ChatToolRuntime,
        backgroundExecution: BackgroundGenerationKeepAlive
    ) {
        self.bindings = bindings
        self.dependencies = dependencies
        self.phoneControl = phoneControl
        self.projection = projection
        self.toolRuntime = toolRuntime
        self.backgroundExecution = backgroundExecution
    }

    func outcomeUnknown(run: Run) async -> Result {
        let runId = run.runId
        await phoneControl.stop(runID: runId)
        projection.discardProvisionalAssistant()
        let startedAt = run.startedAt
        let inputDigest = run.inputDigest
        let conversationId = run.conversationId
        let conversationHex = conversationId?.toHexDashString()
        let finalMessages = bindings.getMessages()
        let didPersist = await bindings.persistMessages(conversationId)
        let terminalStatus: AgentRunStatus = didPersist ? .outcomeUnknown : .recoveryPending
        let didRecordRun = await bindings.recordRun(
            runId,
            startedAt,
            terminalStatus,
            inputDigest,
            conversationHex,
            nil
        )
        guard didRecordRun else {
            return .recordRejected
        }
        if didPersist, let conversationHex {
            if let signal = run.outcomeUnknownSignal {
                let descriptor = IOSToolOutcomeUnknownDescriptor(
                    runId: runId,
                    conversationId: conversationHex,
                    toolCallId: signal.toolCallId,
                    toolName: signal.toolName
                )
                bindings.setToolOutcomeUnknown(descriptor)
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
            } else {
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(
                    runId: runId,
                    conversationId: conversationHex
                )
            }
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: conversationHex,
                presentation: .failed(),
                summary: IOSAppLocalization.string(
                    didPersist
                        ? "操作结果待核实，但没有可打开的 iPhone 对话。"
                        : "操作结果尚未保存，请在 iPhone 恢复。",
                    defaultValue: didPersist
                        ? "操作结果待核实，但没有可打开的 iPhone 对话。"
                        : "操作结果尚未保存，请在 iPhone 恢复。"
                )
            )
        }
        await dependencies.liveActivityController.end(runId: runId, presentation: .failed())
        bindings.setMessages(finalMessages)
        return .recorded(event: .generationFailed, status: terminalStatus, succeeded: false, cancelled: false)
    }

    /// completed(CG-C handleCompletedStream 正常分支 :2732-2797 +
    /// 空回复分支 :2685-2730)。
    func completed(run: Run) async -> Result {
        let runId = run.runId
        await phoneControl.stop(runID: runId)
        projection.discardProvisionalAssistant()
        let startedAt = run.startedAt
        let inputDigest = run.inputDigest
        let conversationId = run.conversationId
        let conversationHex = conversationId?.toHexDashString()
        var final = bindings.getMessages()
        // citation 使用标记:remainder 已由引擎逐段折进 transcript;这里记
        // memory 使用(force:true,引用是模型信号,CG-C :2464-2466 同款)。
        if let tracker = run.citationTracker {
            let ids = tracker.citationIds
            if !ids.isEmpty {
                bindings.recordMemoryUsage(ids.sorted(), true)
            }
        }

        // 空回复检测(CG-C :2685-2730)。
        if ChatGenerationSupport.isEmptyAssistantResponse(final) {
            let miniAppExpected = ChatRuntimeContextBuilder.miniAppTurnContext(in: run.displayBaseline) != nil
            final.append(miniAppExpected
                ? ChatGenerationSupport.emptyMiniAppResponseNotice()
                : ChatGenerationSupport.emptyResponseNotice())
            bindings.setMessages(final)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
            let didPersist = await bindings.persistMessages(conversationId)
            if didPersist {
                await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
            }
            let succeeded = didPersist && !miniAppExpected
            let terminalStatus: AgentRunStatus = didPersist
                ? (miniAppExpected ? .failed : .completed)
                : .recoveryPending
            let didRecordRun = await bindings.recordRun(
                runId, startedAt,
                terminalStatus,
                inputDigest, conversationHex, nil
            )
            guard didRecordRun else {
                return .recordRejected
            }
            if succeeded {
                WatchTaskCoordinator.shared.publishCompleted(runId: runId, conversationId: conversationHex, summary: nil)
            } else {
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: conversationHex,
                    presentation: .failed(),
                    summary: miniAppExpected && didPersist
                        ? IOSAppLocalization.string(
                            "小应用生成失败：模型没有返回任何内容。",
                            defaultValue: "小应用生成失败：模型没有返回任何内容。"
                        )
                        : IOSAppLocalization.string(
                            "回复已生成，但最终结果保存失败。",
                            defaultValue: "回复已生成，但最终结果保存失败。"
                        )
                )
            }
            await dependencies.liveActivityController.end(
                runId: runId,
                presentation: succeeded ? .completed() : .failed()
            )
            return .recorded(
                event: succeeded ? .generationCompleted : .generationFailed,
                status: terminalStatus, succeeded: succeeded, cancelled: false
            )
        }

        // miniApp 输出事务(CG-C :2732-2762)。
        var finalSnapshot = final
        let miniAppApplication = bindings.saveMiniAppIfPresent(final, conversationId)
        if let miniAppApplication {
            finalSnapshot = miniAppApplication.messages
            bindings.setMessages(finalSnapshot)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
        }

        let miniAppFailed = miniAppApplication?.outcome == .failed
        let unstampedFinalSnapshot = finalSnapshot
        if !miniAppFailed {
            finalSnapshot = IOSIntelligentUITerminal.markCompleted(
                finalSnapshot, baseline: run.displayBaseline, runID: runId
            )
            if finalSnapshot != unstampedFinalSnapshot {
                bindings.setMessages(finalSnapshot)
                bindings.bumpMessageRevision(.toolResultAppended, 1)
            }
        }
        let summary = ChatGenerationSupport.watchSummary(from: finalSnapshot)
        let didPersist = await bindings.persistMessages(conversationId)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        if !didPersist, finalSnapshot != unstampedFinalSnapshot {
            finalSnapshot = unstampedFinalSnapshot
            bindings.setMessages(finalSnapshot)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
        }
        if !didPersist, let miniAppApplication {
            if miniAppApplication.rollback() {
                bindings.setMessages(miniAppApplication.rollbackMessages)
                bindings.bumpMessageRevision(.toolResultAppended, 1)
            } else {
                NSLog("[AmberChat] MiniApp rollback skipped because its persisted state changed")
            }
        }
        if didPersist, let miniAppApplication, !miniAppApplication.commit() {
            NSLog("[AmberChat] MiniApp transaction commit remains pending for cold-start reconciliation")
        }
        if didPersist,
           let workspaceFailure = miniAppApplication?.syncWorkspaceAfterConversationPersistence() {
            finalSnapshot = workspaceFailure.messages
            bindings.setMessages(finalSnapshot)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
            _ = await bindings.persistMessages(conversationId)
        }
        let terminalStatus: AgentRunStatus = didPersist
            ? (miniAppFailed ? .failed : .completed)
            : .recoveryPending
        let didRecordRun = await bindings.recordRun(
            runId, startedAt,
            terminalStatus,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            return .recordRejected
        }
        if didPersist, !miniAppFailed {
            WatchTaskCoordinator.shared.publishCompleted(
                runId: runId,
                conversationId: conversationHex,
                summary: summary,
                resultTitle: miniAppApplication?.resultTitle
            )
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: conversationHex,
                presentation: .failed(),
                summary: miniAppFailed && didPersist
                    ? IOSAppLocalization.string(
                        "小应用生成未完成，错误详情已保存在会话中。",
                        defaultValue: "小应用生成未完成，错误详情已保存在会话中。"
                    )
                    : IOSAppLocalization.string(
                        "回复已生成，但最终结果保存失败。",
                        defaultValue: "回复已生成，但最终结果保存失败。"
                    )
            )
        }
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: didPersist && !miniAppFailed ? .completed() : .failed()
        )
        if didPersist, !miniAppFailed, let conversationId {
            bindings.scheduleMemoryExtraction(conversationId, run.displayBaseline, finalSnapshot)
        }
        return .recorded(
            event: didPersist && !miniAppFailed ? .generationCompleted : .generationFailed,
            status: terminalStatus, succeeded: didPersist && !miniAppFailed, cancelled: false
        )
    }

    /// failed(CG-C presentStreamError :2483-2533;截断终态由适配器 A4 分支
    /// 追加过输出上限提示,这里不再加泡,对齐 completeTruncatedStream
    /// :2802-2843 的 Watch/LiveActivity 形状)。
    func failed(run: Run, requiresRecovery: Bool = false) async -> Result {
        let runId = run.runId
        await phoneControl.stop(runID: runId)
        projection.discardProvisionalAssistant()
        let startedAt = run.startedAt
        let inputDigest = run.inputDigest
        let conversationId = run.conversationId
        let conversationHex = conversationId?.toHexDashString()
        var updated = bindings.getMessages()
        var watchSummary: String? = ChatGenerationSupport.watchSummary(from: updated)

        if let rawMessage = run.failureMessage {
            let userFacing = bindings.userFacingGenerationError(
                rawMessage,
                run.modelId
            )
            if toolRuntime.hasUnresolvedToolCall(in: updated) {
                updated = toolRuntime.messagesByFailingPendingToolCalls(
                    in: updated,
                    failureReason: IOSAppLocalization.string(
                        "Generation failed before the tool call completed.",
                        defaultValue: "Generation failed before the tool call completed."
                    )
                )
            }
            // 引擎在 provider 失败时已在尾部追加 "[engine] provider error: …"
            // 占位泡——升级为 CG-C 同款用户向错误泡(保留位置/id);没有则追加。
            if let lastIndex = updated.indices.last,
               updated[lastIndex].role == MessageRole.assistant,
               let text = updated[lastIndex].parts.first as? UIMessagePart.Text,
               text.text.hasPrefix("[engine] provider error:") {
                let last = updated[lastIndex]
                updated[lastIndex] = UIMessage(
                    id: last.id,
                    role: MessageRole.assistant,
                    parts: [MessageKt.localGenerationErrorTextPart(text: userFacing)],
                    annotations: last.annotations,
                    createdAt: last.createdAt,
                    finishedAt: chatNowLocalDateTime(),
                    modelId: last.modelId,
                    usage: last.usage,
                    translation: last.translation
                )
            } else {
                updated.append(UIMessage(
                    id: KotlinUuid.companion.random(),
                    role: MessageRole.assistant,
                    parts: [MessageKt.localGenerationErrorTextPart(text: userFacing)],
                    annotations: [],
                    createdAt: chatNowLocalDateTime(),
                    finishedAt: chatNowLocalDateTime(),
                    modelId: nil,
                    usage: nil,
                    translation: nil
                ))
            }
            bindings.setMessages(updated)
            watchSummary = WatchTaskText.clipped(userFacing, maxLength: 200)
        }

        let didPersist = await bindings.persistMessages(conversationId)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        let terminalStatus: AgentRunStatus = didPersist && !requiresRecovery
            ? .failed
            : .recoveryPending
        let didRecordRun = await bindings.recordRun(
            runId, startedAt, terminalStatus,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            return .recordRejected
        }
        let currentRunMessages = updated.dropFirst(min(run.displayBaseline.count, updated.count))
        let retryableFailure = didPersist
            && !requiresRecovery
            && !currentRunMessages.contains { message in
                message.parts.contains { $0 is UIMessagePart.Tool }
            }
        let failurePresentation = AgentActivityPresentation.failed(
            retryable: retryableFailure
        )
        AgentActivityRetryEligibilityStore.shared.setEligible(
            retryableFailure,
            runId: runId,
            conversationId: conversationHex
        )
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: failurePresentation,
            summary: watchSummary
        )
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: failurePresentation
        )
        if !didPersist {
            print("[AmberChat] Failed to persist kernel failure terminal run=\(runId)")
        }
        return .recorded(event: .generationFailed, status: terminalStatus, succeeded: false, cancelled: false)
    }

    /// cancelled(CG-C cancel 尾 :1501-1581):取消填充/快照已由适配器同步
    /// 发布;这里补 stamp、持久化、durable 终态与收尾。注意与 finishStreaming
    /// 尾的差异:恢复 steer leftover 进 composer,不走 handleSteerQueueAtTerminal,
    /// 也不 generationSucceeded。
    func cancelled(run: Run) async -> Result {
        let runId = run.runId
        await phoneControl.stop(runID: runId)
        // cancelledTerminal 不经过 teardownRun,单独补同名事件,保持三种终态
        // (完成/失败/取消)都能发出 RunTerminal。
        ChatPerfTrace.event("RunTerminal")
        projection.discardProvisionalAssistant()
        let cause = run.cancelCause ?? .user
        let startedAt = run.startedAt
        let inputDigest = run.inputDigest
        let conversationId = run.conversationId
        let conversationHex = conversationId?.toHexDashString()

        var messages = bindings.getMessages()
        // preamble 取消时适配器未起跑,tracker 还没被 flush 过;已起跑时
        // adapter.cancel() 已把 remainder 折进填充,这里 finish() 幂等返回空。
        if let tracker = run.citationTracker {
            let remainder = tracker.finish()
            if !remainder.isEmpty {
                messages = IOSMemoryCitationTracker.appendingCitationRemainder(remainder, to: messages)
            }
            let ids = tracker.citationIds
            if !ids.isEmpty {
                bindings.recordMemoryUsage(ids.sorted(), true)
            }
        }
        messages = messages.applyingLastAssistantGenerationDuration(run.streamClock.duration())
        bindings.setMessages(messages)
        ChatStreamRecorder.shared.finish(runId: runId)
        projection.clearAllApprovals()
        bindings.setIsLoading(false)
        bindings.setContextCompactState(.idle)
        bindings.restoreSteerQueueLeftover(conversationId)
        bindings.bumpMessageRevision(.generationCancelled, 1)
        // 系统 continued-processing 立即掐掉(CG-C :1539-1542);持久化完成前
        // 保留 UIKit 短窗,下方 end 统一归还。
        backgroundExecution.abandonSystemAssertion(runId)

        let baseline = run.cancelBaseline ?? bindings.capturePersistMessagesBaseline(conversationId)
        let didPersist = await bindings.persistMessagesSnapshot(messages, conversationId, baseline)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        let terminalStatus: AgentRunStatus = didPersist ? cause.durableStatus : .recoveryPending
        let didRecordRun = await bindings.recordRun(
            runId, startedAt,
            terminalStatus,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            return .recordRejected
        }
        let terminalPresentation: AgentActivityPresentation
        let terminalSummary: String?
        if !didPersist {
            terminalPresentation = .failed()
            terminalSummary = IOSAppLocalization.string(
                "已停止生成，但最终状态保存失败。",
                defaultValue: "已停止生成，但最终状态保存失败。"
            )
        } else {
            switch cause {
            case .user:
                terminalPresentation = .cancelled()
                terminalSummary = nil
            case .backgroundInterruption:
                terminalPresentation = .failed()
                terminalSummary = IOSAppLocalization.string(
                    "后台生成被系统中断，可以重试。",
                    defaultValue: "后台生成被系统中断，可以重试。"
                )
            }
        }
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: terminalPresentation,
            summary: terminalSummary
        )
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: terminalPresentation
        )
        return .recorded(event: .generationCancelled, status: terminalStatus, succeeded: false, cancelled: true)
    }

}
