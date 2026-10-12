import XCTest
@testable import iosApp

final class IOSIntelligentUIStreamingPreviewTests: XCTestCase {
    func testGoalAppearsOnlyAfterActualEscapedStringCloses() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let prefix = "```task-ui\n{\"version\":1,\"kind\":\"form\",\"goal\":\"学习 \\\"Swift"
        scanner.update(with: prefix)
        XCTAssertNil(scanner.preview)
        scanner.update(with: prefix + "\\\"\",")
        XCTAssertEqual(scanner.preview?.goal, "学习 \"Swift\"")
        XCTAssertFalse(scanner.preview?.isRootComplete ?? true)
    }

    func testCompletedFieldAndComponentAppearBeforeArraysOrRootClose() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let field = #"{"id":"budget","label":"预算","required":false,"type":"number"}"#
        let component = #"{"id":"budget-input","kind":"slider","field_id":"budget","min":0,"max":100,"step":1}"#
        let fieldStage = header + #", "fields":["# + field
        scanner.update(with: fieldStage)
        XCTAssertEqual(scanner.preview?.fields.map(\.id), ["budget"])
        XCTAssertEqual(scanner.preview?.componentCount, 0)
        let componentStage = fieldStage + #"], "components":["# + component
        scanner.update(with: componentStage)
        XCTAssertEqual(scanner.preview?.components.map(\.id), ["budget-input"])
        XCTAssertEqual(scanner.preview?.componentCount, 1)
        XCTAssertFalse(scanner.preview?.isRootComplete ?? true)
    }

    func testMissingFieldReferencesWaitForActualFieldInsteadOfInventingBinding() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let component = #"{"id":"entry","kind":"textField","field_id":"name"}"#
        let first = header + #", "components":["# + component + "]"
        scanner.update(with: first)
        XCTAssertTrue(scanner.preview?.components.isEmpty == true)
        scanner.update(with: first + #", "fields":[{"id":"name","label":"姓名","required":true}]"#)
        XCTAssertEqual(scanner.preview?.components.map(\.id), ["entry"])
    }

    func testNumericReadPreviewWaitsForRealNumberFieldAndReceivedInputOwner() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let prefix = header + #", "fields":[{"id":"budget","label":"预算","required":false,"type":"number"}], "components":["#
        let output = #"{"id":"budget-metric","kind":"metric","value_field_id":"budget"}"#
        let input = #"{"id":"budget-input","kind":"slider","field_id":"budget","min":0,"max":100,"value":40}"#
        scanner.update(with: prefix + output)
        XCTAssertTrue(scanner.preview?.components.isEmpty == true)
        scanner.update(with: prefix + output + "," + input)
        XCTAssertEqual(scanner.preview?.components.map(\.id), ["budget-metric", "budget-input"])

        let invalid = (prefix + output + "," + input).replacingOccurrences(of: "\"type\":\"number\"", with: "\"type\":\"text\"")
        scanner.reconcile(invalid)
        XCTAssertEqual(scanner.preview?.components.map(\.id), ["budget-input"])
    }

    func testCompleteRootPreviewsWithoutClosingFenceAndFenceCloseClearsScannerPreview() throws {
        let card = IOSIntelligentUICardDefinition(
            cardID: "preview-complete", kind: "explore", goal: "浏览研究结果",
            submit: .init(label: "继续研究", intent: "continue"),
            components: [.init(id: "actual-text", kind: .body, text: "已收到的正文")]
        )
        let raw = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let text = "```task-ui\n" + raw
        scanner.update(with: text)
        XCTAssertEqual(scanner.preview, .complete(card))
        scanner.update(with: text + "\n```\n")
        XCTAssertNil(scanner.preview)
    }

    func testOrdinaryInlineAndNestedCodeExamplesNeverCreatePreview() {
        let samples = [
            "文字中的 ```task-ui 只是协议名称。",
            "````markdown\n" + header + "\n```\n````\n",
            "~~~markdown\n" + header + "\n```\n~~~\n",
            "    " + header
        ]
        for sample in samples {
            var scanner = IOSIntelligentUIStreamingPreviewScanner()
            scanner.update(with: sample)
            XCTAssertNil(scanner.preview)
        }
    }

    func testUnsupportedVersionAndComponentCodeFieldsDoNotRender() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        scanner.update(with: header.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"))
        XCTAssertNil(scanner.preview)
        scanner.reconcile(header + #", "components":[{"id":"bad","kind":"body","text":"内容","callback":"run"}"#)
        XCTAssertEqual(scanner.preview?.componentCount, 0)
        scanner.reconcile(header + #", "components":[{"id":"unknown","kind":"executeTool"}"#)
        XCTAssertEqual(scanner.preview?.componentCount, 0)
    }

    func testCombinedComponentsRespectUniqueIDsAndNodeBudget() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let node = #"{"id":"same","kind":"body","text":"正文"}"#
        scanner.update(with: header + #", "components":["# + node + "," + node)
        XCTAssertEqual(scanner.preview?.componentCount, 1)
        XCTAssertEqual(scanner.preview?.components.count, 1)
    }

    func testStudyPreviewContainsOnlyReceivedPromptsAndNoPracticeSession() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let first = #"{"id":"question-1","prompt":"什么是 Swift？","answer":"一种编程语言"}"#
        let second = #"{"id":"question-2","prompt":"什么是值类型？","answer":"按值复制的类型"}"#
        let prefix = header.replacingOccurrences(of: "\"kind\":\"explore\"", with: "\"kind\":\"study\"") + #", "study":{"items":["#
        scanner.update(with: prefix + first)
        XCTAssertEqual(scanner.preview?.studyPrompts, [.init(id: "question-1", prompt: "什么是 Swift？")])
        scanner.update(with: prefix + first + "," + second)
        XCTAssertEqual(scanner.preview?.studyPrompts.count, 2)
        XCTAssertTrue(scanner.preview?.fields.isEmpty == true)
        XCTAssertFalse(scanner.preview?.isRootComplete ?? true)
    }

    func testStructurallyClosedIllegalStudyItemsNeverPublishPrompts() throws {
        let item: [String: Any] = [
            "id": "quiz", "prompt": "题干不能提前当作合法题目展示", "answer": "答案",
            "options": [["id": "one", "label": "一"], ["id": "two", "label": "二"]],
            "correct_option_id": "one"
        ]
        var missingCorrect = item
        missingCorrect.removeValue(forKey: "correct_option_id")
        var wrongCorrect = item
        wrongCorrect["correct_option_id"] = "not-an-option"
        var unknownOptionKey = item
        unknownOptionKey["options"] = [["id": "one", "label": "一", "callback": "run"], ["id": "two", "label": "二"]]
        var longDetail = item
        longDetail["detail"] = String(repeating: "详", count: 4_001)
        let prefix = header.replacingOccurrences(of: "\"kind\":\"explore\"", with: "\"kind\":\"study\"") + #", "study":{"items":["#
        for invalid in [missingCorrect, wrongCorrect, unknownOptionKey, longDetail] {
            var scanner = IOSIntelligentUIStreamingPreviewScanner()
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
            scanner.update(with: prefix + raw)
            XCTAssertEqual(scanner.preview?.studyPrompts.count, 0)
        }
    }

    func testTailReplacementShorteningAndFinalPrefixRewriteDiscardPriorPreview() {
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        scanner.update(with: header)
        XCTAssertEqual(scanner.preview?.goal, "生成界面")
        scanner.update(with: header.replacingOccurrences(of: "生成界面", with: "新的内容"))
        XCTAssertEqual(scanner.preview?.goal, "新的内容")
        scanner.update(with: "普通文字")
        XCTAssertNil(scanner.preview)
        let text = header + #", "components":[{"id":"body","kind":"body","text":"收到正文"}"#
        scanner.reconcile(text)
        XCTAssertEqual(scanner.preview?.goal, "生成界面")
        scanner.reconcile(text.replacingOccurrences(of: "生成界面", with: "重写标题"))
        XCTAssertEqual(scanner.preview?.goal, "重写标题")
        scanner.reset()
        XCTAssertNil(scanner.preview)
    }

    func testNSStringBridgeAndChunkedFencePreserveUnicodeAndActualContent() {
        func bridged(_ value: String) -> String {
            let units = Array(value.utf16)
            return units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
        }
        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        let text = "中文🦊\n" + header + #", "components":[{"id":"fox","kind":"body","text":"🦊 中文内容"}"#
        var prefix = ""
        for character in text {
            prefix.append(character)
            scanner.update(with: bridged(prefix))
        }
        XCTAssertEqual(scanner.preview?.goal, "生成界面")
        XCTAssertEqual(scanner.preview?.components.first?.text, "🦊 中文内容")
    }

    private var header: String { "```task-ui\n" + #"{"version":1,"card_id":"stream-preview","kind":"explore","goal":"生成界面""# }
}
