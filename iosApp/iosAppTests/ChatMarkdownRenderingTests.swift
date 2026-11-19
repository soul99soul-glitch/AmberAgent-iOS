import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMarkdownRenderingTests: ChatMessageProjectionTestCase {
    private final class TextEditRecorder: NSObject, NSTextStorageDelegate {
        var attributeEdits = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
        }
    }

    func testNativeStreamingFadeDoesNotEditTextStorageEveryDisplayFrame() {
        let view = ParagraphUIView.makeTextKit1View()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.red]
        view.setParagraphContents(NSMutableAttributedString(string: "已有文字", attributes: style), animatedByWord: false)
        view.setParagraphContents(NSMutableAttributedString(string: "已有文字 新增文字", attributes: style),
                                  animatedByWord: true, appendsTailFadeAsUnit: true)
        XCTAssertFalse(view.activeAnimations.isEmpty, "保留可见的尾段淡入")
        XCTAssertEqual(view.fadeFrameRateForTesting?.preferred, 120)
        let recorder = TextEditRecorder()
        view.textStorage.delegate = recorder
        defer { view.textStorage.delegate = nil; view.resetForReuse() }
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(recorder.attributeEdits, 0,
                       "显示帧只改变绘制透明度，不应让颜色属性编辑进入 TextKit/布局更新链")
        XCTAssertEqual(view.textStorage.string, "已有文字 新增文字")
        XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor, .red)
    }

    func testLegacyParagraphWordFadeKeepsItsExistingBehavior() {
        let view = ParagraphUIView.makeTextKit1View()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.red]
        view.setParagraphContents(NSMutableAttributedString(string: "existing", attributes: style), animatedByWord: false)
        view.setParagraphContents(NSMutableAttributedString(string: "existing next words", attributes: style), animatedByWord: true)
        XCTAssertFalse(view.activeAnimations.isEmpty)
        let recorder = TextEditRecorder()
        view.textStorage.delegate = recorder
        defer { view.textStorage.delegate = nil; view.resetForReuse() }
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        _ = view.perform(NSSelectorFromString("updateFadeAnimation"))
        XCTAssertGreaterThan(recorder.attributeEdits, 0, "未显式启用尾段模式的 vendor 行为保持不变")
        XCTAssertEqual(view.fadeFrameRateForTesting?.preferred, 60)
    }

    func testGlyphOpacityActuallyFadesWithoutChangingTextOrColor() throws {
        let contents = NSAttributedString(string: "office 字形", attributes: [
            .font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.red])
        let storage = NSTextStorage(attributedString: contents)
        let manager = ParagraphFadeLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 80))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let glyphs = manager.glyphRange(for: container)
        // Initial TextKit layout resolves script-specific font fallback. Fading
        // must preserve the content and attributes after that normal layout.
        let laidOutContents = NSAttributedString(attributedString: storage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 80), format: format)
        let blank = try XCTUnwrap(renderer.image { _ in }.pngData())
        func rendered(_ alpha: CGFloat) throws -> Data {
            manager.setOpacityRanges([.init(range: NSRange(location: 0, length: storage.length), alpha: alpha)])
            return try XCTUnwrap(renderer.image { _ in
                manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            }.pngData())
        }
        let visible = try rendered(1)
        let invisible = try rendered(0)
        let half = try rendered(0.5)
        XCTAssertNotEqual(visible, blank)
        XCTAssertEqual(invisible, blank)
        XCTAssertNotEqual(half, blank)
        XCTAssertNotEqual(half, visible)
        XCTAssertEqual(NSAttributedString(attributedString: storage), laidOutContents)
    }


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

    func testTextKit1ParagraphKeepsItsProposedColumnWidthWhileAppending() throws {
        let width: CGFloat = 337.3
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        func root(_ text: String) -> some View {
            ParagraphView(contents: NSMutableAttributedString(string: text,
                attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]),
                lineSpacing: 4, usesTextKit1: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: width)
        }
        let host = UIHostingController(rootView: root("短句"))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        func paragraph(in view: UIView) -> ParagraphUIView? {
            if let paragraph = view as? ParagraphUIView { return paragraph }
            return view.subviews.lazy.compactMap { paragraph(in: $0) }.first
        }
        for text in ["短句", "短句继续增长", String(repeating: "长正文保持列宽，不跟随字宽来回排版。", count: 12)] {
            host.rootView = root(text)
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let view = try XCTUnwrap(paragraph(in: host.view))
            XCTAssertEqual(view.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(view.text, text)
        }
    }

    func testTextKit1SameLineAppendDoesNotInvalidateIntrinsicSize() {
        let view = ParagraphUIView.makeTextKit1View()
        view.frame = CGRect(x: 0, y: 0, width: 337.3, height: 21)
        let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
        view.setParagraphContents(NSMutableAttributedString(string: "短", attributes: style), animatedByWord: false)
        view.layoutIfNeeded()
        let before = view.sizeThatFits(CGSize(width: 337.3, height: .greatestFiniteMagnitude))
        let previousProbe = ParagraphUIViewLiveProbe.onRecord
        var invalidations = 0
        ParagraphUIViewLiveProbe.onRecord = { if $0 == "para-intrinsic-invalidate" { invalidations += 1 } }
        defer { ParagraphUIViewLiveProbe.onRecord = previousProbe; view.resetForReuse() }
        view.setParagraphContents(NSMutableAttributedString(string: "短句", attributes: style), animatedByWord: false)
        XCTAssertEqual(view.sizeThatFits(CGSize(width: 337.3, height: .greatestFiniteMagnitude)).height, before.height)
        XCTAssertEqual(invalidations, 0, "列宽固定且没有换行时，追加字宽不应让 SwiftUI 重新测量整行")
        XCTAssertEqual(view.text, "短句")
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

    func testRenderableDocumentReusesUnchangedListItemPrefixObjects() async {
        let parser = MarkdownParserImpl()
        let initial = await parser.parse(text: "1. First item\n2. Second item")
        let updated = await parser.parse(text: "1. First item\n2. Second item grows")
        let initialRenderable = await RenderableDocument(document: initial, config: .default)
        let converted = await RenderableDocument(document: updated, config: .default)
        let updatedRenderable = converted.reusingUnchangedPrefix(from: initialRenderable)

        guard case let .orderedList(_, initialItems) = initialRenderable.renderables[0],
              case let .orderedList(_, updatedItems) = updatedRenderable.renderables[0],
              case let .paragraph(_, initialFirst) = initialItems[0].children[0],
              case let .paragraph(_, updatedFirst) = updatedItems[0].children[0],
              case let .paragraph(_, initialSecond) = initialItems[1].children[0],
              case let .paragraph(_, updatedSecond) = updatedItems[1].children[0] else {
            return XCTFail("Expected ordered list with two paragraph items")
        }

        XCTAssertTrue(initialFirst === updatedFirst)
        XCTAssertFalse(initialSecond === updatedSecond)
        XCTAssertEqual(updatedSecond.string, "Second item grows")
    }

    func testTailDrainKeepsStreamingModeAndSingleFlightSerialParseWithoutCancellingInFlightWork() async throws {
        let renderedText = await ChatStableStreamingMarkdownControllerTestSupport
            .renderedTextAfterRapidNonAnimatedPrefixBurst()
        var expectedText = "尾段排空起点"
        for step in 1...12 {
            expectedText += "，第\(step)拍增量"
        }
        XCTAssertEqual(renderedText, expectedText)

        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testDirectory.deletingLastPathComponent()
        let bubbleSource = try String(
            contentsOf: repoRoot.appendingPathComponent("iosApp/Chat/Message/MessageBubbleView.swift"),
            encoding: .utf8
        )
        let blocksSource = try String(
            contentsOf: repoRoot.appendingPathComponent("iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownBlocks.swift"),
            encoding: .utf8
        )
        let stableSource = try String(
            contentsOf: repoRoot.appendingPathComponent("iosApp/Chat/Rendering/Markdown/ChatStableStreamingMarkdown.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            bubbleSource.contains("isStreaming: (isGenerating && isLastMessage) || isPacingReveal"),
            "ChatStreamingRevealPacer 尾段排空期间必须继续向 ChatAssistantMarkdownView 传递流式态。"
        )
        XCTAssertTrue(
            blocksSource.contains("textBlock(revealedText, id: block.id, isPacingReveal: isPacingReveal)"),
            "分段渲染器的内层 pacer 在尾段排空期间必须继续保持动画与增量解析节流。"
        )
        XCTAssertTrue(
            stableSource.contains("throttleSleepTask?.cancel()"),
            "切换完成态只应唤醒节流 sleep，不能取消正在执行的 parseNow 任务导致尾段解析饥饿。"
        )
    }
}
