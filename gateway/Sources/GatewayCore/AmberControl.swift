import Foundation

/// Phone → Mac requests about Amber scheduled tasks. The daemon only authenticates and forwards; the Amber app
/// (listening on `GatewayPaths.amberSocket`) owns the tasks and decides. One JSON request, one JSON reply.
public enum AmberControl {
    public static let timeout: TimeInterval = 5

    public enum Action: String, Codable, Sendable {
        case decide, listSchedules, createSchedule, setScheduleEnabled, runSchedule
    }

    public struct Request: Codable, Sendable, Equatable {
        public var action: Action
        /// `decide`: the gateway session (`amber:<run id>`) and the exact pending call.
        public var sessionKey: String?
        public var toolCallId: String?
        public var allow: Bool?
        /// Schedule actions.
        public var scheduleId: String?
        public var enabled: Bool?
        public var draft: ScheduleDraft?
        /// Paired device that sent it, for the app's own records.
        public var deviceName: String?

        public init(action: Action, sessionKey: String? = nil, toolCallId: String? = nil, allow: Bool? = nil,
                    scheduleId: String? = nil, enabled: Bool? = nil, draft: ScheduleDraft? = nil, deviceName: String? = nil) {
            self.action = action; self.sessionKey = sessionKey; self.toolCallId = toolCallId; self.allow = allow
            self.scheduleId = scheduleId; self.enabled = enabled; self.draft = draft; self.deviceName = deviceName
        }
    }

    /// What a phone may set on a new task. Approval policy is deliberately absent: tasks created remotely
    /// always start with nothing auto-approved.
    public struct ScheduleDraft: Codable, Sendable, Equatable {
        public enum Rule: String, Codable, Sendable { case once, daily, weekdays, weekly, interval }
        public var name: String
        public var prompt: String
        public var rule: Rule
        public var hour: Int?
        public var minute: Int?
        /// Calendar weekdays, 1 = Sunday.
        public var weekdays: [Int]?
        public var intervalMinutes: Int?
        public var at: Date?

        public init(name: String, prompt: String, rule: Rule, hour: Int? = nil, minute: Int? = nil,
                    weekdays: [Int]? = nil, intervalMinutes: Int? = nil, at: Date? = nil) {
            self.name = name; self.prompt = prompt; self.rule = rule; self.hour = hour; self.minute = minute
            self.weekdays = weekdays; self.intervalMinutes = intervalMinutes; self.at = at
        }
    }

    public struct ScheduleSummary: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Human-readable rule, e.g. 每天 09:00.
        public var rule: String
        public var enabled: Bool
        public var running: Bool
        /// All scheduled tasks are paused on the Mac (menu bar 「暂停所有定时任务」).
        public var paused: Bool
        public var nextRunAt: Date?
        public var lastStatus: String?
        public var lastRunAt: Date?
        /// Shown so the phone can warn; never editable from the phone.
        public var autoApprovesHighRisk: Bool

        public init(id: String, name: String, rule: String, enabled: Bool, running: Bool, paused: Bool = false, nextRunAt: Date?,
                    lastStatus: String?, lastRunAt: Date?, autoApprovesHighRisk: Bool) {
            self.id = id; self.name = name; self.rule = rule; self.enabled = enabled; self.running = running; self.paused = paused
            self.nextRunAt = nextRunAt; self.lastStatus = lastStatus; self.lastRunAt = lastRunAt
            self.autoApprovesHighRisk = autoApprovesHighRisk
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        /// HTTP status the daemon returns to the phone.
        public var status: Int
        public var error: String?
        public var schedules: [ScheduleSummary]?
        public var schedule: ScheduleSummary?

        public init(status: Int, error: String? = nil, schedules: [ScheduleSummary]? = nil, schedule: ScheduleSummary? = nil) {
            self.status = status; self.error = error; self.schedules = schedules; self.schedule = schedule
        }

        public static func failure(_ status: Int, _ message: String) -> Response { Response(status: status, error: message) }
    }
}
