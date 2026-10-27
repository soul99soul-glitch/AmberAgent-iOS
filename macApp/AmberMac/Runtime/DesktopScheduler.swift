import AppKit
import Foundation
import Observation

/// Keeps the Mac from idle-sleeping while scheduled runs are active. Swappable in tests.
@MainActor protocol DesktopScheduleActivity: AnyObject {
    func begin()
    func end()
}

@MainActor final class DesktopProcessScheduleActivity: DesktopScheduleActivity {
    private var token: NSObjectProtocol?
    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Amber 正在运行定时任务")
    }
    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}

/// Fires scheduled tasks. One timer aims at the earliest due slot; wake, clock and time-zone changes recompute.
/// Same task never overlaps itself; at most `maxConcurrentRuns` scheduled runs at once.
/// The Mac is not woken from sleep: missed slots are handled by each task's missed-run policy after wake.
@MainActor @Observable final class DesktopScheduler {
    typealias Runner = @MainActor (DesktopScheduledTask, Date?) async -> DesktopScheduleRunRecord

    static let maxConcurrentRuns = 2
    /// Even with nothing due the timer rechecks this often, so a missed system notification cannot strand a task.
    static let maximumTimerInterval: TimeInterval = 60
    /// Event-triggered runs of one task start at least this far apart, like the interval rule's floor.
    static let minimumEventGap = TimeInterval(DesktopSchedule.minimumIntervalMinutes * 60)

    private(set) var tasks: [DesktopScheduledTask] = []
    private(set) var running: Set<UUID> = []
    /// Due while the concurrency cap was full; run in order as slots free up.
    private(set) var queued: [UUID] = []
    private(set) var unreadableFiles: [String] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    var isPaused: Bool {
        didSet {
            guard isPaused != oldValue else { return }
            defaults.set(isPaused, forKey: Self.pausedKey)
            if !isPaused { recomputeAll(); tick() } else { queued.removeAll() }
            rescheduleTimer()
        }
    }
    /// Called after every finished or skipped run (notifications hook in here).
    @ObservationIgnored var onRunFinished: (@MainActor (DesktopScheduledTask, DesktopScheduleRunRecord) -> Void)?

    @ObservationIgnored let store: DesktopScheduleStore
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let calendar: @MainActor () -> Calendar
    @ObservationIgnored private let activity: any DesktopScheduleActivity
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timerEnabled: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var queuedSlots: [UUID: Date] = [:]
    @ObservationIgnored private var queuedContexts: [UUID: String] = [:]
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Writes run in order so a later state never lands under an earlier one.
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var cancelReason: String?

    private static let pausedKey = "desktop.schedules-paused"

    init(store: DesktopScheduleStore, defaults: UserDefaults = .standard, runner: @escaping Runner,
        clock: @escaping @MainActor () -> Date = Date.init,
        calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
        activity: any DesktopScheduleActivity = DesktopProcessScheduleActivity(), timerEnabled: Bool = true) {
        self.store = store; self.defaults = defaults; self.runner = runner; self.clock = clock
        self.calendar = calendar; self.activity = activity; self.timerEnabled = timerEnabled
        isPaused = defaults.bool(forKey: Self.pausedKey)
        loading = Task { await load() }
    }

    func waitUntilLoaded() async { await loading?.value }

    var enabledCount: Int { tasks.filter(\.enabled).count }
    var nextTask: DesktopScheduledTask? {
        tasks.filter { $0.enabled && $0.nextRunAt != nil }.min { $0.nextRunAt! < $1.nextRunAt! }
    }

    private func load() async {
        do {
            let result = try await store.load()
            unreadableFiles = result.unreadable
            let now = clock(), calendar = calendar()
            tasks = result.tasks
            for index in tasks.indices {
                // A run that was in flight when the app quit or crashed.
                if var last = tasks[index].lastRun, last.status == .running {
                    last.status = .failed; last.finishedAt = last.finishedAt ?? now
                    last.error = "应用退出，本次运行已中断。"
                    tasks[index].record(last)
                }
                if tasks[index].enabled, tasks[index].nextRunAt == nil, tasks[index].lastRun == nil {
                    tasks[index].nextRunAt = DesktopSchedulePlanner.initialNextRun(tasks[index], now: now, calendar: calendar)
                }
                if tasks[index] != result.tasks[index] { persist(tasks[index]) }
            }
        } catch { errorMessage = "读取定时任务失败，原始文件已保留。" }
        isLoaded = true
        tick()
    }

    // MARK: editing

    @discardableResult
    func save(task value: DesktopScheduledTask) async -> String? {
        await waitUntilLoaded()
        if let error = value.validationError { return error }
        var value = value
        let previous = tasks.first { $0.id == value.id }
        if previous?.schedule != value.schedule || previous?.trigger != value.trigger || previous?.enabled != value.enabled || previous == nil {
            value.nextRunAt = DesktopSchedulePlanner.initialNextRun(value, now: clock(), calendar: calendar())
            dequeue(value.id)
        }
        if !value.enabled { dequeue(value.id) }
        if value.enabled, value.trigger == nil, value.nextRunAt == nil, case .once = value.schedule { return "这个时间已经过去，请重新选择。" }
        // Run history is owned by the scheduler, never by an editor's stale copy.
        if let previous { value.lastRun = previous.lastRun; value.recentRuns = previous.recentRuns }
        await writes?.value
        guard await save(value) else { return errorMessage }
        if let index = tasks.firstIndex(where: { $0.id == value.id }) { tasks[index] = value } else { tasks.append(value) }
        rescheduleTimer()
        return nil
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard var value = tasks.first(where: { $0.id == id }) else { return }
        value.enabled = enabled
        await save(task: value)
    }

    func delete(_ id: UUID) async {
        dequeue(id)
        runTasks[id]?.cancel()
        await writes?.value
        do {
            try await store.delete(id)
            tasks.removeAll { $0.id == id }
            rescheduleTimer()
        } catch { errorMessage = "删除定时任务失败，请检查文件权限。" }
    }

    /// 「立即运行一次」: does not move the regular schedule.
    @discardableResult
    func runNow(_ id: UUID) -> String? {
        guard let task = tasks.first(where: { $0.id == id }) else { return "找不到此任务。" }
        guard !running.contains(id) else { return "这个任务正在运行。" }
        guard running.count < Self.maxConcurrentRuns else { return "已有 \(Self.maxConcurrentRuns) 个定时任务在运行，请稍后再试。" }
        start(task, scheduledFor: nil)
        return nil
    }

    /// An event-triggered task's event happened; `context` (new file names, the session) is appended to the prompt.
    /// Same rules as a due slot: no overlap with itself, queued behind the global cap, nothing while paused.
    func fire(_ id: UUID, context: String) {
        guard isLoaded, !isPaused, let task = tasks.first(where: { $0.id == id }), task.enabled, task.trigger != nil else { return }
        if running.contains(id) || queued.contains(id) {
            return finishSkipped(id, scheduledFor: nil, reason: "上一次运行尚未结束，本次已跳过。", context: context)
        }
        // lastRun too: a burst of skipped records can push the last real run out of the capped history.
        if let last = ([task.lastRun].compactMap { $0 } + task.recentRuns).first(where: { $0.triggerContext != nil && $0.status != .skipped }),
           clock().timeIntervalSince(last.startedAt) < Self.minimumEventGap {
            return finishSkipped(id, scheduledFor: nil,
                reason: "距上次事件触发不足 \(DesktopSchedule.minimumIntervalMinutes) 分钟，本次已跳过。", context: context)
        }
        if running.count >= Self.maxConcurrentRuns {
            queued.append(id); queuedContexts[id] = context
        } else {
            start(task, scheduledFor: nil, context: context)
        }
    }

    /// Cancels queued and running runs; `reason` replaces the generic cancel message in their records.
    func cancelAll(reason: String? = nil) {
        cancelReason = reason
        queued.removeAll(); queuedSlots.removeAll(); queuedContexts.removeAll()
        for task in runTasks.values { task.cancel() }
    }

    func flush() async { for task in Array(runTasks.values) { await task.value } }

    // MARK: timing

    /// Evaluate every task against the clock. Safe to call any time; runs at most once per due slot.
    func tick() {
        guard isLoaded, !isPaused else { rescheduleTimer(); return }
        let now = clock(), calendar = calendar()
        for task in tasks {
            switch DesktopSchedulePlanner.decide(task, now: now, calendar: calendar) {
            case .wait: continue
            case .skip(let missed, let next):
                advance(task.id, to: next)
                finishSkipped(task.id, scheduledFor: missed, reason: "Mac 当时未运行 Amber 或在睡眠，已按设置跳过错过的运行。")
            case .run(let slot, let next):
                advance(task.id, to: next)
                if running.contains(task.id) || queuedSlots[task.id] != nil {
                    finishSkipped(task.id, scheduledFor: slot, reason: "上一次运行尚未结束，本次已跳过。")
                } else if running.count >= Self.maxConcurrentRuns {
                    queued.append(task.id); queuedSlots[task.id] = slot
                } else if let current = tasks.first(where: { $0.id == task.id }) {
                    start(current, scheduledFor: slot)
                }
            }
        }
        rescheduleTimer()
    }

    /// Clock or time-zone change: move wall-clock rules to the new local time, then evaluate.
    func systemClockChanged() { recomputeAll(); tick() }

    func startObservingSystem() {
        guard observers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let wake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let clock = center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemClockChanged() }
        }
        let zone = center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { NSTimeZone.resetSystemTimeZone(); self?.systemClockChanged() }
        }
        observers = [(workspaceCenter, wake), (center, clock), (center, zone)]
    }

    private func recomputeAll() {
        let now = clock(), calendar = calendar()
        for index in tasks.indices {
            let next = DesktopSchedulePlanner.recompute(tasks[index], now: now, calendar: calendar)
            guard next != tasks[index].nextRunAt else { continue }
            tasks[index].nextRunAt = next
            persist(tasks[index])
        }
    }

    private func rescheduleTimer() {
        timer?.cancel()
        guard timerEnabled, isLoaded, !isPaused else { timer = nil; return }
        let next = tasks.compactMap { $0.enabled ? $0.nextRunAt : nil }.min()
        let delay = min(max(0, (next ?? .distantFuture).timeIntervalSince(clock())), Self.maximumTimerInterval)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: runs

    private func start(_ task: DesktopScheduledTask, scheduledFor: Date?, context: String? = nil) {
        running.insert(task.id)
        activity.begin()
        var started = DesktopScheduleRunRecord(scheduledFor: scheduledFor, startedAt: clock(), status: .running)
        started.triggerContext = context
        update(task.id) { $0.record(started) }
        // The runner only sees the prompt; the event's details ride along at its end.
        var input = task
        if let context { input.prompt += "\n\n" + context }
        runTasks[task.id] = Task { [weak self, runner] in
            var record = await runner(input, scheduledFor)
            guard let self else { return }
            record.id = started.id
            record.triggerContext = context
            if record.status == .failed, let reason = self.cancelReason { record.error = reason }
            self.update(task.id) { $0.record(record) }
            self.running.remove(task.id)
            self.runTasks[task.id] = nil
            if self.running.isEmpty { self.activity.end() }
            if let current = self.tasks.first(where: { $0.id == task.id }) { self.onRunFinished?(current, record) }
            self.drainQueue()
        }
    }

    private func drainQueue() {
        while !isPaused, running.count < Self.maxConcurrentRuns, !queued.isEmpty {
            let id = queued.removeFirst()
            let slot = queuedSlots.removeValue(forKey: id), context = queuedContexts.removeValue(forKey: id)
            guard let task = tasks.first(where: { $0.id == id }), task.enabled, !running.contains(id) else { continue }
            start(task, scheduledFor: slot, context: context)
        }
    }

    private func dequeue(_ id: UUID) {
        queued.removeAll { $0 == id }
        queuedSlots[id] = nil
        queuedContexts[id] = nil
    }

    private func finishSkipped(_ id: UUID, scheduledFor: Date?, reason: String, context: String? = nil) {
        let now = clock()
        var record = DesktopScheduleRunRecord(scheduledFor: scheduledFor, startedAt: now, finishedAt: now, status: .skipped, error: reason)
        record.triggerContext = context
        update(id) { $0.record(record) }
        if let task = tasks.first(where: { $0.id == id }) { onRunFinished?(task, record) }
    }

    private func advance(_ id: UUID, to next: Date?) { update(id) { $0.nextRunAt = next } }

    private func update(_ id: UUID, _ change: (inout DesktopScheduledTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        // A once-task that has fired is spent; keep it listed but switched off.
        if tasks[index].trigger == nil, case .once = tasks[index].schedule, tasks[index].nextRunAt == nil, tasks[index].lastRun != nil { tasks[index].enabled = false }
        persist(tasks[index])
    }

    private func persist(_ value: DesktopScheduledTask) {
        let previous = writes
        writes = Task { [weak self] in
            await previous?.value
            await self?.save(value)
        }
    }

    /// Waits for queued writes; use before reading files back.
    func flushWrites() async { await writes?.value }

    @discardableResult
    private func save(_ value: DesktopScheduledTask) async -> Bool {
        do { try await store.save(value); return true }
        catch { errorMessage = "定时任务保存失败，请检查磁盘空间或文件权限。"; return false }
    }
}
