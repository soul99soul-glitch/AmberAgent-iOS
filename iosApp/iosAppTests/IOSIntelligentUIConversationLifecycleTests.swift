import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUIConversationLifecycleTests: XCTestCase {
    func testConversationOwnerRestoresDraftFromItsBaseDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let source = try saveDraft(in: store, conversationID: id)
        try await store.intelligentUIStateStore.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("task-ui-drafts.json").path))
        let restarted = IOSConversationStore(baseDirectory: directory)
        restarted.intelligentUIStateStore.register(source: source, definition: definition())
        XCTAssertEqual(restarted.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID, "native")
        XCTAssertEqual(restarted.intelligentUIStateStore.activeSource(for: id.toHexDashString()), source)
    }

    func testFailedDeletionKeepsSourceDraftAndSuccessfulDeletionRemovesIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let source = try saveDraft(in: store, conversationID: id)
        try await store.intelligentUIStateStore.flush()
        store.beforeDeleteForTesting = { throw NSError(domain: "DraftDeleteFailure", code: 1) }

        let failed = await store.deleteConversation(id: id)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID, "native")
        store.beforeDeleteForTesting = nil
        let succeeded = await store.deleteConversation(id: id)
        XCTAssertTrue(succeeded)
        XCTAssertNil(store.intelligentUIStateStore.activeSource(for: id.toHexDashString()))
        let restarted = IOSConversationStore(baseDirectory: directory)
        restarted.intelligentUIStateStore.register(source: source, definition: definition())
        XCTAssertNil(restarted.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID)
    }

    func testDeletingParentClearsChildAndGrandchildDraftsButKeepsUnrelatedConversation() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("edges.db").path)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let store = IOSConversationStore(baseDirectory: directory, threadEdgeDaoProvider: { database.threadEdgeDao() })
        await store.bootstrap()
        let root = try XCTUnwrap(store.currentConversation?.id)
        let child = KotlinUuid.companion.random()
        let grandchild = KotlinUuid.companion.random()
        let unrelated = KotlinUuid.companion.random()
        for (id, parent) in [(child, root), (grandchild, child)] {
            try await database.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
                childThreadId: id.toHexDashString(), parentThreadId: parent.toHexDashString(),
                agentPath: "/root/worker", nickname: nil, roleAssistantId: nil,
                forkTurns: "none", status: "Open", createdAt: 1
            ))
        }
        let sources = try [root, child, grandchild, unrelated].map { try saveDraft(in: store, conversationID: $0) }
        try await store.intelligentUIStateStore.flush()

        let succeeded = await store.deleteConversation(id: root)
        XCTAssertTrue(succeeded)
        for source in sources.prefix(3) {
            XCTAssertNil(store.intelligentUIStateStore.activeSource(for: source.conversationID))
            XCTAssertNil(store.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID)
        }
        XCTAssertEqual(store.intelligentUIStateStore.draft(for: sources[3], definition: definition()).selectedOptionID, "native")
        let restarted = IOSConversationStore(baseDirectory: directory)
        for source in sources.prefix(3) {
            restarted.intelligentUIStateStore.register(source: source, definition: definition())
            XCTAssertNil(restarted.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID)
        }
    }

    func testSuccessfulImportInvalidatesOnlyReplacedConversationDrafts() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let firstID = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "restore this conversation")])
        let document = try String(contentsOf: directory.appendingPathComponent("\(firstID).json"), encoding: .utf8)
        let firstSource = try saveDraft(in: store, conversationID: firstID)
        await store.newConversation()
        let unrelatedID = try XCTUnwrap(store.currentConversation?.id)
        let unrelatedSource = try saveDraft(in: store, conversationID: unrelatedID)
        try await store.intelligentUIStateStore.flush()

        let count = try await store.importConversationDocuments([document])
        XCTAssertEqual(count, 1)
        XCTAssertNil(store.intelligentUIStateStore.activeSource(for: firstID.toHexDashString()))
        XCTAssertNil(store.intelligentUIStateStore.draft(for: firstSource, definition: definition()).selectedOptionID)
        XCTAssertEqual(store.intelligentUIStateStore.draft(for: unrelatedSource, definition: definition()).selectedOptionID, "native")
        let restarted = IOSConversationStore(baseDirectory: directory)
        restarted.intelligentUIStateStore.register(source: firstSource, definition: definition())
        XCTAssertNil(restarted.intelligentUIStateStore.draft(for: firstSource, definition: definition()).selectedOptionID)
    }

    func testRejectedImportDoesNotClearExistingDraft() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let source = try saveDraft(in: store, conversationID: id)
        do {
            _ = try await store.importConversationDocuments([#"{"id":"\#(id.toHexDashString())","messageNodes":"invalid"}"#])
            XCTFail("无效会话文档应被拒绝")
        } catch {
            XCTAssertEqual(store.intelligentUIStateStore.draft(for: source, definition: definition()).selectedOptionID, "native")
            XCTAssertEqual(store.intelligentUIStateStore.activeSource(for: id.toHexDashString()), source)
        }
    }

    func testBackupOmitsLocalDraftSidecarAndRetainsConversationDocument() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "backup this conversation")])
        _ = try saveDraft(in: store, conversationID: id)
        try await store.intelligentUIStateStore.flush()
        let draftURL = directory.appendingPathComponent("task-ui-drafts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: directory))
        let documents = try IOSSyncBackup.conversationDocuments(zipData: zip)
        XCTAssertEqual(documents.count, 1)
        XCTAssertTrue(try XCTUnwrap(documents.first).contains("backup this conversation"))
        XCTAssertFalse(documents.contains { $0.contains("definitionFingerprint") })

        let restoredDirectory = directory.appendingPathComponent("restored")
        XCTAssertEqual(try IOSSyncBackup.restoreConversations(zipData: zip, intoDirectory: restoredDirectory), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredDirectory.appendingPathComponent("task-ui-drafts.json").path))
    }

    func testCorruptSidecarLoadAndCleanupFailureUseExistingVisibleErrorBus() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("task-ui-drafts.json")
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: sidecar)
        let store = IOSConversationStore(baseDirectory: directory)
        XCTAssertEqual(store.lastIOError?.operation, "读取任务卡草稿")
        XCTAssertNotNil(store.lastUserVisibleError)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        _ = try saveDraft(in: store, conversationID: id)
        store.clearUserVisibleError()

        let succeeded = await store.deleteConversation(id: id)
        XCTAssertTrue(succeeded, "会话已删除；sidecar 清理错误不能伪装成会话删除失败")
        XCTAssertEqual(store.lastIOError?.operation, "清理任务卡草稿")
        XCTAssertNotNil(store.lastUserVisibleError)
        XCTAssertEqual(try Data(contentsOf: sidecar), corrupt)
    }

    private func saveDraft(in store: IOSConversationStore, conversationID: KotlinUuid) throws -> IOSIntelligentUISource {
        let source = IOSIntelligentUISource(
            conversationID: conversationID.toHexDashString(), messageID: UUID().uuidString,
            textPartIndex: 0, cardID: "implementation-path"
        )
        try store.intelligentUIStateStore.update(
            source: source, definition: definition(), selectedOptionID: "native", values: ["constraints": "本机草稿"]
        )
        return source
    }

    private func definition() -> IOSIntelligentUICardDefinition {
        // Use the real protocol fixture so this lifecycle test follows schema changes.
        do { return try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON) }
        catch { preconditionFailure("task-ui fixture is invalid: \(error)") }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSIntelligentUIConversationLifecycleTests-\(UUID().uuidString)")
    }
}
