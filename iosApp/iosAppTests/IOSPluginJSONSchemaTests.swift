import XCTest
@testable import iosApp

final class IOSPluginJSONSchemaTests: XCTestCase {
    func testStructuredSchemaValidatesNestedOptionalArrayAndEnumValues() throws {
        let schema = try IOSPluginJSONSchema.decode(Data(#"""
        {
            "type": "object",
            "properties": {
                "query": {"type": "string", "enum": ["swift", "kotlin"]},
                "options": {
                    "type": "object",
                    "properties": {"limit": {"type": "integer"}},
                    "required": ["limit"],
                    "additionalProperties": false
                },
                "tags": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["query"],
            "additionalProperties": false
        }
        """#.utf8))

        let valid: [String: IOSRecipeJSONValue] = [
            "query": .string("swift"),
            "options": .object(["limit": .number(2)]),
            "tags": .array([.string("ios"), .string("kmp")]),
        ]
        XCTAssertTrue(schema.validateValue(.object(valid)).isEmpty)

        let invalid = schema.validateValue(.object([
            "query": .string("rust"),
            "options": .object([:]),
            "tags": .array([.number(1)]),
            "extra": .bool(true),
        ]))
        XCTAssertTrue(invalid.contains { $0.path == "$.query" })
        XCTAssertTrue(invalid.contains { $0.path == "$.options.limit" })
        XCTAssertTrue(invalid.contains { $0.path == "$.tags[0]" })
        XCTAssertTrue(invalid.contains { $0.path == "$.extra" })
    }

    func testOpenSchemaKeepsStandardKeywordSemanticsWithoutExplicitTypes() throws {
        let schema = try IOSPluginJSONSchema.decode(Data(#"{"properties":{"values":{"items":{"type":"string"}}}}"#.utf8))
        XCTAssertTrue(schema.validateValue(.object(["extra": .bool(true)])).isEmpty)
        XCTAssertEqual(schema.validateValue(.object(["values": .array([.number(1)])])).first?.path, "$.values[0]")
    }

    func testPluginManifestUsesSnakeCaseSchemasAndOmitsAbsentFields() throws {
        let legacy = IOSPluginToolManifest(name: "legacy", script: "scripts/legacy.js")
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as? [String: Any])
        XCTAssertNil(legacyObject["input_schema"])
        XCTAssertNil(legacyObject["output_schema"])

        let inputSchema = try IOSPluginJSONSchema.decode(Data(#"{"type":"object","properties":{"name":{"type":"string"}},"required":[]}"#.utf8))
        let outputSchema = try IOSPluginJSONSchema.decode(Data(#"{"type":"array","items":{"type":"string"}}"#.utf8))
        let structured = IOSPluginToolManifest(
            name: "structured",
            script: "scripts/structured.js",
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(structured)
        ) as? [String: Any]
        XCTAssertNotNil(encoded?["input_schema"])
        XCTAssertNotNil(encoded?["output_schema"])
        XCTAssertEqual((encoded?["input_schema"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual((encoded?["output_schema"] as? [String: Any])?["type"] as? String, "array")
    }

    func testInputSchemaRequiresObjectRoot() throws {
        let schema = try IOSPluginJSONSchema.decode(Data(#"{"type":"array","items":{"type":"string"}}"#.utf8))
        XCTAssertFalse(schema.inputSchemaIssues.isEmpty)
        XCTAssertTrue(schema.inputSchemaIssues.contains { $0.path == "$" })
    }

    func testUnknownSchemaKeywordIsRejected() {
        XCTAssertThrowsError(try IOSPluginJSONSchema.decode(Data(#"{"type":"string","pattern":".*"}"#.utf8)))
    }
}
