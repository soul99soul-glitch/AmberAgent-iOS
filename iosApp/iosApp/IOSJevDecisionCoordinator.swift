import Foundation

// MARK: - Decision coordinator
//
// 所有 Jev 判断的唯一出站口。职责：模式/范围判定、身份与配置 revision 核对、
// run 轮次预算与 App 日预算、并发上限（每 run 1、App 3）、暂时性失败冷却、
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

    /// 缓存键：完整输入/候选（inputHash）、用途、版本、权限范围、run 隔离。
    static func cacheKey(useCase: IOSJevUseCase, model: String, scopes: Set<IOSJevDataScope>, context: IOSJevRunContext) -> String {
        [
            useCase.rawValue,
            model,
            scopes.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ","),
            context.turnBudgetKey,
            context.inputHash,
        ].joined(separator: "|")
    }
}

enum IOSJevDecisionOutcome {
    /// active 且判断成功；调用方可应用 answers。
    case applied(IOSJevDecision)
    /// shadow 成功观测；调用方必须忽略 answers、不改业务结果。
    case observed(IOSJevDecision)
    /// 未发生网络判断（off / 范围不允许 / 预算耗尽 / 冷却 / 认证暂停 / 并发满）。
    case skipped(reason: String)
    /// 发生了网络判断但失败（错误/超时/无效响应），调用方回退原流程。
    case failed(reason: String)
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

    private var inFlightByRun: [String: Int] = [:]
    private var totalInFlight = 0

    private var consecutiveTransientFailures = 0
    private var cooldownUntil: Date?
    private var pausedForAuthFailure = false

    init(deps: Dependencies) {
        self.deps = deps
    }

    // MARK: Public queries

    var status: (cooldownRemaining: TimeInterval?, pausedForAuth: Bool) {
        synchronized {
            let remaining = cooldownUntil.map { $0.timeIntervalSince(deps.now()) }
            return (remaining.map { max($0, 0) }, pausedForAuthFailure)
        }
    }

    // MARK: Reset hooks

    /// 清 Key / 更新 Key / 显式连接测试时解除认证暂停与冷却。
    func resetAuthState() {
        synchronized {
            pausedForAuthFailure = false
            cooldownUntil = nil
            consecutiveTransientFailures = 0
        }
    }

    /// 配置/范围/Key 变化时取消不再允许的工作，并使内存缓存失效。
    func invalidateCaches() {
        synchronized { turnLedgers.removeAll() }
        deps.client.clearCache()
    }

    // MARK: Decide

    /// 单用途判断入口。requiredScopes 未全部允许 → skipped（零网络）。
    /// cacheKey 为 nil 表示不缓存。
    func decide(
        useCase: IOSJevUseCase,
        requiredScopes: Set<IOSJevDataScope>,
        state: String,
        questions: [IOSJevQuestion],
        context: IOSJevRunContext,
        cacheKey: String? = nil,
        metricSuggestionProvider: (@Sendable (IOSJevDecision) -> (suggestedTop1: String?, keywordTop1: String?))? = nil
    ) async -> IOSJevDecisionOutcome {
        let settings = deps.settingsProvider()
        let settingsRevisionAtStart = settings.revision
        let mode = settings.effectiveMode(for: useCase)
        guard mode != .off else { return .skipped(reason: "mode_off") }
        guard settings.canSend(useCase: useCase, required: requiredScopes) else {
            return .skipped(reason: "scope_not_allowed")
        }
        let policy = settings.policy
        let apiKey = deps.apiKeyProvider()
        guard !apiKey.isEmpty else { return .skipped(reason: "missing_key") }

        let model = mode == .active ? settings.activeModelVersion : (settings.pinnedModelVersion ?? "jev-latest")

        let resolvedCacheKey: String?
        if let cacheKey {
            resolvedCacheKey = IOSJevRunContext.cacheKey(useCase: useCase, model: model, scopes: requiredScopes, context: context)
        } else {
            resolvedCacheKey = nil
        }

        // 缓存命中不占预算、不占并发。
        if let key = resolvedCacheKey, let cached = deps.client.cachedDecision(cacheKey: key) {
            record(useCase: useCase, mode: mode, model: model, outcome: mode == .active ? "applied" : "observed", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: nil, suggestion: metricSuggestionProvider?(cached))
            return mode == .active ? .applied(cached) : .observed(cached)
        }

        guard acquireSlot(runKey: context.runId) else {
            return .skipped(reason: "concurrency_limit")
        }
        defer { releaseSlot(runKey: context.runId) }

        // 认证暂停 / 冷却先于预算扣减：跳过（零网络）不得消耗轮次与日预算。
        let (authPaused, cooling) = synchronized { (pausedForAuthFailure, cooldownUntil.map { deps.now() < $0 } ?? false) }
        if authPaused { return .skipped(reason: "auth_paused") }
        if cooling { return .skipped(reason: "cooling_down") }

        guard beginBudget(turnKey: context.turnBudgetKey, stateBytes: state.utf8.count, policy: policy) else {
            record(useCase: useCase, mode: mode, model: model, outcome: "skipped", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "budget_exhausted", suggestion: nil)
            return .skipped(reason: "budget_exhausted")
        }

        let input = IOSJevClient.RequestInput(
            endpoint: IOSJevSettings.productionEndpoint,
            apiKey: apiKey,
            model: model,
            state: state,
            questions: questions
        )
        do {
            let decision = try await deps.client.decide(
                input,
                policy: policy,
                deadlineMs: policy.deadlineMs,
                cacheKey: resolvedCacheKey
            )
            // 提交结果前再次验证：配置（模式/范围/Key）在途中变化 → 丢弃结果，
            // 不应用、不消费；请求可能已计费，预算与指标如实记录。
            guard deps.settingsProvider().revision == settingsRevisionAtStart else {
                deps.client.clearCache()
                finishBudget(turnKey: context.turnBudgetKey, requestBytes: decision.requestBytes)
                record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: decision.latencyMs, requestBytes: decision.requestBytes, responseBytes: decision.responseBytes, usage: decision.usage, reason: "config_changed", suggestion: nil)
                return .skipped(reason: "config_changed")
            }
            synchronized { consecutiveTransientFailures = 0 }
            finishBudget(turnKey: context.turnBudgetKey, requestBytes: decision.requestBytes)
            let outcome = mode == .active ? "applied" : "observed"
            record(useCase: useCase, mode: mode, model: model, outcome: outcome, latencyMs: decision.latencyMs, requestBytes: decision.requestBytes, responseBytes: decision.responseBytes, usage: decision.usage, reason: nil, suggestion: metricSuggestionProvider?(decision))
            return mode == .active ? .applied(decision) : .observed(decision)
        } catch let error as IOSJevRequestError {
            switch error {
            case .missingKey, .invalidRequest, .stateTooLarge, .requestTooLarge:
                // 出站前本地拒绝：无网络流量、不计费，回滚 beginBudget 的预登记。
                refundBudget(turnKey: context.turnBudgetKey, stateBytes: state.utf8.count)
            default:
                finishBudget(turnKey: context.turnBudgetKey, requestBytes: approximateRequestBytes(state: state, model: model))
            }
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                synchronized {
                    pausedForAuthFailure = true
                    consecutiveTransientFailures = 0
                }
                record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "auth_\(status)", suggestion: nil)
                return .failed(reason: "auth_\(status)")
            case .missingKey:
                return .skipped(reason: "missing_key")
            case .cancelled:
                record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "cancelled", suggestion: nil)
                return .failed(reason: "cancelled")
            case .invalidRequest, .invalidResponse, .stateTooLarge, .requestTooLarge:
                record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: reasonCode(for: error), suggestion: nil)
                return .failed(reason: reasonCode(for: error))
            case .timeout, .transport, .http:
                synchronized {
                    consecutiveTransientFailures += 1
                    if consecutiveTransientFailures >= policy.cooldownFailureThreshold {
                        cooldownUntil = deps.now().addingTimeInterval(TimeInterval(policy.cooldownSeconds))
                        consecutiveTransientFailures = 0
                    }
                }
                record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: reasonCode(for: error), suggestion: nil)
                return .failed(reason: reasonCode(for: error))
            }
        } catch {
            finishBudget(turnKey: context.turnBudgetKey, requestBytes: approximateRequestBytes(state: state, model: model))
            record(useCase: useCase, mode: mode, model: model, outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0, usage: nil, reason: "unknown_error", suggestion: nil)
            return .failed(reason: "unknown_error")
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

    private func acquireSlot(runKey: String?) -> Bool {
        synchronized {
            guard totalInFlight < 3 else { return false }
            if let runKey {
                guard (inFlightByRun[runKey] ?? 0) < 1 else { return false }
                inFlightByRun[runKey, default: 0] += 1
            }
            totalInFlight += 1
            return true
        }
    }

    private func releaseSlot(runKey: String?) {
        synchronized {
            totalInFlight = max(totalInFlight - 1, 0)
            if let runKey {
                inFlightByRun[runKey] = max((inFlightByRun[runKey] ?? 0) - 1, 0)
                if inFlightByRun[runKey] == 0 { inFlightByRun.removeValue(forKey: runKey) }
            }
        }
    }

    /// 预算入口：返回 false = 预算耗尽。缓存命中不进入本函数。
    private func beginBudget(turnKey: String, stateBytes: Int, policy: IOSJevPolicy) -> Bool {
        synchronized {
            rollDailyLedgerIfNeeded()
            guard dailyLedger.requests + 1 <= policy.dailyRequestBudget,
                  dailyLedger.requestBodyBytes + stateBytes <= policy.dailyRequestBodyBudgetBytes else {
                return false
            }
            var ledger = turnLedgers[turnKey] ?? TurnLedger(lastUsed: deps.now())
            guard ledger.requests + 1 <= policy.perTurnRequestBudget,
                  ledger.stateBytes + stateBytes <= policy.perTurnStateBudgetBytes else {
                return false
            }
            ledger.requests += 1
            ledger.stateBytes += stateBytes
            ledger.lastUsed = deps.now()
            turnLedgers[turnKey] = ledger
            // 预登记日账（失败也会计费；usage 缺失标未知，不算零费用）。
            dailyLedger.requests += 1
            return true
        }
    }

    private func finishBudget(turnKey: String, requestBytes: Int) {
        synchronized {
            rollDailyLedgerIfNeeded()
            dailyLedger.requestBodyBytes += requestBytes
            trimTurnLedgersIfNeeded()
        }
    }

    /// 出站前本地拒绝（题数超限/编码失败/state 或请求体超限/缺 Key）时回滚
    /// beginBudget 的预登记：请求未发出、无计费，不应占用轮次与日请求预算。
    private func refundBudget(turnKey: String, stateBytes: Int) {
        synchronized {
            rollDailyLedgerIfNeeded()
            dailyLedger.requests = max(dailyLedger.requests - 1, 0)
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
        suggestion: (suggestedTop1: String?, keywordTop1: String?)?
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
                keywordTop1: suggestion?.keywordTop1
            ),
            deps.now()
        )
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
        let settings = deps.settingsProvider()
        let state = "Connection test: state is a synthetic sentence used only to verify Jev connectivity."
        let question = IOSJevQuestion.noul(id: "connectivity", instructions: "Return yes with probability 1.0 if the state is readable.")
        let input = IOSJevClient.RequestInput(
            endpoint: IOSJevSettings.productionEndpoint,
            apiKey: apiKey,
            model: settings.pinnedModelVersion ?? "jev-latest",
            state: state,
            questions: [question]
        )
        let startedAt = deps.now()
        do {
            let decision = try await deps.client.decide(input, policy: settings.policy, deadlineMs: settings.policy.deadlineMs, cacheKey: nil)
            let latency = Int(deps.now().timeIntervalSince(startedAt) * 1_000)
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
            return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: latency, errorReason: reasonCode(for: error), inputTokens: nil, outputTokens: nil)
        } catch {
            return ConnectionTestResult(succeeded: false, modelVersion: nil, latencyMs: 0, errorReason: "unknown_error", inputTokens: nil, outputTokens: nil)
        }
    }

    private func approximateRequestBytes(state: String, model: String) -> Int {
        state.utf8.count + model.utf8.count + 256
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
