import SwiftUI
import XCTest
@testable import iosApp

final class ChatMarkdownMediaTests: XCTestCase {
    private func parse(_ text: String, completed: Int? = nil) -> ChatMarkdownMediaPlan {
        ChatMarkdownMediaParser.parse(text, completedUTF8Count: completed ?? text.utf8.count)
    }

    func testUnicodeInlineImagesPreserveTextAndStableByteIdentity() {
        let text = "中文👨‍👩‍👧‍👦前 ![写真](https://example.com/a.png) 后日本語\n\n![두 번째](https://example.com/b.jpg)"
        let plan = parse(text)
        XCTAssertEqual(plan.segments.count, 4)
        guard case .text(let before) = plan.segments[0].kind,
              case .images(let first) = plan.segments[1].kind,
              case .text(let middle) = plan.segments[2].kind,
              case .images(let second) = plan.segments[3].kind else { return XCTFail("Unexpected media ordering") }
        XCTAssertEqual(before, "中文👨‍👩‍👧‍👦前 ")
        XCTAssertEqual(middle, " 后日本語\n\n")
        XCTAssertEqual(first[0].title, "写真")
        XCTAssertEqual(second[0].title, "두 번째")
        XCTAssertEqual(first[0].id, "markdown:image:\("中文👨‍👩‍👧‍👦前 ".utf8.count)")
        XCTAssertEqual(plan, parse(text))
    }

    func testLinkedImageConsumesOuterLinkAndPreservesSourceURL() {
        let text = "前 [![图](https://example.com/a.png)](https://example.com/article) 后"
        let plan = parse(text)
        XCTAssertEqual(plan.segments.count, 2)
        guard case .images(let items) = plan.segments.last?.kind else { return XCTFail("Missing image") }
        XCTAssertEqual(items.first?.sourceURL, "https://example.com/article")
        XCTAssertEqual(String(decoding: text.utf8.dropFirst(plan.consumedUTF8Count), as: UTF8.self), " 后")
        guard case .text(let prefix) = plan.segments.first?.kind else { return XCTFail("Missing prefix") }
        XCTAssertEqual(prefix, "前 ")
    }

    func testEmptyImageAltDoesNotExposeMarkdownAsCaption() {
        for source in ["![](https://example.com/a.png)", "[![](https://example.com/a.png)](https://example.com/article)"] {
            let plan = parse(source)
            guard case .images(let images) = plan.segments.first?.kind else { return XCTFail("Missing image") }
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images[0].title, "")
        }
    }

    func testCodeSpanInImageAltUsesCodeContentWithoutFenceSyntax() {
        for (alt, expected) in [("`value`", "value"), ("` one\ntwo `", "one two"), ("`` `value` ``", "`value`")] {
            let source = "**前 ![\(alt)](https://example.com/a.png) 后**"
            let plan = parse(source)
            guard case .text(let content) = plan.segments.first?.kind,
                  case .images(let images) = plan.segments.last?.kind else { return XCTFail("Missing code-alt image") }
            XCTAssertEqual(images[0].title, expected)
            XCTAssertFalse(content.contains("!["))
            XCTAssertFalse(content.contains("https://example.com/a.png"))
            let html = MarkdownBridge.toHtml(content) ?? ""
            XCTAssertTrue(html.contains(expected), html)
            XCTAssertFalse(html.contains("<code>"), html)
        }
    }

    func testEmptyVideoLabelUsesVideoTitleFallback() {
        let plan = parse("[](https://example.com/demo.mp4)")
        guard case .video(let video) = plan.segments.first?.kind else { return XCTFail("Missing video") }
        XCTAssertEqual(video.title, "视频")
        XCTAssertEqual(video.url, "https://example.com/demo.mp4")
    }

    func testReferenceImagesAndOrdinaryReferenceLinksRemainResolvedAcrossFragments() {
        let text = "[前链接][page] ![图][pic] [后链接][page]\n\n[pic]: https://example.com/a.png\n[page]: https://example.com/article\n"
        let plan = parse(text)
        guard case .images(let items) = plan.segments.last?.kind else { return XCTFail("Missing reference image") }
        XCTAssertEqual(items.first?.url, "https://example.com/a.png")
        XCTAssertTrue(plan.referenceContext.contains("[page]: https://example.com/article"))
        for fragment in ["[前链接][page] ", " [后链接][page]"] {
            let source = fragment + "\n\n" + plan.referenceContext
            let root = MarkdownBridge.parse(source).flatMap(PackedAstReader.init(data:))?.root()
            let links = root?.children.flatMap(\.children).filter { $0.type == .link }
            XCTAssertEqual(links?.first?.linkHref(), "https://example.com/article")
        }
    }

    func testCodeAndEscapedExamplesDoNotBecomeMedia() {
        for text in [
            "`![图](https://example.com/a.png)`",
            "\\![图](https://example.com/a.png)",
            "```markdown\n![图](https://example.com/a.png)\n```"
        ] {
            XCTAssertTrue(parse(text).segments.isEmpty, text)
            XCTAssertEqual(parse(text).consumedUTF8Count, 0)
        }
    }

    func testStreamingWaitsForParagraphAndOuterLinkCompletion() {
        var scan = ChatMarkdownMediaScan()
        let unfinished = "[![图](https://example.com/a.png)](https://example.com/"
        XCTAssertFalse(scan.update(unfinished, isStreaming: true))
        XCTAssertEqual(parse(unfinished, completed: scan.completedUTF8Count).consumedUTF8Count, 0)
        let completeLink = unfinished + "article)"
        XCTAssertFalse(scan.update(completeLink, isStreaming: true))
        let endedParagraph = completeLink + "\n\n"
        XCTAssertTrue(scan.update(endedParagraph, isStreaming: true))
        XCTAssertGreaterThan(parse(endedParagraph, completed: scan.completedUTF8Count).consumedUTF8Count, 0)
        var finalScan = ChatMarkdownMediaScan()
        XCTAssertTrue(finalScan.update(completeLink, isStreaming: false))
        XCTAssertGreaterThan(parse(completeLink).consumedUTF8Count, 0)
    }

    func testOnlyExplicitVideoMediaLinksBecomeVideoCards() {
        let text = "前 [演示](https://example.com/demo.MP4?token=abc) 中 [网站](https://example.com/watch?v=1) 后 [直播](https://example.com/live.m3u8)"
        let plan = parse(text)
        XCTAssertEqual(plan.segments.count, 4)
        guard case .video(let first) = plan.segments[1].kind,
              case .text(let between) = plan.segments[2].kind,
              case .video(let last) = plan.segments[3].kind else { return XCTFail("Unexpected video ordering") }
        XCTAssertEqual(first.title, "演示")
        XCTAssertTrue(between.contains("[网站](https://example.com/watch?v=1)"))
        XCTAssertEqual(last.title, "直播")
        for url in ["javascript:demo.mp4", "file:///demo.mp4", "https://example.com/?file=demo.mp4", "https://example.com/demo.mp4/page"] {
            XCTAssertFalse(ChatMarkdownMediaParser.isVideoURL(url))
        }
    }

    func testAdjacentImagesAreOneGalleryAndTextBreaksGallery() {
        let text = "![1](https://example.com/1.png)\n![2](https://example.com/2.png)\n\n说明\n\n![3](https://example.com/3.png)"
        let plan = parse(text)
        XCTAssertEqual(plan.segments.count, 3)
        guard case .images(let first) = plan.segments[0].kind,
              case .text(let text) = plan.segments[1].kind,
              case .images(let last) = plan.segments[2].kind else { return XCTFail("Unexpected gallery ordering") }
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(text.contains("说明"))
        XCTAssertEqual(last.count, 1)
    }

    func testFormattingAcrossMediaRemainsAnIntactParagraph() {
        for (source, expectedTags) in [
            ("**粗体前 ![图](https://example.com/a.png) 粗体后**", ["strong"]),
            ("*前 ![图](https://example.com/a.png) 后*", ["em"]),
            ("~~前 ![图](https://example.com/a.png) 后~~", ["del"]),
            ("**粗体前 *![图](https://example.com/a.png)* 粗体后**", ["strong", "em"]),
            ("**![图](https://example.com/a.png)**", ["strong"])
        ] {
            let plan = parse(source)
            guard case .text(let paragraph) = plan.segments.first?.kind,
                  case .images(let images) = plan.segments.last?.kind else { return XCTFail("Missing formatted content") }
            XCTAssertEqual(paragraph, source.replacingOccurrences(of: "![图](https://example.com/a.png)", with: "图"))
            XCTAssertFalse(paragraph.contains("!["))
            XCTAssertFalse(paragraph.contains("https://example.com/a.png"))
            XCTAssertEqual(images.count, 1)
            let html = MarkdownBridge.toHtml(paragraph) ?? ""
            for tag in expectedTags { XCTAssertTrue(html.contains("<\(tag)>"), html) }
            XCTAssertFalse(html.contains("**"), html)
            XCTAssertEqual(plan.consumedUTF8Count, source.utf8.count)
        }
    }

    func testMixedLinkLabelPreservesLinkedTextAndImageSource() {
        let text = "[前 ![图](https://example.com/a.png) 后](https://example.com/article)"
        let plan = parse(text)
        guard case .text(let paragraph) = plan.segments.first?.kind,
              case .images(let images) = plan.segments.last?.kind else { return XCTFail("Missing linked content") }
        XCTAssertEqual(paragraph, "[前 图 后](https://example.com/article)")
        XCTAssertFalse(paragraph.contains("https://example.com/a.png"))
        XCTAssertEqual(images[0].sourceURL, "https://example.com/article")
        let html = MarkdownBridge.toHtml(paragraph) ?? ""
        XCTAssertTrue(html.contains("href=\"https://example.com/article\""), html)
        XCTAssertFalse(html.contains("](https://"), html)
    }

    func testAutolinkAndRelativeImageRemainVisibleBetweenPromotedImages() {
        for middle in ["<https://example.com/demo.mp4>", "![本地示例](./diagram.png)"] {
            let source = "![1](https://example.com/1.png) \(middle) ![2](https://example.com/2.png)"
            let plan = parse(source)
            XCTAssertEqual(plan.segments.count, 3)
            guard case .images = plan.segments[0].kind,
                  case .text(let content) = plan.segments[1].kind,
                  case .images = plan.segments[2].kind else { return XCTFail("Unexpected media ordering") }
            XCTAssertEqual(content, " \(middle) ")
            let html = MarkdownBridge.toHtml(content) ?? ""
            XCTAssertTrue(html.contains(middle.hasPrefix("<") ? "href=\"https://example.com/demo.mp4\"" : "alt=\"本地示例\""), html)
        }
    }

    func testListQuoteAndTableKeepCompleteContainerBeforeTheirNativeMedia() {
        for text in [
            "- 第一项\n  - 嵌套 ![图](https://example.com/a.png)\n- 后一项\n",
            "> 引用\n> ![图](https://example.com/a.png)\n> 后文\n",
            "| 图 | 文 |\n|---|---|\n| ![图](https://example.com/a.png) | 说明 |\n"
        ] {
            let plan = parse(text)
            guard case .text(let container) = plan.segments.first?.kind,
                  case .images(let images) = plan.segments.last?.kind else { return XCTFail("Missing container media: \(text)") }
            XCTAssertEqual(container, text.replacingOccurrences(of: "![图](https://example.com/a.png)", with: "图"))
            XCTAssertFalse(container.contains("!["))
            XCTAssertFalse(container.contains("https://example.com/a.png"))
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images[0].title, "图")
        }
        let code = "> ```markdown\n> ![图](https://example.com/a.png)\n> ```"
        XCTAssertTrue(parse(code).segments.isEmpty)
    }

    func testContainerAltLabelsEscapeMarkdownAndLeaveCodeAndRelativeImagesIntact() {
        let source = "**前 ![A|B [C] *D*](https://example.com/a.png) 后**\n\n- `![例](https://example.com/code.png)`\n- ![相对图](./diagram.png)\n- ![表内图](https://example.com/b.png)\n"
        let plan = parse(source)
        let text = plan.segments.compactMap { segment -> String? in
            if case .text(let content) = segment.kind { return content }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("A\\|B \\[C\\] D"), text)
        XCTAssertFalse(text.contains("https://example.com/a.png"))
        XCTAssertFalse(text.contains("https://example.com/b.png"))
        XCTAssertTrue(text.contains("`![例](https://example.com/code.png)`"))
        XCTAssertTrue(text.contains("![相对图](./diagram.png)"))
        let html = MarkdownBridge.toHtml(text) ?? ""
        XCTAssertTrue(html.contains("A|B [C] D"), html)
        XCTAssertFalse(html.contains("<em>D</em>"), html)
        let emptyAlt = parse("**前 ![](https://example.com/a.png) 后**")
        guard case .text(let emptyAltText) = emptyAlt.segments.first?.kind else { return XCTFail("Missing alt placeholder") }
        XCTAssertEqual(emptyAltText, "**前 图片 后**")
    }

    @MainActor
    func testComplexParagraphAndListRenderNativeMediaWithoutMarkdownImageSyntax() async throws {
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let url = "data:image/png;base64," + (try XCTUnwrap(bitmap.pngData())).base64EncodedString()
        let source = "**粗体前 *![图示](\(url))* 粗体后**\n\n- 第一项\n  - ![列表配图](\(url))\n- 后一项\n\n结束。"
        let plan = parse(source)
        for segment in plan.segments {
            if case .text(let content) = segment.kind {
                XCTAssertFalse(content.contains("!["), content)
                XCTAssertFalse(content.contains("data:image"), content)
            }
        }
        let scene = try await windowSceneForSnapshot()
        for blockRenderer in [false, true] {
            let host = UIHostingController(rootView: ChatAssistantMarkdownView(markdown: source, hasEverStreamed: blockRenderer).padding(16))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            window.layoutIfNeeded()
            let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
            window.frame.size.height = ceil(host.sizeThatFits(in: proposal).height)
            window.layoutIfNeeded()
            if blockRenderer {
                // Parsed list items are separate text views. The temporary plain
                // document instead contains all three lines with literal markers.
                let expectedItems: Set<String> = ["第一项", "列表配图", "后一项"]
                var renderedItems = Set<String>()
                for _ in 0..<200 {
                    window.layoutIfNeeded()
                    renderedItems = Set(renderedTextViews(in: host.view).map {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    })
                    if expectedItems.isSubset(of: renderedItems) { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(expectedItems.isSubset(of: renderedItems), "List parsing did not finish: \(renderedItems)")
                XCTAssertFalse(renderedItems.contains(where: { $0.hasPrefix("- ") }), "Literal list markers remained: \(renderedItems)")
            }
            let size = host.sizeThatFits(in: proposal)
            XCTAssertLessThanOrEqual(size.width, 320)
            XCTAssertGreaterThan(size.height, 400)
            window.frame.size.height = ceil(size.height)
            window.layoutIfNeeded()
            await Task.yield()
            window.layoutIfNeeded()
            CATransaction.flush()
            var captured = false
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(captured, "The scene-backed Markdown container hierarchy must finish drawing")
            let name = blockRenderer ? "block" : "stable"
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "markdown-container-media-\(name)-320pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-markdown-container-\(name)-320pt.png")
            try screenshot.pngData()?.write(to: path)
            print("MEDIA_SCREENSHOT=\(path.path)")
        }
    }

    @MainActor
    private func renderedTextViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { renderedTextViews(in: $0) }
    }

    @MainActor
    private func windowSceneForSnapshot() async throws -> UIWindowScene {
        for _ in 0..<100 {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
                return scene
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                             "Markdown snapshots require a connected application window scene")
    }

    @MainActor
    func testHistoricalMediaIsPresentAtInitializationAndMeasuresLongDocument() {
        let text = String(repeating: "这是一段带有普通链接的长文说明。\n\n", count: 1100) + "![图](https://example.com/a.png)"
        XCTAssertGreaterThan(text.utf8.count, 50_000)
        let start = Date()
        let controller = ChatMarkdownMediaController(text: text, isStreaming: false)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(controller.plan.segments.isEmpty)
        print("MARKDOWN_MEDIA_INITIAL bytes=\(text.utf8.count) ms=\(elapsed * 1000)")
        let plain = ChatMarkdownMediaController(text: "普通历史文本", isStreaming: false)
        XCTAssertTrue(plain.plan.segments.isEmpty)
    }

    func testLongStreamingScannerConsumesOnlyNewBytesAndReconcilesReplacement() {
        var scan = ChatMarkdownMediaScan()
        var source = ""
        for _ in 0..<500 {
            source += "中文普通文字😀 "
            XCTAssertFalse(scan.update(source, isStreaming: true))
        }
        XCTAssertEqual(scan.totalScannedUTF8Count, source.utf8.count)
        source += "![图](https://example.com/a.png)"
        XCTAssertFalse(scan.update(source, isStreaming: true))
        XCTAssertTrue(scan.update(source + "\n\n", isStreaming: true))
        XCTAssertFalse(scan.update("替换后的纯文本", isStreaming: false))
        XCTAssertTrue(scan.didReset)
        XCTAssertFalse(scan.hasCandidate)
    }

    @MainActor
    func testMixedMarkdownMediaFitsNarrowWidthWithoutLoadingHeightChange() async throws {
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let dataURL = "data:image/png;base64," + (try XCTUnwrap(bitmap.pngData())).base64EncodedString()
        let source = "文字与图片之间保持自然间距。\n\n![图片标题](\(dataURL))\n\n视频前的说明文字。\n\n[演示视频](https://example.com/demo.mp4)\n\n末尾的文字应保持左对齐。"
        let host = UIHostingController(rootView: ChatAssistantMarkdownView(markdown: source).dynamicTypeSize(.accessibility2).padding(16))
        host.safeAreaRegions = []
        let scene = try await windowSceneForSnapshot()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        // Both measurements use the mounted hosting environment. Before the
        // first await, image-loading tasks have not had a chance to finish.
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        window.frame.size.height = ceil(host.sizeThatFits(in: proposal).height)
        window.layoutIfNeeded()
        let before = host.sizeThatFits(in: proposal)
        let beforeInsets = host.view.safeAreaInsets
        let beforeBounds = host.view.bounds
        XCTAssertLessThanOrEqual(before.width, 320)
        XCTAssertGreaterThan(before.height, 400)
        try await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        let after = host.sizeThatFits(in: proposal)
        XCTAssertEqual(host.view.safeAreaInsets, beforeInsets)
        XCTAssertEqual(host.view.bounds, beforeBounds)
        XCTAssertEqual(before.height, after.height, accuracy: 1, "Image load must keep the Markdown media frame height")
        await Task.yield()
        window.layoutIfNeeded()
        CATransaction.flush()
        var captured = false
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(captured, "The scene-backed Markdown media hierarchy must finish drawing")
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "markdown-media-320pt-accessibility2"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-markdown-media-320pt.png")
        try screenshot.pngData()?.write(to: path)
        print("MEDIA_SCREENSHOT=\(path.path)")
    }

    @MainActor
    func testAuthoritativePlainTextReplacementClearsPublishedMedia() async throws {
        let controller = ChatMarkdownMediaController()
        controller.update("![图](https://example.com/a.png)", isStreaming: false)
        for _ in 0..<100 where controller.plan.segments.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.plan.segments.isEmpty)
        controller.update("最终纯文本", isStreaming: false)
        XCTAssertTrue(controller.plan.segments.isEmpty)
    }
}
