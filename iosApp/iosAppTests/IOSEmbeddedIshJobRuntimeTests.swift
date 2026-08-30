import XCTest
@testable import iosApp

/// Job-orchestration contract for embedded iSH runtimes: streaming output,
/// real cancellation, and wait-timeout termination. The GPL kernel is behind
/// the injected `IOSEmbeddedIshJobBackend` seam, so these run in the stable
/// test bundle against a fake backend.
@MainActor
final class IOSEmbeddedIshJobRuntimeTests: XCTestCase {
    func testEmbeddedIshApprovalShowsActualWorkingDirectoryAndRejectsInvalidPath() throws {
        let defaultPreview = try XCTUnwrap(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(input: #"{"command":"pwd"}"#)
        )
        let explicitPreview = try XCTUnwrap(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(
                input: #"{"command":"pwd","cwd":"/workspace/project"}"#
            )
        )

        XCTAssertTrue(defaultPreview.filename.contains("/workspace"))
        XCTAssertTrue(explicitPreview.filename.contains("/workspace/project"))
        XCTAssertNil(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(
                input: #"{"command":"pwd","cwd":"../outside"}"#
            )
        )
        XCTAssertNil(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(
                input: #"{"command":"pwd","cwd":42}"#
            )
        )
        XCTAssertNil(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(
                input: #"{"command":"pwd","background":1}"#
            )
        )

        let longScript = String(repeating: "echo amber\n", count: 240)
        let backgroundInput = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [
            "script": longScript,
            "background": true,
            "timeout_seconds": 600,
        ]), encoding: .utf8))
        let backgroundPreview = try XCTUnwrap(
            IOSEmbeddedIshExecuteExecutor.approvalPreview(input: backgroundInput)
        )
        XCTAssertEqual(backgroundPreview.commandPreview, longScript)
        XCTAssertEqual(backgroundPreview.mode, .embeddedJobStart)
        XCTAssertTrue(backgroundPreview.contextLines.contains { $0.contains("异步 Job") })
        XCTAssertTrue(backgroundPreview.contextLines.contains { $0.contains("600 秒") })
    }

    func testEmbeddedIshDirectExecutionRejectsBlockedCommandBeforeRuntime() async throws {
        let text = await IOSEmbeddedIshExecuteExecutor.execute(
            input: #"{"command":"rm -rf /"}"#
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.failed.rawValue)
        XCTAssertTrue((object["error"] as? String)?.contains("destroy or stop") == true)
        if case .failure = IOSEmbeddedIshCommandPolicy.validate("rm -rf -- /") {
            // Expected: exact guest-root destruction remains blocked.
        } else {
            XCTFail("embedded policy must reject exact guest-root destruction")
        }
        if case .success = IOSEmbeddedIshCommandPolicy.validate("rm -rf /workspace/build && apk add git") {
            // Expected: ordinary workspace writes and package installation are allowed.
        } else {
            XCTFail("embedded policy should allow mutations inside /workspace")
        }
        XCTAssertNotNil(IOSEmbeddedIshCommandPolicy.validate(String(repeating: "echo x\n", count: 300)).successValue)
    }

    func testEmbeddedIshDirectStatusHonorsExplicitPreSpawnCancellation() {
        let result = IOSEmbeddedIshCommandResult(
            exitCode: nil,
            stdout: "",
            stderr: "",
            timedOut: false,
            error: "Embedded iSH command was cancelled.",
            cancelled: true
        )

        XCTAssertEqual(
            IOSEmbeddedIshExecuteExecutor.executionStatus(result: result, taskCancelled: false),
            .cancelled
        )
    }

    func testEmbeddedIshJobDefaultsToIsolatedWorkspace() async {
        let backend = MockEmbeddedIshBackend(result: IOSEmbeddedIshCommandResult(
            exitCode: 0,
            stdout: "/workspace\n",
            stderr: "",
            timedOut: false,
            error: nil
        ))
        let runtime = makeRuntime(embeddedIshBackend: backend)

        let started = await runtime.startJob(
            command: "pwd",
            runtime: .ishExperimental,
            experimentalEnabled: true
        )
        _ = await runtime.waitJob(id: started.id, timeoutSeconds: 2)

        XCTAssertEqual(backend.lastWorkingDirectory, "/workspace")
    }

    func testEmbeddedIshJobStreamsOutputBeforeCompletion() async {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "partial-chunk\nfinal-chunk\n",
                stderr: "",
                timedOut: false,
                error: nil
            ),
            midRunChunks: [
                IOSEmbeddedIshOutputChunk(text: "partial-chunk\n", isStderr: false)
            ],
            chunkDelayNanoseconds: 50_000_000,
            completionDelayNanoseconds: 250_000_000
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)

        let started = await runtime.startJob(
            command: "echo partial-chunk && sleep 1 && echo final-chunk",
            runtime: .ishExperimental,
            experimentalEnabled: true
        )
        XCTAssertEqual(started.status, IOSTerminalJobStatus.running.rawValue)

        let streamed = await eventuallyOutput(
            jobId: started.id,
            contains: "partial-chunk",
            runtime: runtime,
            timeoutSeconds: 2
        )
        XCTAssertTrue(streamed, "job outputTail should expose guest output while the command is still running")

        let finished = await runtime.waitJob(id: started.id, timeoutSeconds: 5)
        XCTAssertEqual(finished?.status, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(finished?.exitCode, 0)
        XCTAssertTrue(finished?.outputTail.contains("final-chunk") == true)
        XCTAssertTrue(finished?.stdoutTail.contains("final-chunk") == true)
    }

    func testAgentBackgroundEmbeddedJobUsesSharedReadWaitControlPlane() async throws {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "partial\ndone\n",
                stderr: "",
                timedOut: false,
                error: nil
            ),
            midRunChunks: [IOSEmbeddedIshOutputChunk(text: "partial\n", isStderr: false)],
            chunkDelayNanoseconds: 20_000_000,
            completionDelayNanoseconds: 120_000_000
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)
        let defaultsName = "IOSEmbeddedIshJobRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "jobs")

        let launch = try jsonObject(await IOSEmbeddedIshExecuteExecutor.execute(
            input: #"{"command":"echo partial; sleep 1; echo done","background":true,"timeout_seconds":30}"#,
            runtime: runtime,
            taskStore: taskStore
        ))
        let jobId = try XCTUnwrap(launch["job_id"] as? String)
        XCTAssertEqual(launch["status"] as? String, IOSTerminalJobStatus.running.rawValue)
        XCTAssertEqual(launch["runtime"] as? String, IOSTerminalRuntimeKind.ishExperimental.rawValue)
        XCTAssertEqual(taskStore.task(id: jobId)?.kind, .embeddedIsh)
        XCTAssertEqual(runtime.readJob(id: jobId)?.id, jobId)

        _ = await eventuallyOutput(jobId: jobId, contains: "partial", runtime: runtime, timeoutSeconds: 1)
        let read = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobReadToolName,
            input: #"{"job_id":"\#(jobId)"}"#,
            settingsStore: nil,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(read["runtime"] as? String, IOSTerminalRuntimeKind.ishExperimental.rawValue)
        XCTAssertTrue((read["stdout"] as? String)?.contains("partial") == true)

        let waited = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
            input: #"{"job_id":"\#(jobId)","wait_timeout_seconds":2}"#,
            settingsStore: nil,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(waited["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(waited["command_ok"] as? Bool, true)
        XCTAssertNil(runtime.readJob(id: jobId))

        let persistedRead = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobReadToolName,
            input: #"{"job_id":"\#(jobId)"}"#,
            settingsStore: nil,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(persistedRead["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(persistedRead["persisted_snapshot"] as? Bool, true)
    }

    func testAgentCanStopEmbeddedJobAndRelaunchSweepIsHonest() async throws {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "late",
                stderr: "",
                timedOut: false,
                error: nil
            ),
            completionDelayNanoseconds: 5_000_000_000
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)
        let defaultsName = "IOSEmbeddedIshJobRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "jobs")

        let launch = try jsonObject(await IOSEmbeddedIshExecuteExecutor.execute(
            input: #"{"command":"sleep 60","background":true}"#,
            runtime: runtime,
            taskStore: taskStore
        ))
        let jobId = try XCTUnwrap(launch["job_id"] as? String)
        let stopInput = #"{"job_id":"\#(jobId)"}"#
        let stopped = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
            input: stopInput,
            settingsStore: nil,
            runtime: runtime,
            taskStore: taskStore
        ))
        let repeated = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
            input: stopInput,
            settingsStore: nil,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(stopped["status"] as? String, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertEqual(repeated["already_terminal"] as? Bool, true)
        XCTAssertNil(runtime.readJob(id: jobId))

        taskStore.startTask(
            id: "interrupted-ish",
            kind: .embeddedIsh,
            title: "running",
            objective: "sleep 60",
            sourceToolName: "ios_ish_execute",
            metadata: ["terminal_job": "true", "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue]
        )
        XCTAssertEqual(taskStore.markInterruptedEmbeddedIshTasks(), ["interrupted-ish"])
        XCTAssertEqual(taskStore.task(id: "interrupted-ish")?.status, .interrupted)
        XCTAssertEqual(taskStore.task(id: "interrupted-ish")?.metadata["outcome"], "unknown")
    }

    func testStopEmbeddedIshJobCancelsAndDropsLateCompletion() async {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "late success",
                stderr: "",
                timedOut: false,
                error: nil
            ),
            completionDelayNanoseconds: 150_000_000,
            ignoresCancellation: true
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)
        let started = await runtime.startJob(
            command: "sleep 60",
            runtime: .ishExperimental,
            experimentalEnabled: true
        )

        let stopped = runtime.stopJob(id: started.id)

        XCTAssertEqual(stopped?.status, IOSTerminalJobStatus.cancelled.rawValue)

        try? await Task.sleep(nanoseconds: 400_000_000)
        let final = runtime.readJob(id: started.id)
        XCTAssertTrue(backend.observedCancellation, "stop must cancel the task driving the guest command")
        XCTAssertEqual(final?.status, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertFalse(final?.outputTail.contains("late success") == true)
    }

    func testEmbeddedIshJobMarksStderrTransitionsInStreamingPreview() async {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "out\n",
                stderr: "boom\n",
                timedOut: false,
                error: nil
            ),
            midRunChunks: [
                IOSEmbeddedIshOutputChunk(text: "out\n", isStderr: false),
                IOSEmbeddedIshOutputChunk(text: "boom\n", isStderr: true)
            ],
            chunkDelayNanoseconds: 30_000_000,
            completionDelayNanoseconds: 150_000_000
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)
        let started = await runtime.startJob(
            command: "echo out && echo boom >&2",
            runtime: .ishExperimental,
            experimentalEnabled: true
        )

        let marked = await eventuallyOutput(
            jobId: started.id,
            contains: "[stderr]\nboom\n",
            runtime: runtime,
            timeoutSeconds: 2
        )
        XCTAssertTrue(marked, "streaming preview should mark the transition into stderr output")

        let finished = await runtime.waitJob(id: started.id, timeoutSeconds: 5)
        XCTAssertEqual(finished?.status, IOSTerminalJobStatus.completed.rawValue)
    }

    func testWaitJobTimeoutTerminatesEmbeddedIshJob() async {
        let backend = MockEmbeddedIshBackend(
            result: IOSEmbeddedIshCommandResult(
                exitCode: 0,
                stdout: "done",
                stderr: "",
                timedOut: false,
                error: nil
            ),
            completionDelayNanoseconds: 5_000_000_000
        )
        let runtime = makeRuntime(embeddedIshBackend: backend)
        let started = await runtime.startJob(
            command: "sleep 60",
            runtime: .ishExperimental,
            experimentalEnabled: true
        )

        let timedOut = await runtime.waitJob(id: started.id, timeoutSeconds: 0.1)

        XCTAssertEqual(timedOut?.status, IOSTerminalJobStatus.timedOut.rawValue)
        XCTAssertEqual(runtime.readJob(id: started.id)?.status, IOSTerminalJobStatus.timedOut.rawValue)
        let observedCancellation = await eventuallyObservedCancellation(backend: backend, timeoutSeconds: 1)
        XCTAssertTrue(observedCancellation, "wait timeout must cancel the task driving the guest command")
    }

    private func makeRuntime(embeddedIshBackend: MockEmbeddedIshBackend) -> IOSTerminalRuntime {
        IOSTerminalRuntime(
            sshBackend: IOSSSHRuntimeBackend(),
            embeddedIshBackend: embeddedIshBackend,
            experimentalRuntimesLinked: true
        )
    }

    private func eventuallyObservedCancellation(
        backend: MockEmbeddedIshBackend,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if backend.observedCancellation { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return backend.observedCancellation
    }

    private func eventuallyOutput(
        jobId: String,
        contains text: String,
        runtime: IOSTerminalRuntime,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if runtime.readJob(id: jobId)?.outputTail.contains(text) == true {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return runtime.readJob(id: jobId)?.outputTail.contains(text) == true
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private extension IOSRemoteCommandPolicyResult {
    var successValue: String? {
        if case .success(let value) = self { return value }
        return nil
    }
}

private final class MockEmbeddedIshBackend: IOSEmbeddedIshJobBackend, @unchecked Sendable {
    private let result: IOSEmbeddedIshCommandResult
    private let midRunChunks: [IOSEmbeddedIshOutputChunk]
    private let chunkDelayNanoseconds: UInt64
    private let completionDelayNanoseconds: UInt64
    private let ignoresCancellation: Bool
    private(set) var runCallCount = 0
    private(set) var observedCancellation = false
    private(set) var lastWorkingDirectory: String?

    init(
        result: IOSEmbeddedIshCommandResult,
        midRunChunks: [IOSEmbeddedIshOutputChunk] = [],
        chunkDelayNanoseconds: UInt64 = 20_000_000,
        completionDelayNanoseconds: UInt64 = 0,
        ignoresCancellation: Bool = false
    ) {
        self.result = result
        self.midRunChunks = midRunChunks
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.completionDelayNanoseconds = completionDelayNanoseconds
        self.ignoresCancellation = ignoresCancellation
    }

    func runJob(
        command: String,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (IOSEmbeddedIshOutputChunk) -> Void
    ) async -> IOSEmbeddedIshCommandResult {
        runCallCount += 1
        lastWorkingDirectory = workingDirectory
        for chunk in midRunChunks {
            await sleepSlice(chunkDelayNanoseconds)
            if noteCancellation(), !ignoresCancellation {
                return cancelledResult()
            }
            onOutput(chunk)
        }
        var remaining = completionDelayNanoseconds
        while remaining > 0 {
            let slice = min(remaining, 20_000_000)
            await sleepSlice(slice)
            remaining -= slice
            if noteCancellation(), !ignoresCancellation {
                return cancelledResult()
            }
        }
        return result
    }

    private func noteCancellation() -> Bool {
        if Task.isCancelled {
            observedCancellation = true
        }
        return Task.isCancelled
    }

    private func sleepSlice(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func cancelledResult() -> IOSEmbeddedIshCommandResult {
        IOSEmbeddedIshCommandResult(
            exitCode: nil,
            stdout: "",
            stderr: "",
            timedOut: false,
            error: "cancelled"
        )
    }
}
