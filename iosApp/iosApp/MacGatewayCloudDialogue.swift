import Foundation
import SwiftUI

// MARK: - Cloud Dialogue v1 Contract (/v2/dialogue/* & /v2/work-items/{id}/inputs|stop)

/// Request body for `POST /v2/dialogue/messages` and `POST /v2/work-items/{id}/inputs`.
/// Strictly encodes only `requestId` and `text`.
struct MacGatewayCloudDialogueInputRequest: Codable, Equatable, Sendable {
    var requestId: String
    var text: String

    init(
        requestId: String = UUID().uuidString.lowercased(),
        text: String
    ) {
        self.requestId = requestId
        self.text = text
    }

    var validationError: String? {
        guard MacGatewayCloudTaskRequest.isValidRequestId(requestId) else {
            return IOSAppLocalization.string("请求 ID 格式无效", defaultValue: "请求 ID 格式无效")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return IOSAppLocalization.string("消息内容不能为空", defaultValue: "消息内容不能为空")
        }
        guard text.utf16.count <= 24_000 else {
            return IOSAppLocalization.string("消息内容不能超过 24000 个字符", defaultValue: "消息内容不能超过 24000 个字符")
        }
        return nil
    }
}

/// Request body for `POST /v2/work-items/{id}/stop`.
/// Strictly encodes only `requestId`.
struct MacGatewayCloudDialogueStopRequest: Codable, Equatable, Sendable {
    var requestId: String

    init(requestId: String = UUID().uuidString.lowercased()) {
        self.requestId = requestId
    }

    var validationError: String? {
        guard MacGatewayCloudTaskRequest.isValidRequestId(requestId) else {
            return IOSAppLocalization.string("请求 ID 格式无效", defaultValue: "请求 ID 格式无效")
        }
        return nil
    }
}

enum MacGatewayCloudDialogueReceiptState: String, Codable, Equatable, CaseIterable, Sendable {
    case received
    case consumed
    case cancelled

    /// Only `.consumed` means the follow-up was actually consumed at a model reasoning boundary.
    /// `.cancelled` (or `.received`) must never be displayed as executed.
    var isExecuted: Bool {
        self == .consumed
    }

    var displayBadgeText: String {
        switch self {
        case .received:
            IOSAppLocalization.string("已送达 · 待推理边界消费", defaultValue: "已送达 · 待推理边界消费")
        case .consumed:
            IOSAppLocalization.string("已消费", defaultValue: "已消费")
        case .cancelled:
            IOSAppLocalization.string("已取消（未执行）", defaultValue: "已取消（未执行）")
        }
    }
}

/// Unified receipt returned by `POST /v2/dialogue/messages`, `POST /v2/work-items/{id}/inputs`,
/// `POST /v2/work-items/{id}/stop`, and `GET /v2/dialogue/receipts/{requestId}`.
struct MacGatewayCloudDialogueReceipt: Codable, Equatable, Sendable {
    var eventId: String
    var requestId: String
    var topicId: String
    var workItemIds: [String]
    var state: MacGatewayCloudDialogueReceiptState
    var replayed: Bool
    var soulRevision: Int64?
}

enum MacGatewayCloudDialogueEventKind: String, Codable, Equatable, CaseIterable, Sendable {
    case userMessage = "user_message"
    case followup = "followup"
    case stopRequested = "stop_requested"
    case assistantReply = "assistant_reply"
    case inputConsumed = "input_consumed"
    case inputCancelled = "input_cancelled"
    case processEvent = "process_event"
    case taskResult = "task_result"
}

enum MacGatewayCloudDialogueOutcome: String, Codable, Equatable, CaseIterable, Sendable {
    case completed
    case blocked
    case failed
    case cancelled

    var isTerminal: Bool { true }

    var displayTitle: String {
        switch self {
        case .completed:
            IOSAppLocalization.string("已完成", defaultValue: "已完成")
        case .blocked:
            IOSAppLocalization.string("受阻", defaultValue: "受阻")
        case .failed:
            IOSAppLocalization.string("执行失败", defaultValue: "执行失败")
        case .cancelled:
            IOSAppLocalization.string("已停止", defaultValue: "已停止")
        }
    }
}

/// Event item returned by `GET /v2/dialogue/events`.
struct MacGatewayCloudDialogueEvent: Codable, Equatable, Identifiable, Sendable {
    var seq: Int64
    var id: String
    var kind: MacGatewayCloudDialogueEventKind
    var role: String
    var text: String
    var topicId: String
    var workItemId: String?
    var outcome: MacGatewayCloudDialogueOutcome?
    var soulRevision: Int64?
}

struct MacGatewayCloudDialogueEventsPage: Codable, Equatable, Sendable {
    var items: [MacGatewayCloudDialogueEvent]
    var nextCursor: Int64
    var soulRevision: Int64?
}

/// Tracks a single in-place dynamic progress line for a cloud `workItemId`.
/// `process_event` updates `statusLine` in place rather than appending multiple tool cards.
struct MacGatewayCloudDialogueWorkItemProgress: Codable, Equatable, Identifiable, Sendable {
    var id: String { workItemId }
    var workItemId: String
    var topicId: String
    var statusLine: String
    var processEventCount: Int
    var lastEventSeq: Int64
    var outcome: MacGatewayCloudDialogueOutcome?

    var isLive: Bool {
        outcome == nil
    }

    var displaySingleLine: String {
        if let outcome {
            let trimmed = statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return outcome.displayTitle
            }
            return "\(outcome.displayTitle) · \(trimmed)"
        }
        return statusLine
    }
}

/// Tracks a follow-up (`POST /v2/work-items/{id}/inputs`) and its truthful consumption state.
struct MacGatewayCloudDialogueFollowupRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { requestId }
    var requestId: String
    var eventId: String?
    var workItemId: String
    var topicId: String?
    var text: String
    var state: MacGatewayCloudDialogueReceiptState
    var lastError: String?

    /// True ONLY when consumed at the worker's next model reasoning boundary.
    /// Unconsumed follow-ups cancelled by stopping the task return `false`.
    var isShownAsExecuted: Bool {
        state == .consumed
    }
}

struct MacGatewayCloudDialoguePersistedSubmission: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case mainMessage
        case followupInput
        case stopWorkItem
    }

    var id: String { requestId }
    var gatewayId: String
    var deviceId: String
    var kind: Kind
    var requestId: String
    var workItemId: String?
    var text: String?
    var receipt: MacGatewayCloudDialogueReceipt?
    var lastError: String?
    var updatedAt: Date
}

struct MacGatewayCloudDialoguePersistedEnvelope: Codable, Equatable, Sendable {
    var gatewayId: String
    var deviceId: String
    var isCloudMainDialogueSelected: Bool
    var cursor: Int64
    var events: [MacGatewayCloudDialogueEvent]
    var receipts: [String: MacGatewayCloudDialogueReceipt]
    var followups: [MacGatewayCloudDialogueFollowupRecord]
    var progressByWorkItem: [String: MacGatewayCloudDialogueWorkItemProgress]
    var submissions: [MacGatewayCloudDialoguePersistedSubmission]
}

/// Transport state of the `/v2/dialogue/*` session channel on the paired gateway.
enum MacGatewayCloudDialogueTransportState: Equatable, Sendable {
    case unknown
    case healthy
    case unsupportedEndpoint
    case failed(String)
}

/// Composite health of the cloud main dialogue session across all four layers:
/// 1) pairing & `/v1/status` reachability
/// 2) `/v2/dialogue/events` session transport & heartbeat
/// 3) `/v2/configuration` Agent & model key readiness
/// 4) pending message enqueue / execution / response status
enum MacGatewayCloudDialogueSessionHealth: Equatable, Sendable {
    case unpaired
    case checking
    case ready(modelSummary: String?)
    case actionRequired(reason: String)
    case unavailable(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .unpaired:
            return IOSAppLocalization.string("尚未配对 Amber · 云端", defaultValue: "尚未配对 Amber · 云端")
        case .checking:
            return IOSAppLocalization.string("正在连接云端对话通道…", defaultValue: "正在连接云端对话通道…")
        case .ready(let modelSummary):
            if let modelSummary, !modelSummary.isEmpty {
                return IOSAppLocalization.string("云端对话就绪 · \(modelSummary)", defaultValue: "云端对话就绪 · \(modelSummary)")
            }
            return IOSAppLocalization.string("云端对话就绪", defaultValue: "云端对话就绪")
        case .actionRequired(let reason):
            return reason
        case .unavailable(let reason):
            return reason
        }
    }
}

// MARK: - Client Endpoints

extension MacGatewayClient {
    private static let dialoguePathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]")
        return allowed
    }()

    private static func encodeDialoguePathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: dialoguePathAllowed) ?? segment
    }

    /// `POST /v2/dialogue/messages`
    func postDialogueMessage(_ request: MacGatewayCloudDialogueInputRequest) async throws -> MacGatewayCloudDialogueReceipt {
        if let validationError = request.validationError {
            throw MacGatewayError.server(validationError)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(request)
        return try decode(await sendData("POST", "/v2/dialogue/messages", bodyData: bodyData, slow: true))
    }

    /// `POST /v2/work-items/{id}/inputs`
    func postWorkItemInput(workItemId: String, _ request: MacGatewayCloudDialogueInputRequest) async throws -> MacGatewayCloudDialogueReceipt {
        if let validationError = request.validationError {
            throw MacGatewayError.server(validationError)
        }
        let encodedId = Self.encodeDialoguePathSegment(workItemId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(request)
        return try decode(await sendData("POST", "/v2/work-items/\(encodedId)/inputs", bodyData: bodyData, slow: true))
    }

    /// `POST /v2/work-items/{id}/stop`
    func stopWorkItem(workItemId: String, requestId: String = UUID().uuidString.lowercased()) async throws -> MacGatewayCloudDialogueReceipt {
        let stopRequest = MacGatewayCloudDialogueStopRequest(requestId: requestId)
        if let validationError = stopRequest.validationError {
            throw MacGatewayError.server(validationError)
        }
        let encodedId = Self.encodeDialoguePathSegment(workItemId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(stopRequest)
        return try decode(await sendData("POST", "/v2/work-items/\(encodedId)/stop", bodyData: bodyData, slow: true))
    }

    /// `GET /v2/dialogue/receipts/{requestId}`
    func dialogueReceipt(requestId: String) async throws -> MacGatewayCloudDialogueReceipt {
        guard MacGatewayCloudTaskRequest.isValidRequestId(requestId) else {
            throw MacGatewayError.server(IOSAppLocalization.string("请求 ID 格式无效", defaultValue: "请求 ID 格式无效"))
        }
        let encodedId = Self.encodeDialoguePathSegment(requestId)
        return try decode(await send("GET", "/v2/dialogue/receipts/\(encodedId)"))
    }

    /// `GET /v2/dialogue/events?after=0&limit=100`
    func dialogueEvents(after: Int64 = 0, limit: Int = 100) async throws -> MacGatewayCloudDialogueEventsPage {
        let clampedAfter = max(0, after)
        let clampedLimit = min(max(limit, 1), 100)
        return try decode(await send("GET", "/v2/dialogue/events?after=\(clampedAfter)&limit=\(clampedLimit)"))
    }
}

// MARK: - Store State, Idempotency & Projection

enum MacGatewayCloudSessionHealth: Equatable {
    case unpaired
    case checking
    case healthy
    case modelUnconfigured(String)
    case degraded(String)
    case offline(String)

    var isOnline: Bool {
        switch self {
        case .healthy, .modelUnconfigured, .degraded:
            return true
        case .unpaired, .checking, .offline:
            return false
        }
    }

    var badgeText: String {
        switch self {
        case .unpaired:
            return IOSAppLocalization.string("未配对", defaultValue: "未配对")
        case .checking:
            return IOSAppLocalization.string("连接中…", defaultValue: "连接中…")
        case .healthy:
            return IOSAppLocalization.string("在线", defaultValue: "在线")
        case .modelUnconfigured:
            return IOSAppLocalization.string("待配置模型", defaultValue: "待配置模型")
        case .degraded:
            return IOSAppLocalization.string("响应异常", defaultValue: "响应异常")
        case .offline:
            return IOSAppLocalization.string("离线", defaultValue: "离线")
        }
    }

    var reasonText: String? {
        switch self {
        case .unpaired, .checking, .healthy:
            return nil
        case .modelUnconfigured(let reason),
             .degraded(let reason),
             .offline(let reason):
            return reason
        }
    }
}

enum MacGatewayCloudDialogueTurnReplyState: Equatable {
    case answered
    case waiting
    case stalled(reason: String)
}

extension MacGatewayStore {
    static let cloudDialogueStateKey = "macGateway.cloudDialogue.v1"

    var cloudSessionHealth: MacGatewayCloudSessionHealth {
        guard connection != nil else { return .unpaired }
        if isReachable == false {
            let reason = cloudDialogueLastError
                ?? (notice?.isError == true ? notice?.text : nil)
                ?? localized("无法连接云端，请确认服务在线且网络可达")
            return .offline(reason)
        }
        guard isReachable == true else {
            return .checking
        }
        if case .unsupportedEndpoint = cloudDialogueTransportState {
            return .degraded(localized("当前已配对节点仅开启状态看板（/v1），未启用云端对话服务（/v2/dialogue）"))
        }
        if let config = cloudConfig, config.model == nil {
            return .modelUnconfigured(localized("云端尚未配置对话模型"))
        }
        if let model = cloudConfig?.model, !model.keyConfigured {
            return .modelUnconfigured(localized("云端模型尚未配置 API Key"))
        }
        if let err = cloudDialogueLastError, !err.isEmpty {
            return .degraded(err)
        }
        return .healthy
    }

    var liveCloudDialogueProgressItems: [MacGatewayCloudDialogueWorkItemProgress] {
        cloudDialogueProgressByWorkItem.values
            .filter(\.isLive)
            .sorted { $0.lastEventSeq > $1.lastEventSeq }
    }

    var unmergedMainSubmissions: [MacGatewayCloudDialoguePersistedSubmission] {
        unmergedCloudMainSubmissions
    }

    func cloudDialogueReplyState(for userEvent: MacGatewayCloudDialogueEvent, now: Date = Date()) -> MacGatewayCloudDialogueTurnReplyState {
        guard userEvent.kind == .userMessage else { return .answered }
        let hasTopicResponse = cloudDialogueEvents.contains { candidate in
            candidate.seq > userEvent.seq &&
            candidate.topicId == userEvent.topicId &&
            candidate.kind != .userMessage
        }
        if hasTopicResponse {
            return .answered
        }
        if let matchedSubmission = cloudDialogueSubmissions.first(where: {
            $0.receipt?.eventId == userEvent.id || $0.receipt?.topicId == userEvent.topicId
        }), !(matchedSubmission.receipt?.workItemIds.isEmpty ?? true) {
            return .answered
        }
        let latestUserMessageId = cloudDialogueVisibleEvents.last(where: { $0.kind == .userMessage })?.id
        guard userEvent.id == latestUserMessageId else {
            return .answered
        }
        if let config = cloudConfig, config.model == nil {
            return .stalled(reason: localized("云端尚未配置对话模型，无法生成回复"))
        }
        if let model = cloudConfig?.model, !model.keyConfigured {
            return .stalled(reason: localized("云端模型尚未配置 API Key，无法生成回复"))
        }
        if isReachable == false {
            return .stalled(reason: cloudDialogueLastError ?? localized("云端当前离线或不可达"))
        }
        if let err = cloudDialogueLastError, !err.isEmpty {
            return .stalled(reason: err)
        }
        let matchedSubmission = cloudDialogueSubmissions.first(where: {
            $0.receipt?.eventId == userEvent.id || $0.receipt?.topicId == userEvent.topicId
        })
        let referenceDate = cloudDialogueFirstSeenAtByEventId[userEvent.id]
            ?? matchedSubmission?.updatedAt
            ?? now
        let elapsed = now.timeIntervalSince(referenceDate)
        if elapsed >= 18 {
            let modelSummary = cloudConfig?.model.map { "\($0.provider) · \($0.modelId)" } ?? localized("云端模型")
            return .stalled(reason: "等待 \(modelSummary) 响应超时，可点击重试或检查云端模型配置")
        }
        return .waiting
    }

    /// Visible timeline rows for the Paired Cloud Main Dialogue:
    /// - `process_event`s never appear as separate rows/cards; they update the single-line progress for their `workItemId` in place.
    /// - `input_consumed` and `input_cancelled` update the corresponding follow-up state in place rather than cluttering the stream.
    var cloudDialogueVisibleEvents: [MacGatewayCloudDialogueEvent] {
        cloudDialogueEvents.filter { event in
            switch event.kind {
            case .userMessage, .followup, .assistantReply, .taskResult, .stopRequested:
                true
            case .processEvent, .inputConsumed, .inputCancelled:
                false
            }
        }
    }

    /// Active (non-terminal) workItemIds discovered from receipts or dialogue events.
    var activeCloudDialogueWorkItemIds: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for submission in cloudDialogueSubmissions {
            for id in submission.receipt?.workItemIds ?? [] where seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        for event in cloudDialogueEvents {
            if let id = event.workItemId, seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered.filter { id in
            if let progress = cloudDialogueProgressByWorkItem[id], progress.outcome != nil {
                return false
            }
            if let task = cloudTasks.first(where: { $0.workItemId == id }), task.isTerminal {
                return false
            }
            return true
        }
    }

    /// Main dialogue messages (`POST /v2/dialogue/messages`) that have been accepted (`.received`)
    /// or failed locally, and whose user event has not yet been merged into `cloudDialogueVisibleEvents`.
    var unmergedCloudMainSubmissions: [MacGatewayCloudDialoguePersistedSubmission] {
        cloudDialogueSubmissions
            .filter { submission in
                guard submission.kind == .mainMessage else { return false }
                if let eventId = submission.receipt?.eventId,
                   cloudDialogueVisibleEvents.contains(where: { $0.id == eventId }) {
                    return false
                }
                return true
            }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    /// True while a submitted main dialogue message is still in `.received` state (or currently sending)
    /// and no assistant reply or terminal task result has arrived after it yet.
    var isAwaitingCloudMainReply: Bool {
        if !busyCloudDialogueRequestIds.isEmpty {
            return true
        }
        let mainSubmissions = cloudDialogueSubmissions.filter { $0.kind == .mainMessage }
        for submission in mainSubmissions {
            let receiptState = submission.receipt.flatMap { cloudDialogueReceipts[$0.requestId]?.state ?? $0.state }
            guard receiptState == .received else { continue }
            if let eventId = submission.receipt?.eventId,
               let userEvent = cloudDialogueEvents.first(where: { $0.id == eventId }) {
                let hasReplyAfter = cloudDialogueEvents.contains { candidate in
                    candidate.seq > userEvent.seq
                        && candidate.topicId == userEvent.topicId
                        && (candidate.kind == .assistantReply || candidate.kind == .taskResult)
                }
                if !hasReplyAfter {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    /// Real cloud dialogue session health derived from pairing, `/v1/status` reachability,
    /// `/v2/dialogue/events` channel status, and `/v2/configuration` model readiness.
    var cloudDialogueSessionHealth: MacGatewayCloudDialogueSessionHealth {
        guard connection != nil else {
            return .unpaired
        }
        if isReachable == false {
            return .unavailable(reason: localized("无法连接已配对节点，请确认网络或守护进程在线"))
        }
        switch cloudDialogueTransportState {
        case .unsupportedEndpoint:
            return .unavailable(
                reason: localized("当前已配对节点仅开启状态看板（/v1），未启用云端对话服务（/v2/dialogue）")
            )
        case .failed(let message):
            return .unavailable(reason: message)
        case .unknown:
            if isReachable == nil {
                return .checking
            }
            return .checking
        case .healthy:
            if let config = cloudConfig {
                guard let model = config.model,
                      !model.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !model.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .actionRequired(reason: localized("云端尚未选择模型，请前往「云端配置」设置"))
                }
                guard model.keyConfigured else {
                    return .actionRequired(reason: localized("云端模型尚未配置 API Key，请前往「云端配置」补齐"))
                }
                return .ready(modelSummary: "\(model.provider) · \(model.modelId)")
            }
            return .ready(modelSummary: nil)
        }
    }

    ///Explicitly selects or exits "已配对云主对话" mode without migrating or modifying local conversations.
    func setCloudMainDialogueSelected(_ selected: Bool) {
        guard connection != nil else {
            isCloudMainDialogueSelected = false
            stopCloudDialoguePolling()
            return
        }
        isCloudMainDialogueSelected = selected
        persistCloudDialogueState()
        // Switching the visible host does not end accepted cloud work or its pending reply.
        // The loop retires itself once the cloud is hidden and all work has settled.
        startCloudDialoguePollingIfNeeded()
    }

    func loadPersistedCloudDialogueState() {
        guard let connection else {
            resetCloudDialogueMemoryState()
            return
        }
        guard let data = defaults.data(forKey: Self.cloudDialogueStateKey),
              let envelope = try? JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: data),
              envelope.gatewayId == connection.gatewayId,
              envelope.deviceId == connection.deviceId else {
            resetCloudDialogueMemoryState()
            defaults.removeObject(forKey: Self.cloudDialogueStateKey)
            return
        }
        isCloudMainDialogueSelected = envelope.isCloudMainDialogueSelected
        cloudDialogueCursor = envelope.cursor
        cloudDialogueEvents = envelope.events
        cloudDialogueReceipts = envelope.receipts
        cloudDialogueFollowups = envelope.followups
        cloudDialogueProgressByWorkItem = envelope.progressByWorkItem
        cloudDialogueSubmissions = envelope.submissions
    }

    func persistCloudDialogueState() {
        let targetDefaults = defaults
        guard let connection else {
            if targetDefaults === UserDefaults.standard {
                nonisolated(unsafe) let sendableDefaults = targetDefaults
                Self.persistenceQueue.async {
                    sendableDefaults.removeObject(forKey: Self.cloudDialogueStateKey)
                }
            } else {
                targetDefaults.removeObject(forKey: Self.cloudDialogueStateKey)
            }
            return
        }
        let envelope = MacGatewayCloudDialoguePersistedEnvelope(
            gatewayId: connection.gatewayId,
            deviceId: connection.deviceId,
            isCloudMainDialogueSelected: isCloudMainDialogueSelected,
            cursor: cloudDialogueCursor,
            events: cloudDialogueEvents,
            receipts: cloudDialogueReceipts,
            followups: cloudDialogueFollowups,
            progressByWorkItem: cloudDialogueProgressByWorkItem,
            submissions: cloudDialogueSubmissions
        )
        if targetDefaults === UserDefaults.standard {
            nonisolated(unsafe) let sendableDefaults = targetDefaults
            Self.persistenceQueue.async {
                if let data = try? JSONEncoder().encode(envelope) {
                    sendableDefaults.set(data, forKey: Self.cloudDialogueStateKey)
                }
            }
        } else if let data = try? JSONEncoder().encode(envelope) {
            targetDefaults.set(data, forKey: Self.cloudDialogueStateKey)
        }
    }

    func resetCloudDialogueMemoryState() {
        stopCloudDialoguePolling()
        isCloudMainDialogueSelected = false
        cloudDialogueCursor = 0
        cloudDialogueEvents = []
        cloudDialogueReceipts = [:]
        cloudDialogueFollowups = []
        cloudDialogueProgressByWorkItem = [:]
        cloudDialogueSubmissions = []
        cloudDialogueFirstSeenAtByEventId = [:]
        selectedCloudDialogueWorkItemId = nil
        busyCloudDialogueRequestIds = []
        cloudDialogueLastError = nil
        cloudDialogueTransportState = .unknown
    }

    /// Sends a main dialogue message (`POST /v2/dialogue/messages`) when in Paired Cloud Main Dialogue mode.
    /// Persists `requestId` and payload before sending so retries reuse the identical `requestId`.
    @discardableResult
    func sendCloudDialogueMessage(
        text: String,
        requestId: String = UUID().uuidString.lowercased()
    ) async -> Result<MacGatewayCloudDialogueReceipt, Error> {
        guard let connection, let client else {
            return .failure(MacGatewayError.server(localized("未与云端或 Mac 配对")))
        }
        let existing = cloudDialogueSubmissions.first {
            $0.requestId == requestId && $0.kind == .mainMessage
        }
        let effectiveText = existing?.text ?? text
        let request = MacGatewayCloudDialogueInputRequest(requestId: requestId, text: effectiveText)
        if let validationError = request.validationError {
            return .failure(MacGatewayError.server(validationError))
        }

        upsertSubmission(
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: connection.gatewayId,
                deviceId: connection.deviceId,
                kind: .mainMessage,
                requestId: requestId,
                workItemId: nil,
                text: effectiveText,
                receipt: existing?.receipt,
                lastError: nil,
                updatedAt: Date()
            )
        )

        busyCloudDialogueRequestIds.insert(requestId)
        defer { busyCloudDialogueRequestIds.remove(requestId) }

        do {
            let receipt = try await client.postDialogueMessage(request)
            guard self.client === client else { return .failure(CancellationError()) }
            cloudDialogueTransportState = .healthy
            isReachable = true
            applyReceipt(receipt, kind: .mainMessage, workItemId: receipt.workItemIds.first, text: effectiveText)
            if selectedCloudDialogueWorkItemId == nil, let firstWorkItem = receipt.workItemIds.first {
                selectedCloudDialogueWorkItemId = firstWorkItem
            }
            persistCloudDialogueState()
            startCloudDialoguePollingIfNeeded()
            return .success(receipt)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            updateCloudDialogueTransportState(for: error)
            recordSubmissionError(requestId: requestId, error: cloudDialogueFriendlyErrorMessage(for: error))
            persistCloudDialogueState()
            return .failure(error)
        }
    }

    /// Appends a follow-up input to a specific running cloud task (`POST /v2/work-items/{id}/inputs`).
    /// Starts in `.received` state and only transitions to `.consumed` when consumed at the next model reasoning boundary.
    @discardableResult
    func sendCloudWorkItemInput(
        workItemId: String,
        text: String,
        requestId: String = UUID().uuidString.lowercased()
    ) async -> Result<MacGatewayCloudDialogueReceipt, Error> {
        guard let connection, let client else {
            return .failure(MacGatewayError.server(localized("未与云端或 Mac 配对")))
        }
        let existing = cloudDialogueSubmissions.first {
            $0.requestId == requestId && $0.kind == .followupInput
        }
        let effectiveWorkItemId = existing?.workItemId ?? workItemId
        let effectiveText = existing?.text ?? text
        let request = MacGatewayCloudDialogueInputRequest(requestId: requestId, text: effectiveText)
        if let validationError = request.validationError {
            return .failure(MacGatewayError.server(validationError))
        }

        upsertSubmission(
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: connection.gatewayId,
                deviceId: connection.deviceId,
                kind: .followupInput,
                requestId: requestId,
                workItemId: effectiveWorkItemId,
                text: effectiveText,
                receipt: existing?.receipt,
                lastError: nil,
                updatedAt: Date()
            )
        )
        upsertFollowupRecord(
            requestId: requestId,
            eventId: existing?.receipt?.eventId,
            workItemId: effectiveWorkItemId,
            topicId: existing?.receipt?.topicId,
            text: effectiveText,
            state: existing?.receipt?.state ?? .received,
            lastError: nil
        )
        persistCloudDialogueState()

        busyCloudDialogueRequestIds.insert(requestId)
        defer { busyCloudDialogueRequestIds.remove(requestId) }

        do {
            let receipt = try await client.postWorkItemInput(workItemId: effectiveWorkItemId, request)
            guard self.client === client else { return .failure(CancellationError()) }
            applyReceipt(receipt, kind: .followupInput, workItemId: effectiveWorkItemId, text: effectiveText)
            persistCloudDialogueState()
            startCloudDialoguePollingIfNeeded()
            return .success(receipt)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            recordSubmissionError(requestId: requestId, error: error.localizedDescription)
            if let idx = cloudDialogueFollowups.firstIndex(where: { $0.requestId == requestId }) {
                cloudDialogueFollowups[idx].lastError = error.localizedDescription
            }
            persistCloudDialogueState()
            return .failure(error)
        }
    }

    /// Stops a running cloud task via the independent control path (`POST /v2/work-items/{id}/stop`).
    /// Any unconsumed (`received`) follow-up inputs for `workItemId` are immediately marked `.cancelled` (never shown as executed).
    @discardableResult
    func stopCloudWorkItem(
        workItemId: String,
        requestId: String = UUID().uuidString.lowercased()
    ) async -> Result<MacGatewayCloudDialogueReceipt, Error> {
        guard let connection, let client else {
            return .failure(MacGatewayError.server(localized("未与云端或 Mac 配对")))
        }
        if let validationError = MacGatewayCloudDialogueStopRequest(requestId: requestId).validationError {
            return .failure(MacGatewayError.server(validationError))
        }

        upsertSubmission(
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: connection.gatewayId,
                deviceId: connection.deviceId,
                kind: .stopWorkItem,
                requestId: requestId,
                workItemId: workItemId,
                text: nil,
                receipt: nil,
                lastError: nil,
                updatedAt: Date()
            )
        )
        persistCloudDialogueState()

        busyCloudDialogueRequestIds.insert(requestId)
        defer { busyCloudDialogueRequestIds.remove(requestId) }

        do {
            let receipt = try await client.stopWorkItem(workItemId: workItemId, requestId: requestId)
            guard self.client === client else { return .failure(CancellationError()) }
            applyReceipt(receipt, kind: .stopWorkItem, workItemId: workItemId, text: nil)
            markUnconsumedFollowupsCancelled(forWorkItemId: workItemId)
            if var progress = cloudDialogueProgressByWorkItem[workItemId] {
                progress.outcome = .cancelled
                cloudDialogueProgressByWorkItem[workItemId] = progress
            } else {
                cloudDialogueProgressByWorkItem[workItemId] = MacGatewayCloudDialogueWorkItemProgress(
                    workItemId: workItemId,
                    topicId: receipt.topicId,
                    statusLine: localized("已停止"),
                    processEventCount: 0,
                    lastEventSeq: cloudDialogueCursor,
                    outcome: .cancelled
                )
            }
            if selectedCloudDialogueWorkItemId == workItemId {
                selectedCloudDialogueWorkItemId = nil
            }
            persistCloudDialogueState()
            return .success(receipt)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            recordSubmissionError(requestId: requestId, error: error.localizedDescription)
            persistCloudDialogueState()
            return .failure(error)
        }
    }

    /// Queries the latest receipt (`GET /v2/dialogue/receipts/{requestId}`) and synchronizes follow-up state.
    @discardableResult
    func refreshCloudDialogueReceipt(requestId: String) async -> Result<MacGatewayCloudDialogueReceipt, Error> {
        guard let client else {
            return .failure(MacGatewayError.server(localized("未与云端或 Mac 配对")))
        }
        do {
            let receipt = try await client.dialogueReceipt(requestId: requestId)
            guard self.client === client else { return .failure(CancellationError()) }
            cloudDialogueReceipts[requestId] = receipt
            if let idx = cloudDialogueSubmissions.firstIndex(where: { $0.requestId == requestId }) {
                cloudDialogueSubmissions[idx].receipt = receipt
                cloudDialogueSubmissions[idx].lastError = nil
            }
            if let fIdx = cloudDialogueFollowups.firstIndex(where: { $0.requestId == requestId || $0.eventId == receipt.eventId }) {
                cloudDialogueFollowups[fIdx].eventId = receipt.eventId
                cloudDialogueFollowups[fIdx].topicId = receipt.topicId
                cloudDialogueFollowups[fIdx].state = receipt.state
            }
            persistCloudDialogueState()
            if let rev = receipt.soulRevision, rev > AgentSoulStore.shared.lastSyncedRevision {
                await syncCloudSoulIfNeeded(observedRevision: rev)
            }
            return .success(receipt)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            return .failure(error)
        }
    }

    /// Polls `GET /v2/dialogue/events?after=<cursor>&limit=<limit>`.
    /// Cursor only advances when `page.items` is non-empty.
    @discardableResult
    func pollCloudDialogueEvents(limit: Int = 100) async -> Result<MacGatewayCloudDialogueEventsPage, Error> {
        guard let client else {
            return .failure(MacGatewayError.server(localized("未与云端或 Mac 配对")))
        }
        let currentCursor = cloudDialogueCursor
        do {
            let page = try await client.dialogueEvents(after: currentCursor, limit: limit)
            guard self.client === client else { return .failure(CancellationError()) }
            cloudDialogueTransportState = .healthy
            isReachable = true
            if !page.items.isEmpty {
                ingestCloudDialogueEventsPage(page, requestedAfter: currentCursor)
                persistCloudDialogueState()
            }
            if let rev = page.soulRevision, rev > AgentSoulStore.shared.lastSyncedRevision {
                await syncCloudSoulIfNeeded(observedRevision: rev)
            }
            return .success(page)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            updateCloudDialogueTransportState(for: error)
            return .failure(error)
        }
    }

    func ingestCloudDialogueEventsPage(_ page: MacGatewayCloudDialogueEventsPage, requestedAfter: Int64) {
        // Empty page must NOT advance cursor.
        guard !page.items.isEmpty else { return }

        var eventsById = Dictionary(uniqueKeysWithValues: cloudDialogueEvents.map { ($0.id, $0) })
        let now = Date()
        let newEvents = page.items.filter { $0.seq > requestedAfter }
        for event in newEvents {
            eventsById[event.id] = event
            if cloudDialogueFirstSeenAtByEventId[event.id] == nil {
                cloudDialogueFirstSeenAtByEventId[event.id] = now
            }
        }
        cloudDialogueEvents = eventsById.values.sorted { lhs, rhs in
            lhs.seq != rhs.seq ? lhs.seq < rhs.seq : lhs.id < rhs.id
        }
        for event in newEvents {
            applyCloudDialogueEvent(event)
        }
        let maxSeenSeq = page.items.map(\.seq).max() ?? requestedAfter
        cloudDialogueCursor = max(cloudDialogueCursor, max(page.nextCursor, maxSeenSeq))
    }

    private func applyCloudDialogueEvent(_ event: MacGatewayCloudDialogueEvent) {
        switch event.kind {
        case .processEvent:
            // In-place single-line progress update per workItemId (or topicId fallback).
            let key = event.workItemId ?? "topic:\(event.topicId)"
            var current = cloudDialogueProgressByWorkItem[key] ?? MacGatewayCloudDialogueWorkItemProgress(
                workItemId: key,
                topicId: event.topicId,
                statusLine: event.text,
                processEventCount: 0,
                lastEventSeq: event.seq,
                outcome: nil
            )
            current.statusLine = event.text
            current.processEventCount += 1
            current.lastEventSeq = max(current.lastEventSeq, event.seq)
            if let outcome = event.outcome {
                current.outcome = outcome
            }
            cloudDialogueProgressByWorkItem[key] = current

        case .taskResult:
            let key = event.workItemId ?? "topic:\(event.topicId)"
            var current = cloudDialogueProgressByWorkItem[key] ?? MacGatewayCloudDialogueWorkItemProgress(
                workItemId: key,
                topicId: event.topicId,
                statusLine: event.text,
                processEventCount: 0,
                lastEventSeq: event.seq,
                outcome: event.outcome ?? .completed
            )
            current.lastEventSeq = max(current.lastEventSeq, event.seq)
            current.outcome = event.outcome ?? .completed
            if current.statusLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current.statusLine = event.text
            }
            cloudDialogueProgressByWorkItem[key] = current
            if let workItemId = event.workItemId, current.outcome == .cancelled {
                markUnconsumedFollowupsCancelled(forWorkItemId: workItemId)
            }
            markMainMessageReceiptsConsumed(forTopicId: event.topicId, upToSeq: event.seq)
            syncCloudDialogueSoulIfNeeded(for: event)

        case .stopRequested:
            if let workItemId = event.workItemId {
                markUnconsumedFollowupsCancelled(forWorkItemId: workItemId)
                if var current = cloudDialogueProgressByWorkItem[workItemId] {
                    current.outcome = event.outcome ?? .cancelled
                    current.lastEventSeq = max(current.lastEventSeq, event.seq)
                    cloudDialogueProgressByWorkItem[workItemId] = current
                }
            }

        case .followup:
            if let workItemId = event.workItemId {
                if let idx = cloudDialogueFollowups.firstIndex(where: {
                    $0.eventId == event.id || ($0.eventId == nil && $0.workItemId == workItemId && $0.text == event.text)
                }) {
                    cloudDialogueFollowups[idx].eventId = event.id
                    cloudDialogueFollowups[idx].topicId = event.topicId
                } else {
                    cloudDialogueFollowups.append(
                        MacGatewayCloudDialogueFollowupRecord(
                            requestId: "event:\(event.id)",
                            eventId: event.id,
                            workItemId: workItemId,
                            topicId: event.topicId,
                            text: event.text,
                            state: .received,
                            lastError: nil
                        )
                    )
                }
            }

        case .inputConsumed:
            updateFollowupStateFromEvent(event, newState: .consumed)

        case .inputCancelled:
            updateFollowupStateFromEvent(event, newState: .cancelled)

        case .userMessage:
            break

        case .assistantReply:
            markMainMessageReceiptsConsumed(forTopicId: event.topicId, upToSeq: event.seq)
            syncCloudDialogueSoulIfNeeded(for: event)
        }
    }

    private func markMainMessageReceiptsConsumed(forTopicId topicId: String, upToSeq: Int64) {
        let consumedEventIds = Set(
            cloudDialogueEvents
                .filter { $0.kind == .userMessage && $0.topicId == topicId && $0.seq <= upToSeq }
                .map(\.id)
        )
        for (reqId, var receipt) in cloudDialogueReceipts {
            if receipt.state == .received,
               (receipt.topicId == topicId || consumedEventIds.contains(receipt.eventId)) {
                receipt.state = .consumed
                cloudDialogueReceipts[reqId] = receipt
            }
        }
        for idx in cloudDialogueSubmissions.indices where cloudDialogueSubmissions[idx].kind == .mainMessage {
            if var receipt = cloudDialogueSubmissions[idx].receipt,
               receipt.state == .received,
               (receipt.topicId == topicId || consumedEventIds.contains(receipt.eventId)) {
                receipt.state = .consumed
                cloudDialogueSubmissions[idx].receipt = receipt
            }
        }
    }

    private func updateCloudDialogueTransportState(for error: Error) {
        if case MacGatewayError.unreachable = error {
            isReachable = false
            cloudDialogueTransportState = .failed(error.localizedDescription)
            return
        }
        if case MacGatewayError.certificateMismatch = error {
            isReachable = false
            cloudDialogueTransportState = .failed(error.localizedDescription)
            return
        }
        if case MacGatewayError.server(let message) = error {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "not found" || normalized == "not_found" || normalized.contains("404") {
                cloudDialogueTransportState = .unsupportedEndpoint
                return
            }
        }
        cloudDialogueTransportState = .failed(error.localizedDescription)
    }

    private func cloudDialogueFriendlyErrorMessage(for error: Error) -> String {
        if case MacGatewayError.server(let message) = error {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "not found" || normalized == "not_found" || normalized.contains("404") {
                return localized("当前连接的节点未启用云端对话服务（/v2/dialogue 404）")
            }
        }
        return error.localizedDescription
    }

    private func syncCloudDialogueSoulIfNeeded(for event: MacGatewayCloudDialogueEvent) {
        if let rev = event.soulRevision, rev > AgentSoulStore.shared.lastSyncedRevision, client != nil {
            Task { @MainActor in
                await self.syncCloudSoulIfNeeded(observedRevision: rev, forcePull: true)
            }
            return
        }
        let userEvents = cloudDialogueEvents.filter {
            ($0.kind == .userMessage || $0.kind == .followup) && $0.topicId == event.topicId
        }
        let latestUserText = userEvents.last?.text
            ?? cloudDialogueSubmissions.first(where: { $0.kind == .mainMessage || $0.kind == .followupInput })?.text
            ?? ""
        let recentContext = userEvents.dropLast().suffix(3).map(\.text).joined(separator: "\n")
        _ = AgentSoulCloudBridge.syncFromTurnIfNeeded(
            userText: latestUserText,
            assistantText: event.text,
            recentConversationContext: recentContext,
            store: AgentSoulStore.shared
        )
    }

    private func updateFollowupStateFromEvent(
        _ event: MacGatewayCloudDialogueEvent,
        newState: MacGatewayCloudDialogueReceiptState
    ) {
        var matched = false
        for idx in cloudDialogueFollowups.indices {
            let record = cloudDialogueFollowups[idx]
            let matchesEventId = record.eventId == event.id
            let matchesWorkItemAndText = (event.workItemId != nil && record.workItemId == event.workItemId && record.text == event.text && record.state == .received)
            if matchesEventId || matchesWorkItemAndText {
                cloudDialogueFollowups[idx].state = newState
                matched = true
            }
        }
        if !matched, let workItemId = event.workItemId {
            // If an input_consumed / input_cancelled event references a workItemId with a single received follow-up, update it.
            if let idx = cloudDialogueFollowups.firstIndex(where: { $0.workItemId == workItemId && $0.state == .received }) {
                cloudDialogueFollowups[idx].state = newState
            }
        }
        for (reqId, var receipt) in cloudDialogueReceipts {
            if receipt.eventId == event.id || (event.workItemId != nil && receipt.workItemIds.contains(event.workItemId!) && receipt.state == .received) {
                receipt.state = newState
                cloudDialogueReceipts[reqId] = receipt
            }
        }
    }

    private func markUnconsumedFollowupsCancelled(forWorkItemId workItemId: String) {
        for idx in cloudDialogueFollowups.indices where cloudDialogueFollowups[idx].workItemId == workItemId {
            if cloudDialogueFollowups[idx].state == .received {
                cloudDialogueFollowups[idx].state = .cancelled
            }
        }
        for (reqId, var receipt) in cloudDialogueReceipts {
            if receipt.workItemIds.contains(workItemId), receipt.state == .received {
                receipt.state = .cancelled
                cloudDialogueReceipts[reqId] = receipt
            }
        }
    }

    private func applyReceipt(
        _ receipt: MacGatewayCloudDialogueReceipt,
        kind: MacGatewayCloudDialoguePersistedSubmission.Kind,
        workItemId: String?,
        text: String?
    ) {
        cloudDialogueReceipts[receipt.requestId] = receipt
        if let idx = cloudDialogueSubmissions.firstIndex(where: { $0.requestId == receipt.requestId }) {
            cloudDialogueSubmissions[idx].receipt = receipt
            cloudDialogueSubmissions[idx].lastError = nil
            cloudDialogueSubmissions[idx].updatedAt = Date()
        }
        if kind == .followupInput, let workItemId = workItemId ?? receipt.workItemIds.first {
            upsertFollowupRecord(
                requestId: receipt.requestId,
                eventId: receipt.eventId,
                workItemId: workItemId,
                topicId: receipt.topicId,
                text: text ?? "",
                state: receipt.state,
                lastError: nil
            )
        }
        if let rev = receipt.soulRevision, rev > AgentSoulStore.shared.lastSyncedRevision {
            Task { @MainActor in
                await self.syncCloudSoulIfNeeded(observedRevision: rev)
            }
        }
    }

    private func upsertSubmission(_ submission: MacGatewayCloudDialoguePersistedSubmission) {
        if let idx = cloudDialogueSubmissions.firstIndex(where: { $0.requestId == submission.requestId }) {
            cloudDialogueSubmissions[idx] = submission
        } else {
            cloudDialogueSubmissions.insert(submission, at: 0)
        }
    }

    private func recordSubmissionError(requestId: String, error: String) {
        if let idx = cloudDialogueSubmissions.firstIndex(where: { $0.requestId == requestId }) {
            cloudDialogueSubmissions[idx].lastError = error
            cloudDialogueSubmissions[idx].updatedAt = Date()
        }
    }

    private func upsertFollowupRecord(
        requestId: String,
        eventId: String?,
        workItemId: String,
        topicId: String?,
        text: String,
        state: MacGatewayCloudDialogueReceiptState,
        lastError: String?
    ) {
        if let idx = cloudDialogueFollowups.firstIndex(where: { $0.requestId == requestId }) {
            if let eventId { cloudDialogueFollowups[idx].eventId = eventId }
            if let topicId { cloudDialogueFollowups[idx].topicId = topicId }
            cloudDialogueFollowups[idx].state = state
            cloudDialogueFollowups[idx].lastError = lastError
        } else {
            cloudDialogueFollowups.append(
                MacGatewayCloudDialogueFollowupRecord(
                    requestId: requestId,
                    eventId: eventId,
                    workItemId: workItemId,
                    topicId: topicId,
                    text: text,
                    state: state,
                    lastError: lastError
                )
            )
        }
    }

    func startCloudDialoguePollingIfNeeded() {
        guard cloudDialoguePollTask == nil,
              client != nil,
              (isCloudMainDialogueSelected || !activeCloudDialogueWorkItemIds.isEmpty || isAwaitingCloudMainReply) else { return }
        cloudDialoguePollTask = Task { @MainActor [weak self] in
            defer {
                // stopCloudDialoguePolling already releases a cancelled handle. Its old
                // task may finish after a replacement has started and must not clear it.
                if !Task.isCancelled { self?.cloudDialoguePollTask = nil }
            }
            while !Task.isCancelled {
                guard let self, self.client != nil,
                      (self.isCloudMainDialogueSelected || !self.activeCloudDialogueWorkItemIds.isEmpty || self.isAwaitingCloudMainReply) else { break }
                _ = await self.pollCloudDialogueEvents()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopCloudDialoguePolling() {
        cloudDialoguePollTask?.cancel()
        cloudDialoguePollTask = nil
    }
}
