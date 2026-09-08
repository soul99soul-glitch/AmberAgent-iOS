import Foundation

/// Compact, watch-safe view of a chat run. iPhone is the sole authority;
/// Watch only renders this snapshot and returns user intents.
struct WatchTaskSnapshot: Codable, Hashable, Sendable {
    var runId: String
    /// Resolved on iPhone and carried with the snapshot so Watch renders its
    /// fixed copy in the same language as the companion app.
    var languageCode: String? = nil
    var conversationId: String?
    var kind: String
    var phase: String
    var stage: String
    var headline: String
    var detail: String?
    var summary: String?
    var metricText: String?
    var decision: WatchDecision?
    var actions: [WatchAction]
    var updatedAt: Date
    var isStale: Bool
    /// Monotonic phone-owned revision; ISO-8601 timestamps alone lose same-second updates.
    var sequence: Int64? = nil
    var library: WatchLibrarySnapshot? = nil

    static let idle = WatchTaskSnapshot(
        runId: "",
        conversationId: nil,
        kind: "workflow",
        phase: "idle",
        stage: "idle",
        headline: "Amber",
        detail: "没有进行中的任务",
        summary: nil,
        metricText: nil,
        decision: nil,
        actions: [],
        updatedAt: .distantPast,
        isStale: false
    )

    var isActive: Bool {
        !runId.isEmpty && phase != "idle"
    }
}

struct WatchLibrarySnapshot: Codable, Hashable, Sendable {
    var assistantName: String
    var isConfigured: Bool
    var configurationMessage: String? = nil
    var quickActions: [WatchQuickAction]
    var recent: [WatchRecentConversation]
    var activities: [WatchRecentActivity]? = nil
    var updatedAt: Date
}

struct WatchQuickAction: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var prompt: String

    static func supports(prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 2_000
            && text.range(of: #"^\[ROUTE:[^\]]+\]$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
}

struct WatchRecentConversation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var preview: String
    var updatedAt: Date
    var runId: String? = nil
}

/// A compact, phone-authored history item for the Watch library. Terminal
/// activities and notes share this shape, while `kind` keeps notes distinct
/// from AI task completion.
struct WatchRecentActivity: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var runId: String? = nil
    var conversationId: String? = nil
    var kind: String
    var phase: String
    var title: String
    /// Exact title of a persisted result/artifact, when the producer owns one.
    /// `nil` keeps older payloads and ordinary conversation activities on the
    /// conversation-title fallback path.
    var resultTitle: String? = nil
    var summary: String
    var updatedAt: Date
}

struct WatchNote: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var text: String
    var createdAt: Date
    var syncedAt: Date? = nil
}

enum WatchSnapshotOrdering {
    static func accepts(_ incoming: WatchTaskSnapshot, after current: WatchTaskSnapshot) -> Bool {
        if let incomingSequence = incoming.sequence, let currentSequence = current.sequence {
            return incomingSequence > currentSequence || incoming == current
        }
        if current.sequence != nil, incoming.sequence == nil { return false }
        if incoming.sequence != nil, current.sequence == nil { return true }
        return incoming.updatedAt > current.updatedAt || incoming == current
    }
}

enum WatchSnapshotFreshnessPolicy {
    static let staleAfter: TimeInterval = 60

    static func presented(
        _ snapshot: WatchTaskSnapshot,
        isPhoneReachable: Bool,
        now: Date = Date()
    ) -> WatchTaskSnapshot {
        guard snapshot.isActive,
              !["completed", "failed", "cancelled"].contains(snapshot.phase),
              !isPhoneReachable,
              now.timeIntervalSince(snapshot.updatedAt) >= staleAfter else {
            return snapshot
        }
        var stale = snapshot
        stale.phase = "stale"
        stale.stage = "stale"
        stale.detail = nil
        stale.metricText = nil
        stale.decision = nil
        stale.actions = stale.actions.filter { $0 == .openOnPhone }
        stale.isStale = true
        return stale
    }
}

struct WatchDecision: Codable, Hashable, Sendable {
    var id: String
    var type: WatchDecisionType
    var title: String
    var body: String
    var options: [WatchDecisionOption]
    var riskLevel: WatchRiskLevel
    var allowsVoice: Bool
}

enum WatchDecisionType: String, Codable, Hashable, Sendable {
    case approval
    case askUser
    case voiceReply
}

enum WatchRiskLevel: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

struct WatchDecisionOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var style: WatchDecisionOptionStyle
}

enum WatchDecisionOptionStyle: String, Codable, Hashable, Sendable {
    case approve
    case deny
    case choice
    case openOnPhone
    case dictate
}

enum WatchAction: String, Codable, Hashable, Sendable {
    case openOnPhone
    case approve
    case deny
    case choose
    case dictate
    case cancel
    case retry
}

struct WatchTaskActionRequest: Codable, Hashable, Sendable {
    var requestId: String
    var runId: String
    var conversationId: String?
    var decisionId: String?
    var action: WatchInboundAction
    var optionId: String?
    var text: String?
    var createdAt: Date
}

enum WatchInboundAction: String, Codable, Hashable, Sendable {
    case approve
    case deny
    case choose
    case answer
    case cancel
    case retry
    case openOnPhone
    case refresh
    case ask
    case saveNote
    case openConversation
    case runQuickAction
}

struct WatchTaskActionResult: Codable, Hashable, Sendable {
    var requestId: String
    var runId: String
    var accepted: Bool
    var message: String?
    var snapshot: WatchTaskSnapshot?
    var conversationId: String? = nil
    /// A transport timeout is not evidence that the phone did not execute the request.
    var deliveryUnknown: Bool? = nil
}

enum WatchConnectivityPayloadKey {
    static let type = "type"
    static let snapshot = "snapshot"
    static let action = "action"
    static let result = "result"
    static let protocolVersion = "protocolVersion"
    static let currentProtocolVersion = 3

    static let typeSnapshot = "snapshot"
    static let typeAction = "action"
    static let typeActionResult = "actionResult"
    static let typeHello = "hello"
    static let typeRequestSnapshot = "requestSnapshot"
}

enum WatchTaskText {
    static func clipped(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func singleLine(_ text: String?, maxLength: Int) -> String? {
        guard let clipped = clipped(text, maxLength: maxLength * 2) else { return nil }
        let collapsed = clipped
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return Self.clipped(collapsed, maxLength: maxLength)
    }
}

/// Resolves only fixed Watch copy. Dynamic task content must be passed through
/// unchanged by callers.
enum WatchTaskLocalization {
    static func language(for languageCode: String?) -> IOSAppLanguage {
        guard let languageCode, !languageCode.isEmpty else { return .system }
        return IOSAppLanguage(storedValue: languageCode)
    }

    static func string(
        _ key: String,
        defaultValue: String? = nil,
        languageCode: String?
    ) -> String {
        IOSAppLocalization.string(
            key,
            defaultValue: defaultValue ?? key,
            language: language(for: languageCode)
        )
    }

    static func formatted(
        _ key: String,
        defaultValue: String? = nil,
        arguments: [CVarArg],
        languageCode: String?
    ) -> String {
        IOSAppLocalization.formatted(
            key,
            defaultValue: defaultValue ?? key,
            arguments: arguments,
            language: language(for: languageCode)
        )
    }
}

enum WatchTaskCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encodeSnapshot(_ snapshot: WatchTaskSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decodeSnapshot(_ data: Data) throws -> WatchTaskSnapshot {
        try decoder.decode(WatchTaskSnapshot.self, from: data)
    }

    static func encodeAction(_ action: WatchTaskActionRequest) throws -> Data {
        try encoder.encode(action)
    }

    static func decodeAction(_ data: Data) throws -> WatchTaskActionRequest {
        try decoder.decode(WatchTaskActionRequest.self, from: data)
    }

    static func encodeResult(_ result: WatchTaskActionResult) throws -> Data {
        try encoder.encode(result)
    }

    static func decodeResult(_ data: Data) throws -> WatchTaskActionResult {
        try decoder.decode(WatchTaskActionResult.self, from: data)
    }

    static func snapshotMessage(for snapshot: WatchTaskSnapshot) throws -> [String: Any] {
        [
            WatchConnectivityPayloadKey.type: WatchConnectivityPayloadKey.typeSnapshot,
            WatchConnectivityPayloadKey.protocolVersion: WatchConnectivityPayloadKey.currentProtocolVersion,
            WatchConnectivityPayloadKey.snapshot: try encodeSnapshot(snapshot)
        ]
    }

    static func actionMessage(for action: WatchTaskActionRequest) throws -> [String: Any] {
        [
            WatchConnectivityPayloadKey.type: WatchConnectivityPayloadKey.typeAction,
            WatchConnectivityPayloadKey.protocolVersion: WatchConnectivityPayloadKey.currentProtocolVersion,
            WatchConnectivityPayloadKey.action: try encodeAction(action)
        ]
    }

    static func resultMessage(for result: WatchTaskActionResult) throws -> [String: Any] {
        [
            WatchConnectivityPayloadKey.type: WatchConnectivityPayloadKey.typeActionResult,
            WatchConnectivityPayloadKey.protocolVersion: WatchConnectivityPayloadKey.currentProtocolVersion,
            WatchConnectivityPayloadKey.result: try encodeResult(result)
        ]
    }

    static func requestSnapshotMessage() -> [String: Any] {
        [
            WatchConnectivityPayloadKey.type: WatchConnectivityPayloadKey.typeRequestSnapshot,
            WatchConnectivityPayloadKey.protocolVersion: WatchConnectivityPayloadKey.currentProtocolVersion
        ]
    }
}
