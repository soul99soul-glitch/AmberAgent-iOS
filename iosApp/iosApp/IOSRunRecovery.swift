import Foundation
@preconcurrency import Shared

struct IOSPendingApprovalRecoveryDescriptor: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let toolCallId: String
}

struct IOSToolOutcomeUnknownDescriptor: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let toolCallId: String
    let toolName: String
}

struct IOSToolCallRecoverySweepResult: Equatable, Sendable {
    var reconciledRunIds = Set<String>()
    var outcomeUnknownRunIds = Set<String>()
}

struct IOSToolCallRecoveryPlan: Equatable {
    let actions: [String: IOSToolCallRecoveryAction]
    let toolNames: [String: String]

    var isEmpty: Bool { actions.isEmpty }

    subscript(toolCallId: String) -> IOSToolCallRecoveryAction? {
        actions[toolCallId]
    }
}

/// Startup recovery for interrupted agent runs. Pending approvals are identified
/// by their durable tool owner and terminated explicitly; tools are never replayed.
@MainActor
enum IOSRunRecovery {
    static func recoverPendingApprovalDescriptors(
        excludingRunIds: Set<String> = [],
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async -> [IOSPendingApprovalRecoveryDescriptor]? {
        let runs: [IOSDurableRunStore.Snapshot]
        do {
            runs = try await runStore.recoverableRuns()
        } catch {
            return nil
        }
        return runs.compactMap { run -> IOSPendingApprovalRecoveryDescriptor? in
            guard run.status == .awaitingPermission,
                  !excludingRunIds.contains(run.runId),
                  let conversationId = run.conversationId,
                  let snapshotRef = run.inputSnapshotRef,
                  snapshotRef.hasPrefix("tool_call:") else { return nil }
            let toolCallId = String(snapshotRef.dropFirst("tool_call:".count))
            guard !toolCallId.isEmpty else { return nil }
            return IOSPendingApprovalRecoveryDescriptor(
                runId: run.runId,
                conversationId: conversationId,
                toolCallId: toolCallId
            )
        }
    }

    static func completePendingApprovalRecovery(
        runId: String,
        reason: String = "process_killed",
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async {
        _ = try? await runStore.transition(
            runId: runId,
            expected: .awaitingPermission,
            to: .interrupted,
            detail: reason,
            at: now
        )
    }

    /// Reclassifies non-approval unfinished runs to "interrupted".
    @discardableResult
    static func recoverInterruptedRuns(
        candidateRunIds: Set<String>? = nil,
        excludingRunIds: Set<String> = [],
        reason: String = "process_killed",
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async -> Int {
        guard let runs = try? await runStore.recoverableRuns() else { return 0 }
        var transitioned = 0
        for run in runs where
            (candidateRunIds == nil || candidateRunIds?.contains(run.runId) == true) &&
            !excludingRunIds.contains(run.runId) {
            if (try? await runStore.transition(
                runId: run.runId,
                expected: run.status,
                to: .interrupted,
                inputSnapshotRef: run.inputSnapshotRef,
                detail: reason,
                at: now
            )) == true {
                transitioned += 1
            }
        }
        return transitioned
    }

    /// Snapshot of the (runId, conversationId) pairs from a startup-frozen set.
    /// AppShell captures candidate ids before bootstrapping conversations so a
    /// new foreground run started after the UI becomes interactive can never be
    /// mistaken for work inherited from the previous process.
    ///
    /// Runs with no `conversationId` are skipped: W3's tool-call recovery
    /// needs a conversation to write its recovery marker into, and a run
    /// without one (e.g. subagent/council-internal runs that don't map to a
    /// chat conversation) has nothing for it to do.
    static func unfinishedRunConversationPairs(
        candidateRunIds: Set<String>? = nil,
        excludingRunIds: Set<String> = [],
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async -> [(runId: String, conversationId: String)]? {
        guard let runs = try? await runStore.recoverableRuns() else { return nil }
        return runs.compactMap { run -> (runId: String, conversationId: String)? in
            guard (candidateRunIds == nil || candidateRunIds?.contains(run.runId) == true),
                  !excludingRunIds.contains(run.runId),
                  let conversationId = run.conversationId else {
                return nil
            }
            return (run.runId, conversationId)
        }
    }

    /// W3 (§ crash-recovery UX, invariant I-3): reads one run's `agent_event`
    /// ledger, decodes it, and decides each unresolved/lost toolCallId's
    /// recovery action (`IOSToolCallRecoveryPlanner`). `messages` is the
    /// caller's already-loaded snapshot of that run's conversation — this
    /// function only reads the ledger; it never touches conversation storage
    /// itself, so callers stay in control of when/whether to persist the
    /// result of applying the plan.
    ///
    /// `@MainActor`: `[UIMessage]` (a KMP-bridged type) isn't `Sendable`, and
    /// every real caller (`ChatViewModel`) is already MainActor-isolated —
    /// pinning this here avoids an actor-crossing "sending risks data races"
    /// diagnostic for no actual concurrency benefit (the DB hop still happens
    /// via `withCheckedContinuation` regardless of which actor called in).
    @MainActor
    static func planToolCallRecovery(
        runId: String,
        messages: [UIMessage],
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
    ) async -> IOSToolCallRecoveryPlan? {
        let completedOutputToolCallIds = Set(
            messages
                .flatMap(\.parts)
                .compactMap { ($0 as? UIMessagePart.Tool) }
                .filter { !$0.output.isEmpty }
                .map(\.toolCallId)
        )
        let ledger = IOSAgentRunLedger(dao: dao)
        let transactions = await ledger.toolTransactions(runId: runId)
        var actions: [String: IOSToolCallRecoveryAction] = [:]
        var toolNames: [String: String] = [:]
        var transactionToolCallIds = Set<String>()
        if let transactions {
            for transaction in transactions {
                transactionToolCallIds.insert(transaction.toolCallId)
                toolNames[transaction.toolCallId] = transaction.toolName
                switch transaction.state {
                case .prepared:
                    if await ledger.recordToolCallRecoveryTransition(
                        runId: runId,
                        toolCallId: transaction.toolCallId,
                        expected: .prepared,
                        to: .reconciled,
                        outcome: "not_started_retryable"
                    ) {
                        actions[transaction.toolCallId] = .markRetryable
                    }
                case .started:
                    if transaction.effectClass == .sideEffect {
                        if await ledger.recordToolCallRecoveryTransition(
                            runId: runId,
                            toolCallId: transaction.toolCallId,
                            expected: .started,
                            to: .outcomeUnknown,
                            outcome: "process_interrupted"
                        ) {
                            actions[transaction.toolCallId] = .markUnknown
                        }
                    } else if await ledger.recordToolCallRecoveryTransition(
                        runId: runId,
                        toolCallId: transaction.toolCallId,
                        expected: .started,
                        to: .reconciled,
                        outcome: "safe_to_retry"
                    ) {
                        actions[transaction.toolCallId] = .markRetryable
                    }
                case .finished:
                    if !completedOutputToolCallIds.contains(transaction.toolCallId) {
                        if let payload = transaction.resultPayload {
                            actions[transaction.toolCallId] = .replayResult(payload)
                        } else {
                            actions[transaction.toolCallId] = .markResultLost
                        }
                    } else {
                        _ = await ledger.recordToolCallRecoveryTransition(
                            runId: runId,
                            toolCallId: transaction.toolCallId,
                            expected: .finished,
                            to: .reconciled,
                            outcome: "persisted_in_conversation"
                        )
                    }
                case .outcomeUnknown:
                    actions[transaction.toolCallId] = .markUnknown
                case .reconciled:
                    if !completedOutputToolCallIds.contains(transaction.toolCallId),
                       (transaction.outcome == "safe_to_retry" || transaction.outcome == "not_started_retryable") {
                        actions[transaction.toolCallId] = .markRetryable
                    } else if !completedOutputToolCallIds.contains(transaction.toolCallId),
                              transaction.outcome == "result_lost" {
                        actions[transaction.toolCallId] = .markResultLost
                    }
                case .waitingUser:
                    if await ledger.recordToolCallRecoveryTransition(
                        runId: runId,
                        toolCallId: transaction.toolCallId,
                        expected: .waitingUser,
                        to: .reconciled,
                        outcome: "process_interrupted_before_approval"
                    ) {
                        actions[transaction.toolCallId] = .markApprovalInterrupted
                    }
                }
            }
        }

        // Older installations have event rows but no transaction rows. Keep
        // their established recovery path. A run can contain both old event-only
        // calls and newer transaction-backed calls after an app upgrade, so merge
        // by toolCallId instead of skipping the entire legacy ledger as soon as
        // one transaction exists.
        let rows: [IOSToolCallLedgerRow]? = await withCheckedContinuation { continuation in
            dao.listEventsForRun(id: runId) { result, error in
                guard error == nil, let result else {
                    continuation.resume(returning: nil)
                    return
                }
                let decoded = result.compactMap {
                    IOSToolCallLedgerRow.decode(type: $0.type, seq: $0.seq, payload: $0.payload)
                }
                continuation.resume(returning: decoded)
            }
        }
        guard let rows else {
            return transactions == nil ? nil : IOSToolCallRecoveryPlan(actions: actions, toolNames: toolNames)
        }
        let legacyActions = IOSToolCallRecoveryPlanner.plan(rows: rows) {
            !completedOutputToolCallIds.contains($0)
        }
        for (toolCallId, action) in legacyActions where !transactionToolCallIds.contains(toolCallId) {
            actions[toolCallId] = action
        }
        return IOSToolCallRecoveryPlan(actions: actions, toolNames: toolNames)
    }

    /// Called only after the recovered conversation snapshot has been saved.
    /// It clears short-lived result payloads and records RECONCILED; a failed
    /// save leaves FINISHED intact so the next launch can replay again.
    static func finalizeToolCallRecovery(
        runId: String,
        plan: IOSToolCallRecoveryPlan,
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
    ) async {
        await finalizeToolCallRecovery(runId: runId, actions: plan.actions, dao: dao)
    }

    static func finalizeToolCallRecovery(
        runId: String,
        actions: [String: IOSToolCallRecoveryAction],
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
    ) async {
        let ledger = IOSAgentRunLedger(dao: dao)
        for (toolCallId, action) in actions {
            let outcome: String?
            switch action {
            case .replayResult:
                outcome = "result_replayed"
            case .markResultLost:
                outcome = "result_lost"
            case .markUnknown, .markRetryable, .markApprovalInterrupted:
                outcome = nil
            }
            guard let outcome else { continue }
            _ = await ledger.recordToolCallRecoveryTransition(
                runId: runId,
                toolCallId: toolCallId,
                expected: .finished,
                to: .reconciled,
                outcome: outcome
            )
        }
    }

    /// Normal terminal path: the authoritative conversation snapshot already
    /// contains each finished result, so clear transaction payloads only after
    /// that snapshot has persisted successfully.
    static func reconcilePersistedToolResults(
        runId: String,
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
    ) async {
        let ledger = IOSAgentRunLedger(dao: dao)
        guard let transactions = await ledger.toolTransactions(runId: runId) else { return }
        for transaction in transactions {
            if transaction.state == .finished {
                _ = await ledger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: transaction.toolCallId,
                    expected: .finished,
                    to: .reconciled,
                    outcome: "persisted_in_conversation"
                )
            } else if transaction.state == .waitingUser {
                _ = await ledger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: transaction.toolCallId,
                    expected: .waitingUser,
                    to: .reconciled,
                    outcome: "cancelled_before_approval"
                )
            }
        }
    }

    /// Completes the explicit user decision for a side-effect call whose
    /// process-death outcome could not be inferred. This acknowledges the
    /// existing attempt only; it never dispatches the tool.
    static func reconcileOutcomeUnknown(
        runId: String,
        toolCallId: String,
        didApply: Bool,
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao(),
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async -> Bool {
        let outcome = didApply ? "user_confirmed_applied" : "user_confirmed_not_applied"
        let ledger = IOSAgentRunLedger(dao: dao)
        guard await ledger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCallId,
            expected: .outcomeUnknown,
            to: .reconciled,
            outcome: outcome
        ) else { return false }
        if (try? await runStore.transition(
            runId: runId,
            expected: .outcomeUnknown,
            to: .interrupted,
            detail: outcome
        )) == true {
            return true
        }
        return (try? await runStore.snapshot(runId: runId)?.status) == .interrupted
    }
}
