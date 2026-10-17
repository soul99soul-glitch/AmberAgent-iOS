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
            XCTAssertEqual(paragraph, source)
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
        XCTAssertEqual(paragraph, text)
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
            XCTAssertEqual(container, text)
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images[0].title, "图")
        }
        let code = "> ```markdown\n> ![图](https://example.com/a.png)\n> ```"
        XCTAssertTrue(parse(code).segments.isEmpty)
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
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let before = host.sizeThatFits(in: proposal)
        XCTAssertLessThanOrEqual(before.width, 320)
        XCTAssertGreaterThan(before.height, 400)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: ceil(before.height) + 40))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let after = host.sizeThatFits(in: proposal)
        XCTAssertEqual(before.height, after.height, accuracy: 1, "Image load must keep the Markdown media frame height")
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
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
