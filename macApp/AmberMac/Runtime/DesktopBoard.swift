import Foundation
@preconcurrency import GatewayCore

/// Builds the task board shared by the Mac view and the phone: scheduled tasks, their recent runs, and the
/// Claude Code / Codex sessions the gateway tracks. Pure, so grouping and ordering are unit-tested.
@MainActor enum DesktopBoard {
    /// What the board knows about a scheduled run that is in flight right now.
    struct LiveRun: Equatable {
        var taskID: UUID
        /// Gateway session key, when the gateway saw the run start; needed to answer an approval from the phone.
        var sessionKey: String?
        var approval: DesktopToolApproval?
        var conversationID: UUID?
    }

    static let doneWindow: TimeInterval = 7 * 24 * 3600
    static let runsPerTask = 3

    static func build(tasks: [DesktopScheduledTask], live: [LiveRun], paused: Bool,
                      sessions: [SessionRecord], now: Date) -> [AmberControl.BoardItem] {
        var items: [AmberControl.BoardItem] = []
        let liveByTask = Dictionary(live.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })

        for task in tasks {
            if let run = liveByTask[task.id] {
                let approval = run.approval.map { approval in
                    AmberControl.BoardItem.Approval(sessionKey: run.sessionKey ?? "", toolCallId: approval.id, tool: approval.name,
                        detail: DesktopGatewayReporter.excerpt(approval.arguments), highRisk: DesktopToolRegistry.isHighRisk(approval.name))
                }
                items.append(.init(id: "run:\(task.id.uuidString)", kind: .run, column: approval == nil ? .running : .needsYou,
                    title: task.name, detail: approval == nil ? "运行中" : "等你确认 · " + (approval?.tool ?? ""),
                    updatedAt: task.lastRun?.startedAt ?? now, scheduleId: task.id.uuidString,
                    conversationId: run.conversationID?.uuidString,
                    // An approval without a gateway session can only be answered on the Mac.
                    approval: approval.flatMap { $0.sessionKey.isEmpty ? nil : $0 }))
            } else if task.enabled {
                let next = paused ? nil : task.nextRunAt
                items.append(.init(id: "schedule:\(task.id.uuidString)", kind: .schedule, column: .scheduled, title: task.name,
                    detail: DesktopScheduledTasksView.ruleText(task) + (paused ? " · 已暂停" : ""),
                    updatedAt: next ?? task.createdAt, scheduleId: task.id.uuidString, nextRunAt: next))
            }
            for run in task.recentRuns.filter({ $0.status == .completed || $0.status == .failed })
                .filter({ now.timeIntervalSince($0.finishedAt ?? $0.startedAt) < doneWindow }).prefix(runsPerTask) {
                let failed = run.status == .failed
                items.append(.init(id: "done:\(run.id.uuidString)", kind: .run, column: .done, title: task.name,
                    detail: run.summary ?? (failed ? (run.error ?? "未完成") : "已完成"),
                    updatedAt: run.finishedAt ?? run.startedAt, scheduleId: task.id.uuidString,
                    conversationId: run.conversationID?.uuidString, failed: failed))
            }
        }

        for rec in sessions where rec.agent != .amber && rec.agent != .run {
            // No prompt ever submitted (e.g. a host's sub-second background call): nothing to name it by.
            // Kept only while it waits on you, so a pending request is never hidden.
            if rec.generatedTitle == nil, rec.summary == nil, rec.state != .waiting { continue }
            let column: AmberControl.BoardItem.Column
            switch rec.state {
            case .waiting: column = .needsYou
            case .running, .stalled: column = .running
            case .completed, .stopped:
                guard now.timeIntervalSince(rec.updatedAt) < doneWindow else { continue }
                column = .done
            }
            let source = [rec.agent.displayName, rec.host].compactMap { $0 }.joined(separator: " · ")
            items.append(.init(id: "session:\(rec.key)", kind: .agentSession, column: column,
                title: rec.generatedTitle ?? rec.summary ?? Registry.subject(for: rec),
                detail: source + " · " + rec.state.label(rec.waitReason, abnormal: rec.abnormal), updatedAt: rec.updatedAt,
                waitingForReply: rec.state == .waiting && rec.waitReason != .permission, failed: rec.abnormal))
        }

        return items.sorted { a, b in
            let (ac, bc) = (columnOrder(a.column), columnOrder(b.column))
            if ac != bc { return ac < bc }
            // Scheduled: soonest first. Everything else: most recent first.
            if a.column == .scheduled { return (a.nextRunAt ?? .distantFuture) < (b.nextRunAt ?? .distantFuture) }
            return a.updatedAt > b.updatedAt
        }
    }

    private static func columnOrder(_ column: AmberControl.BoardItem.Column) -> Int {
        AmberControl.BoardItem.Column.allCases.firstIndex(of: column) ?? 0
    }
}
