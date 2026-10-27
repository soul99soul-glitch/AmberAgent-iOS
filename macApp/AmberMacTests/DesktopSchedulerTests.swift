import XCTest
@testable import AmberMac

@MainActor final class DesktopSchedulerTests: XCTestCase {
    @MainActor private final class Activity: DesktopScheduleActivity {
        var active = false
        var begins = 0
        func begin() { if !active { begins += 1 }; active = true }
        func end() { active = false }
    }

    /// A runner whose runs finish only when the test says so.
    @MainActor private final class Runner {
        var started: [(task: DesktopScheduledTask, slot: Date?)] = []
        private var pending: [UUID: [CheckedContinuation<DesktopScheduleRunRecord, Never>]] = [:]
        func run(_ task: DesktopScheduledTask, _ slot: Date?) async -> DesktopScheduleRunRecord {
            started.append((task, slot))
            return await withCheckedContinuation { pending[task.id, default: []].append($0) }
        }
        func finish(_ id: UUID, status: DesktopScheduleRunStatus = .completed) {
            guard var list = pending[id], !list.isEmpty else { return XCTFail("no run in flight") }
            list.removeFirst().resume(returning: DesktopScheduleRunRecord(startedAt: Date(), finishedAt: Date(), status: status))
            pending[id] = list
        }
        func inFlight(_ id: UUID) -> Int { pending[id]?.count ?? 0 }
    }

    private var now = Date()
    private var zone = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ text: String, _ zone: String = "Asia/Shanghai") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func make(directory: URL? = nil, tasks seeded: [DesktopScheduledTask] = [])
        async throws -> (DesktopScheduler, Runner, Activity, DesktopScheduleStore) {
        let store = DesktopScheduleStore(directory: directory)
        for task in seeded { try await store.save(task) }
        let runner = Runner(), activity = Activity()
        let scheduler = DesktopScheduler(store: store, defaults: UserDefaults(suiteName: "amber.scheduler.\(UUID().uuidString)")!,
            runner: { await runner.run($0, $1) }, clock: { [unowned self] in self.now },
            calendar: { [unowned self] in var value = Calendar(identifier: .gregorian); value.timeZone = self.zone; return value },
            activity: activity, timerEnabled: false)
        await scheduler.waitUntilLoaded()
        return (scheduler, runner, activity, store)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func daily(_ name: String = "汇总", hour: Int = 9) -> DesktopScheduledTask {
        DesktopScheduledTask(name: name, prompt: "做点事", schedule: .daily(hour: hour, minute: 0))
    }

    func testFiresOnceAtTheSlotAndAdvances() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, activity, _) = try await make()
        let task = daily()
        let error = await scheduler.save(task: task)
        XCTAssertNil(error)
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-27 09:00"))
        scheduler.tick(); await settle()
        XCTAssertTrue(runner.started.isEmpty)

        now = date("2026-10-27 09:00")
        scheduler.tick(); await settle()
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 1, "a slot runs once even if checked twice")
        XCTAssertEqual(runner.started.first?.slot, date("2026-10-27 09:00"))
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-28 09:00"))
        XCTAssertTrue(activity.active, "idle sleep is held off while a run is active")
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.status, .running)

        runner.finish(task.id)
        await settle()
        XCTAssertFalse(activity.active)
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.status, .completed)
        XCTAssertTrue(scheduler.running.isEmpty)
    }

    func testWakingAfterManyMissedSlotsRunsOnce() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        var task = DesktopScheduledTask(name: "轮询", prompt: "x", schedule: .interval(minutes: 15, anchor: date("2026-10-27 08:00")))
        task.missedRun = .runOnceOnWake
        await scheduler.save(task: task)
        // Lid closed for five hours.
        now = date("2026-10-27 13:07")
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 1)
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-27 13:15"))
        runner.finish(task.id)
        await settle()
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 1)
    }

    func testSkipPolicyRecordsSkippedRunInsteadOfRunning() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        var task = daily()
        task.missedRun = .skip
        await scheduler.save(task: task)
        var finished: [DesktopScheduleRunRecord] = []
        scheduler.onRunFinished = { finished.append($1) }
        now = date("2026-10-27 15:00")
        scheduler.tick(); await settle()
        XCTAssertTrue(runner.started.isEmpty)
        XCTAssertEqual(finished.map(\.status), [.skipped])
        XCTAssertEqual(scheduler.tasks.first?.recentRuns.first?.status, .skipped)
        XCTAssertNil(scheduler.tasks.first?.lastRun, "lastRun keeps the last real run")
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-28 09:00"))
    }

    func testSameTaskNeverRunsTwiceConcurrently() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        let task = DesktopScheduledTask(name: "慢任务", prompt: "x", schedule: .interval(minutes: 15, anchor: date("2026-10-27 08:00")))
        await scheduler.save(task: task)
        now = date("2026-10-27 08:15")
        scheduler.tick(); await settle()
        now = date("2026-10-27 08:30")
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 1)
        XCTAssertEqual(runner.inFlight(task.id), 1)
        XCTAssertEqual(scheduler.tasks.first?.recentRuns.first?.status, .skipped)
        XCTAssertNotNil(scheduler.tasks.first?.recentRuns.first?.error)
        XCTAssertEqual(scheduler.runNow(task.id), "这个任务正在运行。")
        runner.finish(task.id)
        await settle()
        now = date("2026-10-27 08:45")
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 2)
    }

    func testGlobalCapOfTwoQueuesTheThird() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, activity, _) = try await make()
        let a = daily("A"), b = daily("B"), c = daily("C")
        for task in [a, b, c] { await scheduler.save(task: task) }
        now = date("2026-10-27 09:00")
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 2)
        XCTAssertEqual(scheduler.running.count, 2)
        XCTAssertEqual(scheduler.queued.count, 1)
        let waiting = try XCTUnwrap(scheduler.queued.first)
        XCTAssertNotNil(scheduler.runNow(waiting), "manual runs respect the cap too")

        let first = runner.started[0].task.id
        runner.finish(first)
        await settle()
        XCTAssertEqual(runner.started.count, 3)
        XCTAssertEqual(runner.started.last?.task.id, waiting)
        XCTAssertEqual(runner.started.last?.slot, date("2026-10-27 09:00"), "a queued run keeps its original slot")
        XCTAssertTrue(scheduler.queued.isEmpty)
        XCTAssertLessThanOrEqual(scheduler.running.count, DesktopScheduler.maxConcurrentRuns)
        for id in [runner.started[1].task.id, waiting] { runner.finish(id) }
        await settle()
        XCTAssertFalse(activity.active)
        XCTAssertEqual(activity.begins, 1, "one activity covers overlapping runs")
    }

    func testTimeZoneChangeMovesNextRunToNewLocalTime() async throws {
        now = date("2026-10-27 06:00")
        let (scheduler, runner, _, _) = try await make()
        await scheduler.save(task: daily())
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-27 09:00"))
        zone = TimeZone(identifier: "America/New_York")!
        scheduler.systemClockChanged(); await settle()
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-27 09:00", "America/New_York"))
        XCTAssertTrue(runner.started.isEmpty)
    }

    func testClockJumpForwardRunsDueTaskOnce() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        await scheduler.save(task: daily())
        now = date("2026-10-29 10:00")
        scheduler.systemClockChanged(); await settle()
        XCTAssertEqual(runner.started.count, 1)
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-10-30 09:00"))
    }

    func testDSTSpringForwardDayStillFiresDailyTask() async throws {
        zone = TimeZone(identifier: "America/New_York")!
        now = date("2026-03-07 10:00", "America/New_York")
        let (scheduler, runner, _, _) = try await make()
        let task = daily()
        await scheduler.save(task: task)
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-03-08 09:00", "America/New_York"))
        now = date("2026-03-08 09:00", "America/New_York")
        scheduler.tick(); await settle()
        XCTAssertEqual(runner.started.count, 1)
        XCTAssertEqual(scheduler.tasks.first?.nextRunAt, date("2026-03-09 09:00", "America/New_York"))
    }

    func testPauseStopsFiringAndResumeCatchesUpOnce() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        await scheduler.save(task: daily())
        scheduler.isPaused = true
        now = date("2026-10-27 09:30")
        scheduler.tick(); await settle()
        XCTAssertTrue(runner.started.isEmpty)
        scheduler.isPaused = false; await settle()
        XCTAssertEqual(runner.started.count, 1)
    }

    func testOnceTaskDisablesItselfAfterFiringAndRejectsPastTime() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        let task = DesktopScheduledTask(name: "一次", prompt: "x", schedule: .once(date("2026-10-27 08:30")))
        await scheduler.save(task: task)
        now = date("2026-10-27 08:31")
        scheduler.tick(); await settle()
        runner.finish(task.id)
        await settle()
        XCTAssertEqual(scheduler.tasks.first?.enabled, false)
        XCTAssertNil(scheduler.tasks.first?.nextRunAt)
        let stale = DesktopScheduledTask(name: "过去", prompt: "x", schedule: .once(date("2026-10-27 07:00")))
        let error = await scheduler.save(task: stale)
        XCTAssertNotNil(error)
    }

    func testEditKeepsHistoryAndDisablingDropsQueuedRun() async throws {
        now = date("2026-10-27 08:00")
        let (scheduler, runner, _, _) = try await make()
        let a = daily("A"), b = daily("B"), c = daily("C")
        for task in [a, b, c] { await scheduler.save(task: task) }
        now = date("2026-10-27 09:00")
        scheduler.tick(); await settle()
        let waiting = try XCTUnwrap(scheduler.queued.first)
        await scheduler.setEnabled(waiting, false)
        XCTAssertTrue(scheduler.queued.isEmpty)
        runner.finish(runner.started[0].task.id)
        await settle()
        XCTAssertEqual(runner.started.count, 2)

        var edited = try XCTUnwrap(scheduler.tasks.first { $0.id == runner.started[0].task.id })
        edited.lastRun = nil
        edited.recentRuns = []
        edited.prompt = "新的提示词"
        await scheduler.save(task: edited)
        let after = try XCTUnwrap(scheduler.tasks.first { $0.id == edited.id })
        XCTAssertEqual(after.prompt, "新的提示词")
        XCTAssertEqual(after.lastRun?.status, .completed, "an editor's stale copy never erases run history")
        XCTAssertEqual(after.nextRunAt, date("2026-10-28 09:00"), "schedule unchanged → slot unchanged")
        runner.finish(runner.started[1].task.id)
        await settle()
    }

    func testRunInterruptedByQuitIsRecordedAsFailedOnRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-scheduler-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        now = date("2026-10-27 10:00")
        var task = daily()
        task.nextRunAt = date("2026-10-28 09:00")
        task.lastRun = DesktopScheduleRunRecord(startedAt: date("2026-10-27 09:00"), status: .running)
        let (scheduler, runner, _, _) = try await make(directory: directory, tasks: [task])
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.status, .failed)
        XCTAssertEqual(scheduler.tasks.first?.lastRun?.error, "应用退出，本次运行已中断。")
        XCTAssertTrue(runner.started.isEmpty)
        await scheduler.flushWrites()
        let reread = try await DesktopScheduleStore(directory: directory).load()
        XCTAssertEqual(reread.tasks.first?.lastRun?.status, .failed)
    }

    func testDeleteRemovesTaskFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-scheduler-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        now = date("2026-10-27 08:00")
        let (scheduler, _, _, store) = try await make(directory: directory)
        let task = daily()
        await scheduler.save(task: task)
        await scheduler.delete(task.id)
        XCTAssertTrue(scheduler.tasks.isEmpty)
        let reread = try await store.load()
        XCTAssertTrue(reread.tasks.isEmpty)
    }
}
