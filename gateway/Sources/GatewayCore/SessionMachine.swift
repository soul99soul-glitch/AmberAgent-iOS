import Foundation

/// Pure per-session state transitions (design doc 3.2 / 3.3). Push decisions live in `Registry`.
enum SessionMachine {
    static func apply(_ event: GatewayEvent, to r: inout SessionRecord) {
        if !r.isOpen {
            // A runExit spooled past the ack deadline can land after NOTE_EXIT closed the session as
            // abnormal; it still carries the real exit status.
            let correctsExit = event.kind == .runExit && (r.agent == .run || r.agent == .amber)
            guard correctsExit || [.sessionStart, .promptSubmit, .runStart].contains(event.kind) else { return }
            r.abnormal = false
            r.sawTurnEnd = false
            r.sawFailure = false
        }
        // Any sign of life clears a stall.
        if r.state == .stalled { r.state = .running }

        switch event.kind {
        case .sessionStart:
            r.state = .running
            r.waitReason = nil
        case .promptSubmit, .runStart:
            r.state = .running
            r.waitReason = nil
            r.sawTurnEnd = false
            r.sawFailure = false
        case .permissionRequest, .permissionNotice:
            r.state = .waiting
            r.waitReason = .permission
            if event.kind == .permissionRequest {
                r.waitingTool = event.tool
                r.waitingToolCallId = event.toolCallId
                r.waitingDetail = event.detail
                r.waitingHighRisk = event.highRisk
            }
        case .idleNotice:
            if r.state != .waiting {
                r.state = .waiting
                r.waitReason = .turnEnd
            }
        case .turnStop, .turnFailure, .interrupt:
            if event.kind == .turnStop { r.sawTurnEnd = true }
            if event.kind == .turnFailure { r.sawFailure = true }
            // Headless outcome is decided by process exit, not by turn end.
            if r.origin != .headless {
                r.state = .waiting
                r.waitReason = .turnEnd
            }
        case .toolDone:
            // Parallel calls mean an unrelated auto-approved tool can finish while the prompt is still up.
            if r.state == .waiting, r.waitReason == .permission, event.tool != nil, event.tool == r.waitingTool,
               r.agent != .amber || event.toolCallId == r.waitingToolCallId {
                r.state = .running
                r.waitReason = nil
            }
        case .sessionEnd:
            r.sawTurnEnd = true
            r.waitReason = nil
            if r.origin == .headless {
                r.state = r.sawFailure ? .stopped : .completed
                r.abnormal = r.sawFailure
            } else {
                r.state = .stopped
            }
        case .runExit:
            r.waitReason = nil
            if event.exitCode == 0 && event.signal == nil {
                r.state = .completed
            } else {
                r.state = .stopped
                r.abnormal = true
            }
        }
        clearPermissionDetail(&r)
    }

    static func clearPermissionDetail(_ r: inout SessionRecord) {
        guard r.waitReason != .permission else { return }
        r.waitingToolCallId = nil
        r.waitingDetail = nil
        r.waitingHighRisk = nil
    }

    /// The session's process is gone. Exit status is only known for `run` children, which report via `runExit`.
    static func applyProcessExit(to r: inout SessionRecord) {
        guard r.isOpen else { return }
        r.waitReason = nil
        clearPermissionDetail(&r)
        if r.origin == .headless && r.agent != .run && r.sawTurnEnd && !r.sawFailure {
            r.state = .completed
            r.abnormal = false
        } else {
            r.state = .stopped
            r.abnormal = true
        }
    }
}
