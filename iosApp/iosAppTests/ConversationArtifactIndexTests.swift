import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ConversationArtifactIndexTests: XCTestCase {
    func testIndexesOnlyGeneratedImageResults() {
        let userImage = UIMessagePart.Image(url: "file:///user-upload.png", metadata: nil)
        let user = userMessage(parts: [UIMessagePart.Text(text: "参考这张图", metadata: nil), userImage])
        let generated = toolMessage(
            id: "image-call",
            name: "generate_image",
            input: #"{"prompt":"A quiet garden"}"#,
            output: [UIMessagePart.Image(url: "https://images.example/generated.png", metadata: nil)]
        )

        let index = ConversationArtifactIndex.make(from: [user, generated])

        XCTAssertEqual(index.images.count, 1)
        XCTAssertEqual(index.images[0].url, "https://images.example/generated.png")
        XCTAssertEqual(index.images[0].prompt, "A quiet garden")
        XCTAssertEqual(index.images[0].source.turn, 1)
        XCTAssertEqual(index.images[0].source.toolCallID, "image-call")
        XCTAssertEqual(index.count, 1)
    }

    func testGroupsFileWritesAndEditsAsVersionsWithAvailableContent() {
        let user = userMessage()
        let write = toolMessage(
            id: "write-call",
            name: "workspace_file_write",
            input: #"{"path":"notes.md","content":"alpha"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","size_bytes":5}"#
        )
        let secondWrite = toolMessage(
            id: "write-again",
            name: "workspace_file_write",
            input: #"{"path":"notes.md","content":"alpha\nextra"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","size_bytes":11}"#
        )
        let edit = toolMessage(
            id: "edit-call",
            name: "workspace_file_edit",
            input: #"{"path":"/workspace/notes.md","find":"alpha","replace":"beta"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","changed":true,"replacements":1,"diff_preview":"-alpha\n+beta"}"#
        )

        let index = ConversationArtifactIndex.make(from: [user, write, secondWrite, userMessage(text: "再修改"), edit])

        XCTAssertEqual(index.files.count, 1)
        XCTAssertEqual(index.files[0].path, "notes.md")
        // edit 回执没有完整正文，即便有旧快照也不能猜测执行时的文件内容。
        XCTAssertEqual(index.files[0].versions.map(\.content), ["alpha", "alpha\nextra", nil])
        XCTAssertEqual(index.files[0].versions.map(\.source.toolCallID), ["write-call", "write-again", "edit-call"])
        XCTAssertEqual(index.files[0].versions.map(\.source.turn), [1, 1, 2])
        XCTAssertEqual(index.count, 1, "多版本文件仍算一个产物")
    }

    func testIndexesScrapeAndWebMountPagesFromTheirStructuredResults() {
        let user = userMessage()
        let scrape = toolMessage(
            id: "scrape-call",
            name: "scrape_web",
            input: #"{"url":"https://example.com/article?id=123"}"#,
            outputJSON: #"{"status":"ok","url":"https://example.com/article?id=123","title":"Article","content":"Readable article text"}"#
        )
        let webMount = toolMessage(
            id: "open-call",
            name: "wm_open",
            input: #"{"session_id":"session-1"}"#,
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Mounted page"},"visible_text":"Visible page text"}"#
        )

        let index = ConversationArtifactIndex.make(from: [user, scrape, webMount])

        XCTAssertEqual(index.webPages.map(\.title), ["Article", "Mounted page"])
        XCTAssertEqual(index.webPages.map(\.url), ["https://example.com/article?id=123", "https://example.com/page"])
        XCTAssertEqual(index.webPages.map(\.preview), ["Readable article text", "Visible page text"])
        XCTAssertEqual(index.count, 2)
    }

    func testWebMountSessionCallsDeduplicateByURLAndKeepLatestSource() throws {
        let open = toolMessage(
            id: "call_0",
            name: "wm_open",
            input: "{}",
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Opened"},"visible_text":"Open text"}"#
        )
        let extract = toolMessage(
            id: "call_0",
            name: "wm_extract",
            input: "{}",
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Extracted"},"visible_text":"Latest text"}"#
        )
        let ignoredCalls = ["wm_state", "wm_observe", "wm_back", "wm_forward", "wm_get"].enumerated().map { index, name in
            toolMessage(
                id: "ignored-\(index)",
                name: name,
                input: "{}",
                outputJSON: #"{"ok":true,"page":{"url":"https://example.com/\#(index)","title":"Transient state"}}"#
            )
        }

        let index = ConversationArtifactIndex.make(from: [open, extract] + ignoredCalls)
        let page = try XCTUnwrap(index.webPages.first)

        XCTAssertEqual(index.webPages.count, 1)
        XCTAssertEqual(page.id, "web:https://example.com/page")
        XCTAssertEqual(page.title, "Extracted")
        XCTAssertEqual(page.preview, "Latest text")
        XCTAssertEqual(page.source.toolCallID, "call_0")
        XCTAssertEqual(page.source.messageID, ChatMessageProjector.messageId(for: extract))
    }

    func testWriteContentIsKeptOnlyWhenReceiptByteCountMatches() throws {
        let matching = toolMessage(
            id: "matching-write",
            name: "workspace_file_write",
            input: #"{"path":"matching.txt","content":"café"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/matching.txt","size_bytes":5}"#
        )
        let mismatched = toolMessage(
            id: "mismatched-write",
            name: "workspace_file_write",
            input: #"{"path":"mismatched.txt","content":"same length?"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/mismatched.txt","size_bytes":1}"#
        )
        let missingSize = toolMessage(
            id: "missing-size-write",
            name: "workspace_file_write",
            input: #"{"path":"missing-size.txt","content":"content"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/missing-size.txt"}"#
        )

        let index = ConversationArtifactIndex.make(from: [matching, mismatched, missingSize])

        XCTAssertEqual(index.files.first(where: { $0.path == "matching.txt" })?.versions.first?.content, "café")
        XCTAssertNil(index.files.first(where: { $0.path == "mismatched.txt" })?.versions.first?.content)
        XCTAssertNil(index.files.first(where: { $0.path == "missing-size.txt" })?.versions.first?.content)
    }

    func testReusedToolCallIDInDifferentMessagesKeepsBothArtifacts() {
        let first = toolMessage(
            id: "call_0",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://first", metadata: nil)]
        )
        let second = toolMessage(
            id: "call_0",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://second", metadata: nil)]
        )

        let index = ConversationArtifactIndex.make(from: [first, second])

        XCTAssertEqual(index.images.map(\.url), ["image://first", "image://second"])
        XCTAssertNotEqual(index.images[0].source.messageID, index.images[1].source.messageID)
    }

    func testEditWithoutKnownContentKeepsVersionButDoesNotUseDiffPreviewAsText() {
        let edit = toolMessage(
            id: "edit-without-base",
            name: "workspace_file_edit",
            input: #"{"path":"notes.md","find":"before","replace":"after"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","changed":true,"replacements":1,"diff_preview":"-before\n+after"}"#
        )

        let index = ConversationArtifactIndex.make(from: [userMessage(), edit])

        XCTAssertEqual(index.files.first?.versions.count, 1)
        XCTAssertNil(index.files.first?.versions.first?.content)
        XCTAssertEqual(index.count, 1)
    }

    func testIndexesOnlyMessagesFromTheProvidedCurrentBranch() {
        let branchA = [
            userMessage(text: "分支 A"),
            toolMessage(
                id: "a-call",
                name: "workspace_file_write",
                input: #"{"path":"a.md","content":"A"}"#,
                outputJSON: #"{"ok":true,"path":"/workspace/a.md"}"#
            )
        ]
        let branchB = [
            userMessage(text: "分支 B"),
            toolMessage(
                id: "b-call",
                name: "workspace_file_write",
                input: #"{"path":"b.md","content":"B"}"#,
                outputJSON: #"{"ok":true,"path":"/workspace/b.md"}"#
            )
        ]

        let indexA = ConversationArtifactIndex.make(from: branchA)
        let indexB = ConversationArtifactIndex.make(from: branchB)

        XCTAssertEqual(indexA.files.map(\.path), ["a.md"])
        XCTAssertEqual(indexB.files.map(\.path), ["b.md"])
    }

    func testNoArtifactsAndUnsuccessfulWritesProduceAnEmptyIndex() {
        let messages = [
            userMessage(parts: [UIMessagePart.Image(url: "file:///user.png", metadata: nil)]),
            toolMessage(id: "search-call", name: "search_web", input: "{}", outputJSON: #"{"ok":true}"#),
            toolMessage(
                id: "failed-write",
                name: "workspace_file_write",
                input: #"{"path":"failed.md","content":"no"}"#,
                outputJSON: #"{"ok":false,"error":"denied"}"#
            )
        ]

        let index = ConversationArtifactIndex.make(from: messages)

        XCTAssertTrue(index.images.isEmpty)
        XCTAssertTrue(index.files.isEmpty)
        XCTAssertTrue(index.webPages.isEmpty)
        XCTAssertEqual(index.count, 0)
    }

    func testAnchorRequiresBothMessageAndToolToRemainInCurrentBranch() throws {
        let message = toolMessage(
            id: "anchor-call",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://result", metadata: nil)]
        )
        let source = try XCTUnwrap(ConversationArtifactIndex.make(from: [message]).images.first?.source)

        let anchor = ConversationArtifactIndex.anchor(
            for: source,
            conversationID: "conversation-1",
            messages: [message],
            requestToken: UUID()
        )

        XCTAssertEqual(anchor?.conversationID, "conversation-1")
        XCTAssertEqual(anchor?.messageID, source.messageID)
        XCTAssertEqual(anchor?.toolCallID, source.toolCallID)
        XCTAssertNil(ConversationArtifactIndex.anchor(
            for: .init(messageID: source.messageID, turn: 1, toolCallID: "missing-tool"),
            conversationID: "conversation-1",
            messages: [message]
        ))
        XCTAssertNil(ConversationArtifactIndex.anchor(
            for: .init(messageID: "missing-message", turn: 1, toolCallID: source.toolCallID),
            conversationID: "conversation-1",
            messages: [message]
        ))
    }

    private func userMessage(
        text: String = "hello",
        parts: [UIMessagePart]? = nil
    ) -> UIMessage {
        message(role: MessageRole.user, parts: parts ?? [UIMessagePart.Text(text: text, metadata: nil)])
    }

    private func toolMessage(
        id: String,
        name: String,
        input: String,
        outputJSON: String? = nil,
        output: [UIMessagePart] = []
    ) -> UIMessage {
        let outputParts: [UIMessagePart]
        if let outputJSON {
            outputParts = [UIMessagePart.Text(text: outputJSON, metadata: nil)]
        } else {
            outputParts = output
        }
        return message(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: id,
                toolName: name,
                input: input,
                output: outputParts,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )]
        )
    }

    private func message(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(), role: role, parts: parts,
            annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
            modelId: nil, usage: nil, translation: nil
        )
    }

}
