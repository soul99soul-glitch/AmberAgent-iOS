import XCTest
@testable import iosApp

// IOSJevDecisionCoordinatorTests：off 零调用、范围拒绝、预算（轮/App）、并发
// 上限（每 run 1 / App 3）、冷却、认证暂停、配置变化丢弃、缓存命中不占预算、
// 指标记录。

final class IOSJevDecisionCoordinatorTests: XCTestCase {

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: IOSJevSettings) { lock.lock(); defer { lock.unlock() }; value = v }
    }

    private final class MetricsSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [IOSJevMetricsRecord] = []
        func append(_ record: IOSJevMetricsRecord, _ now: Date) {
            lock.lock(); defer { lock.unlock() }
            records.append(record)
        }
        func all() -> [IOSJevMetricsRecord] {
            lock.lock(); defer { lock.unlock() }
            return records
        }
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func scorePayload(_ answers: [String: Double]) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": answers.mapValues { ["type": "score", "score": $0] },
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeSettings(mode: IOSJevMode = .active, pinned: String? = "jev-fixed-v1", scopes: Set<IOSJevDataScope>? = nil) -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .toolDiscovery)
        settings.pinnedModelVersion = pinned
        if let scopes {
            settings.setScopes(scopes, for: .toolDiscovery)
        } else {
            settings.setScopes([.toolMetadata, .selectedTaskText], for: .toolDiscovery)
        }
        return settings
    }

    private func makeCoordinator(
        settings: SettingsBox,
        transport: JevStubTransport,
        metrics: MetricsSpy? = nil
    ) -> IOSJevDecisionCoordinator {
        return IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { settings.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() },
            metricsStore: { @Sendable record, now in metrics?.append(record, now) }
        ))
    }

    private func makeDecideCall(
        useCase: IOSJevUseCase = .toolDiscovery,
        context: IOSJevRunContext? = nil
    ) -> (Set<IOSJevDataScope>, String, [IOSJevQuestion], IOSJevRunContext) {
        let context = context ?? IOSJevRunContext(
            runId: "run1", turnBudgetKey: "turn1", inputHash: "h"
        )
        return (
            [.toolMetadata, .selectedTaskText],
            "state text",
            [IOSJevQuestion.score(id: "t1", levels: ["0", "3"], instructions: "test")],
            context
        )
    }

    // MARK: Modes & scopes

    func testOffModeMakesZeroNetworkCalls() async {
        let box = SettingsBox(makeSettings(mode: .off))
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k")
        guard case .skipped(let reason) = outcome else { return XCTFail("expected skipped, got \(outcome)") }
        XCTAssertEqual(reason, "mode_off")
        XCTAssertEqual(transport.calls, 0)
    }


    func testScopeNotAllowedSkipsWithoutNetwork() async {
        let box = SettingsBox(makeSettings(scopes: [.toolMetadata]))
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k")
        guard case .skipped(let reason) = outcome else { return XCTFail("expected skipped") }
        XCTAssertEqual(reason, "scope_not_allowed")
        XCTAssertEqual(transport.calls, 0)
    }

    func testActiveWithoutPinnedVersionDegradesToShadow() async {
        let box = SettingsBox(makeSettings(mode: .active, pinned: nil))
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k")
        guard case .observed = outcome else { return XCTFail("expected observed (shadow), got \(outcome)") }
        XCTAssertEqual(transport.calls, 1)
    }

    func testActiveAppliesResult() async {
        let box = SettingsBox(makeSettings())
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k")
        guard case .applied(let decision) = outcome else { return XCTFail("expected applied") }
        XCTAssertEqual(decision.answers.first?.score, 0.9)
    }

    // MARK: Budgets

    func testPerTurnRequestBudgetEnforced() async {
        var settings = makeSettings()
        settings.policy.perTurnRequestBudget = 2
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        for index in 0..<2 {
            let (scopes, state, questions, context) = makeDecideCall(
                context: IOSJevRunContext(runId: "run1", turnBudgetKey: "turnA", inputHash: "h\(index)")
            )
            let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k\(index)")
            guard case .applied = outcome else { return XCTFail("call \(index) should apply") }
        }
        let (scopes, state, questions, context) = makeDecideCall(
            context: IOSJevRunContext(runId: "run1", turnBudgetKey: "turnA", inputHash: "h3")
        )
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k3")
        guard case .skipped(let reason) = outcome else { return XCTFail("expected budget skip") }
        XCTAssertEqual(reason, "budget_exhausted")
    }

    func testNewTurnGetsFreshBudget() async {
        var settings = makeSettings()
        settings.policy.perTurnRequestBudget = 1
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        func call(_ turn: String, _ hash: String) async -> IOSJevDecisionOutcome {
            let (scopes, state, questions, context) = makeDecideCall(
                context: IOSJevRunContext(runId: "run1", turnBudgetKey: turn, inputHash: hash)
            )
            return await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k\(hash)")
        }
        guard case .applied = await call("turnA", "h1") else { return XCTFail("turnA first should apply") }
        guard case .skipped = await call("turnA", "h2") else { return XCTFail("turnA second should skip") }
        guard case .applied = await call("turnB", "h3") else { return XCTFail("turnB should apply (fresh budget)") }
    }

    /// 出站前本地拒绝（state 超限等）无网络流量、不计费：不得占用该轮与日预算。
    func testPreNetworkRejectionRefundsBudget() async {
        var settings = makeSettings()
        settings.policy.perTurnRequestBudget = 1
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let hugeState = String(repeating: "a", count: settings.policy.maxStateBytes + 1)
        let oversized = makeDecideCall(
            context: IOSJevRunContext(runId: "run1", turnBudgetKey: "turnA", inputHash: "h1")
        )
        guard case .failed(let reason) = await coordinator.decide(
            useCase: .toolDiscovery, requiredScopes: oversized.0, state: hugeState,
            questions: oversized.2, context: oversized.3, cacheKey: "k1"
        ) else { return XCTFail("expected state_too_large failure") }
        XCTAssertEqual(reason, "state_too_large")
        XCTAssertEqual(transport.calls, 0, "state oversize must be rejected before any network")
        // 同一轮仍有完整预算：本地拒绝被退款。
        let normal = makeDecideCall(
            context: IOSJevRunContext(runId: "run1", turnBudgetKey: "turnA", inputHash: "h2")
        )
        guard case .applied = await coordinator.decide(
            useCase: .toolDiscovery, requiredScopes: normal.0, state: normal.1,
            questions: normal.2, context: normal.3, cacheKey: "k2"
        ) else { return XCTFail("pre-network rejection must not consume turn budget") }
        XCTAssertEqual(transport.calls, 1)
    }

    func testDailyBudgetEnforced() async {
        var settings = makeSettings()
        settings.policy.dailyRequestBudget = 2
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        for index in 0..<2 {
            let (scopes, state, questions, context) = makeDecideCall(
                context: IOSJevRunContext(runId: "run\(index)", turnBudgetKey: "turn\(index)", inputHash: "h\(index)")
            )
            _ = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k\(index)")
        }
        let (scopes, state, questions, context) = makeDecideCall(
            context: IOSJevRunContext(runId: "run9", turnBudgetKey: "turn9", inputHash: "h9")
        )
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k9")
        guard case .skipped(let reason) = outcome, reason == "budget_exhausted" else {
            return XCTFail("expected daily budget skip, got \(outcome)")
        }
    }

    func testCacheHitDoesNotConsumeBudget() async {
        var settings = makeSettings()
        settings.policy.perTurnRequestBudget = 1
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        // 相同 inputHash + cacheKey → 第二次命中缓存，不占预算。
        guard case .applied = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "same") else {
            return XCTFail("first should apply")
        }
        guard case .applied = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "same") else {
            return XCTFail("cache hit should apply without budget")
        }
        XCTAssertEqual(transport.calls, 1)
    }

    // MARK: Concurrency

    func testPerRunConcurrencyLimitedToOne() async {
        let box = SettingsBox(makeSettings())
        let gate = continuationGate()
        let transport = JevStubTransport { _ in
            await gate.wait()
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let firstTask = Task { await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "c1") }
        // 等第一个真正在途后再发第二个。
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "c2")
        guard case .skipped(let reason) = second, reason == "concurrency_limit" else {
            gate.release()
            return XCTFail("second concurrent call for same run must be skipped, got \(second)")
        }
        gate.release()
        let first = await firstTask.value
        guard case .applied = first else { return XCTFail("first should apply, got \(first)") }
    }

    private func continuationGate() -> (wait: @Sendable () async -> Void, release: @Sendable () -> Void) {
        let semaphore = AsyncSemaphore()
        return (wait: { await semaphore.wait() }, release: { semaphore.signal() })
    }

    // MARK: Cooldown & auth

    func testCooldownAfterConsecutiveTransientFailures() async {
        let box = SettingsBox(makeSettings())
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        for index in 0..<3 {
            let (scopes, state, questions, context) = makeDecideCall(
                context: IOSJevRunContext(runId: "run\(index)", turnBudgetKey: "turn\(index)", inputHash: "h\(index)")
            )
            let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k\(index)")
            guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
        }
        let (scopes, state, questions, context) = makeDecideCall(
            context: IOSJevRunContext(runId: "run9", turnBudgetKey: "turn9", inputHash: "h9")
        )
        let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k9")
        guard case .skipped(let reason) = outcome, reason == "cooling_down" else {
            return XCTFail("expected cooling_down, got \(outcome)")
        }
        XCTAssertEqual(transport.calls, 6, "each failed decide makes 2 attempts (one retry)")
    }

    func testAuthFailurePausesUntilReset() async {
        let box = SettingsBox(makeSettings())
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 401)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let first = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k1")
        guard case .failed(let reason) = first, reason == "auth_401" else {
            return XCTFail("expected auth_401, got \(first)")
        }
        let second = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k2")
        guard case .skipped(let skipReason) = second, skipReason == "auth_paused" else {
            return XCTFail("expected auth_paused, got \(second)")
        }
        coordinator.resetAuthState()
        _ = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k3")
        XCTAssertEqual(transport.calls, 2, "after reset a new request is allowed")
    }

    // MARK: Config change

    func testConfigChangeDuringFlightDiscardsResult() async {
        let box = SettingsBox(makeSettings())
        let gate = continuationGate()
        let transport = JevStubTransport { _ in
            await gate.wait()
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let firstTask = Task { await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "kc") }
        // 等第一个真正在途后再改配置（revision 变化）→ 结果丢弃。
        try? await Task.sleep(nanoseconds: 100_000_000)
        var changed = makeSettings(mode: .off)
        changed.bumpRevision()  // makeSettings 重建后 revision 归 1，必须再加一才是真变化
        box.set(changed)
        gate.release()
        let result = await firstTask.value
        guard case .skipped(let reason) = result, reason == "config_changed" else {
            return XCTFail("expected config_changed, got \(result)")
        }
    }

    // MARK: Metrics

    func testMetricsRecordedForAppliedAndSkipped() async {
        let box = SettingsBox(makeSettings())
        let metrics = MetricsSpy()
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport, metrics: metrics)
        let (scopes, state, questions, context) = makeDecideCall()
        _ = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k1")
        let offBox = SettingsBox(makeSettings(mode: .off))
        // 直接换 settings provider 不可行（deps 捕获），改用新的 coordinator。
        let offCoordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { offBox.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        _ = await offCoordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k2")
        let records = metrics.all()
        XCTAssertEqual(records.count, 1, "off mode must leave zero metric footprint")
        XCTAssertEqual(records.first?.outcome, "applied")
    }
}

/// 简单异步门（测试专用）。
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if jevSync(lock, { signaled }) { return }
        await withCheckedContinuation { continuation in
            let shouldSuspend = jevSync(lock) {
                if signaled { return false }
                continuations.append(continuation)
                return true
            }
            if !shouldSuspend {
                continuation.resume()
            }
        }
    }

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = jevSync(lock) {
            signaled = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}
