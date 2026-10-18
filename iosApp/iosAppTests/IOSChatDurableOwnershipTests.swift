import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatDurableOwnershipTests: IOSChatKernelRunHostTestCase {
    private final class GatedProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var released = false
        private var uploads: [[UIMessage]] = []
        let firstMessage: UIMessage?
        let failsAfterRelease: Bool

        init(firstMessage: UIMessage? = nil, failsAfterRelease: Bool = false) {
            self.firstMessage = firstMessage
            self.failsAfterRelease = failsAfterRelease
        }
        var callCount: Int { lock.withLock { calls } }
        var latestUpload: [UIMessage] { lock.withLock { uploads.last ?? [] } }
        func release() { lock.withLock { released = true } }

        func generateText(providerSetting: ProviderSetting, messages: [UIMessage],
                          params: TextGenerationParams) async throws -> MessageChunk {
            let index = lock.withLock { () -> Int in
                calls += 1
                uploads.append(messages)
                return calls
            }
            while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
            if index == 1, let firstMessage {
                return IOSChatForegroundFixtures.chunk(with: firstMessage, finishReason: "tool_calls")
            }
            if failsAfterRelease { throw URLError(.networkConnectionLost) }
            try await Task.sleep(for: .seconds(60))
            return IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText("done"))
        }
    }

    private struct Fixture {
        let harness: IOSChatForegroundHarness
        let coordinator: IOSChatBackgroundGenerationCoordinator
        let store: IOSConversationStore
        let settings: IOSSharedSettingsStore
        let provider: ProviderSetting.OpenAI
        let runtime: ChatToolRuntime
        let directory: URL
        let defaultsName: String
    }

    private func fixture(harness: IOSChatForegroundHarness,
                         provider: any IOSAgentTextProvider) async throws -> Fixture {
        let name = "durable-owner-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let setting = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: name, models: [harness.params.model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test",
            baseUrl: "https://example.test", chatCompletionsPath: "/chat/completions",
            useResponseApi: true, authMode: .apiKey, brand: .generic
        )
        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: name)),
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        settings.addProvider(setting)
        XCTAssertNil(settings.credentialPersistenceError)
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: harness.keepAlive, provider: provider)
        coordinator.registerRequestOverrideForTesting = { _ in true }
        coordinator.resumeDetachedResponsesOverrideForTesting = {}
        let runtime = makeHost(harness: harness, provider: provider).toolRuntimeForTesting
        return Fixture(harness: harness, coordinator: coordinator, store: store, settings: settings,
                       provider: setting, runtime: runtime, directory: directory, defaultsName: name)
    }

    private func cleanUp(_ fixture: Fixture, runId: String?) {
        if let runId {
            for (requestId, job) in fixture.coordinator.activeJobs where job.runId == runId {
                _ = fixture.coordinator.activeRunStates[requestId]?.cancelAndReserveTerminal()
            }
            fixture.coordinator.discardDurableResponse(runId: runId)
            WatchTaskCoordinator.shared.clear(runId: runId)
        }
        UserDefaults(suiteName: fixture.defaultsName)?.removePersistentDomain(forName: fixture.defaultsName)
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func persistedHandoff(_ fixture: Fixture, runId: String) -> IOSChatBackgroundHandoff? {
        guard let requestId = fixture.coordinator.taskMap().first(where: { $0.value == runId })?.key else { return nil }
        var result: IOSChatBackgroundHandoff?
        fixture.coordinator.withDependenciesForTesting(
            conversationStore: fixture.store, toolRuntime: fixture.runtime, sharedSettings: fixture.settings
        ) { result = fixture.coordinator.loadHandoff(requestId: requestId) }
        return result
    }

    private func makeResponseJob(_ fixture: Fixture, runId: String) async throws -> (IOSChatBackgroundRuntimeJob, String) {
        let conversationId = try XCTUnwrap(fixture.store.currentConversation?.id)
        let handoff = IOSChatBackgroundHandoff(
            runId: runId, startedAt: 1, inputDigest: runId, conversationId: conversationId,
            providerId: fixture.provider.id.toHexDashString(), providerSetting: fixture.provider,
            params: fixture.harness.params, uploadMessages: fixture.harness.messages,
            displayMessages: fixture.harness.messages, mode: .resumeResponse, responseId: "response-first",
            generativeUiRequirement: .none, generativeUiFallbackAttempted: false,
            fullToolNames: fixture.harness.toolExposureBridge.fullToolDeclarations().map(\.name)
        )
        XCTAssertTrue(fixture.coordinator.persistDurableResponseCheckpointForTesting(handoff))
        let requestId = try XCTUnwrap(fixture.coordinator.taskMap().first { $0.value == runId }?.key)
        let job = fixture.coordinator.runtimeJob(
            handoff: handoff, conversationStore: fixture.store, toolRuntime: fixture.runtime,
            liveActivityController: fixture.harness.dependencies.liveActivityController,
            saveMiniAppIfPresent: nil
        )
        fixture.coordinator.activeJobs[requestId] = job
        let didStart = try await fixture.coordinator.runStore.startChatRun(
            runId: runId, startedAt: 1, inputDigest: runId, conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(didStart)
        return (job, requestId)
    }

    func testCompletedDetachedResponseTransfersExistingOwnerToToolLoopOnce() async throws {
        let provider = GatedProvider()
        let harness = makeHarness(exposedToolNames: ["tools_list"])
        let fixture = try await fixture(harness: harness, provider: provider)
        let runId = "response-transfer-\(UUID().uuidString)"
        defer { provider.release(); cleanUp(fixture, runId: runId) }
        let (job, requestId) = try await makeResponseJob(fixture, runId: runId)
        let toolMessage = F.assistantMessage(parts: [UIMessagePart.Tool(
            toolCallId: "durable-list", toolName: "tools_list", input: "{}", output: [],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )])
        let messages = job.displayMessages + [toolMessage]

        XCTAssertTrue(fixture.coordinator.continueCompletedDetachedResponse(job: job, requestId: requestId, messages: messages))
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.mode, .continueModel)
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.mode, .continueModel)
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started, "The completed response must execute its pending tool before requesting another model turn")
        XCTAssertFalse(F.toolPart(toolCallId: "durable-list", in: provider.latestUpload)?.output.isEmpty ?? true)
        XCTAssertFalse(fixture.coordinator.continueCompletedDetachedResponse(job: job, requestId: requestId, messages: messages))
        XCTAssertEqual(provider.callCount, 1)
    }

    func testDetachedTransferPersistenceFailureKeepsResponseOwner() async throws {
        let provider = GatedProvider()
        let harness = makeHarness(exposedToolNames: ["tools_list"])
        let fixture = try await fixture(harness: harness, provider: provider)
        let runId = "response-transfer-failure-\(UUID().uuidString)"
        defer { provider.release(); cleanUp(fixture, runId: runId) }
        let (job, requestId) = try await makeResponseJob(fixture, runId: runId)
        fixture.coordinator.persistHandoffOverrideForTesting = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        XCTAssertFalse(fixture.coordinator.continueCompletedDetachedResponse(
            job: job, requestId: requestId, messages: job.displayMessages + [F.assistantText("complete")]
        ))
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.responseId, "response-first")
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.responseId, "response-first")
        XCTAssertNil(fixture.coordinator.activeBackgroundTasks[requestId])
        XCTAssertEqual(provider.callCount, 0)
    }

    func testTransferredResponsePrefixSurvivesNextProviderFailureAndTerminalSave() async throws {
        let provider = GatedProvider(failsAfterRelease: true)
        let harness = makeHarness(exposedToolNames: ["tools_list"])
        let fixture = try await fixture(harness: harness, provider: provider)
        let runId = "response-prefix-terminal-\(UUID().uuidString)"
        defer { provider.release(); cleanUp(fixture, runId: runId) }
        await fixture.store.saveCurrent(messages: harness.messages)
        let (job, requestId) = try await makeResponseJob(fixture, runId: runId)
        let recovered = F.assistantMessage(parts: [
            UIMessagePart.Text(text: "Recovered first response prefix", metadata: nil),
            UIMessagePart.Tool(toolCallId: "prefix-list", toolName: "tools_list", input: "{}", output: [],
                               approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        ])
        provider.release()

        XCTAssertTrue(fixture.coordinator.continueCompletedDetachedResponse(
            job: job, requestId: requestId, messages: job.displayMessages + [recovered]
        ))
        let continued = try XCTUnwrap(persistedHandoff(fixture, runId: runId))
        XCTAssertEqual(continued.runDisplayBaseline?.map(\.id), harness.messages.map(\.id))
        XCTAssertEqual(continued.displayMessages.last?.id, recovered.id)
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.runDisplayBaseline.map(\.id), harness.messages.map(\.id))
        XCTAssertEqual(fixture.coordinator.subAgentPublicOutput(runId: runId)?.summary, "Recovered first response prefix")
        let finished = await waitForCondition { fixture.coordinator.activeJobs[requestId] == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(provider.callCount, 1)
        let run = try await fixture.coordinator.runStore.snapshot(runId: runId)
        XCTAssertEqual(run?.status, .failed)
        let reopened = IOSConversationStore(baseDirectory: fixture.directory)
        await reopened.bootstrap()
        let storedMessages = await reopened.messages(for: job.conversationId)
        let messages = try XCTUnwrap(storedMessages)
        XCTAssertEqual(Array(messages.prefix(harness.messages.count)).map(\.id), harness.messages.map(\.id))
        let savedPrefix = try XCTUnwrap(messages.first { $0.id == recovered.id })
        XCTAssertTrue(savedPrefix.toText().contains("Recovered first response prefix"))
        let completedTool: UIMessagePart.Tool = try XCTUnwrap(F.toolPart(toolCallId: "prefix-list", in: messages))
        XCTAssertFalse(completedTool.output.isEmpty)
        XCTAssertEqual(messages.filter { $0.id == recovered.id }.count, 1)
        XCTAssertEqual(messages.filter(ChatViewModel.isLocalGenerationError).count, 1)
    }

    func testForegroundCheckpointFailureKeepsDurableOwnerAndRejectsStaleDetach() async throws {
        let provider = GatedProvider()
        let harness = makeHarness()
        let fixture = try await fixture(harness: harness, provider: provider)
        let runId = "foreground-checkpoint-failure-\(UUID().uuidString)"
        defer { provider.release(); cleanUp(fixture, runId: runId) }
        let (job, requestId) = try await makeResponseJob(fixture, runId: runId)
        let host = ChatKernelRunHost(dependencies: harness.dependencies, bindings: harness.bindings,
                                     backgroundCoordinator: fixture.coordinator)
        let session = ChatDurableResponseSession(host: host, runId: runId, backgroundCoordinator: fixture.coordinator)
        let response = try XCTUnwrap(persistedHandoff(fixture, runId: runId))
        XCTAssertNotNil(session.checkpoint(responseId: "response-first", sequenceNumber: 1, handoff: response))
        let continuation = ChatRunBackgroundHandoffBuilder.continuingAfterResponse(
            response, messages: response.displayMessages + [F.assistantText("complete")]
        )
        let completedRequestToken = session.provider.requestTokenForTesting
        fixture.coordinator.persistHandoffOverrideForTesting = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        XCTAssertFalse(session.persistContinuation(continuation))
        XCTAssertNil(session.checkpoint(responseId: "response-first", sequenceNumber: 2,
                                        handoff: response, requestToken: completedRequestToken),
                     "Queued callbacks cannot reclaim a completed response after transfer fails")
        XCTAssertFalse(session.canDetach(handoff: response))
        XCTAssertTrue(session.requiresRecovery)
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.responseId, "response-first")
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.responseId, job.responseId)
        let run = try await fixture.coordinator.runStore.snapshot(runId: runId)
        XCTAssertEqual(run?.status, .running, "Checkpoint transfer must not end or replace the run ledger")
    }

    func testResponseSequenceProgressKeepsPersistedSnapshotAndCachedRuntimeUntilBoundary() async throws {
        let provider = GatedProvider()
        let harness = makeHarness()
        let fixture = try await fixture(harness: harness, provider: provider)
        let runId = "response-sequence-\(UUID().uuidString)"
        defer { provider.release(); cleanUp(fixture, runId: runId) }
        let (_, requestId) = try await makeResponseJob(fixture, runId: runId)
        let host = ChatKernelRunHost(dependencies: harness.dependencies, bindings: harness.bindings,
                                     backgroundCoordinator: fixture.coordinator)
        let session = ChatDurableResponseSession(host: host, runId: runId, backgroundCoordinator: fixture.coordinator)
        let source = try XCTUnwrap(persistedHandoff(fixture, runId: runId))
        let first = try XCTUnwrap(session.checkpoint(responseId: "response-first", sequenceNumber: 1, handoff: source))
        let firstBridge = try XCTUnwrap(fixture.coordinator.activeJobs[requestId]?.toolExposureBridge)
        var sequenceWrites = 0
        fixture.coordinator.persistHandoffOverrideForTesting = { _, _ in sequenceWrites += 1 }
        let second = try XCTUnwrap(session.checkpoint(responseId: "response-first", sequenceNumber: 2, handoff: first.handoff))
        let third = try XCTUnwrap(session.checkpoint(responseId: "response-first", sequenceNumber: 3, handoff: second.handoff))

        XCTAssertEqual(sequenceWrites, 0, "Sequence progress must not persist a cursor without its partial messages")
        XCTAssertEqual(third.handoff.responseSequenceNumber, 3)
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.responseSequenceNumber, 1)
        XCTAssertTrue(fixture.coordinator.activeJobs[requestId]?.toolExposureBridge === firstBridge)
        fixture.coordinator.persistHandoffOverrideForTesting = nil

        let next = try XCTUnwrap(session.checkpoint(responseId: "response-second", sequenceNumber: 1, handoff: third.handoff))
        let nextBridge = try XCTUnwrap(fixture.coordinator.activeJobs[requestId]?.toolExposureBridge)
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.responseId, "response-second")
        XCTAssertFalse(nextBridge === firstBridge)
        let continuation = ChatRunBackgroundHandoffBuilder.continuingAfterResponse(
            next.handoff, messages: next.handoff.displayMessages + [F.assistantText("complete")]
        )
        XCTAssertTrue(session.persistContinuation(continuation))
        XCTAssertEqual(persistedHandoff(fixture, runId: runId)?.mode, .continueModel)
        XCTAssertNil(persistedHandoff(fixture, runId: runId)?.responseId)
        XCTAssertFalse(fixture.coordinator.activeJobs[requestId]?.toolExposureBridge === nextBridge)
    }

    func testCompletedForegroundResponseRetiresDiskCursorBeforeReadToolExecution() async throws {
        let search = NonCooperativeSearchTransport()
        let harness = makeHarness(exposedToolNames: ["search_web"], searchTransport: search)
        let provider = GatedProvider(firstMessage: toolRound("cursor-search", "search_web", #"{"query":"amber"}"#).message)
        let fixture = try await fixture(harness: harness, provider: provider)
        let host = ChatKernelRunHost(
            dependencies: harness.dependencies, bindings: harness.bindings, backgroundExecution: harness.keepAlive,
            toolLedger: harness.ledger, textProvider: provider, backgroundCoordinator: fixture.coordinator
        )
        var cleanupRunId: String?
        defer { provider.release(); search.release(); host.cancel(); cleanUp(fixture, runId: cleanupRunId) }
        host.start(providerSetting: fixture.provider, params: harness.params, inputDigest: "rounds",
                   conversationId: fixture.store.currentConversation?.id, uploadMessages: harness.messages,
                   toolExposureBridge: harness.toolExposureBridge)
        let began = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(began)
        let runId = try XCTUnwrap(host.currentRunId)
        cleanupRunId = runId
        host.installDurableResponseSessionForTesting()
        host.recordDurableResponseCheckpoint(runId: runId, responseId: "response-first", sequenceNumber: 1)
        let requestId = try XCTUnwrap(fixture.coordinator.taskMap().first { $0.value == runId }?.key)
        fixture.coordinator.withDependenciesForTesting(
            conversationStore: fixture.store, toolRuntime: fixture.runtime, sharedSettings: fixture.settings
        ) { _ = fixture.coordinator.job(for: requestId) }
        provider.release()
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.approvePendingSearchTool()
        let executing = await waitForCondition { search.isExecuting }
        XCTAssertTrue(executing)
        let checkpoint = try XCTUnwrap(persistedHandoff(fixture, runId: runId))
        XCTAssertEqual(checkpoint.mode, .continueModel)
        XCTAssertNil(checkpoint.responseId)
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.mode, .continueModel)
        XCTAssertNil(fixture.coordinator.activeJobs[requestId]?.responseId)
        XCTAssertNotNil(F.toolPart(toolCallId: "cursor-search", in: checkpoint.displayMessages))
    }

    func testNextForegroundRoundCannotDetachUsingPreviousResponseCheckpoint() async throws {
        let search = NonCooperativeSearchTransport()
        let harness = makeHarness(exposedToolNames: ["search_web"], searchTransport: search)
        let provider = GatedProvider(firstMessage: toolRound("cursor-search", "search_web", #"{"query":"amber"}"#).message)
        let fixture = try await fixture(harness: harness, provider: provider)
        let host = ChatKernelRunHost(
            dependencies: harness.dependencies, bindings: harness.bindings, backgroundExecution: harness.keepAlive,
            toolLedger: harness.ledger, textProvider: provider, backgroundCoordinator: fixture.coordinator
        )
        var detached = 0
        fixture.coordinator.resumeDetachedResponsesOverrideForTesting = { detached += 1 }
        var regularHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in regularHandoff = handoff; return false }
        var runId: String?
        defer { provider.release(); search.release(); host.cancel(); cleanUp(fixture, runId: runId) }
        host.start(providerSetting: fixture.provider, params: harness.params, inputDigest: "rounds",
                   conversationId: fixture.store.currentConversation?.id, uploadMessages: harness.messages,
                   toolExposureBridge: harness.toolExposureBridge)
        let began = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(began)
        runId = try XCTUnwrap(host.currentRunId)
        host.installDurableResponseSessionForTesting()
        host.recordDurableResponseCheckpoint(runId: runId!, responseId: "response-first", sequenceNumber: 1)
        provider.release()
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.approvePendingSearchTool()
        let executing = await waitForCondition { search.isExecuting }
        XCTAssertTrue(executing)
        search.release()
        let nextRound = await waitForCondition { provider.callCount == 2 }
        XCTAssertTrue(nextRound)

        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: fixture.store))
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(detached, 0)
        XCTAssertEqual(regularHandoff?.mode, .continueModel)
        XCTAssertNil(persistedHandoff(fixture, runId: runId!)?.responseId)
        XCTAssertFalse(F.toolPart(toolCallId: "cursor-search", in: persistedHandoff(fixture, runId: runId!)?.displayMessages ?? [])?.output.isEmpty ?? true)
        guard host.isRunning else { return }
        host.recordDurableResponseCheckpoint(runId: runId!, responseId: "response-second", sequenceNumber: 1)
        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: fixture.store))
        XCTAssertEqual(detached, 1)
        XCTAssertEqual(persistedHandoff(fixture, runId: runId!)?.responseId, "response-second")
    }
    func testForegroundHandoffStartsCachedContinuationBeforeNextCheckpoint() async throws {
        let search = NonCooperativeSearchTransport()
        let harness = makeHarness(exposedToolNames: ["search_web"], searchTransport: search)
        let originalDisplayBaseline = harness.messages
        let provider = GatedProvider(firstMessage: toolRound("cached-search", "search_web", #"{"query":"amber"}"#).message)
        let fixture = try await fixture(harness: harness, provider: provider)
        let host = ChatKernelRunHost(
            dependencies: harness.dependencies, bindings: harness.bindings, backgroundExecution: harness.keepAlive,
            toolLedger: harness.ledger, textProvider: provider, backgroundCoordinator: fixture.coordinator
        )
        var runId: String?
        defer { provider.release(); search.release(); host.cancel(); cleanUp(fixture, runId: runId) }
        host.start(providerSetting: fixture.provider, params: harness.params, inputDigest: "cached-rounds",
                   conversationId: fixture.store.currentConversation?.id, uploadMessages: originalDisplayBaseline,
                   toolExposureBridge: harness.toolExposureBridge)
        let began = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(began)
        let ownedRunId = try XCTUnwrap(host.currentRunId)
        runId = ownedRunId
        let recorded = try await fixture.coordinator.runStore.startChatRun(
            runId: ownedRunId, startedAt: 1, inputDigest: "cached-rounds",
            conversationId: fixture.store.currentConversation?.id.toHexDashString()
        )
        XCTAssertTrue(recorded)
        host.installDurableResponseSessionForTesting()
        host.recordDurableResponseCheckpoint(runId: ownedRunId, responseId: "cached-first", sequenceNumber: 1)
        let requestId = try XCTUnwrap(fixture.coordinator.taskMap().first { $0.value == ownedRunId }?.key)
        let initial = try XCTUnwrap(persistedHandoff(fixture, runId: ownedRunId))
        XCTAssertEqual(initial.runDisplayBaseline?.map(\.id), originalDisplayBaseline.map(\.id))
        fixture.coordinator.withDependenciesForTesting(
            conversationStore: fixture.store, toolRuntime: fixture.runtime, sharedSettings: fixture.settings
        ) { _ = fixture.coordinator.job(for: requestId) }
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.runDisplayBaseline.map(\.id), originalDisplayBaseline.map(\.id))
        provider.release()
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.approvePendingSearchTool()
        let executing = await waitForCondition { search.isExecuting }
        XCTAssertTrue(executing)
        search.release()
        let nextRound = await waitForCondition { provider.callCount == 2 }
        XCTAssertTrue(nextRound)

        let continuation = try XCTUnwrap(persistedHandoff(fixture, runId: ownedRunId))
        XCTAssertEqual(continuation.mode, .continueModel)
        XCTAssertEqual(continuation.runDisplayBaseline?.map(\.id), originalDisplayBaseline.map(\.id))
        XCTAssertEqual(continuation.displayMessages.count, originalDisplayBaseline.count + 1)
        XCTAssertFalse(F.toolPart(toolCallId: "cached-search", in: continuation.displayMessages)?.output.isEmpty ?? true)
        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: fixture.store))
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.runDisplayBaseline.map(\.id), originalDisplayBaseline.map(\.id))
        XCTAssertEqual(fixture.coordinator.activeJobs[requestId]?.displayMessages.count, originalDisplayBaseline.count + 1)
        XCTAssertNotNil(fixture.coordinator.activeBackgroundTasks[requestId],
                        "A hydrated checkpoint is a cached owner, not an already executing continuation")
        let backgroundRequest = await waitForCondition(timeoutSeconds: 2) { provider.callCount == 3 }
        XCTAssertTrue(backgroundRequest)
        XCTAssertFalse(F.toolPart(toolCallId: "cached-search", in: provider.latestUpload)?.output.isEmpty ?? true)
    }

}
