import XCTest
@preconcurrency import Shared
@testable import iosApp

/// 会话内并行前台 run 的最小行为回归。
///
/// 每个用例都使用真实 ChatViewModel、真实 IOSConversationStore 和生产 Kernel
/// 路由，只把 provider 换成可控剧本，确保切会话后旧 run 仍按自己的 owner 收口。
@MainActor
final class ChatViewModelConcurrentConversationTests: XCTestCase {

    private final class ImmediateAuxiliaryProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            IOSChatForegroundFixtures.chunk(with: nil)
        }
    }

    private final class ConcurrentConversationProvider: IOSAgentTextProvider, @unchecked Sendable {
        enum Mode: Equatable {
            case text
            case searchApproval
        }

        private let lock = NSLock()
        private let mode: Mode
        private var releasedA = false
        private var startedLabels: Set<String> = []
        private var callCounts: [String: Int] = [:]

        init(mode: Mode) {
            self.mode = mode
        }

        var startedA: Bool {
            lock.withLock { startedLabels.contains("A") }
        }

        var startedB: Bool {
            lock.withLock { startedLabels.contains("B") }
        }

        func releaseA() {
            lock.withLock { releasedA = true }
        }

        func callCount(for label: String) -> Int {
            lock.withLock { callCounts[label, default: 0] }
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let label = messages
                .last(where: { $0.role == MessageRole.user })?
                .toText()
                .contains("A") == true ? "A" : "B"
            let callNumber = lock.withLock { () -> Int in
                startedLabels.insert(label)
                callCounts[label, default: 0] += 1
                return callCounts[label, default: 0]
            }

            if mode == .text, label == "A" {
                while !lock.withLock({ releasedA }) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantText("A reply")
                )
            }

            if mode == .searchApproval, label == "A", callNumber == 1 {
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantMessage(parts: [
                        UIMessagePart.Tool(
                            toolCallId: "search-a",
                            toolName: "search_web",
                            input: #"{"query":"amber"}"#,
                            output: [],
                            approvalState: ToolApprovalState.Auto.shared,
                            streamIndex: nil,
                            metadata: nil
                        )
                    ]),
                    finishReason: "tool_calls"
                )
            }

            let text = label == "A" ? "A approved reply" : "B reply"
            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantText(text)
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ConcurrentConversationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSharedSettings(
        defaults: UserDefaults,
        enableWebSearch: Bool = false
    ) -> IOSSharedSettingsStore {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Concurrent conversation test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Concurrent test model",
            modelId: "gpt-concurrent-test"
        )
        let added = sharedSettings.addProvider(provider)
        let chatModel = added.models.first { $0.type == ModelType.chat }!
        sharedSettings.setCurrentChatModelId(chatModel.id.description())
        if enableWebSearch {
            sharedSettings.restoreSnapshot(
                IosSettingsMutations.shared.setEnableWebSearch(
                    settings: sharedSettings.snapshot,
                    enabled: true
                )
            )
        }
        return sharedSettings
    }

    private func makeStore() throws -> (IOSConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConcurrentConversationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (IOSConversationStore(baseDirectory: directory), directory)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        sharedSettings: IOSSharedSettingsStore,
        store: IOSConversationStore,
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport(),
        auxiliaryTextProvider: any IOSAgentTextProvider = ImmediateAuxiliaryProvider(),
        autoGenerateResponses: Bool = true
    ) -> ChatViewModel {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrent-conversation-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "concurrent-conversation-settings-\(UUID().uuidString)"
            ),
            sharedSettings: sharedSettings,
            searchTransport: searchTransport,
            autoGenerateResponses: autoGenerateResponses,
            auxiliaryTextProvider: auxiliaryTextProvider,
            agentRuntimeDao: db.agentRuntimeDao()
        )
        viewModel.conversationStore = store
        return viewModel
    }

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

    private func waitForStoredMessage(
        store: IOSConversationStore,
        conversationId: KotlinUuid,
        containing text: String,
        timeoutSeconds: Double = 10
    ) async -> [UIMessage]? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let messages = await store.messages(for: conversationId),
               messages.contains(where: { $0.toText().contains(text) }) {
                return messages
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await store.messages(for: conversationId)
    }

    func testNewChatDoesNotReuseFirstConversationBeforeItsAsyncSaveFinishes() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let conversationA = try XCTUnwrap(store.currentConversation?.id)

        let defaults = makeDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults),
            store: store,
            autoGenerateResponses: false
        )
        viewModel.reloadFromStore()

        let reachedFirstPersist = expectation(description: "first user message reached async persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { conversation in
            guard conversation.id == conversationA else { return }
            reachedFirstPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        viewModel.inputText = "first message must stay in A"
        XCTAssertTrue(viewModel.sendMessage())
        await fulfillment(of: [reachedFirstPersist], timeout: 2)

        let didStartNewConversation = await viewModel.startNewConversation()
        XCTAssertTrue(didStartNewConversation)
        let didCreateB = await waitForCondition {
            store.currentConversation?.id != conversationA
        }
        XCTAssertTrue(didCreateB)
        let conversationB = try XCTUnwrap(store.currentConversation?.id)

        store.beforePersistForTesting = nil
        allowPersist?.resume()
        let messagesA = await waitForStoredMessage(
            store: store,
            conversationId: conversationA,
            containing: "first message must stay in A"
        )

        XCTAssertNotEqual(conversationA, conversationB)
        XCTAssertEqual(store.currentConversation?.id, conversationB)
        XCTAssertTrue(try XCTUnwrap(messagesA).contains {
            $0.toText().contains("first message must stay in A")
        })
        XCTAssertTrue(store.currentMessages.isEmpty)
    }

    func testHiddenConversationCompletesAndPersistsToItsOwnConversation() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let conversationA = try XCTUnwrap(store.currentConversation?.id)

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ConcurrentConversationProvider(mode: .text)
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "A request"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.startedA }
        XCTAssertTrue(aStarted)

        let aUserPersisted = await waitForCondition {
            store.currentMessages.contains { $0.toText().contains("A request") }
        }
        XCTAssertTrue(aUserPersisted)

        XCTAssertTrue(viewModel.prepareForConversationChange())
        let didCreateB = await store.startNewConversationReusingEmpty()
        XCTAssertTrue(didCreateB)
        let conversationB = try XCTUnwrap(store.currentConversation?.id)
        XCTAssertNotEqual(conversationA, conversationB)
        viewModel.reloadFromStore()

        viewModel.inputText = "B request"
        XCTAssertTrue(viewModel.sendMessage())
        let bStarted = await waitForCondition { provider.startedB }
        XCTAssertTrue(bStarted)
        let bCompleted = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "B reply"
        }
        XCTAssertTrue(bCompleted)
        XCTAssertTrue(viewModel.isGenerationActive(conversationId: conversationA))

        provider.releaseA()
        let aStopped = await waitForCondition {
            !viewModel.isGenerationActive(conversationId: conversationA)
        }
        XCTAssertTrue(aStopped)
        let storedA = await waitForStoredMessage(
            store: store,
            conversationId: conversationA,
            containing: "A reply"
        )
        let messagesA = try XCTUnwrap(storedA)
        let storedB = await waitForStoredMessage(
            store: store,
            conversationId: conversationB,
            containing: "B reply"
        )
        let messagesB = try XCTUnwrap(storedB)

        XCTAssertTrue(messagesA.contains { $0.toText() == "A reply" })
        XCTAssertFalse(messagesA.contains { $0.toText() == "B reply" })
        XCTAssertTrue(messagesB.contains { $0.toText() == "B reply" })
        XCTAssertFalse(messagesB.contains { $0.toText() == "A reply" })
        XCTAssertEqual(store.currentConversation?.id, conversationB)
        XCTAssertEqual(viewModel.messages.last?.toText(), "B reply")

        XCTAssertTrue(viewModel.prepareForConversationChange(to: conversationA))
        await store.selectConversation(id: conversationA)
        viewModel.reloadFromStore()
        XCTAssertEqual(viewModel.messages.last?.toText(), "A reply")
    }

    func testApprovalStateSurvivesConversationSwitchAndResumesTheOwningRun() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let conversationA = try XCTUnwrap(store.currentConversation?.id)

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults, enableWebSearch: true)
        let provider = ConcurrentConversationProvider(mode: .searchApproval)
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "A approval request"
        XCTAssertTrue(viewModel.sendMessage())
        let aPaused = await waitForCondition { viewModel.pendingSearchApproval != nil }
        XCTAssertTrue(aPaused)
        let approval = try XCTUnwrap(viewModel.pendingSearchApproval)
        let aRunId = WatchTaskCoordinator.shared.currentSnapshot().runId
        XCTAssertFalse(aRunId.isEmpty)

        XCTAssertTrue(viewModel.prepareForConversationChange())
        let didCreateB = await store.startNewConversationReusingEmpty()
        XCTAssertTrue(didCreateB)
        let conversationB = try XCTUnwrap(store.currentConversation?.id)
        viewModel.reloadFromStore()
        XCTAssertNil(viewModel.pendingSearchApproval)

        viewModel.inputText = "B request"
        XCTAssertTrue(viewModel.sendMessage())
        let bStarted = await waitForCondition { provider.startedB }
        XCTAssertTrue(bStarted)
        let bCompleted = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "B reply"
        }
        XCTAssertTrue(bCompleted)

        XCTAssertTrue(viewModel.prepareForConversationChange(to: conversationA))
        await store.selectConversation(id: conversationA)
        viewModel.reloadFromStore()
        XCTAssertEqual(viewModel.pendingSearchApproval?.id, approval.id)

        XCTAssertTrue(viewModel.resolvePendingToolApprovalFromWatch(
            runId: aRunId,
            requestId: approval.id,
            allow: true
        ))
        let aCompleted = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "A approved reply"
        }
        XCTAssertTrue(aCompleted)
        XCTAssertNil(viewModel.pendingSearchApproval)

        let storedA = await waitForStoredMessage(
            store: store,
            conversationId: conversationA,
            containing: "A approved reply"
        )
        let messagesA = try XCTUnwrap(storedA)
        let storedB = await waitForStoredMessage(
            store: store,
            conversationId: conversationB,
            containing: "B reply"
        )
        let messagesB = try XCTUnwrap(storedB)
        XCTAssertTrue(messagesA.contains { $0.toText() == "A approved reply" })
        XCTAssertFalse(messagesA.contains { $0.toText() == "B reply" })
        XCTAssertTrue(messagesB.contains { $0.toText() == "B reply" })
        XCTAssertFalse(messagesB.contains { $0.toText() == "A approved reply" })
    }
}
