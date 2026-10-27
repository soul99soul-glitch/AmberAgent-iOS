import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

/// Board titles and run summaries with a scripted provider. No daemon runs here, so retitle events land in the spool.
@MainActor final class DesktopBoardWriterTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var messages: [[DesktopMessage]] = []
        var fail = false
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            if fail { throw DesktopRuntimeError.message("provider down") }
            let run = DesktopGeneration()
            runs.append(run); self.messages.append(messages)
            return run
        }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage],
            responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            try start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID)
        }
    }

    private func make(model: Bool = true) -> (DesktopBoardWriter, Provider, Spool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-board-writer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let provider = Provider()
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.board-writer.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials())
        let configuration = settings.selectedProvider!
        let writer = DesktopBoardWriter(provider: provider, paths: paths) { model ? (configuration, "key") : nil }
        return (writer, provider, Spool(dir: paths.spoolDir))
    }

    private func session(_ id: String, agent: AgentKind = .claude, opening: String? = "把登录页的报错修好", title: String? = nil,
        started: TimeInterval = 0) -> SessionRecord {
        var registry = Registry()
        let at = Date(timeIntervalSince1970: started)
        _ = registry.ingest(GatewayEvent(agent: agent, kind: .promptSubmit, sessionId: id, cwd: "/Users/mi", timestamp: at, origin: .host),
            config: GatewayConfig(), now: at, presence: { Presence(screenLocked: false, idleSeconds: 0) })
        var rec = registry.sessions[SessionRecord.key(agent, id)]!
        rec.opening = opening
        rec.generatedTitle = title
        return rec
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func drained(_ spool: Spool, count: Int) async -> [GatewayEvent] {
        await waitFor {
            ((try? FileManager.default.contentsOfDirectory(atPath: spool.dir.path))?
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count ?? 0) >= count
        }
        var events: [GatewayEvent] = []
        spool.drain { events.append($0) }
        return events
    }

    func testTitlesAreGeneratedOneAtATimeAndSpooledAsRetitle() async throws {
        let (writer, provider, spool) = make()
        writer.queueTitles([session("b", agent: .codex, started: 2), session("a", started: 1),
            session("titled", title: "已有标题"), session("bare", opening: nil), session("amber", agent: .amber)])
        await waitFor { !provider.runs.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.runs.count, 1, "one generation at a time")
        XCTAssertEqual(provider.messages[0].last?.text, "把登录页的报错修好")
        writer.queueTitles([session("a", started: 1)])
        XCTAssertEqual(provider.runs.count, 1, "a queued session is not queued again")

        provider.runs[0].yield(.snapshot(text: "「修复登录报错」\n多余说明", reasoning: ""))
        provider.runs[0].yield(.complete)
        await waitFor { provider.runs.count == 2 }
        XCTAssertEqual(provider.runs.count, 2, "the next starts after the first ends")
        provider.runs[1].yield(.snapshot(text: "Codex 任务", reasoning: ""))
        provider.runs[1].yield(.complete)
        await waitFor { writer.titling == nil }

        let events = await drained(spool, count: 2)
        XCTAssertEqual(events.map(\.kind), [.retitle, .retitle])
        XCTAssertEqual(events.map(\.sessionId), ["a", "b"], "oldest first")
        XCTAssertEqual(events.map(\.agent), [.claude, .codex])
        XCTAssertEqual(events.map(\.title), ["修复登录报错", "Codex 任务"])
        XCTAssertEqual(provider.runs.count, 2)
    }

    func testFailedTitleIsNotRetriedAndTheQueueMovesOn() async throws {
        let (writer, provider, spool) = make()
        writer.queueTitles([session("a", started: 1), session("b", started: 2)])
        await waitFor { !provider.runs.isEmpty }
        provider.runs[0].yield(.failed("boom"))
        await waitFor { provider.runs.count == 2 }
        provider.runs[1].yield(.snapshot(text: "第二个", reasoning: ""))
        provider.runs[1].yield(.complete)
        await waitFor { writer.titling == nil }
        writer.queueTitles([session("a", started: 1)])
        XCTAssertEqual(provider.runs.count, 2, "a failed session is not tried again")
        let events = await drained(spool, count: 1)
        XCTAssertEqual(events.map(\.sessionId), ["b"])

        provider.fail = true
        writer.queueTitles([session("c")])
        await waitFor { writer.titling == nil }
        provider.fail = false
        writer.queueTitles([session("c")])
        XCTAssertEqual(provider.runs.count, 2)
    }

    func testAQueueStalledByAMissingKeyResumesOnTheNextPoll() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-board-writer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider()
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.board-writer.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials())
        let configuration = settings.selectedProvider!
        final class Key { var present = false }
        let key = Key()
        let writer = DesktopBoardWriter(provider: provider, paths: GatewayPaths(stateDir: dir)) { key.present ? (configuration, "key") : nil }
        writer.queueTitles([session("a")])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(provider.runs.isEmpty, "the model is configured but its key can't be read yet")
        key.present = true
        writer.queueTitles([])
        await waitFor { !provider.runs.isEmpty }
        XCTAssertEqual(provider.runs.count, 1, "the next poll picks the queued session up again")
    }

    func testNoModelMeansNoWork() async throws {
        let (writer, provider, spool) = make(model: false)
        writer.queueTitles([session("a")])
        let summary = await writer.summarize("今天新增 3 个文件")
        XCTAssertNil(summary)
        XCTAssertTrue(provider.runs.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(spool.isEmpty())
    }

    func testSummaryParsing() {
        let plain = DesktopBoardWriter.parseSummary(#"{"summary":"新增 3 个文件","noteworthy":true}"#)
        XCTAssertEqual(plain?.summary, "新增 3 个文件")
        XCTAssertEqual(plain?.noteworthy, true)
        let fenced = DesktopBoardWriter.parseSummary("```json\n{\"summary\": \"没有变化\", \"noteworthy\": false}\n```")
        XCTAssertEqual(fenced?.summary, "没有变化")
        XCTAssertEqual(fenced?.noteworthy, false)
        XCTAssertEqual(DesktopBoardWriter.parseSummary(#"{"summary":"\#(String(repeating: "长", count: 60))","noteworthy":false}"#)?.summary.count, 40)
        XCTAssertNil(DesktopBoardWriter.parseSummary("今天一切正常"))
        XCTAssertNil(DesktopBoardWriter.parseSummary(#"{"summary":"x","noteworthy":"yes"}"#))
        XCTAssertNil(DesktopBoardWriter.parseSummary(#"{"summary":"","noteworthy":true}"#))
        XCTAssertNil(DesktopBoardWriter.parseSummary("{ broken"))
    }

    func testSummaryUsesTheReplyAndTimesOut() async throws {
        let (writer, provider, _) = make()
        let done = Task { await writer.summarize("发现 2 个新报错") }
        await waitFor { provider.runs.count == 1 }
        XCTAssertEqual(provider.messages[0].last?.text, "发现 2 个新报错")
        provider.runs[0].yield(.snapshot(text: #"{"summary":"2 个新报错","noteworthy":true}"#, reasoning: ""))
        provider.runs[0].yield(.complete)
        let result = await done.value
        XCTAssertEqual(result?.summary, "2 个新报错")
        XCTAssertEqual(result?.noteworthy, true)

        writer.timeout = .milliseconds(50)
        let started = Date()
        let slow = await writer.summarize("慢模型")
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func scheduledWorkspace() throws -> (DesktopWorkspace, DesktopBoardWriter, Provider) {
        let defaults = UserDefaults(suiteName: "amber.board-writer.run.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let provider = Provider()
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([]), provider: provider,
            initialConversations: [], agentTasks: DesktopAgentTasks(defaults: defaults))
        let writer = DesktopBoardWriter(provider: provider) { [weak workspace] in workspace?.boardWriterRequest() }
        workspace.boardWriter = writer
        return (workspace, writer, provider)
    }

    private let scheduled = DesktopScheduledTask(name: "巡检", prompt: "看看有没有新报错", schedule: .daily(hour: 9, minute: 0))

    func testCompletedRunGetsSummaryInItsRecord() async throws {
        let (workspace, _, provider) = try scheduledWorkspace()
        let running = Task { await workspace.runScheduled(self.scheduled) }
        await waitFor { provider.runs.count == 1 }
        provider.runs[0].yield(.snapshot(text: "发现 2 个新报错：……", reasoning: ""))
        provider.runs[0].yield(.complete)
        await waitFor { provider.runs.count == 2 }
        XCTAssertEqual(provider.messages[1].last?.text, "发现 2 个新报错：……", "the summary reads the final reply")
        provider.runs[1].yield(.snapshot(text: "```json\n{\"summary\":\"2 个新报错\",\"noteworthy\":true}\n```", reasoning: ""))
        provider.runs[1].yield(.complete)
        let record = await running.value
        _ = await workspace.flush()
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.summary, "2 个新报错")
        XCTAssertEqual(record.noteworthy, true)
    }

    func testSlowSummaryTimesOutAndFailedRunsSkipIt() async throws {
        let (workspace, writer, provider) = try scheduledWorkspace()
        writer.timeout = .milliseconds(50)
        let running = Task { await workspace.runScheduled(self.scheduled) }
        await waitFor { provider.runs.count == 1 }
        provider.runs[0].yield(.snapshot(text: "一切正常", reasoning: ""))
        provider.runs[0].yield(.complete)
        let record = await running.value
        XCTAssertEqual(provider.runs.count, 2, "the summary was asked")
        XCTAssertEqual(record.status, .completed)
        XCTAssertNil(record.summary)
        XCTAssertNil(record.noteworthy)

        let failing = Task { await workspace.runScheduled(self.scheduled) }
        await waitFor { provider.runs.count == 3 }
        provider.runs[2].yield(.failed("模型报错"))
        let failed = await failing.value
        _ = await workspace.flush()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(provider.runs.count, 3, "failed runs get no summary")
    }
}
