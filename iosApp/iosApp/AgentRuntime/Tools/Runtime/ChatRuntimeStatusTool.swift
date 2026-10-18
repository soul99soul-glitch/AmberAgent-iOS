import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func executeRuntimeStatusToolCall(
        _ pending: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?
    ) -> ChatToolRuntimeResult {
        let resultText = dispatchRuntimeStatusToolCall(
            pending.toolCall,
            toolExposureBridge: toolExposureBridge
        )
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func dispatchRuntimeStatusToolCall(
        _ toolCall: UIMessagePart.Tool,
        toolExposureBridge: IosToolExposureBridge? = nil
    ) -> String {
        runtimeStatusTool.dispatch(toolCall, toolExposureBridge: toolExposureBridge)
    }
}

@MainActor
final class ChatRuntimeStatusTool {
    unowned let runtime: ChatToolRuntime
    init(runtime: ChatToolRuntime) { self.runtime = runtime }

    /// 稳定契约：{ok, tool:"runtime_status", schema, platform, runtime, tools, jev}。
    /// 只暴露布尔/枚举/计数/版本号——Key、原文、URL、会话内容一律不进输出。
    func dispatch(
        _ toolCall: UIMessagePart.Tool,
        toolExposureBridge: IosToolExposureBridge? = nil
    ) -> String {
        let jevSettings = runtime.sharedSettings.jevSettings
        let jevKeyConfigured = runtime.sharedSettings.hasJevApiKey()
        let jevCoordinatorStatus = IOSJevDecisionCoordinator.shared.status
        let jevMetrics = IOSJevMetricsStore.summary()

        var useCases: [String: Any] = [:]
        for useCase in IOSJevUseCase.allCases {
            let configured = jevSettings.mode(for: useCase)
            let effective = jevSettings.effectiveMode(for: useCase)
            let required = useCase.defaultDataScopes
            let canSend = jevSettings.canSend(useCase: useCase, required: required)
            let availableNow = effective != .off
                && canSend
                && jevKeyConfigured
                && jevSettings.modelConfigured
                && !jevCoordinatorStatus.pausedForAuth
                && jevCoordinatorStatus.cooldownRemaining == nil
            useCases[Self.jevUseCaseStatusKey(useCase)] = [
                "mode": configured.rawValue,
                "effective_mode": effective.rawValue,
                "scopes_allowed": jevSettings.allowedScopes(for: useCase).map(\.rawValue).sorted(),
                "scopes_required": required.map(\.rawValue).sorted(),
                "can_send_scopes": canSend,
                "available_now": availableNow,
            ]
        }

        var jev: [String: Any] = [
            "role": "internal_fast_judgment",
            "summary": "快速判断模型（默认 Jev，可在设置里切换 TypeSafe / Vercel AI Gateway / Perplexity / Liquid）是宿主侧快速判断服务，不是模型也不可被直接调用。host 用它排序 tool_search 候选、召回记忆、筛选超长工具输出、为子代理选模型、驱动 wm_run_goal 网页循环、为缺省角色定义的 spawn 荐角色并产出对齐标注、为待审批动作产出三态分诊标注（只标注不授权）、判断压缩前旧工具结果是否保留原文、在自动批准生效时复核高风险调用（只会收紧为人工审批）、在本轮改动未验证却宣称完成时提示用户；手机效果检查只辅助带验收条件的 phone_act 判断后续步骤，手机快速操作通过 phone_run_goal 执行当前界面的有限导航/搜索/草稿操作，真实完成仍由新界面证据核验；script_judgment 为 active 时 exec 脚本可经 `jev` 全局主动调用（数据范围为工具输出）。出站契约见 service / api_mode；每个用途独立 off/shadow/active；off 零网络，shadow 只观测不改业务结果，active 需已验收固定模型版本。",
            "service": jevSettings.apiStyle.serviceIdentifier,
            "api_mode": jevSettings.apiStyle.statusValue,
            "model": jevSettings.modelConfigured ? jevSettings.activeModelVersion : NSNull(),
            "model_configured": jevSettings.modelConfigured,
            "key_configured": jevKeyConfigured,
            "settings_revision": jevSettings.revision,
            "pinned_model_version": jevSettings.pinnedModelVersion ?? NSNull(),
            "policy_version": jevSettings.policy.policyVersion,
            "coordinator": [
                "paused_for_auth": jevCoordinatorStatus.pausedForAuth,
                "cooldown_remaining_s": jevCoordinatorStatus.cooldownRemaining.map { Int($0) } ?? 0,
            ],
            "use_cases": useCases,
            "budget": [
                "per_turn_request_limit": jevSettings.policy.perTurnRequestBudget,
                "daily_request_limit": jevSettings.policy.dailyRequestBudget,
            ],
            "metrics": [
                "today_requests": jevMetrics.todayRequests,
                "today_request_bytes": jevMetrics.todayRequestBytes,
                "last24h_applied": jevMetrics.last24hApplied,
                "last24h_fallback": jevMetrics.last24hFallback,
                "last_error_reason": jevMetrics.lastErrorReason.map { $0 as Any } ?? NSNull(),
            ],
        ]
        if jevSettings.apiStyle == .systemone,
           !IOSJevSettings.isPinnedVersion(jevSettings.activeModelVersion) {
            jev["model_version_note"] = "当前版本不是已验收的固定版本（别名/预览）：配置为 active 的用途按 shadow 收口。"
        }
        if jevSettings.apiStyle == .systemone,
           jevSettings.pinnedModelVersion == nil {
            jev["model_version_note"] = "未验收固定版本：配置为 active 的用途按 shadow 收口，连接测试通过后自动固定。"
        }
        if jevSettings.apiStyle != .systemone, !jevSettings.modelConfigured {
            let style = jevSettings.apiStyle
            jev["model_version_note"] = "\(style.statusValue) 未配置模型：填写模型 ID（默认 \(style.provider.defaultModel)）后才可出站。"
        }

        var tools: [String: Any] = [:]
        if let bridge = toolExposureBridge {
            tools["catalog_total"] = bridge.fullToolDeclarations().count
            tools["visible_now"] = bridge.visibleTools().count
            tools["lazy_mode"] = bridge.lazyModeEnabled()
            tools["deferred_note"] = "未列出的工具经 tool_search 命中后下一轮可见。"
        } else {
            tools["catalog_available"] = false
        }

        let imageGenerationConfigured = runtime.resolvedImageGenerationConfig() != nil
            || { if case .signedIn = runtime.codexImageConfig() { return true }; return false }()

        let runtime: [String: Any] = [
            "search_enabled": runtime.effectiveWebSearchEnabled,
            "exec_javascript_enabled": runtime.effectiveExecJavaScriptEnabled,
            "webmount_enabled": runtime.isWebMountRuntimeEnabled,
            "memory_tool_enabled": IOSMemoryToolExecutor.isEnabled(runtime: runtime.sharedSettings.agentRuntime),
            "image_generation_configured": imageGenerationConfigured,
            "local_tool_executor_available": runtime.localToolExecutor != nil,
            "mcp_network_allowed": runtime.isMcpNetworkAllowed(),
            "mcp_servers_enabled": runtime.mcpManager.servers.filter(\.enabled).count,
            "subagent_dispatch_enabled": runtime.isCapabilityPolicyEnabled("ios.agent.subagent_dispatch"),
            "subagent_dynamic_enabled": runtime.sharedSettings.agentRuntime.subAgent.allowDynamicSubAgents,
            "model_council_enabled": runtime.isCapabilityPolicyEnabled("ios.agent.model_council_run"),
            "miniapp_enabled": runtime.sharedSettings.agentRuntime.miniApp.enabled,
        ]

        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": "runtime_status",
            "schema": 1,
            "platform": "ios",
            "runtime": runtime,
            "tools": tools,
            "jev": jev,
        ])
    }

    /// 用例的稳定 JSON 键（rawValue 是 camelCase，契约统一 snake_case）。
    private static func jevUseCaseStatusKey(_ useCase: IOSJevUseCase) -> String {
        switch useCase {
        case .toolDiscovery: "tool_discovery"
        case .memoryRecall: "memory_recall"
        case .contextSelection: "context_selection"
        case .modelRouting: "model_routing"
        case .webActions: "web_actions"
        case .subagentIntent: "subagent_intent"
        case .approvalTriage: "approval_triage"
        case .scriptJudgment: "script_judgment"
        case .toolResultRetention: "tool_result_retention"
        case .autoApprovalGate: "auto_approval_gate"
        case .completionCheck: "completion_check"
        case .phoneVerification: "phone_verification"
        case .phoneActions: "phone_actions"
        }
    }

}
