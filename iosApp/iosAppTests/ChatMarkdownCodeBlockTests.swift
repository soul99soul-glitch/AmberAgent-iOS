import XCTest
@testable import iosApp

@MainActor
final class ChatMarkdownCodeBlockTests: XCTestCase {
    func testHistoryCodeBlockContainsOnlyCodeBody() throws {
        let samples: [(markdown: String, code: String)] = [
            ("完美！输出干净了：\n\n```\n❯ 6+9=?       ← 提问\n6 + 9 = 15.   ← 答案\n```",
             "❯ 6+9=?       ← 提问\n6 + 9 = 15.   ← 答案\n"),
            ("````html\n<pre>```</pre>\n  保留缩进 & 字符\n````",
             "<pre>```</pre>\n  保留缩进 & 字符\n"),
            ("    first\n    second\n", "first\nsecond\n"),
        ]
        for sample in samples {
            let data = try XCTUnwrap(MarkdownBridge.parse(sample.markdown))
            let reader = try XCTUnwrap(PackedAstReader(data: data))
            let root = try XCTUnwrap(reader.root())
            let block = try XCTUnwrap(root.children.first { $0.type == .codeBlock })
            XCTAssertEqual(
                AmberMarkdownView(markdown: sample.markdown).codeBlockText(from: block, source: sample.markdown),
                sample.code
            )
        }
    }

    func testHistoryInlineCodeRemovesDelimitersAndPreservesLiteralBackticks() throws {
        let samples: [(markdown: String, code: String)] = [
            ("结果：`100 - 28 = 72.`", "100 - 28 = 72."),
            ("使用 `` `pipe-pane` ``", "`pipe-pane`"),
            ("运行 `first\nsecond`", "first second"),
        ]
        for sample in samples {
            let data = try XCTUnwrap(MarkdownBridge.parse(sample.markdown))
            let reader = try XCTUnwrap(PackedAstReader(data: data))
            let root = try XCTUnwrap(reader.root())
            let paragraph = try XCTUnwrap(root.children.first)
            let code = try XCTUnwrap(paragraph.children.first { $0.type == .inlineCode })
            XCTAssertEqual(
                AmberMarkdownView(markdown: sample.markdown).inlineCodeText(from: code, source: sample.markdown),
                sample.code
            )
        }
    }
}
