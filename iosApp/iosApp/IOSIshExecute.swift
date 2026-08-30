import Foundation
import CoreFoundation

enum IOSEmbeddedIshToolCatalog {
    #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    static let supportedToolNames: Set<String> = ["ios_ish_execute"]
    static let capabilityStatus: IOSCapabilityStatus = .supported
    static let unavailableReason: String? = nil
    #else
    static let supportedToolNames: Set<String> = []
    static let capabilityStatus: IOSCapabilityStatus = .unsupported
    static let unavailableReason: String? = "Embedded iSH is only linked in the ExperimentalGPL target."
    #endif
}

struct IOSEmbeddedIshExecuteRequest {
    let command: String?
    let script: String?
    let timeoutSeconds: TimeInterval
    let purpose: String?
    let workingDirectory: String
    let background: Bool
}

@MainActor
enum IOSEmbeddedIshExecuteExecutor {
    private static let maxScriptLength = 32_000
    private static let defaultTimeout: TimeInterval = 60
    private static let maxForegroundTimeout: TimeInterval = 180
    private static let defaultBackgroundTimeout: TimeInterval = 900
    private static let maxBackgroundTimeout: TimeInterval = 3_600

    static func execute(
        input: String,
        runtime: IOSTerminalRuntime = .shared,
        taskStore: IOSAdvancedTaskStore = .shared
    ) async -> String {
        do {
            let request = try parseRequest(input)
            let rawCommand = try normalizedCommand(command: request.command, script: request.script)
            let command: String
            switch IOSEmbeddedIshCommandPolicy.validate(rawCommand) {
            case .success(let validated):
                command = validated
            case .failure(let message):
                throw IOSEmbeddedIshExecuteError.commandRejected(message)
            }
            if request.background {
        return await IOSAgentTerminalJobExecutor.startEmbeddedJob(
                    command: command,
                    purpose: request.purpose,
                    workingDirectory: request.workingDirectory,
                    timeoutSeconds: request.timeoutSeconds,
                    runtime: runtime,
                    taskStore: taskStore
                )
            }
            let result = await IOSEmbeddedIshRuntime.shared.run(
                command: command,
                workingDirectory: request.workingDirectory,
                timeoutSeconds: request.timeoutSeconds
            )
            let status = executionStatus(result: result, taskCancelled: Task.isCancelled)
            let exitCodeValue: Any = result.exitCode.map { $0 as Any } ?? NSNull()
            return IOSWorkspaceStore.json([
                "ok": status == .completed,
                "tool": "ios_ish_execute",
                "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue,
                "status": status.rawValue,
                "background": false,
                "purpose": request.purpose ?? "",
                "cwd": request.workingDirectory,
                "exit_code": exitCodeValue,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "stdout_available": true,
                "stderr_available": true,
                "stdout_truncated": result.stdoutTruncated,
                "stderr_truncated": result.stderrTruncated,
                "exit_code_available": result.exitCode != nil,
                "timed_out": result.timedOut,
                "error": status == .cancelled ? "Embedded iSH command was cancelled." : result.error ?? ""
            ])
        } catch {
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": "ios_ish_execute",
                "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue,
                "status": "failed",
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                "stdout": "",
                "stderr": "",
                "stdout_available": false,
                "stderr_available": false,
                "exit_code_available": false
            ])
        }
    }

    static func approvalPreview(input: String) -> IshHandoffToolApprovalRequest? {
        guard let parsed = try? parseRequest(input) else { return nil }
        let previewSource = nonBlankValue(parsed.script) ?? nonBlankValue(parsed.command) ?? input
        return IshHandoffToolApprovalRequest(
            id: chatInputDigest(for: input),
            mode: parsed.background ? .embeddedJobStart : .embeddedExecute,
            commandPreview: previewSource,
            filename: "ExperimentalGPL 内置 iSH · \(parsed.workingDirectory)",
            reason: parsed.background
                ? "内置 iSH 会启动进程内异步非 PTY 作业并返回 Job ID；App 重启后未完成作业会标记为中断。"
                : "内置 iSH 会在隔离 guest 内执行 Linux 命令，并把 stdout/stderr/exit code 回传给 Agent。",
            contextLines: [
                "模式：\(parsed.background ? "异步 Job（无 PTY、无 stdin）" : "前台非 PTY 执行")",
                "工作目录：\(parsed.workingDirectory)",
                "超时：\(Int(parsed.timeoutSeconds)) 秒",
                "脚本：\(previewSource.count) 个字符",
                parsed.background ? "生命周期：当前 App 进程；重启后标记中断" : "生命周期：等待本次执行结束",
            ]
        )
    }

    private static func parseRequest(_ input: String) throws -> IOSEmbeddedIshExecuteRequest {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSEmbeddedIshExecuteError.emptyInput }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return IOSEmbeddedIshExecuteRequest(
                command: trimmed,
                script: nil,
                timeoutSeconds: defaultTimeout,
                purpose: nil,
                workingDirectory: IOSPOSIXWorkingDirectory.embeddedDefault,
                background: false
            )
        }
        let background = try backgroundValue(object["background"])
        let defaultTimeoutValue = background ? defaultBackgroundTimeout : defaultTimeout
        let maxTimeoutValue = background ? maxBackgroundTimeout : maxForegroundTimeout
        let timeoutValue = numericValue(object["timeout_seconds"]) ?? defaultTimeoutValue
        return IOSEmbeddedIshExecuteRequest(
            command: stringValue(object["command"]),
            script: stringValue(object["script"]),
            timeoutSeconds: min(max(1, timeoutValue), maxTimeoutValue),
            purpose: stringValue(object["purpose"]),
            workingDirectory: try workingDirectory(from: object),
            background: background
        )
    }

    static func executionStatus(
        result: IOSEmbeddedIshCommandResult,
        taskCancelled: Bool
    ) -> IOSTerminalJobStatus {
        if result.cancelled || taskCancelled { return .cancelled }
        if result.timedOut { return .timedOut }
        if result.exitCode == 0, result.error == nil { return .completed }
        return .failed
    }

    private static func normalizedCommand(command: String?, script: String?) throws -> String {
        let rawCommand = nonBlankValue(command)
        let rawScript = nonBlankValue(script)
        if rawCommand != nil, rawScript != nil {
            throw IOSEmbeddedIshExecuteError.ambiguousInput
        }
        guard let value = rawScript ?? rawCommand else {
            throw IOSEmbeddedIshExecuteError.emptyInput
        }
        guard value.count <= maxScriptLength else {
            throw IOSEmbeddedIshExecuteError.scriptTooLarge(maxScriptLength)
        }
        return value
    }

    private static func nonBlankValue(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    private static func workingDirectory(from object: [String: Any]) throws -> String {
        guard let value = object["cwd"] else {
            return IOSPOSIXWorkingDirectory.embeddedDefault
        }
        guard let string = value as? String else {
            throw IOSEmbeddedIshExecuteError.invalidArguments("cwd must be a string.")
        }
        return try IOSPOSIXWorkingDirectory.normalized(
            string,
            default: IOSPOSIXWorkingDirectory.embeddedDefault
        ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
    }

    private static func numericValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func backgroundValue(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw IOSEmbeddedIshExecuteError.invalidArguments("background must be a boolean.")
        }
        return number.boolValue
    }
}

enum IOSEmbeddedIshExecuteError: LocalizedError {
    case emptyInput
    case ambiguousInput
    case scriptTooLarge(Int)
    case invalidArguments(String)
    case commandRejected(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Provide exactly one of command or script."
        case .ambiguousInput:
            "Provide command or script, not both."
        case .scriptTooLarge(let maxLength):
            "Embedded iSH script is too large. Maximum length is \(maxLength) characters."
        case .invalidArguments(let message), .commandRejected(let message):
            message
        }
    }
}
