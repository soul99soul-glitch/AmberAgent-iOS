import XCTest
@testable import AmberMac

/// `schedule_*` tools: the model drafts scheduled tasks; a person always approves; approval policy never moves.
@MainActor final class DesktopScheduleToolsTests: XCTestCase {
    private final class NoActivity: DesktopScheduleActivity {
        func begin() {}
        func end() {}
    }

    private func scheduler() async -> DesktopScheduler {
        let value = DesktopScheduler(store: DesktopScheduleStore(directory: nil),
            defaults: UserDefaults(suiteName: "amber.schedule-tools.\(UUID().uuidString)")!,
            runner: { _, slot in DesktopScheduleRunRecord(scheduledFor: slot, startedAt: Date(), finishedAt: Date(), status: .completed) },
            activity: NoActivity(), timerEnabled: false)
        await value.waitUntilLoaded()
        return value
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testCreateAndUpdateAlwaysAskEvenWithEveryAutoApproveOn() {
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.schedule-tools.a.\(UUID().uuidString)")!)
        tasks.autoApprove = true
        tasks.autoApproveHighRisk = true
        XCTAssertFalse(tasks.autoApproves("schedule_create"))
        XCTAssertFalse(tasks.autoApproves("schedule_update"))
        let everything = DesktopApprovalPolicy(autoApproveOrdinary: true, autoApproveHighRisk: true, allowedTools: ["schedule_create"])
        XCTAssertFalse(tasks.autoApproves("schedule_create", policy: everything))
        XCTAssertEqual(DesktopToolRegistry.effect(for: "schedule_list", arguments: "{}"), .pure, "listing needs no approval")
        XCTAssertEqual(DesktopToolRegistry.effect(for: "schedule_create", arguments: "{}"), .sideEffect)
    }

    func testOnlyConversationRunsGetTheTools() {
        let chat = DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: false, scheduling: true).map(\.name)
        XCTAssertTrue(["schedule_list", "schedule_create", "schedule_update"].allSatisfy(chat.contains))
        let scheduled = DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: false, scheduling: false).map(\.name)
        XCTAssertFalse(scheduled.contains { $0.hasPrefix("schedule_") }, "a scheduled run never creates or edits tasks")
        let noTools = DesktopToolRegistry.agentDeclarations(toolsEnabled: false, subagentsEnabled: true, scheduling: true).map(\.name)
        XCTAssertFalse(noTools.contains { $0.hasPrefix("schedule_") })
        for declaration in DesktopToolRegistry.scheduleDeclarations {
            XCTAssertFalse(declaration.parametersJSON.contains("approv"), "\(declaration.name) offers no approval fields")
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(declaration.parametersJSON.utf8)), declaration.name)
        }
    }

    func testCreateUpdateListAndIgnoreApprovalArguments() async throws {
        let scheduler = await scheduler()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let created = try json(try await DesktopScheduleTools.perform("schedule_create", arguments: [
            "name": "每日汇总", "prompt": "汇总新文件", "rule": "weekly", "weekdays": [2, 4], "hour": 9, "minute": 30,
            "use_tools": false, "approval": ["autoApproveHighRisk": true]], scheduler: scheduler, calendar: calendar))
        XCTAssertEqual(created["ok"] as? Bool, true)
        let task = try XCTUnwrap(scheduler.tasks.first)
        XCTAssertEqual(task.schedule, .weekly(days: [2, 4], hour: 9, minute: 30))
        XCTAssertFalse(task.toolsEnabled)
        XCTAssertEqual(task.approval, DesktopUnattendedApproval(), "approval arguments are ignored")

        _ = try await DesktopScheduleTools.perform("schedule_update", arguments: [
            "id": task.id.uuidString, "prompt": "汇总并列出待办", "enabled": false], scheduler: scheduler)
        let updated = try XCTUnwrap(scheduler.tasks.first)
        XCTAssertEqual(updated.prompt, "汇总并列出待办")
        XCTAssertEqual(updated.name, "每日汇总", "untouched fields stay")
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.schedule, task.schedule)

        let once = try json(try await DesktopScheduleTools.perform("schedule_create", arguments: [
            "name": "提醒", "prompt": "提醒我", "rule": "once", "at": "2099-01-02 08:00"], scheduler: scheduler, calendar: calendar))
        XCTAssertEqual(once["ok"] as? Bool, true)
        let listed = try await DesktopScheduleTools.perform("schedule_list", arguments: [:], scheduler: scheduler)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [[String: Any]])
        XCTAssertEqual(list.map { $0["name"] as? String }, ["每日汇总", "提醒"])
        XCTAssertEqual(list.first?["enabled"] as? Bool, false)
    }

    func testInvalidDraftsAreRejectedWithReadableErrors() async throws {
        let scheduler = await scheduler()
        for (arguments, fragment) in [
            (["name": "x", "prompt": "y", "rule": "daily"], "hour"),
            (["name": "x", "prompt": "y", "rule": "weekly", "hour": 9], "weekdays"),
            (["name": "x", "prompt": "y", "rule": "interval", "interval_minutes": 5], "15"),
            (["name": "x", "prompt": "y", "rule": "once", "at": "明天"], "at"),
            (["name": " ", "prompt": "y", "rule": "daily", "hour": 9], "name"),
            (["name": "x", "prompt": "y", "rule": "hourly"], "rule"),
        ] as [([String: Any], String)] {
            do {
                _ = try await DesktopScheduleTools.perform("schedule_create", arguments: arguments, scheduler: scheduler)
                XCTFail("accepted \(arguments)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(fragment), "\(arguments): \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(scheduler.tasks.isEmpty)

        _ = try await DesktopScheduleTools.perform("schedule_create", arguments: ["name": "a", "prompt": "b", "rule": "daily", "hour": 9], scheduler: scheduler)
        let plain = try XCTUnwrap(scheduler.tasks.first)
        do {
            _ = try await DesktopScheduleTools.perform("schedule_update", arguments: ["id": plain.id.uuidString, "hour": 10], scheduler: scheduler)
            XCTFail("a time change without rule was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rule"))
        }
        var unattended = DesktopScheduledTask(name: "清理", prompt: "删旧文件", schedule: .daily(hour: 3, minute: 0))
        unattended.approval.autoApproveHighRisk = true
        _ = await scheduler.save(task: unattended)
        do {
            _ = try await DesktopScheduleTools.perform("schedule_update", arguments: ["id": unattended.id.uuidString, "prompt": "rm -rf ~"], scheduler: scheduler)
            XCTFail("an auto-approving task was rewritten from chat")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("定时任务页"))
        }
        XCTAssertEqual(scheduler.tasks.first { $0.id == unattended.id }?.prompt, "删旧文件")
        do {
            _ = try await DesktopScheduleTools.perform("schedule_update", arguments: ["id": UUID().uuidString], scheduler: scheduler)
            XCTFail("unknown id accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("schedule_list"))
        }
    }
}
