import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMarkdownRenderingTests: ChatMessageProjectionTestCase {

    func testFrozenMarkdownSnapshotUsesTheSingleNonEmptyTextPartVerbatim() {
        let messageID = KotlinUuid.companion.random()
        let message = UIMessage(
            id: messageID,
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "", metadata: nil),
                UIMessagePart.Text(text: "正文", metadata: nil),
            ],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )

        XCTAssertEqual(message.singleNonEmptyTextPart, "正文")

        let multipleTextParts = UIMessage(
            id: messageID,
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "第一段", metadata: nil),
                UIMessagePart.Text(text: "第二段", metadata: nil),
            ],
            annotations: [],
            createdAt: message.createdAt,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        XCTAssertNil(multipleTextParts.singleNonEmptyTextPart)
    }

    func testPackedAstReaderParsesBlockMathNode() throws {
        let markdown = "$$E=mc^2$$"
        let node = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: markdown)))

        XCTAssertEqual(Self.slice(markdown, node: node), "$$E=mc^2$$")
    }

    func testBlockMathLatexExtraction() throws {
        let inline = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: "$$E=mc^2$$")))
        XCTAssertEqual(AmberMarkdownMath.blockLatex(from: inline, source: "$$E=mc^2$$"), "E=mc^2")

        let multilineMarkdown = """
        $$
          a^2 + b^2 = c^2
        $$
        """
        let multiline = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: multilineMarkdown)))
        XCTAssertEqual(AmberMarkdownMath.blockLatex(from: multiline, source: multilineMarkdown), "a^2 + b^2 = c^2")
    }

    func testKnownGap_B3b_inlineMathRendersAsLiteralText() throws {
        // B3b 实现时本测试应转红并被替换为真渲染断言；设计见 IOS_FIX_PLAN_2026-07-08.md B3b。
        let markdown = "inline $x^2$ math"
        let node = try XCTUnwrap(Self.firstNode(ofType: .mathInline, in: Self.astNodes(for: markdown)))

        XCTAssertEqual(Self.slice(markdown, node: node), "$x^2$")
    }

    func testTableCellFadeInPolicyDoesNotDisableVisibleAnimationForLargeTables() {
        XCTAssertTrue(
            TableViewAnimationPolicy.shouldAnimateCellText(
                configShouldAnimateText: true,
                headingCount: 4,
                rowCount: 8,
                characterCount: 120
            )
        )
    }

    func testTableStreamingThrottleTiersOnlySlowDownHugeTables() {
        // 直播解析限频档位不变（对大表降频止血）；表格尾块发布间隔改为
        // 连续曲线（0.09 + 0.13×(1−e^(−L/4000))，2026-08-15 取代四档）：
        // 锚点行为等价（与旧档偏差 <12ms），但无档位边界断点。
        let live = ChatStreamingMarkdownThrottleTestSupport.liveParseInterval
        XCTAssertEqual(live(800, true), 0.12)
        XCTAssertEqual(live(3_000, true), 0.20)
        XCTAssertEqual(live(10_000, true), 0.32)
        XCTAssertEqual(live(24_000, true), 0.5)
        XCTAssertEqual(live(24_000, false), 0, "普通文本不在此加独立定时门")

        let publish = ChatStreamingMarkdownThrottleTestSupport.blockPublishInterval
        XCTAssertEqual(publish(800, true), 0.09 + 0.13 * (1 - exp(-800.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(3_000, true), 0.09 + 0.13 * (1 - exp(-3_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(10_000, true), 0.09 + 0.13 * (1 - exp(-10_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(24_000, true), 0.09 + 0.13 * (1 - exp(-24_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(24_000, false), 0)
        // 连续性契约：旧档位边界（1.2k/4k/12k）两侧的间隔差 <1ms，无档位跳变。
        let belowBoundary = publish(1_200, true)
        let aboveBoundary = publish(1_201, true)
        XCTAssertLessThan(abs(belowBoundary - aboveBoundary), 0.001)
    }

    func testStreamingMarkdownConfigCacheKeyTracksPaperAndAccent() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Rendering/Markdown/ChatAssistantMarkdownView.swift"),
            encoding: .utf8
        )
        let cache = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownDetection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(cache.contains("let themePaper: String"))
        XCTAssertTrue(cache.contains("let themeAccentHex: UInt32"))
        XCTAssertTrue(source.contains("themePaper: AmberThemeRuntime.shared.paper.rawValue"))
        XCTAssertTrue(source.contains("themeAccentHex: AmberThemeRuntime.shared.accentHex"))
        XCTAssertEqual(
            ChatStreamingMarkdownConfigCacheTestSupport.buildCount(themeKeys: [
                (paper: "paper", accentHex: 0xB8623A),
                (paper: "paper", accentHex: 0xB8623A),
                (paper: "neutral", accentHex: 0xB8623A),
                (paper: "neutral", accentHex: 0x5E9C6E),
            ]),
            3,
            "相同主题必须命中缓存，paper/accent 任一变化必须重建 config"
        )
    }

    func testStreamingBlockParserKeepsHeadingContextInOneMarkdownDocument() {
        let markdown = """
        [文档][reference]

        # 标题

        [reference]: https://example.com

        <script>
        # 这不是 Markdown 标题
        </script>
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: true
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "text")
        XCTAssertEqual(blocks.first?.text, markdown)
    }

    func testStreamingBlockParserKeepsPartialHashAppendInOneTextBlock() {
        let prefix = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: "正文\n\n#",
            includeTrailingPartialTableRow: false
        )
        let completed = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: "正文\n\n#tag",
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(prefix.count, 1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(prefix.first?.kind, "text")
        XCTAssertEqual(completed.first?.kind, "text")
    }

    func testTextKit1LongParagraphMeasuresEachAppendAtLineGranularity() {
        let width: CGFloat = 337.3
        let view = ParagraphUIView.makeTextKit1View()
        view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        XCTAssertTrue(view.usesTextKit1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.label
        ]
        var text = "连续正文开始。" + String(
            repeating: "这是一段没有空行分隔的长篇连续正文，用来复现真实回答累计变长后同一段落仍在增长的布局压力。",
            count: 180
        )
        func contents() -> NSMutableAttributedString {
            NSMutableAttributedString(string: text, attributes: attributes)
        }

        view.setParagraphContents(contents(), lineSpacing: 4, animatedByWord: false)
        var measuredHeight = view.sizeThatFits(CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        )).height
        view.frame.size.height = measuredHeight
        var positiveGrowth: [CGFloat] = []

        for _ in 0..<60 {
            text += String(repeating: "流", count: 12)
            view.setParagraphContents(contents(), lineSpacing: 4, animatedByWord: false)
            let nextHeight = view.sizeThatFits(CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            )).height
            if nextHeight > measuredHeight + 0.5 {
                positiveGrowth.append(nextHeight - measuredHeight)
            }
            measuredHeight = nextHeight
            view.frame.size.height = nextHeight
        }

        XCTAssertGreaterThanOrEqual(positiveGrowth.count, 30)
        XCTAssertLessThanOrEqual(positiveGrowth.max() ?? .greatestFiniteMagnitude, 26)
    }

    func testStreamingTableParserDoesNotLeakTrimmedTrailingRowAsPipeText() {
        let markdown = """
        | 阶段 | 能力 |
        | --- | --- |
        | 初觉 | 雷感 |
        | 一劫雷 | 掌心
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        // 行为契约变更（2026-08-15）：含管道的尾行流式期立即渲染为部分行，
        // 不再「只消费不渲染」——完成瞬间尾行成批出现即「完成后排版重排」。
        XCTAssertEqual(blocks.first?.rows, [["初觉", "雷感"], ["一劫雷", "掌心"]])
        XCTAssertFalse(blocks.contains { $0.kind == "text" && $0.text.contains("|") })
    }

    func testStreamingTableParserKeepsSinglePartialRowAsEmptyTableBlock() {
        let markdown = """
        | 层次 | 说明 |
        | --- | --- |
        | 人间界 | 现代都市
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.headers, ["层次", "说明"])
        // 行为契约变更（2026-08-15）：含管道的尾行流式期立即渲染为部分行，
        // 不再「只消费不渲染」——完成瞬间尾行成批出现即「完成后排版重排」。
        XCTAssertEqual(blocks.first?.rows, [["人间界", "现代都市"]])
        XCTAssertFalse(blocks.contains { $0.kind == "text" && $0.text.contains("|") })
    }

    func testStreamingTableParserHidesNoLeadingPipePartialRow() {
        let markdown = """
        名称 | 数值
        --- | ---
        Alpha | 1
        Bet
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.rows, [["Alpha", "1"]])
    }

    func testStreamingTableDetectorMatchesAcceptedSyntaxAndIgnoresFences() {
        XCTAssertTrue(ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: """
        名称 | 数值
        --- | ---
        Alpha | 1
        """))
        XCTAssertFalse(ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: """
        ~~~markdown
        ```not-a-closing-fence
        | 名称 | 数值 |
        | --- | --- |
        ~~~
        """))
    }

    func testStreamingTableDetectorConsumesOnlyAppendedUTF8AcrossDeltas() {
        let chunks = [
            "普通文本",
            "继续增长",
            "\n名称 | 数值",
            "\n---",
            " | ---"
        ]
        var text = ""
        let prefixes = chunks.map { chunk -> String in
            text += chunk
            return text
        }

        let result = ChatStreamingTableDetectionTestSupport.replay(prefixes)

        XCTAssertTrue(result.containsTable)
        XCTAssertEqual(result.consumedUTF8Count, text.utf8.count)
    }

    func testIncrementalStreamingTableDetectorKeepsFenceStateAcrossDeltas() {
        let prefixes = [
            "~~~markdown\n",
            "~~~markdown\n| 名称 | 数值 |\n",
            "~~~markdown\n| 名称 | 数值 |\n| --- | --- |"
        ]

        XCTAssertFalse(ChatStreamingTableDetectionTestSupport.replay(prefixes).containsTable)
    }

    func testStreamingTableRowCacheReusesCompletedRowsAcrossDeltas() {
        ChatStreamingMarkdownBlockParserTestSupport.resetRowCache()
        let prefix = """
        | 名称 | 数值 |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |
        """
        _ = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: prefix,
            includeTrailingPartialTableRow: false
        )
        let firstMetrics = ChatStreamingMarkdownBlockParserTestSupport.rowCacheMetrics

        _ = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: prefix + "\n| Gamma | 3",
            includeTrailingPartialTableRow: false
        )
        let secondMetrics = ChatStreamingMarkdownBlockParserTestSupport.rowCacheMetrics

        XCTAssertGreaterThan(firstMetrics.misses, 0)
        XCTAssertGreaterThan(secondMetrics.hits, firstMetrics.hits)
    }

    func testProductionStreamingTableBlocksDoNotMaterializeUnusedCellModels() {
        let markdown = """
        | 名称 | 数值 |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |
        """

        let counts = ChatStreamingMarkdownBlockParserTestSupport.productionTableCellCounts(in: markdown)

        XCTAssertEqual(counts?.headers, 0)
        XCTAssertEqual(counts?.rows, 0)
    }

    func testStreamingTableBlockPreservesEscapedPipeForRealMarkdownRenderer() {
        let markdown = """
        | 表达式 | 含义 |
        | --- | --- |
        | `a \\| b` | escaped pipe |
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: true
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.rows, [["`a | b`", "escaped pipe"]])
        XCTAssertEqual(blocks.first?.markdown, markdown)
    }

    func testStreamingTableBlockUsesVendorMarkdownRendererAndAsyncBlockController() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownBlocks.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("text: table.markdown,"))
        XCTAssertTrue(source.contains("cacheIdentity: renderCacheNamespace.map"))
        XCTAssertTrue(source.contains("final class ChatStreamingMarkdownBlockController"))
        XCTAssertTrue(source.contains("Task.detached(priority: .userInitiated)"))

        let controllerSource = source
            .components(separatedBy: "final class ChatStreamingMarkdownBlockController")
            .last?
            .components(separatedBy: "struct ChatStreamingMarkdownBlock:")
            .first ?? ""
        XCTAssertTrue(controllerSource.contains("publishPreservingSettledBlocks(parsed)"))
        XCTAssertFalse(
            controllerSource.contains("if pendingParse == nil"),
            "Continuous deltas must not starve every completed block parse publication."
        )
    }

    func testCompletedMarkdownRenderableCacheReusesSpeculativeStreamingEntry() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        let markdown = """
        | 层次 | 说明 |
        | --- | --- |
        | 人间界 |
        """

        ChatStableStreamingMarkdownCacheTestSupport.store(text: markdown, animate: true)

        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: markdown, animate: false),
            "完成切换瞬间必须能复用流式期已格式化的同一文本渲染产物（原子替换前不退回原文）"
        )
    }

    func testCompletedMarkdownRenderableCacheUsesPrefixFallbackAcrossSpeculativeFlip() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        let prefix = "第一段已经解析"
        let completedText = "\(prefix)\n第二段完成态新增内容"

        ChatStableStreamingMarkdownCacheTestSupport.store(text: prefix, animate: true)

        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: completedText, animate: true)
        )
        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: completedText, animate: false),
            "完成切换瞬间必须持续显示已格式化的前缀渲染（stale-prefix 跨 speculative 翻转），"
                + "不能退回未渲染的 markdown 原文"
        )
    }

    func testIdentityCacheRetainsEnoughCompletedParagraphsToSuppressRemountFade() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        // 长篇(小说/长对话)可有上百个段落 block。完成态重挂载/回滚时,只要 identity
        // 缓存还持有该段落的 renderable,resolution 就返回 suppressesInitialFade=true,
        // 不再重新淡入。旧上限 64 会让靠前的段落被后续解析挤出 → 完成瞬间整屏重新淡入
        // (闪烁);提到 256 后,第 0 段在缓存了 100 段之后必须仍可解析。
        let paragraphCount = 100
        for index in 0..<paragraphCount {
            ChatStableStreamingMarkdownCacheTestSupport.storeIdentity(
                identity: "block-\(index)",
                text: "paragraph \(index)",
                animate: false
            )
        }
        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedIdentity(
                identity: "block-0",
                text: "paragraph 0",
                animate: false
            ),
            "identity 缓存应至少容纳 100 个完成段落,否则已完成段落被挤出,完成/回滚时重新淡入闪烁。"
        )
    }

    func testStableStreamingMarkdownControllerResumesAnimatedParsingAfterNonAnimatedParseCompletes() async {
        let renderedText = await ChatStableStreamingMarkdownControllerTestSupport
            .renderedTextAfterNonAnimatedThenAnimatedParse()

        XCTAssertEqual(renderedText, "initial completed text with live delta")
    }

    func testStableStreamingMarkdownControllerQueuesAnimatedDeltaDuringNonAnimatedParse() async {
        let renderedText = await ChatStableStreamingMarkdownControllerTestSupport
            .renderedTextWhenAnimatedParseArrivesDuringNonAnimatedParse()

        XCTAssertEqual(renderedText, "non-animated parse followed immediately by live delta")
    }

    func testStableStreamingMarkdownControllerReusesOnlyGrowingPrefixRenderable() {
        XCTAssertTrue(
            ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
                renderedText: "已解析前缀",
                requestedText: "已解析前缀继续增长"
            )
        )
        XCTAssertFalse(
            ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
                renderedText: "正文\n| 表头 | 数值 |",
                requestedText: "正文"
            ),
            "表格拆块使文本收缩时不能继续显示包含表头的旧 renderable"
        )
    }

    func testStreamingTableKeepsRenderedSnapshotWhilePaddedTailCellChanges() throws {
        let source = "| 方案 | 说明 |\n| --- | --- |\n| A | 简短 |\n| 新"
        let before = try XCTUnwrap(ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: source, includeTrailingPartialTableRow: false
        ).first { $0.kind == "table" }).markdown
        let after = try XCTUnwrap(ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: source + "方案", includeTrailingPartialTableRow: false
        ).first { $0.kind == "table" }).markdown
        XCTAssertFalse(after.hasPrefix(before), "补出的尾行管道符会被下一拍改写")
        XCTAssertTrue(ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
            renderedText: before,
            requestedText: after,
            preservesRenderedTable: true
        ), "同一表格的新解析就绪前必须保留旧表格，不能退回管道原文导致高度跳变")
    }

    func testStableStreamingMarkdownControllerKeepsInstanceRenderableAcrossCompletionParse() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .instanceResolutionAfterSpeculativeModeChange()

        XCTAssertTrue(resolution.hasRenderable, "完成态解析落地前应保留同一文本的已渲染内容，不能退回纯文本。")
        XCTAssertTrue(resolution.suppressesInitialFade, "完成态复用已有内容时不能让整段文字重新淡入。")
    }

    func testStableStreamingMarkdownControllerKeepsIdentityRenderableAcrossColdCompletion() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .coldCompletionIdentityResolution()

        XCTAssertTrue(resolution.hasRenderable, "完成瞬间发生视图重建时也不能退回纯文本。")
        XCTAssertTrue(resolution.suppressesInitialFade, "冷完成复用已有内容时不能让整段文字重新淡入。")
    }

    func testStableStreamingMarkdownControllerKeepsSpeculativeRenderableForUnclosedMarkupAtCompletion() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .instanceResolutionAfterSpeculativeModeChangeWithUnclosedMarkup()

        XCTAssertTrue(
            resolution.hasRenderable,
            "中断/超时使文本停在未闭合语法时，完成态仍复用流式 renderable 保持连续，随后由立即重解析纠正。"
        )
        XCTAssertTrue(
            resolution.suppressesInitialFade,
            "跨模式复用未闭合内容时同样不能让整段文字重新淡入。"
        )
    }

    func testRenderableDocumentReusesOnlyUnchangedPrefixObjects() async {
        let parser = MarkdownParserImpl()
        let initial = await parser.parse(text: "First paragraph.\n\nSecond paragraph.")
        let updated = await parser.parse(text: "First paragraph.\n\nSecond paragraph grows.")
        let initialRenderable = await RenderableDocument(document: initial, config: .default)
        let converted = await RenderableDocument(document: updated, config: .default)
        let updatedRenderable = converted.reusingUnchangedPrefix(from: initialRenderable)

        guard case let .paragraph(_, initialFirst) = initialRenderable.renderables[0],
              case let .paragraph(_, updatedFirst) = updatedRenderable.renderables[0],
              case let .paragraph(_, initialSecond) = initialRenderable.renderables[1],
              case let .paragraph(_, updatedSecond) = updatedRenderable.renderables[1] else {
            return XCTFail("Expected two paragraphs")
        }

        XCTAssertTrue(initialFirst === updatedFirst)
        XCTAssertFalse(initialSecond === updatedSecond)
        XCTAssertEqual(updatedSecond.string, "Second paragraph grows.")
    }

    func testStableStreamingMarkdownControllerRejectsInstanceRenderableAcrossVisualConfigChange() {
        XCTAssertFalse(
            ChatStableStreamingMarkdownControllerTestSupport
                .hasInstanceRenderableAfterVisualConfigChange(),
            "字体或排版配置变化后不能先显示旧 config renderable。"
        )
    }

    func testStableStreamingMarkdownControllerReusesIdentityPrefixOnColdReentry() {
        let result = ChatStableStreamingMarkdownControllerTestSupport
            .coldReentryIdentityPrefixResolution()

        XCTAssertTrue(result.hasRenderable, "冷重入必须复用该消息块已解析的累计前缀，而不是退回 raw Markdown。")
        XCTAssertTrue(result.suppressesInitialFade, "重建已有前缀时不能把整段内容再次从 alpha 0 淡入。")
    }

    func testStreamingTableHonorsColdReentryFadeSuppression() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let tableViewURL = testDirectory.deletingLastPathComponent()
            .appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/TableView.swift")
        let source = try String(contentsOf: tableViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@Environment(\\.markdownAnimateInitialText) var animateInitialText"))
        XCTAssertTrue(source.contains("config.shouldAnimateText && animateInitialText"))
    }

    func testCompletedStreamedMarkdownKeepsBlockTopologyAfterColdRecreation() {
        XCTAssertTrue(
            ChatStreamingMarkdownRendererPolicy.initialBlockRendererLatch(
                isStreaming: false,
                hasEverStreamed: true,
                liveRenderingEnabled: true
            ),
            "完成态流式消息回收后必须继续使用 block renderer，不能切回 monolith。"
        )
    }

    func testStreamingMarkdownTypographyFollowsChatFont() throws {
        let defaultFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .default)
        let serifFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .serif)
        let monospaceFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .monospace)

        XCTAssertNotEqual(defaultFont, serifFont)
        XCTAssertNotEqual(defaultFont, monospaceFont)
        XCTAssertNotEqual(serifFont, monospaceFont)
        XCTAssertEqual(serifFont, "NotoSerifSC-Regular")
        XCTAssertEqual(monospaceFont, "JetBrainsMono-Regular")

        let serif = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: .serif).normal
        let text = "海棠花与冰块" as CFString
        let resolved = CTFontCreateForString(serif as CTFont, text, CFRange(location: 0, length: 1))
        XCTAssertTrue((CTFontCopyPostScriptName(resolved) as String).hasPrefix("NotoSerifSC"),
                      "中文必须使用包内衬线字体，不能回退到系统字体")

        let mono = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: .monospace).normal
        XCTAssertEqual(("iii" as NSString).size(withAttributes: [.font: mono]).width,
                       ("WWW" as NSString).size(withAttributes: [.font: mono]).width, accuracy: 0.01)

        for font in [IOSChatFont.serif, .monospace] {
            let fonts = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: font)
            let bold = try XCTUnwrap(fonts.bold)
            let italic = try XCTUnwrap(fonts.italic)
            XCTAssertEqual(bold.familyName, fonts.normal.familyName)
            XCTAssertEqual(bold.pointSize, fonts.normal.pointSize)
            XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertNotEqual(CTFontGetMatrix(italic as CTFont).c, 0)
        }
    }

    func testStreamingParagraphAnimationUsesPromotionFrameRateRange() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let paragraphViewURL = testDirectory.deletingLastPathComponent()
            .appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/UIKit/ParagraphUIView.swift")
        let source = try String(contentsOf: paragraphViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("preferredFrameRateRange"))
        XCTAssertFalse(source.contains("preferredFramesPerSecond = 60"))
        XCTAssertFalse(source.contains("completedAnimations.contains"))
        XCTAssertFalse(source.contains("let id: UUID = UUID()"))
    }

    func testCheckedOutParagraphViewCannotBeIssuedTwice() {
        let contents = NSMutableAttributedString(string: "streaming paragraph")
        let first = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil
        )
        let second = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil
        )

        XCTAssertFalse(
            first === second,
            "同一个 ParagraphUIView 不能同时交给两个 SwiftUI representable"
        )

        ParagraphUIViewCache.shared.recycle(first)
        ParagraphUIViewCache.shared.recycle(second)
    }

    func testParagraphViewCacheDoesNotCrossTextLayoutEngines() {
        let contents = NSMutableAttributedString(string: "layout engine isolation")
        let textKit1 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: true
        )
        XCTAssertTrue(textKit1.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(textKit1)

        let textKit2 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: false
        )
        XCTAssertFalse(textKit2.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(textKit2)

        let reusedTextKit1 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: true
        )
        XCTAssertTrue(reusedTextKit1.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(reusedTextKit1)
    }
}
