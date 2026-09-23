import Foundation

// MARK: - Jev 子任务意图路由 + 对齐回执（增强 Phase C）
//
// 契约（jev-enhancements-execution-plan Phase C）：
// - 只在 spawn 缺省角色定义时生效：显式 role_id/system_prompt/tool_scope 或
//   继承配置一律优先，Jev 建议永远不覆盖明确选择。
// - 候选 = 内置角色目录（IOSSubAgentRoleCatalog.builtIns）+ none 弃权项；
//   返回目录外 id 按弃权处理。
// - 对齐回执是一道 Noul（子任务与用户最新请求是否直接相关），仅用于标注：
//   判定偏离时不阻断 spawn，由调用方在工具结果里如实带出。Noul 无
//   confidence 字段，不伪造。
// - 不确定 / 失败 / 范围未允许 / 低置信 → 空建议，走现有 spawn 优先级。

@MainActor
final class IOSJevSubAgentIntentService {

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    /// 一次 spawn 边界的意图判断结果。roleId 为空 = 无建议（弃权/失败/回退）。
    struct Suggestion: Equatable {
        var roleId: String?
        /// 对齐回执判定子任务偏离用户最新请求（仅标注，不阻断）。
        var alignmentDoubtful: Bool
    }

    /// 对齐 Noul 的判定分界：概率 < 0.5 视为偏离。0.5 是是非概率的自然分界，
    /// 不是供应商默认阈值；Noul 无 confidence，不做置信门。
    static let alignmentProbabilityFloor = 0.5

    static let batchPartId = "subagent_intent"

    /// 构造可并入 spawn 时机的角色 Choice 与对齐 Noul part。
    /// 模式和数据范围仍由 decideBatch 按用途独立判定。
    static func makeBatchPart(
        taskText: String,
        parentRequestText: String?,
        settings: IOSJevSettings,
        partId: String = batchPartId
    ) -> IOSJevBatchPart? {
        let roles = IOSSubAgentRoleCatalog.builtIns
        guard !roles.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("子任务：\(String(taskText.prefix(600)))")
        if let parentRequestText, !parentRequestText.isEmpty {
            lines.append("用户最新请求：\(String(parentRequestText.prefix(400)))")
        } else {
            lines.append("用户最新请求：（不可得）")
        }
        lines.append("可选角色：")
        for role in roles {
            lines.append("- \(role.id)（\(role.name)）：\(role.routing)")
        }
        let state = lines.joined(separator: "\n")

        var options: [String: String?] = ["none": "以上角色都不适合该子任务（弃权）"]
        for role in roles { options[role.id] = role.routing }
        let questions = [
            IOSJevQuestion.choice(
                id: "role_choice",
                options: options,
                instructions: "为该子任务选择最合适的内置角色。拿不准或都不合适时选择 none，不要勉强匹配。"
            ),
            IOSJevQuestion.noul(
                id: "aligned",
                instructions: "判断：该子任务直接服务于用户最新请求（是=true）。子任务明显偏离、扩大范围或与用户请求无关时为否。"
            ),
        ]
        let alignmentFloor = alignmentProbabilityFloor
        return IOSJevBatchPart(
            id: partId,
            useCase: .subagentIntent,
            requiredScopes: [.selectedTaskText, .toolMetadata],
            state: state,
            questions: questions,
            cacheKey: settings.effectiveMode(for: .subagentIntent) == .active
                ? "subagent_intent" : "subagent_intent_shadow",
            metricNumbersProvider: { decision in
                guard let probability = decision.answers.first(where: { $0.id == "aligned" })?.noul else { return nil }
                return ["alignment_doubtful": probability < alignmentFloor ? 1 : 0]
            },
            metricIdsProvider: { decision in
                guard let choice = decision.answers.first(where: { $0.id == "role_choice" })?.choice else { return nil }
                return ["suggested_role_id": choice]
            }
        )
    }

    /// 只消费 active 结果；shadow、失败或不确定均走现有 spawn 优先级。
    static func suggestion(from outcome: IOSJevDecisionOutcome, settings: IOSJevSettings) -> Suggestion {
        guard case .applied(let decision) = outcome else {
            return Suggestion(roleId: nil, alignmentDoubtful: false)
        }

        var suggestedRoleId: String?
        if let roleAnswer = decision.answers.first(where: { $0.id == "role_choice" }),
           roleAnswer.type == "choice",
           let choice = roleAnswer.choice, choice != "none" {
            let confidenceOk: Bool
            if let floor = settings.policy.subagentIntentMinConfidence,
               let confidence = roleAnswer.confidence {
                confidenceOk = confidence >= floor
            } else {
                confidenceOk = true
            }
            if confidenceOk, IOSSubAgentRoleCatalog.resolve(roleId: choice) != nil {
                suggestedRoleId = choice
            }
        }
        var alignmentDoubtful = false
        if let alignmentAnswer = decision.answers.first(where: { $0.id == "aligned" }),
           alignmentAnswer.type == "noul",
           let probability = alignmentAnswer.noul, probability.isFinite {
            alignmentDoubtful = probability < Self.alignmentProbabilityFloor
        }
        return Suggestion(roleId: suggestedRoleId, alignmentDoubtful: alignmentDoubtful)
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevSubAgentIntentService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 为一次 spawn 给出角色建议与对齐标注。空建议 = 调用方走现有优先级。
    /// turnBudgetKey：调用方 runId——与其他用途共享 runId 单本轮次账。
    /// shadow：协调器返回 observed，本服务不应用结果（空建议），指标照常记录。
    func suggest(
        taskText: String,
        parentRequestText: String?,
        turnBudgetKey: String
    ) async -> Suggestion {
        let settings = deps.settingsProvider()
        guard let part = Self.makeBatchPart(
            taskText: taskText,
            parentRequestText: parentRequestText,
            settings: settings
        ) else { return Suggestion(roleId: nil, alignmentDoubtful: false) }
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(part.state)
        )
        let outcome = await deps.coordinator.decide(
            useCase: part.useCase,
            requiredScopes: part.requiredScopes,
            state: part.state,
            questions: part.questions,
            context: context,
            // shadow/active 分键（全用途惯例）：协调器缓存命中不重核 revision，
            // 分键保证 shadow 期观测永远不会在切 active 后被命中应用。
            cacheKey: part.cacheKey
        )
        return Self.suggestion(from: outcome, settings: settings)
    }
}
