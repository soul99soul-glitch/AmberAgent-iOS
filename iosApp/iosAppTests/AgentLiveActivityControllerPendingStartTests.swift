import ActivityKit
import XCTest
@testable import iosApp

/// 覆盖 `AgentLiveActivityController.resolvePendingStart` 在途窗口内的三种收尾：
/// 只保留最后一次展示、被撤销后立即结束、撤销又重新 start 后保留所有权。
///
/// 与 `AgentActivityDeepLinkTests` 里同类测试不同，这里不触达真实 ActivityKit、
/// 不需要 `XCTSkipUnless(applicationState == .active)`：授权查询/枚举与
/// `Activity.request` 都通过 `AgentLiveActivityController.init` 的注入点替换成
/// 可手动放行的替身,详见 `AgentLiveActivityController.swift` 里的
/// `SystemSnapshotFetcher` / `SystemCardRequester` / `SystemCardHandle`。
@MainActor
final class AgentLiveActivityControllerPendingStartTests: XCTestCase {
    /// 让测试手动控制「系统快照」这一步何时返回：`waitUntilEntered()` 确认
    /// `resolvePendingStart` 真的已经挂起在这一步（而不是还没被调度），随后测试
    /// 才能安全地在“在途”窗口内调用 update/end/start；`release()` 放行落地。
    private actor PendingGate {
        private var isReleased = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?

        func markEntered() {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func waitForRelease() async {
            if isReleased { return }
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func release() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// 记录系统卡片实际收到的调用：request 的初始展示、update 的展示、end 的
    /// 展示，全部按发生顺序追加到 `deliveredPresentations`，方便断言「最终收到
    /// 的是最后一次展示」而不必关心具体走的是 request 初始内容还是后续 update。
    @MainActor
    private final class CardRecorder {
        private(set) var deliveredPresentations: [AgentActivityPresentation] = []
        private(set) var endCalls: [(presentation: AgentActivityPresentation, dismissalDelay: TimeInterval)] = []
        private(set) var requestCount = 0
        var activityState: ActivityState = .active

        func recordRequest(_ presentation: AgentActivityPresentation) {
            requestCount += 1
            deliveredPresentations.append(presentation)
        }

        func recordUpdate(_ presentation: AgentActivityPresentation) {
            deliveredPresentations.append(presentation)
        }

        func recordEnd(_ presentation: AgentActivityPresentation, dismissalDelay: TimeInterval) {
            deliveredPresentations.append(presentation)
            endCalls.append((presentation, dismissalDelay))
        }
    }

    private func makeController(
        gate: PendingGate,
        recorder: CardRecorder,
        terminalLinger: @escaping (TimeInterval) async -> Void = { _ in },
        lingerAllowance: @escaping @MainActor () -> TimeInterval = { .infinity },
        heartbeatSleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        beforeDelivery: @escaping @MainActor (AgentActivityPresentation) async -> Void = { _ in }
    ) -> AgentLiveActivityController {
        AgentLiveActivityController(
            fetchSystemSnapshot: {
                await gate.markEntered()
                await gate.waitForRelease()
                return AgentLiveActivityController.ActivitySystemSnapshot(enabled: true, activities: [])
            },
            requestSystemCard: { runId, _, _, presentation in
                recorder.recordRequest(presentation)
                return AgentLiveActivityController.SystemCardHandle(
                    id: "fake-\(runId)",
                    activityState: { recorder.activityState },
                    currentPresentation: { presentation },
                    currentUpdatedAt: { Date() },
                    performUpdate: { content in
                        await beforeDelivery(content.state.presentation)
                        recorder.recordUpdate(content.state.presentation)
                    },
                    performEnd: { presentation, dismissalDelay in
                        recorder.recordEnd(presentation, dismissalDelay: dismissalDelay)
                    }
                )
            },
            terminalLinger: terminalLinger,
            lingerAllowance: lingerAllowance,
            heartbeatSleep: heartbeatSleep
        )
    }

    /// 轮询直到 `condition` 成立或超时；`resolvePendingStart` 落地发生在一个
    /// 测试不持有引用的独立 Task 里，只能靠观察副作用来确认它跑完了。
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // a) start → 在途期间 update 两次 → 放行落地 → 系统卡片最终收到最后一次展示。
    func testInFlightUpdatesOnlyDeliverTheLatestPresentationOnLanding() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"

        controller.start(
            runId: runId,
            conversationId: "conv-1",
            presentation: .response(stage: .generating)
        )
        await gate.waitUntilEntered()

        // 在途期间：这两次 update 只应刷新 pending 展示，不发起第二次请求。
        await controller.update(runId: runId, presentation: .response(stage: .runningTool), force: true)
        await controller.update(runId: runId, presentation: .response(stage: .organizing), force: true)

        await gate.release()
        await waitUntil { recorder.deliveredPresentations.last?.stage == .organizing }

        XCTAssertEqual(recorder.requestCount, 1, "在途期间的 update 不应触发额外的系统请求")
        XCTAssertEqual(recorder.deliveredPresentations.last?.stage, .organizing)
        XCTAssertTrue(controller.ownsActivity(runId: runId, conversationId: "conv-1"))
    }

    // b) start → 在途期间 end → 放行落地 → 刚创建的卡片立即被结束，ownsActivity 为 false。
    func testInFlightEndImmediatelyEndsTheJustLandedCard() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"

        controller.start(
            runId: runId,
            conversationId: "conv-1",
            presentation: .response(stage: .generating)
        )
        await gate.waitUntilEntered()

        await controller.end(runId: runId, presentation: .failed())

        await gate.release()
        await waitUntil { !recorder.endCalls.isEmpty }

        XCTAssertEqual(recorder.requestCount, 1, "撤销发生在在途期间，仍应先落地再立即结束，而不是跳过请求")
        XCTAssertEqual(recorder.endCalls.count, 1)
        XCTAssertFalse(controller.ownsActivity(runId: runId, conversationId: "conv-1"))
    }

    // c) start → 在途期间 end → 同一 runId 再 start → 放行落地 → 卡片保留，ownsActivity 为 true。
    func testRestartDuringInFlightEndCancelsTheRevocation() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"

        controller.start(
            runId: runId,
            conversationId: "conv-1",
            presentation: .response(stage: .generating)
        )
        await gate.waitUntilEntered()

        await controller.end(runId: runId, presentation: .failed())
        // 同一 runId 在同一在途窗口内重新 start：应清除刚记录的撤销，不发起
        // 第二次系统请求（仍然只有一次 pendingStart 在途）。
        controller.start(
            runId: runId,
            conversationId: "conv-1",
            presentation: .response(stage: .generating)
        )

        await gate.release()
        await waitUntil { recorder.requestCount >= 1 }
        // 给 resolvePendingStart 的收尾逻辑留出完成窗口（无撤销、展示相同时不会
        // 再触发 update，函数本身应已跑完；仍以小的settle余量保持稳妥）。
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.requestCount, 1, "在途期间的第二次 start 不应重复发起系统请求")
        XCTAssertTrue(recorder.endCalls.isEmpty, "撤销已被同一在途窗口内的重新 start 取消，卡片不应被结束")
        XCTAssertTrue(controller.ownsActivity(runId: runId, conversationId: "conv-1"))
    }

    // d) 同一步骤持续输出时续期过期时间：满间隔才用原状态重发一次，
    //    非运行态（如待确认）不续期，避免把卡住或等人的任务伪装成运行中。
    func testProgressRefreshesStaleDateOnlyWhileRunningAndAtMostOncePerInterval() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"
        let running = AgentActivityPresentation.response(stage: .generating)

        controller.start(runId: runId, conversationId: "conv-1", presentation: running)
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        // requestCount 在落地前自增；再留出 resolvePendingStart 把卡片登记为已拥有的窗口。
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveredPresentations.count, 1)

        let interval = AgentActivityLifecyclePolicy.progressRefreshInterval
        XCTAssertLessThan(
            interval,
            AgentActivityLifecyclePolicy.staleDate(for: .running, now: Date())!.timeIntervalSinceNow,
            "续期间隔必须短于过期时长，否则持续输出时仍会被判过期"
        )

        controller.noteProgress(runId: runId, now: Date().addingTimeInterval(interval / 2))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveredPresentations.count, 1, "未满间隔不应重发")

        let due = Date().addingTimeInterval(interval + 1)
        controller.noteProgress(runId: runId, now: due)
        controller.noteProgress(runId: runId, now: due)
        await waitUntil { recorder.deliveredPresentations.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveredPresentations, [running, running], "同一时刻多次进展只续期一次")

        await controller.update(runId: runId, presentation: .waitingForUser(), force: true)
        controller.noteProgress(runId: runId, now: Date().addingTimeInterval(interval * 5))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveredPresentations.last, .waitingForUser())
        XCTAssertEqual(recorder.deliveredPresentations.count, 3, "待确认不因输出续期")
    }

    // e) 续期在途时状态已被真实更新替换：迟到的续期不得把旧状态盖回去。
    func testProgressRefreshNeverOverwritesANewerPresentation() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .thinking))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        // requestCount 在落地前自增；再留出 resolvePendingStart 把卡片登记为已拥有的窗口。
        try? await Task.sleep(for: .milliseconds(50))

        controller.noteProgress(
            runId: runId,
            now: Date().addingTimeInterval(AgentActivityLifecyclePolicy.progressRefreshInterval + 1)
        )
        await controller.update(runId: runId, presentation: .response(stage: .generating), force: true)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.deliveredPresentations.last?.stage, .generating)
    }

    // f) 后台续跑路径在锁内节流，逐 chunk 调用也只在满间隔时放行一次。
    func testBackgroundRunStateThrottlesProgressHeartbeat() {
        let state = IOSChatBackgroundRunState()
        let start = Date()
        let interval = AgentActivityLifecyclePolicy.progressRefreshInterval

        XCTAssertTrue(state.noteVisibleDelta(at: start), "首个可见输出即可续期")
        XCTAssertFalse(state.noteVisibleDelta(at: start.addingTimeInterval(1)))
        XCTAssertFalse(state.noteVisibleDelta(at: start.addingTimeInterval(interval - 1)))
        XCTAssertTrue(state.noteVisibleDelta(at: start.addingTimeInterval(interval)))
        XCTAssertFalse(state.noteVisibleDelta(at: start.addingTimeInterval(interval + 1)))
    }

    // g) 完成/失败先在灵动岛上停留：先更新成终态，停留结束后才 end；
    //    调用方不等待停留，所有权立即释放。取消没有停留，直接 end。
    func testCompletionLingersOnTheIslandBeforeEnding() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let linger = PendingGate()
        var requestedLinger: TimeInterval?
        let controller = makeController(gate: gate, recorder: recorder) { seconds in
            requestedLinger = seconds
            await linger.markEntered()
            await linger.waitForRelease()
        }
        let runId = "run-\(UUID().uuidString)"

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .generating))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        await controller.update(runId: runId, presentation: .runningTool(toolName: "search_web"), force: true)

        await controller.end(runId: runId, presentation: .completed())
        await linger.waitUntilEntered()

        XCTAssertEqual(recorder.deliveredPresentations.last?.phase, .completed, "结束前先把岛更新成已完成")
        XCTAssertEqual(
            recorder.deliveredPresentations.last?.recentSteps?.map(\.stage),
            [.searching],
            "完成卡片带上这次做过的步骤，底部不留空"
        )
        XCTAssertTrue(recorder.endCalls.isEmpty, "停留期间不得结束")
        XCTAssertEqual(requestedLinger, AgentActivityLifecyclePolicy.islandLingerDuration(for: .completed))
        XCTAssertFalse(controller.ownsActivity(runId: runId, conversationId: "conv-1"))

        await linger.release()
        await waitUntil { !recorder.endCalls.isEmpty }
        XCTAssertEqual(recorder.endCalls.map(\.presentation.phase), [.completed])
    }

    func testCancellationEndsWithoutLingering() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        var lingered = false
        let controller = makeController(gate: gate, recorder: recorder) { _ in lingered = true }
        let runId = "run-\(UUID().uuidString)"

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .generating))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))

        await controller.end(runId: runId, presentation: .cancelled())

        XCTAssertFalse(lingered)
        XCTAssertEqual(recorder.endCalls.map(\.presentation.phase), [.cancelled])
        XCTAssertEqual(recorder.deliveredPresentations.count, 2, "取消不额外发一次终态更新")
    }

    // h) 步骤切换时由控制器记录最近两步，随更新一起送到系统卡片。
    func testUpdatesCarryTheRecentFinishedSteps() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder)
        let runId = "run-\(UUID().uuidString)"

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .thinking))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))

        await controller.update(runId: runId, presentation: .runningTool(toolName: "search_web"), force: true)
        await controller.update(runId: runId, presentation: .response(stage: .generating), force: true)

        XCTAssertEqual(recorder.deliveredPresentations.last?.stage, .generating)
        XCTAssertEqual(
            recorder.deliveredPresentations.last?.recentSteps?.map(\.stage),
            [.searching],
            "思考不进历史，只记录工具步骤"
        )
    }

    // i) 停留期间开始新任务：上一张卡立即以原终态收起，不与新卡并存。
    func testStartingANewRunEndsTheLingeringCardImmediately() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let linger = PendingGate()
        let controller = makeController(gate: gate, recorder: recorder) { _ in
            await linger.markEntered()
            await linger.waitForRelease()
        }
        let first = "run-\(UUID().uuidString)"

        controller.start(runId: first, conversationId: "conv-1", presentation: .response(stage: .generating))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        await controller.end(runId: first, presentation: .completed())
        await linger.waitUntilEntered()
        XCTAssertTrue(recorder.endCalls.isEmpty)

        controller.start(runId: "run-\(UUID().uuidString)", conversationId: "conv-1", presentation: .response(stage: .thinking))
        await waitUntil { !recorder.endCalls.isEmpty }
        XCTAssertEqual(recorder.endCalls.map(\.presentation.phase), [.completed])

        await linger.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.endCalls.count, 1, "停留任务醒来后不得再结束一次")
    }

    // j) 没有可用的停留时间（前台或后台时间不足）：直接结束，不先更新终态。
    func testNoLingerWhenThereIsNoAllowance() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        var lingered = false
        let controller = makeController(
            gate: gate,
            recorder: recorder,
            terminalLinger: { _ in lingered = true },
            lingerAllowance: { 0 }
        )
        let runId = "run-\(UUID().uuidString)"

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .generating))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        await controller.end(runId: runId, presentation: .completed())

        XCTAssertFalse(lingered)
        XCTAssertEqual(recorder.endCalls.map(\.presentation.phase), [.completed])
        XCTAssertEqual(recorder.deliveredPresentations.count, 2)
    }

    // k) 静默的工具步骤由心跳续期；步骤换成非工具后心跳退出。
    // l) 旧更新发送得慢、新更新随后发出：系统卡片必须按调用顺序收到，最后停在新状态。
    //    ActivityKit 的 update 并发执行，不串行时旧的"读网页"会晚到并盖掉"生成"。
    func testSlowEarlierUpdateNeverLandsAfterANewerOne() async {
        let gate = PendingGate()
        let slowSend = PendingGate()
        let recorder = CardRecorder()
        let controller = makeController(gate: gate, recorder: recorder, beforeDelivery: { presentation in
            guard presentation.stage == .readingWeb else { return }
            await slowSend.markEntered()
            await slowSend.waitForRelease()
        })
        let runId = "run-\(UUID().uuidString)"
        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .preparing))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))

        Task { await controller.update(runId: runId, presentation: .runningTool(toolName: "scrape_web"), force: true) }
        await slowSend.waitUntilEntered()
        Task { await controller.update(runId: runId, presentation: .response(stage: .generating), force: true) }
        try? await Task.sleep(for: .milliseconds(50))
        await slowSend.release()
        await waitUntil { recorder.deliveredPresentations.count >= 3 }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.deliveredPresentations.map(\.stage), [.preparing, .readingWeb, .generating])
    }

    func testSilentToolStepIsKeptFreshByHeartbeat() async {
        let gate = PendingGate()
        let recorder = CardRecorder()
        let beat = PendingGate()
        let controller = makeController(gate: gate, recorder: recorder, heartbeatSleep: { _ in
            await beat.markEntered()
            await beat.waitForRelease()
        })
        let runId = "run-\(UUID().uuidString)"
        let tool = AgentActivityPresentation.runningTool(toolName: "generate_image")

        controller.start(runId: runId, conversationId: "conv-1", presentation: .response(stage: .thinking))
        await gate.release()
        await waitUntil { recorder.requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        await controller.update(runId: runId, presentation: tool, force: true)
        await beat.waitUntilEntered()
        let before = recorder.deliveredPresentations.count

        // 心跳醒来时距上次更新不足间隔 → noteProgress 不重发；这里只验证心跳在工具步骤期间运行、
        // 且只在仍是工具步骤时续期（间隔判定由 noteProgress 的测试覆盖）。
        await controller.update(runId: runId, presentation: .response(stage: .generating), force: true)
        await beat.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveredPresentations.count, before + 1, "步骤离开工具后心跳不再续期")
        XCTAssertEqual(recorder.deliveredPresentations.last?.stage, .generating)
    }
}
