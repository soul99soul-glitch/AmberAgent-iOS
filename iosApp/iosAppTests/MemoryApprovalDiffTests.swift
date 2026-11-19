import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class MemoryApprovalDiffTests: XCTestCase {
    func testMemoryApprovalPreviewShowsOldValueAndDiffOnlyWhenTargetExists() {
        IOSMemoryPersistence.shared.load()
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
            IOSMemoryPersistence.shared.persist(previousRecords: [])
            IOSMemoryRecordUndoStore.shared.reset()
        }

        let seed = MemoryRecord(
            id: 901,
            content: "喜欢美式咖啡，不加糖",
            scope: .longTerm,
            kind: .user,
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1.0,
            pinned: false,
            archived: false,
            createdAt: 1_000,
            updatedAt: 1_000,
            lastUsedAt: nil,
            topicTitle: nil,
            memberIds: [],
            lastReinforcedAt: nil
        )
        IosMemoryFactory.shared.replaceAll(records: [seed])

        let editPreview = IOSMemoryToolExecutor.approvalPreview(
            input: #"{"action":"edit","id":901,"content":"喜欢美式咖啡，加少许燕麦奶"}"#
        )
        XCTAssertEqual(editPreview?.oldContentPreview, "喜欢美式咖啡，不加糖")
        XCTAssertTrue(editPreview?.diffPreview?.contains("-喜欢美式咖啡，不加糖") == true)
        XCTAssertTrue(editPreview?.diffPreview?.contains("+喜欢美式咖啡，加少许燕麦奶") == true)

        let deletePreview = IOSMemoryToolExecutor.approvalPreview(
            input: #"{"action":"delete","id":901}"#
        )
        XCTAssertEqual(deletePreview?.oldContentPreview, "喜欢美式咖啡，不加糖")
        XCTAssertTrue(deletePreview?.diffPreview?.contains("-喜欢美式咖啡，不加糖") == true)

        // Create and non-existent edit target have NO old value -> no fabricated diff/restore
        let createPreview = IOSMemoryToolExecutor.approvalPreview(
            input: #"{"action":"create","content":"新记忆内容","scope":"long_term"}"#
        )
        XCTAssertNil(createPreview?.oldContentPreview)
        XCTAssertNil(createPreview?.diffPreview)

        let missingEditPreview = IOSMemoryToolExecutor.approvalPreview(
            input: #"{"action":"edit","id":999999,"content":"覆盖不存在的 ID"}"#
        )
        XCTAssertNil(missingEditPreview?.oldContentPreview)
        XCTAssertNil(missingEditPreview?.diffPreview)
    }

    func testMemoryRevertEditAndDeleteRequirePriorValueAndDetectConflict() throws {
        IOSMemoryPersistence.shared.load()
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
            IOSMemoryPersistence.shared.persist(previousRecords: [])
            IOSMemoryRecordUndoStore.shared.reset()
        }

        IosMemoryFactory.shared.replaceAll(records: [])
        IOSMemoryPersistence.shared.persist(previousRecords: [])
        IOSMemoryRecordUndoStore.shared.reset()

        let settings = IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: "MemoryApprovalDiffTests-\(UUID().uuidString)") ?? .standard)
        let createdJSON = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","content":"初始偏好：早起办公","scope":"long_term","kind":"user"}"#,
            runtime: settings.agentRuntime,
            writePolicy: .allow
        )
        let createdObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(createdJSON.utf8)) as? [String: Any]
        )
        let createdID = try XCTUnwrap((createdObj["memory"] as? [String: Any])?["id"] as? Int)

        // Opus I5: newly created record has NO prior old value -> refuse rollback
        let revertCreate = IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: createdID)
        XCTAssertEqual(revertCreate["ok"] as? Bool, false)

        // Edit existing -> capture old value -> revert succeeds
        _ = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":\#(createdID),"content":"改为晚上办公"}"#,
            runtime: settings.agentRuntime,
            writePolicy: .allow,
            expectedUpdatedAt: IosMemoryFactory.shared.getAllRecords().first(where: { Int($0.id) == createdID })?.updatedAt
        )
        let revertEdit = IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: createdID)
        XCTAssertEqual(revertEdit["ok"] as? Bool, true)
        XCTAssertEqual(
            IosMemoryFactory.shared.getAllRecords().first(where: { Int($0.id) == createdID })?.content,
            "初始偏好：早起办公"
        )

        // Delete -> capture prior record -> revert restores deleted record
        _ = IOSMemoryToolExecutor.execute(
            input: #"{"action":"delete","id":\#(createdID)}"#,
            runtime: settings.agentRuntime,
            writePolicy: .allow
        )
        XCTAssertNil(IosMemoryFactory.shared.getAllRecords().first(where: { Int($0.id) == createdID && !$0.archived }))
        let revertDelete = IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: createdID)
        XCTAssertEqual(revertDelete["ok"] as? Bool, true)
        XCTAssertEqual(
            IosMemoryFactory.shared.getAllRecords().first(where: { Int($0.id) == createdID })?.content,
            "初始偏好：早起办公"
        )
    }

    func testRecordUndoRequiresApprovalCapturedValueAndDeleteUsesArchiveRestore() throws {
        IOSMemoryPersistence.shared.load()
        let original = IosMemoryFactory.shared.getAllRecords()
        let suite = "MemoryUndoReceipt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            IosMemoryFactory.shared.replaceAll(records: original)
            IOSMemoryPersistence.shared.persist(previousRecords: [])
            IOSMemoryRecordUndoStore.shared.reset()
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let created = IOSMemoryToolExecutor.execute(input: #"{"action":"create","scope":"long_term","kind":"user","content":"原始偏好"}"#,
            runtime: settings.agentRuntime, writePolicy: .allow)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created.utf8)) as? [String: Any])
        let id = try XCTUnwrap((result["memory"] as? [String: Any])?["id"] as? Int)
        _ = IOSMemoryToolExecutor.execute(input: "{\"action\":\"edit\",\"id\":\(id),\"content\":\"自动批准的新值\"}",
            runtime: settings.agentRuntime, writePolicy: .allow)
        XCTAssertNil(IOSMemoryRecordUndoStore.shared.entry(for: id), "No approval-captured old value means no edit undo")

        let before = try XCTUnwrap(IosMemoryFactory.shared.getAllRecords().first { Int($0.id) == id })
        _ = IOSMemoryToolExecutor.execute(input: "{\"action\":\"edit\",\"id\":\(id),\"content\":\"已审批的新值\"}",
            runtime: settings.agentRuntime, writePolicy: .allow, expectedUpdatedAt: before.updatedAt)
        let editEntry = try XCTUnwrap(IOSMemoryRecordUndoStore.shared.entry(for: id))
        XCTAssertEqual(IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: id, expectedToken: "stale")["conflict"] as? Bool, true)
        XCTAssertEqual(IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: id, expectedToken: editEntry.token)["ok"] as? Bool, true)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first { Int($0.id) == id }?.content, before.content)

        let deleted = IOSMemoryToolExecutor.execute(input: "{\"action\":\"delete\",\"id\":\(id)}",
            runtime: settings.agentRuntime, writePolicy: .allow)
        XCTAssertTrue(deleted.contains("undo_token"))
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first { Int($0.id) == id }?.archived, true,
                       "Delete is reversible through the existing archive/restore path")
        let deleteEntry = try XCTUnwrap(IOSMemoryRecordUndoStore.shared.entry(for: id))
        XCTAssertEqual(IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: id, expectedToken: deleteEntry.token)["ok"] as? Bool, true)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first { Int($0.id) == id }?.archived, false)
    }

    func testEventKitComparisonPreviewAndCurrentTurnOnlyRollback() {
        IOSEventKitTurnCreationTracker.shared.reset()
        defer { IOSEventKitTurnCreationTracker.shared.reset() }

        let existingEvent = IOSEventKitSnapshotRecord(
            identifier: "ev-1",
            title: "项目评审",
            startAt: "2026-11-16T10:00:00Z",
            endAt: "2026-11-16T11:00:00Z",
            dueAt: nil,
            location: "会议室 A",
            notes: "带方案",
            calendarTitle: "工作"
        )
        let preview = IOSEventKitAgentToolExecutor.approvalComparisonPreview(
            toolName: IOSAppleAgentToolCatalog.calendarEventUpdate,
            arguments: [
                "event_id": "ev-1",
                "title": "项目终审",
                "location": "线上"
            ],
            eventLookup: { id in id == "ev-1" ? existingEvent : nil }
        )
        XCTAssertNotNil(preview)
        XCTAssertTrue(preview?.contains("标题：项目评审 → 项目终审") == true)
        XCTAssertTrue(preview?.contains("地点：会议室 A → 线上") == true)

        let deletePreview = IOSEventKitAgentToolExecutor.approvalComparisonPreview(
            toolName: IOSAppleAgentToolCatalog.calendarEventDelete,
            arguments: ["event_id": "ev-1"],
            eventLookup: { id in id == "ev-1" ? existingEvent : nil }
        )
        XCTAssertTrue(deletePreview?.contains("将删除日历事件") == true)
        XCTAssertTrue(deletePreview?.contains("标题：项目评审") == true)

        // Track current-turn created items vs another turn / pre-existing ID
        IOSEventKitTurnCreationTracker.shared.recordCreated(
            runId: "run-current",
            kind: .event,
            identifier: "ev-turn-1",
            title: "本轮日程"
        )
        IOSEventKitTurnCreationTracker.shared.recordCreated(
            runId: "run-other",
            kind: .event,
            identifier: "ev-other-turn",
            title: "历史轮日程"
        )

        XCTAssertTrue(IOSEventKitTurnCreationTracker.shared.canRollback(identifier: "ev-turn-1", inRunId: "run-current"))
        XCTAssertFalse(IOSEventKitTurnCreationTracker.shared.canRollback(identifier: "ev-other-turn", inRunId: "run-current"))
        XCTAssertFalse(IOSEventKitTurnCreationTracker.shared.canRollback(identifier: "ev-historical", inRunId: "run-current"))

        var removedIDs: [String] = []
        let rollbackResult = IOSEventKitAgentToolExecutor.rollbackCurrentTurnCreatedItems(
            runId: "run-current",
            eventRemover: { id in removedIDs.append(id) }
        )
        XCTAssertEqual(rollbackResult["ok"] as? Bool, true)
        XCTAssertEqual(removedIDs, ["ev-turn-1"])
        XCTAssertEqual(IOSEventKitTurnCreationTracker.shared.createdItems(forRunId: "run-other").count, 1)
    }
}
