import Foundation
import Observation
import Combine
import UIKit
@preconcurrency import Shared

/// A display projection, never a task owner. Execution identity is deliberately
/// separate from the child thread / task identity and its original creation date.
struct IOSSubAgentActivity: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let taskId: String
    var title: String
    var avatarIdentity: String
    var sourceConversationId: String?
    var status: IOSAdvancedTaskStatus
    var startedAt: Date
    var endedAt: Date?
    var statusDetail: String? = nil

    var statusTitle: String { statusDetail ?? status.title }
    var canDismiss: Bool { status.isTerminal }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }
}

extension Notification.Name {
    static let amberSubAgentRunsDidChange = Notification.Name("app.amber.ios.subAgentRunsDidChange")
}

enum IOSSubAgentAutoDismissDelay: Int, CaseIterable, Identifiable {
    case never = 0
    case after15Seconds = 15
    case after30Seconds = 30
    case after1Minute = 60

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .never: "不自动收起"
        case .after15Seconds: "15 秒"
        case .after30Seconds: "30 秒"
        case .after1Minute: "1 分钟"
        }
    }
}

/// App-owned observation continues while any individual chat is off screen.
/// Only display state is persisted here; dismissing cannot mutate the task,
/// transcript, durable ledger, scheduler, or result mailbox.
@MainActor
@Observable
final class IOSSubAgentActivityStore {
    static let shared: IOSSubAgentActivityStore = {
        let launch = Date()
        return IOSSubAgentActivityStore(tasks: .shared, launchedAt: launch)
    }()
    private static let database = IosDatabaseFactory.shared.createDatabase()

    private(set) var items: [IOSSubAgentActivity] = []
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: storageKey + ".enabled")
        }
    }
    var autoDismissDelay: IOSSubAgentAutoDismissDelay {
        didSet {
            guard oldValue != autoDismissDelay else { return }
            defaults.set(autoDismissDelay.rawValue, forKey: storageKey + ".autoDismissSeconds")
            rescheduleAutoDismiss()
        }
    }
    @ObservationIgnored private let tasks: IOSAdvancedTaskStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let launchedAt: Date
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let loadRuns: (@MainActor () async throws -> [IOSSubAgentActivity])?
    @ObservationIgnored private var retained: [String: IOSSubAgentActivity]
    @ObservationIgnored private var dismissed: Set<String>
    @ObservationIgnored private var verifiedLiveIDs: Set<String> = []
    @ObservationIgnored private var latestExecutions: [String: IOSSubAgentActivity] = [:]
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var autoDismissTask: Task<Void, Never>?
    @ObservationIgnored private var viewingCounts: [String: Int] = [:]

    private struct DisplayState: Codable {
        var retained: [IOSSubAgentActivity]
        var dismissed: Set<String>
    }

    init(
        tasks: IOSAdvancedTaskStore = .shared,
        defaults: UserDefaults = .standard,
        storageKey: String = "app.amber.ios.subAgentActivity.v1",
        launchedAt: Date = Date(),
        loadRuns: (@MainActor () async throws -> [IOSSubAgentActivity])? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.tasks = tasks
        self.defaults = defaults
        self.storageKey = storageKey
        self.launchedAt = launchedAt
        self.loadRuns = loadRuns
        self.now = now
        isEnabled = defaults.object(forKey: storageKey + ".enabled") as? Bool ?? true
        autoDismissDelay = (defaults.object(forKey: storageKey + ".autoDismissSeconds") as? Int)
            .flatMap(IOSSubAgentAutoDismissDelay.init(rawValue:)) ?? .after30Seconds
        let saved = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(DisplayState.self, from: $0)
        }
        retained = Dictionary((saved?.retained ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        dismissed = saved?.dismissed ?? []
        // Retained terminals are intentional. Cached active rows must wait for
        // startup recovery and a fresh authoritative read before becoming visible.
        items = Self.sorted(retained.values.filter(\.canDismiss))
        rescheduleAutoDismiss()
    }

    deinit { autoDismissTask?.cancel() }

    /// Called after AppShell's existing durable recovery, not from ChatView.task.
    func start() {
        guard !started else { return }
        started = true
        for name in [Notification.Name.amberSubAgentRunsDidChange,
                     .amberChatBackgroundJobStateDidChange, .amberChatBackgroundJobDidTerminate,
                     UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rescheduleAutoDismiss()
                    self?.requestRefresh()
                }
            }.store(in: &subscriptions)
        }
        observeTasks()
        requestRefresh()
    }

    private func observeTasks() {
        withObservationTracking {
            _ = tasks.tasks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeTasks()
                self.requestRefresh()
            }
        }
    }

    func requestRefresh() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // One reader at a time: an older asynchronous query cannot finish
            // after a newer one and repaint the current execution.
            while self.needsRefresh {
                self.needsRefresh = false
                await self.refresh()
            }
            self.refreshTask = nil
        }
    }

    func refresh() async {
        do {
            let durable: [IOSSubAgentActivity]
            if let loadRuns {
                durable = try await loadRuns()
            } else {
                durable = try await Self.loadDurableActivities(knownActivities: Array(retained.values))
            }
            reconcile(durable + tasks.tasks.compactMap(Self.activity))
        } catch {
            // Keep the last verified durable state on a read failure. Native
            // task updates still work; an I/O error must not invent a terminal.
            reconcile(items.filter { $0.taskId.hasPrefix("thread:") } + tasks.tasks.compactMap(Self.activity))
        }
    }

    func dismiss(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), item.canDismiss else { return }
        dismissFinished(ids: [id])
        rescheduleAutoDismiss()
    }

    func dismissAllFinished() {
        dismissFinished(ids: Set(items.filter(\.canDismiss).map(\.id)))
        rescheduleAutoDismiss()
    }

    private func dismissFinished(ids: Set<String>) {
        let finished = ids.filter { retained[$0]?.canDismiss == true }
        guard !finished.isEmpty else { return }
        dismissed.formUnion(finished)
        for id in finished { retained.removeValue(forKey: id) }
        items.removeAll { finished.contains($0.id) }
        persist()
    }

    func beginViewing(_ id: String) {
        viewingCounts[id, default: 0] += 1
        rescheduleAutoDismiss()
    }

    func endViewing(_ id: String) {
        let count = viewingCounts[id, default: 0]
        if count > 1 { viewingCounts[id] = count - 1 }
        else { viewingCounts.removeValue(forKey: id) }
        rescheduleAutoDismiss()
    }

    /// One app-owned wakeup for the nearest deadline. No per-second UI state
    /// publication, no dependency on the selected conversation or chat view.
    func rescheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard autoDismissDelay != .never else { return }
        let current = now()
        let interval = TimeInterval(autoDismissDelay.rawValue)
        let deadlines = retained.values.compactMap { item -> (String, Date)? in
            guard item.canDismiss, viewingCounts[item.id, default: 0] == 0,
                  let end = item.endedAt else { return nil }
            return (item.id, end.addingTimeInterval(interval))
        }
        dismissFinished(ids: Set(deadlines.filter { $0.1 <= current }.map(\.0)))
        guard let next = deadlines.map(\.1).filter({ $0 > current }).min() else { return }
        let delay = next.timeIntervalSince(current)
        autoDismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.rescheduleAutoDismiss()
        }
    }

    func taskRecord(for activity: IOSSubAgentActivity) -> IOSAdvancedTaskRecord? {
        guard activity.taskId.hasPrefix("task:"),
              let record = tasks.task(id: String(activity.taskId.dropFirst("task:".count))),
              Self.activity(record)?.id == activity.id else { return nil }
        return record
    }

    /// All candidates use per-execution timestamps, including the very first
    /// observation of a task that completed between two notifications.
    func reconcile(_ candidates: [IOSSubAgentActivity]) {
        for candidate in Array(retained.values) + candidates {
            if let previous = latestExecutions[candidate.taskId], Self.isNewer(previous, than: candidate) { continue }
            latestExecutions[candidate.taskId] = candidate
        }
        for var candidate in candidates {
            if !candidate.canDismiss, let latest = latestExecutions[candidate.taskId],
               latest.id != candidate.id, Self.isNewer(latest, than: candidate) { continue }
            if let previous = retained[candidate.id], previous.canDismiss {
                // Terminal is absorbing for this execution. A delayed RUNNING
                // snapshot or a later log write cannot restart its clock.
                continue
            }
            guard !dismissed.contains(candidate.id) else { continue }
            let isNew = candidate.startedAt >= launchedAt
                || (candidate.endedAt.map { $0 >= launchedAt } ?? false)
            guard !candidate.canDismiss || isNew || retained[candidate.id] != nil else { continue }
            if candidate.canDismiss, candidate.endedAt == nil { candidate.endedAt = now() }
            retained[candidate.id] = candidate
            verifiedLiveIDs.insert(candidate.id)
        }
        // A newer activation supersedes a stale live owner, but prior terminal
        // executions stay available until manual or scheduled dismissal.
        retained = retained.filter { _, value in
            guard !value.canDismiss, let latest = latestExecutions[value.taskId] else { return true }
            return latest.id == value.id || !Self.isNewer(latest, than: value)
        }
        let next = Self.sorted(retained.values.filter {
            $0.canDismiss || verifiedLiveIDs.contains($0.id)
        })
        if items != next { items = next }
        persist()
        rescheduleAutoDismiss()
    }

    private static func isNewer(_ lhs: IOSSubAgentActivity, than rhs: IOSSubAgentActivity) -> Bool {
        lhs.startedAt > rhs.startedAt || (lhs.startedAt == rhs.startedAt && lhs.id > rhs.id)
    }

    private static func sorted(_ values: some Sequence<IOSSubAgentActivity>) -> [IOSSubAgentActivity] {
        values.sorted {
            if $0.canDismiss != $1.canDismiss { return !$0.canDismiss }
            return isNewer($0, than: $1)
        }
    }

    private func persist() {
        let value = DisplayState(retained: Array(retained.values), dismissed: dismissed)
        if let data = try? JSONEncoder().encode(value), defaults.data(forKey: storageKey) != data {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func activity(_ task: IOSAdvancedTaskRecord) -> IOSSubAgentActivity? {
        guard task.kind == .subAgent else { return nil }
        let execution = task.metadata["execution_id"] ?? task.id
        let start = task.metadata["execution_started_at"].flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) } ?? task.createdAt
        let end = task.metadata["execution_finished_at"].flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        // The legacy task title includes objective text. Only the real role /
        // task name belongs in this cross-conversation presentation.
        let name = task.metadata["role_name"] ?? task.roleId ?? "子代理"
        return IOSSubAgentActivity(
            id: "task:\(task.id):\(execution)", taskId: "task:\(task.id)", title: name,
            avatarIdentity: "dynamic:\(name.lowercased())",
            sourceConversationId: task.metadata["source_conversation_id"], status: task.status,
            startedAt: start, endedAt: task.status.isTerminal ? (end ?? task.updatedAt) : nil
        )
    }

    private struct Edge: Sendable {
        let child: String
        let parent: String
        let name: String
    }

    static func loadDurableActivities(knownActivities: [IOSSubAgentActivity] = []) async throws -> [IOSSubAgentActivity] {
        let db = database
        let edges: [Edge] = try await withCheckedThrowingContinuation { continuation in
            db.threadEdgeDao().allEdges { @Sendable values, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (values ?? []).map {
                    Edge(child: $0.childThreadId.lowercased(), parent: $0.parentThreadId,
                         name: $0.nickname ?? $0.agentPath.split(separator: "/").last.map(String.init) ?? "子代理")
                })
            }
        }
        var byChild = Dictionary(edges.map { ($0.child, $0) }, uniquingKeysWith: { _, last in last })
        // A deleted source can remove its edge before the child publishes its
        // terminal. Keep the already-observed identity, never recreate a thread.
        for known in knownActivities where known.taskId.hasPrefix("thread:") {
            let child = String(known.taskId.dropFirst("thread:".count))
            if byChild[child] == nil, let source = known.sourceConversationId {
                byChild[child] = Edge(child: child, parent: source, name: known.title)
            }
        }
        let lookup = byChild
        guard !lookup.isEmpty else { return [] }
        let activities: [IOSSubAgentActivity] = try await withCheckedThrowingContinuation { continuation in
            db.agentRuntimeDao().listAllRuns { @Sendable values, error in
                if let error { continuation.resume(throwing: error); return }
                let activities = (values ?? []).compactMap { run -> IOSSubAgentActivity? in
                    guard IOSDurableRunStore.Descriptor.chatRecoveryAliases.contains(run.agentDescriptorId),
                          let conversationId = run.conversationId?.lowercased(),
                          let edge = lookup[conversationId] else { return nil }
                    let state = durableStatus(run.status, reason: run.terminalReason ?? run.interruptedReason)
                    return IOSSubAgentActivity(
                        id: "run:\(run.runId)", taskId: "thread:\(conversationId)", title: edge.name,
                        avatarIdentity: "dynamic:\(edge.name.lowercased())", sourceConversationId: edge.parent,
                        status: state.0, startedAt: Date(timeIntervalSince1970: Double(run.startedAt) / 1_000),
                        endedAt: run.finishedAt.map { Date(timeIntervalSince1970: Double($0.int64Value) / 1_000) },
                        statusDetail: state.1
                    )
                }
                continuation.resume(returning: activities)
            }
        }
        return activities.map { activity in
            guard activity.status == .running else { return activity }
            let runId = String(activity.id.dropFirst("run:".count))
            let live = IOSChatBackgroundGenerationCoordinator.shared.subAgentExecutionState(runId: runId)
            var resolved = activity
            let state = durableStatus(live ?? "resumable", reason: nil)
            resolved.status = state.0
            resolved.statusDetail = state.1
            return resolved
        }
    }

    nonisolated static func durableStatus(_ raw: String, reason: String?) -> (IOSAdvancedTaskStatus, String?) {
        switch raw.lowercased() {
        case "created", "queued": (.queued, nil)
        case "running": (.running, nil)
        case "waiting_user", "awaiting_permission": (.approvalRequired, "等待审批")
        case "waiting_external": (.queued, "等待外部结果")
        case "resumable", "recovery_pending": (.queued, "等待恢复")
        case "outcome_unknown": (.queued, "结果待确认")
        case "completed": (.completed, nil)
        case "failed": (.failed, nil)
        case "cancelled", "canceled": (.cancelled, nil)
        case "timed_out": (.timedOut, nil)
        case "interrupted": (.interrupted, nil)
        default: (.queued, "状态待确认")
        }
    }
}
