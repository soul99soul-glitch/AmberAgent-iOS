import XCTest
import SwiftUI
import UIKit
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatPerformanceWasteFixesTests: ChatNativeTimelineReplayTestCase {

    // MARK: - Fix 1: historyBoundary continuous 120Hz geometry observer convergence

    func testShortConversationScrollingAndStreamingDispatchZeroHistoryBoundaryCallbacks() throws {
        // 30 messages <= historyPageSize (60): startIndex == 0, history pagination cannot trigger.
        let fixture = makeFixture { $0.messages = longConversation(turns: 15) }
        defer {
            fixture.tearDown()
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })
        pump(seconds: 0.4)

        let scrollView = try XCTUnwrap(fixture.scrollView)
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        XCTAssertGreaterThan(maximumY - minimumY, 100, "Fixture should be scrollable")

        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true

        // 1. Scroll repeatedly across the entire viewport (including top).
        for fraction: CGFloat in [0.75, 0.5, 0.25, 0.0, 0.4, 0.85, 1.0] {
            scrollView.setContentOffset(
                CGPoint(x: 0, y: minimumY + (maximumY - minimumY) * fraction),
                animated: false
            )
            fixture.host.view.setNeedsLayout()
            fixture.host.view.layoutIfNeeded()
            pump(seconds: 0.05)
        }

        // 2. Stream tokens at the bottom.
        fixture.model.isGenerationActive = true
        fixture.model.messages.append(makeUserMessage("短会话流式跟随验证"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.1)

        let streamID = KotlinUuid.companion.random()
        for step in 1...6 {
            let text = String(repeating: "短会话流式跟底增量片段。", count: step)
            if step == 1 {
                fixture.model.messages.append(makeAssistantMessage(id: streamID, text: text, finished: false))
            } else {
                fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                    id: streamID, text: text, finished: false
                )
            }
            fixture.model.send(.streamDelta)
            pump(seconds: 0.08)
        }
        ChatRenderProbe.enabled = false

        let boundaryCallbacks = ChatRenderProbe.counts["history-boundary-action"]?.values.reduce(0, +) ?? 0
        XCTAssertEqual(
            boundaryCallbacks,
            0,
            "startIndex == 0 的会话在滚动与流式跟底期间不得派发任何 history-boundary 几何回调"
        )
    }

    func testPaginatedConversationSuppressesBoundaryCallbacksDuringBottomFollowAndMidScrollYetLoadsAtTop() throws {
        // 180 messages => startIndex == 120 (> 0).
        let fixture = makeFixture { $0.messages = longConversation(turns: 90) }
        defer {
            fixture.tearDown()
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })
        pump(seconds: 0.5)

        let scrollView = try XCTUnwrap(fixture.scrollView)
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )

        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true

        // 1. Stream bottom-follow deltas + scroll through lower/middle history (staying well below top boundary).
        fixture.model.isGenerationActive = true
        fixture.model.messages.append(makeUserMessage("分页长会话底部流式跟随"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.1)

        let streamID = KotlinUuid.companion.random()
        fixture.model.messages.append(makeAssistantMessage(id: streamID, text: "分页流式回复第一段。", finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 0.15)
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: streamID,
            text: "分页流式回复第一段。\n\n分页流式回复第二段内容继续增长。",
            finished: true
        )
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 0.25)

        for fraction: CGFloat in [0.92, 0.72, 0.52, 0.35] {
            let targetY = minimumY + (maximumY - minimumY) * fraction
            if targetY > minimumY + 300 {
                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
                fixture.host.view.setNeedsLayout()
                fixture.host.view.layoutIfNeeded()
                pump(seconds: 0.05)
            }
        }
        ChatRenderProbe.enabled = false

        let offScreenCallbacks = ChatRenderProbe.counts["history-boundary-action"]?.values.reduce(0, +) ?? 0
        let prematureLoads = ChatRenderProbe.counts["scroll:load-earlier"]?.values.reduce(0, +) ?? 0
        XCTAssertEqual(
            offScreenCallbacks,
            0,
            "顶部边界尚在视口上方时，流式跟底与中下部滚动不得触发 history-boundary 主线程回调"
        )
        XCTAssertEqual(prematureLoads, 0)

        // 2. Scroll to top and verify one-page prepend & viewport restoration still work identically.
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        let previousHeight = scrollView.contentSize.height
        let topOffset = -scrollView.adjustedContentInset.top
        scrollView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.requestedVariantIndices.contains(60) &&
                scrollView.contentSize.height > previousHeight &&
                scrollView.contentOffset.y > topOffset + 100
        }, "触顶越过边界后必须照常加载上一页并保持屏幕位置")
        ChatRenderProbe.enabled = false

        let loadCount = ChatRenderProbe.counts["scroll:load-earlier"]?.values.reduce(0, +) ?? 0
        XCTAssertEqual(loadCount, 1, "单次触顶应只加载一页")
        XCTAssertEqual(
            scrollView.contentSize.height - scrollView.contentOffset.y,
            previousHeight - topOffset,
            accuracy: 2.0,
            "前插历史消息后原可视锚点偏移必须保持不变"
        )
    }

    // MARK: - Fix 2: StreamingGraphHost inner markRowDirty isolation & zero-full-hash boundary signature

    func testStreamingGraphHostSuppressesInnerRowInvalidationOnSameLineRevealAndInvalidatesOnLineWrap() throws {
        let fixture = makeFixture { model in
            model.messages = longConversation(turns: 15)
        }
        defer {
            fixture.tearDown()
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })
        pump(seconds: 0.3)

        // Direct sentinel guard check (must never increment rowGenerations or unscopedGeneration).
        ChatTimelineRowLayoutInvalidation.installHookIfNeeded()
        let unscopedBeforeSentinel = ChatTimelineRowLayoutInvalidation.unscopedGenerationForTesting()
        let sentinelBefore = ChatTimelineRowLayoutInvalidation.rowGenerationForTesting(
            ChatTimelineRowLayoutInvalidation.graphHostContainedID
        )
        ChatTimelineRowLayoutInvalidation.markRowDirty(ChatTimelineRowLayoutInvalidation.graphHostContainedID)
        ParagraphLayoutInvalidationHook.onInvalidate?(ChatTimelineRowLayoutInvalidation.graphHostContainedID)
        XCTAssertEqual(ChatTimelineRowLayoutInvalidation.unscopedGenerationForTesting(), unscopedBeforeSentinel)
        XCTAssertEqual(
            ChatTimelineRowLayoutInvalidation.rowGenerationForTesting(
                ChatTimelineRowLayoutInvalidation.graphHostContainedID
            ),
            sentinelBefore
        )

        // Mount live streaming message.
        fixture.model.isGenerationActive = true
        fixture.model.messages.append(makeUserMessage("测试宿主内部同行吐字隔离"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.1)

        let streamID = KotlinUuid.companion.random()
        let streamHex = streamID.toHexDashString()
        let seed = "当前行前缀：正在继续输出"
        fixture.model.messages.append(makeAssistantMessage(id: streamID, text: seed, finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 0.5)

        // 1. Append same-line token: SizedView height does not change (> 0.5pt),
        //    so inner ParagraphUIView / ChatAssistantMarkdownView must NOT dirty outer rowGeneration.
        let baselineRowGen = ChatTimelineRowLayoutInvalidation.rowGenerationForTesting(streamHex)
        let baselineUnscoped = ChatTimelineRowLayoutInvalidation.unscopedGenerationForTesting()
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true

        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: streamID, text: seed + "，追加同", finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.35)
        ChatRenderProbe.enabled = false

        XCTAssertEqual(
            ChatTimelineRowLayoutInvalidation.rowGenerationForTesting(streamHex),
            baselineRowGen,
            "ChatStreamingGraphHost 内部同行吐字（未增高）不得污染外层 ChatTimelineRowLayout rowGeneration"
        )
        XCTAssertEqual(
            ChatTimelineRowLayoutInvalidation.unscopedGenerationForTesting(),
            baselineUnscoped,
            "图宿主隔离环境绝不能落入 unscopedGeneration 污染全局历史行"
        )
        XCTAssertEqual(
            ChatRenderProbe.counts["layout-invalidate"]?[streamHex] ?? 0,
            0,
            "同行吐字高度不变时不得触发外层 ChatTimelineRowLayout 缓存失效"
        )
        XCTAssertEqual(
            ChatRenderProbe.counts["layout-measure"]?[streamHex] ?? 0,
            0,
            "同行吐字高度不变时不得触发外层 ChatTimelineRowLayout 重测"
        )

        // 2. Append wrapped paragraphs: height grows (> 0.5pt), SizedView notifies outer row cleanly.
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        let wrapped = seed + "，追加同\n\n" + String(repeating: "多行自动换行生长段落测试文本，用于触发外层宿主高度变化。", count: 8)
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: streamID, text: wrapped, finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.6)
        ChatRenderProbe.enabled = false

        XCTAssertGreaterThan(
            ChatTimelineRowLayoutInvalidation.rowGenerationForTesting(streamHex),
            baselineRowGen,
            "真实折行增高超过 0.5pt 时，宿主 SizedView 必须标记外层 rowGeneration 为脏"
        )
        XCTAssertGreaterThan(
            ChatRenderProbe.counts["layout-measure"]?[streamHex] ?? 0,
            0,
            "折行增高后外层 ChatTimelineRowLayout 必须立即重新测量"
        )
        XCTAssertEqual(
            ChatTimelineRowLayoutInvalidation.unscopedGenerationForTesting(),
            baselineUnscoped
        )
    }

    func testStreamingGraphContentSignatureEqualityAndSegmentedCommitZeroAllocParity() {
        let largeBody = String(repeating: "Paragraph with **bold** and `code` tokens.\n\n", count: 800)
        let sigA = ChatStreamingGraphContentSignature(
            partIndex: 0,
            isSegmented: false,
            isLiveStreaming: true,
            reduceMotion: false,
            liveMarkdownRenderingEnabled: true,
            hasEverStreamed: true,
            isSourceMessageComplete: false,
            displaySignature: 1,
            generativeSignature: 2,
            textToken: .full(largeBody),
            frozenMarkdownSnapshot: nil
        )
        var sigSame = sigA
        XCTAssertEqual(sigA, sigSame)

        sigSame = ChatStreamingGraphContentSignature(
            partIndex: 0,
            isSegmented: false,
            isLiveStreaming: true,
            reduceMotion: false,
            liveMarkdownRenderingEnabled: true,
            hasEverStreamed: true,
            isSourceMessageComplete: false,
            displaySignature: 1,
            generativeSignature: 2,
            textToken: .full(largeBody + "!"),
            frozenMarkdownSnapshot: nil
        )
        XCTAssertNotEqual(sigA, sigSame)

        // Verify zero-alloc Substring refactor in ChatSegmentedMarkdownCommitPolicy matches fenced code + math.
        let sample = """
        导语。

        ```python
        x = 1

        y = 2
        ```

        $$
        a + b = c

        d + e = f
        $$

        未闭合尾段
        """
        let expected = """
        导语。

        ```python
        x = 1

        y = 2
        ```

        $$
        a + b = c

        d + e = f
        $$
        """
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: sample, isStreaming: true),
            expected
        )
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: sample, isStreaming: false),
            sample
        )
    }

    // MARK: - Fix 3: Table detection tick short-circuit & snapshot flags

    func testSnapshotFlagsAndBlocksFollowPrefixReplacementsWithUnchangedTailCheckpoint() async {
        let blank = String(repeating: " ", count: 64)
        let sameLength = "正文" + String(repeating: " ", count: 62)
        let longer = "正文" + String(repeating: " ", count: 80)
        var detector = ChatStreamingTableDetectionState(text: blank)
        detector.update(with: sameLength)
        XCTAssertTrue(detector.hasNonWhitespace)
        detector.update(with: blank)
        XCTAssertFalse(detector.hasNonWhitespace)
        detector.update(with: longer)
        XCTAssertTrue(detector.hasNonWhitespace)

        detector = ChatStreamingTableDetectionState(text: "A" + blank)
        detector.update(with: "\r" + blank)
        XCTAssertTrue(detector.containsCarriageReturn)
        XCTAssertFalse(detector.hasNonWhitespace)
        detector.update(with: "A" + blank)
        XCTAssertFalse(detector.containsCarriageReturn)

        let cases = [(blank, sameLength), (blank, longer), ("A" + blank, "\rX" + String(repeating: " ", count: 63))]
        for (initial, replacement) in cases {
            let controller = ChatStreamingMarkdownBlockController(
                text: initial, includeTrailingPartialTableRow: false
            )
            controller.scheduleParse(text: replacement, includeTrailingPartialTableRow: true)
            for _ in 0..<100 where controller.parsedText != replacement {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.parsedText, replacement)
            XCTAssertEqual(controller.blocks, ChatStreamingMarkdownBlockParser.blocks(
                in: replacement, includeTrailingPartialTableRow: true
            ))
        }
    }

    func testTableDetectionStateShortCircuitsIdenticalTicksAndResolvesSnapshotFlags() {
        // Counts measure incremental parser consumption, excluding snapshot flag reads.
        var detector = ChatStreamingTableDetectionState()
        var text = ""
        text.reserveCapacity(40_000)
        let chunk = "这是第 N 段流式正文，包含 **粗体** 与 `inline_code` 但没有表格。\n"
        for _ in 0..<800 {
            text.append(chunk)
            detector.update(with: text)
            // Simulate 4 pacer ticks reading the exact same immutable String between deltas.
            for _ in 0..<4 {
                detector.update(with: text)
            }
        }
        XCTAssertFalse(detector.containsTable)
        XCTAssertFalse(detector.containsCarriageReturn)
        XCTAssertTrue(detector.hasNonWhitespace)
        XCTAssertEqual(
            detector.totalConsumedUTF8Count,
            text.utf8.count,
            "800 次流式追加与 3,200 次重复帧读取应严格只消费一次总 UTF-8 字节数"
        )

        // 2. Empty & Unicode whitespace edge cases before non-whitespace appears.
        var wsDetector = ChatStreamingTableDetectionState()
        XCTAssertFalse(wsDetector.hasNonWhitespace)
        wsDetector.update(with: "   \t\n\u{3000}  ")
        XCTAssertFalse(wsDetector.hasNonWhitespace, "纯空白与全角空格不可误判为非空内容")
        XCTAssertFalse(wsDetector.containsCarriageReturn)

        wsDetector.update(with: "   \t\n\u{3000}  你好")
        XCTAssertTrue(wsDetector.hasNonWhitespace, "首段出现中文非空白字符时必须锁存 hasNonWhitespace = true")

        // 3. CRLF handling & fallback parity in ChatStreamingMarkdownBlockController.
        let crlfPlain = "第一行\r\n第二行\r\n\r\n第三行"
        var crlfDetector = ChatStreamingTableDetectionState(text: crlfPlain)
        XCTAssertTrue(crlfDetector.containsCarriageReturn)
        XCTAssertFalse(crlfDetector.containsTable)
        XCTAssertTrue(crlfDetector.hasNonWhitespace)

        // Reset on prefix rewrite must clear latched flags cleanly.
        crlfDetector.update(with: "重写后的纯换行文本\n第二行")
        XCTAssertFalse(crlfDetector.containsCarriageReturn)
        XCTAssertTrue(crlfDetector.hasNonWhitespace)

        let crlfTable = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |"
        let controller = ChatStreamingMarkdownBlockController(
            text: crlfTable,
            includeTrailingPartialTableRow: true
        )
        XCTAssertEqual(
            controller.blocks,
            ChatStreamingMarkdownBlockParser.blocks(in: crlfTable, includeTrailingPartialTableRow: true)
        )
    }
}
