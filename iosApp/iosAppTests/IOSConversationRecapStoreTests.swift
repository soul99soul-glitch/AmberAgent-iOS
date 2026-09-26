import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSConversationRecapStoreTests: XCTestCase {
    private struct PendingGeneration {
        let generator: ConversationRecapGenerator
        let provider: BlockingRecapProvider
        let started: XCTestExpectation
        let task: Task<Void, Never>
    }

    func testRecapStorePersistsAndRemovesOnlyTheRequestedConversation() throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationRecapStore(fileURL: fileURL)
        let first = makeRecap(conversationID: "conversation-a", messageID: "message-a")
        let second = makeRecap(conversationID: "conversation-b", messageID: "message-b")

        try store.save(first)
        try store.save(second)

        let reloaded = IOSConversationRecapStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.recap(for: "conversation-a"), first)
        XCTAssertEqual(reloaded.recap(for: "conversation-b"), second)

        try reloaded.removeConversation("conversation-a")
        let afterRemoval = IOSConversationRecapStore(fileURL: fileURL)
        XCTAssertNil(afterRemoval.recap(for: "conversation-a"))
        XCTAssertEqual(afterRemoval.recap(for: "conversation-b"), second)
    }

    func testConversationDeleteAndRestoreClearOnlyAffectedRecaps() async throws {
        let directory = try makeDirectory("ConversationRecapLifecycle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()

        let conversationA = try XCTUnwrap(store.currentConversation?.id)
        let conversationAKey = conversationA.toHexDashString()
        let messagesA = recapEligibleMessages()
        await store.saveCurrent(messages: messagesA)
        try store.recapStore.save(makeRecap(
            conversationID: conversationAKey,
            messageID: ChatMessageProjector.messageId(for: messagesA[0])
        ))
        let documentA = try String(
            contentsOf: directory.appendingPathComponent("\(conversationAKey).json"),
            encoding: .utf8
        )

        await store.newConversation()
        let conversationB = try XCTUnwrap(store.currentConversation?.id)
        let conversationBKey = conversationB.toHexDashString()
        try store.recapStore.save(makeRecap(conversationID: conversationBKey, messageID: "message-b"))

        let restoredCount = try await store.importConversationDocuments([documentA])
        XCTAssertEqual(restoredCount, 1)
        XCTAssertNil(store.recapStore.recap(for: conversationAKey), "Restore must clear recap for the replaced conversation")
        XCTAssertNotNil(store.recapStore.recap(for: conversationBKey), "Restore must retain unrelated recaps")

        await store.newConversation()
        let conversationC = try XCTUnwrap(store.currentConversation?.id)
        let conversationCKey = conversationC.toHexDashString()
        try store.recapStore.save(makeRecap(conversationID: conversationCKey, messageID: "message-c"))

        let didDeleteB = await store.deleteConversation(id: conversationB)
        XCTAssertTrue(didDeleteB)
        XCTAssertNil(store.recapStore.recap(for: conversationBKey), "Delete must clear the deleted conversation recap")
        XCTAssertNotNil(store.recapStore.recap(for: conversationCKey), "Delete must retain unrelated recaps")
    }

    func testConversationBackupExcludesRecapSidecar() async throws {
        let directory = try makeDirectory("ConversationRecapBackup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id.toHexDashString())
        try store.recapStore.save(makeRecap(conversationID: conversationID, messageID: "message-1"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation-recaps.json").path))
        let archive = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: directory))
        let documents = try IOSSyncBackup.conversationDocuments(zipData: archive)

        XCTAssertEqual(documents.count, 1)
        XCTAssertFalse(documents.contains { $0.contains("Recap overview") })
    }

    func testBranchIdentifierUsesTheMessagesCapturedBeforeVariantSelectionChanges() async throws {
        let directory = try makeDirectory("ConversationRecapBranchSnapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        await store.saveCurrent(messages: [
            IOSChatForegroundFixtures.userMessage("Question"),
            IOSChatForegroundFixtures.assistantText("Original answer"),
        ])
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        _ = await store.appendVariant(
            messageIndex: 1,
            message: IOSChatForegroundFixtures.assistantText("Alternate answer")
        )
        let capturedMessages = store.currentMessages
        let capturedBranch = await store.branchIdentifier(for: conversationID, messages: capturedMessages)

        await store.selectVariant(messageIndex: 1, variantIndex: 0)
        let selectedBranch = await store.branchIdentifier(for: conversationID, messages: store.currentMessages)
        let capturedBranchAfterSelection = await store.branchIdentifier(for: conversationID, messages: capturedMessages)

        XCTAssertNotNil(capturedBranch)
        XCTAssertNotNil(selectedBranch)
        XCTAssertNotEqual(capturedBranch, selectedBranch)
        XCTAssertEqual(capturedBranchAfterSelection, capturedBranch)
    }

    func testScheduledGenerationDebouncesAndIgnoresRequestsWhileActive() async throws {
        let directory = try makeDirectory("ConversationRecapSchedule")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let messages = recapEligibleMessages()
        await store.saveCurrent(messages: messages)
        let settings = makeSettings()
        defer { settings.defaults.removePersistentDomain(forName: settings.suite) }
        let started = expectation(description: "debounced recap provider started")
        let response = IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText(#"{"overview":"Recap overview","nodes":[{"kind":"decision","title":"First","messageRef":"m1"},{"kind":"milestone","title":"Second","messageRef":"m2"},{"kind":"artifact","title":"Third","messageRef":"m3"}],"nextSteps":[]}"#))
        let provider = BlockingRecapProvider(response: response) { started.fulfill() }
        let generator = ConversationRecapGenerator(
            conversationStore: store,
            recapStore: store.recapStore,
            textProvider: provider
        )

        generator.schedule(conversationID: conversationID, messages: messages, settings: settings.store)
        generator.schedule(conversationID: conversationID, messages: messages, settings: settings.store)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(provider.callCount, 1)

        generator.schedule(conversationID: conversationID, messages: messages, settings: settings.store)
        XCTAssertEqual(provider.callCount, 1, "An active request must coalesce another schedule for the same conversation")
        provider.release()

        let key = conversationID.toHexDashString()
        for _ in 0..<100 where generator.isLoading(for: key) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(generator.isLoading(for: key))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNotNil(store.recapStore.recap(for: key))
    }

    func testPendingGenerationWritesBackToItsConversationAfterSwitch() async throws {
        let directory = try makeDirectory("ConversationRecapOwnerWrite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationA = try XCTUnwrap(store.currentConversation?.id)
        let messages = recapEligibleMessages()
        await store.saveCurrent(messages: messages)
        let settings = makeSettings()
        defer { settings.defaults.removePersistentDomain(forName: settings.suite) }
        let pending = startPendingGeneration(store: store, conversationID: conversationA, messages: messages, settings: settings.store)
        defer { pending.provider.release() }

        await fulfillment(of: [pending.started], timeout: 2)
        await store.newConversation()
        let conversationB = try XCTUnwrap(store.currentConversation?.id)
        pending.provider.release()
        await pending.task.value

        XCTAssertNotNil(store.recapStore.recap(for: conversationA.toHexDashString()))
        XCTAssertNil(store.recapStore.recap(for: conversationB.toHexDashString()))
        XCTAssertNil(pending.generator.error(for: conversationA.toHexDashString()))
    }

    func testRestoreWhileGenerationIsPendingFencesOldResult() async throws {
        let directory = try makeDirectory("ConversationRecapRestoreFence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let key = conversationID.toHexDashString()
        let messages = recapEligibleMessages()
        await store.saveCurrent(messages: messages)
        try store.recapStore.save(makeRecap(
            conversationID: key,
            messageID: ChatMessageProjector.messageId(for: messages[0])
        ))
        let document = try String(
            contentsOf: directory.appendingPathComponent("\(key).json"),
            encoding: .utf8
        )
        let settings = makeSettings()
        defer { settings.defaults.removePersistentDomain(forName: settings.suite) }
        let pending = startPendingGeneration(store: store, conversationID: conversationID, messages: messages, settings: settings.store)
        defer { pending.provider.release() }

        await fulfillment(of: [pending.started], timeout: 2)
        let restoredCount = try await store.importConversationDocuments([document])
        XCTAssertEqual(restoredCount, 1)
        XCTAssertNil(store.recapStore.recap(for: key), "Restore clears the old recap before the pending result returns")
        pending.provider.release()
        await pending.task.value

        XCTAssertNil(store.recapStore.recap(for: key), "A pre-restore result must not repopulate the recap store")
        XCTAssertNotNil(pending.generator.error(for: key))
    }

    func testDeleteWhileGenerationIsPendingFencesOldResult() async throws {
        let directory = try makeDirectory("ConversationRecapDeleteFence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let key = conversationID.toHexDashString()
        let messages = recapEligibleMessages()
        await store.saveCurrent(messages: messages)
        try store.recapStore.save(makeRecap(
            conversationID: key,
            messageID: ChatMessageProjector.messageId(for: messages[0])
        ))
        let settings = makeSettings()
        defer { settings.defaults.removePersistentDomain(forName: settings.suite) }
        let pending = startPendingGeneration(store: store, conversationID: conversationID, messages: messages, settings: settings.store)
        defer { pending.provider.release() }

        await fulfillment(of: [pending.started], timeout: 2)
        let didDelete = await store.deleteConversation(id: conversationID)
        XCTAssertTrue(didDelete)
        XCTAssertNil(store.recapStore.recap(for: key), "Delete clears the old recap before the pending result returns")
        pending.provider.release()
        await pending.task.value

        XCTAssertNil(store.recapStore.recap(for: key), "A pre-delete result must not recreate a deleted recap")
        XCTAssertNotNil(pending.generator.error(for: key))
    }

    private func startPendingGeneration(
        store: IOSConversationStore,
        conversationID: KotlinUuid,
        messages: [UIMessage],
        settings: IOSSharedSettingsStore
    ) -> PendingGeneration {
        let started = expectation(description: "recap provider started")
        let response = IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText(#"{"overview":"Recap overview","nodes":[{"kind":"decision","title":"First","messageRef":"m1"},{"kind":"milestone","title":"Second","messageRef":"m2"},{"kind":"artifact","title":"Third","messageRef":"m3"}],"nextSteps":[]}"#))
        let provider = BlockingRecapProvider(response: response) { started.fulfill() }
        let generator = ConversationRecapGenerator(
            conversationStore: store,
            recapStore: store.recapStore,
            textProvider: provider
        )
        let task = Task {
            await generator.request(conversationID: conversationID, messages: messages, settings: settings)
        }
        return PendingGeneration(generator: generator, provider: provider, started: started, task: task)
    }

    private func makeSettings() -> (store: IOSSharedSettingsStore, defaults: UserDefaults, suite: String) {
        let suite = "ConversationRecapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Conversation recap test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Conversation recap test model",
            modelId: "gpt-conversation-recap-test"
        )
        let addedProvider = settings.addProvider(provider)
        let chatModel = addedProvider.models.first { $0.type == ModelType.chat }!
        settings.setCurrentChatModelId(chatModel.id.description())
        return (settings, defaults, suite)
    }

    private func recapEligibleMessages() -> [UIMessage] {
        [
            IOSChatForegroundFixtures.userMessage("First question"),
            IOSChatForegroundFixtures.assistantText("First answer"),
            IOSChatForegroundFixtures.userMessage("Second question"),
            IOSChatForegroundFixtures.assistantText("Second answer"),
            IOSChatForegroundFixtures.userMessage("Third question"),
        ]
    }

    private func makeRecap(conversationID: String, messageID: String) -> ConversationRecap {
        ConversationRecap(
            overview: "Recap overview",
            nodes: [ConversationRecap.Node(
                kind: .decision,
                title: "Stored decision",
                messageRef: "m1",
                messageID: messageID
            )],
            nextSteps: [],
            conversationID: conversationID,
            coveredThroughMessageID: messageID,
            branchID: "main",
            generatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStoreURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationRecapStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("conversation-recaps.json"), directory)
    }
}

@MainActor
private final class BlockingRecapProvider: @preconcurrency IOSAgentTextProvider {
    private let response: MessageChunk
    private let onStart: () -> Void
    private var continuations: [CheckedContinuation<MessageChunk, Error>] = []
    private(set) var callCount = 0

    init(response: MessageChunk, onStart: @escaping () -> Void) {
        self.response = response
        self.onStart = onStart
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            callCount += 1
            if callCount == 1 { onStart() }
        }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: response) }
    }
}
