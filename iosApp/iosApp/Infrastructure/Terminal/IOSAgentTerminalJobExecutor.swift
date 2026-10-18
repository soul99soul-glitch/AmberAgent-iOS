import Foundation
@preconcurrency import Shared

// MARK: - Agent terminal jobs

private struct IOSRemoteTerminalJobStartRequest {
    let command: String
    let profileId: String?
    let timeoutSeconds: TimeInterval
    let purpose: String?
    let workingDirectory: String?
}

private struct IOSRemoteTerminalJobReferenceRequest {
    let jobId: String
    let waitTimeoutSeconds: TimeInterval
}

@MainActor
enum IOSAgentTerminalJobExecutor {
    private static let defaultCommandTimeout: TimeInterval = 60
    private static let maxCommandTimeout: TimeInterval = 180
    private static let defaultWaitTimeout: TimeInterval = 10
    private static let maxWaitTimeout: TimeInterval = 30

    static func execute(
        toolName: String,
        input: String,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        expectedProfileId: String? = nil,
        expectedTargetDigest: String? = nil
    ) async -> String {
        do {
            switch toolName {
            case IOSRemoteTerminalToolCatalog.jobStartToolName:
                return try await start(
                    request: parseStartRequest(input),
                    settingsStore: settingsStore,
                    runtime: runtime,
                    taskStore: taskStore,
                    expectedProfileId: expectedProfileId,
                    expectedTargetDigest: expectedTargetDigest
                )
            case IOSRemoteTerminalToolCatalog.jobReadToolName:
                return try read(
                    request: parseReferenceRequest(input, allowsWait: false),
                    runtime: runtime,
                    taskStore: taskStore,
                    toolName: toolName
                )
            case IOSRemoteTerminalToolCatalog.jobWaitToolName:
                return try await wait(
                    request: parseReferenceRequest(input, allowsWait: true),
                    runtime: runtime,
                    taskStore: taskStore
                )
            case IOSRemoteTerminalToolCatalog.jobStopToolName:
                return try stop(
                    request: parseReferenceRequest(input, allowsWait: false),
                    runtime: runtime,
                    taskStore: taskStore
                )
            default:
                throw IOSRemoteTerminalJobError.unsupportedTool(toolName)
            }
        } catch let error as IOSRemoteTerminalJobError {
            let responseRuntime = error.jobId
                .flatMap { taskStore.task(id: $0) }
                .flatMap(runtimeKind(for:))
            return failureJSON(
                toolName: toolName,
                jobId: error.jobId,
                runtime: responseRuntime,
                errorCode: error.code,
                message: error.localizedDescription
            )
        } catch {
            return failureJSON(
                toolName: toolName,
                jobId: nil,
                runtime: nil,
                errorCode: "invalid_arguments",
                message: error.localizedDescription
            )
        }
    }

    static func startEmbeddedJob(
        command: String,
        purpose: String?,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) async -> String {
        let jobId = UUID().uuidString
        let now = Date()
        taskStore.startTask(
            id: jobId,
            kind: .embeddedIsh,
            title: purpose ?? "Agent 内置 iSH 作业",
            objective: purpose ?? command,
            connectionSummary: "ExperimentalGPL 内置 iSH · \(workingDirectory)",
            commandPreview: command,
            sourceToolName: "ios_ish_execute",
            metadata: [
                "terminal_job": "true",
                "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue,
                "purpose": purpose ?? "",
                "cwd": workingDirectory,
                "execution_mode": "background",
                "lifecycle": "process_local",
                "command_timeout_seconds": String(Int(timeoutSeconds)),
                "started_at_ms": milliseconds(now),
                "stdout_tail": "",
                "stderr_tail": "",
            ],
            now: now
        )

        let started = await runtime.startJob(
            command: command,
            runtime: .ishExperimental,
            experimentalEnabled: true,
            workingDirectory: workingDirectory,
            sshProfile: nil,
            sshPassword: nil,
            timeoutSeconds: timeoutSeconds,
            jobId: jobId
        )
        persist(snapshot: started, taskId: jobId, taskStore: taskStore)

        if started.status == IOSTerminalJobStatus.running.rawValue {
            Task { @MainActor in
                if let finished = await runtime.waitJob(
                    id: jobId,
                    timeoutSeconds: timeoutSeconds + 1
                ) {
                    persist(snapshot: finished, taskId: jobId, taskStore: taskStore)
                    _ = runtime.consumeTerminalJob(id: jobId)
                }
            }
        }
        return responseJSON(
            toolName: "ios_ish_execute",
            jobId: jobId,
            snapshot: started,
            record: taskStore.task(id: jobId),
            operationOK: started.status == IOSTerminalJobStatus.running.rawValue,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    static func approvalPreview(
        toolName: String,
        input: String,
        settingsStore: SettingsStore?,
        taskStore: IOSAdvancedTaskStore
    ) -> IshHandoffToolApprovalRequest? {
        switch toolName {
        case IOSRemoteTerminalToolCatalog.jobStartToolName:
            guard let request = try? parseStartRequest(input) else { return nil }
            guard let profile = resolvedProfile(profileId: request.profileId, settingsStore: settingsStore) else {
                return nil
            }
            return IshHandoffToolApprovalRequest(
                id: chatInputDigest(for: input),
                mode: .remoteJobStart,
                commandPreview: request.command,
                filename: targetLabel(
                    profile: profile,
                    profileId: request.profileId,
                    workingDirectory: request.workingDirectory
                ),
                reason: "Amber 将在已信任的 Remote SSH 连接上启动一个可轮询的非 PTY 作业。",
                contextLines: [
                    "模式：异步 Job（无 PTY、无 stdin）",
                    "工作目录：\(request.workingDirectory ?? "SSH 账户默认目录")",
                    "超时：\(Int(request.timeoutSeconds)) 秒",
                ],
                remoteProfileId: profile.id,
                remoteTargetDigest: remoteSSHTargetDigest(profile)
            )
        case IOSRemoteTerminalToolCatalog.jobStopToolName:
            guard let request = try? parseReferenceRequest(input, allowsWait: false) else { return nil }
            let record = taskStore.task(id: request.jobId)
            let isEmbedded = record?.kind == .embeddedIsh
            return IshHandoffToolApprovalRequest(
                id: chatInputDigest(for: input),
                mode: isEmbedded ? .embeddedJobStop : .remoteJobStop,
                commandPreview: record?.commandPreview.nilIfBlank
                    ?? "停止终端作业 \(request.jobId)",
                filename: record?.connectionSummary.nilIfBlank ?? "Job · \(String(request.jobId.prefix(12)))",
                reason: isEmbedded
                    ? "Amber 将取消当前 App 进程仍在控制的内置 iSH 非 PTY 作业。"
                    : "Amber 将取消当前 App 进程仍在控制的 Remote SSH 作业。",
                contextLines: [
                    "Job ID：\(request.jobId)",
                    "运行环境：\(isEmbedded ? "ExperimentalGPL 内置 iSH" : "Remote SSH")",
                ]
            )
        default:
            return nil
        }
    }

    private static func start(
        request: IOSRemoteTerminalJobStartRequest,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        expectedProfileId: String?,
        expectedTargetDigest: String?
    ) async throws -> String {
        guard let settingsStore else { throw IOSRemoteTerminalJobError.settingsUnavailable }
        if let requestProfileId = request.profileId,
           let expectedProfileId,
           requestProfileId != expectedProfileId {
            throw IOSRemoteTerminalJobError.approvedTargetChanged
        }
        let effectiveProfileId = expectedProfileId ?? request.profileId
        guard let profile = resolvedProfile(profileId: effectiveProfileId, settingsStore: settingsStore) else {
            if let profileId = effectiveProfileId {
                throw IOSRemoteTerminalJobError.profileNotFound(profileId)
            }
            throw IOSRemoteTerminalJobError.noDefaultProfile
        }
        if let expectedTargetDigest,
           expectedTargetDigest != remoteSSHTargetDigest(profile) {
            throw IOSRemoteTerminalJobError.approvedTargetChanged
        }
        let credential = try settingsStore.credentialForSSHProfile(profile)
        let jobId = UUID().uuidString
        let now = Date()
        taskStore.startTask(
            id: jobId,
            kind: .remoteCommand,
            title: request.purpose ?? "Agent Remote SSH 作业",
            objective: request.purpose ?? request.command,
            connectionSummary: profileLabel(profile: profile, profileId: profile.id),
            commandPreview: request.command,
            sourceToolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            metadata: [
                "terminal_job": "true",
                "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
                "profile_id": profile.id,
                "profile_name": profile.displayName,
                "purpose": request.purpose ?? "",
                "cwd": request.workingDirectory ?? "",
                "execution_mode": "background",
                "lifecycle": "process_local",
                "command_timeout_seconds": String(Int(request.timeoutSeconds)),
                "started_at_ms": milliseconds(now),
                "stdout_tail": "",
                "stderr_tail": "",
            ],
            now: now
        )

        let started = await runtime.startJob(
            command: request.command,
            runtime: .remoteSSH,
            experimentalEnabled: false,
            workingDirectory: request.workingDirectory,
            sshProfile: profile,
            sshCredential: credential,
            timeoutSeconds: request.timeoutSeconds,
            jobId: jobId
        )
        persist(snapshot: started, taskId: jobId, taskStore: taskStore)

        if started.status == IOSTerminalJobStatus.running.rawValue {
            Task { @MainActor in
                if let finished = await runtime.waitJob(
                    id: jobId,
                    timeoutSeconds: request.timeoutSeconds + 1
                ) {
                    persist(snapshot: finished, taskId: jobId, taskStore: taskStore)
                    _ = runtime.consumeTerminalJob(id: jobId)
                }
            }
        }
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            jobId: jobId,
            snapshot: started,
            record: taskStore.task(id: jobId),
            operationOK: started.status == IOSTerminalJobStatus.running.rawValue,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    private static func read(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        toolName: String
    ) throws -> String {
        let resolved = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        return responseJSON(
            toolName: toolName,
            jobId: request.jobId,
            snapshot: resolved.snapshot,
            record: resolved.record,
            operationOK: true,
            waitTimedOut: false,
            alreadyTerminal: resolved.status.isTerminal
        )
    }

    private static func wait(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) async throws -> String {
        let initial = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        if initial.status.isTerminal {
            _ = runtime.consumeTerminalJob(id: request.jobId)
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
                jobId: request.jobId,
                snapshot: initial.snapshot,
                record: initial.record,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: true
            )
        }

        let deadline = Date().addingTimeInterval(request.waitTimeoutSeconds)
        var latest = initial
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            latest = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
            if latest.status.isTerminal { break }
        }
        if latest.status.isTerminal {
            _ = runtime.consumeTerminalJob(id: request.jobId)
        }
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
            jobId: request.jobId,
            snapshot: latest.snapshot,
            record: latest.record,
            operationOK: true,
            waitTimedOut: !latest.status.isTerminal,
            alreadyTerminal: false
        )
    }

    private static func stop(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) throws -> String {
        let current = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        if current.status.isTerminal {
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
                jobId: request.jobId,
                snapshot: current.snapshot,
                record: current.record,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: true
            )
        }
        guard let stopped = runtime.stopJob(id: request.jobId) else {
            let interrupted = interruptMissingRuntimeJob(record: current.record, taskStore: taskStore)
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
                jobId: request.jobId,
                snapshot: nil,
                record: interrupted,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: false
            )
        }
        persist(snapshot: stopped, taskId: request.jobId, taskStore: taskStore)
        _ = runtime.consumeTerminalJob(id: request.jobId)
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
            jobId: request.jobId,
            snapshot: stopped,
            record: taskStore.task(id: request.jobId),
            operationOK: true,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    private static func resolveSnapshot(
        jobId: String,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) throws -> (snapshot: IOSTerminalJobSnapshot?, record: IOSAdvancedTaskRecord, status: IOSAdvancedTaskStatus) {
        guard var record = taskStore.task(id: jobId),
              runtimeKind(for: record) != nil,
              record.metadata["terminal_job"] == "true" else {
            throw IOSRemoteTerminalJobError.jobNotFound(jobId)
        }
        if let snapshot = runtime.readJob(id: jobId) {
            let changed = record.status != advancedStatus(snapshot.status)
                || record.metadata["updated_at_ms"] != milliseconds(snapshot.updatedAt)
            if changed {
                persist(snapshot: snapshot, taskId: jobId, taskStore: taskStore)
                record = taskStore.task(id: jobId) ?? record
            }
            return (snapshot, record, record.status)
        }
        if record.status == .running {
            record = interruptMissingRuntimeJob(record: record, taskStore: taskStore) ?? record
        }
        return (nil, record, record.status)
    }

    @discardableResult
    private static func interruptMissingRuntimeJob(
        record: IOSAdvancedTaskRecord,
        taskStore: IOSAdvancedTaskStore
    ) -> IOSAdvancedTaskRecord? {
        let isEmbedded = record.kind == .embeddedIsh
        return taskStore.updateTask(
            id: record.id,
            status: .interrupted,
            resultSummary: isEmbedded
                ? "应用进程已结束，内置 iSH 命令的最终结果未知。"
                : "应用进程已结束，远程命令的最终结果未知。",
            error: isEmbedded
                ? "无法重新连接该内置 iSH 作业。"
                : "无法重新连接该 Remote SSH 作业。",
            retryable: false,
            cancelCapability: false,
            metadata: [
                "interruption_reason": "process_terminated",
                "outcome": "unknown",
            ]
        )
    }

    private static func persist(
        snapshot: IOSTerminalJobSnapshot,
        taskId: String,
        taskStore: IOSAdvancedTaskStore
    ) {
        let status = advancedStatus(snapshot.status)
        let runtimeTitle = snapshot.runtime == .ishExperimental ? "内置 iSH" : "Remote SSH"
        let summary: String
        switch status {
        case .running, .queued:
            summary = ""
        case .completed:
            summary = "\(runtimeTitle) 作业已完成。"
        case .failed:
            summary = "\(runtimeTitle) 作业执行失败。"
        case .cancelled:
            summary = "\(runtimeTitle) 作业已取消。"
        case .timedOut:
            summary = "\(runtimeTitle) 作业已超时。"
        case .interrupted:
            summary = "\(runtimeTitle) 作业已中断。"
        case .approvalRequired:
            summary = "\(runtimeTitle) 作业等待确认。"
        }
        taskStore.updateTask(
            id: taskId,
            status: status,
            resultSummary: summary,
            logTail: snapshot.outputTail,
            error: snapshot.error ?? "",
            retryable: false,
            cancelCapability: status == .running,
            metadata: [
                "runtime_job_id": snapshot.id,
                "runtime": snapshot.runtime.rawValue,
                "stdout_tail": snapshot.stdoutTail,
                "stderr_tail": snapshot.stderrTail,
                "stdout_truncated": String(snapshot.stdoutTruncated),
                "stderr_truncated": String(snapshot.stderrTruncated),
                "stdout_persisted_truncated": String(snapshot.stdoutTail.count > 4_000),
                "stderr_persisted_truncated": String(snapshot.stderrTail.count > 4_000),
                "exit_code": snapshot.exitCode.map(String.init) ?? "",
                "started_at_ms": milliseconds(snapshot.startedAt),
                "updated_at_ms": milliseconds(snapshot.updatedAt),
            ]
        )
    }

    private static func responseJSON(
        toolName: String,
        jobId: String,
        snapshot: IOSTerminalJobSnapshot?,
        record: IOSAdvancedTaskRecord?,
        operationOK: Bool,
        waitTimedOut: Bool,
        alreadyTerminal: Bool
    ) -> String {
        let status = snapshot?.status ?? terminalStatus(record?.status).rawValue
        let exitCode = snapshot?.exitCode ?? record?.metadata["exit_code"].flatMap(Int.init)
        let stdout = snapshot?.stdoutTail ?? record?.metadata["stdout_tail"] ?? ""
        let stderr = snapshot?.stderrTail ?? record?.metadata["stderr_tail"] ?? ""
        let output = snapshot?.outputTail ?? record?.logTail ?? ""
        let terminalStatus = IOSTerminalJobStatus(rawValue: status)
        let runtime = snapshot?.runtime ?? record.flatMap(runtimeKind(for:))
        let commandOK: Any
        if terminalStatus == .completed {
            commandOK = (exitCode == 0)
        } else if terminalStatus == .failed {
            commandOK = false
        } else {
            commandOK = NSNull()
        }
        let errorCode: Any
        if terminalStatus == .interrupted {
            errorCode = "process_terminated"
        } else if terminalStatus == .timedOut {
            errorCode = "timeout"
        } else {
            errorCode = NSNull()
        }
        return IOSWorkspaceStore.json([
            "ok": operationOK,
            "tool": toolName,
            "runtime": runtime?.rawValue ?? "unknown",
            "job_id": jobId,
            "cwd": record?.metadata["cwd"] ?? "",
            "background": record?.metadata["execution_mode"] == "background",
            "lifecycle": record?.metadata["lifecycle"] ?? "process_local",
            "status": status,
            "running": terminalStatus == .running,
            "command_ok": commandOK,
            "exit_code": exitCode.map { $0 as Any } ?? NSNull(),
            "stdout": stdout,
            "stderr": stderr,
            "output_tail": output,
            "stdout_available": true,
            "stderr_available": true,
            "stdout_truncated": snapshot?.stdoutTruncated
                ?? (record?.metadata["stdout_truncated"] == "true"),
            "stderr_truncated": snapshot?.stderrTruncated
                ?? (record?.metadata["stderr_truncated"] == "true"),
            "persisted_snapshot": snapshot == nil,
            "stdout_persisted_truncated": record?.metadata["stdout_persisted_truncated"] == "true",
            "stderr_persisted_truncated": record?.metadata["stderr_persisted_truncated"] == "true",
            "exit_code_available": exitCode != nil,
            "started_at_ms": timestampValue(snapshot?.startedAt, fallback: record?.createdAt),
            "updated_at_ms": timestampValue(snapshot?.updatedAt, fallback: record?.updatedAt),
            "wait_timed_out": waitTimedOut,
            "already_terminal": alreadyTerminal,
            "error_code": errorCode,
            "error": snapshot?.error ?? record?.error ?? "",
            "related_tools": [
                IOSRemoteTerminalToolCatalog.jobReadToolName,
                IOSRemoteTerminalToolCatalog.jobWaitToolName,
                IOSRemoteTerminalToolCatalog.jobStopToolName,
            ],
        ])
    }

    private static func failureJSON(
        toolName: String,
        jobId: String?,
        runtime: IOSTerminalRuntimeKind?,
        errorCode: String,
        message: String
    ) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": toolName,
            "runtime": runtime?.rawValue ?? "unknown",
            "job_id": jobId ?? "",
            "status": IOSTerminalJobStatus.failed.rawValue,
            "running": false,
            "command_ok": NSNull(),
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "output_tail": "",
            "stdout_available": false,
            "stderr_available": false,
            "stdout_truncated": false,
            "stderr_truncated": false,
            "exit_code_available": false,
            "wait_timed_out": false,
            "already_terminal": false,
            "error_code": errorCode,
            "error": message,
        ])
    }

    private static func parseStartRequest(_ input: String) throws -> IOSRemoteTerminalJobStartRequest {
        let object = try inputObject(input)
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSRemoteTerminalJobError.invalidArguments("A Remote SSH command is required.")
        }
        let timeout = numericValue(object["timeout_seconds"]) ?? defaultCommandTimeout
        return IOSRemoteTerminalJobStartRequest(
            command: command,
            profileId: nonEmptyString(object["profile_id"]),
            timeoutSeconds: min(max(1, timeout), maxCommandTimeout),
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: try workingDirectory(from: object)
        )
    }

    private static func parseReferenceRequest(
        _ input: String,
        allowsWait: Bool
    ) throws -> IOSRemoteTerminalJobReferenceRequest {
        let object = try inputObject(input)
        guard let jobId = nonEmptyString(object["job_id"]) else {
            throw IOSRemoteTerminalJobError.invalidArguments("job_id is required.")
        }
        let wait = allowsWait
            ? min(max(1, numericValue(object["wait_timeout_seconds"]) ?? defaultWaitTimeout), maxWaitTimeout)
            : 0
        return IOSRemoteTerminalJobReferenceRequest(jobId: jobId, waitTimeoutSeconds: wait)
    }

    private static func inputObject(_ input: String) throws -> [String: Any] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSRemoteTerminalJobError.invalidArguments("A JSON object is required.")
        }
        return object
    }

    private static func resolvedProfile(
        profileId: String?,
        settingsStore: SettingsStore?
    ) -> IOSSSHProfile? {
        guard let settingsStore else { return nil }
        if let profileId {
            return settingsStore.sshProfiles.first(where: { $0.id == profileId })
        }
        return settingsStore.defaultSSHProfile
    }

    private static func profileLabel(profile: IOSSSHProfile?, profileId: String?) -> String {
        if let profile {
            return "\(profile.displayName) · \(profile.username)@\(profile.host):\(profile.port)"
        }
        if let profileId { return "SSH Profile · \(String(profileId.prefix(12)))" }
        return "默认 SSH Profile"
    }

    private static func targetLabel(
        profile: IOSSSHProfile?,
        profileId: String?,
        workingDirectory: String?
    ) -> String {
        let profile = profileLabel(profile: profile, profileId: profileId)
        return workingDirectory.map { "\(profile) · \($0)" } ?? profile
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workingDirectory(from object: [String: Any]) throws -> String? {
        guard let value = object["cwd"] else { return nil }
        guard let string = value as? String else {
            throw IOSRemoteTerminalJobError.invalidArguments("cwd must be a string.")
        }
        return try IOSPOSIXWorkingDirectory.normalized(string)
    }

    private static func numericValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func runtimeKind(for record: IOSAdvancedTaskRecord) -> IOSTerminalRuntimeKind? {
        let persistedRuntime = record.metadata["runtime"].flatMap(IOSTerminalRuntimeKind.init(rawValue:))
        switch record.kind {
        case .remoteCommand:
            guard persistedRuntime == nil || persistedRuntime == .remoteSSH else { return nil }
            return .remoteSSH
        case .embeddedIsh:
            guard persistedRuntime == nil || persistedRuntime == .ishExperimental else { return nil }
            return .ishExperimental
        case .subAgent, .modelCouncil, .toolApproval:
            return nil
        }
    }

    private static func advancedStatus(_ rawValue: String) -> IOSAdvancedTaskStatus {
        switch IOSTerminalJobStatus(rawValue: rawValue) {
        case .queued: .queued
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .interrupted: .interrupted
        case nil: .failed
        }
    }

    private static func terminalStatus(_ status: IOSAdvancedTaskStatus?) -> IOSTerminalJobStatus {
        switch status {
        case .queued: .queued
        case .running: .running
        case .completed: .completed
        case .failed, .approvalRequired, nil: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .interrupted: .interrupted
        }
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000))
    }

    private static func timestampValue(_ date: Date?, fallback: Date?) -> Any {
        guard let date = date ?? fallback else { return NSNull() }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}


private enum IOSRemoteTerminalJobError: LocalizedError {
    case invalidArguments(String)
    case settingsUnavailable
    case noDefaultProfile
    case profileNotFound(String)
    case jobNotFound(String)
    case unsupportedTool(String)
    case approvedTargetChanged

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .settingsUnavailable, .noDefaultProfile, .profileNotFound: "configuration_error"
        case .jobNotFound: "job_not_found"
        case .unsupportedTool: "unsupported_tool"
        case .approvedTargetChanged: "approved_target_changed"
        }
    }

    var jobId: String? {
        if case .jobNotFound(let id) = self { return id }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .settingsUnavailable: "SSH settings are unavailable."
        case .noDefaultProfile: "No default SSH profile is selected."
        case .profileNotFound(let id): "SSH profile was not found: \(id)"
        case .jobNotFound(let id): "Terminal job was not found: \(id)"
        case .unsupportedTool(let name): "Unsupported terminal job tool: \(name)"
        case .approvedTargetChanged: "The approved SSH profile or trusted endpoint changed before execution. Review and approve the updated target again."
        }
    }
}

