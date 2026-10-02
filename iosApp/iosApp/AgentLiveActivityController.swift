@preconcurrency import ActivityKit
import Foundation
import UIKit

/// 终态停留期间向系统申请的后台时间；到期或停留结束都只释放一次。
/// 到期时交给 `onExpire` 收尾，由收尾在 end 落地后释放；没有收尾时直接释放。
@MainActor
private final class LingerBackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    var onExpire: (() -> Void)?

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "AmberActivityTerminalLinger") { [weak self] in
            MainActor.assumeIsolated {
                // 先释放会让 App 可能在 end 落地前就被挂起，岛上一直停在终态。
                if let onExpire = self?.onExpire {
                    onExpire()
                } else {
                    self?.finish()
                }
            }
        }
    }

    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

struct AgentActivityOwnershipCandidate: Equatable {
    let id: String
    let runId: String
    let updatedAt: Date
}

enum AgentActivityOwnershipPolicy {
    static func retainedActivityIDs(
        from candidates: [AgentActivityOwnershipCandidate],
        ownedRunIds: Set<String>
    ) -> Set<String> {
        var newestByRunId: [String: AgentActivityOwnershipCandidate] = [:]
        for candidate in candidates where ownedRunIds.contains(candidate.runId) {
            if let current = newestByRunId[candidate.runId],
               current.updatedAt >= candidate.updatedAt {
                continue
            }
            newestByRunId[candidate.runId] = candidate
        }
        return Set(newestByRunId.values.map(\.id))
    }
}

@MainActor
final class AgentLiveActivityController {
    static let shared = AgentLiveActivityController()

    /// Bound handle to a single system Live Activity card. Production wraps a
    /// real `Activity<AgentActivityAttributes>` (see `wrap(_:)`); tests
    /// substitute a fake handle so start/update/end sequencing can be
    /// exercised without real ActivityKit or a foregrounded app (ActivityKit's
    /// `Activity.request` itself requires foreground, which is what gated the
    /// pre-existing `AgentActivityDeepLinkTests` pending-start tests).
    struct SystemCardHandle {
        let id: String
        let activityState: () -> ActivityState
        let currentPresentation: () -> AgentActivityPresentation
        let currentUpdatedAt: () -> Date
        let performUpdate: (ActivityContent<AgentActivityAttributes.ContentState>) async -> Void
        let performEnd: (AgentActivityPresentation, TimeInterval) async -> Void
    }

    private struct OwnedActivity {
        let runId: String
        let conversationId: String?
        let card: SystemCardHandle
        var lastPresentation: AgentActivityPresentation
        var lastUpdateAt: Date
        var stepHistory: [AgentActivityStep]

        init(
            runId: String,
            conversationId: String?,
            card: SystemCardHandle,
            lastPresentation: AgentActivityPresentation,
            lastUpdateAt: Date
        ) {
            self.runId = runId
            self.conversationId = conversationId
            self.card = card
            self.lastPresentation = lastPresentation
            self.lastUpdateAt = lastUpdateAt
            // 重启/接管已有卡片时沿用卡片上已显示的历史，避免下一次更新时"缩水"。
            self.stepHistory = lastPresentation.recentSteps ?? []
        }
    }

    /// 完成/失败后仍停留在灵动岛上的卡片，按 card id 记录，便于被新任务或关闭开关提前收起。
    private struct LingeringEnd {
        let card: SystemCardHandle
        let presentation: AgentActivityPresentation
        let dismissalDelay: TimeInterval
        let task: Task<Void, Never>
        let backgroundTime: LingerBackgroundTime
    }

    /// 起步意图在系统请求在途期间被撤销（`end`/`stopCurrent`）时记录的终态：
    /// 请求落地后不再展示新卡片，而是用这份终态立即结束它。
    private struct PendingRevocation {
        let presentation: AgentActivityPresentation
        let dismissalDelay: TimeInterval?
    }

    /// 系统 Activity 请求（授权查询 + 枚举 + request 都是同步 IPC，首轮可达数百
    /// 毫秒）在后台线程执行，不再用人为延迟给上屏动画让路。这段时间里，请求
    /// 视为“在途”：`update` 只刷新待落地的展示；`end`/`stopCurrent` 记录撤销
    /// 终态而不等待。请求落地后（见 `resolvePendingStart`）按撤销与否二选一
    /// 收尾。
    private struct PendingStart {
        let conversationId: String?
        let conversationTitle: String?
        let deepReadTaskId: String?
        var presentation: AgentActivityPresentation
        var revocation: PendingRevocation?
    }

    struct ActivitySystemSnapshot {
        let enabled: Bool
        let activities: [Activity<AgentActivityAttributes>]
    }

    /// 系统快照（授权查询 + 现有 activities 枚举）注入点。生产默认值
    /// `defaultFetchSystemSnapshot` 与原实现一致（在后台线程执行）；测试注入可手动
    /// 控制完成时机的替身，不依赖真实 ActivityKit 授权状态或前台门控。
    typealias SystemSnapshotFetcher = () async -> ActivitySystemSnapshot
    /// 发起系统 request 注入点。生产默认值 `defaultRequestSystemCard` 与原实现一致
    /// （后台线程 `Activity.request`），返回的 `SystemCardHandle` 把后续“结束/更新
    /// 系统卡片”也一并绑定好（见 `wrap(_:)`），测试替身直接构造不触达 ActivityKit
    /// 的 handle。
    typealias SystemCardRequester = (
        _ runId: String,
        _ conversationId: String?,
        _ conversationTitle: String?,
        _ deepReadTaskId: String?,
        _ presentation: AgentActivityPresentation
    ) async -> SystemCardHandle?

    private var activitiesByRunId: [String: OwnedActivity] = [:]
    private var endingActivityIDs: Set<String> = []
    private var pendingStarts: [String: PendingStart] = [:]
    private let fetchSystemSnapshot: SystemSnapshotFetcher
    private let requestSystemCard: SystemCardRequester
    private let terminalLinger: (TimeInterval) async -> Void
    private let lingerAllowance: @MainActor () -> TimeInterval
    private let heartbeatSleep: (TimeInterval) async -> Void
    private var lingering: [String: LingeringEnd] = [:]
    private var heartbeats: [String: Task<Void, Never>] = [:]
    /// 每张卡最后一次排队的写入。ActivityKit 的 update/end 会并发执行、不保证落地顺序，
    /// 旧状态可能晚到并覆盖新状态（真机上正文写完后仍停在"正在阅读网页"），
    /// 所以同一张卡的写入按调用顺序依次执行。
    private var cardWrites: [String: Task<Void, Never>] = [:]

    /// 单例继续用默认值（真实 ActivityKit 调用）。测试创建独立实例注入替身，
    /// 与 `BackgroundAudioKeepAlive` 同一做法。
    init(
        fetchSystemSnapshot: @escaping SystemSnapshotFetcher = AgentLiveActivityController.defaultFetchSystemSnapshot,
        requestSystemCard: @escaping SystemCardRequester = AgentLiveActivityController.defaultRequestSystemCard,
        terminalLinger: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        lingerAllowance: @escaping @MainActor () -> TimeInterval = AgentLiveActivityController.defaultLingerAllowance,
        heartbeatSleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.terminalLinger = terminalLinger
        self.lingerAllowance = lingerAllowance
        self.heartbeatSleep = heartbeatSleep
        self.fetchSystemSnapshot = fetchSystemSnapshot
        self.requestSystemCard = requestSystemCard
    }

    /// 起步请求视为“在途”，在后台线程完成授权查询 + 枚举 + request 后落地。
    /// 在途期间重复调用只刷新待落地的展示（不会重复发起系统请求）。
    func start(
        runId: String,
        conversationId: String?,
        conversationTitle: String? = nil,
        deepReadTaskId: String? = nil,
        presentation: AgentActivityPresentation
    ) {
        // 新任务开始时，上一张还在展示「完成 / 中断」的卡立即收起，不与新卡并存。
        if !lingering.isEmpty {
            let ended = takeLingering()
            Task { await self.endLingering(ended) }
        }
        if pendingStarts[runId] != nil {
            pendingStarts[runId]?.presentation = presentation
            // 在途期间先撤销再重新 start：以最新意图为准，落地后保留卡片。
            pendingStarts[runId]?.revocation = nil
            return
        }
        // 已有卡片（如审批恢复）只是更新，没有昂贵的 request。
        if activitiesByRunId[runId] != nil {
            Task {
                await update(runId: runId, presentation: presentation, force: true)
            }
            return
        }
        pendingStarts[runId] = PendingStart(
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            deepReadTaskId: deepReadTaskId,
            presentation: presentation,
            revocation: nil
        )
        Task { [weak self] in
            await self?.resolvePendingStart(
                runId: runId,
                conversationId: conversationId,
                conversationTitle: conversationTitle,
                deepReadTaskId: deepReadTaskId
            )
        }
    }

    static let defaultFetchSystemSnapshot: SystemSnapshotFetcher = {
        await Task.detached(priority: .userInitiated) {
            ActivitySystemSnapshot(
                enabled: ActivityAuthorizationInfo().areActivitiesEnabled,
                activities: Activity<AgentActivityAttributes>.activities
            )
        }.value
    }

    static let defaultRequestSystemCard: SystemCardRequester = { runId, conversationId, conversationTitle, deepReadTaskId, presentation in
        let now = Date()
        let attributes = AgentActivityAttributes(
            runId: runId,
            conversationId: conversationId,
            startedAt: now,
            conversationTitle: WatchTaskText.singleLine(conversationTitle, maxLength: 120),
            deepReadTaskId: deepReadTaskId
        )
        let content = AgentLiveActivityController.content(presentation: presentation, now: now)

        do {
            let activity = try await Task.detached(priority: .userInitiated) {
                try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            }.value
            return AgentLiveActivityController.wrap(activity)
        } catch {
            print("[LiveActivity] Failed to start Agent activity: \(error)")
            return nil
        }
    }

    /// 请求落地：先查授权 + 枚举现有卡片（后台线程），必要时发起 request（同样
    /// 后台线程）；随后回到主线程按在途期间是否被撤销收尾。
    private func resolvePendingStart(
        runId: String,
        conversationId: String?,
        conversationTitle: String?,
        deepReadTaskId: String?
    ) async {
        guard let presentationForRequest = pendingStarts[runId]?.presentation else { return }

        let snapshot = await fetchSystemSnapshot()

        guard snapshot.enabled else {
            pendingStarts.removeValue(forKey: runId)
            return
        }

        reconcileExistingActivities(
            for: runId,
            conversationId: conversationId,
            activities: snapshot.activities
        )

        if activitiesByRunId[runId] == nil {
            guard let card = await requestSystemCard(
                runId,
                conversationId,
                conversationTitle,
                deepReadTaskId,
                presentationForRequest
            ) else {
                pendingStarts.removeValue(forKey: runId)
                return
            }
            activitiesByRunId[runId] = OwnedActivity(
                runId: runId,
                conversationId: conversationId,
                card: card,
                lastPresentation: presentationForRequest,
                lastUpdateAt: Date()
            )
        }

        guard let pending = pendingStarts.removeValue(forKey: runId) else { return }

        if let revocation = pending.revocation {
            // `end(runId:presentation:)` 会用 `owned.lastPresentation`（刚落地的卡片）
            // 做 preservingKind，这里不用再对 pending.presentation 做一次。
            await end(
                runId: runId,
                presentation: revocation.presentation,
                dismissalDelay: revocation.dismissalDelay
            )
            return
        }

        // 新建卡片已用 presentationForRequest 初始化；被 reconcile 复用的既有卡片
        // (如审批恢复) 可能带着更早的展示，需要与 pending 期间收到的最新展示比较，
        // 不能只比 presentationForRequest。
        if pending.presentation != activitiesByRunId[runId]?.lastPresentation {
            await update(runId: runId, presentation: pending.presentation, force: true)
        }
    }

    func update(
        runId: String,
        presentation: AgentActivityPresentation,
        force: Bool = false,
        minimumInterval: TimeInterval = 1.5
    ) async {
        if pendingStarts[runId] != nil {
            pendingStarts[runId]?.presentation = presentation
            return
        }
        guard var owned = activitiesByRunId[runId], owned.runId == runId else { return }

        owned.stepHistory = AgentActivityStepHistoryPolicy.history(
            after: owned.lastPresentation,
            current: owned.stepHistory,
            next: presentation
        )
        var presentation = presentation
        if presentation.phase == .running || presentation.phase == .reconnecting {
            presentation.recentSteps = owned.stepHistory.isEmpty ? nil : owned.stepHistory
        }

        let now = Date()
        if !force,
           now.timeIntervalSince(owned.lastUpdateAt) < minimumInterval,
           presentation == owned.lastPresentation {
            return
        }

        owned.lastPresentation = presentation
        owned.lastUpdateAt = now
        activitiesByRunId[runId] = owned
        let content = Self.content(presentation: presentation, now: now)
        await write(owned.card) { await $0.performUpdate(content) }
        if presentation.phase == .running, presentation.stage.isToolStage {
            startToolHeartbeatIfNeeded(runId: runId)
        }
    }

    /// 工具执行期间没有流式输出（终端命令、生图、子代理可能持续数分钟），
    /// 只要 App 仍在执行，就按间隔续期；步骤一变或卡片结束即退出。
    /// App 被挂起时这里不会运行，系统照常把卡片显示为失联。
    private func startToolHeartbeatIfNeeded(runId: String) {
        guard heartbeats[runId] == nil else { return }
        heartbeats[runId] = Task { @MainActor [weak self, heartbeatSleep] in
            while !Task.isCancelled {
                await heartbeatSleep(AgentActivityLifecyclePolicy.progressRefreshInterval)
                guard let self else { return }
                guard let owned = self.activitiesByRunId[runId],
                      owned.lastPresentation.phase == .running,
                      owned.lastPresentation.stage.isToolStage else {
                    self.heartbeats[runId] = nil
                    return
                }
                self.noteProgress(runId: runId)
            }
        }
    }

    /// 流式输出仍在前进时调用，逐 chunk 调用也只是一次字典查找。
    /// 同一步骤里状态不变就不会有更新，系统会在过期时间后把仍在输出的任务显示为失联；
    /// 这里满间隔后原样重发一次，把过期时间往后推。输出一停就不再续期，
    /// 真卡住的任务照常过期。
    func noteProgress(runId: String, now: Date = Date()) {
        guard pendingStarts[runId] == nil,
              var owned = activitiesByRunId[runId],
              owned.lastPresentation.phase == .running,
              now.timeIntervalSince(owned.lastUpdateAt) >= AgentActivityLifecyclePolicy.progressRefreshInterval
        else { return }
        let presentation = owned.lastPresentation
        owned.lastUpdateAt = now
        activitiesByRunId[runId] = owned
        let cardId = owned.card.id
        Task { @MainActor [weak self] in
            // 续期排队期间状态可能已被真实更新替换，迟到的续期不得把旧状态盖回去。
            guard let current = self?.activitiesByRunId[runId],
                  current.card.id == cardId,
                  current.lastPresentation == presentation else { return }
            let content = Self.content(presentation: presentation, now: now)
            await self?.write(current.card) { await $0.performUpdate(content) }
        }
    }

    func refreshLanguage() async {
        let activePresentations = activitiesByRunId.map { ($0.key, $0.value.lastPresentation) }
        for (runId, presentation) in activePresentations {
            await update(
                runId: runId,
                presentation: presentation,
                force: true,
                minimumInterval: 0
            )
        }
    }

    func end(
        runId: String,
        presentation: AgentActivityPresentation,
        dismissalDelay: TimeInterval? = nil
    ) async {
        // 请求在途：系统请求可能仍未返回，这里不阻塞等待，只记录撤销终态；
        // `resolvePendingStart` 落地后会立即用这份终态结束刚创建/复用的卡片。
        if pendingStarts[runId] != nil {
            pendingStarts[runId]?.revocation = PendingRevocation(
                presentation: presentation,
                dismissalDelay: dismissalDelay
            )
            return
        }
        guard let owned = activitiesByRunId[runId], owned.runId == runId else { return }
        guard endingActivityIDs.insert(owned.card.id).inserted else { return }

        var terminalPresentation = presentation.preservingKind(from: owned.lastPresentation)
        let finishedSteps = AgentActivityStepHistoryPolicy.closing(
            last: owned.lastPresentation,
            current: owned.stepHistory
        )
        terminalPresentation.recentSteps = finishedSteps.isEmpty ? nil : finishedSteps
        activitiesByRunId.removeValue(forKey: runId)
        let card = owned.card
        let resolvedDismissalDelay = dismissalDelay
            ?? AgentActivityLifecyclePolicy.lockScreenDismissalDelay(for: terminalPresentation.phase)

        // end 后系统立刻把活动撤出灵动岛：先在岛上展示终态，停留后再 end。
        // 前台时系统不在岛上显示本 App 的活动，不停留；后台时停留不超过剩余后台时间。
        let backgroundTime = LingerBackgroundTime()
        let linger = min(
            AgentActivityLifecyclePolicy.islandLingerDuration(for: terminalPresentation.phase),
            lingerAllowance()
        )
        guard linger >= 1 else {
            let terminal = terminalPresentation
            await write(card) { await $0.performEnd(terminal, resolvedDismissalDelay) }
            endingActivityIDs.remove(card.id)
            backgroundTime.finish()
            return
        }

        // 停留在独立任务里进行，调用方不等待。
        // 先登记再发终态：等待发送期间进来的 start / stopCurrent / 到期都能找到这张卡。
        let cardId = card.id
        let task = Task { @MainActor [weak self, terminalLinger] in
            await terminalLinger(linger)
            guard let self, let entry = self.lingering.removeValue(forKey: cardId) else { return }
            await self.endLingering([entry])
        }
        lingering[cardId] = LingeringEnd(
            card: card,
            presentation: terminalPresentation,
            dismissalDelay: resolvedDismissalDelay,
            task: task,
            backgroundTime: backgroundTime
        )
        // 后台时间提前到期：立即收起，不把终态留在岛上等下次唤醒。
        // 取不到说明已被别处收尾，由那边释放后台时间。
        backgroundTime.onExpire = { [weak self] in
            guard let self, let entry = self.lingering.removeValue(forKey: cardId) else { return }
            Task { await self.endLingering([entry]) }
        }
        let content = Self.content(presentation: terminalPresentation, now: Date())
        await write(card) { await $0.performUpdate(content) }
    }

    /// 同步取走全部停留中的卡片，保证每张只结束一次。
    private func takeLingering() -> [LingeringEnd] {
        let entries = Array(lingering.values)
        lingering.removeAll()
        return entries
    }

    private func write(
        _ card: SystemCardHandle,
        _ operation: @escaping @MainActor (SystemCardHandle) async -> Void
    ) async {
        let previous = cardWrites[card.id]
        let task = Task { @MainActor in
            await previous?.value
            await operation(card)
        }
        cardWrites[card.id] = task
        await task.value
        if cardWrites[card.id] == task {
            cardWrites[card.id] = nil
        }
    }

    private func endLingering(_ entries: [LingeringEnd]) async {
        for entry in entries {
            entry.task.cancel()
            await write(entry.card) { await $0.performEnd(entry.presentation, entry.dismissalDelay) }
            endingActivityIDs.remove(entry.card.id)
            entry.backgroundTime.finish()
        }
    }

    /// 前台为 0；后台取剩余后台时间减去余量，保证在挂起前完成 end。
    static func defaultLingerAllowance() -> TimeInterval {
        let application = UIApplication.shared
        guard application.applicationState != .active else { return 0 }
        return max(0, application.backgroundTimeRemaining - 2)
    }

    func stopCurrent(dismissalDelay: TimeInterval = 1) async {
        // 停留中的卡片按其终态结束一次，下面的系统枚举不再重复结束它们。
        let lingeringEnded = takeLingering()
        let lingeringCardIDs = Set(lingeringEnded.map(\.card.id))
        await endLingering(lingeringEnded)

        // 在途请求同样标记撤销而非直接丢弃：系统请求已经发出，落地后
        // `resolvePendingStart` 需要知道要立即结束这张卡片，而不是误当作
        // 仍然存活继续展示。
        for runId in pendingStarts.keys {
            let kind = pendingStarts[runId]?.presentation.kind ?? .response
            pendingStarts[runId]?.revocation = PendingRevocation(
                presentation: AgentActivityPresentation(
                    kind: kind,
                    phase: .cancelled,
                    stage: .cancelled,
                    action: nil
                ),
                dismissalDelay: dismissalDelay
            )
        }

        let owned = activitiesByRunId
        activitiesByRunId.removeAll()
        let ownedCardIDs = Set(owned.values.map(\.card.id))

        let discovered = Activity<AgentActivityAttributes>.activities
        endingActivityIDs.formUnion(discovered.map(\.id).filter { !lingeringCardIDs.contains($0) })
        endingActivityIDs.formUnion(ownedCardIDs)

        for activity in discovered where !ownedCardIDs.contains(activity.id) && !lingeringCardIDs.contains(activity.id) {
            let kind = owned[activity.attributes.runId]?.lastPresentation.kind
                ?? activity.content.state.presentation.kind
            let cancelledPresentation = AgentActivityPresentation(
                kind: kind,
                phase: .cancelled,
                stage: .cancelled,
                action: nil
            )
            await Self.end(
                activity: activity,
                presentation: cancelledPresentation,
                dismissalDelay: dismissalDelay
            )
            endingActivityIDs.remove(activity.id)
        }

        for entry in owned.values {
            let cancelledPresentation = AgentActivityPresentation(
                kind: entry.lastPresentation.kind,
                phase: .cancelled,
                stage: .cancelled,
                action: nil
            )
            await write(entry.card) { await $0.performEnd(cancelledPresentation, dismissalDelay) }
            endingActivityIDs.remove(entry.card.id)
        }
    }

    func restoreExistingActivity(ownedRunIds: Set<String>) {
        let existing = Activity<AgentActivityAttributes>.activities
        let candidates = existing.filter {
            isAdoptable($0) && AgentActivityLifecyclePolicy.shouldRestore(
                runId: $0.attributes.runId,
                ownedRunIds: ownedRunIds,
                activityState: $0.activityState
            )
        }
        let retainedIDs = AgentActivityOwnershipPolicy.retainedActivityIDs(
            from: candidates.map(Self.ownershipCandidate),
            ownedRunIds: ownedRunIds
        )

        activitiesByRunId = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            guard retainedIDs.contains(candidate.id) else { return nil }
            return (
                candidate.attributes.runId,
                OwnedActivity(
                    runId: candidate.attributes.runId,
                    conversationId: candidate.attributes.conversationId,
                    card: Self.wrap(candidate),
                    lastPresentation: candidate.content.state.presentation,
                    lastUpdateAt: candidate.content.state.updatedAt
                )
            )
        })

        for obsolete in existing where !retainedIDs.contains(obsolete.id) {
            scheduleEnd(activity: obsolete, dismissalDelay: 1)
        }
    }

    @discardableResult
    func adoptExistingActivity(
        runId: String,
        conversationId: String? = nil
    ) -> Bool {
        if let owned = activitiesByRunId[runId],
           isAdoptable(id: owned.card.id, activityState: owned.card.activityState()),
           conversationId == nil || owned.conversationId == conversationId {
            return true
        }

        let candidates = Activity<AgentActivityAttributes>.activities
            .filter({ candidate in
                isAdoptable(candidate) &&
                    candidate.attributes.runId == runId &&
                    (conversationId == nil || candidate.attributes.conversationId == conversationId)
            })
        let retainedIDs = AgentActivityOwnershipPolicy.retainedActivityIDs(
            from: candidates.map(Self.ownershipCandidate),
            ownedRunIds: [runId]
        )
        guard let restored = candidates.first(where: { retainedIDs.contains($0.id) }) else {
            return false
        }

        activitiesByRunId[runId] = OwnedActivity(
            runId: runId,
            conversationId: restored.attributes.conversationId,
            card: Self.wrap(restored),
            lastPresentation: restored.content.state.presentation,
            lastUpdateAt: restored.content.state.updatedAt
        )
        for duplicate in candidates where duplicate.id != restored.id {
            scheduleEnd(activity: duplicate, dismissalDelay: 1)
        }
        return true
    }

    func ownsActivity(runId: String, conversationId: String) -> Bool {
        // 已撤销的在途请求不再代表所有权：请求落地后会立即结束这张卡片。
        if let pending = pendingStarts[runId],
           pending.revocation == nil,
           pending.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame {
            return true
        }
        if let owned = activitiesByRunId[runId],
           !endingActivityIDs.contains(owned.card.id),
           isAdoptable(id: owned.card.id, activityState: owned.card.activityState()),
           owned.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame {
            return true
        }
        return Activity<AgentActivityAttributes>.activities.contains {
            !endingActivityIDs.contains($0.id) &&
                $0.attributes.runId == runId &&
                $0.attributes.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame
        }
    }

    private func reconcileExistingActivities(
        for runId: String,
        conversationId: String?,
        activities: [Activity<AgentActivityAttributes>]
    ) {
        let sameRun = activities.filter {
            isAdoptable($0) && $0.attributes.runId == runId
        }

        var ownedCandidate: AgentActivityOwnershipCandidate?
        if let owned = activitiesByRunId[runId],
           isAdoptable(id: owned.card.id, activityState: owned.card.activityState()),
           !sameRun.contains(where: { $0.id == owned.card.id }) {
            ownedCandidate = AgentActivityOwnershipCandidate(
                id: owned.card.id,
                runId: runId,
                updatedAt: owned.lastUpdateAt
            )
        }

        let matchingConversation = sameRun.filter {
            $0.attributes.conversationId == conversationId
        }
        var candidates = matchingConversation.map(Self.ownershipCandidate)
        if let ownedCandidate, activitiesByRunId[runId]?.conversationId == conversationId {
            candidates.append(ownedCandidate)
        }

        let retainedIDs = AgentActivityOwnershipPolicy.retainedActivityIDs(
            from: candidates,
            ownedRunIds: [runId]
        )

        if let currentOwned = activitiesByRunId[runId], retainedIDs.contains(currentOwned.card.id) {
            // 既有卡片仍是赢家：与 reconcile 时刻的真实系统状态重新对齐
            // lastPresentation/lastUpdateAt（原实现每次都会用刚枚举到的
            // content state 覆盖一次，不只在被替换时）。
            activitiesByRunId[runId] = OwnedActivity(
                runId: runId,
                conversationId: currentOwned.conversationId,
                card: currentOwned.card,
                lastPresentation: currentOwned.card.currentPresentation(),
                lastUpdateAt: currentOwned.card.currentUpdatedAt()
            )
        } else if let restored = matchingConversation.first(where: { retainedIDs.contains($0.id) }) {
            activitiesByRunId[runId] = OwnedActivity(
                runId: runId,
                conversationId: restored.attributes.conversationId,
                card: Self.wrap(restored),
                lastPresentation: restored.content.state.presentation,
                lastUpdateAt: restored.content.state.updatedAt
            )
        } else {
            activitiesByRunId.removeValue(forKey: runId)
        }

        for duplicate in matchingConversation where !retainedIDs.contains(duplicate.id) {
            scheduleEnd(activity: duplicate, dismissalDelay: 1)
        }
        if let currentOwned = activitiesByRunId[runId],
           candidates.contains(where: { $0.id == currentOwned.card.id }),
           !retainedIDs.contains(currentOwned.card.id) {
            scheduleEndOwned(runId: runId, owned: currentOwned, dismissalDelay: 1)
        }
    }

    private func isAdoptable(id: String, activityState: ActivityState) -> Bool {
        guard !endingActivityIDs.contains(id) else { return false }
        return activityState == .active || activityState == .stale
    }

    private func isAdoptable(_ candidate: Activity<AgentActivityAttributes>) -> Bool {
        isAdoptable(id: candidate.id, activityState: candidate.activityState)
    }

    private func scheduleEnd(
        activity: Activity<AgentActivityAttributes>,
        dismissalDelay: TimeInterval
    ) {
        guard endingActivityIDs.insert(activity.id).inserted else { return }
        let runId = activity.attributes.runId
        if activitiesByRunId[runId]?.card.id == activity.id {
            activitiesByRunId.removeValue(forKey: runId)
        }
        let presentation = AgentActivityPresentation(
            kind: activity.content.state.presentation.kind,
            phase: .cancelled,
            stage: .cancelled,
            action: nil
        )
        Task { [weak self] in
            await Self.end(
                activity: activity,
                presentation: presentation,
                dismissalDelay: dismissalDelay
            )
            self?.endingActivityIDs.remove(activity.id)
        }
    }

    /// `scheduleEnd(activity:dismissalDelay:)` 的对应版本，用于一张既有的
    /// `OwnedActivity`（可能是测试替身，没有真实 `Activity` 对象）在 reconcile
    /// 中输给了别的卡片、需要异步收尾的场景。
    private func scheduleEndOwned(
        runId: String,
        owned: OwnedActivity,
        dismissalDelay: TimeInterval
    ) {
        guard endingActivityIDs.insert(owned.card.id).inserted else { return }
        if activitiesByRunId[runId]?.card.id == owned.card.id {
            activitiesByRunId.removeValue(forKey: runId)
        }
        let presentation = AgentActivityPresentation(
            kind: owned.lastPresentation.kind,
            phase: .cancelled,
            stage: .cancelled,
            action: nil
        )
        Task { [weak self] in
            await self?.write(owned.card) { await $0.performEnd(presentation, dismissalDelay) }
            self?.endingActivityIDs.remove(owned.card.id)
        }
    }

    private static func ownershipCandidate(
        _ activity: Activity<AgentActivityAttributes>
    ) -> AgentActivityOwnershipCandidate {
        AgentActivityOwnershipCandidate(
            id: activity.id,
            runId: activity.attributes.runId,
            updatedAt: activity.content.state.updatedAt
        )
    }

    private static func content(
        presentation: AgentActivityPresentation,
        now: Date
    ) -> ActivityContent<AgentActivityAttributes.ContentState> {
        ActivityContent(
            state: .init(
                presentation: presentation,
                updatedAt: now,
                languageCode: IOSAppLanguagePreference.selected()
                    .resolvedLanguage()
                    .rawValue
            ),
            staleDate: AgentActivityLifecyclePolicy.staleDate(
                for: presentation.phase,
                now: now
            ),
            relevanceScore: AgentActivityLifecyclePolicy.relevanceScore(
                for: presentation.phase
            )
        )
    }

    /// 把一个真实 `Activity<AgentActivityAttributes>` 包成 `SystemCardHandle`：
    /// “结束/更新系统卡片”这两步的生产实现都封在这里，行为与重构前直接调用
    /// `activity.update(...)` / `activity.end(...)` 完全一致。
    private static func wrap(_ activity: Activity<AgentActivityAttributes>) -> SystemCardHandle {
        SystemCardHandle(
            id: activity.id,
            activityState: { activity.activityState },
            currentPresentation: { activity.content.state.presentation },
            currentUpdatedAt: { activity.content.state.updatedAt },
            performUpdate: { content in
                await activity.update(content)
            },
            performEnd: { presentation, dismissalDelay in
                let now = Date()
                await activity.end(
                    Self.content(presentation: presentation, now: now),
                    dismissalPolicy: .after(now.addingTimeInterval(dismissalDelay))
                )
            }
        )
    }

    private static func end(
        activity: Activity<AgentActivityAttributes>,
        presentation: AgentActivityPresentation,
        dismissalDelay: TimeInterval
    ) async {
        let now = Date()
        // Ending removes the task from Dynamic Island immediately. The policy
        // below only controls how long its terminal card remains on Lock Screen.
        await activity.end(
            Self.content(presentation: presentation, now: now),
            dismissalPolicy: .after(now.addingTimeInterval(dismissalDelay))
        )
    }
}
