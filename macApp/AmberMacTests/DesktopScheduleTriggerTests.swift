import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

@MainActor final class DesktopScheduleTriggerTests: XCTestCase {
    /// A runner whose runs finish only when the test says so.
    @MainActor private final class Runner {
        var prompts: [String] = []
        var clock: () -> Date = Date.init
        private var pending: [UUID: [CheckedContinuation<DesktopScheduleRunRecord, Never>]] = [:]
        func run(_ task: DesktopScheduledTask) async -> DesktopScheduleRunRecord {
            prompts.append(task.prompt)
            return await withCheckedContinuation { pending[task.id, default: []].append($0) }
        }
        func finish(_ id: UUID) {
            guard var list = pending[id], !list.isEmpty else { return XCTFail("no run in flight") }
            list.removeFirst().resume(returning: DesktopScheduleRunRecord(startedAt: clock(), finishedAt: clock(), status: .completed))
            pending[id] = list
        }
    }

    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amber-triggers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func make() async -> (DesktopScheduler, Runner) {
        let runner = Runner()
        runner.clock = { [unowned self] in self.now }
        let scheduler = DesktopScheduler(store: DesktopScheduleStore(directory: nil),
            defaults: UserDefaults(suiteName: "amber.triggers.\(UUID().uuidString)")!,
            runner: { task, _ in await runner.run(task) }, clock: { [unowned self] in self.now }, timerEnabled: false)
        await scheduler.waitUntilLoaded()
        return (scheduler, runner)
    }

    private func eventTask(_ name: String = "整理下载", _ trigger: DesktopScheduleTrigger = .folder(path: "/tmp")) -> DesktopScheduledTask {
        var task = DesktopScheduledTask(name: name, prompt: "整理新文件", schedule: .daily(hour: 9, minute: 0))
        task.trigger = trigger
        return task
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: model

    func testOldFilesWithoutTriggerStillDecode() throws {
        let task = DesktopScheduledTask(name: "汇总", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        XCTAssertNil(object["trigger"], "nil trigger is not written, so files stay readable by older builds")
        let decoded = try JSONDecoder().decode(DesktopScheduledTask.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.trigger)
        XCTAssertEqual(decoded, task)

        let event = eventTask("会话", .agentSession(.needsYou))
        XCTAssertEqual(try JSONDecoder().decode(DesktopScheduledTask.self, from: JSONEncoder().encode(event)).trigger, .agentSession(.needsYou))
    }

    func testValidationIgnoresScheduleOfEventTasks() {
        var task = eventTask()
        task.schedule = .weekly(days: [], hour: 9, minute: 0)
        XCTAssertNil(task.validationError)
        task.trigger = .folder(path: "")
        XCTAssertEqual(task.validationError, "请选择要监听的文件夹。")
        task.trigger = nil
        XCTAssertEqual(task.validationError, "每周规则至少选择一天。")
    }

    func testEventTaskHasNoNextRunAndRuleText() async {
        let (scheduler, _) = await make()
        var task = eventTask("整理", .folder(path: "/Users/mi/Downloads"))
        task.schedule = .once(now.addingTimeInterval(-60))
        let error = await scheduler.save(task: task)
        XCTAssertNil(error, "a spent once-rule under an event trigger is not rejected")
        XCTAssertNil(scheduler.tasks.first?.nextRunAt)
        XCTAssertEqual(DesktopScheduledTasksView.ruleText(task), "文件夹 Downloads 有新文件时")
        XCTAssertEqual(DesktopScheduledTasksView.ruleText(eventTask("x", .agentSession(.ended))), "Claude Code / Codex 会话结束时")

        let items = DesktopBoard.build(tasks: scheduler.tasks, live: [], paused: false, sessions: [], now: now)
        XCTAssertEqual(items.map(\.column), [.scheduled])
        XCTAssertEqual(items.first?.detail, "文件夹 Downloads 有新文件时")
        XCTAssertNil(items.first?.nextRunAt)

        now = now.addingTimeInterval(86_400 * 2)
        scheduler.tick(); await settle()
        XCTAssertTrue(scheduler.running.isEmpty, "the clock never fires an event task")
    }

    // MARK: fire

    func testFireAppendsContextAndEnforcesTheGap() async {
        let (scheduler, runner) = await make()
        let task = eventTask()
        await scheduler.save(task: task)
        scheduler.fire(task.id, context: "新文件：a.txt")
        await settle()
        XCTAssertEqual(runner.prompts, ["整理新文件\n\n新文件：a.txt"])
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.triggerContext, "新文件：a.txt")
        runner.finish(task.id); await settle()
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.status, .completed)
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.triggerContext, "新文件：a.txt", "the runner's record keeps the context")

        now = now.addingTimeInterval(14 * 60)
        scheduler.fire(task.id, context: "新文件：b.txt")
        await settle()
        XCTAssertEqual(runner.prompts.count, 1)
        XCTAssertEqual(scheduler.tasks.first?.recentRuns.first?.status, .skipped)
        XCTAssertEqual(scheduler.tasks.first?.recentRuns.first?.triggerContext, "新文件：b.txt")
        XCTAssertTrue(scheduler.tasks.first?.recentRuns.first?.error?.contains("15 分钟") == true)

        // The gap counts from the last event-triggered start, not from the skipped one.
        now = now.addingTimeInterval(60)
        scheduler.fire(task.id, context: "新文件：c.txt")
        await settle()
        XCTAssertEqual(runner.prompts.count, 2)
    }

    func testFireSkipsWhileRunningAndIgnoresDisabledPausedAndTimedTasks() async {
        let (scheduler, runner) = await make()
        let task = eventTask()
        var off = eventTask("停用")
        off.enabled = false
        let timed = DesktopScheduledTask(name: "定时", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        for value in [task, off, timed] { await scheduler.save(task: value) }

        scheduler.fire(off.id, context: "x")
        scheduler.fire(timed.id, context: "x")
        await settle()
        XCTAssertTrue(runner.prompts.isEmpty)

        scheduler.fire(task.id, context: "一")
        await settle()
        scheduler.fire(task.id, context: "二")
        await settle()
        XCTAssertEqual(runner.prompts.count, 1)
        XCTAssertEqual(scheduler.tasks.first { $0.id == task.id }?.recentRuns.first?.error, "上一次运行尚未结束，本次已跳过。")
        runner.finish(task.id); await settle()

        scheduler.isPaused = true
        now = now.addingTimeInterval(3600)
        scheduler.fire(task.id, context: "三")
        await settle()
        XCTAssertEqual(runner.prompts.count, 1, "nothing fires while paused")
    }

    func testFireQueuesBehindTheGlobalCap() async {
        let (scheduler, runner) = await make()
        let a = eventTask("A"), b = eventTask("B"), c = eventTask("C")
        for task in [a, b, c] { await scheduler.save(task: task) }
        for task in [a, b, c] { scheduler.fire(task.id, context: "新文件：\(task.name)") }
        await settle()
        XCTAssertEqual(scheduler.running.count, 2)
        XCTAssertEqual(scheduler.queued, [c.id])
        scheduler.fire(c.id, context: "again")
        XCTAssertEqual(scheduler.queued, [c.id], "a queued event task is not queued twice")
        runner.finish(a.id); await settle()
        XCTAssertEqual(runner.prompts.last, "整理新文件\n\n新文件：C", "the queued run keeps its context")
        XCTAssertTrue(scheduler.queued.isEmpty)
    }

    // MARK: folder

    func testNewFilesIgnoresDeletionsAndEdits() {
        let t0 = Date(timeIntervalSince1970: 1), t1 = Date(timeIntervalSince1970: 2)
        let before = ["keep.txt": t0, "gone.txt": t0, "same.pdf": t0]
        let after = ["keep.txt": t0, "same.pdf": t1, "new.png": t1]
        XCTAssertEqual(DesktopScheduleTriggers.newFiles(before: before, after: after), ["new.png", "same.pdf"])
        XCTAssertEqual(DesktopScheduleTriggers.newFiles(before: after, after: ["keep.txt": t0]), [])
        let many = (1...12).map { "f\($0).txt" }
        XCTAssertEqual(DesktopScheduleTriggers.folderContext(Array(many.prefix(2))), "新文件：f1.txt、f2.txt")
        XCTAssertTrue(DesktopScheduleTriggers.folderContext(many).hasSuffix("f10.txt 等 12 个"))
    }

    func testFolderWatcherDebouncesAndReportsOnlyNewVisibleFiles() async throws {
        let folder = try temporaryDirectory()
        try Data("old".utf8).write(to: folder.appendingPathComponent("old.txt"))
        let (scheduler, _) = await make()
        let task = eventTask("整理", .folder(path: folder.path))
        await scheduler.save(task: task)
        var fired: [(UUID, String)] = []
        let triggers = DesktopScheduleTriggers(scheduler: scheduler, registryURL: folder.appendingPathComponent("none/registry.json"),
            debounce: .milliseconds(300), fire: { fired.append(($0, $1)) })
        triggers.start()
        defer { triggers.stop() }

        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try await Task.sleep(for: .milliseconds(100))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.pdf"))
        try Data("h".utf8).write(to: folder.appendingPathComponent(".hidden"))
        try Data("p".utf8).write(to: folder.appendingPathComponent("movie.mp4.crdownload"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("old.txt"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fired.isEmpty, "still inside the quiet period")
        try await waitUntil { !fired.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fired.count, 1, "a burst of changes becomes one fire")
        XCTAssertEqual(fired.first?.0, task.id)
        XCTAssertEqual(fired.first?.1, "新文件：a.txt、b.pdf")

        // Deleting only: nothing new, nothing fires.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.txt"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(fired.count, 1)

        // Disabling the task closes its watcher.
        await scheduler.setEnabled(task.id, false)
        triggers.reconcile()
        try Data("c".utf8).write(to: folder.appendingPathComponent("c.txt"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(fired.count, 1)
    }

    // MARK: agent sessions

    private func session(_ id: String, _ state: TaskState, agent: AgentKind = .claude, summary: String? = nil, at: Date) -> SessionRecord {
        var registry = Registry()
        var start = GatewayEvent(agent: agent, kind: .promptSubmit, sessionId: id, cwd: "/Users/mi/amber", timestamp: at, origin: .interactive)
        start.summary = summary
        let presence = { Presence(screenLocked: false, idleSeconds: 0) }
        _ = registry.ingest(start, config: GatewayConfig(), now: at, presence: presence)
        var rec = registry.sessions[SessionRecord.key(agent, id)]!
        rec.state = state
        rec.updatedAt = at
        return rec
    }

    private func writeRegistry(_ sessions: [SessionRecord], to url: URL) throws {
        var registry = Registry()
        for rec in sessions { registry.sessions[rec.key] = rec }
        try RegistryStore(url: url).save(registry)
    }

    func testSessionEventsMapStatesAndSkipAmberRuns() {
        let at = now
        let previous: [String: TaskState] = ["claude:a": .running, "claude:b": .waiting, "codex:c": .running]
        let events = DesktopScheduleTriggers.sessionEvents(previous: previous, sessions: [
            session("a", .waiting, at: at),
            session("b", .waiting, at: at),
            session("c", .completed, agent: .codex, at: at),
            session("d", .stopped, agent: .amber, at: at),
            session("e", .stopped, agent: .run, at: at),
            session("f", .running, at: at),
        ])
        XCTAssertEqual(events.map { "\($0.0.key)|\($0.1.rawValue)" }.sorted(), ["claude:a|needsYou", "codex:c|ended"])
        // A session first seen already stopped still counts as having ended.
        XCTAssertEqual(DesktopScheduleTriggers.sessionEvents(previous: [:], sessions: [session("g", .stopped, at: at)]).map(\.1), [.ended])
        let context = DesktopScheduleTriggers.sessionContext(session("h", .waiting, summary: "修复看板", at: at), .needsYou)
        XCTAssertEqual(context, "Claude Code 会话在等你处理：「修复看板」\n目录：/Users/mi/amber")
    }

    func testRegistryChangesFireOncePerSessionAndEvent() async throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("registry.json")
        try writeRegistry([session("old", .stopped, at: now)], to: url)
        let (scheduler, _) = await make()
        let ended = eventTask("会话结束", .agentSession(.ended)), waiting = eventTask("等你", .agentSession(.needsYou))
        for task in [ended, waiting] { await scheduler.save(task: task) }
        var fired: [(UUID, String)] = []
        let triggers = DesktopScheduleTriggers(scheduler: scheduler, registryURL: url, fire: { fired.append(($0, $1)) })
        triggers.registryChanged()
        XCTAssertTrue(fired.isEmpty, "sessions that ended before Amber looked do not fire")

        func update(_ sessions: [SessionRecord]) throws {
            try writeRegistry(sessions, to: url)
            // Force a fresh modification date; two writes within the file system's resolution look the same.
            now = now.addingTimeInterval(1)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            triggers.registryChanged()
        }
        try update([session("old", .stopped, at: now), session("x", .running, summary: "写测试", at: now),
                    session("run", .running, agent: .amber, at: now)])
        XCTAssertTrue(fired.isEmpty)
        try update([session("old", .stopped, at: now), session("x", .waiting, summary: "写测试", at: now),
                    session("run", .stopped, agent: .amber, at: now)])
        XCTAssertEqual(fired.map(\.0), [waiting.id])
        XCTAssertTrue(fired.first?.1.contains("「写测试」") == true)
        try update([session("x", .running, summary: "写测试", at: now)])
        try update([session("x", .waiting, summary: "写测试", at: now)])
        XCTAssertEqual(fired.count, 1, "the same session waiting again does not fire twice")
        try update([session("x", .completed, summary: "写测试", at: now)])
        XCTAssertEqual(fired.map(\.0), [waiting.id, ended.id])
        try update([session("x", .stopped, summary: "写测试", at: now)])
        XCTAssertEqual(fired.count, 2, "completed → stopped is still the same ended event")
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
