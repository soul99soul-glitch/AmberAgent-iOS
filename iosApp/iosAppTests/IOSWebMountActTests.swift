import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountActTests: IOSWebMountToolTestCase {

    // MARK: - wm_act 批量动作

    /// wm_act 逐步递归走单动作派发管道：每步注入的是宿主取的**最新**
    /// snapshot_id（批量内 revision 必然推进，绑计划时点会全部 stale）。
    func testWebMountActRunsStepsSeriallyWithFreshSnapshots() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-serial")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act", conversationId: "conversation-act")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        var dispatchedSnapshots: [String] = []
        runtime.interactResultProvider = { method, _, _, options in
            if let snap = options["snapshot_id"] as? String { dispatchedSnapshots.append(snap) }
            return nil
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "click", "target": "wm:act-serial:1"],
                    ["action": "scroll", "by_y": 600],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["executed"] as? Int, 2)
        XCTAssertEqual(result["total"] as? Int, 2)
        XCTAssertEqual(runtime.interactionCallCount, 2)
        XCTAssertEqual(
            dispatchedSnapshots, ["mock-document:0", "mock-document:1"],
            "每步绑定执行时点最新快照而非批量起始快照：\(dispatchedSnapshots)"
        )
        XCTAssertEqual((result["final"] as? [String: Any])?["document_id"] as? String, "mock-document")
    }

    /// find 步的首个匹配 ref 自动喂给缺省 target 的后续步——
    /// [find "More", click] 链是 wm_act 的设计目标。
    func testWebMountActFindFeedsTargetlessClick() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-find")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-find", conversationId: "conversation-act-find")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, text, _ in
            guard method == "find" else { return nil }
            return [
                "ok": true, "found": true, "count": 1, "verified": true,
                "matches": [["ref": "wm:act-find:9", "tag": "a", "role": "link", "name": "More"]],
            ]
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "find", "text": "More"],
                    ["action": "click"],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["executed"] as? Int, 2)
        XCTAssertEqual(runtime.lastInteraction?.method, "click")
        XCTAssertEqual(runtime.lastInteraction?.selector, "wm:act-find:9", "find 产出的 ref 应注入缺省 target 的 click")
    }

    /// 导航熔断：第一步点击触发 document 变换后，已枚举 ref 全部失效，
    /// 剩余步骤不再派发。
    func testWebMountActAbortsRemainingStepsOnNavigation() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-nav")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-nav", conversationId: "conversation-act-nav")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, _, _ in
            if method == "click" { runtime.documentId = "navigated-document" }
            return nil
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "click", "target": "wm:act-nav:1"],
                    ["action": "click", "target": "wm:act-nav:2"],
                    ["action": "click", "target": "wm:act-nav:3"],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(runtime.interactionCallCount, 1, "导航后剩余步骤不得派发")
        let aborted = try XCTUnwrap(result["aborted"] as? [String: Any])
        XCTAssertEqual(aborted["error_code"] as? String, "page_navigated")
        XCTAssertEqual(aborted["index"] as? Int, 0)
        XCTAssertEqual(result["may_have_applied"] as? Bool, true, "导航步已派发——页面可能已变")
        XCTAssertEqual(result["executed"] as? Int, 1, "中止针对后续步：已跑完的导航步仍计入 executed")
    }

    /// F1 回归：verified 变更步触发导航熔断时，may_have_applied 仍必须为
    /// true——该步确实派发了副作用，verified 不代表"没动过页面"。
    func testWebMountActVerifiedNavigationStillReportsMayHaveApplied() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-verified-nav")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-vnav", conversationId: "conversation-vnav")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, _, _ in
            if method == "select" {
                runtime.documentId = "post-select-document"
                return ["ok": true, "method": "select", "verified": true]
            }
            return nil
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "select", "target": "wm:act-verified-nav:1", "option": "x"],
                    ["action": "click", "target": "wm:act-verified-nav:2"],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual((result["aborted"] as? [String: Any])?["error_code"] as? String, "page_navigated")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true,
                       "verified 的 select 已派发——may_have_applied 不得漏计")
        XCTAssertEqual(result["executed"] as? Int, 1)
    }

    /// F2 回归：批量内 unknown_after_action 必须把 status 顶到顶层——
    /// 宿主 isWebMountInterruptedOutcome 只认顶层 status+may_have_applied，
    /// 缺了它模型循环会继续而不是进入结果未知终态。
    func testWebMountActUnknownStepSurfacesInterruptedOutcome() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-unknown")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-unknown", conversationId: "conversation-unknown")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        // 走真实 unknown 路径：派发途中用户接管控制权 → 内层产出
        // status=unknown_after_action + may_have_applied=true。
        runtime.suspendsInteraction = true
        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_act",
                input: IOSWebMountController.json([
                    "session_id": runtime.snapshot.sessionId,
                    "snapshot_id": "mock-document:0",
                    "steps": [
                        ["action": "click", "target": "wm:act-unknown:1"],
                        ["action": "scroll"],
                    ],
                ]),
                isUserInitiated: false,
                context: context
            )
        }
        while runtime.interactionContinuation == nil { await Task.yield() }
        _ = try controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        runtime.resumeInteraction()
        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action",
                       "顶层 status 必须透出，宿主的中断终态检测器才接得住")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual((result["aborted"] as? [String: Any])?["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(runtime.interactionCallCount, 1)
    }

    /// F4 回归：wait 的变更类条件需要 before_* 基线——宿主按上一步页面
    /// 状态注入，不再缺省 missing_wait_baseline。
    func testWebMountActWaitGetsBaselineFromEpoch() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-wait")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-wait", conversationId: "conversation-wait")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        var waitOptions: [String: Any]?
        runtime.interactResultProvider = { method, _, _, options in
            if method == "wait" { waitOptions = options }
            return nil
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "click", "target": "wm:act-wait:1"],
                    ["action": "wait", "condition": "url_changed", "timeout_ms": 100],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        let options = try XCTUnwrap(waitOptions, "wait 步应被派发：\(result)")
        XCTAssertEqual(options["before_document_id"] as? String, "mock-document")
        XCTAssertNotNil(options["before_url"], "before_url 必须按纪元注入")
    }

    /// F5 回归：用户发起且未传 session_id 时，批量钉在解析时点的会话上——
    /// resolvedSessionId 逐步注入，结构上保证不跟随中途的当前会话切换。
    func testWebMountActPinsResolvedSessionForUserCalls() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-pinned")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: true,
            context: nil
        )
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "steps": [["action": "scroll"], ["action": "scroll"]],
            ]),
            isUserInitiated: true,
            context: nil
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["session_id"] as? String, runtime.snapshot.sessionId,
                       "批量与输出必须钉在解析出的会话上")
        XCTAssertEqual(runtime.interactionCallCount, 2)
    }

    /// find 未命中 → 依赖它的后续步不再派发。
    func testWebMountActFindNotFoundAbortsBatch() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-miss")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-miss", conversationId: "conversation-act-miss")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, _, _ in
            guard method == "find" else { return nil }
            return ["ok": true, "found": false, "count": 0, "matches": [], "verified": false]
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "find", "text": "Missing"],
                    ["action": "click"],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual((result["aborted"] as? [String: Any])?["error_code"] as? String, "target_not_found")
        XCTAssertEqual(runtime.interactionCallCount, 1, "click 不得在未命中后派发")
    }

    /// 高后果步触发本地闸门：needs_user_action 原样透出并终止批量。
    func testWebMountActPropagatesUserActionGate() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-gate")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-gate", conversationId: "conversation-act-gate")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, _, _ in
            guard method == "click" else { return nil }
            return [
                "ok": true, "needs_user_action": true,
                "error_code": "high_consequence_requires_approval",
                "reason": "This WebMount action requires explicit foreground approval.",
                "target_ref": "wm:act-gate:1",
            ]
        }
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [
                    ["action": "click", "target": "wm:act-gate:1"],
                    ["action": "scroll"],
                ],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, false)
        let aborted = try XCTUnwrap(result["aborted"] as? [String: Any])
        XCTAssertEqual(aborted["needs_user_action"] as? Bool, true)
        XCTAssertEqual(aborted["error_code"] as? String, "high_consequence_requires_approval")
        XCTAssertEqual(runtime.interactionCallCount, 1)
        // Gate details stay in the result so the caller can retry this step alone.
        XCTAssertEqual(result["needs_user_action"] as? Bool, true)
        XCTAssertEqual(result["error_code"] as? String, "high_consequence_requires_approval")
        XCTAssertEqual(result["target_ref"] as? String, "wm:act-gate:1")
        XCTAssertNotNil(result["retry_hint"], "应提示以单工具调用重发该步走审批流")

        let executor = makeExecutor(webMountController: controller)
        let currentSnapshot = try await runtime.state()["snapshot_id"] as? String ?? ""
        let request = executor.executionRequest(
            toolName: "wm_act",
            operation: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": currentSnapshot,
                "steps": [["action": "click", "target": "wm:act-gate:1"]]
            ]),
            isUserInitiated: true,
            runId: "run-act-gate",
            conversationId: "conversation-act-gate"
        )
        guard case .webMountResult(let batchOutput) = await executor.execute(request) else {
            return XCTFail("Batch gate must return its partial result instead of an approval that replays the batch")
        }
        let batch = try jsonObject(batchOutput)
        XCTAssertEqual(batch["error_code"] as? String, "high_consequence_requires_approval")
        XCTAssertEqual(batch["needs_user_action"] as? Bool, true)
    }

    /// P1-1 回归：批量内 requires_human 步触发真实控制权移交后，审批卡的
    /// 「完成并继续」走 completeWebMountHumanHandoff——wm_act 必须在白名单内，
    /// 否则交接永远无法完成（死局）。
    func testWebMountActHumanHandoffCompletesViaWhitelist() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-handoff")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-handoff", conversationId: "conversation-act-handoff")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.interactResultProvider = { method, _, _, _ in
            guard method == "type" else { return nil }
            return [
                "ok": true, "requires_human": true,
                "error_code": "sensitive_field_requires_human",
                "reason": "Sensitive field requires human input.",
                "target_ref": "wm:act-handoff:1",
            ]
        }
        let actInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": "mock-document:0",
            "steps": [
                ["action": "type", "target": "wm:act-handoff:1", "text": "4111"],
                ["action": "scroll"],
            ],
        ])
        let result = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: actInput,
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["requires_human"] as? Bool, true, "requires_human 必须顶到顶层")
        XCTAssertEqual(runtime.interactionCallCount, 1, "scroll 不得在交接后派发")

        // 控制权已真实移交用户（agent invocation 的 handoffToUser 路径）。
        let record = try XCTUnwrap(controller.sessionStore.record(sessionId: runtime.snapshot.sessionId))
        XCTAssertEqual(record.controlOwner, .user)
        // 白名单含 wm_act：交接待处理 + 完成路径都必须可达。
        let executor = makeExecutor(webMountController: controller)
        XCTAssertTrue(executor.webMountHandoffIsPending(toolName: "wm_act", input: actInput))
        XCTAssertTrue(executor.completeWebMountHumanHandoff(
            toolName: "wm_act", input: actInput, runId: "run-act-handoff"
        ), "wm_act 交接必须可完成，否则审批卡死局")
        XCTAssertEqual(controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner, .agent)
    }

    /// 契约：agent 批量必须有顶层 snapshot_id；步骤数与动作白名单有界。
    func testWebMountActContractGates() async throws {
        let runtime = MockWebMountRuntime(sessionId: "act-contract")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-act-contract", conversationId: "conversation-act-contract")
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        let missingSnapshot = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "steps": [["action": "scroll"]],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(missingSnapshot["error_code"] as? String, "snapshot_required")
        XCTAssertEqual(runtime.interactionCallCount, 0)

        let tooMany = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": (0..<9).map { _ in ["action": "scroll"] },
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(tooMany["error_code"] as? String, "too_many_steps")

        let unknownAction = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": [["action": "eval"], ["action": "scroll"]],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(unknownAction["ok"] as? Bool, false)
        XCTAssertEqual((unknownAction["aborted"] as? [String: Any])?["error_code"] as? String, "unsupported_step_action")
        XCTAssertEqual(runtime.interactionCallCount, 0, "eval 等非白名单动作不得派发")

        // 非字典步让整个 steps cast 失败 → 顶层 steps_required 拒收。
        let nonDictStep = try jsonObject(await controller.execute(
            toolName: "wm_act",
            input: IOSWebMountController.json([
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": "mock-document:0",
                "steps": ["x"],
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(nonDictStep["ok"] as? Bool, false)
        XCTAssertEqual(nonDictStep["error_code"] as? String, "steps_required")
        XCTAssertEqual(nonDictStep["denied"] as? Bool, true)
        XCTAssertEqual(runtime.interactionCallCount, 0)
    }

}
