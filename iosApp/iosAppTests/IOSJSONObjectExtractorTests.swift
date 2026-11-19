import XCTest
@testable import iosApp

final class IOSJSONObjectExtractorTests: XCTestCase {
    func testExtractJSONObjectStripsCodeFencesAndProse() {
        let wrapped = "这是模型的说明\n```json\n{\"summary\":\"x\",\"nested\":{\"a\":1}}\n```\n结束语"
        XCTAssertEqual(
            IOSJSONObjectExtractor.extractJSONObject(wrapped),
            #"{"summary":"x","nested":{"a":1}}"#
        )
        XCTAssertNil(IOSJSONObjectExtractor.extractJSONObject("no json here"))
    }

    func testExtractJSONObjectIgnoresBracesInsideStrings() {
        let raw = #"prefix {"text":"hello } { world","ok":true} suffix"#
        XCTAssertEqual(
            IOSJSONObjectExtractor.extractJSONObject(raw),
            #"{"text":"hello } { world","ok":true}"#
        )
    }
}
