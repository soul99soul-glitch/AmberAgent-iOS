import XCTest
@testable import AmberMac

@MainActor final class DesktopWorkspaceContextTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var requests: [[DesktopMessage]] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            requests.append(messages)
            let run = DesktopGeneration()
            runs.append(run)
            return run
        }
    }

    private func settings(window: Int? = nil) throws -> DesktopSettings {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.context.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials())
        var config = try XCTUnwrap(settings.selectedProvider)
        var model = DesktopModelConfiguration(modelID: "context-model")
        model.contextWindowTokens = window
        config.models = [model]
        config.selectedModelID = model.id
        try settings.saveProvider(config, apiKey: "test-key")
        return settings
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amber-context-" + UUID().uuidString)
    }

    private func workspace(_ settings: DesktopSettings, conversation: DesktopConversation,
        provider: Provider, knowledge: DesktopKnowledgeStore? = nil) -> DesktopWorkspace {
        DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider, initialConversations: [conversation], knowledge: knowledge)
    }

    private func waitForRequest(_ provider: Provider, count: Int) async throws -> [DesktopMessage] {
        let deadline = Date().addingTimeInterval(2)
        while provider.requests.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(provider.requests.last)
    }

    private func filler(_ tokens: Int) -> String { String(repeating: "a", count: tokens * 4) }

    /// Recalled memories change with the user's wording, so they must not enter the cached system prefix.
    func testRecalledMemoryIsSentBeforeTheNewestUserTurnInsteadOfInsideTheSystemPrefix() async throws {
        let settings = try settings()
        settings.systemPrompt = "始终使用中文。"
        let knowledgeDirectory = temporary()
        defer { try? FileManager.default.removeItem(at: knowledgeDirectory) }
        let knowledge = DesktopKnowledgeStore(directory: knowledgeDirectory)
        _ = try knowledge.saveMemory(DesktopMemoryRecord(content: "用户每天喝拿铁咖啡。"))

        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: "咖啡偏好"),
            DesktopMessage(role: .assistant, text: "记住了")
        ])
        let provider = Provider()
        let workspace = workspace(settings, conversation: conversation, provider: provider, knowledge: knowledge)

        workspace.draft = "再想想咖啡的事"
        workspace.send()
        let first = try await waitForRequest(provider, count: 1)

        let system = try XCTUnwrap(first.first)
        XCTAssertEqual(system.role, .system)
        XCTAssertTrue(system.text.contains("始终使用中文。"))
        XCTAssertFalse(system.text.contains("memory-context"), "recall must not enter the turn-invariant prefix")

        let lastUser = try XCTUnwrap(first.lastIndex(where: { $0.role == .user }))
        XCTAssertEqual(lastUser, first.count - 1)
        XCTAssertEqual(first[lastUser].text, "再想想咖啡的事")
        // Recall travels as a user turn: on the Claude path a `.system` recall would be flattened into the
        // top-level system prompt and rewrite the cached prefix.
        let recall = first[lastUser - 1]
        XCTAssertEqual(recall.role, .user)
        XCTAssertTrue(recall.text.contains("memory-context"))
        XCTAssertTrue(recall.text.contains("拿铁"))

        // A second turn with unrelated wording keeps the system prefix byte-identical.
        provider.runs[0].yield(.snapshot(text: "好的", reasoning: ""))
        provider.runs[0].yield(.complete)
        _ = await workspace.flush()
        workspace.draft = "今天下雨吗"
        workspace.send()
        let second = try await waitForRequest(provider, count: 2)
        XCTAssertEqual(try XCTUnwrap(second.first).text, system.text)
        XCTAssertFalse(second[second.count - 2].text.contains("拿铁"))
        workspace.stop()
        _ = await workspace.flush()
    }

    /// M2.3: the cache flag is opt-in, survives the settings round trip, and is off for an older record.
    func testPromptCachingFlagIsOptInAndPersists() throws {
        let settings = try settings()
        XCTAssertFalse(try XCTUnwrap(settings.selectedProvider).promptCaching)
        var config = try XCTUnwrap(settings.selectedProvider)
        config.kind = .claude
        config.baseURL = "https://api.anthropic.com/v1"
        config.promptCaching = true
        try settings.saveProvider(config, apiKey: "test-key")
        XCTAssertTrue(try XCTUnwrap(settings.selectedProvider).promptCaching)
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old","kind":"claude","baseURL":"https://api.anthropic.com/v1","models":[{"id":"\#(UUID().uuidString)","modelID":"claude-sonnet-4","enabled":true}],"authMode":"apiKey","modelID":"claude-sonnet-4"}"#
        let decoded = try DesktopJSON.decode(DesktopProviderConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.promptCaching, "older records default to no cache writes")
    }

    func testOverBudgetRequestsDropOldestTurnsAtUserBoundariesAndExplainTheTrim() async throws {
        let settings = try settings(window: 6_000)
        settings.systemPrompt = "始终使用中文。"
        let call = DesktopToolCall(id: "tool-1", name: "shell", status: .complete)
        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: filler(4_000)),
            DesktopMessage(role: .assistant, text: filler(4_000)),
            DesktopMessage(role: .user, text: "运行命令"),
            DesktopMessage(role: .assistant, text: "", tools: [call]),
            DesktopMessage(role: .tool, text: "done"),
            DesktopMessage(role: .assistant, text: "已完成")
        ])
        let provider = Provider()
        let workspace = workspace(settings, conversation: conversation, provider: provider)

        workspace.draft = "继续"
        workspace.send()
        let request = try await waitForRequest(provider, count: 1)

        XCTAssertEqual(request.first?.role, .system, "the system prefix survives trimming")
        XCTAssertTrue(request[0].text.contains("始终使用中文。"))
        XCTAssertEqual(request[1].role, .user, "trimming starts on a user turn right after the prefix")
        XCTAssertTrue(request.contains(where: { $0.role == .tool }))
        for (index, message) in request.enumerated() where message.role == .tool {
            XCTAssertEqual(request[index - 1].role, .assistant)
            XCTAssertFalse(request[index - 1].tools.isEmpty, "a tool result never loses its call")
        }
        let notice = try XCTUnwrap(workspace.contextNotices[conversation.id])
        XCTAssertTrue(notice.contains("省略最早的 2 条消息"))
        // The stored transcript only gains this turn (user + reply placeholder); trimming is request-only.
        XCTAssertEqual(workspace.selectedConversation?.messages.count, conversation.messages.count + 2)
        workspace.stop()
        _ = await workspace.flush()
    }

    /// M1: once a summary covers the early turns, the same stored history must not trigger another full
    /// summary on every finished turn; only new pressure past the covered boundary does.
    func testAutoCompactionDoesNotRepeatWhileCoverageIsUnchanged() async throws {
        let settings = try settings(window: 4_000)
        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: filler(3_000)),
            DesktopMessage(role: .assistant, text: filler(1_000)),
            DesktopMessage(role: .user, text: "第二问"),
            DesktopMessage(role: .assistant, text: "第二答"),
            DesktopMessage(role: .user, text: "第三问"),
            DesktopMessage(role: .assistant, text: "第三答")
        ])
        let provider = Provider()
        let workspace = workspace(settings, conversation: conversation, provider: provider)

        workspace.draft = "继续"
        workspace.send()
        provider.runs[0].yield(.snapshot(text: "回复", reasoning: ""))
        provider.runs[0].yield(.complete)
        _ = try await waitForRequest(provider, count: 2)
        provider.runs[1].yield(.snapshot(text: "目标与已确认事实。", reasoning: ""))
        provider.runs[1].yield(.complete)
        let owner = try XCTUnwrap(workspace.selectedConversation)
        await workspace.insights.waitUntilIdle(owner.id)
        XCTAssertNotNil(workspace.insights.value(.compact, for: owner))

        // One more completed turn on the same (now covered) history must not summarise again.
        workspace.draft = "再继续"
        workspace.send()
        provider.runs[2].yield(.snapshot(text: "好的", reasoning: ""))
        provider.runs[2].yield(.complete)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(provider.requests.count, 3, "chat, one compaction, one chat — no second summary")
        _ = await workspace.flush()
    }

    /// S4: a stopped or failed turn leaves a history a summary should not bake in, so it never triggers one.
    func testStoppedTurnDoesNotTriggerAutomaticCompaction() async throws {
        let settings = try settings(window: 4_000)
        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: filler(3_000)),
            DesktopMessage(role: .assistant, text: filler(1_000)),
            DesktopMessage(role: .user, text: "第二问"),
            DesktopMessage(role: .assistant, text: "第二答"),
            DesktopMessage(role: .user, text: "第三问"),
            DesktopMessage(role: .assistant, text: "第三答")
        ])
        let provider = Provider()
        let workspace = workspace(settings, conversation: conversation, provider: provider)

        workspace.draft = "继续"
        workspace.send()
        provider.runs[0].yield(.snapshot(text: "半截回复", reasoning: ""))
        workspace.stop()
        _ = await workspace.flush()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(provider.requests.count, 1, "only the chat request; a stopped turn does not compact")
        XCTAssertNil(workspace.insights.value(.compact, for: try XCTUnwrap(workspace.selectedConversation)))
    }

    func testNearWindowTurnsCompactAutomaticallyAfterTheTurnEnds() async throws {
        let settings = try settings(window: 4_000)
        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: filler(3_000)),
            DesktopMessage(role: .assistant, text: filler(1_000)),
            DesktopMessage(role: .user, text: "第二问"),
            DesktopMessage(role: .assistant, text: "第二答"),
            DesktopMessage(role: .user, text: "第三问"),
            DesktopMessage(role: .assistant, text: "第三答")
        ])
        let provider = Provider()
        let workspace = workspace(settings, conversation: conversation, provider: provider)

        workspace.draft = "继续"
        workspace.send()
        let chat = try XCTUnwrap(provider.runs.first)
        chat.yield(.snapshot(text: "回复", reasoning: ""))
        chat.yield(.complete)

        let compactionRequest = try await waitForRequest(provider, count: 2)
        XCTAssertEqual(compactionRequest.first?.role, .system)
        XCTAssertEqual(provider.runs.count, 2)
        XCTAssertGreaterThan(compactionRequest.count, 1, "the summary request carries the folded prefix")

        provider.runs[1].yield(.snapshot(text: "目标与已确认事实。", reasoning: ""))
        provider.runs[1].yield(.complete)
        let owner = try XCTUnwrap(workspace.selectedConversation)
        await workspace.insights.waitUntilIdle(owner.id)
        let compact = try XCTUnwrap(workspace.insights.value(.compact, for: owner))
        XCTAssertEqual(compact.sourceMessageIDs.count, 4, "the summary folds everything before the last two turns")
        XCTAssertEqual(workspace.selectedConversation?.messages.count, conversation.messages.count + 2,
                       "automatic compaction never rewrites the stored transcript")
        _ = await workspace.flush()
    }
}
