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
        let mapped: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: answers.map {
            ("single." + $0.key, ["type": "score", "score": $0.value])
        })
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": mapped,
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

    /// Phase 4：webActions 用专属更长 deadline（2500ms 默认）。慢 transport
    /// 睡 1.5s：默认 1200ms 的用途必超时，webActions 可完成——超时一次烧掉
    /// 整轮观察+决策，长视野更划算；其余用途保持轻快判断语义。
    func testWebActionsUsesExtendedDeadline() async {
        let transport = JevStubTransport { _ in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        var webSettings = IOSJevSettings()
        webSettings.setMode(.active, for: .webActions)
        webSettings.pinnedModelVersion = "jev-fixed-v1"
        webSettings.setScopes([.webContent, .selectedTaskText], for: .webActions)
        let webBox = SettingsBox(webSettings)
        let webCoordinator = makeCoordinator(settings: webBox, transport: transport)
        let webOutcome = await webCoordinator.decide(
            useCase: .webActions,
            requiredScopes: [.webContent, .selectedTaskText],
            state: "state text",
            questions: [IOSJevQuestion.score(id: "t1", levels: ["0", "3"], instructions: "test")],
            context: IOSJevRunContext(runId: "run-w", turnBudgetKey: "turn-w", inputHash: "h"),
            cacheKey: nil,
            waitBudgetMs: 2_000
        )
        guard case .applied = webOutcome else {
            return XCTFail("webActions 2500ms deadline 应容纳 1.5s 慢响应：\(webOutcome)")
        }

        // 同一慢 transport 在 toolDiscovery（1200ms）下必须超时。
        let box = SettingsBox(makeSettings(mode: .active))
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(
            useCase: .toolDiscovery, requiredScopes: scopes,
            state: state, questions: questions, context: context, cacheKey: "k", waitBudgetMs: 2_000
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("toolDiscovery 1200ms 应对 1.5s 响应超时：\(outcome)")
        }
        XCTAssertEqual(reason, "timeout")
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

    func testPerRunAllowsThreeActiveAndQueuesFourthUntilWaitBudget() async {
        let box = SettingsBox(makeSettings())
        let gate = continuationGate()
        let transport = JevStubTransport { _ in
            await gate.wait()
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let firstThree = (0..<3).map { index in
            Task { await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "c\(index)", waitBudgetMs: 2_000) }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.calls, 3)
        let fourth = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "c4", waitBudgetMs: 80)
        guard case .skipped = fourth else {
            for _ in 0..<3 { gate.release() }
            return XCTFail("fourth request must fall back after wait budget: \(fourth)")
        }
        XCTAssertEqual(transport.calls, 3)
        for _ in 0..<3 { gate.release() }
        for task in firstThree {
            guard case .applied = await task.value else { return XCTFail("first three active requests should complete") }
        }
    }

    func testBatchOmitsDisallowedStateAndSplitsAnswersByPart() async throws {
        var settings = makeSettings()
        settings.setMode(.active, for: .memoryRecall)
        settings.setScopes([.selectedTaskText], for: .memoryRecall)
        let box = SettingsBox(settings)
        let transport = JevStubTransport { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let state = body["state"] as! String
            XCTAssertTrue(state.contains("allowed catalogue"))
            XCTAssertFalse(state.contains("private memory"))
            let questions = body["questions"] as! [String: Any]
            XCTAssertEqual(Set(questions.keys), ["tools.t1"])
            let payload: [String: Any] = [
                "model": "jev-fixed-v1",
                "answers": [
                    "tools.t1": ["type": "score", "score": 0.9],
                    "unknown.t1": ["type": "score", "score": 0.9],
                ],
            ]
            return (try! JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let parts = [
            IOSJevBatchPart(id: "tools", useCase: .toolDiscovery, requiredScopes: [.toolMetadata, .selectedTaskText], state: "allowed catalogue", questions: [.score(id: "t1", levels: ["0", "1"], instructions: "a")]),
            IOSJevBatchPart(id: "memory", useCase: .memoryRecall, requiredScopes: [.personalMemory], state: "private memory", questions: [.score(id: "t1", levels: ["0", "1"], instructions: "b")]),
        ]
        let outcomes = await coordinator.decideBatch(parts: parts, context: IOSJevRunContext(runId: "r", turnBudgetKey: "r", inputHash: "h"))
        guard case .applied(let tools)? = outcomes["tools"] else { return XCTFail("allowed part should apply") }
        XCTAssertEqual(tools.answers.map(\.id), ["t1"])
        guard case .skipped(let reason)? = outcomes["memory"] else { return XCTFail("disallowed part should skip") }
        XCTAssertEqual(reason, "scope_not_allowed")
        XCTAssertEqual(transport.calls, 1)
    }

    func testBatchSplitsAboveLocalQuestionLimit() async {
        var settings = makeSettings()
        settings.policy.maxQuestions = 2
        let box = SettingsBox(settings)
        let transport = JevStubTransport { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let questions = body["questions"] as! [String: Any]
            XCTAssertLessThanOrEqual(questions.count, 2)
            let answers: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: questions.keys.map {
                ($0, ["type": "score", "score": 0.9])
            })
            return (try! JSONSerialization.data(withJSONObject: ["model": "jev-fixed-v1", "answers": answers]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let questions = (1...3).map { IOSJevQuestion.score(id: "q\($0)", levels: ["0", "1"], instructions: "test") }
        let part = IOSJevBatchPart(id: "tools", useCase: .toolDiscovery, requiredScopes: [.toolMetadata, .selectedTaskText], state: "catalogue", questions: questions)
        let result = await coordinator.decideBatch(parts: [part], context: IOSJevRunContext(runId: "r", turnBudgetKey: "r", inputHash: "h"))
        guard case .applied(let decision)? = result["tools"] else { return XCTFail("split request should apply") }
        XCTAssertEqual(Set(decision.answers.map(\.id)), ["q1", "q2", "q3"])
        XCTAssertEqual(transport.calls, 2)
    }

    func testIncompleteBatchAnswersFailOnlyAffectedPart() async {
        var settings = makeSettings()
        settings.setMode(.active, for: .memoryRecall)
        settings.setScopes([.personalMemory], for: .memoryRecall)
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in
            let payload: [String: Any] = ["model": "jev-fixed-v1", "answers": ["tools.t1": ["type": "score", "score": 0.9]]]
            return (try! JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let question = [IOSJevQuestion.score(id: "t1", levels: ["0", "1"], instructions: "test")]
        let parts = [
            IOSJevBatchPart(id: "tools", useCase: .toolDiscovery, requiredScopes: [.toolMetadata, .selectedTaskText], state: "catalogue", questions: question, cacheKey: "tool"),
            IOSJevBatchPart(id: "memory", useCase: .memoryRecall, requiredScopes: [.personalMemory], state: "records", questions: question, cacheKey: "mem"),
        ]
        let results = await coordinator.decideBatch(parts: parts, context: IOSJevRunContext(runId: "r", turnBudgetKey: "r", inputHash: "h"))
        guard case .applied? = results["tools"] else { return XCTFail("complete tools part should apply") }
        guard case .failed(let reason)? = results["memory"] else { return XCTFail("missing memory answer must fail open") }
        XCTAssertEqual(reason, "incomplete_response")
        _ = await coordinator.decideBatch(parts: parts, context: IOSJevRunContext(runId: "r", turnBudgetKey: "r", inputHash: "h"))
        XCTAssertEqual(transport.calls, 2, "incomplete part must be sent again; complete part may hit cache")
    }

    func testLateResultOnlyReachesNextCachedCall() async {
        let box = SettingsBox(makeSettings())
        let metrics = MetricsSpy()
        let transport = JevStubTransport { _ in
            try? await Task.sleep(nanoseconds: 180_000_000)
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport, metrics: metrics)
        let (scopes, state, questions, context) = makeDecideCall()
        let first = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "late", waitBudgetMs: 30)
        guard case .skipped(let reason) = first, reason == "late" else { return XCTFail("first call must fall back") }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let second = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "late", waitBudgetMs: 30)
        guard case .applied(let cached) = second else { return XCTFail("late answer should be cached for next call") }
        XCTAssertEqual(cached.answers.first?.score, 0.9)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertTrue(metrics.all().contains(where: { $0.outcome == "late" }))
    }

    func testShadowOccupancyDoesNotBlockActive() async {
        var settings = makeSettings(mode: .shadow)
        settings.setMode(.active, for: .memoryRecall)
        settings.setScopes([.personalMemory], for: .memoryRecall)
        settings.policy.shadowAppLimit = 1
        let box = SettingsBox(settings)
        let gate = continuationGate()
        let transport = JevStubTransport { request in
            let state = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if state.contains("shadow-marker") { await gate.wait() }
            let answers: [String: Any] = ["single.t1": ["type": "score", "score": 0.9]]
            return (try! JSONSerialization.data(withJSONObject: ["model": "jev-fixed-v1", "answers": answers]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let context = IOSJevRunContext(runId: "same", turnBudgetKey: "same", inputHash: "h")
        let question = [IOSJevQuestion.score(id: "t1", levels: ["0", "1"], instructions: "test")]
        let shadowTask = Task { await coordinator.decide(useCase: .toolDiscovery, requiredScopes: [.toolMetadata, .selectedTaskText], state: "shadow-marker", questions: question, context: context, waitBudgetMs: 2_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let active = await coordinator.decide(useCase: .memoryRecall, requiredScopes: [.personalMemory], state: "active-marker", questions: question, context: context)
        guard case .applied = active else { gate.release(); return XCTFail("shadow must not occupy active lane") }
        gate.release()
        _ = await shadowTask.value
    }

    func testConcurrentRequestsReserveExactDailyBodyBudget() async throws {
        var settings = makeSettings()
        let (scopes, state, questions, context) = makeDecideCall()
        var prefixed = questions[0]
        prefixed.id = "single." + prefixed.id
        let client = IOSJevClient(transport: JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) })
        let encodedBytes = try client.requestBodyByteCount(.init(
            endpoint: settings.resolvedEndpoint, apiKey: "test-key", model: settings.activeModelVersion,
            state: "## toolDiscovery.single\n" + state, questions: [prefixed], style: settings.apiStyle
        ))
        settings.policy.dailyRequestBodyBudgetBytes = encodedBytes
        let box = SettingsBox(settings)
        let gate = continuationGate()
        let transport = JevStubTransport { _ in
            await gate.wait()
            return (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let first = Task { await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "first", waitBudgetMs: 2_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "second")
        guard case .skipped(let reason) = second else { gate.release(); return XCTFail("second body must exceed reserved budget") }
        XCTAssertEqual(reason, "budget_exhausted")
        XCTAssertEqual(transport.calls, 1)
        gate.release()
        guard case .applied = await first.value else { return XCTFail("first request should complete") }
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

    /// 永久性 4xx 不计入冷却计数：跨 run 重复失败不得触发全局 cooling_down
    /// 殃及其他用例——第 4 次 decide 仍应真实出站并以 http_400 失败。
    func testPermanentHttpFailuresDoNotTripCooldown() async {
        let box = SettingsBox(makeSettings())
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 400)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        for index in 0..<4 {
            let (scopes, state, questions, context) = makeDecideCall(
                context: IOSJevRunContext(runId: "run\(index)", turnBudgetKey: "turn\(index)", inputHash: "h\(index)")
            )
            let outcome = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions, context: context, cacheKey: "k\(index)")
            guard case .failed(let reason) = outcome, reason == "http_400" else {
                return XCTFail("decide \(index) must still hit the wire and fail http_400, got \(outcome)")
            }
        }
        XCTAssertEqual(transport.calls, 4, "4xx 不内部重试、不触发冷却：每次都真实出站")
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

    func testDeferredBatchRejectsChangedSettingsRevisionBeforeNetwork() async {
        let settings = makeSettings()
        let box = SettingsBox(settings)
        let transport = JevStubTransport { _ in (self.scorePayload(["t1": 0.9]), self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let part = IOSJevBatchPart(id: "route", useCase: .toolDiscovery, requiredScopes: scopes, state: state, questions: questions)
        let outcomes = await coordinator.decideBatch(
            parts: [part], context: context,
            expectedSettingsRevision: settings.revision + 1
        )
        guard case .skipped(let reason)? = outcomes["route"] else { return XCTFail("stale deferred request must skip") }
        XCTAssertEqual(reason, "config_changed")
        XCTAssertEqual(transport.calls, 0)
    }

    func testConnectionTestDoesNotAcceptStaleConfiguration() async {
        let box = SettingsBox(makeSettings())
        let gate = continuationGate()
        let transport = JevStubTransport { _ in
            await gate.wait()
            let payload: [String: Any] = ["model": "jev-fixed-v1", "answers": ["connectivity": ["type": "noul", "noul": 1.0]]]
            return (try! JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200))
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let task = Task { await coordinator.runConnectionTest(apiKey: "test-key") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        var changed = box.get()
        changed.setAPIStyle(.vercelGateway)
        box.set(changed)
        gate.release()
        let result = await task.value
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errorReason, "config_changed")
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

    // MARK: vercelGateway API 形态

    private func makeVercelSettings(mode: IOSJevMode = .active, model: String = "typesafe-ai/jev") -> IOSJevSettings {
        var settings = makeSettings(mode: mode)
        settings.setAPIStyle(.vercelGateway)
        settings.setVercelModel(model)
        return settings
    }

    /// Gateway evaluation-model 响应：顶层 answers map + camelCase usage。
    private func vercelEvalPayload() -> Data {
        let payload: [String: Any] = [
            "answers": ["single.t1": ["type": "score", "score": 0.8]],
            "usage": ["inputTokens": 10, "outputTokens": 5],
            "providerMetadata": ["typesafe": ["confidence": ["single.t1": 0.9]]],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func vercelHTTPResponse(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: IOSJevSettings.vercelGatewayEndpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    /// vercel 模式：出站打到 gateway evaluation endpoint，body 为
    /// {state, questions} 评估负载，模型 slug 走 ai-model-id header；
    /// 答案映射后正常 applied。
    func testVercelModeRoutesToGatewayEndpointAndModel() async throws {
        let box = SettingsBox(makeVercelSettings())
        let seenURL = NSMutableArray()
        let seenModelHeader = NSMutableArray()
        let transport = JevStubTransport { request in
            seenURL.add(request.url as Any)
            seenModelHeader.add(request.value(forHTTPHeaderField: "ai-model-id") as Any)
            return (self.vercelEvalPayload(), self.vercelHTTPResponse())
        }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(
            useCase: .toolDiscovery, requiredScopes: scopes, state: state,
            questions: questions, context: context, cacheKey: nil
        )
        guard case .applied(let decision) = outcome else {
            return XCTFail("expected applied, got \(outcome)")
        }
        XCTAssertEqual(decision.answers.first?.score, 0.8)
        XCTAssertEqual(decision.answers.first?.confidence, 0.9)
        XCTAssertEqual(decision.usage?.inputTokens, 10)
        XCTAssertEqual(seenURL.firstObject as? URL, IOSJevSettings.vercelGatewayEndpoint)
        XCTAssertEqual(seenModelHeader.firstObject as? String, "typesafe-ai/jev")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["model"], "evaluation body 不含 model（走 ai-model-id header）")
        XCTAssertNil(object["messages"], "evaluation body 不是 chat completions 形态")
        XCTAssertNotNil(object["state"])
        XCTAssertNotNil(object["questions"], "evaluation body 顶层携带 questions map")
    }

    /// vercel 未配置模型 slug：active 收口 shadow 后仍按 model_unspecified 零网络跳过。
    func testVercelEmptyModelSkipsWithoutNetwork() async {
        let box = SettingsBox(makeVercelSettings(model: ""))
        let transport = JevStubTransport { _ in (Data(), self.vercelHTTPResponse()) }
        let coordinator = makeCoordinator(settings: box, transport: transport)
        let (scopes, state, questions, context) = makeDecideCall()
        let outcome = await coordinator.decide(
            useCase: .toolDiscovery, requiredScopes: scopes, state: state,
            questions: questions, context: context, cacheKey: nil
        )
        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected skipped, got \(outcome)")
        }
        XCTAssertEqual(reason, "model_unspecified")
        XCTAssertEqual(transport.calls, 0)
    }

    /// vercel 模式 active + 已填 slug：effective 直接 active（slug 即固定版本）。
    func testVercelActiveAppliesWithConfiguredModel() async {
        let settings = makeVercelSettings(mode: .active, model: "anthropic/claude-haiku-4.5")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
        XCTAssertEqual(settings.activeModelVersion, "anthropic/claude-haiku-4.5")
        XCTAssertTrue(settings.modelConfigured)
    }

    /// systemone 设置持久化兼容：旧 JSON（无 apiStyle/vercelModel）解码回默认。
    func testLegacySettingsDecodeDefaultsToSystemone() throws {
        var settings = makeSettings()
        let legacyData = try JSONEncoder().encode(settings)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        legacy.removeValue(forKey: "apiStyle")
        legacy.removeValue(forKey: "vercelModel")
        let decoded = try JSONDecoder().decode(
            IOSJevSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.apiStyle, .systemone)
        XCTAssertEqual(decoded.vercelModel, "")
        XCTAssertEqual(decoded.resolvedEndpoint, IOSJevSettings.productionEndpoint)
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.resolvedEndpoint, IOSJevSettings.vercelGatewayEndpoint)
    }

    /// A3：成功决策的指标携带头条数值（跨答案最大置信/最高分）；
    /// 缓存命中同样填充；skipped 记录为 nil。
    func testMetricsCarryHeadlineConfidenceAndScore() async {
        let box = SettingsBox(makeSettings())
        let metrics = MetricsSpy()
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "single.t1": ["type": "score", "score": 2.0, "confidence": 0.7],
                "single.t2": ["type": "score", "score": 2.8, "confidence": 0.4],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let coordinator = makeCoordinator(settings: box, transport: transport, metrics: metrics)
        let questions = [
            // 4 级量表（合法分 0...3），与答案分 2.0/2.8 对齐。
            IOSJevQuestion.score(id: "t1", levels: ["0", "1", "2", "3"], instructions: "a"),
            IOSJevQuestion.score(id: "t2", levels: ["0", "1", "2", "3"], instructions: "b"),
        ]
        let context = IOSJevRunContext(runId: "run1", turnBudgetKey: "turn1", inputHash: "h")
        let scopes: Set<IOSJevDataScope> = [.toolMetadata, .selectedTaskText]
        _ = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: "s", questions: questions, context: context, cacheKey: "k-headline")
        _ = await coordinator.decide(useCase: .toolDiscovery, requiredScopes: scopes, state: "s", questions: questions, context: context, cacheKey: "k-headline")

        let records = metrics.all()
        XCTAssertEqual(records.count, 2, "网络一次 + 缓存命中一次")
        XCTAssertEqual(records[0].outcome, "applied")
        XCTAssertEqual(records[0].topConfidence, 0.7, "头条置信 = 跨答案最大值")
        XCTAssertEqual(records[0].topScore, 2.8)
        XCTAssertEqual(records[1].topConfidence, 0.7, "缓存命中同样填充头条数值")
        XCTAssertEqual(records[1].latencyMs, 0, "缓存命中零延迟")
        XCTAssertEqual(transport.calls, 1)
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
