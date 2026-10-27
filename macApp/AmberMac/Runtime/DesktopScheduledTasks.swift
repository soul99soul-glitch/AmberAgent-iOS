import Foundation

/// When a scheduled task fires. Wall-clock rules (daily/weekdays/weekly) follow the calendar's current time zone,
/// so they keep firing at 9:00 local across DST changes and time-zone moves; `once` and `interval` are absolute.
enum DesktopSchedule: Codable, Equatable, Sendable {
    case once(Date)
    case daily(hour: Int, minute: Int)
    /// Monday–Friday.
    case weekdays(hour: Int, minute: Int)
    /// `days` uses Calendar weekday numbers: 1 = Sunday … 7 = Saturday.
    case weekly(days: [Int], hour: Int, minute: Int)
    /// Every `minutes` (≥ 15), counted from `anchor`.
    case interval(minutes: Int, anchor: Date)

    static let minimumIntervalMinutes = 15

    var validationError: String? {
        switch self {
        case .once: return nil
        case .daily(let hour, let minute), .weekdays(let hour, let minute):
            return Self.clockError(hour, minute)
        case .weekly(let days, let hour, let minute):
            if days.isEmpty { return "每周规则至少选择一天。" }
            if days.contains(where: { !(1...7).contains($0) }) { return "星期取值无效。" }
            return Self.clockError(hour, minute)
        case .interval(let minutes, _):
            return minutes < Self.minimumIntervalMinutes ? "间隔不能小于 \(Self.minimumIntervalMinutes) 分钟。" : nil
        }
    }

    private static func clockError(_ hour: Int, _ minute: Int) -> String? {
        (0...23).contains(hour) && (0...59).contains(minute) ? nil : "时间无效。"
    }

    /// The first fire time strictly after `date`, or nil when the rule is exhausted or invalid.
    func nextFire(after date: Date, calendar: Calendar) -> Date? {
        guard validationError == nil else { return nil }
        switch self {
        case .once(let at):
            return at > date ? at : nil
        case .daily(let hour, let minute):
            return Self.next(after: date, calendar: calendar, components: DateComponents(hour: hour, minute: minute, second: 0))
        case .weekdays(let hour, let minute):
            return Self.nextWeekly(after: date, calendar: calendar, days: [2, 3, 4, 5, 6], hour: hour, minute: minute)
        case .weekly(let days, let hour, let minute):
            return Self.nextWeekly(after: date, calendar: calendar, days: Set(days), hour: hour, minute: minute)
        case .interval(let minutes, let anchor):
            let step = TimeInterval(minutes * 60)
            guard date >= anchor else { return anchor }
            let elapsed = (date.timeIntervalSince(anchor) / step).rounded(.down) + 1
            return anchor.addingTimeInterval(elapsed * step)
        }
    }

    private static func nextWeekly(after date: Date, calendar: Calendar, days: Set<Int>, hour: Int, minute: Int) -> Date? {
        days.compactMap {
            next(after: date, calendar: calendar, components: DateComponents(hour: hour, minute: minute, second: 0, weekday: $0))
        }.min()
    }

    /// Spring-forward: a nonexistent 2:30 fires at the next valid moment (3:00) that day.
    /// Fall-back: a repeated 1:30 fires once, on its first occurrence.
    private static func next(after date: Date, calendar: Calendar, components: DateComponents) -> Date? {
        calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}

enum DesktopScheduleOutput: Codable, Equatable, Sendable {
    case newConversation
    case appendTo(UUID)
}

enum DesktopMissedRunPolicy: String, Codable, Sendable {
    /// After sleep or a quit, run once for however many slots were missed.
    case runOnceOnWake
    /// Drop missed slots and wait for the next one.
    case skip
}

/// A scheduled task's own approval rules; unattended runs never read the conversation-level switches.
struct DesktopUnattendedApproval: Codable, Equatable, Sendable {
    var autoApproveOrdinary = false
    var autoApproveHighRisk = false
    /// nil = every exposed tool; otherwise calls outside the list are denied.
    var allowedTools: [String]?
    /// An approval left unanswered this long fails the run.
    var approvalTimeoutHours = 12

    var policy: DesktopApprovalPolicy {
        DesktopApprovalPolicy(autoApproveOrdinary: autoApproveOrdinary, autoApproveHighRisk: autoApproveHighRisk,
            allowedTools: allowedTools.map(Set.init))
    }
}

enum DesktopScheduleRunStatus: String, Codable, Sendable {
    case running, completed, failed, skipped
}

struct DesktopScheduleRunRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var scheduledFor: Date?
    var startedAt: Date
    var finishedAt: Date?
    var status: DesktopScheduleRunStatus
    var conversationID: UUID?
    var agentRunID: UUID?
    var error: String?
    /// Tool calls that ran without a human approving them, for after-the-fact review.
    var autoApprovedTools: [String] = []
}

struct DesktopScheduledTask: Identifiable, Codable, Equatable, Sendable {
    static let currentSchema = "amber.schedule.v1"

    var schema = Self.currentSchema
    let id: UUID
    var name: String
    var prompt: String
    var schedule: DesktopSchedule
    /// nil = the default model at run time.
    var providerID: UUID?
    var toolsEnabled = true
    var subagentsEnabled = false
    var approval = DesktopUnattendedApproval()
    var output = DesktopScheduleOutput.newConversation
    var missedRun = DesktopMissedRunPolicy.runOnceOnWake
    var enabled = true
    var createdAt: Date
    var lastRun: DesktopScheduleRunRecord?
    var nextRunAt: Date?

    init(id: UUID = UUID(), name: String, prompt: String, schedule: DesktopSchedule, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.prompt = prompt; self.schedule = schedule; self.createdAt = createdAt
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写任务名称。" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写提示词。" }
        if approval.approvalTimeoutHours < 1 { return "审批超时至少 1 小时。" }
        return schedule.validationError
    }
}

/// What the scheduler should do with a task at `now`. Pure so the clock and calendar can be injected in tests.
enum DesktopScheduleDecision: Equatable, Sendable {
    /// Not due; wake up at the date (nil = never).
    case wait(Date?)
    /// Run now for the slot `scheduledFor`; afterwards the next slot is `nextRunAt`.
    case run(scheduledFor: Date, nextRunAt: Date?)
    /// Missed slots dropped by `.skip`; next slot is `nextRunAt`.
    case skip(missed: Date, nextRunAt: Date?)
}

enum DesktopSchedulePlanner {
    /// A slot reached within this window counts as on time, not missed (timer jitter, brief stalls).
    static let onTimeGrace: TimeInterval = 120

    /// First slot for a new or edited task: the next one strictly after `now`.
    static func initialNextRun(_ task: DesktopScheduledTask, now: Date, calendar: Calendar) -> Date? {
        guard task.enabled else { return nil }
        return task.schedule.nextFire(after: now, calendar: calendar)
    }

    /// However many slots were missed, at most one run is produced and the next slot jumps past `now`.
    static func decide(_ task: DesktopScheduledTask, now: Date, calendar: Calendar) -> DesktopScheduleDecision {
        guard task.enabled, let due = task.nextRunAt else { return .wait(nil) }
        guard due <= now else { return .wait(due) }
        let following = task.schedule.nextFire(after: now, calendar: calendar)
        if now.timeIntervalSince(due) <= onTimeGrace || task.missedRun == .runOnceOnWake {
            return .run(scheduledFor: due, nextRunAt: following)
        }
        return .skip(missed: due, nextRunAt: following)
    }

    /// After a time-zone or clock change: wall-clock rules move to the new local time. A slot already due
    /// stays due so the missed-run policy still applies to it.
    static func recompute(_ task: DesktopScheduledTask, now: Date, calendar: Calendar) -> Date? {
        guard task.enabled else { return nil }
        if let due = task.nextRunAt, due <= now { return due }
        return task.schedule.nextFire(after: now, calendar: calendar)
    }
}

struct DesktopScheduleLoadResult: Sendable {
    var tasks: [DesktopScheduledTask]
    /// Files that failed to decode; left untouched on disk.
    var unreadable: [String]
}

/// One JSON file per task, written atomically (same shape as DesktopAgentJournal).
actor DesktopScheduleStore {
    let directory: URL?
    private var tasks: [UUID: DesktopScheduledTask] = [:]

    init(directory: URL?) { self.directory = directory }

    func load() throws -> DesktopScheduleLoadResult {
        var unreadable: [String] = []
        tasks = [:]
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let task = try? JSONDecoder().decode(DesktopScheduledTask.self, from: data),
                      task.schema == DesktopScheduledTask.currentSchema else {
                    unreadable.append(url.lastPathComponent)
                    continue
                }
                tasks[task.id] = task
            }
        }
        return DesktopScheduleLoadResult(tasks: sorted(), unreadable: unreadable.sorted())
    }

    func save(_ task: DesktopScheduledTask) throws {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(task).write(to: fileURL(task.id, in: directory), options: .atomic)
        }
        tasks[task.id] = task
    }

    func delete(_ id: UUID) throws {
        if let directory {
            let url = fileURL(id, in: directory)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        tasks[id] = nil
    }

    func all() -> [DesktopScheduledTask] { sorted() }

    private func sorted() -> [DesktopScheduledTask] { tasks.values.sorted { $0.createdAt < $1.createdAt } }
    private func fileURL(_ id: UUID, in directory: URL) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
