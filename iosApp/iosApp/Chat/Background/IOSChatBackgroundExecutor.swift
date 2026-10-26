@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    private func scheduleSubAgentTimeout(
        job: IOSChatBackgroundRuntimeJob,
        execution: IOSChatBackgroundExecution,
        runState: IOSChatBackgroundRunState
    ) {
        guard let seconds = job.subAgentTimeoutSeconds else { return }
        let requestId = execution.identifier
        subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
        let deadline = Date(timeIntervalSince1970: Double(job.startedAt) / 1_000 + seconds)
        let remaining = max(0, deadline.timeIntervalSinceNow)
        subAgentTimeoutTasks[requestId] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.activeBackgroundTasks[requestId] === execution,
                  runState.expireAndReserveTerminal(requireUnclaimed: true) == .persistFailure else { return }
            IOSPhoneControlController.shared.revoke(runID: job.runId)
            self.keepAlive.abandonSystemAssertion(self.chatBackgroundAudioLeaseId(for: requestId), preservingAdoptedTask: true)
            await runState.waitForExpiredOperationExit()
            await IOSPhoneControlController.shared.stop(runID: job.runId)
            guard self.activeBackgroundTasks[requestId] === execution,
                  runState.finalizeTerminal(as: .expiration) else { return }
            // The same ledger gate used by foreground recovery preserves any
            // already-started side effect as outcome-unknown before timing out.
            guard let prepared = await self.prepareOrdinaryJobForResume(job: job, requestId: requestId) else {
                if self.activeBackgroundTasks[requestId] === execution {
                    _ = await self.recordRun(job.runId, status: .recoveryPending,
                                            conversationId: job.conversationId)
                    self.releaseRuntimeOwnership(requestId: requestId)
                }
                return
            }
            IOSBackgroundLifecycleLog.record("subAgentTimedOut(run=\(job.runId.prefix(8)))")
            _ = await self.persistExpirationFailure(
                job: prepared, requestId: requestId,
                rawMessage: "子代理已达到运行时限（\(max(1, Int(ceil(seconds / 60)))) 分钟），已保存当前结果。可在子代理设置中调整超时后重试。",
                partialAssistantText: nil,
                terminalReason: IOSThreadOrchestrationToolService.modelRoutingTimeoutTerminalReason
            )
        }
    }

    func handle(_ backgroundTask: IOSChatBackgroundExecution) async {
        let mappedRunId = taskMap()[backgroundTask.identifier]
        // 先标记“系统已经把这一轮交回来了”，再做 payload 解码。冷启动扫尾
        // 可能和 handler 同时被调度；只要 handler 已经到达这里，就不能把它误判
        // 成 App Switcher 强杀留下的 stale request。
        activeBackgroundTasks[backgroundTask.identifier] = backgroundTask
        guard let job = job(for: backgroundTask.identifier) else {
            backgroundTask.updateTitle(
                IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
                subtitle: IOSAppLocalization.string("无法恢复任务", defaultValue: "无法恢复任务")
            )
            if let mappedRunId {
                let controller = dependencies?.liveActivityController ?? .shared
                _ = controller.adoptExistingActivity(runId: mappedRunId)
                guard await markRunInterrupted(
                    runId: mappedRunId,
                    reason: "background_payload_unavailable"
                ) else {
                    releaseRuntimeOwnership(requestId: backgroundTask.identifier)
                    return
                }
                await controller.end(runId: mappedRunId, presentation: .failed())
            }
            finish(requestId: backgroundTask.identifier)
            backgroundTask.setTaskCompleted(success: false)
            return
        }
        let runState = activeRunStates[backgroundTask.identifier] ?? IOSChatBackgroundRunState()
        activeRunStates[backgroundTask.identifier] = runState
        publishStateEvent(for: job)
        IOSBackgroundLifecycleLog.record(
            "bgTaskStarted(run=\(job.runId.prefix(8)))",
            detail: lifecycleSnapshotDetail
        )
        beginChatBackgroundKeepAlive(
            requestId: backgroundTask.identifier,
            subtitle: job.params.model.displayName
        )
        let assistantTextSnapshot = IOSChatBackgroundAssistantTextSnapshot()
        let progress = backgroundTask.progress
        let reportsPhoneWorkProgress = job.mode != .singleToolOnly
            && IOSPhoneControlController.shared.handoffState(runID: job.runId) != nil
        progress.totalUnitCount = reportsPhoneWorkProgress ? -1 : 4
        if reportsPhoneWorkProgress {
            _ = runState.claimPhoneToolResultProgress(in: job.uploadMessages)
        } else {
            progress.completedUnitCount = 0
        }
        backgroundTask.updateTitle(
            IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
            subtitle: IOSAppLocalization.string("准备上下文", defaultValue: "准备上下文")
        )
        _ = job.liveActivityController.adoptExistingActivity(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString()
        )
        backgroundTask.expirationHandler = { [weak self] in
            guard let self else {
                backgroundTask.setTaskCompleted(success: false)
                return
            }

            // `expirationHandler` is the last synchronous callback before iOS may
            // terminate the process. Reserve the terminal owner and claim the
            // system task here, before hopping to MainActor for persistence/UI
            // cleanup. Waiting for the hop can leave BGTask uncompleted at the
            // deadline, especially while the app is suspended.
            let claim = runState.expireAndReserveTerminal()
            if claim == .rejected {
                guard runState.terminalWasFinalized(by: .completion),
                      runState.claimSystemTaskCompletion() else { return }
                backgroundTask.setTaskCompleted(success: false)
                Task { @MainActor in
                    self.finish(requestId: backgroundTask.identifier)
                }
                return
            }
            guard runState.claimSystemTaskCompletion() else { return }
            backgroundTask.setTaskCompleted(success: false)

            Task { @MainActor in
                IOSPhoneControlController.shared.revoke(runID: job.runId)
                guard runState.finalizeTerminal(as: .expiration) else { return }
                IOSBackgroundLifecycleLog.record(
                    "bgTaskExpired(claim=\(claim))",
                    detail: self.lifecycleSnapshotDetail
                )
                switch claim {
                case .persistFailure:
                    let didPause = await self.persistExpirationPause(
                        job: job,
                        requestId: backgroundTask.identifier
                    )
                    if !didPause {
                        self.releaseRuntimeOwnership(requestId: backgroundTask.identifier)
                    }
                case .terminateInFlightSave:
                    // 会话写入已经开始，无法原子取消；由保存结果决定最终呈现，避免双终态。
                    break
                case .rejected:
                    self.finish(requestId: backgroundTask.identifier)
                }
            }
        }

        scheduleSubAgentTimeout(job: job, execution: backgroundTask, runState: runState)

        let requestProvider: ProviderSetting
        let requestParams: TextGenerationParams
        do {
            requestProvider = try await IOSGrokWebProviderResolver.resolved(
                try await IOSCodexProviderResolver.resolved(job.providerSetting)
            )
            requestParams = IOSGrokWebProviderResolver.augmentParamsForGrok(
                IOSCodexProviderResolver.augmentParamsForCodex(job.params, provider: requestProvider),
                provider: requestProvider
            )
        } catch {
            await fail(
                job: job,
                backgroundTask: backgroundTask,
                runState: runState,
                rawMessage: (error as NSError).localizedDescription
            )
            return
        }

        let runningPresentation = job.mode == .singleToolOnly
            ? AgentActivityPresentation.runningTool(toolName: "generate_image")
            : AgentActivityPresentation.response(
                stage: AgentActivityResponseStagePolicy.initialStage
            )
        await publishRunningPresentation(runningPresentation, for: job, runState: runState)

        if !reportsPhoneWorkProgress { progress.completedUnitCount = 1 }
        backgroundTask.updateTitle(
            IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
            subtitle: IOSAppLocalization.string(
                job.mode == .singleToolOnly ? "正在执行工具" : "正在生成回复",
                defaultValue: job.mode == .singleToolOnly ? "正在执行工具" : "正在生成回复"
            )
        )

        let presentationEvents = AsyncStream<AgentActivityPresentation>.makeStream()
        func makeExecutors(_ params: TextGenerationParams) -> [String: any IOSToolExecutor] {
            let executors = job.toolRuntime.backgroundToolExecutors(
                providerSetting: requestProvider,
                params: params,
                runId: job.runId,
                toolExposureBridge: job.toolExposureBridge,
                conversationId: job.conversationId,
                messages: job.displayMessages,
                executionPolicy: job.executionPolicy,
                dynamicToolSnapshot: job.dynamicToolSnapshot
            )
            return Self.routingPhoneActivity(
                executors: executors,
                runID: job.runId,
                events: presentationEvents.continuation
            )
        }
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: makeExecutors(requestParams),
            configuration: Self.backgroundToolLoopConfiguration,
            ledger: toolLedger,
            ledgerRunId: job.runId,
            phoneAutomaticReasoning: job.phoneAutomaticReasoning,
            phoneSessionIsActive: { @MainActor @Sendable runID in
                let controller = IOSPhoneControlController.shared
                return controller.handoffState(runID: runID) != nil
                    && controller.hasRequestedSession(runID: runID)
            },
            // tool_search changes visibility each round. Rebuilt phone executors must use
            // the same presentation queue as the initially registered executors.
            executorRebuilder: makeExecutors
        )
        // P1-d: 后台引擎 mailbox drain——每轮批量执行后，或纯文本终态收口前，
        // 把本会话信封渲染折入下一轮 upload 并持久化进会话（后台无 UI 上屏，
        // 折入 = 持久化 + 入 working）。
        // 前后台双 drain 由 MailboxDao.drainPending 的事务加固兜底（loser 返回空）。
        let mailboxStore = IOSMailboxStore(mailboxDao: self.db.mailboxDao())
        let mailboxDrain: @Sendable () async -> IOSMailboxDrainResult = { [weak self] in
            guard let self else { return IOSMailboxDrainResult(values: []) }
            // 渲染 + 会话持久化全部在 MainActor 助手内完成（KMP UIMessage 非
            // Sendable，不跨隔离边界传递实体）；返回盒携带渲染出的 user 消息。
            return await self.drainMailboxForBackgroundJob(
                store: job.conversationStore,
                mailboxStore: mailboxStore,
                conversationId: job.conversationId
            )
        }
        let presentationConsumer = Task { @MainActor in
            for await presentation in presentationEvents.stream {
                await self.publishRunningPresentation(
                    presentation,
                    for: job,
                    runState: runState
                )
            }
        }
        // P2-c: 后台流 citation 隐藏标记剥离。每个 engine.run 一个 tracker
        // （finish 幂等收口该 run 的未闭合标签；generative UI retry 是第二次
        // 独立生成，不共享 tracker——跨 run 复用会把上一 run 的 citations 串进
        // 下一 run）。引擎终结处已把剩余可见文本并入终态消息；run 结束后这里在
        // MainActor 上把收集到的引用 id 落 markUsed——引用是模型显式信号 →
        // force（不受 P2-b 召回同集去抖影响）。
        let initialCitationTracker = IOSMemoryCitationTracker(enforceCitationAllowlist: true)
        let retryCitationTracker = IOSMemoryCitationTracker(enforceCitationAllowlist: true)
        let budgetSettings = dependencies?.sharedSettings.snapshot
        func uploadPreparer(
            params: TextGenerationParams
        ) -> (@Sendable ([UIMessage]) async throws -> [UIMessage])? {
            guard let budgetSettings else { return nil }
            let preparer = IOSChatBackgroundUploadPreparer(settings: budgetSettings, params: params)
            return { try await preparer.prepare($0) }
        }
        let initialUploadPreparer = uploadPreparer(params: requestParams)
        let recordModelText: @Sendable (String) -> Void = { [weak self] text in
            if !text.isEmpty { Self.noteVisibleProgress(runState, job: job) }
            assistantTextSnapshot.replace(with: text)
            if reportsPhoneWorkProgress, runState.claimPhoneContentProgress(text) {
                self?.reportPhoneWorkProgress(units: 1, runId: job.runId, requestId: backgroundTask.identifier,
                                              runState: runState, execution: backgroundTask)
            }
        }
        let recordModelReasoning: (@Sendable (String) -> Void)?
        if reportsPhoneWorkProgress {
            recordModelReasoning = { [weak self] reasoning in
                if runState.claimPhoneContentProgress(reasoning, reasoning: true) {
                    Self.noteVisibleProgress(runState, job: job)
                    self?.reportPhoneWorkProgress(units: 1, runId: job.runId, requestId: backgroundTask.identifier,
                                                  runState: runState, execution: backgroundTask)
                }
            }
        } else {
            recordModelReasoning = nil
        }
        let recordToolResults: @Sendable ([UIMessage]) -> Void = { [weak self] messages in
            guard reportsPhoneWorkProgress else { return }
            let units = runState.claimPhoneToolResultProgress(in: messages)
            self?.reportPhoneWorkProgress(units: units, runId: job.runId, requestId: backgroundTask.identifier,
                                          runState: runState, execution: backgroundTask)
        }
        let operationTask = Task { () -> IOSAgentToolEngineResult in
            switch job.mode {
            case .continueModel, .resumeResponse:
                let initialResult = await engine.run(
                    providerSetting: requestProvider,
                    messages: job.uploadMessages,
                    params: requestParams,
                    citationTracker: initialCitationTracker,
                    toolExposureBridge: job.toolExposureBridge,
                    mailboxDrain: mailboxDrain,
                    prepareRequestMessages: initialUploadPreparer,
                    onAssistantTurnStarted: {
                        runState.resetGenerationRound()
                        assistantTextSnapshot.replace(with: "")
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.response(
                                stage: AgentActivityResponseStagePolicy.initialStage
                            )
                        )
                    },
                    onToolExecutionStarted: { toolName, input in
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.runningTool(toolName: toolName, input: input)
                        )
                    },
                    onAssistantStage: { stage in
                        if stage == .thinking || stage == .generating {
                            Self.noteVisibleProgress(runState, job: job)
                        }
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.response(stage: stage)
                        )
                    },
                    onAssistantText: recordModelText,
                    onAssistantReasoning: recordModelReasoning,
                    onMessagesUpdated: { messages in
                        recordToolResults(messages)
                        job.messagesSnapshot.replace(with: messages)
                    }
                )
                guard !job.generativeUiFallbackAttempted,
                      !initialResult.wasCancelled,
                      !Task.isCancelled,
                      initialResult.providerFailureMessage == nil || initialResult.hitOutputLimit,
                      initialResult.pendingApproval == nil,
                      initialResult.toolOutcomeUnknown == nil,
                      !initialResult.hitStepLimit,
                      !initialResult.guardStopped,
                      !job.toolRuntime.hasUnresolvedToolCall(in: initialResult.messages),
                      let widgetIssue = IOSGenerativeUiRequestPolicy.widgetIssue(
                        in: initialResult.messages,
                        afterDisplayMessageCount: job.uploadMessages.count,
                        requirement: job.generativeUiRequirement
                      ) else {
                    return initialResult
                }
                let retryBase = IOSGenerativeUiRequestPolicy.retryBaseMessages(initialResult.messages)
                let retryDisplayMessages = Self.reconciledMessages(
                    resultMessages: retryBase,
                    uploadMessageCount: job.uploadMessages.count,
                    displayMessages: job.displayMessages
                )
                let retryMessages = IOSGenerativeUiRequestPolicy.retryMessages(
                    retryBase,
                    requirement: job.generativeUiRequirement,
                    issue: widgetIssue
                )
                let retryParams = IOSGenerativeUiRequestPolicy.retryParams(requestParams)
                let transcriptCapabilities = PromptTranscriptCapabilities.companion.resolve(
                    setting: requestProvider,
                    model: retryParams.model
                )
                let retryUpload = IOSChatBackgroundRetryMessages(
                    values: transcriptCapabilities.systemUpdates
                        ? retryMessages
                        : ChatRuntimeContextBuilder.coalescingSystemMessages(retryMessages)
                )
                let retryUploadMessageCount = retryUpload.values.count
                guard self.persistGenerativeUiRetryCheckpoint(
                    for: job,
                    requestId: backgroundTask.identifier,
                    uploadMessages: retryUpload.values,
                    displayMessages: retryDisplayMessages,
                    params: retryParams
                ) else {
                    return IOSAgentToolEngineResult(
                        messages: initialResult.messages,
                        stepsExecuted: initialResult.stepsExecuted,
                        pendingApproval: initialResult.pendingApproval,
                        hitStepLimit: initialResult.hitStepLimit,
                        providerFailureMessage: IOSAppLocalization.string(
                            "Unable to persist the required visual retry checkpoint.",
                            defaultValue: "Unable to persist the required visual retry checkpoint."
                        ),
                        durabilityFailureMessage: initialResult.durabilityFailureMessage,
                        toolOutcomeUnknown: initialResult.toolOutcomeUnknown,
                        hitOutputLimit: initialResult.hitOutputLimit,
                        wasCancelled: initialResult.wasCancelled,
                        guardStopped: initialResult.guardStopped
                    )
                }
                let retryResult = await engine.run(
                    providerSetting: requestProvider,
                    messages: retryUpload.values,
                    params: retryParams,
                    citationTracker: retryCitationTracker,
                    toolExposureBridge: job.toolExposureBridge,
                    mailboxDrain: mailboxDrain,
                    prepareRequestMessages: uploadPreparer(params: retryParams),
                    onAssistantTurnStarted: {
                        runState.resetGenerationRound()
                        assistantTextSnapshot.replace(with: "")
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.response(
                                stage: AgentActivityResponseStagePolicy.initialStage
                            )
                        )
                    },
                    onToolExecutionStarted: { toolName, input in
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.runningTool(toolName: toolName, input: input)
                        )
                    },
                    onAssistantStage: { stage in
                        if stage == .thinking || stage == .generating {
                            Self.noteVisibleProgress(runState, job: job)
                        }
                        presentationEvents.continuation.yield(
                            AgentActivityPresentation.response(stage: stage)
                        )
                    },
                    onAssistantText: recordModelText,
                    onAssistantReasoning: recordModelReasoning,
                    onMessagesUpdated: { messages in
                        recordToolResults(messages)
                        job.messagesSnapshot.replace(
                            with: retryBase + Array(messages.dropFirst(retryUploadMessageCount))
                        )
                    }
                )
                return IOSAgentToolEngineResult(
                    messages: retryBase + Array(retryResult.messages.dropFirst(retryUploadMessageCount)),
                    stepsExecuted: retryResult.stepsExecuted,
                    pendingApproval: retryResult.pendingApproval,
                    hitStepLimit: retryResult.hitStepLimit,
                    providerFailureMessage: retryResult.providerFailureMessage,
                    durabilityFailureMessage: retryResult.durabilityFailureMessage,
                    toolOutcomeUnknown: retryResult.toolOutcomeUnknown,
                    hitOutputLimit: retryResult.hitOutputLimit,
                    wasCancelled: retryResult.wasCancelled,
                    guardStopped: retryResult.guardStopped
                )
            case .singleToolOnly:
                return await engine.executePreExistingToolsOnly(messages: job.uploadMessages)
            }
        }
        runState.installOperationTask(operationTask)
        let result = await operationTask.value
        job.messagesSnapshot.replace(with: result.messages)
        // P2-c: 引擎终结处 finish() 已把引用 id 收齐（幂等）；模型显式引用 →
        // markUsed(force: true)，与前台 citation flush 同语义。空集合 no-op。
        IOSMemoryPersistence.shared.markUsed(ids: initialCitationTracker.citationIds, force: true)
        IOSMemoryPersistence.shared.markUsed(ids: retryCitationTracker.citationIds, force: true)
        presentationEvents.continuation.finish()
        await presentationConsumer.value
        runState.clearOperationTask()
        guard runState.reserveTerminal() else { return }
        // Keep background execution through the return to Amber and runner teardown.
        await IOSPhoneControlController.shared.stop(
            runID: job.runId,
            returnToAmber: !result.wasCancelled && result.toolOutcomeUnknown == nil && result.durabilityFailureMessage == nil
        )

        if !reportsPhoneWorkProgress { progress.completedUnitCount = 3 }
        backgroundTask.updateTitle(
            IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
            subtitle: IOSAppLocalization.string("正在保存结果", defaultValue: "正在保存结果")
        )

        var reconciledMessages = job.mode == .continueModel
            ? Self.reconciledMessages(
                resultMessages: result.messages,
                uploadMessageCount: job.uploadMessages.count,
                displayMessages: job.displayMessages
            )
            : result.messages
        var generativeUiRepairFailed = false
        if job.mode == .continueModel,
           IOSGenerativeUiRequestPolicy.widgetIssue(
               in: reconciledMessages,
               afterDisplayMessageCount: job.displayMessages.count,
               requirement: job.generativeUiRequirement
           ) != nil {
            reconciledMessages = IOSGenerativeUiRequestPolicy.terminalRepairFailureMessages(
                reconciledMessages
            )
            generativeUiRepairFailed = true
        } else if job.mode == .continueModel {
            reconciledMessages = IOSGenerativeUiRequestPolicy.terminalRepairSuccessMessages(
                reconciledMessages
            )
        }
        let generatedSuffix = job.mode == .continueModel
            ? Array(reconciledMessages.dropFirst(job.displayMessages.count))
            : []
        if job.mode == .continueModel, result.hitOutputLimit {
            await completeTruncatedAfterTerminalReservation(
                job: job,
                backgroundTask: backgroundTask,
                runState: runState,
                reconciledMessages: reconciledMessages
            )
            return
        }
        if let rawFailure = result.durabilityFailureMessage {
            await failAfterTerminalReservation(
                job: job,
                backgroundTask: backgroundTask,
                runState: runState,
                terminalOwner: .completion,
                rawMessage: rawFailure,
                preservedGeneratedSuffix: generatedSuffix,
                partialAssistantText: assistantTextSnapshot.text,
                requiresRecovery: true
            )
            return
        }
        if let unknown = result.toolOutcomeUnknown {
            await completeOutcomeUnknownAfterTerminalReservation(
                job: job,
                backgroundTask: backgroundTask,
                runState: runState,
                messages: reconciledMessages,
                signal: unknown
            )
            return
        }
        if job.mode == .continueModel, let rawFailure = result.providerFailureMessage {
            await failAfterTerminalReservation(
                job: job,
                backgroundTask: backgroundTask,
                runState: runState,
                terminalOwner: .completion,
                rawMessage: rawFailure,
                preservedGeneratedSuffix: Array(generatedSuffix.dropLast()),
                partialAssistantText: assistantTextSnapshot.text
            )
            return
        }

        var finalMessages = reconciledMessages.applyingLastAssistantGenerationDuration(
            runState.generationDuration()
        )
        if job.mode == .continueModel,
           job.toolRuntime.hasUnresolvedToolCall(in: finalMessages) {
            finalMessages = job.toolRuntime.messagesByFailingPendingToolCalls(
                in: finalMessages,
                failureReason: IOSAppLocalization.string(
                    "The tool was unavailable during background continuation.",
                    defaultValue: "The tool was unavailable during background continuation."
                )
            )
        }
        if job.mode == .continueModel, result.hitStepLimit {
            finalMessages.append(Self.assistantMessage(IOSAppLocalization.string(
                "后台生成已达到工具循环上限，已保存当前结果。",
                defaultValue: "后台生成已达到工具循环上限，已保存当前结果。"
            )))
        }
        // I-5: same visibility contract as the hitStepLimit notice above — the
        // engine already wrote a per-tool stop explanation into that tool's
        // output; this appends a chat-level notice so the user does not read
        // the transcript as an ordinary, uninterrupted completion.
        //
        // F6 fix: this notice alone used to be the ONLY trace of the stop —
        // the terminal status below still recorded "completed" and published
        // `.completed()`/`publishCompleted`, so Watch/LiveActivity/`agent_run`
        // all read this as an ordinary successful finish. That is I-5 failing
        // silently specifically on the background path (the foreground
        // sibling, `terminatePendingToolCalls`, records shared status `failed`
        // and publishes `.failed()`). Capture the notice text here so the
        // terminal-status block below can align background with foreground.
        var guardStoppedNotice: String?
        if job.mode == .continueModel, result.guardStopped {
            let notice = IOSAppLocalization.string(
                "模型连续以相同参数重复调用工具，已停止本轮以避免空耗，已保存当前结果。",
                defaultValue: "模型连续以相同参数重复调用工具，已停止本轮以避免空耗，已保存当前结果。"
            )
            finalMessages.append(Self.assistantMessage(notice))
            guardStoppedNotice = notice
        }
        let emptyMiniAppResponse = job.mode == .continueModel &&
            ChatRuntimeContextBuilder.miniAppTurnContext(in: job.displayMessages) != nil &&
            ChatGenerationSupport.isEmptyAssistantResponse(finalMessages)
        if emptyMiniAppResponse {
            finalMessages.append(ChatGenerationSupport.emptyMiniAppResponseNotice())
        }
        let miniAppApplication = job.mode == .continueModel
            ? job.saveMiniAppIfPresent?(finalMessages, job.conversationId)
            : nil
        if let miniAppApplication {
            finalMessages = miniAppApplication.messages
        }
        let miniAppFailed = emptyMiniAppResponse || miniAppApplication?.outcome == .failed
        let singleToolFailureReason = job.mode == .singleToolOnly
            ? ChatToolOutputFormatter.imageFailureReason(in: finalMessages)
            : nil
        let watchSummary = Self.backgroundSummary(from: finalMessages)

        let successfulGeneration = Self.backgroundTerminalStatus(
            didSave: true,
            singleToolFailureReason: singleToolFailureReason,
            guardStopped: guardStoppedNotice != nil,
            miniAppFailed: miniAppFailed,
            hitStepLimit: result.hitStepLimit,
            generativeUiRepairFailed: generativeUiRepairFailed
        ) == .completed
        if successfulGeneration {
            finalMessages = IOSIntelligentUITerminal.markCompleted(
                finalMessages, baseline: job.runDisplayBaseline, runID: job.runId
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
        if !didSave,
           let miniAppApplication,
           !miniAppApplication.rollback() {
            NSLog("[AmberChatBG] MiniApp rollback skipped because its persisted state changed")
        }
        if didSave,
           let miniAppApplication,
           !miniAppApplication.commit() {
            NSLog("[AmberChatBG] MiniApp transaction commit remains pending for cold-start reconciliation")
        }
        if didSave,
           let workspaceFailure = miniAppApplication?.syncWorkspaceAfterConversationPersistence() {
            finalMessages = workspaceFailure.messages
            _ = await job.conversationStore.replaceBackgroundMessage(
                workspaceFailure.replacementMessage,
                in: job.conversationId
            )
        }
        let runStatus = didSave
            ? Self.backgroundTerminalStatus(
                didSave: true,
                singleToolFailureReason: singleToolFailureReason,
                guardStopped: guardStoppedNotice != nil,
                miniAppFailed: miniAppFailed,
                hitStepLimit: result.hitStepLimit,
                generativeUiRepairFailed: generativeUiRepairFailed
            )
            : .recoveryPending
        guard await recordRun(
            job.runId,
            status: runStatus,
            conversationId: job.conversationId
        ) else {
            releaseRuntimeOwnership(requestId: backgroundTask.identifier)
            return
        }
        guard runState.finalizeTerminal() else {
            if runState.terminalIsOwned(by: .expiration) {
                await publishExpiredInFlightSaveAfterRecordedRun(
                    job: job,
                    requestId: backgroundTask.identifier,
                    didSave: didSave,
                    recordedStatus: runStatus,
                    guardStoppedNotice: guardStoppedNotice,
                    miniAppFailed: miniAppFailed,
                    resultTitle: miniAppApplication?.resultTitle,
                    summary: watchSummary,
                    completedMessages: finalMessages
                )
            }
            return
        }
        guard didSave else {
            backgroundTask.updateTitle(
                IOSAppLocalization.string("Amber 后台生成", defaultValue: "Amber 后台生成"),
                subtitle: IOSAppLocalization.string("保存结果失败", defaultValue: "保存结果失败")
            )
            await completeAsFailureAfterSaveFailure(
                job: job,
                backgroundTask: backgroundTask
            )
            return
        }
        let succeeded = runStatus == .completed
        let terminalPresentation: AgentActivityPresentation
        if succeeded {
            terminalPresentation = .completed()
        } else {
            terminalPresentation = await backgroundFailurePresentation(
                job: job,
                didSave: didSave,
                status: runStatus,
                finalMessages: finalMessages
            )
        }
        await notifyRunTerminal(job: job, runId: job.runId, finalMessages: finalMessages)
        if succeeded {
            IOSMemoryExtractionCoordinator.shared.enqueue(
                conversationId: job.conversationId, baseline: job.runDisplayBaseline, completed: finalMessages
            )
            WatchTaskCoordinator.shared.publishCompleted(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                summary: watchSummary,
                resultTitle: miniAppApplication?.resultTitle
            )
            // 与前台 generationSucceeded → list preview 对齐：用本 job 的消息快照，不读可能已切换的 ChatViewModel。
            if let settings = dependencies?.sharedSettings {
                ConversationListPreviewGenerator.schedule(
                    conversationId: job.conversationId,
                    messages: finalMessages,
                    store: job.conversationStore,
                    settings: settings
                )
                job.conversationStore.recapGenerator.schedule(
                    conversationID: job.conversationId,
                    messages: finalMessages,
                    settings: settings
                )
            }
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: terminalPresentation,
                summary: guardStoppedNotice.flatMap { WatchTaskText.clipped($0, maxLength: 200) }
                    ?? (miniAppFailed ? watchSummary : nil)
            )
        }
        await job.liveActivityController.end(
            runId: job.runId,
            presentation: terminalPresentation
        )
        if progress.totalUnitCount >= 0 { progress.completedUnitCount = progress.totalUnitCount }
        if runState.claimSystemTaskCompletion() {
            finish(runId: job.runId, requestId: backgroundTask.identifier)
            backgroundTask.setTaskCompleted(success: succeeded)
        } else {
            removePayload(requestId: backgroundTask.identifier)
        }
    }

}
