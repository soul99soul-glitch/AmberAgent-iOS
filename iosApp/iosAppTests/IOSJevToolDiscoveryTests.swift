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

    private func scorePayload(_ answers: [String: Double]) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": answers.mapValues { ["type": "score", "score": $0] },
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

    /// 纯关键词参考结果（用于回退语义断言，不硬编码具体工具名）。
    private func keywordFirstResult(bridge: IosToolExposureBridge, argumentsJson: String) -> String? {
        let referenceBridge = makeBridge()
        let reference = referenceBridge.executeToolSearch(argumentsJson: argumentsJson)
        let object = try! JSONSerialization.jsonObject(with: reference.data(using: .utf8)!) as! [String: Any]
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
        let transport = JevStubTransport { _ in
            (self.scorePayload(["wm_click": 2.8, "workspace_file_write": 2.0]), self.httpResponse(status: 200))
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

    func testLowConfidenceFallsBackToKeywordOrder() async {
        // 全部低分 → 回退关键词顺序。查询含英文 token "file"（中文整句无空格
        // 时关键词路径本来召回为空——那是 Jev 要补的基线缺口，不作回退断言载体）。
        let transport = JevStubTransport { _ in
            (self.scorePayload(["wm_click": 0.4, "workspace_file_write": 0.2]), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        let expanded = object["expanded_tools"] as! [String]
        XCTAssertEqual(expanded.first, keywordFirstResult(bridge: bridge, argumentsJson: queryArgs), "low confidence must fall back to keyword order")
    }

    func testShadowReturnsKeywordResultButObserves() async {
        let transport = JevStubTransport { _ in
            (self.scorePayload(["wm_click": 2.8]), self.httpResponse(status: 200))
        }
        let bridge = makeBridge()
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let queryArgs = #"{"query":"save the file to disk","limit":5}"#
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        // shadow 已改为后台观测（不阻塞主路径）；等待一拍再确认发生了调用。
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(transport.calls, 0, "shadow must observe via network")
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
        let output = await execute(service, argumentsJson: queryArgs, bridge: bridge, identity: identity())
        let object = try! JSONSerialization.jsonObject(with: output.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(
            (object["expanded_tools"] as! [String]).first,
            keywordFirstResult(bridge: bridge, argumentsJson: queryArgs),
            "network failure must fall back to keyword result"
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
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "wm_click": ["type": "score", "score": 2.8, "confidence": 0.3],
                "workspace_file_write": ["type": "score", "score": 2.0, "confidence": 0.95],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)

        let ungatedTransport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let ungated = await execute(
            makeService(settings: makeSettings(mode: .active), transport: ungatedTransport),
            argumentsJson: args, bridge: makeBridge(), identity: identity()
        )
        let ungatedObject = try! JSONSerialization.jsonObject(with: ungated.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual((ungatedObject["expanded_tools"] as! [String]).first, "wm_click", "无阈值：高分低置信候选领先")

        var gated = makeSettings(mode: .active)
        gated.policy.toolDiscoveryMinConfidence = 0.5
        let gatedTransport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
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

