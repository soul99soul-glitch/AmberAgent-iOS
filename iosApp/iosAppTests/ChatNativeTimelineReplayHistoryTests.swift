import XCTest
import SwiftUI
import QuartzCore
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatNativeTimelineReplayHistoryTests: ChatNativeTimelineReplayTestCase {

    func testConversationEntryAnchorsToBottom() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 225)
        fixture.model.send(.initialLoad)

        // Native timeline 首帧解析后泵到入场锚定完成。
        pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        }
        let viewport = fixture.model.latestViewport

        if let scrollView = fixture.scrollView {
            print(
                "[REPLAY-DIAG] entry offsetY=\(scrollView.contentOffset.y) " +
                "contentH=\(scrollView.contentSize.height) boundsH=\(scrollView.bounds.height) " +
                "insets=\(scrollView.adjustedContentInset) viewport=\(viewport) " +
                "history=\(fixture.model.viewportHistory.count)"
            )
        }
        XCTAssertTrue(viewport.isContentScrollable, "225 轮对话必须可滚动")
        XCTAssertEqual(fixture.model.requestedVariantIndices, Set(390..<450),
                       "从空页加载长会话的第一帧也只能构建最后60条，并保留绝对索引")
        XCTAssertTrue(viewport.isAtBottom, "进入长会话必须锚定到底部(入场重试梯)")
        XCTAssertFalse(viewport.followPaused)
        XCTAssertFalse(viewport.showScrollToBottom)
    }

    func testConversationAndBranchSwitchDoNotRenderPreviousHistoryWindow() {
        for reason in [ChatMessageUpdateReason.conversationSwitch, .branchChange] {
            let fixture = makeFixture { $0.messages = longConversation(turns: 2) }
            defer { fixture.tearDown() }
            pump(seconds: 0.1)
            fixture.model.requestedVariantIndices.removeAll()
            fixture.model.messages = longConversation(turns: 225)
            fixture.model.send(reason)
            XCTAssertTrue(pumpUntil(timeout: 4) {
                fixture.model.requestedVariantIndices.contains(449)
            })
            XCTAssertEqual(fixture.model.requestedVariantIndices, Set(390..<450),
                           "切换或分支变更的第一帧不能沿用上一段短会话的窗口")
        }
    }

    func testScrollingToHistoryTopAutomaticallyPrependsOnePageAndPreservesPosition() throws {
        let fixture = makeFixture { $0.messages = longConversation(turns: 90) }
        defer { fixture.tearDown() }
        XCTAssertTrue(pumpUntil(timeout: 4) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })
        pump(seconds: 0.5)
        XCTAssertEqual(fixture.model.requestedVariantIndices, Set(120..<180),
                       "入场不得自动展开全部历史")
        let scrollView = try XCTUnwrap(fixture.scrollView)
        for firstIndex in [60, 0] {
            let previousHeight = scrollView.contentSize.height
            let topOffset = -scrollView.adjustedContentInset.top
            scrollView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)
            XCTAssertTrue(pumpUntil(timeout: 4) {
                fixture.model.requestedVariantIndices.contains(firstIndex) &&
                    scrollView.contentSize.height > previousHeight && scrollView.contentOffset.y > topOffset + 100
            }, "滚到顶部应自动加载下一页，无需点按钮")
            pump(seconds: 0.25)
            XCTAssertEqual(fixture.model.requestedVariantIndices, Set(firstIndex..<180),
                           "一次触顶只加载一页，不连锁展开")
            XCTAssertEqual(scrollView.contentSize.height - scrollView.contentOffset.y,
                           previousHeight - topOffset, accuracy: 2,
                           "前插消息后原内容应停留在同一屏幕位置")
            XCTAssertFalse(fixture.model.latestViewport.isAtBottom)
        }
    }

    func testCompletedImageAnchorTargetsToolPartInsideTallMessageBeforeConsumption() throws {
        let defaults = UserDefaults.standard
        let viewedKey = ChatImageGenerationResumeConsumption.viewedCompletionIDKey
        let previousViewedID = defaults.object(forKey: viewedKey)
        defaults.removeObject(forKey: viewedKey)
        defer {
            if let previousViewedID {
                defaults.set(previousViewedID, forKey: viewedKey)
            } else {
                defaults.removeObject(forKey: viewedKey)
            }
        }

        let conversationID = "image-anchor-conversation"
        let toolCallID = "image-anchor-tool"
        let targetMessage = makeCompletedImageMessage(
            id: KotlinUuid.companion.random(),
            toolCallID: toolCallID
        )
        let targetMessageID = ChatMessageProjector.messageId(for: targetMessage)
        // Keep the image outside the initial message window so consumption also
        // proves that revealing history completes before the exact anchor scroll.
        let messages = longConversation(turns: 3) + [targetMessage] + longConversation(turns: 35)

        let imageFixture = makeFixture { model in
            model.followGeneration = false
            model.currentConversationID = conversationID
            model.messageAnchor = ChatMessageAnchor(
                conversationID: conversationID,
                messageID: targetMessageID,
                toolCallID: toolCallID
            )
        }
        defer { imageFixture.tearDown() }
        pump(seconds: 0.2)
        XCTAssertNil(defaults.string(forKey: viewedKey))
        imageFixture.model.messages = messages
        imageFixture.model.send(.conversationSwitch)
        XCTAssertTrue(pumpUntil(timeout: 6.0) {
            imageFixture.model.latestViewport.isContentScrollable &&
                imageFixture.model.latestViewport.followPaused &&
                !imageFixture.model.latestViewport.isAtBottom
        })
        pump(seconds: 0.4)

        let imageScrollView = try XCTUnwrap(imageFixture.scrollView)
        let imageOffsetY = imageScrollView.contentOffset.y
        let maximumOffsetY = imageScrollView.contentSize.height - imageScrollView.bounds.height +
            imageScrollView.adjustedContentInset.bottom
        XCTAssertGreaterThan(
            imageOffsetY,
            -imageScrollView.adjustedContentInset.top + 120,
            "精确图片锚点不能因目标未解析而停留在顶部"
        )
        XCTAssertLessThan(
            imageOffsetY,
            maximumOffsetY - 120,
            "精确图片锚点不能因目标未解析而停留在默认底部"
        )

        let expectedContextID = "\(conversationID)|\(targetMessageID)|\(toolCallID)"
        XCTAssertEqual(
            defaults.string(forKey: viewedKey),
            expectedContextID,
            "完成结果只能在真实 timeline 已提交精确图片滚动后消费"
        )
    }

    func testCompletedLongHistoryKeepsStableContentHeightDuringBidirectionalBrowse() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.followGeneration = false
        fixture.model.messages = longHistoricalConversation()
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 6.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        }
        pump(seconds: 0.8)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        defer { probe.stop() }

        for fraction in [0.0, 0.72, 0.18, 1.0, 0.0, 1.0] {
            let maximumY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height +
                    scrollView.adjustedContentInset.bottom
            )
            let minimumY = -scrollView.adjustedContentInset.top
            scrollView.setContentOffset(
                CGPoint(x: 0, y: minimumY + (maximumY - minimumY) * fraction),
                animated: false
            )
            pump(seconds: 0.45)
        }

        let heights = probe.samples.map(\.contentHeight)
        var maximumCollapse: CGFloat = 0
        for index in 1..<heights.count {
            maximumCollapse = max(maximumCollapse, heights[index - 1] - heights[index])
        }
        let heightRange = (heights.max() ?? 0) - (heights.min() ?? 0)

        XCTAssertLessThan(
            maximumCollapse,
            ChatLayout.bottomStickThreshold,
            "完成态双向浏览不能因历史行重新测量产生结构性高度塌陷：" +
                "maxCollapse=\(maximumCollapse), range=\(heightRange)"
        )
        XCTAssertLessThan(
            heightRange,
            ChatLayout.bottomStickThreshold,
            "完成态双向浏览不能让同一条 eager timeline 的总高度来回漂移"
        )
    }

    func testShortContentDoesNotFakeScroll() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = [makeUserMessage("你好")]
        fixture.model.send(.initialLoad)
        pump(seconds: 0.5)

        let assistantId = KotlinUuid.companion.random()
        fixture.model.isGenerationActive = true
        var text = ""
        for index in 0..<5 {
            text += "好的\(index)。"
            let tail = makeAssistantMessage(id: assistantId, text: text, finished: false)
            if fixture.model.messages.last?.role == MessageRole.assistant {
                fixture.model.messages[fixture.model.messages.count - 1] = tail
            } else {
                fixture.model.messages.append(tail)
            }
            fixture.model.send(.streamDelta)
            pump(seconds: 0.05)
        }

        // 负向断言:固定泵一段时间,断言不良状态从未出现。
        pump(seconds: 1.2)
        let viewport = fixture.model.latestViewport
        XCTAssertFalse(viewport.isContentScrollable, "一屏内的短内容不得被判定为可滚动")
        XCTAssertFalse(viewport.showScrollToBottom)
        if let scrollView = fixture.scrollView {
            XCTAssertLessThan(
                abs(scrollView.contentOffset.y + scrollView.adjustedContentInset.top),
                8,
                "短内容不得产生假滚动位移"
            )
        }
    }

    func testCapsuleSpacingDoesNotChangeAcrossToolRounds() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        let parts: [UIMessagePart] = [
            UIMessagePart.Reasoning(reasoning: "核对资料", createdAt: instant, finishedAt: instant, metadata: nil),
            UIMessagePart.Tool(toolCallId: "first", toolName: "search_web", input: "{}",
                               output: [UIMessagePart.Text(text: "完成", metadata: nil)],
                               approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil),
            UIMessagePart.Tool(toolCallId: "next", toolName: "scrape_web", input: "{}",
                               output: [UIMessagePart.Text(text: "完成", metadata: nil)],
                               approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        ]
        func assistant(_ parts: [UIMessagePart]) -> UIMessage {
            UIMessage(id: KotlinUuid.companion.random(), role: MessageRole.assistant, parts: parts,
                      annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
                      modelId: nil, usage: nil, translation: nil)
        }
        let user = makeUserMessage("查询资料")
        fixture.model.messages = [user, assistant(parts)]
        fixture.model.send(.initialLoad)
        pump(seconds: 0.8)
        let scrollView = try XCTUnwrap(fixture.scrollView)
        let singleMessageHeight = scrollView.contentSize.height
        XCTAssertGreaterThan(singleMessageHeight, 132)

        fixture.model.messages = [user] + parts.map { assistant([$0]) }
        fixture.model.send(.branchChange)
        pump(seconds: 0.8)
        XCTAssertEqual(scrollView.contentSize.height, singleMessageHeight, accuracy: 1,
                       "同一回合的思考和工具胶囊不能因内部消息分段而增加间距")
    }

    func testAssistantContinuationHasNoRepeatedHeaderGap() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let first = makeAssistantMessage(text: "第一轮工具后的说明", finished: true)
        let next = makeAssistantMessage(text: "下一轮工具后的结论", finished: false)
        fixture.model.messages = [makeUserMessage("查询资料"), first]
        fixture.model.send(.initialLoad)
        pump(seconds: 0.5)
        let scrollView = try XCTUnwrap(fixture.scrollView)
        let firstHeight = scrollView.contentSize.height
        fixture.model.isGenerationActive = true
        fixture.model.messages.append(next)
        fixture.model.send(.streamDelta)
        pump(seconds: 0.8)

        let nextParagraph = try XCTUnwrap(ScrollFrameProbe.paragraph(
            in: fixture.host.view, withPrefix: "下一轮工具后的结论"
        ))
        let continuedHeight = scrollView.contentSize.height
        XCTAssertEqual(continuedHeight - firstHeight, nextParagraph.bounds.height + 8, accuracy: 1,
                       "续答只增加正文与列表间距，不应重复标题或预留标题空白")
        fixture.model.isGenerationActive = false
        fixture.model.messages[2] = makeAssistantMessage(id: next.id, text: "下一轮工具后的结论", finished: true)
        fixture.model.send(.generationCompleted)
        pump(seconds: 0.8)
        XCTAssertEqual(scrollView.contentSize.height, continuedHeight, accuracy: 1)
    }

    func testCompletedMarkdownRemountKeepsFormattedContentAndHeight() {
        let text = """
        连续正文开始。**已完成的内容**在重新打开时保持格式。

        | 项目 | 结果 |
        | --- | --- |
        | 缓存 | 保持原有列宽和换行 |
        | 终态 | 不重新淡入 |
        """
        let messages = [makeAssistantMessage(text: text, finished: true)]
        let first = makeFixture()
        first.model.messages = messages
        first.model.send(.initialLoad)
        pump(seconds: 0.8)
        XCTAssertFalse(ScrollFrameProbe.hasRawMarkdown(in: first.host.view))
        let originalHeight = first.scrollView?.contentSize.height ?? 0
        XCTAssertGreaterThan(originalHeight, 0)
        first.tearDown()

        let reopened = makeFixture()
        defer { reopened.tearDown() }
        guard let scrollView = reopened.scrollView else {
            return XCTFail("Expected the native scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: reopened.host.view)
        probe.start()
        reopened.model.messages = messages
        reopened.model.send(.initialLoad)
        pump(seconds: 0.8)
        probe.stop()

        XCTAssertFalse(probe.samples.isEmpty)
        XCTAssertFalse(probe.samples.contains { $0.rawMarkdownVisible == true })
        XCTAssertEqual(scrollView.contentSize.height, originalHeight, accuracy: 0.5)
    }

    func testConversationSwitchResetsAndReanchors() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 15)
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        // 程序化把视口挪离底部(不模拟拖拽——拖拽语义属真机;这里只制造
        // 「切换前视口不在底部」的前置状态)。
        if let scrollView = fixture.scrollView {
            scrollView.setContentOffset(
                CGPoint(x: 0, y: max(0, scrollView.contentOffset.y - 600)),
                animated: false
            )
        }
        pump(seconds: 0.3)

        // 切换到另一个长会话:必须清态并重新锚定到底部。
        fixture.model.messages = longConversation(turns: 10)
        fixture.model.send(.conversationSwitch)

        pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && !fixture.model.latestViewport.followPaused
        }
        let viewport = fixture.model.latestViewport
        XCTAssertTrue(viewport.isAtBottom, "切换会话必须重新锚定到底部")
        XCTAssertFalse(viewport.followPaused, "切换会话必须清掉上个会话的暂停态")
        XCTAssertFalse(viewport.showScrollToBottom)
    }
}
