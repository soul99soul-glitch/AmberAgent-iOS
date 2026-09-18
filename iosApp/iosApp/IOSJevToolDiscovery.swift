import Foundation
@preconcurrency import Shared

// MARK: - Jev 工具语义发现（Phase 1）
//
// 统一前台 executeToolSearchToolCall、后台 tool_search executor、Recipe
// discovery 三条路径的异步搜索服务。契约：
// - 精确工具名查询直接走原搜索，零 Jev 网络。
// - 候选来自 bridge 的纯快照（关键词 + 类别补充，全部属于当前 run 目录）。
// - 仅 active 应用 Jev 排序；shadow 记录建议与指标但返回原关键词结果。
// - 失败 / 超时 / 低置信 / 候选不足 → 回退原同步搜索（fallback 语义不变）。
// - 暴露集合只经 bridge.executeToolSearch 更新；发现 ≠ 授权执行。

enum IOSJevToolDiscoveryService {

    struct RunIdentity: Sendable {
        var runId: String?
        var turnBudgetKey: String
    }

    /// 轮次预算 key：runId（本 App 的 run 即一次用户输入及其工具续跑；steer
    /// 不清空当轮已用预算，与计划口径一致）。全部用途共用同一本轮账。
    static func turnBudgetKey(runId: String?) -> String {
        runId ?? "run"
    }

    /// 三条路径共用的执行入口。返回 tool_search 的最终输出 JSON。
    /// @MainActor：bridge 与 KMP 目录是非 Sendable 类型，保持在调用方 actor 上。
    @MainActor
    static func execute(
        argumentsJson: String,
        bridge: IosToolExposureBridge?,
        coordinator: IOSJevDecisionCoordinator = .shared,
        settingsProvider: @escaping () -> IOSJevSettings = { IOSSharedSettingsStore.loadPersistedJevSettings() },
        identity: RunIdentity
    ) async -> String {
        guard let bridge else {
            return ChatToolOutputFormatter.toolFailureJSON(toolName: "tool_search", reason: "tool_search 当前不可用。")
        }
        let settings = settingsProvider()
        let effectiveMode = settings.effectiveMode(for: .toolDiscovery)

        // 精确名与 off：直接原搜索，零 Jev 网络。
        if effectiveMode == .off {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        // 纯候选快照（不改暴露）。exact_match 或快照失败 → 原搜索。
        guard let snapshotData = snapshotJSON(bridge.candidateSnapshot(argumentsJson: argumentsJson)),
              let parsed = parseSnapshot(snapshotData) else {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }
        if parsed.exactMatch != nil {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }
        guard !parsed.candidates.isEmpty else {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        let requiredScopes: Set<IOSJevDataScope> = [.toolMetadata, .selectedTaskText]
        guard settings.canSend(useCase: .toolDiscovery, required: requiredScopes) else {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        guard let request = makeRequest(parsed: parsed, settings: settings) else {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        let inputHash = Self.stableHash(request.state + "|" + request.questions.map(\.id).joined(separator: ","))
        let context = IOSJevRunContext(
            runId: identity.runId,
            turnBudgetKey: identity.turnBudgetKey,
            inputHash: inputHash
        )
        let keywordTop1 = parsed.candidates.max { $0.keywordScore < $1.keywordScore }?.name
        let keywordFallback = bridge.executeToolSearch(argumentsJson: argumentsJson)

        // shadow：后台观测只记指标（含建议排序），不阻塞 tool_search 主路径。
        if effectiveMode == .shadow {
            let coordinator = coordinator
            Task(priority: .utility) {
                _ = await coordinator.decide(
                    useCase: .toolDiscovery,
                    requiredScopes: requiredScopes,
                    state: request.state,
                    questions: request.questions,
                    context: context,
                    cacheKey: "tool_discovery_shadow",
                    metricSuggestionProvider: { decision in
                        (rankingTop1(decision, candidates: parsed.candidates), keywordTop1)
                    }
                )
            }
            return keywordFallback
        }

        // active：应用 Jev 排序（失败/低置信回退关键词结果）。
        let outcome = await coordinator.decide(
            useCase: .toolDiscovery,
            requiredScopes: requiredScopes,
            state: request.state,
            questions: request.questions,
            context: context,
            cacheKey: "tool_discovery",
            metricSuggestionProvider: { decision in
                (rankingTop1(decision, candidates: parsed.candidates), keywordTop1)
            }
        )
        switch outcome {
        case .applied(let decision):
            if let ranking = ranking(from: decision, candidates: parsed.candidates, minScore: settings.policy.toolDiscoveryMinScore) {
                return bridge.executeToolSearch(argumentsJson: argumentsJson, rankingOverride: ranking)
            }
            // 低置信 / 无足够候选：回退原搜索。
            return keywordFallback
        case .observed, .skipped, .failed:
            return keywordFallback
        }
    }

    // MARK: Snapshot parsing

    struct SnapshotCandidate {
        var name: String
        var category: String
        var description: String
        var mutates: Bool
        var keywordScore: Int
    }

    struct ParsedSnapshot {
        var query: String
        var category: String?
        var exactMatch: String?
        var candidates: [SnapshotCandidate]
    }

    private static func snapshotJSON(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func parseSnapshot(_ object: [String: Any]) -> ParsedSnapshot? {
        guard object["status"] as? String == "ok" else { return nil }
        let query = object["query"] as? String ?? ""
        guard !query.isEmpty else { return nil }
        let rawCandidates = object["candidates"] as? [[String: Any]] ?? []
        let candidates = rawCandidates.compactMap { raw -> SnapshotCandidate? in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return SnapshotCandidate(
                name: name,
                category: raw["category"] as? String ?? "",
                description: raw["description"] as? String ?? "",
                mutates: raw["mutates"] as? Bool ?? false,
                keywordScore: raw["score"] as? Int ?? 0
            )
        }
        return ParsedSnapshot(
            query: query,
            category: object["category"] as? String,
            exactMatch: object["exact_match"] as? String,
            candidates: candidates
        )
    }

    // MARK: Request building

    struct BuiltRequest {
        var state: String
        var questions: [IOSJevQuestion]
    }

    private static let relevanceLevels = [
        "0 = 与查询意图无关",
        "1 = 略有关联但通常不是用户要找的",
        "2 = 相关，能合理完成查询意图",
        "3 = 高度相关，就是该意图的合适工具",
    ]

    /// state = 查询 + 候选元数据（每条描述截断，防 48KiB 超限；仍超则整体放弃）。
    private static func makeRequest(parsed: ParsedSnapshot, settings: IOSJevSettings) -> BuiltRequest? {
        let maxCandidates = min(settings.policy.maxCandidates, parsed.candidates.count)
        let candidates = Array(parsed.candidates.prefix(maxCandidates))
        var lines: [String] = []
        lines.append("用户查询：\(parsed.query)")
        if let category = parsed.category {
            lines.append("限定类别：\(category)")
        }
        lines.append("候选工具（id = 工具名）：")
        for candidate in candidates {
            let description = String(candidate.description.prefix(200))
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(candidate.name) [\(candidate.category)]\(candidate.mutates ? " (mutates)" : ""): \(description)")
        }
        let state = lines.joined(separator: "\n")
        let questions = candidates.map { candidate in
            IOSJevQuestion.score(
                id: candidate.name,
                levels: relevanceLevels,
                instructions: "评估候选工具「\(candidate.name)」对用户查询的语义相关性。只依据查询意图与候选描述，不因候选在列表中的位置产生偏好。"
            )
        }
        return BuiltRequest(state: state, questions: questions)
    }

    /// Score 0-3 分量表 → 排序。任一候选达到 minScore 才算足够；全部低于阈值
    /// 视为无足够候选（保持关键词结果）。分数并列时保持快照顺序（稳定）。
    /// 决策中的最高分候选名（无有效评分返回 nil）。
    private static func rankingTop1(
        _ decision: IOSJevDecision,
        candidates: [SnapshotCandidate]
    ) -> String? {
        var best: (String, Double)?
        for answer in decision.answers where answer.type == "score" {
            guard let score = answer.score else { continue }
            if let current = best {
                if score > current.1 { best = (answer.id, score) }
            } else {
                best = (answer.id, score)
            }
        }
        return best?.0
    }

    private static func ranking(
        from decision: IOSJevDecision,
        candidates: [SnapshotCandidate],
        minScore: Double
    ) -> [String]? {
        var scores: [String: (score: Double, confidence: Double?)] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard let score = answer.score else { continue }
            scores[answer.id] = (score, answer.confidence)
        }
        let indexed = Array(candidates.enumerated())
        let ordered = indexed
            .map { index, candidate in
                let entry = scores[candidate.name]
                return (index: index, name: candidate.name, score: entry?.score ?? 0, keyword: candidate.keywordScore)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.keyword != $1.keyword { return $0.keyword > $1.keyword }
                return $0.index < $1.index
            }
        guard let best = ordered.first, best.score >= minScore else { return nil }
        return ordered.filter { $0.score >= minScore }.map(\.name)
    }

    static func stableHash(_ text: String) -> String {
        // 非 cryptographic：仅用于缓存键与身份核对。
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
