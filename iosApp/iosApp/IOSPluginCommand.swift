import Foundation
import CoreFoundation

/// The two local command runtimes that a pinned plugin source may target.
/// The raw values are part of the plugin manifest wire format.
enum IOSPluginCommandRuntime: String, Codable, Equatable, Sendable {
    case amberShell = "ambershell"
    case ish = "ish"

    var toolName: String {
        switch self {
        case .amberShell:
            "ios_shell_execute"
        case .ish:
            "ios_ish_execute"
        }
    }

    var title: String {
        switch self {
        case .amberShell:
            "AmberShell"
        case .ish:
            "iSH Experimental"
        }
    }

    var permissionSummary: String {
        switch self {
        case .amberShell:
            "AmberShell：整个 Amber Workspace"
        case .ish:
            "iSH：整个 guest 文件系统及 guest 网络（与 Amber Workspace 隔离）"
        }
    }

    fileprivate var commandLimit: Int {
        switch self {
        case .amberShell:
            4_096
        case .ish:
            32_000
        }
    }
}

/// A command handler declaration inside a plugin tool.
struct IOSPluginCommandManifest: Codable, Equatable, Sendable {
    let runtime: IOSPluginCommandRuntime
    let entry: String
    /// When present, this input object member must be a String and is passed
    /// as the command's data input. When absent, the complete input object is
    /// encoded as JSON and passed as the data input.
    let stdinInput: String?

    init(
        runtime: IOSPluginCommandRuntime,
        entry: String,
        stdinInput: String? = nil
    ) {
        self.runtime = runtime
        self.entry = entry
        self.stdinInput = stdinInput
    }

    private enum CodingKeys: String, CodingKey {
        case runtime
        case entry
        case stdinInput = "stdin_input"
    }
}

/// The source and its manifest as read from one pinned plugin package
/// snapshot. Keeping them together prevents a caller from pairing source
/// bytes with a different manifest revision by accident.
struct IOSPluginCommandSource: Equatable, Sendable {
    let manifest: IOSPluginCommandManifest
    let source: String

    init(manifest: IOSPluginCommandManifest, source: String) {
        self.manifest = manifest
        self.source = source
    }
}

/// Arguments ready for an existing `ios_shell_execute` or `ios_ish_execute`
/// call.
struct IOSPluginCommandInvocation {
    let runtime: IOSPluginCommandRuntime
    let argumentsJSON: String

    var toolName: String { runtime.toolName }
    var title: String { runtime.title }
}

enum IOSPluginCommandError: LocalizedError, Equatable, Sendable {
    case invalidEntry(String)
    case unsupportedEntry(runtime: IOSPluginCommandRuntime, entry: String)
    case emptySource
    case sourceContainsNUL
    case sourceContainsLineBreaks
    case invalidInputName(String)
    case missingInput(String)
    case inputMustBeString(String)
    case inputContainsNUL
    case inputTooLarge(limit: Int)
    case inputNotJSON
    case invalidTimeout
    case commandTooLong(runtime: IOSPluginCommandRuntime, limit: Int)
    case unavailable(String)
    case malformedOutput
    case missingOutputField(String)
    case outputOutcomeUnknown
    case outputTimedOut
    case outputCancelled
    case outputTruncated(stream: String)
    case outputNonZeroExit(Int)
    case outputFailed(status: String, detail: String)
    case outputNotJSON

    var errorDescription: String? {
        switch self {
        case .invalidEntry(let entry):
            return "插件命令入口「\(entry)」必须是规范的 scripts/<name>.<ext> 路径。"
        case .unsupportedEntry(let runtime, let entry):
            return "插件命令入口「\(entry)」不适用于 \(runtime.rawValue) runtime。"
        case .emptySource:
            return "插件命令入口的 source 不能为空。"
        case .sourceContainsNUL:
            return "插件命令 source 不能包含 NUL。"
        case .sourceContainsLineBreaks:
            return "AmberShell .sh 入口只能是单条受限命令或 pipeline，不能包含换行。"
        case .invalidInputName(let name):
            return "stdin_input「\(name)」不是合法的插件输入名。"
        case .missingInput(let name):
            return "插件调用缺少 stdin_input「\(name)」。"
        case .inputMustBeString(let name):
            return "插件输入「\(name)」必须是字符串，才能安全传给命令。"
        case .inputContainsNUL:
            return "iSH 命令参数不能包含 NUL。"
        case .inputTooLarge(let limit):
            return "插件命令输入超过现有 stdin 上限 \(limit) bytes。"
        case .inputNotJSON:
            return "插件调用参数不能编码为 JSON。"
        case .invalidTimeout:
            return "插件命令 timeout_ms 必须在 1000...180000。"
        case .commandTooLong(let runtime, let limit):
            return "\(runtime.title) command 超过 \(limit) 个字符。"
        case .unavailable(let reason):
            return reason
        case .malformedOutput:
            return "插件命令返回的执行结果不是合法的 runtime JSON。"
        case .missingOutputField(let field):
            return "插件命令执行结果缺少或错误地提供了字段「\(field)」。"
        case .outputOutcomeUnknown:
            return "插件命令已开始动作但结果未知，不能把它当作成功。"
        case .outputTimedOut:
            return "插件命令执行超时。"
        case .outputCancelled:
            return "插件命令执行已取消。"
        case .outputTruncated(let stream):
            return "插件命令的 \(stream) 输出已截断，不能把不完整结果当作成功。"
        case .outputNonZeroExit(let code):
            return "插件命令以非零退出码 \(code) 结束。"
        case .outputFailed(let status, let detail):
            let suffix = detail.isEmpty ? "" : "：\(detail)"
            return "插件命令执行状态为 \(status)\(suffix)。"
        case .outputNotJSON:
            return "插件命令 stdout 不是合法 JSON。"
        }
    }
}

/// Pure conversion and output parsing for a pinned command handler.
enum IOSPluginCommandBuilder {
    private static let minTimeoutMs = 1_000
    static let maxTimeoutMs = 180_000
    private static let maxAmberShellInputBytes = 64 * 1024

    /// Validates the manifest/source pair without needing call arguments.
    private static func validate(
        source: String,
        manifest: IOSPluginCommandManifest,
        timeoutMs: Int
    ) throws {
        _ = try timeoutSeconds(for: timeoutMs)
        let entryExtension = try validateEntry(manifest)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSPluginCommandError.emptySource
        }
        let commandSource = entryExtension == "sh"
            ? source.trimmingCharacters(in: .whitespacesAndNewlines)
            : source

        let command: String
        switch manifest.runtime {
        case .amberShell:
            guard !commandSource.contains("\0") else {
                throw IOSPluginCommandError.sourceContainsNUL
            }
            if entryExtension == "sh" {
                guard !commandSource.contains("\n"), !commandSource.contains("\r") else {
                    throw IOSPluginCommandError.sourceContainsLineBreaks
                }
            }
            command = amberShellCommand(source: commandSource, entryExtension: entryExtension)
        case .ish:
            guard !commandSource.contains("\0") else {
                throw IOSPluginCommandError.sourceContainsNUL
            }
            command = ishCommand(source: commandSource, inputPayload: "")
        }

        guard command.count <= manifest.runtime.commandLimit else {
            throw IOSPluginCommandError.commandTooLong(
                runtime: manifest.runtime,
                limit: manifest.runtime.commandLimit
            )
        }
    }

    /// Returns a human-readable validation reason, or nil when valid.
    static func validationReason(
        source: String,
        manifest: IOSPluginCommandManifest,
        timeoutMs: Int
    ) -> String? {
        do {
            try validate(source: source, manifest: manifest, timeoutMs: timeoutMs)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func build(
        source: String,
        manifest: IOSPluginCommandManifest,
        inputObject: [String: Any],
        timeoutMs: Int
    ) throws -> IOSPluginCommandInvocation {
        try validate(source: source, manifest: manifest, timeoutMs: timeoutMs)
        let timeoutSeconds = try timeoutSeconds(for: timeoutMs)
        let inputPayload = try inputPayload(from: inputObject, manifest: manifest)

        if manifest.runtime == .amberShell,
           inputPayload.utf8.count > maxAmberShellInputBytes {
            throw IOSPluginCommandError.inputTooLarge(limit: maxAmberShellInputBytes)
        }
        if manifest.runtime == .ish, inputPayload.contains("\0") {
            throw IOSPluginCommandError.inputContainsNUL
        }

        let entryExtension = try entryExtension(for: manifest.entry)
        let commandSource = entryExtension == "sh"
            ? source.trimmingCharacters(in: .whitespacesAndNewlines)
            : source
        let command: String
        var arguments: [String: Any] = [
            "timeout_seconds": timeoutSeconds,
        ]
        switch manifest.runtime {
        case .amberShell:
            command = amberShellCommand(source: commandSource, entryExtension: entryExtension)
            arguments["command"] = command
            arguments["stdin"] = inputPayload
        case .ish:
            command = ishCommand(source: commandSource, inputPayload: inputPayload)
            arguments["command"] = command
        }

        guard command.count <= manifest.runtime.commandLimit else {
            throw IOSPluginCommandError.commandTooLong(
                runtime: manifest.runtime,
                limit: manifest.runtime.commandLimit
            )
        }

        let argumentsJSON: String
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw IOSPluginCommandError.inputNotJSON
            }
            argumentsJSON = text
        } catch let error as IOSPluginCommandError {
            throw error
        } catch {
            throw IOSPluginCommandError.inputNotJSON
        }

        return IOSPluginCommandInvocation(
            runtime: manifest.runtime,
            argumentsJSON: argumentsJSON
        )
    }

    /// Converts a successful runtime envelope into the raw JSON consumed by
    /// the existing plugin output formatter. String output is deliberately
    /// encoded as one JSON string; other output schema checks stay with the
    /// existing plugin output formatter.
    static func parseOutput(
        _ output: String,
        outputType: IOSPluginOutputType
    ) throws -> String {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = value as? [String: Any] else {
            throw IOSPluginCommandError.malformedOutput
        }

        if object["status"] as? String == "unknown_after_action"
            || object["status"] as? String == "outcome_unknown"
            || object["error_code"] as? String == "unknown_after_action"
            || boolValue(object["may_have_applied"]) == true {
            throw IOSPluginCommandError.outputOutcomeUnknown
        }

        let status = try requiredString(object, key: "status")
        let timedOut = try requiredBool(object, key: "timed_out")
        let cancelled = boolValue(object["cancelled"]) == true
        if timedOut || status == "timed_out" {
            throw IOSPluginCommandError.outputTimedOut
        }
        if cancelled || status == "cancelled" {
            throw IOSPluginCommandError.outputCancelled
        }

        let exitCode = integerValue(object["exit_code"])
        if status == "failed" || status != "completed" {
            if let exitCode, exitCode != 0 {
                throw IOSPluginCommandError.outputNonZeroExit(exitCode)
            }
            throw IOSPluginCommandError.outputFailed(
                status: status,
                detail: outputDetail(from: object)
            )
        }

        guard try requiredBool(object, key: "ok") else {
            if let exitCode, exitCode != 0 {
                throw IOSPluginCommandError.outputNonZeroExit(exitCode)
            }
            throw IOSPluginCommandError.outputFailed(
                status: status,
                detail: outputDetail(from: object)
            )
        }
        guard try requiredBool(object, key: "stdout_available"),
              try requiredBool(object, key: "stderr_available"),
              try requiredBool(object, key: "exit_code_available"),
              exitCode == 0 else {
            if let exitCode, exitCode != 0 {
                throw IOSPluginCommandError.outputNonZeroExit(exitCode)
            }
            throw IOSPluginCommandError.missingOutputField("stdout/exit_code")
        }
        let stdoutTruncated = try requiredBool(object, key: "stdout_truncated")
        guard !stdoutTruncated else {
            throw IOSPluginCommandError.outputTruncated(stream: "stdout")
        }
        let stderrTruncated = try requiredBool(object, key: "stderr_truncated")
        guard !stderrTruncated else {
            throw IOSPluginCommandError.outputTruncated(stream: "stderr")
        }
        let stdout = try requiredString(object, key: "stdout")
        _ = try requiredString(object, key: "stderr")

        if outputType == .string {
            do {
                let data = try JSONSerialization.data(withJSONObject: stdout, options: [.fragmentsAllowed])
                guard let text = String(data: data, encoding: .utf8) else {
                    throw IOSPluginCommandError.outputNotJSON
                }
                return text
            } catch let error as IOSPluginCommandError {
                throw error
            } catch {
                throw IOSPluginCommandError.outputNotJSON
            }
        }

        guard let stdoutData = stdout.data(using: .utf8),
              (try? JSONSerialization.jsonObject(
                  with: stdoutData,
                  options: [.fragmentsAllowed]
              )) != nil else {
            throw IOSPluginCommandError.outputNotJSON
        }
        return stdout
    }

    // MARK: - Manifest and command conversion

    private static func validateEntry(_ manifest: IOSPluginCommandManifest) throws -> String {
        guard IOSPluginValidator.isCanonicalPackagePath(manifest.entry) else {
            throw IOSPluginCommandError.invalidEntry(manifest.entry)
        }
        let parts = manifest.entry.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "scripts", parts[1].first != "." else {
            throw IOSPluginCommandError.invalidEntry(manifest.entry)
        }
        let entryExtension = try entryExtension(for: manifest.entry)
        switch manifest.runtime {
        case .amberShell:
            guard entryExtension == "sh" || entryExtension == "py" else {
                throw IOSPluginCommandError.unsupportedEntry(
                    runtime: manifest.runtime,
                    entry: manifest.entry
                )
            }
        case .ish:
            guard entryExtension == "sh" else {
                throw IOSPluginCommandError.unsupportedEntry(
                    runtime: manifest.runtime,
                    entry: manifest.entry
                )
            }
        }
        if let stdinInput = manifest.stdinInput {
            guard IOSRecipeNames.isValidMemberName(stdinInput) else {
                throw IOSPluginCommandError.invalidInputName(stdinInput)
            }
        }
        return entryExtension
    }

    private static func entryExtension(for entry: String) throws -> String {
        guard let dot = entry.lastIndex(of: "."),
              dot != entry.startIndex,
              entry.index(after: dot) != entry.endIndex else {
            throw IOSPluginCommandError.invalidEntry(entry)
        }
        return String(entry[entry.index(after: dot)...])
    }

    private static func timeoutSeconds(for timeoutMs: Int) throws -> Int {
        guard (minTimeoutMs...maxTimeoutMs).contains(timeoutMs) else {
            throw IOSPluginCommandError.invalidTimeout
        }
        // The existing terminal executors accept whole seconds. Round up so
        // a millisecond timeout is never silently shortened.
        return (timeoutMs + 999) / 1_000
    }

    private static func inputPayload(
        from inputObject: [String: Any],
        manifest: IOSPluginCommandManifest
    ) throws -> String {
        if let stdinInput = manifest.stdinInput {
            guard let value = inputObject[stdinInput] else {
                throw IOSPluginCommandError.missingInput(stdinInput)
            }
            guard let string = value as? String else {
                throw IOSPluginCommandError.inputMustBeString(stdinInput)
            }
            return string
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: inputObject, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw IOSPluginCommandError.inputNotJSON
            }
            return text
        } catch let error as IOSPluginCommandError {
            throw error
        } catch {
            throw IOSPluginCommandError.inputNotJSON
        }
    }

    private static func amberShellCommand(source: String, entryExtension: String) -> String {
        entryExtension == "py" ? "python -c \(shellQuote(source))" : source
    }

    private static func ishCommand(source: String, inputPayload: String) -> String {
        // The payload is the final positional argument of `sh -c`; `$1` in
        // the pinned source can read it, while shell metacharacters in the
        // payload remain data because it is single-quoted and escaped.
        "sh -c \(shellQuote(source)) -- \(shellQuote(inputPayload))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - Runtime output parsing

    private static func requiredString(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw IOSPluginCommandError.missingOutputField(key)
        }
        return value
    }

    private static func requiredBool(_ object: [String: Any], key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw IOSPluginCommandError.missingOutputField(key)
        }
        return value.boolValue
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return value.boolValue
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    private static func outputDetail(from object: [String: Any]) -> String {
        let details = [object["error"] as? String, object["stderr"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let detail = details.first else { return "" }
        return String(detail.prefix(512))
    }

}
