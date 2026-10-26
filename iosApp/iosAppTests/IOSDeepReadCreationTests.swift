import XCTest
@testable import iosApp

@MainActor
final class IOSDeepReadCreationTests: XCTestCase {
    func testCreationOffersEveryTemplateAvailableInBoardSettings() {
        let options = DeepReadCreateView.templateOptions(customTemplates: [])

        XCTAssertEqual(options.map(\.id), DeepReadSynthesisTemplate.options.map(\.id))
        XCTAssertTrue(options.contains { $0.id == DeepReadSynthesisTemplate.auto.id })
        XCTAssertTrue(options.contains { $0.id == DeepReadSynthesisTemplate.brief.id })
        XCTAssertTrue(options.contains { $0.id == DeepReadSynthesisTemplate.qa.id })
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
    }

    func testCreationOffersSavedCustomTemplateWithItsOriginalIdentityAndName() {
        let custom = IOSDeepReadCustomTemplate(
            id: "custom:my-reading",
            name: "我的阅读版式",
            description: "已保存模板",
            html: IOSDeepReadHTMLTemplateRenderer.starterHTML(),
            createdByAI: false
        )

        let options = DeepReadCreateView.templateOptions(customTemplates: [custom])

        XCTAssertEqual(options.last?.id, custom.id)
        XCTAssertEqual(options.last?.name, custom.name)
        XCTAssertEqual(options.last?.description, custom.description)
        XCTAssertTrue(options.contains { $0.id == IOSDeepReadTemplate.defaultId })
    }
}
