import Foundation
@preconcurrency import Shared

// MARK: - Agent Remote SSH execution

private struct IOSRemoteTerminalExecuteRequest {
    let command: String
    let profileId: String?
    let timeoutSeconds: TimeInterval
    let purpose: String?
    let workingDirectory: String?
}

@MainActor
enum IOSRemoteTerminalExecuteExecutor {
    private static let defaultTimeout: TimeInterval = 60
    private static let maxTimeout: TimeInterval = 180

    static func execute(
        input: String,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime = .shared,
        expectedProfileId: String? = nil,
        expectedTargetDigest: String? = nil
    ) async -> String {
        do {
            let request = try parseRequest(input)
            guard let settingsStore else {
                throw IOSRemoteTerminalExecuteError.settingsUnavailable
            }
            let profile: IOSSSHProfile
            let effectiveProfileId = expectedProfileId ?? request.profileId
            if let requestProfileId = request.profileId,
               let expectedProfileId,
               requestProfileId != expectedProfileId {
                throw IOSRemoteTerminalExecuteError.approvedTargetChanged
            }
            if let profileId = effectiveProfileId {
                guard let selected = settingsStore.sshProfiles.first(where: { $0.id == profileId }) else {
                    throw IOSRemoteTerminalExecuteError.profileNotFound(profileId)
                }
                profile = selected
            } else {
                guard let selected = settingsStore.defaultSSHProfile else {
                    throw IOSSSHError.noDefaultProfile
                }
                profile = selected
            }
            if let expectedTargetDigest,
               expectedTargetDigest != remoteSSHTargetDigest(profile) {
                throw IOSRemoteTerminalExecuteError.approvedTargetChanged
            }
            let credential = try settingsStore.credentialForSSHProfile(profile)
            return await execute(request: request, profile: profile, credential: credential, runtime: runtime)
        } catch {
            return failureJSON(error)
        }
    }

    static func execute(
        input: String,
        profile: IOSSSHProfile,
        password: String,
        runtime: IOSTerminalRuntime
    ) async -> String {
        do {
            return await execute(
                request: try parseRequest(input),
                profile: profile,
                credential: .password(password),
                runtime: runtime
            )
        } catch {
            return failureJSON(error)
        }
    }

    static func approvalPreview(
        input: String,
        settingsStore: SettingsStore? = nil
    ) -> IshHandoffToolApprovalRequest? {
        guard let request = try? parseRequest(input), let settingsStore else { return nil }
        let profile: IOSSSHProfile
        if let profileId = request.profileId {
            guard let selected = settingsStore.sshProfiles.first(where: { $0.id == profileId }) else {
                return nil
            }
            profile = selected
        } else {
            guard let selected = settingsStore.defaultSSHProfile else { return nil }
            profile = selected
        }
        let profileLabel = "\(profile.displayName) · \(profile.username)@\(profile.host):\(profile.port)"
        let targetLabel = request.workingDirectory.map { "\(profileLabel) · \($0)" } ?? profileLabel
        return IshHandoffToolApprovalRequest(
            id: chatInputDigest(for: input),
            mode: .remoteSSH,
            commandPreview: request.command,
            filename: targetLabel,
            reason: "Amber 将在已信任的 Remote SSH 连接上执行一次非交互命令，并回传 stdout/stderr/exit code。",
            remoteProfileId: profile.id,
            remoteTargetDigest: remoteSSHTargetDigest(profile)
        )
    }

    private static func execute(
        request: IOSRemoteTerminalExecuteRequest,
        profile: IOSSSHProfile,
        credential: IOSSSHCredential?,
        runtime: IOSTerminalRuntime
    ) async -> String {
        let started = await runtime.startJob(
            command: request.command,
            runtime: .remoteSSH,
            experimentalEnabled: false,
            workingDirectory: request.workingDirectory,
            sshProfile: profile,
            sshCredential: credential,
            timeoutSeconds: request.timeoutSeconds
        )
        var snapshot = started
        if started.status == IOSTerminalJobStatus.running.rawValue {
            snapshot = await runtime.waitJob(
                id: started.id,
                timeoutSeconds: request.timeoutSeconds + 1
            ) ?? started
            if Task.isCancelled {
                snapshot = runtime.stopJob(id: started.id) ?? snapshot
            }
        }
        _ = runtime.consumeTerminalJob(id: started.id)

        let completed = snapshot.status == IOSTerminalJobStatus.completed.rawValue && snapshot.exitCode == 0
        let exitCode: Any = snapshot.exitCode.map { $0 as Any } ?? NSNull()
        return IOSWorkspaceStore.json([
            "ok": completed,
            "tool": "terminal_execute",
            "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
            "profile_id": profile.id,
            "profile_name": profile.displayName,
            "cwd": request.workingDirectory ?? "",
            "status": snapshot.status,
            "purpose": request.purpose ?? "",
            "exit_code": exitCode,
            "stdout": snapshot.stdoutTail,
            "stderr": snapshot.stderrTail,
            "stdout_available": true,
            "stderr_available": true,
            "exit_code_available": snapshot.exitCode != nil,
            "timed_out": snapshot.status == IOSTerminalJobStatus.timedOut.rawValue,
            "error": snapshot.error ?? ""
        ])
    }

    private static func parseRequest(_ input: String) throws -> IOSRemoteTerminalExecuteRequest {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSRemoteTerminalExecuteError.emptyInput }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return IOSRemoteTerminalExecuteRequest(
                command: trimmed,
                profileId: nil,
                timeoutSeconds: defaultTimeout,
                purpose: nil,
                workingDirectory: nil
            )
        }
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSRemoteTerminalExecuteError.emptyInput
        }
        let timeout = numericValue(object["timeout_seconds"]) ?? defaultTimeout
        return IOSRemoteTerminalExecuteRequest(
            command: command,
            profileId: nonEmptyString(object["profile_id"]),
            timeoutSeconds: min(max(1, timeout), maxTimeout),
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: try workingDirectory(from: object)
        )
    }

    private static func failureJSON(_ error: Error, purpose: String? = nil) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": "terminal_execute",
            "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
            "status": IOSTerminalJobStatus.failed.rawValue,
            "purpose": purpose ?? "",
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "stdout_available": false,
            "stderr_available": false,
            "exit_code_available": false,
            "timed_out": false,
            "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        ])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workingDirectory(from object: [String: Any]) throws -> String? {
        guard let value = object["cwd"] else { return nil }
        guard let string = value as? String else {
            throw IOSRemoteTerminalExecuteError.invalidArguments("cwd must be a string.")
        }
        return try IOSPOSIXWorkingDirectory.normalized(string)
    }

    private static func numericValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

}


private enum IOSRemoteTerminalExecuteError: LocalizedError {
    case emptyInput
    case invalidArguments(String)
    case profileNotFound(String)
    case settingsUnavailable
    case approvedTargetChanged

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "A Remote SSH command is required."
        case .invalidArguments(let message):
            message
        case .profileNotFound(let id):
            "SSH profile was not found: \(id)"
        case .settingsUnavailable:
            "SSH settings are unavailable."
        case .approvedTargetChanged:
            "The approved SSH profile or trusted endpoint changed before execution. Review and approve the updated target again."
        }
    }
}

