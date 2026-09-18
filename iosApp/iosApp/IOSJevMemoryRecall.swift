import Foundation
@preconcurrency import Shared

// MARK: - Jev 记忆语义召回（Phase 1）
//
// 契约（计划 Phase 1 步骤 5）：
// - 硬筛选（memory scope 开关、archived、expiresAt）先于外发候选构建，Jev
//   不能扩大合法候选范围。
// - 保留 ChatMemoryContextBuilder 的同步原行为；本服务在异步请求准备层调用，
//   由 builder 根据合法排序结果组装 prompt。
// - 候选包含词面匹配、新近记忆及合法 scope 内补充条目（不能先排除零命中）。
// - 每条候选独立 Score（0-3 同量表）；置顶/核心等强保留语义继续满足；最后
//   执行原条数与字符预算。
// - 输出具体 MemoryRecord.id，不改写记忆文本。
// - **一次计算选中集合**：统一供 prompt、metadata、usage marking 与 citation
//   allowlist 使用——prepareTurnSelection 的返回值由 run host 显式传给注入与
//   usage marking，禁止两处各自计算。
// - shadow 不影响注入、不标记已使用；memory_tool 主动 search/query 行为不变。
// - 为同一 user turn 的工具循环复用结果；steer、内容/范围/配置变化时失效
//   （turnKey 含最后一条 user 消息 id + 记录指纹 + 设置 revision）。

@MainActor
final class IOSJevMemoryRecallService {

    struct RunIdentity: Sendable {
        var runId: String?
    }

    struct TurnSelection {
        var key: String
        var result: ChatMemoryContextBuilder.RecallResult
        var appliedByJev: Bool
    }

    static let shared = IOSJevMemoryRecallService()

    private var currentSelection: TurnSelection?

    /// shadow 模式最近一次已观测的 turnKey：同轮不重复发起/记录。
    private var lastShadowObservedKey: String?

    /// 防并发同轮重复发起判断：同 key 在途时后来者不等待，直接回退同步原行为。
    private var inFlightKey: String?

    private let coordinator: IOSJevDecisionCoordinator
    private let settingsProvider: () -> IOSJevSettings

    init(
        coordinator: IOSJevDecisionCoordinator = .shared,
        settingsProvider: @escaping () -> IOSJevSettings = { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ) {
        self.coordinator = coordinator
        self.settingsProvider = settingsProvider
    }

    // MARK: Async prep（每轮 prepareUploadMessages 调用一次）

    /// active：计算并返回本轮统一选中集合（调用方显式传给注入与 usage
    /// marking）；失败/超时返回 nil，回退同步原行为。shadow：后台评估只记
    /// 指标，返回 nil。off：返回 nil、零网络。
    /// 同一 turnKey 已缓存时直接复用（工具循环多轮不重复发起判断）。
    func prepareTurnSelection(
        messages: [UIMessage],
        records: [MemoryRecord],
        runtime: AgentRuntimeSetting,
        identity: RunIdentity
    ) async -> ChatMemoryContextBuilder.RecallResult? {
        let settings = settingsProvider()
        // 硬筛选先于外发候选构建：归档/过期记忆不得进入 state（与注入侧共用入口）。
        let eligible = ChatMemoryContextBuilder.hardEligible(
            ChatMemoryContextBuilder.recordsForPrompt(records: records, runtime: runtime)
        )
        let key = Self.turnKey(messages: messages, eligible: eligible, settingsRevision: settings.revision)

        if let cached = currentSelection, cached.key == key {
            return cached.result
        }
        currentSelection = nil

        let effectiveMode = settings.effectiveMode(for: .memoryRecall)
        guard effectiveMode != .off else { return nil }
        let queryText = messages.reversed().first { $0.role == MessageRole.user }?.toText() ?? ""

        // 候选：词面命中 + 新近 + 全量补充（小集合全评估，大集合截断并记覆盖）。
        let candidates = candidatePool(eligible: eligible, queryText: queryText, policy: settings.policy)
        guard !candidates.isEmpty else { return nil }

        let requiredScopes: Set<IOSJevDataScope> = [.selectedTaskText, .personalMemory]
        guard settings.canSend(useCase: .memoryRecall, required: requiredScopes) else { return nil }

        guard effectiveMode == .active else {
            // shadow：不阻塞主路径——脱离当前 async 上下文后台评估，只记指标。
            // 同一轮（同 key）只观测一次，避免工具循环逐轮刷重复指标。
            guard lastShadowObservedKey != key else { return nil }
            lastShadowObservedKey = key
            let coordinator = self.coordinator
            let context = makeContext(identity: identity, settings: settings, inputHash: hashInput(queryText, candidates))
            let state = stateText(queryText: queryText, candidates: candidates)
            let questions = scoreQuestions(for: candidates)
            Task(priority: .utility) {
                _ = await coordinator.decide(
                    useCase: .memoryRecall,
                    requiredScopes: requiredScopes,
                    state: state,
                    questions: questions,
                    context: context,
                    cacheKey: "memory_shadow"
                )
            }
            return nil
        }

        // active：等待判断（deadline 1.2s 上限）；同 key 在途时后来者直接回退同步原行为。
        guard beginInFlight(key) else { return nil }
        defer { endInFlight() }

        let context = makeContext(identity: identity, settings: settings, inputHash: hashInput(queryText, candidates))
        let outcome = await coordinator.decide(
            useCase: .memoryRecall,
            requiredScopes: requiredScopes,
            state: stateText(queryText: queryText, candidates: candidates),
            questions: scoreQuestions(for: candidates),
            context: context,
            cacheKey: "memory_active"
        )
        guard case .applied(let decision) = outcome else { return nil }

        let ordered = Self.orderedSelection(
            eligible: eligible,
            candidates: candidates,
            decision: decision,
            minScore: settings.policy.memoryRecallMinScore,
            queryText: queryText,
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: eligible,
            runtime: runtime,
            queryText: queryText,
            orderedSelection: ordered
        )
        guard result.records.isEmpty == false || ordered.isEmpty else { return nil }
        let selection = TurnSelection(key: key, result: result, appliedByJev: true)
        currentSelection = selection
        return selection.result
    }

    // MARK: Candidate pool

    /// 词面命中 + 新近（30 天窗口降序）+ 合法集合补充，去重后有界。
    private func candidatePool(eligible: [MemoryRecord], queryText: String, policy: IOSJevPolicy) -> [MemoryRecord] {
        let maxCandidates = min(policy.maxCandidates, 32)
        let tokens = Set(ChatMemoryContextBuilder.recallTokens(from: queryText))
        var pool: [MemoryRecord] = []
        var seen = Set<Int32>()
        func add(_ record: MemoryRecord) {
            guard seen.insert(record.id).inserted else { return }
            guard pool.count < maxCandidates else { return }
            pool.append(record)
        }
        // 1) 词面命中（含中文 bigram）。
        for record in eligible where ChatMemoryContextBuilder.recallMatchText(record).hasRecallOverlapFallback(tokens) {
            add(record)
        }
        // 2) 新近记忆（updatedAt 降序前 12），保证零词面命中也可被语义召回。
        for record in eligible.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(12) {
            add(record)
        }
        // 3) 合法集合补充（保持原顺序）。
        for record in eligible {
            if pool.count >= maxCandidates { break }
            add(record)
        }
        return pool
    }

    // MARK: Score request

    private static let relevanceLevels = [
        "0 = 与当前任务无关",
        "1 = 边缘相关，大概率不需要注入",
        "2 = 相关，注入后可能影响回复",
        "3 = 明确相关，应注入当前上下文",
    ]

    private func scoreQuestions(for candidates: [MemoryRecord]) -> [IOSJevQuestion] {
        candidates.map { record in
            IOSJevQuestion.score(
                id: "m\(record.id)",
                levels: Self.relevanceLevels,
                instructions: "评估该条用户记忆对当前任务文本的相关性。置顶或核心记忆已在其他机制中保证保留，本评分只决定普通记忆的注入优先级。"
            )
        }
    }

    private func stateText(queryText: String, candidates: [MemoryRecord]) -> String {
        var lines: [String] = []
        lines.append("当前任务文本：\(String(queryText.prefix(2_000)))")
        lines.append("候选记忆（id = m<记忆ID>）：")
        for record in candidates {
            let content = String(record.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
                .replacingOccurrences(of: "\n", with: " ")
            let pinned = record.pinned ? " (pinned)" : ""
            lines.append("- m\(record.id) [\(record.scope.wireName)/\(record.kind.wireName)\(pinned)]: \(content)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Ordering

    /// Jev 排序 + 强保留语义 + 预算，产出最终选中集合：
    /// - Jev 高分记忆按分降序入选（pinned/core 也可通过评分入选）；
    /// - 强保留（pinned/core，计划点名的置顶/核心语义）未被选中时插到最前，
    ///   保证存在性不低于基线；feedback / 高置信 user 等次级规则交由 Jev 评分
    ///   决定（语义召回提供信号后，零信号兜底规则不再主导排序）；
    /// - topic 聚合行不参与 Jev 评分，保留原 mid-tier 行为。
    static func orderedSelection(
        eligible: [MemoryRecord],
        candidates: [MemoryRecord],
        decision: IOSJevDecision,
        minScore: Double,
        queryText: String,
        now: Int64
    ) -> [MemoryRecord] {
        var scores: [Int32: Double] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard let score = answer.score, answer.id.hasPrefix("m"),
                  let id = Int32(answer.id.dropFirst()) else { continue }
            scores[id] = score
        }
        let candidateIds = Set(candidates.map(\.id))
        var selectedIds = Set<Int32>()
        var ordered: [MemoryRecord] = []

        // 1) Jev 高分记忆（仅限外发候选集合内）。
        let scored = eligible
            .filter { candidateIds.contains($0.id) && $0.kind != .topic }
            .compactMap { record -> (MemoryRecord, Double)? in
                guard let score = scores[record.id], score >= minScore else { return nil }
                return (record, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
                return $0.0.id < $1.0.id
            }
        for (record, _) in scored {
            guard selectedIds.insert(record.id).inserted else { continue }
            ordered.append(record)
        }

        // 2) 强保留：pinned/core 缺失时按原相对顺序插到最前。
        let strongKeep = eligible
            .filter {
                $0.kind != .topic
                    && ($0.pinned || $0.scope == .core)
                    && !selectedIds.contains($0.id)
            }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                return lhs.id < rhs.id
            }
        for record in strongKeep.reversed() {
            ordered.insert(record, at: 0)
            selectedIds.insert(record.id)
        }

        // 3) topic 行（未外发、零评分）：保留原 mid-tier 语义，附在后面。
        for record in eligible where record.kind == .topic {
            guard selectedIds.insert(record.id).inserted else { continue }
            ordered.append(record)
        }
        return ordered
    }

    // MARK: Helpers

    private var inFlight: Bool {
        inFlightKey != nil
    }

    private func beginInFlight(_ key: String) -> Bool {
        guard inFlightKey == nil else { return false }
        inFlightKey = key
        return true
    }

    private func endInFlight() {
        inFlightKey = nil
    }

    private func makeContext(identity: RunIdentity, settings: IOSJevSettings, inputHash: String) -> IOSJevRunContext {
        IOSJevRunContext(
            runId: identity.runId,
            turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: identity.runId),
            inputHash: inputHash
        )
    }

    private func hashInput(_ queryText: String, _ candidates: [MemoryRecord]) -> String {
        IOSJevToolDiscoveryService.stableHash(
            queryText + "|" + candidates.map { "\($0.id):\($0.updatedAt)" }.joined(separator: ",")
        )
    }

    static func turnKey(messages: [UIMessage], eligible: [MemoryRecord], settingsRevision: Int) -> String {
        let lastUserId = messages.reversed().first { $0.role == MessageRole.user }?.id.description() ?? "none"
        let fingerprint = eligible
            .map { "\($0.id):\($0.updatedAt)" }
            .joined(separator: ",")
        return "\(lastUserId)#\(settingsRevision)#\(IOSJevToolDiscoveryService.stableHash(fingerprint))"
    }
}

private extension String {
    /// String 版本的重叠判断（避免为 token 集合构造完整 record）。
    func hasRecallOverlapFallback(_ tokens: Set<String>) -> Bool {
        !tokens.isDisjoint(with: Set(ChatMemoryContextBuilder.recallTokens(from: self)))
    }
}
