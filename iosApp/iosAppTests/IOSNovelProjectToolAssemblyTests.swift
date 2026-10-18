import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSNovelProjectToolAssemblyTests: XCTestCase {
    // MARK: - Assembly chain (adapter start → makeParameters → transport)

    func testAdapterStartThreadsProjectContextIntoDiscussionTransport() async throws {
        let model = makeModel()
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Discussion",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let captured = TestBox<NovelLiveTransportRequest>()
        let adapter = NovelLiveModelAdapter(
            catalogProvider: {
                NovelLiveModelCatalog(currentModel: model, providers: [provider])
            },
            kmpTransport: { _, callbacks in
                callbacks.onComplete()
                return nil
            },
            discussionTransport: { request, callbacks in
                captured.set(request)
                callbacks.onComplete()
                return nil
            },
            discussionSearchEnabled: { true }
        )

        let projectID = NovelProjectID()
        let branchID = NovelBranchID()
        let resolved = try await adapter.resolveModel(for: .global)
        let request = NovelModelRequest(
            runID: NovelRunID(),
            model: resolved,
            purpose: .discussion,
            messages: [],
            parameters: NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .off
            ),
            projectID: projectID,
            branchID: branchID
        )
        let events = try await adapter.start(request)
        for await _ in events { /* drain until completion */ }

        let transportRequest = try XCTUnwrap(captured.value)
        XCTAssertEqual(transportRequest.novelProjectContext?.projectID, projectID)
        XCTAssertEqual(transportRequest.novelProjectContext?.branchID, branchID)
        let toolNames = transportRequest.parameters.tools.map { $0.name }
        for name in IOSNovelProjectToolExecutor.supportedToolNames {
            XCTAssertTrue(toolNames.contains(name), "adapter.start 必须带上 \(name)")
        }
        XCTAssertTrue(toolNames.contains("ask_user"))
        XCTAssertTrue(toolNames.contains("search_web"))
    }

    func testAdapterStartOmitsProjectToolsForProsePurpose() async throws {
        let model = makeModel()
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Discussion",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let captured = TestBox<NovelLiveTransportRequest>()
        let adapter = NovelLiveModelAdapter(
            catalogProvider: {
                NovelLiveModelCatalog(currentModel: model, providers: [provider])
            },
            kmpTransport: { request, callbacks in
                captured.set(request)
                callbacks.onComplete()
                return nil
            },
            discussionTransport: { _, callbacks in
                callbacks.onComplete()
                return nil
            },
            discussionSearchEnabled: { true }
        )

        let resolved = try await adapter.resolveModel(for: .global)
        let request = NovelModelRequest(
            runID: NovelRunID(),
            model: resolved,
            purpose: .prose,
            messages: [],
            parameters: NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .off
            ),
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        let events = try await adapter.start(request)
        for await _ in events { /* drain until completion */ }

        let transportRequest = try XCTUnwrap(captured.value)
        XCTAssertNil(transportRequest.novelProjectContext, "非 discussion purpose 不得注入项目上下文")
        XCTAssertTrue(
            transportRequest.parameters.tools.map { $0.name }.allSatisfy {
                !IOSNovelProjectToolExecutor.supportedToolNames.contains($0)
            },
            "非 discussion purpose 不得注入小说写工具"
        )
    }

    // MARK: - Helpers

    private func makeModel() -> Model {
        Model(
            modelId: "novel-live",
            displayName: "Novel Live",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 128_000),
            providerOverwrite: nil
        )
    }
}

/// 跨隔离域捕获工具请求的小盒子（测试专用）。
private final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
