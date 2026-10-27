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
}
