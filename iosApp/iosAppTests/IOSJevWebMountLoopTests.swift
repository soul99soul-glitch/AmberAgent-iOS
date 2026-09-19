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
        let transport = JevStubTransport { _ in (self.choicePayload("click_nav@e1"), self.httpResponse(status: 200)) }
        var revision = 1
        let service = makeService(
            settings: makeSettings(mode: .active), transport: transport,
            observe: { _ in self.observation(revision: revision) },
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
            "page": ["url": url],
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
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "approval_required", "error_code": "high_consequence_requires_approval",
        ]) else { return XCTFail("approval_required 必须映射 .denied") }
        guard case .denied = ChatToolRuntime.webMountLoopActionResult([
            "ok": false, "status": "requires_human",
        ]) else { return XCTFail("requires_human 必须映射 .denied") }
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
}
