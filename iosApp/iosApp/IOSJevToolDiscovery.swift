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

    static let suitabilityQuestionID = "jev_tool_discovery_suitable"

    struct RunIdentity: Sendable {
        var runId: String?
        var turnBudgetKey: String
        /// 只有前台 Host 会在下一模型响应/终态消费 tracker；后台与 Recipe 不登记。
        var trackNextForegroundStep: Bool = false
    }

    /// 轮次预算 key：runId（本 App 的 run 即一次用户输入及其工具续跑；steer
    /// 不清空当轮已用预算，与计划口径一致）。全部用途共用同一本轮账。
    /// 非可选调用点可能传空串（如 WebMount 默认 runId），与 nil 统一兜底 "run"，
    /// 避免同轮账分裂成 "" 与 "run" 两本。
    static func turnBudgetKey(runId: String?) -> String {
        if let runId, !runId.isEmpty { return runId }
        return "run"
    }

    /// 三条路径共用的执行入口。返回 tool_search 的最终输出 JSON。
    /// @MainActor：bridge 与 KMP 目录是非 Sendable 类型，保持在调用方 actor 上。
    @MainActor
    static func execute(
        argumentsJson: String,
        selectedTaskText: String = "",
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

        guard let request = makeRequest(
            parsed: parsed,
            selectedTaskText: selectedTaskText,
            settings: settings
        ) else {
            return bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        let inputHash = Self.stableHash(request.state + "|" + request.questions.map(\.id).joined(separator: ","))
        let context = IOSJevRunContext(
            runId: identity.runId,
            turnBudgetKey: identity.turnBudgetKey,
            inputHash: inputHash
        )
        let keywordTop1 = parsed.candidates.max { $0.keywordScore < $1.keywordScore }?.name

        func keywordFallback() -> String {
            bridge.executeToolSearch(argumentsJson: argumentsJson)
        }

        let keywordExposureNames = Self.expandedToolNames(
            from: bridge.previewToolSearch(argumentsJson: argumentsJson)
        )

        // shadow：后台观测只记指标（含建议排序），不阻塞 tool_search 主路径。
        if effectiveMode == .shadow {
            let coordinator = coordinator
            Task(priority: .utility) { @MainActor in
                let outcome = await coordinator.decide(
                    useCase: .toolDiscovery,
                    requiredScopes: requiredScopes,
                    state: request.state,
                    questions: request.questions,
                    context: context,
                    cacheKey: "tool_discovery_shadow",
                    waitBudgetMs: settings.policy.deadlineMs,
                    expectedSettingsRevision: settings.revision,
                    metricSuggestionProvider: { decision in
                        (rankingTop1(decision, candidates: parsed.candidates), keywordTop1)
                    }
                )
                guard case .observed(let decision) = outcome,
                      !keywordExposureNames.isEmpty else { return }
                let suitable = (decision.answers.first(where: { $0.id == request.suitabilityQuestionID })?.noul ?? 0) >= 0.5
                let predictedRanking = suitable
                    ? ranking(from: decision, candidates: request.candidates,
                              minScore: settings.policy.toolDiscoveryMinScore,
                              minConfidence: settings.policy.toolDiscoveryMinConfidence)
                    : nil
                let predicted = predictedRanking.map {
                    Self.expandedToolNames(from: bridge.previewToolSearch(argumentsJson: argumentsJson, rankingOverride: $0))
                } ?? keywordExposureNames
                IOSJevMetricsStore.append(IOSJevMetricsRecord(
                    timestamp: Date(), useCase: .toolDiscovery, mode: .shadow,
                    modelVersion: settings.activeModelVersion, outcome: "summary",
                    latencyMs: 0, requestBytes: 0, responseBytes: 0,
                    inputTokens: nil, outputTokens: nil, reason: nil,
                    runId: context.runId,
                    numbers: ["exposure_ratio": Double(predicted.count) / Double(keywordExposureNames.count)]
                ))
            }
            return keywordFallback()
        }

        let visibleBeforeDecision = Set(bridge.visibleTools().map(\.name))

        func recordActiveExposure(_ output: String, jevRanked: Bool) {
            let activeExposureNames = Self.expandedToolNames(from: output)
            IOSJevToolDiscoveryMetricsTracker.recordExposureRatio(
                runId: context.runId,
                modelVersion: settings.activeModelVersion,
                activeExposureCount: activeExposureNames.count,
                keywordExposureCount: keywordExposureNames.count
            )
            guard jevRanked, identity.trackNextForegroundStep else { return }
            IOSJevToolDiscoveryMetricsTracker.registerActiveExposure(
                runId: context.runId,
                exposedToolNames: activeExposureNames.subtracting(visibleBeforeDecision),
                modelVersion: settings.activeModelVersion
            )
        }

        func activeKeywordFallback() -> String {
            let output = keywordFallback()
            recordActiveExposure(output, jevRanked: false)
            return output
        }

        func appliedFallback(_ reason: String) -> String {
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: Date(), useCase: .toolDiscovery, mode: .active,
                modelVersion: settings.activeModelVersion, outcome: "summary",
                latencyMs: 0, requestBytes: 0, responseBytes: 0,
                inputTokens: nil, outputTokens: nil, reason: reason,
                runId: context.runId, numbers: ["business_fallback": 1]
            ))
            return activeKeywordFallback()
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
            guard let suitability = decision.answers.first(where: { $0.id == request.suitabilityQuestionID })?.noul,
                  suitability >= 0.5 else {
                return appliedFallback("no_suitable_tool")
            }
            if let ranking = ranking(from: decision, candidates: request.candidates, minScore: settings.policy.toolDiscoveryMinScore, minConfidence: settings.policy.toolDiscoveryMinConfidence) {
                let output = bridge.executeToolSearch(argumentsJson: argumentsJson, rankingOverride: ranking)
                recordActiveExposure(output, jevRanked: true)
                return output
            }
            // 低置信 / 无足够候选：回退原搜索。
            return appliedFallback("ranking_unavailable")
        case .observed, .skipped, .failed:
            return activeKeywordFallback()
        }
    }

    private static func expandedToolNames(from payload: String) -> Set<String> {
        guard let object = snapshotJSON(payload),
              let names = object["expanded_tools"] as? [String] else { return [] }
        return Set(names)
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
        var candidates: [SnapshotCandidate]
        var suitabilityQuestionID: String
    }

    private static let relevanceLevels = [
        "0 = 与查询意图无关",
        "1 = 略有关联但通常不是用户要找的",
        "2 = 相关，能合理完成查询意图",
        "3 = 高度相关，就是该意图的合适工具",
    ]

    /// state = 查询 + 候选元数据（每条描述截断，防 48KiB 超限；仍超则整体放弃）。
    /// internal：契约测试锁定"每候选一题 ≤ maxQuestions"（客户端对超题数是硬拒绝，
    /// 且 KMP 快照池的 32 条上限与本截断各自独立，任何一侧调整都不许打破）。
    static func makeRequest(
        parsed: ParsedSnapshot,
        selectedTaskText: String = "",
        settings: IOSJevSettings
    ) -> BuiltRequest? {
        guard settings.policy.maxQuestions > 1 else { return nil }
        let maxCandidates = min(settings.policy.maxCandidates, settings.policy.maxQuestions - 1, parsed.candidates.count)
        let candidates = Array(parsed.candidates.prefix(maxCandidates))
        guard !candidates.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("用户查询：\(parsed.query)")
        let trimmedTaskText = String(selectedTaskText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        if !trimmedTaskText.isEmpty {
            lines.append("用户最新原话：\(trimmedTaskText)")
        }
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
        let candidateQuestions = candidates.map { candidate in
            IOSJevQuestion.score(
                id: candidate.name,
                levels: relevanceLevels,
                instructions: "评估候选工具「\(candidate.name)」对用户查询和用户最新原话所表达意图的语义相关性。只依据意图与候选描述，不因候选在列表中的位置产生偏好。"
            )
        }
        let candidateIDs = Set(candidates.map(\.name))
        var suitabilityQuestionID = Self.suitabilityQuestionID
        while candidateIDs.contains(suitabilityQuestionID) {
            suitabilityQuestionID += "_"
        }
        let suitabilityQuestion = IOSJevQuestion.noul(
            id: suitabilityQuestionID,
            instructions: "候选工具中是否至少有一个能够完成用户查询和用户最新原话表达的意图？仅当候选列表中确有合适工具时回答是；否则回答否。"
        )
        return BuiltRequest(
            state: state,
            questions: candidateQuestions + [suitabilityQuestion],
            candidates: candidates,
            suitabilityQuestionID: suitabilityQuestionID
        )
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
        minScore: Double,
        minConfidence: Double? = nil
    ) -> [String]? {
        var scores: [String: (score: Double, confidence: Double?)] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard let score = answer.score else { continue }
            scores[answer.id] = (score, answer.confidence)
        }
        let indexed = Array(candidates.enumerated())
        // 置信弃权：低于 policy 阈值的候选直接剔除（不参与排序与入选）；
        // 置信缺失不门控。
        var abstained = Set<String>()
        if let minConfidence {
            for candidate in candidates {
                if let confidence = scores[candidate.name]?.confidence, confidence < minConfidence {
                    abstained.insert(candidate.name)
                }
            }
        }
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
        let surviving = ordered.filter { !abstained.contains($0.name) && $0.score >= minScore }
        // 空集 = 低置信 / 无足够候选：回退原搜索。
        return surviving.isEmpty ? nil : surviving.map(\.name)
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

/// In-memory correlation between an active Jev exposure and the next assistant
/// model response. Tool names stay only in this short-lived tracker; persisted
/// metrics contain the 0/1 outcome and run ID, never the query text.
@MainActor
enum IOSJevToolDiscoveryMetricsTracker {
    private struct PendingExposure {
        var toolNames: Set<String>
        var modelVersion: String
    }

    private static var pendingByRun: [String: [PendingExposure]] = [:]

    static func recordExposureRatio(
        runId: String?,
        modelVersion: String,
        activeExposureCount: Int,
        keywordExposureCount: Int
    ) {
        guard keywordExposureCount > 0 else { return }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(), useCase: .toolDiscovery, mode: .active,
            modelVersion: modelVersion, outcome: "summary",
            latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: nil,
            runId: runId,
            numbers: ["exposure_ratio": Double(activeExposureCount) / Double(keywordExposureCount)]
        ))
    }

    /// Called after an active ranked result has updated bridge exposure.
    /// Names are held only until the following model step is observed.
    static func registerActiveExposure(
        runId: String?,
        exposedToolNames: Set<String>,
        modelVersion: String = ""
    ) {
        guard let key = validRunKey(runId), !exposedToolNames.isEmpty else { return }
        pendingByRun[key, default: []].append(
            PendingExposure(toolNames: exposedToolNames, modelVersion: modelVersion)
        )
    }

    /// Call once when the next assistant model response is available, before
    /// its tool calls execute. Multiple searches from the prior step are
    /// evaluated independently against this same response.
    static func recordNextModelStep(runId: String?, calledToolNames: Set<String>) {
        guard let key = validRunKey(runId),
              let exposures = pendingByRun.removeValue(forKey: key) else { return }
        for exposure in exposures {
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: Date(), useCase: .toolDiscovery, mode: .active,
                modelVersion: exposure.modelVersion, outcome: "summary",
                latencyMs: 0, requestBytes: 0, responseBytes: 0,
                inputTokens: nil, outputTokens: nil, reason: nil,
                runId: key,
                numbers: ["next_step_new_tool_used": exposure.toolNames.isDisjoint(with: calledToolNames) ? 0 : 1]
            ))
        }
    }

    /// Drop pending observations when a run ends without another assistant
    /// model response (for example, cancellation).
    static func discardPending(runId: String?) {
        guard let key = validRunKey(runId) else { return }
        pendingByRun.removeValue(forKey: key)
    }

    private static func validRunKey(_ runId: String?) -> String? {
        guard let runId, !runId.isEmpty else { return nil }
        return runId
    }
}
