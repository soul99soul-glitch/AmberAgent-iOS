import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

/// Scheduled-run lifecycle as the gateway receives it. No daemon runs here, so every event lands in the spool.
@MainActor final class DesktopGatewayReporterTests: XCTestCase {
    private func make(enabled: Bool = true) throws -> (DesktopGatewayReporter, Spool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-reporter-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { enabled },
            process: ProcessIdentity(pid: 4242, startSec: 1, startUsec: 0))
        return (reporter, Spool(dir: paths.spoolDir))
    }

    private func drained(_ spool: Spool, count: Int) async -> [GatewayEvent] {
        let deadline = Date().addingTimeInterval(3)
        var events: [GatewayEvent] = []
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.dir.path))?.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") } ?? []
            if names.count >= count { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        spool.drain { events.append($0) }
        return events
    }

    func testRunLifecycleBecomesAmberSessionEvents() async throws {
        let (reporter, spool) = try make()
        let conversation = UUID(), run = UUID()
        reporter.runStarted(runID: run, conversationID: conversation, taskName: "每日汇总")
        reporter.approval(conversationID: conversation, DesktopToolApproval(id: "call-1", name: "terminal_exec",
            arguments: "{\n  \"command\": \"ls   -la\"\n}", reason: "执行"))
        reporter.approval(conversationID: conversation, nil)
        reporter.runFinished(conversationID: conversation, succeeded: false)
        let events = await drained(spool, count: 4)

        XCTAssertEqual(events.map(\.kind), [.runStart, .permissionRequest, .toolDone, .runExit])
        XCTAssertTrue(events.allSatisfy { $0.agent == .amber && $0.sessionId == run.uuidString.lowercased() && $0.title == "每日汇总" })
        XCTAssertTrue(events.allSatisfy { $0.process?.pid == 4242 && $0.origin == .headless })
        let ask = events[1]
        XCTAssertEqual(ask.tool, "terminal_exec")
        XCTAssertEqual(ask.toolCallId, "call-1")
        XCTAssertEqual(ask.highRisk, true)
        XCTAssertEqual(ask.detail, "{ \"command\": \"ls -la\" }")
        XCTAssertEqual(events[2].toolCallId, "call-1", "the answer names the call it resolves")
        XCTAssertEqual(events[2].tool, "terminal_exec")
        XCTAssertEqual(events[3].exitCode, 1)
    }

    func testNothingIsSentWhenTheGatewayIsOffOrTheConversationIsNotAScheduledRun() async throws {
        let (off, offSpool) = try make(enabled: false)
        let conversation = UUID()
        off.runStarted(runID: UUID(), conversationID: conversation, taskName: "x")
        off.runFinished(conversationID: conversation, succeeded: true)
        let (on, onSpool) = try make()
        on.approval(conversationID: UUID(), DesktopToolApproval(id: "c", name: "t", arguments: "{}", reason: ""))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(offSpool.isEmpty())
        XCTAssertTrue(onSpool.isEmpty())
    }

    func testRunEndedWhileWaitingStillClosesTheSessionAndGatewayOffMidRunDoesNotStrandIt() async throws {
        final class Flag { var on = true }
        let enabled = Flag()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-reporter-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { enabled.on }, process: nil)
        let conversation = UUID()
        reporter.runStarted(runID: UUID(), conversationID: conversation, taskName: "汇总")
        reporter.approval(conversationID: conversation, DesktopToolApproval(id: "c1", name: "workspace_file_write", arguments: "{}", reason: ""))
        enabled.on = false
        // Approval timeout / cancel / quit: finish() never answers the call, the run just ends.
        reporter.runFinished(conversationID: conversation, succeeded: false)
        let events = await drained(Spool(dir: paths.spoolDir), count: 3)
        XCTAssertEqual(events.map(\.kind), [.runStart, .permissionRequest, .runExit])
        XCTAssertEqual(events.last?.exitCode, 1)
    }

    func testQuietCompletionReachesTheSpooledRunExit() async throws {
        let (reporter, spool) = try make()
        let quiet = UUID(), loud = UUID()
        reporter.runStarted(runID: UUID(), conversationID: quiet, taskName: "汇总")
        reporter.runFinished(conversationID: quiet, succeeded: true, quiet: true)
        reporter.runStarted(runID: UUID(), conversationID: loud, taskName: "汇总")
        reporter.runFinished(conversationID: loud, succeeded: true)
        let exits = await drained(spool, count: 4).filter { $0.kind == .runExit }
        XCTAssertEqual(exits.count, 2)
        XCTAssertEqual(Set(exits.map(\.quiet)), [true, nil])
        XCTAssertTrue(exits.allSatisfy { $0.exitCode == 0 })
    }

    func testExcerptIsCollapsedAndCapped() {
        XCTAssertNil(DesktopGatewayReporter.excerpt("{}"))
        XCTAssertNil(DesktopGatewayReporter.excerpt("  "))
        let long = DesktopGatewayReporter.excerpt(String(repeating: "长", count: 300))
        XCTAssertEqual(long?.count, DesktopGatewayReporter.detailLimit)
        XCTAssertEqual(long?.last, "…")
    }
}
