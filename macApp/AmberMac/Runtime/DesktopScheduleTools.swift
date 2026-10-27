import Foundation

/// `schedule_list` / `schedule_create` / `schedule_update`: the model drafts scheduled tasks in a conversation.
/// Create and update always go through the approval card (DesktopToolRegistry.alwaysAsks), and none of them can
/// touch a task's approval policy; tasks made here start with nothing auto-approved.
@MainActor enum DesktopScheduleTools {
    static func perform(_ name: String, arguments: [String: Any], scheduler: DesktopScheduler?, calendar: Calendar = .current) async throws -> String {
        guard let scheduler else { throw DesktopRuntimeError.message("定时任务在此环境不可用。") }
        await scheduler.waitUntilLoaded()
        switch name {
        case "schedule_list":
            return try json(scheduler.tasks.map { summary($0, scheduler) })
        case "schedule_create":
            var task = DesktopScheduledTask(name: try text("name", arguments), prompt: try text("prompt", arguments),
                schedule: try schedule(arguments, calendar: calendar))
            if let tools = arguments["use_tools"] as? Bool { task.toolsEnabled = tools }
            if let error = await scheduler.save(task: task) { throw DesktopRuntimeError.message(error) }
            return try json(["ok": true, "task": summary(scheduler.tasks.first { $0.id == task.id } ?? task, scheduler)])
        case "schedule_update":
            guard let id = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)),
                  var task = scheduler.tasks.first(where: { $0.id == id }) else {
                throw DesktopRuntimeError.message("找不到这个定时任务，请先用 schedule_list 查看 id。")
            }
            // A task that runs tools unattended is only changed on its Mac page, where its approval rules are visible.
            if task.approval.autoApproveOrdinary || task.approval.autoApproveHighRisk {
                throw DesktopRuntimeError.message("「\(task.name)」开启了无人值守自动批准，只能在定时任务页修改。")
            }
            if arguments["rule"] == nil, !["hour", "minute", "weekdays", "interval_minutes", "at"].allSatisfy({ arguments[$0] == nil }) {
                throw DesktopRuntimeError.message("修改时间须同时给出 rule。")
            }
            if arguments["name"] != nil { task.name = try text("name", arguments) }
            if arguments["prompt"] != nil { task.prompt = try text("prompt", arguments) }
            if arguments["rule"] != nil { task.schedule = try schedule(arguments, calendar: calendar) }
            if let tools = arguments["use_tools"] as? Bool { task.toolsEnabled = tools }
            if let enabled = arguments["enabled"] as? Bool { task.enabled = enabled }
            if let error = await scheduler.save(task: task) { throw DesktopRuntimeError.message(error) }
            return try json(["ok": true, "task": summary(scheduler.tasks.first { $0.id == id } ?? task, scheduler)])
        default:
            throw DesktopRuntimeError.message("未知的定时任务工具。")
        }
    }

    static func schedule(_ arguments: [String: Any], calendar: Calendar) throws -> DesktopSchedule {
        let hour = arguments["hour"] as? Int, minute = arguments["minute"] as? Int ?? 0
        func needHour() throws -> Int {
            guard let hour else { throw DesktopRuntimeError.message("这个时间规则需要 hour。") }
            return hour
        }
        switch arguments["rule"] as? String {
        case "once":
            guard let text = arguments["at"] as? String, let date = localDate(text, calendar: calendar) else {
                throw DesktopRuntimeError.message("仅一次规则需要 at，格式 yyyy-MM-dd HH:mm。")
            }
            return .once(date)
        case "daily": return .daily(hour: try needHour(), minute: minute)
        case "weekdays": return .weekdays(hour: try needHour(), minute: minute)
        case "weekly":
            guard let days = arguments["weekdays"] as? [Int], !days.isEmpty else { throw DesktopRuntimeError.message("每周规则需要 weekdays。") }
            return .weekly(days: days, hour: try needHour(), minute: minute)
        case "interval":
            guard let minutes = arguments["interval_minutes"] as? Int else { throw DesktopRuntimeError.message("间隔规则需要 interval_minutes。") }
            return .interval(minutes: minutes, anchor: Date())
        default:
            throw DesktopRuntimeError.message("rule 须为 once / daily / weekdays / weekly / interval。")
        }
    }

    private static func localDate(_ text: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static func summary(_ task: DesktopScheduledTask, _ scheduler: DesktopScheduler) -> [String: Any] {
        var value: [String: Any] = ["id": task.id.uuidString, "name": task.name, "rule": DesktopScheduledTasksView.ruleText(task.schedule),
            "enabled": task.enabled, "running": scheduler.running.contains(task.id)]
        if let next = task.nextRunAt { value["next_run"] = next.formatted(.iso8601) }
        if let last = task.lastRun { value["last_status"] = last.status.rawValue }
        value["auto_approves"] = task.approval.autoApproveOrdinary || task.approval.autoApproveHighRisk
        return value
    }

    private static func text(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw DesktopRuntimeError.message("工具参数 \(key) 缺失。")
        }
        return value
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
