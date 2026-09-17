import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevSubAgentModelRoutingTests（Phase 3 模型调度）：
// 显式选择优先不被覆盖（服务只返回首选集合，选择权仍在池）、off 零网络、
// 范围拒绝返回空、低分/缺题不入首选、排序确定性、首选集与池的交集验证。

@MainActor
final class IOSJevSubAgentModelRoutingTests: XCTestCase {

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

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { jevSync(lock) { value } }
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .modelRouting)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeService(settings: IOSJevSettings, transport: JevStubTransport) -> IOSJevModelRoutingService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevModelRoutingService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() }
        ))
    }

    // MARK: 服务级（候选用 id 直构）

    private func makeCandidate(id: String) -> IOSSubAgentModelPool.Candidate {
        // KMP 类型不导出默认参数；沿 IOSSubAgentModelPoolTests 的完整构造。
        let model = Model(
            modelId: id,
            displayName: id,
            id: KotlinUuid.companion.random(),
            type: .chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 128_000),
            providerOverwrite: nil
        )
        let provider = provider(id: KotlinUuid.companion.random(), name: "p-\(id)")
        return IOSSubAgentModelPool.Candidate(
            model: model, provider: provider, configuredReasoning: nil, supportedReasoning: [.medium]
        )
    }

    private func provider(id: KotlinUuid, name: String) -> ProviderSetting.OpenAI {
        // 完整构造器（KMP 不导出默认参数），沿 IOSSubAgentModelPoolTests。
        ProviderSetting.OpenAI(
            id: id,
            enabled: true,
            name: name,
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://api.example.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: .apiKey,
            brand: .generic
        )
    }

    func testOffModeReturnsEmptyWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off), transport: transport)
        let candidates = ["model-a", "model-b"].map(makeCandidate)
        let ranked = await service.rankedPreferredModelIds(taskText: "整理这段文本", candidates: candidates)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testScopeNotAllowedReturnsEmpty() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([], for: .modelRouting)
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let candidates = ["model-a"].map(makeCandidate)
        let ranked = await service.rankedPreferredModelIds(taskText: "任务", candidates: candidates)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testActiveRanksByFitAndDropsBelowThreshold() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["model-a": 2.5, "model-b": 1.0, "model-c": 2.8]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let candidates = ["model-a", "model-b", "model-c"].map(makeCandidate)
        let ranked = await service.rankedPreferredModelIds(taskText: "修复这段代码的空指针", candidates: candidates)
        XCTAssertEqual(ranked, ["model-c", "model-a"], "ranked by fit, below-threshold dropped")
    }

    func testMissingScoreMeansNotPreferred() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["model-a": 2.5]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let candidates = ["model-a", "model-b"].map(makeCandidate)
        let ranked = await service.rankedPreferredModelIds(taskText: "任务", candidates: candidates)
        XCTAssertEqual(ranked, ["model-a"], "missing score = uncertain = not preferred")
    }

    func testFailureReturnsEmpty() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let candidates = ["model-a"].map(makeCandidate)
        let ranked = await service.rankedPreferredModelIds(taskText: "任务", candidates: candidates)
        XCTAssertTrue(ranked.isEmpty, "failure falls back to existing selection")
    }

    func testPreferredCandidatesIntersectsWithPool() {
        let candidates = ["model-a", "model-b"].map(makeCandidate)
        let preferred = IOSJevModelRoutingService.preferredCandidates(
            from: candidates,
            rankedIds: ["model-b", "gone-model", "model-a"]
        )
        XCTAssertEqual(preferred.map { $0.model.modelId }, ["model-b", "model-a"], "unknown ids dropped, Jev order preserved")
    }
}
