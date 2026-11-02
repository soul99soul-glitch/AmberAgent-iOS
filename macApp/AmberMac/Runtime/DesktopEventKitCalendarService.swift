import EventKit
import Foundation

/// The real EventKit implementation. Kept in its own file so the plugin logic and its tests never need the
/// user's calendar: `DesktopAppleScheduleTools` talks to the `DesktopCalendarService` protocol instead.
@MainActor final class DesktopEventKitCalendarService: DesktopCalendarService {
    /// Created on first use, never at plugin-store init: an `EKEventStore` outside a signed app (the offscreen
    /// snapshot tool, a unit-test host) has no TCC context and traps. The plugin must be able to exist with no
    /// calendar access at all.
    private var cachedStore: EKEventStore?
    private let storeFactory: @MainActor () -> EKEventStore
    /// Stable across relaunches: the plugin's own default calendar so Amber never mixes its events into a
    /// personal calendar the user picked for something else.
    static let defaultCalendarTitle = "Amber"

    init(storeFactory: @escaping @MainActor () -> EKEventStore = { EKEventStore() }) {
        self.storeFactory = storeFactory
    }

    private var store: EKEventStore {
        if let cachedStore { return cachedStore }
        let created = storeFactory()
        cachedStore = created
        return created
    }

    // MARK: Authorization

    func authorization(for kind: DesktopCalendarKind) -> DesktopCalendarAuthorization {
        switch kind {
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            // Write-only cannot read the schedule back, so it does not count as granted for this plugin.
            case .denied, .restricted, .writeOnly: return .denied
            @unknown default: return .denied
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted, .writeOnly: return .denied
            @unknown default: return .denied
            }
        }
    }

    func requestAccess(for kind: DesktopCalendarKind) async throws {
        switch kind {
        case .calendar:
            _ = try await store.requestFullAccessToEvents()
        case .reminders:
            _ = try await store.requestFullAccessToReminders()
        }
    }

    // MARK: Events

    func events(from start: Date, to end: Date, limit: Int) throws -> [DesktopCalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate.timeIntervalSince($1.startDate) < 0 }
            .prefix(limit)
            .map(Self.record)
    }

    func createEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord {
        guard let start = draft.start, let end = draft.end else {
            throw DesktopCalendarError.invalidArguments("创建日程缺少开始或结束时间。")
        }
        // Interval comparison, not `Date.>`: that operator traps on this SDK/runtime pairing.
        guard end.timeIntervalSince(start) > 0 else {
            throw DesktopCalendarError.invalidArguments("结束时间需要晚于开始时间。")
        }
        let event = EKEvent(eventStore: store)
        event.title = draft.title ?? "Amber 日程"
        event.startDate = start
        event.endDate = end
        event.location = draft.location
        event.notes = draft.notes
        event.isAllDay = draft.isAllDay ?? false
        event.calendar = try calendarForWriting(named: draft.calendarName)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw DesktopCalendarError.saveFailed(error.localizedDescription)
        }
        return Self.record(event)
    }

    func updateEvent(_ draft: DesktopCalendarEventDraft) throws -> DesktopCalendarEventRecord {
        guard let id = draft.eventID else {
            throw DesktopCalendarError.invalidArguments("修改日程缺少 event_id。")
        }
        guard let event = store.event(withIdentifier: id) else {
            throw DesktopCalendarError.notFound("这条日程")
        }
        if let title = draft.title { event.title = title }
        if let start = draft.start { event.startDate = start }
        if let end = draft.end { event.endDate = end }
        guard event.endDate.timeIntervalSince(event.startDate) > 0 else {
            throw DesktopCalendarError.invalidArguments("结束时间需要晚于开始时间。")
        }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let allDay = draft.isAllDay { event.isAllDay = allDay }
        if let name = draft.calendarName { event.calendar = try calendarForWriting(named: name) }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw DesktopCalendarError.saveFailed(error.localizedDescription)
        }
        return Self.record(event)
    }

    func deleteEvent(id: String) throws {
        guard let event = store.event(withIdentifier: id) else {
            throw DesktopCalendarError.notFound("这条日程")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw DesktopCalendarError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Reminders

    private struct RawReminderSnapshot: Sendable {
        let id: String
        let title: String
        let dueDateComponents: DateComponents?
        let isCompleted: Bool
        let list: String
    }

    func reminders(dueBefore: Date?, limit: Int) async throws -> [DesktopCalendarReminderRecord] {
        let calendars = store.calendars(for: .reminder)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        let fetched: [RawReminderSnapshot] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    RawReminderSnapshot(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "",
                        dueDateComponents: reminder.dueDateComponents,
                        isCompleted: reminder.isCompleted,
                        list: reminder.calendar?.title ?? ""
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
        let filtered = fetched
            .filter { reminder in
                guard let due = reminder.dueDateComponents.flatMap(Self.date(from:)) else { return dueBefore == nil }
                return dueBefore.map { due.timeIntervalSince($0) <= 0 } ?? true
            }
            .sorted {
                let lhs = $0.dueDateComponents.flatMap(Self.date(from:)) ?? .distantFuture
                let rhs = $1.dueDateComponents.flatMap(Self.date(from:)) ?? .distantFuture
                return lhs.timeIntervalSince(rhs) < 0
            }
            .prefix(limit)
        return filtered.map { reminder in
            DesktopCalendarReminderRecord(
                id: reminder.id,
                title: reminder.title,
                due: reminder.dueDateComponents.flatMap(Self.date(from:)).map(Self.stamp),
                isCompleted: reminder.isCompleted,
                list: reminder.list
            )
        }
    }

    func completeReminder(id: String) throws -> DesktopCalendarReminderRecord {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw DesktopCalendarError.notFound("这条提醒事项")
        }
        item.isCompleted = true
        item.completionDate = Date()
        do {
            try store.save(item, commit: true)
        } catch {
            throw DesktopCalendarError.saveFailed(error.localizedDescription)
        }
        return DesktopCalendarReminderRecord(
            id: item.calendarItemIdentifier,
            title: item.title ?? "",
            due: item.dueDateComponents.flatMap(Self.date(from:)).map(Self.stamp),
            isCompleted: item.isCompleted,
            list: item.calendar?.title ?? ""
        )
    }

    // MARK: Helpers

    /// An explicit calendar name wins; otherwise Amber writes into its own calendar, created on first write.
    private func calendarForWriting(named name: String?) throws -> EKCalendar {
        if let name, let match = store.calendars(for: .event).first(where: { $0.title == name }) {
            guard match.allowsContentModifications else {
                throw DesktopCalendarError.invalidArguments("日历「\(name)」是只读的，换一个可写的日历。")
            }
            return match
        }
        if let existing = store.calendars(for: .event).first(where: { $0.title == Self.defaultCalendarTitle }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw DesktopCalendarError.saveFailed("系统里没有可写入的日历来源。")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.defaultCalendarTitle
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            throw DesktopCalendarError.saveFailed(error.localizedDescription)
        }
    }

    private static func record(_ event: EKEvent) -> DesktopCalendarEventRecord {
        DesktopCalendarEventRecord(
            id: event.eventIdentifier ?? "",
            title: event.title ?? "",
            start: stamp(event.startDate),
            end: stamp(event.endDate),
            isAllDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            location: event.location ?? "",
            notes: event.notes ?? ""
        )
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func date(from components: DateComponents) -> Date? {
        var components = components
        components.timeZone = components.timeZone ?? .current
        return components.calendar?.date(from: components) ?? Calendar.current.date(from: components)
    }
}

// MARK: - Plugin manifest

@MainActor extension DesktopPluginStore {
    /// The official host-native calendar plugin. No JavaScript: every tool is implemented by EventKit, and the
    /// three write tools are `sideEffect`/`idempotent` so they go through the usual approval card.
    static func makeBuiltInAppleSchedulePlugin(enabled: Bool) -> DesktopInstalledPlugin {
        let manifest = DesktopPluginManifest(
            schema: DesktopPluginManifest.schemaV2,
            id: DesktopAppleScheduleTools.pluginID,
            name: "本机日程",
            version: "1.0.0",
            description: "读写这台 Mac 上的日历与提醒事项：查排期、建会议、改时间、标记完成。改动经你批准后才会写入系统日历。",
            icon: "calendar.badge.clock",
            capabilities: DesktopPluginCapabilities(hostModules: [DesktopPluginHostModule.calendar.rawValue]),
            settingsSchema: [],
            tools: [
                DesktopPluginToolManifest(
                    name: "list_events",
                    description: "读取本机日历在指定时间范围内的日程。",
                    effect: .readOnly,
                    entry: "listEvents",
                    parametersJSON: #"{"type":"object","properties":{"start_at":{"type":"string","description":"开始时间 yyyy-MM-dd HH:mm，默认现在"},"end_at":{"type":"string","description":"结束时间 yyyy-MM-dd HH:mm，默认七天后"},"limit":{"type":"integer","description":"最多返回条数，默认 30"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "create_event",
                    description: "在本机日历创建日程（需要你批准）。",
                    effect: .sideEffect,
                    entry: "createEvent",
                    parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"},"start_at":{"type":"string","description":"yyyy-MM-dd HH:mm"},"end_at":{"type":"string","description":"yyyy-MM-dd HH:mm"},"location":{"type":"string"},"notes":{"type":"string"},"calendar":{"type":"string","description":"可选日历名称，默认写入 Amber 日历"},"all_day":{"type":"boolean"}},"required":["title","start_at","end_at"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "update_event",
                    description: "修改本机日历中的一条日程（需要你批准）。",
                    effect: .sideEffect,
                    entry: "updateEvent",
                    parametersJSON: #"{"type":"object","properties":{"event_id":{"type":"string"},"title":{"type":"string"},"start_at":{"type":"string"},"end_at":{"type":"string"},"location":{"type":"string"},"notes":{"type":"string"},"calendar":{"type":"string"},"all_day":{"type":"boolean"}},"required":["event_id"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "delete_event",
                    description: "删除本机日历中的一条日程（需要你批准）。",
                    effect: .sideEffect,
                    entry: "deleteEvent",
                    parametersJSON: #"{"type":"object","properties":{"event_id":{"type":"string"}},"required":["event_id"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "list_reminders",
                    description: "读取本机提醒事项。",
                    effect: .readOnly,
                    entry: "listReminders",
                    parametersJSON: #"{"type":"object","properties":{"due_before":{"type":"string","description":"只返回此时间之前到期的 yyyy-MM-dd HH:mm"},"limit":{"type":"integer"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "complete_reminder",
                    description: "把一条提醒事项标记为已完成（需要你批准）。",
                    effect: .idempotent,
                    entry: "completeReminder",
                    parametersJSON: #"{"type":"object","properties":{"reminder_id":{"type":"string"}},"required":["reminder_id"],"additionalProperties":false}"#
                ),
            ],
            ui: DesktopPluginUIManifest(
                commands: [
                    DesktopPluginCommandManifest(id: "apple_today", title: "梳理今天的本机日程",
                        slash: "/today", symbol: "calendar.badge.clock",
                        promptTemplate: "请调用 plugin__apple_schedule__list_events 读取我今天的日程（start_at 为今天 00:00，end_at 为明天 00:00），按时间顺序列出并指出冲突的时段。"),
                    DesktopPluginCommandManifest(id: "apple_meet", title: "在本机日历约一个会议",
                        slash: "/schedule", symbol: "calendar.badge.plus",
                        promptTemplate: "请先调用 plugin__apple_schedule__list_events 检查冲突，然后调用 plugin__apple_schedule__create_event 在本机日历安排这场会议："),
                ]
            )
        )
        return DesktopInstalledPlugin(manifest: manifest, scriptSource: "", enabled: enabled, isBuiltIn: true)
    }
}
