import XCTest
@testable import AmberMac

/// Approval prompts and task-named results for unattended runs.
@MainActor final class DesktopScheduleNotificationTests: XCTestCase {
    private final class Delivery: DesktopNotificationDelivery {
        var sent: [(identifier: String, title: String, body: String, userInfo: [String: String], category: String?)] = []
        var removed: [String] = []
        func requestAuthorization() async throws -> Bool { true }
        func isAuthorized() async -> Bool { true }
        func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws {
            sent.append((identifier, title, body, userInfo, nil))
        }
        func send(identifier: String, title: String, body: String, userInfo: [String: String], category: String?) async throws {
            sent.append((identifier, title, body, userInfo, category))
        }
        func remove(identifiers: [String]) { removed += identifiers }
    }

    private func make() -> (DesktopAgentTasks, Delivery) {
        let defaults = UserDefaults(suiteName: "amber.schedule-notify.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        settings.notificationsEnabled = true
        let delivery = Delivery()
        return (DesktopAgentTasks(defaults: defaults, notifications: DesktopNotifications(settings: settings, delivery: delivery)), delivery)
    }

    private func settle(_ delivery: Delivery, count: Int) async {
        let deadline = Date().addingTimeInterval(2)
        while delivery.sent.count < count, Date() < deadline { await Task.yield() }
    }

    func testOrdinaryApprovalNotificationHasActionsAndApproveContinuesTheRun() async throws {
        let (tasks, delivery) = make()
        let owner = UUID()
        tasks.unattendedConversations[owner] = "每日汇总"
        let runID = try await tasks.begin(conversationID: owner, title: "x", cancel: {})
        let long = String(repeating: "长参数", count: 80)
        try await tasks.requestApproval(runID: runID, approval: DesktopToolApproval(id: "call-1", name: "workspace_file_write",
            arguments: "{\"path\": \"a.txt\",\n  \"content\": \"\(long)\"}", reason: "写入"))
        await settle(delivery, count: 1)
        let note = try XCTUnwrap(delivery.sent.first)
        XCTAssertEqual(note.category, DesktopNotificationAction.approvalCategory)
        XCTAssertEqual(note.title, "⏱ 每日汇总 等待批准")
        XCTAssertTrue(note.body.hasPrefix("工具：workspace_file_write\n参数：{\"path\": \"a.txt\", \"content\""), note.body)
        let excerpt = try XCTUnwrap(note.body.components(separatedBy: "参数：").last)
        XCTAssertLessThanOrEqual(excerpt.count, 120)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertEqual(note.userInfo["toolID"], "call-1")
        XCTAssertEqual(note.userInfo["runID"], runID.uuidString.lowercased())

        let decision = Task { await tasks.awaitDecision(runID: runID, toolID: "call-1") }
        await tasks.decideFromNotification(runID: runID, toolID: "call-1", allow: true)
        let allowed = await decision.value
        XCTAssertTrue(allowed)
        XCTAssertTrue(delivery.removed.contains(DesktopNotificationAction.approvalIdentifier(runID: runID)))
    }

    func testHighRiskApprovalHasNoApproveButtonAndNotificationApproveIsIgnored() async throws {
        let (tasks, delivery) = make()
        let owner = UUID()
        tasks.unattendedConversations[owner] = "清理"
        let runID = try await tasks.begin(conversationID: owner, title: "x", cancel: {})
        try await tasks.requestApproval(runID: runID, approval: DesktopToolApproval(id: "call-1", name: "terminal_exec",
            arguments: "{\"command\":\"rm -rf build\"}", reason: "执行"))
        await settle(delivery, count: 1)
        XCTAssertEqual(delivery.sent.first?.category, DesktopNotificationAction.highRiskApprovalCategory)
        XCTAssertTrue(delivery.sent.first?.body.contains("高风险") == true)

        await tasks.decideFromNotification(runID: runID, toolID: "call-1", allow: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(tasks.records.first?.status, .waiting, "approving a high-risk call from a notification is refused")
        XCTAssertNil(tasks.decision(runID: runID, toolID: "call-1"))

        let decision = Task { await tasks.awaitDecision(runID: runID, toolID: "call-1") }
        await tasks.decideFromNotification(runID: runID, toolID: "call-1", allow: false)
        let allowed = await decision.value
        XCTAssertFalse(allowed, "denying is always allowed")
    }

    func testStaleNotificationForAnotherCallDoesNothing() async throws {
        let (tasks, _) = make()
        let owner = UUID()
        tasks.unattendedConversations[owner] = "汇总"
        let runID = try await tasks.begin(conversationID: owner, title: "x", cancel: {})
        try await tasks.requestApproval(runID: runID, approval: DesktopToolApproval(id: "call-2", name: "workspace_file_write",
            arguments: "{}", reason: "写入"))
        await tasks.decideFromNotification(runID: runID, toolID: "call-1", allow: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(tasks.records.first?.status, .waiting)
        XCTAssertEqual(tasks.records.first?.approval?.id, "call-2")
    }

    func testConversationRunsKeepGenericNoticesAndNoApprovalPush() async throws {
        let (tasks, delivery) = make()
        let runID = try await tasks.begin(conversationID: UUID(), title: "x", cancel: {})
        try await tasks.requestApproval(runID: runID, approval: DesktopToolApproval(id: "c", name: "workspace_file_write",
            arguments: "{}", reason: "写入"))
        await tasks.finish(runID, status: .completed)
        await settle(delivery, count: 1)
        XCTAssertEqual(delivery.sent.map(\.title), ["任务已完成"])
        XCTAssertNil(delivery.sent.first?.category)
    }

    func testUnattendedRunSuppressesGenericNoticeAndScheduleNoticeCarriesTaskName() async throws {
        let (tasks, delivery) = make()
        let owner = UUID()
        tasks.unattendedConversations[owner] = "每日汇总"
        let runID = try await tasks.begin(conversationID: owner, title: "x", cancel: {})
        await tasks.finish(runID, status: .completed)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(delivery.sent.isEmpty, "the scheduler sends the task-named notice instead")

        let defaults = UserDefaults(suiteName: "amber.schedule-notify.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        settings.notificationsEnabled = true
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        var record = DesktopScheduleRunRecord(startedAt: Date(), status: .completed, conversationID: owner)
        await service.notifySchedule(taskName: "每日汇总", record: record)
        record.id = UUID(); record.status = .failed; record.error = "模型报错"
        await service.notifySchedule(taskName: "每日汇总", record: record)
        record.id = UUID(); record.status = .skipped
        let skipped = await service.notifySchedule(taskName: "每日汇总", record: record)
        XCTAssertEqual(delivery.sent.map(\.title), ["⏱ 每日汇总 已完成", "⏱ 每日汇总 未完成"])
        XCTAssertEqual(delivery.sent.last?.body, "模型报错")
        XCTAssertEqual(delivery.sent.first?.userInfo["conversationID"], owner.uuidString.lowercased())
        XCTAssertFalse(skipped, "skipped slots stay quiet")
    }
}
