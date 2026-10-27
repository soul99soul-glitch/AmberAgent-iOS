import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

@MainActor final class DesktopBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ name: String, enabled: Bool = true, next: TimeInterval? = 3600) -> DesktopScheduledTask {
        var value = DesktopScheduledTask(name: name, prompt: "x", schedule: .daily(hour: 9, minute: 0), createdAt: now.addingTimeInterval(-86_400))
        value.enabled = enabled
        value.nextRunAt = next.map { now.addingTimeInterval($0) }
        return value
    }

    private func run(_ status: DesktopScheduleRunStatus, ago: TimeInterval, summary: String? = nil) -> DesktopScheduleRunRecord {
        var value = DesktopScheduleRunRecord(startedAt: now.addingTimeInterval(-ago - 30), finishedAt: now.addingTimeInterval(-ago), status: status)
        value.summary = summary
        return value
    }

    /// Sessions as the gateway records them: fed through the real registry.
    private func session(_ id: String, _ state: TaskState, wait: WaitReason? = nil, ago: TimeInterval = 60, summary: String? = nil,
                         generated: String? = nil, agent: AgentKind = .claude) -> SessionRecord {
        var registry = Registry()
        let at = now.addingTimeInterval(-ago)
        var start = GatewayEvent(agent: agent, kind: .promptSubmit, sessionId: id, cwd: "/Users/mi", timestamp: at, origin: .host)
        start.summary = summary
        start.host = "Synara"
        let presence = { Presence(screenLocked: false, idleSeconds: 0) }
        _ = registry.ingest(start, config: GatewayConfig(), now: at, presence: presence)
        let kind: EventKind? = switch state {
        case .waiting: wait == .permission ? .permissionRequest : .turnStop
        case .stopped: .sessionEnd
        case .completed: nil
        default: nil
        }
        if let kind {
            _ = registry.ingest(GatewayEvent(id: "\(id)-2", agent: agent, kind: kind, sessionId: id, timestamp: at), config: GatewayConfig(), now: at, presence: presence)
        }
        var rec = registry.sessions["\(agent.rawValue):\(id)"]!
        if state == .completed { rec.state = .completed }
        rec.generatedTitle = generated
        return rec
    }

    func testColumnsOrderingAndTitles() {
        var daily = task("每日汇总", next: 7200)
        daily.recentRuns = [run(.completed, ago: 600, summary: "新增 3 个文件"), run(.skipped, ago: 900), run(.failed, ago: 3600)]
        let soon = task("周报", next: 600)
        let off = task("季度回顾", enabled: false, next: nil)
        let items = DesktopBoard.build(tasks: [daily, soon, off], live: [], paused: false, sessions: [
            session("a", .waiting, wait: .turnEnd, ago: 30, summary: "在 amber-macos 实现定时任务"),
            session("b", .running, ago: 10, summary: "长句", generated: "Amber 定时任务"),
            session("c", .stopped, ago: 8 * 86_400),
            session("d", .completed, ago: 120),
        ], now: now)

        XCTAssertEqual(items.map(\.column), [.needsYou, .running, .scheduled, .scheduled, .done, .done, .done])
        XCTAssertEqual(items[0].title, "在 amber-macos 实现定时任务")
        XCTAssertTrue(items[0].waitingForReply)
        XCTAssertEqual(items[1].title, "Amber 定时任务", "a written title wins over the first prompt")
        XCTAssertEqual(items.filter { $0.column == .scheduled }.map(\.title), ["周报", "每日汇总"], "soonest first; disabled tasks are not scheduled")
        let done = items.filter { $0.column == .done }
        XCTAssertEqual(done.map(\.title), ["mi", "每日汇总", "每日汇总"], "newest first; skipped and >7 day items dropped")
        XCTAssertEqual(done[1].detail, "新增 3 个文件")
        XCTAssertTrue(done[2].failed)
    }

    func testLiveRunWaitingOnApprovalNeedsYouAndCarriesTheAnswerKey() {
        let daily = task("每日汇总")
        let approval = DesktopToolApproval(id: "call-1", name: "terminal_exec", arguments: "{\n \"command\": \"ls\"\n}", reason: "")
        let conversation = UUID()
        var items = DesktopBoard.build(tasks: [daily], live: [.init(taskID: daily.id, sessionKey: "amber:r1", approval: approval, conversationID: conversation)],
            paused: false, sessions: [], now: now)
        XCTAssertEqual(items.map(\.column), [.needsYou], "a running task is not also listed as scheduled")
        XCTAssertEqual(items[0].approval?.sessionKey, "amber:r1")
        XCTAssertEqual(items[0].approval?.highRisk, true)
        XCTAssertEqual(items[0].approval?.detail, "{ \"command\": \"ls\" }")
        XCTAssertEqual(items[0].conversationId, conversation.uuidString)

        items = DesktopBoard.build(tasks: [daily], live: [.init(taskID: daily.id, sessionKey: nil, approval: approval, conversationID: nil)],
            paused: false, sessions: [], now: now)
        XCTAssertEqual(items[0].column, .needsYou)
        XCTAssertNil(items[0].approval, "without a gateway session the phone cannot answer it")

        items = DesktopBoard.build(tasks: [daily], live: [.init(taskID: daily.id, sessionKey: "amber:r1", approval: nil, conversationID: nil)],
            paused: false, sessions: [], now: now)
        XCTAssertEqual(items.map(\.column), [.running])
    }

    func testRunsPerTaskCapPausedStateAndAmberSessionsAreNotDoubled() {
        var daily = task("每日汇总")
        daily.recentRuns = (1...6).map { run(.completed, ago: TimeInterval($0) * 600) }
        let items = DesktopBoard.build(tasks: [daily], live: [], paused: true,
            sessions: [session("r1", .running, agent: .amber)], now: now)
        XCTAssertEqual(items.filter { $0.column == .done }.count, DesktopBoard.runsPerTask)
        let scheduled = items.first { $0.column == .scheduled }
        XCTAssertNil(scheduled?.nextRunAt)
        XCTAssertTrue(scheduled?.detail.hasSuffix("已暂停") == true)
        XCTAssertFalse(items.contains { $0.kind == .agentSession }, "Amber's own runs come from the scheduler, not the gateway registry")
    }
}
