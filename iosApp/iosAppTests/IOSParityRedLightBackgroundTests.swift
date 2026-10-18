import XCTest
@preconcurrency import Shared
@testable import iosApp

extension IOSParityRedLightTests {
    /// RED for P0. GREEN target: P5.
    /// Cell: chat.recover.
    /// RED for P0. GREEN target: P5 (now GREEN).
    /// Cell: chat.recover.
    ///
    /// A run killed mid-stream must be reclassified to an interrupted-or-
    /// resumable state — NOT silently lost or frozen as "running" forever. P5
    /// added `IOSRunRecovery.recoverInterruptedRuns()` — a descriptor-scoped
    /// startup sweep that claims non-terminal Chat rows with a CAS transition,
    /// so a killed run surfaces honestly on next launch.
    ///
    /// This test inserts a "running" row (simulating a mid-stream kill), runs
    /// the recovery sweep, then asserts the run was reclassified to
    /// interrupted/resumable (not still "running").
    func test_recovery_killMidStream_runInterruptedOrResumed() async throws {
        let db = IosDatabaseFactory.shared.createDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "redlight-recovery-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // Simulate the row that a start() would write mid-stream (P5 adds the
        // start-row write; here we inject it directly to model the killed state).
        let runningRow = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: "chat",
            agentVersion: "1",
            conversationId: nil,
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: "running",
            inputDigest: "digest-\(runId)",
            inputSnapshotRef: nil,
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: nil,
            interruptedReason: nil,
            terminalReason: nil,
            providerId: nil,
            modelId: nil,
            promptVersion: nil,
            toolCatalogVersion: nil,
            capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: runningRow) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }

        // On next launch, the recovery sweep (IOSRunRecovery.recoverInterruptedRuns)
        // reclassifies orphaned non-terminal rows to "interrupted". This is the
        // P5 parity target: a killed run surfaces as interrupted-or-resumable.
        _ = await IOSRunRecovery.recoverInterruptedRuns(reason: "process_killed", now: now)

        // After the sweep, the run must be reclassified — read its status.
        let recoveredStatus = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            dao.getRun(id: runId) { result, _ in
                cont.resume(returning: result?.status)
            }
        }

        // Parity target: after a kill + the recovery sweep, the run must be in an
        // interrupted-or-resumable state, not left frozen as "running".
        let isInterruptedOrResumed = recoveredStatus == "interrupted" || recoveredStatus == "resumed"
        XCTAssertTrue(
            isInterruptedOrResumed,
            "A run killed mid-stream must be reclassified to interrupted/resumable by the recovery "
                + "sweep, not left frozen as 'running'. Recovered status: \(recoveredStatus ?? "<nil>") (P5)."
        )
    }

    func test_recovery_preservesDurablyOwnedBackgroundRun() async throws {
        let dao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
        let runId = "background-owned-recovery-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let runningRow = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: "chat",
            agentVersion: "1",
            conversationId: "conversation-owned-by-background",
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: "running",
            inputDigest: "digest-\(runId)",
            inputSnapshotRef: nil,
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: nil,
            interruptedReason: nil,
            terminalReason: nil,
            providerId: nil,
            modelId: nil,
            promptVersion: nil,
            toolCatalogVersion: nil,
            capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: runningRow) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        _ = await IOSRunRecovery.recoverInterruptedRuns(
            excludingRunIds: [runId],
            reason: "process_killed",
            now: now
        )

        let status = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            dao.getRun(id: runId) { result, _ in
                continuation.resume(returning: result?.status)
            }
        }
        XCTAssertEqual(status, "running")

        _ = await IOSRunRecovery.recoverInterruptedRuns(
            reason: "test_cleanup",
            now: now
        )
    }

    func test_recovery_pendingApprovalCarriesExactToolOwnerBeforeInterruptingRun() async throws {
        let dao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
        let runId = "pending-approval-recovery-\(UUID().uuidString)"
        let conversationId = "conversation-\(UUID().uuidString)"
        let toolCallId = "tool-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let run = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: "chat",
            agentVersion: "1",
            conversationId: conversationId,
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: AgentRunStatus.awaitingPermission.wireName,
            inputDigest: "digest",
            inputSnapshotRef: "tool_call:\(toolCallId)",
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: nil,
            interruptedReason: nil,
            terminalReason: nil,
            providerId: nil,
            modelId: nil,
            promptVersion: nil,
            toolCatalogVersion: nil,
            capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let loadedDescriptors = await IOSRunRecovery.recoverPendingApprovalDescriptors()
        let descriptors = try XCTUnwrap(loadedDescriptors)
        let descriptor = try XCTUnwrap(descriptors.first { $0.runId == runId })
        XCTAssertEqual(descriptor.conversationId, conversationId)
        XCTAssertEqual(descriptor.toolCallId, toolCallId)
        let pendingStatus = await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            dao.getRun(id: runId) { result, _ in
                continuation.resume(returning: result?.status)
            }
        }
        XCTAssertEqual(pendingStatus, AgentRunStatus.awaitingPermission.wireName)

        await IOSRunRecovery.completePendingApprovalRecovery(runId: runId, now: now)
        let recoveredStatus = await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            dao.getRun(id: runId) { result, _ in
                continuation.resume(returning: result?.status)
            }
        }
        XCTAssertEqual(recoveredStatus, "interrupted")
    }

    func testBackgroundExpirationFailureMergesPartialAndFailureIntoSingleAssistantMessage() {
        let displayMessages = [UIMessage.companion.user(prompt: "question")]

        let messages = IOSChatBackgroundGenerationCoordinator.failedMessagesForTesting(
            displayMessages: displayMessages,
            partialAssistantText: "已经生成但尚未完成的正文",
            rawMessage: "后台生成被系统中断，可回到 App 后重试。",
            modelId: "test-model"
        )

        XCTAssertEqual(messages.map { $0.role }, [MessageRole.user, MessageRole.assistant])
        XCTAssertTrue(messages[1].toText().contains("已经生成但尚未完成的正文"))
        XCTAssertTrue(messages[1].toText().contains("后台生成被系统中断"))
        let errorPart = messages[1].parts.first as? UIMessagePart.Text
        XCTAssertEqual(
            errorPart?.metadata?[MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY]?.jsonPrimitiveOrNull?.content,
            MessageKt.LOCAL_GENERATION_ERROR_METADATA_VALUE
        )
    }

    func testBackgroundExpirationAtomicallyOwnsTheTerminalPath() {
        let expiredState = IOSChatBackgroundRunState()

        XCTAssertEqual(expiredState.expireAndReserveTerminal(), .persistFailure)
        XCTAssertTrue(expiredState.isExpired)
        XCTAssertEqual(expiredState.expireAndReserveTerminal(), .rejected)
        XCTAssertFalse(expiredState.reserveTerminal())

        let completedState = IOSChatBackgroundRunState()
        XCTAssertTrue(completedState.reserveTerminal())
        XCTAssertTrue(completedState.finalizeTerminal())
        XCTAssertEqual(completedState.expireAndReserveTerminal(), .rejected)
        XCTAssertFalse(completedState.isExpired)

        let cancelledState = IOSChatBackgroundRunState()
        XCTAssertTrue(cancelledState.cancelAndReserveTerminal())
        XCTAssertTrue(cancelledState.isExpired)
        XCTAssertFalse(cancelledState.reserveTerminal())
        XCTAssertFalse(cancelledState.cancelAndReserveTerminal())
    }

    func testBackgroundTerminalReservationStopsRunningPresentations() {
        let expiredState = IOSChatBackgroundRunState()
        let cancelledState = IOSChatBackgroundRunState()
        let completedState = IOSChatBackgroundRunState()

        XCTAssertEqual(completedState.nextPresentationStage(.thinking), .thinking)
        XCTAssertNil(completedState.nextPresentationStage(.thinking))
        XCTAssertEqual(completedState.nextPresentationStage(.generating), .generating)
        XCTAssertNil(completedState.nextPresentationStage(.thinking))
        XCTAssertFalse(completedState.shouldPublishPresentationStage(.thinking))
        XCTAssertTrue(completedState.shouldPublishPresentationStage(.generating))

        XCTAssertTrue(expiredState.allowsRunningPresentation)
        XCTAssertTrue(cancelledState.allowsRunningPresentation)
        XCTAssertTrue(completedState.allowsRunningPresentation)

        XCTAssertEqual(expiredState.expireAndReserveTerminal(), .persistFailure)
        XCTAssertTrue(cancelledState.cancelAndReserveTerminal())
        XCTAssertTrue(completedState.reserveTerminal())

        XCTAssertFalse(expiredState.allowsRunningPresentation)
        XCTAssertFalse(cancelledState.allowsRunningPresentation)
        XCTAssertFalse(completedState.allowsRunningPresentation)
        XCTAssertFalse(completedState.shouldPublishPresentationStage(.generating))
    }

    func testBackgroundCancellationCancelsTheInstalledOperationTask() {
        let state = IOSChatBackgroundRunState()
        let operationTask = Task {
            IOSAgentToolEngineResult(
                messages: [],
                stepsExecuted: 0,
                pendingApproval: nil,
                hitStepLimit: false
            )
        }
        state.installOperationTask(operationTask)

        XCTAssertTrue(state.cancelAndReserveTerminal())
        XCTAssertTrue(operationTask.isCancelled)
        XCTAssertFalse(state.reserveTerminal())
    }

    func testBackgroundCancellationCannotPreemptCompletionAfterSavingStarts() {
        let savingState = IOSChatBackgroundRunState()
        XCTAssertTrue(savingState.reserveTerminal())
        XCTAssertFalse(savingState.cancelAndReserveTerminal())
        XCTAssertTrue(savingState.finalizeTerminal())
        XCTAssertTrue(savingState.terminalWasFinalized(by: .completion))

        let committedState = IOSChatBackgroundRunState()
        XCTAssertTrue(committedState.reserveTerminal())
        XCTAssertTrue(committedState.finalizeTerminal())
        XCTAssertFalse(committedState.cancelAndReserveTerminal())
    }

    func testBackgroundExpirationPreemptsReservedTerminalAndOwnsFinalization() {
        let savingState = IOSChatBackgroundRunState()
        XCTAssertTrue(savingState.reserveTerminal())

        XCTAssertEqual(savingState.expireAndReserveTerminal(), .terminateInFlightSave)
        XCTAssertTrue(savingState.isExpired)
        XCTAssertTrue(savingState.terminalIsOwned(by: .expiration))
        XCTAssertFalse(savingState.terminalWasFinalized(by: .expiration))
        XCTAssertFalse(savingState.finalizeTerminal())
        XCTAssertTrue(savingState.finalizeTerminal(as: .expiration))
        XCTAssertTrue(savingState.terminalWasFinalized(by: .expiration))
        XCTAssertFalse(savingState.terminalWasFinalized(by: .completion))
    }

    func testBackgroundGuardStoppedMapsToSharedFailedStatusDuringExpirationSave() {
        let savingState = IOSChatBackgroundRunState()
        XCTAssertTrue(savingState.reserveTerminal())
        XCTAssertEqual(savingState.expireAndReserveTerminal(), .terminateInFlightSave)
        XCTAssertTrue(savingState.finalizeTerminal(as: .expiration))

        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: nil,
                guardStopped: true
            ),
            "failed"
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: "tool failed",
                guardStopped: true
            ),
            "failed"
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: "tool failed",
                guardStopped: false
            ),
            "failed"
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: false,
                singleToolFailureReason: nil,
                guardStopped: true
            ),
            AgentRunStatus.recoveryPending.wireName
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: nil,
                guardStopped: false,
                miniAppFailed: true
            ),
            "failed"
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: nil,
                guardStopped: false,
                hitStepLimit: true
            ),
            "failed"
        )
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.backgroundTerminalStatusForTesting(
                didSave: true,
                singleToolFailureReason: nil,
                guardStopped: false,
                generativeUiRepairFailed: true
            ),
            "failed"
        )
    }

    func testBackgroundRetryRequiresACommittedPureChatFailure() {
        let cases: [(IOSChatBackgroundHandoffMode, Bool, AgentRunStatus, Bool, Bool?, Bool, Bool)] = [
            (.continueModel, true, .failed, true, false, false, true),
            (.resumeResponse, true, .failed, true, false, false, true),
            (.continueModel, false, .recoveryPending, true, false, false, false),
            (.singleToolOnly, true, .failed, true, false, false, false),
            (.continueModel, true, .failed, false, false, false, false),
            (.continueModel, true, .failed, true, true, false, false),
            (.continueModel, true, .failed, true, nil, false, false),
            (.continueModel, true, .failed, true, false, true, false),
        ]

        for (mode, didSave, status, supportsChatRetry, hasToolTransactions, hasCurrentRunTool, expected) in cases {
            XCTAssertEqual(
                IOSChatBackgroundGenerationCoordinator.backgroundFailureIsRetryable(
                    mode: mode,
                    didSave: didSave,
                    status: status,
                    supportsChatRetry: supportsChatRetry,
                    hasToolTransactions: hasToolTransactions,
                    hasCurrentRunTool: hasCurrentRunTool
                ),
                expected
            )
        }
    }

    func testBackgroundSystemTaskCompletionCanOnlyBeClaimedOnce() {
        let state = IOSChatBackgroundRunState()

        XCTAssertTrue(state.claimSystemTaskCompletion())
        XCTAssertFalse(state.claimSystemTaskCompletion())
    }

    func testBackgroundProviderExposesRealStreamingCallbacks() {
        let provider: any IOSAgentTextProvider = IOSChatBackgroundProvider()

        XCTAssertTrue(provider is any IOSAgentStreamingProvider)
    }

    func testBackgroundProviderFailureKeepsCompletedSuffixAndCurrentPartial() {
        let displayMessages = [UIMessage.companion.user(prompt: "question")]
        let seed = UIMessage.companion.assistant(prompt: "")
        let completedToolTurn = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [UIMessagePart.Tool(
                toolCallId: "tool-1",
                toolName: "search_web",
                input: #"{"query":"amber"}"#,
                output: [UIMessagePart.Text(text: "tool result already completed", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )

        let messages = IOSChatBackgroundGenerationCoordinator.failedMessagesForTesting(
            displayMessages: displayMessages,
            preservedGeneratedSuffix: [completedToolTurn],
            partialAssistantText: "current round partial",
            rawMessage: "network error",
            modelId: "test-model"
        )

        XCTAssertEqual(messages.count, 3)
        let preservedTool = messages[1].parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(
            preservedTool?.output.compactMap { ($0 as? UIMessagePart.Text)?.text },
            ["tool result already completed"]
        )
        XCTAssertTrue(messages[2].toText().contains("current round partial"))
        XCTAssertTrue(messages[2].toText().contains("network"))
    }

    func testBackgroundCompletionReconcilesPreExecutedPrefixToolOutputsIntoDisplayMessages() {
        let user = UIMessage.companion.user(prompt: "question")
        let seed = UIMessage.companion.assistant(prompt: "")
        let pendingTool = UIMessagePart.Tool(
            toolCallId: "tool-1",
            toolName: "search_web",
            input: #"{"query":"amber"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let completedTool = UIMessagePart.Tool(
            toolCallId: pendingTool.toolCallId,
            toolName: pendingTool.toolName,
            input: pendingTool.input,
            output: [UIMessagePart.Text(text: "completed in background", metadata: nil)],
            approvalState: pendingTool.approvalState,
            streamIndex: pendingTool.streamIndex,
            metadata: nil
        )
        let pendingAssistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [pendingTool],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
        let completedAssistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [completedTool],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
        let runtimeSystem = UIMessage.companion.system(prompt: "runtime-only")
        let finalAnswer = UIMessage.companion.assistant(prompt: "final answer")

        let reconciled = IOSChatBackgroundGenerationCoordinator.reconciledMessagesForTesting(
            resultMessages: [runtimeSystem, user, completedAssistant, finalAnswer],
            uploadMessageCount: 3,
            displayMessages: [user, pendingAssistant]
        )

        XCTAssertEqual(reconciled.count, 3)
        XCTAssertEqual(reconciled[0].role, MessageRole.user)
        let tool = reconciled[1].parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(
            tool?.output.compactMap { ($0 as? UIMessagePart.Text)?.text },
            ["completed in background"]
        )
        XCTAssertEqual(reconciled[2].toText(), "final answer")
        XCTAssertFalse(reconciled.contains { $0.toText().contains("runtime-only") })
    }

    func testBackgroundSuccessBuildsWatchSummaryFromLastAssistantText() {
        let messages = [
            UIMessage.companion.user(prompt: "question"),
            UIMessage.companion.assistant(prompt: "first answer"),
            UIMessage.companion.assistant(prompt: String(repeating: "最终摘要", count: 80))
        ]

        let summary = IOSChatBackgroundGenerationCoordinator.backgroundSummaryForTesting(messages: messages)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.hasPrefix("最终摘要") == true)
        XCTAssertLessThanOrEqual(summary?.count ?? 0, 281)
    }

    func testBackgroundResumeRehydratesRuntimeHeadersFromCurrentSettingsModelAndAssistant() throws {
        let modelId = KotlinUuid.companion.random()
        let configuredModel = Model(
            modelId: "runtime-model",
            displayName: "Runtime Model",
            id: modelId,
            type: ModelType.chat,
            customHeaders: [CustomHeader(name: "X-Model-Token", value: "current-model-secret")],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Runtime Provider",
            models: [configuredModel],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "current-provider-secret",
            baseUrl: "https://example.com",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let persistedModel = Model(
            modelId: "runtime-model",
            displayName: "Runtime Model",
            id: modelId,
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let persistedParams = TextGenerationParams(
            model: persistedModel,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: ReasoningLevel.off,
            customHeaders: [],
            customBody: []
        )

        let resumed = try XCTUnwrap(
            IOSChatBackgroundGenerationCoordinator.rehydratedParamsForTesting(
                persistedParams: persistedParams,
                providerSetting: provider,
                assistantHeaders: [CustomHeader(name: "X-Assistant-Token", value: "current-assistant-secret")],
                assistantBodies: []
            )
        )

        XCTAssertEqual(
            Set(resumed.customHeaders.map(\.value)),
            Set(["current-assistant-secret", "current-model-secret"])
        )
        XCTAssertEqual(
            resumed.model.customHeaders.map(\.value),
            ["current-model-secret"]
        )
        XCTAssertNil(
            IOSChatBackgroundGenerationCoordinator.rehydratedParamsForTesting(
                persistedParams: persistedParams,
                providerSetting: makeOpenAIProvider(),
                assistantHeaders: [CustomHeader(name: "X-Assistant-Token", value: "other-secret")],
                assistantBodies: []
            ),
            "A resumed job must not borrow a same-named model from a different provider."
        )
    }

    func testBackgroundCoordinatorRetainsPayloadAfterTerminalSaveFailureForColdStartRecovery() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let executor = try String(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundExecutor.swift"),
            encoding: .utf8
        )
        let terminalWriter = try String(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift"),
            encoding: .utf8
        )
        guard let completionStart = executor.range(of: "let successfulGeneration ="),
              let completionEnd = executor.range(
                of: "let succeeded = runStatus == .completed",
                range: completionStart.upperBound..<executor.endIndex
              ),
              let retainedFailureStart = terminalWriter.range(of: "func completeAsFailureAfterSaveFailure("),
              let retainedFailureEnd = terminalWriter.range(
                of: "func completeOutcomeUnknownAfterTerminalReservation(",
                range: retainedFailureStart.upperBound..<terminalWriter.endIndex
              ) else {
            return XCTFail("Expected persistence result to guard the background terminal path")
        }
        let completion = String(executor[completionStart.lowerBound..<completionEnd.lowerBound])
        guard let saveResult = completion.range(of: "let didSave: Bool"),
              let status = completion.range(of: "let runStatus = didSave", range: saveResult.upperBound..<completion.endIndex),
              let completedRecord = completion.range(of: "guard await recordRun(", range: status.upperBound..<completion.endIndex),
              let finalize = completion.range(of: "guard runState.finalizeTerminal()", range: completedRecord.upperBound..<completion.endIndex),
              let saveGuard = completion.range(of: "guard didSave else", range: finalize.upperBound..<completion.endIndex) else {
            return XCTFail("Expected save, recoveryPending record, terminal claim and save-failure branch in one completion path")
        }

        XCTAssertLessThan(saveResult.lowerBound, status.lowerBound)
        XCTAssertLessThan(status.lowerBound, completedRecord.lowerBound)
        XCTAssertLessThan(completedRecord.lowerBound, finalize.lowerBound)
        XCTAssertLessThan(finalize.lowerBound, saveGuard.lowerBound)
        XCTAssertTrue(completion[status.lowerBound..<completedRecord.lowerBound].contains(": .recoveryPending"))
        XCTAssertTrue(completion[completedRecord.lowerBound..<finalize.lowerBound].contains("status: runStatus"))
        let retainedFailureBody = terminalWriter[
            retainedFailureStart.lowerBound..<retainedFailureEnd.lowerBound
        ]
        XCTAssertTrue(
            retainedFailureBody.contains(
                "releaseRuntimeOwnership(requestId: backgroundTask.identifier)"
            ),
            "A terminal save failure must release only its live owner so cold-start reconciliation can retry."
        )
        XCTAssertFalse(
            retainedFailureBody.contains("finish(requestId: backgroundTask.identifier)"),
            "The cold-start reconciliation payload must survive a terminal save failure."
        )
        XCTAssertFalse(retainedFailureBody.contains("removePayload("))
        XCTAssertFalse(retainedFailureBody.contains("finish("))
    }

    func testTerminalDrainLagAllowanceDecaysContinuously() {
        let drainStart = 24 * 1_024
        XCTAssertEqual(
            StreamPresentationPacingPolicy.lagAllowance(
                remainingBacklog: drainStart,
                drainStartBacklog: drainStart
            ),
            1,
            "排空起始的 allowance 必须是 1（与流式期行为无缝衔接）"
        )
        XCTAssertEqual(
            StreamPresentationPacingPolicy.lagAllowance(remainingBacklog: 0, drainStartBacklog: drainStart),
            0,
            "最后一拍落定后 allowance 必须归零"
        )
        XCTAssertEqual(
            StreamPresentationPacingPolicy.lagAllowance(
                remainingBacklog: drainStart / 2,
                drainStartBacklog: drainStart
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StreamPresentationPacingPolicy.lagAllowance(
                remainingBacklog: drainStart * 2,
                drainStartBacklog: drainStart
            ),
            1,
            "超过起始积压的读数钳制在 1"
        )
        XCTAssertEqual(
            StreamPresentationPacingPolicy.lagAllowance(remainingBacklog: 100, drainStartBacklog: 0),
            0
        )
    }

    func testForegroundCompletionRecognizesOutputLimitFinishReasons() {
        func chunk(finishReason: String?) -> MessageChunk {
            MessageChunk(
                id: "chunk",
                model: "test-model",
                choices: [UIMessageChoice(
                    index: 0,
                    delta: UIMessage.companion.assistant(prompt: "部分正文"),
                    message: nil,
                    finishReason: finishReason
                )],
                usage: nil
            )
        }

        XCTAssertTrue(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "length")))
        XCTAssertTrue(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "max_tokens")))
        XCTAssertTrue(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "max_output_tokens")))
        XCTAssertTrue(
            ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "LENGTH")),
            "finish_reason 的大小写由网关决定,判定必须大小写无关。"
        )
        XCTAssertFalse(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "stop")))
        XCTAssertFalse(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: "tool_calls")))
        XCTAssertFalse(ChatGenerationSupport.reachedOutputLimit(chunk(finishReason: nil)))
    }

    /// Source-level canary for ordering contracts that do not have an injectable behavior seam.
    /// Keep the cases together as a table so the orchestration wiring costs one focused test.
    func testBackgroundCompletionUsesTypedEngineTerminalSignals() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let executor = try String(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundExecutor.swift"),
            encoding: .utf8
        )
        let terminalWriter = try String(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift"),
            encoding: .utf8
        )

        guard let limitBranch = executor.range(of: "result.hitOutputLimit"),
              let providerFailureBranch = executor.range(
                of: "result.providerFailureMessage",
                range: limitBranch.upperBound..<executor.endIndex
              ) else {
            return XCTFail("Background completion must consume typed engine terminal fields")
        }
        XCTAssertLessThan(limitBranch.lowerBound, providerFailureBranch.lowerBound)
        XCTAssertFalse(
            executor.contains("providerFailureMessage(in generatedSuffix:"),
            "Background completion must not infer provider failure from localized transcript text"
        )
        XCTAssertFalse(terminalWriter.contains("providerFailureMessage(in generatedSuffix:"))

        guard let truncatedStart = terminalWriter.range(of: "func completeTruncatedAfterTerminalReservation("),
              let truncatedEnd = terminalWriter.range(
                of: "func fail(",
                range: truncatedStart.upperBound..<terminalWriter.endIndex
              ) else {
            return XCTFail("Expected a dedicated background truncated terminal")
        }
        let truncatedBody = terminalWriter[truncatedStart.lowerBound..<truncatedEnd.lowerBound]
        XCTAssertTrue(truncatedBody.contains("let recordedStatus: AgentRunStatus = didSave ? .failed : .recoveryPending"))
        XCTAssertTrue(truncatedBody.contains("status: recordedStatus"))
        XCTAssertTrue(
            truncatedBody.contains("await backgroundFailurePresentation(")
                && truncatedBody.contains("presentation: failurePresentation"),
            "Watch and Live Activity must not present truncated output as an unqualified success"
        )
        guard let presentationStart = terminalWriter.range(of: "func backgroundFailurePresentation("),
              let presentationEnd = terminalWriter.range(of: "static func backgroundFailureIsRetryable(", range: presentationStart.upperBound..<terminalWriter.endIndex) else {
            return XCTFail("Expected the failed terminal presentation policy")
        }
        let presentationBody = terminalWriter[presentationStart.lowerBound..<presentationEnd.lowerBound]
        XCTAssertTrue(presentationBody.contains("return .failed(retryable:"))
        XCTAssertFalse(presentationBody.contains("return .completed("))
    }

    func testForegroundStreamEventSinkRetainsQueuedChunksUntilClaimed() {
        let sink = ChatStreamEventSink()
        _ = AsyncStream<ChatStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            sink.bind(continuation)
        }
        let first = MessageChunk(
            id: "first",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: UIMessage.companion.assistant(prompt: "A"),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
        let second = MessageChunk(
            id: "second",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: UIMessage.companion.assistant(prompt: "B"),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )

        sink.yield(.chunk(first))
        sink.yield(.chunk(second))
        sink.yield(.complete())
        sink.finish()

        let drained = sink.takePendingChunks()
        XCTAssertEqual(drained.map(\.id), ["first", "second"])
        XCTAssertEqual(sink.pendingEventCountForTesting, 1, "Terminal event should remain queued for the FIFO consumer.")
    }

    func testForegroundStreamEventSinkDoesNotHandoffPastQueuedTerminal() {
        let sink = ChatStreamEventSink()
        _ = AsyncStream<ChatStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            sink.bind(continuation)
        }
        sink.yield(.complete())
        var startCount = 0

        let didStart = sink.transitionToBackgroundIfNoTerminal {
            startCount += 1
            return true
        }

        XCTAssertFalse(didStart)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(sink.pendingEventCountForTesting, 1)
    }

    func testForegroundStreamEventSinkClaimsOnlyFIFOHeadAndCompactsLargeBacklog() {
        let sink = ChatStreamEventSink()
        _ = AsyncStream<ChatStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            sink.bind(continuation)
        }
        let events = (0..<1_000).map { index in
            ChatStreamEvent.chunk(MessageChunk(
                id: "chunk-\(index)",
                model: "test-model",
                choices: [],
                usage: nil
            ))
        }
        for event in events {
            sink.yield(event)
        }

        XCTAssertFalse(sink.claim(events[1]), "Out-of-order claims must not disturb FIFO ownership.")
        XCTAssertEqual(sink.pendingEventCountForTesting, events.count)
        for event in events {
            XCTAssertTrue(sink.claim(event))
        }
        XCTAssertEqual(sink.pendingEventCountForTesting, 0)
    }

}
