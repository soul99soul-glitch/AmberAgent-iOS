import XCTest
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport
@testable import AmberMac

/// The Amber end of phone requests. The daemon has already authenticated the phone; these are the app's own rules.
@MainActor final class DesktopGatewayControlTests: XCTestCase {
    private func make() async throws -> (DesktopGatewayControl, DesktopAgentTasks, DesktopGatewayReporter, GatewayPaths, UUID) {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("agc-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.control.\(UUID().uuidString)")!)
        await tasks.waitUntilLoaded()
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { true }, process: nil)
        let control = DesktopGatewayControl(paths: paths, tasks: tasks, reporter: reporter, scheduler: nil)
        let conversation = UUID()
        tasks.unattendedConversations[conversation] = "每日汇总"
        reporter.runStarted(runID: UUID(), conversationID: conversation, taskName: "每日汇总")
        return (control, tasks, reporter, paths, conversation)
    }

    private func sessionKey(_ paths: GatewayPaths) async -> String {
        let deadline = Date().addingTimeInterval(2)
        var key: String?
        while key == nil, deadline.timeIntervalSince(Date()) > 0 {
            Spool(dir: paths.spoolDir).drain { if $0.kind == .runStart { key = "amber:" + $0.sessionId } }
            if key == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return key ?? ""
    }

    private func waitingRun(_ tasks: DesktopAgentTasks, conversation: UUID, tool: String) async throws -> UUID {
        let id = try await tasks.begin(conversationID: conversation, title: "x", cancel: {})
        try await tasks.requestApproval(runID: id, approval: DesktopToolApproval(id: "call-1", name: tool, arguments: "{}", reason: ""))
        return id
    }

    func testPhoneApprovalAnswersTheExactPendingCall() async throws {
        let (control, tasks, _, paths, conversation) = try await make()
        let key = await sessionKey(paths)
        let run = try await waitingRun(tasks, conversation: conversation, tool: "workspace_file_write")
        let decision = Task { await tasks.awaitDecision(runID: run, toolID: "call-1") }

        let stale = await control.handle(.init(action: .decide, sessionKey: key, toolCallId: "call-0", allow: true))
        XCTAssertEqual(stale.status, 409)
        let unknown = await control.handle(.init(action: .decide, sessionKey: "amber:nope", toolCallId: "call-1", allow: true))
        XCTAssertEqual(unknown.status, 409)

        let ok = await control.handle(.init(action: .decide, sessionKey: key, toolCallId: "call-1", allow: true))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(tasks.records.first { $0.id == run }?.status, .running, "written before the phone gets 200")
        let allowed = await decision.value
        XCTAssertTrue(allowed)
        let again = await control.handle(.init(action: .decide, sessionKey: key, toolCallId: "call-1", allow: true))
        XCTAssertEqual(again.status, 409, "one decision per call")
    }

    func testHighRiskIsNeverApprovedFromThePhoneButCanBeDenied() async throws {
        let (control, tasks, _, paths, conversation) = try await make()
        let key = await sessionKey(paths)
        let run = try await waitingRun(tasks, conversation: conversation, tool: "terminal_exec")
        let refused = await control.handle(.init(action: .decide, sessionKey: key, toolCallId: "call-1", allow: true))
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(tasks.records.first { $0.id == run }?.status, .waiting)
        let decision = Task { await tasks.awaitDecision(runID: run, toolID: "call-1") }
        let denied = await control.handle(.init(action: .decide, sessionKey: key, toolCallId: "call-1", allow: false))
        XCTAssertEqual(denied.status, 200)
        let allowed = await decision.value
        XCTAssertFalse(allowed)
    }

    func testRemoteScheduleManagementNeverGrantsAutoApproval() async throws {
        let (_, tasks, reporter, paths, _) = try await make()
        let scheduler = DesktopScheduler(store: DesktopScheduleStore(directory: nil), defaults: UserDefaults(suiteName: "amber.control.s.\(UUID().uuidString)")!,
            runner: { _, slot in DesktopScheduleRunRecord(scheduledFor: slot, startedAt: Date(), finishedAt: Date(), status: .completed) },
            activity: NoActivity(), timerEnabled: false)
        var existing = DesktopScheduledTask(name: "清理", prompt: "x", schedule: .daily(hour: 3, minute: 0))
        existing.approval.autoApproveHighRisk = true
        let seeded = await scheduler.save(task: existing)
        XCTAssertNil(seeded)
        let control = DesktopGatewayControl(paths: paths, tasks: tasks, reporter: reporter, scheduler: scheduler)

        let list = await control.handle(.init(action: .listSchedules))
        XCTAssertEqual(list.schedules?.map(\.name), ["清理"])
        XCTAssertEqual(list.schedules?.first?.autoApprovesHighRisk, true, "shown so the phone can warn")
        XCTAssertEqual(list.schedules?.first?.rule, "每天 03:00")

        let created = await control.handle(.init(action: .createSchedule, draft: .init(name: " 周报 ", prompt: "写周报", rule: .weekly, hour: 17, minute: 30, weekdays: [6])))
        XCTAssertEqual(created.status, 200)
        let task = try XCTUnwrap(scheduler.tasks.first { $0.name == "周报" })
        XCTAssertEqual(task.schedule, .weekly(days: [6], hour: 17, minute: 30))
        XCTAssertEqual(task.approval, DesktopUnattendedApproval(), "remote creation never chooses an approval policy")
        XCTAssertTrue(task.enabled)
        XCTAssertNotNil(task.nextRunAt)

        let incomplete = await control.handle(.init(action: .createSchedule, draft: .init(name: "x", prompt: "y", rule: .daily)))
        XCTAssertEqual(incomplete.status, 400)
        let tooFrequent = await control.handle(.init(action: .createSchedule, draft: .init(name: "x", prompt: "y", rule: .interval, intervalMinutes: 5)))
        XCTAssertEqual(tooFrequent.status, 400)

        let huge = await control.handle(.init(action: .createSchedule, draft: .init(name: "x", prompt: "y", rule: .interval, intervalMinutes: Int.max)))
        XCTAssertEqual(huge.status, 400, "rejected instead of overflowing the date math")
        let past = await control.handle(.init(action: .createSchedule, draft: .init(name: "旧", prompt: "y", rule: .once, at: Date().addingTimeInterval(-60))))
        XCTAssertEqual(past.status, 400)
        let unknownRun = await control.handle(.init(action: .runSchedule, scheduleId: UUID().uuidString))
        XCTAssertEqual(unknownRun.status, 404)

        let off = await control.handle(.init(action: .setScheduleEnabled, scheduleId: task.id.uuidString, enabled: false))
        XCTAssertEqual(off.schedule?.enabled, false)
        XCTAssertEqual(scheduler.tasks.first { $0.id == task.id }?.enabled, false)
        let missing = await control.handle(.init(action: .setScheduleEnabled, scheduleId: UUID().uuidString, enabled: true))
        XCTAssertEqual(missing.status, 404)

        let run = await control.handle(.init(action: .runSchedule, scheduleId: existing.id.uuidString))
        XCTAssertEqual(run.status, 200)
        XCTAssertEqual(run.schedule?.running, true)
        let twice = await control.handle(.init(action: .runSchedule, scheduleId: existing.id.uuidString))
        XCTAssertEqual(twice.status, 409)
        await scheduler.flush()
    }

    private final class NoActivity: DesktopScheduleActivity {
        func begin() {}
        func end() {}
    }

    func testAQuittingSecondListenerDoesNotDeleteTheSocketAndTheFirstRebinds() async throws {
        let (control, _, _, paths, _) = try await make()
        control.start()
        defer { control.stop() }
        let other = UnixSocketServer(path: paths.amberSocket.path, queue: DispatchQueue(label: "other"), respond: { _ in nil })
        try other.start()
        other.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.amberSocket.path), "the other process removed its own socket")
        control.ensureListening()
        let request = try GatewayJSON.encoder().encode(AmberControl.Request(action: .decide, sessionKey: "amber:x", toolCallId: "c", allow: false))
        let socket = paths.amberSocket.path
        let reply = await Task.detached { UnixSocketClient.request(request, to: socket, timeout: 3) }.value
        XCTAssertNotNil(reply, "Amber answers again after rebinding")

        let intruder = UnixSocketServer(path: paths.amberSocket.path, queue: DispatchQueue(label: "intruder"), respond: { _ in nil })
        try intruder.start()
        control.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.amberSocket.path), "stop never removes a socket another server owns")
        intruder.stop()
    }

    func testSocketRoundTripAndGarbage() async throws {
        let (control, _, _, paths, _) = try await make()
        control.start()
        defer { control.stop() }
        let request = try GatewayJSON.encoder().encode(AmberControl.Request(action: .decide, sessionKey: "amber:x", toolCallId: "c", allow: false))
        let socket = paths.amberSocket.path
        let reply = await Task.detached { UnixSocketClient.request(request, to: socket, timeout: 3) }.value
        let decoded = try GatewayJSON.decoder().decode(AmberControl.Response.self, from: try XCTUnwrap(reply))
        XCTAssertEqual(decoded.status, 409)
        let attributes = try FileManager.default.attributesOfItem(atPath: socket)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let garbage = await control.handle(Data("nope".utf8))
        XCTAssertEqual(try GatewayJSON.decoder().decode(AmberControl.Response.self, from: try XCTUnwrap(garbage)).status, 400)
    }

    func testRiskMatrixPluginSideEffectsOldRunIsolationAndAuditRecords() async throws {
        let (control, tasks, reporter, paths, conversation) = try await make()
        let key1 = await sessionKey(paths)
        let run1 = try await waitingRun(tasks, conversation: conversation, tool: "plugin__feishu_bot__send_message")

        // High-risk plugin write tool cannot be approved on the phone (403), but can be denied (200)
        let refusedPlugin = await control.handle(.init(action: .decide, sessionKey: key1, toolCallId: "call-1", allow: true, deviceName: "iPhone"))
        XCTAssertEqual(refusedPlugin.status, 403)
        XCTAssertEqual(tasks.records.first { $0.id == run1 }?.status, .waiting)

        // Simulate Run 1 expiring / finishing before any valid decision arrives, then Run 2 starting in the same conversation
        await tasks.finish(run1, status: .failed, error: "审批等待超时")
        reporter.runFinished(conversationID: conversation, succeeded: false)

        let run2SessionID = UUID()
        reporter.runStarted(runID: run2SessionID, conversationID: conversation, taskName: "每日汇总")
        let key2 = "amber:" + run2SessionID.uuidString.lowercased()
        let run2 = try await waitingRun(tasks, conversation: conversation, tool: "workspace_file_write")

        // Old run's sessionKey (key1) with matching toolCallId ("call-1") must return 409 and never approve Run 2
        let expiredRunAttempt = await control.handle(.init(action: .decide, sessionKey: key1, toolCallId: "call-1", allow: true, deviceName: "iPhone"))
        XCTAssertEqual(expiredRunAttempt.status, 409)
        XCTAssertEqual(tasks.records.first { $0.id == run2 }?.status, .waiting, "old run approval must never affect a newer run")

        // Current run (key2) with ordinary risk tool is approved (200)
        let waitRun2 = Task { await tasks.awaitDecision(runID: run2, toolID: "call-1") }
        let approvedRun2 = await control.handle(.init(action: .decide, sessionKey: key2, toolCallId: "call-1", allow: true, deviceName: "iPhone"))
        XCTAssertEqual(approvedRun2.status, 200)
        let decisionValue = await waitRun2.value
        XCTAssertTrue(decisionValue)

        // Verify audit.jsonl contains run, tool, toolCallId, and decision for both rejected high-risk and approved ordinary risk
        let auditRaw = try String(contentsOf: paths.audit, encoding: .utf8)
        let lines = auditRaw.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
        let highRiskAudit = try XCTUnwrap(lines.first { $0["outcome"] == "rejected_high_risk" })
        XCTAssertEqual(highRiskAudit["run"], run1.uuidString.lowercased())
        XCTAssertEqual(highRiskAudit["tool"], "plugin__feishu_bot__send_message")
        XCTAssertEqual(highRiskAudit["toolCallId"], "call-1")
        XCTAssertEqual(highRiskAudit["decision"], "allow")

        let approvedAudit = try XCTUnwrap(lines.first { $0["outcome"] == "approved" })
        XCTAssertEqual(approvedAudit["run"], run2.uuidString.lowercased())
        XCTAssertEqual(approvedAudit["tool"], "workspace_file_write")
        XCTAssertEqual(approvedAudit["toolCallId"], "call-1")
        XCTAssertEqual(approvedAudit["decision"], "allow")
        XCTAssertEqual(approvedAudit["device"], "iPhone")
    }
}
