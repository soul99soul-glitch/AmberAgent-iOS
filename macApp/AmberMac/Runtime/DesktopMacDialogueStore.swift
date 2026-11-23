import CryptoKit
import Foundation
@preconcurrency import GatewayCore

// MARK: - Dialogue Event Contract v1 (Mac Local Executor)

enum DesktopDialogueContract {
    static let schemaVersion: Int = 1
    static let executorKind: String = "mac"
    static let maxTextLength: Int = 24_000
    static let maxRequestIdLength: Int = 128
    static let maxConversationIdLength: Int = 128
    static let maxLimit: Int = 100

    static let legacyVisibleKinds: Set<String> = [
        "user_message", "followup", "stop_requested", "assistant_reply",
        "input_consumed", "input_cancelled", "process_event", "task_result"
    ]
}

struct DesktopDialogueSubmitRequest: Codable, Equatable, Sendable {
    var requestId: String
    var text: String?
    var conversationId: String?
    var executorKind: String?
    var executorId: String?
    var epoch: Int64?
    var parentRunId: String?
    var observedSeq: Int64?
    var ledgerId: String?
}

enum DesktopDialogueReceiptState: String, Codable, Equatable, Sendable {
    case received
    case consumed
    case cancelled
}

struct DesktopDialogueReceipt: Codable, Equatable, Sendable {
    var eventId: String
    var requestId: String
    var topicId: String
    var workItemIds: [String]
    var state: DesktopDialogueReceiptState
    var replayed: Bool
    var soulRevision: Int64
    var conversationId: String?
    var executorKind: String?
    var executorId: String?
    var epoch: Int64?
    var causedByInputId: String?
    var causedByRequestId: String?
    var parentRunId: String?
    var observedSeq: Int64?
    var ledgerId: String?
    var outcomeUnknown: Bool
    var schemaVersion: Int

    init(
        eventId: String,
        requestId: String,
        topicId: String,
        workItemIds: [String],
        state: DesktopDialogueReceiptState,
        replayed: Bool = false,
        soulRevision: Int64 = 0,
        conversationId: String? = nil,
        executorKind: String? = DesktopDialogueContract.executorKind,
        executorId: String? = nil,
        epoch: Int64? = nil,
        causedByInputId: String? = nil,
        causedByRequestId: String? = nil,
        parentRunId: String? = nil,
        observedSeq: Int64? = nil,
        ledgerId: String? = nil,
        outcomeUnknown: Bool = false,
        schemaVersion: Int = DesktopDialogueContract.schemaVersion
    ) {
        self.eventId = eventId
        self.requestId = requestId
        self.topicId = topicId
        self.workItemIds = workItemIds
        self.state = state
        self.replayed = replayed
        self.soulRevision = soulRevision
        self.conversationId = conversationId
        self.executorKind = executorKind
        self.executorId = executorId
        self.epoch = epoch
        self.causedByInputId = causedByInputId
        self.causedByRequestId = causedByRequestId
        self.parentRunId = parentRunId
        self.observedSeq = observedSeq
        self.ledgerId = ledgerId
        self.outcomeUnknown = outcomeUnknown
        self.schemaVersion = schemaVersion
    }
}

struct DesktopDialogueEvent: Codable, Equatable, Sendable {
    var seq: Int64
    var id: String
    var kind: String
    var role: String
    var text: String
    var topicId: String
    var workItemId: String?
    var outcome: String?
    var soulRevision: Int64?
    var conversationId: String?
    var executorKind: String?
    var executorId: String?
    var epoch: Int64?
    var causedByInputId: String?
    var causedByRequestId: String?
    var parentRunId: String?
    var observedSeq: Int64?
    var ledgerId: String?
    var outcomeUnknown: Bool
    var schemaVersion: Int
    var riskLevel: String?
    var targetDevice: String?
    var targetSummary: String?
    var diffPreview: String?
    var requiresLocalApproval: Bool?
    var sourceRefs: [String]?
    var sourcePaths: [String]?

    init(
        seq: Int64 = 0,
        id: String,
        kind: String,
        role: String,
        text: String,
        topicId: String,
        workItemId: String? = nil,
        outcome: String? = nil,
        soulRevision: Int64? = nil,
        conversationId: String? = nil,
        executorKind: String? = DesktopDialogueContract.executorKind,
        executorId: String? = nil,
        epoch: Int64? = nil,
        causedByInputId: String? = nil,
        causedByRequestId: String? = nil,
        parentRunId: String? = nil,
        observedSeq: Int64? = nil,
        ledgerId: String? = nil,
        outcomeUnknown: Bool = false,
        schemaVersion: Int = DesktopDialogueContract.schemaVersion,
        riskLevel: String? = nil,
        targetDevice: String? = nil,
        targetSummary: String? = nil,
        diffPreview: String? = nil,
        requiresLocalApproval: Bool? = nil,
        sourceRefs: [String]? = nil,
        sourcePaths: [String]? = nil
    ) {
        self.seq = seq
        self.id = id
        self.kind = kind
        self.role = role
        self.text = text
        self.topicId = topicId
        self.workItemId = workItemId
        self.outcome = outcome
        self.soulRevision = soulRevision
        self.conversationId = conversationId
        self.executorKind = executorKind
        self.executorId = executorId
        self.epoch = epoch
        self.causedByInputId = causedByInputId
        self.causedByRequestId = causedByRequestId
        self.parentRunId = parentRunId
        self.observedSeq = observedSeq
        self.ledgerId = ledgerId
        self.outcomeUnknown = outcomeUnknown
        self.schemaVersion = schemaVersion
        self.riskLevel = riskLevel
        self.targetDevice = targetDevice
        self.targetSummary = targetSummary
        self.diffPreview = diffPreview
        self.requiresLocalApproval = requiresLocalApproval
        self.sourceRefs = sourceRefs
        self.sourcePaths = sourcePaths
    }
}

struct DesktopDialoguePage: Codable, Equatable, Sendable {
    var items: [DesktopDialogueEvent]
    var nextCursor: Int64
    var soulRevision: Int64
    var schemaVersion: Int

    init(
        items: [DesktopDialogueEvent],
        nextCursor: Int64,
        soulRevision: Int64 = 0,
        schemaVersion: Int = DesktopDialogueContract.schemaVersion
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.soulRevision = soulRevision
        self.schemaVersion = schemaVersion
    }
}

enum DesktopDialogueWorkItemLifecycle: String, Codable, Equatable, Sendable {
    case active
    case stopping
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    var isStoppingOrTerminal: Bool {
        self == .stopping || isTerminal
    }
}

struct DesktopDialogueInputRecord: Codable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var requestId: String
    var kind: String
    var text: String
    var topicId: String
    var workItemId: String?
    var createdWorkItemId: String?
    var conversationId: String?
    var executorKind: String?
    var executorId: String?
    var epoch: Int64?
    var parentRunId: String?
    var observedSeq: Int64?
    var ledgerId: String?
    var fingerprint: String
    var disposition: DesktopDialogueReceiptState
    var closedOnArrival: Bool
}

struct DesktopDialogueWorkItem: Codable, Equatable, Sendable {
    var workItemId: String
    var topicId: String
    var conversationId: String?
    var deviceId: String
    var sourceInputId: String
    var sourceRequestId: String
    var prompt: String
    var lifecycle: DesktopDialogueWorkItemLifecycle
    var maxEpoch: Int64
    var parentRunId: String?
    var observedSeq: Int64?
    var ledgerId: String?
    var localConversationID: UUID?
}

enum DesktopDialogueError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidCursor
    case storageUnavailable
    case taskNotFound
    case receiptNotFound
    case requestIdConflict
    case staleEpoch
    case taskTerminal

    var httpStatus: Int {
        switch self {
        case .storageUnavailable: 503
        case .invalidRequest, .invalidCursor: 400
        case .taskNotFound, .receiptNotFound: 404
        case .requestIdConflict, .staleEpoch, .taskTerminal: 409
        }
    }

    var code: String {
        switch self {
        case .storageUnavailable: "storage_unavailable"
        case .invalidRequest: "invalid_request"
        case .invalidCursor: "invalid_cursor"
        case .taskNotFound: "task_not_found"
        case .receiptNotFound: "receipt_not_found"
        case .requestIdConflict: "request_id_conflict"
        case .staleEpoch: "stale_epoch"
        case .taskTerminal: "task_terminal"
        }
    }
}

// MARK: - Serialized Persistent Coordinator

/// Local Mac coordinator for `/v2/dialogue/*` and `/v2/work-items/{id}/*`.
/// Runs strictly on `@MainActor` so idempotency, epoch checks, terminal protection,
/// event sequencing, and atomic persistence are completely race-free.
@MainActor
final class DesktopMacDialogueCoordinator {
    private struct PersistedState: Codable {
        var nextSeq: Int64 = 1
        var inputs: [DesktopDialogueInputRecord] = []
        var workItems: [String: DesktopDialogueWorkItem] = [:]
        var events: [DesktopDialogueEvent] = []
    }

    let fileURL: URL?
    private(set) var executorId: String
    var soulRevisionProvider: @MainActor () -> Int64

    /// Local execution hooks (wired by `DesktopWorkspace.attachMacDialogue`).
    var onStartWorkItem: (@MainActor (DesktopDialogueWorkItem) -> Void)?
    var onFollowupAccepted: (@MainActor (String) -> Void)?
    var onStopWorkItem: (@MainActor (String) -> Void)?

    private var writerLock: FileHandle?
    private var loadFailed = false
    private var needsFlush = false
    private var state = PersistedState()
    private var inputIndexByDeviceRequest: [String: Int] = [:]
    private var inputIndexById: [String: Int] = [:]
    private var eventIds: Set<String> = []
    private var lateStopCauseIds: Set<String> = []

    init(
        fileURL: URL? = nil,
        executorId: String = "mac-local",
        soulRevisionProvider: @escaping @MainActor () -> Int64 = { 0 }
    ) {
        self.fileURL = fileURL
        self.executorId = executorId.isEmpty ? "mac-local" : executorId
        self.soulRevisionProvider = soulRevisionProvider
        load()
    }

    /// Only the live writer binds the control socket. Another app instance may already own active runs.
    func acquireWriter() throws -> Bool {
        guard let fileURL, writerLock == nil else { return true }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(fileURL.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DesktopDialogueError.storageUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        writerLock = handle
        load()
        recoverInterruptedWorkItems()
        return true
    }

    // MARK: - AmberControl Entry Point

    func handleControl(_ request: AmberControl.Request) -> AmberControl.Response {
        if let gatewayId = request.gatewayId { executorId = gatewayId }
        let legacyClient = request.dialogueVersion != String(DesktopDialogueContract.schemaVersion)
        let deviceId = request.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            try ensureStorageAvailable()
            switch request.action {
            case .dialogueMessage:
                guard !deviceId.isEmpty else { return .failure(400, DesktopDialogueError.invalidRequest.code) }
                let body = try decodeSubmitRequest(request.rawBody)
                let result = try submit(
                    deviceId: deviceId,
                    requestId: body.requestId,
                    text: body.text ?? "",
                    kind: "message",
                    workItemId: nil,
                    conversationId: body.conversationId,
                    epoch: body.epoch,
                    parentRunId: body.parentRunId,
                    observedSeq: body.observedSeq,
                    ledgerId: body.ledgerId,
                    legacyClient: legacyClient
                )
                return try encodeRawResponse(status: result.status, payload: result.receipt)

            case .dialogueFollowup:
                guard !deviceId.isEmpty else { return .failure(400, DesktopDialogueError.invalidRequest.code) }
                let body = try decodeSubmitRequest(request.rawBody)
                let result = try submit(
                    deviceId: deviceId,
                    requestId: body.requestId,
                    text: body.text ?? "",
                    kind: "followup",
                    workItemId: request.workItemId,
                    conversationId: body.conversationId,
                    epoch: body.epoch,
                    parentRunId: body.parentRunId,
                    observedSeq: body.observedSeq,
                    ledgerId: body.ledgerId,
                    legacyClient: legacyClient
                )
                return try encodeRawResponse(status: result.status, payload: result.receipt)

            case .dialogueStop:
                guard !deviceId.isEmpty else { return .failure(400, DesktopDialogueError.invalidRequest.code) }
                let body = try decodeSubmitRequest(request.rawBody)
                let result = try submit(
                    deviceId: deviceId,
                    requestId: body.requestId,
                    text: body.text ?? "",
                    kind: "stop",
                    workItemId: request.workItemId,
                    conversationId: body.conversationId,
                    epoch: body.epoch,
                    parentRunId: body.parentRunId,
                    observedSeq: body.observedSeq,
                    ledgerId: body.ledgerId,
                    legacyClient: legacyClient
                )
                return try encodeRawResponse(status: result.status, payload: result.receipt)

            case .dialogueReceipt:
                guard !deviceId.isEmpty, let requestId = request.requestId, !requestId.isEmpty else {
                    return .failure(404, DesktopDialogueError.receiptNotFound.code)
                }
                guard let found = receipt(deviceId: deviceId, requestId: requestId, legacyClient: legacyClient) else {
                    return .failure(404, DesktopDialogueError.receiptNotFound.code)
                }
                return try encodeRawResponse(status: 200, payload: found)

            case .dialogueEvents:
                let after = request.after ?? 0
                let limit = request.limit ?? DesktopDialogueContract.maxLimit
                let eventsPage = try page(after: after, limit: limit, legacyClient: legacyClient)
                return try encodeRawResponse(status: 200, payload: eventsPage)

            default:
                return .failure(400, DesktopDialogueError.invalidRequest.code)
            }
        } catch let error as DesktopDialogueError {
            return .failure(error.httpStatus, error.code)
        } catch {
            return .failure(500, "internal_error")
        }
    }

    // MARK: - Core Contract Operations

    func submit(
        deviceId: String,
        requestId: String,
        text: String,
        kind: String,
        workItemId: String? = nil,
        conversationId: String? = nil,
        epoch: Int64? = nil,
        parentRunId: String? = nil,
        observedSeq: Int64? = nil,
        ledgerId: String? = nil,
        legacyClient: Bool = false
    ) throws -> (status: Int, receipt: DesktopDialogueReceipt) {
        try ensureStorageAvailable()
        guard Self.isValidRequestId(requestId) else { throw DesktopDialogueError.invalidRequest }
        guard kind == "message" || kind == "followup" || kind == "stop" else { throw DesktopDialogueError.invalidRequest }
        if kind != "message", (workItemId ?? "").isEmpty { throw DesktopDialogueError.invalidRequest }
        if kind != "stop" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, text.utf16.count <= DesktopDialogueContract.maxTextLength else {
                throw DesktopDialogueError.invalidRequest
            }
        }
        if let conversationId {
            let trimmed = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, conversationId.utf16.count <= DesktopDialogueContract.maxConversationIdLength else {
                throw DesktopDialogueError.invalidRequest
            }
        }

        let fp = Self.fingerprint(kind: kind, text: text, target: workItemId, conversationId: conversationId, epoch: epoch)
        let dedupeKey = Self.dedupeKey(deviceId: deviceId, requestId: requestId)

        // 1. Idempotency check by (deviceId, requestId)
        if let existingIndex = inputIndexByDeviceRequest[dedupeKey] {
            let existing = state.inputs[existingIndex]
            let owner = conversationId ?? workItemId.flatMap { state.workItems[$0]?.conversationId }
            // Legacy fingerprints delimit fields with NUL. Verify the field boundary for text containing it.
            let containsDelimiter = text.utf8.contains(0) || existing.text.utf8.contains(0)
            if existing.fingerprint != fp || existing.conversationId != owner ||
                (containsDelimiter && existing.text != Self.redact(text)) {
                throw DesktopDialogueError.requestIdConflict
            }
            if legacyClient && isRejectedForLegacy(existing) {
                throw DesktopDialogueError.taskTerminal
            }
            let r = makeReceipt(for: existing, replayed: true)
            return (200, r)
        }

        // 2. Target work item existence & epoch check
        var existingWorkItem: DesktopDialogueWorkItem?
        if let workItemId {
            guard let found = state.workItems[workItemId] else {
                throw DesktopDialogueError.taskNotFound
            }
            if let epoch, epoch < found.maxEpoch {
                throw DesktopDialogueError.staleEpoch
            }
            existingWorkItem = found
        }

        // 3. Lifecycle transition & arrival disposition
        let lifecycle = existingWorkItem?.lifecycle
        let cancelledFollowup = (kind == "followup" && lifecycle?.isStoppingOrTerminal == true)
        let terminalStop = (kind == "stop" && lifecycle?.isTerminal == true)
        let lateStop = (kind == "stop" && lifecycle == .completed)
        let closedOnArrival = cancelledFollowup || terminalStop
        let disposition: DesktopDialogueReceiptState
        if cancelledFollowup || lateStop {
            disposition = .cancelled
        } else if terminalStop {
            // Stopping an already cancelled or failed task is a handled no-op.
            disposition = .consumed
        } else {
            disposition = .received
        }

        let inputId = UUID().uuidString.lowercased()
        let safeText = Self.redact(text)
        let topicId = existingWorkItem?.topicId ?? UUID().uuidString.lowercased()
        let resolvedConversationId = conversationId ?? existingWorkItem?.conversationId
        let resolvedEpoch = epoch ?? existingWorkItem?.maxEpoch ?? 1

        let previous = state
        var createdWorkItem: DesktopDialogueWorkItem?
        if kind == "message" {
            let newWorkItemId = "work:mac-\(UUID().uuidString.lowercased())"
            let item = DesktopDialogueWorkItem(
                workItemId: newWorkItemId,
                topicId: topicId,
                conversationId: resolvedConversationId,
                deviceId: deviceId,
                sourceInputId: inputId,
                sourceRequestId: requestId,
                prompt: safeText,
                lifecycle: .active,
                maxEpoch: resolvedEpoch,
                parentRunId: parentRunId,
                observedSeq: observedSeq,
                ledgerId: ledgerId,
                localConversationID: nil
            )
            state.workItems[newWorkItemId] = item
            createdWorkItem = item
        } else if var target = existingWorkItem {
            if let epoch, epoch > target.maxEpoch {
                target.maxEpoch = epoch
            }
            if kind == "stop" && !terminalStop {
                target.lifecycle = .stopping
            }
            state.workItems[target.workItemId] = target
        }

        let inputRecord = DesktopDialogueInputRecord(
            id: inputId,
            deviceId: deviceId,
            requestId: requestId,
            kind: kind,
            text: safeText,
            topicId: topicId,
            workItemId: workItemId,
            createdWorkItemId: createdWorkItem?.workItemId,
            conversationId: resolvedConversationId,
            executorKind: DesktopDialogueContract.executorKind,
            executorId: executorId,
            epoch: resolvedEpoch,
            parentRunId: parentRunId,
            observedSeq: observedSeq,
            ledgerId: ledgerId,
            fingerprint: fp,
            disposition: disposition,
            closedOnArrival: closedOnArrival
        )
        let insertedIndex = state.inputs.count
        state.inputs.append(inputRecord)
        inputIndexByDeviceRequest[dedupeKey] = insertedIndex
        inputIndexById[inputId] = insertedIndex

        // 4. Append outward user event
        let userEventKind: String
        switch kind {
        case "message": userEventKind = "user_message"
        case "stop": userEventKind = "stop_requested"
        default: userEventKind = "followup"
        }
        appendEventRaw(
            DesktopDialogueEvent(
                id: inputId,
                kind: userEventKind,
                role: "user",
                text: safeText,
                topicId: topicId,
                workItemId: workItemId,
                conversationId: resolvedConversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: resolvedEpoch,
                causedByRequestId: kind == "followup" ? requestId : nil,
                parentRunId: parentRunId,
                observedSeq: observedSeq,
                ledgerId: ledgerId
            )
        )

        // 5. Append causal audit event for auto-cancelled followup or late stop
        if cancelledFollowup || lateStop {
            appendEventRaw(
                DesktopDialogueEvent(
                    id: lateStop ? "stop_too_late:\(inputId)" : "cancelled:\(inputId)",
                    kind: lateStop ? "stop_too_late" : "input_cancelled",
                    role: "system",
                    text: lateStop ? "任务已完成，停止请求到达过晚" : "任务已停止，这条补充未执行",
                    topicId: topicId,
                    workItemId: workItemId,
                    conversationId: resolvedConversationId,
                    executorKind: DesktopDialogueContract.executorKind,
                    executorId: executorId,
                    epoch: resolvedEpoch,
                    causedByInputId: inputId,
                    causedByRequestId: requestId,
                    parentRunId: parentRunId,
                    observedSeq: observedSeq,
                    ledgerId: ledgerId
                )
            )
        }

        // 6. For an active stop request, mark stop input consumed once accepted and signal cancellation.
        let shouldDispatchStart = (kind == "message" && disposition == .received && createdWorkItem != nil)
        let shouldDispatchFollowup = (kind == "followup" && disposition == .received && workItemId != nil)
        let shouldDispatchStop = (kind == "stop" && disposition == .received && workItemId != nil)
        if shouldDispatchStop {
            state.inputs[insertedIndex].disposition = .consumed
        }

        guard persist() else {
            state = previous
            rebuildIndexes()
            needsFlush = false
            throw DesktopDialogueError.storageUnavailable
        }

        if legacyClient && isRejectedForLegacy(state.inputs[insertedIndex]) {
            throw DesktopDialogueError.taskTerminal
        }

        let finalInput = state.inputs[insertedIndex]
        let receipt = makeReceipt(for: finalInput, replayed: false)
        let status = (kind == "stop" || receipt.replayed || receipt.state == .cancelled) ? 200 : 202

        // Trigger execution hooks after state is durably saved.
        if shouldDispatchStart, let item = createdWorkItem {
            onStartWorkItem?(item)
        } else if shouldDispatchFollowup, let workItemId {
            onFollowupAccepted?(workItemId)
        } else if shouldDispatchStop, let workItemId {
            onStopWorkItem?(workItemId)
        }

        return (status, receipt)
    }

    func receipt(deviceId: String, requestId: String, legacyClient: Bool = false) -> DesktopDialogueReceipt? {
        guard let index = inputIndexByDeviceRequest[Self.dedupeKey(deviceId: deviceId, requestId: requestId)] else {
            return nil
        }
        let input = state.inputs[index]
        if legacyClient && isRejectedForLegacy(input) {
            return nil
        }
        return makeReceipt(for: input, replayed: true)
    }

    func page(after: Int64, limit: Int, legacyClient: Bool = false) throws -> DesktopDialoguePage {
        guard after >= 0, (1...DesktopDialogueContract.maxLimit).contains(limit) else {
            throw DesktopDialogueError.invalidCursor
        }
        var items: [DesktopDialogueEvent] = []
        items.reserveCapacity(min(limit, state.events.count))
        for event in state.events where event.seq > after {
            if legacyClient {
                guard DesktopDialogueContract.legacyVisibleKinds.contains(event.kind) else { continue }
                if event.kind == "stop_requested" {
                    if let idx = inputIndexById[event.id], state.inputs[idx].closedOnArrival {
                        continue
                    }
                    if lateStopCauseIds.contains(event.id) {
                        continue
                    }
                }
            }
            items.append(event)
            if items.count >= limit { break }
        }
        let nextCursor = items.last?.seq ?? after
        return DesktopDialoguePage(
            items: items,
            nextCursor: nextCursor,
            soulRevision: soulRevisionProvider()
        )
    }

    // MARK: - Executor Lifecycle Methods

    func workItem(_ workItemId: String) -> DesktopDialogueWorkItem? {
        state.workItems[workItemId]
    }

    func isStopping(_ workItemId: String) -> Bool {
        state.workItems[workItemId]?.lifecycle == .stopping
    }

    func isStoppingOrTerminal(_ workItemId: String) -> Bool {
        state.workItems[workItemId]?.lifecycle.isStoppingOrTerminal ?? true
    }

    func markRunStarted(
        workItemId: String,
        localConversationID: UUID? = nil,
        statusText: String = "Mac 端已接手任务，正在准备执行…"
    ) -> Bool {
        guard var item = state.workItems[workItemId], item.lifecycle == .active else { return false }
        if let localConversationID {
            item.localConversationID = localConversationID
            state.workItems[workItemId] = item
        }
        if let inputIdx = inputIndexById[item.sourceInputId], state.inputs[inputIdx].disposition == .received {
            state.inputs[inputIdx].disposition = .consumed
        }
        appendEventRaw(
            DesktopDialogueEvent(
                id: "run_started:\(workItemId):\(item.maxEpoch)",
                kind: "run_started",
                role: "system",
                text: "Mac 本地执行器已启动",
                topicId: item.topicId,
                workItemId: workItemId,
                conversationId: item.conversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: item.maxEpoch,
                causedByInputId: item.sourceInputId,
                causedByRequestId: item.sourceRequestId,
                parentRunId: item.parentRunId,
                observedSeq: item.observedSeq,
                ledgerId: item.ledgerId
            )
        )
        let trimmedStatus = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStatus.isEmpty {
            appendEventRaw(
                DesktopDialogueEvent(
                    id: "process:\(workItemId):started",
                    kind: "process_event",
                    role: "system",
                    text: Self.redact(trimmedStatus),
                    topicId: item.topicId,
                    workItemId: workItemId,
                    conversationId: item.conversationId,
                    executorKind: DesktopDialogueContract.executorKind,
                    executorId: executorId,
                    epoch: item.maxEpoch,
                    causedByInputId: item.sourceInputId,
                    causedByRequestId: item.sourceRequestId,
                    parentRunId: item.parentRunId,
                    observedSeq: item.observedSeq,
                    ledgerId: item.ledgerId
                )
            )
        }
        return persist()
    }

    func appendProcessEvent(
        workItemId: String,
        text: String,
        riskLevel: String? = nil,
        targetDevice: String? = nil,
        targetSummary: String? = nil,
        diffPreview: String? = nil,
        requiresLocalApproval: Bool? = nil
    ) {
        guard let item = state.workItems[workItemId], !item.lifecycle.isTerminal else { return }
        let safe = Self.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        appendEventRaw(
            DesktopDialogueEvent(
                id: "process:\(workItemId):\(UUID().uuidString.lowercased())",
                kind: "process_event",
                role: "system",
                text: safe,
                topicId: item.topicId,
                workItemId: workItemId,
                conversationId: item.conversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: item.maxEpoch,
                causedByInputId: item.sourceInputId,
                causedByRequestId: item.sourceRequestId,
                parentRunId: item.parentRunId,
                observedSeq: item.observedSeq,
                ledgerId: item.ledgerId,
                riskLevel: riskLevel,
                targetDevice: targetDevice,
                targetSummary: targetSummary.map(Self.redact),
                diffPreview: diffPreview.map(Self.redact),
                requiresLocalApproval: requiresLocalApproval
            )
        )
        persist()
    }

    func appendAssistantReply(workItemId: String, id: String? = nil, text: String) {
        guard let item = state.workItems[workItemId], !item.lifecycle.isTerminal else { return }
        let safe = Self.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        appendEventRaw(
            DesktopDialogueEvent(
                id: id ?? "reply:\(workItemId):\(UUID().uuidString.lowercased())",
                kind: "assistant_reply",
                role: "assistant",
                text: safe,
                topicId: item.topicId,
                workItemId: workItemId,
                conversationId: item.conversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: item.maxEpoch,
                causedByInputId: item.sourceInputId,
                causedByRequestId: item.sourceRequestId,
                parentRunId: item.parentRunId,
                observedSeq: item.observedSeq,
                ledgerId: item.ledgerId
            )
        )
        persist()
    }

    /// Returns pending follow-up inputs for an active (non-stopping, non-terminal) work item.
    func pendingFollowups(workItemId: String) -> [DesktopDialogueInputRecord] {
        guard let item = state.workItems[workItemId], !item.lifecycle.isStoppingOrTerminal else { return [] }
        return state.inputs.filter {
            $0.kind == "followup" && $0.workItemId == workItemId && $0.disposition == .received
        }
    }

    /// Atomically marks the supplied follow-up inputs as consumed and writes causal `input_consumed` events.
    func consumeFollowups(_ inputs: [DesktopDialogueInputRecord]) -> Bool {
        guard !inputs.isEmpty else { return true }
        let previous = state
        var changed = false
        for input in inputs {
            guard let index = inputIndexById[input.id], state.inputs[index].disposition == .received else { continue }
            state.inputs[index].disposition = .consumed
            changed = true
            let current = state.inputs[index]
            if current.kind == "followup" {
                appendEventRaw(
                    DesktopDialogueEvent(
                        id: "consumed:\(current.id)",
                        kind: "input_consumed",
                        role: "system",
                        text: "补充已被任务消费",
                        topicId: current.topicId,
                        workItemId: current.workItemId,
                        conversationId: current.conversationId,
                        executorKind: DesktopDialogueContract.executorKind,
                        executorId: executorId,
                        epoch: current.epoch,
                        causedByInputId: current.id,
                        causedByRequestId: current.requestId,
                        parentRunId: current.parentRunId,
                        observedSeq: current.observedSeq,
                        ledgerId: current.ledgerId
                    )
                )
            }
        }
        guard !changed || persist() else {
            state = previous
            rebuildIndexes()
            return false
        }
        return true
    }

    /// Atomically settles a work item to a terminal outcome (`completed`, `failed`, or `cancelled`),
    /// preserving any existing terminal state (especially never overwriting `completed` with `cancelled`).
    func settle(
        workItemId: String,
        outcome: String,
        text: String,
        outcomeUnknown: Bool = false,
        sourceRefs: [String]? = nil,
        sourcePaths: [String]? = nil
    ) {
        guard var item = state.workItems[workItemId] else { return }
        let normalizedOutcome = outcome.lowercased()
        let nextLifecycle: DesktopDialogueWorkItemLifecycle
        switch normalizedOutcome {
        case "completed": nextLifecycle = .completed
        case "cancelled": nextLifecycle = .cancelled
        default: nextLifecycle = .failed
        }
        // Terminal states are immutable once settled (completed can never be overwritten).
        if item.lifecycle.isTerminal { return }
        item.lifecycle = nextLifecycle
        state.workItems[workItemId] = item

        // Mark source message consumed if not already.
        if let srcIdx = inputIndexById[item.sourceInputId], state.inputs[srcIdx].disposition == .received {
            state.inputs[srcIdx].disposition = .consumed
        }

        // Any unconsumed follow-ups on a finished/stopped/failed task must be explicitly cancelled (never silently executed).
        for idx in state.inputs.indices {
            let input = state.inputs[idx]
            guard input.workItemId == workItemId, input.kind == "followup", input.disposition == .received else { continue }
            state.inputs[idx].disposition = .cancelled
            appendEventRaw(
                DesktopDialogueEvent(
                    id: "cancelled:\(input.id)",
                    kind: "input_cancelled",
                    role: "system",
                    text: nextLifecycle == .completed ? "任务已完成，这条补充未执行" : "任务已停止，这条补充未执行",
                    topicId: input.topicId,
                    workItemId: workItemId,
                    conversationId: input.conversationId,
                    executorKind: DesktopDialogueContract.executorKind,
                    executorId: executorId,
                    epoch: input.epoch ?? item.maxEpoch,
                    causedByInputId: input.id,
                    causedByRequestId: input.requestId,
                    parentRunId: input.parentRunId,
                    observedSeq: input.observedSeq,
                    ledgerId: input.ledgerId
                )
            )
        }

        let fallbackText: String = switch nextLifecycle {
        case .completed: "任务已完成。"
        case .cancelled: "任务已停止。"
        default: "任务未完成。"
        }
        let safeText = Self.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedText = safeText.isEmpty ? fallbackText : safeText
        let cleanRefs = sourceRefs?.map { Self.redact($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanPaths = sourcePaths?.map { Self.redact($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        appendEventRaw(
            DesktopDialogueEvent(
                id: "result:\(workItemId)",
                kind: "task_result",
                role: "assistant",
                text: resolvedText,
                topicId: item.topicId,
                workItemId: workItemId,
                outcome: nextLifecycle.rawValue,
                soulRevision: soulRevisionProvider(),
                conversationId: item.conversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: item.maxEpoch,
                causedByInputId: item.sourceInputId,
                causedByRequestId: item.sourceRequestId,
                parentRunId: item.parentRunId,
                observedSeq: item.observedSeq,
                ledgerId: item.ledgerId,
                outcomeUnknown: outcomeUnknown,
                sourceRefs: (cleanRefs?.isEmpty == false) ? cleanRefs : nil,
                sourcePaths: (cleanPaths?.isEmpty == false) ? cleanPaths : nil
            )
        )
        appendEventRaw(
            DesktopDialogueEvent(
                id: "run_finished:\(workItemId):\(item.maxEpoch)",
                kind: "run_finished",
                role: "system",
                text: nextLifecycle == .completed ? "Mac 本地执行已完成" : (nextLifecycle == .cancelled ? "Mac 本地执行已停止" : "Mac 本地执行未完成"),
                topicId: item.topicId,
                workItemId: workItemId,
                outcome: nextLifecycle.rawValue,
                soulRevision: soulRevisionProvider(),
                conversationId: item.conversationId,
                executorKind: DesktopDialogueContract.executorKind,
                executorId: executorId,
                epoch: item.maxEpoch,
                causedByInputId: item.sourceInputId,
                causedByRequestId: item.sourceRequestId,
                parentRunId: item.parentRunId,
                observedSeq: item.observedSeq,
                ledgerId: item.ledgerId,
                outcomeUnknown: outcomeUnknown
            )
        )
        persist()
    }

    /// Called once on live app launch: marks any orphaned active/stopping work items from a previous process
    /// so they never stay permanently stuck.
    func recoverInterruptedWorkItems() {
        let orphaned = state.workItems.values.filter { !$0.lifecycle.isTerminal }
        for item in orphaned {
            if item.lifecycle == .stopping {
                settle(workItemId: item.workItemId, outcome: "cancelled", text: "Amber 已重启，停止中的任务已结束。")
            } else {
                settle(
                    workItemId: item.workItemId,
                    outcome: "failed",
                    text: "Amber 已重启，上次 Mac 端本地任务中断，结果待确认。",
                    outcomeUnknown: true
                )
            }
        }
    }

    // MARK: - Private Helpers

    private func decodeSubmitRequest(_ rawBody: String?) throws -> DesktopDialogueSubmitRequest {
        guard let rawBody, let data = rawBody.data(using: .utf8) else {
            throw DesktopDialogueError.invalidRequest
        }
        guard let decoded = try? JSONDecoder().decode(DesktopDialogueSubmitRequest.self, from: data) else {
            throw DesktopDialogueError.invalidRequest
        }
        return decoded
    }

    private func encodeRawResponse<T: Encodable>(status: Int, payload: T) throws -> AmberControl.Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return AmberControl.Response(status: status, rawJSON: String(decoding: data, as: UTF8.self))
    }

    private func isRejectedForLegacy(_ input: DesktopDialogueInputRecord) -> Bool {
        input.closedOnArrival || (input.kind == "stop" && input.disposition == .cancelled)
    }

    private func makeReceipt(for input: DesktopDialogueInputRecord, replayed: Bool) -> DesktopDialogueReceipt {
        let workItemIds: [String]
        if let target = input.workItemId {
            workItemIds = [target]
        } else if let created = input.createdWorkItemId {
            workItemIds = [created]
        } else {
            workItemIds = []
        }
        return DesktopDialogueReceipt(
            eventId: input.id,
            requestId: input.requestId,
            topicId: input.topicId,
            workItemIds: workItemIds,
            state: input.disposition,
            replayed: replayed,
            soulRevision: soulRevisionProvider(),
            conversationId: input.conversationId,
            executorKind: input.executorKind ?? DesktopDialogueContract.executorKind,
            executorId: input.executorId ?? executorId,
            epoch: input.epoch,
            parentRunId: input.parentRunId,
            observedSeq: input.observedSeq,
            ledgerId: input.ledgerId,
            outcomeUnknown: false
        )
    }

    private func appendEventRaw(_ event: DesktopDialogueEvent) {
        guard !eventIds.contains(event.id) else { return }
        var assigned = event
        assigned.seq = state.nextSeq
        state.nextSeq += 1
        state.events.append(assigned)
        eventIds.insert(assigned.id)
        if assigned.kind == "stop_too_late", let cause = assigned.causedByInputId {
            lateStopCauseIds.insert(cause)
        }
    }

    private func load() {
        guard let fileURL else { return }
        loadFailed = false
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: fileURL))
            if let previous = state.inputs.last?.executorId { executorId = previous }
            rebuildIndexes()
        } catch CocoaError.fileReadNoSuchFile {
            // First launch.
        } catch {
            loadFailed = true
        }
    }

    func lastLocalConversationID(for remoteKey: String) -> UUID? {
        for input in state.inputs.reversed() where (input.conversationId ?? input.topicId) == remoteKey {
            if let id = input.createdWorkItemId, let localID = state.workItems[id]?.localConversationID { return localID }
        }
        return nil
    }

    private func rebuildIndexes() {
        inputIndexByDeviceRequest.removeAll(keepingCapacity: true)
        inputIndexById.removeAll(keepingCapacity: true)
        eventIds.removeAll(keepingCapacity: true)
        lateStopCauseIds.removeAll(keepingCapacity: true)
        for (idx, input) in state.inputs.enumerated() {
            inputIndexByDeviceRequest[Self.dedupeKey(deviceId: input.deviceId, requestId: input.requestId)] = idx
            inputIndexById[input.id] = idx
        }
        for event in state.events {
            eventIds.insert(event.id)
            if event.kind == "stop_too_late", let cause = event.causedByInputId {
                lateStopCauseIds.insert(cause)
            }
        }
        if let maxSeq = state.events.map(\.seq).max(), state.nextSeq <= maxSeq {
            state.nextSeq = maxSeq + 1
        }
    }

    private func ensureStorageAvailable() throws {
        guard !loadFailed, !needsFlush || persist() else { throw DesktopDialogueError.storageUnavailable }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let fileURL else { return true }
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DesktopDialogueError.storageUnavailable }
            defer { unlink(temporary.path) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else { throw DesktopDialogueError.storageUnavailable }
            needsFlush = false
            return true
        } catch {
            needsFlush = true
            return false
        }
    }

    static func isValidRequestId(_ value: String) -> Bool {
        let count = value.utf16.count
        guard count >= 1, count <= DesktopDialogueContract.maxRequestIdLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    static func fingerprint(kind: String, text: String, target: String?, conversationId: String?, epoch: Int64?) -> String {
        var raw = "\(kind)\u{0}\(target ?? "")\u{0}\(text)"
        if let conversationId { raw += "\u{0}conv:\(conversationId)" }
        if let epoch { raw += "\u{0}epoch:\(epoch)" }
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func dedupeKey(deviceId: String, requestId: String) -> String {
        "\(deviceId)\u{0}\(requestId)"
    }

    static func redact(_ text: String) -> String {
        var maskedCredential = false
        let redacted = IOSCredentialRedactor.redact(text) { _, _ in maskedCredential = true }
        return DesktopHistoryRedaction.redact(maskedCredential ? redacted : text)
    }
}
