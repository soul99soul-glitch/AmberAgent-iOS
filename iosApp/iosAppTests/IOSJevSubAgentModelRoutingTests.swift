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
        let prefixed: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: answers.map {
            ("single." + $0.key, ["type": "score", "score": $0.value])
        })
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": prefixed,
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

    private func makeCandidate(
        id: String,
        providerName: String? = nil,
        abilities: [ModelAbility] = [],
        contextWindowTokens: KotlinInt? = KotlinInt(value: 128_000),
        configuredReasoning: ReasoningLevel? = nil,
        supportedReasoning: [ReasoningLevel] = [.medium]
    ) -> IOSSubAgentModelPool.Candidate {
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
            abilities: abilities,
            tools: Set<BuiltInTools>(),
            contextWindowTokens: contextWindowTokens,
            providerOverwrite: nil
        )
        let provider = provider(id: KotlinUuid.companion.random(), name: providerName ?? "p-\(id)")
        return IOSSubAgentModelPool.Candidate(
            model: model,
            provider: provider,
            configuredReasoning: configuredReasoning,
            supportedReasoning: supportedReasoning
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
        let candidates = ["model-a", "model-b"].map { makeCandidate(id: $0) }
        let ranked = await service.rankedPreferredModelIds(
            taskText: "整理这段文本",
            candidates: candidates,
            turnBudgetKey: "run-test"
)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testScopeNotAllowedReturnsEmpty() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([], for: .modelRouting)
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let candidates = ["model-a"].map { makeCandidate(id: $0) }
        let ranked = await service.rankedPreferredModelIds(
            taskText: "任务",
            candidates: candidates,
            turnBudgetKey: "run-test"
)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testModelMetadataNeedsItsOwnScope() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.selectedTaskText], for: .modelRouting)
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let result = await service.rankedPreferredModelIds(
            taskText: "任务", candidates: [makeCandidate(id: "model-a")], turnBudgetKey: "run"
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(transport.calls, 0)
    }

    func testActiveRanksByFitAndDropsBelowThreshold() async {
        let candidates = ["model-a", "model-b", "model-c"].map { makeCandidate(id: $0) }
        let transport = JevStubTransport { _ in
            (self.scorePayload([
                candidates[0].modelId: 2.5,
                candidates[1].modelId: 1.0,
                candidates[2].modelId: 2.8,
            ]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let ranked = await service.rankedPreferredModelIds(
            taskText: "修复这段代码的空指针",
            candidates: candidates,
            turnBudgetKey: "run-test"
)
        XCTAssertEqual(ranked, [candidates[2].modelId, candidates[0].modelId], "ranked by fit, below-threshold dropped")
    }

    func testMissingScoreFallsBackWithoutPartialRouting() async {
        let candidates = ["model-a", "model-b"].map { makeCandidate(id: $0) }
        let transport = JevStubTransport { _ in
            (self.scorePayload([candidates[0].modelId: 2.5]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let ranked = await service.rankedPreferredModelIds(
            taskText: "任务",
            candidates: candidates,
            turnBudgetKey: "run-test"
)
        XCTAssertTrue(ranked.isEmpty, "incomplete answers must fail open to the local pool")
    }

    func testFailureReturnsEmpty() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let candidates = ["model-a"].map { makeCandidate(id: $0) }
        let ranked = await service.rankedPreferredModelIds(
            taskText: "任务",
            candidates: candidates,
            turnBudgetKey: "run-test"
)
        XCTAssertTrue(ranked.isEmpty, "failure falls back to existing selection")
    }

    func testPreferredCandidatesIntersectsWithPool() {
        let candidates = ["model-a", "model-b"].map { makeCandidate(id: $0) }
        let preferred = IOSJevModelRoutingService.preferredCandidates(
            from: candidates,
            rankedIds: [candidates[1].modelId, "gone-model", candidates[0].modelId]
        )
        XCTAssertEqual(preferred.map(\.modelId), [candidates[1].modelId, candidates[0].modelId], "unknown ids dropped, Jev order preserved")
    }

    func testSameModelNameAcrossProvidersKeepsBothCandidatesAndUsesFacts() async throws {
        let candidates = [
            makeCandidate(
                id: "shared-api-model",
                providerName: "OpenAI API",
                abilities: [.tool, .reasoning],
                configuredReasoning: .high,
                supportedReasoning: [.medium, .high]
            ),
            makeCandidate(
                id: "shared-api-model",
                providerName: "Codex Login",
                contextWindowTokens: nil,
                supportedReasoning: []
            ),
        ]
        let candidateIDs = candidates.map(\.modelId)
        let answers = Dictionary(uniqueKeysWithValues: candidateIDs.map { ($0, 2.8) })
        let transport = JevStubTransport { _ in
            (self.scorePayload(answers), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)

        let ranked = await service.rankedPreferredModelIds(
            taskText: "实现复杂任务",
            candidates: candidates,
            turnBudgetKey: "run-duplicate-api-model"
        )

        XCTAssertEqual(Set(ranked), Set(candidateIDs), "same API model name under separate providers must retain both pool entries")
        XCTAssertEqual(
            IOSJevModelRoutingService.preferredCandidates(from: candidates, rankedIds: ranked).count,
            2,
            "ranked candidate UUIDs must intersect the pool"
        )
        let body = try XCTUnwrap(transport.lastBody)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(request["state"] as? String)
        let questions = try XCTUnwrap(request["questions"] as? [String: Any])
        XCTAssertTrue(candidateIDs.allSatisfy { questions["single." + $0] != nil })
        XCTAssertTrue(state.contains("provider=OpenAI API"))
        XCTAssertTrue(state.contains("provider=Codex Login"))
        XCTAssertTrue(state.contains("abilities=reasoning,tool"))
        XCTAssertTrue(state.contains("context=unknown"))
        XCTAssertTrue(state.contains("supported_reasoning=unknown"))
        XCTAssertTrue(state.contains("configured_reasoning=high"))
    }

    /// A3 置信弃权：低置信高分配适分不进首选集；高置信候选照常。
    func testConfidenceFloorDropsLowConfidenceFit() async {
        let candidates = ["model-a", "model-b"].map { makeCandidate(id: $0) }
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "single." + candidates[0].modelId: ["type": "score", "score": 2.9, "confidence": 0.3],
                "single." + candidates[1].modelId: ["type": "score", "score": 2.5, "confidence": 0.95],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        var settings = makeSettings(mode: .active)
        settings.policy.modelRoutingMinConfidence = 0.5
        let service = makeService(settings: settings, transport: transport)
        let ranked = await service.rankedPreferredModelIds(
            taskText: "修复这段代码的空指针",
            candidates: candidates,
            turnBudgetKey: "run-test"
        )
        XCTAssertEqual(ranked, [candidates[1].modelId], "低置信高分被弃权")
    }
}
