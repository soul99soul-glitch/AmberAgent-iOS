import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

extension NovelLiveModelAdapterTests {
    func testDiscussionDoesNotRetryAfterAWriteToolWhenTheNextRequestFails() async throws {
        let fixture = makeFixture(apiKey: "test-key")
        let provider = NovelRetryRegressionProvider(failsAfterTool: true)
        let executor = NovelRetryRegressionExecutor()
        let adapter = NovelLiveModelAdapter(
            catalogProvider: { fixture.catalog },
            kmpTransport: { _, _ in nil },
            discussionTransport: NovelLiveModelAdapter.discussionSearchTransport(
                using: provider,
                executors: { _ in ["novel_revise_material": executor] }
            )
        )
        let model = try await adapter.resolveModel(for: .global)

        let events = await Self.collect(try await adapter.start(makeRequest(
            model: model, purpose: .discussion, withProjectContext: true
        )))

        XCTAssertEqual(executor.calls, 1, "A completed mutation must not be replayed after the next request fails.")
        XCTAssertEqual(provider.calls, 2)
        XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
        XCTAssertFalse(events.contains(.completed))
    }

    func testDiscussionStillRetriesAnOpeningFailureBeforeAnyTextOrTool() async throws {
        let fixture = makeFixture(apiKey: "test-key")
        let provider = NovelRetryRegressionProvider(failsAfterTool: false)
        let adapter = NovelLiveModelAdapter(
            catalogProvider: { fixture.catalog },
            kmpTransport: { _, _ in nil },
            discussionTransport: NovelLiveModelAdapter.discussionSearchTransport(
                using: provider, executors: { _ in [:] }
            )
        )
        let model = try await adapter.resolveModel(for: .global)

        let events = await Self.collect(try await adapter.start(makeRequest(model: model, purpose: .discussion)))

        XCTAssertEqual(provider.calls, 2)
        XCTAssertTrue(events.contains(.completed))
    }
}

private final class NovelRetryRegressionExecutor: IOSToolExecutor, @unchecked Sendable {
    private let count = LockedBox(0)
    var calls: Int { count.value }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        count.mutate { $0 += 1 }
        return .filled("Material saved.")
    }
}

private final class NovelRetryRegressionProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let count = LockedBox(0)
    private let failsAfterTool: Bool
    var calls: Int { count.value }

    init(failsAfterTool: Bool) { self.failsAfterTool = failsAfterTool }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        var call = 0
        count.mutate { $0 += 1; call = $0 }
        if !failsAfterTool, call > 1 {
            return NovelLiveModelAdapterTests.deltaChunk("可以继续讨论。")
        }
        if !failsAfterTool || call.isMultiple(of: 2) {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                          userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        }
        let message = UIMessage(
            id: KotlinUuid.companion.random(), role: .assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: "write-\(call)", toolName: "novel_revise_material",
                input: #"{"kind":"setting","title":"城门规则","body":"夜里关闭"}"#,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 10, day: 25,
                                                    hour: 0, minute: 0, second: 0, nanosecond: 0),
            finishedAt: nil, modelId: nil, usage: nil, translation: nil
        )
        return MessageChunk(
            id: UUID().uuidString, model: "novel-test",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "tool_calls")],
            usage: nil
        )
    }
}
