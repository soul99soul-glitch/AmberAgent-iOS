import Foundation
@preconcurrency import Shared

// MARK: - Jev 子任务模型调度（Phase 3）
//
// 契约（计划 Phase 3.3）：
// - 只作用于现有规则允许从模型池自动选择的 spawn/followup 分支；显式 model_id、
//   角色默认、继承模型的明确选择不被覆盖。
// - 只使用用户当前启用且配置有效的池内候选（候选由 IOSSubAgentModelPool 给出，
//   已含 enabled/配置有效性硬过滤）；能力未知按 unknown 上送，不按名称推断。
// - Jev 返回"适配"排序；程序在 Jev 首选集合内再用现有负载/轮转选择——
//   select+reserve 仍在 MainActor 无 await 临界段完成，await 期间不占名额。
// - 不确定 / 失败 / 范围未允许 → 返回空，走现有选择。

@MainActor
final class IOSJevModelRoutingService {

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevModelRoutingService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 返回 Jev 判定为"适配当前任务"的模型 id（按适配度降序）。空 = 走现有选择。
    /// 每个候选一个 Score 题（0-3 适配度）；缺题/无效分数 = 不确定 = 不进入首选集。
    /// turnBudgetKey：调用方的 runId——模型调度预算按 run 记账，而非 App 全局。
    /// shadow：后台观测只记指标，不阻塞主路径（立即返回空）。
    func rankedPreferredModelIds(
        taskText: String,
        candidates: [IOSSubAgentModelPool.Candidate],
        turnBudgetKey: String
    ) async -> [String] {
        guard !candidates.isEmpty else { return [] }
        let settings = deps.settingsProvider()
        guard settings.effectiveMode(for: .modelRouting) != .off else { return [] }
        let requiredScopes: Set<IOSJevDataScope> = [.selectedTaskText]
        guard settings.canSend(useCase: .modelRouting, required: requiredScopes) else { return [] }

        let trimmedTask = String(taskText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500))
        guard !trimmedTask.isEmpty else { return [] }

        // state/questions 构建一次，active 与 shadow 共用。
        let entries = candidates.map { candidate -> (id: String, description: String) in
            let contextWindow = Self.intValue(candidate.model.contextWindowTokens)
                .map { "context=\($0) tokens" } ?? "context=unknown"
            return (candidate.model.modelId, "\(candidate.model.modelId) (\(contextWindow))")
        }
        var lines: [String] = []
        lines.append("子任务文本：\(trimmedTask)")
        lines.append("候选模型（id = 模型标识）：")
        for entry in entries {
            lines.append("- \(entry.id): \(entry.description)")
        }
        let state = lines.joined(separator: "\n")
        let questions = entries.map { entry in
            IOSJevQuestion.score(
                id: entry.id,
                levels: Self.fitLevels,
                instructions: "评估该模型执行此子任务的适配度。依据任务复杂度与模型上下文容量，不对未知能力做假设，不因标识中出现熟悉名称而加分。"
            )
        }
        let context = IOSJevRunContext(
            runId: nil,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(state)
        )

        // shadow：后台观测只记指标，不阻塞主路径（契约表：shadow 不阻塞原主路径）。
        if settings.effectiveMode(for: .modelRouting) == .shadow {
            let coordinator = deps.coordinator
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await coordinator.decide(
                    useCase: .modelRouting,
                    requiredScopes: requiredScopes,
                    state: state,
                    questions: questions,
                    context: context,
                    cacheKey: "model_routing_shadow"
                )
                _ = self
            }
            return []
        }

        let outcome = await deps.coordinator.decide(
            useCase: .modelRouting,
            requiredScopes: requiredScopes,
            state: state,
            questions: questions,
            context: context,
            cacheKey: "model_routing"
        )
        guard case .applied(let decision) = outcome else { return [] }

        var scores: [String: Double] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard let score = answer.score, answer.id.count <= 128 else { continue }
            scores[answer.id] = score
        }
        let scored = entries.compactMap { entry -> (String, Double)? in
            guard let score = scores[entry.id], score >= settings.policy.modelRoutingMinScore else { return nil }
            return (entry.id, score)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return sorted.map { pair in pair.0 }
    }

    /// 在 Jev 首选集合内切出仍存在的池内候选（保持 Jev 顺序）。
    static func preferredCandidates(
        from candidates: [IOSSubAgentModelPool.Candidate],
        rankedIds: [String]
    ) -> [IOSSubAgentModelPool.Candidate] {
        guard !rankedIds.isEmpty else { return [] }
        return rankedIds.compactMap { rankedId in
            candidates.first { $0.model.modelId.caseInsensitiveCompare(rankedId) == .orderedSame }
        }
    }

    private static func intValue(_ tokens: KotlinInt?) -> Int64? {
        tokens?.int64Value
    }

    private static let fitLevels = [
        "0 = 无法胜任（能力明显不符）",
        "1 = 勉强可做但大概率不理想",
        "2 = 可以胜任",
        "3 = 与该任务高度匹配",
    ]
}
