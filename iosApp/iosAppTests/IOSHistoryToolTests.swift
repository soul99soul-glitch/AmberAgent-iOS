import XCTest
@preconcurrency import Shared
@testable import iosApp

/// I2.3：当前会话原始历史检索。需要真实 store（消息持久化后才可回查），
/// 覆盖检索、去重、limit、分页、只读当前会话与参数错误。
@MainActor
final class IOSHistoryToolTests: XCTestCase {

    private var directory: URL!
    private var store: IOSConversationStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tool-\(UUID().uuidString)")
        store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        await store.newConversation()
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testHistorySearchFindsCurrentConversationAndReturnsAnchor() async throws {
        let needle = "original-command-\(UUID().uuidString.prefix(6))"
        let first = UIMessage.companion.user(prompt: "run \(needle) then report")
        let second = UIMessage.companion.assistant(prompt: "done")
        await store.saveCurrent(messages: [first, second])

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let output = await tool.dispatch(makeTool(
            "history_search", #"{"query":"\#(needle)"}"#
        ))
        let payload = try XCTUnwrap(json(output))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["scope"] as? String, "current_conversation")
        XCTAssertEqual(payload["stale_count"] as? Int, 0)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["message_id"] as? String, first.id.toHexDashString())
        XCTAssertEqual(results[0]["stale"] as? Bool, false)
        let anchor = try XCTUnwrap(results[0]["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["message_id"] as? String, first.id.toHexDashString())
        XCTAssertEqual(anchor["conversation_id"] as? String, store.currentConversation?.id.toHexDashString())
    }

    func testHistorySearchDeduplicatesPerMessageAndRespectsLimit() async throws {
        let needle = "repeat-\(UUID().uuidString.prefix(6))"
        let repeated = UIMessage.companion.user(prompt: "\(needle) and \(needle) again")
        let older = UIMessage.companion.user(prompt: "first \(needle)")
        await store.saveCurrent(messages: [older, repeated])

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let output = await tool.dispatch(makeTool(
            "history_search", #"{"query":"\#(needle)","limit":1}"#
        ))
        let payload = try XCTUnwrap(json(output))
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1, "limit=1 只返回一条")
        let all = await tool.dispatch(makeTool(
            "history_search", #"{"query":"\#(needle)","limit":8}"#
        ))
        let allResults = try XCTUnwrap(json(all)?["results"] as? [[String: Any]])
        XCTAssertEqual(allResults.count, 2, "两条消息各一条，重复命中不去重成同一条")
        XCTAssertEqual(Set(allResults.compactMap { $0["message_id"] as? String }).count, 2)
    }

    func testHistorySearchOnlyReadsTheCurrentConversation() async throws {
        let needle = "side-conversation-\(UUID().uuidString.prefix(6))"
        let side = UIMessage.companion.user(prompt: "side \(needle)")
        await store.saveCurrent(messages: [side])
        await store.newConversation()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "main hello")])

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let output = await tool.dispatch(makeTool(
            "history_search", #"{"query":"\#(needle)"}"#
        ))
        let payload = try XCTUnwrap(json(output))
        XCTAssertEqual((payload["results"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(payload["hint"])
    }

    func testHistoryFetchReturnsFullTextAndSource() async throws {
        let text = "line one\nline two \(UUID().uuidString.prefix(6))"
        let message = UIMessage.companion.user(prompt: text)
        await store.saveCurrent(messages: [message])

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let output = await tool.dispatch(makeTool(
            "history_fetch", #"{"message_id":"\#(message.id.toHexDashString())","max_chars":4000}"#
        ))
        let payload = try XCTUnwrap(json(output))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["tool"] as? String, "history_fetch")
        XCTAssertEqual(payload["source"] as? String, "original_transcript")
        XCTAssertEqual(payload["stale"] as? Bool, false)
        XCTAssertEqual(payload["text"] as? String, text)
        XCTAssertTrue(payload["next_offset"] is NSNull)
        let anchor = try XCTUnwrap(payload["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["message_id"] as? String, message.id.toHexDashString())
    }

    func testHistoryFetchRejectsMissingMessageId() async throws {
        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let output = await tool.dispatch(makeTool("history_fetch", "{}"))
        let payload = try XCTUnwrap(json(output))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["tool"] as? String, "history_fetch")
    }

    func testHistoryToolsMarkCompactedMessagesStale() async throws {
        let needle = "compacted-\(UUID().uuidString.prefix(6))"
        let message = UIMessage.companion.user(prompt: "old \(needle)")
        await store.saveCurrent(messages: [message])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let messageId = message.id.toHexDashString()
        let compact = IOSConversationCompact(
            id: "compact-\(UUID().uuidString)",
            conversationId: conversationId.toHexDashString(),
            summary: #"{"schema_version":2,"timeline_summary":"old history","handoff_markdown":"Goal\nOld history.","covered_compact_ids":[]}"#,
            level: 1, sourceStartIndex: 0, sourceEndIndex: 0,
            sourceMessageIds: [messageId],
            tokenEstimate: 10, createdAt: 1, updatedAt: 1, status: "completed",
            timelineAnchorMessageId: messageId
        )
        try IOSContextCompactionCoordinator.shared.insertTestCompact(compact)
        defer {
            try? IOSContextCompactionCoordinator.shared.removeCompacts(
                conversationIds: [conversationId.toHexDashString()]
            )
        }

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let search = await tool.dispatch(makeTool("history_search", #"{"query":"\#(needle)"}"#))
        let searchPayload = try XCTUnwrap(json(search))
        XCTAssertEqual(searchPayload["stale_count"] as? Int, 1)
        let hit = try XCTUnwrap((searchPayload["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["stale"] as? Bool, true)

        let fetch = await tool.dispatch(makeTool("history_fetch", #"{"message_id":"\#(messageId)"}"#))
        let fetchPayload = try XCTUnwrap(json(fetch))
        XCTAssertEqual(fetchPayload["stale"] as? Bool, true)
        XCTAssertTrue((fetchPayload["text"] as? String)?.contains(needle) == true)
    }

    func testHistorySearchAndFetchRedactCredentialsInTextAndToolParts() async throws {
        let rawBearer = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let rawOpenAIKey = "sk-proj-secretKeyMaterial1234567890ABCD"
        let rawProviderKey = "sk-live-providerSecret9876"
        let rawPassword = "superSecretPassword999"
        let rawUrl = "https://user:urlPass123@example.com/callback?access_token=tok_url_secret_999&ok=1"
        let rawPem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        -----END OPENSSH PRIVATE KEY-----
        """
        let userMsg = UIMessage.companion.user(
            prompt: "Save credentials \(rawBearer) and \(rawOpenAIKey) password=\(rawPassword) \(rawUrl)\n\(rawPem)"
        )
        let toolPart = UIMessagePart.Tool(
            toolCallId: "call-provider-cfg",
            toolName: "provider_config_apply",
            input: #"{"provider_name":"OpenAI","api_key":"\#(rawProviderKey)","note":"token: tok_inline_secret_12345"}"#,
            output: [
                UIMessagePart.Text(
                    text: #"{"status":"ok","echo":"Authorization: Bearer secret_bearer_token_abcdef12345"}"#,
                    metadata: nil
                )
            ],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantMsg = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolPart],
            annotations: [],
            createdAt: userMsg.createdAt,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        await store.saveCurrent(messages: [userMsg, assistantMsg])

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let searchOut = await tool.dispatch(makeTool("history_search", #"{"query":"credentials"}"#))
        for leaked in [
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            rawOpenAIKey,
            rawProviderKey,
            rawPassword,
            "urlPass123",
            "tok_url_secret_999",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW"
        ] {
            XCTAssertFalse(searchOut.contains(leaked), "history_search leaked secret: \(leaked) in \(searchOut)")
        }

        let fetchUser = await tool.dispatch(
            makeTool("history_fetch", #"{"message_id":"\#(userMsg.id.toHexDashString())"}"#)
        )
        for leaked in [
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            rawOpenAIKey,
            rawPassword,
            "urlPass123",
            "tok_url_secret_999",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW"
        ] {
            XCTAssertFalse(fetchUser.contains(leaked), "history_fetch(user) leaked secret: \(leaked)")
        }

        let fetchAssistant = await tool.dispatch(
            makeTool("history_fetch", #"{"message_id":"\#(assistantMsg.id.toHexDashString())"}"#)
        )
        for leaked in [
            rawProviderKey,
            "tok_inline_secret_12345",
            "secret_bearer_token_abcdef12345"
        ] {
            XCTAssertFalse(fetchAssistant.contains(leaked), "history_fetch(assistant) leaked secret: \(leaked)")
        }
        XCTAssertTrue(fetchAssistant.contains("****9876"), "provider_config_apply api_key should use redactedArgumentsJSON tail format")
    }

    func testHistoryFetchConversationIdOverrideTakesPrecedenceOverArgs() async throws {
        let firstMsg = UIMessage.companion.user(prompt: "first conversation message")
        await store.saveCurrent(messages: [firstMsg])
        let firstConvId = try XCTUnwrap(store.currentConversation?.id)

        await store.newConversation()
        let secondMsg = UIMessage.companion.user(prompt: "second conversation message")
        await store.saveCurrent(messages: [secondMsg])
        let secondConvId = try XCTUnwrap(store.currentConversation?.id)

        let tool = ChatSessionReadTool(conversationStoreProvider: { self.store })
        let forgedCall = makeTool(
            "history_fetch",
            #"{"conversation_id":"\#(firstConvId.toHexDashString())","message_id":"\#(firstMsg.id.toHexDashString())"}"#
        )
        let output = await tool.dispatch(forgedCall, conversationId: secondConvId)
        let payload = try XCTUnwrap(json(output))
        XCTAssertEqual(payload["ok"] as? Bool, false, "history_fetch must not read another conversation via forged conversation_id arg")
        XCTAssertEqual(payload["error"] as? String, "message_not_found")
    }

    private func makeTool(_ name: String, _ input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "call-\(UUID().uuidString)",
            toolName: name,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
