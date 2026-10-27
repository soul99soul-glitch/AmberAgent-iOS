import XCTest
@testable import AmberMac

@MainActor final class DesktopConversationInsightsTests: XCTestCase {
    private final class CurrentBranch { var valid = true }
    private final class Provider: DesktopTextProvider {
        var requests: [[DesktopMessage]] = []
        var runs: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            requests.append(messages)
            let run = DesktopGeneration()
            runs.append(run)
            return run
        }
    }

    private let configuration = DesktopProviderConfiguration(name: "Test", kind: .openAI,
        baseURL: "http://localhost:8080/v1", modelID: "test-model")

    private func conversation() -> DesktopConversation {
        DesktopConversation(messages: (0..<8).map {
            DesktopMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: "第\($0)条原始内容。" + String(repeating: "保留目标约束与已确认的关键事实。", count: 20))
        })
    }

    private func waitForRun(_ provider: Provider, count: Int = 1) async throws -> DesktopGeneration {
        let deadline = Date().addingTimeInterval(2)
        while provider.runs.count < count, Date() < deadline { await Task.yield() }
        return try XCTUnwrap(provider.runs.last)
    }

    func testCompactionRetainsRecentTurnsAndDoesNotChangeStoredTranscript() async throws {
        let controller = DesktopConversationInsights()
        let provider = Provider()
        let original = conversation()
        controller.generate(.compact, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { $0 == original.messages.map(\.id) })
        let run = try await waitForRun(provider)
        XCTAssertEqual(provider.requests[0].dropFirst().map(\.id), original.messages.prefix(4).map(\.id))
        run.yield(.snapshot(text: "目标与已确认事实。", reasoning: ""))
        run.yield(.complete)
        await controller.waitUntilIdle(original.id)
        let prepared = controller.prepare(messages: original.messages, conversationID: original.id)
        XCTAssertEqual(prepared.first?.role, .system)
        XCTAssertTrue(prepared.first?.text.contains("目标与已确认事实") == true)
        XCTAssertEqual(prepared.dropFirst().map(\.id), original.messages.suffix(4).map(\.id))
        XCTAssertEqual(original.messages.count, 8)
        var otherBranch = original
        otherBranch.messages[0].id = UUID()
        XCTAssertNil(controller.value(.compact, for: otherBranch))
        XCTAssertEqual(controller.prepare(messages: otherBranch.messages, conversationID: original.id), otherBranch.messages)
        let prior = controller.value(.compact, for: original)
        controller.generate(.compact, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let oversized = try await waitForRun(provider, count: 2)
        oversized.yield(.snapshot(text: String(repeating: "冗长重复内容。", count: 1000), reasoning: ""))
        oversized.yield(.complete)
        await controller.waitUntilIdle(original.id)
        XCTAssertEqual(controller.value(.compact, for: original), prior)
        XCTAssertTrue(controller.errors[original.id]?.contains("没有减少") == true)
        controller.clearCompaction(original.id)
        await controller.waitUntilIdle(original.id)
        XCTAssertNil(controller.value(.compact, for: original))
        XCTAssertEqual(controller.prepare(messages: original.messages, conversationID: original.id), original.messages)
    }

    func testChangedBranchRejectsRecapResultAndLeavesOriginalMessagesAlone() async throws {
        let controller = DesktopConversationInsights()
        let provider = Provider()
        let original = conversation()
        let current = CurrentBranch()
        controller.generate(.recap, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in current.valid })
        let run = try await waitForRun(provider)
        current.valid = false
        run.yield(.snapshot(text: "旧分支的回顾", reasoning: ""))
        run.yield(.complete)
        await controller.waitUntilIdle(original.id)
        XCTAssertNil(controller.value(.recap, for: original))
        XCTAssertTrue(controller.errors[original.id]?.contains("分支已更改") == true)
        XCTAssertFalse(controller.activeOwners.contains(original.id))
    }

    func testSuggestionsRequireStructuredResponseAndPreserveOwner() async throws {
        let controller = DesktopConversationInsights()
        let provider = Provider()
        let original = conversation()
        controller.generate(.suggestions, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let first = try await waitForRun(provider)
        first.yield(.snapshot(text: "not JSON", reasoning: "")); first.yield(.complete)
        await controller.waitUntilIdle(original.id)
        XCTAssertNil(controller.value(.suggestions, for: original))
        XCTAssertNotNil(controller.errors[original.id])
        controller.generate(.suggestions, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let second = try await waitForRun(provider, count: 2)
        second.yield(.snapshot(text: "[\" 继续梳理约束 \",\"\",\"核对下一步\"]", reasoning: "")); second.yield(.complete)
        await controller.waitUntilIdle(original.id)
        XCTAssertEqual(controller.value(.suggestions, for: original)?.suggestions, ["继续梳理约束", "核对下一步"])
        XCTAssertNil(controller.errors[original.id])
    }

    func testPersistedRecapReopensAndDeletionRejectsLateGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DesktopConversationInsights(directory: directory)
        let provider = Provider()
        let original = conversation()
        controller.generate(.recap, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let first = try await waitForRun(provider)
        first.yield(.snapshot(text: "持久化回顾", reasoning: "")); first.yield(.complete)
        await controller.waitUntilIdle(original.id)
        let restored = DesktopConversationInsights(directory: directory)
        restored.load(original.id)
        await restored.waitUntilIdle(original.id)
        XCTAssertEqual(restored.value(.recap, for: original)?.text, "持久化回顾")
        controller.generate(.recap, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let late = try await waitForRun(provider, count: 2)
        controller.remove(original.id)
        late.yield(.snapshot(text: "不能复活的内容", reasoning: "")); late.yield(.complete)
        await controller.flush()
        XCTAssertNil(controller.value(.recap, for: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.id.uuidString + ".json").path))
    }

    func testFailedSidecarWriteDoesNotPublishSuccessfulResult() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = DesktopConversationInsights(directory: file)
        let provider = Provider()
        let original = conversation()
        controller.generate(.recap, conversation: original, configuration: configuration,
            apiKey: "test", provider: provider, isCurrent: { _ in true })
        let run = try await waitForRun(provider)
        run.yield(.snapshot(text: "不能静默成功", reasoning: "")); run.yield(.complete)
        await controller.waitUntilIdle(original.id)
        XCTAssertNil(controller.value(.recap, for: original))
        XCTAssertNotNil(controller.errors[original.id])
    }

    func testEstimateUsesFullMessageProjectionWhenAvailableAndCJKFallbackOtherwise() {
        let text = DesktopMessage(role: .user, text: "中文abcd")
        let rich = DesktopMessage(role: .assistant, text: "", estimatedTokens: 1600)
        XCTAssertEqual(DesktopConversationInsights.estimatedTokens([text]), 7)
        XCTAssertEqual(DesktopConversationInsights.estimatedTokens([rich]), 1604)
    }
}
