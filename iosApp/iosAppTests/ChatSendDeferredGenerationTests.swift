import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Regression coverage for the "send-time deferred generation start" timing
/// contract in `ChatViewModel.sendUserMessage` / `startDeferredGeneration`.
///
/// Composer sends (`startsGenerationAfterInsertion: true`) append the user
/// bubble and flip `isLoading` immediately, but intentionally hold off on
/// actually starting the Kernel run until the user-message entrance spring
/// (`ChatViewModel.userMessageSendSpring`, ~0.34s) has visually settled — the
/// main-thread work to assemble params/tools/memory recall would otherwise
/// stall that animation. Several call sites must be able to "pull forward"
/// that pending start before the timer fires (re-send, cancel, new
/// conversation, Watch question) so a same-run action never races the
/// deferred Task. These tests exercise that contract against a real
/// `ChatViewModel` + real `IOSConversationStore` + a scripted provider,
/// mirroring the harness pattern in `ChatViewModelConcurrentConversationTests`.
@MainActor
final class ChatSendDeferredGenerationTests: XCTestCase {

    /// Records every `generateText` invocation so tests can assert "started
    /// exactly once" / "never called" without depending on wall-clock timing.
    /// Optionally blocks (cancellable poll, not a fixed sleep) after
    /// recording the call until `release()` is invoked — this lets a test
    /// observe the "started but not yet finished" window deterministically
    /// instead of racing a same-process fake reply that can complete in well
    /// under a millisecond.
    private final class RecordingTextProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var released = true
        var replyText = "assistant reply"

        var callCount: Int { lock.withLock { count } }

        func holdUntilReleased() {
            lock.withLock { released = false }
        }

        func release() {
            lock.withLock { released = true }
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            lock.withLock { count += 1 }
            while !lock.withLock({ released }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantText(replyText)
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ChatSendDeferredGenerationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSharedSettings(defaults: UserDefaults) -> IOSSharedSettingsStore {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Deferred generation test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Deferred test model",
            modelId: "gpt-deferred-test"
        )
        let added = sharedSettings.addProvider(provider)
        let chatModel = added.models.first { $0.type == ModelType.chat }!
        sharedSettings.setCurrentChatModelId(chatModel.id.description())
        return sharedSettings
    }

    private func makeStore() throws -> (IOSConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatSendDeferredGenerationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (IOSConversationStore(baseDirectory: directory), directory)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        sharedSettings: IOSSharedSettingsStore,
        store: IOSConversationStore
    ) -> ChatViewModel {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("deferred-generation-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "deferred-generation-settings-\(UUID().uuidString)"
            ),
            sharedSettings: sharedSettings,
            searchTransport: IOSForegroundNoopSearchTransport(),
            autoGenerateResponses: true,
            agentRuntimeDao: db.agentRuntimeDao()
        )
        viewModel.conversationStore = store
        return viewModel
    }

    /// Polls a synchronous condition instead of sleeping a fixed duration —
    /// used both to await a positive outcome (with a generous timeout) and,
    /// with a short timeout, to assert an outcome does *not* happen (the
    /// call returns `false` once the timeout is reached without the
    /// condition ever becoming true).
    private func waitForCondition(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// - Returns: the view model plus its `store` and `directory`, both of
    ///   which the caller MUST hold onto for the lifetime of the test.
    ///   `ChatViewModel.conversationStore` is `weak`, so if the store isn't
    ///   kept alive by a strong reference somewhere it is deallocated as
    ///   soon as this helper returns; `currentConversationId` then silently
    ///   reads back nil (with no crash) and every conversation-keyed lookup
    ///   quietly degrades to an untracked "" run bucket instead of failing loudly.
    private func makeReadyViewModel(
        provider: RecordingTextProvider
    ) async throws -> (ChatViewModel, IOSConversationStore, URL) {
        let (store, directory) = try makeStore()
        // Bootstrap gives the store a real current conversation; without it
        // `ChatViewModel.currentConversationId` stays nil, which in turn
        // makes `currentConversationRunId` always report nil regardless of
        // whether a run actually started (it keys off the conversation id).
        await store.bootstrap()
        let defaults = makeDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults),
            store: store
        )
        // Must be injected before the first send: the per-conversation Host
        // is lazily built then, and its provider override sticks for the
        // conversation's lifetime (see `kernelTextProviderOverrideForTesting`
        // doc comment on ChatViewModel).
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()
        return (viewModel, store, directory)
    }

    // MARK: - 1) Composer send: immediate append, deferred single start

    func testComposerSendAppendsImmediatelyButDefersGenerationStartUntilEntranceSettles() async throws {
        let provider = RecordingTextProvider()
        // Hold the reply so the "started but not finished" window is wide
        // enough to observe deterministically — a same-process fake reply
        // with no delay can start and fully complete faster than a 10ms
        // poll would ever catch.
        provider.holdUntilReleased()
        let (viewModel, store, directory) = try await makeReadyViewModel(provider: provider)
        _ = store // keep the store (weakly referenced by viewModel) alive for the whole test
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.inputText = "hello deferred window"
        XCTAssertTrue(viewModel.sendMessage(startsGenerationAfterInsertion: true))

        // Right after the composer-send call returns (still on the same
        // synchronous call stack, before the deferred Task's `Task.sleep`
        // can possibly have fired): the user bubble and isLoading=true land
        // immediately, but the Kernel run itself must NOT have started yet —
        // that's the entire point of deferring past the entrance spring.
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.last?.toText(), "hello deferred window")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isGenerationActive, "kernel must not be running before the entrance spring settles")
        XCTAssertEqual(provider.callCount, 0, "provider must not be called before the entrance spring settles")

        // After the entrance-animation window elapses, generation starts —
        // and starts exactly once.
        let started = await waitForCondition(timeoutSeconds: 10) { provider.callCount >= 1 }
        XCTAssertTrue(started, "generation should auto-start once the deferred window elapses")
        let becameActive = await waitForCondition(timeoutSeconds: 1) { viewModel.isGenerationActive }
        XCTAssertTrue(becameActive)

        // No duplicate start: waiting further must not produce a second call.
        let calledTwice = await waitForCondition(timeoutSeconds: 1) { provider.callCount >= 2 }
        XCTAssertFalse(calledTwice, "the deferred token must guarantee a single start")
        XCTAssertEqual(provider.callCount, 1)

        // Let the held run finish so its terminal write lands cleanly.
        provider.release()
        let finished = await waitForCondition(timeoutSeconds: 10) { !viewModel.isGenerationActive }
        XCTAssertTrue(finished)
    }

    // MARK: - 2) cancelGeneration() during the deferred window

    func testCancelDuringDeferredWindowStartsThenImmediatelyCancelsWithNoLateRestart() async throws {
        let provider = RecordingTextProvider()
        let (viewModel, store, directory) = try await makeReadyViewModel(provider: provider)
        _ = store // keep the store (weakly referenced by viewModel) alive for the whole test
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.inputText = "cancel me before I start"
        XCTAssertTrue(viewModel.sendMessage(startsGenerationAfterInsertion: true))
        XCTAssertNil(viewModel.currentConversationRunId, "still inside the deferred window: no run created yet")
        XCTAssertFalse(viewModel.isGenerationActive)

        viewModel.cancelGeneration()

        // `cancelGeneration()` calls `startDeferredGenerationNow()` as its
        // very first step, so the pending run is pulled forward and created
        // synchronously (Kernel `start()` sets `currentRunId` synchronously)
        // before `cancel()` is asked to stop it. Observing a non-nil run id
        // right here — on the same call stack, before Kernel teardown can
        // possibly have run — is the proof that generation really was
        // started (not silently dropped) ahead of being cancelled.
        XCTAssertNotNil(viewModel.currentConversationRunId, "cancel must pull the deferred start forward before cancelling it")

        // Kernel teardown (clearing currentRunId / isLoading) happens on an
        // async Task even for a same-tick cancel, so poll for the terminal
        // state instead of asserting it synchronously.
        let settledToCancelled = await waitForCondition(timeoutSeconds: 10) {
            !viewModel.isGenerationActive && !viewModel.isLoading
        }
        XCTAssertTrue(settledToCancelled, "run must reach a cancelled terminal state")

        // No assistant reply should ever have landed: a plain-text run that
        // gets cancelled this early must not silently complete instead.
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.toText(), "cancel me before I start")

        // No delayed self-restart: waiting past where the entrance spring
        // would have fired must not flip generation back on.
        let restarted = await waitForCondition(timeoutSeconds: 1) { viewModel.isGenerationActive }
        XCTAssertFalse(restarted, "a cancelled deferred start must not resurrect itself later")
    }

    // MARK: - 3) Second composer send during the deferred window queues as steer

    func testSecondComposerSendDuringDeferredWindowQueuesAsSteerNotConcurrentRun() async throws {
        let provider = RecordingTextProvider()
        let (viewModel, store, directory) = try await makeReadyViewModel(provider: provider)
        _ = store // keep the store (weakly referenced by viewModel) alive for the whole test
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.inputText = "first"
        XCTAssertTrue(viewModel.sendMessage(startsGenerationAfterInsertion: true))
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertFalse(viewModel.isGenerationActive)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertTrue(viewModel.steerQueue.isEmpty)

        viewModel.inputText = "second"
        XCTAssertTrue(viewModel.sendMessage(startsGenerationAfterInsertion: true))

        // `sendMessage` calls `startDeferredGenerationNow()` as its first
        // line, so the first turn's run is already created by the time this
        // call inspects `isGenerationActive` further down — which is exactly
        // why the second turn cannot become a second concurrent run: it must
        // fall into the steer queue instead. This is all synchronous (no
        // await between the two `sendMessage` calls), so it's safe to assert
        // directly without polling.
        XCTAssertTrue(viewModel.isGenerationActive, "first turn's deferred start must be pulled forward by the second send")
        XCTAssertEqual(viewModel.messages.count, 1, "the second send must not append a second user bubble/run")
        XCTAssertEqual(viewModel.messages.last?.toText(), "first")
        XCTAssertEqual(viewModel.steerQueue.count, 1, "the second turn must land in the steer queue")
        XCTAssertEqual(viewModel.steerQueue.first?.text, "second")

        // The first (and only) run does progress...
        let started = await waitForCondition(timeoutSeconds: 10) { provider.callCount >= 1 }
        XCTAssertTrue(started)
        // ...and while it's in flight, no second concurrent run/provider call
        // is ever observed.
        let calledTwice = await waitForCondition(timeoutSeconds: 1) { provider.callCount >= 2 }
        XCTAssertFalse(calledTwice, "no concurrent run may start while the first is still active")
        XCTAssertEqual(provider.callCount, 1)
    }

    // MARK: - 4) Default sendMessage() still starts generation synchronously

    func testDefaultSendMessageStartsGenerationSynchronously() async throws {
        let provider = RecordingTextProvider()
        let (viewModel, store, directory) = try await makeReadyViewModel(provider: provider)
        _ = store // keep the store (weakly referenced by viewModel) alive for the whole test
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.inputText = "watch / deep-link style send"
        // Default `sendMessage()` (startsGenerationAfterInsertion: false) is
        // the path used by Watch questions and deep links; it must keep
        // starting generation synchronously (no deferred window) so callers
        // that read `kernelRunHost.currentRunId` right after this call
        // (e.g. `startWatchQuestion`) keep working.
        XCTAssertTrue(viewModel.sendMessage())

        XCTAssertTrue(viewModel.isGenerationActive, "non-composer sendMessage() must start the run before returning")
        XCTAssertNotNil(viewModel.currentConversationRunId)

        let started = await waitForCondition(timeoutSeconds: 10) { provider.callCount >= 1 }
        XCTAssertTrue(started)
    }
}
