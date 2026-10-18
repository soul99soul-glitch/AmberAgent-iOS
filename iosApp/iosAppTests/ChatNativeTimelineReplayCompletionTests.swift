import XCTest
import SwiftUI
import QuartzCore
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatNativeTimelineReplayCompletionTests: ChatNativeTimelineReplayTestCase {

    func testCompletionKeepsAlreadyRenderedFinalResponseGeometryStable() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请连续生成一段最终正文。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantID = KotlinUuid.companion.random()
        let finalText = "连续正文开始。" + String(
            repeating: "最后一个字已经上屏后，完成态只能结束生成状态，不能重新排版同一段正文。",
            count: 10
        )
        let baseMessages = fixture.model.messages
        let target = baseMessages + [makeAssistantMessage(
            id: assistantID,
            text: finalText,
            finished: true
        )]
        let prefixes = iosChatScriptedTextPrefixes(finalText, chunkCount: 12)
        for (index, prefix) in prefixes.enumerated() {
            let isFinalPrefix = index == prefixes.count - 1
            fixture.model.messages = baseMessages + [makeAssistantMessage(
                id: assistantID,
                text: prefix,
                finished: isFinalPrefix
            )]
            fixture.model.send(.streamDelta)
            if !isFinalPrefix { pump(seconds: 0.048) }
        }

        // 与生产顺序一致：drain 的最后一拍已经带上 authoritative finishedAt，
        // 随后只发送 stream-closed revision，消息值不再变化。
        fixture.model.messages = target
        fixture.model.send(.assistantStreamClosed)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            guard let paragraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
                return false
            }
            return ScrollFrameProbe.streamingTextLength(in: paragraph) == finalText.utf16.count
        })
        pump(seconds: 0.6)

        guard let scrollView = fixture.scrollView,
              let paragraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
            return XCTFail("Expected the fully rendered final streaming paragraph")
        }
        let baselineContentHeight = scrollView.contentSize.height
        let baselineOffsetY = scrollView.contentOffset.y
        let baselineParagraphHeight = paragraph.frame.height
        let baselineParagraphIdentity = ObjectIdentifier(paragraph)

        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 1.0)
        probe.stop()

        let terminalSamples = probe.samples.filter {
            $0.paragraphLength == finalText.utf16.count
        }
        XCTAssertFalse(terminalSamples.isEmpty, "终态门禁必须真实采到最终正文")
        XCTAssertTrue(
            terminalSamples.allSatisfy { $0.paragraphIdentity == baselineParagraphIdentity },
            "完成态不能重建已经显示的 ParagraphUIView"
        )
        let maximumParagraphShift = terminalSamples.compactMap(\.paragraphHeight)
            .map { abs($0 - baselineParagraphHeight) }
            .max() ?? 0
        let maximumContentShift = terminalSamples.map {
            abs($0.contentHeight - baselineContentHeight)
        }.max() ?? 0
        let maximumOffsetShift = terminalSamples.map {
            abs($0.contentOffsetY - baselineOffsetY)
        }.max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumParagraphShift,
            0.5,
            "相同最终正文不能在 completion 后再次改变段落高度：\(maximumParagraphShift)"
        )
        XCTAssertLessThanOrEqual(
            maximumContentShift,
            0.5,
            "相同最终正文不能在 completion 后再次改变列表高度：\(maximumContentShift)"
        )
        XCTAssertLessThanOrEqual(
            maximumOffsetShift,
            0.5,
            "最后一个字已稳定后，completion 不能再次移动视口：\(maximumOffsetShift)"
        )
    }

    func testStreamingTableTailRowVisibleBeforeCompletionWithoutRelayout() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请给出对比表格。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantID = KotlinUuid.companion.random()
        // 开头必须含 ScrollFrameProbe.streamingMarker，探针按它定位段落视图。
        // 最后一行完成时不带结尾换行——正是「尾行」判定的生产形态。
        let finalText = """
        连续正文开始。**（重点）** 这里必须保留粗体强调。

        ## 对比方案

        - 列表项一：保持流式连续。
        - 列表项二：完成不重排。

        | 方案 | 机制 | 结论 |
        | --- | --- | --- |
        | 一 | 几何驱动到点补偿的机制描述 | 采纳 |
        | 二 | 连续节奏曲线的机制描述 | 不采纳 |
        | 三 | 尾段整体淡入的机制描述 | 再议 |
        | 四 | 完成零跳变的机制描述 | 待定
        """
        let baseMessages = fixture.model.messages
        for prefix in iosChatScriptedTextPrefixes(finalText, chunkCount: 16) {
            fixture.model.messages = baseMessages + [makeAssistantMessage(
                id: assistantID,
                text: prefix,
                finished: false
            )]
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }

        // 等流式解析落地（表格 live parse 0.12s + 块发布限频 0.09s 之上留余量），
        // 再取基线。基线必须在 completion 之前，否则采样不到「完成差」。
        pump(seconds: 0.8)

        guard let scrollView = fixture.scrollView,
              let markerParagraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view),
              let baselineTable = ScrollFrameProbe.tableScrollView(
                in: fixture.host.view,
                excluding: scrollView
              ) else {
            return XCTFail("Expected the fully rendered streaming table and marker paragraph")
        }
        let baselineContentHeight = scrollView.contentSize.height
        let baselineParagraphHeight = markerParagraph.frame.height
        let baselineParagraphIdentity = ObjectIdentifier(markerParagraph)
        let baselineTableHeight = baselineTable.frame.height
        let baselineTableIdentity = ObjectIdentifier(baselineTable)

        // 生产顺序：最后一拍后立即 stream-closed + 完成，无静默收敛窗。
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        fixture.model.messages = fixture.model.messages.dropLast() + [makeAssistantMessage(
            id: assistantID,
            text: finalText,
            finished: true
        )]
        fixture.model.send(.assistantStreamClosed)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 1.2)
        probe.stop()

        XCTAssertFalse(probe.samples.isEmpty, "完成窗口必须真实采到帧")
        XCTAssertTrue(
            probe.samples.allSatisfy { $0.paragraphIdentity == baselineParagraphIdentity },
            "完成态不能重建已经显示的 ParagraphUIView"
        )
        XCTAssertTrue(
            probe.samples.compactMap(\.tableIdentity).allSatisfy { $0 == baselineTableIdentity },
            "完成态不能重建表格视图"
        )
        XCTAssertFalse(
            probe.samples.compactMap(\.tableHeight).isEmpty,
            "表格视图必须持续在屏"
        )
        let maximumParagraphShift = probe.samples.compactMap(\.paragraphHeight)
            .map { abs($0 - baselineParagraphHeight) }
            .max() ?? 0
        let maximumContentShift = probe.samples.map {
            abs($0.contentHeight - baselineContentHeight)
        }.max() ?? 0
        let maximumTableShift = probe.samples.compactMap(\.tableHeight)
            .map { abs($0 - baselineTableHeight) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumParagraphShift,
            0.5,
            "相同最终正文不能在 completion 后再次改变段落高度：\(maximumParagraphShift)"
        )
        XCTAssertLessThanOrEqual(
            maximumContentShift,
            0.5,
            "表格最后一行必须在流式期已显示——completion 后列表高度不得再增长：\(maximumContentShift)"
        )
        XCTAssertLessThanOrEqual(
            maximumTableShift,
            0.5,
            "表格最后一行必须在流式期已显示——completion 后表格高度不得再增长：\(maximumTableShift)"
        )
    }

    func testCompletionSwitchNeverShowsUnrenderedMarkdownRawText() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请给出对比表格。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantID = KotlinUuid.companion.random()
        // 开头必须含 ScrollFrameProbe.streamingMarker，探针按它定位段落视图。
        // 表格放大完成态解析窗（80 行 ≈3.4KB：终态首次解析+整表布局 ≥2 帧），
        // 最后一行完成时不带结尾换行——「尾行」判定的生产形态。
        let rows = (0..<80).map { row in
            "| \(row) | 用于放大完成切换解析窗的流式表格行内容，行号 \(row) 便于取证 | 采纳 |"
        }
        let finalText = """
        连续正文开始。**（重点）** 这里必须保留粗体强调。

        ## 对比方案

        - 列表项一：保持流式连续。
        - 列表项二：完成不重排。

        | 方案 | 机制 | 结论 |
        | --- | --- | --- |
        """ + "\n" + rows.joined(separator: "\n")
        let baseMessages = fixture.model.messages
        guard let finalRowStart = finalText.lastIndex(of: "\n") else {
            return XCTFail("Expected a final table-row boundary")
        }
        let settledPrefix = String(finalText[..<finalRowStart])
        for prefix in iosChatScriptedTextPrefixes(settledPrefix, chunkCount: 24) {
            fixture.model.messages = baseMessages + [makeAssistantMessage(
                id: assistantID,
                text: prefix,
                finished: false
            )]
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }
        // 先让截至完整行的大表格前缀解析落地，再立即补上最后一行；
        // 这样终态切换时最后一次解析仍在飞行，但基线是有效的格式化前缀。
        pump(seconds: 0.4)
        fixture.model.messages = baseMessages + [makeAssistantMessage(
            id: assistantID,
            text: finalText,
            finished: false
        )]
        fixture.model.send(.streamDelta)
        pump(seconds: 0.048)

        // 基线：流式期最后一拍的渲染必须是「已格式化」——没有任何字面结构标记
        // （表格尾块按 0.12s 节流，最后一拍全文解析仍在飞行中，基线只要求
        // 已上屏的流式前缀已格式化，不要求全文解析落地）。
        XCTAssertFalse(
            ScrollFrameProbe.hasRawMarkdown(in: fixture.host.view),
            "流式期任何一帧都不得出现未渲染的 markdown 原文（字面 **、##、-、表格管道行）"
        )

        // 生产顺序：最后一拍后立即 stream-closed + 完成，无静默收敛窗。
        // 完成瞬间表格尾块的终态首次解析必然在飞行中——修复前空窗退回原文。
        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the native scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        fixture.model.messages = fixture.model.messages.dropLast() + [makeAssistantMessage(
            id: assistantID,
            text: finalText,
            finished: true
        )]
        fixture.model.send(.assistantStreamClosed)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 1.2)
        probe.stop()

        XCTAssertFalse(probe.samples.isEmpty, "完成窗口必须真实采到帧")
        let rawFrames = probe.samples.filter { $0.rawMarkdownVisible == true }
        XCTAssertTrue(
            rawFrames.isEmpty,
            "完成切换的任何一帧都不得把已流式渲染的正文退回未渲染的 markdown 原文"
                + "（字面 **、##、-、表格管道行）：rawFrames=\(rawFrames.count)/\(probe.samples.count)"
        )
        // 完成窗口内格式化正文必须持续可见（探针始终能定位到已渲染的 marker 段落）。
        XCTAssertFalse(
            probe.samples.compactMap(\.paragraphIdentity).isEmpty,
            "完成切换期间已流式渲染的正文段落必须持续在屏"
        )
    }

    func testScrolledAwayLiveTailUnfreezesKeepingBlockIdentity() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 12)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请生成长回复。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantID = KotlinUuid.companion.random()
        let finalText = "连续正文开始。" + String(
            repeating: "流式尾行离屏时模型发布必须暂停，回到视口后同一块继续增长而不重建。",
            count: 24
        )
        let baseMessages = fixture.model.messages
        for prefix in iosChatScriptedTextPrefixes(finalText, chunkCount: 18) {
            fixture.model.messages = baseMessages + [makeAssistantMessage(
                id: assistantID,
                text: prefix,
                finished: false
            )]
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }
        pump(seconds: 0.6)

        guard let scrollView = fixture.scrollView,
              let markerParagraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
            return XCTFail("Expected the fully rendered streaming paragraph")
        }
        let baselineIdentity = ObjectIdentifier(markerParagraph)

        // 冻结：messageAnchor 指向历史消息 → 锚点滚动路径提交 .userDragBegan，
        // driver 进入 pausedForUser（followPaused=true），随后滚离底部即触发
        // liveRenderingFarFromBottom 冻结。
        let conversationID = "lod-conversation"
        fixture.model.currentConversationID = conversationID
        let anchorMessage = fixture.model.messages[3]
        let anchorMessageID = ChatMessageProjector.messageId(for: anchorMessage)
        fixture.model.messageAnchor = ChatMessageAnchor(
            conversationID: conversationID,
            messageID: anchorMessageID
        )
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.followPaused &&
                !fixture.model.latestViewport.isAtBottom &&
                fixture.model.latestViewport.liveRenderingFarFromBottom
        })

        // 离屏期间消息继续增长（生产形态：尾部仍在下发）。
        let grownText = finalText + "\n\n离屏期间追加的段落。"
        fixture.model.messages = fixture.model.messages.dropLast() + [makeAssistantMessage(
            id: assistantID,
            text: grownText,
            finished: false
        )]
        fixture.model.send(.streamDelta)
        pump(seconds: 0.5)
        XCTAssertTrue(
            fixture.model.latestViewport.liveRenderingFarFromBottom,
            "冻结期间视口必须保持远离底部"
        )

        // 解冻：滚回底部 → 近底几何恢复（unfreezeVisibleLiveTailIfNeeded +
        // streamContentGrew），driver 恢复跟随。
        let bottomOffset = max(
            0,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom &&
                !fixture.model.latestViewport.liveRenderingFarFromBottom
        })
        pump(seconds: 0.8)

        guard let unfrozen = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
            return XCTFail("Expected the live tail paragraph after unfreeze")
        }
        XCTAssertEqual(
            ObjectIdentifier(unfrozen),
            baselineIdentity,
            "LOD 解冻必须复用冻结前的同一块渲染结果，不能重建淡入"
        )
        XCTAssertTrue(
            ScrollFrameProbe.streamingTextLength(in: unfrozen) ?? 0 > finalText.utf16.count,
            "离屏期间下发的追加内容必须在回到视口后可见"
        )
    }

    func testLongReasoningStreamThroughNativeTimelineKeepsLatestTextAndCompletes() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let id = KotlinUuid.companion.random()
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        var reasoning = String(repeating: "先检查上下文与工具结果，再逐步推演下一步。", count: 600)
        func message(finished: Bool = false) -> UIMessage {
            var parts: [UIMessagePart] = [UIMessagePart.Reasoning(reasoning: reasoning,
                createdAt: instant, finishedAt: finished ? instant : nil, metadata: nil)]
            if finished { parts.append(UIMessagePart.Text(text: "连续正文开始。思考已完成。", metadata: nil)) }
            return UIMessage(id: id, role: MessageRole.assistant, parts: parts, annotations: [],
                createdAt: chatNowLocalDateTime(), finishedAt: finished ? chatNowLocalDateTime() : nil,
                modelId: nil, usage: nil, translation: nil)
        }
        func reasoningView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView, textView.accessibilityIdentifier == "chat.reasoning.body" { return textView }
            for child in view.subviews {
                if let found = reasoningView(in: child) { return found }
            }
            return nil
        }
        fixture.model.messages = longConversation(turns: 8) + [makeUserMessage("请详细思考。"), message()]
        fixture.model.isGenerationActive = true
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom && reasoningView(in: fixture.host.view) != nil })
        pump(seconds: 0.6)
        let textView = try XCTUnwrap(reasoningView(in: fixture.host.view))
        let probe = DisplayLinkGapProbe()
        probe.start()
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<30 {
            reasoning += "继续核对推理中的每一步。"
            fixture.model.messages[fixture.model.messages.count - 1] = message()
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        pump(seconds: 0.55)
        probe.stop()
        XCTAssertTrue(reasoningView(in: fixture.host.view) === textView)
        // `ChatTextWindow`'s stepped slide (ChatTextWindow.step) keeps the live
        // window up to `step` characters ahead of where a freshly-reconstructed
        // window over the same source would have slid to — exact equality no
        // longer holds once omission has started, only "still ends with the
        // latest tail, still bounded".
        let freshWindow = ChatTextWindow(reasoning)
        XCTAssertTrue(
            textView.text.hasSuffix(freshWindow.text),
            "尾窗必须仍以最新内容收尾"
        )
        XCTAssertLessThanOrEqual(
            (textView.text as NSString).length,
            freshWindow.text.utf16.count + ChatTextWindow.step + 64,
            "尾窗不能无限增长，必须在一个步长内收敛"
        )
        XCTAssertEqual(textView.bounds.height, 180, accuracy: 0.5)
        let metrics = "[PERF-REASONING-NATIVE] updates=30 CPU=\(cpuMs)ms per-update=\(cpuMs / 30)ms max-frame-gap=\((probe.gaps.max() ?? 0) * 1000)ms"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.name = "native-reasoning-stream-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        fixture.model.messages[fixture.model.messages.count - 1] = message(finished: true)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        XCTAssertTrue(pumpUntil(timeout: 4) {
            reasoningView(in: fixture.host.view) == nil && fixture.model.latestViewport.isAtBottom
        })
        XCTAssertTrue(try XCTUnwrap(fixture.model.messages.last?.parts.first as? UIMessagePart.Reasoning).reasoning == reasoning,
            "绘制尾窗不能截断持久化/上下文中的完整思考内容")
    }

    func testTerminalWithReasoningCollapseSettlesMonotonically() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 6)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请先思考再回答。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantID = KotlinUuid.companion.random()
        let reasoningText = String(
            repeating: "推理过程需要逐步展开，确保每一步都有依据，避免凭空结论。",
            count: 12
        )
        // 开头必须含 ScrollFrameProbe.streamingMarker，探针按它定位段落视图。
        let finalText = "连续正文开始。" + String(
            repeating: "终态收起推理卡时，视口只能一次性收敛到新底部，不能来回挪动。",
            count: 12
        )
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        func assistantMessage(
            text: String = finalText,
            reasoningFinished: Bool,
            finished: Bool
        ) -> UIMessage {
            UIMessage(
                id: assistantID,
                role: MessageRole.assistant,
                parts: [
                    UIMessagePart.Reasoning(
                        reasoning: reasoningText,
                        createdAt: instant,
                        finishedAt: reasoningFinished ? instant : nil,
                        metadata: nil
                    ),
                    UIMessagePart.Text(text: text, metadata: nil),
                ],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: finished ? chatNowLocalDateTime() : nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        // 流式期：推理进行中（未收口）+ 固定正文前缀回放。
        let baseMessages = fixture.model.messages
        for prefix in iosChatScriptedTextPrefixes(finalText, chunkCount: 16) {
            fixture.model.messages = baseMessages + [assistantMessage(
                text: prefix,
                reasoningFinished: false,
                finished: false
            )]
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }

        // stream-closed：全文就位但推理仍未收口（生成最后一刻才停止思考的真实形态），
        // 让收起发生在终态采样窗口内，验证收起瞬间视口逐帧钉底。
        let closedTarget = fixture.model.messages.dropLast() + [assistantMessage(reasoningFinished: false, finished: true)]
        fixture.model.messages = Array(closedTarget)
        fixture.model.send(.assistantStreamClosed)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected an attached scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            guard let paragraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
                return false
            }
            return ScrollFrameProbe.streamingTextLength(in: paragraph) == finalText.utf16.count
        })

        // 终态：推理 finishedAt 落地 + run 结束 → 推理卡无动画收起（高度收缩）。
        let terminal = fixture.model.messages.dropLast() + [assistantMessage(reasoningFinished: true, finished: true)]
        fixture.model.messages = Array(terminal)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        // 留足窗口让负载下的晚到二 pass 布局落地再采尾段。
        pump(seconds: 2.0)
        probe.stop()

        let terminalSamples = probe.samples.filter {
            $0.paragraphLength == finalText.utf16.count
        }
        XCTAssertFalse(terminalSamples.isEmpty, "终态门禁必须真实采到最终正文")

        if let first = terminalSamples.first, let last = terminalSamples.last {
            XCTAssertLessThan(
                last.contentHeight,
                first.contentHeight,
                "推理卡终态收起必须真实收缩内容高度，否则本用例没有覆盖到目标路径"
            )
        }

        // 逐帧钉底：contentHeight − offsetY 即视口可见高度，贴底时恒为常数。
        // 缓动病灶的签名是大幅持续漂移（本用例收缩 169pt，缓动会让漂移逼近该量级
        // 并持续 150ms+）；collection 两 pass 布局的帧间残差只是小量一次性尖峰，
        // 用「全窗口上限 + 尾段严格钉底」两级断言区分这两种形态。
        let anchors = terminalSamples.map { $0.contentHeight - $0.contentOffsetY }
        // 基准取收敛后的锚点：窗口开头允许存在尚未重锚定的过渡帧
        // （snap 会在几帧内把它们拉回底部），断言针对「是否收敛并钉住」。
        let settledAnchor = anchors.last ?? 0

        let maximumAnchorDrift = anchors.map { abs($0 - settledAnchor) }.max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumAnchorDrift,
            25.0,
            "终态窗口不允许缓动级漂移（两 pass 布局残差应远小于此）：\(maximumAnchorDrift)"
        )

        // 尾段严格钉底：过渡尖峰必须收敛，不允许持续漂移。
        let tailLength = max(terminalSamples.count * 2 / 5, 3)
        let tailAnchors = Array(anchors.suffix(tailLength))
        let tailDrift = tailAnchors.map { abs($0 - settledAnchor) }.max() ?? 0
        XCTAssertLessThanOrEqual(
            tailDrift,
            2.0,
            "终态尾段视口必须逐帧钉在底部：\(tailDrift)"
        )
        // 单调收敛：尾段 offset 只允许朝新底部移动（收缩场景下非增），任何超过
        // 1pt 的反向回升都是两段式运动/回跳。
        let tailOffsets = terminalSamples.suffix(tailLength).map(\.contentOffsetY)
        let maximumBackjump = zip(tailOffsets.dropFirst(), tailOffsets)
            .map { next, previous in next - previous }
            .max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumBackjump,
            1.0,
            "终态尾段视口不得先向旧目标移动再纠正：\(maximumBackjump)"
        )
        XCTAssertTrue(
            fixture.model.latestViewport.isAtBottom,
            "终态收敛后必须贴底"
        )
    }

    func testUnitFadeDurationScalesContinuouslyWithAppendedBeatSize() {
        XCTAssertEqual(ParagraphUIView.unitFadeDuration(forAppendedLength: 0), 0.5)
        XCTAssertEqual(ParagraphUIView.unitFadeDuration(forAppendedLength: 12), 0.5)
        XCTAssertEqual(
            ParagraphUIView.unitFadeDuration(forAppendedLength: 36),
            0.5 * 12.0 / 36.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ParagraphUIView.unitFadeDuration(forAppendedLength: 600),
            1.0 / 30.0,
            "600 字大拍已触地板（0.5×12/600 < 1/30）"
        )
        XCTAssertEqual(
            ParagraphUIView.unitFadeDuration(forAppendedLength: 1_536),
            1.0 / 30.0,
            "超大拍淡入时长钳制在一帧级别，不拖长渐变尾巴"
        )
    }

    func testGenerationEndSettleConvergesAfterLateLayout() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 4)
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        fixture.model.messages.append(makeUserMessage("给我一个含表格的长回答。"))
        fixture.model.isGenerationActive = true
        fixture.model.send(.userAppend)
        pump(seconds: 0.2)

        // 含表格的尾部内容:完成后 vendor 的最终解析(节流 120-320ms)会带来
        // 晚于 terminal signal 的 contentHeight 变化,正是 settle 窗口要承接的。
        let assistantId = KotlinUuid.companion.random()
        var tailText = "## 结论\n\n先给出对比表格:\n\n| 方案 | 机制 | 结论 |\n|---|---|---|\n"
        for index in 0..<12 {
            tailText += "| 方案\(index) | 几何驱动到点补偿的机制描述第 \(index) 行 | 采纳与否的详细结论说明 |\n"
            let tail = makeAssistantMessage(id: assistantId, text: tailText, finished: false)
            if fixture.model.messages.last?.role == MessageRole.assistant {
                fixture.model.messages[fixture.model.messages.count - 1] = tail
            } else {
                fixture.model.messages.append(tail)
            }
            fixture.model.send(.streamDelta)
            pump(seconds: 0.04)
        }

        fixture.model.messages[fixture.model.messages.count - 1] =
            makeAssistantMessage(id: assistantId, text: tailText, finished: true)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)

        // 让 terminal signal 建立 settle 窗口，但保持在 0.4s quiet-window 内。
        pump(seconds: 0.1)
        let heightBeforeLateGrowth = fixture.scrollView?.contentSize.height ?? 0

        // 模拟 terminal 后 renderer/附件晚到的真实布局增长。settingsRefresh 只触发
        // view 刷新，不发滚动命令，也不会重启 settle，因此只有 measured-growth
        // follow 能承接这次增长。
        var lateText = tailText
        for index in 12..<22 {
            lateText += "| 方案\(index) | terminal 后到达的布局内容第 \(index) 行 | settle 必须继续贴底 |\n"
        }
        fixture.model.messages[fixture.model.messages.count - 1] =
            makeAssistantMessage(id: assistantId, text: lateText, finished: true)
        fixture.model.send(.settingsRefresh)

        let didObserveGrowthAndSettle = pumpUntil(timeout: 4.0) {
            guard let scrollView = fixture.scrollView else { return false }
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
                scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(0, scrollView.contentSize.height - visibleBottom)
            return scrollView.contentSize.height > heightBeforeLateGrowth + 0.5 &&
                distanceToBottom <= ChatLayout.bottomStickThreshold &&
                fixture.model.latestViewport.isAtBottom
        }
        XCTAssertTrue(didObserveGrowthAndSettle, "完成后的真实高度增长必须被 terminal settle 承接")

        // 等 quiet-window/绝对上限结束后再验一次，避免只命中中间态。
        pump(seconds: 1.05)
        XCTAssertTrue(fixture.model.latestViewport.isAtBottom, "terminal settle 收尾后必须仍在底部")
    }

    func testTerminalBeforeFirstAttachSettlesThenReleasesBottomOwnership() {
        let assistantID = KotlinUuid.companion.random()
        var initialMessages = longConversation(turns: 6)
        initialMessages.append(makeUserMessage("请验证首帧前已经完成的回复。"))
        initialMessages.append(makeAssistantMessage(
            id: assistantID,
            text: "首帧挂载前已经完成。",
            finished: true
        ))
        let fixture = makeFixture { model in
            model.messages = initialMessages
            model.signal = ChatMessageUpdateSignal(revision: 1, reason: .generationCompleted)
        }
        defer { fixture.tearDown() }

        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })
        pump(seconds: 0.8)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let historyOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentOffset.y - 420
        )
        scrollView.setContentOffset(CGPoint(x: 0, y: historyOffset), animated: false)
        pump(seconds: 0.15)
        XCTAssertEqual(scrollView.contentOffset.y, historyOffset, accuracy: 2)
        let heightBeforeLateGrowth = scrollView.contentSize.height

        var lateText = "首帧挂载前已经完成。\n\n"
        for index in 0..<35 {
            lateText += "挂载后迟到布局第 \(index) 段：终态窗口结束后不能重新抢回底部。\n\n"
        }
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: lateText,
            finished: true
        )
        fixture.model.send(.settingsRefresh)

        XCTAssertTrue(pumpUntil(timeout: 3.0) {
            scrollView.contentSize.height > heightBeforeLateGrowth + 0.5
        }, "测试必须实际观察到终态后的迟到高度增长")
        pump(seconds: 0.5)
        XCTAssertEqual(
            scrollView.contentOffset.y,
            historyOffset,
            accuracy: 2,
            "终态早于首帧 attach 时，settle 结束后也必须交还历史浏览位置"
        )
    }

    func testEveryGenerationTerminalReleasesBottomOwnershipAfterLateLayoutSettle() {
        let terminalReasons: [ChatMessageUpdateReason] = [
            .generationCompleted,
            .generationFailed,
            .generationCancelled,
            .generationHandedOffToBackground
        ]

        func assertTerminalReleases(_ terminalReason: ChatMessageUpdateReason) {
            let fixture = makeFixture()
            defer { fixture.tearDown() }

            fixture.model.messages = longConversation(turns: 6)
            fixture.model.messages.append(makeUserMessage("请生成一段终态测试正文。"))
            let assistantID = KotlinUuid.companion.random()
            fixture.model.messages.append(makeAssistantMessage(
                id: assistantID,
                text: "终态前正文。",
                finished: false
            ))
            fixture.model.isGenerationActive = true
            fixture.model.send(.streamDelta)
            pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: "终态前正文。",
                finished: true
            )
            fixture.model.isGenerationActive = false
            fixture.model.send(terminalReason)
            pump(seconds: 0.75)

            guard let scrollView = fixture.scrollView else {
                return XCTFail("Expected the default Native timeline scroll view")
            }
            scrollView.setContentOffset(
                CGPoint(x: 0, y: max(
                    -scrollView.adjustedContentInset.top,
                    scrollView.contentOffset.y - 420
                )),
                animated: false
            )
            pump(seconds: 0.15)
            let historyOffset = scrollView.contentOffset.y
            let heightBeforeLateGrowth = scrollView.contentSize.height

            var lateText = "终态前正文。\n\n"
            for index in 0..<35 {
                lateText += "终态后布局第 \(index) 段：仅改变真实内容高度，不能重新取得滚动所有权。\n\n"
            }
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: lateText,
                finished: true
            )
            fixture.model.send(.settingsRefresh)
            XCTAssertTrue(pumpUntil(timeout: 3.0) {
                scrollView.contentSize.height > heightBeforeLateGrowth + 0.5
            }, "\(terminalReason) 必须实际观察到终态后的迟到高度增长")
            pump(seconds: 0.5)

            XCTAssertEqual(
                scrollView.contentOffset.y,
                historyOffset,
                accuracy: 2,
                "\(terminalReason) settle 结束后，迟到布局不能把历史浏览位置拉回底部"
            )
        }

        for terminalReason in terminalReasons {
            assertTerminalReleases(terminalReason)
        }
    }
}
