@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    func resumeDetachedResponse(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        reconnectAttempt: Int = 0
    ) async {
        guard let openAI = job.providerSetting as? ProviderSetting.OpenAI,
              let responseId = job.responseId else {
            endChatBackgroundAudioKeepAlive(requestId: requestId)
            return
        }
        if Task.isCancelled {
            return
        }
        beginChatBackgroundKeepAlive(
            requestId: requestId,
            subtitle: job.params.model.displayName,
            submitSystemFallback: true
        )
        do {
            guard let snapshot = try await runStore.snapshot(runId: job.runId) else {
                endChatBackgroundAudioKeepAlive(requestId: requestId)
                return
            }
            guard await reconcileDetachedResponseLedgerBeforeResume(
                job: job,
                requestId: requestId
            ) else {
                endChatBackgroundAudioKeepAlive(requestId: requestId)
                return
            }
            if snapshot.status == .awaitingPermission {
                endChatBackgroundAudioKeepAlive(requestId: requestId)
                return
            }
            if snapshot.status == .recoveryPending {
                guard try await runStore.transition(
                    runId: job.runId,
                    expected: .recoveryPending,
                    to: .running
                ) else {
                    endChatBackgroundAudioKeepAlive(requestId: requestId)
                    return
                }
            } else if snapshot.status != .running {
                finish(runId: job.runId, requestId: requestId)
                return
            }
        } catch {
            endChatBackgroundAudioKeepAlive(requestId: requestId)
            return
        }
        let runState = activeRunStates[requestId] ?? IOSChatBackgroundRunState()
        activeRunStates[requestId] = runState
        runState.resetGenerationRound()
        await publishRunningPresentation(
            AgentActivityPresentation.response(stage: .preparing),
            for: job,
            runState: runState
        )
        let accumulator = makeDetachedResponseAccumulator(job: job)
        let transcriptRequest: PromptTranscriptRequest? = {
            let capabilities = PromptTranscriptCapabilities.companion.resolve(
                setting: job.providerSetting,
                model: job.params.model
            )
            guard capabilities.systemUpdates else { return nil }
            return PromptTranscript.shared.prepare(
                canonicalMessages: job.displayMessages,
                preparedMessages: job.uploadMessages,
                tools: job.params.tools
            )
        }()
        let completion = IOSChatDurableResumeCompletion()
        activeDetachedResponseCompletions[requestId] = completion
        let transport = IOSSharedKmpProviders.openAIBackgroundTransport
        let outcome = await withCheckedContinuation { continuation in
            completion.install(continuation)
            do {
                let streamJob = try transport.resumeBackground(
                    providerSetting: openAI,
                    responseId: responseId,
                    startingAfter: 0,
                    customHeaders: job.params.customHeaders,
                    onChunk: { chunk in
                        if ChatGenerationSpeedClock.chunkHasVisibleContent(chunk) {
                            Self.noteVisibleProgress(runState, job: job)
                        }
                        accumulator.append(chunk)
                        if let candidate = Self.resumePresentationStage(for: chunk),
                           let stage = runState.nextPresentationStage(candidate) {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                guard runState.shouldPublishPresentationStage(stage) else { return }
                                await self.publishRunningPresentation(
                                    AgentActivityPresentation.response(stage: stage),
                                    for: job,
                                    runState: runState
                                )
                            }
                        }
                    },
                    onCheckpoint: { _, sequenceNumber in
                        accumulator.recordCheckpoint(sequenceNumber: sequenceNumber.int64Value)
                    },
                    onComplete: {
                        completion.resolve(.completed)
                    },
                    onDisconnected: { error in
                        completion.resolve(.disconnected(error.message ?? String(describing: error)))
                    },
                    onFailure: { error in
                        completion.resolve(.failed(error.message ?? String(describing: error)))
                    }
                )
                activeDetachedResponseJobs[requestId] = streamJob
            } catch {
                completion.resolve(.failed((error as NSError).localizedDescription))
            }
        }

        activeDetachedResponseJobs.removeValue(forKey: requestId)
        activeDetachedResponseCompletions.removeValue(forKey: requestId)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .completed:
            var messages = IOSIntelligentUITerminal.markSourcesPending(
                accumulator.messages, baseline: job.displayMessages, runID: job.runId
            )
            if let transcriptRequest,
               let index = messages.indices.reversed().first(where: {
                   $0 >= job.displayMessages.count && messages[$0].role == MessageRole.assistant
               }) {
                messages[index] = PromptTranscript.shared.recordResponse(
                    message: messages[index],
                    request: transcriptRequest
                )
            }
            job.messagesSnapshot.replace(with: messages)
            if job.toolRuntime.hasUnresolvedToolCall(in: messages) {
                if !continueCompletedDetachedResponse(job: job, requestId: requestId, messages: messages) {
                    _ = checkpointDurableResponse(durableResponseHandoff(for: job))
                    activeJobs[requestId] = job
                    guard runState.reserveTerminal() else { return }
                    let didSave = await persistExpirationFailure(
                        job: job,
                        requestId: requestId,
                        rawMessage: IOSAppLocalization.string(
                            "回复已恢复，但工具阶段未能继续，请重试。",
                            defaultValue: "回复已恢复，但工具阶段未能继续，请重试。"
                        ),
                        partialAssistantText: nil
                    )
                    guard runState.finalizeTerminal() else { return }
                    if !didSave {
                        activeRunStates[requestId] = IOSChatBackgroundRunState()
                    }
                }
                return
            }
            guard runState.reserveTerminal() else { return }
            await completeDetachedResponse(
                job: job,
                requestId: requestId,
                messages: messages,
                runState: runState
            )
        case .failed(let message):
            guard runState.reserveTerminal() else { return }
            let didSave = await persistExpirationFailure(
                job: job,
                requestId: requestId,
                rawMessage: message,
                partialAssistantText: nil
            )
            guard runState.finalizeTerminal() else { return }
            if !didSave {
                activeRunStates[requestId] = IOSChatBackgroundRunState()
            }
        case .disconnected(let message):
            if reconnectAttempt == 0 {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await resumeDetachedResponse(
                    job: job,
                    requestId: requestId,
                    reconnectAttempt: 1
                )
                return
            }
            guard runState.reserveTerminal() else { return }
            let didSave = await persistExpirationFailure(
                job: job,
                requestId: requestId,
                rawMessage: message.isEmpty
                    ? IOSAppLocalization.string(
                        "后台回复连接中断，请重试。",
                        defaultValue: "后台回复连接中断，请重试。"
                    )
                    : message,
                partialAssistantText: nil
            )
            guard runState.finalizeTerminal() else { return }
            if didSave {
                cancelRemoteResponse(for: job)
            } else {
                // Keep a visible/cancellable owner. A future foreground entry
                // may retry the same response after storage becomes writable.
                activeRunStates[requestId] = IOSChatBackgroundRunState()
            }
        }
    }

    func makeDetachedResponseAccumulator(job: IOSChatBackgroundRuntimeJob) -> IOSChatDurableResponseAccumulator {
        IOSChatDurableResponseAccumulator(
            displayMessages: job.displayMessages, model: job.params.model,
            messagesSnapshot: job.messagesSnapshot
        )
    }

    /// Transfers a completed server response to this same run's local tool loop.
    func continueCompletedDetachedResponse(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        messages: [UIMessage]
    ) -> Bool {
        let generatedSuffix = Array(messages.dropFirst(job.displayMessages.count))
        let nextHandoff = IOSChatBackgroundHandoff(
            runId: job.runId,
            startedAt: job.startedAt,
            inputDigest: job.inputDigest,
            conversationId: job.conversationId,
            providerId: job.providerSetting.id.toHexDashString(),
            providerSetting: job.providerSetting,
            params: job.params,
            uploadMessages: job.uploadMessages + generatedSuffix,
            displayMessages: messages,
            mode: .continueModel,
            generativeUiRequirement: job.generativeUiRequirement,
            generativeUiFallbackAttempted: job.generativeUiFallbackAttempted,
            fullToolNames: job.toolExposureBridge.fullToolDeclarations().map(\.name),
            dynamicToolSnapshot: job.dynamicToolSnapshot,
            executionPolicy: job.executionPolicy,
            subAgentTimeoutSeconds: job.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: job.phoneAutomaticReasoning,
            runDisplayBaseline: job.runDisplayBaseline
        )
        guard job.mode == .resumeResponse,
              let current = activeJobs[requestId],
              current.runId == job.runId, current.mode == .resumeResponse,
              current.responseId == job.responseId,
              taskMap()[requestId] == job.runId,
              activeBackgroundTasks[requestId] == nil else { return false }
        return persistAndStartLocalExecution(
            handoff: nextHandoff, requestId: requestId, conversationStore: job.conversationStore,
            toolRuntime: job.toolRuntime, liveActivityController: job.liveActivityController,
            saveMiniAppIfPresent: job.saveMiniAppIfPresent
        )
    }

    /// AppShell normally performs W3 before starting a detached response. Keep
    /// the same ledger gate here as a cold-start race guard: a hydrated
    /// `resumeResponse` payload must never resume the server response while a
    /// side-effect tool is still `started` or already `outcomeUnknown`.
    func reconcileDetachedResponseLedgerBeforeResume(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String
    ) async -> Bool {
        toolRecoveryInFlightRequestIds.insert(requestId)
        defer { toolRecoveryInFlightRequestIds.remove(requestId) }
        let messages = await job.conversationStore.messages(for: job.conversationId)
            ?? job.messagesSnapshot.messages
        guard let plan = await IOSRunRecovery.planToolCallRecovery(
            runId: job.runId,
            messages: messages,
            dao: db.agentRuntimeDao()
        ) else {
            // A ledger lookup failure is not evidence that the response is
            // safe to resume. Leave the durable owner for a later W3 retry.
            return false
        }
        guard !plan.isEmpty else {
            return true
        }

        let unknownToolCallIds = plan.actions.compactMap { toolCallId, action -> String? in
            action == .markUnknown ? toolCallId : nil
        }
        let recoveredMessages = IOSToolCallRecoveryApplier.apply(plan, to: messages)
        job.messagesSnapshot.replace(with: recoveredMessages)
        // This patches the conversation just read, so its transaction base is
        // that snapshot; the original run baseline belongs to full terminal merges.
        let didSave = await job.conversationStore.saveBackgroundCompletion(
            baseMessages: messages,
            completedMessages: recoveredMessages,
            to: job.conversationId
        )
        guard didSave else {
            if !unknownToolCallIds.isEmpty {
                _ = try? await runStore.transitionFromAnyActive(
                    runId: job.runId,
                    to: .recoveryPending,
                    detail: "tool_outcome_unknown"
                )
                WatchTaskCoordinator.shared.publish(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString(),
                    presentation: .failed(),
                    summary: IOSAppLocalization.string(
                        "操作结果尚未保存，请在 iPhone 恢复。",
                        defaultValue: "操作结果尚未保存，请在 iPhone 恢复。"
                    )
                )
                await job.liveActivityController.end(
                    runId: job.runId,
                    presentation: .failed()
                )
                releaseRuntimeOwnership(requestId: requestId)
            }
            return false
        }
        await IOSRunRecovery.finalizeToolCallRecovery(
            runId: job.runId,
            plan: plan,
            dao: db.agentRuntimeDao()
        )

        guard !unknownToolCallIds.isEmpty else {
            return true
        }

        IOSPhoneControlController.shared.revoke(runID: job.runId)
        guard (try? await runStore.transitionFromAnyActive(
            runId: job.runId,
            to: .outcomeUnknown,
            detail: "tool_outcome_unknown"
        )) == true else {
            releaseRuntimeOwnership(requestId: requestId)
            return false
        }
        outcomeUnknownRequestIds.insert(requestId)
        var unknownDescriptors: [IOSToolOutcomeUnknownDescriptor] = []
        for toolCallId in unknownToolCallIds.sorted() {
            guard let toolName = recoveredMessages
                .flatMap(\.parts)
                .compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: { $0.toolCallId == toolCallId })?.toolName
                ?? plan.toolNames[toolCallId] else { continue }
            let descriptor = IOSToolOutcomeUnknownDescriptor(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                toolCallId: toolCallId,
                toolName: toolName
            )
            unknownDescriptors.append(descriptor)
            onToolOutcomeUnknown?(descriptor)
        }
        if let descriptor = unknownDescriptors.first {
            _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
        } else {
            _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString()
            )
        }
        await job.liveActivityController.end(
            runId: job.runId,
            presentation: .failed()
        )
        finish(runId: job.runId, requestId: requestId)
        return false
    }

    /// Prepare an ordinary continuation from the last completed in-memory
    /// round before handing execution back to KeepAlive. The persisted payload
    /// contains only the handoff baseline; `messagesSnapshot` is the only
    /// process-local record of a completed provider/tool round after that
    /// baseline. Save that display and checkpoint its upload before restarting
    /// the provider, so completed tool results remain part of the next round.
    func prepareOrdinaryJobForResume(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String
    ) async -> IOSChatBackgroundRuntimeJob? {
        toolRecoveryInFlightRequestIds.insert(requestId)
        defer { toolRecoveryInFlightRequestIds.remove(requestId) }

        // Keep the raw upload snapshot for the next provider round. It may
        // contain system/tool-context messages that are intentionally absent
        // from the user-visible display baseline.
        let snapshotMessages = job.messagesSnapshot.messages
        guard let loadedPlan = await IOSRunRecovery.planToolCallRecovery(
            runId: job.runId,
            messages: snapshotMessages,
            dao: db.agentRuntimeDao()
        ), let transactions = await toolLedger.toolTransactions(runId: job.runId) else {
            // A missing ledger read is not proof that the run is safe to replay.
            return nil
        }

        var actions = loadedPlan.actions
        for transaction in transactions {
            guard let action = actions[transaction.toolCallId] else { continue }
            actions[transaction.toolCallId] = Self.ordinaryRecoveryAction(
                state: transaction.state,
                outcome: transaction.outcome,
                planned: action
            )
        }
        let plan = IOSToolCallRecoveryPlan(actions: actions, toolNames: loadedPlan.toolNames)
        let unknownToolCallIds = plan.actions.compactMap { toolCallId, action -> String? in
            Self.isOutcomeUnknownRecoveryAction(action) ? toolCallId : nil
        }
        let recoveredUploadMessages = IOSIntelligentUITerminal.markSourcesPending(
            IOSToolCallRecoveryApplier.apply(plan, to: snapshotMessages),
            baseline: job.displayMessages,
            runID: job.runId
        )
        let recoveredDisplayMessages = IOSIntelligentUITerminal.markSourcesPending(
            Self.reconciledMessages(
                resultMessages: recoveredUploadMessages,
                uploadMessageCount: job.uploadMessages.count,
                displayMessages: job.displayMessages
            ),
            baseline: job.displayMessages,
            runID: job.runId
        )

        guard await job.conversationStore.saveBackgroundCompletion(
            baseMessages: job.runDisplayBaseline,
            completedMessages: recoveredDisplayMessages,
            to: job.conversationId
        ) else {
            _ = try? await runStore.transitionFromAnyActive(
                runId: job.runId,
                to: .recoveryPending,
                detail: "background_recovery_save_failed"
            )
            return nil
        }
        // Advance the upload/display checkpoint only after its display is
        // saved. On a save failure the old baseline remains retryable.
        if unknownToolCallIds.isEmpty {
            let handoff = IOSChatBackgroundHandoff(
                runId: job.runId,
                startedAt: job.startedAt,
                inputDigest: job.inputDigest,
                conversationId: job.conversationId,
                providerId: job.providerSetting.id.toHexDashString(),
                providerSetting: job.providerSetting,
                params: job.params,
                uploadMessages: recoveredUploadMessages,
                displayMessages: recoveredDisplayMessages,
                mode: .continueModel,
                generativeUiRequirement: job.generativeUiRequirement,
                generativeUiFallbackAttempted: job.generativeUiFallbackAttempted,
                fullToolNames: job.fullToolNames,
                dynamicToolSnapshot: job.dynamicToolSnapshot,
                executionPolicy: job.executionPolicy,
                subAgentTimeoutSeconds: job.subAgentTimeoutSeconds,
                phoneAutomaticReasoning: job.phoneAutomaticReasoning,
                runDisplayBaseline: job.runDisplayBaseline
            )
            do {
                try persist(handoff: handoff, requestId: requestId)
            } catch {
                NSLog("[AmberChatBG] Failed to persist recovery checkpoint: \(error)")
                return nil
            }
            let updatedJob = runtimeJob(
                handoff: handoff,
                conversationStore: job.conversationStore,
                toolRuntime: job.toolRuntime,
                liveActivityController: job.liveActivityController,
                saveMiniAppIfPresent: job.saveMiniAppIfPresent
            )
            activeJobs[requestId] = updatedJob
        }

        await IOSRunRecovery.finalizeToolCallRecovery(
            runId: job.runId,
            plan: plan,
            dao: db.agentRuntimeDao()
        )

        guard unknownToolCallIds.isEmpty else {
            IOSPhoneControlController.shared.revoke(runID: job.runId)
            guard (try? await runStore.transitionFromAnyActive(
                runId: job.runId,
                to: .outcomeUnknown,
                detail: "tool_outcome_unknown"
            )) == true else {
                return nil
            }
            outcomeUnknownRequestIds.insert(requestId)
            var unknownDescriptors: [IOSToolOutcomeUnknownDescriptor] = []
            for toolCallId in unknownToolCallIds.sorted() {
                guard let toolName = recoveredDisplayMessages
                    .flatMap(\.parts)
                    .compactMap({ $0 as? UIMessagePart.Tool })
                    .first(where: { $0.toolCallId == toolCallId })?.toolName
                    ?? plan.toolNames[toolCallId] else { continue }
                let descriptor = IOSToolOutcomeUnknownDescriptor(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString(),
                    toolCallId: toolCallId,
                    toolName: toolName
                )
                unknownDescriptors.append(descriptor)
                onToolOutcomeUnknown?(descriptor)
            }
            if let descriptor = unknownDescriptors.first {
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
            } else {
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(
                    runId: job.runId,
                    conversationId: job.conversationId.toHexDashString()
                )
            }
            await job.liveActivityController.end(runId: job.runId, presentation: .failed())
            finish(runId: job.runId, requestId: requestId)
            return nil
        }

        return activeJobs[requestId] ?? job
    }

    static func ordinaryRecoveryAction(
        state: IOSToolTransactionState,
        outcome: String?,
        planned: IOSToolCallRecoveryAction
    ) -> IOSToolCallRecoveryAction {
        // The engine durably records this terminal before a tool executor is
        // entered. It is not a lost side-effect result and must remain
        // model-retryable after a cancellation race.
        if state == .finished,
           outcome == "cancelled_before_execution",
           planned == .markResultLost {
            return .markRetryable
        }
        return planned
    }

    static func isOutcomeUnknownRecoveryAction(
        _ action: IOSToolCallRecoveryAction
    ) -> Bool {
        if case .markUnknown = action { return true }
        return false
    }

    private func durableResponseHandoff(
        for job: IOSChatBackgroundRuntimeJob
    ) -> IOSChatBackgroundHandoff {
        IOSChatBackgroundHandoff(
            runId: job.runId,
            startedAt: job.startedAt,
            inputDigest: job.inputDigest,
            conversationId: job.conversationId,
            providerId: job.providerSetting.id.toHexDashString(),
            providerSetting: job.providerSetting,
            params: job.params,
            uploadMessages: job.uploadMessages,
            displayMessages: job.displayMessages,
            mode: .resumeResponse,
            responseId: job.responseId,
            responseSequenceNumber: job.responseSequenceNumber,
            generativeUiRequirement: job.generativeUiRequirement,
            generativeUiFallbackAttempted: job.generativeUiFallbackAttempted,
            fullToolNames: job.toolExposureBridge.fullToolDeclarations().map(\.name),
            dynamicToolSnapshot: job.dynamicToolSnapshot,
            executionPolicy: job.executionPolicy,
            subAgentTimeoutSeconds: job.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: job.phoneAutomaticReasoning,
            runDisplayBaseline: job.runDisplayBaseline
        )
    }

    private func cancelRemoteResponse(for job: IOSChatBackgroundRuntimeJob) {
        guard let openAI = job.providerSetting as? ProviderSetting.OpenAI,
              let responseId = job.responseId else { return }
        _ = try? IOSSharedKmpProviders.openAIBackgroundTransport.cancelBackground(
            providerSetting: openAI,
            responseId: responseId,
            customHeaders: job.params.customHeaders,
            onComplete: {},
            onError: { _ in }
        )
    }

    func cancelDetachedResponseTransport(
        requestId: String,
        job: IOSChatBackgroundRuntimeJob
    ) {
        activeDetachedResponseTasks[requestId]?.cancel()
        activeDetachedResponseJobs.removeValue(forKey: requestId)?.cancel(cause: nil)
        activeDetachedResponseCompletions.removeValue(forKey: requestId)?
            .resolve(.disconnected("cancelled"))
        cancelRemoteResponse(for: job)
    }

}
