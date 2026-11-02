import Foundation

/// Human-readable schedule text. The task board, gateway schedule summaries and the schedule tools all
/// emit the same rule line, so it lives with the runtime rather than inside a view.
enum DesktopScheduleText {
    static func rule(_ task: DesktopScheduledTask) -> String {
        switch task.trigger {
        case nil: return rule(task.schedule)
        case .folder(let path): return "文件夹 \(URL(fileURLWithPath: path).lastPathComponent) 有新文件时"
        case .agentSession(.ended): return "Claude Code / Codex 会话结束时"
        case .agentSession(.needsYou): return "Claude Code / Codex 会话等你处理时"
        }
    }

    static func rule(_ schedule: DesktopSchedule) -> String {
        func hhmm(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .once(let date): return "仅一次 · " + clock(date)
        case .daily(let hour, let minute): return "每天 " + hhmm(hour, minute)
        case .weekdays(let hour, let minute): return "工作日 " + hhmm(hour, minute)
        case .weekly(let days, let hour, let minute):
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            return "每周" + days.sorted().map { names[($0 - 1) % 7] }.joined(separator: "、") + " " + hhmm(hour, minute)
        case .interval(let minutes, _):
            return minutes % 60 == 0 ? "每 \(minutes / 60) 小时" : "每 \(minutes) 分钟"
        }
    }

    static func clock(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        if calendar.isDateInToday(date) { return "今天 " + time }
        if calendar.isDateInTomorrow(date) { return "明天 " + time }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.abbreviated)) + " " + time
    }
}
