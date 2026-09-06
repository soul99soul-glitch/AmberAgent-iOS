import Foundation

/// A deliberately small JSON Schema value used by plugin tool contracts.
///
/// The schema is retained as JSON so the exact declaration can be forwarded to
/// providers. Validation implements a deliberately bounded vocabulary:
/// `type`, `properties`, `required`, `items`, `additionalProperties`, `enum`,
/// and `description`. Unknown keywords fail manifest decoding instead
/// of being silently ignored.
struct IOSPluginJSONSchema: Codable, Equatable, Sendable {
    private let value: IOSRecipeJSONValue

    /// Creates a schema after checking that its supported structural keywords
    /// have valid JSON shapes. Unknown keywords are rejected.
    init(_ value: IOSRecipeJSONValue) throws {
        let issues = Self.schemaIssues(in: value, at: "$")
        guard issues.isEmpty else {
            throw IOSPluginJSONSchemaError.invalidSchema(issues[0])
        }
        self.value = value
    }

    /// Internal constructor for schemas assembled from already typed legacy
    /// manifests. Those values are built from the same bounded shapes above.
    fileprivate init(unchecked value: IOSRecipeJSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let value = try IOSRecipeJSONValue(from: decoder)
        try self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Decodes one standalone JSON Schema object.
    static func decode(_ data: Data) throws -> IOSPluginJSONSchema {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as IOSPluginJSONSchemaError {
            throw error
        } catch {
            throw IOSPluginJSONSchemaError.invalidJSON(error.localizedDescription)
        }
    }

    /// Deterministic JSON used in plugin package canonicalization and for
    /// passing the same declaration to KMP/provider layers.
    var canonicalJSONString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? String(decoding: encoder.encode(self), as: UTF8.self)
    }

    /// Input contracts are always object contracts because tool arguments are
    /// represented as a JSON object. An empty schema is valid JSON Schema for
    /// output, but is too broad to serve as an input contract.
    var inputSchemaIssues: [IOSPluginJSONSchemaIssue] {
        var issues: [IOSPluginJSONSchemaIssue] = []
        let node = Node(value)
        let types = node.types
        let isObject = types?.contains("object") == true || (types == nil && node.properties != nil)
        if !isObject {
            issues.append(IOSPluginJSONSchemaIssue(path: "$", message: "input_schema 根节点必须是 object。"))
        }
        if node.properties == nil {
            issues.append(IOSPluginJSONSchemaIssue(path: "$.properties", message: "input_schema 根节点必须明确声明 properties。"))
        }
        if let types, types.contains(where: { $0 != "object" }) {
            issues.append(IOSPluginJSONSchemaIssue(path: "$.type", message: "input_schema 根节点只能允许 object。"))
        }
        if let properties = node.properties {
            for name in properties.keys where !IOSRecipeNames.isValidMemberName(name) {
                issues.append(IOSPluginJSONSchemaIssue(path: "$.properties.\(name)", message: "输入名无效。"))
            }
            if let required = node.required {
                for name in required where properties[name] == nil {
                    issues.append(IOSPluginJSONSchemaIssue(path: "$.required", message: "required 字段「\(name)」未在 properties 中声明。"))
                }
            }
        }
        return issues
    }

    func hasStringProperty(named name: String) -> Bool {
        guard let property = Node(value).properties?[name] else { return false }
        return Node(property).types == ["string"]
    }

    /// Validates one JSON value, including nested objects and arrays.
    func validateValue(_ candidate: IOSRecipeJSONValue) -> [IOSPluginJSONSchemaIssue] {
        validateValue(candidate, against: value, at: "$")
    }

    /// Checks compatibility with the coarse legacy output declaration. A
    /// schema without `type` remains open; `number` also admits `integer`.
    func allowsLegacyOutputType(_ output: IOSPluginOutputType) -> Bool {
        guard output != .json else { return true }
        let types = Node(value).types
        guard let types else { return true }
        if output == .number, types.contains("integer") { return true }
        return types.contains(output.rawValue)
    }

    /// Builds an explicit object schema matching the legacy Recipe input map.
    /// Requiredness is kept identical to the old runtime: every declared input
    /// is required and unknown keys are rejected.
    static func legacyInputSchema(
        from inputs: [String: IOSRecipeInputType]
    ) -> IOSPluginJSONSchema {
        let properties = inputs.reduce(into: [String: IOSRecipeJSONValue]()) { result, entry in
            result[entry.key] = .object(["type": .string(entry.value.rawValue)])
        }
        let required = inputs.keys.sorted().map(IOSRecipeJSONValue.string)
        return IOSPluginJSONSchema(unchecked: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ]))
    }

    /// Converts the coarse legacy output declaration to a schema for callers
    /// that want one validation seam. `.json` intentionally remains open.
    static func legacyOutputSchema(from output: IOSPluginOutputType) -> IOSPluginJSONSchema {
        switch output {
        case .json:
            return IOSPluginJSONSchema(unchecked: .object([:]))
        case .object, .array, .string, .number, .boolean:
            return IOSPluginJSONSchema(unchecked: .object(["type": .string(output.rawValue)]))
        }
    }
}

struct IOSPluginJSONSchemaIssue: Equatable, Sendable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "\(path)：\(message)" }
}

enum IOSPluginJSONSchemaError: LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case invalidSchema(IOSPluginJSONSchemaIssue)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return "JSON Schema 不是合法 JSON：\(message)"
        case .invalidSchema(let issue):
            return "JSON Schema\(issue)"
        }
    }
}

private extension IOSPluginJSONSchema {
    struct Node {
        let object: [String: IOSRecipeJSONValue]

        init(_ value: IOSRecipeJSONValue) {
            if case .object(let object) = value {
                self.object = object
            } else {
                self.object = [:]
            }
        }

        var types: [String]? {
            guard let raw = object["type"] else { return nil }
            switch raw {
            case .string(let type): return [type]
            case .array(let values):
                let strings = values.compactMap { value -> String? in
                    guard case .string(let type) = value else { return nil }
                    return type
                }
                return strings.count == values.count ? strings : nil
            default: return nil
            }
        }

        var properties: [String: IOSRecipeJSONValue]? {
            guard case .object(let properties) = object["properties"] else { return nil }
            return properties
        }

        var required: [String]? {
            guard case .array(let values) = object["required"] else { return nil }
            let names = values.compactMap { value -> String? in
                guard case .string(let name) = value else { return nil }
                return name
            }
            return names.count == values.count ? names : nil
        }

        var items: IOSRecipeJSONValue? {
            object["items"]
        }

        var additionalProperties: IOSRecipeJSONValue? {
            object["additionalProperties"]
        }

        var rejectsAdditionalProperties: Bool {
            if case .bool(false)? = additionalProperties { return true }
            return false
        }

        var enumValues: [IOSRecipeJSONValue]? {
            guard case .array(let values) = object["enum"] else { return nil }
            return values
        }
    }

    static let supportedTypes: Set<String> = [
        "string", "number", "integer", "boolean", "object", "array", "null",
    ]

    static func schemaIssues(
        in value: IOSRecipeJSONValue,
        at path: String
    ) -> [IOSPluginJSONSchemaIssue] {
        guard case .object(let object) = value else {
            return [IOSPluginJSONSchemaIssue(path: path, message: "Schema 节点必须是 JSON object。")]
        }
        var issues: [IOSPluginJSONSchemaIssue] = []
        let node = Node(value)

        if let rawType = object["type"] {
            switch rawType {
            case .string(let type):
                if !supportedTypes.contains(type) {
                    issues.append(IOSPluginJSONSchemaIssue(path: "\(path).type", message: "不支持的 type「\(type)」。"))
                }
            case .array(let types):
                var parsed: [String] = []
                for (index, type) in types.enumerated() {
                    guard case .string(let name) = type else {
                        issues.append(IOSPluginJSONSchemaIssue(path: "\(path).type[\(index)]", message: "type 数组只能包含字符串。"))
                        continue
                    }
                    parsed.append(name)
                    if !supportedTypes.contains(name) {
                        issues.append(IOSPluginJSONSchemaIssue(path: "\(path).type[\(index)]", message: "不支持的 type「\(name)」。"))
                    }
                }
                if types.isEmpty || Set(parsed).count != parsed.count {
                    issues.append(IOSPluginJSONSchemaIssue(path: "\(path).type", message: "type 数组不能为空且不能重复。"))
                }
            default:
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).type", message: "type 必须是字符串或字符串数组。"))
            }
        }

        if let rawProperties = object["properties"] {
            guard case .object(let properties) = rawProperties else {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).properties", message: "properties 必须是 JSON object。"))
                return issues
            }
            for (name, child) in properties.sorted(by: { $0.key < $1.key }) {
                issues += schemaIssues(in: child, at: "\(path).properties.\(name)")
            }
        }

        if let rawRequired = object["required"] {
            guard case .array(let required) = rawRequired else {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).required", message: "required 必须是字符串数组。"))
                return issues
            }
            var names: [String] = []
            for (index, name) in required.enumerated() {
                guard case .string(let name) = name else {
                    issues.append(IOSPluginJSONSchemaIssue(path: "\(path).required[\(index)]", message: "required 只能包含字符串。"))
                    continue
                }
                names.append(name)
            }
            if Set(names).count != names.count {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).required", message: "required 不能包含重复字段。"))
            }
        }

        if let rawItems = object["items"] {
            if case .object = rawItems {
                issues += schemaIssues(in: rawItems, at: "\(path).items")
            } else {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).items", message: "items 必须是 Schema object。"))
            }
        }

        if let rawAdditional = object["additionalProperties"] {
            switch rawAdditional {
            case .bool:
                break
            case .object:
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).additionalProperties", message: "additionalProperties 只支持 boolean。"))
            default:
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).additionalProperties", message: "additionalProperties 必须是 boolean。"))
            }
        }

        if let rawEnum = object["enum"] {
            guard case .array(let values) = rawEnum else {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).enum", message: "enum 必须是非空数组。"))
                return issues
            }
            if values.isEmpty {
                issues.append(IOSPluginJSONSchemaIssue(path: "\(path).enum", message: "enum 不能是空数组。"))
            }
        }

        for key in object.keys where !allowedKeywords.contains(key) {
            issues.append(IOSPluginJSONSchemaIssue(path: "\(path).\(key)", message: "不支持的 JSON Schema 关键字。"))
        }

        for keyword in ["description"] where object[keyword] != nil {
            if case .string = object[keyword]! {
                continue
            }
            issues.append(IOSPluginJSONSchemaIssue(path: "\(path).\(keyword)", message: "\(keyword) 必须是字符串。"))
        }

        if let types = node.types, types.contains("object") == false, object["properties"] != nil {
            issues.append(IOSPluginJSONSchemaIssue(path: "\(path).properties", message: "带 properties 的节点必须允许 object。"))
        }
        return issues
    }

    static let allowedKeywords: Set<String> = [
        "type", "properties", "required", "items", "additionalProperties",
        "enum", "description",
    ]

    func validateValue(
        _ candidate: IOSRecipeJSONValue,
        against schemaValue: IOSRecipeJSONValue,
        at path: String
    ) -> [IOSPluginJSONSchemaIssue] {
        let node = Node(schemaValue)
        var issues: [IOSPluginJSONSchemaIssue] = []

        if let enumValues = node.enumValues, !enumValues.contains(candidate) {
            issues.append(IOSPluginJSONSchemaIssue(path: path, message: "值不在 enum 允许范围内。"))
        }

        if let types = node.types, !types.contains(where: { matches(candidate, type: $0) }) {
            issues.append(IOSPluginJSONSchemaIssue(path: path, message: "值类型不符合 type「\(types.joined(separator: "、"))」。"))
            return issues
        }

        if case .object(let object) = candidate {
            if let required = node.required {
                for name in required where object[name] == nil {
                    issues.append(IOSPluginJSONSchemaIssue(path: "\(path).\(name)", message: "缺少必填字段。"))
                }
            }
            let properties = node.properties ?? [:]
            for (name, child) in object.sorted(by: { $0.key < $1.key }) {
                if let childSchema = properties[name] {
                    issues += validateValue(child, against: childSchema, at: "\(path).\(name)")
                } else if node.rejectsAdditionalProperties {
                    issues.append(IOSPluginJSONSchemaIssue(path: "\(path).\(name)", message: "不允许额外字段。"))
                }
            }
        }

        if case .array(let items) = candidate,
           let itemSchema = node.items {
            for (index, item) in items.enumerated() {
                issues += validateValue(item, against: itemSchema, at: "\(path)[\(index)]")
            }
        }
        return issues
    }

    func matches(_ value: IOSRecipeJSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.string, "string"), (.bool, "boolean"), (.object, "object"), (.array, "array"), (.null, "null"):
            return true
        case (.number(let number), "number"):
            return number.isFinite
        case (.number(let number), "integer"):
            return number.isFinite && number.rounded(.towardZero) == number
        default:
            return false
        }
    }
}
