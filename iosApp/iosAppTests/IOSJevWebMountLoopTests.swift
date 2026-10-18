import XCTest
@preconcurrency import Shared
@testable import iosApp

// off/scope → handback 零网络；shadow/dry-run 不执行动作；active 白名单动作
// 每轮重新观察，unknown 不重放，无进展或达到决策上限时 handback。
@MainActor
final class IOSJevWebMountLoopTests: IOSJevWebMountLoopTestCase {

    // MARK: Off / scope

    func testOffModeHandbackWithZeroNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .off), transport: transport,
            observe: { _ in recorder.recordObservation(); return self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(recorder.executed.isEmpty)
    }

    func testScopeNotAllowedHandback() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.selectedTaskText], for: .webActions) // 缺 webContent
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(
            settings: settings, transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback = outcome else { return XCTFail("expected handback") }
        XCTAssertEqual(transport.calls, 0)
    }

    // MARK: Dry-run / shadow 决不执行

    func testShadowProducesTrajectoryWithoutExecuting() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .shadow, pinned: nil), transport: transport,
            observe: { _ in recorder.recordObservation(); return self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(
            input(allowed: ["scroll", "click_nav"], draft: nil, maxDecisions: 4),
            runId: "run"
        )
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected decision-cap handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertFalse(steps.isEmpty, "dry-run trajectory must be produced")
        XCTAssertTrue(steps.allSatisfy { $0.hasPrefix("dry-run:") })
        XCTAssertTrue(recorder.executed.isEmpty, "shadow must never execute actions")
        XCTAssertGreaterThan(transport.calls, 0)
    }

    /// 中途降级回归：active 跑起来后配置切 shadow，之后协调器只产 observed
    /// 决策——它们只能进 dry-run 轨迹，绝不能被执行（启动时快照不得绕过
    /// 「shadow 只观测不应用」契约）。
    func testMidRunDowngradeToShadowStopsExecuting() async {
        let box = SettingsBox(makeSettings(mode: .active))
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observationCount = 0
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        let service = IOSJevWebMountLoopService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() },
            observe: { _ in
                recorder.recordObservation()
                observationCount += 1
                if observationCount == 2 {
                    box.set(self.makeSettings(mode: .shadow, pinned: nil))
                }
                return self.observation(revision: observationCount)
            },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                return .applied(newRevision: observationCount + 1)
            },
            isComplete: { _, _ in false }
        ))
        let outcome = await service.run(input(allowed: ["click_nav"], maxDecisions: 4), runId: "run")
        guard case .handback(_, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertEqual(recorder.executed.count, 1, "降级前的决策已执行一次；降级后 observed 决策不得执行")
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0.hasPrefix("dry-run:") }, "降级后轨迹只能 dry-run: \(steps)")
    }

    // MARK: Active 执行

    func testActiveExecutesWhitelistedActionAndChecksCompletion() async {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var revision = 1
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                recorder.recordObservation()
                return self.observation(revision: revision)
            },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                revision += 1
                return .applied(newRevision: revision)
            },
            isComplete: { _, obs in obs.revision >= 2 }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .completed(let steps, let final) = outcome else { return XCTFail("expected completed, got \(outcome)") }
        XCTAssertEqual(recorder.executed.count, 1)
        XCTAssertEqual(recorder.executed.first?.0, "click_nav")
        XCTAssertEqual(recorder.executed.first?.1, "e1")
        XCTAssertEqual(final?.revision, 2, "completion verified against page state, not Jev DONE")
        XCTAssertFalse(steps.isEmpty)
    }

    func testHandbackChoiceDoesNotExecuteAndItsReasonReachesToolResult() async throws {
        let transport = JevStubTransport { _ in
            (self.choicePayload("handback"), self.httpResponse(status: 200))
        }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                return .applied(newRevision: 2)
            }
        )

        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else {
            return XCTFail("expected handback, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Jev 选择 handback"))
        XCTAssertTrue(steps.isEmpty)
        XCTAssertTrue(recorder.executed.isEmpty)

        let output = IOSJevWebMountLoopService.outputText(for: outcome, goal: "在列表找目标")
        let outputObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(outputObject["status"] as? String, "handback")
        XCTAssertEqual(outputObject["reason"] as? String, reason)

        let body = try XCTUnwrap(transport.lastBody)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(request["questions"] as? [String: Any])
        let actionQuestion = try XCTUnwrap(questions["single.next_action"] as? [String: Any])
        let options = try XCTUnwrap(actionQuestion["criteria"] as? [String: Any])
        XCTAssertNotNil(options["handback"])
        XCTAssertFalse((actionQuestion["instructions"] as? String ?? "").contains("不确定时选择 scroll"))
    }

    func testStateIncludesAllElementsWithBoundedActionCandidates() async throws {
        let elements = (1...80).map {
            IOSJevWebMountLoopService.PageElement(id: "e\($0)", role: "link", label: "条目 \($0)")
        }
        let page = IOSJevWebMountLoopService.PageObservation(
            snapshotId: "snapshot-many", revision: 1,
            url: "https://example.com/list", elements: elements
        )
        let transport = JevStubTransport { _ in
            (self.choicePayload("handback"), self.httpResponse(status: 200))
        }
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in page },
            execute: { _, _ in XCTFail("handback must not execute a page action"); return .failed(reason: "unexpected") }
        )

        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback = outcome else { return XCTFail("expected handback, got \(outcome)") }
        let body = try XCTUnwrap(transport.lastBody)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(request["state"] as? String)
        let elementLines = state.components(separatedBy: "\n").filter { $0.hasPrefix("- e") }
        XCTAssertEqual(elementLines.count, 62, "63 legal choices include scroll, leaving 62 element actions plus handback")
        XCTAssertTrue(state.contains("- e62 [link]"))
        XCTAssertFalse(state.contains("- e63 [link]"), "elements without a bounded action must not appear in state")
    }

    func testUnknownExecutorResultNeverReplays() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in recorder.recordObservation(); return self.observation() },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .unknown
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .outcomeUnknown(let action, _) = outcome else { return XCTFail("expected outcomeUnknown, got \(outcome)") }
        XCTAssertTrue(action.contains("scroll"))
        XCTAssertEqual(recorder.executed.count, 1, "no replay after unknown result")
    }

    func testNoProgressTriggersHandback() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: 1) }, // revision 恒不变
            execute: { _, _ in .applied(newRevision: 1) }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxNoProgress: 3), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("无进展"))
    }

    /// 真机回归：底部空滚每次 bump page_revision，revision 比较永远算"有进展"，
    /// max_no_progress 拦不住 → 20 次决策烧干。修复后 scroll 的进展按状态指纹
    /// （url+scrollY+元素集合）判定：指纹不变 = 空转，计入无进展。
    func testScrollStallCountsNoProgressDespiteRevisionBump() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                // 模拟真机：每次观察 revision 递增，但 url/scrollY/元素完全不变（页底）。
                return self.observation(revision: observeCount)
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .applied(newRevision: observeCount + 1) // revision 递增 ≠ 进展
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 20, maxNoProgress: 3), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("无进展"), "空转滚动应计无进展，got: \(reason)")
        XCTAssertEqual(recorder.executed.count, 3, "空滚最多 maxNoProgress 次即退出，不得烧穿决策额度")
    }

    /// 对照：滚动真带来新元素（无限加载）→ 指纹变化 → 算进展，不计无进展。
    func testScrollRevealingNewElementsResetsProgress() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                obs.scrollY = observeCount * 500
                obs.elements.append(IOSJevWebMountLoopService.PageElement(id: "new\(observeCount)", role: "link", label: "新条目"))
                return obs
            },
            execute: { _, _ in .applied(newRevision: observeCount + 1) }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 4, maxNoProgress: 2), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"), "滚动持续带来新内容应按决策上限退出，got: \(reason)")
    }

    /// 滚动自动驾驶：Jev 判定滚动后，只要每段仍在推进（指纹变化），续滚
    /// 不再付决策往返——"滚到底"类任务的 Jev 调用从每段 1 次降为全程 1 次。
    func testAutoScrollChainsWithoutExtraJevCalls() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                obs.scrollY = observeCount * 700 // 每段都推进 → 指纹变化
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .applied(newRevision: observeCount + 1)
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 5), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(recorder.executed.count, 5)
        XCTAssertEqual(transport.calls, 1, "续滚免决策，只有首段由 Jev 选择")
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0.contains("auto") }, "续滚应标记 auto：\(steps)")
        XCTAssertTrue(steps.allSatisfy { $0.contains("obs=") && $0.contains("exec=") }, "每步应带分项耗时：\(steps)")
    }

    /// 自动驾驶停滞后必须回落 Jev（带页底提示）——不是无 Jev 死滚，也不是
    /// 停滞后继续自动驾驶。
    func testAutoScrollStallReturnsToJevWithHint() async throws {
        var callIndex = 0
        let answers = ["scroll", "click_nav@e1"]
        let transport = JevStubTransport { _ in
            defer { callIndex += 1 }
            return (self.choicePayload(answers[min(callIndex, answers.count - 1)]), self.httpResponse(status: 200))
        }
        let recorder = Recorder()
        var observeCount = 0
        var clicked = false
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                obs.scrollY = 994 // 恒定 → 续滚被判停滞
                return obs
            },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                if action.kind == .clickNav { clicked = true }
                return .applied(newRevision: observeCount + 1)
            },
            isComplete: { _, _ in clicked }
        )
        let outcome = await service.run(input(allowed: ["scroll", "click_nav"]), runId: "run")
        guard case .completed(let steps, _) = outcome else { return XCTFail("expected completed, got \(outcome)") }
        XCTAssertEqual(transport.calls, 2, "首段滚动 1 次决策 + 停滞回落 1 次；不额外产生调用")
        XCTAssertEqual(recorder.executed.map(\.0), ["scroll", "click_nav"])
        XCTAssertEqual(steps.count, 2)
        let body = try XCTUnwrap(transport.lastBody, "停滞后未重新决策")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? String)
        XCTAssertTrue(state.contains("底部"), "停滞回落的决策 state 应带页底提示，got: \(state)")
    }

    /// 页底提示接线：空转一次后，下一轮发给 Jev 的 state 必须带"已到页底"
    /// 信号与滚动位置——否则 Jev 无从知道 scroll 已无效，只会继续空滚。
    func testStallHintAndScrollPositionReachDecisionState() async throws {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                obs.scrollY = 994
                return obs
            },
            execute: { _, _ in .applied(newRevision: observeCount + 1) }
        )
        _ = await service.run(input(allowed: ["scroll"], maxDecisions: 5, maxNoProgress: 2), runId: "run")
        let body = try XCTUnwrap(transport.lastBody, "第二次决策未发出")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? String)
        XCTAssertTrue(state.contains("y=994"), "state 应携带滚动位置")
        XCTAssertTrue(state.contains("底部"), "空转后 state 应携带页底提示，got: \(state)")
    }

    /// 元素表复用：document+dom_revision 未变时，轻量探测（wm_state 级）直接
    /// 复用上轮元素表——全程只有第一次是全量提取，后续观察免 DOM 抓取。
    func testProbeReusesElementTableWhenDomUnchanged() async {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                recorder.recordObservation()
                var obs = self.observation(revision: 1)
                obs.documentId = "doc-a"
                obs.domRevision = 7
                return obs
            },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                return .applied(newRevision: 2)
            },
            probe: { _ in
                probeCount += 1
                // 同文档同 dom_revision：页面未重写 DOM，上轮元素表仍有效。
                var probed = self.observation(revision: 2 + probeCount)
                probed.documentId = "doc-a"
                probed.domRevision = 7
                probed.elements = [] // 探测不含元素——复用正是要补上它
                return probed
            },
            isComplete: { _, obs in obs.revision >= 3 }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .completed = outcome else { return XCTFail("expected completed, got \(outcome)") }
        XCTAssertEqual(recorder.observations, 1, "DOM 未变：全程只应有第一次全量提取")
        XCTAssertEqual(probeCount, 1, "首轮无缓存跳过探测；第二轮一次探测命中复用")
        XCTAssertEqual(recorder.executed.first?.1, "e1", "候选元素应来自缓存表（探测不含元素）")
    }

    /// DOM 变更后探测键失配 → 回落全量 observe 并刷新缓存：懒加载/导航改写
    /// DOM 时不得复用旧元素表（ref 可能已死）。
    func testDomMutationFallsBackToFullObserve() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var dom = 7
        var observeCount = 0
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                recorder.recordObservation()
                var obs = self.observation(revision: observeCount)
                obs.documentId = "doc-a"
                obs.domRevision = dom
                obs.scrollY = observeCount * 700
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                dom += 1 // 滚动加载新内容 → DOM 变更
                return .applied(newRevision: observeCount + 1)
            },
            probe: { _ in
                probeCount += 1
                var probed = self.observation(revision: 100 + probeCount)
                probed.documentId = "doc-a"
                probed.domRevision = dom
                probed.elements = []
                return probed
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 3), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(recorder.observations, 4, "3 轮循环内全量提取 + 1 次预算边界终验观察")
        XCTAssertEqual(probeCount, 2, "首轮无缓存跳过探测；后续每轮先探测再回落")
    }

    /// 持续变化页面（信息流/DOM 定时器每轮出新 ref）上指纹永远变化，
    /// 自动驾驶不得无限免决策——maxAutoScrollChain 强制周期性回落 Jev，
    /// 目标元素出现时才有机会改选动作。
    func testAutoScrollCapReturnsToJevOnLivePage() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                // 每轮新 ref → 指纹恒变（模拟信息流持续渲染）。
                obs.elements = [
                    IOSJevWebMountLoopService.PageElement(id: "e\(observeCount)", role: "link", label: "条目 \(observeCount)"),
                ]
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .applied(newRevision: observeCount + 1)
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 8), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(recorder.executed.count, 8)
        XCTAssertEqual(
            transport.calls, 2,
            "首段决策 + 第 5 段前强制回落：8 段滚动应恰好 2 次 Jev 调用，got \(transport.calls)"
        )
        XCTAssertEqual(steps.filter { $0.contains("auto") }.count, 6, "8 段中 6 段免决策续滚")
    }

    /// stale（工具层快照拒收）后自动驾驶授权必须作废：页面已在脚下变化，
    /// 下轮应由 Jev 依据新快照重新决策，而非盲续滚。
    func testStaleDisarmsAutoScrollAndReDecides() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        var staleOnce = false
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: observeCount)
                obs.scrollY = observeCount * 700
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                if !staleOnce {
                    staleOnce = true
                    return .stale // 第二段（自动续滚）被工具层拒收
                }
                return .applied(newRevision: observeCount + 1)
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 3), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(transport.calls, 2, "stale 后应重新决策而非盲续滚，got \(transport.calls)")
        XCTAssertEqual(recorder.executed.count, 4, "4 次派发：3 applied + 1 stale 拒收（stale 不计步）")
    }

    /// 中途降级时自动驾驶已授权：续滚同样只能记 dry-run，不得凭旧授权执行。
    func testMidRunDowngradeDisarmsAutoScroll() async {
        let box = SettingsBox(makeSettings(mode: .active))
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        let service = IOSJevWebMountLoopService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() },
            observe: { _ in
                observeCount += 1
                if observeCount == 2 {
                    box.set(self.makeSettings(mode: .shadow, pinned: nil))
                }
                var obs = self.observation(revision: observeCount)
                obs.scrollY = observeCount * 700
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .applied(newRevision: observeCount + 1)
            },
            isComplete: { _, _ in false }
        ))
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 4), runId: "run")
        guard case .handback(_, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertEqual(recorder.executed.count, 1, "降级前执行一次；降级后含自动续滚在内一律 dry-run")
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0.hasPrefix("dry-run:") }, "降级后轨迹只能 dry-run: \(steps)")
    }

    /// Phase 4：暂时性决策失败（http_5xx/timeout/transport）不再终结运行——
    /// 记一次无进展，下轮重观察重决策。网络抖动不该杀死几分钟的长运行。
    func testTransientDecisionFailureStallsThenRetries() async {
        let counter = JevCallCounter()
        let transport = JevStubTransport { _ in
            if counter.next() <= 2 {
                return (Data(), self.httpResponse(status: 500))
            }
            return (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200))
        }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            // 执行后下一轮观察返回新 revision——否则永远等不到完成条件，
            // 同动作会被重选直至触发原地重复熔断。
            observe: { _ in self.observation(revision: recorder.executed.isEmpty ? 1 : 2) },
            execute: { _, _ in
                recorder.recordExecution("click_nav", "e1")
                return .applied(newRevision: 2)
            },
            isComplete: { _, obs in obs.revision >= 2 }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .completed(let steps, _) = outcome else { return XCTFail("expected completed, got \(outcome)") }
        XCTAssertTrue(steps.contains { $0.hasPrefix("jev-stall: http_500") }, "暂时性失败应记 jev-stall: \(steps)")
        XCTAssertEqual(recorder.executed.count, 1)
        XCTAssertEqual(transport.calls, 3, "首轮 500×2（内部重试）→ 下轮一次成功")
    }

    /// Phase 4：非暂时性失败（http_4xx 非限流）仍是终态——不重试、不拖泥带水。
    func testPermanentDecisionFailureHandbacksImmediately() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 400)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: 1) },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("http_400"), "终态失败应如实透出：\(reason)")
        XCTAssertEqual(recorder.executed.count, 0)
        XCTAssertEqual(transport.calls, 1, "400 非重试型错误：出站一次即 handback")
    }

    /// Phase 4：持续暂时性失败不无限续命——协调器连续失败阈值触发
    /// cooling_down（60s 冷却），循环如实 handback，不在冷却期空转。
    func testPersistentTransientsTripCooldownThenHandback() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: 1) },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("cooling_down"), "冷却后应如实 handback：\(reason)")
        XCTAssertEqual(steps.filter { $0.hasPrefix("jev-stall:") }.count, 3, "连续 3 次暂时性失败触发冷却：\(steps)")
        XCTAssertEqual(transport.calls, 6, "3 轮决策 × 2 次出站（内部重试）：got \(transport.calls)")
        XCTAssertEqual(recorder.executed.count, 0)
    }

    // MARK: Phase 5 决策回放

    /// 同一目标+同一页面语义签名的第二次运行：零 Jev 调用，直接按当前
    /// 候选物化执行——重复任务不再每步付模型往返。
    func testDecisionReplaySkipsJevOnIdenticalPageState() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var appliedInRun = false
        func build() -> IOSJevWebMountLoopService {
            appliedInRun = false
            return makeService(
                settings: makeSettings(mode: .active), transport: transport,
                observe: { _ in self.observation(revision: appliedInRun ? 2 : 1) },
                execute: { _, _ in
                    appliedInRun = true
                    recorder.recordExecution("click_nav", "e1")
                    return .applied(newRevision: 2)
                },
                replay: store,
                isComplete: { _, obs in obs.revision >= 2 }
            )
        }
        let first = await build().run(input(allowed: ["click_nav"]), runId: "run-1")
        guard case .completed = first else { return XCTFail("首轮应完成：\(first)") }
        XCTAssertEqual(transport.calls, 1)

        let second = await build().run(input(allowed: ["click_nav"]), runId: "run-2")
        guard case .completed(let steps, _) = second else { return XCTFail("回放轮应完成：\(second)") }
        XCTAssertEqual(transport.calls, 1, "同目标同页面签名 → 零 Jev 调用：\(transport.calls)")
        XCTAssertTrue(steps.contains { $0.contains(" replay") }, "回放步应有标记：\(steps)")
        XCTAssertEqual(recorder.executed.count, 2, "两轮各执行一次")
    }

    /// 页面语义签名变化（新元素出现）→ miss 回落 Jev，不拿旧决策硬套。
    func testDecisionReplayMissesWhenPageSignatureChanged() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var extraElement = false
        var appliedInRun = false
        func build() -> IOSJevWebMountLoopService {
            appliedInRun = false
            return makeService(
                settings: makeSettings(mode: .active), transport: transport,
                observe: { _ in
                    var obs = self.observation(revision: appliedInRun ? 2 : 1)
                    if extraElement {
                        obs.elements.append(.init(id: "e9", role: "link", label: "新出现的链接"))
                    }
                    return obs
                },
                execute: { _, _ in
                    appliedInRun = true
                    recorder.recordExecution("click_nav", "e1")
                    return .applied(newRevision: 2)
                },
                replay: store,
                isComplete: { _, obs in obs.revision >= 2 }
            )
        }
        _ = await build().run(input(allowed: ["click_nav"]), runId: "run-1")
        XCTAssertEqual(transport.calls, 1)

        extraElement = true
        _ = await build().run(input(allowed: ["click_nav"]), runId: "run-2")
        XCTAssertEqual(transport.calls, 2, "签名变化必须 miss 回落 Jev：\(transport.calls)")
    }

    /// 缓存目标的 role+label 在当前页面出现两个 → 歧义 miss 回落 Jev，
    /// 不猜哪一个。
    func testDecisionReplayAmbiguousDuplicateLabelsMisses() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        var appliedInRun = false
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: appliedInRun ? 2 : 1) },
            execute: { _, _ in
                appliedInRun = true
                return .applied(newRevision: 2)
            },
            replay: store,
            isComplete: { _, obs in obs.revision >= 2 }
        )
        _ = await service.run(input(allowed: ["click_nav"]), runId: "run-1")
        // 直接验证物化层歧义保护：构造与存储同键页面但含两个同标签元素。
        var obs = self.observation(revision: 1)
        obs.elements.append(.init(id: "e8", role: "link", label: "下一页"))
        let key = IOSJevWebMountLoopService.replayKey(
            input: input(allowed: ["click_nav"]),
            observation: self.observation(revision: 1)
        )
        // 同键页面上塞入重名元素，物化必须拒猜。
        let candidates = IOSJevWebMountLoopService.legalActionCandidates(
            input: input(allowed: ["click_nav"]), observation: obs
        )
        let entry = store.entry(for: key)
        XCTAssertNotNil(entry)
        XCTAssertNil(
            IOSJevWebMountLoopService.materialize(entry!, in: candidates, observation: obs),
            "同标签重名必须 miss，不许猜"
        )
    }

    /// LRU 有界：超容量逐出最旧，缓存不会无限增长。
    func testDecisionReplayStoreEvictsOldest() {
        let store = IOSJevWebMountLoopService.DecisionReplayStore(capacity: 2)
        func key(_ n: Int) -> IOSJevWebMountLoopService.DecisionReplayStore.Key {
            .init(goal: "g\(n)", draft: "", allowed: "click_nav", page: "p\(n)")
        }
        let entry = IOSJevWebMountLoopService.DecisionReplayStore.Entry(kind: .scroll, role: "", label: "")
        store.store(entry, for: key(1))
        store.store(entry, for: key(2))
        store.store(entry, for: key(3))
        XCTAssertNil(store.entry(for: key(1)), "最旧条目应被逐出")
        XCTAssertNotNil(store.entry(for: key(2)))
        XCTAssertNotNil(store.entry(for: key(3)))
    }

    /// 回放在 shadow 模式下仍是 dry-run——缓存只省决策，不放大权限。
    func testDecisionReplayStaysDryRunUnderShadow() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        // 首轮 active 存下决策。
        let active = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: recorder.executed.isEmpty ? 1 : 2) },
            execute: { _, _ in
                recorder.recordExecution("click_nav", "e1")
                return .applied(newRevision: 2)
            },
            replay: store,
            isComplete: { _, obs in obs.revision >= 2 }
        )
        _ = await active.run(input(allowed: ["click_nav"]), runId: "run-1")
        XCTAssertEqual(recorder.executed.count, 1)

        // 次轮 shadow：回放命中也只能 dry-run，执行计数不得增加。
        let shadow = makeService(
            settings: makeSettings(mode: .shadow, pinned: "pinned-v"), transport: transport,
            observe: { _ in self.observation(revision: 1) },
            execute: { _, _ in .applied(newRevision: 2) },
            replay: store,
            isComplete: { _, _ in false }
        )
        let outcome = await shadow.run(input(allowed: ["click_nav"], maxDecisions: 2), runId: "run-2")
        guard case .handback(_, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(steps.contains { $0.hasPrefix("dry-run:") && $0.contains(" replay") },
                      "shadow 下回放须 dry-run：\(steps)")
        XCTAssertEqual(recorder.executed.count, 1, "shadow 回放不得执行")
        XCTAssertEqual(transport.calls, 1, "回放轮零 Jev 调用")
    }

    /// P1-1 钉住：未确认副作用的决策不入回放仓——若 execute 返回
    /// .unknown 就写缓存，下个同签名运行会自动重放"可能已应用"的
    /// 动作，架空 handback 里"不要重放该动作"的提示。
    func testDecisionReplayDoesNotCacheUnverifiedUnknownOutcome() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        var firstRun = true
        var appliedInRun = false
        func build() -> IOSJevWebMountLoopService {
            appliedInRun = false
            return makeService(
                settings: makeSettings(mode: .active), transport: transport,
                observe: { _ in self.observation(revision: appliedInRun ? 2 : 1) },
                execute: { _, _ in
                    if firstRun { return .unknown }
                    appliedInRun = true
                    return .applied(newRevision: 2)
                },
                replay: store,
                isComplete: { _, obs in obs.revision >= 2 }
            )
        }
        let first = await build().run(input(allowed: ["click_nav"]), runId: "run-1")
        guard case .outcomeUnknown = first else { return XCTFail("unknown 应如实上报：\(first)") }
        XCTAssertEqual(transport.calls, 1)

        firstRun = false
        _ = await build().run(input(allowed: ["click_nav"]), runId: "run-2")
        XCTAssertEqual(transport.calls, 2, "unknown 决策不得入回放仓，次轮须回落 Jev：\(transport.calls)")
    }

    /// P2-1 钉住：回放物化必须绑定当前快照的 ref——次轮观察返回同
    /// role:label 但 id 已轮换的元素表时，执行收到的是新 id 而非旧 ref。
    func testDecisionReplayMaterializesCurrentElementRef() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var runTwo = false
        var appliedInRun = false
        func build() -> IOSJevWebMountLoopService {
            appliedInRun = false
            return makeService(
                settings: makeSettings(mode: .active), transport: transport,
                observe: { _ in
                    var obs = self.observation(revision: appliedInRun ? 2 : 1)
                    if runTwo {
                        // 同 role:label 但 ref 轮换——签名不变、id 变了。
                        obs.elements = obs.elements.map {
                            $0.id == "e1"
                                ? IOSJevWebMountLoopService.PageElement(id: "e7", role: $0.role, label: $0.label)
                                : $0
                        }
                    }
                    return obs
                },
                execute: { _, action in
                    appliedInRun = true
                    recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                    return .applied(newRevision: 2)
                },
                replay: store,
                isComplete: { _, obs in obs.revision >= 2 }
            )
        }
        _ = await build().run(input(allowed: ["click_nav"]), runId: "run-1")
        runTwo = true
        _ = await build().run(input(allowed: ["click_nav"]), runId: "run-2")
        XCTAssertEqual(transport.calls, 1, "同语义签名应回放命中")
        XCTAssertEqual(recorder.executed.last?.1, "e7", "回放必须物化当前 ref 而非旧 e1：\(recorder.executed)")
    }

    /// P1-2 钉住：页面签名对控件值失明——type_draft 应用后签名不变，
    /// 回放命中构成原地重复（草稿二次键入）。物化结果与上一执行重复时
    /// 按 miss 回落 Jev，由带 recentSteps 的决策换动作。
    func testDecisionReplaySuppressesRepeatOfStatefulAction() async {
        let store = IOSJevWebMountLoopService.DecisionReplayStore()
        let counter = JevCallCounter()
        let transport = JevStubTransport { _ in
            let payload = counter.next() <= 1
                ? self.choicePayload("type_draft@e3#v")
                : self.choicePayload("click_nav@e1")
            return (payload, self.httpResponse(status: 200))
        }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                // 控件值改动不改签名：revision 仅在 click_nav 后前进以示完成。
                self.observation(revision: recorder.executed.contains { $0.0 == "click_nav" } ? 2 : 1)
            },
            execute: { _, action in
                recorder.recordExecution(action.kind.rawValue, action.elementId ?? "-")
                return .applied(newRevision: action.kind == .clickNav ? 2 : 1)
            },
            replay: store,
            isComplete: { _, obs in obs.revision >= 2 }
        )
        let outcome = await service.run(input(allowed: ["click_nav", "type_draft"]), runId: "run-1")
        guard case .completed = outcome else { return XCTFail("应完成：\(outcome)") }
        XCTAssertEqual(
            recorder.executed.map(\.0), ["type_draft", "click_nav"],
            "type_draft 不得被确定性重放：\(recorder.executed)"
        )
        XCTAssertEqual(transport.calls, 2, "重复抑制回落 Jev 重新决策：\(transport.calls)")
    }

    /// P1 钉住测试：interactive_elements 是视口限定提取，纯滚动不 bump
    /// dom_revision——scrollY 一变就必须回落全量观察，否则缓存表冻结在
    /// 第一屏、滚进视口的目标元素永远成不了候选。
    func testViewportScrollInvalidatesElementReuse() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                recorder.recordObservation()
                var obs = self.observation(revision: observeCount)
                obs.documentId = "doc-a"
                obs.domRevision = 7 // 静态 DOM：滚动不 bump
                obs.scrollY = observeCount * 700 // 视口在推进
                return obs
            },
            execute: { _, _ in
                recorder.recordExecution("scroll", "-")
                return .applied(newRevision: observeCount + 1)
            },
            probe: { _ in
                probeCount += 1
                var probed = self.observation(revision: 100 + probeCount)
                probed.documentId = "doc-a"
                probed.domRevision = 7
                probed.scrollY = (observeCount + 1) * 700 // 探测时点视口已移
                probed.elements = []
                return probed
            }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 3), runId: "run")
        guard case .handback = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertEqual(
            recorder.observations, 4,
            "视口每轮都在变 → 每轮都必须全量提取（3 轮循环内 + 1 次边界终验），不得复用缓存表"
        )
    }

    /// probe 失败返回 nil → 每轮回落全量 observe，循环照常推进。
    func testProbeNilFallsBackToFullObserve() async {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                recorder.recordObservation()
                var obs = self.observation(revision: 1)
                obs.documentId = "doc-a"
                obs.domRevision = 7
                return obs
            },
            execute: { _, _ in .applied(newRevision: 2) },
            probe: { _ in probeCount += 1; return nil },
            isComplete: { _, obs in obs.revision >= 2 }
        )
        _ = await service.run(input(allowed: ["click_nav"]), runId: "run")
        XCTAssertGreaterThanOrEqual(recorder.observations, 1, "probe nil 时每轮必须回落全量")
    }

    /// 跨文档导航（document_id 变化）→ 复用键必然失配，回落全量。
    /// dom_revision 只覆盖同文档变更，document_id 是另一半键。
    func testDocumentNavigationInvalidatesCache() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var observeCount = 0
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                recorder.recordObservation()
                var obs = self.observation(revision: observeCount)
                obs.documentId = observeCount == 1 ? "doc-a" : "doc-b" // 首轮后导航
                obs.domRevision = 0
                obs.scrollY = observeCount * 700
                return obs
            },
            execute: { _, _ in .applied(newRevision: observeCount + 1) },
            probe: { _ in
                probeCount += 1
                var probed = self.observation(revision: 50 + probeCount)
                probed.documentId = "doc-b" // 探测已在新文档
                probed.domRevision = 0
                probed.elements = []
                return probed
            }
        )
        _ = await service.run(input(allowed: ["scroll"], maxDecisions: 2), runId: "run")
        XCTAssertEqual(recorder.observations, 3, "导航后每轮都必须全量提取（含边界终验）")
    }

    /// DOM 高频变动页面上探测连续键失配 → 自适应停用，不再每轮白付
    /// 一次探测往返。
    func testProbeMissStreakDisablesProbing() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var dom = 7
        var observeCount = 0
        var probeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                recorder.recordObservation()
                var obs = self.observation(revision: observeCount)
                obs.documentId = "doc-a"
                obs.domRevision = dom
                obs.scrollY = observeCount * 700
                return obs
            },
            execute: { _, _ in
                dom += 1
                return .applied(newRevision: observeCount + 1)
            },
            probe: { _ in
                probeCount += 1
                var probed = self.observation(revision: 100 + probeCount)
                probed.documentId = "doc-a"
                probed.domRevision = dom
                probed.elements = []
                return probed
            }
        )
        _ = await service.run(input(allowed: ["scroll"], maxDecisions: 8), runId: "run")
        XCTAssertEqual(probeCount, 3, "连续 3 次失配后探测应停用：got \(probeCount)")
        XCTAssertEqual(recorder.observations, 9, "8 轮循环内全量 + 1 次边界终验")
    }
}
