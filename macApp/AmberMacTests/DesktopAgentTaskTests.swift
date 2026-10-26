import XCTest
@testable import AmberMac

@MainActor final class DesktopAgentTaskTests: XCTestCase {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("amber-agent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }

    func testApprovalPersistsBeforeDecisionAndBelongsToExactRun() async throws {
        let directory = try directory()
        let tasks = DesktopAgentTasks(directory: directory, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let owner = UUID()
        let id = try await tasks.begin(conversationID: owner, title: "写文件", cancel: {})
        try await tasks.requestApproval(runID: id, approval: DesktopToolApproval(id: "call-1", name: "workspace_write", arguments: "{}", reason: "写入文件"))
        let waiting = try await tasks.journal.value(id)
        XCTAssertEqual(waiting.approval?.id, "call-1")
        let decision = Task { await tasks.awaitDecision(runID: id, toolID: "call-1") }
        tasks.decide(runID: id, allow: false)
        let denied = await decision.value
        XCTAssertFalse(denied)
        XCTAssertNil(tasks.decision(runID: id, toolID: "call-2"))
        XCTAssertEqual(tasks.records.first?.conversationID, owner)
        await tasks.finish(id, status: .cancelled)
        let reopened = DesktopAgentTasks(directory: directory)
        await reopened.waitUntilLoaded()
        XCTAssertEqual(reopened.records.first?.status, .cancelled)
        XCTAssertNil(reopened.records.first?.approval)
    }

    func testReopenClosesApprovalThatWasStillWaiting() async throws {
        let directory = try directory()
        let journal = DesktopAgentJournal(directory: directory)
        var value = DesktopAgentTask(id: UUID(), conversationID: UUID(), title: "写文件", status: .waiting, createdAt: Date(), updatedAt: Date())
        value.approval = DesktopToolApproval(id: "call-1", name: "workspace_file_write", arguments: "{}", reason: "写入")
        value.transactions = [DesktopToolTransaction(id: "call-1", name: "workspace_file_write", argsDigest: "d", effect: "sideEffect", state: "waiting_user")]
        try await journal.save(value)
        let reopened = DesktopAgentTasks(directory: directory)
        await reopened.waitUntilLoaded()
        let record = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(record.status, .interrupted)
        XCTAssertNil(record.approval)
        XCTAssertEqual(record.transactions.first?.state, "finished")
        XCTAssertEqual(record.transactions.first?.outcome, "interrupted")
    }

    func testReopenNeverReplaysStartedEffectAndKeepsOtherRunOwners() async throws {
        let directory = try directory()
        let journal = DesktopAgentJournal(directory: directory)
        let owner = UUID(), run = UUID()
        var value = DesktopAgentTask(id: run, conversationID: owner, title: "shell", status: .running, createdAt: Date(), updatedAt: Date())
        value.transactions = [DesktopToolTransaction(id: "effect", name: "terminal_exec", argsDigest: "digest", effect: "sideEffect", state: "started")]
        try await journal.save(value)
        let reopened = DesktopAgentJournal(directory: directory)
        let restored = try await reopened.load()
        XCTAssertEqual(restored.first?.status, .outcomeUnknown)
        XCTAssertEqual(restored.first?.transactions.first?.state, "outcome_unknown")
        XCTAssertEqual(restored.first?.conversationID, owner)
    }

    func testCommandReturnsActualExitOutputAndKillsBackgroundDescendants() async throws {
        let result = try await DesktopCommandRunner.run("printf 'actual output'; exit 7", directory: try directory())
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.output, "actual output")
        XCTAssertFalse(result.cancelled)
        let background = try await DesktopCommandRunner.run("sleep 30 & printf done", directory: try directory(), timeout: .seconds(3))
        XCTAssertEqual(background.output, "done")
        XCTAssertFalse(background.timedOut)
    }

    func testCommandTimeoutCancellationAndLargeOutputAreBounded() async throws {
        let directory = try directory()
        let timeout = try await DesktopCommandRunner.run("printf before; sleep 30", directory: directory, timeout: .milliseconds(100))
        XCTAssertTrue(timeout.timedOut)
        XCTAssertEqual(timeout.output, "before")
        let task = Task { try await DesktopCommandRunner.run("sleep 30", directory: directory) }
        await Task.yield()
        task.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.cancelled)
        let large = try await DesktopCommandRunner.run("/usr/bin/yes x | /usr/bin/head -c 100000", directory: directory)
        XCTAssertEqual(large.output.utf8.count, 65_536)
        XCTAssertTrue(large.truncated)
    }

    func testDeferredCancellationAcceptsFinalCanonicalSnapshotThenCancels() {
        let generation = DesktopGeneration(cancellationCompletesAsynchronously: true)
        generation.installCancellation {}
        generation.yield(.snapshot(text: "first", reasoning: ""))
        generation.cancel()
        generation.yield(.transcript([DesktopMessage(role: .assistant, text: "final accepted partial", canonicalJSON: "canonical")]))
        generation.yield(.complete)
        let events = generation.drain()
        XCTAssertEqual(events.count, 3)
        if case .cancelled? = events.last {} else { XCTFail("Cancellation must win the late complete") }
        generation.yield(.failed("late"))
        XCTAssertTrue(generation.drain().isEmpty)
    }

    func testJournalRejectsReusingStartedCallAndReplaysOnlyMatchingFinishedResult() async throws {
        let journal = DesktopAgentJournal()
        let id = UUID()
        try await journal.save(DesktopAgentTask(id: id, conversationID: UUID(), title: "实际调用", status: .running, createdAt: Date(), updatedAt: Date()))
        let first = try await journal.prepare(id, callID: "call", name: "workspace_file_write", argsDigest: "original", effect: "sideEffect")
        XCTAssertEqual(first, .ready)
        _ = try await journal.change(id) { $0.transactions[0].state = "started" }
        let repeated = try await journal.prepare(id, callID: "call", name: "workspace_file_write", argsDigest: "original", effect: "sideEffect")
        guard case .blocked = repeated else { return XCTFail("A dispatched call must never run twice") }
        _ = try await journal.change(id) { $0.transactions[0].state = "finished"; $0.transactions[0].resultPayload = "known result" }
        let replay = try await journal.prepare(id, callID: "call", name: "workspace_file_write", argsDigest: "original", effect: "sideEffect")
        XCTAssertEqual(replay, .replay("known result"))
        let changed = try await journal.prepare(id, callID: "call", name: "workspace_file_write", argsDigest: "changed", effect: "sideEffect")
        guard case .blocked = changed else { return XCTFail("A call id must be bound to its original arguments") }
    }

    func testCancelledApprovalCannotBeGrantedLaterAndSkillScopeCannotGrantTools() async throws {
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let id = try await tasks.begin(conversationID: UUID(), title: "待审批", cancel: {})
        try await tasks.requestApproval(runID: id, approval: DesktopToolApproval(id: "call", name: "terminal_exec", arguments: "{}", reason: "确认命令"))
        tasks.cancel(id)
        tasks.decide(runID: id, allow: true)
        let decision = await tasks.awaitDecision(runID: id, toolID: "call")
        XCTAssertFalse(decision)
        XCTAssertNil(tasks.decision(runID: id, toolID: "call"))
        var scope = DesktopSkillToolScope()
        scope.apply(["workspace_file_read", "workspace_file_write"])
        scope.apply(["workspace_file_read", "terminal_exec"])
        XCTAssertTrue(scope.permits("workspace_file_read"))
        XCTAssertFalse(scope.permits("terminal_exec"))
        XCTAssertFalse(scope.permits("workspace_file_write"))
        XCTAssertTrue(scope.permits("tool_search"))
        await tasks.finish(id, status: .cancelled)
    }
}

@MainActor final class DesktopAutoApprovalTests: XCTestCase {
    func testGlobalCoversOrdinaryToolsOnlyAndHighRiskCoversEverythingAndPersists() {
        let defaults = UserDefaults(suiteName: "amber.autoapprove.\(UUID().uuidString)")!
        let tasks = DesktopAgentTasks(defaults: defaults)
        XCTAssertFalse(tasks.autoApproves("workspace_file_write"))
        XCTAssertFalse(tasks.autoApproves("terminal_exec"))
        tasks.autoApprove = true
        XCTAssertTrue(tasks.autoApproves("workspace_file_write"))
        XCTAssertTrue(tasks.autoApproves("memory_tool"))
        XCTAssertFalse(tasks.autoApproves("terminal_exec"), "shell stays behind 高风险自动批准")
        XCTAssertFalse(tasks.autoApproves("workspace_artifact_delete"))
        XCTAssertFalse(tasks.autoApproves("mcp_call_tool"))
        tasks.autoApproveHighRisk = true
        XCTAssertTrue(tasks.autoApproves("terminal_exec"))
        let reopened = DesktopAgentTasks(defaults: defaults)
        XCTAssertTrue(reopened.autoApprove)
        XCTAssertTrue(reopened.autoApproveHighRisk)
    }
}
