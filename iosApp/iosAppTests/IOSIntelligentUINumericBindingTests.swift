import XCTest
@testable import iosApp

final class IOSIntelligentUINumericBindingTests: XCTestCase {
    func testNumericExploreExampleUsesRealTypedOwnersAndAllOutputKinds() throws {
        let definition = try example()
        XCTAssertEqual(definition.kind, "explore")
        XCTAssertEqual(definition.fields.first?.type, "number")
        XCTAssertEqual(Set(definition.components.filter { $0.valueFieldID != nil }.map(\.kind)), [.metric, .progress, .stepProgress])
        XCTAssertEqual(definition.components.last?.rows?.first?.valueFieldID, "chapters")
        XCTAssertEqual(IOSIntelligentUIComponent.Kind.allCases.count, 80)
        for json in [IOSIntelligentUIProtocol.exampleJSON, IOSIntelligentUIProtocol.studyExampleJSON,
                     IOSIntelligentUIProtocol.formExampleJSON, IOSIntelligentUIProtocol.exploreExampleJSON] {
            XCTAssertNoThrow(try IOSIntelligentUIProtocol.decode(json))
        }
    }

    func testDraftChangesResolveAllOutputsAndRowsWithoutWritingInitialValues() throws {
        let definition = try example()
        let owner = try XCTUnwrap(definition.boundComponent(for: "chapters"))
        let owners = ["chapters": owner]
        var values: [String: String] = [:]
        for component in definition.components where component.valueFieldID != nil {
            XCTAssertEqual(resolve(component, values: values, owners: owners), 1)
        }
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(nil, input: owner), 1)
        XCTAssertEqual(values, [:], "Displaying a preview must not fill a required field")
        XCTAssertFalse(definition.requiredFieldHasValue(try XCTUnwrap(definition.fields.first), values: values))
        values["chapters"] = "3"
        for component in definition.components where component.valueFieldID != nil {
            XCTAssertEqual(resolve(component, values: values, owners: owners), 3)
        }
        let row = try XCTUnwrap(definition.components.last?.rows?.first)
        XCTAssertEqual(IOSIntelligentUIComponentValues.resolveNumber(value: row.value, valueFieldID: row.valueFieldID,
            draftValues: values, fieldComponents: owners), 3)
        XCTAssertNoThrow(try IOSIntelligentUIComponentCatalog.validateDraftValues(values, components: definition.components))
        values = [:]
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(values["chapters"], input: owner), 1)
        XCTAssertEqual(values, [:])
    }

    func testNonemptyInvalidNumbersRemainInvalidInsteadOfBecomingZeroOrPreview() throws {
        let definition = try example()
        let owner = try XCTUnwrap(definition.boundComponent(for: "chapters"))
        let output = try XCTUnwrap(definition.components.first(where: { $0.kind == .metric }))
        for raw in ["abc", "NaN", "nan", "inf", "1e999", "-1", "5", " "] {
            let values = ["chapters": raw]
            XCTAssertNil(IOSIntelligentUIComponentValues.numericValue(raw, input: owner), raw)
            XCTAssertNil(resolve(output, values: values, owners: ["chapters": owner]), raw)
            XCTAssertFalse(IOSIntelligentUIComponentValues.hasValidNumericDraftValues(values, components: definition.components), raw)
            XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateDraftValues(values, components: definition.components), raw)
        }
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue("0", input: owner), 0, "An explicit zero is valid")
    }

    func testNumberFieldAndRatingDefaultRulesAndValidationMatchPreview() {
        let field = IOSIntelligentUIComponent(id: "n", kind: .numberField, fieldID: "n", min: 1, max: 10)
        XCTAssertNil(IOSIntelligentUIComponentValues.numericValue(nil, input: field))
        var fieldWithPreview = field
        fieldWithPreview.value = 4
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue("", input: fieldWithPreview), 4)
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue("2.5", input: fieldWithPreview), 2.5)
        XCTAssertNil(IOSIntelligentUIComponentValues.numericValue("20", input: fieldWithPreview))
        let rating = IOSIntelligentUIComponent(id: "r", kind: .rating, fieldID: "n", value: 3, max: 5)
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(nil, input: rating), 3)
        XCTAssertNil(IOSIntelligentUIComponentValues.numericValue("2.5", input: rating))
        XCTAssertNil(IOSIntelligentUIComponentValues.numericValue("0", input: rating))
        let slider = IOSIntelligentUIComponent(id: "s", kind: .slider, fieldID: "n", min: 2, max: 10)
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(nil, input: slider), 2)
    }

    func testConfirmingPreviewAndFineStepsPreservesNumericPrecision() throws {
        for value in [0.0000001, 1.0000001, 0.123456789012345] {
            let input = IOSIntelligentUIComponent(id: "precise", kind: .numberField, fieldID: "amount", value: value, min: 0.00000001, max: 2)
            let initial = try XCTUnwrap(IOSIntelligentUIComponentValues.numericValue(nil, input: input))
            let stored = IOSIntelligentUIComponentValues.numericDraftString(initial)
            XCTAssertEqual(Double(stored), value)
            XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(stored, input: input), value)
            XCTAssertNoThrow(try IOSIntelligentUIComponentCatalog.validateDraftValues(["amount": stored], components: [input]))
        }
        let slider = IOSIntelligentUIComponent(id: "fine-slider", kind: .slider, fieldID: "amount", min: 0, max: 1, step: 0.0000001)
        let stored = IOSIntelligentUIComponentValues.numericDraftString(0.0000001)
        XCTAssertEqual(IOSIntelligentUIComponentValues.numericValue(stored, input: slider), 0.0000001)
    }

    func testNumericDisplayKeepsTinyValuesVisibleAndOrdinaryFormatting() {
        for value in [0.0000001, -0.0000001, 1e-20, -1e-20] {
            let display = IOSIntelligentUIComponentValues.numericDisplayString(value)
            XCTAssertNotEqual(display, 0.0.formatted())
            XCTAssertNotEqual(display, (-0.0).formatted())
            XCTAssertTrue(display.contains("1"), display)
        }
        for value in [0.0, 317.0, 689.125, 1_280.5] {
            XCTAssertEqual(IOSIntelligentUIComponentValues.numericDisplayString(value), value.formatted())
        }
        XCTAssertNotEqual(IOSIntelligentUIComponentValues.numericDisplayString(1.0000001), 1.0.formatted())
    }

    func testUnknownUntypedOwnerlessAndReservedReferencesAreRejected() throws {
        let invalid = [
            try changedExample { $0["fields"] = [["id": "chapters", "label": "章节", "required": true, "type": "text"]] },
            try changedExample { root in
                var nodes = root["components"] as! [[String: Any]]
                nodes.removeFirst()
                root["components"] = nodes
            },
            try changedExample { root in
                var nodes = root["components"] as! [[String: Any]]
                nodes[1]["value_field_id"] = "other-card:chapters"
                root["components"] = nodes
            },
            try changedExample { root in
                var fields = root["fields"] as! [[String: Any]]
                fields[0]["id"] = IOSIntelligentUIStudySession.storageKey
                root["fields"] = fields
            }
        ]
        for json in invalid { XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json)) }
    }

    func testValueReferenceCannotBeMixedWithLiteralOrAttachedToUnsupportedKinds() throws {
        for kind in ["metric", "progress", "stepProgress", "body", "slider"] {
            let json = try changedExample { root in
                var nodes = root["components"] as! [[String: Any]]
                nodes[1]["kind"] = kind
                nodes[1]["value"] = 2
                root["components"] = nodes
            }
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json), kind)
        }
        for change in ["both", "table", "missing", "unknown"] {
            let json = try changedExample { root in
                var nodes = root["components"] as! [[String: Any]]
                var rows = nodes[4]["rows"] as! [[String: Any]]
                switch change {
                case "both": rows[0]["value"] = 2
                case "table": nodes[4]["kind"] = "table"
                case "missing": rows[0].removeValue(forKey: "value_field_id")
                default: rows[0]["formula"] = "chapters * 2"
                }
                nodes[4]["rows"] = rows
                root["components"] = nodes
            }
            XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(json), change)
        }
    }

    func testOnlyReferencedFieldsRequireUnambiguousMultipleOwners() throws {
        let matching = try changedExample { root in
            var nodes = root["components"] as! [[String: Any]]
            var second = nodes[0]
            second["id"] = "second-input"
            second["kind"] = "slider"
            nodes.append(second)
            root["components"] = nodes
        }
        XCTAssertNoThrow(try IOSIntelligentUIProtocol.decode(matching))
        let conflicting = try changedExample { root in
            var nodes = root["components"] as! [[String: Any]]
            var second = nodes[0]
            second["id"] = "second-input"
            second["value"] = 2
            nodes.append(second)
            root["components"] = nodes
        }
        XCTAssertThrowsError(try IOSIntelligentUIProtocol.decode(conflicting))
        var noReferences = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(conflicting.utf8)) as? [String: Any])
        let nodes = noReferences["components"] as! [[String: Any]]
        noReferences["components"] = [nodes[0], nodes.last!]
        XCTAssertNoThrow(try IOSIntelligentUIProtocol.decode(String(decoding: JSONSerialization.data(withJSONObject: noReferences), as: UTF8.self)))
    }

    func testPreviewReferencesValidateAgainstExistingRealFieldAndOwnerContext() throws {
        let definition = try example()
        let preview = try IOSIntelligentUIProtocol.decodePreviewComponent(
            #"{"id":"live-preview","kind":"lineChart","rows":[{"label":"当前","value_field_id":"chapters"},{"label":"总量","value":4}]}"#,
            allowedFieldIDs: Set(definition.fields.map(\.id))
        )
        XCTAssertNoThrow(try IOSIntelligentUIComponentCatalog.validateValueReferences([preview],
            numberFieldIDs: ["chapters"], inputComponents: definition.components))
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateValueReferences([preview],
            numberFieldIDs: [], inputComponents: definition.components))
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateValueReferences([preview],
            numberFieldIDs: ["chapters"], inputComponents: []))
    }

    private func example() throws -> IOSIntelligentUICardDefinition {
        try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.numericExploreExampleJSON)
    }

    private func resolve(_ output: IOSIntelligentUIComponent, values: [String: String],
                         owners: [String: IOSIntelligentUIComponent]) -> Double? {
        IOSIntelligentUIComponentValues.resolveNumber(value: output.value, valueFieldID: output.valueFieldID,
                                                       draftValues: values, fieldComponents: owners)
    }

    private func changedExample(_ change: (inout [String: Any]) -> Void) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IOSIntelligentUIProtocol.numericExploreExampleJSON.utf8)) as? [String: Any])
        change(&object)
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
