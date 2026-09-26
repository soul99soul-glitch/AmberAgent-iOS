import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ConversationRecapTests: XCTestCase {
    func testEligibilityRequiresThreeUserMessages() {
        let twoMessages = [
            IOSChatForegroundFixtures.userMessage("one"),
            IOSChatForegroundFixtures.assistantText("reply"),
            IOSChatForegroundFixtures.userMessage("two"),
        ]
        let threeMessages = twoMessages + [IOSChatForegroundFixtures.userMessage("three")]

        XCTAssertFalse(ConversationRecapLogic.eligible(messages: Array(twoMessages.prefix(2))))
        XCTAssertFalse(ConversationRecapLogic.eligible(messages: twoMessages))
        XCTAssertTrue(ConversationRecapLogic.eligible(messages: threeMessages))
    }

    func testNumberedRecentMessagesMapCitationsAndLeaveOutOfRangeReferencesUnlinked() throws {
        let messages = (1...35).map { IOSChatForegroundFixtures.userMessage("message \($0)") }
        let input = try XCTUnwrap(ConversationRecapLogic.makeInput(
            previousRecap: nil,
            messages: messages,
            conversationID: "conversation-a",
            branchID: "main",
            compactSummary: nil
        ))

        XCTAssertFalse(input.prompt.contains("m3 User: message 3"))
        XCTAssertTrue(input.prompt.contains("m4 User: message 4"))
        XCTAssertTrue(input.prompt.contains("m35 User: message 35"))
        XCTAssertNil(input.messageIDsByReference["m3"])
        XCTAssertEqual(input.messageIDsByReference["m4"], ChatMessageProjector.messageId(for: messages[3]))
        XCTAssertEqual(input.messageIDsByReference["m35"], ChatMessageProjector.messageId(for: messages[34]))
        XCTAssertEqual(input.coveredThroughMessageID, ChatMessageProjector.messageId(for: messages[34]))

        let raw = #"{"overview":"summary","nodes":[{"kind":"decision","title":"first","messageRef":"m4"},{"kind":"milestone","title":"last","messageRef":"m35"},{"kind":"failure","title":"outside","messageRef":"m36"}],"nextSteps":[]}"#
        let recap = try ConversationRecapLogic.parse(
            raw,
            messageIDsByReference: input.messageIDsByReference,
            conversationID: "conversation-a",
            coveredThroughMessageID: input.coveredThroughMessageID,
            branchID: input.branchID,
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(recap.nodes[0].messageID, ChatMessageProjector.messageId(for: messages[3]))
        XCTAssertEqual(recap.nodes[1].messageID, ChatMessageProjector.messageId(for: messages[34]))
        XCTAssertNil(recap.nodes[2].messageID)
    }

    func testIncrementalInputCombinesPriorRecapNewMessagesAndCompactSummary() throws {
        let toolMessage = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "search-1",
                toolName: "web_search",
                input: #"{"query":"amber"}"#,
                output: [UIMessagePart.Text(text: "Found the relevant result", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        ])
        let messages = [
            IOSChatForegroundFixtures.userMessage("old question"),
            IOSChatForegroundFixtures.assistantText("old answer"),
            IOSChatForegroundFixtures.userMessage("old follow-up"),
            IOSChatForegroundFixtures.assistantText("old result"),
            IOSChatForegroundFixtures.userMessage("new request"),
            toolMessage,
        ]
        let prior = ConversationRecap(
            overview: "Earlier work",
            nodes: [ConversationRecap.Node(
                kind: .decision,
                title: "Chosen approach",
                messageRef: "m1",
                messageID: ChatMessageProjector.messageId(for: messages[0])
            )],
            nextSteps: ["Check the result"],
            conversationID: "conversation-a",
            coveredThroughMessageID: ChatMessageProjector.messageId(for: messages[3]),
            branchID: "main",
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        let input = try XCTUnwrap(ConversationRecapLogic.makeInput(
            previousRecap: prior,
            messages: messages,
            conversationID: "conversation-a",
            branchID: "main",
            compactSummary: "  Compressed context  "
        ))

        XCTAssertTrue(input.prompt.contains("<context_summary>\nCompressed context\n</context_summary>"))
        XCTAssertTrue(input.prompt.contains("<previous_recap>"))
        XCTAssertTrue(input.prompt.contains("Overview: Earlier work"))
        XCTAssertTrue(input.prompt.contains("[decision] Chosen approach (m1)"))
        XCTAssertTrue(input.prompt.contains("Check the result"))
        XCTAssertTrue(input.prompt.contains("m5 User: new request"))
        XCTAssertTrue(input.prompt.contains("Tool: web_search"))
        XCTAssertTrue(input.prompt.contains(#"Input: {"query":"amber"}"#))
        XCTAssertTrue(input.prompt.contains("Output: Found the relevant result"))
        XCTAssertFalse(input.prompt.contains("m1 User: old question"))
        XCTAssertFalse(input.prompt.contains("m4 Assistant: old result"))
        XCTAssertEqual(input.messageIDsByReference["m1"], ChatMessageProjector.messageId(for: messages[0]))
        XCTAssertEqual(input.messageIDsByReference["m6"], ChatMessageProjector.messageId(for: messages[5]))
        XCTAssertEqual(input.coveredThroughMessageID, ChatMessageProjector.messageId(for: messages[5]))
    }

    func testBranchChangeKeepsPriorContextWithoutReusingItsMessageReferences() throws {
        let messages = [
            IOSChatForegroundFixtures.userMessage("new branch question"),
            IOSChatForegroundFixtures.assistantText("new branch reply"),
            IOSChatForegroundFixtures.userMessage("shared earlier question"),
            IOSChatForegroundFixtures.assistantText("shared earlier answer"),
            IOSChatForegroundFixtures.userMessage("new branch follow-up"),
        ]
        let sharedMessageID = ChatMessageProjector.messageId(for: messages[2])
        let prior = ConversationRecap(
            overview: "Earlier branch context",
            nodes: [
                ConversationRecap.Node(
                    kind: .decision,
                    title: "Still present in this branch",
                    messageRef: "m1",
                    messageID: sharedMessageID
                ),
                ConversationRecap.Node(
                    kind: .failure,
                    title: "Removed with the old branch",
                    messageRef: "m2",
                    messageID: "removed-message"
                ),
            ],
            nextSteps: [],
            conversationID: "conversation-a",
            coveredThroughMessageID: "old-branch-tail",
            branchID: "old-branch",
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        let input = try XCTUnwrap(ConversationRecapLogic.makeInput(
            previousRecap: prior,
            messages: messages,
            conversationID: "conversation-a",
            branchID: "new-branch",
            compactSummary: nil
        ))

        XCTAssertTrue(input.prompt.contains("Earlier branch context"))
        XCTAssertTrue(input.prompt.contains("Still present in this branch (m3)"))
        XCTAssertFalse(input.prompt.contains("Still present in this branch (m1)"))
        XCTAssertFalse(input.prompt.contains("Removed with the old branch (m2)"))
        XCTAssertTrue(input.prompt.contains("m1 User: new branch question"))
        XCTAssertTrue(input.prompt.contains("m5 User: new branch follow-up"))
        XCTAssertEqual(input.messageIDsByReference["m1"], ChatMessageProjector.messageId(for: messages[0]))
        XCTAssertEqual(input.messageIDsByReference["m3"], sharedMessageID)
        XCTAssertFalse(input.messageIDsByReference.values.contains("removed-message"))
    }

    func testRecapIsStaleAfterAppendBranchChangeOrMissingCoverage() {
        let messages = [
            IOSChatForegroundFixtures.userMessage("question"),
            IOSChatForegroundFixtures.assistantText("answer"),
        ]
        let recap = ConversationRecap(
            overview: "Done",
            nodes: [],
            nextSteps: [],
            conversationID: "conversation-a",
            coveredThroughMessageID: ChatMessageProjector.messageId(for: messages[1]),
            branchID: "branch-a",
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertFalse(ConversationRecapLogic.isStale(recap: recap, messages: messages, branchID: "branch-a"))
        XCTAssertTrue(ConversationRecapLogic.isStale(
            recap: recap,
            messages: messages + [IOSChatForegroundFixtures.userMessage("new message")],
            branchID: "branch-a"
        ))
        XCTAssertTrue(ConversationRecapLogic.isStale(recap: recap, messages: messages, branchID: "branch-b"))

        let missingCoverage = ConversationRecap(
            overview: recap.overview,
            nodes: recap.nodes,
            nextSteps: recap.nextSteps,
            conversationID: recap.conversationID,
            coveredThroughMessageID: "missing-message",
            branchID: recap.branchID,
            generatedAt: recap.generatedAt
        )
        XCTAssertTrue(ConversationRecapLogic.isStale(
            recap: missingCoverage,
            messages: messages,
            branchID: "branch-a"
        ))
    }

    func testParserReportsInvalidJSONAndIncompleteContent() {
        XCTAssertThrowsError(try ConversationRecapLogic.parse(
            "not JSON",
            messageIDsByReference: [:],
            conversationID: "conversation-a",
            coveredThroughMessageID: "message-1",
            branchID: "main"
        )) { error in
            XCTAssertEqual(error as? ConversationRecapLogic.ParseError, .invalidJSON)
        }

        XCTAssertThrowsError(try ConversationRecapLogic.parse(
            #"{"overview":"","nodes":[],"nextSteps":[]}"#,
            messageIDsByReference: [:],
            conversationID: "conversation-a",
            coveredThroughMessageID: "message-1",
            branchID: "main"
        )) { error in
            XCTAssertEqual(error as? ConversationRecapLogic.ParseError, .invalidContent)
        }
    }

    func testParserAcceptsWrappedJSONAndDropsUnknownNodeKinds() throws {
        let json = try recapJSON(nodes: [
            ["kind": "unknown", "title": "Ignore", "messageRef": "m1"],
            ["kind": "failure", "title": "Keep this node", "messageRef": "m2"],
        ])
        let recap = try ConversationRecapLogic.parse(
            "Here is the recap:\n```json\n\(json)\n```\nHope this helps.",
            messageIDsByReference: ["m2": "message-2"],
            conversationID: "conversation-a",
            coveredThroughMessageID: "message-3",
            branchID: "main"
        )

        XCTAssertEqual(recap.nodes.count, 1)
        XCTAssertEqual(recap.nodes[0].kind, .failure)
        XCTAssertEqual(recap.nodes[0].messageID, "message-2")
    }

    func testParserAcceptsTwoNodesAndKeepsOnlyFirstEightOfNine() throws {
        let twoNodeRecap = try ConversationRecapLogic.parse(
            recapJSON(nodes: (0..<2).map(recapNode)),
            messageIDsByReference: [:],
            conversationID: "conversation-a",
            coveredThroughMessageID: "message-1",
            branchID: "main"
        )
        XCTAssertEqual(twoNodeRecap.nodes.count, 2)

        var nineNodes = (0..<9).map(recapNode)
        nineNodes[8]["title"] = ""
        let nineNodeRecap = try ConversationRecapLogic.parse(
            recapJSON(nodes: nineNodes),
            messageIDsByReference: [:],
            conversationID: "conversation-a",
            coveredThroughMessageID: "message-1",
            branchID: "main"
        )
        XCTAssertEqual(nineNodeRecap.nodes.count, 8)
        XCTAssertEqual(nineNodeRecap.nodes.last?.title, "Node 7")
    }

    func testTranscriptBoundsMessageBodyAndToolFields() throws {
        let longMessage = IOSChatForegroundFixtures.userMessage(String(repeating: "x", count: 1_800))
        let longInput = String(repeating: "i", count: 400)
        let longOutput = String(repeating: "o", count: 400)
        let toolMessage = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "bounded-tool",
                toolName: "workspace_file_write",
                input: longInput,
                output: [UIMessagePart.Text(text: longOutput, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        ])
        let input = try XCTUnwrap(ConversationRecapLogic.makeInput(
            previousRecap: nil,
            messages: [longMessage, toolMessage],
            conversationID: "conversation-a",
            branchID: "main",
            compactSummary: nil
        ))

        XCTAssertTrue(input.prompt.contains(String(repeating: "x", count: 1_500)))
        XCTAssertFalse(input.prompt.contains(String(repeating: "x", count: 1_501)))
        XCTAssertTrue(input.prompt.contains("Input: \(String(repeating: "i", count: 300))"))
        XCTAssertFalse(input.prompt.contains(String(repeating: "i", count: 301)))
        XCTAssertTrue(input.prompt.contains("Output: \(String(repeating: "o", count: 300))"))
        XCTAssertFalse(input.prompt.contains(String(repeating: "o", count: 301)))
    }

    func testIncrementalTranscriptAlsoKeepsOnlyTheRecentMessageLimit() throws {
        let messages = [IOSChatForegroundFixtures.userMessage("covered")]
            + (0..<40).map { IOSChatForegroundFixtures.userMessage("new \($0)") }
        let prior = ConversationRecap(
            overview: "Previous recap",
            nodes: [],
            nextSteps: [],
            conversationID: "conversation-a",
            coveredThroughMessageID: ChatMessageProjector.messageId(for: messages[0]),
            branchID: "main",
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        let input = try XCTUnwrap(ConversationRecapLogic.makeInput(
            previousRecap: prior,
            messages: messages,
            conversationID: "conversation-a",
            branchID: "main",
            compactSummary: nil
        ))

        XCTAssertFalse(input.prompt.contains("m9 User: new 7"))
        XCTAssertTrue(input.prompt.contains("m10 User: new 8"))
        XCTAssertTrue(input.prompt.contains("m41 User: new 39"))
        XCTAssertNil(input.messageIDsByReference["m9"])
        XCTAssertNotNil(input.messageIDsByReference["m10"])
    }

    private func recapJSON(nodes: [[String: String]]) throws -> String {
        let object: [String: Any] = ["overview": "Recap overview", "nodes": nodes, "nextSteps": []]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func recapNode(_ index: Int) -> [String: String] {
        let kinds = ["decision", "milestone", "failure", "artifact"]
        return [
            "kind": kinds[index % kinds.count],
            "title": "Node \(index)",
            "messageRef": "m\(index + 1)",
        ]
    }
}
