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
        recorder: CardRecorder
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
                    performUpdate: { content in recorder.recordUpdate(content.state.presentation) },
                    performEnd: { presentation, dismissalDelay in
                        recorder.recordEnd(presentation, dismissalDelay: dismissalDelay)
                    }
                )
            }
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
        await waitUntil { recorder.deliveredPresentations.last == .response(stage: .organizing) }

        XCTAssertEqual(recorder.requestCount, 1, "在途期间的 update 不应触发额外的系统请求")
        XCTAssertEqual(recorder.deliveredPresentations.last, .response(stage: .organizing))
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
}
