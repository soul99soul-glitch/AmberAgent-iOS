import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSubAgentModelPoolTests: XCTestCase {
    private func provider(id: KotlinUuid, name: String) -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: id,
            enabled: true,
            name: name,
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: .apiKey,
            brand: .generic
        )
    }

    private func model(id: KotlinUuid, name: String) -> Model {
        Model(
            modelId: name,
            displayName: name,
            id: id,
            type: .chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
    }

    func testSelectorUsesProviderThenModelLoadAndReservation() {
        let pool = IOSSubAgentModelPool()
        let providerA = provider(id: KotlinUuid.companion.random(), name: "A")
        let providerB = provider(id: KotlinUuid.companion.random(), name: "B")
        let modelA = model(id: KotlinUuid.companion.random(), name: "model-a")
        let modelB = model(id: KotlinUuid.companion.random(), name: "model-b")
        let candidateA = IOSSubAgentModelPool.Candidate(
            model: modelA,
            provider: providerA,
            configuredReasoning: nil,
            supportedReasoning: [.auto_, .medium]
        )
        let candidateB = IOSSubAgentModelPool.Candidate(
            model: modelB,
            provider: providerB,
            configuredReasoning: nil,
            supportedReasoning: [.medium]
        )

        let first = pool.select(
            from: [candidateA, candidateB],
            activeModelCounts: [candidateA.modelId: 1],
            activeProviderCounts: [candidateA.providerId: 1]
        )
        XCTAssertEqual(first?.modelId, candidateB.modelId)

        let reservation = pool.reserve(candidateB)
        let second = pool.select(
            from: [candidateA, candidateB],
            activeModelCounts: [:],
            activeProviderCounts: [:]
        )
        XCTAssertEqual(second?.modelId, candidateA.modelId)

        pool.release(reservation)
        let preview = pool.previewSelection(
            from: [candidateA, candidateB],
            activeModelCounts: [:],
            activeProviderCounts: [:]
        )
        let third = pool.select(
            from: [candidateA, candidateB],
            activeModelCounts: [:],
            activeProviderCounts: [:]
        )
        XCTAssertEqual(third?.modelId, preview?.modelId, "counterfactual preview must not advance pool rotation")
    }

    func testDefaultReasoningPrefersAutoThenMediumThenHighThenFirst() {
        let pool = IOSSubAgentModelPool()
        let providerValue = provider(id: KotlinUuid.companion.random(), name: "A")
        let modelValue = model(id: KotlinUuid.companion.random(), name: "model")
        let autoCandidate = IOSSubAgentModelPool.Candidate(
            model: modelValue,
            provider: providerValue,
            configuredReasoning: nil,
            supportedReasoning: [.max, .auto_, .medium]
        )
        XCTAssertEqual(pool.defaultReasoning(for: autoCandidate), .auto_)

        let firstCandidate = IOSSubAgentModelPool.Candidate(
            model: modelValue,
            provider: providerValue,
            configuredReasoning: nil,
            supportedReasoning: [.low, .off]
        )
        XCTAssertEqual(pool.defaultReasoning(for: firstCandidate), .low)
    }

    func testExplicitModelSelectionIsLimitedToPoolCandidates() {
        let pool = IOSSubAgentModelPool()
        let candidate = IOSSubAgentModelPool.Candidate(
            model: model(id: KotlinUuid.companion.random(), name: "model"),
            provider: provider(id: KotlinUuid.companion.random(), name: "provider"),
            configuredReasoning: nil,
            supportedReasoning: [.auto_]
        )
        XCTAssertEqual(
            pool.candidate(for: candidate.modelId, from: [candidate])?.modelId,
            candidate.modelId
        )
        XCTAssertNil(pool.candidate(
            for: KotlinUuid.companion.random().toHexDashString(),
            from: [candidate]
        ))
    }
}
