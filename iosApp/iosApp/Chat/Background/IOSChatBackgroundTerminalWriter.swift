@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    func completeDetachedResponse(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        messages: [UIMessage],
        runState: IOSChatBackgroundRunState
    ) async {
        await IOSPhoneControlController.shared.stop(runID: job.runId, returnToAmber: true)
        var stamped = messages.applyingLastAssistantGenerationDuration(runState.generationDuration())
        let miniAppApplication = job.saveMiniAppIfPresent?(stamped, job.conversationId)
        if let miniAppApplication {
            stamped = miniAppApplication.messages
        }
        let miniAppFailed = miniAppApplication?.outcome == .failed
        if !miniAppFailed {
            stamped = IOSIntelligentUITerminal.markCompleted(
                stamped, baseline: job.runDisplayBaseline, runID: job.runId
            )
        }
        let didSave = await job.conversationStore.saveBackgroundCompletion(
            baseMessages: job.runDisplayBaseline,
            completedMessages: stamped,
            to: job.conversationId
        )
        if didSave {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: job.runId)
        }
        if didSave {
            _ = miniAppApplication?.commit()
        } else {
            _ = miniAppApplication?.rollback()
        }
        if didSave,
           let workspaceFailure = miniAppApplication?.syncWorkspaceAfterConversationPersistence() {
            stamped = workspaceFailure.messages
            _ = await job.conversationStore.replaceBackgroundMessage(
                workspaceFailure.replacementMessage,
                in: job.conversationId
            )
        }
        let runStatus = Self.backgroundTerminalStatus(
            didSave: didSave,
            singleToolFailureReason: nil,
            guardStopped: false,
            miniAppFailed: miniAppFailed
        )
        guard await recordRun(
            job.runId,
            status: runStatus,
            conversationId: job.conversationId
        ) else {
            releaseRuntimeOwnership(requestId: requestId)
            return
        }
        guard runState.finalizeTerminal() else { return }
        if didSave {
            let terminalPresentation: AgentActivityPresentation
            if runStatus == .completed {
                terminalPresentation = .completed()
            } else {
                terminalPresentation = await backgroundFailurePresentation(
                    job: job,
                    didSave: didSave,
                    status: runStatus,
                    finalMessages: stamped
                )
            }
            await notifyRunTerminal(job: job, runId: job.runId, finalMessages: stamped)
            if runStatus == .completed {
                IOSMemoryExtractionCoordinator.shared.enqueue(
                    conversationId: job.conversationId, baseline: job.runDisplayBaseline, completed: stamped
                )
                WatchTaskCoordinator.shared.publishCompleted(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString(),
                    summary: Self.backgroundSummary(from: stamped),
                    resultTitle: miniAppApplication?.resultTitle
                )
            } else {
                WatchTaskCoordinator.shared.publish(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString(),
                    presentation: terminalPresentation,
                    summary: Self.backgroundSummary(from: stamped)
                )
            }
            await job.liveActivityController.end(runId: job.runId, presentation: terminalPresentation)
            finish(runId: job.runId, requestId: requestId)
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: .failed(),
                summary: IOSAppLocalization.string(
                    "回复已完成，但保存失败。",
                    defaultValue: "回复已完成，但保存失败。"
                )
            )
            await job.liveActivityController.end(runId: job.runId, presentation: .failed())
            activeRunStates[requestId] = IOSChatBackgroundRunState()
            endChatBackgroundAudioKeepAlive(requestId: requestId)
        }
    }

    func completeTruncatedAfterTerminalReservation(
        job: IOSChatBackgroundRuntimeJob,
        backgroundTask: IOSChatBackgroundExecution,
        runState: IOSChatBackgroundRunState,
        reconciledMessages: [UIMessage]
    ) async {
        var finalMessages = reconciledMessages.applyingLastAssistantGenerationDuration(
            runState.generationDuration()
        )
        if job.toolRuntime.hasUnresolvedToolCall(in: finalMessages) {
            finalMessages = job.toolRuntime.messagesByFailingPendingToolCalls(
                in: finalMessages,
                failureReason: IOSAppLocalization.string(
                    "The model output ended before the tool call completed.",
                    defaultValue: "The model output ended before the tool call completed."
                )
            )
        }
        finalMessages.append(ChatGenerationSupport.outputLimitNotice())
        let didSave = await job.conversationStore.saveBackgroundCompletion(
            baseMessages: job.runDisplayBaseline,
            completedMessages: finalMessages,
            to: job.conversationId
        )
        if didSave {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: job.runId)
        }
        let recordedStatus: AgentRunStatus = didSave ? .failed : .recoveryPending
        guard await recordRun(
            job.runId,
            status: recordedStatus,
            conversationId: job.conversationId
        ) else {
            releaseRuntimeOwnership(requestId: backgroundTask.identifier)
            return
        }
        let didFinalize = runState.finalizeTerminal()
        guard didFinalize else {
            if runState.terminalIsOwned(by: .expiration) {
                let failurePresentation = await backgroundFailurePresentation(
                    job: job,
                    didSave: didSave,
                    status: recordedStatus,
                    finalMessages: finalMessages
                )
                if didSave {
                    await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
                } else {
                    await archiveTerminalOutput(
                        runId: job.runId,
                        conversationId: job.conversationId,
                        displayMessages: job.runDisplayBaseline,
                        finalMessages: finalMessages
                    )
                }
                _ = await publishTruncatedTerminal(
                    job: job,
                    requestId: backgroundTask.identifier,
                    didSave: didSave,
                    summary: Self.backgroundSummary(from: finalMessages),
                    presentation: failurePresentation
                )
            }
            return
        }
        guard didSave else {
            backgroundTask.updateTitle(
                IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
                subtitle: IOSAppLocalization.string(
                    "保存截断回复失败",
                    defaultValue: "保存截断回复失败"
                )
            )
            await completeAsFailureAfterSaveFailure(
                job: job,
                backgroundTask: backgroundTask
            )
            return
        }

        let failurePresentation = await backgroundFailurePresentation(
            job: job,
            didSave: didSave,
            status: recordedStatus,
            finalMessages: finalMessages
        )
        await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
        guard await publishTruncatedTerminal(
            job: job,
            requestId: backgroundTask.identifier,
            didSave: true,
            summary: Self.backgroundSummary(from: finalMessages),
            presentation: failurePresentation
        ) else { return }
        backgroundTask.updateTitle(
            IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
            subtitle: IOSAppLocalization.string("回复达到输出上限", defaultValue: "回复达到输出上限")
        )
        if backgroundTask.progress.totalUnitCount >= 0 {
            backgroundTask.progress.completedUnitCount = backgroundTask.progress.totalUnitCount
        }
        if runState.claimSystemTaskCompletion() {
            backgroundTask.setTaskCompleted(success: true)
        }
    }

    private func publishTruncatedTerminal(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        didSave: Bool,
        summary: String?,
        presentation: AgentActivityPresentation
    ) async -> Bool {
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: presentation,
            summary: summary
        )
        await job.liveActivityController.end(runId: job.runId, presentation: presentation)
        if didSave {
            finish(runId: job.runId, requestId: requestId)
        } else {
            releaseRuntimeOwnership(requestId: requestId)
        }
        return true
    }

    func fail(
        job: IOSChatBackgroundRuntimeJob,
        backgroundTask: IOSChatBackgroundExecution,
        runState: IOSChatBackgroundRunState,
        rawMessage: String,
        preservedGeneratedSuffix: [UIMessage] = [],
        partialAssistantText: String? = nil
    ) async {
        guard runState.reserveTerminal() else { return }
        await IOSPhoneControlController.shared.stop(runID: job.runId, returnToAmber: true)
        await failAfterTerminalReservation(
            job: job,
            backgroundTask: backgroundTask,
            runState: runState,
            terminalOwner: .completion,
            rawMessage: rawMessage,
            preservedGeneratedSuffix: preservedGeneratedSuffix,
            partialAssistantText: partialAssistantText
        )
    }

    func failAfterTerminalReservation(
        job: IOSChatBackgroundRuntimeJob,
        backgroundTask: IOSChatBackgroundExecution,
        runState: IOSChatBackgroundRunState,
        terminalOwner: IOSChatBackgroundRunState.TerminalOwner,
        rawMessage: String,
        preservedGeneratedSuffix: [UIMessage] = [],
        partialAssistantText: String? = nil,
        requiresRecovery: Bool = false
    ) async {
        let reconciledBase = Self.reconciledDisplayPrefix(
            resultMessages: job.messagesSnapshot.messages,
            uploadMessageCount: job.uploadMessages.count,
            displayMessages: job.displayMessages
        )
        var finalMessages = Self.failedMessages(
            displayMessages: reconciledBase,
            preservedGeneratedSuffix: preservedGeneratedSuffix,
            partialAssistantText: partialAssistantText,
            rawMessage: rawMessage,
            modelId: job.params.model.modelId
        )
        if job.toolRuntime.hasUnresolvedToolCall(in: finalMessages) {
            finalMessages = job.toolRuntime.messagesByFailingPendingToolCalls(
                in: finalMessages,
                failureReason: IOSAppLocalization.string(
                    "Generation failed before the tool call completed.",
                    defaultValue: "Generation failed before the tool call completed."
                )
            )
        }
        let didSave: Bool
        switch job.mode {
        case .continueModel, .resumeResponse:
            didSave = await job.conversationStore.saveBackgroundCompletion(
                baseMessages: job.runDisplayBaseline,
                completedMessages: finalMessages,
                to: job.conversationId
            )
        case .singleToolOnly:
            didSave = await job.conversationStore.saveBackgroundToolCompletion(
                baseMessages: job.displayMessages,
                completedMessages: finalMessages,
                to: job.conversationId
            )
        }
        if didSave {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: job.runId)
        }
        let recordedStatus: AgentRunStatus = didSave && !requiresRecovery
            ? .failed
            : .recoveryPending
        guard await recordRun(
            job.runId,
            status: recordedStatus,
            conversationId: job.conversationId
        ) else {
            releaseRuntimeOwnership(requestId: backgroundTask.identifier)
            return
        }
        let didFinalize = terminalOwner == .completion
            ? runState.finalizeTerminal()
            : runState.finalizeTerminal(as: terminalOwner)
        guard didFinalize else {
            if runState.terminalIsOwned(by: .expiration) {
                let failurePresentation = await backgroundFailurePresentation(
                    job: job,
                    didSave: didSave,
                    status: recordedStatus,
                    finalMessages: finalMessages
                )
                WatchTaskCoordinator.shared.publish(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString(),
                    presentation: failurePresentation
                )
                await job.liveActivityController.end(
                    runId: job.runId,
                    presentation: failurePresentation
                )
                if didSave && !requiresRecovery {
                    await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
                    finish(runId: job.runId, requestId: backgroundTask.identifier)
                } else {
                    releaseRuntimeOwnership(requestId: backgroundTask.identifier)
                }
            }
            return
        }
        guard didSave else {
            backgroundTask.updateTitle(
                IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
                subtitle: IOSAppLocalization.string(
                    "无法保存失败状态",
                    defaultValue: "无法保存失败状态"
                )
            )
            await completeAsFailureAfterSaveFailure(
                job: job,
                backgroundTask: backgroundTask
            )
            return
        }
        if requiresRecovery {
            await completeAsFailureAfterSaveFailure(
                job: job,
                backgroundTask: backgroundTask
            )
            return
        }
        let failurePresentation = await backgroundFailurePresentation(
            job: job,
            didSave: didSave,
            status: recordedStatus,
            finalMessages: finalMessages
        )
        await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: failurePresentation
        )
        await job.liveActivityController.end(
            runId: job.runId,
            presentation: failurePresentation
        )
        if runState.claimSystemTaskCompletion() {
            finish(runId: job.runId, requestId: backgroundTask.identifier)
            backgroundTask.setTaskCompleted(success: false)
        } else {
            removePayload(requestId: backgroundTask.identifier)
        }
    }

    func persistExpirationFailure(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        rawMessage: String,
        partialAssistantText: String?,
        terminalReason: String? = nil
    ) async -> Bool {
        await IOSPhoneControlController.shared.stop(runID: job.runId)
        let snapshotMessages = job.messagesSnapshot.messages
        // Resume accumulates over display messages; ordinary execution accumulates
        // over the prepared upload, whose prefix can have a different length.
        let reconciledBase = job.mode == .resumeResponse
            ? job.displayMessages
            : Self.reconciledDisplayPrefix(
                resultMessages: snapshotMessages,
                uploadMessageCount: job.uploadMessages.count,
                displayMessages: job.displayMessages
            )
        let preservedGeneratedSuffix = job.mode == .resumeResponse
            ? Array(snapshotMessages.dropFirst(job.displayMessages.count))
            : []
        var finalMessages = Self.failedMessages(
            displayMessages: reconciledBase,
            preservedGeneratedSuffix: preservedGeneratedSuffix,
            partialAssistantText: partialAssistantText,
            rawMessage: rawMessage,
            modelId: job.params.model.modelId
        )
        if job.toolRuntime.hasUnresolvedToolCall(in: finalMessages) {
            finalMessages = job.toolRuntime.messagesByFailingPendingToolCalls(
                in: finalMessages,
                failureReason: IOSAppLocalization.string(
                    "Generation failed before the tool call completed.",
                    defaultValue: "Generation failed before the tool call completed."
                )
            )
        }
        let didSave = await job.conversationStore.saveBackgroundCompletion(
            baseMessages: job.runDisplayBaseline,
            completedMessages: finalMessages,
            to: job.conversationId
        )
        if didSave {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: job.runId)
        }
        let recordedStatus: AgentRunStatus = didSave ? .failed : .recoveryPending
        guard await recordRun(
            job.runId,
            status: recordedStatus,
            conversationId: job.conversationId,
            terminalReason: terminalReason
        ) else {
            releaseRuntimeOwnership(requestId: requestId)
            return false
        }
        let failurePresentation = await backgroundFailurePresentation(
            job: job,
            didSave: didSave,
            status: recordedStatus,
            finalMessages: finalMessages
        )
        await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: failurePresentation
        )
        await job.liveActivityController.end(
            runId: job.runId,
            presentation: failurePresentation
        )
        if didSave {
            finish(runId: job.runId, requestId: requestId)
        } else {
            releaseRuntimeOwnership(requestId: requestId)
        }
        return didSave
    }

    func persistExpirationPause(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String
    ) async -> Bool {
        backgroundInterruptedRequestIds.insert(requestId)
        // Drop the expired system-task owner before the first actor hop.
        // Foreground recovery may submit a new handler while durable state is
        // being recorded; the old expiration path must not retain that owner.
        pauseRuntimeOwnership(requestId: requestId)
        guard await recordRun(
            job.runId,
            status: .recoveryPending,
            conversationId: job.conversationId
        ) else {
            backgroundInterruptedRequestIds.remove(requestId)
            publishStateEvent(for: job)
            return false
        }
        publishStateEvent(for: job)
        let presentation = AgentActivityPresentation.reconnecting(kind: .response)
        let hasDeclaredTools = !job.params.tools.isEmpty || !job.fullToolNames.isEmpty
        let resumesAutomatically = job.mode == .resumeResponse
            || Self.canAutomaticallyResumeOrdinaryJob(
                mode: job.mode,
                hasDeclaredTools: hasDeclaredTools
            )
        let resumeSummary = resumesAutomatically
            ? IOSAppLocalization.string(
                "后台执行已暂停，回到 Amber 后自动继续。",
                defaultValue: "后台执行已暂停，回到 Amber 后自动继续。"
            )
            : IOSAppLocalization.string(
                "后台任务包含不能安全自动重放的操作，请回到会话重试。",
                defaultValue: "后台任务包含不能安全自动重放的操作，请回到会话重试。"
            )
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: presentation,
            summary: resumeSummary
        )
        await job.liveActivityController.update(
            runId: job.runId,
            presentation: presentation,
            force: true
        )
        if UIApplication.shared.applicationState == .active {
            resumeRecoverableJobsIfNeeded()
        }
        return true
    }

    /// Called only after the completion owner has already persisted
    /// `recordedStatus`, but expiration won the in-memory terminal race.
    func publishExpiredInFlightSaveAfterRecordedRun(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        didSave: Bool,
        recordedStatus: AgentRunStatus,
        guardStoppedNotice: String?,
        miniAppFailed: Bool,
        resultTitle: String?,
        summary: String?,
        completedMessages: [UIMessage]
    ) async {
        let succeeded = recordedStatus == .completed
        let terminalPresentation: AgentActivityPresentation
        if succeeded {
            terminalPresentation = .completed()
        } else {
            terminalPresentation = await backgroundFailurePresentation(
                job: job,
                didSave: didSave,
                status: recordedStatus,
                finalMessages: completedMessages
            )
        }
        if didSave {
            removePayload(requestId: requestId)
        }
        await notifyRunTerminal(job: job, runId: job.runId, finalMessages: completedMessages)
        if succeeded {
            WatchTaskCoordinator.shared.publishCompleted(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                summary: summary,
                resultTitle: resultTitle
            )
            if let settings = dependencies?.sharedSettings {
                ConversationListPreviewGenerator.schedule(
                    conversationId: job.conversationId,
                    messages: completedMessages,
                    store: job.conversationStore,
                    settings: settings
                )
                job.conversationStore.recapGenerator.schedule(
                    conversationID: job.conversationId,
                    messages: completedMessages,
                    settings: settings
                )
            }
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: terminalPresentation,
                summary: guardStoppedNotice.flatMap { WatchTaskText.clipped($0, maxLength: 200) }
                    ?? (miniAppFailed ? summary : nil)
            )
        }
        await job.liveActivityController.end(
            runId: job.runId,
            presentation: terminalPresentation
        )
        if didSave {
            finish(runId: job.runId, requestId: requestId)
        } else {
            releaseRuntimeOwnership(requestId: requestId)
        }
    }

    func completeAsFailureAfterSaveFailure(
        job: IOSChatBackgroundRuntimeJob,
        backgroundTask: IOSChatBackgroundExecution
    ) async {
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: .failed()
        )
        await job.liveActivityController.end(runId: job.runId, presentation: .failed())
        releaseRuntimeOwnership(requestId: backgroundTask.identifier)
    }

    func completeOutcomeUnknownAfterTerminalReservation(
        job: IOSChatBackgroundRuntimeJob,
        backgroundTask: IOSChatBackgroundExecution,
        runState: IOSChatBackgroundRunState,
        messages: [UIMessage],
        signal: IOSToolOutcomeUnknownSignal
    ) async {
        IOSPhoneControlController.shared.revoke(runID: job.runId)
        let finalMessages = messages.applyingLastAssistantGenerationDuration(
            runState.generationDuration()
        )
        let didSave = await job.conversationStore.saveBackgroundCompletion(
            baseMessages: job.runDisplayBaseline,
            completedMessages: finalMessages,
            to: job.conversationId
        )
        let runStatus: AgentRunStatus = didSave ? .outcomeUnknown : .recoveryPending
        guard await recordRun(
            job.runId,
            status: runStatus,
            conversationId: job.conversationId
        ) else {
            releaseRuntimeOwnership(requestId: backgroundTask.identifier)
            return
        }
        if runStatus == .outcomeUnknown {
            outcomeUnknownRequestIds.insert(backgroundTask.identifier)
        }
        guard runState.finalizeTerminal() else {
            if runState.terminalIsOwned(by: .expiration) {
                await publishExpiredOutcomeUnknownAfterRecordedRun(
                    job: job,
                    requestId: backgroundTask.identifier,
                    didSave: didSave,
                    signal: signal
                )
            }
            return
        }
        if didSave {
            let descriptor = IOSToolOutcomeUnknownDescriptor(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                toolCallId: signal.toolCallId,
                toolName: signal.toolName
            )
            onToolOutcomeUnknown?(descriptor)
            _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: .failed(),
                summary: IOSAppLocalization.string(
                    "操作结果尚未保存，请在 iPhone 恢复。",
                    defaultValue: "操作结果尚未保存，请在 iPhone 恢复。"
                )
            )
        }
        await job.liveActivityController.end(runId: job.runId, presentation: .failed())
        if didSave {
            if runState.claimSystemTaskCompletion() {
                finish(runId: job.runId, requestId: backgroundTask.identifier)
                backgroundTask.setTaskCompleted(success: false)
            } else {
                removePayload(requestId: backgroundTask.identifier)
            }
        } else {
            releaseRuntimeOwnership(requestId: backgroundTask.identifier)
        }
    }

    /// Outcome-unknown 的保存与 completion 竞态被 expiration 抢占时，仍需
    /// 完成与正常终态相同的系统/UI owner 收口；但只在 transcript 已落盘时
    /// 发出用户确认门禁，避免保存失败时伪造可恢复之外的 unknown 结论。
    private func publishExpiredOutcomeUnknownAfterRecordedRun(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        didSave: Bool,
        signal: IOSToolOutcomeUnknownSignal
    ) async {
        if didSave {
            removePayload(requestId: requestId)
            let descriptor = IOSToolOutcomeUnknownDescriptor(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                toolCallId: signal.toolCallId,
                toolName: signal.toolName
            )
            onToolOutcomeUnknown?(descriptor)
            _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: .failed(),
                summary: IOSAppLocalization.string(
                    "操作结果尚未保存，请在 iPhone 恢复。",
                    defaultValue: "操作结果尚未保存，请在 iPhone 恢复。"
                )
            )
        }
        await job.liveActivityController.end(runId: job.runId, presentation: .failed())
        if didSave {
            finish(runId: job.runId, requestId: requestId)
        } else {
            releaseRuntimeOwnership(requestId: requestId)
        }
    }

    func recordRun(
        _ runId: String,
        status: AgentRunStatus,
        conversationId: KotlinUuid,
        interruptedReason: String? = nil,
        terminalReason: String? = nil
    ) async -> Bool {
        await recordRunResult(
            runId,
            status: status,
            conversationId: conversationId,
            interruptedReason: interruptedReason,
            terminalReason: terminalReason
        ) == .recorded
    }

    func recordRunResult(
        _ runId: String,
        status: AgentRunStatus,
        conversationId: KotlinUuid,
        interruptedReason: String? = nil,
        terminalReason: String? = nil
    ) async -> RunRecordResult {
        let resolvedTerminalReason: String? = status == .interrupted
            ? (interruptedReason ?? "background_interruption")
            : terminalReason

        do {
            let didRecord = try await runStore.transitionFromAnyActiveOrMatchingState(
                runId: runId,
                to: status,
                detail: resolvedTerminalReason
            )
            if !didRecord {
                let actualStatus = try? await runStore.snapshot(runId: runId)?.status.wireName
                IOSBackgroundLifecycleLog.record(
                    "backgroundRunTerminalConflict",
                    detail: "run=\(runId) target=\(status.wireName) actual=\(actualStatus ?? "unavailable")"
                )
                let detail = IOSAppLocalization.string(
                    "运行终态发生冲突，后台任务已保留等待恢复。",
                    defaultValue: "运行终态发生冲突，后台任务已保留等待恢复。"
                )
                if let store = dependencies?.conversationStore {
                    store.publishUserVisibleError(
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
                    backgroundRunLedgerLogger.error("\(detail)")
                }
            }
            return didRecord ? .recorded : .conflict
        } catch {
            // agent_run 是强杀恢复（applyToolCallLedgerRecovery）依赖的账本，
            // 写失败必须走用户可见错误通道，不能只 print 静默吞掉。
            let detail = IOSAppLocalization.formatted(
                "未能写入运行账本：%@",
                defaultValue: "未能写入运行账本：%@",
                arguments: [String(describing: error)]
            )
            if let store = dependencies?.conversationStore {
                store.publishUserVisibleError(
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
                backgroundRunLedgerLogger.error("\(detail)")
            }
            return .failed
        }
    }

    func markRunInterrupted(runId: String, reason: String) async -> Bool {
        (try? await runStore.transitionFromAnyActiveOrMatchingState(
            runId: runId,
            to: .interrupted,
            detail: reason
        )) == true
    }

    /// P1-c: 后台 job 终态回传（FINAL_ANSWER 投递由接线方——编排服务——处理；
    /// 每个终态路径调用一次；enqueue 按 runId 幂等去重）。
    func notifyRunTerminal(
        job: IOSChatBackgroundRuntimeJob,
        runId: String,
        finalMessages: [UIMessage]
    ) async {
        await archiveTerminalOutput(
            runId: runId,
            conversationId: job.conversationId,
            displayMessages: job.runDisplayBaseline,
            finalMessages: finalMessages
        )
        let conversationId = job.conversationId
        let displayBaseline = job.runDisplayBaseline
        guard let onRunTerminal else { return }
        Task { @MainActor [onRunTerminal, conversationId, runId, finalMessages, displayBaseline] in
            await onRunTerminal(conversationId, runId, finalMessages, displayBaseline)
        }
    }

    private func archiveTerminalOutput(
        runId: String,
        conversationId: KotlinUuid,
        displayMessages: [UIMessage],
        finalMessages: [UIMessage]
    ) async {
        let generated = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: finalMessages,
            displayMessages: displayMessages
        )
        guard let output = IOSSubAgentOutputProjection.snapshot(
            messages: generated,
            isFinal: true
        ) else {
            return
        }
        // The archive is part of the terminal result, so finish the durable
        // write before the caller releases the BGTask/runtime owner. The
        // parent callback remains fire-and-forget in notifyRunTerminal to
        // preserve its existing mailbox delivery semantics.
        await IOSSubAgentOutputArchive.archive(
            runId: runId,
            conversationId: conversationId,
            snapshot: output
        )
    }

    static func backgroundSummary(from messages: [UIMessage]) -> String? {
        guard let lastAssistant = messages.last(where: { $0.role == MessageRole.assistant }) else {
            return nil
        }
        let text = lastAssistant.parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchTaskText.clipped(text, maxLength: 280)
    }

    static func backgroundTerminalStatus(
        didSave: Bool,
        singleToolFailureReason: String?,
        guardStopped: Bool,
        miniAppFailed: Bool = false,
        hitStepLimit: Bool = false,
        generativeUiRepairFailed: Bool = false
    ) -> AgentRunStatus {
        guard didSave else { return .recoveryPending }
        if guardStopped || miniAppFailed || hitStepLimit || generativeUiRepairFailed {
            return .failed
        }
        return singleToolFailureReason == nil ? .completed : .failed
    }

    func backgroundFailurePresentation(
        job: IOSChatBackgroundRuntimeJob,
        didSave: Bool,
        status: AgentRunStatus,
        finalMessages: [UIMessage]
    ) async -> AgentActivityPresentation {
        guard didSave, status == .failed, job.mode != .singleToolOnly else {
            AgentActivityRetryEligibilityStore.shared.setEligible(
                false,
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString()
            )
            return .failed(retryable: false)
        }
        let transactions = await toolLedger.toolTransactions(runId: job.runId)
        let visibleConversations = await job.conversationStore.appIntentSummaries(limit: nil)
        let supportsChatRetry = visibleConversations.contains {
            $0.id.toHexDashString().caseInsensitiveCompare(
                job.conversationId.toHexDashString()
            ) == .orderedSame
        }
        let retryable = Self.backgroundFailureIsRetryable(
            mode: job.mode,
            didSave: didSave,
            status: status,
            supportsChatRetry: supportsChatRetry,
            hasToolTransactions: transactions.map { !$0.isEmpty },
            hasCurrentRunTool: Self.hasToolInCurrentRun(finalMessages)
        )
        AgentActivityRetryEligibilityStore.shared.setEligible(
            retryable,
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString()
        )
        return .failed(retryable: retryable)
    }

    static func backgroundFailureIsRetryable(
        mode: IOSChatBackgroundHandoffMode,
        didSave: Bool,
        status: AgentRunStatus,
        supportsChatRetry: Bool,
        hasToolTransactions: Bool?,
        hasCurrentRunTool: Bool
    ) -> Bool {
        didSave
            && status == .failed
            && mode != .singleToolOnly
            && supportsChatRetry
            && hasToolTransactions == false
            && !hasCurrentRunTool
    }

    private static func hasToolInCurrentRun(_ messages: [UIMessage]) -> Bool {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return true
        }
        return messages[lastUserIndex...].contains { message in
            message.parts.contains { $0 is UIMessagePart.Tool }
        }
    }

}
