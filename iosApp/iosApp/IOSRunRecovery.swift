import Foundation
@preconcurrency import Shared

struct IOSPendingApprovalRecoveryDescriptor: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let toolCallId: String
}

enum IOSOutcomeUnknownResolution: String, Equatable, Sendable {
    case applied
    case notApplied
    case recheckRequested

    var ledgerOutcome: String {
        switch self {
        case .applied:
            return "user_confirmed_applied"
        case .notApplied:
            return "user_confirmed_not_applied"
        case .recheckRequested:
            return "user_requested_recheck"
        }
    }
}

struct IOSOutcomeUnknownFollowup: Equatable, Sendable {
    let conversationId: String
    let runId: String
    let toolCallId: String
    let toolName: String
    let localizedToolTitle: String
    let resolution: IOSOutcomeUnknownResolution
    let suggestedPrompt: String
    let buttonTitle: String
}

struct IOSToolOutcomeUnknownDescriptor: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let toolCallId: String
    let toolName: String
    let targetSummary: String?

    init(
        runId: String,
        conversationId: String,
        toolCallId: String,
        toolName: String,
        targetSummary: String? = nil
    ) {
        self.runId = runId
        self.conversationId = conversationId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.targetSummary = Self.sanitizedTargetSummary(targetSummary)
    }

    var localizedToolTitle: String {
        Self.localizedTitle(for: toolName)
    }

    var redactedTargetSummary: String? {
        targetSummary
    }

    var sideEffectExplanation: String {
        Self.localizedSideEffectExplanation(for: toolName)
    }

    static func localizedTitle(for toolName: String) -> String {
        switch toolName {
        case "workspace_file_write":
            return IOSAppLocalization.string("写入 Workspace 文件", defaultValue: "写入 Workspace 文件")
        case "workspace_file_edit":
            return IOSAppLocalization.string("编辑 Workspace 文件", defaultValue: "编辑 Workspace 文件")
        case "workspace_file_move":
            return IOSAppLocalization.string("移动 Workspace 文件", defaultValue: "移动 Workspace 文件")
        case "workspace_artifact_delete":
            return IOSAppLocalization.string("删除 Workspace 文件", defaultValue: "删除 Workspace 文件")
        case "memory_tool":
            return IOSAppLocalization.string("更新长期记忆", defaultValue: "更新长期记忆")
        case "calendar_event_create":
            return IOSAppLocalization.string("新建日历日程", defaultValue: "新建日历日程")
        case "calendar_event_update":
            return IOSAppLocalization.string("修改日历日程", defaultValue: "修改日历日程")
        case "calendar_event_delete":
            return IOSAppLocalization.string("删除日历日程", defaultValue: "删除日历日程")
        case "reminder_create":
            return IOSAppLocalization.string("新建提醒事项", defaultValue: "新建提醒事项")
        case "reminder_update":
            return IOSAppLocalization.string("修改提醒事项", defaultValue: "修改提醒事项")
        case "reminder_delete":
            return IOSAppLocalization.string("删除提醒事项", defaultValue: "删除提醒事项")
        case "reminder_complete":
            return IOSAppLocalization.string("完成提醒事项", defaultValue: "完成提醒事项")
        case "notification_schedule":
            return IOSAppLocalization.string("安排本地通知", defaultValue: "安排本地通知")
        case "notification_cancel":
            return IOSAppLocalization.string("取消本地通知", defaultValue: "取消本地通知")
        case "alarm_schedule", "alarm_cancel":
            return IOSAppLocalization.string("修改闹钟与计时器", defaultValue: "修改闹钟与计时器")
        case "mcp_call":
            return IOSAppLocalization.string("调用外部 MCP 工具", defaultValue: "调用外部 MCP 工具")
        default:
            if toolName.hasPrefix("mcp__") {
                return IOSAppLocalization.string("调用外部 MCP 工具", defaultValue: "调用外部 MCP 工具")
            }
            if toolName.hasPrefix("wm_") {
                return IOSAppLocalization.string("执行网页站内操作", defaultValue: "执行网页站内操作")
            }
            if toolName.hasPrefix("phone_") {
                return IOSAppLocalization.string("执行手机操作", defaultValue: "执行手机操作")
            }
            if toolName.hasPrefix("ish_") || toolName.hasPrefix("terminal_") {
                return IOSAppLocalization.string("执行终端命令", defaultValue: "执行终端命令")
            }
            return IOSAppLocalization.string("执行本地操作", defaultValue: "执行本地操作")
        }
    }

    static func localizedSideEffectExplanation(for toolName: String) -> String {
        if toolName.hasPrefix("workspace_") {
            return IOSAppLocalization.string("App 在工作区写入或修改过程中中断，文件内容可能已部分或全部落盘。", defaultValue: "App 在工作区写入或修改过程中中断，文件内容可能已部分或全部落盘。")
        }
        if toolName == "memory_tool" {
            return IOSAppLocalization.string("记忆写入过程中应用中断，笔记或记忆条目可能已写入。", defaultValue: "记忆写入过程中应用中断，笔记或记忆条目可能已写入。")
        }
        if toolName.hasPrefix("calendar_") || toolName.hasPrefix("reminder_") || toolName.hasPrefix("alarm_") || toolName.hasPrefix("notification_") {
            return IOSAppLocalization.string("系统日程或提醒修改过程中应用中断，系统数据可能已更新。", defaultValue: "系统日程或提醒修改过程中应用中断，系统数据可能已更新。")
        }
        return IOSAppLocalization.string("工具执行期间应用中途中断，目标状态可能已变化；系统已禁止自动重放。", defaultValue: "工具执行期间应用中途中断，目标状态可能已变化；系统已禁止自动重放。")
    }

    static func extractRedactedTargetSummary(from rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return sanitizedTargetSummary(trimmed)
        }
        let candidateKeys = ["path", "to_path", "target", "title", "url", "server", "tool", "app", "query", "id"]
        for key in candidateKeys {
            if let value = json[key] as? String,
               let safe = sanitizedTargetSummary(value) {
                return safe
            }
        }
        return nil
    }

    private static func sanitizedTargetSummary(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let redactionPatterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9\-._~+/]+=*"#,
            #"(?i)(sk-|ghp_|xoxb-|xoxp-)[A-Za-z0-9\-_]{8,}"#,
            #"(?i)(token|secret|password|api_key)\s*[:=]\s*[^\s,;\"'}]+"#,
        ]
        for pattern in redactionPatterns {
            value = value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        if value.count > 100 {
            value = String(value.prefix(97)) + "..."
        }
        return value
    }
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
        guard let transactions = await ledger.toolTransactions(runId: runId) else {
            return nil
        }

        // Read both ledger generations before mutating either one. Otherwise a
        // legacy-read failure after a modern STARTED -> OUTCOME_UNKNOWN CAS can
        // leave the caller without the plan needed to present confirmation.
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
            return nil
        }

        var actions: [String: IOSToolCallRecoveryAction] = [:]
        var toolNames: [String: String] = [:]
        var transactionToolCallIds = Set<String>()
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
                    if transaction.outcome == "completed_requires_replan" {
                        // The current result may already be in the snapshot while
                        // the rest of its batch is still pending. Keep the marker
                        // even in that case until the applier's skips are saved.
                        actions[transaction.toolCallId] = .replayResult(
                            transaction.resultPayload ?? "",
                            requiresReplan: true
                        )
                    } else if !completedOutputToolCallIds.contains(transaction.toolCallId) {
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

        // Older installations have event rows but no transaction rows. Keep
        // their established recovery path. A run can contain both old event-only
        // calls and newer transaction-backed calls after an app upgrade, so merge
        // by toolCallId instead of skipping the entire legacy ledger as soon as
        // one transaction exists.
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
        await reconcileOutcomeUnknown(
            runId: runId,
            toolCallId: toolCallId,
            resolution: didApply ? .applied : .notApplied,
            dao: dao,
            runStore: runStore
        )
    }

    static func reconcileOutcomeUnknown(
        runId: String,
        toolCallId: String,
        resolution: IOSOutcomeUnknownResolution,
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao(),
        runStore: IOSDurableRunStore = IOSDurableRunStore()
    ) async -> Bool {
        let outcome = resolution.ledgerOutcome
        let ledger = IOSAgentRunLedger(dao: dao)
        let didRecord = await ledger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCallId,
            expected: .outcomeUnknown,
            to: .reconciled,
            outcome: outcome
        )
        // Reconciliation is per tool call. Keep the run recoverable while
        // another unknown result still needs a decision after a cold launch.
        guard let transactions = await ledger.toolTransactions(runId: runId) else { return false }
        // A previous attempt may have committed the tool decision before a
        // later read or run-state write failed. Retrying that same decision
        // is safe; a conflicting decision must not overwrite it.
        guard didRecord || transactions.contains(where: {
            $0.toolCallId == toolCallId && $0.state == .reconciled && $0.outcome == outcome
        }) else { return false }
        if transactions.contains(where: { $0.state == .outcomeUnknown }) {
            return (try? await runStore.snapshot(runId: runId)?.status) == .outcomeUnknown
        }
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
