import XCTest
@testable import iosApp

final class IOSIntelligentUIProtocolTests: XCTestCase {
    func testPayloadDetectorFindsMarkerAcrossEveryChunkBoundary() {
        let marker = "task-ui"
        for split in 1..<marker.count {
            let prefix = "中文前言\n```" + marker.prefix(split)
            var detector = IOSIntelligentUIPayloadDetector(text: prefix)
            XCTAssertFalse(detector.mayContainPayload)
            detector.update(with: prefix + marker.dropFirst(split))
            XCTAssertTrue(detector.mayContainPayload, "Split at \(split)")
        }
    }

    func testPayloadDetectorLeavesLongOrdinaryAppendsOnTextPath() {
        var detector = IOSIntelligentUIPayloadDetector()
        var text = ""
        for _ in 0..<100 {
            text += "普通正文与 task 文字，包含 SVG 和 Three.js。\n"
            detector.update(with: text)
            XCTAssertFalse(detector.mayContainPayload)
        }
        detector.update(with: text)
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: text + "\n```task-ui\n")
        XCTAssertTrue(detector.mayContainPayload)
    }

    func testPayloadDetectorRescansShorteningAndTailReplacement() {
        var detector = IOSIntelligentUIPayloadDetector(text: "prefix task-ui")
        XCTAssertTrue(detector.mayContainPayload)
        detector.update(with: "prefix text-ui")
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: "task-ui")
        XCTAssertTrue(detector.mayContainPayload)
        detector.update(with: "plain")
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: "task-ui")
        XCTAssertTrue(detector.mayContainPayload)
    }

    func testPayloadDetectorReconcilesWholeFinalSnapshotIncludingUnchangedTail() {
        let tail = String(repeating: "a", count: 100)
        var detector = IOSIntelligentUIPayloadDetector(text: "ordinary" + tail)
        detector.reconcileFinalText("task-ui " + tail)
        XCTAssertTrue(detector.mayContainPayload)
        detector.reconcileFinalText("ordinary" + tail)
        XCTAssertFalse(detector.mayContainPayload)
        detector.reconcileFinalText("")
        XCTAssertFalse(detector.mayContainPayload)
    }

    func testPayloadDetectorHandlesNSStringBridgeAndSplitSurrogateCheckpoint() {
        func bridged(_ value: String) -> String {
            let units = Array(value.utf16)
            return units.withUnsafeBufferPointer { buffer in
                NSString(characters: buffer.baseAddress!, length: buffer.count) as String
            }
        }
        // The 24-unit checkpoint starts on the fox's low surrogate.
        let prefix = "🦊" + String(repeating: "a", count: 23)
        var detector = IOSIntelligentUIPayloadDetector(text: bridged(prefix))
        detector.update(with: bridged(prefix + "task"))
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: bridged(prefix + "task-ui"))
        XCTAssertTrue(detector.mayContainPayload)
        detector.update(with: bridged(prefix + "text-ui"))
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: bridged("中文🙂task-"))
        XCTAssertFalse(detector.mayContainPayload)
        detector.update(with: bridged("中文🙂task-ui"))
        XCTAssertTrue(detector.mayContainPayload)
    }

    func testExampleDecodesAndRoundTrips() throws {
        let card = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        XCTAssertEqual(card.id, "implementation-path")
        XCTAssertEqual(card.options.map(\.id), ["native", "web"])
        XCTAssertEqual(card.fields.first?.type, "text")
        let data = try JSONEncoder().encode(card)
        XCTAssertEqual(try IOSIntelligentUIProtocol.decode(String(decoding: data, as: UTF8.self)), card)
    }

    func testOptionalFieldsCanBeOmittedWithoutInventingInputs() throws {
        var object = try exampleObject()
        object.removeValue(forKey: "fields")
        let card = try IOSIntelligentUIProtocol.decode(json(object))
        XCTAssertTrue(card.fields.isEmpty)
        XCTAssertNil(card.options[1].recommended)
    }

    func testUnknownVersionsHaveReadableError() throws {
        var object = try exampleObject()
        object["version"] = 2
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object))) { error in
            XCTAssertTrue(error.localizedDescription.contains("v2"))
        }
    }

    func testUnsupportedActionsAndCodeFieldsAreRejected() throws {
        for key in ["tool", "script", "callback", "conversation_id", "url"] {
            var object = try exampleObject()
            object[key] = "do-something"
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)), key)
        }
        var object = try exampleObject()
        object["submit"] = ["label": "执行", "intent": "tool"]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testDuplicateOptionAndFieldIDsAreRejected() throws {
        var object = try exampleObject()
        var options = try XCTUnwrap(object["options"] as? [[String: Any]])
        options[1]["id"] = "native"
        object["options"] = options
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))

        object = try exampleObject()
        let field = try XCTUnwrap((object["fields"] as? [[String: Any]])?.first)
        object["fields"] = [field, field]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testEmptyRequiredDefinitionTextAndOverlongTextAreRejected() throws {
        for value in [" \n ", String(repeating: "目", count: 501)] {
            var object = try exampleObject()
            object["goal"] = value
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        }
        var object = try exampleObject()
        object["fields"] = [["id": "constraint", "label": " ", "required": true]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testAtMostOneRecommendedOption() throws {
        var object = try exampleObject()
        var options = try XCTUnwrap(object["options"] as? [[String: Any]])
        options[1]["recommended"] = true
        object["options"] = options
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testExpandedOptionAndInputBounds() throws {
        var object = try exampleObject()
        object["options"] = (0..<8).map { ["id": "option-\($0)", "title": "方案 \($0)", "summary": "方案内容"] }
        object["fields"] = (0..<16).map { ["id": "field-\($0)", "label": "约束 \($0)", "required": false] as [String: Any] }
        let card = try IOSIntelligentUIProtocol.decode(json(object))
        XCTAssertEqual(card.options.count, 8)
        XCTAssertEqual(card.fields.count, 16)
        object["fields"] = (0..<17).map { ["id": "field-\($0)", "label": "约束", "required": false] as [String: Any] }
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["fields"] = []
        object["options"] = [["id": "one", "title": "唯一方案", "summary": "没有决策"]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testPlainTextAndVisualWidgetArePreservedExactly() {
        let text = "开头\n\n```show-widget\n{\"renderer\":\"svg\"}\n```\n\n末尾  \n"
        XCTAssertEqual(IOSIntelligentUIProtocol.parse(text, isStreaming: false), [.text(text)])
    }

    func testTextOrderAndWhitespaceAroundTaskBlockArePreserved() throws {
        let before = "开头  \n\n"
        let after = "\n结束\n"
        let segments = IOSIntelligentUIProtocol.parse(before + fencedExample + after, isStreaming: false)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first, .text(before))
        XCTAssertEqual(segments.last, .text(after))
        guard case .card(let card) = segments[1] else { return XCTFail("Expected decision card") }
        XCTAssertEqual(card.cardID, "implementation-path")
    }

    func testPartialFenceIsLoadingUntilFinalSnapshot() {
        let partial = "文字\n```task-ui\n{\"version\":1"
        let streaming = IOSIntelligentUIProtocol.parse(partial, isStreaming: true)
        XCTAssertEqual(streaming, [.text("文字\n"), .loading])
        let final = IOSIntelligentUIProtocol.parse(partial, isStreaming: false)
        guard case .invalid(let raw, let reason) = final.last else { return XCTFail("Expected incomplete error") }
        XCTAssertEqual(raw, "```task-ui\n{\"version\":1")
        XCTAssertTrue(reason.contains("未完整结束"))
    }

    func testCompleteFenceCanPreviewDuringStreamingWithoutChangingCardIdentity() {
        let streaming = IOSIntelligentUIProtocol.parse(fencedExample, isStreaming: true)
        let final = IOSIntelligentUIProtocol.parse("新增前言\n" + fencedExample, isStreaming: false)
        guard case .card(let preview) = streaming.first,
              case .card(let completed) = final.last else { return XCTFail("Expected cards") }
        XCTAssertEqual(preview, completed)
        XCTAssertEqual(preview.id, completed.id)
    }

    func testInvalidCardPreservesRawBlockAndAllowsNextValidCard() {
        let bad = "```task-ui\n{\"version\":2}\n```\n"
        let segments = IOSIntelligentUIProtocol.parse(bad + fencedExample, isStreaming: false)
        guard case .invalid(let raw, _) = segments.first,
              case .card = segments.last else { return XCTFail("Expected invalid block then valid card") }
        XCTAssertEqual(raw, bad)
    }

    func testOnlyFirstValidCardIsOperable() {
        let segments = IOSIntelligentUIProtocol.parse(fencedExample + fencedExample, isStreaming: false)
        XCTAssertEqual(segments.count, 2)
        guard case .card = segments[0], case .invalid(let raw, let reason) = segments[1] else {
            return XCTFail("Expected first card and duplicate-card explanation")
        }
        XCTAssertEqual(raw, fencedExample)
        XCTAssertTrue(reason.contains("一张任务卡"))
    }

    func testTaskExamplesInsideOrdinaryFencesAndInlineTextAreNotOperable() {
        let examples = [
            "````markdown\n" + fencedExample + "````\n",
            "~~~markdown\n" + fencedExample + "~~~\n",
            "正文中的 ```task-ui 只是文字。",
            "    ```task-ui\n{}\n    ```\n"
        ]
        for example in examples {
            XCTAssertEqual(IOSIntelligentUIProtocol.parse(example, isStreaming: false), [.text(example)])
        }
    }

    func testAllEightyNativeKindsDecodeInRealTaskCards() throws {
        for kind in IOSIntelligentUIComponent.Kind.allCases {
            var object = try exampleObject()
            object["fields"] = [
                ["id": "value", "label": "用户输入", "required": false],
                ["id": "open", "label": "展示状态", "required": false]
            ]
            let node = IOSIntelligentUIComponentTests.sample(kind)
            object["components"] = try componentObjects([node])
            let card = try IOSIntelligentUIProtocol.decode(json(object))
            XCTAssertEqual(card.components, [node], kind.rawValue)
            XCTAssertEqual(try IOSIntelligentUIProtocol.decode(String(decoding: JSONEncoder().encode(card), as: UTF8.self)), card)
        }
    }

    func testNativeTypedFieldsAndDefaultsStayCompatible() throws {
        let samples: [(IOSIntelligentUIComponent.Kind, String)] = [
            (.textField, "text"), (.slider, "number"), (.toggle, "bool"),
            (.datePicker, "date"), (.timePicker, "time"), (.singleChoice, "choice"),
            (.multiChoice, "multiChoice"), (.disclosure, "presentation")
        ]
        for (kind, type) in samples {
            var object = try exampleObject()
            var node = IOSIntelligentUIComponentTests.sample(kind)
            node.fieldID = "input"
            object["fields"] = [["id": "input", "label": "输入", "required": false, "type": type]]
            object["components"] = try componentObjects([node])
            let card = try IOSIntelligentUIProtocol.decode(json(object))
            XCTAssertEqual(card.boundComponent(for: "input")?.kind, kind)
            XCTAssertEqual(card.submissionFields.count, kind.isPresentationField ? 0 : 1)
        }
        let plain = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        XCTAssertTrue(plain.components.isEmpty)
        XCTAssertEqual(plain.submissionFields, plain.fields)
    }

    func testTypedUnboundAndPresentationRequiredFieldsAreRejected() throws {
        for type in ["number", "bool", "date", "time", "choice", "multiChoice", "presentation", "script"] {
            var object = try exampleObject()
            object["fields"] = [["id": "input", "label": "输入", "required": false, "type": type]]
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)), type)
        }
        var object = try exampleObject()
        object["fields"] = [["id": "open", "label": "展开状态", "required": true, "type": "presentation"]]
        object["components"] = [["id": "details", "kind": "disclosure", "field_id": "open", "title": "详情"]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["fields"] = [["id": "open", "label": "展开状态", "required": false, "type": "number"]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testUnknownNestedComponentKeysCannotBecomeHiddenExecutionInstructions() throws {
        let payloads: [[String: Any]] = [
            ["id": "group", "kind": "column", "children": [["id": "child", "kind": "body", "text": "text", "script": "run()"]]],
            ["id": "choose", "kind": "singleChoice", "field_id": "constraints", "options": [["id": "a", "label": "A", "tool": "delete"]]],
            ["id": "table", "kind": "table", "rows": [["label": "A", "callback": "execute"]]],
            ["id": "styled", "kind": "body", "style": ["css": "position:fixed"]],
            ["id": "group", "kind": "column", "children": ["invalid"]]
        ]
        for payload in payloads {
            var object = try exampleObject()
            object["components"] = [payload]
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        }
    }

    func testComponentBoundariesApplyBeforeDeepJSONIsDecoded() throws {
        var node: [String: Any] = ["id": "leaf", "kind": "body", "text": "内容"]
        for index in 1..<9 { node = ["id": "level-\(index)", "kind": "column", "children": [node]] }
        var object = try exampleObject()
        object["components"] = [node]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["components"] = (0..<161).map { ["id": "node-\($0)", "kind": "body", "text": "内容"] }
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["components"] = [["id": "unknown", "kind": "shader"]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["components"] = [["id": "missing-field", "kind": "toggle", "field_id": "not-declared"]]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    func testRequiredValuesAndSubmissionSummariesUseComponentMeaning() throws {
        var object = try exampleObject()
        object["fields"] = [
            ["id": "choice", "label": "额外能力", "required": true, "type": "multiChoice"],
            ["id": "open", "label": "展开详情", "required": false, "type": "presentation"],
            ["id": "enabled", "label": "允许联网", "required": true, "type": "bool"]
        ]
        object["components"] = [
            ["id": "choice", "kind": "multiChoice", "field_id": "choice", "options": [["id": "offline", "label": "离线可用"], ["id": "fast", "label": "优先性能"]]],
            ["id": "open", "kind": "disclosure", "field_id": "open", "title": "详情"],
            ["id": "enabled", "kind": "toggle", "field_id": "enabled", "title": "联网"]
        ]
        let card = try IOSIntelligentUIProtocol.decode(json(object))
        let field = try XCTUnwrap(card.fields.first)
        XCTAssertFalse(card.requiredFieldHasValue(field, values: ["choice": "[]"]))
        XCTAssertTrue(card.requiredFieldHasValue(field, values: ["choice": #"["offline"]"#]))
        XCTAssertEqual(card.fieldValueSummary(#"["offline"]"#, for: field), "离线可用")
        XCTAssertEqual(card.submissionFields.map(\.id), ["choice", "enabled"])
        XCTAssertTrue(card.requiredFieldHasValue(card.fields[2], values: ["enabled": "false"]))
        XCTAssertEqual(card.fieldValueSummary("false", for: card.fields[2]), "否")
    }

    func testNativeStyleTokensRoundTripAndVisualOutputRemainsSeparate() throws {
        var object = try exampleObject()
        object["components"] = [["id": "summary", "kind": "body", "text": "内容", "style": ["tone": "accent", "emphasis": "outlined", "density": "compact", "alignment": "center", "spacing": "small", "padding": "medium"]]]
        let card = try IOSIntelligentUIProtocol.decode(json(object))
        XCTAssertEqual(card.components.first?.style?.padding, .medium)
        XCTAssertTrue(IOSIntelligentUIProtocol.capabilityPrompt.contains("80 个原生组件"))
        let widget = "```show-widget\n{\"renderer\":\"three.js\",\"widget_code\":\"scene\"}\n```"
        XCTAssertEqual(IOSIntelligentUIProtocol.parse(widget, isStreaming: false), [.text(widget)])
    }

    func testSharedBindingAcceptsNumericViewsAndRejectsIncompatibleSemantics() throws {
        var object = try exampleObject()
        object["fields"] = [["id": "budget", "label": "预算", "required": false, "type": "number"]]
        object["components"] = [
            ["id": "slider", "kind": "slider", "field_id": "budget", "min": 0, "max": 100],
            ["id": "stepper", "kind": "stepper", "field_id": "budget", "min": 0, "max": 100]
        ]
        XCTAssertEqual(try IOSIntelligentUIProtocol.decode(json(object)).components.count, 2)
        object["fields"] = [["id": "budget", "label": "输入", "required": false]]
        object["components"] = [
            ["id": "text", "kind": "textField", "field_id": "budget"],
            ["id": "toggle", "kind": "toggle", "field_id": "budget"]
        ]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
        object["components"] = [
            ["id": "toggle", "kind": "toggle", "field_id": "budget"],
            ["id": "open", "kind": "disclosure", "field_id": "budget"]
        ]
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json(object)))
    }

    private func componentObjects(_ components: [IOSIntelligentUIComponent]) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(components)) as? [[String: Any]])
    }

    private var fencedExample: String { "```task-ui\n" + IOSIntelligentUIProtocol.exampleJSON + "\n```\n" }

    private func exampleObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IOSIntelligentUIProtocol.exampleJSON.utf8)) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
