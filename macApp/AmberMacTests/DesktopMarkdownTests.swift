import XCTest
@testable import AmberMac

final class DesktopMarkdownTests: XCTestCase {
    func testFencedCodeKeepsWhitespaceAndUnfinishedStream() {
        XCTAssertEqual(DesktopMarkdownParser.parse("## 结果\n\n```swift\n  let value = 1\n\n  print(value)"), [
            .heading("结果", 2),
            .code("  let value = 1\n\n  print(value)", "swift")
        ])
    }

    func testParagraphAfterClosedCodeRemainsVisible() {
        XCTAssertEqual(DesktopMarkdownParser.parse("```\ncode\n```\n下一段"), [.code("code", ""), .paragraph("下一段")])
    }

    func testLongFenceCanContainShortFenceAndLanguageLikeContent() {
        XCTAssertEqual(DesktopMarkdownParser.parse("````markdown\n```swift\nlet x = 1\n```\n````\n正文"), [
            .code("```swift\nlet x = 1\n```", "markdown"), .paragraph("正文")
        ])
    }

    func testTablesRetainEscapedAndInlineCodePipes() {
        XCTAssertEqual(DesktopMarkdownParser.parse("| 名称 | 说明 |\n| --- | :---: |\n| A\\|B | `x|y` |"), [
            .table([["名称", "说明"], ["A|B", "`x|y`"]], alignments: [.leading, .center])
        ])
        XCTAssertEqual(DesktopMarkdownParser.tableCells("| C:\\temp | 尾部\\ |"), ["C:\\temp", "尾部\\"])
        XCTAssertEqual(DesktopMarkdownParser.tableCells("| C:\\Users\\mi | \\d+ | `a\\\\b` |"), ["C:\\Users\\mi", "\\d+", "`a\\\\b`"])
        XCTAssertEqual(DesktopMarkdownParser.tableCells("A | B\\|"), ["A", "B|"])
    }

    func testHashAndPipeInProseDoNotCreateFalseHeadingsOrTables() {
        XCTAssertEqual(DesktopMarkdownParser.parse("#hashtag\nA | B\n普通文字"), [.paragraph("#hashtag\nA | B\n普通文字")])
    }

    func testEmptyTextHasNoEmptyBlocks() {
        XCTAssertEqual(DesktopMarkdownParser.parse("\n\n"), [])
    }

    func testListsPreserveNestedItemsContinuationAndOrderedStart() {
        XCTAssertEqual(DesktopMarkdownParser.parse("3. **第一项**\n   补充说明\n9. 第二项\n  - 嵌套项\n10. 最后一项\n\n普通段落"), [
            .list([
                .init(marker: "3.", text: "**第一项**\n补充说明", level: 0),
                .init(marker: "4.", text: "第二项", level: 0),
                .init(marker: "•", text: "嵌套项", level: 1),
                .init(marker: "5.", text: "最后一项", level: 0),
            ]),
            .paragraph("普通段落"),
        ])
        XCTAssertEqual(DesktopMarkdownParser.parse("- 第一项\n\n- 第二项\n\n下一段"), [
            .list([.init(marker: "•", text: "第一项", level: 0), .init(marker: "•", text: "第二项", level: 0)]),
            .paragraph("下一段"),
        ])
    }

    func testQuotedBlocksRetainListsAndNestedQuoteStructure() {
        XCTAssertEqual(DesktopMarkdownParser.parse("> ## 引用标题\n> - **要点**\n> - `code`\n>\n> > 更深引用\n\n正文"), [
            .quote([
                .heading("引用标题", 2),
                .list([.init(marker: "•", text: "**要点**", level: 0), .init(marker: "•", text: "`code`", level: 0)]),
                .quote([.paragraph("更深引用")]),
            ]),
            .paragraph("正文"),
        ])
    }

    func testDividersAndNumericProseAreNotLists() {
        XCTAssertEqual(DesktopMarkdownParser.parse("- - -\n3.14 是圆周率\n1.不是列表\n***"), [
            .divider, .paragraph("3.14 是圆周率\n1.不是列表"), .divider,
        ])
    }

    func testTableAlignmentAndMultipleBacktickDelimiters() {
        XCTAssertEqual(DesktopMarkdownParser.parse("左 | 中 | 右\n:--- | :---: | ---:\n**重点** | [来源](https://example.com) | ``a`|b``"), [
            .table([["左", "中", "右"], ["**重点**", "[来源](https://example.com)", "``a`|b``"]],
                   alignments: [.leading, .center, .trailing]),
        ])
        XCTAssertEqual(DesktopMarkdownParser.tableCells(#"| \`literal\` | \*plain\* | C:\temp |"#), [#"\`literal\`"#, #"\*plain\*"#, #"C:\temp"#])
        XCTAssertEqual(DesktopMarkdownParser.parse("一 | 二\n--- | ---::\n正文"), [.paragraph("一 | 二\n--- | ---::\n正文")])
    }

    func testFoundationInlineParserCarriesEmphasisCodeAndRealLinks() {
        let value = DesktopMarkdownInline.parse("**重点**、*强调*、`let value = 1` 与 [来源](https://example.com)")
        XCTAssertEqual(String(value.characters), "重点、强调、let value = 1 与 来源")
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(value.runs.compactMap(\.link), [URL(string: "https://example.com")!])
    }

    func testUnclosedInlineCodeDoesNotConsumeFollowingTableColumns() {
        XCTAssertEqual(DesktopMarkdownParser.tableCells("| `unfinished | second |"), ["`unfinished", "second"])
        XCTAssertEqual(DesktopMarkdownParser.tableCells("| ``unfinished ` | second |"), ["``unfinished `", "second"])
        XCTAssertEqual(DesktopMarkdownParser.parse("A | B\n--- | ---\n`unfinished | second"), [
            .table([["A", "B"], ["`unfinished", "second"]], alignments: [.leading, .leading]),
        ])
    }

    func testInterleavedTextSingleImageAndMultipleImagesPreserveExactOrder() {
        let markdown = """
        第一段文字说明

        ![架构图](https://example.com/arch.png "架构总览")

        第二段文字说明，包含行内代码 `![not-an-image](https://example.com/skip.png)`

        ![图A](https://example.com/a.jpg)
        [![图B](https://example.com/b.webp)](https://example.com/source-b)
        """
        XCTAssertEqual(DesktopMarkdownParser.parse(markdown), [
            .paragraph("第一段文字说明"),
            .images([DesktopMessageImage(url: "https://example.com/arch.png", name: "架构图", title: "架构总览")]),
            .paragraph("第二段文字说明，包含行内代码 `![not-an-image](https://example.com/skip.png)`"),
            .images([
                DesktopMessageImage(url: "https://example.com/a.jpg", name: "图A", title: "图A"),
                DesktopMessageImage(url: "https://example.com/b.webp", name: "图B", title: "图B", sourceURL: "https://example.com/source-b"),
            ]),
        ])
    }

    func testInlineInterleavedTextAndMediaWithinSameParagraphSplitsAndCoalescesAdjacentImages() {
        let markdown = "开场文字 ![单图](https://example.com/1.png) 中间文字 ![多图1](https://example.com/2.png) ![多图2](https://example.com/3.png) 结尾文字"
        XCTAssertEqual(DesktopMarkdownParser.parse(markdown), [
            .paragraph("开场文字"),
            .images([DesktopMessageImage(url: "https://example.com/1.png", name: "单图", title: "单图")]),
            .paragraph("中间文字"),
            .images([
                DesktopMessageImage(url: "https://example.com/2.png", name: "多图1", title: "多图1"),
                DesktopMessageImage(url: "https://example.com/3.png", name: "多图2", title: "多图2"),
            ]),
            .paragraph("结尾文字"),
        ])
    }

    func testMarkdownVideoAndAudioLinksBecomeEmbeddedMediaBlocksWhileWebLinksStayProse() {
        let markdown = """
        请看下面的演示媒体与普通参考链接 [官网](https://example.com/docs)：

        ![产品演示](https://cdn.example.com/demo.mp4)

        [语音播报](https://cdn.example.com/briefing.m4a)
        """
        XCTAssertEqual(DesktopMarkdownParser.parse(markdown), [
            .paragraph("请看下面的演示媒体与普通参考链接 [官网](https://example.com/docs)："),
            .video(DesktopVideoMedia(url: "https://cdn.example.com/demo.mp4", title: "产品演示", sourceURL: "https://cdn.example.com/demo.mp4")),
            .audio(DesktopAudioMedia(url: "https://cdn.example.com/briefing.m4a", fileName: "briefing.m4a", title: "语音播报")),
        ])
    }

    func testStreamingWithholdsIncompleteTrailingImageSyntaxUntilClosed() {
        let partial = "正在输出图文说明 ![未完成图片](https://example.com/half-url"
        XCTAssertEqual(DesktopMarkdownParser.parse(partial, streaming: true), [
            .paragraph("正在输出图文说明"),
        ])
        let completed = partial + ".png) 后续说明"
        XCTAssertEqual(DesktopMarkdownParser.parse(completed, streaming: true), [
            .paragraph("正在输出图文说明"),
            .images([DesktopMessageImage(url: "https://example.com/half-url.png", name: "未完成图片", title: "未完成图片")]),
            .paragraph("后续说明"),
        ])
    }

    func testOrderedDisplayBlocksPreserveInterleavingAcrossCanonicalJSONAndUserAttachments() throws {
        let canonical = #"""
        {
          "id": "20000000-0000-4000-8000-000000000002",
          "role": "assistant",
          "parts": [
            {"type": "reasoning", "reasoning": "先分析图文结构"},
            {"type": "text", "text": "文字段落一"},
            {"type": "image", "url": "data:image/png;base64,aW1nMQ==", "metadata": {"fileName": "one.png"}},
            {"type": "text", "text": "文字段落二"},
            {"type": "image", "url": "data:image/png;base64,aW1nMg==", "metadata": {"fileName": "two.png"}},
            {"type": "image", "url": "data:image/png;base64,aW1nMw==", "metadata": {"fileName": "three.png"}},
            {"type": "video", "url": "https://example.com/clip.mp4", "metadata": {"app.amber.media.title": "Clip"}},
            {"type": "audio", "url": "https://example.com/audio.mp3", "fileName": "audio.mp3"}
          ]
        }
        """#
        let assistant = DesktopMessage(
            role: .assistant,
            text: "文字段落一文字段落二",
            reasoning: "先分析图文结构",
            canonicalJSON: canonical
        )
        XCTAssertEqual(assistant.orderedDisplayBlocks(), [
            .text("文字段落一"),
            .images([DesktopMessageImage(url: "data:image/png;base64,aW1nMQ==", name: "one.png")]),
            .text("文字段落二"),
            .images([
                DesktopMessageImage(url: "data:image/png;base64,aW1nMg==", name: "two.png"),
                DesktopMessageImage(url: "data:image/png;base64,aW1nMw==", name: "three.png"),
            ]),
            .video(DesktopVideoMedia(url: "https://example.com/clip.mp4", title: "Clip")),
            .audio(DesktopAudioMedia(url: "https://example.com/audio.mp3", fileName: "audio.mp3", title: "audio.mp3")),
        ])

        let tool = DesktopToolCall(
            id: "call-search",
            name: "search_web",
            input: #"{"query":"amber"}"#,
            output: #"{"images":[{"url":"https://example.com/search1.png","title":"Search 1","sourceURL":"https://example.com/p1"}]}"#
        )
        XCTAssertEqual(tool.resolvedImages, [
            DesktopMessageImage(url: "https://example.com/search1.png", title: "Search 1", sourceURL: "https://example.com/p1"),
        ])
    }
}
