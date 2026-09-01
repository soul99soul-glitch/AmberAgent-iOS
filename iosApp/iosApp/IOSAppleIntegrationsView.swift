import SwiftUI

#if canImport(EventKit)
@preconcurrency import EventKit
#endif

@MainActor
struct IOSAppleIntegrationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(IOSAppleIntegrationPreferenceKeys.completionNotificationsEnabled)
    private var completionNotificationsEnabled = false
    @State private var isRequestingNotifications = false
    @State private var notificationRequestRevision = 0
    @State private var reminderTitle = ""
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var reminderMessage: String?

    private let notificationService: IOSLocalNotificationService

    init(
        systemPermissionCoordinator: IOSSystemPermissionCoordinator,
        notificationService: IOSLocalNotificationService? = nil
    ) {
        self.notificationService = notificationService
            ?? IOSLocalNotificationService(permissionCoordinator: systemPermissionCoordinator)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        capabilitySection
                        notificationSection
                        reminderSection
                        shortcutSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer()
            Text("Apple 集成")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var capabilitySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "设备能力")
            AmberFormGroup {
                integrationNavigationRow(
                    title: "健康摘要",
                    subtitle: "本机只读步数，不进入模型或同步",
                    icon: "heart.text.clipboard"
                ) { router.navigate(to: .healthSummary) }
                Divider().overlay(AmberTheme.borderSoft).padding(.leading, 56)
                integrationNavigationRow(
                    title: "WeatherKit 天气",
                    subtitle: "城市查询或按需读取当前位置",
                    icon: "cloud.sun"
                ) { router.navigate(to: .weather) }
            }
        }
    }

    private var notificationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "本地通知")
            AmberFormGroup {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("后台任务完成通知")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("只在 App 不活跃且本机任务结束时提醒；不使用远程推送。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isRequestingNotifications {
                        ProgressView()
                            .tint(AmberTheme.accent)
                            .accessibilityLabel("正在请求通知权限")
                            .accessibilityHint("系统权限确认完成后会更新后台任务通知开关")
                    } else {
                        Toggle("", isOn: Binding(
                            get: { completionNotificationsEnabled },
                            set: { updateCompletionNotifications($0) }
                        ))
                        .labelsHidden()
                        .tint(AmberTheme.accent)
                        .accessibilityLabel("后台任务完成通知")
                        .accessibilityHint("只在 Amber 不活跃且本机任务完成时发送本地通知")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var reminderSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "一次提醒")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("提醒标题（可选）", text: $reminderTitle)
                        .textFieldStyle(.plain)
                    Divider().overlay(AmberTheme.borderSoft)
                    reminderDatePicker
                    reminderActions

                    if let reminderMessage {
                        Text(reminderMessage)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private var reminderDatePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("提醒时间")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                DatePicker(
                    "提醒时间",
                    selection: $reminderDate,
                    in: Date().addingTimeInterval(5)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
        } else {
            DatePicker(
                "提醒时间",
                selection: $reminderDate,
                in: Date().addingTimeInterval(5)...,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    @ViewBuilder
    private var reminderActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                cancelReminderButton.frame(maxWidth: .infinity)
                scheduleReminderButton.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                cancelReminderButton
                scheduleReminderButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var cancelReminderButton: some View {
        Button("取消待发提醒") {
            notificationService.cancelManualReminder()
            reminderMessage = "已取消待发提醒。"
        }
        .buttonStyle(.bordered)
        .tint(AmberTheme.muted)
    }

    private var scheduleReminderButton: some View {
        Button("安排提醒") {
            Task { await scheduleReminder() }
        }
        .buttonStyle(.borderedProminent)
        .tint(AmberTheme.accent)
    }

    private var shortcutSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Siri 与快捷指令")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Label("询问 Amber", systemImage: "sparkles")
                    Label("生成每日简报", systemImage: "sun.max")
                    Label("运行快捷消息", systemImage: "text.badge.checkmark")
                    Text("安装后可在“快捷指令”App、Siri 和系统搜索中使用。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private func integrationNavigationRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(AmberTheme.foreground)
                    Text(subtitle).font(.caption).foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func updateCompletionNotifications(_ enabled: Bool) {
        guard enabled else {
            notificationRequestRevision &+= 1
            isRequestingNotifications = false
            completionNotificationsEnabled = false
            Task { await notificationService.cancelTaskCompletionNotifications() }
            return
        }
        guard !isRequestingNotifications else { return }
        notificationRequestRevision &+= 1
        let revision = notificationRequestRevision
        isRequestingNotifications = true
        Task {
            let granted = await notificationService.requestAuthorization()
            guard revision == notificationRequestRevision else { return }
            completionNotificationsEnabled = granted
            isRequestingNotifications = false
        }
    }

    private func scheduleReminder() async {
        if await notificationService.authorization() != .allowed,
           await notificationService.requestAuthorization() == false {
            reminderMessage = "通知权限未开启，未安排提醒。"
            return
        }
        do {
            switch try await notificationService.scheduleManualReminder(
                title: reminderTitle,
                fireDate: reminderDate
            ) {
            case .scheduled:
                reminderMessage = "提醒已安排；重新安排会替换上一条。"
            case .notAuthorized:
                reminderMessage = "通知权限未开启，未安排提醒。"
            case .invalidDate:
                reminderMessage = "请选择至少 5 秒后的时间。"
            }
        } catch {
            reminderMessage = "安排失败：\(error.localizedDescription)"
        }
    }
}

enum IOSAppleAgentToolCatalog {
    static let calendarEventsList = "calendar_events_list"
    static let calendarEventCreate = "calendar_event_create"
    static let calendarEventUpdate = "calendar_event_update"
    static let calendarEventDelete = "calendar_event_delete"
    static let remindersList = "reminders_list"
    static let reminderCreate = "reminder_create"
    static let reminderUpdate = "reminder_update"
    static let reminderDelete = "reminder_delete"
    static let reminderComplete = "reminder_complete"
    static let notificationSchedule = "notification_schedule"
    static let notificationCancel = "notification_cancel"
    static let alarmSchedule = "alarm_schedule"
    static let alarmsList = "alarms_list"
    static let alarmCancel = "alarm_cancel"
    static let contactsPick = "contacts_pick"
    static let photosPick = "photos_pick"
    static let journalingSuggestionPick = "journaling_suggestion_pick"
    static let workoutPlanPreview = "workout_plan_preview"
    static let workoutSchedule = "workout_schedule"
    static let scheduledWorkoutsList = "workouts_scheduled_list"
    static let scheduledWorkoutRemove = "workout_scheduled_remove"

    static let eventKitToolNames: Set<String> = [
        calendarEventsList, calendarEventCreate, calendarEventUpdate, calendarEventDelete,
        remindersList, reminderCreate, reminderUpdate, reminderDelete, reminderComplete
    ]
    static let notificationToolNames: Set<String> = [notificationSchedule, notificationCancel]
    static let alarmToolNames: Set<String> = [alarmSchedule, alarmsList, alarmCancel]
    static let pickerToolNames: Set<String> = [contactsPick, photosPick, journalingSuggestionPick]
    static let workoutToolNames: Set<String> = [
        workoutPlanPreview, workoutSchedule, scheduledWorkoutsList, scheduledWorkoutRemove
    ]
    static let backgroundSafeToolNames: Set<String> = [workoutPlanPreview]
    static let toolNames = eventKitToolNames
        .union(notificationToolNames)
        .union(alarmToolNames)
        .union(pickerToolNames)
        .union(workoutToolNames)
        .union([IOSHealthAgentToolCatalog.toolName, IOSWeatherToolCatalog.toolName])
    static let approvalRequiredToolNames = toolNames
        .subtracting(pickerToolNames)
        .subtracting(backgroundSafeToolNames)
        .subtracting([IOSWeatherToolCatalog.toolName])
    static let mutatingToolNames: Set<String> = [
        calendarEventCreate, calendarEventUpdate, calendarEventDelete,
        reminderCreate, reminderUpdate, reminderDelete, reminderComplete,
        notificationSchedule, notificationCancel,
        alarmSchedule, alarmCancel,
        workoutSchedule, scheduledWorkoutRemove
    ]
}

@MainActor
enum IOSEventKitAgentToolExecutor {
    static func execute(toolName: String, input: String) async -> String {
        #if canImport(EventKit)
        guard IOSAppleAgentToolCatalog.eventKitToolNames.contains(toolName),
              var arguments = object(input) else {
            return failure(toolName, "参数不是有效的 JSON 对象。")
        }
        arguments.removeValue(forKey: "display_title")
        do {
            let store = EKEventStore()
            switch toolName {
            case IOSAppleAgentToolCatalog.calendarEventsList:
                try await ensureEventAccess(store)
                return try listEvents(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.calendarEventCreate:
                try await ensureEventCreateAccess(store)
                return try createEvent(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.calendarEventUpdate:
                try await ensureEventAccess(store)
                return try updateEvent(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.calendarEventDelete:
                try await ensureEventAccess(store)
                return try deleteEvent(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.remindersList:
                try await ensureReminderAccess(store)
                return try await listReminders(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.reminderCreate:
                try await ensureReminderAccess(store)
                return try createReminder(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.reminderUpdate:
                try await ensureReminderAccess(store)
                return try updateReminder(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.reminderDelete:
                try await ensureReminderAccess(store)
                return try deleteReminder(store, arguments: arguments)
            case IOSAppleAgentToolCatalog.reminderComplete:
                try await ensureReminderAccess(store)
                return try completeReminder(store, arguments: arguments)
            default:
                return failure(toolName, "未知 Apple 工具。")
            }
        } catch {
            return failure(toolName, error.localizedDescription)
        }
        #else
        return failure(toolName, "当前系统不可用 EventKit。")
        #endif
    }

    private static func object(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    #if canImport(EventKit)
    private static func ensureEventAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            guard try await store.requestFullAccessToEvents() else { throw IOSAppleAgentToolError.permissionDenied("日历") }
        case .denied, .restricted, .writeOnly:
            throw IOSAppleAgentToolError.permissionDenied("日历")
        @unknown default:
            throw IOSAppleAgentToolError.permissionDenied("日历")
        }
    }

    private static func ensureEventCreateAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            guard try await store.requestWriteOnlyAccessToEvents() else {
                throw IOSAppleAgentToolError.permissionDenied("日历写入")
            }
        case .denied, .restricted:
            throw IOSAppleAgentToolError.permissionDenied("日历写入")
        @unknown default:
            throw IOSAppleAgentToolError.permissionDenied("日历写入")
        }
    }

    private static func ensureReminderAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else { throw IOSAppleAgentToolError.permissionDenied("提醒事项") }
        case .denied, .restricted, .writeOnly:
            throw IOSAppleAgentToolError.permissionDenied("提醒事项")
        @unknown default:
            throw IOSAppleAgentToolError.permissionDenied("提醒事项")
        }
    }

    private static func listEvents(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys).isSubset(of: ["start_at", "end_at", "limit"]) else {
            throw IOSAppleAgentToolError.invalidArguments
        }
        let start = try date(arguments["start_at"] as? String) ?? Date()
        let end = try date(arguments["end_at"] as? String) ?? start.addingTimeInterval(7 * 86_400)
        guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else {
            throw IOSAppleAgentToolError.invalidDateRange
        }
        let limit = min(max(arguments["limit"] as? Int ?? 30, 1), 100)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                [
                    "event_id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "start_at": formatter.string(from: event.startDate),
                    "end_at": formatter.string(from: event.endDate),
                    "all_day": event.isAllDay,
                    "calendar_id": event.calendar?.calendarIdentifier ?? "",
                    "calendar": event.calendar?.title ?? "",
                    "location": event.location ?? "",
                    "notes": event.notes ?? "",
                    "recurrence": recurrencePayload(event.recurrenceRules?.first)
                ] as [String: Any]
            }
        return json(["ok": true, "tool": IOSAppleAgentToolCatalog.calendarEventsList, "events": Array(events)])
    }

    private static func createEvent(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys).isSubset(of: [
            "title", "start_at", "end_at", "location", "notes", "calendar_id",
            "recurrence", "recurrence_interval", "recurrence_end_at"
        ]),
              let title = nonBlank(arguments["title"] as? String),
              let start = try date(arguments["start_at"] as? String),
              let end = try date(arguments["end_at"] as? String),
              end > start else {
            throw IOSAppleAgentToolError.invalidArguments
        }
        let calendar = try eventCalendar(store, identifier: arguments["calendar_id"] as? String)
        let event = EKEvent(eventStore: store)
        event.title = String(title.prefix(200))
        event.startDate = start
        event.endDate = end
        event.location = (arguments["location"] as? String).map { String($0.prefix(300)) }
        event.notes = (arguments["notes"] as? String).map { String($0.prefix(2_000)) }
        event.calendar = calendar
        event.recurrenceRules = try recurrenceRules(arguments, start: start)
        try store.save(event, span: .thisEvent, commit: true)
        return json(eventPayload(event, tool: IOSAppleAgentToolCatalog.calendarEventCreate))
    }

    private static func updateEvent(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        let allowed: Set<String> = [
            "event_id", "title", "start_at", "end_at", "location", "notes", "calendar_id",
            "recurrence", "recurrence_interval", "recurrence_end_at"
        ]
        guard Set(arguments.keys).isSubset(of: allowed),
              arguments.keys.count > 1,
              let identifier = nonBlank(arguments["event_id"] as? String),
              let event = store.event(withIdentifier: identifier) else {
            throw IOSAppleAgentToolError.itemNotFound("日历事件")
        }
        if let title = arguments["title"] as? String {
            guard let clean = nonBlank(title) else { throw IOSAppleAgentToolError.invalidArguments }
            event.title = String(clean.prefix(200))
        }
        if arguments.keys.contains("start_at") { event.startDate = try requiredDate(arguments["start_at"]) }
        if arguments.keys.contains("end_at") { event.endDate = try requiredDate(arguments["end_at"]) }
        guard event.endDate > event.startDate else { throw IOSAppleAgentToolError.invalidDateRange }
        if let location = arguments["location"] as? String { event.location = String(location.prefix(300)) }
        if let notes = arguments["notes"] as? String { event.notes = String(notes.prefix(2_000)) }
        if arguments.keys.contains("calendar_id") {
            event.calendar = try eventCalendar(store, identifier: arguments["calendar_id"] as? String)
        }
        if arguments.keys.contains("recurrence") {
            event.recurrenceRules = try recurrenceRules(arguments, start: event.startDate)
        } else if arguments.keys.contains("recurrence_interval") || arguments.keys.contains("recurrence_end_at") {
            throw IOSAppleAgentToolError.invalidRecurrence
        }
        try store.save(event, span: .thisEvent, commit: true)
        return json(eventPayload(event, tool: IOSAppleAgentToolCatalog.calendarEventUpdate))
    }

    private static func deleteEvent(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys) == ["event_id"],
              let identifier = nonBlank(arguments["event_id"] as? String),
              let event = store.event(withIdentifier: identifier) else {
            throw IOSAppleAgentToolError.itemNotFound("日历事件")
        }
        let title = event.title ?? ""
        try store.remove(event, span: .thisEvent, commit: true)
        return json([
            "ok": true,
            "tool": IOSAppleAgentToolCatalog.calendarEventDelete,
            "event_id": identifier,
            "title": title,
            "deleted": true
        ])
    }

    private static func listReminders(_ store: EKEventStore, arguments: [String: Any]) async throws -> String {
        guard Set(arguments.keys).isSubset(of: ["include_completed", "limit"]) else {
            throw IOSAppleAgentToolError.invalidArguments
        }
        let includeCompleted = arguments["include_completed"] as? Bool ?? false
        let limit = min(max(arguments["limit"] as? Int ?? 30, 1), 100)
        let reminderIDs: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { values in
                continuation.resume(returning: values?.map(\.calendarItemIdentifier) ?? [])
            }
        }
        let reminders = reminderIDs.compactMap {
            store.calendarItem(withIdentifier: $0) as? EKReminder
        }
        let values = reminders
            .filter { includeCompleted || !$0.isCompleted }
            .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
            .prefix(limit)
            .map { reminder in
                var value: [String: Any] = [
                    "reminder_id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "completed": reminder.isCompleted,
                    "list_id": reminder.calendar.calendarIdentifier,
                    "list": reminder.calendar.title,
                    "notes": reminder.notes ?? "",
                    "priority": reminder.priority
                ]
                reminder.dueDateComponents?.date.map { value["due_at"] = formatter.string(from: $0) }
                return value
            }
        return json(["ok": true, "tool": IOSAppleAgentToolCatalog.remindersList, "reminders": Array(values)])
    }

    private static func createReminder(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys).isSubset(of: ["title", "due_at", "notes", "priority", "list_id"]),
              let title = nonBlank(arguments["title"] as? String) else {
            throw IOSAppleAgentToolError.invalidArguments
        }
        let calendar = try reminderCalendar(store, identifier: arguments["list_id"] as? String)
        let reminder = EKReminder(eventStore: store)
        reminder.title = String(title.prefix(200))
        reminder.notes = (arguments["notes"] as? String).map { String($0.prefix(2_000)) }
        reminder.calendar = calendar
        if let priority = arguments["priority"] as? Int {
            guard (0...9).contains(priority) else { throw IOSAppleAgentToolError.invalidArguments }
            reminder.priority = priority
        }
        if let due = try date(arguments["due_at"] as? String) {
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            components.calendar = .current
            components.timeZone = .current
            reminder.dueDateComponents = components
        }
        try store.save(reminder, commit: true)
        return json(reminderPayload(reminder, tool: IOSAppleAgentToolCatalog.reminderCreate))
    }

    private static func updateReminder(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        let allowed: Set<String> = [
            "reminder_id", "title", "due_at", "remove_due_date", "notes", "priority", "list_id"
        ]
        guard Set(arguments.keys).isSubset(of: allowed),
              arguments.keys.count > 1,
              let identifier = nonBlank(arguments["reminder_id"] as? String),
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw IOSAppleAgentToolError.itemNotFound("提醒事项")
        }
        if let title = arguments["title"] as? String {
            guard let clean = nonBlank(title) else { throw IOSAppleAgentToolError.invalidArguments }
            reminder.title = String(clean.prefix(200))
        }
        let removesDueDate = arguments["remove_due_date"] as? Bool ?? false
        guard !(removesDueDate && arguments.keys.contains("due_at")) else {
            throw IOSAppleAgentToolError.invalidArguments
        }
        if removesDueDate {
            reminder.dueDateComponents = nil
        } else if arguments.keys.contains("due_at") {
            let due = try requiredDate(arguments["due_at"])
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            components.calendar = .current
            components.timeZone = .current
            reminder.dueDateComponents = components
        }
        if let notes = arguments["notes"] as? String { reminder.notes = String(notes.prefix(2_000)) }
        if let priority = arguments["priority"] as? Int {
            guard (0...9).contains(priority) else { throw IOSAppleAgentToolError.invalidArguments }
            reminder.priority = priority
        }
        if arguments.keys.contains("list_id") {
            reminder.calendar = try reminderCalendar(store, identifier: arguments["list_id"] as? String)
        }
        try store.save(reminder, commit: true)
        return json(reminderPayload(reminder, tool: IOSAppleAgentToolCatalog.reminderUpdate))
    }

    private static func deleteReminder(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys) == ["reminder_id"],
              let identifier = nonBlank(arguments["reminder_id"] as? String),
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw IOSAppleAgentToolError.itemNotFound("提醒事项")
        }
        let title = reminder.title ?? ""
        try store.remove(reminder, commit: true)
        return json([
            "ok": true,
            "tool": IOSAppleAgentToolCatalog.reminderDelete,
            "reminder_id": identifier,
            "title": title,
            "deleted": true
        ])
    }

    private static func completeReminder(_ store: EKEventStore, arguments: [String: Any]) throws -> String {
        guard Set(arguments.keys) == ["reminder_id"],
              let identifier = nonBlank(arguments["reminder_id"] as? String),
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw IOSAppleAgentToolError.reminderNotFound
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
        return json(reminderPayload(reminder, tool: IOSAppleAgentToolCatalog.reminderComplete))
    }

    private static func eventCalendar(_ store: EKEventStore, identifier: String?) throws -> EKCalendar {
        let calendar = nonBlank(identifier).flatMap { store.calendar(withIdentifier: $0) }
            ?? (identifier == nil ? store.defaultCalendarForNewEvents : nil)
        guard let calendar, calendar.allowsContentModifications else {
            throw IOSAppleAgentToolError.itemNotFound("可写日历")
        }
        return calendar
    }

    private static func reminderCalendar(_ store: EKEventStore, identifier: String?) throws -> EKCalendar {
        let calendar = nonBlank(identifier).flatMap { store.calendar(withIdentifier: $0) }
            ?? (identifier == nil ? store.defaultCalendarForNewReminders() : nil)
        guard let calendar, calendar.allowsContentModifications else {
            throw IOSAppleAgentToolError.itemNotFound("可写提醒清单")
        }
        return calendar
    }

    private static func recurrenceRules(
        _ arguments: [String: Any],
        start: Date
    ) throws -> [EKRecurrenceRule]? {
        guard let raw = arguments["recurrence"] as? String else {
            if arguments.keys.contains("recurrence_interval") || arguments.keys.contains("recurrence_end_at") {
                throw IOSAppleAgentToolError.invalidRecurrence
            }
            return nil
        }
        if raw == "none" { return [] }
        let frequency: EKRecurrenceFrequency
        switch raw {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        default: throw IOSAppleAgentToolError.invalidRecurrence
        }
        let interval = arguments["recurrence_interval"] as? Int ?? 1
        guard (1...30).contains(interval) else { throw IOSAppleAgentToolError.invalidRecurrence }
        let endDate = try date(arguments["recurrence_end_at"] as? String)
        if let endDate, endDate <= start { throw IOSAppleAgentToolError.invalidRecurrence }
        let end = endDate.map { EKRecurrenceEnd(end: $0) }
        return [EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)]
    }

    private static func eventPayload(_ event: EKEvent, tool: String) -> [String: Any] {
        [
            "ok": true,
            "tool": tool,
            "event_id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start_at": formatter.string(from: event.startDate),
            "end_at": formatter.string(from: event.endDate),
            "all_day": event.isAllDay,
            "calendar_id": event.calendar?.calendarIdentifier ?? "",
            "calendar": event.calendar?.title ?? "",
            "location": event.location ?? "",
            "notes": event.notes ?? "",
            "recurrence": recurrencePayload(event.recurrenceRules?.first)
        ]
    }

    private static func reminderPayload(_ reminder: EKReminder, tool: String) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "tool": tool,
            "reminder_id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "completed": reminder.isCompleted,
            "list_id": reminder.calendar.calendarIdentifier,
            "list": reminder.calendar.title,
            "notes": reminder.notes ?? "",
            "priority": reminder.priority
        ]
        reminder.dueDateComponents?.date.map { payload["due_at"] = formatter.string(from: $0) }
        reminder.completionDate.map { payload["completed_at"] = formatter.string(from: $0) }
        return payload
    }

    private static func recurrencePayload(_ rule: EKRecurrenceRule?) -> [String: Any] {
        guard let rule else { return [:] }
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        var payload: [String: Any] = ["frequency": frequency, "interval": rule.interval]
        rule.recurrenceEnd?.endDate.map { payload["end_at"] = formatter.string(from: $0) }
        return payload
    }
    #endif

    private static var formatter: ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }

    private static func date(_ value: String?) throws -> Date? {
        guard let value = nonBlank(value) else { return nil }
        if let date = formatter.date(from: value) { return date }
        let fallback = ISO8601DateFormatter()
        guard let date = fallback.date(from: value) else { throw IOSAppleAgentToolError.invalidDate }
        return date
    }

    private static func requiredDate(_ value: Any?) throws -> Date {
        guard let value = value as? String, let parsed = try date(value) else {
            throw IOSAppleAgentToolError.invalidDate
        }
        return parsed
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func failure(_ toolName: String, _ reason: String) -> String {
        json(["ok": false, "tool": toolName, "reason": reason])
    }

    private static func json(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private enum IOSAppleAgentToolError: LocalizedError {
    case invalidArguments
    case invalidDate
    case invalidDateRange
    case invalidRecurrence
    case itemNotFound(String)
    case permissionDenied(String)
    case reminderNotFound

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "工具参数无效。"
        case .invalidDate: "日期必须是 ISO-8601 格式。"
        case .invalidDateRange: "日期范围无效或过大。"
        case .invalidRecurrence: "重复规则无效。"
        case .itemNotFound(let name): "找不到对应的\(name)。"
        case .permissionDenied(let name): "未获准访问\(name)，可在系统设置中修改权限。"
        case .reminderNotFound: "找不到对应的提醒事项。"
        }
    }
}
