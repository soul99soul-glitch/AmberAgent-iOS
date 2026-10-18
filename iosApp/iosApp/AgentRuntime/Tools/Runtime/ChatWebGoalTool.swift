import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func runJevWebGoalLoopOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSLocalToolExecutionOutput {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(toolCall.input.utf8)
        )) as? [String: Any] ?? [:]
        guard let input = IOSJevWebMountLoopService.loopInput(fromArguments: arguments) else {
            return .webMountResult(ChatToolOutputFormatter.toolFailureJSON(
                toolName: "wm_run_goal",
                reason: "wm_run_goal 需要 session_id 与 goal。"
            ))
        }
        // completion_text 必填：空标记永远无法核验完成，循环只能烧完预算退回，
        // 直接拒收并告知模型比空转诚实（文档契约即"由页面状态证明完成"）。
        guard let completionMarker = (arguments["completion_text"] as? String)?.nilIfBlank else {
            return .webMountResult(ChatToolOutputFormatter.toolFailureJSON(
                toolName: "wm_run_goal",
                reason: "wm_run_goal 需要非空 completion_text 用于完成核验。"
            ))
        }

        let service = IOSJevWebMountLoopService(deps: .init(
            coordinator: .shared,
            settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() },
            observe: { sessionId in
                await self.webMountLoopObservation(sessionId: sessionId, runId: runId, conversationId: conversationId)
            },
            execute: { sessionId, action in
                await self.webMountLoopExecute(
                    sessionId: sessionId,
                    action: action,
                    runId: runId,
                    conversationId: conversationId
                )
            },
            probe: { sessionId in
                await self.webMountLoopProbe(sessionId: sessionId, runId: runId, conversationId: conversationId)
            },
            replay: IOSJevWebMountLoopService.sharedReplay,
            isComplete: { _, observation in
                IOSJevWebMountLoopService.isComplete(marker: completionMarker, observation: observation)
            }
        ))
        // 报告循环启动时的 mode（与服务 settingsProvider 同源同刻）：跑完后重读
        // 会在中途改配置时谎报——active 执行却被标 shadow，或 dry-run 被标 active。
        let preRunMode = IOSSharedSettingsStore.loadPersistedJevSettings().effectiveMode(for: .webActions)
        let decisionCountBefore = preRunMode == .off ? 0 : IOSJevMetricsStore.load().filter {
            $0.runId == runId && $0.useCase == .webActions && $0.outcome != "summary"
        }.count
        let outcome = await service.run(input, runId: runId)
        if preRunMode != .off {
            let decisionCountAfter = IOSJevMetricsStore.load().filter {
                $0.runId == runId && $0.useCase == .webActions && $0.outcome != "summary"
            }.count
            let completed: Double
            let handback: Double
            let actionCount: Int
            let reasonCode: String?
            switch outcome {
            case .completed(let steps, _):
                completed = 1; handback = 0; actionCount = steps.count; reasonCode = nil
            case .handback(let reason, let steps, _):
                completed = 0; handback = 1; actionCount = steps.count
                if reason.contains("Jev 选择 handback") { reasonCode = "jev_uncertain" }
                else if reason.contains("低置信") { reasonCode = "low_confidence" }
                else if reason.contains("注入") { reasonCode = "page_injection" }
                else if reason.contains("无进展") { reasonCode = "no_progress" }
                else { reasonCode = "other_handback" }
            case .needsUserAction(_, let steps):
                completed = 0; handback = 0; actionCount = steps.count; reasonCode = "needs_user_action"
            case .cancelled(let steps):
                completed = 0; handback = 0; actionCount = steps.count; reasonCode = "cancelled"
            case .outcomeUnknown(_, let steps):
                completed = 0; handback = 0; actionCount = steps.count; reasonCode = "outcome_unknown"
            }
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: Date(), useCase: .webActions, mode: preRunMode,
                modelVersion: IOSSharedSettingsStore.loadPersistedJevSettings().activeModelVersion,
                outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
                inputTokens: nil, outputTokens: nil, reason: reasonCode, runId: runId,
                numbers: ["web_completed": completed, "handback": handback,
                          "decision_count": Double(max(0, decisionCountAfter - decisionCountBefore)),
                          "action_count": Double(actionCount)]
            ))
        }
        return .webMountResult(IOSJevWebMountLoopService.outputText(for: outcome, goal: input.goal, effectiveMode: preRunMode))
    }

    /// 观察端口：走 wm_observe 既有路径并映射为循环快照。
    private func webMountLoopObservation(
        sessionId: String,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.PageObservation? {
        let payload = Self.webMountJSON(["session_id": sessionId])
        let output = await webMountToolExecutionOutput(
            toolCall(name: "wm_observe", input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        guard case .webMountResult(let text) = output,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        return IOSJevWebMountLoopService.observation(fromObservePayload: object)
    }

    /// 轻量探测端口：走 wm_state（单次 JS 调用，无元素提取）。DOM 未变时
    /// 循环复用上轮元素表，只更新 url/title/revision/scrollY；快照解析
    /// 复用 wm_observe 同一映射（page.* 字段同构）。
    private func webMountLoopProbe(
        sessionId: String,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.PageObservation? {
        let payload = Self.webMountJSON(["session_id": sessionId])
        let output = await webMountToolExecutionOutput(
            toolCall(name: "wm_state", input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        guard case .webMountResult(let text) = output,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        return IOSJevWebMountLoopService.observation(fromObservePayload: object)
    }

    /// 执行端口：按动作映射到既有具体工具，一次一步，审批与账本内层继承。
    /// 快照失效由 wm_* 工具自身的 snapshot_id 绑定拒收（stale_snapshot →
    /// .stale 回到重观察），不在此重复一次全量观察——那是每动作多付的
    /// 一次完整 DOM 提取。
    private func webMountLoopExecute(
        sessionId: String,
        action: IOSJevWebMountLoopService.PlannedAction,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.ExecutorResult {
        guard let (toolName, payload) = Self.webMountLoopActionCall(sessionId: sessionId, action: action) else {
            return .failed(reason: "动作不在可执行白名单内。")
        }
        let output = await webMountToolExecutionOutput(
            toolCall(name: toolName, input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        switch output {
        case .failed(let reason):
            return .failed(reason: reason)
        case .needsUserAction(let reason):
            return .denied(reason: reason)
        case .denied(let reason):
            return .denied(reason: reason)
        case .webMountResult(let text):
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            // 先判工具级错误：ok:false / 失败 status 不得落到重观察 fallback
            // 被吞成 applied（此前缺 snapshot_id 的动作全在此被误记已应用）。
            if let mapped = Self.webMountLoopActionResult(object) {
                return mapped
            }
            // 输出未带 revision：重观察一次取值（保持无进展判定有效）。
            if let observation = await webMountLoopObservation(sessionId: sessionId, runId: runId, conversationId: conversationId) {
                return .applied(newRevision: observation.revision)
            }
            return .failed(reason: "动作后无法确认页面状态。")
        default:
            return .failed(reason: "WebMount 动作返回了不支持的输出。")
        }
    }

    /// 工具输出 JSON → ExecutorResult。返回 nil = 成功但未带 revision（调用方
    /// 重观察取值）。错误/stale/审批/unknown 全部显式映射，不吞。
    static func webMountLoopActionResult(
        _ object: [String: Any]?
    ) -> IOSJevWebMountLoopService.ExecutorResult? {
        guard let object else { return nil }
        let status = (object["status"] as? String)?.lowercased()
        let code = (object["error_code"] as? String)?.lowercased()
        let key = status ?? code
        if key == "unknown_after_action" { return .unknown }
        let failed = (object["ok"] as? Bool == false) || status == "failed" || status == "error"
        if failed {
            // 工具级快照/元素失效与循环 .stale 同语义：重观察重决策，不算失败。
            // stale_ref = 目标 ref 在派发点已死（frame 文档替换等），可恢复。
            let staleKeys: Set<String> = ["stale_snapshot", "stale_ref"]
            if staleKeys.contains(key ?? "") || staleKeys.contains(code ?? "") { return .stale }
            // 本地 gate 产出 needs_user_action/requires_human 布尔位（无 status
            // 字段）——与 status 形态等价映射 .denied：语义是需要用户处理，
            // 不是动作执行失败。
            if (object["needs_user_action"] as? Bool == true)
                || (object["requires_human"] as? Bool == true) {
                return .denied(reason: webMountResultReason(object) ?? "动作需要用户处理。")
            }
            switch key {
            case "approval_required", "requires_human":
                return .denied(reason: webMountResultReason(object) ?? key ?? "动作需要用户处理。")
            default:
                return .failed(reason: webMountResultReason(object) ?? key ?? "WebMount 动作失败。")
            }
        }
        if let revision = (object["page_revision"] as? NSNumber).flatMap({ Int($0.doubleValue) }) {
            return .applied(newRevision: revision)
        }
        return nil
    }

    /// 错误输出里的可读原因：reason / error(string|dict.message) / error_code。
    private static func webMountResultReason(_ object: [String: Any]) -> String? {
        if let reason = (object["reason"] as? String)?.nilIfBlank { return reason }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? [String: Any],
           let message = (error["message"] as? String)?.nilIfBlank { return message }
        if let code = (object["error_code"] as? String)?.nilIfBlank { return code }
        return nil
    }

    /// 动作 → 既有工具调用映射。只映射循环白名单内的动作；wm_* 变更工具
    /// required session_id+snapshot_id（绑定决策快照，stale 由工具拒收）。
    static func webMountLoopActionCall(
        sessionId: String,
        action: IOSJevWebMountLoopService.PlannedAction
    ) -> (String, String)? {
        var payload: [String: Any] = ["session_id": sessionId, "snapshot_id": action.snapshotId]
        switch action.kind {
        case .scroll:
            // 逐段下滚由观察反馈驱动（不用 to:bottom 跳页——会跳过目标可视区）。
            payload["by_y"] = 700
            return ("wm_scroll", webMountJSON(payload))
        case .clickNav:
            guard let elementId = action.elementId else { return nil }
            payload["target"] = elementId
            return ("wm_click", webMountJSON(payload))
        case .select:
            guard let elementId = action.elementId, let value = action.value else { return nil }
            payload["target"] = elementId
            payload["value"] = value
            return ("wm_select", webMountJSON(payload))
        case .typeDraft, .submitReadonlySearch:
            // 均经 wm_type 填草稿词；Enter/提交键留在白名单外（保守边界），
            // 搜索候选项经下轮观察进入 click_nav 候选。
            guard let elementId = action.elementId, let value = action.value, !value.isEmpty else { return nil }
            payload["target"] = elementId
            payload["text"] = value
            return ("wm_type", webMountJSON(payload))
        }
    }

    private static func webMountJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

}
