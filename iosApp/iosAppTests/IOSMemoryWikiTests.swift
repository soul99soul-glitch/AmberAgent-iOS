import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryWikiTests: XCTestCase {
    func testNotesSurviveRegenerationRenameReloadAndCanBeReverted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = IOSMemoryWikiNotes(directory: root)
        let store = IOSMemoryMarkdownStore(directory: root, wikiNotes: notes)
        let first = try notes.edit(path: "topics/9-习惯.md", content: "联系前先核对时区。", expectedRevision: "", reason: "补充使用经验")
        store.syncIfChanged(records: [topic(title: "习惯")])
        XCTAssertTrue(try XCTUnwrap(store.readDocument(relativePath: "topics/9-习惯.md")).contains(first.content))
        store.syncIfChanged(records: [topic(title: "新的习惯")])
        XCTAssertTrue(try XCTUnwrap(store.readDocument(relativePath: "topics/9-新的习惯.md")).contains(first.content))
        let loaded = IOSMemoryWikiNotes(directory: root)
        let second = try loaded.edit(path: "topics/9-新的习惯.md", content: "新内容", expectedRevision: first.id, reason: "修订")
        let restored = try loaded.edit(path: second.path, content: "", expectedRevision: second.id, reason: "撤销修订", restoreRevision: first.id)
        XCTAssertEqual(restored.content, first.content)
        XCTAssertEqual(restored.restoredFrom, first.id)
        XCTAssertEqual(loaded.history(path: first.path).count, 3)
        XCTAssertThrowsError(try loaded.edit(path: first.path, content: "旧写入", expectedRevision: first.id, reason: "测试冲突"))
    }

    func testRelativeLinksResolveInsideWikiAndRejectExternalPaths() throws {
        XCTAssertEqual(try IOSMemoryWikiNotes.resolve("../index.md", from: "topics/9-习惯.md"), "index.md")
        XCTAssertEqual(try IOSMemoryWikiNotes.resolve("10-计划.md#详情", from: "topics/9-习惯.md"), "topics/10-计划.md")
        for path in ["../../secrets.md", "/etc/passwd", "https://example.com/a.md", "notes/%2e%2e/%2e%2e/private.md"] {
            XCTAssertThrowsError(try IOSMemoryWikiNotes.resolve(path))
        }
    }

    func testToolWritesNeedApprovalAndDoNotChangeCuratedRecords() throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: original) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IOSMemoryPersistence(fileURL: root.appendingPathComponent("memories.json"))
        persistence.load()
        let prior = IosMemoryFactory.shared.snapshotRecords()
        IosMemoryFactory.shared.replaceAll(records: [topic(title: "习惯")])
        XCTAssertTrue(persistence.persist(previousRecords: prior))
        let suite = "MemoryWikiTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        settings.restoreSnapshot(IosSettingsMutations.shared.setMemoryRuntimeEnabled(
            settings: settings.snapshot, enableCoreMemory: true, enableShortTermMemory: true, enableLongTermMemory: true
        ))
        let runtime = settings.agentRuntime
        let args: [String: Any] = ["action": "wiki_edit", "path": "topics/9-习惯.md", "content": "仅 Agent 笔记", "expected_revision": "", "reason": "补充"]
        XCTAssertEqual(IOSMemoryWikiTool.execute(args: args, runtime: runtime, persistence: persistence, writePolicy: .needsUserAction("approval"))["ok"] as? Bool, false)
        XCTAssertTrue(persistence.wikiNotes.paths.isEmpty)
        XCTAssertEqual(IOSMemoryWikiTool.execute(args: args, runtime: runtime, persistence: persistence, writePolicy: .allow)["ok"] as? Bool, true)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first?.content, "用户确认的原始记忆")
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first?.pinned, true)
        let page = IOSMemoryWikiTool.execute(args: ["action": "wiki_read", "path": "topics/9-习惯.md"], runtime: runtime, persistence: persistence, writePolicy: .allow)
        XCTAssertTrue((page["content"] as? String)?.contains("仅 Agent 笔记") == true)
        XCTAssertTrue((page["links"] as? [String])?.contains("../index.md") == true)
        let index = try XCTUnwrap(persistence.wikiNavigation(runtime: runtime))
        XCTAssertLessThanOrEqual(index.count, 1000)
        XCTAssertFalse(index.contains("仅 Agent 笔记"))
        XCTAssertTrue(IOSMemoryToolExecutor.requiresWriteApproval(input: #"{"action":"wiki_edit"}"#))
        XCTAssertFalse(IOSMemoryToolExecutor.requiresWriteApproval(input: #"{"action":"wiki_read"}"#))
    }

    private func topic(title: String) -> MemoryRecord {
        MemoryRecord(id: 9, content: "用户确认的原始记忆", scope: .core, kind: .topic,
                     assistantId: "__global__", sourceConversationId: "conversation", sourceMessageIds: ["user-message"],
                     supersedesIds: [], expiresAt: nil, confidence: 1, pinned: true, archived: false,
                     createdAt: 1, updatedAt: 2, lastUsedAt: nil, topicTitle: title, memberIds: [], lastReinforcedAt: nil)
    }
}
