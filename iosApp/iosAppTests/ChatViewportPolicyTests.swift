import XCTest
@testable import iosApp

final class ChatViewportPolicyTests: XCTestCase {

    func testTurnStageUsesOnlyRemainingViewportAndReleasesBottomPinDuringPush() {
        XCTAssertEqual(ChatTurnStagePolicy.floorHeight(anchorTopY: 0, visibleHeight: 780, topClearance: 42), 716)
        XCTAssertEqual(ChatTurnStagePolicy.floorHeight(anchorTopY: 0, visibleHeight: 40, topClearance: 42), 0)
        let open = ChatTurnStagePolicy.floorHeight(anchorTopY: 2200, visibleHeight: 500, topClearance: 42)
        let closed = ChatTurnStagePolicy.floorHeight(anchorTopY: 2200, visibleHeight: 780, topClearance: 42)
        XCTAssertEqual(closed - open, 280)
        XCTAssertEqual(ChatTurnStagePolicy.provisionalAnchorTop(naturalStackHeight: 0), 0)
        XCTAssertEqual(ChatTurnStagePolicy.provisionalAnchorTop(naturalStackHeight: 500), 488)

        var viewport = ChatViewportState()
        viewport.isAtBottom = true
        XCTAssertFalse(NativeChatTimelineView.shouldPinBottomOnSizeChanges(
            followGeneration: true, viewportState: viewport, driverPausedForUser: false, turnStagePushing: true))
    }

    @MainActor
    func testOnlyANewArmedIdleNativeSendActivatesTheStage() {
        func activates(_ event: ChatEvent = .userMessageAppended, id: String? = "new", anchor: String? = "old",
                       armed: Bool = true, generating: Bool = false, native: Bool = true) -> Bool {
            ChatTurnStagePolicy.shouldActivate(event: event, lastUserMessageID: id, currentAnchorID: anchor,
                                              wasArmed: armed, isGenerationActive: generating, nativeDriverActive: native)
        }
        XCTAssertTrue(activates())
        XCTAssertFalse(activates(.assistantStreamDelta))
        XCTAssertFalse(activates(id: nil))
        XCTAssertFalse(activates(anchor: "new"))
        XCTAssertFalse(activates(armed: false))
        XCTAssertFalse(activates(generating: true))
        XCTAssertFalse(activates(native: false))
        XCTAssertTrue(ChatTurnStagePolicy.resets(on: .conversationLoaded))
        XCTAssertTrue(ChatTurnStagePolicy.resets(on: .conversationSwitched))
        XCTAssertTrue(ChatTurnStagePolicy.resets(on: .branchChanged))
        XCTAssertFalse(ChatTurnStagePolicy.resets(on: .generationCompleted))

        let key = UUID().uuidString
        ChatUserSendEntranceGate.arm(key, at: 10)
        XCTAssertNotNil(ChatUserSendEntranceGate.claimOrResume(key, at: 10))
        XCTAssertTrue(ChatUserSendEntranceGate.wasArmedRecently(key, at: 10.1))
        XCTAssertFalse(ChatUserSendEntranceGate.wasArmedRecently(key, at: 12))
    }

    func testSwiftUIStreamingTailSuspendsOnlyAfterTailIsConfirmedOffscreen() {
        let messageID = "tail"

        XCTAssertFalse(
            ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: true,
                hasEverStreamed: true,
                messageID: messageID,
                visibility: .init()
            ),
            "未知可见性必须保守保持 live，不能把可能已在屏内的长尾行降级。"
        )
        XCTAssertFalse(
            ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: true,
                hasEverStreamed: true,
                messageID: messageID,
                visibility: .init(messageID: messageID, isVisible: true)
            )
        )
        XCTAssertTrue(
            ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: true,
                hasEverStreamed: true,
                messageID: messageID,
                visibility: .init(messageID: messageID, isVisible: false)
            ),
            "曾流式的尾行确认离屏后保持冻结，tool/terminal 不能唤醒全文渲染。"
        )
        XCTAssertFalse(
            ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: true,
                hasEverStreamed: false,
                messageID: messageID,
                visibility: .init(messageID: messageID, isVisible: false)
            ),
            "从未流式过的普通尾行不能进入流式 LOD。"
        )
        XCTAssertFalse(
            ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: false,
                hasEverStreamed: true,
                messageID: messageID,
                visibility: .init(messageID: messageID, isVisible: false)
            ),
            "新消息追加后，旧 assistant 不能继续沿用过期的尾行可见性冻结。"
        )
    }

    func testNativeStreamingTailUpdatesVisibleLongTailAwayFromBottomOnly() {
        let messageID = "tail"

        XCTAssertTrue(
            NativeTimelineStreamingTailUpdatePolicy.shouldUpdate(
                messageID: messageID,
                isFarFromBottom: true,
                visibility: .init(messageID: messageID, isVisible: true)
            )
        )
        XCTAssertFalse(
            NativeTimelineStreamingTailUpdatePolicy.shouldUpdate(
                messageID: messageID,
                isFarFromBottom: true,
                visibility: .init(messageID: messageID, isVisible: false)
            )
        )
        XCTAssertFalse(
            NativeTimelineStreamingTailUpdatePolicy.shouldUpdate(
                messageID: messageID,
                isFarFromBottom: true,
                visibility: .init(messageID: "other", isVisible: true)
            )
        )
        XCTAssertTrue(
            NativeTimelineStreamingTailUpdatePolicy.shouldUpdate(
                messageID: messageID,
                isFarFromBottom: false,
                visibility: .init(messageID: messageID, isVisible: false)
            ),
            "回到底部附近沿用原有 live-tail 更新路径。"
        )
    }

    func testLegacyStreamFinishMapsToStreamClosedEvent() {
        XCTAssertEqual(ChatMessageUpdateReason.streamFinish.event, .assistantStreamClosed)
    }

    func testAssistantStreamClosedIsNotTerminalGenerationComplete() {
        XCTAssertEqual(ChatEvent.assistantStreamClosed.contract.payload, .stream)
        XCTAssertEqual(ChatEvent.generationCompleted.contract.payload, .generation)
        XCTAssertTrue(ChatEvent.assistantStreamClosed.contract.affectsViewport)
        XCTAssertTrue(ChatEvent.generationCompleted.contract.affectsViewport)
    }

    func testComposerFocusFollowsBottomOnlyWhenTimelineIsAtBottomAndNotPaused() {
        var state = ChatViewportState()
        state.isAtBottom = true
        state.followPaused = false
        XCTAssertTrue(ChatView.shouldFollowBottomOnComposerFocus(viewportState: state))
        XCTAssertTrue(
            NativeChatTimelineView.shouldPinBottomOnSizeChanges(
                followGeneration: true,
                viewportState: state,
                driverPausedForUser: false
            )
        )

        state.followPaused = true
        state.isAtBottom = false
        XCTAssertFalse(
            ChatView.shouldFollowBottomOnComposerFocus(viewportState: state),
            "上滑浏览历史时聚焦输入框不得强行拉回底部。"
        )
        XCTAssertFalse(
            NativeChatTimelineView.shouldPinBottomOnSizeChanges(
                followGeneration: true,
                viewportState: state,
                driverPausedForUser: true
            ),
            "浏览历史时必须关闭 .sizeChanges 底锚，防止键盘弹起/收起改高度时拽回底部。"
        )
    }

    func testScrollGeometryMessageSyncGateSkipsFarHistoryAndPreservesNearBottomResume() {
        XCTAssertFalse(
            NativeChatTimelineView.shouldSyncMessagesOnScrollGeometryChange(
                viewportChanged: false,
                driverPausedForUser: true,
                isMeasuredNearBottom: false
            ),
            "远离底部浏览历史且视口状态未变时，不得逐帧桥接全消息集合。"
        )
        XCTAssertTrue(
            NativeChatTimelineView.shouldSyncMessagesOnScrollGeometryChange(
                viewportChanged: false,
                driverPausedForUser: true,
                isMeasuredNearBottom: true
            ),
            "用户暂停后滚回底部附近时必须允许恢复跟随，且不依赖 isGenerationActive。"
        )
        XCTAssertTrue(
            NativeChatTimelineView.shouldSyncMessagesOnScrollGeometryChange(
                viewportChanged: true,
                driverPausedForUser: true,
                isMeasuredNearBottom: false
            ),
            "视口状态真正变化（例如进入/离开底部或跨越远底阈值）时必须同步。"
        )
        XCTAssertFalse(
            NativeChatTimelineView.shouldSyncMessagesOnScrollGeometryChange(
                viewportChanged: false,
                driverPausedForUser: false,
                isMeasuredNearBottom: true
            )
        )
    }
}
