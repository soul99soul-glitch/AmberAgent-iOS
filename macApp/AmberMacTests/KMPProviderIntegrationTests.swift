import Foundation
import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

@MainActor
final class KMPProviderIntegrationTests: XCTestCase {
    private let fixtureKey = "amber-mac-integration-only"

    func testEmptyInputIsRejectedBeforeEnteringKotlinAccumulator() throws {
        let configuration = DesktopProviderConfiguration(name: "Unused", kind: .openAI,
            baseURL: "https://example.com/v1", modelID: "unused")
        XCTAssertThrowsError(try DesktopKMPProvider().start(configuration: configuration, apiKey: "unused",
            messages: [], responseID: UUID()))
    }

    private func configuration(kind: DesktopProviderKind, model: String = "mock-success") throws -> DesktopProviderConfiguration {
        guard let base = ProcessInfo.processInfo.environment["AMBER_MAC_PROVIDER_TEST_URL"],
              base.hasPrefix("http://127.0.0.1:"), !base.contains("$(") else {
            throw XCTSkip("Run macApp/scripts/test-provider.sh to start the local provider fixture.")
        }
        return DesktopProviderConfiguration(name: "Local protocol fixture", kind: kind,
            baseURL: base + "/v1", modelID: model)
    }

    func testOpenAIStreamsOrderedSnapshotsThroughRealKMP() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .openAI), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run)
        let snapshots = snapshots(events)
        XCTAssertEqual(snapshots.last?.text, "你好，Amber")
        XCTAssertEqual(snapshots.last?.reasoning, "先确认顺序。")
        assertOrderedPrefixes(snapshots.map(\.text))
        XCTAssertTrue(events.contains { if case .complete = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
    }

    func testClaudeStreamsOrderedSnapshotsThroughRealKMP() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .claude), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run)
        let values = snapshots(events)
        XCTAssertEqual(values.last?.text, "你好，Amber")
        assertOrderedPrefixes(values.map(\.text))
        XCTAssertTrue(events.contains { if case .complete = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
    }

    func testHTTPFailureDoesNotExposeEchoedCredential() async throws {
        let provider = DesktopKMPProvider()
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-error"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: UUID())
        let events = try await collect(run)
        let failures = events.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures.joined().contains(fixtureKey))
        XCTAssertFalse(failures.joined().contains("Authorization"))
        XCTAssertFalse(events.contains { if case .complete = $0 { true } else { false } })
    }

    func testCancellationPreservesAcceptedPartialAndRejectsLateChunks() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-cancel"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run, cancelAfterPartial: true)
        XCTAssertEqual(snapshots(events).last?.text, "partial")
        XCTAssertTrue(events.contains { if case .cancelled = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .complete = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
        let lastSnapshot = try XCTUnwrap(events.lastIndex { if case .snapshot = $0 { true } else { false } })
        let cancelled = try XCTUnwrap(events.firstIndex { if case .cancelled = $0 { true } else { false } })
        XCTAssertLessThan(lastSnapshot, cancelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(run.drain().isEmpty)
    }

    func testStreamErrorPreservesTheAcceptedPartialBeforeFailure() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-stream-error"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run)
        XCTAssertEqual(snapshots(events).last?.text, "partial")
        XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .complete = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
        let lastSnapshot = try XCTUnwrap(events.lastIndex { if case .snapshot = $0 { true } else { false } })
        let failed = try XCTUnwrap(events.firstIndex { if case .failed = $0 { true } else { false } })
        XCTAssertLessThan(lastSnapshot, failed)
    }

    func testBurstSnapshotBaselineIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_MAC_PERFORMANCE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set AMBER_MAC_PERFORMANCE_BENCHMARK=1 to run the provider burst baseline.")
        }
        for count in [1_000, 5_000] {
            let provider = DesktopKMPProvider()
            let responseID = UUID()
            let start = Date()
            let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-burst-\(count)"), apiKey: fixtureKey,
                messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
            let events = try await collect(run, maxWaitMilliseconds: 60_000)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(start) * 1_000)
            let payloads = snapshotPayloads(events)
            XCTAssertTrue(events.contains { if case .complete = $0 { true } else { false } })
            XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
            let latest = try XCTUnwrap(payloads.last)
            let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(latest.utf8)) as? [String: Any])
            let usage = try XCTUnwrap(canonical["usage"] as? [String: Any])
            let text = snapshots(events).last?.text
            XCTAssertEqual(text?.count, count)
            XCTAssertEqual(usage["completionTokens"] as? Int, count)
            XCTAssertEqual(canonical["id"] as? String, responseID.uuidString.lowercased())
            print("PERF provider_burst chunks=\(count) snapshots=\(payloads.count) elapsed_ms=\(elapsedMilliseconds) final_text_chars=\(text?.count ?? -1) usage_completion=\(usage["completionTokens"] ?? "nil")")
        }
    }

    func testAgentProviderSubagentOnlyScopeRejectsHiddenWorkspaceWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amber-agent-scope-" + UUID().uuidString, isDirectory: true)
        let suite = "amber-agent-scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = DesktopMemoryCredentials()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }

        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let tasks = DesktopAgentTasks(directory: root.appendingPathComponent("agent-runs"), defaults: defaults)
        await tasks.waitUntilLoaded()
        let files = DesktopWorkspaceFiles(directory: root.appendingPathComponent("workspaces"))
        let knowledge = DesktopKnowledgeStore(directory: root.appendingPathComponent("knowledge"))
        let mcp = DesktopMCPManager(store: DesktopMCPStore(defaults: defaults, credentials: credentials))
        let text = DesktopKMPProvider()
        let collaborations = DesktopCollaborations(settings: settings, provider: text)
        let search = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        let provider = DesktopAgentProvider(text: text, tasks: tasks, files: files, knowledge: knowledge, mcp: mcp,
            collaborations: collaborations, searchSettings: search)
        let owner = UUID()
        let context = DesktopRunContext(conversationID: owner, toolsEnabled: false, subagentsEnabled: true,
            persistTurns: { _ in true })
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-agent-scope"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "尝试写文件，然后给出最终答复")], responseID: UUID(), context: context)

        let events = try await collect(run)
        let messages = events.flatMap { event -> [DesktopMessage] in
            if case .transcript(let values) = event { return values }
            return []
        }
        XCTAssertEqual(messages.last(where: { $0.role == .assistant })?.text, "scope-safe")
        let record = try XCTUnwrap(tasks.records.first { $0.conversationID == owner })
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        XCTAssertNil(record.approval)
        XCTAssertTrue(record.transactions.allSatisfy { $0.name != "workspace_file_write" || $0.outcome == "failed" })
        let ownerFiles = try await files.list(conversationID: owner)
        XCTAssertTrue(ownerFiles.isEmpty)
    }

    /// Scheduled run end to end: DesktopWorkspace.runScheduled → real DesktopAgentProvider/engine → loopback fixture.
    private func scheduledWorkspace(approval: DesktopUnattendedApproval) throws
        -> (DesktopWorkspace, DesktopWorkspaceFiles, DesktopScheduledTask, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amber-scheduled-e2e-" + UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "amber-scheduled-e2e.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        var config = try XCTUnwrap(settings.selectedProvider)
        config.kind = .openAI
        config.baseURL = try configuration(kind: .openAI).baseURL
        config.modelID = "mock-scheduled-write"
        try settings.saveProvider(config, apiKey: fixtureKey)
        let tasks = DesktopAgentTasks(directory: root.appendingPathComponent("agent-runs"), defaults: defaults)
        // The conversation-level switches say "approve everything"; the task's own policy must win.
        tasks.autoApprove = true
        tasks.autoApproveHighRisk = true
        let files = DesktopWorkspaceFiles(directory: root.appendingPathComponent("workspaces"))
        let knowledge = DesktopKnowledgeStore(directory: root.appendingPathComponent("knowledge"))
        let mcp = DesktopMCPManager(store: DesktopMCPStore(defaults: defaults, credentials: credentials))
        let text = DesktopKMPProvider()
        let collaborations = DesktopCollaborations(settings: settings, provider: text)
        let search = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        let provider = DesktopAgentProvider(text: text, tasks: tasks, files: files, knowledge: knowledge, mcp: mcp,
            collaborations: collaborations, searchSettings: search)
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage(), provider: provider,
            initialConversations: [], files: files, agentTasks: tasks, knowledge: knowledge, mcp: mcp, collaborations: collaborations,
            searchSettings: search)
        var task = DesktopScheduledTask(name: "写摘要", prompt: "写一份摘要文件", schedule: .daily(hour: 9, minute: 0))
        task.approval = approval
        return (workspace, files, task, root)
    }

    func testScheduledRunAutoApprovesAllowListedToolWithItsOwnPolicy() async throws {
        let (workspace, files, task, root) = try scheduledWorkspace(approval: DesktopUnattendedApproval(
            autoApproveOrdinary: true, allowedTools: ["workspace_file_write"]))
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await withTimeout { await workspace.runScheduled(task) }
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        let owner = try XCTUnwrap(record.conversationID)
        let written = try await files.list(conversationID: owner)
        XCTAssertEqual(written.map(\.id), ["summary.txt"])
        XCTAssertEqual(record.autoApprovedTools, ["workspace_file_write"])
        let reply = workspace.conversations.first { $0.id == owner }?.messages.last
        XCTAssertTrue(reply?.text.hasPrefix("scheduled-result:") == true, reply?.text ?? "")
    }

    func testScheduledRunDeniesToolOutsideAllowListDespiteGlobalAutoApprove() async throws {
        let (workspace, files, task, root) = try scheduledWorkspace(approval: DesktopUnattendedApproval(
            autoApproveOrdinary: true, autoApproveHighRisk: true, allowedTools: ["workspace_file_list"]))
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await withTimeout { await workspace.runScheduled(task) }
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        let owner = try XCTUnwrap(record.conversationID)
        let written = try await files.list(conversationID: owner)
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(record.autoApprovedTools.isEmpty)
        let reply = workspace.conversations.first { $0.id == owner }?.messages.last?.text ?? ""
        XCTAssertTrue(reply.contains("不在定时任务允许的工具范围内"), reply)
        XCTAssertNil(workspace.agentTasks.records.first { $0.conversationID == owner }?.approval)
    }

    func testScheduledRunWithoutAutoApproveWaitsForApprovalAndContinuesWhenAllowed() async throws {
        let (workspace, files, task, root) = try scheduledWorkspace(approval: DesktopUnattendedApproval())
        defer { try? FileManager.default.removeItem(at: root) }
        let running = Task { await workspace.runScheduled(task) }
        var waiting: DesktopAgentTask?
        for _ in 0..<400 where waiting == nil {
            waiting = workspace.agentTasks.records.first { $0.status == .waiting }
            if waiting == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let run = try XCTUnwrap(waiting, "the global auto-approve switch must not let the scheduled write through")
        XCTAssertEqual(run.approval?.name, "workspace_file_write")
        workspace.agentTasks.decide(runID: run.id, allow: true)
        let record = try await withTimeout { await running.value }
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        let written = try await files.list(conversationID: try XCTUnwrap(record.conversationID))
        XCTAssertEqual(written.map(\.id), ["summary.txt"])
        XCTAssertTrue(record.autoApprovedTools.isEmpty)
    }

    /// Opt-in live check against the real gateway daemon on this Mac (AMBER_MAC_GATEWAY_LIVE=1): the run shows up in
    /// the daemon's registry as an amber session, waits for approval with the call recorded, then completes.
    func testScheduledRunIsReportedToTheLiveGateway() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_MAC_GATEWAY_LIVE"] == "1" else { throw XCTSkip("Set AMBER_MAC_GATEWAY_LIVE=1 with the gateway enabled.") }
        let paths = GatewayPaths.resolve()
        guard paths.daemonRunning else { throw XCTSkip("Mac Gateway daemon is not running.") }
        let (workspace, _, task, root) = try scheduledWorkspace(approval: DesktopUnattendedApproval())
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { true })
        workspace.gatewayReporter = reporter
        workspace.agentTasks.onUnattendedApproval = { reporter.approval(conversationID: $0, $1) }
        let running = Task { await workspace.runScheduled(task) }
        var waiting: DesktopAgentTask?
        for _ in 0..<400 where waiting == nil {
            waiting = workspace.agentTasks.records.first { $0.status == .waiting }
            if waiting == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let run = try XCTUnwrap(waiting)
        func session() -> SessionRecord? {
            RegistryStore(url: paths.registry).load().sessions.values.first { $0.agent == .amber && $0.title == task.name && $0.isOpen }
        }
        var live: SessionRecord?
        for _ in 0..<100 where live?.waitingToolCallId == nil { live = session(); try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(live?.state, .waiting)
        XCTAssertEqual(live?.waitingTool, "workspace_file_write")
        XCTAssertEqual(live?.waitingToolCallId, run.approval?.id)
        let key = try XCTUnwrap(live?.key)
        workspace.agentTasks.decide(runID: run.id, allow: true)
        let record = try await withTimeout { await running.value }
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        var final: SessionRecord?
        for _ in 0..<100 where final?.state != .completed {
            final = RegistryStore(url: paths.registry).load().sessions[key]
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(final?.state, .completed)
        print("GATEWAY_LIVE session=\(key) final=\(final?.state.rawValue ?? "nil")")
    }

    private func withTimeout<T: Sendable>(seconds: Double = 15, _ body: @escaping @MainActor () async -> T) async throws -> T {
        let work = Task { @MainActor in await body() }
        let watchdog = Task { try await Task.sleep(for: .seconds(seconds)); work.cancel() }
        let value = await work.value
        watchdog.cancel()
        return value
    }

    private func collect(_ run: DesktopGeneration, cancelAfterPartial: Bool = false,
                         maxWaitMilliseconds: Int = 8_000) async throws -> [DesktopProviderEvent] {
        var events: [DesktopProviderEvent] = []
        var finished = false
        let consumer = Task { @MainActor in
            for await _ in run.signals {
                events.append(contentsOf: run.drain())
                if cancelAfterPartial, snapshots(events).contains(where: { $0.text == "partial" }) {
                    run.cancel()
                }
            }
            events.append(contentsOf: run.drain())
            finished = true
        }
        defer { consumer.cancel(); run.cancel() }
        for _ in 0..<(maxWaitMilliseconds / 20) {
            if finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(finished, "The KMP provider did not publish a terminal event within eight seconds.")
        return events
    }

    private func snapshots(_ events: [DesktopProviderEvent]) -> [(text: String, reasoning: String)] {
        events.compactMap { event in
            if case .snapshot(let text, let reasoning, _, _) = event { return (text, reasoning) }
            return nil
        }
    }

    private func snapshotPayloads(_ events: [DesktopProviderEvent]) -> [String] {
        events.compactMap { event in
            if case .snapshot(_, _, let canonicalJSON, _) = event { return canonicalJSON }
            return nil
        }
    }

    private func assertCanonicalSnapshots(_ events: [DesktopProviderEvent], responseID: UUID) throws {
        var count = 0
        for event in events {
            guard case .snapshot(_, _, let payload, _) = event else { continue }
            let json = try XCTUnwrap(payload)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(root["id"] as? String, responseID.uuidString.lowercased())
            XCTAssertNotNil(root["parts"] as? [Any])
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }

    private func assertOrderedPrefixes(_ values: [String], file: StaticString = #filePath, line: UInt = #line) {
        for (before, after) in zip(values, values.dropFirst()) {
            XCTAssertTrue(after.hasPrefix(before), "A snapshot arrived out of order.", file: file, line: line)
        }
    }
}
