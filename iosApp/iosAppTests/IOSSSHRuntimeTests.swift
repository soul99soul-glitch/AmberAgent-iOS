import XCTest
@testable import iosApp

final class IOSSSHProfileTests: XCTestCase {
    func testProfileValidationTrimsRequiredFields() throws {
        let profile = IOSSSHProfile(
            name: "  dev box  ",
            host: "  example.com  ",
            port: 22,
            username: "  amber  ",
            knownHostSHA256: "  SHA256:test  "
        )

        let validated = try profile.validated()

        XCTAssertEqual(validated.name, "dev box")
        XCTAssertEqual(validated.host, "example.com")
        XCTAssertEqual(validated.username, "amber")
        XCTAssertEqual(validated.knownHostSHA256, "SHA256:test")
    }

    func testProfileValidationRejectsMissingRequiredFields() {
        XCTAssertThrowsError(try IOSSSHProfile(host: "", username: "amber").validated())
        XCTAssertThrowsError(try IOSSSHProfile(host: "example.com", port: 0, username: "amber").validated())
        XCTAssertThrowsError(try IOSSSHProfile(host: "example.com", username: "").validated())
    }

    func testProbePolicyNeverOffersRealPassword() {
        XCTAssertTrue(IOSSSHProbePolicy.abortsAfterHostKey)
        XCTAssertEqual(IOSSSHProbePolicy.passwordOffer(realPassword: "secret"), IOSSSHProbePolicy.passwordPlaceholder)
        XCTAssertNotEqual(IOSSSHProbePolicy.passwordOffer(realPassword: "secret"), "secret")
    }

    func testKnownHostTrustIsBoundToHostAndPort() throws {
        let trusted = IOSSSHProfile(
            host: "example.com",
            port: 22,
            username: "amber",
            knownHostSHA256: "SHA256:test",
            knownHostHost: "example.com",
            knownHostPort: 22
        )

        let validated = try trusted.validated()

        XCTAssertEqual(validated.knownHostSHA256, "SHA256:test")
        XCTAssertEqual(validated.knownHostHost, "example.com")
        XCTAssertEqual(validated.knownHostPort, 22)
    }

    func testKnownHostTrustIsClearedWhenEndpointChanges() throws {
        let changedHost = IOSSSHProfile(
            host: "new.example.com",
            port: 22,
            username: "amber",
            knownHostSHA256: "SHA256:test",
            knownHostHost: "example.com",
            knownHostPort: 22
        )
        let changedPort = IOSSSHProfile(
            host: "example.com",
            port: 2222,
            username: "amber",
            knownHostSHA256: "SHA256:test",
            knownHostHost: "example.com",
            knownHostPort: 22
        )

        XCTAssertNil(try changedHost.validated().knownHostSHA256)
        XCTAssertNil(try changedPort.validated().knownHostSHA256)
    }
}

@MainActor
final class IOSTerminalSSHRuntimeTests: XCTestCase {
    func testPOSIXWorkingDirectoryIsCanonicalAndShellQuoted() throws {
        XCTAssertEqual(try IOSPOSIXWorkingDirectory.normalized("//srv///amber"), "/srv/amber")
        XCTAssertEqual(IOSPOSIXWorkingDirectory.shellQuote("/srv/O'Brien"), "'/srv/O'\"'\"'Brien'")
        XCTAssertThrowsError(try IOSPOSIXWorkingDirectory.normalized("srv/amber"))
        XCTAssertThrowsError(try IOSPOSIXWorkingDirectory.normalized("/srv/../etc"))
    }

    func testRemoteSSHExecutesInsideRequestedWorkingDirectory() async {
        let backend = MockSSHBackend(result: IOSSSHCommandResult(output: "/srv/amber\n", exitCode: 0))
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let started = await runtime.startJob(
            command: "pwd",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            workingDirectory: "/srv/amber",
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )
        _ = await runtime.waitJob(id: started.id, timeoutSeconds: 2)

        XCTAssertEqual(backend.lastCommand, "cd '/srv/amber' && pwd")
    }

    func testRemoteSSHJobCompletesWithMockBackend() async {
        let backend = MockSSHBackend(result: IOSSSHCommandResult(output: "amber-terminal-smoke\n", exitCode: 0))
        let runtime = IOSTerminalRuntime(sshBackend: backend)
        let profile = trustedProfile()

        let started = await runtime.startJob(
            command: "echo amber-terminal-smoke",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: profile,
            sshPassword: "secret"
        )
        let finished = await runtime.waitJob(id: started.id, timeoutSeconds: 2)

        XCTAssertEqual(started.status, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(finished?.status, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(finished?.exitCode, 0)
        XCTAssertEqual(finished?.outputTail, "amber-terminal-smoke\n")
        XCTAssertEqual(finished?.stdoutTail, "amber-terminal-smoke\n")
        XCTAssertEqual(finished?.stderrTail, "")
    }

    func testRemoteSSHJobKeepsStdoutAndStderrSeparate() async {
        let backend = MockSSHBackend(result: IOSSSHCommandResult(
            stdout: "normal output\n",
            stderr: "warning output\n",
            exitCode: 7
        ))
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let started = await runtime.startJob(
            command: "failing-command",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )
        let finished = await runtime.waitJob(id: started.id, timeoutSeconds: 2)

        XCTAssertEqual(finished?.status, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertEqual(finished?.exitCode, 7)
        XCTAssertEqual(finished?.stdoutTail, "normal output\n")
        XCTAssertEqual(finished?.stderrTail, "warning output\n")
        XCTAssertTrue(finished?.outputTail.contains("[stderr]") == true)
    }

    func testRemoteSSHJobStreamsStdoutAndStderrWhileRunning() async {
        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend(
            result: IOSSSHCommandResult(stdout: "live out\n", stderr: "live err\n", exitCode: 0),
            delayNanoseconds: 5_000_000_000,
            streamsBeforeDelay: true
        ))

        let started = await runtime.startJob(
            command: "stream-output",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        let running = runtime.readJob(id: started.id)

        XCTAssertEqual(running?.status, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(running?.stdoutTail, "live out\n")
        XCTAssertEqual(running?.stderrTail, "live err\n")
        XCTAssertTrue(running?.outputTail.contains("[stderr]\nlive err") == true)
        _ = runtime.stopJob(id: started.id)
    }

    func testTerminalExecuteRunsThroughApprovalAwareLocalExecutor() async throws {
        let profile = trustedProfile()
        let settingsDefaults = isolatedDefaults()
        let settings = SettingsStore(userDefaults: settingsDefaults, storageKey: "terminal-settings")
        try settings.upsertSSHProfile(profile, password: "secret")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }

        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend(result: IOSSSHCommandResult(
            stdout: "hello\n",
            stderr: "notice\n",
            exitCode: 0
        )))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            settingsStore: settings,
            terminalRuntime: runtime
        )
        let request = executor.executionRequest(
            toolName: "terminal_execute",
            operation: #"{"command":"printf hello","purpose":"verify remote"}"#,
            isUserInitiated: true
        )

        let output = await executor.execute(request)
        guard case .terminalResult(let text) = output else {
            return XCTFail("Expected structured terminal result, got \(output)")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(object["stdout"] as? String, "hello\n")
        XCTAssertEqual(object["stderr"] as? String, "notice\n")
        XCTAssertEqual(object["exit_code"] as? Int, 0)
    }

    func testTerminalExecuteApprovalPreviewShowsResolvedEndpointWithoutPassword() throws {
        let profile = trustedProfile()
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "terminal-preview-settings")
        try settings.upsertSSHProfile(profile, password: "secret-not-for-preview")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }

        let preview = try XCTUnwrap(IOSRemoteTerminalExecuteExecutor.approvalPreview(
            input: #"{"command":"uname -a","cwd":"/srv/amber"}"#,
            settingsStore: settings
        ))

        XCTAssertTrue(preview.filename.contains(profile.displayName))
        XCTAssertTrue(preview.filename.contains("\(profile.username)@\(profile.host):\(profile.port)"))
        XCTAssertTrue(preview.filename.contains("/srv/amber"))
        XCTAssertFalse(preview.filename.contains("secret-not-for-preview"))
    }

    func testRemoteTerminalApprovalPreviewsRequireResolvedProfile() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(userDefaults: defaults, storageKey: "missing-terminal-profile")
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "missing-terminal-jobs")

        XCTAssertNil(IOSRemoteTerminalExecuteExecutor.approvalPreview(
            input: #"{"command":"uname -a"}"#,
            settingsStore: settings
        ))
        XCTAssertNil(IOSAgentTerminalJobExecutor.approvalPreview(
            toolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            input: #"{"command":"sleep 10"}"#,
            settingsStore: settings,
            taskStore: taskStore
        ))
    }

    func testTerminalExecuteRejectsNonStringWorkingDirectoryBeforeBackend() async throws {
        let backend = MockSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let text = await IOSRemoteTerminalExecuteExecutor.execute(
            input: #"{"command":"pwd","cwd":42}"#,
            profile: trustedProfile(),
            password: "secret",
            runtime: runtime
        )
        let object = try jsonObject(text)

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue((object["error"] as? String)?.contains("cwd must be a string") == true)
        XCTAssertEqual(backend.executeCallCount, 0)
    }

    func testTerminalExecuteRequiresApprovalAndReturnsNonZeroExit() async throws {
        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend(result: IOSSSHCommandResult(
            stdout: "",
            stderr: "command failed\n",
            exitCode: 9
        )))
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults())
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            terminalRuntime: runtime
        )
        let pending = await executor.execute(executor.executionRequest(
            toolName: "terminal_execute",
            operation: #"{"command":"false"}"#,
            isUserInitiated: false
        ))
        guard case .needsUserAction(let reason) = pending else {
            return XCTFail("Expected foreground approval requirement, got \(pending)")
        }
        XCTAssertTrue(reason.contains("explicit foreground approval"))

        let text = await IOSRemoteTerminalExecuteExecutor.execute(
            input: #"{"command":"false"}"#,
            profile: trustedProfile(),
            password: "secret",
            runtime: runtime
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertEqual(object["stderr"] as? String, "command failed\n")
        XCTAssertEqual(object["exit_code"] as? Int, 9)
    }

    func testRemoteSSHRequiresTrustedHostBeforeStart() async {
        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend())
        var profile = trustedProfile()
        profile.knownHostSHA256 = nil

        let snapshot = await runtime.startJob(
            command: "echo amber-terminal-smoke",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: profile,
            sshPassword: "secret"
        )

        XCTAssertEqual(snapshot.status, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertTrue(snapshot.outputTail.contains("Trust Host"))
    }

    func testRemoteSSHRejectsTrustWhenEndpointChanged() async {
        let backend = MockSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)
        var profile = trustedProfile()
        profile.host = "changed.example.com"

        let snapshot = await runtime.startJob(
            command: "echo amber-terminal-smoke",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: profile,
            sshPassword: "secret"
        )

        XCTAssertEqual(snapshot.status, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertTrue(snapshot.outputTail.contains("Trust Host"))
        XCTAssertEqual(backend.executeCallCount, 0)
    }

    func testOutputTailIsLimitedToLast128KB() async {
        let oversized = String(repeating: "a", count: 140 * 1024)
        let backend = MockSSHBackend(result: IOSSSHCommandResult(output: oversized, exitCode: 0))
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let started = await runtime.startJob(
            command: "big-output",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )
        let finished = await runtime.waitJob(id: started.id, timeoutSeconds: 2)

        XCTAssertEqual(finished?.outputTail.utf8.count, 128 * 1024)
    }

    func testStopJobCancelsRunningTask() async {
        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend(delayNanoseconds: 5_000_000_000))
        let started = await runtime.startJob(
            command: "sleep 5",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )

        let stopped = runtime.stopJob(id: started.id)

        XCTAssertEqual(stopped?.status, IOSTerminalJobStatus.cancelled.rawValue)
    }

    func testLateBackendCompletionDoesNotOverwriteCancelledJob() async {
        let runtime = IOSTerminalRuntime(
            sshBackend: MockSSHBackend(
                result: IOSSSHCommandResult(output: "late success", exitCode: 0),
                delayNanoseconds: 50_000_000,
                ignoresCancellation: true
            )
        )
        let started = await runtime.startJob(
            command: "sleep",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )

        _ = runtime.stopJob(id: started.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let final = runtime.readJob(id: started.id)

        XCTAssertEqual(final?.status, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertFalse(final?.outputTail.contains("late success") == true)
    }

    func testWaitJobTimeoutMarksTimedOut() async {
        let runtime = IOSTerminalRuntime(
            sshBackend: MockSSHBackend(delayNanoseconds: 5_000_000_000, ignoresCancellation: true)
        )
        let started = await runtime.startJob(
            command: "sleep",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )

        let timedOut = await runtime.waitJob(id: started.id, timeoutSeconds: 0.1)

        XCTAssertEqual(timedOut?.status, IOSTerminalJobStatus.timedOut.rawValue)
        XCTAssertEqual(runtime.readJob(id: started.id)?.status, IOSTerminalJobStatus.timedOut.rawValue)
    }

    func testWaitJobReturnsEarlyWhenCallerIsCancelled() async {
        let runtime = IOSTerminalRuntime(
            sshBackend: MockSSHBackend(delayNanoseconds: 5_000_000_000, ignoresCancellation: true)
        )
        let started = await runtime.startJob(
            command: "sleep",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )

        let waiter = Task {
            await runtime.waitJob(id: started.id, timeoutSeconds: 30)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        let early = await waiter.value

        XCTAssertEqual(early?.status, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(runtime.readJob(id: started.id)?.status, IOSTerminalJobStatus.running.rawValue)
        _ = runtime.stopJob(id: started.id)
    }

    func testRemoteCommandPolicyRejectsDangerousCommands() {
        switch IOSRemoteCommandPolicy.validate("echo amber") {
        case .success(let command):
            XCTAssertEqual(command, "echo amber")
        case .failure(let message):
            XCTFail("Expected safe command, got \(message)")
        }

        switch IOSRemoteCommandPolicy.validate("rm -rf /") {
        case .success:
            XCTFail("Expected dangerous command to be blocked")
        case .failure(let message):
            XCTAssertTrue(message.contains("Blocked"))
        }
    }

    func testRemoteSSHRuntimeDoesNotStartBlockedCommand() async {
        let backend = MockSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let snapshot = await runtime.startJob(
            command: "rm -rf /",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: trustedProfile(),
            sshPassword: "secret"
        )

        XCTAssertEqual(snapshot.status, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertTrue(snapshot.error?.contains("Blocked") == true)
        XCTAssertEqual(backend.executeCallCount, 0)
    }

    func testAdvancedTaskStorePersistsAndRedactsRemoteTaskState() {
        let defaults = isolatedDefaults()
        let store = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let task = store.startTask(
            kind: .remoteCommand,
            title: "Remote task",
            objective: "Run command",
            connectionSummary: "dev.example.com",
            commandPreview: "echo token=secret",
            sourceToolName: "remote_command_run"
        )
        store.appendLog(id: task.id, chunk: "Authorization: Bearer abcdef123456")
        _ = store.updateTask(
            id: task.id,
            status: .completed,
            resultSummary: "password=secret finished",
            retryable: false
        )

        let reloaded = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let restored = reloaded.recent(kind: .remoteCommand, limit: 1).first

        XCTAssertEqual(restored?.status, .completed)
        XCTAssertFalse(restored?.commandPreview.contains("secret") == true)
        XCTAssertFalse(restored?.logTail.contains("abcdef123456") == true)
        XCTAssertFalse(restored?.resultSummary.contains("secret") == true)
        XCTAssertFalse(restored?.canRetry == true)
    }

    func testRemoteTerminalJobLifecycleKeepsObserverWaitNonDestructiveAndStopIdempotent() async throws {
        let profile = trustedProfile()
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "job-settings")
        try settings.upsertSSHProfile(profile, password: "secret")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "job-tasks")
        let runtime = IOSTerminalRuntime(
            sshBackend: MockSSHBackend(delayNanoseconds: 5_000_000_000, ignoresCancellation: true)
        )

        let startText = await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_start",
            input: #"{"command":"sleep 5","cwd":"/srv/amber","purpose":"lifecycle"}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        )
        let start = try jsonObject(startText)
        let jobId = try XCTUnwrap(start["job_id"] as? String)
        XCTAssertEqual(start["status"] as? String, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(taskStore.task(id: jobId)?.status, .running)
        XCTAssertEqual(taskStore.task(id: jobId)?.metadata["cwd"], "/srv/amber")
        XCTAssertEqual(start["cwd"] as? String, "/srv/amber")
        XCTAssertFalse(taskStore.task(id: jobId)?.commandPreview.contains("secret") == true)
        let persistedAtBeforeWait = taskStore.task(id: jobId)?.updatedAt

        let waitText = await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_wait",
            input: #"{"job_id":"\#(jobId)","wait_timeout_seconds":1}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        )
        let waited = try jsonObject(waitText)
        XCTAssertEqual(waited["wait_timed_out"] as? Bool, true)
        XCTAssertEqual(waited["status"] as? String, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(runtime.readJob(id: jobId)?.status, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(
            taskStore.task(id: jobId)?.updatedAt,
            persistedAtBeforeWait,
            "observer wait without runtime changes must not rewrite persisted task state"
        )

        let stopInput = #"{"job_id":"\#(jobId)"}"#
        let stopped = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_stop",
            input: stopInput,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(stopped["status"] as? String, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertEqual(stopped["already_terminal"] as? Bool, false)
        XCTAssertEqual(taskStore.task(id: jobId)?.status, .cancelled)

        let repeated = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_stop",
            input: stopInput,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(repeated["status"] as? String, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertEqual(repeated["already_terminal"] as? Bool, true)
    }

    func testTerminalJobStartRejectsNonStringWorkingDirectoryBeforeCreatingTask() async throws {
        let profile = trustedProfile()
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "job-cwd-type-settings")
        try settings.upsertSSHProfile(profile, password: "secret")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "job-cwd-type-tasks")
        let backend = MockSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let text = await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_start",
            input: #"{"command":"pwd","cwd":["/srv/amber"]}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        )
        let object = try jsonObject(text)

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error_code"] as? String, "invalid_arguments")
        XCTAssertTrue((object["error"] as? String)?.contains("cwd must be a string") == true)
        XCTAssertEqual(backend.executeCallCount, 0)
        XCTAssertTrue(taskStore.recent(kind: .remoteCommand, limit: 1).isEmpty)
    }

    func testRemoteTerminalJobCompletionPersistsSeparatedOutputAndUnknownHandleFails() async throws {
        let profile = trustedProfile()
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "job-complete-settings")
        try settings.upsertSSHProfile(profile, password: "secret")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "job-complete-tasks")
        let runtime = IOSTerminalRuntime(sshBackend: MockSSHBackend(
            result: IOSSSHCommandResult(stdout: "done\n", stderr: "notice\n", exitCode: 0),
            delayNanoseconds: 50_000_000
        ))

        let started = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_start",
            input: #"{"command":"printf done"}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        let jobId = try XCTUnwrap(started["job_id"] as? String)
        let finished = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_wait",
            input: #"{"job_id":"\#(jobId)","wait_timeout_seconds":2}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))

        XCTAssertEqual(finished["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(finished["command_ok"] as? Bool, true)
        XCTAssertEqual(finished["stdout"] as? String, "done\n")
        XCTAssertEqual(finished["stderr"] as? String, "notice\n")
        XCTAssertEqual(taskStore.task(id: jobId)?.status, .completed)

        let missing = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: "terminal_job_read",
            input: #"{"job_id":"missing"}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["error_code"] as? String, "job_not_found")
    }

    func testRemoteTerminalJobStartupSweepMarksOnlyRunningJobsInterrupted() {
        let store = IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "job-recovery")
        let running = store.startTask(
            id: "running-job",
            kind: .remoteCommand,
            title: "Running",
            objective: "sleep",
            sourceToolName: "terminal_job_start",
            metadata: ["terminal_job": "true"]
        )
        let completed = store.startTask(
            id: "completed-job",
            kind: .remoteCommand,
            title: "Completed",
            objective: "true",
            sourceToolName: "terminal_job_start",
            metadata: ["terminal_job": "true"]
        )
        store.updateTask(id: completed.id, status: .completed)

        XCTAssertEqual(store.markInterruptedRemoteCommandTasks(), [running.id])
        XCTAssertEqual(store.task(id: running.id)?.status, .interrupted)
        XCTAssertEqual(store.task(id: running.id)?.metadata["outcome"], "unknown")
        XCTAssertEqual(store.task(id: completed.id)?.status, .completed)
        XCTAssertTrue(store.markInterruptedRemoteCommandTasks().isEmpty)
    }

    func testApprovedRemoteTargetChangeFailsClosedBeforeBackendCall() async throws {
        var profile = trustedProfile()
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "target-settings")
        try settings.upsertSSHProfile(profile, password: "secret")
        settings.sshDefaultProfileId = profile.id
        defer { settings.clearSSHPassword(profileId: profile.id) }
        let preview = try XCTUnwrap(IOSRemoteTerminalExecuteExecutor.approvalPreview(
            input: #"{"command":"uname -a"}"#,
            settingsStore: settings
        ))

        profile.host = "changed.example.com"
        profile.knownHostHost = "changed.example.com"
        try settings.upsertSSHProfile(profile, password: nil)
        let backend = MockSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)
        let result = try jsonObject(await IOSRemoteTerminalExecuteExecutor.execute(
            input: #"{"command":"uname -a"}"#,
            settingsStore: settings,
            runtime: runtime,
            expectedProfileId: preview.remoteProfileId,
            expectedTargetDigest: preview.remoteTargetDigest
        ))

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue((result["error"] as? String)?.contains("approved SSH profile") == true)
        XCTAssertEqual(backend.executeCallCount, 0)
    }

    func testTerminalJobEffectClassesSeparateObserversFromMutations() {
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("terminal_job_read", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("terminal_job_wait", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("terminal_job_start", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("terminal_job_stop", input: "{}"), .sideEffect)
        XCTAssertTrue(ChatToolRuntime.execNestedToolExclusions.isSuperset(of: IOSRemoteTerminalToolCatalog.jobToolNames))
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func trustedProfile() -> IOSSSHProfile {
        IOSSSHProfile(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "amber",
            knownHostSHA256: "SHA256:test",
            knownHostHost: "example.com",
            knownHostPort: 22
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class IOSTerminalCapabilityContractTests: XCTestCase {
    func testSwiftCapabilityViewUsesCurrentSharedIOSContract() {
        let remoteSSH = IOSTerminalRuntimeCapabilities.capability(for: .remoteSSH)
        XCTAssertFalse(remoteSSH.supportsPTY)
        XCTAssertTrue(remoteSSH.supportsLongRunningJobs)

        let localTools = IOSTerminalRuntimeCapabilities.capability(for: .localIOSTools)
        XCTAssertFalse(localTools.supportsFileSync)

        let remoteMosh = IOSTerminalRuntimeCapabilities.capability(for: .remoteMosh)
        XCTAssertFalse(remoteMosh.supportsPTY)
        XCTAssertFalse(remoteMosh.supportsPackageInstall)
        XCTAssertFalse(remoteMosh.supportsLongRunningJobs)
        XCTAssertFalse(remoteMosh.supportsInteractiveLogin)

        let embeddedIsh = IOSTerminalRuntimeCapabilities.capability(for: .ishExperimental)
        XCTAssertTrue(embeddedIsh.supportsPTY)
        XCTAssertTrue(embeddedIsh.supportsPackageInstall)
        XCTAssertTrue(embeddedIsh.supportsLongRunningJobs)
        XCTAssertTrue(embeddedIsh.supportsInteractiveLogin)
        XCTAssertFalse(embeddedIsh.supportsFileSync)
    }

    func testStableBuildDoesNotSelectUnlinkedRuntimes() {
        XCTAssertFalse(IOSTerminalBuildPolicy.experimentalRuntimesLinked)
        XCTAssertEqual(IOSTerminalBuildPolicy.selectableRuntimes, [.remoteSSH, .localIOSTools])
        XCTAssertEqual(IOSTerminalBuildPolicy.normalizedDefaultRuntime(.remoteMosh), .remoteSSH)
        XCTAssertEqual(IOSTerminalBuildPolicy.normalizedDefaultRuntime(.ishExperimental), .remoteSSH)
    }
}

private final class MockSSHBackend: IOSSSHRuntimeBackendProtocol, @unchecked Sendable {
    var probeResult: IOSSSHConnectionProbeResult
    var result: IOSSSHCommandResult
    var delayNanoseconds: UInt64
    var ignoresCancellation: Bool
    var streamsBeforeDelay: Bool
    var executeCallCount = 0
    var lastCommand: String?

    init(
        probeResult: IOSSSHConnectionProbeResult = IOSSSHConnectionProbeResult(
            fingerprint: "SHA256:test",
            trustState: .trusted
        ),
        result: IOSSSHCommandResult = IOSSSHCommandResult(output: "", exitCode: 0),
        delayNanoseconds: UInt64 = 0,
        ignoresCancellation: Bool = false,
        streamsBeforeDelay: Bool = false
    ) {
        self.probeResult = probeResult
        self.result = result
        self.delayNanoseconds = delayNanoseconds
        self.ignoresCancellation = ignoresCancellation
        self.streamsBeforeDelay = streamsBeforeDelay
    }

    func testConnection(profile: IOSSSHProfile, password: String) async throws -> IOSSSHConnectionProbeResult {
        probeResult
    }

    func execute(
        command: String,
        profile: IOSSSHProfile,
        password: String,
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult {
        executeCallCount += 1
        lastCommand = command
        if streamsBeforeDelay {
            emit(result, output: output)
        }
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch where ignoresCancellation {
                // Continue to simulate a backend callback that arrives after stop/timeout.
            }
        }
        if !streamsBeforeDelay {
            emit(result, output: output)
        }
        return result
    }

    private func emit(
        _ result: IOSSSHCommandResult,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) {
        if !result.stdout.isEmpty {
            output(IOSSSHOutputChunk(text: result.stdout, isStderr: false))
        }
        if !result.stderr.isEmpty {
            output(IOSSSHOutputChunk(text: result.stderr, isStderr: true))
        }
    }
}
