import XCTest
@testable import AmberMac

final class DesktopMathTokenizerTests: XCTestCase {
    func testInlineMathPreservesCodeCurrencyEscapesAndStreamingDelimiters() {
        XCTAssertEqual(DesktopMathTokenizer.inline(#"能量 $E=mc^2$，比值 \(\frac{a}{b}\)。"#), [
            .text("能量 "), .formula("E=mc^2"), .text("，比值 "), .formula(#"\frac{a}{b}"#), .text("。")])
        for source in [#"价格 $100 and $200"#, #"代码 `$x$` 和 ``\(y\)``"#, #"转义 \$x\$ 与 \\(y\\)"#, #"未完成 $x+"#, #"未完成 \(\frac{a}"#, "`未完成代码 $x$"] {
            XCTAssertEqual(DesktopMathTokenizer.inline(source), [.text(source)], source)
        }
    }

    func testBlockMathUsesRealDelimitersAndNeverConsumesFencedCode() {
        XCTAssertEqual(DesktopMarkdownParser.parse("$$\n\\frac{a}{b}\n$$"), [.math(#"\frac{a}{b}"#)])
        XCTAssertEqual(DesktopMarkdownParser.parse(#"\[x^2+y^2\]"#), [.math("x^2+y^2")])
        XCTAssertEqual(DesktopMarkdownParser.parse("```tex\n$$x$$\n```"), [.code("$$x$$", "tex")])
        XCTAssertEqual(DesktopMarkdownParser.parse("$$x\n\n```tex\n$$\n```"), [.paragraph("$$x"), .code("$$", "tex")])
        XCTAssertEqual(DesktopMarkdownParser.parse("$$unfinished"), [.paragraph("$$unfinished")])
    }
}
