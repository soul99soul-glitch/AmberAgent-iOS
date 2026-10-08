import XCTest
@testable import AmberDeepRead

final class DeepReadTemplateExportTests: XCTestCase {
    func testCustomTemplateUsesFullConfiguredFontScale() throws {
        let template = IOSDeepReadCustomTemplate(name: "默认", description: "", html: IOSDeepReadHTMLTemplateRenderer.starterHTML(), createdByAI: false)
        let task = IOSDeepReadTask(id: "test", title: "标题", status: .succeeded, templateId: template.id, sources: [], resultMarkdown: "正文", failureMessage: nil, createdAt: 0, updatedAt: 0, completedAt: 0, retryCount: 0)
        for (scale, expected) in [(Float(0.7), "11.20px"), (Float(1.8), "28.80px")] {
            let html = try IOSDeepReadHTMLTemplateRenderer.render(task: task, template: template, fontScale: scale, fontModeWireName: "system")
            XCTAssertTrue(html.contains("font-size: \(expected)"))
        }
    }

    func testStarterFitsDeviceViewport() {
        XCTAssertTrue(IOSDeepReadHTMLTemplateRenderer.starterHTML().contains("name=\"viewport\" content=\"width=device-width, initial-scale=1\""))
    }

    func testStarterHasScreenOnlyDarkPalette() {
        let html = IOSDeepReadHTMLTemplateRenderer.starterHTML()
        XCTAssertTrue(html.contains("@media screen and (prefers-color-scheme: dark)"))
    }

    func testTextExportKeepsHeadingParagraphAndListSeparators() throws {
        let markdown = "# 标题\n\n第一段 **重点**。\n\n第二段 [链接](https://example.com)。\n\n- 甲\n- 乙\n\n## 下一节\n\n正文"
        let text = DeepReadTextExporter.text(from: markdown)
        XCTAssertTrue(text.contains("标题\n\n第一段 重点。\n\n第二段 链接。"))
        XCTAssertTrue(text.contains("- 甲\n- 乙"))
        XCTAssertTrue(text.contains("下一节\n\n正文"))
    }

    func testTextExportKeepsCodeAndTableReadable() throws {
        let markdown = "# 示例\n\n```swift\nlet first = 1\nlet second = 2\n```\n\n| 项目 | 值 |\n| --- | --- |\n| 甲 | 1 |\n| 乙 | 2 |"
        let text = DeepReadTextExporter.text(from: markdown)
        XCTAssertTrue(text.contains("let first = 1\nlet second = 2"))
        XCTAssertTrue(text.contains("项目\t值\n甲\t1\n乙\t2"))
        XCTAssertFalse(text.contains("```"))
        XCTAssertFalse(text.contains("--- |"))
    }
}
