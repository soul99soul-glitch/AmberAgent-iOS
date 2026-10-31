import Foundation
@preconcurrency import Shared

protocol IOSSSHRuntimeBackendProtocol: Sendable {
    func testConnection(profile: IOSSSHProfile) async throws -> IOSSSHConnectionProbeResult
    func probeRoute(
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential]
    ) async throws -> [IOSSSHHopProbeResult]
    func execute(
        command: String,
        profile: IOSSSHProfile,
        credential: IOSSSHCredential,
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult
    func executeRoute(
        command: String,
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential],
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult
}

extension IOSSSHRuntimeBackendProtocol {
    func probeRoute(
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential]
    ) async throws -> [IOSSSHHopProbeResult] {
        guard route.count == 1, let first = route.first else { throw IOSSSHError.backendUnavailable }
        let single = try await testConnection(profile: first)
        return [IOSSSHHopProbeResult(hopIndex: 1, hopCount: 1, profileId: first.id,
                                    host: first.host, port: first.port,
                                    fingerprint: single.fingerprint, trustState: single.trustState)]
    }

    func executeRoute(
        command: String,
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential],
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult {
        _ = try IOSSSHMultiHopClient.preflightValidate(route: route, credentials: credentials)
        guard route.count == 1, let target = route.last, let credential = credentials[target.id] else {
            throw IOSSSHError.noDefaultProfile
        }
        return try await execute(
            command: command,
            profile: target,
            credential: credential,
            timeout: timeout,
            output: output
        )
    }
}

/// Seam for embedded-iSH job execution. The production witness is
/// `IOSEmbeddedIshRuntime.shared`; tests inject fakes so job orchestration
/// (streaming, cancellation, timeout) is verifiable in the stable test
/// bundle without linking the GPL runtime. Cancelling the task returned by
/// the surrounding job must terminate the guest command.
protocol IOSEmbeddedIshJobBackend: Sendable {
    func runJob(
        command: String,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (IOSEmbeddedIshOutputChunk) -> Void
    ) async -> IOSEmbeddedIshCommandResult
}

private final class IOSTerminalJobState {
    let id: String
    let runtime: IOSTerminalRuntimeKind
    let startedAt: Date
    var updatedAt: Date
    var status: IOSTerminalJobStatus
    var exitCode: Int?
    var outputTail: String
    var stdoutTail: String
    var stderrTail: String
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var lastOutputWasStderr: Bool?
    var error: String?
    var hopFailure: IOSSSHHopFailure?
    var task: Task<Void, Never>?

    init(id: String, runtime: IOSTerminalRuntimeKind, startedAt: Date, status: IOSTerminalJobStatus) {
        self.id = id
        self.runtime = runtime
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.status = status
        self.outputTail = ""
        self.stdoutTail = ""
        self.stderrTail = ""
        self.stdoutTruncated = false
        self.stderrTruncated = false
    }

    var snapshot: IOSTerminalJobSnapshot {
        IOSTerminalJobSnapshot(
            id: id,
            runtime: runtime,
            status: status.rawValue,
            exitCode: exitCode,
            outputTail: outputTail,
            stdoutTail: stdoutTail,
            stderrTail: stderrTail,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            startedAt: startedAt,
            updatedAt: updatedAt,
            error: error,
            hopFailure: hopFailure
        )
    }
}

@MainActor
final class IOSTerminalRuntime {
    static let shared = IOSTerminalRuntime(sshBackend: IOSSSHRuntimeBackend())

    private static let outputTailLimit = 128 * 1024

    private let sshBackend: IOSSSHRuntimeBackendProtocol
    private let embeddedIshBackend: IOSEmbeddedIshJobBackend
    private let experimentalRuntimesLinked: Bool
    private var jobs: [String: IOSTerminalJobState] = [:]

    init(
        sshBackend: IOSSSHRuntimeBackendProtocol,
        embeddedIshBackend: IOSEmbeddedIshJobBackend = IOSEmbeddedIshRuntime.shared,
        experimentalRuntimesLinked: Bool = IOSTerminalBuildPolicy.experimentalRuntimesLinked
    ) {
        self.sshBackend = sshBackend
        self.embeddedIshBackend = embeddedIshBackend
        self.experimentalRuntimesLinked = experimentalRuntimesLinked
    }

    func testSSHConnection(profile: IOSSSHProfile) async throws -> IOSSSHConnectionProbeResult {
        try await sshBackend.testConnection(profile: profile.validated())
    }

    func testSSHRoute(
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential]
    ) async throws -> [IOSSSHHopProbeResult] {
        let validatedRoute = try route.map { try $0.validated() }
        return try await sshBackend.probeRoute(route: validatedRoute, credentials: credentials)
    }

    func startJob(
        command: String,
        runtime: IOSTerminalRuntimeKind,
        experimentalEnabled: Bool,
        workingDirectory: String? = nil,
        amberShellStdin: String? = nil
    ) async -> IOSTerminalJobSnapshot {
        await startJob(
            command: command,
            runtime: runtime,
            experimentalEnabled: experimentalEnabled,
            workingDirectory: workingDirectory,
            sshProfile: nil,
            sshPassword: nil,
            amberShellStdin: amberShellStdin
        )
    }

    func startJob(
        command: String,
        runtime: IOSTerminalRuntimeKind,
        experimentalEnabled: Bool,
        workingDirectory: String? = nil,
        sshProfile: IOSSSHProfile?,
        sshPassword: String? = nil,
        sshCredential: IOSSSHCredential? = nil,
        sshRoute: [IOSSSHProfile]? = nil,
        sshRouteCredentials: [String: IOSSSHCredential]? = nil,
        timeoutSeconds: TimeInterval = 60,
        jobId: String? = nil,
        workspaceStore: IOSWorkspaceStore = .shared,
        amberShellStdin: String? = nil,
        amberShellExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)? = nil
    ) async -> IOSTerminalJobSnapshot {
        let now = Date()
        let capability = IOSTerminalRuntimeCapabilities.capability(for: runtime)
        if capability.tier == .experimental && !experimentalRuntimesLinked {
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "\(runtime.displayName) is not linked in this stable build.",
                id: jobId
            )
        }
        if capability.tier == .experimental && !experimentalEnabled {
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "\(runtime.displayName) is experimental and disabled in the stable build.",
                id: jobId
            )
        }

        switch runtime {
        case .remoteSSH:
            return startSSHJob(
                command: command,
                workingDirectory: workingDirectory,
                now: now,
                profile: sshProfile,
                credential: sshCredential ?? sshPassword.map(IOSSSHCredential.password),
                route: sshRoute,
                routeCredentials: sshRouteCredentials,
                timeoutSeconds: timeoutSeconds,
                jobId: jobId
            )
        case .localIOSTools:
            do {
                let cwd = try IOSPOSIXWorkingDirectory.normalized(
                    workingDirectory,
                    default: IOSPOSIXWorkingDirectory.embeddedDefault
                ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
                guard cwd == IOSPOSIXWorkingDirectory.embeddedDefault else {
                    return failedSnapshot(
                        runtime: runtime,
                        command: command,
                        now: now,
                        message: "AmberShell currently exposes only /workspace.",
                        id: jobId
                    )
                }
                return try await runLocalTool(
                    command: command,
                    workingDirectory: cwd,
                    workspaceStore: workspaceStore,
                    amberShellStdin: amberShellStdin,
                    timeoutSeconds: timeoutSeconds,
                    now: now,
                    jobId: jobId,
                    onExecutionEvent: amberShellExecutionEvent
                )
            } catch {
                return failedSnapshot(
                    runtime: runtime,
                    command: command,
                    now: now,
                    message: error.localizedDescription,
                    id: jobId
                )
            }
        case .remoteMosh:
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "Remote Mosh requires GPL/license review before it can be linked into a distributable build.",
                id: jobId
            )
        case .ishExperimental:
            return startEmbeddedIshJob(
                command: command,
                workingDirectory: workingDirectory,
                now: now,
                timeoutSeconds: timeoutSeconds,
                jobId: jobId
            )
        }
    }

    func readJob(id: String) -> IOSTerminalJobSnapshot? {
        jobs[id]?.snapshot
    }

    /// One-shot executors consume their terminal snapshot after constructing
    /// the tool result. Durable job handles remain available to read/wait/stop.
    func consumeTerminalJob(id: String) -> IOSTerminalJobSnapshot? {
        guard let job = jobs[id], job.status.isTerminal else { return nil }
        jobs.removeValue(forKey: id)
        return job.snapshot
    }

    func waitJob(id: String, timeoutSeconds: TimeInterval = 60) async -> IOSTerminalJobSnapshot? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // Caller cancellation stops the wait, not the job: hand back the
            // current snapshot without mutating job state.
            guard !Task.isCancelled else { return jobs[id]?.snapshot }
            guard let job = jobs[id] else { return nil }
            if job.status.isTerminal {
                return job.snapshot
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let job = jobs[id] else { return nil }
        guard !job.status.isTerminal else { return job.snapshot }
        job.task?.cancel()
        job.status = .timedOut
        job.error = Self.timeoutMessage(for: job.runtime)
        job.updatedAt = Date()
        return job.snapshot
    }

    func stopJob(id: String) -> IOSTerminalJobSnapshot? {
        guard let job = jobs[id] else { return nil }
        guard !job.status.isTerminal else { return job.snapshot }
        job.task?.cancel()
        job.status = .cancelled
        job.error = Self.cancellationMessage(for: job.runtime)
        job.updatedAt = Date()
        return job.snapshot
    }

    private func startSSHJob(
        command: String,
        workingDirectory: String?,
        now: Date,
        profile: IOSSSHProfile?,
        credential: IOSSSHCredential?,
        route: [IOSSSHProfile]? = nil,
        routeCredentials: [String: IOSSSHCredential]? = nil,
        timeoutSeconds: TimeInterval,
        jobId: String?
    ) -> IOSTerminalJobSnapshot {
        let validatedCommand: String
        switch IOSRemoteCommandPolicy.validate(command) {
        case .success(let command):
            validatedCommand = command
        case .failure(let message):
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: message,
                id: jobId
            )
        }
        let normalizedWorkingDirectory: String?
        do {
            normalizedWorkingDirectory = try IOSPOSIXWorkingDirectory.normalized(workingDirectory)
        } catch {
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }

        let validatedRoute: [IOSSSHProfile]
        let validatedCredentials: [String: IOSSSHCredential]
        let isMultiHopRequest = (route?.count ?? 0) > 1
        do {
            if let route, !route.isEmpty {
                var creds = routeCredentials ?? [:]
                if let profile, let credential, creds[profile.id] == nil {
                    creds[profile.id] = credential
                }
                if route.count == 1, let single = route.first {
                    let validated = try single.validated()
                    guard validated.knownHostSHA256?.isEmpty == false else {
                        throw IOSSSHError.hopFailure(
                            IOSSSHHopFailure(
                                status: "host_key_untrusted",
                                hopIndex: 1,
                                hopCount: 1,
                                profileId: validated.id,
                                display: "\(validated.displayName) (\(validated.username)@\(validated.host):\(validated.port))",
                                expectedFingerprint: nil,
                                presentedFingerprint: nil,
                                message: "Run Test Connection and Trust Host first."
                            )
                        )
                    }
                    guard let singleCred = creds[validated.id] else {
                        throw validated.authMethod == .password ? IOSSSHError.missingPassword : IOSSSHError.missingPrivateKey
                    }
                    let validCred = try singleCred.validated(for: validated)
                    validatedRoute = [validated]
                    validatedCredentials = [validated.id: validCred]
                } else {
                    let preflight = try IOSSSHMultiHopClient.preflightValidate(route: route, credentials: creds)
                    validatedRoute = preflight
                    validatedCredentials = creds
                }
            } else {
                guard let profile else { throw IOSSSHError.noDefaultProfile }
                let validated = try profile.validated()
                guard validated.knownHostSHA256?.isEmpty == false else {
                    throw IOSSSHError.hopFailure(IOSSSHHopFailure(status: "host_key_untrusted", hopIndex: 1,
                        hopCount: 1, profileId: validated.id, display: validated.displayName,
                        message: "Run Test Connection and Trust Host first."))
                }
                guard let credential else {
                    throw validated.authMethod == .password ? IOSSSHError.missingPassword : IOSSSHError.missingPrivateKey
                }
                let validCred = try credential.validated(for: validated)
                validatedRoute = [validated]
                validatedCredentials = [validated.id: validCred]
            }
        } catch let IOSSSHError.hopFailure(failure) {
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: failure.message,
                id: jobId,
                hopFailure: failure
            )
        } catch {
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }

        let job = IOSTerminalJobState(
            id: jobId ?? UUID().uuidString,
            runtime: .remoteSSH,
            startedAt: now,
            status: .running
        )
        jobs[job.id] = job

        let jobId = job.id
        let sshBackend = sshBackend
        let allCredentials = Array(validatedCredentials.values)
        job.task = Task {
            do {
                let remoteCmd = IOSPOSIXWorkingDirectory.remoteCommand(
                    validatedCommand,
                    workingDirectory: normalizedWorkingDirectory
                )
                let result: IOSSSHCommandResult
                if isMultiHopRequest || validatedRoute.count > 1 {
                    result = try await sshBackend.executeRoute(
                        command: remoteCmd,
                        route: validatedRoute,
                        credentials: validatedCredentials,
                        timeout: timeoutSeconds,
                        output: { chunk in
                            Task { @MainActor in
                                self.appendOutput(chunk, to: jobId)
                            }
                        }
                    )
                } else {
                    let target = validatedRoute[0]
                    let targetCred = validatedCredentials[target.id]!
                    result = try await sshBackend.execute(
                        command: remoteCmd,
                        profile: target,
                        credential: targetCred,
                        timeout: timeoutSeconds,
                        output: { chunk in
                            Task { @MainActor in
                                self.appendOutput(chunk, to: jobId)
                            }
                        }
                    )
                }
                updateJob(
                    id: jobId,
                    status: result.exitCode == 0 ? .completed : .failed,
                    exitCode: result.exitCode,
                    output: result.output,
                    error: result.exitCode == 0 ? nil : "Remote command exited with \(result.exitCode ?? -1).",
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            } catch is CancellationError {
                updateJob(
                    id: jobId,
                    status: .cancelled,
                    exitCode: nil,
                    output: nil,
                    error: IOSSSHError.commandCancelled.localizedDescription
                )
            } catch IOSSSHError.commandTimedOut {
                updateJob(
                    id: jobId,
                    status: .timedOut,
                    exitCode: nil,
                    output: nil,
                    error: IOSSSHError.commandTimedOut.localizedDescription
                )
            } catch IOSSSHError.hostKeyMismatch(let expected, let actual) {
                let target = validatedRoute[0]
                let failure = IOSSSHHopFailure(status: "host_key_changed", hopIndex: 1, hopCount: 1,
                    profileId: target.id, display: target.displayName, expectedFingerprint: expected,
                    presentedFingerprint: actual, message: "第 1 跳主机指纹变化，已拦截。请在设置中人工核对。")
                updateJob(id: jobId, status: .failed, exitCode: nil, output: nil, error: failure.message, hopFailure: failure)
            } catch let IOSSSHError.hopFailure(failure) {
                let redactedMsg = IOSSSHOutputRedactor.redact(failure.message, credentials: allCredentials)
                let redactedFailure = IOSSSHHopFailure(
                    status: failure.status,
                    hopIndex: failure.hopIndex,
                    hopCount: failure.hopCount,
                    profileId: failure.profileId,
                    display: failure.display,
                    expectedFingerprint: failure.expectedFingerprint,
                    presentedFingerprint: failure.presentedFingerprint,
                    message: redactedMsg
                )
                updateJob(
                    id: jobId,
                    status: .failed,
                    exitCode: nil,
                    output: nil,
                    error: redactedMsg,
                    hopFailure: redactedFailure
                )
            } catch {
                updateJob(
                    id: jobId,
                    status: .failed,
                    exitCode: nil,
                    output: nil,
                    error: IOSSSHOutputRedactor.redact(error.localizedDescription, credentials: allCredentials)
                )
            }
        }
        return job.snapshot
    }

    private func appendOutput(_ chunk: IOSSSHOutputChunk, to id: String) {
        guard let job = jobs[id], !chunk.text.isEmpty else { return }
        guard !job.status.isTerminal else { return }
        if chunk.isStderr {
            let value = job.stderrTail + chunk.text
            job.stderrTruncated = job.stderrTruncated || exceedsOutputLimit(value)
            job.stderrTail = limitedTail(value)
            if job.lastOutputWasStderr != true {
                let separator = job.outputTail.isEmpty || job.outputTail.hasSuffix("\n") ? "" : "\n"
                job.outputTail = limitedTail(job.outputTail + separator + "[stderr]\n")
            }
        } else {
            let value = job.stdoutTail + chunk.text
            job.stdoutTruncated = job.stdoutTruncated || exceedsOutputLimit(value)
            job.stdoutTail = limitedTail(value)
        }
        job.outputTail = limitedTail(job.outputTail + chunk.text)
        job.lastOutputWasStderr = chunk.isStderr
        job.updatedAt = Date()
    }

    private func appendOutput(_ chunk: IOSEmbeddedIshOutputChunk, to id: String) {
        guard let job = jobs[id], !chunk.text.isEmpty else { return }
        guard !job.status.isTerminal else { return }
        if chunk.isStderr {
            let value = job.stderrTail + chunk.text
            job.stderrTruncated = job.stderrTruncated || exceedsOutputLimit(value)
            job.stderrTail = limitedTail(value)
            if job.lastOutputWasStderr != true {
                let separator = job.outputTail.isEmpty || job.outputTail.hasSuffix("\n") ? "" : "\n"
                job.outputTail = limitedTail(job.outputTail + separator + "[stderr]\n")
            }
        } else {
            let value = job.stdoutTail + chunk.text
            job.stdoutTruncated = job.stdoutTruncated || exceedsOutputLimit(value)
            job.stdoutTail = limitedTail(value)
        }
        job.outputTail = limitedTail(job.outputTail + chunk.text)
        job.lastOutputWasStderr = chunk.isStderr
        job.updatedAt = Date()
    }

    private func updateJob(
        id: String,
        status: IOSTerminalJobStatus,
        exitCode: Int?,
        output: String?,
        error: String?,
        stdout: String? = nil,
        stderr: String? = nil,
        stdoutTruncated: Bool? = nil,
        stderrTruncated: Bool? = nil,
        hopFailure: IOSSSHHopFailure? = nil
    ) {
        guard let job = jobs[id] else { return }
        guard !job.status.isTerminal else { return }
        if let output {
            job.outputTail = limitedTail(output)
        }
        if let stdout {
            job.stdoutTruncated = stdoutTruncated ?? exceedsOutputLimit(stdout)
            job.stdoutTail = limitedTail(stdout)
        }
        if let stderr {
            job.stderrTruncated = stderrTruncated ?? exceedsOutputLimit(stderr)
            job.stderrTail = limitedTail(stderr)
        }
        if let hopFailure {
            job.hopFailure = hopFailure
        }
        job.status = status
        job.exitCode = exitCode
        job.error = error
        job.updatedAt = Date()
    }

    private func limitedTail(_ value: String) -> String {
        let utf8 = Array(value.utf8)
        guard utf8.count > Self.outputTailLimit else { return value }
        let suffix = utf8.suffix(Self.outputTailLimit)
        return String(decoding: suffix, as: UTF8.self)
    }

    private func exceedsOutputLimit(_ value: String) -> Bool {
        value.utf8.count > Self.outputTailLimit
    }

    private static func timeoutMessage(for runtime: IOSTerminalRuntimeKind) -> String {
        switch runtime {
        case .ishExperimental:
            "Embedded iSH command timed out."
        case .remoteSSH, .localIOSTools, .remoteMosh:
            IOSSSHError.commandTimedOut.localizedDescription
        }
    }

    private static func cancellationMessage(for runtime: IOSTerminalRuntimeKind) -> String {
        switch runtime {
        case .ishExperimental:
            "Embedded iSH command was cancelled."
        case .remoteSSH, .localIOSTools, .remoteMosh:
            IOSSSHError.commandCancelled.localizedDescription
        }
    }

    private func runLocalTool(
        command: String,
        workingDirectory: String,
        workspaceStore: IOSWorkspaceStore,
        amberShellStdin: String?,
        timeoutSeconds: TimeInterval,
        now: Date,
        jobId: String?,
        onExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)?
    ) async throws -> IOSTerminalJobSnapshot {
        let control = try IOSAmberShellExecutionControl(timeoutSeconds: timeoutSeconds)
        let result = await withTaskCancellationHandler {
            await IOSAmberShellEngine.execute(
                command: command,
                stdin: amberShellStdin,
                workspaceStore: workspaceStore,
                control: control,
                onExecutionEvent: onExecutionEvent
            )
        } onCancel: {
            control.cancel()
        }

        var finalTermination = result.termination
        // A final checkpoint is valid only before any mutation was dispatched.
        // Otherwise it can turn a known commit into a retryable cancellation.
        if result.dispatchOutcome == .notDispatched {
            do {
                try control.checkpoint()
            } catch let termination as IOSAmberShellTermination {
                finalTermination = termination
            }
        }

        let mayHaveApplied = result.dispatchOutcome == .mayHaveApplied
        let status: String
        let terminationError: String?
        switch (mayHaveApplied, finalTermination) {
        case (true, _):
            status = "unknown_after_action"
            terminationError = "AmberShell action may have applied before execution stopped; the outcome is unknown."
        case (false, .cancelled):
            status = IOSTerminalJobStatus.cancelled.rawValue
            terminationError = "AmberShell command was cancelled."
        case (false, .timedOut):
            status = IOSTerminalJobStatus.timedOut.rawValue
            terminationError = "AmberShell command timed out after \(Int(timeoutSeconds)) seconds."
        case (false, nil):
            status = result.exitCode == 0
                ? IOSTerminalJobStatus.completed.rawValue
                : IOSTerminalJobStatus.failed.rawValue
            terminationError = nil
        }
        let stderr = terminationError.map { $0 + "\n" } ?? result.stderr
        let outputTail = result.stdout + stderr
        let completed = status == IOSTerminalJobStatus.completed.rawValue

        return IOSTerminalJobSnapshot(
            id: jobId ?? UUID().uuidString,
            runtime: .localIOSTools,
            status: status,
            exitCode: finalTermination == nil && !mayHaveApplied ? result.exitCode : nil,
            outputTail: outputTail,
            stdoutTail: result.stdout,
            stderrTail: stderr,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated,
            startedAt: now,
            updatedAt: Date(),
            error: completed ? nil : (terminationError ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private func failedSnapshot(
        runtime: IOSTerminalRuntimeKind,
        command: String,
        now: Date,
        message: String,
        id: String? = nil,
        hopFailure: IOSSSHHopFailure? = nil
    ) -> IOSTerminalJobSnapshot {
        IOSTerminalJobSnapshot(
            id: id ?? UUID().uuidString,
            runtime: runtime,
            status: IOSTerminalJobStatus.failed.rawValue,
            exitCode: nil,
            outputTail: "\(message)\nCommand: \(command)",
            stdoutTail: "",
            startedAt: now,
            updatedAt: Date(),
            error: message,
            hopFailure: hopFailure
        )
    }
}

// MARK: - Embedded iSH job execution

extension IOSTerminalRuntime {
    private func startEmbeddedIshJob(
        command: String,
        workingDirectory: String?,
        now: Date,
        timeoutSeconds: TimeInterval,
        jobId: String?
    ) -> IOSTerminalJobSnapshot {
        let validatedCommand: String
        switch IOSEmbeddedIshCommandPolicy.validate(command) {
        case .success(let command):
            validatedCommand = command
        case .failure(let message):
            return failedSnapshot(
                runtime: .ishExperimental,
                command: command,
                now: now,
                message: message,
                id: jobId
            )
        }
        let normalizedWorkingDirectory: String
        do {
            normalizedWorkingDirectory = try IOSPOSIXWorkingDirectory.normalized(
                workingDirectory,
                default: IOSPOSIXWorkingDirectory.embeddedDefault
            ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
        } catch {
            return failedSnapshot(
                runtime: .ishExperimental,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }

        let job = IOSTerminalJobState(
            id: jobId ?? UUID().uuidString,
            runtime: .ishExperimental,
            startedAt: now,
            status: .running
        )
        jobs[job.id] = job

        let jobId = job.id
        let embeddedIshBackend = embeddedIshBackend
        job.task = Task {
            let result = await embeddedIshBackend.runJob(
                command: validatedCommand,
                workingDirectory: normalizedWorkingDirectory,
                timeoutSeconds: timeoutSeconds,
                onOutput: { chunk in
                    Task { @MainActor in
                        self.appendOutput(chunk, to: jobId)
                    }
                }
            )
            guard !Task.isCancelled else {
                updateJob(
                    id: jobId,
                    status: .cancelled,
                    exitCode: nil,
                    output: nil,
                    error: Self.cancellationMessage(for: .ishExperimental)
                )
                return
            }
            let output = Self.embeddedIshOutput(stdout: result.stdout, stderr: result.stderr)
            let status: IOSTerminalJobStatus
            if result.timedOut {
                status = .timedOut
            } else if result.exitCode == 0, result.error == nil {
                status = .completed
            } else {
                status = .failed
            }
            updateJob(
                id: jobId,
                status: status,
                exitCode: result.exitCode,
                output: output,
                error: result.error ?? (status == .failed ? "Embedded iSH command exited with \(result.exitCode ?? -1)." : nil),
                stdout: result.stdout,
                stderr: result.stderr,
                stdoutTruncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated
            )
        }
        return job.snapshot
    }

    private static func embeddedIshOutput(stdout: String, stderr: String) -> String {
        var parts: [String] = []
        if !stdout.isEmpty {
            parts.append(stdout)
        }
        if !stderr.isEmpty {
            parts.append("[stderr]\n\(stderr)")
        }
        return parts.joined(separator: stdout.hasSuffix("\n") ? "" : "\n")
    }
}

