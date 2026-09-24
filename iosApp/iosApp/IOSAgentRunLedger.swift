import Foundation
import CryptoKit
@preconcurrency import Shared

// MARK: - W1 durable tool-execution ledger ("先记账，后动手")
//
// See docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md §W1 / invariant I-1. Writes
// a Started/Finished pair per tool call to the shared `agent_event` Room table
// BEFORE and AFTER the tool's side effect, so a process death mid-execution
// leaves a durable "we called X and don't know if it finished" trace instead
// of amnesia. This file only writes the ledger; W3 (crash-recovery UX) reads
// it back and decides what to tell the user.

/// How safe a tool call is to blindly retry after its outcome becomes unknown
/// (process died between Started and Finished). Four values only — amber
/// runs one tool at a time per run, so it doesn't need the fuller
/// `resourceKey`/lock model a concurrent executor would.
///
/// - `pure`: no observable side effect and no network egress (local search,
///   catalog listing, asking the user a question). Always safe to retry.
/// - `networkRead`: read-only network call (search_web/scrape_web) — no local
///   write, so replay is safe; but the request itself egresses query/URL/credentials
///   to third parties, so promotion policy must tier it above `pure`.
/// - `idempotent`: has a side effect, but re-running with the same arguments
///   converges to the same state (memory edit/delete by stable id). Safe to retry.
/// - `sideEffect`: re-running could double-apply or double-charge (workspace
///   writes, shell execution, webMount mutation, MCP/council/subagent calls).
///   Never auto-retried; W3 must surface it as "outcome unknown" instead.
public enum IOSToolEffectClass: String, Sendable, Equatable {
    case pure
    case networkRead
    case idempotent
    case sideEffect
}

public enum IOSToolTransactionState: String, Sendable, Equatable {
    case prepared
    case started
    case waitingUser = "waiting_user"
    case finished
    case outcomeUnknown = "outcome_unknown"
    case reconciled
}

public enum IOSToolTransactionPreparation: Sendable, Equatable {
    case ready
    case replay(resultPayload: String)
    case blocked(reason: String)
}

public struct IOSToolTransactionSnapshot: Sendable, Equatable {
    public let runId: String
    public let toolCallId: String
    public let toolName: String
    public let argsDigest: String
    public let effectClass: IOSToolEffectClass
    public let state: IOSToolTransactionState
    public let outcome: String?
    public let resultPayload: String?
}

/// Secret-free logical request identity for one provider round.
/// Raw messages, prompts and credentials stay out of the durable ledger; their
/// canonical bytes are reduced to SHA-256 digests before this value is written.
public struct IOSRunRequestSnapshot: Sendable, Equatable, Codable {
    let roundIndex: Int
    let requestDigest: String
    let messageCount: Int
    let systemPromptDigest: String
    let generationParamsDigest: String
    let toolCatalogDigest: String
    let toolNames: [String]
    let providerId: String
    let modelId: String
    let compactionRefs: [String]

    static func make(
        roundIndex: Int,
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) -> IOSRunRequestSnapshot {
        let bridge = IosRunRequestSnapshotJsonBridge.shared
        let systemMessages = messages.filter { $0.role == MessageRole.system }
        return IOSRunRequestSnapshot(
            roundIndex: roundIndex,
            requestDigest: sha256(bridge.encodeMessages(messages: messages)),
            messageCount: messages.count,
            systemPromptDigest: sha256(bridge.encodeMessages(messages: systemMessages)),
            generationParamsDigest: sha256(bridge.encodeGenerationParams(params: params)),
            toolCatalogDigest: sha256(bridge.encodeToolCatalog(tools: params.tools)),
            toolNames: params.tools.map(\.name).sorted(),
            providerId: providerSetting.id.description(),
            modelId: params.model.modelId,
            compactionRefs: compactHandoffRefs(in: systemMessages)
        )
    }

    func withRoundIndex(_ roundIndex: Int) -> IOSRunRequestSnapshot {
        IOSRunRequestSnapshot(
            roundIndex: roundIndex,
            requestDigest: requestDigest,
            messageCount: messageCount,
            systemPromptDigest: systemPromptDigest,
            generationParamsDigest: generationParamsDigest,
            toolCatalogDigest: toolCatalogDigest,
            toolNames: toolNames,
            providerId: providerId,
            modelId: modelId,
            compactionRefs: compactionRefs
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func compactHandoffRefs(in messages: [UIMessage]) -> [String] {
        let prefix = "[Conversation compact handoff: "
        var refs = Set<String>()
        for text in messages.flatMap(\.parts).compactMap({ ($0 as? UIMessagePart.Text)?.text }) {
            for line in text.split(separator: "\n") {
                guard line.hasPrefix(prefix), line.hasSuffix("]") else { continue }
                let start = line.index(line.startIndex, offsetBy: prefix.count)
                let id = String(line[start..<line.index(before: line.endIndex)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { refs.insert(id) }
            }
        }
        return refs.sorted()
    }
}

/// Testable surface for the ledger. Production uses `IOSAgentRunLedger`
/// (Room-backed); tests substitute a spy that records calls and can force a
/// failure to exercise the fail-closed path without touching the real DB.
///
/// `public` solely because `IOSAgentToolEngine`'s public initializer takes an
/// optional `IOSAgentRunLedgering?` — Swift requires a public API's parameter
/// types to be at least as visible as the API itself, even though every
/// conformer (`IOSAgentRunLedger`, the test spy) lives in this same module.
public protocol IOSAgentRunLedgering: Sendable {
    /// Must succeed before the provider sees this round. Failure prevents the
    /// request, preserving a complete audit trail instead of an untracked call.
    func recordRequestSnapshot(
        runId: String,
        snapshot: IOSRunRequestSnapshot
    ) async -> Bool

    func recordToolCallPrepared(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> IOSToolTransactionPreparation

    @discardableResult
    func recordToolCallStarted(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> Bool

    @discardableResult
    func recordToolCallFinished(
        runId: String,
        toolCallId: String,
        outcome: String
    ) async -> Bool

    /// Evolution contract (§15 Phase 0): finished/terminal tool events may
    /// carry optional artifact identity, a structured outcome and a source
    /// reference. Kept as an OVERLOAD of the original 3-parameter method so
    /// pre-contract call sites compile unchanged; the new keys are OPTIONAL —
    /// rows written without them (and old rows already in the table) still
    /// decode (acceptance 4).
    @discardableResult
    func recordToolCallFinished(
        runId: String,
        toolCallId: String,
        outcome: String,
        artifactId: String?,
        artifactVersion: String?,
        outcomeKind: String?,
        errorCode: String?,
        sourceRef: String?
    ) async -> Bool

    /// Explicit `approval_denied` ledger event (§11.1 evidence source):
    /// a user denied an approval card for this tool call. The event's
    /// `eventId` is the stable evidence ref.
    func recordApprovalDenied(
        runId: String,
        toolCallId: String,
        toolName: String,
        reason: String,
        capabilityId: String?
    ) async

    @discardableResult
    func recordToolCallTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool

    /// Closes an outer tool transaction that is paused at an approval card.
    /// Denial/context loss performs no side effect and therefore must not
    /// fabricate a second Started transition.
    @discardableResult
    func recordWaitingToolApprovalTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool

    func toolTransactions(runId: String) async -> [IOSToolTransactionSnapshot]?

    func transitionToolTransaction(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String?,
        resultPayload: String?
    ) async -> Bool

    func recordToolCallRecoveryTransition(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String
    ) async -> Bool

}

extension IOSAgentRunLedgering {
    func recordRequestSnapshot(
        runId: String,
        snapshot: IOSRunRequestSnapshot
    ) async -> Bool { true }

    func recordToolCallPrepared(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> IOSToolTransactionPreparation {
        .ready
    }

    @discardableResult
    func recordToolCallTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool {
        await recordToolCallFinished(runId: runId, toolCallId: toolCallId, outcome: outcome)
    }

    func recordWaitingToolApprovalTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool {
        await transitionToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            expected: .waitingUser,
            to: .finished,
            outcome: outcome,
            resultPayload: resultPayload
        )
    }

    func toolTransactions(runId: String) async -> [IOSToolTransactionSnapshot]? { nil }

    func transitionToolTransaction(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String?,
        resultPayload: String?
    ) async -> Bool { false }

    func recordToolCallRecoveryTransition(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String
    ) async -> Bool {
        await transitionToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            expected: expected,
            to: state,
            outcome: outcome,
            resultPayload: nil
        )
    }
}

/// Room-backed production ledger. Room allocates `seq` and copies run identity
/// in one SQL insert, so foreground/background writers cannot drift or collide.
actor IOSAgentRunLedger: IOSAgentRunLedgering {
    /// Ledger event type for an explicitly denied approval card (§11.1). Its
    /// `eventId` is the stable evidence ref for the denial.
    static let approvalDeniedEventType = "tool_approval_denied"
    static let toolStartedEventType = "tool_started"
    static let toolFinishedEventType = "tool_finished"
    static let toolPreparedEventType = "tool_prepared"
    static let toolOutcomeUnknownEventType = "tool_outcome_unknown"
    static let toolReconciledEventType = "tool_reconciled"
    static let requestSnapshotEventType = "request_snapshot"

    private let dao: AgentRuntimeDao
    private let store: RoomAgentEventStore

    init(dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()) {
        self.dao = dao
        self.store = RoomAgentEventStore(dao: dao)
    }

    func recordRequestSnapshot(
        runId: String,
        snapshot: IOSRunRequestSnapshot
    ) async -> Bool {
        guard let roundIndex = await nextRequestSnapshotIndex(runId: runId) else { return false }
        let persistedSnapshot = snapshot.withRoundIndex(roundIndex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(persistedSnapshot),
              let payload = String(data: data, encoding: .utf8) else { return false }
        return await append(
            runId: runId,
            event: AgentRunEvent(
                eventId: UUID().uuidString,
                type: Self.requestSnapshotEventType,
                payloadType: Self.requestSnapshotEventType,
                payload: payload,
                payloadSchemaVersion: 1,
                isFinal: false,
                ts: Self.nowMillis(),
                turnId: String(roundIndex),
                stepId: String(roundIndex),
                toolCallId: nil
            )
        )
    }

    private func nextRequestSnapshotIndex(runId: String) async -> Int? {
        await withCheckedContinuation { continuation in
            dao.listEventsForRun(id: runId) { rows, error in
                guard error == nil, let rows else {
                    continuation.resume(returning: nil)
                    return
                }
                let existingCount = rows.lazy.filter { $0.type == Self.requestSnapshotEventType }.count
                continuation.resume(returning: existingCount + 1)
            }
        }
    }

    func recordToolCallPrepared(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> IOSToolTransactionPreparation {
        let transaction = AgentToolTransactionEntity(
            runId: runId,
            toolCallId: toolCallId,
            toolName: toolName,
            argsDigest: argsDigest,
            effectClass: effectClass.rawValue,
            state: IOSToolTransactionState.prepared.rawValue,
            outcome: nil,
            resultPayload: nil,
            updatedAt: Self.nowMillis()
        )
        let inserted = await withCheckedContinuation { continuation in
            dao.insertToolTransactionIfAbsent(transaction: transaction) { rowId, error in
                continuation.resume(returning: error == nil && (rowId?.int64Value ?? -1) != -1)
            }
        }
        if inserted {
            let ok = await append(
                runId: runId,
                event: makeToolEvent(
                    type: Self.toolPreparedEventType,
                    toolCallId: toolCallId,
                    fields: [
                        "toolCallId": toolCallId,
                        "toolName": toolName,
                        "argsDigest": argsDigest,
                        "effectClass": effectClass.rawValue,
                    ]
                )
            )
            if !ok {
                _ = await transitionToolTransaction(
                    runId: runId,
                    toolCallId: toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "not_executed_prepared_event_failed",
                    resultPayload: nil
                )
            }
            return ok ? .ready : .blocked(reason: "could not durably append tool_prepared")
        }

        guard let existing = await toolTransaction(runId: runId, toolCallId: toolCallId) else {
            return .blocked(reason: "tool transaction claim failed")
        }
        guard existing.toolName == toolName, existing.argsDigest == argsDigest else {
            return .blocked(reason: "tool call identity changed for an existing transaction")
        }
        if existing.state == .finished, let payload = existing.resultPayload {
            return .replay(resultPayload: payload)
        }
        return .blocked(reason: "tool transaction is already \(existing.state.rawValue)")
    }

    @discardableResult
    func recordToolCallStarted(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> Bool {
        if await toolTransaction(runId: runId, toolCallId: toolCallId) == nil {
            guard await recordToolCallPrepared(
                runId: runId,
                toolCallId: toolCallId,
                toolName: toolName,
                argsDigest: argsDigest,
                effectClass: effectClass
            ) == .ready else { return false }
        }
        let current = await toolTransaction(runId: runId, toolCallId: toolCallId)
        guard let expected = current?.state,
              expected == .prepared || expected == .waitingUser,
              await transitionToolTransaction(
                runId: runId,
                toolCallId: toolCallId,
                expected: expected,
                to: .started,
                outcome: nil,
                resultPayload: nil
              ) else { return false }
        let payload = Self.jsonPayload([
            "toolCallId": toolCallId,
            "toolName": toolName,
            "argsDigest": argsDigest,
            "effectClass": effectClass.rawValue,
        ])
        let ok = await append(
            runId: runId,
            event: AgentRunEvent(
                eventId: UUID().uuidString,
                type: Self.toolStartedEventType,
                payloadType: Self.toolStartedEventType,
                payload: payload,
                payloadSchemaVersion: 1,
                isFinal: false,
                ts: Self.nowMillis(),
                turnId: nil,
                stepId: nil,
                toolCallId: toolCallId
            )
        )
        if !ok {
            _ = await transitionToolTransaction(
                runId: runId,
                toolCallId: toolCallId,
                expected: .started,
                to: .reconciled,
                outcome: "not_executed_started_event_failed",
                resultPayload: nil
            )
        }
        return ok
    }

    /// Pre-contract overload: delegates to the full evolution-contract form
    /// with every optional key nil, so old callers write exactly the payload
    /// they always did (`{"toolCallId":…,"outcome":…}`).
    @discardableResult
    func recordToolCallFinished(
        runId: String,
        toolCallId: String,
        outcome: String
    ) async -> Bool {
        await recordToolCallFinished(
            runId: runId,
            toolCallId: toolCallId,
            outcome: outcome,
            artifactId: nil,
            artifactVersion: nil,
            outcomeKind: nil,
            errorCode: nil,
            sourceRef: nil
        )
    }

    @discardableResult
    func recordToolCallFinished(
        runId: String,
        toolCallId: String,
        outcome: String,
        artifactId: String? = nil,
        artifactVersion: String? = nil,
        outcomeKind: String? = nil,
        errorCode: String? = nil,
        sourceRef: String? = nil
    ) async -> Bool {
        var fields: [String: String] = [
            "toolCallId": toolCallId,
            "outcome": outcome,
        ]
        // Evolution contract keys are all optional; absent keys are omitted so
        // old rows (and old readers like `IOSToolCallLedgerRow.decode`) keep
        // decoding both old and new payloads.
        if let artifactId { fields["artifactId"] = artifactId }
        if let artifactVersion { fields["artifactVersion"] = artifactVersion }
        if let outcomeKind { fields["outcomeKind"] = outcomeKind }
        if let errorCode { fields["errorCode"] = errorCode }
        if let sourceRef { fields["sourceRef"] = sourceRef }
        return await finishToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            outcome: outcome,
            resultPayload: nil,
            fields: fields
        )
    }

    @discardableResult
    func recordToolCallTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool {
        await finishToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            outcome: outcome,
            resultPayload: resultPayload,
            fields: ["toolCallId": toolCallId, "outcome": outcome]
        )
    }


    @discardableResult
    func recordWaitingToolApprovalTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?
    ) async -> Bool {
        let transitioned = await transitionToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            expected: .waitingUser,
            to: .finished,
            outcome: outcome,
            resultPayload: resultPayload
        )
        guard transitioned else {
            if let current = await toolTransaction(runId: runId, toolCallId: toolCallId),
               current.state == .finished,
               current.outcome == outcome,
               current.resultPayload == resultPayload {
                return true
            }
            return false
        }
        let ok = await append(
            runId: runId,
            event: makeToolEvent(
                type: Self.toolFinishedEventType,
                toolCallId: toolCallId,
                fields: ["toolCallId": toolCallId, "outcome": outcome]
            )
        )
        if !ok {
            print("[AmberChat] waiting approval terminal event write failed run=\(runId) toolCallId=\(toolCallId)")
        }
        return true
    }

    private func finishToolTransaction(
        runId: String,
        toolCallId: String,
        outcome: String,
        resultPayload: String?,
        fields: [String: String]
    ) async -> Bool {
        if await toolTransaction(runId: runId, toolCallId: toolCallId) == nil {
            let ok = await append(
                runId: runId,
                event: makeToolEvent(type: Self.toolFinishedEventType, toolCallId: toolCallId, fields: fields)
            )
            if !ok {
                print("[AmberChat] non-executed tool terminal ledger write failed run=\(runId) toolCallId=\(toolCallId) outcome=\(outcome)")
            }
            return ok
        }
        let nextState: IOSToolTransactionState = outcome == "paused_for_approval" ? .waitingUser : .finished
        let transitioned = await transitionToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            expected: .started,
            to: nextState,
            outcome: outcome,
            resultPayload: resultPayload
        )
        guard transitioned else {
            if let current = await toolTransaction(runId: runId, toolCallId: toolCallId),
               current.state == nextState,
               current.outcome == outcome,
               current.resultPayload == resultPayload {
                return true
            }
            print("[AmberChat] tool transaction finish CAS failed run=\(runId) toolCallId=\(toolCallId) outcome=\(outcome)")
            return false
        }
        let payload = Self.jsonPayload(fields)
        // The attempt either produced an outcome or was definitively stopped
        // before its side effect began. A failed write here can't change that
        // fact, so unlike Started, we only log and move on.
        let ok = await append(
            runId: runId,
            event: AgentRunEvent(
                eventId: UUID().uuidString,
                type: Self.toolFinishedEventType,
                payloadType: Self.toolFinishedEventType,
                payload: payload,
                payloadSchemaVersion: 1,
                isFinal: false,
                ts: Self.nowMillis(),
                turnId: nil,
                stepId: nil,
                toolCallId: toolCallId
            )
        )
        if !ok {
            print("[AmberChat] tool_call_finished ledger write failed run=\(runId) toolCallId=\(toolCallId) outcome=\(outcome)")
        }
        return true
    }

    func toolTransactions(runId: String) async -> [IOSToolTransactionSnapshot]? {
        await withCheckedContinuation { continuation in
            dao.listToolTransactionsForRun(runId: runId) { rows, error in
                guard error == nil, let rows else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: rows.compactMap(Self.snapshot))
            }
        }
    }

    func transitionToolTransaction(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String?,
        resultPayload: String?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            dao.transitionToolTransaction(
                runId: runId,
                toolCallId: toolCallId,
                expectedState: expected.rawValue,
                state: state.rawValue,
                outcome: outcome,
                resultPayload: resultPayload,
                updatedAt: Self.nowMillis()
            ) { count, error in
                continuation.resume(returning: error == nil && (count?.intValue ?? 0) == 1)
            }
        }
    }

    func recordToolCallRecoveryTransition(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String
    ) async -> Bool {
        guard state == .outcomeUnknown || state == .reconciled else { return false }
        guard await transitionToolTransaction(
            runId: runId,
            toolCallId: toolCallId,
            expected: expected,
            to: state,
            outcome: outcome,
            resultPayload: nil
        ) else { return false }
        let type = state == .outcomeUnknown
            ? Self.toolOutcomeUnknownEventType
            : Self.toolReconciledEventType
        let eventWritten = await append(
            runId: runId,
            event: makeToolEvent(
                type: type,
                toolCallId: toolCallId,
                fields: ["toolCallId": toolCallId, "outcome": outcome]
            )
        )
        if !eventWritten {
            print("[AmberChat] tool recovery event write failed run=\(runId) toolCallId=\(toolCallId) state=\(state.rawValue)")
        }
        return true
    }

    private func toolTransaction(runId: String, toolCallId: String) async -> IOSToolTransactionSnapshot? {
        await withCheckedContinuation { continuation in
            dao.getToolTransaction(runId: runId, toolCallId: toolCallId) { row, error in
                continuation.resume(returning: error == nil ? row.flatMap(Self.snapshot) : nil)
            }
        }
    }

    private nonisolated static func snapshot(_ row: AgentToolTransactionEntity) -> IOSToolTransactionSnapshot? {
        guard let state = IOSToolTransactionState(rawValue: row.state) else { return nil }
        return IOSToolTransactionSnapshot(
            runId: row.runId,
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            argsDigest: row.argsDigest,
            effectClass: IOSToolEffectClass(rawValue: row.effectClass) ?? .sideEffect,
            state: state,
            outcome: row.outcome,
            resultPayload: row.resultPayload
        )
    }

    private func makeToolEvent(
        type: String,
        toolCallId: String,
        fields: [String: String]
    ) -> AgentRunEvent {
        AgentRunEvent(
            eventId: UUID().uuidString,
            type: type,
            payloadType: type,
            payload: Self.jsonPayload(fields),
            payloadSchemaVersion: 1,
            isFinal: false,
            ts: Self.nowMillis(),
            turnId: nil,
            stepId: nil,
            toolCallId: toolCallId
        )
    }

    /// Approval-denial ledger event (§11.1 required evidence source). Written
    /// best-effort like Finished: the user's decision is already final in the
    /// approval UI; a failed durable write only loses attribution, not the
    /// decision.
    func recordApprovalDenied(
        runId: String,
        toolCallId: String,
        toolName: String,
        reason: String,
        capabilityId: String?
    ) async {
        var fields: [String: String] = [
            "toolCallId": toolCallId,
            "toolName": toolName,
        ]
        if let capabilityId { fields["capabilityId"] = capabilityId }
        // `reason` is an app-owned fixed string (e.g. "User denied network
        // search."), never user message content; kept for provenance only.
        fields["reason"] = reason
        let payload = Self.jsonPayload(fields)
        let ok = await append(
            runId: runId,
            event: AgentRunEvent(
                eventId: UUID().uuidString,
                type: Self.approvalDeniedEventType,
                payloadType: Self.approvalDeniedEventType,
                payload: payload,
                payloadSchemaVersion: 1,
                isFinal: false,
                ts: Self.nowMillis(),
                turnId: nil,
                stepId: nil,
                toolCallId: toolCallId
            )
        )
        if !ok {
            print("[AmberChat] approval_denied ledger write failed run=\(runId) toolCallId=\(toolCallId)")
        }
    }

    private func append(
        runId: String,
        event: AgentRunEvent
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            store.appendRunEvent(runId: runId, event: event) { inserted, error in
                if let error { print("[AmberChat] agent_event insert failed: \(error)") }
                continuation.resume(returning: error == nil && (inserted?.boolValue ?? false))
            }
        }
    }

    private static func jsonPayload(_ fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// effectClass lookup tables (§W1 table), split by call site because the two
/// execution paths key tools differently:
///   - chat foreground/approval path knows only `ChatPendingToolKind` (a
///     coarser grouping computed by `ChatToolRuntime.nextPendingToolCall`);
///   - the reusable engine (`IOSAgentToolEngine`) dispatches by raw tool name
///     against an executor map, so it classifies by name directly.
/// Both fail safe: anything not explicitly listed maps to `.sideEffect`, so an
/// unrecognized tool is never assumed retryable after a crash.
enum IOSToolEffectClassMapping {
    static func forChatKind(
        _ kind: ChatPendingToolKind,
        input: String
    ) -> IOSToolEffectClass {
        switch kind {
        case .toolSearch:
            // Local catalog search — no effect in the world.
            .pure
        case .search:
            // search_web / scrape_web — read-only network calls: replay-safe
            // (no local write) but they do egress query/URL to third parties.
            .networkRead
        case .memory:
            memoryEffectClass(input: input)
        case .askUser:
            // Asking a question has no effect in the world.
            .pure
        case .sessionRead:
            // 跨会话读取（session_search/session_read）——本地只读检索，无副作用。
            .pure
        case .runtimeStatus:
            // runtime_status——本地运行时自省快照，无副作用。
            .pure
        case .workspace, .ish, .webMount, .image, .advanced:
            // advanced covers mcp_call / subagent_dispatch / model_council_run.
            .sideEffect
        }
    }

    static func forToolName(_ toolName: String, input: String) -> IOSToolEffectClass {
        if toolName == "tool_search" {
            // P0-a: local catalog search — no effect in the world.
            return .pure
        }
        if toolName == "tools_list" {
            // M5: tools_list 与 tool_search 同属本地目录调用（发现引导同一路径），
            // 纯读无副作用——与 ChatToolRuntime 的 kind(.toolSearch) 分类对齐，
            // 也保证生成中在途 tools_list 允许后台交接重放。
            return .pure
        }
        if IOSSearchExecutor.supportedToolNames.contains(toolName) {
            // search_web / scrape_web: replay-safe (no local write) but egress
            // query/URL/API key to third parties — tier above pure.
            return .networkRead
        }
        if toolName == "ask_user" {
            return .pure
        }
        // 跨会话读取工具：本地只读检索（搜索/读取其它会话），重放无副作用。
        if toolName == "session_search" || toolName == "session_read" {
            return .pure
        }
        // 本地运行时自省快照（Jev 模式/门控/目录计数）——纯读，重放无副作用。
        if toolName == "runtime_status" {
            return .pure
        }
        if toolName == IOSWeatherToolCatalog.toolName
            || toolName == IOSHealthAgentToolCatalog.toolName
            || toolName == IOSAppleAgentToolCatalog.calendarEventsList
            || toolName == IOSAppleAgentToolCatalog.remindersList {
            return .pure
        }
        // Provider 配置：status 纯读；apply/refresh/set_slot 写 SharedSettings。
        if toolName == "provider_config_status" {
            return .pure
        }
        if toolName == "theme_pack_status" {
            return .pure
        }
        if IOSProviderConfigToolCatalog.mutatingToolNames.contains(toolName) {
            return .sideEffect
        }
        if IOSThemePackToolCatalog.mutatingToolNames.contains(toolName) {
            return .sideEffect
        }
        if toolName == "memory_tool" {
            return memoryEffectClass(input: input)
        }
        if IOSWorkspaceToolCatalog.supportedToolNames.contains(toolName) {
            return .sideEffect
        }
        if IOSRemoteTerminalToolCatalog.readOnlyToolNames.contains(toolName) {
            return .pure
        }
        if IOSAgentTerminalToolCatalog.supportedToolNames.contains(toolName) {
            return .sideEffect
        }
        if IOSWebMountToolCatalog.supportedToolNames.contains(toolName)
            || IOSWebMountToolCatalog.unsupportedToolNames.contains(toolName) {
            return .sideEffect
        }
        // 本机只读查询：skills_list/use_skill/skill_validate 读本机 Skill 文件与
        // 设置；mcp_list 只刷新内存目录（IOSMcpManager.refreshServers 是纯本地
        // 重读，不出网）；mcp_describe_tool 是已发现工具的只读目录查询（其实现
        // 注释明确 "never touches the network and never mutates config"，
        // IOSSkillMcpTools.swift mcpDescribeToolJSON）——按真实行为标 pure。
        if toolName == "skills_list"
            || toolName == "use_skill"
            || toolName == "skill_validate"
            || toolName == "recipes_list"
            || toolName == "recipe_validate"
            || toolName == "mcp_list"
            || toolName == "mcp_describe_tool" {
            return .pure
        }
        if toolName == "generate_image"
            || toolName == "subagent_dispatch"
            || toolName == "model_council_run"
            || toolName == "mcp_call"
            || ToolKt.isExpandedMcpToolName(name: toolName) // P0-b: flattened MCP calls
            || toolName == "mcp_test"
            || toolName == "mcp_import_from_skill"
            || toolName == "skill_import"
            || toolName == "soul_import"
            || toolName == "skill_enable"
            || toolName == "skill_disable"
            || IOSRecipeToolCatalog.mutatingToolNames.contains(toolName) {
            return .sideEffect
        }
        // P1-c: 编排工具——spawn/interrupt 有真实副作用（建线程/取消 run），
        // list_agents 只读。
        if toolName == "spawn_agent" || toolName == "interrupt_agent" {
            return .sideEffect
        }
        if toolName == "list_agents" {
            return .pure
        }
        // P1-d: send/followup 投递信封（重放会重复投递）→ sideEffect；
        // wait_agent 只等 mailbox 活动（无外部副作用）→ pure。
        if toolName == "send_message" || toolName == "followup_task" {
            return .sideEffect
        }
        if toolName == "wait_agent" {
            return .pure
        }
        // P3-a: exec 运行任意 JS——重放会重复执行，按 shell 执行同类处理。
        if toolName == "exec" {
            return .sideEffect
        }
        // P3-c: wait 推进 cell 状态（terminate=true 真实变更；读取也消耗
        // read-once 终态）——显式钉死为保守 sideEffect（fail-safe 默认同值）：
        // 崩溃后不自动重试 wait，避免重试读到推进后的另一终态。
        if toolName == "wait" {
            return .sideEffect
        }
        // Fail-safe default (I-3): a tool name this map doesn't know about
        // must never be assumed retryable — better to under-retry a pure tool
        // than to auto-replay an unknown side effect.
        return .sideEffect
    }

    /// `memory_tool` multiplexes reads and three materially different write
    /// shapes. Creates allocate a fresh record id and can duplicate data, while
    /// edit/delete address a stable id and converge when repeated.
    private static func memoryEffectClass(input: String) -> IOSToolEffectClass {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAction = object["action"] as? String else {
            return .sideEffect
        }
        switch rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list", "read", "search", "query", "status":
            return .pure
        case "edit", "update", "delete", "remove":
            return .idempotent
        case "create", "add", "write":
            return .sideEffect
        default:
            return .sideEffect
        }
    }
}

enum IOSToolCallLedgerClassifier {
    static let startedType = IOSAgentRunLedger.toolStartedEventType
    static let finishedType = IOSAgentRunLedger.toolFinishedEventType
    private static let legacyStartedType = "tool_call_started"
    private static let legacyFinishedType = "tool_call_finished"

    static func isStarted(_ type: String) -> Bool {
        type == startedType || type == legacyStartedType
    }

    static func isFinished(_ type: String) -> Bool {
        type == finishedType || type == legacyFinishedType
    }

}

// MARK: - W3: crash-recovery UX (§W3, invariant I-3)
//
// W3's recovery sweep covers all three documented states, including the third
// one (§W3 step 3 / task point 3):
// a clean Started→Finished(completed) pairing whose result never reached the
// persisted conversation (died between Finished and the turn-end message
// save). That disambiguation needs the *outcome* string a Finished event
// carries and whether the tool part's output is still empty — neither of
// which simple Started/Finished pairing alone cannot distinguish.

/// What a single toolCallId's ledger trail resolves to for the recovery UX.
/// I-3: three durable outcomes, none of which is "silently rerun" — every
/// case below writes a structured record into the tool part's `output`, so
/// `groupPartsByToolBoundary` (`ai-core/.../ProviderMessageUtils.kt:46`)
/// treats the call as resolved (`isExecuted`) rather than silently dropping
/// it from the next provider request. An earlier revision of this type had a
/// fourth "leave output empty" case for pure/idempotent tools, reasoning
/// that `nextPendingToolCall` would pick it back up on the next turn — that
/// was wrong: an empty-output Tool part falls into `groupPartsByToolBoundary`'s
/// Content group and is silently dropped when building the provider request,
/// so the call would simply vanish from the model's view, not "retry
/// automatically". Fixed per the same W2 fail-closed philosophy: hand the
/// state back to the model as text and let the model decide to re-call the
/// tool — a real, model-mediated retry instead of an app-level replay.
enum IOSToolCallRecoveryAction: Equatable {
    /// sideEffect class, unresolved Started (no Finished after it): the tool
    /// may or may not actually have run — never auto-rerun it. Written output
    /// makes that structural: once `output` is non-empty no mechanism in the
    /// app can ever re-dispatch this toolCallId.
    case markUnknown
    /// pure/idempotent class, unresolved Started: the tool provably did NOT
    /// finish (no side effect risk either way), so it is safe to hand back to
    /// the model as "not executed, safe to call again" — the model reads this
    /// like any other tool result and re-issues the call itself if the task
    /// still needs it.
    case markRetryable
    /// The app stopped while the tool was waiting for explicit approval. The
    /// side effect never started; close the abandoned approval without implying
    /// that the tool itself was side-effect free.
    case markApprovalInterrupted
    /// Clean Started/Finished(completed) pairing, but the conversation's
    /// persisted tool part still has an empty output: the side effect ran to
    /// completion, only the write of its result never made it to disk.
    case markResultLost
    /// A terminal result exists in the transaction row even though the
    /// conversation snapshot did not yet contain it. Apply the stored parts;
    /// never invoke the executor again.
    case replayResult(String)

    /// User-visible text (I-3), rendered via `ChatToolOutputFormatter.failureReason(from:)`
    /// as the tool timeline's failed-step detail — the same JSON shape for
    /// all three states means the UI needs zero new rendering code, and the
    /// model reads the exact same text (it's what `output` actually is).
    var toolPartMessage: String {
        switch self {
        case .markUnknown:
            return "应用中断，此操作是否已生效未知。为避免重复执行的风险，已停止自动重试。"
        case .markRetryable:
            return "应用中断，该操作未执行（该工具无副作用，可安全重试）。如任务仍需要，请重新调用此工具。"
        case .markApprovalInterrupted:
            return "App 在等待确认时中断，该操作尚未执行。本次调用已结束；如仍需要，请重新发起。"
        case .markResultLost:
            return "工具已执行完成，但结果在应用中断中丢失（不会重复执行）。"
        case .replayResult:
            return "工具结果已从安全恢复记录中还原。"
        }
    }
}

/// One decoded `agent_event` row used by W3 grouping. Built by best-effort parsing of
/// `AgentEventEntity.payload` (a flat JSON string — see `IOSAgentRunLedger`'s
/// `jsonPayload`).
struct IOSToolCallLedgerRow: Equatable {
    let toolCallId: String
    let type: String
    let seq: Int64
    /// Present (non-nil) only on Started rows.
    let effectClass: IOSToolEffectClass?
    /// Present (non-nil) only on Finished rows.
    let outcome: String?

    /// Decodes one ledger row's payload. Returns `nil` only when `toolCallId`
    /// itself can't be recovered — without it the row can't be grouped with
    /// its siblings, so it is dropped rather than guessed at (there is
    /// nothing conservative to fall back to for "which call is this").
    ///
    /// A Started row whose `effectClass` field is missing or an unrecognized
    /// string still keeps its `toolCallId` and is attributed `.sideEffect` —
    /// the same fail-closed default `IOSToolEffectClassMapping` uses for an
    /// unrecognized tool name. Corrupt metadata must never be read as "safe
    /// to retry"; the worst case of defaulting to `.sideEffect` is an
    /// unnecessary "outcome unknown" notice, not a silent re-execution.
    static func decode(type: String, seq: Int64, payload: String) -> IOSToolCallLedgerRow? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolCallId = (object["toolCallId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolCallId.isEmpty else {
            return nil
        }
        var effectClass: IOSToolEffectClass?
        if IOSToolCallLedgerClassifier.isStarted(type) {
            if let raw = object["effectClass"] as? String, let parsed = IOSToolEffectClass(rawValue: raw) {
                effectClass = parsed
            } else {
                effectClass = .sideEffect
            }
        }
        let outcome = object["outcome"] as? String
        return IOSToolCallLedgerRow(toolCallId: toolCallId, type: type, seq: seq, effectClass: effectClass, outcome: outcome)
    }
}

/// Pure grouping + decision function: many `IOSToolCallLedgerRow`s (one
/// run's whole `agent_event` history, potentially several toolCallIds across
/// several tool-resume turns) → at most one `IOSToolCallRecoveryAction` per
/// toolCallId that actually needs one. No I/O — callers own reading the
/// ledger and reading whether a tool part's persisted output is empty.
enum IOSToolCallRecoveryPlanner {
    static func plan(
        rows: [IOSToolCallLedgerRow],
        isOutputEmpty: (String) -> Bool
    ) -> [String: IOSToolCallRecoveryAction] {
        var byToolCallId: [String: [IOSToolCallLedgerRow]] = [:]
        for row in rows {
            byToolCallId[row.toolCallId, default: []].append(row)
        }
        var actions: [String: IOSToolCallRecoveryAction] = [:]
        for (toolCallId, toolRows) in byToolCallId {
            let sorted = toolRows.sorted { $0.seq < $1.seq }
            guard let lastStarted = sorted.last(where: { IOSToolCallLedgerClassifier.isStarted($0.type) }) else {
                continue // Never started: nothing to reconcile.
            }
            let effectClass = lastStarted.effectClass ?? .sideEffect
            let finishedAfter = sorted.last(where: {
                IOSToolCallLedgerClassifier.isFinished($0.type) && $0.seq > lastStarted.seq
            })
            guard let finishedAfter else {
                // Unresolved (same condition `classify` calls outcomeUnknown/retryable).
                actions[toolCallId] = (effectClass == .sideEffect) ? .markUnknown : .markRetryable
                continue
            }
            // Clean pairing. "paused_for_approval" is the awaiting-approval
            // hand-off, already owned by `IOSRunRecovery`'s pending-approval
            // path — only a completed call whose result never reached disk
            // (§W3 third state) is actionable here.
            if finishedAfter.outcome == "completed", isOutputEmpty(toolCallId) {
                actions[toolCallId] = .markResultLost
            }
        }
        return actions
    }
}

/// Applies a `IOSToolCallRecoveryPlanner.plan` result to one conversation's
/// message list. Pure (no I/O) and deliberately independent of
/// `ChatToolRuntime` — replacing one tool part's `output` needs none of its
/// settings/executor plumbing, and keeping this free-standing lets both the
/// pending-approval and plain-interrupted recovery paths share it, and lets
/// tests exercise it without constructing a full runtime.
///
/// One code path for all three states: every `IOSToolCallRecoveryAction`
/// writes its `toolPartMessage` into the matching tool part's `output` via
/// the same `failureJSON` shape. This is deliberate, not incidental — a Tool
/// part with empty `output` is dropped from the next provider request by
/// `groupPartsByToolBoundary` (`ai-core/.../ProviderMessageUtils.kt:46`,
/// which only treats `isExecuted` parts as boundaries), so leaving `output`
/// empty for any of these states would make the call vanish from the
/// model's view instead of "staying resumable".
enum IOSToolCallRecoveryApplier {
    static func apply(
        _ plan: IOSToolCallRecoveryPlan,
        to messages: [UIMessage]
    ) -> [UIMessage] {
        apply(plan.actions, to: messages, toolNames: plan.toolNames)
    }

    static func apply(
        _ actions: [String: IOSToolCallRecoveryAction],
        to messages: [UIMessage],
        toolNames: [String: String] = [:]
    ) -> [UIMessage] {
        guard !actions.isEmpty else { return messages }
        var result = messages
        // Deterministic order so tests (and any future logging) aren't at the
        // mercy of Dictionary's iteration order.
        for toolCallId in actions.keys.sorted() {
            guard let action = actions[toolCallId] else { continue }
            let toolPart = result
                .flatMap(\.parts)
                .compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: { $0.toolCallId == toolCallId && $0.output.isEmpty })
            let hasPersistedToolPart = result
                .flatMap(\.parts)
                .compactMap({ $0 as? UIMessagePart.Tool })
                .contains(where: { $0.toolCallId == toolCallId })
            if let toolPart {
                let output = output(for: action, toolName: toolPart.toolName)
                result = replacingToolOutput(toolCallId: toolCallId, output: output, in: result)
            } else if !hasPersistedToolPart, let toolName = toolNames[toolCallId] {
                result.append(recoveredToolMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    output: output(for: action, toolName: toolName)
                ))
            }
        }
        return result
    }

    private static func output(
        for action: IOSToolCallRecoveryAction,
        toolName: String
    ) -> [UIMessagePart] {
        if case .replayResult(let payload) = action,
           let replayed = try? IosToolOutputJsonBridge.shared.decode(json: payload) {
            return replayed
        }
        return [UIMessagePart.Text(
            text: failureJSON(toolName: toolName, reason: action.toolPartMessage),
            metadata: nil
        )]
    }

    private static func recoveredToolMessage(
        toolCallId: String,
        toolName: String,
        output: [UIMessagePart]
    ) -> UIMessage {
        let seed = UIMessage.companion.assistant(prompt: "")
        return UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallId,
                toolName: toolName,
                input: #"{"recovered_from_transaction":true}"#,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
    }

    static func applyOutcomeUnknownReconciliation(
        toolCallId: String,
        didApply: Bool,
        to messages: [UIMessage]
    ) -> [UIMessage] {
        guard let toolName = messages
            .flatMap(\.parts)
            .compactMap({ $0 as? UIMessagePart.Tool })
            .first(where: { $0.toolCallId == toolCallId })?.toolName else {
            return messages
        }
        let reason = didApply
            ? "用户确认：该操作已经生效。为避免重复执行，不会再次运行此工具。"
            : "用户确认：该操作没有生效。本次调用已结束；如仍需要，请重新发起。"
        let output = [UIMessagePart.Text(
            text: failureJSON(toolName: toolName, reason: reason),
            metadata: nil
        )]
        return replacingToolOutput(toolCallId: toolCallId, output: output, in: messages)
    }

    /// Same `{"ok":false,"tool":...,"reason":...}` shape as
    /// `ChatToolOutputFormatter.toolFailureJSON` (so `failureReason(from:)`
    /// recognizes it and the tool timeline UI renders it as a failed step
    /// with `reason` as the detail) — reimplemented locally rather than
    /// calling that formatter directly because `ChatToolOutputFormatter` is
    /// `@MainActor`-isolated and this applier must stay a plain, testable,
    /// non-isolated pure function.
    private static func failureJSON(toolName: String, reason: String) -> String {
        let payload: [String: Any] = ["ok": false, "tool": toolName, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(toolName) failed: \(reason)"
        }
        return text
    }

    private static func replacingToolOutput(
        toolCallId: String,
        output: [UIMessagePart],
        in messages: [UIMessage]
    ) -> [UIMessage] {
        var didReplace = false
        return messages.map { message in
            guard message.role == MessageRole.assistant, !didReplace else { return message }
            var didChangeMessage = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard !didReplace,
                      let toolPart = part as? UIMessagePart.Tool,
                      toolPart.toolCallId == toolCallId else { return part }
                didReplace = true
                didChangeMessage = true
                return PromptTranscript.shared.doCopyTool(
                    tool: toolPart,
                    input: toolPart.input,
                    output: output
                )
            }
            guard didChangeMessage else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }
}
