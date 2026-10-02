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

struct IOSWebMountRunReport: Sendable, Equatable, Identifiable {
    let id: String
    let startedAtMillis: Int64
    let isRunning: Bool
    let durationMillis: Int64
    let totalToolCalls: Int
    let webMountToolCalls: Int
    let failedToolCalls: Int
    let rejectedToolCalls: Int
    let userHandoffCount: Int
    let steps: [IOSWebMountRunReportStep]
}

struct IOSWebMountRunReportStep: Sendable, Equatable, Identifiable {
    let id: String
    let timestampMillis: Int64?
    let toolName: String
    let targetSummary: String
    let dispatched: Bool?
    let pageChanged: Bool?
    let goalVerified: Bool?
    let errorCode: String?
    let handedOffToUser: Bool
    let pageDrift: Bool
    let credentialRedacted: Bool
    let unattributedPageActivity: Bool
    let isFailure: Bool
    let isRejected: Bool
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
