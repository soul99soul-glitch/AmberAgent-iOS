import Foundation

// MARK: - Jev 审批分诊标注（增强 Phase E）
//
// 契约（jev-enhancements-execution-plan Phase E，红线不可破）：
// - 只标注，永不自动批准/拒绝；不改变审批状态机、按钮与顺序。
// - 三道 Noul 是中性事实（只读/可逆/与任务相关），UI 措辞禁止
//   "安全/低风险"等诱导词——标注是分诊信息，不是授权建议。
// - 不阻塞审批链：卡片照常立即展示，标签异步补充；失败/超时/非 active/
//   范围不足 → 返回 nil，审批卡片与原样完全一致。
// - 默认外发仅工具名与动作类型（元数据），不含参数原文。

/// 一次审批的三道中性事实判断。
struct IOSJevApprovalTriage: Equatable {
    enum TriState: String, Equatable {
        case yes, no, unknown
    }
    var requestId: String
    var readonly: TriState
    var reversible: TriState
    var goalAligned: TriState
}

@MainActor
final class IOSJevApprovalTriageService {

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevApprovalTriageService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 三态分界：Noul ≥0.65 是 / ≤0.35 否 / 之间与缺题 = 未知。
    /// Noul 无 confidence 字段；0.65/0.35 是保守带，不是供应商默认值。
    static func band(_ probability: Double?) -> IOSJevApprovalTriage.TriState {
        guard let probability, probability.isFinite else { return .unknown }
        if probability >= 0.65 { return .yes }
        if probability <= 0.35 { return .no }
        return .unknown
    }

    /// 为一个待审批请求产出分诊标注。nil = 不标注（off/shadow/失败/跳过）。
    /// turnBudgetKey：调用方 runId，与其他用途共享 runId 单本轮次账。
    func triage(
        requestId: String,
        toolName: String,
        actionSummary: String,
        goalText: String?,
        turnBudgetKey: String
    ) async -> IOSJevApprovalTriage? {
        let settings = deps.settingsProvider()
        // 动作摘要可空（mcp/council 只有工具名）：不悬挂分隔符。
        let actionLine = actionSummary.isEmpty
            ? "待审批动作：\(toolName)"
            : "待审批动作：\(toolName) · \(String(actionSummary.prefix(200)))"
        var lines = [actionLine]
        lines.append("用户最新请求：\(goalText.map { String($0.prefix(400)) } ?? "（不可得）")")
        let state = lines.joined(separator: "\n")
        let questions = [
            IOSJevQuestion.noul(
                id: "readonly",
                instructions: "判断：该动作是纯读取/观察，不修改任何持久状态或对外发送内容（是=true）。"
            ),
            IOSJevQuestion.noul(
                id: "reversible",
                instructions: "判断：该动作的效果可以轻易撤销或恢复（是=true）。删除、发送、支付、发布为否。"
            ),
            IOSJevQuestion.noul(
                id: "goal_aligned",
                instructions: "判断：该动作直接服务于用户最新请求（是=true）。偏离、扩大范围或无关为否。"
            ),
        ]
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(state)
        )
        let outcome = await deps.coordinator.decide(
            useCase: .approvalTriage,
            requiredScopes: [.toolMetadata, .selectedTaskText],
            state: state,
            questions: questions,
            context: context,
            // shadow/active 分键（全用途惯例）：shadow 观测不会被 active 命中应用。
            cacheKey: settings.effectiveMode(for: .approvalTriage) == .active
                ? "approval_triage" : "approval_triage_shadow"
        )
        guard case .applied(let decision) = outcome else { return nil }
        func answer(_ id: String) -> Double? {
            decision.answers.first { $0.id == id && $0.type == "noul" }?.noul
        }
        return IOSJevApprovalTriage(
            requestId: requestId,
            readonly: Self.band(answer("readonly")),
            reversible: Self.band(answer("reversible")),
            goalAligned: Self.band(answer("goal_aligned"))
        )
    }
}
