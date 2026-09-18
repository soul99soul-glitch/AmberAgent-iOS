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

    private func input(allowed: Set<String>, draft: String? = "关键词") -> IOSJevWebMountLoopService.LoopInput {
        .init(
            sessionId: "sess-1",
            goal: "在列表页找到目标条目",
            draftValue: draft,
            allowedActions: allowed,
            maxActionDecisions: nil,
            maxSeconds: nil,
            maxNoProgress: nil
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
            input(allowed: ["scroll", "click_nav"], draft: nil),
            runId: "run"
        )
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected decision-cap handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertFalse(steps.isEmpty, "dry-run trajectory must be produced")
        XCTAssertTrue(steps.allSatisfy { $0.hasPrefix("dry-run:") })
        XCTAssertTrue(recorder.executed.isEmpty, "shadow must never execute actions")
        XCTAssertGreaterThan(transport.calls, 0)
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
        let outcome = await service.run(input(allowed: ["scroll"]), runId: "run")
        guard case .handback(let reason, _, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("无进展"))
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
        let outcome = await service.run(input(allowed: ["click_nav"]), runId: "run")
        guard case .handback(let reason, let steps, _) = outcome else { return XCTFail("expected handback, got \(outcome)") }
        XCTAssertTrue(reason.contains("耗尽"))
        XCTAssertEqual(steps.count, 6, "runtime cap 6 action decisions; input cannot raise it")
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
