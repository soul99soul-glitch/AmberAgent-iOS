import Shared
import XCTest
@testable import iosApp

@MainActor
final class ChatIslandNavigationTests: XCTestCase {
    private let conversationID = "conversation-island"

    func testToolPresentationMapsToItsOwningMessageAnchor() {
        let message = makeToolMessage(toolCallID: "search-call")
        let token = UUID()
        let target = ChatIslandNavigation.target(
            for: .active(state(.tool, toolID: "search-call")),
            conversationID: conversationID,
            messages: [message],
            pendingRequestID: nil,
            requestToken: token
        )

        XCTAssertEqual(target, .anchor(ChatMessageAnchor(
            conversationID: conversationID,
            messageID: ChatMessageProjector.messageId(for: message),
            toolCallID: "search-call",
            requestToken: token
        )))
    }

    func testImagePresentationMapsToItsToolAnchor() {
        let message = makeToolMessage(toolCallID: "image-call", toolName: "generate_image")

        XCTAssertEqual(
            ChatIslandNavigation.target(
                for: .active(state(.image, toolID: "image-call")),
                conversationID: conversationID,
                messages: [message],
                pendingRequestID: nil
            ),
            .anchor(ChatMessageAnchor(
                conversationID: conversationID,
                messageID: ChatMessageProjector.messageId(for: message),
                toolCallID: "image-call"
            ))
        )
    }

    func testTerminalHoldMapsUsingDisplayedFailedTool() {
        let message = makeToolMessage(toolCallID: "failed-call")
        let failedTool = state(.tool, toolID: "failed-call").failedCopy()
        let presentation = ChatIslandPresentation.terminalHold(
            active: failedTool,
            fallback: .conversationTitle("会话"),
            until: 10
        )

        guard case .anchor(let anchor) = ChatIslandNavigation.target(
            for: presentation,
            conversationID: conversationID,
            messages: [message],
            pendingRequestID: nil
        ) else {
            return XCTFail("terminalHold 应按当前显示的失败工具定位")
        }
        XCTAssertEqual(anchor.toolCallID, "failed-call")
        XCTAssertEqual(anchor.messageID, ChatMessageProjector.messageId(for: message))
    }

    func testAwaitingGateRequiresTheRequestThatWasDisplayed() {
        let awaiting = state(.awaitingUser, toolID: "approval-call")

        XCTAssertEqual(
            ChatIslandNavigation.target(
                for: .active(awaiting),
                conversationID: conversationID,
                messages: [],
                pendingRequestID: "approval-call"
            ),
            .pendingGate
        )
        XCTAssertEqual(
            ChatIslandNavigation.target(
                for: .active(awaiting),
                conversationID: conversationID,
                messages: [],
                pendingRequestID: "newer-approval-call"
            ),
            .none
        )
    }

    func testThinkingAndGenerationReturnToBottomWhileTitleDoesNothing() {
        for kind in [ChatActivityIslandState.Kind.waiting, .thinking, .generating] {
            XCTAssertEqual(
                ChatIslandNavigation.target(
                    for: .active(state(kind)),
                    conversationID: conversationID,
                    messages: [],
                    pendingRequestID: nil
                ),
                .bottom
            )
        }

        XCTAssertEqual(
            ChatIslandNavigation.target(
                for: .idle(.conversationTitle("会话")),
                conversationID: conversationID,
                messages: [],
                pendingRequestID: nil
            ),
            .none
        )
    }

    func testMissingToolTargetDoesNothing() {
        XCTAssertEqual(
            ChatIslandNavigation.target(
                for: .active(state(.tool, toolID: "removed-call")),
                conversationID: conversationID,
                messages: [makeToolMessage(toolCallID: "another-call")],
                pendingRequestID: nil
            ),
            .none
        )
    }

    func testToolAnchorPolicyRequiresTheToolInTheAnchoredMessage() {
        let anchor = ChatMessageAnchor(
            conversationID: conversationID,
            messageID: "message-a",
            toolCallID: "tool-a"
        )

        XCTAssertNil(NativeTimelineMessageAnchorPolicy.targetEntryID(
            request: anchor,
            consumed: nil,
            currentConversationID: conversationID,
            availableMessageIDs: ["message-a", "message-b"],
            availableToolCallIDsByMessageID: ["message-b": ["tool-a"]]
        ))
        XCTAssertEqual(NativeTimelineMessageAnchorPolicy.targetEntryID(
            request: anchor,
            consumed: nil,
            currentConversationID: conversationID,
            availableMessageIDs: ["message-a", "message-b"],
            availableToolCallIDsByMessageID: ["message-a": ["tool-a"]]
        ), ChatToolCallAnchorTarget.id(messageID: "message-a", toolCallID: "tool-a"))
    }

    func testRequestTokenAllowsTheSameToolAnchorToBeRequestedAgain() {
        let message = makeToolMessage(toolCallID: "repeat-call")
        let first = ChatIslandNavigation.target(
            for: .active(state(.tool, toolID: "repeat-call")),
            conversationID: conversationID,
            messages: [message],
            pendingRequestID: nil,
            requestToken: UUID()
        )
        let second = ChatIslandNavigation.target(
            for: .active(state(.tool, toolID: "repeat-call")),
            conversationID: conversationID,
            messages: [message],
            pendingRequestID: nil,
            requestToken: UUID()
        )
        guard case .anchor(let firstAnchor) = first,
              case .anchor(let secondAnchor) = second else {
            return XCTFail("工具状态应生成锚点")
        }
        let toolIDsByMessage: [String: Set<String>] = [
            ChatMessageProjector.messageId(for: message): ["repeat-call"]
        ]

        XCTAssertNil(NativeTimelineMessageAnchorPolicy.targetEntryID(
            request: firstAnchor,
            consumed: firstAnchor,
            currentConversationID: conversationID,
            availableMessageIDs: [ChatMessageProjector.messageId(for: message)],
            availableToolCallIDsByMessageID: toolIDsByMessage
        ))
        XCTAssertEqual(NativeTimelineMessageAnchorPolicy.targetEntryID(
            request: secondAnchor,
            consumed: firstAnchor,
            currentConversationID: conversationID,
            availableMessageIDs: [ChatMessageProjector.messageId(for: message)],
            availableToolCallIDsByMessageID: toolIDsByMessage
        ), ChatToolCallAnchorTarget.id(
            messageID: ChatMessageProjector.messageId(for: message),
            toolCallID: "repeat-call"
        ))
    }

    private func state(
        _ kind: ChatActivityIslandState.Kind,
        toolID: String? = nil
    ) -> ChatActivityIslandState {
        .activity(
            kind: kind,
            title: "状态",
            systemImage: "wrench",
            tint: .amber,
            toolID: toolID
        )
    }

    private func makeToolMessage(toolCallID: String, toolName: String = "search_web") -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallID,
                toolName: toolName,
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }
}
