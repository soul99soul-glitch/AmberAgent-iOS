import XCTest
@testable import AmberMac

/// A calendar service that never touches the user's real EventKit store.
@MainActor final class FakeCalendarService: DesktopCalendarService {
    var calendarAuthorization: DesktopCalendarAuthorization = .granted
    var reminderAuthorization: DesktopCalendarAuthorization = .granted
    /// Set to simulate the user dismissing the system prompt.
    var grantOnRequest = true
    private(set) var requestCount = 0
    var events: [DesktopCalendarEventRecord] = []
    var reminders: [DesktopCalendarReminderRecord] = []
    private(set) var deleted: [String] = []
    private(set) var savedEvents: [DesktopCalendarEventRecord] = []
    var nextID = 1
    var failOnSave: String?

    func authorization(for kind: DesktopCalendarKind) -> DesktopCalendarAuthorization {
        kind == .calendar ? calendarAuthorization : reminderAuthorization
    }

    func requestAccess(for kind: DesktopCalendarKind) async throws {
        requestCount += 1
        guard grantOnRequest else { return }
        if kind == .calendar { calendarAuthorization = .granted } else { reminderAuthorization = .granted }
    }

    func events(from start: Date, to end: Date, limit: Int) throws -> [DesktopCalendarEventRecord] {
        events.filter { record in
            guard let startDate = Self.parse(record.start), let endDate = Self.parse(record.end) else { return false }
            return startDate.timeIntervalSince(end) < 0 && endDate.timeIntervalSince(start) > 0
        }.prefix(limit).map { $0 }
    }

    func createEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord {
        if let failOnSave { throw DesktopCalendarError.saveFailed(failOnSave) }
        let record = DesktopCalendarEventRecord(
            id: "evt-\(nextID)", title: draft.title ?? "", start: Self.stamp(draft.start!), end: Self.stamp(draft.end!),
            isAllDay: draft.isAllDay ?? false, calendar: draft.calendarName ?? "Amber",
            location: draft.location ?? "", notes: draft.notes ?? "")
        nextID += 1
        events.append(record)
        savedEvents.append(record)
        return record
    }

    func updateEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord {
        guard let index = events.firstIndex(where: { $0.id == draft.eventID }) else {
            throw DesktopCalendarError.notFound("这条日程")
        }
        var record = events[index]
        if let title = draft.title { record.title = title }
        if let start = draft.start { record.start = Self.stamp(start) }
        if let end = draft.end { record.end = Self.stamp(end) }
        if let location = draft.location { record.location = location }
        if let notes = draft.notes { record.notes = notes }
        if let allDay = draft.isAllDay { record.isAllDay = allDay }
        if let name = draft.calendarName { record.calendar = name }
        events[index] = record
        savedEvents.append(record)
        return record
    }

    func deleteEvent(id: String) throws {
        guard events.contains(where: { $0.id == id }) else { throw DesktopCalendarError.notFound("这条日程") }
        events.removeAll { $0.id == id }
        deleted.append(id)
    }

    func reminders(dueBefore: Date?, limit: Int) async throws -> [DesktopCalendarReminderRecord] {
        reminders.prefix(limit).map { $0 }
    }

    func completeReminder(id: String) throws -> DesktopCalendarReminderRecord {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            throw DesktopCalendarError.notFound("这条提醒事项")
        }
        reminders[index].isCompleted = true
        return reminders[index]
    }

    private static func stamp(_ date: Date) -> String { formatter.string(from: date) }
    private static func parse(_ value: String) -> Date? { formatter.date(from: value) }
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// M3.4: `plugin__apple_schedule__*` is a host-native tool set. Reads stay quiet, writes go through the approval
/// card, and a denied permission produces an actionable message instead of a generic failure.
@MainActor final class DesktopAppleScheduleTests: XCTestCase {
    private var directory: URL!
    private var service: FakeCalendarService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-apple-schedule-\(UUID().uuidString)", isDirectory: true)
        service = FakeCalendarService()
    }

    override func tearDown() async throws {
        DesktopToolRegistry.updatePluginEffects([:])
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func store() -> DesktopPluginStore {
        DesktopPluginStore(directory: directory,
            defaults: UserDefaults(suiteName: "amber.apple.schedule.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials(), calendarService: service)
    }

    private func call(_ store: DesktopPluginStore, _ tool: String, _ json: String) async throws -> [String: Any] {
        let output = try await store.executeTool(qualifiedName: "plugin__apple_schedule__\(tool)", argumentsJSON: json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    func testBuiltInCalendarPluginRegistersHostToolsWithTheRightEffects() throws {
        let store = store()
        XCTAssertTrue(store.plugins.contains { $0.id == "apple_schedule" && $0.isBuiltIn && $0.enabled })
        let names = store.activeToolDeclarations.map(\.name)
        XCTAssertTrue(names.contains("plugin__apple_schedule__list_events"))
        XCTAssertEqual(store.plugins.first { $0.id == "apple_schedule" }?.manifest.capabilities.hostModules, ["calendar"])

        // Reads are local EventKit queries (.pure / .readOnly), never .networkRead; every write is high risk.
        XCTAssertEqual(DesktopToolRegistry.effect(for: "plugin__apple_schedule__list_events", arguments: "{}"), .pure)
        XCTAssertEqual(DesktopToolRegistry.effect(for: "plugin__apple_schedule__list_reminders", arguments: "{}"), .pure)
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__apple_schedule__list_events"))
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__apple_schedule__list_reminders"))
        for write in ["create_event", "update_event", "delete_event", "complete_reminder"] {
            XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__apple_schedule__\(write)"), write)
        }
        // No unwired workspaceView shell on apple_schedule.
        let applePlugin = try XCTUnwrap(store.plugins.first { $0.id == "apple_schedule" })
        XCTAssertTrue(applePlugin.manifest.ui.workspaceViews.isEmpty)
    }

    func testListReadsWithoutPromptingAndReportsEmptyCalendar() async throws {
        let store = store()
        let result = try await call(store, "list_events", #"{"start_at":"2026-11-02 00:00","end_at":"2026-11-03 00:00"}"#)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Int, 0)
        XCTAssertEqual(service.requestCount, 0, "读取不该弹出权限对话框")
    }

    func testCreateUpdateDeleteRoundTrip() async throws {
        let store = store()
        let created = try await call(store, "create_event",
            #"{"title":"架构评审","start_at":"2026-11-02 14:00","end_at":"2026-11-02 15:00","location":"会议室 A","notes":"带方案"}"#)
        let event = try XCTUnwrap(created["event"] as? [String: Any])
        let id = try XCTUnwrap(event["event_id"] as? String)
        XCTAssertEqual(event["title"] as? String, "架构评审")
        XCTAssertEqual(event["start_at"] as? String, "2026-11-02 14:00")
        XCTAssertEqual(event["calendar"] as? String, "Amber", "默认写进 Amber 自己的日历")

        let listedOutput = try await store.executeTool(
            qualifiedName: "plugin__apple_schedule__list_events",
            argumentsJSON: #"{"start_at":"2026-11-02 00:00","end_at":"2026-11-03 00:00"}"#)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listedOutput.utf8)) as? [String: Any])
        XCTAssertEqual(listed["count"] as? Int, 1)
        let listPreview = DesktopToolCallPreview.pluginSummary(for: DesktopToolCall(
            id: "cal-list", name: "plugin__apple_schedule__list_events", input: "{}",
            output: listedOutput, status: .complete))
        XCTAssertEqual(listPreview?.text, "共读取 1 项本机日历日程")

        let updated = try await call(store, "update_event",
            #"{"event_id":"\#(id)","title":"架构评审（改期）","start_at":"2026-11-02 16:00","end_at":"2026-11-02 17:00"}"#)
        let updatedEvent = try XCTUnwrap(updated["event"] as? [String: Any])
        XCTAssertEqual(updatedEvent["title"] as? String, "架构评审（改期）")
        XCTAssertEqual(updatedEvent["start_at"] as? String, "2026-11-02 16:00")
        XCTAssertEqual(updatedEvent["location"] as? String, "会议室 A", "没传的字段保持不变")

        let deleted = try await call(store, "delete_event", #"{"event_id":"\#(id)"}"#)
        XCTAssertEqual(deleted["deleted_event_id"] as? String, id)
        XCTAssertEqual(service.deleted, [id])
    }

    func testInvalidArgumentsAreReportedInsteadOfCrashing() async throws {
        let store = store()
        await assertThrows(store, "create_event", #"{"title":"缺时间"}"#) { message in
            XCTAssertTrue(message.contains("start_at"), message)
        }
        await assertThrows(store, "create_event",
            #"{"title":"倒序","start_at":"2026-11-02 15:00","end_at":"2026-11-02 14:00"}"#) { message in
            XCTAssertTrue(message.contains("结束晚于开始"), message)
        }
        await assertThrows(store, "update_event", #"{"event_id":"evt-missing","title":"x"}"#) { message in
            XCTAssertTrue(message.contains("找不到"), message)
        }
        await assertThrows(store, "delete_event", #"{"event_id":"evt-missing"}"#) { message in
            XCTAssertTrue(message.contains("找不到"), message)
        }
    }

    func testDeniedPermissionPointsAtSystemSettings() async throws {
        service.calendarAuthorization = .denied
        let store = store()
        await assertThrows(store, "create_event",
            #"{"title":"写作","start_at":"2026-11-02 10:00","end_at":"2026-11-02 11:00"}"#) { message in
            XCTAssertTrue(message.contains("系统设置"), message)
            XCTAssertTrue(message.contains("隐私与安全性"), message)
        }
        XCTAssertEqual(service.requestCount, 0, "已拒绝时不再重复弹窗")
        // A read with no permission also explains the fix rather than silently returning nothing.
        await assertThrows(store, "list_events", #"{}"#) { message in
            XCTAssertTrue(message.contains("系统设置"), message)
        }
    }

    func testRemindersRequireTheirOwnPermission() async throws {
        service.reminderAuthorization = .denied
        let store = store()
        await assertThrows(store, "list_reminders", #"{}"#) { message in
            XCTAssertTrue(message.contains("提醒事项"), message)
        }
        service.reminderAuthorization = .granted
        service.reminders = [DesktopCalendarReminderRecord(id: "rem-1", title: "写周报", due: "2026-11-02 18:00",
            isCompleted: false, list: "工作")]
        let listed = try await call(store, "list_reminders", #"{}"#)
        XCTAssertEqual(listed["count"] as? Int, 1)
        let completed = try await call(store, "complete_reminder", #"{"reminder_id":"rem-1"}"#)
        let reminder = try XCTUnwrap(completed["reminder"] as? [String: Any])
        XCTAssertEqual(reminder["completed"] as? Bool, true)
    }

    func testDisablingThePluginWithdrawsItsTools() throws {
        let store = store()
        XCTAssertTrue(store.activeToolDeclarations.contains { $0.name == "plugin__apple_schedule__list_events" })
        try store.setPluginEnabled("apple_schedule", enabled: false)
        XCTAssertFalse(store.activeToolDeclarations.contains { $0.name.hasPrefix("plugin__apple_schedule__") })
        try store.setPluginEnabled("apple_schedule", enabled: true)
        XCTAssertTrue(store.activeToolDeclarations.contains { $0.name == "plugin__apple_schedule__list_events" })
    }

    func testImportingAPluginCannotTakeTheBuiltInIdentifier() throws {
        let store = store()
        let folder = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"schema":"amber.plugin.v2","id":"apple_schedule","name":"伪装","version":"1","description":"x"}
        """.utf8).write(to: folder.appendingPathComponent("plugin.json"))
        XCTAssertThrowsError(try store.importPlugin(from: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("内置插件 ID"))
        }
    }

    private func assertThrows(_ store: DesktopPluginStore, _ tool: String, _ json: String,
                              _ check: (String) -> Void) async {
        do {
            _ = try await store.executeTool(qualifiedName: "plugin__apple_schedule__\(tool)", argumentsJSON: json)
            XCTFail("应当抛出错误：\(tool) \(json)")
        } catch {
            check(error.localizedDescription)
        }
    }
}
