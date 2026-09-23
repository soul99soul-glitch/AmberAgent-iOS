import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevToolDiscoveryTests：精确名 bypass 零 Jev、off 零网络、shadow 返回关键
// 词结果但发起观测、active 应用排序（未知名丢弃、低分回退）、范围拒绝回退、
// 暴露集合只经 bridge 更新。

@MainActor
final class IOSJevToolDiscoveryTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func scorePayload(_ answers: [String: Double], suitable: Double = 0.9, confidences: [String: Double] = [:], for request: URLRequest) -> Data {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let requested = body["questions"] as! [String: Any]
        var rawAnswers: [String: [String: Any]] = [:]
        for id in requested.keys where id != "single." + IOSJevToolDiscoveryService.suitabilityQuestionID {
            let localId = id.hasPrefix("single.") ? String(id.dropFirst("single.".count)) : id
            rawAnswers[id] = ["type": "score", "score": answers[localId] ?? 0.0, "confidence": confidences[localId] ?? 0.9]
        }
        rawAnswers["single." + IOSJevToolDiscoveryService.suitabilityQuestionID] = [
            "type": "noul",
            "noul": suitable,
        ]
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": rawAnswers,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Bridge construction（45 条合成工具 → lazy 模式）

    private func makeBridge() -> IosToolExposureBridge {
        let tools = JevFixtures.tools.map { fixture in
            IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
                toolId: fixture.name,
                version: "1",
                description: fixture.description,
                inputsJson: "{}",
                effectClass: "pure"
            )
        }
        return IosToolExposureBridge(tools: tools)
    }

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .toolDiscovery)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeCoordinator(settings: IOSJevSettings, transport: JevStubTransport) -> IOSJevDecisionCoordinator {
        let box = SettingsBox(settings)
        return IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
    }

    /// 返回 (coordinator, settings)：直接调 IOSJevToolDiscoveryService.execute。
    private func makeService(
        settings: IOSJevSettings,
        transport: JevStubTransport
    ) -> (IOSJevDecisionCoordinator, IOSJevSettings) {
        (makeCoordinator(settings: settings, transport: transport), settings)
    }

    private let args = #"{"query":"帮我把总结保存成文件","limit":5}"#

    /// 在被测 bridge 上执行纯关键词搜索，避免拿另一份目录/暴露状态作基线。
    private func keywordFirstResult(bridge: IosToolExposureBridge, argumentsJson: String) -> String? {
        let baseline = bridge.executeToolSearch(argumentsJson: argumentsJson)
        let object = try! JSONSerialization.jsonObject(with: baseline.data(using: .utf8)!) as! [String: Any]
        return (object["expanded_tools"] as? [String])?.first
    }

    private func execute(
        _ service: (IOSJevDecisionCoordinator, IOSJevSettings),
        argumentsJson: String,
        bridge: IosToolExposureBridge?,
        identity: IOSJevToolDiscoveryService.RunIdentity
    ) async -> String {
        await IOSJevToolDiscoveryService.execute(
            argumentsJson: argumentsJson,
            bridge: bridge,
            coordinator: service.0,
            settingsProvider: { service.1 },
            identity: identity
        )
    }

    private func identity() -> IOSJevToolDiscoveryService.RunIdentity {
        .init(runId: "run", turnBudgetKey: "turn")
    }

    // MARK: Bridge snapshot entries

    func testCandidateSnapshotIsReadOnlyAndPoolsCurrentRegistry() {
        let bridge = makeBridge()
        let snapshot = bridge.candidateSnapshot(argumentsJson: args)
        let object = try! JSONSerialization.jsonObject(with: snapshot.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(object["status"] as? String, "ok")
        let candidates = object["candidates"] as! [[String: Any]]
        XCTAssertFalse(candidates.isEmpty)
        // 候选必须全部属于当前 run 目录。
        let names = Set(candidates.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSubset(of: Set(JevFixtures.tools.map(\.name) + ["tool_search"])))
        // 只读：快照后暴露集合不变（lazy 模式下非驻留工具仍隐藏）。
        let visibleBefore = bridge.visibleTools().map(\.name)
        _ = bridge.candidateSnapshot(argumentsJson: args)
        XCTAssertEqual(Set(bridge.visibleTools().map(\.name)), Set(visibleBefore))
    }

    func testRankingOverrideReordersAndDropsUnknownNames() {
        let bridge = makeBridge()
        // Jev 排序：把评分给到 workspace_file_write 与一个不存在的名字。
        let ranked = ["totally_unknown_tool", "workspace_file_write", "wm_click"]
        let payload = bridge.executeToolSearch(argumentsJson: args, rankingOverride: ranked)
        let object = try! JSONSerialization.jsonObject(with: payload.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, "workspace_file_write", "ranking override must drive order")
        XCTAssertFalse(expanded.contains("totally_unknown_tool"), "unknown names must be dropped")
        XCTAssertTrue(expanded.contains("wm_click"))
        // 暴露生效（下一轮可调用）。
        let visible = Set(bridge.visibleTools().map(\.name))
        XCTAssertTrue(visible.contains("workspace_file_write"))
    }

    func testRequestIncludesUserWordsAndOneSuitableToolQuestion() throws {
        var settings = makeSettings(mode: .active)
        settings.policy.maxQuestions = 4
        let parsed = IOSJevToolDiscoveryService.ParsedSnapshot(
            query: "查日程",
            category: nil,
            exactMatch: nil,
            candidates: [
                .init(
                    name: IOSJevToolDiscoveryService.suitabilityQuestionID,
                    category: "calendar",
                    description: "查询日程",
                    mutates: false,
                    keywordScore: 1
                ),
                .init(name: "calendar_create", category: "calendar", description: "创建日程", mutates: true, keywordScore: 1),
                .init(name: "calendar_list", category: "calendar", description: "列出日程", mutates: false, keywordScore: 1),
                .init(name: "calendar_search", category: "calendar", description: "搜索日程", mutates: false, keywordScore: 1),
            ]
        )

        let built = try XCTUnwrap(IOSJevToolDiscoveryService.makeRequest(
            parsed: parsed,
            selectedTaskText: "  请找出我刚才提到的周五会议，并告诉我安排。  ",
            settings: settings
        ))

        XCTAssertTrue(built.state.contains("用户最新原话：请找出我刚才提到的周五会议，并告诉我安排。"))
        XCTAssertEqual(built.questions.count, settings.policy.maxQuestions)
        XCTAssertEqual(built.questions.last?.type, "noul")
        XCTAssertNotEqual(built.suitabilityQuestionID, IOSJevToolDiscoveryService.suitabilityQuestionID)
        XCTAssertEqual(Set(built.questions.map(\.id)).count, built.questions.count)
    }

    // MARK: Service paths

    func testExactNameQueryBypassesJev() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let bridge = makeBridge()
        let output = await execute(service, 
            argumentsJson: #"{"query":"wm_click","limit":5}"#,
            bridge: bridge,
            identity: identity()
        )
        XCTAssertEqual(transport.calls, 0, "exact tool name must not consume Jev")
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual((object["expanded_tools"] as! [String]).first, "wm_click")
    }

    func testOffModeZeroNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off), transport: transport)
        let bridge = makeBridge()
        _ = await execute(service, argumentsJson: args, bridge: bridge, identity: identity())
        XCTAssertEqual(transport.calls, 0)
    }

    func testActiveAppliesJevRanking() async {
        // 关键词对"保存文件"命中 workspace_file_write；Jev 给 wm_click 更高分
        // 也应重排到前面（active 语义），且都在 expanded_tools。
        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8, "workspace_file_write": 2.0], for: request), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let output = await execute(service, argumentsJson: args, bridge: bridge, identity: identity())
        XCTAssertGreaterThan(transport.calls, 0)
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, "wm_click", "active must apply Jev ranking")
        XCTAssertTrue(expanded.contains("workspace_file_write"))
    }

    func testActiveExposureRatioUsesReadOnlyKeywordPreview() async throws {
        IOSJevMetricsStore.clear()
        defer {
            IOSJevToolDiscoveryMetricsTracker.discardPending(runId: "run")
            IOSJevMetricsStore.clear()
        }

        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let bridge = makeBridge()
        let keywordPreview = try XCTUnwrap(JSONSerialization.jsonObject(
            with: bridge.previewToolSearch(argumentsJson: queryArgs).data(using: .utf8)!
        ) as? [String: Any])
        let keywordCount = Set(keywordPreview["expanded_tools"] as? [String] ?? []).count
        XCTAssertGreaterThan(keywordCount, 0)

        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8, "workspace_file_write": 2.0], for: request), self.httpResponse(status: 200))
        }
        let output = await execute(
            makeService(settings: makeSettings(mode: .active), transport: transport),
            argumentsJson: queryArgs,
            bridge: bridge,
            identity: .init(runId: "run", turnBudgetKey: "turn", trackNextForegroundStep: true)
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as? [String: Any])
        let activeCount = Set(payload["expanded_tools"] as? [String] ?? []).count
        let exposureRecords = IOSJevMetricsStore.load().filter {
            $0.useCase == .toolDiscovery && $0.outcome == "summary" && $0.numbers?["exposure_ratio"] != nil
        }
        let exposureRecord = try XCTUnwrap(exposureRecords.last)
        let exposureRatio = try XCTUnwrap(exposureRecord.numbers?["exposure_ratio"])
        XCTAssertEqual(
            exposureRatio,
            Double(activeCount) / Double(keywordCount),
            accuracy: 0.000_001
        )

        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
            runId: "run",
            calledToolNames: ["wm_click"]
        )
        let nextStepRecord = try XCTUnwrap(IOSJevMetricsStore.load().last {
            $0.useCase == .toolDiscovery && $0.numbers?["next_step_new_tool_used"] != nil
        })
        XCTAssertEqual(nextStepRecord.numbers?["next_step_new_tool_used"], 1)
    }

    func testBackgroundLikeDiscoveryDoesNotRetainForegroundTracker() async {
        IOSJevMetricsStore.clear()
        defer {
            IOSJevToolDiscoveryMetricsTracker.discardPending(runId: "run")
            IOSJevMetricsStore.clear()
        }
        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8], for: request), self.httpResponse(status: 200))
        }
        _ = await execute(
            makeService(settings: makeSettings(mode: .active), transport: transport),
            argumentsJson: args,
            bridge: makeBridge(),
            identity: identity()
        )
        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(runId: "run", calledToolNames: ["wm_click"])
        XCTAssertFalse(IOSJevMetricsStore.load().contains(where: { $0.numbers?["next_step_new_tool_used"] != nil }))
    }

    func testNextModelStepTrackerRecordsEachPendingSearchOnce() {
        IOSJevMetricsStore.clear()
        defer {
            IOSJevToolDiscoveryMetricsTracker.discardPending(runId: "tracker-run")
            IOSJevMetricsStore.clear()
        }

        IOSJevToolDiscoveryMetricsTracker.registerActiveExposure(
            runId: "tracker-run", exposedToolNames: ["tool_used"], modelVersion: "jev-v1"
        )
        IOSJevToolDiscoveryMetricsTracker.registerActiveExposure(
            runId: "tracker-run", exposedToolNames: ["tool_not_used"], modelVersion: "jev-v1"
        )
        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
            runId: "tracker-run", calledToolNames: ["tool_used"]
        )

        let outcomes = IOSJevMetricsStore.load().compactMap { record -> Double? in
            guard record.useCase == .toolDiscovery else { return nil }
            return record.numbers?["next_step_new_tool_used"]
        }
        XCTAssertEqual(outcomes, [1, 0])

        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
            runId: "tracker-run", calledToolNames: ["tool_used"]
        )
        XCTAssertEqual(
            IOSJevMetricsStore.load().compactMap { $0.numbers?["next_step_new_tool_used"] },
            [1, 0],
            "one next model response must consume all pending searches exactly once"
        )
    }

    func testActiveExposureContainsOnlyRankedResultsAndRelatedExpansion() async throws {
        let queryArgs = #"{"query":"在系统日历创建会议","limit":5}"#
        let bridge = makeBridge()
        let before = Set(bridge.visibleTools().map(\.name))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: bridge.candidateSnapshot(argumentsJson: queryArgs).data(using: .utf8)!
        ) as? [String: Any])
        let candidateNames = Set((snapshot["candidates"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        XCTAssertTrue(candidateNames.contains("calendar_event_create"))
        XCTAssertTrue(candidateNames.contains("wm_click"))

        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8], for: request), self.httpResponse(status: 200))
        }
        let output = await execute(
            makeService(settings: makeSettings(mode: .active), transport: transport),
            argumentsJson: queryArgs,
            bridge: bridge,
            identity: identity()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as? [String: Any])
        let expanded = Set(object["expanded_tools"] as? [String] ?? [])
        let newlyExposed = Set(bridge.visibleTools().map(\.name)).subtracting(before)

        XCTAssertTrue(expanded.contains("wm_click"))
        XCTAssertTrue(expanded.contains("wm_open"), "related WebMount tools must remain included in the ranked exposure")
        XCTAssertFalse(expanded.contains("calendar_event_create"), "keyword-only results must not survive the applied Jev ranking")
        XCTAssertEqual(newlyExposed, expanded.subtracting(before), "only ranked results and their related expansion become visible")
    }

    func testLowConfidenceFallsBackToKeywordOrder() async {
        // 全部低分 → 回退关键词顺序。查询含英文 token "file"（中文整句无空格
        // 时关键词路径本来召回为空——那是 Jev 要补的基线缺口，不作回退断言载体）。
        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 0.4, "workspace_file_write": 0.2], for: request), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, keywordFirstResult(bridge: bridge, argumentsJson: queryArgs), "low confidence must fall back to keyword order")
    }

    func testNoSuitableToolFallsBackToKeywordResults() async {
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8], suitable: 0.1, for: request), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let output = await execute(
            makeService(settings: makeSettings(mode: .active), transport: transport),
            argumentsJson: queryArgs,
            bridge: bridge,
            identity: identity()
        )
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]

        XCTAssertEqual(expanded.first, keywordFirstResult(bridge: bridge, argumentsJson: queryArgs))
        XCTAssertFalse(expanded.contains("wm_click"), "a negative suitable-tool judgment must skip Jev ranking")
    }

    func testShadowReturnsKeywordResultButObserves() async {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let transport = JevStubTransport { request in
            (self.scorePayload(["wm_click": 2.8], for: request), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        // shadow 已改为后台观测（不阻塞主路径）；等待一拍再确认发生了调用。
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(transport.calls, 0, "shadow must observe via network")
        XCTAssertNotNil(IOSJevMetricsStore.useCaseSummaries().first(where: { $0.useCase == .toolDiscovery })?.exposureRatio,
                        "shadow should record a hypothetical exposure ratio without changing the keyword result")
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, keywordFirstResult(bridge: bridge, argumentsJson: queryArgs), "shadow must return keyword result")
    }

    func testScopeNotAllowedSkipsNetwork() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.toolMetadata], for: .toolDiscovery) // 缺 selectedTaskText
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let bridge = makeBridge()
        _ = await execute(service, argumentsJson: args, bridge: bridge, identity: identity())
        XCTAssertEqual(transport.calls, 0)
    }

    func testNetworkFailureFallsBackToKeywordResult() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let before = Set(bridge.visibleTools().map(\.name))
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as? [String] ?? []
        XCTAssertEqual(
            expanded.first,
            keywordFirstResult(bridge: bridge, argumentsJson: queryArgs),
            "network failure must fall back to keyword result"
        )
        XCTAssertEqual(
            Set(bridge.visibleTools().map(\.name)).subtracting(before),
            Set(expanded).subtracting(before),
            "fallback exposure must match the original keyword result"
        )
    }

    func testFrozenToolCasesRunThroughKeywordBaseline() {
        // 基线：记录冻结集在纯关键词路径下的命中（Recall@5 对比用）。
        let bridge = makeBridge()
        var hits = 0
        var total = 0
        for evalCase in JevFixtures.frozenCases where !evalCase.noAnswer {
            total += 1
            let payload = bridge.executeToolSearch(
                argumentsJson: #"{"query":"\#(evalCase.query.replacingOccurrences(of: "\"", with: "\\\""))","limit":5}"#
            )
            let object = try! JSONSerialization.jsonObject(with: payload.data(using: .utf8)!) as! [String: Any]
            let expanded = Set((object["expanded_tools"] as? [String]) ?? [])
            if evalCase.mustFind.allSatisfy(expanded.contains) {
                hits += 1
            }
        }
        // 基线不必满分；该断言只锁定基线可运行并输出结构合法。
        XCTAssertGreaterThan(total, 0)
        print("[Jev Phase 1 baseline] tool frozen cases full-hit: \(hits)/\(total)")
    }

    // MARK: 契约锁（候选数 × 题数）

    /// 每候选一题、总题数 ≤ maxQuestions：客户端对超题数是出站前硬拒绝，
    /// 且 KMP 快照池的 32 条上限与本截断各自独立演进，任何一侧调整都不许
    /// 让 active 在大候选集下静默回退。
    func testMakeRequestCapsQuestionsAtMaxQuestions() {
        var settings = IOSJevSettings()
        settings.policy.maxQuestions = 32
        settings.policy.maxCandidates = 64
        let candidates = (0..<40).map { index in
            IOSJevToolDiscoveryService.SnapshotCandidate(
                name: "tool_\(index)", category: "workspace",
                description: "d\(index)", mutates: false, keywordScore: index
            )
        }
        let parsed = IOSJevToolDiscoveryService.ParsedSnapshot(
            query: "查询", category: nil, exactMatch: nil, candidates: candidates
        )
        let built = IOSJevToolDiscoveryService.makeRequest(parsed: parsed, settings: settings)
        XCTAssertNotNil(built)
        XCTAssertLessThanOrEqual(built!.questions.count, 32, "questions must never exceed client maxQuestions")
        XCTAssertFalse(built!.state.contains("tool_39"), "candidates beyond the cap must not leak into state")
    }

    /// A3 置信弃权：高分但置信低于 policy 阈值的候选按未入选计；
    /// 不设阈值时同一响应仍由高分候选领先（对照证明是置信门在起作用）。
    func testConfidenceFloorGatesHighScoreCandidate() async {
        let response: (URLRequest) -> Data = { request in
            self.scorePayload(
                ["wm_click": 2.8, "workspace_file_write": 2.0],
                confidences: ["wm_click": 0.3, "workspace_file_write": 0.95],
                for: request
            )
        }

        let ungatedTransport = JevStubTransport { request in (response(request), self.httpResponse(status: 200)) }
        let ungated = await execute(
            makeService(settings: makeSettings(mode: .active), transport: ungatedTransport),
            argumentsJson: args, bridge: makeBridge(), identity: identity()
        )
        let ungatedObject = try! JSONSerialization.jsonObject(with: ungated.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual((ungatedObject["expanded_tools"] as! [String]).first, "wm_click", "无阈值：高分低置信候选领先")

        var gated = makeSettings(mode: .active)
        gated.policy.toolDiscoveryMinConfidence = 0.5
        let gatedTransport = JevStubTransport { request in (response(request), self.httpResponse(status: 200)) }
        let output = await execute(
            makeService(settings: gated, transport: gatedTransport),
            argumentsJson: args, bridge: makeBridge(), identity: identity()
        )
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, "workspace_file_write", "低置信高分候选被弃权，次候选顶上")
        XCTAssertFalse(expanded.contains("wm_click"), "被弃权候选不进入暴露集合")
    }
}
