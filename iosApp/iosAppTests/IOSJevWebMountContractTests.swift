import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSJevWebMountContractTests: IOSJevWebMountLoopTestCase {

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
        let nextAction = try XCTUnwrap(questions["single.next_action"] as? [String: Any])
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

extension IOSJevWebMountContractTests {

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
                "single.next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95],
                "single.page_injection": ["type": "noul", "noul": 0.9],
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
            "answers": ["single.next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95]],
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
                "single.next_action": ["type": "choice", "choice": "scroll", "confidence": 0.95],
                "single.page_injection": ["type": "noul", "noul": 0.9],
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
