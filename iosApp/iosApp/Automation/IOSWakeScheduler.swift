@preconcurrency import BackgroundTasks
import Foundation
import Observation
import UIKit
@preconcurrency import Shared

struct IOSWakeExecutionReport: Sendable {
    var startedCount = 0
    var deferredCount = 0
    var failedCount = 0
    var runIDs: [String] = []
    var message: String?

    var summary: String {
        if let message { return message }
        if startedCount == 0 && deferredCount == 0 && failedCount == 0 { return "没有到期的 Amber 任务。" }
        return "已启动 \(startedCount) 项，等待执行 \(deferredCount) 项，失败 \(failedCount) 项。启动不代表执行完成，结果会写回原对话。"
    }
}

/// All triggers share this owner. The persisted claim precedes provider work;
/// a process death leaves an interrupted task instead of replaying side effects.
@MainActor @Observable
final class IOSWakeScheduler {
    static let shared = IOSWakeScheduler(store: .shared, systemSchedulingEnabled: true)
    let store: IOSWakeTaskStore
    private(set) var schedulingStatus = "计划保存在本机；后台执行时间由系统决定。"
    private(set) var lastError: String?

    private weak var chatViewModel: ChatViewModel?
    private let now: () -> Date
    private let isForeground: () -> Bool
    private let launchOverride: ((IOSWakeTask, String) async -> IOSWakeRunStartResult)?
    private let cancelOverride: ((String) -> Void)?
    private let submitOverride: ((Date?) throws -> Void)?
    private let notifications: (any IOSLocalNotificationCenter)?
    private let systemSchedulingEnabled: Bool
    private var isDraining = false
    private var didReconcile = false
    private var hasRegistered = false
    private var timer: Task<Void, Never>?
    private var preparation: Task<IOSWakeRunStartResult, Never>?
    private var preparingRunID: String?
    private var systemExecutionCount = 0
    private var schedulingRevision = 0
    private var settlingRunIDs: Set<String> = []

    init(
        store: IOSWakeTaskStore,
        now: @escaping () -> Date = Date.init,
        isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
        systemSchedulingEnabled: Bool = false,
        notifications: (any IOSLocalNotificationCenter)? = nil,
        startRun: ((IOSWakeTask, String) async -> IOSWakeRunStartResult)? = nil,
        cancelRun: ((String) -> Void)? = nil,
        submitSystem: ((Date?) throws -> Void)? = nil
    ) {
        self.store = store
        self.now = now
        self.isForeground = isForeground
        self.systemSchedulingEnabled = systemSchedulingEnabled
        self.notifications = notifications ?? (systemSchedulingEnabled ? IOSUserNotificationCenterAdapter() : nil)
        self.launchOverride = startRun
        self.cancelOverride = cancelRun
        self.submitOverride = submitSystem
    }

    private var systemIdentifier: String { "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").wake" }
    private func reminderID(_ taskID: String) -> String { "amber.wake.\(taskID)" }

    func attach(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
    }

    func tasks(conversationID: String) -> [IOSWakeTask] {
        store.tasks.filter { $0.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame }
    }

    func origin(forRunID runID: String) -> IOSWakeOrigin? {
        store.tasks.first { $0.executionRunID == runID }?.origin
    }

    func isRunClaimCurrent(taskID: String, runID: String) -> Bool {
        guard let task = store.task(id: taskID) else { return false }
        return task.status == .running && task.executionRunID == runID
    }

    func schedule(
        conversationID: String,
        sourceRunID: String,
        origin: IOSWakeOrigin,
        title: String,
        prompt: String,
        fireAt: Date?,
        event: String?,
        requiresForeground: Bool,
        requestID: String
    ) async throws -> IOSWakeTask {
        let task = try store.schedule(
            conversationID: conversationID, sourceRunID: sourceRunID, origin: origin,
            title: title, prompt: prompt, fireAt: fireAt, event: event,
            requiresForeground: requiresForeground, requestID: requestID
        )
        await refreshScheduling()
        return task
    }

    @discardableResult
    func cancel(id: String, conversationID: String) async throws -> IOSWakeTask {
        try await cancelTask(id: id, conversationID: conversationID)
    }

    @discardableResult
    func cancel(id: String) async throws -> IOSWakeTask {
        try await cancelTask(id: id, conversationID: nil)
    }

    private func cancelTask(id: String, conversationID: String?) async throws -> IOSWakeTask {
        let task = try store.cancel(id: id, conversationID: conversationID)
        if let runID = task.executionRunID {
            if preparingRunID == runID { preparation?.cancel() }
            cancelOwnedRun(runID)
        }
        notifications?.removePendingRequests(identifiers: [reminderID(id)])
        notifications?.removeDeliveredRequests(identifiers: [reminderID(id)])
        await refreshScheduling()
        return task
    }

    func runTask(id: String) async -> IOSWakeExecutionReport {
        do {
            try store.requestExecution(id: id)
            notifications?.removePendingRequests(identifiers: [reminderID(id)])
            notifications?.removeDeliveredRequests(identifiers: [reminderID(id)])
            return await runDueTasks(onlyTaskID: id)
        } catch {
            return IOSWakeExecutionReport(failedCount: 1, message: error.localizedDescription)
        }
    }

    func runDueTasks(event: String? = nil, content: String? = nil) async -> IOSWakeExecutionReport {
        if let event {
            do {
                let name = event.trimmingCharacters(in: .whitespacesAndNewlines)
                let newlyTriggered = store.tasks.filter {
                    $0.status == .scheduled && $0.event == name && $0.eventReceivedAt == nil
                }.map { reminderID($0.id) }
                try store.receive(event: event, content: content)
                notifications?.removePendingRequests(identifiers: newlyTriggered)
                notifications?.removeDeliveredRequests(identifiers: newlyTriggered)
            }
            catch { return IOSWakeExecutionReport(failedCount: 1, message: error.localizedDescription) }
        }
        return await runDueTasks(onlyTaskID: nil)
    }

    private func runDueTasks(onlyTaskID: String?) async -> IOSWakeExecutionReport {
        // Claim the drain before the first await; concurrent Shortcut, timer,
        // notification and BG delivery never create competing runs.
        guard !isDraining else {
            return IOSWakeExecutionReport(deferredCount: 1, message: "已有续跑请求正在处理，任务已保留。")
        }
        isDraining = true
        defer { isDraining = false }
        var report = IOSWakeExecutionReport()
        if let error = store.loadError {
            return IOSWakeExecutionReport(failedCount: 1, message: "任务文件暂不可读：\(error)")
        }
        await reconcileInterruptedTasksIfNeeded()
        let candidates = store.tasks.filter { $0.isDue(at: now()) && (onlyTaskID == nil || $0.id == onlyTaskID) }
            .sorted { ($0.fireAt ?? $0.eventReceivedAt ?? $0.createdAt) < ($1.fireAt ?? $1.eventReceivedAt ?? $1.createdAt) }
        for task in candidates {
            guard !Task.isCancelled else { break }
            do {
                if task.requiresForeground && !isForeground() {
                    try store.noteWaiting(id: task.id, reason: "需要前台操作；打开 Amber 后继续。")
                    report.deferredCount += 1
                    continue
                }
                // Serialize wake work, including runs started by a previous
                // trigger that have not yet reached a durable terminal.
                if store.tasks.contains(where: { $0.status == .running }) {
                    try store.noteWaiting(id: task.id, reason: "正在等待另一项续跑任务结束。")
                    report.deferredCount += 1
                    continue
                }
                let runID = UUID().uuidString
                let claimed = try store.claim(id: task.id, runID: runID)
                preparingRunID = runID
                let start = Task { @MainActor [weak self] in
                    guard let self else { return IOSWakeRunStartResult.deferred("运行服务不可用。") }
                    if let launchOverride { return await launchOverride(claimed, runID) }
                    guard let chatViewModel = await readyChatViewModel() else { return .deferred("Amber 聊天服务尚未就绪。") }
                    return await chatViewModel.startWakeTask(
                        claimed, runID: runID,
                        externallyManagedBackgroundExecution: systemExecutionCount > 0
                    )
                }
                preparation = start
                let result = await withTaskCancellationHandler {
                    await start.value
                } onCancel: {
                    start.cancel()
                }
                preparation = nil
                preparingRunID = nil
                if Task.isCancelled {
                    cancelOwnedRun(runID, interrupted: true)
                    _ = try store.finish(runID: runID, status: .interrupted, message: "系统执行时间已结束，请查看原对话后重试。")
                    break
                }
                // Cancellation can arrive while preparing the target history.
                guard let current = store.task(id: task.id), current.executionRunID == runID,
                      current.status != .cancelled else { continue }
                switch result {
                case .started:
                    report.startedCount += 1
                    report.runIDs.append(runID)
                    notifications?.removePendingRequests(identifiers: [reminderID(task.id)])
                    notifications?.removeDeliveredRequests(identifiers: [reminderID(task.id)])
                case .deferred(let reason):
                    try store.deferExecution(id: task.id, runID: runID, reason: reason)
                    report.deferredCount += 1
                case .failed(let reason):
                    _ = try store.finish(runID: runID, status: .failed, message: reason)
                    report.failedCount += 1
                }
            } catch {
                lastError = error.localizedDescription
                report.failedCount += 1
            }
        }
        await refreshScheduling()
        return report
    }

    func recordRunTerminal(runID: String, status: String, result: String? = nil) async {
        settlingRunIDs.insert(runID)
        defer { settlingRunIDs.remove(runID) }
        let state: IOSWakeTask.Status
        switch status.lowercased() {
        case "completed": state = .completed
        case "cancelled", "canceled": state = .cancelled
        case "interrupted", "expired": state = .interrupted
        default: state = .failed
        }
        do {
            if let task = try store.finish(
                runID: runID, status: state,
                message: state == .completed ? nil : "请查看原对话中的执行结果。", result: result
            ) {
                notifications?.removePendingRequests(identifiers: [reminderID(task.id)])
                notifications?.removeDeliveredRequests(identifiers: [reminderID(task.id)])
                if systemSchedulingEnabled && !isForeground() {
                    _ = try await IOSLocalNotificationService.shared.scheduleTaskCompletion(conversationID: task.conversationID)
                }
            }
            await refreshScheduling()
        } catch {
            didReconcile = false
            lastError = "保存续跑结果失败：\(error.localizedDescription)"
        }
    }

    func applicationBecameActive() async {
        _ = await runDueTasks()
    }

    func applicationEnteredBackground() {
        timer?.cancel()
        timer = nil
    }

    /// Called before didFinishLaunching returns, including headless launches.
    func prepareForApplicationLaunch() {
        guard systemSchedulingEnabled, !hasRegistered else { return }
        hasRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: systemIdentifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.handleSystemTask(task) }
        }
        if !hasRegistered { schedulingStatus = "后台触发注册失败；仍可通过快捷指令或打开 Amber 执行。" }
        Task { await refreshScheduling() }
    }

    func refreshScheduling() async {
        schedulingRevision += 1
        let revision = schedulingRevision
        timer?.cancel()
        timer = nil
        let scheduled = store.tasks.filter { $0.status == .scheduled }
        let times = scheduled.compactMap { task -> Date? in
            if task.eventReceivedAt != nil { return now() }
            return task.fireAt
        }
        let next = times.min()
        let nextBackground = scheduled.filter { !$0.requiresForeground }.compactMap { task in
            task.eventReceivedAt != nil ? now() : task.fireAt
        }.min()
        let requestDate = nextBackground.map { max($0, now().addingTimeInterval(30)) }
        do {
            if let submitOverride {
                try submitOverride(requestDate)
            } else if systemSchedulingEnabled && hasRegistered {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: systemIdentifier)
                if let requestDate {
                    let request = BGProcessingTaskRequest(identifier: systemIdentifier)
                    request.earliestBeginDate = requestDate
                    request.requiresNetworkConnectivity = true
                    request.requiresExternalPower = false
                    try BGTaskScheduler.shared.submit(request)
                    schedulingStatus = "已申请后台执行；系统决定实际时间，也可由快捷指令触发。"
                } else {
                    schedulingStatus = scheduled.isEmpty ? "没有待执行的续跑任务。" : "正在等待事件或前台操作。"
                }
            }
        } catch {
            schedulingStatus = "计划已保存，后台请求未获准：\(error.localizedDescription)。可由快捷指令或打开 Amber 执行。"
        }
        await reconcileReminders(scheduled)
        guard revision == schedulingRevision, systemSchedulingEnabled, isForeground(), let next else { return }
        let hasWaiting = scheduled.contains { $0.isDue(at: now()) && $0.lastMessage != nil }
        let delay = max(hasWaiting ? 30 : 1, next.timeIntervalSince(now()))
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            _ = await runDueTasks()
        }
    }

    private func reconcileReminders(_ scheduled: [IOSWakeTask]) async {
        guard let notifications else { return }
        let pending = await notifications.pendingRequestIdentifiers()
        let live = Set(store.tasks.filter { $0.status == .scheduled }.map { reminderID($0.id) })
        let obsolete = pending.filter { $0.hasPrefix("amber.wake.") && !live.contains($0) }
        if !obsolete.isEmpty { notifications.removePendingRequests(identifiers: obsolete) }
        guard await notifications.authorization() == .allowed else { return }
        for task in scheduled {
            guard let fireAt = task.eventReceivedAt ?? task.fireAt,
                  task.reminderRequestedAt == nil,
                  !pending.contains(reminderID(task.id)),
                  let url = IOSAppDeepLink.url(for: .wakeTask(id: task.id)),
                  let current = store.task(id: task.id), current.status == .scheduled,
                  current.reminderRequestedAt == nil else { continue }
            do {
                try await notifications.add(IOSLocalNotificationRequest(
                    identifier: reminderID(task.id), title: "Amber 有待执行的任务",
                    body: "\(task.title)：点按打开并继续。", fireDate: max(fireAt, now().addingTimeInterval(1)), deepLink: url
                ))
                // add is asynchronous; a concurrent cancel must also remove a
                // request that finished adding after the cancellation.
                if store.task(id: task.id)?.status != .scheduled {
                    notifications.removePendingRequests(identifiers: [reminderID(task.id)])
                } else {
                    try store.markReminderRequested(id: task.id)
                }
            } catch { lastError = "任务已保存，通知安排失败：\(error.localizedDescription)" }
        }
    }

    private func reconcileInterruptedTasksIfNeeded() async {
        guard !didReconcile else { return }
        didReconcile = true
        for task in store.tasks where task.status == .running {
            guard let runID = task.executionRunID else { continue }
            if launchOverride != nil { continue }
            let model = await readyChatViewModel()
            do {
                let runStore = model?.runStore ?? IOSDurableRunStore()
                let terminal = try await runStore.snapshot(runId: runID)
                if let terminal, terminal.status.isTerminal, terminal.finishedAt != nil {
                    var result: String?
                    if terminal.status.wireName.lowercased() == "completed" {
                        guard let conversationStore = model?.conversationStore,
                              let conversationID = IOSOrchestrationLaunchPolicy.parseKotlinUuid(task.conversationID) else {
                            didReconcile = false
                            lastError = "已完成运行的原会话尚未就绪，等待恢复结果。"
                            continue
                        }
                        guard let messages = await conversationStore.messages(for: conversationID) else {
                            didReconcile = false
                            lastError = conversationStore.lastIOError?.message ?? "暂时无法读取原会话，已保留任务等待恢复。"
                            continue
                        }
                        result = IOSWakeTaskOutput.text(for: task, in: messages)
                    }
                    await recordRunTerminal(runID: runID, status: terminal.status.wireName, result: result)
                    if store.task(id: task.id)?.status == .running { didReconcile = false }
                } else if !IOSChatBackgroundGenerationCoordinator.shared.restorableRunIds.contains(runID),
                          model?.host(runId: runID) == nil {
                    _ = try store.finish(runID: runID, status: .interrupted, message: "上次执行中断；为避免重复操作，请先查看原对话，再手动重试。")
                }
            } catch {
                didReconcile = false
                lastError = "暂时无法确认上次运行状态，已保留任务：\(error.localizedDescription)"
            }
        }
    }

    private func readyChatViewModel() async -> ChatViewModel? {
        if let chatViewModel { return chatViewModel }
        if let model = await IOSChatBackgroundGenerationCoordinator.shared.prepareHeadlessChatViewModelForWatch() {
            attach(chatViewModel: model)
        }
        return chatViewModel
    }

    private func cancelOwnedRun(_ runID: String, interrupted: Bool = false) {
        if let cancelOverride { cancelOverride(runID) }
        else { _ = chatViewModel?.cancelWakeRun(runID: runID, interrupted: interrupted) }
    }

    private func handleSystemTask(_ task: BGTask) {
        let operation = Task { @MainActor in
            task.setTaskCompleted(success: await performBackgroundWake())
        }
        task.expirationHandler = { operation.cancel() }
    }

    func performBackgroundWake() async -> Bool {
        systemExecutionCount += 1
        defer { systemExecutionCount -= 1 }
        // Transfer existing hosts before the first suspension so their shorter
        // UIKit lease cannot expire while the system window is being prepared.
        for task in store.tasks where task.status == .running {
            if let runID = task.executionRunID {
                _ = chatViewModel?.adoptWakeRunBackgroundExecution(runID: runID)
            }
        }
        let report = await runDueTasks()
        // A Shortcut may already be preparing a wake when iOS grants this
        // assertion. Adopt that same queue owner instead of ending the window
        // as soon as the second trigger reports "already processing".
        while isDraining && !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        let ownedRunIDs = Set(report.runIDs).union(store.tasks.compactMap {
            $0.status == .running ? $0.executionRunID : nil
        })
        for runID in ownedRunIDs {
            _ = chatViewModel?.adoptWakeRunBackgroundExecution(runID: runID)
        }
        // Hold execution through the durable result and notification callback.
        while !Task.isCancelled && ownedRunIDs.contains(where: { runID in
            settlingRunIDs.contains(runID)
                || store.tasks.contains { $0.executionRunID == runID && $0.status == .running }
        }) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        if Task.isCancelled {
            for runID in ownedRunIDs {
                guard store.tasks.contains(where: { $0.executionRunID == runID && $0.status == .running }) else { continue }
                if preparingRunID == runID { preparation?.cancel() }
                cancelOwnedRun(runID, interrupted: true)
                do { _ = try store.finish(runID: runID, status: .interrupted, message: "系统后台时间已结束，请查看原对话后重试。") }
                catch { lastError = error.localizedDescription }
            }
        }
        return !Task.isCancelled && report.failedCount == 0
    }
}
