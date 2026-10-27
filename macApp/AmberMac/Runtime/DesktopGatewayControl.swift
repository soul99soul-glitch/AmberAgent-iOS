import Foundation
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport

/// Answers the gateway daemon on `amber-app.sock` while Amber runs: approval decisions from the phone and
/// remote schedule management. The daemon has already authenticated the phone; policy lives here.
@MainActor final class DesktopGatewayControl {
    private let paths: GatewayPaths
    private let tasks: DesktopAgentTasks
    private let reporter: DesktopGatewayReporter
    private let scheduler: DesktopScheduler?
    private let queue = DispatchQueue(label: "amber.gateway.control")
    private var server: UnixSocketServer?

    /// The task board as the phone sees it; set by the live app (it knows the scheduled runs in flight).
    var board: (@MainActor () -> [AmberControl.BoardItem])?

    init(paths: GatewayPaths = .resolve(), tasks: DesktopAgentTasks, reporter: DesktopGatewayReporter, scheduler: DesktopScheduler?) {
        self.paths = paths; self.tasks = tasks; self.reporter = reporter; self.scheduler = scheduler
    }

    /// Socket file permissions (600 in a 700 directory) are the access control, same as the hook socket.
    func start() {
        guard server == nil else { return }
        do {
            try paths.ensureDirectories()
            let server = UnixSocketServer(path: paths.amberSocket.path, queue: queue, respond: Self.bridge { [weak self] in await self?.handle($0) })
            try server.start()
            self.server = server
        } catch {
            // Without the socket the phone just hears "Amber 未运行"; nothing else depends on it.
        }
    }

    func stop() { server?.stop(); server = nil }

    /// Rebinds if another process took over or removed the socket path (e.g. a second Amber that has since quit).
    /// Cheap; called from the gateway settings poll and on activation.
    func ensureListening() {
        guard let server, !server.isBound else { return }
        server.stop()
        self.server = nil
        start()
    }

    /// The socket queue blocks for the reply while the work runs on the main actor (never the other way round,
    /// so this cannot deadlock: the main actor never waits on the socket queue).
    nonisolated private static func bridge(_ work: @escaping @MainActor @Sendable (Data) async -> Data?) -> @Sendable (Data) -> Data? {
        { data in
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var reply: Data?
            Task { @MainActor in
                reply = await work(data)
                semaphore.signal()
            }
            // Answer before the daemon gives up: "busy" is true, whereas "Amber 未运行" would not be.
            guard semaphore.wait(timeout: .now() + AmberControl.timeout - 0.5) == .success else {
                return try? GatewayJSON.encoder().encode(AmberControl.Response.failure(504, "Mac 正忙，请稍后刷新查看结果"))
            }
            return reply
        }
    }

    func handle(_ data: Data) async -> Data? {
        let response: AmberControl.Response
        if let request = try? GatewayJSON.decoder().decode(AmberControl.Request.self, from: data) {
            response = await handle(request)
        } else {
            response = .failure(400, "无法识别的请求")
        }
        return try? GatewayJSON.encoder().encode(response)
    }

    func handle(_ request: AmberControl.Request) async -> AmberControl.Response {
        switch request.action {
        case .decide: return await decide(request)
        case .board:
            guard let board, let scheduler else { return .failure(503, "任务看板不可用") }
            await scheduler.waitUntilLoaded()
            return AmberControl.Response(status: 200, board: board())
        case .listSchedules, .createSchedule, .setScheduleEnabled, .runSchedule:
            guard let scheduler else { return .failure(503, "定时任务不可用") }
            await scheduler.waitUntilLoaded()
            return await schedules(request, scheduler)
        }
    }

    private func schedules(_ request: AmberControl.Request, _ scheduler: DesktopScheduler) async -> AmberControl.Response {
        switch request.action {
        case .listSchedules:
            return AmberControl.Response(status: 200, schedules: scheduler.tasks.map { Self.summary($0, scheduler) })
        case .createSchedule:
            guard let draft = request.draft else { return .failure(400, "缺少任务内容") }
            guard let schedule = Self.schedule(draft) else { return .failure(400, "时间规则不完整") }
            // Remote creation never chooses an approval policy: nothing is auto-approved until edited on the Mac.
            let task = DesktopScheduledTask(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines), schedule: schedule)
            if let error = await scheduler.save(task: task) { return .failure(400, error) }
            return AmberControl.Response(status: 200, schedule: scheduler.tasks.first { $0.id == task.id }.map { Self.summary($0, scheduler) })
        case .setScheduleEnabled:
            guard let id = request.scheduleId.flatMap(UUID.init(uuidString:)), let enabled = request.enabled,
                  var task = scheduler.tasks.first(where: { $0.id == id }) else { return .failure(404, "找不到这个定时任务") }
            task.enabled = enabled
            if let error = await scheduler.save(task: task) { return .failure(409, error) }
            return AmberControl.Response(status: 200, schedule: scheduler.tasks.first { $0.id == id }.map { Self.summary($0, scheduler) })
        case .runSchedule:
            guard let id = request.scheduleId.flatMap(UUID.init(uuidString:)), scheduler.tasks.contains(where: { $0.id == id }) else {
                return .failure(404, "找不到这个定时任务")
            }
            if let error = scheduler.runNow(id) { return .failure(409, error) }
            return AmberControl.Response(status: 200, schedule: scheduler.tasks.first { $0.id == id }.map { Self.summary($0, scheduler) })
        case .decide, .board:
            return .failure(400, "无法识别的请求")
        }
    }

    static func summary(_ task: DesktopScheduledTask, _ scheduler: DesktopScheduler) -> AmberControl.ScheduleSummary {
        AmberControl.ScheduleSummary(id: task.id.uuidString, name: task.name, rule: DesktopScheduledTasksView.ruleText(task),
            enabled: task.enabled, running: scheduler.running.contains(task.id), paused: scheduler.isPaused,
            nextRunAt: scheduler.isPaused ? nil : task.nextRunAt,
            lastStatus: task.lastRun?.status.rawValue, lastRunAt: task.lastRun?.finishedAt ?? task.lastRun?.startedAt,
            autoApprovesHighRisk: task.approval.autoApproveHighRisk)
    }

    static func schedule(_ draft: AmberControl.ScheduleDraft) -> DesktopSchedule? {
        let hour = draft.hour, minute = draft.minute ?? 0
        switch draft.rule {
        case .once: return draft.at.map { .once($0) }
        case .daily: return hour.map { .daily(hour: $0, minute: minute) }
        case .weekdays: return hour.map { .weekdays(hour: $0, minute: minute) }
        case .weekly:
            guard let hour, let days = draft.weekdays else { return nil }
            return .weekly(days: days, hour: hour, minute: minute)
        case .interval: return draft.intervalMinutes.map { .interval(minutes: $0, anchor: Date()) }
        }
    }

    private func decide(_ request: AmberControl.Request) async -> AmberControl.Response {
        guard let key = request.sessionKey, let call = request.toolCallId, let allow = request.allow,
              let conversation = reporter.conversation(forSessionKey: key),
              let run = tasks.records.first(where: { $0.conversationID == conversation && $0.status == .waiting })
        else { return .failure(409, "这次审批已经结束") }
        guard let approval = run.approval, approval.id == call else { return .failure(409, "这次审批已经结束") }
        if allow, DesktopToolRegistry.isHighRisk(approval.name) {
            return .failure(403, "高风险操作只能在 Mac 上核对后批准")
        }
        guard await tasks.decideFromNotification(runID: run.id, toolID: call, allow: allow) else {
            return .failure(409, "这次审批已经结束")
        }
        return AmberControl.Response(status: 200)
    }
}
