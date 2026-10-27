import Foundation

public enum AgentKind: String, Codable, Sendable {
    /// `amber`: a scheduled task run by the Amber Mac app. Reported by the app itself, never by a hook.
    case claude, codex, run, amber
}

public enum SessionOrigin: String, Codable, Sendable {
    /// Terminal CLI session with a human on the other end.
    case interactive
    /// `claude -p`, `codex exec`, `amber-gateway run`.
    case headless
    /// Codex app-server / Claude Agent SDK: one process may carry many sessions.
    case host
}

public enum EventKind: String, Codable, Sendable {
    case sessionStart
    case promptSubmit
    case permissionRequest
    /// Claude `Notification` of a permission/elicitation type (fires ~6s after the prompt).
    case permissionNotice
    /// Claude `Notification` `idle_prompt` (fires ~60s after the turn ended).
    case idleNotice
    case turnStop
    /// Claude `StopFailure`: the turn ended on an API error.
    case turnFailure
    case interrupt
    /// `PostToolUse` (async hook). The only sign that a permission prompt was answered.
    case toolDone
    case sessionEnd
    case runStart
    case runExit
    /// From the Amber app: a model-written title (`GatewayEvent.title`) for an existing session. Changes nothing else.
    case retitle
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startSec: Int64
    public var startUsec: Int64

    public init(pid: Int32, startSec: Int64, startUsec: Int64) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }
}

public struct GatewayEvent: Codable, Sendable, Equatable {
    public var id: String
    public var agent: AgentKind
    public var kind: EventKind
    public var sessionId: String
    public var cwd: String?
    public var timestamp: Date
    public var process: ProcessIdentity?
    public var origin: SessionOrigin?
    public var title: String?
    public var exitCode: Int32?
    public var signal: Int32?
    /// Tool name of `permissionRequest` / `toolDone`.
    public var tool: String?
    /// App that spawned a host session, e.g. "Synara".
    public var host: String?
    /// Amber `permissionRequest` only: the pending tool call, a short argument excerpt and its risk class.
    /// Shown over TLS in `/v1/status`; never put in a push body.
    public var toolCallId: String?
    public var detail: String?
    public var highRisk: Bool?
    /// `promptSubmit` only: a short, whitespace-collapsed excerpt of the user's prompt, used as the task's
    /// display title on the phone (over TLS). Never put in a push body or the outbox.
    public var summary: String?
    /// `promptSubmit` only: a longer opening of the prompt (≤ 400 characters), kept on the Mac so the Amber app
    /// can write a title from it. Never sent to the phone or put in a push.
    public var opening: String?

    public init(
        id: String = UUID().uuidString,
        agent: AgentKind,
        kind: EventKind,
        sessionId: String,
        cwd: String? = nil,
        timestamp: Date = Date(),
        process: ProcessIdentity? = nil,
        origin: SessionOrigin? = nil,
        title: String? = nil,
        exitCode: Int32? = nil,
        signal: Int32? = nil,
        tool: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.timestamp = timestamp
        self.process = process
        self.origin = origin
        self.title = title
        self.exitCode = exitCode
        self.signal = signal
        self.tool = tool
    }
}

public enum TaskState: String, Codable, Sendable {
    /// `stalled`: a headless task with no event for longer than `GatewayConfig.headlessStallMinutes`.
    case running, waiting, stalled, completed, stopped
}

public enum WaitReason: String, Codable, Sendable {
    case turnEnd, permission
}

public struct SessionRecord: Codable, Sendable, Equatable {
    public var key: String
    public var agent: AgentKind
    public var sessionId: String
    public var cwd: String?
    public var title: String?
    /// Opening words of the first prompt (see `GatewayEvent.summary`). Display only; pushes use `subject`.
    public var summary: String?
    /// Opening of the first prompt for title writing; Mac-local (see `GatewayEvent.opening`).
    public var opening: String?
    /// Title the Amber app wrote from `opening`; shown on the phone in place of `summary`.
    public var generatedTitle: String?
    public var origin: SessionOrigin
    /// App hosting the session (host origin only), e.g. "Synara".
    public var host: String?
    public var state: TaskState
    public var waitReason: WaitReason?
    /// Tool that raised the current permission wait; only its own `toolDone` resolves the wait.
    public var waitingTool: String?
    /// Amber permission waits: what the phone shows and answers (see `GatewayEvent`).
    public var waitingToolCallId: String?
    public var waitingDetail: String?
    public var waitingHighRisk: Bool?
    public var abnormal: Bool
    /// A `Stop` or `SessionEnd` was seen; distinguishes clean headless exits from crashes.
    public var sawTurnEnd: Bool
    public var sawFailure: Bool
    public var process: ProcessIdentity?
    public var startedAt: Date
    public var updatedAt: Date
    public var monitored: Bool
    /// Set while a "waiting" push is held back because the user is at the Mac.
    public var pendingPushSince: Date?
    public var lastPushAt: [String: Date]

    public var isOpen: Bool { state == .running || state == .waiting || state == .stalled }

    public static func key(_ agent: AgentKind, _ sessionId: String) -> String {
        "\(agent.rawValue):\(sessionId)"
    }
}

public struct Presence: Sendable, Equatable {
    public var screenLocked: Bool
    public var idleSeconds: Double

    public init(screenLocked: Bool, idleSeconds: Double) {
        self.screenLocked = screenLocked
        self.idleSeconds = idleSeconds
    }

    public func isAway(threshold: Double) -> Bool {
        screenLocked || idleSeconds >= threshold
    }
}

public struct PushIntent: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable { case active, timeSensitive }
    public enum Kind: String, Codable, Sendable { case task, health, sleep, test }

    public var id: String
    public var kind: Kind
    public var sessionKey: String?
    public var agent: AgentKind?
    /// Project directory name, run title, or health metric name. Never contains conversation content.
    public var subject: String
    public var state: TaskState?
    public var waitReason: WaitReason?
    public var abnormal: Bool
    /// Amber approval pushes: lets the phone answer from the notification. Not shown in the push text.
    public var toolCallId: String?
    public var highRisk: Bool?
    /// Short metadata-only line for non-task pushes, e.g. "剩余 12 GB".
    public var detail: String?
    public var level: Level
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString, kind: Kind, sessionKey: String? = nil, agent: AgentKind? = nil,
        subject: String, state: TaskState? = nil, waitReason: WaitReason? = nil, abnormal: Bool = false,
        toolCallId: String? = nil, highRisk: Bool? = nil, detail: String? = nil, level: Level = .active, createdAt: Date
    ) {
        self.toolCallId = toolCallId
        self.highRisk = highRisk
        self.id = id
        self.kind = kind
        self.sessionKey = sessionKey
        self.agent = agent
        self.subject = subject
        self.state = state
        self.waitReason = waitReason
        self.abnormal = abnormal
        self.detail = detail
        self.level = level
        self.createdAt = createdAt
    }
}
