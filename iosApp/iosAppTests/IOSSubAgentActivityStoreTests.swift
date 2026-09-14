import XCTest
@testable import iosApp

@MainActor
final class IOSSubAgentActivityStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let launch = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        super.setUp()
        suite = "IOSSubAgentActivityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func activity(
        task: String = "child", execution: String = "run1", source: String = "source-a",
        status: IOSAdvancedTaskStatus = .running, start: TimeInterval = 1_001,
        end: TimeInterval? = nil
    ) -> IOSSubAgentActivity {
        IOSSubAgentActivity(
            id: execution, taskId: task, title: "核查接口", avatarIdentity: "dynamic:review",
            sourceConversationId: source, status: status,
            startedAt: Date(timeIntervalSince1970: start),
            endedAt: end.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func store(launch: Date? = nil) -> IOSSubAgentActivityStore {
        let model = IOSSubAgentActivityStore(
            tasks: IOSAdvancedTaskStore(userDefaults: defaults), defaults: defaults,
            launchedAt: launch ?? self.launch, loadRuns: { [] }
        )
        model.autoDismissDelay = .never
        return model
    }

    func testGlobalProjectionRetainsBothSourcesAndOnlyDismissesTerminals() {
        let model = store()
        let active = activity()
        let waiting = activity(task: "other", execution: "run2", source: "source-b", status: .approvalRequired)
        model.reconcile([active, waiting])
        XCTAssertEqual(Set(model.items.compactMap(\.sourceConversationId)), ["source-a", "source-b"])
        model.dismiss(active.id)
        model.dismiss(waiting.id)
        XCTAssertEqual(model.items.count, 2)
        let done = activity(status: .completed, end: 1_020)
        model.reconcile([done, waiting])
        model.reconcile([waiting])
        XCTAssertTrue(model.items.contains { $0.id == done.id }, "终态不因离开来源会话或下一次快照缺失而消失")
        model.dismiss(done.id)
        model.reconcile([done, waiting])
        XCTAssertEqual(model.items.map(\.id), [waiting.id])
    }

    func testDismissDoesNotMutateTaskOrResultAndSameIDReactivationReappears() async throws {
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let first = tasks.startTask(
            id: "reusable", kind: .subAgent, title: "review", objective: "private task body",
            metadata: ["execution_id": "first", "execution_started_at": "1001", "role_name": "review"],
            now: Date(timeIntervalSince1970: 1_001)
        )
        tasks.updateTask(id: first.id, status: .completed, resultSummary: "mailbox result", now: Date(timeIntervalSince1970: 1_020))
        let model = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: launch, loadRuns: { [] })
        model.autoDismissDelay = .never
        await model.refresh()
        let shown = try XCTUnwrap(model.items.first)
        let stored = tasks.task(id: first.id)
        model.dismiss(shown.id)
        XCTAssertEqual(tasks.task(id: first.id), stored)
        tasks.updateTask(id: first.id, status: .running, metadata: ["execution_id": "second", "execution_started_at": "1100"], now: Date(timeIntervalSince1970: 1_100))
        await model.refresh()
        let resumed = try XCTUnwrap(model.items.first)
        XCTAssertNotEqual(resumed.id, shown.id)
        XCTAssertEqual(resumed.startedAt.timeIntervalSince1970, 1_100)
        XCTAssertEqual(tasks.task(id: first.id)?.createdAt, first.createdAt)
    }

    func testFirstObservationCanBeTerminalWithoutImportingOldHistory() {
        let model = store()
        let old = activity(task: "old", execution: "old", status: .completed, start: 100, end: 101)
        let instant = activity(status: .completed, start: 1_001, end: 1_001.01)
        model.reconcile([old, instant])
        XCTAssertEqual(model.items.map(\.id), [instant.id])
        XCTAssertEqual(model.items[0].elapsed(at: Date(timeIntervalSince1970: 9_999)), 0.01, accuracy: 0.001)
        let continued = activity(execution: "next", start: 1_002)
        model.reconcile([instant, continued])
        XCTAssertEqual(Set(model.items.map(\.id)), [instant.id, continued.id], "上一轮终态保留到主动收起")
    }

    func testOldRunningCannotOverwriteNewExecutionOrReviveTerminal() throws {
        let model = store()
        let first = activity()
        let second = activity(execution: "run2", start: 1_100)
        model.reconcile([first, second])
        model.reconcile([first])
        XCTAssertEqual(model.items.first?.id, second.id)
        let done = activity(execution: "run2", status: .timedOut, start: 1_100, end: 1_120)
        model.reconcile([done])
        model.reconcile([second])
        let final = try XCTUnwrap(model.items.first)
        XCTAssertEqual(final.status, .timedOut)
        XCTAssertEqual(final.elapsed(at: Date(timeIntervalSince1970: 2_000)), 20)
    }

    func testRestartKeepsOnlyExplicitlyRetainedTerminalsUntilRecovery() {
        let model = store()
        let completed = activity(status: .completed, end: 1_010)
        let active = activity(task: "active", execution: "active", start: 1_005)
        model.reconcile([completed, active])
        let relaunched = store(launch: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(relaunched.items.map(\.id), [completed.id], "缓存运行态不能当成重启后仍在执行")
        var interrupted = active
        interrupted.status = .interrupted
        interrupted.endedAt = Date(timeIntervalSince1970: 2_001)
        relaunched.reconcile([interrupted, completed])
        XCTAssertEqual(Set(relaunched.items.map(\.status)), [.interrupted, .completed])
        relaunched.dismiss(completed.id)
        let again = store(launch: Date(timeIntervalSince1970: 3_000))
        again.reconcile([completed, interrupted])
        XCTAssertEqual(again.items.map(\.id), [interrupted.id])
    }

    func testRealDurableWaitStatesRemainVisibleAndCannotBeDismissed() {
        for wire in ["created", "waiting_user", "waiting_external", "resumable", "outcome_unknown"] {
            let state = IOSSubAgentActivityStore.durableStatus(wire, reason: nil)
            XCTAssertFalse(state.0.isTerminal, wire)
        }
        for wire in ["completed", "failed", "cancelled", "timed_out", "interrupted"] {
            XCTAssertTrue(IOSSubAgentActivityStore.durableStatus(wire, reason: nil).0.isTerminal, wire)
        }
    }

    func testFloatingPreferencesPersistWithoutChangingTaskState() {
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let model = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, loadRuns: { [] })
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.autoDismissDelay, .after30Seconds)
        model.autoDismissDelay = .never
        let active = activity()
        model.reconcile([active])
        model.isEnabled = false
        XCTAssertEqual(model.items, [active], "显示开关不收起或取消运行中的任务")
        let restored = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, loadRuns: { [] })
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.autoDismissDelay, .never)
        restored.reconcile([active])
        restored.isEnabled = true
        XCTAssertEqual(restored.items, [active])
    }

    func testBulkDismissKeepsQueuedRunningAndApprovalAndDoesNotTouchRecords() async {
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let model = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: launch, loadRuns: { [] })
        model.autoDismissDelay = .never
        let statuses: [IOSAdvancedTaskStatus] = [
            .queued, .running, .approvalRequired, .completed, .failed, .cancelled, .timedOut, .interrupted
        ]
        for (index, status) in statuses.enumerated() {
            let task = tasks.startTask(kind: .subAgent, title: "测试", objective: "private objective",
                metadata: ["source_conversation_id": index.isMultiple(of: 2) ? "source-a" : "source-b"],
                now: Date(timeIntervalSince1970: 1_001))
            tasks.updateTask(id: task.id, status: status, resultSummary: "retained result",
                now: Date(timeIntervalSince1970: 1_010))
        }
        await model.refresh()
        XCTAssertEqual(model.items.count, 8)
        let records = tasks.tasks
        model.dismissAllFinished()
        await model.refresh()
        XCTAssertEqual(Set(model.items.map(\.status)), [.queued, .running, .approvalRequired])
        XCTAssertEqual(tasks.tasks, records, "批量收起只改变展示，不修改记录或回传结果")
    }

    func testConfiguredDeadlinesUseExecutionEndAndNeverDisablesExpiry() {
        var clock = launch
        let model = IOSSubAgentActivityStore(
            tasks: IOSAdvancedTaskStore(userDefaults: defaults), defaults: defaults,
            launchedAt: launch, loadRuns: { [] }, now: { clock }
        )
        for (index, delay) in [IOSSubAgentAutoDismissDelay.after15Seconds, .after30Seconds, .after1Minute].enumerated() {
            let start = 1_001.0 + Double(index) * 200
            let end = start + 100
            clock = Date(timeIntervalSince1970: end)
            model.autoDismissDelay = delay
            let done = activity(execution: "execution-\(index)", status: .completed, start: start, end: end)
            model.reconcile([done])
            clock = Date(timeIntervalSince1970: end + Double(delay.rawValue) - 0.001)
            model.rescheduleAutoDismiss()
            XCTAssertEqual(model.items.map(\.id), [done.id])
            clock = clock.addingTimeInterval(0.001)
            model.rescheduleAutoDismiss()
            model.reconcile([done])
            XCTAssertTrue(model.items.isEmpty, "\(delay.title)按本轮结束时间到期，旧终态不会重现")
        }
        clock = Date(timeIntervalSince1970: 2_000)
        let done = activity(execution: "manual", status: .failed, start: 1_999, end: 2_000)
        model.reconcile([done])
        model.autoDismissDelay = .never
        clock = clock.addingTimeInterval(3_600)
        model.rescheduleAutoDismiss()
        XCTAssertEqual(model.items.map(\.id), [done.id])
    }

    func testReadingDefersAutoDismissAndRelaunchDoesNotResetDeadlineOrHideNewExecution() {
        var clock = Date(timeIntervalSince1970: 1_020)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let model = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: launch,
            loadRuns: { [] }, now: { clock })
        model.autoDismissDelay = .after15Seconds
        let done = activity(status: .completed, end: 1_020)
        model.reconcile([done])
        model.beginViewing(done.id)
        model.beginViewing(done.id)
        clock = Date(timeIntervalSince1970: 1_040)
        model.rescheduleAutoDismiss()
        model.endViewing(done.id)
        XCTAssertEqual(model.items.map(\.id), [done.id], "任一详情仍在阅读时不自动消失")
        model.endViewing(done.id)
        XCTAssertTrue(model.items.isEmpty)

        let second = activity(execution: "second", status: .completed, start: 1_035, end: 1_040)
        model.reconcile([second])
        clock = Date(timeIntervalSince1970: 1_056)
        let relaunched = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: clock,
            loadRuns: { [] }, now: { clock })
        XCTAssertEqual(relaunched.autoDismissDelay, .after15Seconds)
        XCTAssertTrue(relaunched.items.isEmpty, "重启立即处理到期终态，不重新给一轮倒计时")
        relaunched.reconcile([activity(execution: "second", start: 1_035)])
        XCTAssertTrue(relaunched.items.isEmpty, "旧 RUNNING 不能复活已自动收起的执行")
        let next = activity(execution: "third", start: 1_057)
        relaunched.reconcile([next])
        XCTAssertEqual(relaunched.items.map(\.id), [next.id])
    }

    func testAutoDismissTimerFiresWithoutAnyChatViewOrRefresh() async throws {
        let current = Date()
        let model = IOSSubAgentActivityStore(tasks: IOSAdvancedTaskStore(userDefaults: defaults),
            defaults: defaults, launchedAt: current.addingTimeInterval(-60), loadRuns: { [] })
        model.autoDismissDelay = .after15Seconds
        model.reconcile([activity(status: .completed,
            start: current.addingTimeInterval(-20).timeIntervalSince1970,
            end: current.addingTimeInterval(-14.8).timeIntervalSince1970)])
        XCTAssertEqual(model.items.count, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(model.items.isEmpty)
    }
}
