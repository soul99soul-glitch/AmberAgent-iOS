import Foundation

// MARK: - Decision coordinator
//
// 所有 Jev 判断的唯一出站口。职责：模式/范围判定、身份与配置 revision 核对、
// run 轮次预算与 App 日预算、active/shadow 独立并发、暂时性失败冷却、
// 认证失败暂停、缓存键、指标记录。off = 零网络、零缓存写入。

/// 判断身份。异步返回后重新核对，旧 run / 旧配置 / 旧轮次的结果不得应用。
/// 配置 revision 由协调器在出站前后各读一次设置快照自行核对。
struct IOSJevRunContext: Equatable, Sendable {
    var runId: String?
    /// 轮次预算 key：现有 runId；无稳定 run 时接收输入处生成的稳定 ID。
    /// 主模型再次生成、分块、重试、前后台恢复都不重置。
    var turnBudgetKey: String
    /// 输入内容哈希（候选/查询/记录集合），用于缓存键与身份。
    var inputHash: String

    init(runId: String? = nil, turnBudgetKey: String, inputHash: String) {
        self.runId = runId
        self.turnBudgetKey = turnBudgetKey
        self.inputHash = inputHash
    }

    /// 工具相关性和上下文块相关性只依赖内容；其它用途保留轮次隔离。
    static func cacheKey(useCase: IOSJevUseCase, mode: IOSJevMode, apiStyle: IOSJevAPIStyle, model: String, scopes: Set<IOSJevDataScope>, policyVersion: Int, settingsRevision: Int, callerKey: String, context: IOSJevRunContext) -> String {
        [
            useCase.rawValue,
            mode.rawValue,
            apiStyle.rawValue,
            model,
            String(policyVersion),
            String(settingsRevision),
            scopes.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ","),
            callerKey,
            (useCase == .toolDiscovery || useCase == .contextSelection) ? "content" : context.turnBudgetKey,
            context.inputHash,
        ].joined(separator: "|")
    }
}

enum IOSJevDecisionOutcome: Sendable {
    /// active 且判断成功；调用方可应用 answers。
    case applied(IOSJevDecision)
    /// shadow 成功观测；调用方必须忽略 answers、不改业务结果。
    case observed(IOSJevDecision)
    /// 未发生网络判断（off / 范围不允许 / 预算耗尽 / 冷却 / 认证暂停 / 并发满）。
    case skipped(reason: String)
    /// 发生了网络判断但失败（错误/超时/无效响应），调用方回退原流程。
    case failed(reason: String)
}

struct IOSJevBatchPart: Sendable {
    var id: String
    var useCase: IOSJevUseCase
    var requiredScopes: Set<IOSJevDataScope>
    var state: String
    var questions: [IOSJevQuestion]
    var cacheKey: String?
    var metricSuggestionProvider: (@Sendable (IOSJevDecision) -> (suggestedTop1: String?, keywordTop1: String?))?
    var metricNumbersProvider: (@Sendable (IOSJevDecision) -> [String: Double]?)?
    var metricIdsProvider: (@Sendable (IOSJevDecision) -> [String: String]?)?

    init(id: String, useCase: IOSJevUseCase, requiredScopes: Set<IOSJevDataScope>, state: String, questions: [IOSJevQuestion], cacheKey: String? = nil, metricSuggestionProvider: (@Sendable (IOSJevDecision) -> (suggestedTop1: String?, keywordTop1: String?))? = nil, metricNumbersProvider: (@Sendable (IOSJevDecision) -> [String: Double]?)? = nil, metricIdsProvider: (@Sendable (IOSJevDecision) -> [String: String]?)? = nil) {
        self.id = id
        self.useCase = useCase
        self.requiredScopes = requiredScopes
        self.state = state
        self.questions = questions
        self.cacheKey = cacheKey
        self.metricSuggestionProvider = metricSuggestionProvider
        self.metricNumbersProvider = metricNumbersProvider
        self.metricIdsProvider = metricIdsProvider
    }
}

final class IOSJevDecisionCoordinator: @unchecked Sendable {
    struct Dependencies {
        let client: IOSJevClient
        let settingsProvider: @Sendable () -> IOSJevSettings
        let apiKeyProvider: @Sendable () -> String
        let now: @Sendable () -> Date
        var metricsStore: @Sendable (IOSJevMetricsRecord, Date) -> Void = {
            IOSJevMetricsStore.append($0, now: $1)
        }
    }

    private let deps: Dependencies
    private let lock = NSLock()

    /// 同步临界区包装：async 上下文中不得直接 lock/unlock（Swift 6 并发检查）。
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: State

    /// 每轮预算：requests + 累计 state 字节。无条目的 key 按零计。
    private struct TurnLedger {
        var requests: Int = 0
        var stateBytes: Int = 0
        var lastUsed: Date
    }
    private var turnLedgers: [String: TurnLedger] = [:]

    private struct DailyLedger {
        var day: Date
        var requests: Int = 0
        var requestBodyBytes: Int = 0
    }
    private var dailyLedger = DailyLedger(day: Date())

    private var activeInFlightByRun: [String: Int] = [:]
    private var activeInFlight = 0
    private var shadowInFlight = 0
    private var cachedApiKey: String?

    private var consecutiveTransientFailures = 0
    private var cooldownUntil: Date?
    private var pausedForAuthFailure = false
    private var configurationEpoch = 0
    private var configurationChangeDepth = 0

    init(deps: Dependencies) {
        self.deps = deps
        IOSJevMetricsStore.startObservingLifecycle()
    }

    // MARK: Public queries

    var status: (cooldownRemaining: TimeInterval?, pausedForAuth: Bool) {
        synchronized {
            // 已过期视为无冷却：Some(0) 会让消费方误判仍在冷却。
            let remaining = cooldownUntil.map { $0.timeIntervalSince(deps.now()) }
            return (remaining.flatMap { $0 > 0 ? $0 : nil }, pausedForAuthFailure)
        }
    }

    // MARK: Reset hooks

    /// 清 Key / 更新 Key / 显式连接测试时解除认证暂停与冷却。
    func resetAuthState() {
        synchronized {
            pausedForAuthFailure = false
            cooldownUntil = nil
            consecutiveTransientFailures = 0
            cachedApiKey = nil
        }
    }

    /// store 在修改设置或 Keychain 前发布变更边界，阻止新请求进入；
    /// 在途请求会因 epoch 变化丢弃结果。支持同步嵌套写入。
    func beginConfigurationChange() {
        synchronized {
            configurationEpoch &+= 1
            configurationChangeDepth += 1
            cachedApiKey = nil
            turnLedgers.removeAll()
        }
        deps.client.clearCache()
    }

    func endConfigurationChange() {
        synchronized {
            configurationChangeDepth = max(0, configurationChangeDepth - 1)
        }
    }

    /// 配置/范围/Key 变化时取消不再允许的工作，并使内存缓存失效。
    func invalidateCaches() {
        synchronized {
            configurationEpoch &+= 1
            turnLedgers.removeAll()
            cachedApiKey = nil
        }
        deps.client.clearCache()
    }

    // MARK: Decide

    private struct PreparedPart: Sendable {
        var part: IOSJevBatchPart
        var mode: IOSJevMode
        var resolvedCacheKey: String?
    }

    private struct BatchQuestion: Sendable {
        var partId: String
        var question: IOSJevQuestion
    }

    private struct BatchChunk: Sendable {
        var parts: [PreparedPart]
        var questions: [BatchQuestion]
    }

    private enum ChunkOutcome: Sendable {
        case success(IOSJevDecision)
        case skipped(String)
        case failed(String)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: IOSJevDecisionOutcome]?
        func set(_ result: [String: IOSJevDecisionOutcome]) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }
        func get() -> [String: IOSJevDecisionOutcome]? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func configurationIsCurrent(_ epoch: Int) -> Bool {
        synchronized { configurationChangeDepth == 0 && configurationEpoch == epoch }
    }

    private func publishing(_ outcomes: [String: IOSJevDecisionOutcome], parts: [IOSJevBatchPart], epoch: Int) -> [String: IOSJevDecisionOutcome] {
        guard configurationIsCurrent(epoch) else {
            return parts.reduce(into: [:]) { $0[$1.id] = .skipped(reason: "config_changed") }
        }
        return outcomes
    }

    /// 单用途入口沿用原调用契约，统一经过批量调度与等待预算。
    func decide(
        useCase: IOSJevUseCase,
        requiredScopes: Set<IOSJevDataScope>,
        state: String,
        questions: [IOSJevQuestion],
        context: IOSJevRunContext,
        cacheKey: String? = nil,
        waitBudgetMs: Int? = nil,
        expectedSettingsRevision: Int? = nil,
        metricSuggestionProvider: (@Sendable (IOSJevDecision) -> (suggestedTop1: String?, keywordTop1: String?))? = nil,
        metricNumbersProvider: (@Sendable (IOSJevDecision) -> [String: Double]?)? = nil
    ) async -> IOSJevDecisionOutcome {
        let part = IOSJevBatchPart(
            id: "single", useCase: useCase, requiredScopes: requiredScopes,
            state: state, questions: questions, cacheKey: cacheKey,
            metricSuggestionProvider: metricSuggestionProvider,
            metricNumbersProvider: metricNumbersProvider
        )
        return await decideBatch(
            parts: [part], context: context, waitBudgetMs: waitBudgetMs,
            expectedSettingsRevision: expectedSettingsRevision
        )["single"]
            ?? .skipped(reason: "empty_batch")
    }

    /// 每个 part 独立检查模式与范围；只把获允许的分节和题目放进请求。
    /// active 与 shadow 混合时，shadow 题目随 active 同车，不占 shadow 槽位。
    func decideBatch(
        parts: [IOSJevBatchPart],
        context: IOSJevRunContext,
        waitBudgetMs: Int? = nil,
        expectedSettingsRevision: Int? = nil
    ) async -> [String: IOSJevDecisionOutcome] {
        guard !parts.isEmpty else { return [:] }
        let epochBefore = synchronized { configurationEpoch }
        let settings = deps.settingsProvider()
        if let expectedSettingsRevision, settings.revision != expectedSettingsRevision {
            return parts.reduce(into: [:]) { $0[$1.id] = .skipped(reason: "config_changed") }
        }
        let epochAtStart = synchronized { configurationChangeDepth == 0 && configurationEpoch == epochBefore ? configurationEpoch : nil }
        guard let epochAtStart else {
            return parts.reduce(into: [:]) { $0[$1.id] = .skipped(reason: "config_changed") }
        }
        let policy = settings.policy
        let model = settings.activeModelVersion
        var results: [String: IOSJevDecisionOutcome] = [:]
        var prepared: [PreparedPart] = []
        var seen = Set<String>()
        for part in parts {
            guard seen.insert(part.id).inserted else {
                // 重复 part ID 不能安全分回答案，整批在本地拒绝。
                return parts.reduce(into: [:]) { $0[$1.id] = .failed(reason: "duplicate_part_id") }
            }
            let mode = settings.effectiveMode(for: part.useCase)
            if mode == .off {
                results[part.id] = .skipped(reason: "mode_off")
                continue
            }
            guard settings.canSend(useCase: part.useCase, required: part.requiredScopes) else {
                record(useCase: part.useCase, mode: mode, model: model, outcome: "skipped", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "scope_not_allowed", suggestion: nil, runId: context.runId)
                results[part.id] = .skipped(reason: "scope_not_allowed")
                continue
            }
            let key = part.cacheKey.map {
                IOSJevRunContext.cacheKey(
                    useCase: part.useCase, mode: mode, apiStyle: settings.apiStyle, model: model,
                    scopes: part.requiredScopes, policyVersion: policy.policyVersion, settingsRevision: settings.revision,
                    callerKey: $0, context: context
                )
            }
            if let key, let cached = deps.client.cachedDecision(cacheKey: key) {
                let outcome: IOSJevDecisionOutcome = mode == .active ? .applied(cached) : .observed(cached)
                record(useCase: part.useCase, mode: mode, model: model, outcome: mode == .active ? "applied" : "observed", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: nil, suggestion: part.metricSuggestionProvider?(cached), headline: Self.headlineMetrics(from: cached), runId: context.runId, waitedMs: 0, numbers: Self.withActiveWaitFit(part.metricNumbersProvider?(cached), mode: mode, useCase: part.useCase, latencyMs: 0, policy: policy), ids: part.metricIdsProvider?(cached))
                results[part.id] = outcome
                continue
            }
            prepared.append(PreparedPart(part: part, mode: mode, resolvedCacheKey: key))
        }
        guard !prepared.isEmpty else { return publishing(results, parts: parts, epoch: epochAtStart) }
        let prefixedQuestionIds = prepared.flatMap { item in
            item.part.questions.map { item.part.id + "." + $0.id }
        }
        guard Set(prefixedQuestionIds).count == prefixedQuestionIds.count else {
            for item in prepared {
                results[item.part.id] = .failed(reason: "invalid_request")
                record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "duplicate_question_id", suggestion: nil, runId: context.runId)
            }
            return results
        }
        let budgetMs = max(0, waitBudgetMs
            ?? prepared.map { policy.activeWaitBudgetMs(for: $0.part.useCase) }.max()
            ?? policy.onDemandWaitBudgetMs)
        let waitStarted = Date()
        let waitDeadline = waitStarted.addingTimeInterval(Double(budgetMs) / 1_000)
        let box = ResultBox()
        let initialResults = results
        let submittedParts = prepared
        // Unstructured work deliberately survives caller wait expiry. A late answer may fill
        // the cache and metrics, but cannot change the already returned local result.
        Task.detached(priority: .userInitiated) { @Sendable [self, initialResults, submittedParts, settings, context, waitStarted, waitDeadline, box] in
            let completed = await self.performBatch(
                prepared: submittedParts, initial: initialResults, settings: settings,
                context: context, epochAtStart: epochAtStart,
                waitStarted: waitStarted, waitDeadline: waitDeadline
            )
            box.set(completed)
        }
        while Date() < waitDeadline {
            if let completed = box.get() { return publishing(completed, parts: parts, epoch: epochAtStart) }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if let completed = box.get(), Date() <= waitDeadline {
            return publishing(completed, parts: parts, epoch: epochAtStart)
        }
        for item in prepared { results[item.part.id] = .skipped(reason: "late") }
        return publishing(results, parts: parts, epoch: epochAtStart)
    }

    private func performBatch(
        prepared: [PreparedPart],
        initial: [String: IOSJevDecisionOutcome],
        settings: IOSJevSettings,
        context: IOSJevRunContext,
        epochAtStart: Int,
        waitStarted: Date,
        waitDeadline: Date
    ) async -> [String: IOSJevDecisionOutcome] {
        var results = initial
        let model = settings.activeModelVersion
        guard !model.isEmpty else {
            for item in prepared {
                results[item.part.id] = .skipped(reason: "model_unspecified")
                record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: "skipped", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "model_unspecified", suggestion: nil, runId: context.runId)
            }
            return results
        }
        let apiKey: String = synchronized { cachedApiKey } ?? deps.apiKeyProvider()
        guard !apiKey.isEmpty else {
            for item in prepared {
                results[item.part.id] = .skipped(reason: "missing_key")
                record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: "skipped", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "missing_key", suggestion: nil, runId: context.runId)
            }
            return results
        }
        synchronized { cachedApiKey = apiKey }
        guard synchronized({ configurationChangeDepth == 0 && configurationEpoch == epochAtStart }),
              deps.settingsProvider().revision == settings.revision else {
            for item in prepared { results[item.part.id] = .skipped(reason: "config_changed") }
            return results
        }

        // Local policy is 32 questions/request. The official API describes typed question
        // maps but does not publish a total request question limit; chunks run concurrently.
        // Chunks are also packed by combined state bytes (same heading layout as
        // executeChunk), so parts that fit alone never fail as state_too_large
        // only because they share a chunk.
        let maxQuestions = max(1, settings.policy.maxQuestions)
        var chunks: [BatchChunk] = []
        var chunkStateBytes = 0
        for item in prepared {
            let partStateBytes = "## \(item.part.useCase.rawValue).\(item.part.id)\n\n\n".utf8.count
                + item.part.state.utf8.count
            for original in item.part.questions {
                var question = original
                question.id = item.part.id + "." + original.id
                let joinsChunk = chunks.last?.parts.contains(where: { $0.part.id == item.part.id }) ?? false
                if chunks.isEmpty || chunks[chunks.count - 1].questions.count >= maxQuestions
                    || (!joinsChunk && chunkStateBytes + partStateBytes > settings.policy.maxStateBytes) {
                    chunks.append(BatchChunk(parts: [], questions: []))
                    chunkStateBytes = 0
                }
                let index = chunks.count - 1
                if !chunks[index].parts.contains(where: { $0.part.id == item.part.id }) {
                    chunks[index].parts.append(item)
                    chunkStateBytes += partStateBytes
                }
                chunks[index].questions.append(BatchQuestion(partId: item.part.id, question: question))
            }
        }
        if chunks.isEmpty {
            for item in prepared { results[item.part.id] = .failed(reason: "invalid_request") }
            return results
        }
        var chunkResults = Array<ChunkOutcome?>(repeating: nil, count: chunks.count)
        await withTaskGroup(of: (Int, ChunkOutcome).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask { [self] in
                    (index, await self.executeChunk(chunk, settings: settings, apiKey: apiKey, context: context, epochAtStart: epochAtStart, waitDeadline: waitDeadline))
                }
            }
            for await (index, result) in group { chunkResults[index] = result }
        }
        let late = Date() > waitDeadline
        guard configurationIsCurrent(epochAtStart) else {
            for item in prepared { results[item.part.id] = .skipped(reason: "config_changed") }
            return results
        }
        for item in prepared {
            guard configurationIsCurrent(epochAtStart) else {
                results[item.part.id] = .skipped(reason: "config_changed")
                continue
            }
            let relevant = chunks.enumerated().compactMap { index, chunk -> ChunkOutcome? in
                chunk.parts.contains(where: { $0.part.id == item.part.id }) ? chunkResults[index] : nil
            }
            if let failure = relevant.first(where: { if case .success = $0 { return false }; return true }) {
                let reason: String
                let outcome: String
                switch failure {
                case .skipped(let code): reason = code; outcome = code == "shadow_dropped" ? "shadow_dropped" : "skipped"
                case .failed(let code): reason = code; outcome = "error"
                case .success: continue
                }
                results[item.part.id] = outcome == "error" ? .failed(reason: reason) : .skipped(reason: reason)
                record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: outcome, latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: reason, suggestion: nil, runId: context.runId)
                continue
            }
            let decisions = relevant.compactMap { outcome -> IOSJevDecision? in
                if case .success(let decision) = outcome { return decision }
                return nil
            }
            guard let first = decisions.first else { continue }
            let prefix = item.part.id + "."
            let answerIds = Set(item.part.questions.map(\.id))
            let answers = decisions.flatMap(\.answers).compactMap { answer -> IOSJevAnswer? in
                guard answer.id.hasPrefix(prefix) else { return nil }
                var local = answer
                local.id = String(answer.id.dropFirst(prefix.count))
                return answerIds.contains(local.id) ? local : nil
            }
            var bytes = 0
            var responseBytes = 0
            var apportionedUsage = IOSJevUsage(inputTokens: 0, outputTokens: 0)
            var hasUsage = false
            for (index, chunk) in chunks.enumerated() {
                guard case .success(let completed)? = chunkResults[index] else { continue }
                let count = chunk.questions.filter { $0.partId == item.part.id }.count
                guard count > 0 else { continue }
                let total = max(1, chunk.questions.count)
                bytes += completed.requestBytes * count / total
                responseBytes += completed.responseBytes * count / total
                if let usage = completed.usage {
                    hasUsage = true
                    apportionedUsage.inputTokens += usage.inputTokens * count / total
                    apportionedUsage.outputTokens += usage.outputTokens * count / total
                }
            }
            let usage = hasUsage ? apportionedUsage : nil
            guard Set(answers.map(\.id)) == answerIds,
                  answers.count == item.part.questions.count else {
                results[item.part.id] = .failed(reason: "incomplete_response")
                record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: "error", latencyMs: decisions.map(\.latencyMs).max() ?? 0, requestBytes: bytes, responseBytes: responseBytes, usage: usage, reason: "incomplete_response", suggestion: nil, runId: context.runId)
                continue
            }
            let decision = IOSJevDecision(
                answers: answers, usage: usage,
                modelVersion: first.modelVersion, latencyMs: decisions.map(\.latencyMs).max() ?? 0,
                requestBytes: bytes,
                responseBytes: responseBytes
            )
            if let key = item.resolvedCacheKey, !answers.isEmpty {
                deps.client.storeCachedDecision(cacheKey: key, decision: decision, ttlSeconds: settings.policy.cacheTTLSeconds, maxEntries: settings.policy.cacheMaxEntries)
            }
            results[item.part.id] = item.mode == .active ? .applied(decision) : .observed(decision)
            record(useCase: item.part.useCase, mode: item.mode, model: model, outcome: late ? "late" : (item.mode == .active ? "applied" : "observed"), latencyMs: decision.latencyMs, requestBytes: decision.requestBytes, responseBytes: decision.responseBytes, usage: decision.usage, reason: late ? "late" : nil, suggestion: item.part.metricSuggestionProvider?(decision), headline: Self.headlineMetrics(from: decision), runId: context.runId, waitedMs: min(Int(Date().timeIntervalSince(waitStarted) * 1_000), Int(waitDeadline.timeIntervalSince(waitStarted) * 1_000)), numbers: Self.withActiveWaitFit(item.part.metricNumbersProvider?(decision), mode: item.mode, useCase: item.part.useCase, latencyMs: decision.latencyMs, policy: settings.policy), ids: item.part.metricIdsProvider?(decision))
        }
        return results
    }

    private func executeChunk(
        _ chunk: BatchChunk,
        settings: IOSJevSettings,
        apiKey: String,
        context: IOSJevRunContext,
        epochAtStart: Int,
        waitDeadline: Date
    ) async -> ChunkOutcome {
        let mode: IOSJevMode = chunk.parts.contains(where: { $0.mode == .active }) ? .active : .shadow
        if mode == .shadow {
            guard acquireSlot(mode: .shadow, runKey: nil, policy: settings.policy) else { return .skipped("shadow_dropped") }
        } else {
            while !acquireSlot(mode: .active, runKey: context.runId, policy: settings.policy) {
                guard Date() < waitDeadline else { return .skipped("concurrency_limit") }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { releaseSlot(mode: mode, runKey: context.runId) }
        guard synchronized({ configurationChangeDepth == 0 && configurationEpoch == epochAtStart }) else { return .skipped("config_changed") }
        let (authPaused, cooling) = synchronized { (pausedForAuthFailure, cooldownUntil.map { deps.now() < $0 } ?? false) }
        if authPaused { return .skipped("auth_paused") }
        if cooling { return .skipped("cooling_down") }
        let state = chunk.parts.map { "## \($0.part.useCase.rawValue).\($0.part.id)\n\($0.part.state)" }.joined(separator: "\n\n")
        let questions = chunk.questions.map(\.question)
        let input = IOSJevClient.RequestInput(endpoint: settings.resolvedEndpoint, apiKey: apiKey, model: settings.activeModelVersion, state: state, questions: questions, style: settings.apiStyle)
        let bodyBytes: Int
        do {
            bodyBytes = try deps.client.requestBodyByteCount(input)
        } catch {
            return .failed("invalid_request")
        }
        guard state.utf8.count <= settings.policy.maxStateBytes else { return .failed("state_too_large") }
        guard bodyBytes <= settings.policy.maxRequestBytes else { return .failed("request_too_large") }
        guard let budgetDay = beginBudget(turnKey: context.turnBudgetKey, stateBytes: state.utf8.count, bodyBytes: bodyBytes, policy: settings.policy) else {
            return .skipped("budget_exhausted")
        }
        guard synchronized({ configurationChangeDepth == 0 && configurationEpoch == epochAtStart }) else {
            refundBudget(turnKey: context.turnBudgetKey, stateBytes: state.utf8.count, bodyBytes: bodyBytes, budgetDay: budgetDay)
            return .skipped("config_changed")
        }
        let deadline = chunk.parts.contains(where: { $0.part.useCase == .webActions })
            ? settings.policy.webActionsDeadlineMs : settings.policy.deadlineMs
        do {
            let decision = try await deps.client.decide(
                input,
                policy: settings.policy, deadlineMs: deadline, cacheKey: nil
            )
            finishBudget()
            guard synchronized({ configurationChangeDepth == 0 && configurationEpoch == epochAtStart }),
                  deps.settingsProvider().revision == settings.revision else {
                deps.client.clearCache()
                return .skipped("config_changed")
            }
            synchronized { consecutiveTransientFailures = 0 }
            return .success(decision)
        } catch let error as IOSJevRequestError {
            switch error {
            case .missingKey, .invalidRequest, .stateTooLarge, .requestTooLarge:
                refundBudget(turnKey: context.turnBudgetKey, stateBytes: state.utf8.count, bodyBytes: bodyBytes, budgetDay: budgetDay)
            default:
                finishBudget()
            }
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                synchronized { pausedForAuthFailure = true; consecutiveTransientFailures = 0 }
                return .failed("auth_\(status)")
            case .timeout, .transport, .http:
                let transient: Bool
                if case .http(let status, _) = error { transient = status == 429 || status >= 500 }
                else { transient = true }
                if transient {
                    synchronized {
                        consecutiveTransientFailures += 1
                        if consecutiveTransientFailures >= settings.policy.cooldownFailureThreshold {
                            cooldownUntil = deps.now().addingTimeInterval(TimeInterval(settings.policy.cooldownSeconds))
                            consecutiveTransientFailures = 0
                        }
                    }
                }
            default: break
            }
            return .failed(reasonCode(for: error))
        } catch {
            finishBudget()
            return .failed("unknown_error")
        }
    }

    private func reasonCode(for error: IOSJevRequestError) -> String {
        switch error {
        case .missingKey: "missing_key"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .http(let status, _): "http_\(status)"
        case .invalidResponse: "invalid_response"
        case .invalidRequest: "invalid_request"
        case .stateTooLarge: "state_too_large"
        case .requestTooLarge: "request_too_large"
        case .transport: "transport"
        }
    }

    // MARK: Slots & budgets

    private func acquireSlot(mode: IOSJevMode, runKey: String?, policy: IOSJevPolicy) -> Bool {
        synchronized {
            if mode == .shadow {
                guard shadowInFlight < max(1, policy.shadowAppLimit) else { return false }
                shadowInFlight += 1
                return true
            }
            guard activeInFlight < max(1, policy.activeAppLimit) else { return false }
            if let runKey {
                guard (activeInFlightByRun[runKey] ?? 0) < max(1, policy.activePerRunLimit) else { return false }
                activeInFlightByRun[runKey, default: 0] += 1
            }
            activeInFlight += 1
            return true
        }
    }

    private func releaseSlot(mode: IOSJevMode, runKey: String?) {
        synchronized {
            if mode == .shadow {
                shadowInFlight = max(shadowInFlight - 1, 0)
                return
            }
            activeInFlight = max(activeInFlight - 1, 0)
            if let runKey {
                activeInFlightByRun[runKey] = max((activeInFlightByRun[runKey] ?? 0) - 1, 0)
                if activeInFlightByRun[runKey] == 0 { activeInFlightByRun.removeValue(forKey: runKey) }
            }
        }
    }

    /// 预算入口：返回 false = 预算耗尽。缓存命中不进入本函数。
    private func beginBudget(turnKey: String, stateBytes: Int, bodyBytes: Int, policy: IOSJevPolicy) -> Date? {
        synchronized {
            rollDailyLedgerIfNeeded()
            guard dailyLedger.requests + 1 <= policy.dailyRequestBudget,
                  dailyLedger.requestBodyBytes + bodyBytes <= policy.dailyRequestBodyBudgetBytes else {
                return nil
            }
            var ledger = turnLedgers[turnKey] ?? TurnLedger(lastUsed: deps.now())
            guard ledger.requests + 1 <= policy.perTurnRequestBudget,
                  ledger.stateBytes + stateBytes <= policy.perTurnStateBudgetBytes else {
                return nil
            }
            ledger.requests += 1
            ledger.stateBytes += stateBytes
            ledger.lastUsed = deps.now()
            turnLedgers[turnKey] = ledger
            // 精确编码体积在锁内预留，防止并发请求都越过同一日字节上限。
            dailyLedger.requests += 1
            dailyLedger.requestBodyBytes += bodyBytes
            return dailyLedger.day
        }
    }

    private func finishBudget() {
        synchronized {
            trimTurnLedgersIfNeeded()
        }
    }

    /// 出站前本地拒绝（题数超限/编码失败/state 或请求体超限/缺 Key）时回滚
    /// beginBudget 的预登记：请求未发出、无计费，不应占用轮次与日请求预算。
    private func refundBudget(turnKey: String, stateBytes: Int, bodyBytes: Int, budgetDay: Date) {
        synchronized {
            rollDailyLedgerIfNeeded()
            if Calendar.current.isDate(dailyLedger.day, inSameDayAs: budgetDay) {
                dailyLedger.requests = max(dailyLedger.requests - 1, 0)
                dailyLedger.requestBodyBytes = max(dailyLedger.requestBodyBytes - bodyBytes, 0)
            }
            if var ledger = turnLedgers[turnKey] {
                ledger.requests = max(ledger.requests - 1, 0)
                ledger.stateBytes = max(ledger.stateBytes - stateBytes, 0)
                turnLedgers[turnKey] = ledger
            }
        }
    }

    private func rollDailyLedgerIfNeeded() {
        let today = deps.now()
        if !Calendar.current.isDate(dailyLedger.day, inSameDayAs: today) {
            dailyLedger = DailyLedger(day: today)
        }
    }

    private func trimTurnLedgersIfNeeded() {
        guard turnLedgers.count > 32 else { return }
        let sorted = turnLedgers.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, _) in sorted.prefix(turnLedgers.count - 32) {
            turnLedgers.removeValue(forKey: key)
        }
    }

    // MARK: Metrics

    private func record(
        useCase: IOSJevUseCase,
        mode: IOSJevMode,
        model: String,
        outcome: String,
        latencyMs: Int,
        requestBytes: Int,
        responseBytes: Int,
        usage: IOSJevUsage?,
        reason: String?,
        suggestion: (suggestedTop1: String?, keywordTop1: String?)?,
        headline: (topConfidence: Double?, topScore: Double?)? = nil,
        runId: String? = nil,
        waitedMs: Int? = nil,
        numbers: [String: Double]? = nil,
        ids: [String: String]? = nil
    ) {
        deps.metricsStore(
            IOSJevMetricsRecord(
                timestamp: deps.now(),
                useCase: useCase,
                mode: mode,
                modelVersion: model,
                outcome: outcome,
                latencyMs: latencyMs,
                requestBytes: requestBytes,
                responseBytes: responseBytes,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                reason: reason,
                suggestedTop1: suggestion?.suggestedTop1,
                keywordTop1: suggestion?.keywordTop1,
                topConfidence: headline?.topConfidence,
                topScore: headline?.topScore,
                runId: runId,
                waitPhase: {
                    switch useCase {
                    case .memoryRecall: "T1"
                    case .contextSelection: "T2"
                    case .modelRouting, .subagentIntent: "T3"
                    default: "on_demand"
                    }
                }(),
                waitedMs: waitedMs,
                numbers: numbers,
                ids: ids
            ),
            deps.now()
        )
    }

    /// shadow 会等到网络 deadline，active 只等本用途的等待预算；标出该答案在
    /// active 下是否来得及应用，避免 shadow 指标高估启用效果。
    static func withActiveWaitFit(_ numbers: [String: Double]?, mode: IOSJevMode, useCase: IOSJevUseCase, latencyMs: Int, policy: IOSJevPolicy) -> [String: Double]? {
        guard mode == .shadow else { return numbers }
        var merged = numbers ?? [:]
        merged["within_active_wait_budget"] = latencyMs <= policy.activeWaitBudgetMs(for: useCase) ? 1 : 0
        return merged
    }

    /// 决策头条数值：跨答案的最大置信与最高分（非有限值剔除）。
    /// 指标只承载分布监测口径；逐答案校准由分析侧从完整决策重建。
    static func headlineMetrics(from decision: IOSJevDecision) -> (topConfidence: Double?, topScore: Double?) {
        let confidences = decision.answers.compactMap(\.confidence).filter { $0.isFinite }
        let scores = decision.answers.compactMap(\.score).filter { $0.isFinite }
        return (confidences.max(), scores.max())
    }

    // MARK: Connection test（合成数据；返回实际模型版本、耗时与错误，不自动启用任何用途）

    struct ConnectionTestResult: Equatable {
        var succeeded: Bool
        var modelVersion: String?
        var latencyMs: Int
        var errorReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    func runConnectionTest(apiKey: String) async -> ConnectionTestResult {
        let epochBefore = synchronized { configurationEpoch }
        let settings = deps.settingsProvider()
        guard configurationIsCurrent(epochBefore) else {
            return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: 0, errorReason: "config_changed", inputTokens: nil, outputTokens: nil)
        }
        let state = "Connection test: state is a synthetic sentence used only to verify Jev connectivity."
        let question = IOSJevQuestion.noul(id: "connectivity", instructions: "Return yes with probability 1.0 if the state is readable.")
        let input = IOSJevClient.RequestInput(
            endpoint: settings.resolvedEndpoint,
            apiKey: apiKey,
            model: settings.activeModelVersion,
            state: state,
            questions: [question],
            style: settings.apiStyle
        )
        let startedAt = deps.now()
        do {
            let decision = try await deps.client.decide(input, policy: settings.policy, deadlineMs: settings.policy.deadlineMs, cacheKey: nil)
            let latency = Int(deps.now().timeIntervalSince(startedAt) * 1_000)
            guard configurationIsCurrent(epochBefore), deps.settingsProvider().revision == settings.revision else {
                return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: latency, errorReason: "config_changed", inputTokens: nil, outputTokens: nil)
            }
            // 显式连接测试成功即恢复认证暂停/冷却（用户拿新 Key 验证通过的场景）。
            resetAuthState()
            deps.metricsStore(
                IOSJevMetricsRecord(
                    timestamp: deps.now(), useCase: .toolDiscovery, mode: .off, modelVersion: decision.modelVersion,
                    outcome: "connection_test", latencyMs: latency, requestBytes: decision.requestBytes,
                    responseBytes: decision.responseBytes, inputTokens: decision.usage?.inputTokens,
                    outputTokens: decision.usage?.outputTokens, reason: nil
                ),
                deps.now()
            )
            return ConnectionTestResult(
                succeeded: true, modelVersion: decision.modelVersion, latencyMs: latency,
                errorReason: nil, inputTokens: decision.usage?.inputTokens, outputTokens: decision.usage?.outputTokens
            )
        } catch let error as IOSJevRequestError {
            let latency = Int(deps.now().timeIntervalSince(startedAt) * 1_000)
            if !configurationIsCurrent(epochBefore) || deps.settingsProvider().revision != settings.revision {
                return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: latency, errorReason: "config_changed", inputTokens: nil, outputTokens: nil)
            }
            return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: latency, errorReason: reasonCode(for: error), inputTokens: nil, outputTokens: nil)
        } catch {
            let reason = configurationIsCurrent(epochBefore) && deps.settingsProvider().revision == settings.revision
                ? "unknown_error" : "config_changed"
            return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: 0, errorReason: reason, inputTokens: nil, outputTokens: nil)
        }
    }

}

// MARK: - Shared coordinator

extension IOSJevDecisionCoordinator {
    /// 生产共享实例：设置读持久化 Jev 配置，Key 读 Keychain side-table。
    static let shared = IOSJevDecisionCoordinator(deps: Dependencies(
        client: IOSJevClient(transport: IOSJevURLSessionTransport(session: URLSession.shared)),
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() },
        apiKeyProvider: { IOSCredentialSideTable.load(key: IOSCredentialSideTable.jevApiKey) ?? "" },
        now: { Date() }
    ))
}

// MARK: - exec 脚本判断入口（`jev` 全局）

/// exec 沙箱里 `jev.ask` / `jev.askAll` 的宿主侧：解析脚本请求 → 一次
/// `decideBatch`（分块、槽位、预算、指标全部沿用协调器）→ 按请求序回 JSON。
/// 只在「脚本判断」用途生效为 active 时注入；数据范围固定为工具输出。
enum IOSExecJevBridge {
    /// 单次 askAll 的请求数上限（每个请求再受协调器的题数/体积上限约束）。
    static let maxRequestsPerCall = 256
    /// 脚本侧等待预算：JS 线程阻塞等待，exec 自身的 timeout 仍是外层兜底。
    static let waitBudgetMs = 20_000

    static func makeBridge(
        runKey: String,
        settings: IOSJevSettings,
        coordinator: IOSJevDecisionCoordinator = .shared
    ) -> IOSJsSandboxJev? {
        guard settings.effectiveMode(for: .scriptJudgment) == .active,
              settings.canSend(useCase: .scriptJudgment, required: [.toolOutput]) else { return nil }
        let maxQuestions = settings.policy.maxQuestions
        let maxCandidates = settings.policy.maxCandidates
        return IOSJsSandboxJev { requestsJSON in
            await askBatch(
                requestsJSON,
                runKey: runKey,
                maxQuestions: maxQuestions,
                maxCandidates: maxCandidates,
                coordinator: coordinator
            )
        }
    }

    static func askBatch(
        _ requestsJSON: String,
        runKey: String,
        maxQuestions: Int,
        maxCandidates: Int,
        coordinator: IOSJevDecisionCoordinator
    ) async -> String {
        guard let data = requestsJSON.data(using: .utf8),
              let rawRequests = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return encode(["error": "requests must be an array of {state, questions}"])
        }
        guard rawRequests.count <= maxRequestsPerCall else {
            return encode(["error": "at most \(maxRequestsPerCall) requests per call"])
        }
        var results = [[String: Any]](repeating: [:], count: rawRequests.count)
        var parts: [IOSJevBatchPart] = []
        for (index, raw) in rawRequests.enumerated() {
            switch parseRequest(raw, maxQuestions: maxQuestions, maxCandidates: maxCandidates) {
            case .failure(let message):
                results[index] = ["error": message]
            case .success(let request):
                parts.append(IOSJevBatchPart(
                    id: "r\(index)",
                    useCase: .scriptJudgment,
                    requiredScopes: [.toolOutput],
                    state: request.state,
                    questions: request.questions
                ))
            }
        }
        if !parts.isEmpty {
            let context = IOSJevRunContext(
                runId: runKey,
                turnBudgetKey: runKey,
                inputHash: IOSJevToolDiscoveryService.stableHash(requestsJSON)
            )
            let outcomes = await coordinator.decideBatch(
                parts: parts,
                context: context,
                waitBudgetMs: waitBudgetMs
            )
            for part in parts {
                guard let index = Int(part.id.dropFirst()) else { continue }
                results[index] = resultObject(outcomes[part.id])
            }
        }
        return encode(results)
    }

    struct ParsedRequest {
        var state: String
        var questions: [IOSJevQuestion]
    }

    enum ParseResult {
        case success(ParsedRequest)
        case failure(String)
    }

    /// `{state: string, questions: [{id, type: noul|choice|score, options?, levels?, instructions?}]}`；
    /// choice 的 options 可为字符串数组或 {选项: 说明}。
    static func parseRequest(_ raw: Any, maxQuestions: Int, maxCandidates: Int) -> ParseResult {
        guard let object = raw as? [String: Any] else { return .failure("request must be an object") }
        guard let state = object["state"] as? String else { return .failure("state must be a string") }
        guard let rawQuestions = object["questions"] as? [Any], !rawQuestions.isEmpty else {
            return .failure("questions must be a non-empty array")
        }
        guard rawQuestions.count <= maxQuestions else {
            return .failure("at most \(maxQuestions) questions per request")
        }
        var questions: [IOSJevQuestion] = []
        var seen = Set<String>()
        for rawQuestion in rawQuestions {
            guard let question = rawQuestion as? [String: Any],
                  let id = question["id"] as? String, !id.isEmpty else {
                return .failure("each question needs a non-empty string id")
            }
            guard seen.insert(id).inserted else { return .failure("duplicate question id: \(id)") }
            let instructions = question["instructions"] as? String ?? ""
            switch question["type"] as? String {
            case "noul":
                questions.append(.noul(id: id, instructions: instructions))
            case "choice":
                let options: [String: String?]
                if let list = question["options"] as? [String] {
                    options = Dictionary(list.map { ($0, nil) }, uniquingKeysWith: { first, _ in first })
                } else if let map = question["options"] as? [String: String] {
                    options = map.mapValues { Optional($0) }
                } else {
                    return .failure("choice question \(id) needs options (string array or {option: description})")
                }
                guard (2...max(2, maxCandidates)).contains(options.count) else {
                    return .failure("choice question \(id) needs 2...\(maxCandidates) distinct options")
                }
                questions.append(.choice(id: id, options: options, instructions: instructions))
            case "score":
                guard let levels = question["levels"] as? [String], levels.count >= 2 else {
                    return .failure("score question \(id) needs at least two levels")
                }
                questions.append(.score(id: id, levels: levels, instructions: instructions))
            default:
                return .failure("question \(id) type must be noul, choice or score")
            }
        }
        return .success(ParsedRequest(state: state, questions: questions))
    }

    private static func resultObject(_ outcome: IOSJevDecisionOutcome?) -> [String: Any] {
        switch outcome {
        case .applied(let decision):
            var answers: [String: Any] = [:]
            for answer in decision.answers {
                var entry: [String: Any] = ["type": answer.type]
                if let noul = answer.noul { entry["probability"] = noul }
                if let choice = answer.choice { entry["choice"] = choice }
                if let score = answer.score { entry["score"] = score }
                if let confidence = answer.confidence { entry["confidence"] = confidence }
                answers[answer.id] = entry
            }
            return ["answers": answers, "model": decision.modelVersion]
        case .observed:
            return ["error": "script_judgment is not active (shadow results are never applied)"]
        case .skipped(let reason):
            return ["error": "skipped: \(reason)"]
        case .failed(let reason):
            return ["error": "failed: \(reason)"]
        case nil:
            return ["error": "no result"]
        }
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"jev result serialization failed"}"#
        }
        return text
    }
}
