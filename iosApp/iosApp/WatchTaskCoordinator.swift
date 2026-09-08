import Foundation
import UIKit
@preconcurrency import Shared

extension Notification.Name {
    static let amberWatchOpenTask = Notification.Name("app.amber.ios.watch.openTask")
}

struct WatchTaskReconnectProjection: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let startedAt: Int64
}

/// Value-only copy used to cross the asynchronous Kotlin callback boundary.
/// AgentRunEntity is a generated reference type and must stay inside the
/// callback that receives it.
private struct WatchDurableRunProjection: Sendable {
    let runId: String
    let conversationId: String?
    let descriptorID: String
    let status: String
    let startedAt: Int64
    let finishedAt: Int64?
}

/// The smallest composition needed when Watch wakes iOS before AppShell exists.
/// Production supplies this from the background coordinator; tests can inject
/// an isolated VM/store without touching its singleton.
struct WatchTaskColdStartContext {
    let chatViewModel: ChatViewModel
    let sharedSettings: IOSSharedSettingsStore?
    let reconnecting: [WatchTaskReconnectProjection]

    init(
        chatViewModel: ChatViewModel,
        sharedSettings: IOSSharedSettingsStore? = nil,
        reconnecting: [WatchTaskReconnectProjection] = []
    ) {
        self.chatViewModel = chatViewModel
        self.sharedSettings = sharedSettings
        self.reconnecting = reconnecting
    }
}

typealias WatchTaskColdStartPreparer = @MainActor () async -> WatchTaskColdStartContext?
typealias WatchLibrarySnapshotProvider = @MainActor (IOSSharedSettingsStore, IOSConversationStore?, String?) async -> WatchLibrarySnapshot

/// Owns the current watch-facing task snapshot and translates Watch intents
/// into ChatViewModel / ChatKernelRunHost actions.
@MainActor
final class WatchTaskCoordinator: WatchTaskActionHandling {
    static let shared = WatchTaskCoordinator(coldStartPreparer: {
        await WatchTaskCoordinator.productionColdStartPreparer()
    })

    private weak var chatViewModel: ChatViewModel?
    /// Cold-start Watch runs may outlive AppShell's later foreground VM.
    /// The background coordinator retains this headless owner; this weak handle
    /// keeps approvals and cancellation routed to the owner that started them.
    private weak var headlessChatViewModel: ChatViewModel?
    private let bridge: WatchConnectivityBridge
    private let companionService: IOSWatchCompanionService
    private let deepLinkInbox: IOSDeepLinkInbox
    private let coldStartPreparer: WatchTaskColdStartPreparer?
    private let librarySnapshotProvider: WatchLibrarySnapshotProvider
    private let attachmentWaitNanoseconds: UInt64
    private var sharedSettings: IOSSharedSettingsStore?
    private weak var conversationStore: IOSConversationStore?
    private var librarySnapshot: WatchLibrarySnapshot?
    private var libraryRefreshRevision: UInt64 = 0
    private var didRecoverTerminalActivities = false
    private var currentRunId: String?
    private var currentConversationId: String?
    private var currentPresentation: AgentActivityPresentation?
    private var currentDecision: WatchDecision?
    private var currentApprovalPrompt: ChatToolApprovalPrompt?
    private var currentSummary: String?
    private var pendingAskUser: WatchAskUserRequest?
    /// Runs whose side-effect outcome is durable but not authoritative. The
    /// set is intentionally local to the Watch projection: it is a guard
    /// against cancel/retry intents, while the shared run/ledger stores remain
    /// the source of truth for reconciliation on iPhone.
    private var outcomeUnknownRunIds = Set<String>()
    private let durableRunStore: IOSDurableRunStore
    private let toolLedger: IOSAgentRunLedger
    private var isAttached = false
    private var attachmentWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var runGeneration: [String: UInt64] = [:]
    private var runStartedAt: [String: Int64] = [:]
    private var nextRunGeneration: UInt64 = 0
    private struct ProcessedAction {
        let request: WatchTaskActionRequest
        let result: WatchTaskActionResult
    }
    private struct InFlightAction {
        let request: WatchTaskActionRequest
        let task: Task<WatchTaskActionResult, Never>
    }
    private var processedActions: [String: ProcessedAction] = [:]
    private var processedActionOrder: [String] = []
    private var inFlightActions: [String: InFlightAction] = [:]

    private var resolvedLanguageCode: String {
        IOSAppLanguagePreference.selected().resolvedLanguage().rawValue
    }

    init(
        bridge: WatchConnectivityBridge = .shared,
        companionService: IOSWatchCompanionService = .shared,
        deepLinkInbox: IOSDeepLinkInbox = .shared,
        coldStartPreparer: WatchTaskColdStartPreparer? = nil,
        attachmentWaitNanoseconds: UInt64 = 5_000_000_000,
        librarySnapshotProvider: WatchLibrarySnapshotProvider? = nil,
        agentRuntimeDao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
    ) {
        self.bridge = bridge
        self.companionService = companionService
        self.deepLinkInbox = deepLinkInbox
        self.coldStartPreparer = coldStartPreparer
        self.attachmentWaitNanoseconds = attachmentWaitNanoseconds
        self.librarySnapshotProvider = librarySnapshotProvider ?? { settings, store, message in
            await companionService.makeLibrarySnapshot(
                sharedSettings: settings, conversationStore: store, configurationMessage: message
            )
        }
        self.durableRunStore = IOSDurableRunStore(dao: agentRuntimeDao)
        self.toolLedger = IOSAgentRunLedger(dao: agentRuntimeDao)
    }

    private static func productionColdStartPreparer() async -> WatchTaskColdStartContext? {
        let background = IOSChatBackgroundGenerationCoordinator.shared
        guard let chatViewModel = await background.prepareHeadlessChatViewModelForWatch() else {
            return nil
        }
        return WatchTaskColdStartContext(
            chatViewModel: chatViewModel,
            sharedSettings: background.headlessSharedSettingsForWatch,
            reconnecting: background.reconnectingWatchProjections
        )
    }

    func attach(
        chatViewModel: ChatViewModel,
        sharedSettings: IOSSharedSettingsStore? = nil,
        reconnecting: [WatchTaskReconnectProjection] = [],
        isHeadlessOwner: Bool = false
    ) {
        if isHeadlessOwner {
            headlessChatViewModel = chatViewModel
        }
        self.chatViewModel = chatViewModel
        self.sharedSettings = sharedSettings ?? self.sharedSettings ?? IOSSharedSettingsStore()
        self.conversationStore = chatViewModel.conversationStore
        isAttached = true
        let waiters = attachmentWaiters.values
        attachmentWaiters.removeAll()
        waiters.forEach { $0.resume() }
        bridge.configure(actionHandler: self)
        bridge.activateIfNeeded()
        for projection in reconnecting.sorted(by: { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.runId < rhs.runId }
            return lhs.startedAt < rhs.startedAt
        }) {
            registerRun(runId: projection.runId, startedAt: projection.startedAt)
        }
        if currentPresentation == nil {
            let restoredPhoneOnlyDecision = WatchTaskSnapshotBuilder.isPhoneOnlyDecision(
                bridge.latestSnapshot.decision
            )
            if restoredPhoneOnlyDecision, !bridge.latestSnapshot.runId.isEmpty {
                // Do not replace a restored outcome-unknown decision with a
                // reconnecting/cancellable projection while the phone process
                // is still booting. The durable status check below remains the
                // final guard for forged cancel intents.
                outcomeUnknownRunIds.insert(bridge.latestSnapshot.runId)
            } else if let reconnecting = reconnecting.max(by: { lhs, rhs in
                if lhs.startedAt == rhs.startedAt { return lhs.runId < rhs.runId }
                return lhs.startedAt < rhs.startedAt
            }) {
                publish(
                    runId: reconnecting.runId,
                    conversationId: reconnecting.conversationId,
                    presentation: .reconnecting(kind: .response)
                )
            } else if !bridge.latestSnapshot.isActive {
                republish()
            }
        } else {
            republish()
        }
        Task { @MainActor [weak self] in
            await self?.refreshWatchSnapshot()
        }
    }

    /// Rebuilds the Watch library projection from the same settings and
    /// conversation store used by the active phone UI.
    func refreshWatchSnapshot() async {
        libraryRefreshRevision &+= 1
        let revision = libraryRefreshRevision
        await prepareForWatchRequestIfNeeded()
        if !isAttached {
            _ = await waitForAttachment()
        }
        // A cold refresh may arrive while AppShell is still constructing its
        // composition. Never publish a synthetic idle snapshot in that window:
        // the Watch already has the last phone-owned projection.
        guard isAttached else { return }
        await recoverTerminalActivitiesIfNeeded()

        let sharedSettings = self.sharedSettings ?? IOSSharedSettingsStore()
        self.sharedSettings = sharedSettings
        if let chatViewModel {
            conversationStore = chatViewModel.conversationStore
        }
        let configurationMessage = chatViewModel?.configurationIssue?.message
            ?? watchConfigurationIssue(for: sharedSettings)?.message
        let refreshedLibrary = await librarySnapshotProvider(sharedSettings, conversationStore, configurationMessage)
        // MainActor refreshes can interleave while reading conversations. An
        // older completion must never be republished with a newer WC revision.
        guard revision == libraryRefreshRevision else { return }
        librarySnapshot = refreshedLibrary
        if currentRunId != nil, currentPresentation != nil {
            republish()
        } else if bridge.latestSnapshot.isActive {
            // A restored iOS-side snapshot can precede coordinator attachment.
            // Add the fresh library while preserving the task phase and its
            // original updatedAt so stale detection remains truthful.
            var snapshot = bridge.latestSnapshot
            snapshot.languageCode = resolvedLanguageCode
            snapshot.library = librarySnapshot
            bridge.publish(snapshot)
            scheduleWatchAttention(for: snapshot)
        } else {
            var idle = WatchTaskSnapshot.idle
            idle.languageCode = resolvedLanguageCode
            idle.library = librarySnapshot
            idle.updatedAt = Date()
            bridge.publish(idle)
            scheduleWatchAttention(for: idle)
        }
    }

    private func recoverTerminalActivitiesIfNeeded() async {
        guard !didRecoverTerminalActivities else { return }
        didRecoverTerminalActivities = true
        let rows: [WatchDurableRunProjection] = await withCheckedContinuation { continuation in
            IosDatabaseFactory.shared.createDatabase().agentRuntimeDao().listAllRuns { result, _ in
                let projections = (result ?? []).compactMap { row -> WatchDurableRunProjection? in
                    guard !row.runId.isEmpty else { return nil }
                    let isOutcomeUnknown = row.status == AgentRunStatus.outcomeUnknown.wireName
                    guard isOutcomeUnknown || row.finishedAt != nil else { return nil }
                    return WatchDurableRunProjection(
                        runId: row.runId,
                        conversationId: row.conversationId,
                        descriptorID: row.agentDescriptorId,
                        status: row.status,
                        startedAt: row.startedAt,
                        finishedAt: row.finishedAt?.int64Value
                    )
                }
                continuation.resume(returning: projections)
            }
        }
        let cachedSnapshot = bridge.latestSnapshot
        // OUTCOME_UNKNOWN is recoverable rather than terminal. Recreate the
        // same phone-only gate after a process death, before AppShell's W3
        // sweep has had a chance to rediscover the tool descriptor. A restored
        // active snapshot wins until its own run is reconciled; an older
        // unknown run is kept as a cancel guard and remains in the library.
        for row in rows where row.status == AgentRunStatus.outcomeUnknown.wireName {
            guard let conversationId = row.conversationId,
                  !conversationId.isEmpty else { continue }
            registerRun(runId: row.runId, startedAt: row.startedAt)
            outcomeUnknownRunIds.insert(row.runId)
            _ = companionService.discardFailedActivityForUnresolvedRun(row.runId)
            let canReplaceCurrent: Bool
            if let currentRunId {
                canReplaceCurrent = currentRunId == row.runId
                    || (runStartedAt[currentRunId] != nil
                        && isNewerRun(row.runId, than: currentRunId))
            } else {
                canReplaceCurrent = !cachedSnapshot.isActive || cachedSnapshot.runId == row.runId
            }
            if canReplaceCurrent {
                _ = publishOutcomeUnknown(
                    runId: row.runId,
                    conversationId: conversationId
                )
            }
        }
        let activities = rows.compactMap { row -> WatchRecentActivity? in
            guard Self.terminalActivityPhases.contains(row.status),
                  let finishedAt = row.finishedAt,
                  !row.runId.isEmpty else { return nil }
            let cachedSummary = cachedSnapshot.runId == row.runId
                && cachedSnapshot.phase == row.status
                ? cachedSnapshot.summary
                : nil
            // A previously persisted activity is the only unambiguous source
            // for a result title during cold restore. Do not scan a
            // conversation's last message: one conversation may contain many
            // runs and the durable row does not identify a message.
            let persistedResultTitle = companionService.recentActivities.first {
                $0.runId?.caseInsensitiveCompare(row.runId) == .orderedSame
            }?.resultTitle
            return WatchRecentActivity(
                id: "run:\(row.runId)",
                runId: row.runId,
                conversationId: row.conversationId,
                kind: activityKind(for: row.descriptorID),
                phase: row.status,
                title: activityTitle(conversationId: row.conversationId),
                resultTitle: persistedResultTitle,
                summary: activitySummary(
                    cachedSummary,
                    phase: AgentActivityPhase(rawValue: row.status) ?? .failed
                ),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(finishedAt) / 1_000)
            )
        }
        _ = companionService.restoreTerminalActivities(activities)
    }

    private static let terminalActivityPhases: Set<String> = [
        "completed", "failed", "cancelled"
    ]

    private func activityKind(for descriptorID: String) -> String {
        switch descriptorID {
        case IOSDurableRunStore.Descriptor.chat, "chat_turn":
            return AgentActivityKind.response.rawValue
        case IOSDurableRunStore.Descriptor.deepRead:
            return AgentActivityKind.research.rawValue
        case IOSDurableRunStore.Descriptor.novelGeneration,
             IOSDurableRunStore.Descriptor.miniAppAI,
             IOSDurableRunStore.Descriptor.council:
            return AgentActivityKind.workflow.rawValue
        default:
            return AgentActivityKind.workflow.rawValue
        }
    }

    /// Records the durable run ordering token before any asynchronous Watch
    /// projection can arrive. Arrival order remains only a legacy fallback for
    /// call sites that do not own a persisted start time.
    func registerRun(runId: String, startedAt: Int64) {
        runStartedAt[runId] = startedAt
        if runGeneration[runId] == nil {
            nextRunGeneration &+= 1
            runGeneration[runId] = nextRunGeneration
        }
    }

    @discardableResult
    func publish(
        runId: String,
        conversationId: String?,
        presentation: AgentActivityPresentation,
        summary: String? = nil,
        decision: WatchDecision? = nil,
        resultTitle: String? = nil
    ) -> Bool {
        let isTerminalPresentation = isTerminal(presentation.phase)
        if isTerminalPresentation {
            let activity = WatchRecentActivity(
                id: "run:\(runId)",
                runId: runId,
                conversationId: conversationId,
                kind: presentation.kind.rawValue,
                phase: presentation.phase.rawValue,
                title: activityTitle(conversationId: conversationId),
                resultTitle: resultTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                summary: activitySummary(summary, phase: presentation.phase),
                updatedAt: Date()
            )
            if !companionService.recordTerminalActivity(activity) {
                NSLog("[AmberWatch] unable to persist terminal activity for run \(runId)")
            }
            // Record before the run-order filter above, then refresh the
            // library even when an older run is intentionally kept out of the
            // current task card.
            scheduleWatchLibraryRefresh()
        }
        let isKnownRun = runGeneration[runId] != nil
        if !isKnownRun {
            nextRunGeneration &+= 1
            runGeneration[runId] = nextRunGeneration
        }
        if let currentRunId,
           currentRunId != runId,
           !isNewerRun(runId, than: currentRunId) {
            return false
        }
        if currentRunId != runId {
            currentSummary = nil
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        }
        currentRunId = runId
        currentConversationId = conversationId
        currentPresentation = presentation
        if let summary {
            currentSummary = WatchTaskText.clipped(summary, maxLength: 280)
        }
        if presentation.phase == .completed
            || presentation.phase == .failed
            || presentation.phase == .cancelled {
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        } else if let decision {
            currentDecision = decision
        } else if presentation.phase != .waitingForUser {
            // Running/tool stages replace a previous decision node.
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        }
        republish()
        return true
    }

    private func scheduleWatchLibraryRefresh() {
        Task { @MainActor [weak self] in
            await self?.refreshWatchSnapshot()
        }
    }

    private func isTerminal(_ phase: AgentActivityPhase) -> Bool {
        phase == .completed || phase == .failed || phase == .cancelled
    }

    private func activityTitle(conversationId: String?) -> String {
        if let conversationId {
            if let summary = conversationStore?.summaries.first(where: {
                $0.id.toHexDashString().caseInsensitiveCompare(conversationId) == .orderedSame
            }) {
                let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
            if let current = conversationStore?.currentConversation,
               current.id.toHexDashString().caseInsensitiveCompare(conversationId) == .orderedSame {
                let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
            if let cached = companionService.conversationTitle(for: conversationId), !cached.isEmpty {
                return cached
            }
        }
        return "Amber 任务"
    }

    private func activitySummary(_ summary: String?, phase: AgentActivityPhase) -> String {
        if let summary = WatchTaskText.clipped(summary, maxLength: 280), !summary.isEmpty {
            return summary
        }
        switch phase {
        case .completed:
            return "任务已完成"
        case .failed:
            return "任务失败"
        case .cancelled:
            return "任务已取消"
        default:
            return "任务已结束"
        }
    }

    private func isNewerRun(_ incomingRunId: String, than currentRunId: String) -> Bool {
        if let incomingStartedAt = runStartedAt[incomingRunId],
           let currentStartedAt = runStartedAt[currentRunId] {
            if incomingStartedAt == currentStartedAt {
                return incomingRunId > currentRunId
            }
            return incomingStartedAt > currentStartedAt
        }
        return (runGeneration[incomingRunId] ?? 0) > (runGeneration[currentRunId] ?? 0)
    }

    func publishWaitingApproval(
        runId: String,
        conversationId: String?,
        prompt: ChatToolApprovalPrompt
    ) {
        pendingAskUser = nil
        let accepted = publish(
            runId: runId,
            conversationId: conversationId,
            presentation: .waitingForUser(kind: prompt.activityKind),
            decision: WatchTaskSnapshotBuilder.decision(
                from: prompt,
                languageCode: resolvedLanguageCode
            )
        )
        if accepted { currentApprovalPrompt = prompt }
    }

    func publishAskUser(
        runId: String,
        conversationId: String?,
        request: WatchAskUserRequest
    ) {
        currentApprovalPrompt = nil
        let accepted = publish(
            runId: runId,
            conversationId: conversationId,
            presentation: .waitingForUser(kind: .workflow),
            decision: WatchTaskSnapshotBuilder.askUserDecision(
                from: request,
                languageCode: resolvedLanguageCode
            )
        )
        if accepted { pendingAskUser = request }
    }

    /// Projects a durable side-effect result that still needs phone-side
    /// reconciliation. The Watch receives exactly one affordance: open the
    /// original iPhone conversation. No retry, cancel, or direct confirmation
    /// is exposed because the operation may already have happened.
    @discardableResult
    func publishOutcomeUnknown(
        _ descriptor: IOSToolOutcomeUnknownDescriptor
    ) -> Bool {
        let normalizedRunId = descriptor.runId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToolCallId = descriptor.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunId.isEmpty, !normalizedToolCallId.isEmpty else { return false }
        return publishOutcomeUnknown(
            runId: normalizedRunId,
            conversationId: descriptor.conversationId
        )
    }

    @discardableResult
    func publishOutcomeUnknown(
        runId: String,
        conversationId: String
    ) -> Bool {
        let normalizedRunId = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunId.isEmpty, !normalizedConversationId.isEmpty else { return false }
        outcomeUnknownRunIds.insert(normalizedRunId)
        if companionService.discardFailedActivityForUnresolvedRun(normalizedRunId) {
            scheduleWatchLibraryRefresh()
        }
        let summary = IOSAppLocalization.string(
            "操作结果待核实，请在原 iPhone 对话中确认。",
            defaultValue: "操作结果待核实，请在原 iPhone 对话中确认。"
        )
        let decision = WatchTaskSnapshotBuilder.outcomeUnknownDecision(
            id: "outcome-unknown:\(normalizedRunId)",
            languageCode: resolvedLanguageCode
        )
        return publish(
            runId: normalizedRunId,
            conversationId: normalizedConversationId,
            presentation: .waitingForUser(kind: .workflow),
            summary: summary,
            decision: decision
        )
    }

    /// Clears only the reconciled tool-call gate after the iPhone has persisted
    /// the exact result. The durable run remains interrupted, so this method
    /// never invents a completed/failed task terminal state.
    @discardableResult
    func publishOutcomeUnknownReconciled(
        runId: String,
        conversationId: String,
        toolCallId: String,
        hasRemainingUnknown: Bool,
        didApply _: Bool
    ) -> Bool {
        let normalizedRunId = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunId.isEmpty,
              !normalizedConversationId.isEmpty,
              !toolCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let currentRunId, currentRunId != normalizedRunId {
            return false
        }
        if currentRunId == nil,
           bridge.latestSnapshot.isActive,
           bridge.latestSnapshot.runId != normalizedRunId {
            return false
        }
        if hasRemainingUnknown {
            outcomeUnknownRunIds.insert(normalizedRunId)
            _ = publishOutcomeUnknown(
                runId: normalizedRunId,
                conversationId: normalizedConversationId
            )
            return true
        }

        // A generic phone-only projection has no tool-call identity to
        // reconcile. Do not claim that it became a terminal result.
        outcomeUnknownRunIds.remove(normalizedRunId)
        clear(runId: normalizedRunId)
        return true
    }

    func publishCompleted(
        runId: String,
        conversationId: String?,
        summary: String?,
        kind: AgentActivityKind = .response,
        resultTitle: String? = nil
    ) {
        publish(
            runId: runId,
            conversationId: conversationId,
            presentation: AgentActivityPresentation(
                kind: kind,
                phase: .completed,
                stage: .completed,
                action: .viewResult
            ),
            summary: summary,
            decision: nil,
            resultTitle: resultTitle
        )
    }

    func clear(runId: String? = nil) {
        if let runId, currentRunId != nil, currentRunId != runId {
            return
        }
        if let runId {
            outcomeUnknownRunIds.remove(runId)
        } else {
            outcomeUnknownRunIds.removeAll()
        }
        currentRunId = nil
        currentConversationId = nil
        currentPresentation = nil
        currentDecision = nil
        currentApprovalPrompt = nil
        currentSummary = nil
        pendingAskUser = nil
        bridge.clear(languageCode: resolvedLanguageCode)
    }

    func currentSnapshot() -> WatchTaskSnapshot {
        bridge.latestSnapshot
    }

    func refreshLanguage() {
        if let currentApprovalPrompt {
            currentDecision = WatchTaskSnapshotBuilder.decision(
                from: currentApprovalPrompt,
                languageCode: resolvedLanguageCode
            )
        } else if let pendingAskUser {
            currentDecision = WatchTaskSnapshotBuilder.askUserDecision(
                from: pendingAskUser,
                languageCode: resolvedLanguageCode
            )
        }
        republish()
    }

    func handleWatchAction(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        // A persisted receipt is checked before freshness validation so an
        // offline retry of an already completed ask remains idempotent.
        if let receipt = companionService.receipt(for: request.requestId) {
            guard IOSWatchCompanionService.receiptRequestsMatch(receipt.request, request) else {
                return rejected(request, "请求标识已被另一项操作使用")
            }
            // A note write is intrinsically idempotent by note id. Do not let
            // an old transient write failure turn a later identical delivery
            // into a permanent rejection.
            if request.action == .saveNote, !receipt.result.accepted {
                // Retry the actual note write below.
            } else {
                if receipt.result.deliveryUnknown == true,
                   let inFlight = inFlightActions[request.requestId] {
                    return await inFlight.task.value
                }
                var result = receipt.result
                result.snapshot = bridge.latestSnapshot
                return result
            }
        }
        if let validationError = validationError(for: request) {
            let result = rejected(request, validationError)
            if request.action != .saveNote {
                _ = companionService.recordReceipt(request: request, result: result)
            }
            return result
        }
        if (request.action == .ask || request.action == .runQuickAction),
           Date().timeIntervalSince(request.createdAt) > 5 * 60 {
            let result = deliveryUnknown(
                request,
                "请求已过期，请在 iPhone 核实是否已执行"
            )
            // Persisting this reconciliation result is optional. If the
            // ledger is full or unavailable, the same old request still gets
            // the same no-replay answer on every delivery.
            _ = companionService.recordReceipt(request: request, result: result)
            return result
        }
        if request.action != .saveNote {
            await prepareForWatchRequestIfNeeded()
        }
        if !isAttached, request.action != .saveNote, request.action != .refresh {
            await waitForAttachment()
        }
        if request.action == .cancel,
           await rejectCancelForOutcomeUnknown(request) {
            return rejected(
                request,
                "操作结果待核实，请在原 iPhone 对话中确认"
            )
        }
        if let processed = processedActions[request.requestId] {
            guard IOSWatchCompanionService.receiptRequestsMatch(processed.request, request) else {
                return rejected(request, "请求标识已被另一项操作使用")
            }
            var result = processed.result
            result.snapshot = bridge.latestSnapshot
            return result
        }
        if let inFlight = inFlightActions[request.requestId] {
            guard IOSWatchCompanionService.receiptRequestsMatch(inFlight.request, request) else {
                return rejected(request, "请求标识已被另一项操作使用")
            }
            return await inFlight.task.value
        }

        if requiresDurableClaim(for: request.action) {
            guard companionService.claimReceipt(request: request) else {
                if let receipt = companionService.receipt(for: request.requestId),
                   IOSWatchCompanionService.receiptRequestsMatch(receipt.request, request) {
                    var result = receipt.result
                    result.snapshot = bridge.latestSnapshot
                    return result
                }
                return rejected(request, companionService.storageError ?? "iPhone 暂时无法安全接收此操作")
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return WatchTaskActionResult(
                    requestId: request.requestId,
                    runId: request.runId,
                    accepted: false,
                    message: "iPhone 当前无法处理手表操作",
                    snapshot: nil
                )
            }
            return await self.handleWatchActionUncached(request)
        }
        inFlightActions[request.requestId] = InFlightAction(request: request, task: task)
        let result = await task.value
        inFlightActions.removeValue(forKey: request.requestId)
        if shouldCacheResult(request: request, result: result) {
            processedActions[request.requestId] = ProcessedAction(request: request, result: result)
            processedActionOrder.append(request.requestId)
            if processedActionOrder.count > 64 {
                let expired = processedActionOrder.removeFirst()
                processedActions.removeValue(forKey: expired)
            }
            if !companionService.recordReceipt(request: request, result: result) {
                // The operation result remains truthful, but the next retry cannot
                // be promised safe across a process restart when the ledger failed.
                NSLog("[AmberWatch] unable to persist action receipt \(request.requestId)")
            }
        } else {
            // A failed note write must remain retryable after a transient
            // storage failure. In particular, do not retain a stale negative
            // result in either in-memory or durable dedupe state.
            processedActions.removeValue(forKey: request.requestId)
        }
        return result
    }

    private func shouldCacheResult(
        request: WatchTaskActionRequest,
        result: WatchTaskActionResult
    ) -> Bool {
        request.action != .saveNote || result.accepted
    }

    private func requiresDurableClaim(for action: WatchInboundAction) -> Bool {
        switch action {
        case .ask, .runQuickAction:
            return true
        case .saveNote, .approve, .deny, .choose, .answer, .cancel, .retry,
             .openOnPhone, .refresh, .openConversation:
            return false
        }
    }

    private func validationError(for request: WatchTaskActionRequest) -> String? {
        let requestId = request.requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestId.isEmpty, requestId.count <= 256 else {
            return "请求标识无效"
        }
        let isNewAction: Bool
        switch request.action {
        case .ask, .saveNote, .openConversation, .runQuickAction:
            isNewAction = true
        default:
            isNewAction = false
        }
        if isNewAction, UUID(uuidString: requestId) == nil {
            return "请求标识无效"
        }
        if request.runId.count > 256 {
            return "任务标识无效"
        }
        if let conversationId = request.conversationId,
           conversationId.trimmingCharacters(in: .whitespacesAndNewlines).count > 256 {
            return "会话标识无效"
        }
        if let text = request.text, text.count > 2_000 {
            return "文本不能超过 2000 个字符"
        }

        switch request.action {
        case .ask:
            guard let text = request.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "请输入问题"
            }
        case .saveNote:
            guard let text = request.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "记事内容不能为空"
            }
        case .runQuickAction:
            guard let optionId = request.optionId,
                  !optionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  optionId.count <= 256 else {
                return "快捷动作无效"
            }
            guard let text = request.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "快捷动作内容为空"
            }
        case .openConversation:
            guard let conversationId = request.conversationId,
                  !conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "缺少会话标识"
            }
        case .approve, .deny, .choose, .answer, .cancel, .retry:
            guard !request.runId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "缺少任务标识"
            }
            let age = Date().timeIntervalSince(request.createdAt)
            guard age >= -10, age <= 60 else {
                return "这个操作已过期，请从手表重新打开"
            }
        case .refresh:
            break
        case .openOnPhone:
            break
        }
        return nil
    }

    private func watchConfigurationIssue(for sharedSettings: IOSSharedSettingsStore) -> ChatConfigurationIssue? {
        guard let model = sharedSettings.snapshot.getCurrentChatModel() else {
            return .missingModel
        }
        return ChatProviderConfiguration.issue(
            for: model,
            provider: sharedSettings.resolveCurrentProviderSetting()
        )
    }

    private func ownerChatViewModel(for runId: String? = nil) -> ChatViewModel? {
        if let runId {
            if chatViewModel?.currentKernelRunId == runId { return chatViewModel }
            if headlessChatViewModel?.currentKernelRunId == runId { return headlessChatViewModel }
        }
        return chatViewModel ?? headlessChatViewModel
    }

    private func prepareForWatchRequestIfNeeded() async {
        guard !isAttached, let coldStartPreparer,
              let context = await coldStartPreparer() else { return }
        // AppShell may have attached while the headless composition awaited its
        // store bootstrap. Keep the foreground owner and do not replace it.
        guard !isAttached else { return }
        attach(
            chatViewModel: context.chatViewModel,
            sharedSettings: context.sharedSettings,
            reconnecting: context.reconnecting,
            isHeadlessOwner: true
        )
    }

    @discardableResult
    private func waitForAttachment() async -> Bool {
        guard !isAttached else { return true }
        let waiterId = UUID()
        await withCheckedContinuation { continuation in
            attachmentWaiters[waiterId] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: self?.attachmentWaitNanoseconds ?? 0)
                guard let continuation = self?.attachmentWaiters.removeValue(forKey: waiterId) else {
                    return
                }
                continuation.resume()
            }
        }
        return isAttached
    }

    /// A cold Watch can deliver a stale reconnecting cancel before AppShell's
    /// W3 sweep has rebuilt the phone-only decision. Consult the durable run
    /// row at the execution boundary so the UI projection is never the sole
    /// safety check.
    private func rejectCancelForOutcomeUnknown(
        _ request: WatchTaskActionRequest
    ) async -> Bool {
        guard !request.runId.isEmpty else { return false }
        var isKnownUnknown = outcomeUnknownRunIds.contains(request.runId)
        if !isKnownUnknown {
            do {
                isKnownUnknown = try await durableRunStore.snapshot(runId: request.runId)?.status == .outcomeUnknown
                if !isKnownUnknown {
                    // The transcript save can fail after the ledger records
                    // an unknown effect, leaving the run recoveryPending.
                    guard let transactions = await toolLedger.toolTransactions(runId: request.runId) else {
                        return true
                    }
                    isKnownUnknown = transactions.contains { $0.state == .outcomeUnknown }
                }
            } catch {
                // A failed evidence lookup must not authorize cancellation.
                return true
            }
        }
        guard isKnownUnknown else { return false }
        let conversationId = request.runId == currentRunId
            ? currentConversationId
            : request.conversationId
        if let conversationId {
            _ = publishOutcomeUnknown(
                runId: request.runId,
                conversationId: conversationId
            )
        } else {
            outcomeUnknownRunIds.insert(request.runId)
        }
        return true
    }

    private func handleWatchActionUncached(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        switch request.action {
        case .refresh:
            await refreshWatchSnapshot()
            return accepted(request, message: nil)
        case .openOnPhone:
            return await handoffToPhone(request, requiresCurrentRun: true)
        case .openConversation:
            return await handoffToPhone(request, requiresCurrentRun: false)
        case .saveNote:
            guard let text = request.text else {
                return rejected(request, "记事内容不能为空")
            }
            let note = WatchNote(
                id: request.requestId,
                text: text,
                createdAt: request.createdAt,
                syncedAt: Date()
            )
            guard companionService.saveNote(note) else {
                return rejected(request, companionService.storageError ?? "记事无法保存，请稍后重试")
            }
            return accepted(request, message: "已保存到 iPhone")
        case .ask:
            guard let chatViewModel else {
                return rejected(request, "iPhone 聊天状态不可用")
            }
            let started = await chatViewModel.startWatchQuestion(
                text: request.text ?? "",
                conversationId: request.conversationId
            )
            guard started.started,
                  let conversationId = started.conversationId,
                  let runId = started.runId else {
                return rejected(request, started.failureMessage ?? "iPhone 无法启动这条任务")
            }
            return accepted(
                request,
                message: "已发送到 iPhone",
                runId: runId,
                conversationId: conversationId
            )
        case .runQuickAction:
            guard let optionId = request.optionId,
                  let text = request.text else {
                return rejected(request, "快捷动作无效")
            }
            await refreshWatchSnapshot()
            guard let library = librarySnapshot,
                  library.isConfigured else {
                return rejected(request, librarySnapshot?.configurationMessage ?? "当前助手尚未配置")
            }
            guard let action = library.quickActions.first(where: {
                $0.id.caseInsensitiveCompare(optionId) == .orderedSame
            }) else {
                return rejected(request, "快捷动作已更新，请从手表刷新")
            }
            guard action.prompt == text else {
                return rejected(request, "快捷动作内容已更新，请从手表刷新")
            }
            guard let chatViewModel else {
                return rejected(request, "iPhone 聊天状态不可用")
            }
            let started = await chatViewModel.startWatchQuestion(text: text)
            guard started.started,
                  let conversationId = started.conversationId,
                  let runId = started.runId else {
                return rejected(request, started.failureMessage ?? "iPhone 无法启动这条任务")
            }
            return accepted(
                request,
                message: "已发送到 iPhone",
                runId: runId,
                conversationId: conversationId
            )
        case .cancel:
            guard let currentRunId, request.runId == currentRunId else {
                return rejected(request, "当前没有可取消的任务")
            }
            guard !outcomeUnknownRunIds.contains(request.runId),
                  !WatchTaskSnapshotBuilder.isPhoneOnlyDecision(currentDecision) else {
                return rejected(request, "操作结果待核实，请在原 iPhone 对话中确认")
            }
            // The run may already belong to the background coordinator. Only
            // report success after the current foreground/background owner accepts it.
            let owner = ownerChatViewModel(for: currentRunId)
            let acceptedByForeground = owner?.cancelGeneration(runId: currentRunId) == true
            let acceptedByBackground = acceptedByForeground
                ? false
                : IOSChatBackgroundGenerationCoordinator.shared.cancelJob(runId: currentRunId)
            guard acceptedByForeground || acceptedByBackground else {
                return rejected(request, "当前任务已经结束或不再由 iPhone 执行")
            }
            return accepted(request, message: "已取消")
        case .retry:
            guard let chatViewModel = ownerChatViewModel(for: currentRunId),
                  let runId = currentRunId,
                  request.runId == runId,
                  currentPresentation?.phase == .failed,
                  currentPresentation?.retryable == true,
                  let conversationId = currentConversationId,
                  request.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame else {
                return rejected(request, "这个失败任务已失效")
            }
            guard await chatViewModel.retryFailedGeneration(
                sourceRunId: runId,
                conversationId: conversationId
            ) else {
                return rejected(request, "当前无法重试这个任务")
            }
            return accepted(request, message: "已重试")
        case .approve, .deny:
            return await handleApproval(request)
        case .choose, .answer:
            return await handleAskUser(request)
        }
    }

    private func handoffToPhone(
        _ request: WatchTaskActionRequest,
        requiresCurrentRun: Bool
    ) async -> WatchTaskActionResult {
        let conversationId: String
        if requiresCurrentRun,
           request.runId == currentRunId,
           let currentConversationId,
           !currentConversationId.isEmpty,
           (request.conversationId == nil
                || request.conversationId?.caseInsensitiveCompare(currentConversationId) == .orderedSame) {
            conversationId = currentConversationId
        } else if let requestedConversationId = request.conversationId,
                  let canonical = await canonicalConversationId(
                      requestedConversationId,
                      runId: requiresCurrentRun ? request.runId : nil
                  ) {
            if requiresCurrentRun {
                guard !request.runId.isEmpty,
                      await belongsToCurrentRunIfKnown(
                          runId: request.runId,
                          conversationId: canonical
                      ) else {
                    return rejected(request, "当前任务没有可打开的会话")
                }
            }
            conversationId = canonical
        } else {
            return rejected(request, requiresCurrentRun ? "当前任务没有可打开的会话" : "找不到这条对话")
        }

        let focus: String
        let restoredDecision = bridge.latestSnapshot.runId == request.runId
            ? bridge.latestSnapshot.decision
            : nil
        if request.runId.isEmpty || request.runId != currentRunId {
            focus = WatchTaskSnapshotBuilder.isPhoneOnlyDecision(restoredDecision)
                ? "confirmation"
                : "result"
        } else if currentDecision?.type == .approval
            || currentDecision?.type == .askUser
            || currentDecision?.type == .voiceReply
            || WatchTaskSnapshotBuilder.isPhoneOnlyDecision(restoredDecision) {
            focus = "confirmation"
        } else if currentPresentation?.phase == .completed {
            focus = "result"
        } else {
            focus = "task"
        }
        let destination: IOSAppDeepLink.Destination
        if request.runId.isEmpty {
            destination = .conversation(id: conversationId)
        } else {
            destination = .agentActivity(AgentActivityDeepLink.Target(
                runId: request.runId,
                conversationId: conversationId,
                focus: AgentActivityDeepLink.Focus(rawValue: focus) ?? .task
            ))
        }
        if let url = IOSAppDeepLink.url(for: destination) {
            // The inbox persists while no AppShell handler is installed, so a
            // Watch handoff survives a cold launch and is consumed after the
            // conversation store has bootstrapped. The durable entry is
            // acknowledged only after AppShell applies the destination.
            deepLinkInbox.submit(url, persistUntilHandled: true)
        }
        return accepted(
            request,
            message: "已发送到 iPhone",
            conversationId: conversationId
        )
    }

    private func canonicalConversationId(_ raw: String, runId: String? = nil) async -> String? {
        if let conversationStore {
            let summaries = await conversationStore.appIntentSummaries(limit: nil)
            if let summary = summaries.first(where: {
                $0.id.toHexDashString().caseInsensitiveCompare(raw) == .orderedSame
            }) {
                return summary.id.toHexDashString()
            }
        }
        if bridge.latestSnapshot.library?.recent.contains(where: {
            $0.id.caseInsensitiveCompare(raw) == .orderedSame
        }) == true {
            return raw
        }
        // Persisted runs may use legacy conversation identifiers that are not
        // Kotlin UUIDs. For an old activity, the durable run record is the
        // authoritative ownership check; AppShell will resolve the matching
        // conversation after its store bootstrap.
        if let runId, !runId.isEmpty,
           let owner = ownerChatViewModel(for: runId),
           await owner.recordedAgentRunBelongsToConversation(
               runId: runId,
               conversationId: raw
           ) {
            return raw
        }
        return nil
    }

    private func belongsToCurrentRunIfKnown(runId: String, conversationId: String) async -> Bool {
        guard !runId.isEmpty else { return true }
        if runId == currentRunId,
           let currentConversationId {
            return currentConversationId.caseInsensitiveCompare(conversationId) == .orderedSame
        }
        guard let chatViewModel = ownerChatViewModel(for: runId) else { return false }
        return await chatViewModel.recordedAgentRunBelongsToConversation(
            runId: runId,
            conversationId: conversationId
        )
    }

    private func handleApproval(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        guard let decision = currentDecision,
              decision.type == .approval,
              request.decisionId == decision.id else {
            return rejected(request, "这个确认步骤已失效")
        }
        guard let approvalPrompt = currentApprovalPrompt else {
            return rejected(request, "这个操作不支持在 Apple Watch 上确认")
        }
        guard let chatViewModel = ownerChatViewModel(for: currentRunId) else {
            return rejected(request, "iPhone 聊天状态不可用")
        }
        guard let runId = currentRunId,
              request.runId == runId,
              chatViewModel.canOpenActivityConfirmation(runId: runId) else {
            return rejected(request, "当前没有待确认的操作")
        }

        let allow: Bool
        switch request.action {
        case .approve:
            allow = true
        case .deny:
            allow = false
        default:
            if request.optionId == "approve" {
                allow = true
            } else if request.optionId == "deny" {
                allow = false
            } else {
                return rejected(request, "无法识别审批选项")
            }
        }

        // The Watch gate is repeated at the point of execution. A stale or
        // swapped prompt must fail closed even if the old decision id matches.
        if allow {
            guard WatchTaskSnapshotBuilder.allowsApprovalOnWatch(approvalPrompt) else {
                return rejected(request, "这个确认步骤已失效")
            }
        }

        guard chatViewModel.resolvePendingToolApprovalFromWatch(
            runId: runId,
            requestId: decision.id,
            allow: allow
        ) else {
            return rejected(request, "这个确认步骤已失效")
        }
        // Awaited finish/resume path publishes the next watch snapshot before we reply.
        return accepted(request, message: allow ? "已允许" : "已拒绝")
    }

    private func handleAskUser(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        guard let decision = currentDecision,
              decision.type == .askUser || decision.type == .voiceReply,
              request.decisionId == decision.id else {
            return rejected(request, "这个确认步骤已失效")
        }
        guard let chatViewModel = ownerChatViewModel(for: currentRunId) else {
            return rejected(request, "iPhone 聊天状态不可用")
        }
        guard let runId = currentRunId,
              request.runId == runId,
              let pendingAskUser else {
            return rejected(request, "当前没有等待回答的问题")
        }

        let answer: String
        if request.action == .choose {
            guard let optionId = request.optionId,
                  let option = decision.options.first(where: { $0.id == optionId }),
                  option.style == .choice || option.style == .deny else {
                return rejected(request, "无法识别这个回答选项")
            }
            if option.id == "skip" {
                answer = ""
            } else if option.id.hasPrefix("choice-"),
                      let index = Int(option.id.dropFirst("choice-".count)),
                      pendingAskUser.options.indices.contains(index) {
                answer = pendingAskUser.options[index]
            } else {
                return rejected(request, "无法识别这个回答选项")
            }
        } else {
            guard request.action == .answer,
                  decision.allowsVoice,
                  let text = request.text else {
                return rejected(request, "这个问题不接受语音回答")
            }
            answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                return rejected(request, "回答不能为空")
            }
        }

        // submitWatchUserAnswer returns true only after finish+resume ownership accepts.
        // resumeAfterApproval already publishes the next snapshot; do not clear locally
        // first or report success before that Bool is true.
        let acceptedSend = chatViewModel.submitWatchUserAnswer(
            runId: runId,
            requestId: decision.id,
            text: answer
        )
        guard acceptedSend else {
            return rejected(request, "当前无法提交回答")
        }
        return accepted(
            request,
            message: answer.isEmpty ? "已跳过" : "已提交回答"
        )
    }

    private func republish() {
        guard let runId = currentRunId,
              let presentation = currentPresentation else {
            var idle = WatchTaskSnapshot.idle
            idle.languageCode = resolvedLanguageCode
            idle.library = librarySnapshot ?? bridge.latestSnapshot.library
            idle.updatedAt = Date()
            bridge.publish(idle)
            scheduleWatchAttention(for: idle)
            return
        }
        var snapshot = WatchTaskSnapshotBuilder.make(
            runId: runId,
            conversationId: currentConversationId,
            presentation: presentation,
            summary: currentSummary,
            decision: currentDecision,
            languageCode: resolvedLanguageCode
        )
        snapshot.library = librarySnapshot ?? bridge.latestSnapshot.library
        bridge.publish(snapshot)
        scheduleWatchAttention(for: snapshot)
    }

    private func scheduleWatchAttention(for snapshot: WatchTaskSnapshot) {
        let runId = snapshot.runId
        let phase = snapshot.phase
        let decisionId = snapshot.decision?.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await IOSLocalNotificationService.shared.scheduleWatchAttention(
                    snapshot: snapshot,
                    notifyIfNeeded: UIApplication.shared.applicationState != .active,
                    isStillCurrent: { [weak self] in
                        guard let self else { return false }
                        let latest = self.bridge.latestSnapshot
                        return latest.runId == runId
                            && latest.phase == phase
                            && latest.decision?.id == decisionId
                    }
                )
            } catch {
                NSLog("[AmberWatch] attention notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func accepted(
        _ request: WatchTaskActionRequest,
        message: String?,
        runId: String? = nil,
        conversationId: String? = nil
    ) -> WatchTaskActionResult {
        WatchTaskActionResult(
            requestId: request.requestId,
            runId: runId ?? request.runId,
            accepted: true,
            message: message.map {
                WatchTaskLocalization.string(
                    $0,
                    defaultValue: $0,
                    languageCode: resolvedLanguageCode
                )
            },
            snapshot: bridge.latestSnapshot,
            conversationId: conversationId,
            deliveryUnknown: nil
        )
    }

    private func rejected(
        _ request: WatchTaskActionRequest,
        _ message: String
    ) -> WatchTaskActionResult {
        WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: false,
            message: WatchTaskLocalization.string(
                message,
                defaultValue: message,
                languageCode: resolvedLanguageCode
            ),
            snapshot: bridge.latestSnapshot,
            conversationId: nil,
            deliveryUnknown: nil
        )
    }

    private func deliveryUnknown(
        _ request: WatchTaskActionRequest,
        _ message: String
    ) -> WatchTaskActionResult {
        WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: false,
            message: WatchTaskLocalization.string(
                message,
                defaultValue: message,
                languageCode: resolvedLanguageCode
            ),
            snapshot: bridge.latestSnapshot,
            conversationId: request.conversationId,
            deliveryUnknown: true
        )
    }
}
