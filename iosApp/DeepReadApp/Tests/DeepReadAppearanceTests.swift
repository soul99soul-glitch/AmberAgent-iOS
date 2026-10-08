import XCTest
@testable import AmberDeepRead

@MainActor
final class DeepReadAppearanceTests: XCTestCase {
    func testChoicesPersistAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "appearance-tests")!
        defaults.removePersistentDomain(forName: "appearance-tests")
        let first = DeepReadAppearance(defaults: defaults)
        XCTAssertEqual(first.accent, .cinnabar)
        XCTAssertEqual(first.readerStyle, .classic)
        first.accent = .pine
        first.readerStyle = .journal
        let relaunched = DeepReadAppearance(defaults: defaults)
        XCTAssertEqual(relaunched.accent, .pine)
        XCTAssertEqual(relaunched.readerStyle, .journal)
    }

    func testArticleFollowsAccentAndReaderStyle() throws {
        let appearance = DeepReadAppearance.shared
        let original = (appearance.accent, appearance.readerStyle)
        defer { appearance.accent = original.0; appearance.readerStyle = original.1 }
        appearance.accent = .indigo
        appearance.readerStyle = .broadsheet
        let task = try JSONDecoder().decode(IOSDeepReadTask.self, from: Data("""
        {"id":"t","title":"标题","status":"succeeded","templateId":"compose_magazine","sources":[],
         "resultMarkdown":"# 标题\\n\\n正文","createdAt":0,"updatedAt":0,"retryCount":0}
        """.utf8))
        let settings = DeepReadSettingsStore(defaults: UserDefaults(suiteName: "appearance-tests-settings")!)
        let light = try DeepReadArticleRenderer.html(task: task, settings: settings, dark: false)
        XCTAssertTrue(light.contains("--deep-read-accent:#2F5D8A;"))
        XCTAssertTrue(light.contains("--deep-read-bg:#F5F1E8;"))
        XCTAssertTrue(light.contains("border-top:4px double"))
        let dark = try DeepReadArticleRenderer.html(task: task, settings: settings, dark: true)
        XCTAssertTrue(dark.contains("--deep-read-accent:#7FA8D6;"))
    }
}
