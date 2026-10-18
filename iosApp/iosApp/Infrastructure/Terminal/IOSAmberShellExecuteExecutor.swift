import Foundation
@preconcurrency import Shared

// MARK: - Agent AmberShell execution

private struct IOSAmberShellExecuteRequest {
    let command: String
    let stdin: String?
    let purpose: String?
    let workingDirectory: String
    let timeoutSeconds: TimeInterval
}

@MainActor
enum IOSAmberShellExecuteExecutor {
    static func execute(
        input: String,
        runtime: IOSTerminalRuntime = .shared,
        workspaceStore: IOSWorkspaceStore = .shared,
        onExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)? = nil
    ) async -> String {
        do {
            let request = try parseRequest(input)
            let snapshot = await runtime.startJob(
                command: request.command,
                runtime: .localIOSTools,
                experimentalEnabled: false,
                workingDirectory: request.workingDirectory,
                sshProfile: nil,
                sshPassword: nil,
                timeoutSeconds: request.timeoutSeconds,
                workspaceStore: workspaceStore,
                amberShellStdin: request.stdin,
                amberShellExecutionEvent: onExecutionEvent
            )
            let completed = snapshot.status == IOSTerminalJobStatus.completed.rawValue
                && snapshot.exitCode == 0
            let mayHaveApplied = snapshot.status == "unknown_after_action"
            return IOSWorkspaceStore.json([
                "ok": completed,
                "tool": IOSAmberShellToolCatalog.executeToolName,
                "runtime": IOSTerminalRuntimeKind.localIOSTools.rawValue,
                "cwd": request.workingDirectory,
                "status": snapshot.status,
                "purpose": request.purpose ?? "",
                "exit_code": snapshot.exitCode.map { $0 as Any } ?? NSNull(),
                "stdout": snapshot.stdoutTail,
                "stderr": snapshot.stderrTail,
                "stdout_available": true,
                "stderr_available": true,
                "exit_code_available": snapshot.exitCode != nil,
                "stdout_truncated": snapshot.stdoutTruncated,
                "stderr_truncated": snapshot.stderrTruncated,
                "timed_out": snapshot.status == IOSTerminalJobStatus.timedOut.rawValue,
                "error_code": mayHaveApplied ? "unknown_after_action" : "",
                "may_have_applied": mayHaveApplied,
                "error": snapshot.error ?? "",
            ])
        } catch {
            return failureJSON(error)
        }
    }

    static func approvalPreview(input: String) -> IshHandoffToolApprovalRequest? {
        guard let request = try? parseRequest(input) else { return nil }
        return IshHandoffToolApprovalRequest(
            id: chatInputDigest(for: input),
            mode: .amberShell,
            commandPreview: request.command,
            filename: "AmberShell · \(request.workingDirectory)",
            reason: IOSAppLocalization.string(
                "Amber 将在 App 自有 /workspace 中执行一次非交互 AmberShell 命令，并回传 stdout/stderr/exit code。",
                defaultValue: "Amber 将在 App 自有 /workspace 中执行一次非交互 AmberShell 命令，并回传 stdout/stderr/exit code。"
            ),
            contextLines: [
                IOSAppLocalization.string(
                    "模式：稳定版本地执行（无 PTY）",
                    defaultValue: "模式：稳定版本地执行（无 PTY）"
                ),
                IOSAppLocalization.formatted(
                    "工作目录：%@",
                    defaultValue: "工作目录：%@",
                    arguments: [request.workingDirectory]
                ),
                IOSAppLocalization.formatted(
                    "超时：%lld 秒（协作式）",
                    defaultValue: "超时：%lld 秒（协作式）",
                    arguments: [Int64(request.timeoutSeconds)]
                ),
            ] + (request.stdin.map {
                $0.isEmpty ? [] : [IOSAppLocalization.formatted(
                    "stdin：%lld bytes",
                    defaultValue: "stdin：%lld bytes",
                    arguments: [Int64($0.utf8.count)]
                )]
            } ?? [])
        )
    }

    private static func parseRequest(_ input: String) throws -> IOSAmberShellExecuteRequest {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSAmberShellExecuteError.emptyInput }

        let object: [String: Any]
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        } else {
            object = ["command": trimmed]
        }
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSAmberShellExecuteError.emptyInput
        }
        let cwd = try IOSPOSIXWorkingDirectory.normalized(
            object["cwd"] as? String,
            default: IOSPOSIXWorkingDirectory.embeddedDefault
        ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
        guard cwd == IOSPOSIXWorkingDirectory.embeddedDefault else {
            throw IOSAmberShellExecuteError.unsupportedWorkingDirectory(cwd)
        }
        let stdin: String?
        if let rawStdin = object["stdin"] {
            guard let value = rawStdin as? String else {
                throw IOSAmberShellExecuteError.invalidArguments("stdin must be a string.")
            }
            guard value.utf8.count <= IOSAmberShellInputContract.maxStdinBytes else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "stdin cannot exceed \(IOSAmberShellInputContract.maxStdinBytes) UTF-8 bytes."
                )
            }
            stdin = value
        } else {
            stdin = nil
        }
        let timeoutSeconds: TimeInterval
        if let rawTimeout = object["timeout_seconds"] {
            guard let number = rawTimeout as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "timeout_seconds must be an integer from 1 through 180."
                )
            }
            let value = number.doubleValue
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  (1...180).contains(value) else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "timeout_seconds must be an integer from 1 through 180."
                )
            }
            timeoutSeconds = value
        } else {
            timeoutSeconds = 60
        }
        return IOSAmberShellExecuteRequest(
            command: command,
            stdin: stdin,
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: cwd,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func failureJSON(_ error: Error) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": IOSAmberShellToolCatalog.executeToolName,
            "runtime": IOSTerminalRuntimeKind.localIOSTools.rawValue,
            "status": IOSTerminalJobStatus.failed.rawValue,
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "stdout_available": false,
            "stderr_available": false,
            "exit_code_available": false,
            "timed_out": false,
            "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        ])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}


private enum IOSAmberShellExecuteError: LocalizedError {
    case emptyInput
    case invalidArguments(String)
    case unsupportedWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "需要提供 AmberShell 命令。"
        case .invalidArguments(let message):
            message
        case .unsupportedWorkingDirectory(let path):
            "AmberShell 当前只开放 /workspace，不支持 \(path)。"
        }
    }
}

