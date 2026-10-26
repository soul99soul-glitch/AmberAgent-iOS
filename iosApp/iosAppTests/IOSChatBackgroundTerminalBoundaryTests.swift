import BackgroundTasks
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatBackgroundTerminalBoundaryTests: IOSOrchestrationToolTestCase {
    func testCancelledBackgroundRunCarriesOriginalBaselineAndDoesNotDeliverOldAnswer() async throws {
        let fixture = try await makeFixture()
        let provider = IOSChatProgressStreamingProvider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: provider)
        defer {
            coordinator.cancelJobs(conversationId: fixture.handoff.conversationId)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "Cancelled producer terminal callback and mailbox delivery")
        var receipt: TerminalReceipt?
        coordinator.onRunTerminal = { conversationID, runID, finalMessages, displayBaseline in
            receipt = TerminalReceipt(
                conversationID: conversationID,
                runID: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline
            )
            await fixture.service.notifyRunTerminal(
                conversationId: conversationID,
                runId: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline,
                terminalStatus: .cancelled
            )
            delivered.fulfill()
        }

        XCTAssertTrue(coordinator.start(
            handoff: fixture.handoff,
            conversationStore: fixture.store,
            toolRuntime: fixture.runtime,
            liveActivityController: .shared
        ))
        try await waitUntil { provider.callCount == 1 }
        XCTAssertTrue(coordinator.cancelJob(runId: fixture.handoff.runId))
        await fulfillment(of: [delivered], timeout: 5)

        let terminal = try XCTUnwrap(receipt)
        assertBaseline(terminal, matches: fixture)
        XCTAssertEqual(messageIDs(terminal.finalMessages), messageIDs(fixture.handoff.displayMessages))
        XCTAssertTrue(IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: terminal.finalMessages,
            displayMessages: terminal.displayBaseline
        ).isEmpty)
        XCTAssertTrue(terminal.finalMessages.contains { $0.toText().contains(fixture.oldAnswer) })
        let envelope = try await finalEnvelope(in: fixture)
        XCTAssertFalse(envelope.payload.contains(fixture.oldAnswer))
        XCTAssertTrue(envelope.payload.contains("run ended without assistant output"))
        let metadata = try terminalMetadata(in: envelope.payload)
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        XCTAssertEqual(metadata["run_ended"] as? Bool, true)
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .cancelled)
        try await waitUntil { coordinator.activeJobCount == 0 }
    }

    func testCompletedBackgroundRunKeepsHistoryInFullTranscriptAndOnlyDeliversNewAnswer() async throws {
        let fixture = try await makeFixture()
        let provider = IOSChatProgressStreamingProvider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: provider)
        defer {
            coordinator.cancelJobs(conversationId: fixture.handoff.conversationId)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "Completed producer terminal callback and mailbox delivery")
        var receipt: TerminalReceipt?
        coordinator.onRunTerminal = { conversationID, runID, finalMessages, displayBaseline in
            receipt = TerminalReceipt(
                conversationID: conversationID,
                runID: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline
            )
            await fixture.service.notifyRunTerminal(
                conversationId: conversationID,
                runId: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline,
                terminalStatus: .completed
            )
            delivered.fulfill()
        }

        XCTAssertTrue(coordinator.start(
            handoff: fixture.handoff,
            conversationStore: fixture.store,
            toolRuntime: fixture.runtime,
            liveActivityController: .shared
        ))
        try await waitUntil { provider.callCount == 1 }
        let newAnswer = "本轮新核实的结果。"
        provider.emit(IOSChatForegroundFixtures.streamChunk(
            delta: IOSChatForegroundFixtures.assistantText(newAnswer)
        ))
        provider.finishRound()
        await fulfillment(of: [delivered], timeout: 5)

        let terminal = try XCTUnwrap(receipt)
        assertBaseline(terminal, matches: fixture)
        XCTAssertEqual(
            messageIDs(Array(terminal.finalMessages.prefix(terminal.displayBaseline.count))),
            messageIDs(fixture.handoff.displayMessages)
        )
        let generated = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: terminal.finalMessages,
            displayMessages: terminal.displayBaseline
        )
        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated.first?.toText(), newAnswer)
        XCTAssertFalse(terminal.displayBaseline.contains { $0.toText().contains(newAnswer) })
        XCTAssertTrue(terminal.finalMessages.contains { $0.toText().contains(fixture.oldAnswer) })
        let envelope = try await finalEnvelope(in: fixture)
        XCTAssertTrue(envelope.payload.contains(newAnswer))
        XCTAssertFalse(envelope.payload.contains(fixture.oldAnswer))
        let metadata = try terminalMetadata(in: envelope.payload)
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.completed.wireName)
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .completed)
        try await waitUntil { coordinator.activeJobCount == 0 }
    }

    func testCancellationAfterHandoffDeliversPartialGeneratedBeforeHandoff() async throws {
        let partial = "交接后台前，本轮已经核实了这条结果。"
        let fixture = try await makeFixture(handoffPartial: partial)
        let provider = IOSChatProgressStreamingProvider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: provider)
        defer {
            coordinator.cancelJobs(conversationId: fixture.handoff.conversationId)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "Handoff partial remains this run's output after background cancellation")
        var receipt: TerminalReceipt?
        coordinator.onRunTerminal = { conversationID, runID, finalMessages, displayBaseline in
            receipt = TerminalReceipt(
                conversationID: conversationID,
                runID: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline
            )
            await fixture.service.notifyRunTerminal(
                conversationId: conversationID,
                runId: runID,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline,
                terminalStatus: .cancelled
            )
            delivered.fulfill()
        }

        XCTAssertTrue(coordinator.start(
            handoff: fixture.handoff,
            conversationStore: fixture.store,
            toolRuntime: fixture.runtime,
            liveActivityController: .shared
        ))
        try await waitUntil { provider.callCount == 1 }
        XCTAssertTrue(coordinator.cancelJob(runId: fixture.handoff.runId))
        await fulfillment(of: [delivered], timeout: 5)

        let terminal = try XCTUnwrap(receipt)
        assertBaseline(terminal, matches: fixture)
        XCTAssertFalse(terminal.displayBaseline.contains { $0.toText() == partial })
        XCTAssertEqual(messageIDs(terminal.finalMessages), messageIDs(fixture.handoff.displayMessages))
        let generated = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: terminal.finalMessages,
            displayMessages: terminal.displayBaseline
        )
        XCTAssertEqual(generated.map { $0.toText() }, [partial])
        let envelope = try await finalEnvelope(in: fixture)
        XCTAssertTrue(envelope.payload.contains(partial), "交接前生成的partial仍属于同一run，取消报告不能把它当成历史基线排除。")
        XCTAssertFalse(envelope.payload.contains(fixture.oldAnswer))
        XCTAssertEqual(try terminalMetadata(in: envelope.payload)["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        let saved = await fixture.store.messages(for: fixture.handoff.conversationId)
        XCTAssertEqual(saved?.filter { $0.toText() == partial }.count, 1)
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .cancelled)
        try await waitUntil { coordinator.activeJobCount == 0 }
    }

    func testFailureSavedDuringExpirationStillDeliversItsTerminal() async throws {
        let fixture = try await makeFixture()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: IOSChatProgressStreamingProvider())
        let execution = try prepareTerminalExecution(coordinator: coordinator, fixture: fixture)
        defer {
            fixture.store.afterPersistReservationForTesting = nil
            coordinator.finish(runId: fixture.handoff.runId, requestId: execution.task.identifier)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "Saved failure terminal remains deliverable after expiration")
        var callbackCount = 0
        coordinator.onRunTerminal = { conversationID, runID, finalMessages, baseline in
            callbackCount += 1
            XCTAssertEqual(conversationID, fixture.handoff.conversationId)
            XCTAssertEqual(runID, fixture.handoff.runId)
            XCTAssertEqual(self.messageIDs(baseline), self.messageIDs(fixture.runDisplayBaseline))
            XCTAssertTrue(finalMessages.contains { $0.toText().contains("provider failed") })
            delivered.fulfill()
        }
        expireOnConversationSave(fixture: fixture, runState: execution.state)

        await coordinator.failAfterTerminalReservation(
            job: execution.job, backgroundTask: execution.task,
            runState: execution.state, terminalOwner: .completion, rawMessage: "provider failed"
        )
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(coordinator.restorableRunIds.contains(fixture.handoff.runId))
        XCTAssertNil(coordinator.taskMap()[execution.task.identifier])
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL(requestID: execution.task.identifier).path))
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .failed)
    }

    func testFailureRequiringRecoveryDuringExpirationRetainsCheckpointWithoutTerminalDelivery() async throws {
        let fixture = try await makeFixture()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: IOSChatProgressStreamingProvider())
        let execution = try prepareTerminalExecution(coordinator: coordinator, fixture: fixture)
        defer {
            fixture.store.afterPersistReservationForTesting = nil
            coordinator.finish(runId: fixture.handoff.runId, requestId: execution.task.identifier)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "A recovery checkpoint is not a terminal result")
        delivered.isInverted = true
        coordinator.onRunTerminal = { _, _, _, _ in delivered.fulfill() }
        expireOnConversationSave(fixture: fixture, runState: execution.state)

        await coordinator.failAfterTerminalReservation(
            job: execution.job, backgroundTask: execution.task,
            runState: execution.state, terminalOwner: .completion,
            rawMessage: "provider failed", requiresRecovery: true
        )
        await fulfillment(of: [delivered], timeout: 0.05)

        XCTAssertEqual(coordinator.activeJobCount, 0)
        XCTAssertEqual(coordinator.taskMap()[execution.task.identifier], fixture.handoff.runId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL(requestID: execution.task.identifier).path))
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .recoveryPending)
    }

    func testFailureUnableToSaveDuringExpirationRetainsCheckpoint() async throws {
        let fixture = try await makeFixture()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: IOSChatProgressStreamingProvider())
        let execution = try prepareTerminalExecution(coordinator: coordinator, fixture: fixture)
        defer {
            fixture.store.beforePersistForTesting = nil
            coordinator.finish(runId: fixture.handoff.runId, requestId: execution.task.identifier)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let reachedPersist = expectation(description: "Failure transcript reached the persistence boundary")
        var resumeSave: CheckedContinuation<Void, Never>?
        fixture.store.beforePersistForTesting = { conversation in
            guard conversation.id == fixture.handoff.conversationId else { return }
            XCTAssertEqual(execution.state.expireAndReserveTerminal(), .terminateInFlightSave)
            XCTAssertTrue(execution.state.finalizeTerminal(as: .expiration))
            reachedPersist.fulfill()
            await withCheckedContinuation { resumeSave = $0 }
        }
        let delivered = expectation(description: "Unsaved failure must remain recoverable")
        delivered.isInverted = true
        coordinator.onRunTerminal = { _, _, _, _ in delivered.fulfill() }
        let writer = Task { @MainActor in
            await coordinator.failAfterTerminalReservation(
                job: execution.job, backgroundTask: execution.task,
                runState: execution.state, terminalOwner: .completion, rawMessage: "provider failed"
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)
        // The existing tombstone barrier deterministically rejects the suspended write.
        _ = await fixture.store.deleteConversation(id: fixture.handoff.conversationId)
        fixture.store.beforePersistForTesting = nil
        resumeSave?.resume()
        await writer.value
        await fulfillment(of: [delivered], timeout: 0.05)

        XCTAssertEqual(coordinator.activeJobCount, 0)
        XCTAssertEqual(coordinator.taskMap()[execution.task.identifier], fixture.handoff.runId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL(requestID: execution.task.identifier).path))
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .recoveryPending)
    }

    func testTruncatedReplySavedDuringExpirationStillDeliversItsTerminal() async throws {
        let fixture = try await makeFixture()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: makeKeepAlive(), provider: IOSChatProgressStreamingProvider())
        let execution = try prepareTerminalExecution(coordinator: coordinator, fixture: fixture)
        defer {
            fixture.store.afterPersistReservationForTesting = nil
            coordinator.finish(runId: fixture.handoff.runId, requestId: execution.task.identifier)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let delivered = expectation(description: "Saved truncated output still reaches its original run")
        var callbackCount = 0
        coordinator.onRunTerminal = { conversationID, runID, messages, _ in
            callbackCount += 1
            XCTAssertEqual(conversationID, fixture.handoff.conversationId)
            XCTAssertEqual(runID, fixture.handoff.runId)
            XCTAssertTrue(messages.contains { $0.toText() == "new partial output" })
            delivered.fulfill()
        }
        expireOnConversationSave(fixture: fixture, runState: execution.state)

        await coordinator.completeTruncatedAfterTerminalReservation(
            job: execution.job, backgroundTask: execution.task, runState: execution.state,
            reconciledMessages: fixture.handoff.displayMessages + [UIMessage.companion.assistant(prompt: "new partial output")]
        )
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(coordinator.restorableRunIds.contains(fixture.handoff.runId))
        XCTAssertNil(coordinator.taskMap()[execution.task.identifier])
        let durable = try await IOSDurableRunStore().snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(durable?.status, .failed)
    }

    private func prepareTerminalExecution(
        coordinator: IOSChatBackgroundGenerationCoordinator,
        fixture: Fixture
    ) throws -> (job: IOSChatBackgroundRuntimeJob, task: IOSChatBackgroundExecution, state: IOSChatBackgroundRunState) {
        XCTAssertTrue(coordinator.persistBackgroundCheckpointForTesting(fixture.handoff))
        let taskMapKey = "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").chat.backgroundTaskMap"
        let map = UserDefaults.standard.dictionary(forKey: taskMapKey) as? [String: String] ?? [:]
        let requestID = try XCTUnwrap(map.first { $0.value == fixture.handoff.runId }?.key)
        let job = coordinator.runtimeJob(
            handoff: fixture.handoff, conversationStore: fixture.store, toolRuntime: fixture.runtime,
            liveActivityController: .shared, saveMiniAppIfPresent: nil
        )
        let state = IOSChatBackgroundRunState()
        XCTAssertTrue(state.reserveTerminal())
        coordinator.activeJobs[requestID] = job
        coordinator.activeRunStates[requestID] = state
        return (job, IOSChatBackgroundExecution(
            identifier: requestID, keepAlive: coordinator.keepAlive, leaseId: fixture.handoff.runId
        ), state)
    }

    private func expireOnConversationSave(fixture: Fixture, runState: IOSChatBackgroundRunState) {
        fixture.store.afterPersistReservationForTesting = { conversation in
            guard conversation.id == fixture.handoff.conversationId else { return }
            XCTAssertEqual(runState.expireAndReserveTerminal(), .terminateInFlightSave)
            XCTAssertTrue(runState.finalizeTerminal(as: .expiration))
        }
    }

    private func payloadURL(requestID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatBackgroundJobs", isDirectory: true)
            .appendingPathComponent(IOSChatBackgroundJobFileNaming.sanitized(requestID))
            .appendingPathExtension("json")
    }

    private struct TerminalReceipt {
        let conversationID: KotlinUuid
        let runID: String
        let finalMessages: [UIMessage]
        let displayBaseline: [UIMessage]
    }

    private struct Fixture {
        let directory: URL
        let database: AgentRuntimeDatabase
        let store: IOSConversationStore
        let runtime: ChatToolRuntime
        let service: IOSThreadOrchestrationToolService
        let parentID: KotlinUuid
        let handoff: IOSChatBackgroundHandoff
        let runDisplayBaseline: [UIMessage]
        let oldAnswer: String
    }

    private func makeFixture(handoffPartial: String? = nil) async throws -> Fixture {
        let directory = makeTempDirectory("BackgroundTerminalBoundary")
        let store = makeStore(directory: directory)
        let database = makeDatabase(directory: directory)
        await store.newConversation()
        let parentID = try XCTUnwrap(store.currentConversation?.id)
        await store.newConversation()
        let childID = try XCTUnwrap(store.currentConversation?.id)
        let oldAnswer = "上一轮已交付的旧报告，不能作为本轮结果。"
        let baseline = [
            UIMessage.companion.assistant(prompt: oldAnswer),
            UIMessage.companion.user(prompt: "执行新一轮核查任务"),
        ]
        let displayMessages = baseline + (handoffPartial.map {
            [UIMessage.companion.assistant(prompt: $0)]
        } ?? [])
        await store.saveCurrent(messages: displayMessages)
        try await database.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childID.toHexDashString(),
            parentThreadId: parentID.toHexDashString(),
            agentPath: "/root/background-worker",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: 1
        ))
        let setting = makeProviderSetting()
        let runID = UUID().uuidString
        let handoff = IOSChatBackgroundHandoff(
            runId: runID,
            startedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            inputDigest: runID,
            conversationId: childID,
            providerId: setting.id.toHexDashString(),
            providerSetting: setting,
            params: makeParams(),
            uploadMessages: [UIMessage.companion.system(prompt: "Upload-only system context.")] + displayMessages,
            displayMessages: displayMessages,
            mode: .continueModel,
            generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false,
            fullToolNames: [],
            runDisplayBaseline: baseline
        )
        let recorded = try await IOSDurableRunStore().startChatRun(
            runId: runID,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: childID.toHexDashString()
        )
        XCTAssertTrue(recorded)
        return Fixture(
            directory: directory,
            database: database,
            store: store,
            runtime: makeRuntime(),
            service: makeService(
                store: store,
                db: database,
                scheduler: FakeBackgroundScheduler(),
                currentConversationId: { childID }
            ),
            parentID: parentID,
            handoff: handoff,
            runDisplayBaseline: baseline,
            oldAnswer: oldAnswer
        )
    }

    private func assertBaseline(_ receipt: TerminalReceipt, matches fixture: Fixture) {
        XCTAssertEqual(receipt.conversationID, fixture.handoff.conversationId)
        XCTAssertEqual(receipt.runID, fixture.handoff.runId)
        XCTAssertFalse(receipt.displayBaseline.isEmpty)
        XCTAssertEqual(messageIDs(receipt.displayBaseline), messageIDs(fixture.runDisplayBaseline))
        XCTAssertFalse(receipt.displayBaseline.contains { $0.role == .system })
        XCTAssertEqual(fixture.handoff.uploadMessages.count, fixture.handoff.displayMessages.count + 1)
    }

    private func messageIDs(_ messages: [UIMessage]) -> [String] {
        messages.map { $0.id.toHexDashString() }
    }

    private func finalEnvelope(in fixture: Fixture) async throws -> MailboxEnvelopeEntity {
        let pending = try await fixture.database.mailboxDao().pendingForRecipient(
            recipientId: fixture.parentID.toHexDashString()
        )
        return try XCTUnwrap(pending.first {
            $0.parentTurnId == fixture.handoff.runId && $0.type == MailboxEnvelopeType.finalAnswer.name
        })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func terminalMetadata(in payload: String) throws -> [String: Any] {
        let line = try XCTUnwrap(payload.components(separatedBy: "\n").last { $0.hasPrefix("{") })
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(value as? [String: Any])
    }

    private final class Audio: BackgroundAudioKeepAliveControlling {
        var isActive = false
        var isStartingOrActive: Bool { isActive }
        func start() { isActive = true }
        func stop() { isActive = false }
    }

    private func makeKeepAlive() -> BackgroundGenerationKeepAlive {
        BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 1) },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true },
            isApplicationForeground: { true },
            audioKeepAlive: Audio(),
            isAudioKeepAliveEnabled: { false }
        )
    }
}
