import Foundation
import XCTest
@testable import AmberMac

@MainActor final class DesktopKnowledgeTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("amber-knowledge-" + UUID().uuidString) }
    private let skillMarkdown = """
    ---
    name: review-notes
    description: >
      检查笔记内容
      并核对来源
    allowed-tools: [memory_tool, use_skill]
    ---

    # 检查步骤
    逐条核对笔记与原始来源。
    """

    func testSkillImportEditEnableDeleteSurvivesRestart() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("SKILL.md")
        try Data(skillMarkdown.utf8).write(to: source)
        let directory = root.appendingPathComponent("Knowledge")
        let store = DesktopKnowledgeStore(directory: directory)
        XCTAssertEqual(try store.importSkill(from: source), "review-notes")
        XCTAssertEqual(store.skills.first?.allowedTools, ["memory_tool", "use_skill"])
        XCTAssertEqual(store.skills.first?.description, "检查笔记内容 并核对来源")
        XCTAssertFalse(try store.requestContext(query: "").contains("review-notes"))
        XCTAssertThrowsError(try store.executeTool(name: "use_skill", argumentsJSON: #"{"name":"review-notes"}"#))
        try store.setSkillEnabled("review-notes", enabled: true)
        XCTAssertTrue(try store.requestContext(query: "").contains("review-notes"))
        let edited = skillMarkdown.replacingOccurrences(of: "检查步骤", with: "修订步骤")
        try store.saveSkill(name: "review-notes", markdown: edited)
        XCTAssertThrowsError(try store.saveSkill(name: "review-notes", markdown: edited.replacingOccurrences(of: "review-notes", with: "renamed")))
        let restarted = DesktopKnowledgeStore(directory: directory)
        XCTAssertNil(restarted.loadError)
        XCTAssertEqual(restarted.skills.first?.markdown, edited)
        XCTAssertTrue(restarted.skills.first?.enabled == true)
        XCTAssertTrue(try restarted.executeTool(name: "use_skill", argumentsJSON: #"{"name":"review-notes"}"#).contains("修订步骤"))
        XCTAssertThrowsError(try restarted.executeTool(name: "use_skill", argumentsJSON: #"{"name":"review-notes","path":"../secret"}"#))
        try restarted.deleteSkill(name: "review-notes")
        XCTAssertTrue(DesktopKnowledgeStore(directory: directory).skills.isEmpty)
        try restarted.importSkill(from: source)
        XCTAssertFalse(DesktopKnowledgeStore(directory: directory).skills.first?.enabled ?? true)
    }

    func testSoulTextAndSourcePersistWithoutStaleProvenance() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        try store.saveSoul("# 核心指令\r\n用中文回答。", source: "导入的 SOUL.md")
        let restarted = DesktopKnowledgeStore(directory: directory)
        XCTAssertEqual(restarted.soulMarkdown, "# 核心指令\n用中文回答。")
        XCTAssertEqual(restarted.soulSource, "导入的 SOUL.md")
        XCTAssertTrue(try restarted.requestContext(query: "").contains("用中文回答。"))
        try Data("外部编辑后的指令".utf8).write(to: directory.appendingPathComponent("SOUL.md"))
        try restarted.reload()
        XCTAssertEqual(restarted.soulSource, "本地 SOUL.md")
        XCTAssertThrowsError(try restarted.saveSoul(String(repeating: "大", count: 64_001)))
        XCTAssertEqual(restarted.soulMarkdown, "外部编辑后的指令")
        try restarted.saveSoul("")
        XCTAssertNil(DesktopKnowledgeStore(directory: directory).soulSource)
    }

    func testExistingIOSMemoryJSONKeepsAllProvenanceAndWireFields() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories/memories.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"[{"id":1002,"content":"喜欢中文回答","scope":"long_term","kind":"user","assistantId":"assistant-uuid","sourceConversationId":"conversation-id","sourceMessageIds":["message-a","message-b"],"supersedesIds":[998],"expiresAt":4102444800000,"confidence":0.8,"pinned":true,"archived":false,"createdAt":100,"updatedAt":200,"lastUsedAt":300,"topicTitle":null,"memberIds":[],"lastReinforcedAt":400}]"#
        try Data(json.utf8).write(to: url)
        let store = DesktopKnowledgeStore(directory: directory)
        XCTAssertNil(store.loadError)
        var original = try XCTUnwrap(store.memories.first)
        original.content = "仍然喜欢中文回答"
        let updated = try store.saveMemory(original)
        XCTAssertEqual(updated.assistantId, "assistant-uuid")
        XCTAssertEqual(updated.createdAt, 100)
        XCTAssertEqual(updated.sourceMessageIds, ["message-a", "message-b"])
        XCTAssertEqual(updated.sourceConversationId, "conversation-id")
        XCTAssertEqual(updated.expiresAt, 4_102_444_800_000)
        XCTAssertEqual(updated.lastReinforcedAt, 400)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(persisted.first?["scope"] as? String, "long_term")
        XCTAssertEqual(persisted.first?["supersedesIds"] as? [Int], [998])
        XCTAssertEqual(try store.saveMemory(DesktopMemoryRecord(content: "下一条")).id, 1003)
        XCTAssertEqual(DesktopKnowledgeStore(directory: directory).memories.first, updated)
    }

    func testChineseRecallFiltersExpiredArchivedAndUnrelatedRecords() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        var coffee = DesktopMemoryRecord(content: "用户每天喝咖啡，喜欢拿铁。", kind: .note)
        coffee.sourceConversationId = "origin-conversation"
        let matching = try store.saveMemory(coffee)
        var expired = DesktopMemoryRecord(content: "咖啡过期信息", scope: .core)
        expired.expiresAt = now - 1; expired.pinned = true
        let expiredID = try store.saveMemory(expired).id
        var archived = DesktopMemoryRecord(content: "咖啡归档信息")
        archived.archived = true
        let archivedID = try store.saveMemory(archived).id
        let unrelated = try store.saveMemory(DesktopMemoryRecord(content: "假期安排在海边。"))
        let core = try store.saveMemory(DesktopMemoryRecord(content: "始终用中文沟通。", scope: .core))
        let recalled = store.recall(query: "咖啡偏好", now: now)
        XCTAssertEqual(Set(recalled.map(\.id)), [matching.id, core.id])
        XCTAssertFalse(recalled.contains { [expiredID, archivedID, unrelated.id].contains($0.id) })
        XCTAssertEqual(recalled.first(where: { $0.id == matching.id })?.sourceConversationId, "origin-conversation")
        let context = store.memoryContext(query: "咖啡偏好")
        XCTAssertEqual(Set(context.records.map(\.id)), [matching.id, core.id])
        XCTAssertTrue(context.prompt.contains("memory_id=\(matching.id)"))
        XCTAssertTrue(context.prompt.contains("untrusted context"))
    }

    func testFailedPersistenceDoesNotPublishAndCorruptStoreIsPreserved() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        let saved = try store.saveMemory(DesktopMemoryRecord(content: "已成功保存"))
        let memoriesDirectory = directory.appendingPathComponent("memories")
        try FileManager.default.removeItem(at: memoriesDirectory)
        try Data("阻止目录创建".utf8).write(to: memoriesDirectory)
        var change = saved; change.content = "未保存的变化"
        XCTAssertThrowsError(try store.saveMemory(change))
        XCTAssertEqual(store.memories, [saved])
        try FileManager.default.removeItem(at: memoriesDirectory)
        try FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
        let corrupt = Data("[{ damaged]".utf8)
        let url = memoriesDirectory.appendingPathComponent("memories.json")
        try corrupt.write(to: url)
        let reopened = DesktopKnowledgeStore(directory: directory)
        XCTAssertNotNil(reopened.loadError)
        XCTAssertThrowsError(try reopened.saveMemory(DesktopMemoryRecord(content: "不可覆盖")))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testMemoryToolActuallyCreatesEditsSearchesAndDeletes() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        _ = try store.executeTool(name: "memory_tool", argumentsJSON: #"{"action":"create","content":"喜欢咖啡","scope":"long_term","kind":"note","sourceConversationId":"origin","sourceMessageIds":["m1"],"expiresAt":4102444800000}"#)
        let id = try XCTUnwrap(store.memories.first?.id)
        _ = try store.executeTool(name: "memory_tool", argumentsJSON: "{\"action\":\"edit\",\"id\":\(id),\"content\":\"喜欢无糖咖啡\",\"pinned\":true}")
        XCTAssertEqual(store.memories.first?.content, "喜欢无糖咖啡")
        XCTAssertEqual(store.memories.first?.sourceMessageIds, ["m1"])
        XCTAssertTrue(try store.executeTool(name: "memory_tool", argumentsJSON: #"{"action":"search","query":"咖啡"}"#).contains("无糖咖啡"))
        XCTAssertThrowsError(try store.executeTool(name: "memory_tool", argumentsJSON: #"{"action":"create","content":"无效","confidence":2}"#))
        XCTAssertEqual(store.memories.count, 1)
        _ = try store.executeTool(name: "memory_tool", argumentsJSON: "{\"action\":\"delete\",\"id\":\(id)}")
        XCTAssertTrue(DesktopKnowledgeStore(directory: directory).memories.isEmpty)
    }

    func testIOSAggregateTopicAndToolScopeFilteringBeforeLimit() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories/memories.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var records = (1...45).map { id in
            var record = DesktopMemoryRecord(content: "条目 \(id)", scope: id == 45 ? .core : .longTerm)
            record.id = id
            return record
        }
        var topic = DesktopMemoryRecord(content: "", kind: .topic)
        topic.id = 46; topic.topicTitle = "咖啡偏好"; topic.memberIds = [1, 2]
        records.append(topic)
        try JSONEncoder().encode(records).write(to: url)
        let store = DesktopKnowledgeStore(directory: directory)
        XCTAssertNil(store.loadError)
        XCTAssertTrue(store.memoryContext(query: "咖啡偏好").prompt.contains("咖啡偏好"))
        let result = try store.executeTool(name: "memory_tool", argumentsJSON: #"{"action":"list","scope":"core","limit":1}"#)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let memories = try XCTUnwrap(payload["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.first?["id"] as? Int, 45)
        XCTAssertEqual(payload["total"] as? Int, 1)
    }

    func testBackupMemoryMergeRemapsNumericLinksAndRollsBackOnlyRestoredCopies() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        let existing = try store.saveMemory(DesktopMemoryRecord(content: "保留当前记忆"))
        let oldConversation = UUID(), newConversation = UUID()
        var imported = DesktopMemoryRecord(content: "恢复来源")
        imported.id = existing.id; imported.sourceConversationId = oldConversation.uuidString
        imported.sourceMessageIds = ["m-original"]; imported.expiresAt = 4_102_444_800_000
        var topic = DesktopMemoryRecord(content: "恢复主题", kind: .topic)
        topic.id = existing.id + 1; topic.memberIds = [imported.id, 998]; topic.supersedesIds = [imported.id]
        let ids = try store.mergeRestoredMemories([imported, topic], conversationIDs: [oldConversation: newConversation])
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertFalse(ids.contains(existing.id))
        let restored = try XCTUnwrap(store.memories.first { $0.id == ids[0] })
        XCTAssertEqual(restored.sourceConversationId, newConversation.uuidString)
        XCTAssertEqual(restored.sourceMessageIds, ["m-original"])
        XCTAssertEqual(restored.expiresAt, imported.expiresAt)
        let restoredTopic = try XCTUnwrap(store.memories.first { $0.id == ids[1] })
        XCTAssertEqual(restoredTopic.memberIds, [ids[0]])
        XCTAssertEqual(restoredTopic.supersedesIds, [ids[0]])
        try store.removeRestoredMemories(ids: ids)
        XCTAssertEqual(store.memories, [existing])
        XCTAssertEqual(DesktopKnowledgeStore(directory: directory).memories, [existing])
    }

    func testDeletedMemoryIDsAreNeverReusedAfterRestartOrRestore() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopKnowledgeStore(directory: directory)
        var retained = try store.saveMemory(DesktopMemoryRecord(content: "保留的记录"))
        let removed = try store.saveMemory(DesktopMemoryRecord(content: "删除的最高编号"))
        retained.supersedesIds = [removed.id]; retained.memberIds = [removed.id]
        _ = try store.saveMemory(retained)
        try store.deleteMemory(id: removed.id)
        let reopened = DesktopKnowledgeStore(directory: directory)
        XCTAssertEqual(reopened.memories.first?.supersedesIds, [])
        XCTAssertEqual(reopened.memories.first?.memberIds, [])
        let next = try reopened.saveMemory(DesktopMemoryRecord(content: "新记录不能继承旧编号"))
        XCTAssertGreaterThan(next.id, removed.id)
        try reopened.deleteMemory(id: next.id)
        let again = DesktopKnowledgeStore(directory: directory)
        let restoredIDs = try again.mergeRestoredMemories([removed], conversationIDs: [:])
        XCTAssertGreaterThan(try XCTUnwrap(restoredIDs.first), next.id)
    }
}
