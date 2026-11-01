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
}

struct MacGatewayCloudDialogueEventsPage: Codable, Equatable, Sendable {
    var items: [MacGatewayCloudDialogueEvent]
    var nextCursor: Int64
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

extension MacGatewayStore {
    static let cloudDialogueStateKey = "macGateway.cloudDialogue.v1"

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

    ///Explicitly selects or exits "已配对云主对话" mode without migrating or modifying local conversations.
    func setCloudMainDialogueSelected(_ selected: Bool) {
        guard connection != nil else {
            isCloudMainDialogueSelected = false
            stopCloudDialoguePolling()
            return
        }
        isCloudMainDialogueSelected = selected
        persistCloudDialogueState()
        if selected {
            startCloudDialoguePollingIfNeeded()
        } else {
            stopCloudDialoguePolling()
        }
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
        guard let connection else {
            defaults.removeObject(forKey: Self.cloudDialogueStateKey)
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
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: Self.cloudDialogueStateKey)
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
        selectedCloudDialogueWorkItemId = nil
        busyCloudDialogueRequestIds = []
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
            recordSubmissionError(requestId: requestId, error: error.localizedDescription)
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
            ingestCloudDialogueEventsPage(page, requestedAfter: currentCursor)
            persistCloudDialogueState()
            return .success(page)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            return .failure(error)
        }
    }

    func ingestCloudDialogueEventsPage(_ page: MacGatewayCloudDialogueEventsPage, requestedAfter: Int64) {
        // Empty page must NOT advance cursor.
        guard !page.items.isEmpty else { return }

        var eventsById = Dictionary(uniqueKeysWithValues: cloudDialogueEvents.map { ($0.id, $0) })
        for event in page.items where event.seq > requestedAfter {
            eventsById[event.id] = event
            applyCloudDialogueEvent(event)
        }
        cloudDialogueEvents = eventsById.values.sorted { lhs, rhs in
            lhs.seq != rhs.seq ? lhs.seq < rhs.seq : lhs.id < rhs.id
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

        case .userMessage, .assistantReply:
            break
        }
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
              (isCloudMainDialogueSelected || !activeCloudDialogueWorkItemIds.isEmpty) else { return }
        cloudDialoguePollTask = Task { @MainActor [weak self] in
            defer { self?.cloudDialoguePollTask = nil }
            while !Task.isCancelled {
                guard let self, self.client != nil,
                      (self.isCloudMainDialogueSelected || !self.activeCloudDialogueWorkItemIds.isEmpty) else { break }
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

// MARK: - Explicit Paired Cloud Main Dialogue Sheet View

struct MacGatewayCloudDialogueSheet: View {
    let store: MacGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var activeRequestId = UUID().uuidString.lowercased()
    @State private var lastAttemptedFingerprint: String?
    @State private var errorMessage: String?
    @State private var isSending = false

    private var currentFingerprint: String {
        "\(store.selectedCloudDialogueWorkItemId ?? "main")\u{0000}\(inputText)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.cloudDialogueProgressByWorkItem.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(store.cloudDialogueProgressByWorkItem.values.sorted(by: { $0.lastEventSeq > $1.lastEventSeq }))) { progress in
                            HStack(spacing: 8) {
                                if progress.isLive {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: progress.outcome == .completed ? "checkmark.circle.fill" : "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(progress.outcome == .completed ? AmberTheme.accentGreen : AmberTheme.muted)
                                }
                                Text(verbatim: progress.displaySingleLine)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AmberTheme.foreground)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if progress.isLive {
                                    Button(macGatewayL("补充")) {
                                        store.selectedCloudDialogueWorkItemId = progress.workItemId
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)

                                    Button(macGatewayL("停止"), role: .destructive) {
                                        Task { _ = await store.stopCloudWorkItem(workItemId: progress.workItemId) }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                List {
                    ForEach(store.cloudDialogueVisibleEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: event.role == "user" ? macGatewayL("你") : "Amber Cloud")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                if let workItemId = event.workItemId {
                                    Text(verbatim: workItemId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(AmberTheme.muted2)
                                }
                                Spacer()
                                if event.kind == .followup,
                                   let followup = store.cloudDialogueFollowups.first(where: { $0.eventId == event.id || ($0.workItemId == event.workItemId && $0.text == event.text) }) {
                                    Text(verbatim: followup.state.displayBadgeText)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                                }
                            }
                            Text(verbatim: event.text)
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(store.cloudDialogueFollowups.filter { record in
                        !store.cloudDialogueVisibleEvents.contains(where: { $0.id == record.eventId })
                    }) { followup in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: macGatewayL("任务补充"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                Spacer()
                                Text(verbatim: followup.state.displayBadgeText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                            }
                            Text(verbatim: followup.text)
                                .font(.subheadline)
                                .foregroundStyle(followup.state == .cancelled ? AmberTheme.muted : AmberTheme.foreground)
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let targetWorkItemId = store.selectedCloudDialogueWorkItemId {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AmberTheme.accent)
                            Text(verbatim: "\(macGatewayL("补充运行中任务"))：\(targetWorkItemId)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.selectedCloudDialogueWorkItemId = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        TextField(
                            store.selectedCloudDialogueWorkItemId == nil
                                ? macGatewayL("发送消息给已配对云主对话…")
                                : macGatewayL("向选中任务追加补充说明…"),
                            text: $inputText,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                        Button(macGatewayL("发送")) {
                            sendInput()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(AmberTheme.surface)
            }
            .navigationTitle(Text(verbatim: macGatewayL("已配对云主对话")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("关闭")) {
                        store.setCloudMainDialogueSelected(false)
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.setCloudMainDialogueSelected(true)
            }
        }
        .tint(AmberTheme.accent)
    }

    private func sendInput() {
        if let lastAttemptedFingerprint, lastAttemptedFingerprint != currentFingerprint {
            activeRequestId = UUID().uuidString.lowercased()
        }
        lastAttemptedFingerprint = currentFingerprint
        let reqId = activeRequestId
        let text = inputText
        let targetWorkItemId = store.selectedCloudDialogueWorkItemId
        isSending = true
        errorMessage = nil

        Task { @MainActor in
            let result: Result<MacGatewayCloudDialogueReceipt, Error>
            if let targetWorkItemId {
                result = await store.sendCloudWorkItemInput(workItemId: targetWorkItemId, text: text, requestId: reqId)
            } else {
                result = await store.sendCloudDialogueMessage(text: text, requestId: reqId)
            }
            isSending = false
            switch result {
            case .success:
                inputText = ""
                activeRequestId = UUID().uuidString.lowercased()
                lastAttemptedFingerprint = nil
                _ = await store.pollCloudDialogueEvents()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
