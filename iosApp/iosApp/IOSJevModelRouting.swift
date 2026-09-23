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
        let mode = settings.effectiveMode(for: .modelRouting)
        guard mode != .off else { return [] }
        let requiredScopes: Set<IOSJevDataScope> = [.selectedTaskText, .modelMetadata]
        guard settings.canSend(useCase: .modelRouting, required: requiredScopes) else { return [] }
        guard let part = Self.makeBatchPart(taskText: taskText, candidates: candidates) else { return [] }
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(part.state)
        )
        let cacheKey = part.cacheKey

        // shadow：后台观测只记指标，不阻塞主路径（契约表：shadow 不阻塞原主路径）。
        if mode == .shadow {
            let coordinator = deps.coordinator
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await coordinator.decide(
                    useCase: part.useCase,
                    requiredScopes: part.requiredScopes,
                    state: part.state,
                    questions: part.questions,
                    context: context,
                    cacheKey: cacheKey
                )
                _ = self
            }
            return []
        }

        let outcome = await deps.coordinator.decide(
            useCase: part.useCase,
            requiredScopes: part.requiredScopes,
            state: part.state,
            questions: part.questions,
            context: context,
            cacheKey: cacheKey
        )
        return Self.preferredModelIds(from: outcome, candidates: candidates, settings: settings)
    }

    /// 为 spawn 的单次 decideBatch 构建可复用模型调度 part。
    /// 已知不支持工具的模型在出站前硬过滤；未知能力保留并明确标成 unknown。
    static func makeBatchPart(
        taskText: String,
        candidates: [IOSSubAgentModelPool.Candidate],
        partId: String = "model_routing"
    ) -> IOSJevBatchPart? {
        let toolCapable = toolCapableCandidates(candidates)
        guard !toolCapable.isEmpty else { return nil }
        let trimmedTask = String(taskText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500))
        guard !trimmedTask.isEmpty else { return nil }

        let entries = toolCapable.map { candidate -> (id: String, description: String) in
            let modelName = candidate.model.displayName.isEmpty ? "unknown" : candidate.model.displayName
            let modelId = candidate.model.modelId.isEmpty ? "unknown" : candidate.model.modelId
            let providerName = candidate.provider.name.isEmpty ? "unknown" : candidate.provider.name
            let abilities = candidate.model.abilities.isEmpty
                ? "unknown"
                : candidate.model.abilities.map { $0.name.lowercased() }.sorted().joined(separator: ",")
            let contextWindow = intValue(candidate.model.contextWindowTokens)
                .map { "\($0) tokens" } ?? "unknown"
            let supportedReasoning = candidate.supportedReasoning.isEmpty
                ? "unknown"
                : candidate.supportedReasoning.map { $0.name.lowercased() }.sorted().joined(separator: ",")
            let configuredReasoning = candidate.configuredReasoning?.name.lowercased() ?? "unknown"
            let description = "name=\(modelName); model_id=\(modelId); provider=\(providerName); abilities=\(abilities); context=\(contextWindow); supported_reasoning=\(supportedReasoning); configured_reasoning=\(configuredReasoning)"
            return (candidate.modelId, description)
        }
        var lines = [
            "子任务文本：\(trimmedTask)",
            "候选模型（id = 本地候选 UUID；unknown 表示该事实未提供）：",
        ]
        lines += entries.map { "- \($0.id): \($0.description)" }
        let state = lines.joined(separator: "\n")
        let questions = entries.map { entry in
            IOSJevQuestion.score(
                id: entry.id,
                levels: fitLevels,
                instructions: "评估该模型执行此子任务的适配度。以已提供的能力事实为主要依据，模型名称只作辅助参考；unknown 表示未提供，不得自行补全或假设模型能力。"
            )
        }
        return IOSJevBatchPart(
            id: partId,
            useCase: .modelRouting,
            requiredScopes: [.selectedTaskText, .modelMetadata],
            state: state,
            questions: questions,
            cacheKey: partId
        )
    }

    /// 只解析 active 成功结果；UUID 必须仍属于当前池，未知或不可用条目不入选。
    static func preferredModelIds(
        from outcome: IOSJevDecisionOutcome,
        candidates: [IOSSubAgentModelPool.Candidate],
        settings: IOSJevSettings
    ) -> [String] {
        guard case .applied(let decision) = outcome else { return [] }
        let candidateIds = Set(toolCapableCandidates(candidates).map(\.modelId))
        var scores: [String: Double] = [:]
        var confidences: [String: Double] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard candidateIds.contains(answer.id), let score = answer.score else { continue }
            scores[answer.id] = score
            if let confidence = answer.confidence { confidences[answer.id] = confidence }
        }
        let minConfidence = settings.policy.modelRoutingMinConfidence
        let scored = candidateIds.compactMap { candidateId -> (String, Double)? in
            guard let score = scores[candidateId], score >= settings.policy.modelRoutingMinScore else { return nil }
            // 置信弃权：低于 policy 阈值不进首选集；置信缺失不门控。
            if let minConfidence, let confidence = confidences[candidateId], confidence < minConfidence { return nil }
            return (candidateId, score)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return sorted.map { pair in pair.0 }
    }

    private static func toolCapableCandidates(
        _ candidates: [IOSSubAgentModelPool.Candidate]
    ) -> [IOSSubAgentModelPool.Candidate] {
        candidates.filter { candidate in
            let abilities = candidate.model.abilities
            return abilities.isEmpty || abilities.contains { $0.name == "TOOL" }
        }
    }

    /// 在 Jev 首选集合内切出仍存在的池内候选（保持 Jev 顺序）。
    static func preferredCandidates(
        from candidates: [IOSSubAgentModelPool.Candidate],
        rankedIds: [String]
    ) -> [IOSSubAgentModelPool.Candidate] {
        guard !rankedIds.isEmpty else { return [] }
        return rankedIds.compactMap { rankedId in
            candidates.first { $0.modelId.caseInsensitiveCompare(rankedId) == .orderedSame }
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
