import Foundation

// MARK: - amber.recipe.v1 manifest model, canonical encoding and validator
//
// Declarative Recipe plugin model (§10 of
// the iOS Recipe runtime contract).
//
// Wire format decision: the manifest is JSON (Codable), not YAML. §10.2 of the
// plan shows a YAML example, but that is only a semantic illustration — a
// recipe package is a single `recipe.json` file, and its canonical bytes are
// the JSON produced by `canonicalJSONData()` (deterministically re-encoded,
// keys sorted at every level), so "executed = stored = hashed" (invariant 5)
// holds across preview, apply, rollback and execution.
//
// Grammar / budget decisions (documented here, enforced below):
// - recipe `name`: `^[a-z][a-z0-9_]{1,31}$` (2..32 chars). It will later be
//   exposed to the model as the tool `recipe__<name>` (§13.2), so the charset
//   excludes characters that cannot appear in a ToolId.
// - input names / step ids / output names: `^[a-z][a-z0-9_]{1,32}$` — the
//   same conservative charset keeps binding syntax unambiguous.
// - step-output JSON fields referenced by bindings: `^[A-Za-z_][A-Za-z0-9_]*$`
//   (a JSON key may be anything, but only identifier-like keys can be bound).
// - binding grammar: `"${input.<name>}"` or `"${step.<id>.output.<field>}"`.
//   A binding must be the ENTIRE argument string; there is no string
//   interpolation. A string that starts with `${` but does not match the
//   grammar is a syntax error (rejected), so a typo cannot silently become a
//   literal.
// - steps ≤ 8 (§18.3 "artifact 文件数/总字节/step 数上限" budget spirit; the
//   exact cap is a budget constant, not a schema rule).
// - per-step timeout: default 60s, cap 600s (`IOSRecipeLimits`).
// - numbers in argument literals decode to Double; integers beyond 2^53 may
//   lose exactness on re-encode (documented limitation, deterministic hash).
//
// Invariants this file participates in:
// - I-5 (executed = stored = hashed): the store hashes the canonical bytes
//   this file produces; the runner executes the same decoded manifest.
// - I-10 (permission does not silently widen): `permissionEnvelope` is the
//   conservative union (upper bound) of every step's effect class.
// - No loops / recursion / dynamic code / recipe-calling-recipe (§10.1): the
//   validator rejects any step whose tool starts with `recipe__`.

// MARK: - Limits and naming rules

enum IOSRecipeLimits {
    /// §18.3 budget spirit: at most 8 sequential steps per recipe.
    static let maxSteps = 8
    /// Every step has a timeout; this applies when the manifest omits one.
    static let defaultStepTimeoutSeconds = 60
    /// Upper cap for an explicitly declared step timeout.
    static let maxStepTimeoutSeconds = 600
    /// Recipe package hash domain separator (mirrors the skill store's
    /// domain-separated hashing so different artifact kinds cannot collide).
    static let packageHashDomain = Data("amber.recipe.package.v1\0".utf8)
}

enum IOSRecipeNames {
    /// `^[a-z][a-z0-9_]{1,31}$` — the recipe id, later exposed as `recipe__<name>`.
    static func isValidRecipeName(_ raw: String) -> Bool {
        guard let first = raw.first, isAsciiLowercase(first) else { return false }
        let rest = raw.dropFirst()
        guard (1...31).contains(rest.count) else { return false }
        return rest.allSatisfy { isAsciiLowercase($0) || isAsciiDigit($0) || $0 == "_" }
    }

    /// `^[a-z][a-z0-9_]{1,31}$` — input names / step ids / output names.
    static func isValidMemberName(_ raw: String) -> Bool {
        guard let first = raw.first, isAsciiLowercase(first) else { return false }
        let rest = raw.dropFirst()
        guard (0...31).contains(rest.count) else { return false }
        return rest.allSatisfy { isAsciiLowercase($0) || isAsciiDigit($0) || $0 == "_" }
    }

    /// `^[A-Za-z_][A-Za-z0-9_]*$` — a step-output JSON field that a binding
    /// may reference (top-level keys only).
    static func isValidOutputField(_ raw: String) -> Bool {
        guard let first = raw.first, isAsciiLowercase(first) || isAsciiUppercase(first) || first == "_" else {
            return false
        }
        return raw.dropFirst().allSatisfy { isAsciiLowercase($0) || isAsciiUppercase($0) || isAsciiDigit($0) || $0 == "_" }
    }

    private static func isAsciiLowercase(_ c: Character) -> Bool { ("a"..."z").contains(c) }
    private static func isAsciiUppercase(_ c: Character) -> Bool { ("A"..."Z").contains(c) }
    private static func isAsciiDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }
}

// MARK: - JSON value (argument literals, run inputs, run outputs)

/// A JSON value with a deterministic canonical encoding. Used for step
/// argument literals, call-time inputs and recipe outputs.
enum IOSRecipeJSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([IOSRecipeJSONValue])
    case object([String: IOSRecipeJSONValue])

    /// Walks the value and returns every string that starts with "${" but does
    /// not parse as a binding — i.e. intended-but-malformed binding syntax.
    func malformedBindingStrings() -> [String] {
        var found: [String] = []
        collectMalformedBindings(into: &found)
        return found
    }

    private func collectMalformedBindings(into found: inout [String]) {
        switch self {
        case .string(let s):
            if s.hasPrefix("${"), IOSRecipeBinding.parse(s) == nil {
                found.append(s)
            }
        case .array(let items):
            for item in items { item.collectMalformedBindings(into: &found) }
        case .object(let dict):
            for (_, value) in dict.sorted(by: { $0.key < $1.key }) {
                value.collectMalformedBindings(into: &found)
            }
        case .number, .bool, .null:
            break
        }
    }
}

extension IOSRecipeJSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Verified: JSONDecoder throws for `1` when asked for Bool and for
            // `true` when asked for Double, so this order is unambiguous.
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IOSRecipeJSONValue].self) {
            self = .array(value)
        } else {
            let object = try container.decode([String: IOSRecipeJSONValue].self)
            self = .object(object)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let items): try container.encode(items)
        case .object(let dict): try container.encode(dict)
        }
    }
}

// MARK: - Bindings

/// One `"${input.x}"` / `"${step.<id>.output.<field>}"` reference.
struct IOSRecipeBinding: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case input(String)
        case stepOutput(stepId: String, field: String)
    }

    let source: Source

    /// Parses the strict grammar. Returns nil for anything that is not a
    /// complete, well-formed binding.
    static func parse(_ raw: String) -> IOSRecipeBinding? {
        guard raw.hasPrefix("${"), raw.hasSuffix("}") else { return nil }
        let inner = String(raw.dropFirst(2).dropLast())
        if inner.hasPrefix("input.") {
            let name = String(inner.dropFirst("input.".count))
            guard IOSRecipeNames.isValidMemberName(name) else { return nil }
            return IOSRecipeBinding(source: .input(name))
        }
        if inner.hasPrefix("step.") {
            let rest = String(inner.dropFirst("step.".count))
            guard let outputRange = rest.range(of: ".output.") else { return nil }
            let stepId = String(rest[..<outputRange.lowerBound])
            let field = String(rest[outputRange.upperBound...])
            guard IOSRecipeNames.isValidMemberName(stepId),
                  IOSRecipeNames.isValidOutputField(field) else { return nil }
            return IOSRecipeBinding(source: .stepOutput(stepId: stepId, field: field))
        }
        return nil
    }

    /// Canonical `${...}` text for this binding.
    var text: String {
        switch source {
        case .input(let name): return "${input.\(name)}"
        case .stepOutput(let stepId, let field): return "${step.\(stepId).output.\(field)}"
        }
    }
}

/// An argument value: either a literal JSON value or a binding. A string that
/// matches the full binding grammar is always a binding; any other string is a
/// literal (a `${`-prefixed non-matching string is flagged by the validator).
enum IOSRecipeValue: Equatable, Sendable {
    case binding(IOSRecipeBinding)
    case literal(IOSRecipeJSONValue)
}

extension IOSRecipeValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            if let binding = IOSRecipeBinding.parse(raw) {
                self = .binding(binding)
            } else {
                self = .literal(.string(raw))
            }
        } else {
            self = .literal(try container.decode(IOSRecipeJSONValue.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .binding(let binding): try container.encode(binding.text)
        case .literal(let value): try container.encode(value)
        }
    }
}

// MARK: - Manifest

enum IOSRecipeInputType: String, Codable, Equatable, Sendable {
    case string
    case number
    case boolean
}

struct IOSRecipeStep: Codable, Equatable, Sendable {
    let id: String
    /// Production ToolId of an App-shipped primitive (§5.3: recipes may only
    /// reference already-published ToolIds).
    let tool: String
    let arguments: [String: IOSRecipeValue]
    /// Optional; `IOSRecipeLimits.defaultStepTimeoutSeconds` applies when nil.
    let timeoutSeconds: Int?
}

struct IOSRecipeManifest: Codable, Equatable, Sendable {
    static let schemaVersion = "amber.recipe.v1"

    let schema: String
    let name: String
    let version: String
    let description: String
    let inputs: [String: IOSRecipeInputType]
    let steps: [IOSRecipeStep]
    let outputs: [String: IOSRecipeValue]

    init(
        schema: String = IOSRecipeManifest.schemaVersion,
        name: String,
        version: String,
        description: String,
        inputs: [String: IOSRecipeInputType],
        steps: [IOSRecipeStep],
        outputs: [String: IOSRecipeValue]
    ) {
        self.schema = schema
        self.name = name
        self.version = version
        self.description = description
        self.inputs = inputs
        self.steps = steps
        self.outputs = outputs
    }

    /// Decodes a recipe manifest from raw JSON bytes. Throws on malformed
    /// JSON, unknown input types or a malformed binding — i.e. grammar/shape
    /// errors. Semantic errors (unknown tools, dangling references, budget
    /// violations) are reported by `IOSRecipeValidator`, which needs a catalog.
    static func decode(_ data: Data) throws -> IOSRecipeManifest {
        do {
            return try JSONDecoder().decode(IOSRecipeManifest.self, from: data)
        } catch let error as DecodingError {
            let keys: [CodingKey]
            let message: String
            switch error {
            case .keyNotFound(let key, let context):
                keys = context.codingPath + [key]
                message = "缺少必填字段。"
            case .typeMismatch(let type, let context):
                keys = context.codingPath
                message = "字段类型错误，需要 \(type)。\(context.debugDescription)"
            case .valueNotFound(_, let context):
                keys = context.codingPath
                message = "必填字段不能为 null。"
            case .dataCorrupted(let context):
                keys = context.codingPath
                message = context.debugDescription
            @unknown default:
                keys = []
                message = error.localizedDescription
            }
            let path = keys.reduce("") { path, key in
                if let index = key.intValue { return "\(path)[\(index)]" }
                return path.isEmpty ? key.stringValue : "\(path).\(key.stringValue)"
            }
            throw IOSRecipeValidationIssue(
                code: .invalidManifestJSON,
                path: path.isEmpty ? nil : path,
                message: message
            )
        }
    }

    /// Canonical bytes: every dictionary key sorted at every level
    /// (`JSONEncoder.sortedKeys`), deterministic for identical content. The
    /// store hashes exactly these bytes (invariant 5).
    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        return try encoder.encode(self)
    }
}

// MARK: - Catalog lookup (injected; no chat singleton dependency)

/// What the runner/validator needs to know about one primitive ToolId.
struct IOSRecipeCatalogEntry: Equatable, Sendable {
    let exists: Bool
    /// The tool's version as known to the catalog (informational today; used
    /// as the plan's `toolVersion` for ledger/lease attribution, and reserved
    /// for future per-step minimum-version checks — §10.1 "ToolId 和最低版本").
    let minVersion: String?
    let effectClass: IOSToolEffectClass
}

/// `(ToolId) -> entry?`; nil means the catalog does not know the tool at all
/// (same fail-closed treatment as `exists == false`).
typealias IOSRecipeCatalogLookup = @Sendable (String) -> IOSRecipeCatalogEntry?

// MARK: - Validation

enum IOSRecipeValidationCode: String, Equatable, Sendable {
    case invalidManifestJSON
    case schemaMismatch
    case invalidName
    case invalidVersion
    case emptyDescription
    case invalidInputName
    case invalidInputType
    case noSteps
    case stepLimitExceeded
    case invalidStepId
    case duplicateStepId
    case invalidToolName
    case recipeToolReference
    case unknownTool
    case invalidBindingSyntax
    case unresolvedInputBinding
    case unresolvedStepBinding
    case invalidStepReference
    case invalidTimeout
    case invalidOutputName
    case outputMustBeBinding
    case unresolvedOutputStep
}

struct IOSRecipeValidationIssue: LocalizedError, Equatable, Sendable {
    let code: IOSRecipeValidationCode
    /// Human-readable dotted path to the offending field, e.g. `steps[1].tool`.
    let path: String?
    let message: String

    var errorDescription: String? {
        "recipe.json\(path.map { "：\($0)" } ?? "")：\(message)"
    }
}

struct IOSRecipeValidationResult: Equatable, Sendable {
    let issues: [IOSRecipeValidationIssue]
    /// Conservative union of all steps' effect classes (I-10, §10.3.7); nil
    /// when the manifest has any issue (there is no valid envelope to report).
    let permissionEnvelope: IOSToolEffectClass?

    var isValid: Bool { issues.isEmpty }
}

enum IOSRecipeValidator {
    /// Pure function: manifest + catalog lookup closure → issues + envelope.
    /// No chat singleton, no I/O — unit-testable in isolation.
    static func validate(
        manifest: IOSRecipeManifest,
        catalog: @escaping IOSRecipeCatalogLookup
    ) -> IOSRecipeValidationResult {
        var issues: [IOSRecipeValidationIssue] = []

        if manifest.schema != IOSRecipeManifest.schemaVersion {
            issues.append(issue(.schemaMismatch, path: "schema",
                                 "不支持的 schema「\(manifest.schema)」，需要 \(IOSRecipeManifest.schemaVersion)。"))
        }
        if !IOSRecipeNames.isValidRecipeName(manifest.name) {
            issues.append(issue(.invalidName, path: "name",
                                 "name 必须匹配 ^[a-z][a-z0-9_]{1,31}$（将来以 recipe__<name> 暴露）。"))
        }
        if manifest.version.isEmpty || manifest.version.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }) {
            issues.append(issue(.invalidVersion, path: "version", "version 不能为空且不能包含空白字符。"))
        }
        if manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(issue(.emptyDescription, path: "description", "description 不能为空。"))
        }

        for (name, _) in manifest.inputs.sorted(by: { $0.key < $1.key }) {
            if !IOSRecipeNames.isValidMemberName(name) {
                issues.append(issue(.invalidInputName, path: "inputs.\(name)",
                                     "输入名必须匹配 ^[a-z][a-z0-9_]{1,31}$。"))
            }
        }

        if manifest.steps.isEmpty {
            issues.append(issue(.noSteps, path: "steps", "Recipe 至少需要一个 step。"))
        } else if manifest.steps.count > IOSRecipeLimits.maxSteps {
            issues.append(issue(.stepLimitExceeded, path: "steps",
                                 "step 数 \(manifest.steps.count) 超过上限 \(IOSRecipeLimits.maxSteps)（§18.3 预算）。"))
        }

        var seenStepIds: Set<String> = []
        for (index, step) in manifest.steps.enumerated() {
            let stepPath = "steps[\(index)]"
            if !IOSRecipeNames.isValidMemberName(step.id) {
                issues.append(issue(.invalidStepId, path: "\(stepPath).id",
                                     "step id 必须匹配 ^[a-z][a-z0-9_]{1,31}$。"))
            } else if seenStepIds.contains(step.id) {
                issues.append(issue(.duplicateStepId, path: "\(stepPath).id",
                                     "step id「\(step.id)」重复。"))
            } else {
                seenStepIds.insert(step.id)
            }

            let trimmedTool = step.tool.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTool.isEmpty || trimmedTool != step.tool || trimmedTool.contains(where: { $0.isWhitespace }) {
                issues.append(issue(.invalidToolName, path: "\(stepPath).tool",
                                     "tool 必须是 App 已发布的 ToolId 字符串（无空白）。"))
            } else if trimmedTool.hasPrefix("recipe__") || trimmedTool.hasPrefix("plugin__") {
                // §10.1: no recipe-calling-recipe; recipes only compose
                // primitives, defense in depth even before catalog lookup.
                issues.append(issue(.recipeToolReference, path: "\(stepPath).tool",
                                     "工作流不能引用 Recipe 或插件工具（tool「\(trimmedTool)」）。"))
            } else if let entry = catalog(trimmedTool) {
                if !entry.exists {
                    issues.append(issue(.unknownTool, path: "\(stepPath).tool",
                                         "工具「\(trimmedTool)」在目录中不存在。"))
                }
            } else {
                issues.append(issue(.unknownTool, path: "\(stepPath).tool",
                                     "工具「\(trimmedTool)」不在当前 primitive 目录中。"))
            }

            if let timeout = step.timeoutSeconds {
                if timeout <= 0 || timeout > IOSRecipeLimits.maxStepTimeoutSeconds {
                    issues.append(issue(.invalidTimeout, path: "\(stepPath).timeoutSeconds",
                                         "timeout 必须在 1…\(IOSRecipeLimits.maxStepTimeoutSeconds) 秒之间。"))
                }
            }

            for (key, value) in step.arguments.sorted(by: { $0.key < $1.key }) {
                let argPath = "\(stepPath).arguments.\(key)"
                switch value {
                case .binding(let binding):
                    validate(binding, at: argPath, stepId: step.id, index: index,
                             manifest: manifest, issues: &issues)
                case .literal(let literal):
                    for malformed in literal.malformedBindingStrings() {
                        issues.append(issue(.invalidBindingSyntax, path: argPath,
                                             "「\(malformed)」不是合法的绑定语法（绑定必须是完整字符串，如 ${input.x}）。"))
                    }
                }
            }
        }

        for (name, value) in manifest.outputs.sorted(by: { $0.key < $1.key }) {
            if !IOSRecipeNames.isValidMemberName(name) {
                issues.append(issue(.invalidOutputName, path: "outputs.\(name)",
                                     "输出名必须匹配 ^[a-z][a-z0-9_]{1,31}$。"))
            }
            switch value {
            case .binding(let binding):
                // Outputs are evaluated after every step has run, so any
                // existing step may be referenced (but still not a missing one).
                switch binding.source {
                case .stepOutput(let stepId, _):
                    if !seenStepIds.contains(stepId) {
                        issues.append(issue(.unresolvedOutputStep, path: "outputs.\(name)",
                                             "输出引用了不存在的 step「\(stepId)」。"))
                    }
                case .input:
                    issues.append(issue(.outputMustBeBinding, path: "outputs.\(name)",
                                         "输出必须绑定 step 输出，不能绑定输入。"))
                }
            case .literal:
                issues.append(issue(.outputMustBeBinding, path: "outputs.\(name)",
                                     "输出必须是 ${step.<id>.output.<field>} 绑定。"))
            }
        }

        let envelope: IOSToolEffectClass?
        if issues.isEmpty {
            let classes = manifest.steps.compactMap { step -> IOSToolEffectClass? in
                let trimmedTool = step.tool.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let entry = catalog(trimmedTool), entry.exists else { return nil }
                return entry.effectClass
            }
            envelope = IOSToolEffectClass.conservativeUpperBound(of: classes)
        } else {
            envelope = nil
        }
        return IOSRecipeValidationResult(issues: issues, permissionEnvelope: envelope)
    }

    /// Convenience for raw bytes: a decode failure surfaces as a single
    /// `invalidManifestJSON` issue instead of throwing.
    static func validate(
        data: Data,
        catalog: @escaping IOSRecipeCatalogLookup
    ) -> IOSRecipeValidationResult {
        do {
            return validate(manifest: try IOSRecipeManifest.decode(data), catalog: catalog)
        } catch let issue as IOSRecipeValidationIssue {
            return IOSRecipeValidationResult(issues: [issue], permissionEnvelope: nil)
        } catch {
            return IOSRecipeValidationResult(
                issues: [issue(.invalidManifestJSON, path: nil, error.localizedDescription)],
                permissionEnvelope: nil
            )
        }
    }

    // MARK: Argument binding resolution rules (used by validate)

    private static func validate(
        _ binding: IOSRecipeBinding,
        at path: String,
        stepId: String,
        index: Int,
        manifest: IOSRecipeManifest,
        issues: inout [IOSRecipeValidationIssue]
    ) {
        switch binding.source {
        case .input(let name):
            if manifest.inputs[name] == nil {
                issues.append(issue(.unresolvedInputBinding, path: path,
                                     "绑定了未声明的输入「\(name)」。"))
            }
        case .stepOutput(let referencedStepId, _):
            guard let referencedIndex = manifest.steps.firstIndex(where: { $0.id == referencedStepId }) else {
                issues.append(issue(.unresolvedStepBinding, path: path,
                                     "绑定了不存在的 step「\(referencedStepId)」。"))
                return
            }
            if referencedIndex >= index {
                issues.append(issue(.invalidStepReference, path: path,
                                     "step「\(stepId)」只能绑定前序 step（不能绑定自身或后续 step）。"))
            }
        }
    }

    private static func issue(_ code: IOSRecipeValidationCode, path: String?, _ message: String) -> IOSRecipeValidationIssue {
        IOSRecipeValidationIssue(code: code, path: path, message: message)
    }
}

// MARK: - Effect class ordering (I-10 conservative union)

extension IOSToolEffectClass {
    /// Ordering used for the conservative union:
    /// pure < networkRead < idempotent < sideEffect.
    var conservativenessRank: Int {
        switch self {
        case .pure: return 0
        case .networkRead: return 1
        case .idempotent: return 2
        case .sideEffect: return 3
        }
    }

    /// Upper bound of a set of effect classes; nil only for an empty set.
    /// A recipe's envelope is the most conservative class among all steps
    /// (§10.3.7, invariant 10: permission does not silently widen).
    static func conservativeUpperBound(of classes: [IOSToolEffectClass]) -> IOSToolEffectClass? {
        classes.max { $0.conservativenessRank < $1.conservativenessRank }
    }
}

// MARK: - amber.plugin.v1

enum IOSPluginLimits {
    static let maxFiles = 32
    static let maxFileBytes = 256 * 1024
    static let maxPackageBytes = 1024 * 1024
    static let packageHashDomain = Data("amber.plugin.package.v1\0".utf8)
}

enum IOSPluginOutputType: String, Codable, Equatable, Sendable {
    case json
    case object
    case array
    case string
    case number
    case boolean
}

enum IOSPluginRemoteKind: String, Codable, Equatable, Sendable {
    case mcp
    case openapi
}

struct IOSPluginRemoteManifest: Codable, Equatable, Sendable {
    let kind: IOSPluginRemoteKind
    /// MCP server name for `.mcp` handlers.
    let server: String?
    /// MCP tool name for `.mcp` handlers.
    let tool: String?
    /// Fixed endpoint for `.openapi` handlers. Call arguments can never
    /// replace this URL; GET/HEAD use query items and other methods use JSON.
    let url: String?
    let method: String?

    init(
        kind: IOSPluginRemoteKind,
        server: String? = nil,
        tool: String? = nil,
        url: String? = nil,
        method: String? = nil
    ) {
        self.kind = kind
        self.server = server
        self.tool = tool
        self.url = url
        self.method = method
    }
}

struct IOSPluginToolManifest: Codable, Equatable, Sendable {
    /// Stable member name used in `plugin__<plugin id>__<name>`.
    let name: String
    let description: String?
    /// Exactly one handler: Recipe, restricted JS, remote or a local command.
    let recipe: String?
    let script: String?
    let remote: IOSPluginRemoteManifest?
    let command: IOSPluginCommandManifest?
    /// Host primitives made visible inside a restricted JS handler.
    let hostTools: [String]
    /// Script/remote declaration inputs. Recipe inputs come from recipe.json.
    let inputs: [String: IOSRecipeInputType]
    let output: IOSPluginOutputType
    /// Optional structured JSON Schema contract. `input_schema` replaces the
    /// legacy inputs map; `output_schema` further constrains the legacy coarse
    /// output type when one is present.
    let inputSchema: IOSPluginJSONSchema?
    let outputSchema: IOSPluginJSONSchema?
    let timeoutMs: Int
    let maxOutputChars: Int

    init(
        name: String,
        recipe: String,
        description: String? = nil
    ) {
        self.init(
            name: name,
            description: description,
            recipe: recipe,
            script: nil,
            remote: nil
        )
    }

    init(
        name: String,
        description: String? = nil,
        recipe: String? = nil,
        script: String? = nil,
        remote: IOSPluginRemoteManifest? = nil,
        hostTools: [String] = [],
        inputs: [String: IOSRecipeInputType] = [:],
        output: IOSPluginOutputType = .json,
        timeoutMs: Int = 10_000,
        maxOutputChars: Int = 10_000,
        inputSchema: IOSPluginJSONSchema? = nil,
        outputSchema: IOSPluginJSONSchema? = nil,
        command: IOSPluginCommandManifest? = nil
    ) {
        self.name = name
        self.description = description
        self.recipe = recipe
        self.script = script
        self.remote = remote
        self.command = command
        self.hostTools = hostTools
        self.inputs = inputs
        self.output = output
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.timeoutMs = timeoutMs
        self.maxOutputChars = maxOutputChars
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, recipe, script, remote, command, hostTools = "host_tools"
        case inputs, output, inputSchema = "input_schema", outputSchema = "output_schema"
        case timeoutMs = "timeout_ms", maxOutputChars = "max_output_chars"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            recipe: try container.decodeIfPresent(String.self, forKey: .recipe),
            script: try container.decodeIfPresent(String.self, forKey: .script),
            remote: try container.decodeIfPresent(IOSPluginRemoteManifest.self, forKey: .remote),
            hostTools: try container.decodeIfPresent([String].self, forKey: .hostTools) ?? [],
            inputs: try container.decodeIfPresent([String: IOSRecipeInputType].self, forKey: .inputs) ?? [:],
            output: try container.decodeIfPresent(IOSPluginOutputType.self, forKey: .output) ?? .json,
            timeoutMs: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 10_000,
            maxOutputChars: try container.decodeIfPresent(Int.self, forKey: .maxOutputChars) ?? 10_000,
            inputSchema: try container.decodeIfPresent(IOSPluginJSONSchema.self, forKey: .inputSchema),
            outputSchema: try container.decodeIfPresent(IOSPluginJSONSchema.self, forKey: .outputSchema),
            command: try container.decodeIfPresent(IOSPluginCommandManifest.self, forKey: .command)
        )
    }
}

struct IOSPluginCapabilities: Codable, Equatable, Sendable {
    let workspaceReadPrefixes: [String]
    let workspaceWritePrefixes: [String]
    let networkDomains: [String]
    let webMountActions: [String]
    /// Whole local runtime grants; path/domain scopes do not sandbox commands.
    let localRuntimes: [IOSPluginCommandRuntime]

    init(
        workspaceReadPrefixes: [String] = [],
        workspaceWritePrefixes: [String] = [],
        networkDomains: [String] = [],
        webMountActions: [String] = [],
        localRuntimes: [IOSPluginCommandRuntime] = []
    ) {
        self.workspaceReadPrefixes = workspaceReadPrefixes
        self.workspaceWritePrefixes = workspaceWritePrefixes
        self.networkDomains = networkDomains
        self.webMountActions = webMountActions
        self.localRuntimes = localRuntimes
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceReadPrefixes, workspaceWritePrefixes, networkDomains, webMountActions, localRuntimes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workspaceReadPrefixes: try container.decode([String].self, forKey: .workspaceReadPrefixes),
            workspaceWritePrefixes: try container.decode([String].self, forKey: .workspaceWritePrefixes),
            networkDomains: try container.decode([String].self, forKey: .networkDomains),
            webMountActions: try container.decode([String].self, forKey: .webMountActions),
            localRuntimes: try container.decodeIfPresent([IOSPluginCommandRuntime].self, forKey: .localRuntimes) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceReadPrefixes, forKey: .workspaceReadPrefixes)
        try container.encode(workspaceWritePrefixes, forKey: .workspaceWritePrefixes)
        try container.encode(networkDomains, forKey: .networkDomains)
        try container.encode(webMountActions, forKey: .webMountActions)
        // Old packages keep their canonical bytes and signature hashes.
        if !localRuntimes.isEmpty { try container.encode(localRuntimes, forKey: .localRuntimes) }
    }
}

struct IOSPluginDirectoryMetadata: Codable, Equatable, Sendable {
    let publisher: String
    let homepageURL: String?
    let supportURL: String?
    let privacyURL: String?
    let minimumAge: Int?

    init(
        publisher: String,
        homepageURL: String? = nil,
        supportURL: String? = nil,
        privacyURL: String? = nil,
        minimumAge: Int? = nil
    ) {
        self.publisher = publisher
        self.homepageURL = homepageURL
        self.supportURL = supportURL
        self.privacyURL = privacyURL
        self.minimumAge = minimumAge
    }

    private enum CodingKeys: String, CodingKey {
        case publisher
        case homepageURL = "homepage_url"
        case supportURL = "support_url"
        case privacyURL = "privacy_url"
        case minimumAge = "minimum_age"
    }
}

struct IOSPluginManifest: Codable, Equatable, Sendable {
    static let schemaVersion = "amber.plugin.v1"

    let schema: String
    let id: String
    let name: String
    let version: String
    let description: String
    let tools: [IOSPluginToolManifest]
    let capabilities: IOSPluginCapabilities
    let backgroundAllowed: Bool
    /// Optional metadata consumed by a future public index. Its presence does
    /// not imply that a marketplace or server-side listing exists.
    let directory: IOSPluginDirectoryMetadata?

    init(
        schema: String = IOSPluginManifest.schemaVersion,
        id: String,
        name: String,
        version: String,
        description: String,
        tools: [IOSPluginToolManifest],
        capabilities: IOSPluginCapabilities = .init(),
        backgroundAllowed: Bool = false,
        directory: IOSPluginDirectoryMetadata? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.tools = tools
        self.capabilities = capabilities
        self.backgroundAllowed = backgroundAllowed
        self.directory = directory
    }

    static func decode(_ data: Data) throws -> IOSPluginManifest {
        try JSONDecoder().decode(IOSPluginManifest.self, from: data)
    }

    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

enum IOSPluginToolImplementation: Equatable, Sendable {
    case recipe(IOSRecipeManifest)
    case javascript(source: String, hostTools: Set<String>)
    case remote(IOSPluginRemoteManifest)
    case command(IOSPluginCommandSource)
}

struct IOSPluginResolvedTool: Equatable, Sendable {
    let toolId: String
    let name: String
    let description: String
    let inputs: [String: IOSRecipeInputType]
    let output: IOSPluginOutputType
    let inputSchema: IOSPluginJSONSchema?
    let outputSchema: IOSPluginJSONSchema?
    let timeoutMs: Int
    let maxOutputChars: Int
    let implementation: IOSPluginToolImplementation
    let primitiveTools: Set<String>
    let effectClass: IOSToolEffectClass

    var effectiveInputSchema: IOSPluginJSONSchema {
        inputSchema ?? IOSPluginJSONSchema.legacyInputSchema(from: inputs)
    }

    var effectiveOutputSchema: IOSPluginJSONSchema {
        outputSchema ?? IOSPluginJSONSchema.legacyOutputSchema(from: output)
    }
}

struct IOSPluginValidationResult: Equatable, Sendable {
    let issues: [String]
    let tools: [IOSPluginResolvedTool]
    /// Derived from the recipes' real primitives. The plugin manifest has no
    /// field that can downgrade this envelope.
    let primitiveTools: Set<String>
    let permissionEnvelope: IOSToolEffectClass?

    var isValid: Bool { issues.isEmpty }
}

enum IOSPluginValidator {
    static func validate(
        manifest: IOSPluginManifest,
        recipes: [String: IOSRecipeManifest],
        scripts: [String: String] = [:],
        catalog: @escaping IOSRecipeCatalogLookup
    ) -> IOSPluginValidationResult {
        var issues: [String] = []
        if manifest.schema != IOSPluginManifest.schemaVersion {
            issues.append("不支持的 schema「\(manifest.schema)」。")
        }
        if !IOSRecipeNames.isValidRecipeName(manifest.id) || manifest.id.contains("__") {
            issues.append("插件 id 必须匹配 ^[a-z][a-z0-9_]{1,31}$。")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("插件名称不能为空。")
        } else if manifest.name.count > 80 {
            issues.append("插件名称不能超过 80 个字符。")
        }
        if manifest.version.isEmpty || manifest.version.contains(where: { $0.isWhitespace }) {
            issues.append("插件版本不能为空且不能包含空白。")
        }
        if manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("插件描述不能为空。")
        }
        if manifest.tools.isEmpty {
            issues.append("插件至少需要注册一个工具。")
        }

        var seenNames: Set<String> = []
        var resolved: [IOSPluginResolvedTool] = []
        var primitives: Set<String> = []
        for tool in manifest.tools {
            guard IOSRecipeNames.isValidMemberName(tool.name), !tool.name.contains("__") else {
                issues.append("插件工具名「\(tool.name)」无效。")
                continue
            }
            guard seenNames.insert(tool.name).inserted else {
                issues.append("插件工具名「\(tool.name)」重复。")
                continue
            }
            for input in tool.inputs.keys where !IOSRecipeNames.isValidMemberName(input) {
                issues.append("插件工具「\(tool.name)」的输入名「\(input)」无效。")
            }
            if let inputSchema = tool.inputSchema {
                for issue in inputSchema.inputSchemaIssues {
                    issues.append("插件工具「\(tool.name)」的 input_schema 无效：\(issue)。")
                }
                if !tool.inputs.isEmpty {
                    issues.append("插件工具「\(tool.name)」不能同时声明 inputs 和 input_schema。")
                }
            }
            if let outputSchema = tool.outputSchema {
                if !outputSchema.allowsLegacyOutputType(tool.output) {
                    issues.append("插件工具「\(tool.name)」的 output_schema 根类型与 output「\(tool.output.rawValue)」冲突。")
                }
            }
            let maximumTimeout = tool.command == nil ? 30_000 : IOSPluginCommandBuilder.maxTimeoutMs
            guard (1_000...maximumTimeout).contains(tool.timeoutMs) else {
                issues.append("插件工具「\(tool.name)」的 timeout_ms 必须在 1000...\(maximumTimeout)。")
                continue
            }
            guard (1_000...32_000).contains(tool.maxOutputChars) else {
                issues.append("插件工具「\(tool.name)」的 max_output_chars 必须在 1000...32000。")
                continue
            }

            let handlerCount = [tool.recipe != nil, tool.script != nil, tool.remote != nil, tool.command != nil].filter { $0 }.count
            guard handlerCount == 1 else {
                issues.append("插件工具「\(tool.name)」必须且只能声明 recipe、script、remote、command 之一。")
                continue
            }

            let implementation: IOSPluginToolImplementation
            let inputs: [String: IOSRecipeInputType]
            let effect: IOSToolEffectClass
            let memberPrimitives: Set<String>
            if let recipePath = tool.recipe {
                guard tool.hostTools.isEmpty, tool.inputs.isEmpty,
                      tool.inputSchema == nil, tool.outputSchema == nil else {
                    issues.append("Recipe 工具「\(tool.name)」的输入、输出和能力必须由 recipe.json 定义。")
                    continue
                }
                guard isCanonicalRecipePath(recipePath) else {
                    issues.append("Recipe 路径「\(recipePath)」必须位于 recipes/ 且为规范 JSON 路径。")
                    continue
                }
                guard let recipe = recipes[recipePath] else {
                    issues.append("找不到插件工具「\(tool.name)」引用的 \(recipePath)。")
                    continue
                }
                let validation = IOSRecipeValidator.validate(manifest: recipe, catalog: catalog)
                if !validation.isValid {
                    issues.append("\(recipePath) 校验失败：\(validation.issues.map(\.message).joined(separator: "；"))")
                    continue
                }
                guard let envelope = validation.permissionEnvelope else {
                    issues.append("\(recipePath) 无法计算权限包络。")
                    continue
                }
                let unsupported = recipe.steps.map(\.tool).filter { !isAllowedPublicPluginPrimitive($0) }
                guard unsupported.isEmpty else {
                    issues.append("\(recipePath) 使用了公开插件不允许的能力：\(unsupported.joined(separator: "、"))。")
                    continue
                }
                memberPrimitives = Set(recipe.steps.map(\.tool))
                inputs = recipe.inputs
                effect = envelope
                implementation = .recipe(recipe)
            } else if let scriptPath = tool.script {
                guard isCanonicalScriptPath(scriptPath) else {
                    issues.append("脚本路径「\(scriptPath)」必须位于 scripts/ 且为规范 JS 路径。")
                    continue
                }
                guard let source = scripts[scriptPath], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    issues.append("找不到插件工具「\(tool.name)」引用的 \(scriptPath)，或脚本为空。")
                    continue
                }
                let declared = Set(tool.hostTools)
                guard declared.count == tool.hostTools.count else {
                    issues.append("插件工具「\(tool.name)」重复声明了 host_tools。")
                    continue
                }
                let unsupported = declared.filter { !isAllowedPublicPluginPrimitive($0) }.sorted()
                guard unsupported.isEmpty else {
                    issues.append("\(scriptPath) 使用了公开插件不允许的能力：\(unsupported.joined(separator: "、"))。")
                    continue
                }
                let effects = declared.compactMap { catalog($0)?.effectClass }
                guard effects.count == declared.count else {
                    issues.append("\(scriptPath) 声明了不存在的 host_tools。")
                    continue
                }
                memberPrimitives = declared
                inputs = tool.inputs
                effect = IOSToolEffectClass.conservativeUpperBound(of: effects) ?? .pure
                implementation = .javascript(source: source, hostTools: declared)
            } else if let command = tool.command {
                guard tool.hostTools.isEmpty else {
                    issues.append("命令工具「\(tool.name)」不能同时声明 host_tools。")
                    continue
                }
                guard manifest.capabilities.localRuntimes.contains(command.runtime) else {
                    issues.append("命令工具「\(tool.name)」需要显式声明 capabilities.localRuntimes 中的 \(command.runtime.rawValue)。")
                    continue
                }
                guard let source = scripts[command.entry] else {
                    issues.append("找不到命令工具「\(tool.name)」的入口 \(command.entry)。")
                    continue
                }
                if let reason = IOSPluginCommandBuilder.validationReason(source: source, manifest: command, timeoutMs: tool.timeoutMs) {
                    issues.append("命令工具「\(tool.name)」无效：\(reason)")
                    continue
                }
                if let field = command.stdinInput,
                   !(tool.inputSchema ?? .legacyInputSchema(from: tool.inputs)).hasStringProperty(named: field) {
                    issues.append("命令工具「\(tool.name)」的 stdin_input 必须引用已声明的字符串输入。")
                    continue
                }
                memberPrimitives = [command.runtime.toolName]
                inputs = tool.inputs
                effect = .sideEffect
                implementation = .command(IOSPluginCommandSource(manifest: command, source: source))
            } else if let remote = tool.remote {
                guard tool.hostTools.isEmpty else {
                    issues.append("远端工具「\(tool.name)」不能同时声明 host_tools。")
                    continue
                }
                guard let remoteEffect = validateRemote(
                    remote,
                    capabilities: manifest.capabilities,
                    toolName: tool.name,
                    issues: &issues
                ) else { continue }
                memberPrimitives = []
                inputs = tool.inputs
                effect = remoteEffect
                implementation = .remote(remote)
            } else {
                continue
            }
            primitives.formUnion(memberPrimitives)
            resolved.append(IOSPluginResolvedTool(
                toolId: "plugin__\(manifest.id)__\(tool.name)",
                name: tool.name,
                description: tool.description
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? manifest.description,
                inputs: inputs,
                output: tool.output,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                timeoutMs: tool.timeoutMs,
                maxOutputChars: tool.maxOutputChars,
                implementation: implementation,
                primitiveTools: memberPrimitives,
                effectClass: effect
            ))
        }

        validateCapabilities(manifest.capabilities, issues: &issues)
        validateDirectoryMetadata(manifest.directory, issues: &issues)
        let envelope = issues.isEmpty
            ? IOSToolEffectClass.conservativeUpperBound(of: resolved.map(\.effectClass))
            : nil
        return IOSPluginValidationResult(
            issues: issues,
            tools: resolved,
            primitiveTools: primitives,
            permissionEnvelope: envelope
        )
    }

    static func isCanonicalPackagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              path == path.precomposedStringWithCanonicalMapping,
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    private static func isCanonicalRecipePath(_ path: String) -> Bool {
        isCanonicalPackagePath(path)
            && path.hasPrefix("recipes/")
            && path.hasSuffix(".json")
            && path.split(separator: "/").count == 2
    }

    private static func isCanonicalScriptPath(_ path: String) -> Bool {
        isCanonicalPackagePath(path)
            && path.hasPrefix("scripts/")
            && path.hasSuffix(".js")
            && path.split(separator: "/").count == 2
    }

    private static func validateRemote(
        _ remote: IOSPluginRemoteManifest,
        capabilities: IOSPluginCapabilities,
        toolName: String,
        issues: inout [String]
    ) -> IOSToolEffectClass? {
        switch remote.kind {
        case .mcp:
            guard let server = remote.server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty,
                  let tool = remote.tool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty,
                  remote.url == nil, remote.method == nil else {
                issues.append("MCP 工具「\(toolName)」必须且只能声明 server 和 tool。")
                return nil
            }
            return .sideEffect
        case .openapi:
            guard remote.server == nil, remote.tool == nil,
                  let rawURL = remote.url,
                  let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty,
                  capabilities.networkDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
                issues.append("OpenAPI 工具「\(toolName)」必须绑定能力范围内的固定 HTTPS URL。")
                return nil
            }
            let method = (remote.method ?? "GET").uppercased()
            guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method),
                  remote.method == nil || remote.method == method else {
                issues.append("OpenAPI 工具「\(toolName)」的 method 无效；请使用大写标准方法。")
                return nil
            }
            return method == "GET" || method == "HEAD" ? .networkRead : .sideEffect
        }
    }

    private static func validateCapabilities(
        _ capabilities: IOSPluginCapabilities,
        issues: inout [String]
    ) {
        for prefix in capabilities.workspaceReadPrefixes + capabilities.workspaceWritePrefixes {
            guard prefix == "/workspace" || prefix.hasPrefix("/workspace/") else {
                issues.append("Workspace 权限前缀「\(prefix)」必须位于 /workspace。")
                continue
            }
            let relative = String(prefix.dropFirst("/workspace".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty,
               relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) {
                issues.append("Workspace 权限前缀「\(prefix)」不是规范路径。")
            }
        }
        for domain in capabilities.networkDomains {
            let normalized = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
            let validLabels = labels.count >= 2 && labels.allSatisfy { label in
                guard let first = label.first, let last = label.last,
                      first.isASCII, last.isASCII, first != "-", last != "-" else { return false }
                return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
            if normalized != domain || normalized.isEmpty || !validLabels {
                issues.append("网络域名「\(domain)」不是规范主机名。")
            }
        }
        for action in capabilities.webMountActions where !action.hasPrefix("wm_") {
            issues.append("WebMount 动作「\(action)」必须是 wm_* 工具名。")
        }
    }

    private static func validateDirectoryMetadata(
        _ metadata: IOSPluginDirectoryMetadata?,
        issues: inout [String]
    ) {
        guard let metadata else { return }
        if metadata.publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("公开索引 publisher 不能为空。")
        }
        for (label, raw) in [
            ("homepage_url", metadata.homepageURL),
            ("support_url", metadata.supportURL),
            ("privacy_url", metadata.privacyURL),
        ] {
            guard let raw else { continue }
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
                issues.append("公开索引 \(label) 必须是固定 HTTPS 链接。")
                continue
            }
        }
        if let age = metadata.minimumAge, ![4, 9, 12, 17].contains(age) {
            issues.append("公开索引 minimum_age 只支持 4、9、12、17。")
        }
    }

    /// Public plugins intentionally start with the host primitives whose
    /// authorization can be decided from one call's arguments. Legacy Recipe
    /// files keep their broader catalog; terminal/Python, Apple/private data,
    /// orchestration, exec, MCP and hostless search are not plugin capabilities.
    static func isAllowedPublicPluginPrimitive(_ tool: String) -> Bool {
        let pathScopedWorkspace = IOSWorkspaceToolCatalog.supportedToolNames
            .subtracting(["workspace_artifact_read", "workspace_artifact_delete"])
        return pathScopedWorkspace.contains(tool)
            || tool == "scrape_web"
            || IOSWebMountToolCatalog.supportedToolNames.contains(tool)
            || tool == "tool_search" || tool == "tools_list"
    }
}

/// One enforcement point between a plugin workflow and every host primitive.
/// It uses the validated package snapshot, never live files or manifest risk labels.
struct IOSPluginCapabilityBroker: Sendable, Equatable {
    let pluginId: String
    let primitiveTools: Set<String>
    let capabilities: IOSPluginCapabilities

    func authorize(tool: String, argumentsJSON: String) -> String? {
        guard primitiveTools.contains(tool) else {
            return "插件 \(pluginId) 未声明工具能力 \(tool)。"
        }
        guard IOSPluginValidator.isAllowedPublicPluginPrimitive(tool) else {
            return "公开插件不允许调用能力 \(tool)。"
        }
        let args = ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:]
        if IOSWorkspaceToolCatalog.supportedToolNames.contains(tool) {
            if ["file_id", "artifact_id", "id"].contains(where: { args[$0] != nil }) {
                return "插件 \(pluginId) 的 Workspace 调用必须使用可校验的 path，不能使用对象 ID。"
            }
            let write = !IOSWorkspaceToolCatalog.readToolNames.contains(tool)
            let prefixes = write ? capabilities.workspaceWritePrefixes : capabilities.workspaceReadPrefixes
            if tool == "workspace_file_list" || tool == "workspace_file_search" {
                guard prefixes.contains("/workspace") else {
                    return "插件 \(pluginId) 需要 /workspace 读取范围才能列出或搜索整个 Workspace。"
                }
            } else {
                let requiredKeys = tool == "workspace_file_move" ? ["path", "destination_path"] : ["path"]
                for key in requiredKeys {
                    guard let raw = args[key] as? String, !raw.isEmpty else {
                        return "插件 \(pluginId) 的 Workspace 调用缺少可校验的 \(key)。"
                    }
                    if !allowsWorkspacePath(raw, prefixes: prefixes) {
                        return "插件 \(pluginId) 无权访问 Workspace 路径 \(raw)。"
                    }
                }
            }
        }
        if tool.hasPrefix("wm_") && !capabilities.webMountActions.contains(tool) {
            return "插件 \(pluginId) 未声明 WebMount 动作 \(tool)。"
        }
        if tool == "scrape_web" {
            guard let raw = args["url"] as? String,
                  let host = URL(string: raw)?.host?.lowercased() else {
                return "插件 \(pluginId) 的网页读取缺少可校验的 URL。"
            }
            if !allowsHost(host) {
                return "插件 \(pluginId) 无权访问网络域名 \(host)。"
            }
        }
        for key in ["url", "endpoint"] where tool != "scrape_web" {
            if let raw = args[key] as? String {
                guard let host = URL(string: raw)?.host?.lowercased(), allowsHost(host) else {
                    return "插件 \(pluginId) 无权访问网络地址 \(raw)。"
                }
            }
        }
        return nil
    }

    private func allowsWorkspacePath(_ raw: String, prefixes: [String]) -> Bool {
        let normalized: String
        if raw == "/workspace" || raw.hasPrefix("/workspace/") {
            normalized = raw
        } else if !raw.hasPrefix("/") {
            normalized = "/workspace/\(raw)"
        } else {
            return false
        }
        guard !normalized.contains("\\"),
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        return prefixes.contains { normalized == $0 || normalized.hasPrefix($0.hasSuffix("/") ? $0 : "\($0)/") }
    }

    private func allowsHost(_ host: String) -> Bool {
        capabilities.networkDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
