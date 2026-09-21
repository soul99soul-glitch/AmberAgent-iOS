import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevWebMountLoopTests（Phase 3 网页自动化）：
// off/scope → handback 零网络；shadow/dry-run 决不执行动作；active 白名单动作
// 经注入 executor 执行且每轮重观察；完成检查由页面状态核验；未知结果不重放；
// 无进展/决策次数上限 → handback；缺草稿值不产生 type_draft 候选；白名单外
// 动作（提交/发布/支付类）永不进入候选。

@MainActor
final class IOSJevWebMountLoopTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func choicePayload(_ option: String, confidence: Double = 0.9) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": ["next_action": ["type": "choice", "choice": option, "confidence": confidence]],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { jevSync(lock) { value } }
        func set(_ newValue: IOSJevSettings) { jevSync(lock) { value = newValue } }
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .webActions)
        settings.pinnedModelVersion = pinned
        settings.setScopes([.webContent, .selectedTaskText], for: .webActions)
        return settings
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _executed: [(String, String)] = []
        private var _observations = 0
        func recordExecution(_ action: String, _ element: String) {
            lock.lock(); _executed.append((action, element)); lock.unlock()
        }
        func recordObservation() { lock.lock(); _observations += 1; lock.unlock() }
        var executed: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _executed }
        var observations: Int { lock.lock(); defer { lock.unlock() }; return _observations }
    }

    private func makeService(
        settings: IOSJevSettings,
        transport: JevStubTransport,
        observe: @escaping IOSJevWebMountLoopService.Observer,
        execute: @escaping IOSJevWebMountLoopService.Executor,
        probe: IOSJevWebMountLoopService.Observer? = nil,
        replay: IOSJevWebMountLoopService.DecisionReplayStore? = nil,
        isComplete: @escaping (String, IOSJevWebMountLoopService.PageObservation) -> Bool = { _, _ in false }
    ) -> IOSJevWebMountLoopService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevWebMountLoopService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() },
            observe: observe,
            execute: execute,
            probe: probe,
            replay: replay,
            isComplete: isComplete
        ))
    }

    private let baseElements = [
        IOSJevWebMountLoopService.PageElement(id: "e1", role: "link", label: "下一页"),
        IOSJevWebMountLoopService.PageElement(id: "e2", role: "searchbox", label: "站内搜索"),
        IOSJevWebMountLoopService.PageElement(id: "e3", role: "textbox", label: "评论"),
    ]

    private func observation(revision: Int = 1) -> IOSJevWebMountLoopService.PageObservation {
        .init(snapshotId: "s\(revision)", revision: revision, url: "https://example.com/list", elements: baseElements)
    }

    private func input(
        allowed: Set<String>,
        draft: String? = "关键词",
        maxDecisions: Int? = nil,
        maxSeconds: Int? = nil,
        maxNoProgress: Int? = nil
    ) -> IOSJevWebMountLoopService.LoopInput {
        .init(
            sessionId: "sess-1",
            goal: "在列表页找到目标条目",
            draftValue: draft,
            allowedActions: allowed,
            maxActionDecisions: maxDecisions,
            maxSeconds: maxSeconds,
            maxNoProgress: maxNoProgress
        )
    }

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

    /// 探测快照解析：wm_state 输出形状（snapshot_id/page_revision 顶层，
    /// url/title/document_id/dom_revision/scroll 在 page 内，无元素表）。
    func testObservationMappingFromStateProbePayload() {
        let probed = IOSJevWebMountLoopService.observation(fromObservePayload: [
            "snapshot_id": "snap-p",
            "page_revision": 9,
            "page": [
                "url": "https://example.com/items",
                "title": "Items",
                "document_id": "doc-a",
                "dom_revision": 12,
                "scroll": ["y": 640],
            ],
        ])
        XCTAssertEqual(probed?.snapshotId, "snap-p")
        XCTAssertEqual(probed?.revision, 9)
        XCTAssertEqual(probed?.documentId, "doc-a")
        XCTAssertEqual(probed?.domRevision, 12)
        XCTAssertEqual(probed?.scrollY, 640)
        XCTAssertEqual(probed?.title, "Items")
        XCTAssertEqual(probed?.elements.isEmpty, true)
    }

    /// 真机回归：点击导航成功后 completion_text 命中的是**页面标题**
    /// （如 "New Links"），旧实现只查 URL/元素 label → 目标达成也检不出，
    /// Jev 继续对同一链接连点 10 次直到预算耗尽。标题必须参与完成核验。
    func testCompletionMatchesPageTitle() async {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        var navigated = false
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                var obs = self.observation(revision: navigated ? 2 : 1)
                obs.url = navigated ? "https://news.ycombinator.com/newest" : "https://news.ycombinator.com"
                obs.title = navigated ? "New Links | Hacker News" : "Hacker News"
                return obs
            },
            execute: { _, _ in navigated = true; return .applied(newRevision: 2) },
            isComplete: { _, o in IOSJevWebMountLoopService.isComplete(marker: "New Links", observation: o) }
        )
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .completed(let steps, _) = outcome else { return XCTFail("expected completed, got \(outcome)") }
        XCTAssertEqual(steps.count, 1, "标题命中验收词 → 第一次点击后即完成")
    }

    /// 真机回归：验收词不命中时，Jev 无记忆地重复选同一导航链接 → 同一
    /// 动作在同一目的地连续重复必须熔断，不能连点 10 次烧穿预算。
    /// （重导航会换新 document/ref，元素指纹必变——只能靠签名+目的地判出。）
    func testRepeatedSameDestinationClickHandsBack() async {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        var obs = self.observation(revision: 1)
        obs.title = "Hacker News"
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in obs },
            execute: { _, _ in recorder.recordExecution("click_nav", "e1"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["click_nav"], maxDecisions: 20), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("重复"), "原地重复应熔断，got: \(reason)")
        XCTAssertEqual(recorder.executed.count, 2, "同一动作到同一目的地最多放行一次重试")
    }

    /// Jev 每轮无记忆：已执行动作必须进下一轮 state，否则它会把已点过的
    /// 链接当成新目标反复执行。
    func testExecutedHistoryReachesDecisionState() async throws {
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        var obs = self.observation(revision: 1)
        obs.title = "Hacker News"
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in obs },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        _ = await service.run(input(allowed: ["click_nav"], maxDecisions: 20), runId: "run")
        let body = try XCTUnwrap(transport.lastBody, "未发出第二次决策请求")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? String)
        XCTAssertTrue(state.contains("已执行动作"), "state 应携带执行历史，got: \(state)")
        XCTAssertTrue(state.contains("click_nav"), "历史应包含上一步动作")
    }

    /// wm_observe 的 page.scroll.y 必须进 PageObservation（指纹与 state 都依赖它）。
    func testObservationParsesScrollPosition() throws {
        let payload: [String: Any] = [
            "snapshot_id": "doc:3",
            "page_revision": 3,
            "page": ["url": "https://example.com", "scroll": ["x": 0, "y": 994]],
            "interactive_elements": [["ref": "e1", "role": "link", "text": "More"]],
        ]
        let obs = try XCTUnwrap(IOSJevWebMountLoopService.observation(fromObservePayload: payload))
        XCTAssertEqual(obs.scrollY, 994)
        XCTAssertEqual(obs.elements.first?.id, "e1")
    }

    func testDecisionCapHandsBack() async {
        // 交替决策避免触发"原地重复"熔断——该熔断本身有独立用例覆盖。
        var call = 0
        let transport = JevStubTransport { _ in
            call += 1
            return (self.choicePayload(call % 2 == 0 ? "scroll" : "click_nav@e1"), self.httpResponse(status: 200))
        }
        var revision = 1
        var observeCount = 0
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in
                observeCount += 1
                var obs = self.observation(revision: revision)
                // scroll 的指纹判进展：每轮换一组元素，防止空滚被计无进展
                // （这里要验证的是决策上限，不是无进展上限）。
                obs.elements.append(IOSJevWebMountLoopService.PageElement(id: "dyn\(observeCount)", role: "link", label: "动态条目"))
                return obs
            },
            execute: { _, _ in revision += 1; return .applied(newRevision: revision) },
            isComplete: { _, _ in false } // 永不完成 → 撞上限
        )
        let outcome = await service.run(input(allowed: ["click_nav"], maxDecisions: 6), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(steps.count, 6, "输入收窄上限生效；runtime 默认上限（100）更高时不干预")
    }

    // MARK: 白名单与候选约束

    func testMissingDraftValueExcludesTypeDraftCandidates() {
        let input = self.input(allowed: ["type_draft"], draft: nil)
        let candidates = IOSJevWebMountLoopService.legalActionCandidates(
            input: input,
            observation: observation()
        )
        XCTAssertFalse(candidates.contains { $0.kind == .typeDraft }, "missing draft value must not offer type_draft")
        XCTAssertTrue(candidates.allSatisfy { IOSJevWebMountLoopService.actionWhitelist.contains($0.kind.rawValue) })
    }

    func testWhitelistExcludesSendPublishDeletePayActions() {
        // 输入试图放大允许范围：发送/发布/删除/支付类动作不在白名单内，
        // 即便 allowedActions 里写了也进不了候选。
        let input = self.input(allowed: [
            "scroll", "click_nav", "select", "type_draft", "submit_readonly_search",
            "send_message", "publish", "delete", "pay", "type_text", "click_any",
        ], draft: "v")
        let candidates = IOSJevWebMountLoopService.legalActionCandidates(
            input: input,
            observation: observation()
        )
        XCTAssertTrue(candidates.allSatisfy { IOSJevWebMountLoopService.actionWhitelist.contains($0.kind.rawValue) },
                      "runtime whitelist cannot be enlarged by input")
        // click_nav 只对 link 角色元素成立（e3 textbox 不产生 click_nav）。
        XCTAssertFalse(candidates.contains { $0.kind == .clickNav && $0.elementId == "e3" })
        // type_draft 只对 textbox（e3）；select 只对选择控件（无）。
        XCTAssertEqual(candidates.filter { $0.kind == .typeDraft }.map(\.elementId), ["e3"])
        XCTAssertTrue(candidates.filter { $0.kind == .select }.isEmpty)
        // submit_readonly_search 只对 searchbox（e2）。
        XCTAssertEqual(candidates.filter { $0.kind == .submitReadonlySearch }.map(\.elementId), ["e2"])
    }

    func testLowConfidenceChoiceHandsBack() async {
        let transport = JevStubTransport { _ in (self.choicePayload("not_a_real_option"), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("无法确定"))
        XCTAssertTrue(recorder.executed.isEmpty, "unresolvable choice must not execute")
    }

    func testDeniedActionNeedsUserAction() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .denied(reason: "需要用户确认网页操作。") }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .needsUserAction = outcome else { return XCTFail("expected needsUserAction, got \(outcome)") }
    }

    // MARK: 失败原因透传 / 置信门 / criteria 描述

    /// 协调器 .failed 的原因码必须进 handback，主模型据此区分 http 错误与低置信。
    func testFailedCallReasonSurfacedInHandback() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("http_500"), "handback 应带协调器失败码，got: \(reason)")
    }

    /// 协调器 .skipped 的原因码同样透传（预算耗尽/冷却/鉴权暂停均可辨识）。
    func testSkippedReasonSurfacedInHandback() async {
        var settings = makeSettings(mode: .active)
        settings.policy.perTurnRequestBudget = 0
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let service = makeService(
            settings: settings, transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("budget_exhausted"), "skipped 原因应透传，got: \(reason)")
        XCTAssertEqual(transport.calls, 0, "预算耗尽为零网络跳过")
    }

    /// 置信低于阈值 → handback 且不执行（文档承诺的低置信语义）。
    func testLowConfidenceChoiceNeverExecutes() async {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll", confidence: 0.2), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("低置信"), "got: \(reason)")
        XCTAssertTrue(recorder.executed.isEmpty, "低置信不得执行")
    }

    /// Vercel 契约按 option→描述字符串校验：null 描述会被 Gateway 拒收（真机
    /// 0 步 handback 的根因）。每个候选必须带非空描述。
    func testChoiceCriteriaCarryNonNullDescriptions() async throws {
        let transport = JevStubTransport { _ in (self.choicePayload("scroll"), self.httpResponse(status: 200)) }
        let service = makeService(
            settings: makeSettings(mode: .shadow, pinned: nil), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        _ = await service.run(input(allowed: ["scroll", "click_nav"], maxDecisions: 1), runId: "run")
        let body = try XCTUnwrap(transport.lastBody, "未发出 Jev 请求")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [String: Any])
        let nextAction = try XCTUnwrap(questions["next_action"] as? [String: Any])
        let criteria = try XCTUnwrap(nextAction["criteria"] as? [String: Any])
        XCTAssertFalse(criteria.isEmpty)
        for (key, value) in criteria {
            guard let description = value as? String, !description.isEmpty else {
                return XCTFail("选项 \(key) 描述为空/null —— Vercel Gateway 会拒收")
            }
        }
    }

    /// 输出带 effective_mode：配置 active 被降级时主模型能直接看到 shadow。
    func testOutputTextIncludesEffectiveMode() throws {
        let text = IOSJevWebMountLoopService.outputText(
            for: .handback(reason: "r", steps: [], latestObservation: nil),
            goal: "g",
            effectiveMode: .shadow
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["effective_mode"] as? String, "shadow")
        XCTAssertEqual(object["status"] as? String, "handback")
    }
}

// MARK: - wm_run_goal 工具入口绑定（纯函数层）

extension IOSJevWebMountLoopTests {

    private func observePayload(
        snapshotId: String = "snap-1",
        revision: Int = 3,
        url: String = "https://example.com/list?filter=done",
        nodes: [[String: Any]] = [["ref": "e1", "role": "link", "text": "Done items"]]
    ) -> [String: Any] {
        [
            "snapshot_id": snapshotId,
            "page_revision": revision,
            "page": ["url": url, "document_id": "doc-1", "dom_revision": 5],
            "interactive_elements": nodes,
        ]
    }

    func testLoopInputParsingNarrowsWhitelistAndRequiresCoreFields() {
        // 缺 session/goal → nil。
        XCTAssertNil(IOSJevWebMountLoopService.loopInput(fromArguments: ["goal": "x"]))
        XCTAssertNil(IOSJevWebMountLoopService.loopInput(fromArguments: ["session_id": "s"]))

        // 白名单外的名字被丢弃；缺省 = 全白名单。
        let full = IOSJevWebMountLoopService.loopInput(fromArguments: [
            "session_id": "s", "goal": "筛选出已完成条目",
        ])
        XCTAssertEqual(full?.allowedActions, IOSJevWebMountLoopService.actionWhitelist)

        let narrowed = IOSJevWebMountLoopService.loopInput(fromArguments: [
            "session_id": "s", "goal": "g",
            "allowed_actions": ["scroll", "type_draft", "submit_form", "pay"],
            "draft_value": "done",
            "max_action_decisions": 2,
        ])
        XCTAssertEqual(narrowed?.allowedActions, ["scroll", "type_draft"])
        XCTAssertEqual(narrowed?.draftValue, "done")
        XCTAssertEqual(narrowed?.maxActionDecisions, 2)
    }

    /// 真机「applied 但页面不动」根因回归：wm_* 变更工具 required
    /// session_id+snapshot_id，payload 必须绑定决策快照与正确参数。
    func testActionCallBindsSessionSnapshotAndTarget() throws {
        let action = IOSJevWebMountLoopService.PlannedAction(
            kind: .clickNav, elementId: "wm:sess:3", value: nil,
            snapshotRevision: 7, snapshotId: "snap-7"
        )
        let (tool, payload) = try XCTUnwrap(
            ChatToolRuntime.webMountLoopActionCall(sessionId: "sess", action: action)
        )
        XCTAssertEqual(tool, "wm_click")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "sess")
        XCTAssertEqual(object["snapshot_id"] as? String, "snap-7")
        XCTAssertEqual(object["target"] as? String, "wm:sess:3")
    }

    func testScrollAndSubmitReadonlySearchPayloads() throws {
        let scroll = IOSJevWebMountLoopService.PlannedAction(
            kind: .scroll, elementId: nil, value: nil, snapshotRevision: 1, snapshotId: "s1"
        )
        let (scrollTool, scrollPayload) = try XCTUnwrap(
            ChatToolRuntime.webMountLoopActionCall(sessionId: "sess", action: scroll)
        )
        XCTAssertEqual(scrollTool, "wm_scroll")
        let scrollObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(scrollPayload.utf8)) as? [String: Any])
        XCTAssertEqual(scrollObject["snapshot_id"] as? String, "s1")
        XCTAssertNotNil(scrollObject["by_y"], "scroll 需要位移参数（by_y/to/target 之一）")

        // 搜索框点击只是聚焦不提交：submit_readonly_search 映射 wm_type 填草稿。
        let submit = IOSJevWebMountLoopService.PlannedAction(
            kind: .submitReadonlySearch, elementId: "wm:sess:9", value: "关键词",
            snapshotRevision: 2, snapshotId: "s2"
        )
        let (submitTool, submitPayload) = try XCTUnwrap(
            ChatToolRuntime.webMountLoopActionCall(sessionId: "sess", action: submit)
        )
        XCTAssertEqual(submitTool, "wm_type")
        let submitObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(submitPayload.utf8)) as? [String: Any])
        XCTAssertEqual(submitObject["target"] as? String, "wm:sess:9")
        XCTAssertEqual(submitObject["text"] as? String, "关键词")
        XCTAssertEqual(submitObject["snapshot_id"] as? String, "s2")
    }

    /// 工具级错误不得被吞成 applied（真机症状：错误 JSON 落到重观察 fallback
    /// 被误记为已应用、revision 恒不变）。
    func testActionResultMappingRejectsSwallowedFailures() {
        guard case .stale = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "failed", "error_code": "stale_snapshot",
        ]) else { return XCTFail("stale_snapshot 必须映射 .stale（重观察重决策）") }
        guard case .stale = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "stale_snapshot",
        ]) else { return XCTFail("status=stale_snapshot 必须映射 .stale") }
        guard case .stale = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "failed", "error_code": "stale_ref",
        ]) else { return XCTFail("stale_ref 必须映射 .stale（重观察重决策）") }
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "approval_required", "error_code": "high_consequence_requires_approval",
        ]) else { return XCTFail("approval_required 必须映射 .denied") }
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "requires_human",
        ]) else { return XCTFail("requires_human 必须映射 .denied") }
        // 本地 gate 形态：布尔位 + error_code，无 status 字段——语义是
        // 需要用户处理，不是执行失败。
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "needs_user_action": true,
            "error_code": "high_consequence_requires_approval",
            "reason": "This WebMount action requires explicit foreground approval.",
        ]) else { return XCTFail("needs_user_action 布尔位必须映射 .denied") }
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "requires_human": true,
            "error_code": "sensitive_field_requires_human",
        ]) else { return XCTFail("requires_human 布尔位必须映射 .denied") }
        guard case .failed = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "failed", "error": "missing snapshot_id",
        ]) else { return XCTFail("ok:false 必须映射 .failed") }
        guard case .unknown = ChatToolRuntime.webMountLoopActionResult([
            "status": "unknown_after_action",
        ]) else { return XCTFail("unknown_after_action 必须映射 .unknown") }
        guard case .applied(let revision) = ChatToolRuntime.webMountLoopActionResult([
            "ok": true, "page_revision": 4,
        ]) else { return XCTFail("成功输出必须映射 .applied") }
        XCTAssertEqual(revision, 4)
        XCTAssertNil(
            ChatToolRuntime.webMountLoopActionResult(["ok": true]),
            "成功但无 revision → nil，由调用方重观察取值"
        )
    }

    /// 候选必须带观察快照的 id 与 revision：执行端口据此绑定 snapshot_id。
    func testCandidatesCarryObservationSnapshotId() {
        let obs = IOSJevWebMountLoopService.PageObservation(
            snapshotId: "snap-x", revision: 5, url: "https://example.com", elements: baseElements
        )
        let candidates = IOSJevWebMountLoopService.legalActionCandidates(
            input: input(allowed: ["click_nav", "type_draft", "submit_readonly_search"], draft: "v"),
            observation: obs
        )
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.snapshotId == "snap-x" && $0.snapshotRevision == 5 })
    }

    func testCompletionCheckRequiresMarkerInURLOrElementLabel() {
        let observation = IOSJevWebMountLoopService.PageObservation(
            snapshotId: "snap", revision: 1,
            url: "https://example.com/list?filter=done",
            elements: [IOSJevWebMountLoopService.PageElement(id: "e1", role: "link", label: "已完成 12 条")]
        )
        // 空标记永不完成（安全侧：只能走预算/handback 边界）。
        XCTAssertFalse(IOSJevWebMountLoopService.isComplete(marker: "  ", observation: observation))
        XCTAssertTrue(IOSJevWebMountLoopService.isComplete(marker: "filter=done", observation: observation))
        XCTAssertTrue(IOSJevWebMountLoopService.isComplete(marker: "已完成", observation: observation))
        XCTAssertFalse(IOSJevWebMountLoopService.isComplete(marker: "payment confirmation", observation: observation))
    }

    func testObservationMappingFromObservePayload() {
        let observation = IOSJevWebMountLoopService.observation(fromObservePayload: observePayload())
        XCTAssertEqual(observation?.snapshotId, "snap-1")
        XCTAssertEqual(observation?.revision, 3)
        XCTAssertEqual(observation?.url, "https://example.com/list?filter=done")
        XCTAssertEqual(observation?.elements.first?.id, "e1")
        XCTAssertEqual(observation?.elements.first?.role, "link")
        XCTAssertEqual(observation?.documentId, "doc-1")
        XCTAssertEqual(observation?.domRevision, 5)

        // 缺 snapshot_id = 观察失败；无 ref 的节点被跳过。
        XCTAssertNil(IOSJevWebMountLoopService.observation(fromObservePayload: ["page_revision": 1]))
        let skipped = IOSJevWebMountLoopService.observation(fromObservePayload: observePayload(
            nodes: [["role": "link"], ["ref": "e2", "role": "textbox", "text": "搜索"]]
        ))
        XCTAssertEqual(skipped?.elements.map(\.id), ["e2"])
    }

    func testOutcomeOutputShapeMatchesWebMountUnknownContract() throws {
        let observation = IOSJevWebMountLoopService.PageObservation(
            snapshotId: "snap", revision: 2, url: "https://example.com", elements: []
        )
        let completed = IOSJevWebMountLoopService.outputText(
            for: .completed(steps: ["click_nav e1 @r2"], finalObservation: observation), goal: "g"
        )
        let completedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(completed.utf8)) as? [String: Any])
        XCTAssertEqual(completedObject["status"] as? String, "completed")
        XCTAssertEqual(completedObject["final_url"] as? String, "https://example.com")

        let unknown = IOSJevWebMountLoopService.outputText(
            for: .outcomeUnknown(action: "click_nav e1", steps: ["click_nav e1"]), goal: "g"
        )
        // 与 WebMount 既有 unknown 契约对齐：外层把它识别为 outcome-unknown。
        let unknownObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unknown.utf8)) as? [String: Any])
        XCTAssertEqual(unknownObject["status"] as? String, "unknown_after_action")
        XCTAssertEqual(unknownObject["may_have_applied"] as? Bool, true)

        let handback = IOSJevWebMountLoopService.outputText(
            for: .handback(reason: "预算耗尽。", steps: [], latestObservation: nil), goal: "g"
        )
        let handbackObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(handback.utf8)) as? [String: Any])
        XCTAssertEqual(handbackObject["status"] as? String, "handback")
    }

    /// A3：置信下限收编进版本化 policy——调高 webActionsMinConfidence 后，
    /// 原可通过的 0.9 置信也触发 handback 且不执行。
    func testConfidenceFloorComesFromPolicy() async {
        var settings = makeSettings(mode: .active)
        settings.policy.webActionsMinConfidence = 0.95
        let transport = JevStubTransport { _ in (self.choicePayload("scroll", confidence: 0.9), self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: settings, transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("低置信"), "got: \(reason)")
        XCTAssertTrue(recorder.executed.isEmpty, "低于 policy 阈值不得执行")
    }

    /// 增强 Phase D：页面注入筛查命中（同请求 Noul ≥ 0.5）→ 立即 handback，
    /// 不执行任何动作；reason 透传给主模型。
    func testPageInjectionHitHandbacksWithoutExecuting() async {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95],
                "page_injection": ["type": "noul", "noul": 0.9],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("注入"), "got: \(reason)")
        XCTAssertTrue(recorder.executed.isEmpty, "注入命中不得执行任何动作")
    }

    /// 增强 Phase D 对照：筛查题缺答不阻断正常决策（fail-open）。
    func testMissingInjectionAnswerDoesNotBlock() async {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": ["next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation() },
            execute: { _, _ in .applied(newRevision: 2) }
        )
        // 缺筛查答案时循环照常运转（决策上限后 handback，不得因缺题卡死或误报）。
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 2), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertFalse(reason.contains("注入"), "缺题不得误报注入")
    }

    /// 增强 Phase D：shadow 观测不被注入命中截断——只观测不应用的契约优先；
    /// dry-run 轨迹完整跑满决策上限，不执行任何动作。
    func testShadowInjectionHitDoesNotTruncateDryRun() async {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95],
                "page_injection": ["type": "noul", "noul": 0.9],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let recorder = Recorder()
        let service = makeService(
            settings: makeSettings(mode: .shadow, pinned: nil), transport: transport,
            observe: { _ in recorder.recordObservation(); return self.observation() },
            execute: { _, _ in recorder.recordExecution("x", "y"); return .applied(newRevision: 2) }
        )
        let outcome = await service.run(input(allowed: ["scroll"], maxDecisions: 4), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected decision-cap handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"), "shadow 应跑满决策上限而非注入终止，got: \(reason)")
        XCTAssertTrue(steps.allSatisfy { $0.hasPrefix("dry-run:") })
        XCTAssertTrue(recorder.executed.isEmpty, "shadow must never execute actions")
    }
}
