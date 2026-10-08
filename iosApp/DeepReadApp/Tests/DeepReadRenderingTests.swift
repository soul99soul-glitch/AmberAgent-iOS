import XCTest
@testable import AmberDeepRead

@MainActor
final class DeepReadRenderingTests: XCTestCase {
    private struct EmptyCredentials: DeepReadCredentialStorage {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws {}
    }

    func testEditorialUsesStructuredContentAndEscapesSourceHTML() throws {
        var output = IOSDeepReadOutput()
        output.summary = "**可靠摘要**"
        output.timeline = [.init(date: "2026", event: "真实事件")]
        output.corePoints = [.init(point: "关键观点", supporting: "来源支持")]
        let html = IOSDeepReadEditorialRenderer.renderHTML(.init(
            title: "<script>不是脚本</script>", markdown: "", structured: output
        ))
        XCTAssertTrue(html.contains("时间轴"))
        XCTAssertTrue(html.contains("关键观点"))
        XCTAssertTrue(html.contains("<strong>可靠摘要</strong>"))
        XCTAssertFalse(html.contains("<script>不是脚本</script>"))
    }

    func testDarkReaderAndLightPDFUseDifferentCanvas() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = DeepReadSettingsStore(defaults: defaults, credentials: EmptyCredentials())
        let source = try IOSDeepReadSourceNormalizer.manualText(title: "主题", text: "可靠的原文材料")
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let task = try store.createTask(title: "主题", sources: [source], templateId: IOSDeepReadTemplate.defaultId)
        XCTAssertTrue(store.complete(id: task.id, markdown: "# 主题\n\n正文"))
        let saved = try XCTUnwrap(store.task(id: task.id))
        // The canvas follows the persisted reader style; pin the classic paper this test asserts.
        let appearance = DeepReadAppearance.shared
        let originalStyle = appearance.readerStyle
        defer { appearance.readerStyle = originalStyle }
        appearance.readerStyle = .classic
        let dark = try DeepReadArticleRenderer.html(task: saved, settings: settings, dark: true)
        let light = try DeepReadArticleRenderer.html(task: saved, settings: settings)
        XCTAssertTrue(light.lowercased().contains("#fbf7f1"))
        XCTAssertTrue(dark.lowercased().contains("#201c19"), "the dark reader uses the style's dark paper")
        XCTAssertFalse(light.lowercased().contains("#201c19"))
    }

    func testReaderFontsAreActuallyBundled() throws {
        for (name, ext) in [("noto_serif_sc", "otf"), ("jetbrains_mono", "ttf")] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext))
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 1_000)
        }
    }

    func testGeneratedArticleAllowsImagesWithoutOpeningScriptOrConnectionPermissions() {
        let html = IOSDeepReadHTMLSecurity.hardenedDocument("<html><head></head><body><img src=\"https://example.org/image.png\"></body></html>", allowsRemoteImages: true)
        XCTAssertTrue(html.contains("img-src data: https: http:;"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
    }

    func testCustomTemplateKeepsDataOnlyImagePolicy() {
        let html = IOSDeepReadHTMLSecurity.hardenedDocument("<html><head></head><body></body></html>")
        XCTAssertTrue(html.contains("img-src data:;"))
        XCTAssertFalse(html.contains("img-src data: https:"))
    }
}
