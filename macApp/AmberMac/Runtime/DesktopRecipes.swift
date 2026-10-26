import Foundation
import Observation

// The wire fields and binding grammar mirror iOS amber.recipe.v1.
enum DesktopRecipeJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([DesktopRecipeJSONValue]), object([String: DesktopRecipeJSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        case .array(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        }
    }
}

enum DesktopRecipeInputType: String, Codable, Sendable { case string, number, boolean }
struct DesktopRecipeStep: Codable, Equatable, Sendable {
    let id: String
    let tool: String
    let arguments: [String: DesktopRecipeJSONValue]
    var timeoutSeconds: Int? = nil
}
struct DesktopRecipeManifest: Codable, Equatable, Sendable {
    var schema = "amber.recipe.v1"
    let name: String
    let version: String
    let description: String
    let inputs: [String: DesktopRecipeInputType]
    let steps: [DesktopRecipeStep]
    let outputs: [String: DesktopRecipeJSONValue]

    func validated(registeredTools: Set<String>? = nil) throws {
        guard schema == "amber.recipe.v1" else { throw recipeError("schema 须为 amber.recipe.v1。") }
        guard recipeName(name), !version.isEmpty, !version.contains(where: \.isWhitespace),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw recipeError("name、version 或 description 无效。") }
        guard (1...8).contains(steps.count) else { throw recipeError("Recipe 必须包含 1–8 个固定步骤。") }
        guard inputs.keys.allSatisfy({ memberName($0) }) else { throw recipeError("Recipe 输入名无效。") }
        var seen = Set<String>()
        for step in steps {
            guard memberName(step.id), !seen.contains(step.id) else { throw recipeError("步骤 id 无效或重复：\(step.id)。") }
            guard !step.tool.isEmpty, !step.tool.contains(where: \.isWhitespace), !step.tool.hasPrefix("recipe__") else { throw recipeError("步骤 \(step.id) 不能递归调用 Recipe 或使用无效工具名。") }
            if let registeredTools, !registeredTools.contains(step.tool) { throw recipeError("步骤 \(step.id) 使用未注册工具：\(step.tool)。") }
            guard (1...600).contains(step.timeoutSeconds ?? 60) else { throw recipeError("步骤 \(step.id) 的 timeoutSeconds 须为 1–600。") }
            for (key, value) in step.arguments {
                try checkMalformed(value)
                if let binding = binding(value) { try checkReference(binding, inputs: Set(inputs.keys), steps: seen, location: "\(step.id).\(key)") }
            }
            seen.insert(step.id)
        }
        for (name, value) in outputs {
            guard memberName(name), let binding = binding(value), case .step = binding else { throw recipeError("输出 \(name) 必须绑定 ${step.<id>.output.<field>}。") }
            try checkReference(binding, inputs: [], steps: seen, location: "outputs.\(name)")
        }
    }

    func canonicalJSON() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct DesktopInstalledRecipe: Identifiable, Equatable, Sendable {
    var id: String { manifest.name }
    let manifest: DesktopRecipeManifest
    let json: String
    let enabled: Bool
}
struct DesktopRecipeRunResult: Equatable, Sendable {
    let outputs: [String: DesktopRecipeJSONValue]
    let completedSteps: [String]
    let failedStep: String?
    let error: String?
    var succeeded: Bool { error == nil }
}

@MainActor @Observable
final class DesktopRecipeStore {
    private(set) var recipes: [DesktopInstalledRecipe] = []
    private(set) var loadError: String?
    @ObservationIgnored let directory: URL
    @ObservationIgnored var registeredTools: Set<String>

    init(directory: URL, registeredTools: Set<String>) {
        self.directory = directory
        self.registeredTools = registeredTools
        do { try reload() } catch { loadError = error.localizedDescription }
    }
    func reload() throws {
        do {
            let root = directory.appendingPathComponent("recipes", isDirectory: true)
            let fm = FileManager.default
            let entries = fm.fileExists(atPath: root.path) ? try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) : []
            let loaded = try entries.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { folder -> DesktopInstalledRecipe? in
                let url = folder.appendingPathComponent("recipe.json")
                guard fm.fileExists(atPath: url.path) else { return nil }
                let manifest = try JSONDecoder().decode(DesktopRecipeManifest.self, from: Data(contentsOf: url))
                try manifest.validated()
                guard manifest.name == folder.lastPathComponent else { throw recipeError("Recipe 目录名与 name 不一致。") }
                return DesktopInstalledRecipe(manifest: manifest, json: try manifest.canonicalJSON(), enabled: fm.fileExists(atPath: folder.appendingPathComponent(".enabled").path))
            }
            recipes = loaded.sorted { $0.id < $1.id }; loadError = nil
        } catch {
            let message = "无法读取 Recipe，原文件已保留：\(error.localizedDescription)"
            loadError = message; throw recipeError(message)
        }
    }
    @discardableResult
    func importRecipe(from url: URL) throws -> String {
        try ready()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 1_024 * 1_024 else { throw recipeError("请选择不超过 1 MB 的 recipe.json 文件。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_024 * 1_024 else { throw recipeError("Recipe 超过 1 MB。") }
        let manifest = try JSONDecoder().decode(DesktopRecipeManifest.self, from: data)
        try manifest.validated(registeredTools: registeredTools)
        let target = try folder(manifest.name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw recipeError("Recipe 已安装，请编辑现有版本。") }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let json = try manifest.canonicalJSON()
        do { try Data(json.utf8).write(to: target.appendingPathComponent("recipe.json"), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        recipes.append(DesktopInstalledRecipe(manifest: manifest, json: json, enabled: false))
        recipes.sort { $0.id < $1.id }
        return manifest.name
    }
    func saveRecipe(name: String, json: String) throws {
        try ready()
        guard json.utf8.count <= 1_024 * 1_024 else { throw recipeError("Recipe 超过 1 MB。") }
        let manifest = try JSONDecoder().decode(DesktopRecipeManifest.self, from: Data(json.utf8))
        try manifest.validated(registeredTools: registeredTools)
        guard manifest.name == name, let index = recipes.firstIndex(where: { $0.id == name }) else { throw recipeError("Recipe 不存在或编辑改变了 name。") }
        let canonical = try manifest.canonicalJSON()
        try Data(canonical.utf8).write(to: try folder(name).appendingPathComponent("recipe.json"), options: .atomic)
        recipes[index] = DesktopInstalledRecipe(manifest: manifest, json: canonical, enabled: recipes[index].enabled)
    }
    func setEnabled(_ name: String, enabled: Bool) throws {
        try ready()
        guard let index = recipes.firstIndex(where: { $0.id == name }) else { throw recipeError("Recipe 不存在。") }
        if enabled { try recipes[index].manifest.validated(registeredTools: registeredTools) }
        let marker = try folder(name).appendingPathComponent(".enabled")
        if enabled { try Data().write(to: marker, options: .atomic) }
        else if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        let previous = recipes[index]
        recipes[index] = DesktopInstalledRecipe(manifest: previous.manifest, json: previous.json, enabled: enabled)
    }
    func deleteRecipe(name: String) throws {
        try ready()
        guard recipes.contains(where: { $0.id == name }) else { throw recipeError("Recipe 不存在。") }
        try FileManager.default.removeItem(at: try folder(name))
        recipes.removeAll { $0.id == name }
    }

    // The injected dispatcher retains its normal approval and cancellation checks for every primitive.
    func run(name: String, inputs: [String: DesktopRecipeJSONValue],
        execute: @escaping @MainActor @Sendable (String, String) async throws -> String) async -> DesktopRecipeRunResult {
        var completed: [String] = [], active: String?
        do {
            try ready(); try Task.checkCancellation()
            guard let installed = recipes.first(where: { $0.id == name }), installed.enabled else { throw recipeError("Recipe 未安装或尚未启用。") }
            let manifest = installed.manifest
            try manifest.validated(registeredTools: registeredTools)
            guard Set(inputs.keys) == Set(manifest.inputs.keys) else { throw recipeError("Recipe 输入缺失或包含未声明字段。") }
            for (key, type) in manifest.inputs {
                let matches = switch (type, inputs[key]) { case (.string, .string), (.number, .number), (.boolean, .bool): true; default: false }
                guard matches else { throw recipeError("输入 \(key) 须为 \(type.rawValue)。") }
            }
            var outputs: [String: String] = [:]
            for step in manifest.steps {
                active = step.id
                try Task.checkCancellation()
                var arguments: [String: DesktopRecipeJSONValue] = [:]
                for (key, value) in step.arguments { arguments[key] = try resolve(value, inputs: inputs, outputs: outputs) }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let json = String(decoding: try encoder.encode(arguments), as: UTF8.self)
                let output = try await withThrowingTaskGroup(of: String?.self, returning: String.self) { group in
                    group.addTask {
                        try Task.checkCancellation()
                        return try await execute(step.tool, json)
                    }
                    group.addTask {
                        do { try await Task.sleep(for: .seconds(step.timeoutSeconds ?? 60)) }
                        catch is CancellationError { return nil }
                        throw recipeError("步骤 \(step.id) 超时，已请求取消。")
                    }
                    defer { group.cancelAll() }
                    // Cancellation of the timer must not hide an already confirmed primitive result.
                    while let result = try await group.next() {
                        if let result { return result }
                    }
                    throw CancellationError()
                }
                if let object = try? JSONDecoder().decode([String: DesktopRecipeJSONValue].self, from: Data(output.utf8)), object["ok"] == .bool(false) || object["isError"] == .bool(true) {
                    throw recipeError("步骤 \(step.id) 的工具返回失败：\(String(output.prefix(500)))")
                }
                outputs[step.id] = output; completed.append(step.id)
                try Task.checkCancellation()
            }
            active = nil
            var final: [String: DesktopRecipeJSONValue] = [:]
            for (key, value) in manifest.outputs { final[key] = try resolve(value, inputs: inputs, outputs: outputs) }
            return DesktopRecipeRunResult(outputs: final, completedSteps: completed, failedStep: nil, error: nil)
        } catch {
            return DesktopRecipeRunResult(outputs: [:], completedSteps: completed, failedStep: active,
                error: error is CancellationError ? "Recipe 已取消。" : error.localizedDescription)
        }
    }

    private func ready() throws { if let loadError { throw recipeError(loadError) } }
    private func folder(_ name: String) throws -> URL {
        guard recipeName(name) else { throw recipeError("Recipe name 无效。") }
        return directory.appendingPathComponent("recipes", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
}

private enum DesktopRecipeBinding { case input(String), step(String, String) }
private func recipeError(_ value: String) -> DesktopRuntimeError { .message(value) }
private func memberName(_ value: String) -> Bool { value.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) == value.startIndex..<value.endIndex }
private func recipeName(_ value: String) -> Bool { value.count >= 2 && memberName(value) }
private func binding(_ value: DesktopRecipeJSONValue) -> DesktopRecipeBinding? {
    guard case .string(let text) = value, text.hasPrefix("${"), text.hasSuffix("}") else { return nil }
    let parts = text.dropFirst(2).dropLast().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 2, parts[0] == "input", memberName(parts[1]) { return .input(parts[1]) }
    if parts.count == 4, parts[0] == "step", memberName(parts[1]), parts[2] == "output",
       parts[3].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == parts[3].startIndex..<parts[3].endIndex { return .step(parts[1], parts[3]) }
    return nil
}
private func checkMalformed(_ value: DesktopRecipeJSONValue) throws {
    switch value {
    case .string(let text): if text.hasPrefix("${"), binding(value) == nil { throw recipeError("绑定语法无效：\(text)。") }
    case .array(let values): for value in values { try checkMalformed(value) }
    case .object(let values): for value in values.values { try checkMalformed(value) }
    default: break
    }
}
private func checkReference(_ binding: DesktopRecipeBinding, inputs: Set<String>, steps: Set<String>, location: String) throws {
    switch binding {
    case .input(let name): guard inputs.contains(name) else { throw recipeError("\(location) 引用了未声明输入 \(name)。") }
    case .step(let id, _): guard steps.contains(id) else { throw recipeError("\(location) 引用了不存在或尚未完成的步骤 \(id)。") }
    }
}
private func resolve(_ value: DesktopRecipeJSONValue, inputs: [String: DesktopRecipeJSONValue], outputs: [String: String]) throws -> DesktopRecipeJSONValue {
    guard let binding = binding(value) else { return value }
    switch binding {
    case .input(let name): guard let value = inputs[name] else { throw recipeError("缺少输入绑定 \(name)。") }; return value
    case .step(let id, let field):
        guard let raw = outputs[id], let object = try? JSONDecoder().decode([String: DesktopRecipeJSONValue].self, from: Data(raw.utf8)), let value = object[field] else {
            throw recipeError("步骤 \(id) 输出缺少 JSON 字段 \(field)。")
        }
        return value
    }
}
