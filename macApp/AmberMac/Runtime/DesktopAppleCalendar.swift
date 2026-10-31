import Foundation

// MARK: - Host-native calendar access (EventKit on macOS)

/// One calendar event as the plugin exposes it to the model. Strings, so the tool output is stable JSON.
struct DesktopCalendarEventRecord: Equatable, Sendable {
    var id: String
    var title: String
    var start: String
    var end: String
    var isAllDay = false
    var calendar: String = ""
    var location: String = ""
    var notes: String = ""

    var json: [String: Any] {
        ["event_id": id, "title": title, "start_at": start, "end_at": end, "all_day": isAllDay,
         "calendar": calendar, "location": location, "notes": notes]
    }
}

struct DesktopCalendarReminderRecord: Equatable, Sendable {
    var id: String
    var title: String
    var due: String?
    var isCompleted: Bool
    var list: String = ""

    var json: [String: Any] {
        var value: [String: Any] = ["reminder_id": id, "title": title, "completed": isCompleted, "list": list]
        if let due { value["due_at"] = due }
        return value
    }
}

/// What a create call may set. Every field is optional so an update can carry only the changes.
struct DesktopCalendarEventDraft: Equatable, Sendable {
    var eventID: String?
    var title: String?
    var start: Date?
    var end: Date?
    var location: String?
    var notes: String?
    var calendarName: String?
    var isAllDay: Bool?
}

enum DesktopCalendarAuthorization: Equatable, Sendable {
    case notDetermined, granted, denied

    /// What the user can actually do about it. Amber never pretends a denied permission is a retryable error.
    func denialMessage(_ kind: String) -> String {
        "Amber 没有访问\(kind)的权限。请打开「系统设置 › 隐私与安全性 › \(kind)」，允许 Amber 访问后重试；也可以先在 Amber 设置里停用「本机日程」插件。"
    }
}

enum DesktopCalendarError: Error, Equatable, LocalizedError {
    case permissionDenied(kind: String)
    case invalidArguments(String)
    case notFound(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let kind):
            return DesktopCalendarAuthorization.denied.denialMessage(kind)
        case .invalidArguments(let reason): return reason
        case .notFound(let what): return "找不到\(what)，可能已被删除或改到别的日历。"
        case .saveFailed(let reason): return "保存日历改动失败：\(reason)"
        }
    }
}

/// The seam that lets the whole plugin be tested without touching the user's real calendar.
@MainActor protocol DesktopCalendarService: AnyObject {
    func authorization(for kind: DesktopCalendarKind) -> DesktopCalendarAuthorization
    func requestAccess(for kind: DesktopCalendarKind) async throws
    func events(from start: Date, to end: Date, limit: Int) throws -> [DesktopCalendarEventRecord]
    func createEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord
    func updateEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord
    func deleteEvent(id: String) throws
    func reminders(dueBefore: Date?, limit: Int) async throws -> [DesktopCalendarReminderRecord]
    func completeReminder(id: String) throws -> DesktopCalendarReminderRecord
}

enum DesktopCalendarKind: String, Sendable {
    case calendar, reminders

    var displayName: String {
        switch self {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        }
    }
}

// MARK: - Tool dispatch

/// `plugin__apple_schedule__*`: the tools are implemented by the host (EventKit), not by plugin JavaScript,
/// because a sandbox has no way to reach the user's calendar. Writes are declared `sideEffect`/`idempotent`
/// in the manifest, so they inherit the ordinary high-risk approval gate.
@MainActor enum DesktopAppleScheduleTools {
    nonisolated static let pluginID = "apple_schedule"

    static func perform(tool name: String, argumentsJSON: String, service: any DesktopCalendarService,
                        calendar: Calendar = .current, now: Date = Date()) async throws -> String {
        let arguments = decode(argumentsJSON)
        switch name {
        case "list_events":
            try await ensureAccess(.calendar, service: service, requestIfNeeded: false)
            let start = try date(arguments["start_at"] as? String) ?? now
            let end = try date(arguments["end_at"] as? String) ?? start.addingTimeInterval(7 * 86_400)
            // Interval comparison, not `Date.>`: that operator traps on this SDK/runtime pairing.
            guard end.timeIntervalSince(start) > 0 else {
                throw DesktopCalendarError.invalidArguments("end_at 需要晚于 start_at。")
            }
            guard end.timeIntervalSince(start) <= 366 * 86_400 else {
                throw DesktopCalendarError.invalidArguments("一次最多查询一年内的日程。")
            }
            let limit = clamp(arguments["limit"] as? Int ?? 30, 1, 100)
            let events = try service.events(from: start, to: end, limit: limit)
            return json(["ok": true, "plugin": pluginID, "count": events.count, "events": events.map(\.json)])

        case "create_event":
            try await ensureAccess(.calendar, service: service)
            var draft = DesktopCalendarEventDraft()
            guard let title = clean(arguments["title"]), let start = try date(arguments["start_at"]),
                  let end = try date(arguments["end_at"]), end.timeIntervalSince(start) > 0 else {
                throw DesktopCalendarError.invalidArguments("create_event 需要 title、start_at、end_at，且结束晚于开始（格式 yyyy-MM-dd HH:mm）。")
            }
            draft.title = String(title.prefix(200))
            draft.start = start
            draft.end = end
            draft.location = clean(arguments["location"]).map { String($0.prefix(300)) }
            draft.notes = clean(arguments["notes"]).map { String($0.prefix(2_000)) }
            draft.calendarName = clean(arguments["calendar"])
            draft.isAllDay = arguments["all_day"] as? Bool
            let created = try service.createEvent(draft)
            return json(["ok": true, "plugin": pluginID, "event": created.json])

        case "update_event":
            try await ensureAccess(.calendar, service: service)
            guard let id = clean(arguments["event_id"]) else {
                throw DesktopCalendarError.invalidArguments("update_event 需要 event_id。")
            }
            var draft = DesktopCalendarEventDraft()
            draft.eventID = id
            draft.title = clean(arguments["title"]).map { String($0.prefix(200)) }
            draft.start = try date(arguments["start_at"])
            draft.end = try date(arguments["end_at"])
            draft.location = arguments.keys.contains("location") ? (arguments["location"] as? String).map { String($0.prefix(300)) } : nil
            draft.notes = arguments.keys.contains("notes") ? (arguments["notes"] as? String).map { String($0.prefix(2_000)) } : nil
            draft.calendarName = clean(arguments["calendar"])
            draft.isAllDay = arguments["all_day"] as? Bool
            if draft.title == nil, draft.start == nil, draft.end == nil, draft.location == nil,
               draft.notes == nil, draft.calendarName == nil, draft.isAllDay == nil {
                throw DesktopCalendarError.invalidArguments("update_event 至少需要一个要修改的字段。")
            }
            let updated = try service.updateEvent(draft)
            return json(["ok": true, "plugin": pluginID, "event": updated.json])

        case "delete_event":
            try await ensureAccess(.calendar, service: service)
            guard let id = clean(arguments["event_id"]) else {
                throw DesktopCalendarError.invalidArguments("delete_event 需要 event_id。")
            }
            try service.deleteEvent(id: id)
            return json(["ok": true, "plugin": pluginID, "deleted_event_id": id])

        case "list_reminders":
            try await ensureAccess(.reminders, service: service, requestIfNeeded: false)
            let due = try date(arguments["due_before"])
            let limit = clamp(arguments["limit"] as? Int ?? 30, 1, 100)
            let items = try await service.reminders(dueBefore: due, limit: limit)
            return json(["ok": true, "plugin": pluginID, "count": items.count, "reminders": items.map(\.json)])

        case "complete_reminder":
            try await ensureAccess(.reminders, service: service)
            guard let id = clean(arguments["reminder_id"]) else {
                throw DesktopCalendarError.invalidArguments("complete_reminder 需要 reminder_id。")
            }
            let item = try service.completeReminder(id: id)
            return json(["ok": true, "plugin": pluginID, "reminder": item.json])

        default:
            throw DesktopCalendarError.invalidArguments("本机日程插件没有工具 \(name)。")
        }
    }

    /// `requestIfNeeded` is false for reads: a list call must not pop a permission dialog the user did not expect.
    /// When access is missing the error says exactly which System Settings pane to open.
    private static func ensureAccess(_ kind: DesktopCalendarKind, service: any DesktopCalendarService,
                                     requestIfNeeded: Bool = true) async throws {
        switch service.authorization(for: kind) {
        case .granted: return
        case .denied: throw DesktopCalendarError.permissionDenied(kind: kind.displayName)
        case .notDetermined:
            guard requestIfNeeded else {
                throw DesktopCalendarError.permissionDenied(kind: kind.displayName)
            }
            try await service.requestAccess(for: kind)
            guard service.authorization(for: kind) == .granted else {
                throw DesktopCalendarError.permissionDenied(kind: kind.displayName)
            }
        }
    }

    private static func decode(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// `arguments["x"]` is `Any?` (nested optionals), so the dictionary subscript needs its own overload.
    private static func clean(_ value: Any??) -> String? {
        guard let value else { return nil }
        return clean(value as Any?)
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }

    /// The model writes local wall-clock time, the same string the Feishu plugin uses.
    static func date(_ value: String?) throws -> Date? {
        guard let value = clean(value) else { return nil }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        throw DesktopCalendarError.invalidArguments("时间格式无法识别：\(value)（用 yyyy-MM-dd HH:mm）。")
    }

    /// The same parse for `arguments["x"]`, which arrives as a doubly-wrapped optional.
    static func date(_ value: Any??) throws -> Date? {
        guard let value else { return nil }
        return try date(value as? String)
    }

    static func json(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
