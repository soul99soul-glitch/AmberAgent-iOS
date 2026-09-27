@preconcurrency import ActivityKit
import Foundation
import UIKit

enum IOSExecutionPreferenceKeys {
    static let liveActivity = "app.amber.ios.execution.liveActivity"
    /// 历史音频保活偏好 key。稳定版不声明 audio background mode，因此始终关闭；
    /// 仅保留给明确声明该模式的内部构建读取。
    static let audioKeepAlive = "app.amber.ios.execution.audioKeepAlive"
    /// G7: 前台单轮工具循环上限（默认 24，clamp 24-384）。与
    /// ExecutionSettingsView 的 @AppStorage / SettingsStore 共用同一 key。
    static let chatMaxToolResumeCount = "app.amber.ios.execution.chatMaxToolResumeCount"
    /// Experimental-only optional location background activity. Stable builds
    /// do not declare the location background mode, so the runtime guard keeps
    /// this preference inert there.
    static let backgroundLocationKeepAlive = "app.amber.ios.execution.backgroundLocationKeepAlive"
    /// P3-a: exec 纯求值工具总开关（默认关）。与 ExecutionSettingsView 的
    /// @AppStorage / SettingsStore 共用同一 key。
    static let execJavaScriptEnabled = "app.amber.ios.execution.execJavaScriptEnabled"
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

    private struct OwnedActivity {
        let activity: Activity<AgentActivityAttributes>
        var lastPresentation: AgentActivityPresentation
        var lastUpdateAt: Date
    }

    /// 发送瞬间的系统 Activity 请求（授权查询 + 枚举 + request 都是同步 IPC）
    /// 会与用户消息上屏动画抢主线程：首轮可达数百毫秒。起步因此推迟到上屏
    /// 动画结束后；App 失去前台时立即补做，保证离开 App 前系统卡片已就位。
    private struct PendingStart {
        let conversationId: String?
        let conversationTitle: String?
        var presentation: AgentActivityPresentation
        var task: Task<Void, Never>?
    }

    static let deferredStartDelay: Duration = .milliseconds(500)

    private var activitiesByRunId: [String: OwnedActivity] = [:]
    private var endingActivityIDs: Set<String> = []
    private var pendingStarts: [String: PendingStart] = [:]
    private var resignActiveObserver: NSObjectProtocol?

    private init() {}

    var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 前台新卡片的真实请求延后执行（见 `PendingStart`）。
    /// 延后窗口内的 update 只刷新待起步的展示，end 撤销待起步。
    func start(
        runId: String,
        conversationId: String?,
        conversationTitle: String? = nil,
        presentation: AgentActivityPresentation
    ) {
        if pendingStarts[runId] != nil {
            pendingStarts[runId]?.presentation = presentation
            return
        }
        // 已有卡片（如审批恢复）只是更新，没有昂贵的 request；非前台时没有上屏
        // 动画要让路，且延后可能落到后台导致 request 失败。两者都立即执行。
        if activitiesByRunId[runId] != nil || UIApplication.shared.applicationState != .active {
            startNow(
                runId: runId,
                conversationId: conversationId,
                conversationTitle: conversationTitle,
                presentation: presentation
            )
            return
        }
        installResignActiveObserverIfNeeded()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.deferredStartDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingStart(runId: runId)
        }
        pendingStarts[runId] = PendingStart(
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            presentation: presentation,
            task: task
        )
    }

    /// 失去前台时立即执行所有待起步请求。
    private func flushPendingStarts() {
        for runId in Array(pendingStarts.keys) {
            flushPendingStart(runId: runId)
        }
    }

    private func flushPendingStart(runId: String) {
        guard let pending = pendingStarts.removeValue(forKey: runId) else { return }
        pending.task?.cancel()
        startNow(
            runId: runId,
            conversationId: pending.conversationId,
            conversationTitle: pending.conversationTitle,
            presentation: pending.presentation
        )
    }

    private func cancelPendingStart(runId: String) {
        pendingStarts.removeValue(forKey: runId)?.task?.cancel()
    }

    private func installResignActiveObserverIfNeeded() {
        guard resignActiveObserver == nil else { return }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingStarts()
            }
        }
    }

    private func startNow(
        runId: String,
        conversationId: String?,
        conversationTitle: String?,
        presentation: AgentActivityPresentation
    ) {
        guard activitiesEnabled else { return }
        reconcileExistingActivities(
            for: runId,
            conversationId: conversationId
        )

        if activitiesByRunId[runId] != nil {
            Task {
                await update(runId: runId, presentation: presentation, force: true)
            }
            return
        }

        requestActivity(
            runId: runId,
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            presentation: presentation
        )
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
        guard var owned = activitiesByRunId[runId],
              owned.activity.attributes.runId == runId else { return }

        let now = Date()
        if !force,
           now.timeIntervalSince(owned.lastUpdateAt) < minimumInterval,
           presentation == owned.lastPresentation {
            return
        }

        owned.lastPresentation = presentation
        owned.lastUpdateAt = now
        activitiesByRunId[runId] = owned
        await owned.activity.update(Self.content(presentation: presentation, now: now))
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
        // 延后窗口内即终态：撤销待起步，不再为已结束的 run 请求系统卡片。
        cancelPendingStart(runId: runId)
        guard let owned = activitiesByRunId[runId],
              owned.activity.attributes.runId == runId else { return }
        guard endingActivityIDs.insert(owned.activity.id).inserted else { return }

        let terminalPresentation = presentation.preservingKind(from: owned.lastPresentation)
        activitiesByRunId.removeValue(forKey: runId)

        await Self.end(
            activity: owned.activity,
            presentation: terminalPresentation,
            dismissalDelay: dismissalDelay ?? AgentActivityLifecyclePolicy
                .lockScreenDismissalDelay(for: terminalPresentation.phase)
        )
        endingActivityIDs.remove(owned.activity.id)
    }

    func stopCurrent(dismissalDelay: TimeInterval = 1) async {
        pendingStarts.values.forEach { $0.task?.cancel() }
        pendingStarts.removeAll()
        var activitiesToEnd = Activity<AgentActivityAttributes>.activities
        for owned in activitiesByRunId.values where
            !activitiesToEnd.contains(where: { $0.id == owned.activity.id }) {
            activitiesToEnd.append(owned.activity)
        }

        endingActivityIDs.formUnion(activitiesToEnd.map(\.id))
        let ownedActivities = activitiesByRunId
        activitiesByRunId.removeAll()

        for activity in activitiesToEnd {
            let lastPresentation = ownedActivities[activity.attributes.runId]?.lastPresentation
                ?? activity.content.state.presentation
            let cancelledPresentation = AgentActivityPresentation(
                kind: lastPresentation.kind,
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
                    activity: candidate,
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
           isAdoptable(owned.activity),
           conversationId == nil || owned.activity.attributes.conversationId == conversationId {
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
            activity: restored,
            lastPresentation: restored.content.state.presentation,
            lastUpdateAt: restored.content.state.updatedAt
        )
        for duplicate in candidates where duplicate.id != restored.id {
            scheduleEnd(activity: duplicate, dismissalDelay: 1)
        }
        return true
    }

    func ownsActivity(runId: String, conversationId: String) -> Bool {
        if pendingStarts[runId]?.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame {
            return true
        }
        if let owned = activitiesByRunId[runId],
           !endingActivityIDs.contains(owned.activity.id),
           isAdoptable(owned.activity),
           owned.activity.attributes.conversationId?.caseInsensitiveCompare(conversationId)
            == .orderedSame {
            return true
        }
        return Activity<AgentActivityAttributes>.activities.contains {
            !endingActivityIDs.contains($0.id) &&
                $0.attributes.runId == runId &&
                $0.attributes.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame
        }
    }

    private func requestActivity(
        runId: String,
        conversationId: String?,
        conversationTitle: String?,
        presentation: AgentActivityPresentation
    ) {
        let now = Date()
        let attributes = AgentActivityAttributes(
            runId: runId,
            conversationId: conversationId,
            startedAt: now,
            conversationTitle: WatchTaskText.singleLine(conversationTitle, maxLength: 120)
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: Self.content(presentation: presentation, now: now),
                pushType: nil
            )
            activitiesByRunId[runId] = OwnedActivity(
                activity: activity,
                lastPresentation: presentation,
                lastUpdateAt: now
            )
        } catch {
            print("[LiveActivity] Failed to start Agent activity: \(error)")
            activitiesByRunId.removeValue(forKey: runId)
        }
    }

    private func reconcileExistingActivities(
        for runId: String,
        conversationId: String?
    ) {
        var sameRun = Activity<AgentActivityAttributes>.activities.filter {
            isAdoptable($0) && $0.attributes.runId == runId
        }
        if let owned = activitiesByRunId[runId],
           isAdoptable(owned.activity),
           !sameRun.contains(where: { $0.id == owned.activity.id }) {
            sameRun.append(owned.activity)
        }

        let matchingConversation = sameRun.filter {
            $0.attributes.conversationId == conversationId
        }
        let retainedIDs = AgentActivityOwnershipPolicy.retainedActivityIDs(
            from: matchingConversation.map(Self.ownershipCandidate),
            ownedRunIds: [runId]
        )
        if let restored = matchingConversation.first(where: { retainedIDs.contains($0.id) }) {
            activitiesByRunId[runId] = OwnedActivity(
                activity: restored,
                lastPresentation: restored.content.state.presentation,
                lastUpdateAt: restored.content.state.updatedAt
            )
        } else {
            activitiesByRunId.removeValue(forKey: runId)
        }

        for duplicate in sameRun where !retainedIDs.contains(duplicate.id) {
            scheduleEnd(activity: duplicate, dismissalDelay: 1)
        }
    }

    private func isAdoptable(_ candidate: Activity<AgentActivityAttributes>) -> Bool {
        guard !endingActivityIDs.contains(candidate.id) else { return false }
        return candidate.activityState == .active || candidate.activityState == .stale
    }

    private func scheduleEnd(
        activity: Activity<AgentActivityAttributes>,
        dismissalDelay: TimeInterval
    ) {
        guard endingActivityIDs.insert(activity.id).inserted else { return }
        let runId = activity.attributes.runId
        if activitiesByRunId[runId]?.activity.id == activity.id {
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
