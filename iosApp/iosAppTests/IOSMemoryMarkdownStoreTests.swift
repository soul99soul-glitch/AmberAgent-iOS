import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSMemoryMarkdownStoreTests: XCTestCase {
    private var original: [MemoryRecord] = []

    override func setUp() {
        super.setUp()
        original = IosMemoryFactory.shared.snapshotRecords()
    }

    override func tearDown() {
        IosMemoryFactory.shared.replaceAll(records: original)
        super.tearDown()
    }

    func testIndexAndTopicFilesMaterializeAndStaleFilesAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMarkdown-\(UUID().uuidString)", isDirectory: true)
        let suite = "MemoryMarkdown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = IOSMemoryMarkdownStore(directory: root, defaults: defaults)

        let member = record(id: 2, content: "喜欢冰美式。")
        let loose = record(id: 3, content: "临时事项")
        let topic = topicRecord(id: 9, title: "咖啡偏好", summary: "手冲为主", memberIds: [2])
        store.syncIfChanged(records: [member, loose, topic])

        let index = try String(contentsOf: root.appendingPathComponent("index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("[咖啡偏好](topics/9-"))
        XCTAssertTrue(index.contains("共 2 条记忆 · 1 个主题 · 1 条未归类"))

        let topicsDir = root.appendingPathComponent("topics")
        let topicFiles = try FileManager.default.contentsOfDirectory(atPath: topicsDir.path)
        XCTAssertEqual(topicFiles, ["9-咖啡偏好.md"])
        let topicBody = try String(contentsOf: topicsDir.appendingPathComponent("9-咖啡偏好.md"), encoding: .utf8)
        XCTAssertTrue(topicBody.contains("# 咖啡偏好"))
        XCTAssertTrue(topicBody.contains("> 手冲为主"))
        XCTAssertTrue(topicBody.contains("- 喜欢冰美式。"))
        XCTAssertTrue(topicBody.contains("*长期 · 笔记 ·"))
        XCTAssertFalse(topicBody.contains("memory:"), "用户可读文档不得泄漏内部 memory id")

        // 归档主题后重新同步：主题文档被移除，索引不再引用。
        let archived = MemoryRecord(
            id: 9, content: "手冲为主", scope: .longTerm, kind: .topic,
            assistantId: "__long_term__", sourceConversationId: nil, sourceMessageIds: [],
            supersedesIds: [], expiresAt: nil, confidence: 1, pinned: false, archived: true,
            createdAt: 1, updatedAt: 2, lastUsedAt: nil, topicTitle: "咖啡偏好", memberIds: [KotlinInt(value: 2)]
        )
        store.syncIfChanged(records: [member, loose, archived])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: topicsDir.path), [])
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("index.md"), encoding: .utf8).contains("咖啡偏好"))
    }

    func testSignatureSkipsUnchangedRewrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMarkdown-\(UUID().uuidString)", isDirectory: true)
        let suite = "MemoryMarkdown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = IOSMemoryMarkdownStore(directory: root, defaults: defaults)
        let records = [record(id: 1, content: "一条记忆")]

        store.syncIfChanged(records: records)
        let indexURL = root.appendingPathComponent("index.md")
        try "手改".write(to: indexURL, atomically: true, encoding: .utf8)
        store.syncIfChanged(records: records)
        XCTAssertEqual(try String(contentsOf: indexURL, encoding: .utf8), "手改", "签名不变时不得重写")

        store.syncIfChanged(records: records + [record(id: 2, content: "新增", updatedAt: 9)])
        XCTAssertTrue(try String(contentsOf: indexURL, encoding: .utf8).contains("记忆索引"))
    }

    func testListDocumentsExposesIndexThenTopicsWithTitlesAndPreviews() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMarkdown-\(UUID().uuidString)", isDirectory: true)
        let suite = "MemoryMarkdown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = IOSMemoryMarkdownStore(directory: root, defaults: defaults)
        store.syncIfChanged(records: [
            record(id: 2, content: "喜欢冰美式。"),
            topicRecord(id: 9, title: "咖啡偏好", summary: "手冲为主", memberIds: [2]),
        ])

        let docs = store.listDocuments()
        XCTAssertEqual(docs.map(\.relativePath), ["index.md", "topics/9-咖啡偏好.md"])
        XCTAssertEqual(docs[0].title, "Amber 记忆索引")
        XCTAssertEqual(docs[0].preview, "共 1 条记忆 · 1 个主题 · 0 条未归类", "概览行应作为索引预览")
        XCTAssertEqual(docs[1].title, "咖啡偏好")
        XCTAssertEqual(docs[1].preview, "手冲为主")
        XCTAssertGreaterThan(docs[0].sizeBytes, 0)

        // 未归类条目也要进入 index.md，文档视角才完整。
        let loose = record(id: 3, content: "临时事项")
        store.syncIfChanged(records: [
            record(id: 2, content: "喜欢冰美式。"),
            loose,
            topicRecord(id: 9, title: "咖啡偏好", summary: "手冲为主", memberIds: [2]),
        ])
        let index = store.readDocument(relativePath: "index.md") ?? ""
        XCTAssertTrue(index.contains("## 未归类"))
        XCTAssertTrue(index.contains("临时事项"))

        // 越界路径被拒绝。
        XCTAssertNil(store.readDocument(relativePath: "../memories.json"))
        XCTAssertNil(store.readDocument(relativePath: "topics/../../secrets"))
    }

    func testEmptyStoreLeavesNoDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMarkdown-\(UUID().uuidString)", isDirectory: true)
        let suite = "MemoryMarkdown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = IOSMemoryMarkdownStore(directory: root, defaults: defaults)

        store.syncIfChanged(records: [])
        XCTAssertTrue(store.listDocuments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.md").path))

        // 清空后残留的 index.md 与主题文档也必须被清掉。
        store.syncIfChanged(records: [
            record(id: 2, content: "喜欢冰美式。"),
            topicRecord(id: 9, title: "咖啡偏好", summary: "手冲为主", memberIds: [2]),
        ])
        XCTAssertEqual(store.listDocuments().count, 2)
        store.syncIfChanged(records: [])
        XCTAssertTrue(store.listDocuments().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("topics").path), [])
    }

    func testSlugKeepsCJKAndCollapsesPunctuation() {
        XCTAssertEqual(IOSMemoryMarkdownStore.slug("咖啡偏好"), "咖啡偏好")
        XCTAssertEqual(IOSMemoryMarkdownStore.slug("Foo  Bar!!"), "foo-bar")
        XCTAssertEqual(IOSMemoryMarkdownStore.slug(""), "topic")
        XCTAssertEqual(IOSMemoryMarkdownStore.slug("---"), "topic")
    }

    private func record(id: Int32, content: String, updatedAt: Int64 = 1) -> MemoryRecord {
        MemoryRecord(
            id: id, content: content, scope: .longTerm, kind: .note,
            assistantId: "__long_term__", sourceConversationId: nil, sourceMessageIds: [],
            supersedesIds: [], expiresAt: nil, confidence: 1, pinned: false, archived: false,
            createdAt: updatedAt, updatedAt: updatedAt, lastUsedAt: nil,
            topicTitle: nil, memberIds: []
        )
    }

    private func topicRecord(id: Int32, title: String, summary: String, memberIds: [Int32]) -> MemoryRecord {
        MemoryRecord(
            id: id, content: summary, scope: .longTerm, kind: .topic,
            assistantId: "__long_term__", sourceConversationId: nil, sourceMessageIds: [],
            supersedesIds: [], expiresAt: nil, confidence: 1, pinned: false, archived: false,
            createdAt: 1, updatedAt: 1, lastUsedAt: nil,
            topicTitle: title, memberIds: memberIds.map { KotlinInt(value: $0) }
        )
    }
}
