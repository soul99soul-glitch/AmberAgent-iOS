import Combine
import Foundation

// MARK: - Cloud Proactive Wire DTOs (/v2/proactive/*)

enum CloudProactiveFeedbackAction: String, Codable, Equatable, CaseIterable, Sendable {
    case opened
    case replied
    case dismiss
    case snooze
    case muteTopic = "mute_topic"
}

struct CloudProactiveMonitorRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: String
    var conditionPrompt: String = ""
    var intervalMinutes: Int = 15
    var enabled: Bool = true
    var createdAtMs: Int64 = 0
    var lastCheckedAtMs: Int64? = nil
    var lastOutcome: String? = nil
    var lastSummary: String? = nil
    var consecutiveUnchanged: Int = 0
    var nextRunAtMs: Int64 = 0
    var deliveryMode: String = "immediate"

    init(
        id: String,
        title: String,
        url: String,
        conditionPrompt: String = "",
        intervalMinutes: Int = 15,
        enabled: Bool = true,
        createdAtMs: Int64 = 0,
        lastCheckedAtMs: Int64? = nil,
        lastOutcome: String? = nil,
        lastSummary: String? = nil,
        consecutiveUnchanged: Int = 0,
        nextRunAtMs: Int64 = 0,
        deliveryMode: String = "immediate"
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.conditionPrompt = conditionPrompt
        self.intervalMinutes = intervalMinutes
        self.enabled = enabled
        self.createdAtMs = createdAtMs
        self.lastCheckedAtMs = lastCheckedAtMs
        self.lastOutcome = lastOutcome
        self.lastSummary = lastSummary
        self.consecutiveUnchanged = consecutiveUnchanged
        self.nextRunAtMs = nextRunAtMs
        self.deliveryMode = deliveryMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, conditionPrompt, intervalMinutes, enabled
        case createdAtMs, lastCheckedAtMs, lastOutcome, lastSummary
        case consecutiveUnchanged, nextRunAtMs, deliveryMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        conditionPrompt = try container.decodeIfPresent(String.self, forKey: .conditionPrompt) ?? ""
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        lastCheckedAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastCheckedAtMs)
        lastOutcome = try container.decodeIfPresent(String.self, forKey: .lastOutcome)
        lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        consecutiveUnchanged = try container.decodeIfPresent(Int.self, forKey: .consecutiveUnchanged) ?? 0
        nextRunAtMs = try container.decodeIfPresent(Int64.self, forKey: .nextRunAtMs) ?? 0
        deliveryMode = try container.decodeIfPresent(String.self, forKey: .deliveryMode) ?? "immediate"
    }
}

struct CloudProactiveWebhookRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var enabled: Bool = true
    var instruction: String = ""
    var createdAtMs: Int64 = 0
    var lastTriggeredAtMs: Int64? = nil
    var triggerCount: Int = 0

    init(
        id: String,
        name: String,
        enabled: Bool = true,
        instruction: String = "",
        createdAtMs: Int64 = 0,
        lastTriggeredAtMs: Int64? = nil,
        triggerCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.instruction = instruction
        self.createdAtMs = createdAtMs
        self.lastTriggeredAtMs = lastTriggeredAtMs
        self.triggerCount = triggerCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, instruction, createdAtMs, lastTriggeredAtMs, triggerCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        lastTriggeredAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastTriggeredAtMs)
        triggerCount = try container.decodeIfPresent(Int.self, forKey: .triggerCount) ?? 0
    }
}

struct CloudProactiveMutedTopic: Codable, Equatable, Identifiable, Sendable {
    var topicKey: String
    var untilEpochMs: Int64

    var id: String { topicKey }

    init(topicKey: String, untilEpochMs: Int64) {
        self.topicKey = topicKey
        self.untilEpochMs = untilEpochMs
    }

    private enum CodingKeys: String, CodingKey {
        case topicKey, untilEpochMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topicKey = try container.decode(String.self, forKey: .topicKey)
        untilEpochMs = try container.decodeIfPresent(Int64.self, forKey: .untilEpochMs) ?? 0
    }
}

struct CloudProactiveRestraintSnapshot: Codable, Equatable, Sendable {
    var quietHoursEnabled: Bool = true
    var quietHoursStart: String = "23:00"
    var quietHoursEnd: String = "08:00"
    var zoneId: String = "Asia/Shanghai"
    var dailyMaxPushes: Int = 5
    var pushesToday: Int = 0
    var remainingToday: Int = 0
    var bufferedPulseCount: Int = 0
    var mutedTopicsCount: Int = 0
    var pulseEnabled: Bool = true
    var pulseTime: String = "08:30"
    var commitmentExtractionEnabled: Bool = true
    var mutedTopics: [CloudProactiveMutedTopic] = []

    init(
        quietHoursEnabled: Bool = true,
        quietHoursStart: String = "23:00",
        quietHoursEnd: String = "08:00",
        zoneId: String = "Asia/Shanghai",
        dailyMaxPushes: Int = 5,
        pushesToday: Int = 0,
        remainingToday: Int = 0,
        bufferedPulseCount: Int = 0,
        mutedTopicsCount: Int = 0,
        pulseEnabled: Bool = true,
        pulseTime: String = "08:30",
        commitmentExtractionEnabled: Bool = true,
        mutedTopics: [CloudProactiveMutedTopic] = []
    ) {
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.zoneId = zoneId
        self.dailyMaxPushes = dailyMaxPushes
        self.pushesToday = pushesToday
        self.remainingToday = remainingToday
        self.bufferedPulseCount = bufferedPulseCount
        self.mutedTopicsCount = mutedTopicsCount
        self.pulseEnabled = pulseEnabled
        self.pulseTime = pulseTime
        self.commitmentExtractionEnabled = commitmentExtractionEnabled
        self.mutedTopics = mutedTopics
    }

    private enum CodingKeys: String, CodingKey {
        case quietHoursEnabled, quietHoursStart, quietHoursEnd, zoneId
        case dailyMaxPushes, pushesToday, remainingToday
        case bufferedPulseCount, mutedTopicsCount
        case pulseEnabled, pulseTime, commitmentExtractionEnabled, mutedTopics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? true
        quietHoursStart = try container.decodeIfPresent(String.self, forKey: .quietHoursStart) ?? "23:00"
        quietHoursEnd = try container.decodeIfPresent(String.self, forKey: .quietHoursEnd) ?? "08:00"
        zoneId = try container.decodeIfPresent(String.self, forKey: .zoneId) ?? "Asia/Shanghai"
        dailyMaxPushes = try container.decodeIfPresent(Int.self, forKey: .dailyMaxPushes) ?? 5
        pushesToday = try container.decodeIfPresent(Int.self, forKey: .pushesToday) ?? 0
        remainingToday = try container.decodeIfPresent(Int.self, forKey: .remainingToday) ?? 0
        bufferedPulseCount = try container.decodeIfPresent(Int.self, forKey: .bufferedPulseCount) ?? 0
        mutedTopicsCount = try container.decodeIfPresent(Int.self, forKey: .mutedTopicsCount) ?? 0
        pulseEnabled = try container.decodeIfPresent(Bool.self, forKey: .pulseEnabled) ?? true
        pulseTime = try container.decodeIfPresent(String.self, forKey: .pulseTime) ?? "08:30"
        commitmentExtractionEnabled = try container.decodeIfPresent(Bool.self, forKey: .commitmentExtractionEnabled) ?? true
        mutedTopics = try container.decodeIfPresent([CloudProactiveMutedTopic].self, forKey: .mutedTopics) ?? []
    }
}

struct CloudProactiveRunHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var signalId: String = ""
    var category: String = ""
    var topicKey: String = ""
    var title: String = ""
    /// Unknown server outcome values are preserved verbatim for forward compatibility.
    var outcome: String = ""
    var summary: String = ""
    var timestampEpochMs: Int64 = 0

    init(
        id: String,
        signalId: String = "",
        category: String = "",
        topicKey: String = "",
        title: String = "",
        outcome: String = "",
        summary: String = "",
        timestampEpochMs: Int64 = 0
    ) {
        self.id = id
        self.signalId = signalId
        self.category = category
        self.topicKey = topicKey
        self.title = title
        self.outcome = outcome
        self.summary = summary
        self.timestampEpochMs = timestampEpochMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, signalId, category, topicKey, title, outcome, summary, timestampEpochMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        signalId = try container.decodeIfPresent(String.self, forKey: .signalId) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        topicKey = try container.decodeIfPresent(String.self, forKey: .topicKey) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        timestampEpochMs = try container.decodeIfPresent(Int64.self, forKey: .timestampEpochMs) ?? 0
    }
}

struct CloudProactiveWakeupRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var title: String
    var detail: String = ""
    var checkPrompt: String? = nil
    var triggerAtEpochMs: Int64
    var userRequested: Bool = false
    var originSignalId: String? = nil
    var sourceConversationId: String? = nil
    var status: String = "pending"
    var createdAtEpochMs: Int64 = 0
    var firedAtEpochMs: Int64? = nil

    init(
        id: String,
        kind: String,
        title: String,
        detail: String = "",
        checkPrompt: String? = nil,
        triggerAtEpochMs: Int64,
        userRequested: Bool = false,
        originSignalId: String? = nil,
        sourceConversationId: String? = nil,
        status: String = "pending",
        createdAtEpochMs: Int64 = 0,
        firedAtEpochMs: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.checkPrompt = checkPrompt
        self.triggerAtEpochMs = triggerAtEpochMs
        self.userRequested = userRequested
        self.originSignalId = originSignalId
        self.sourceConversationId = sourceConversationId
        self.status = status
        self.createdAtEpochMs = createdAtEpochMs
        self.firedAtEpochMs = firedAtEpochMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, checkPrompt, triggerAtEpochMs
        case userRequested, originSignalId, sourceConversationId
        case status, createdAtEpochMs, firedAtEpochMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        checkPrompt = try container.decodeIfPresent(String.self, forKey: .checkPrompt)
        triggerAtEpochMs = try container.decode(Int64.self, forKey: .triggerAtEpochMs)
        userRequested = try container.decodeIfPresent(Bool.self, forKey: .userRequested) ?? false
        originSignalId = try container.decodeIfPresent(String.self, forKey: .originSignalId)
        sourceConversationId = try container.decodeIfPresent(String.self, forKey: .sourceConversationId)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        createdAtEpochMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtEpochMs) ?? 0
        firedAtEpochMs = try container.decodeIfPresent(Int64.self, forKey: .firedAtEpochMs)
    }
}

struct CloudProactiveSummary: Codable, Equatable, Sendable {
    var monitors: [CloudProactiveMonitorRecord] = []
    var webhooks: [CloudProactiveWebhookRecord] = []
    var restraint: CloudProactiveRestraintSnapshot
    var recentRuns: [CloudProactiveRunHistoryEntry] = []
    var wakeups: [CloudProactiveWakeupRecord] = []

    init(
        monitors: [CloudProactiveMonitorRecord] = [],
        webhooks: [CloudProactiveWebhookRecord] = [],
        restraint: CloudProactiveRestraintSnapshot = CloudProactiveRestraintSnapshot(),
        recentRuns: [CloudProactiveRunHistoryEntry] = [],
        wakeups: [CloudProactiveWakeupRecord] = []
    ) {
        self.monitors = monitors
        self.webhooks = webhooks
        self.restraint = restraint
        self.recentRuns = recentRuns
        self.wakeups = wakeups
    }

    private enum CodingKeys: String, CodingKey {
        case monitors, webhooks, restraint, recentRuns, wakeups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitors = try container.decodeIfPresent([CloudProactiveMonitorRecord].self, forKey: .monitors) ?? []
        webhooks = try container.decodeIfPresent([CloudProactiveWebhookRecord].self, forKey: .webhooks) ?? []
        restraint = try container.decodeIfPresent(CloudProactiveRestraintSnapshot.self, forKey: .restraint)
            ?? CloudProactiveRestraintSnapshot()
        recentRuns = try container.decodeIfPresent([CloudProactiveRunHistoryEntry].self, forKey: .recentRuns) ?? []
        wakeups = try container.decodeIfPresent([CloudProactiveWakeupRecord].self, forKey: .wakeups) ?? []
    }
}

struct CloudProactiveRestraintPatch: Codable, Equatable, Sendable {
    var quietHoursEnabled: Bool? = nil
    var quietHoursStart: String? = nil
    var quietHoursEnd: String? = nil
    var dailyMaxPushes: Int? = nil
    var pulseEnabled: Bool? = nil
    var pulseTime: String? = nil
    var commitmentExtractionEnabled: Bool? = nil

    init(
        quietHoursEnabled: Bool? = nil,
        quietHoursStart: String? = nil,
        quietHoursEnd: String? = nil,
        dailyMaxPushes: Int? = nil,
        pulseEnabled: Bool? = nil,
        pulseTime: String? = nil,
        commitmentExtractionEnabled: Bool? = nil
    ) {
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.dailyMaxPushes = dailyMaxPushes
        self.pulseEnabled = pulseEnabled
        self.pulseTime = pulseTime
        self.commitmentExtractionEnabled = commitmentExtractionEnabled
    }
}

struct CloudProactiveFeedbackResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var action: String
    var applied: Bool
    var wakeupId: String? = nil
    var mutedUntilEpochMs: Int64? = nil
}

struct CloudProactiveSignalResponse: Codable, Equatable, Sendable {
    var event: MacGatewayCloudDialogueEvent
}

// MARK: - MacGatewayClient Proactive Endpoints

extension MacGatewayClient {
    private static let proactivePathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]")
        return allowed
    }()

    /// Validates signal IDs against the frozen contract `^[A-Za-z0-9_-]{1,48}$`.
    static func isValidProactiveSignalId(_ signalId: String) -> Bool {
        guard !signalId.isEmpty, signalId.utf8.count <= 48 else { return false }
        return signalId.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)      // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F                           // _
                || scalar.value == 0x2D                           // -
        }
    }

    /// Validates wakeup IDs against `^[A-Za-z0-9_-]{1,64}$` before issuing DELETE requests.
    static func isValidProactiveWakeupId(_ wakeupId: String) -> Bool {
        guard !wakeupId.isEmpty, wakeupId.utf8.count <= 64 else { return false }
        return wakeupId.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)      // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F                           // _
                || scalar.value == 0x2D                           // -
        }
    }

    /// Valid monitor delivery modes per the frozen Phase 3 contract.
    static func isValidProactiveMonitorDeliveryMode(_ mode: String) -> Bool {
        mode == "immediate" || mode == "digest"
    }

    /// Both path segments are ASCII. Managed GitHub users can have an enterprise shortcode suffix.
    static func buildGitHubReleaseFeedURL(from repoSlug: String) -> URL? {
        let parts = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        guard owner.utf8.count <= 39,
              owner.range(of: #"\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?:_[A-Za-z0-9]+)?\z"#, options: .regularExpression) != nil,
              repo.utf8.count <= 100, repo != ".", !repo.contains(".."),
              repo.range(of: #"\A[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")
    }

    private static func encodeProactivePathSegment(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: proactivePathAllowed),
              !encoded.isEmpty else {
            throw MacGatewayError.server("invalid_identifier")
        }
        return encoded
    }

    private static func validatedEncodedSignalId(_ signalId: String) throws -> String {
        guard isValidProactiveSignalId(signalId),
              let encoded = signalId.addingPercentEncoding(withAllowedCharacters: proactivePathAllowed) else {
            throw MacGatewayError.server("invalid_signal_id")
        }
        return encoded
    }

    private static func validatedEncodedWakeupId(_ wakeupId: String) throws -> String {
        guard isValidProactiveWakeupId(wakeupId),
              let encoded = wakeupId.addingPercentEncoding(withAllowedCharacters: proactivePathAllowed) else {
            throw MacGatewayError.server("invalid_wakeup_id")
        }
        return encoded
    }

    func fetchProactiveSummary() async throws -> CloudProactiveSummary {
        try decode(await send("GET", "/v2/proactive/summary"))
    }

    func fetchProactiveSignal(signalId: String) async throws -> MacGatewayCloudDialogueEvent {
        let encoded = try Self.validatedEncodedSignalId(signalId)
        let response: CloudProactiveSignalResponse = try decode(
            await send("GET", "/v2/proactive/signals/\(encoded)")
        )
        guard response.event.proactiveSignalId == signalId else { throw MacGatewayError.invalidResponse }
        return response.event
    }

    func sendProactiveFeedback(
        signalId: String,
        action: CloudProactiveFeedbackAction,
        snoozeMinutes: Int? = nil,
        muteHours: Int? = nil
    ) async throws -> CloudProactiveFeedbackResponse {
        let encoded = try Self.validatedEncodedSignalId(signalId)
        var body: [String: Any] = ["action": action.rawValue]
        if let snoozeMinutes {
            body["snoozeMinutes"] = snoozeMinutes
        }
        if let muteHours {
            body["muteHours"] = muteHours
        }
        let receipt: CloudProactiveFeedbackResponse = try decode(
            await send("POST", "/v2/proactive/signals/\(encoded)/feedback", body: body)
        )
        guard receipt.ok, receipt.action == action.rawValue else { throw MacGatewayError.invalidResponse }
        return receipt
    }

    @discardableResult
    func setProactiveMonitorEnabled(id: String, enabled: Bool) async throws -> CloudProactiveMonitorRecord {
        struct Response: Decodable { var monitor: CloudProactiveMonitorRecord }
        let encoded = try Self.encodeProactivePathSegment(id)
        let response: Response = try decode(
            await send("PATCH", "/v2/proactive/monitors/\(encoded)", body: ["enabled": enabled])
        )
        return response.monitor
    }

    @discardableResult
    func setProactiveMonitorDeliveryMode(id: String, deliveryMode: String) async throws -> CloudProactiveMonitorRecord {
        struct Response: Decodable { var monitor: CloudProactiveMonitorRecord }
        guard Self.isValidProactiveMonitorDeliveryMode(deliveryMode) else {
            throw MacGatewayError.server("invalid_delivery_mode")
        }
        let encoded = try Self.encodeProactivePathSegment(id)
        let response: Response = try decode(
            await send("PATCH", "/v2/proactive/monitors/\(encoded)", body: ["deliveryMode": deliveryMode])
        )
        return response.monitor
    }

    @discardableResult
    func createProactiveMonitor(
        name: String,
        url: String,
        deliveryMode: String
    ) async throws -> CloudProactiveMonitorRecord {
        struct Response: Decodable { var monitor: CloudProactiveMonitorRecord }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MacGatewayError.server("invalid_monitor_title")
        }
        guard let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = parsedURL.host,
              !host.isEmpty else {
            throw MacGatewayError.server("invalid_monitor_url")
        }
        guard Self.isValidProactiveMonitorDeliveryMode(deliveryMode) else {
            throw MacGatewayError.server("invalid_delivery_mode")
        }
        let response: Response = try decode(
            await send(
                "POST",
                "/v2/proactive/monitors",
                body: [
                    "title": trimmedName,
                    "url": trimmedURL,
                    "deliveryMode": deliveryMode,
                ]
            )
        )
        return response.monitor
    }

    func deleteProactiveMonitor(id: String) async throws {
        let encoded = try Self.encodeProactivePathSegment(id)
        _ = try await send("DELETE", "/v2/proactive/monitors/\(encoded)")
    }

    func cancelProactiveWakeup(id: String) async throws {
        let encoded = try Self.validatedEncodedWakeupId(id)
        _ = try await send("DELETE", "/v2/proactive/wakeups/\(encoded)")
    }

    @discardableResult
    func setProactiveWebhookEnabled(id: String, enabled: Bool) async throws -> CloudProactiveWebhookRecord {
        struct Response: Decodable { var webhook: CloudProactiveWebhookRecord }
        let encoded = try Self.encodeProactivePathSegment(id)
        let response: Response = try decode(
            await send("PATCH", "/v2/proactive/webhooks/\(encoded)", body: ["enabled": enabled])
        )
        return response.webhook
    }

    func deleteProactiveWebhook(id: String) async throws {
        let encoded = try Self.encodeProactivePathSegment(id)
        _ = try await send("DELETE", "/v2/proactive/webhooks/\(encoded)")
    }

    @discardableResult
    func updateProactiveRestraint(_ patch: CloudProactiveRestraintPatch) async throws -> CloudProactiveRestraintSnapshot {
        struct Response: Decodable { var restraint: CloudProactiveRestraintSnapshot }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(patch)
        let response: Response = try decode(
            await sendData("PATCH", "/v2/proactive/restraint", bodyData: bodyData)
        )
        return response.restraint
    }

    @discardableResult
    func unmuteProactiveTopic(_ topicKey: String) async throws -> CloudProactiveRestraintSnapshot {
        struct Response: Decodable { var restraint: CloudProactiveRestraintSnapshot }
        let response: Response = try decode(
            await send("POST", "/v2/proactive/restraint/unmute", body: ["topicKey": topicKey])
        )
        return response.restraint
    }
}

// MARK: - CloudProactiveStore

@MainActor
final class CloudProactiveStore: ObservableObject {
    static let shared = CloudProactiveStore()

    @Published private(set) var summary: CloudProactiveSummary?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?
    @Published var pendingSignalId: String?

    private let clientProvider: @MainActor () -> MacGatewayClient?
    private let localEventsProvider: @MainActor () -> [MacGatewayCloudDialogueEvent]
    private let sendCloudMessageHandler: @MainActor (String) async -> Result<MacGatewayCloudDialogueReceipt, Error>

    init(
        clientProvider: @escaping @MainActor () -> MacGatewayClient? = {
            MacGatewayStore.shared.slot(for: .cloud).client
        },
        localEventsProvider: @escaping @MainActor () -> [MacGatewayCloudDialogueEvent] = {
            MacGatewayStore.shared.slot(for: .cloud).cloudDialogueEvents
        },
        sendCloudMessageHandler: @escaping @MainActor (String) async -> Result<MacGatewayCloudDialogueReceipt, Error> = { text in
            await MacGatewayStore.shared.slot(for: .cloud).sendCloudDialogueMessage(text: text)
        }
    ) {
        self.clientProvider = clientProvider
        self.localEventsProvider = localEventsProvider
        self.sendCloudMessageHandler = sendCloudMessageHandler
    }

    convenience init(gatewayStore: MacGatewayStore) {
        self.init(
            clientProvider: { gatewayStore.slot(for: .cloud).client },
            localEventsProvider: { gatewayStore.slot(for: .cloud).cloudDialogueEvents },
            sendCloudMessageHandler: { text in
                await gatewayStore.slot(for: .cloud).sendCloudDialogueMessage(text: text)
            }
        )
    }

    func dismissSignal(_ signalId: String) {
        if pendingSignalId == signalId { pendingSignalId = nil }
    }

    private func requireClient() -> MacGatewayClient? {
        guard let client = clientProvider() else {
            let message = IOSAppLocalization.string("尚未配对 Amber · 云端", defaultValue: "尚未配对 Amber · 云端")
            if lastError != message { lastError = message }
            return nil
        }
        return client
    }

    private func clearErrorIfNeeded() {
        if lastError != nil { lastError = nil }
    }

    private func recordError(_ error: Error) {
        let message = error.localizedDescription
        if lastError != message { lastError = message }
    }

    func refreshSummary() async {
        guard !isLoading, let client = requireClient() else { return }
        isLoading = true
        defer { isLoading = false }
        let previous = summary
        do {
            let fetched = try await client.fetchProactiveSummary()
            guard summary == previous, clientProvider() === client else { return }
            if summary != fetched { summary = fetched }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func sendFeedback(
        signalId: String,
        action: CloudProactiveFeedbackAction,
        snoozeMinutes: Int? = nil
    ) async -> Bool {
        guard let client = requireClient() else { return false }
        do {
            _ = try await client.sendProactiveFeedback(
                signalId: signalId,
                action: action,
                snoozeMinutes: snoozeMinutes
            )
            clearErrorIfNeeded()
            return true
        } catch {
            recordError(error)
            return false
        }
    }

    func loadSignal(_ signalId: String) async -> MacGatewayCloudDialogueEvent? {
        guard MacGatewayClient.isValidProactiveSignalId(signalId) else {
            let message = IOSAppLocalization.string("无效的主动消息标识", defaultValue: "无效的主动消息标识")
            if lastError != message { lastError = message }
            return nil
        }

        if let cached = localEventsProvider().last(where: { $0.proactiveSignalId == signalId }) {
            clearErrorIfNeeded()
            return cached
        }

        guard let client = requireClient() else { return nil }
        do {
            let fetched = try await client.fetchProactiveSignal(signalId: signalId)
            clearErrorIfNeeded()
            return fetched
        } catch {
            recordError(error)
            return nil
        }
    }

    nonisolated static func buildActPrompt(for event: MacGatewayCloudDialogueEvent) -> String {
        if let checkPrompt = event.proactive?.checkPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !checkPrompt.isEmpty {
            return checkPrompt
        }
        let rawTitle = event.proactive?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : IOSAppLocalization.string("主动提醒", defaultValue: "主动提醒")
        return "关于这条主动提醒「\(title)」，请帮我处理：\n\n" + String(event.text.prefix(600))
    }

    enum ActResult {
        case sendFailed
        case submitted
        case submittedWithFeedbackError(String)
    }

    func act(on event: MacGatewayCloudDialogueEvent) async -> Bool {
        if case .sendFailed = await submitAct(on: event) { return false }
        return true
    }

    func submitAct(on event: MacGatewayCloudDialogueEvent) async -> ActResult {
        guard let signalId = event.proactiveSignalId else {
            recordError(MacGatewayError.invalidResponse)
            return .sendFailed
        }
        guard let client = requireClient() else { return .sendFailed }
        switch await sendCloudMessageHandler(Self.buildActPrompt(for: event)) {
        case .failure(let error):
            recordError(error)
            return .sendFailed
        case .success:
            // The dialogue already accepted the message. Retrying feedback must never submit it again.
            do {
                _ = try await client.sendProactiveFeedback(signalId: signalId, action: .replied)
                clearErrorIfNeeded()
                return .submitted
            } catch {
                recordError(error)
                return .submittedWithFeedbackError(error.localizedDescription)
            }
        }
    }

    func setMonitorEnabled(id: String, enabled: Bool) async {
        guard let client = requireClient() else { return }
        do {
            let updated = try await client.setProactiveMonitorEnabled(id: id, enabled: enabled)
            if var current = summary {
                if let idx = current.monitors.firstIndex(where: { $0.id == updated.id }) {
                    current.monitors[idx] = updated
                } else {
                    current.monitors.append(updated)
                }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func deleteMonitor(id: String) async {
        guard let client = requireClient() else { return }
        do {
            try await client.deleteProactiveMonitor(id: id)
            if var current = summary {
                current.monitors.removeAll { $0.id == id }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func setMonitorDeliveryMode(id: String, mode: String) async {
        guard MacGatewayClient.isValidProactiveMonitorDeliveryMode(mode) else {
            let message = IOSAppLocalization.string(
                "不支持的投递方式，仅支持即时推送或并入晨报",
                defaultValue: "不支持的投递方式，仅支持即时推送或并入晨报"
            )
            if lastError != message { lastError = message }
            return
        }
        guard let client = requireClient() else { return }
        do {
            let updated = try await client.setProactiveMonitorDeliveryMode(id: id, deliveryMode: mode)
            if var current = summary {
                if let idx = current.monitors.firstIndex(where: { $0.id == updated.id }) {
                    current.monitors[idx] = updated
                } else {
                    current.monitors.append(updated)
                }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    nonisolated static func buildGitHubReleaseFeedURL(from repoSlug: String) -> URL? {
        MacGatewayClient.buildGitHubReleaseFeedURL(from: repoSlug)
    }

    @discardableResult
    func addGitHubReleaseMonitor(repoSlug: String, deliveryMode: String = "digest") async -> Bool {
        let trimmedSlug = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let feedURL = Self.buildGitHubReleaseFeedURL(from: trimmedSlug) else {
            let message = IOSAppLocalization.string(
                "仓库格式无效，请输入 owner/repo（例如 apple/swift）",
                defaultValue: "仓库格式无效，请输入 owner/repo（例如 apple/swift）"
            )
            if lastError != message { lastError = message }
            return false
        }
        guard MacGatewayClient.isValidProactiveMonitorDeliveryMode(deliveryMode) else {
            let message = IOSAppLocalization.string(
                "不支持的投递方式，仅支持即时推送或并入晨报",
                defaultValue: "不支持的投递方式，仅支持即时推送或并入晨报"
            )
            if lastError != message { lastError = message }
            return false
        }
        guard let client = requireClient() else { return false }
        do {
            let created = try await client.createProactiveMonitor(
                name: "\(trimmedSlug) Releases",
                url: feedURL.absoluteString,
                deliveryMode: deliveryMode
            )
            if var current = summary {
                if let idx = current.monitors.firstIndex(where: { $0.id == created.id }) {
                    current.monitors[idx] = created
                } else {
                    current.monitors.append(created)
                }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
            if summary == nil { await refreshSummary() }
            return true
        } catch {
            recordError(error)
            return false
        }
    }

    func cancelWakeup(id: String) async {
        guard MacGatewayClient.isValidProactiveWakeupId(id) else {
            let message = IOSAppLocalization.string("无效的待提醒标识", defaultValue: "无效的待提醒标识")
            if lastError != message { lastError = message }
            return
        }
        guard let client = requireClient() else { return }
        do {
            try await client.cancelProactiveWakeup(id: id)
            if var current = summary {
                current.wakeups.removeAll { $0.id == id }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func setWebhookEnabled(id: String, enabled: Bool) async {
        guard let client = requireClient() else { return }
        do {
            let updated = try await client.setProactiveWebhookEnabled(id: id, enabled: enabled)
            if var current = summary {
                if let idx = current.webhooks.firstIndex(where: { $0.id == updated.id }) {
                    current.webhooks[idx] = updated
                } else {
                    current.webhooks.append(updated)
                }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func deleteWebhook(id: String) async {
        guard let client = requireClient() else { return }
        do {
            try await client.deleteProactiveWebhook(id: id)
            if var current = summary {
                current.webhooks.removeAll { $0.id == id }
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func updateRestraint(_ patch: CloudProactiveRestraintPatch) async {
        guard let client = requireClient() else { return }
        do {
            let updated = try await client.updateProactiveRestraint(patch)
            if var current = summary {
                current.restraint = updated
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

    func unmute(topicKey: String) async {
        guard let client = requireClient() else { return }
        do {
            let updated = try await client.unmuteProactiveTopic(topicKey)
            if var current = summary {
                current.restraint = updated
                if summary != current { summary = current }
            }
            clearErrorIfNeeded()
        } catch {
            recordError(error)
        }
    }

}

// A legacy cached card can identify itself through its event id even without metadata.
extension MacGatewayCloudDialogueEvent {
    var proactiveSignalId: String? {
        guard kind == .proactiveMessage else { return nil }
        let prefix = "proactive:"
        let idSuffix = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
        if let metadataId = proactive?.signalId {
            guard MacGatewayClient.isValidProactiveSignalId(metadataId),
                  idSuffix == nil || idSuffix == metadataId else { return nil }
            return metadataId
        }
        guard let idSuffix, MacGatewayClient.isValidProactiveSignalId(idSuffix) else { return nil }
        return idSuffix
    }
}
