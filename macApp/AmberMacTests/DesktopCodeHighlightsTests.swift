import AppKit
import XCTest
@testable import AmberMac

final class DesktopCodeHighlightsTests: XCTestCase {
    func testSwiftHighlightsKeepSourceAndDoNotTreatCommentMarkersInsideStringAsComments() throws {
        let source = "let 中文 = \"https://example.com\" // 来源\nlet count = 42\n"
        let highlighted = DesktopCodeHighlights.highlight(source, language: "swift", fontSize: 13)
        XCTAssertEqual(String(highlighted.characters), source)
        let text = NSAttributedString(highlighted)
        func color(_ token: String) throws -> NSColor {
            let range = (source as NSString).range(of: token)
            return try XCTUnwrap(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        }
        XCTAssertEqual(try color("let"), NSColor.systemBlue)
        XCTAssertEqual(try color("https://example.com"), NSColor.systemRed)
        XCTAssertEqual(try color("// 来源"), NSColor.secondaryLabelColor)
        XCTAssertEqual(try color("42"), NSColor.systemPurple)
        XCTAssertEqual((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 13)
    }

    func testSupportedLanguagesAndUnknownFallbackPreserveEveryCharacter() {
        let examples = ["json": #"{"name":"中文","enabled":true,"count":12}"#,
            "javascript": "const value = 12; // comment", "python": "def greet():\n    return 'hello' # 注释\n",
            "bash": "if true; then\n echo '你好'\nfi\n", "unknown": "unclosed '原文 <x> & $100"]
        for (language, source) in examples {
            XCTAssertEqual(String(DesktopCodeHighlights.highlight(source, language: language, fontSize: 16).characters), source)
        }
    }
}
