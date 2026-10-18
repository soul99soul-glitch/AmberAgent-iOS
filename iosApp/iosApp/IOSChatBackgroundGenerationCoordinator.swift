@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator: IOSThreadOrchestrationToolService.BackgroundScheduling {}

@MainActor
final class IOSChatBackgroundGenerationCoordinator {
    static let shared = IOSChatBackgroundGenerationCoordinator()

    /// Background continuations need enough rounds for a child-agent tool
    /// chain to finish. Keep this separate from the user-configurable
    /// foreground budget: background jobs have no settings UI, and six rounds
    /// truncated ordinary subagent chains before they could report back.
    /// Thirty is a bounded five-fold increase over the old cap of six.
    static let backgroundToolLoopMaxSteps = 30

    /// The production engine configuration is shared with the regression test
    /// so it exercises the same budget used by `handle(_:)`.
    static let backgroundToolLoopConfiguration = IOSAgentToolEngine.Configuration(
        maxSteps: backgroundToolLoopMaxSteps,
        honorApprovalPause: false
    )

    enum RunRecordResult: Equatable {
        case recorded
        case conflict
        case failed
    }

    /// P1-c: 后台 job 终态钩子（子线程完成/失败/截断/取消时向父线程投递
    /// FINAL_ANSWER 由 ChatViewModel 接线到编排服务）。nil 时零开销。
    var onRunTerminal: (@MainActor (KotlinUuid, String, [UIMessage], [UIMessage]) async -> Void)?
    /// A terminal run can release ownership while a user followup is already
    /// pending in the child mailbox. The owner must be released before this
    /// callback starts the idle bootstrap, otherwise the service quite
    /// correctly observes the old run as active and leaves the task queued.
    /// ChatViewModel wires this to
    /// `IOSThreadOrchestrationToolService.resumePendingTasks`.
    var onRunFinishedWithPendingTasks: (@MainActor (
        KotlinUuid,
        ProviderSetting,
        TextGenerationParams,
        IosToolExposureBridge,
        IOSExecutionPolicySnapshot?
    ) async -> Void)?
    var onToolOutcomeUnknown: (@MainActor (IOSToolOutcomeUnknownDescriptor) -> Void)?

    private var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "app.amber.ios" }
    private var permittedIdentifier: String { "\(bundleIdentifier).chat.*" }
    private var requestPrefix: String { "\(bundleIdentifier).chat." }
    private var taskMapKey: String { "\(bundleIdentifier).chat.backgroundTaskMap" }
    private var registeredRequestIds: Set<String> = []
    private(set) var dependencies: IOSChatBackgroundDependencies?
    // These registries remain on the single MainActor coordinator. Their
    // internal visibility serves its responsibility extensions in other files.
    var activeJobs: [String: IOSChatBackgroundRuntimeJob] = [:]
    var activeRunStates: [String: IOSChatBackgroundRunState] = [:]
    var activeBackgroundTasks: [String: IOSChatBackgroundExecution] = [:]
    var subAgentTimeoutTasks: [String: Task<Void, Never>] = [:]
    private(set) var activeDetachedResponseTasks: [String: Task<Void, Never>] = [:]
    var activeDetachedResponseJobs: [String: Kotlinx_coroutines_coreJob] = [:]
    var activeDetachedResponseCompletions: [String: IOSChatDurableResumeCompletion] = [:]
    var staleSweepInFlightRequestIds: Set<String> = []
    /// Same-process system expiration only. These IDs are deliberately not persisted:
    /// ordinary provider streams have no cross-process cursor and must not claim one.
    var backgroundInterruptedRequestIds: Set<String> = []
    private(set) var foregroundResumeInFlightRequestIds: Set<String> = []
    var automaticallyResumedRequestIds: Set<String> = []
    var toolRecoveryInFlightRequestIds: Set<String> = []
    /// A side-effect result awaiting explicit user reconciliation must not be
    /// overwritten by the ordinary Stop path while terminal UI is settling.
    var outcomeUnknownRequestIds: Set<String> = []
    /// Retains the composition root used only when iOS launches the process for
    /// a background task before SwiftUI creates AppShell.
    private var headlessChatViewModel: ChatViewModel?
    private var headlessConversationStore: IOSConversationStore?
    private var headlessSharedSettings: IOSSharedSettingsStore?
    private var headlessComposition: IOSChatHeadlessComposition?
    private(set) lazy var db: AgentRuntimeDatabase = IosDatabaseFactory.shared.createDatabase()
    private(set) lazy var runStore = IOSDurableRunStore(dao: db.agentRuntimeDao())
    // W1 durable ledger (I-1): background-continued tool execution accounts
    // itself against the SAME runId the foreground run already started under
    // (see the `IOSAgentToolEngine(... ledger:ledgerRunId:)` call below).
    private(set) lazy var toolLedger: IOSAgentRunLedgering = IOSAgentRunLedger(dao: db.agentRuntimeDao())

    let keepAlive: BackgroundGenerationKeepAlive
    let provider: any IOSAgentTextProvider
#if DEBUG
    var registerRequestOverrideForTesting: ((String) -> Bool)?
    var resumeDetachedResponsesOverrideForTesting: (() -> Void)?
    var persistHandoffOverrideForTesting: ((IOSChatBackgroundHandoff, String) throws -> Void)?
#endif
    private let registersPersistedTasksOnStart: Bool

    private init() {
        self.keepAlive = .shared
        self.provider = IOSChatBackgroundProvider()
        self.registersPersistedTasksOnStart = true
    }

    /// Injected executions do not register the App singleton's persisted jobs.
    init(keepAlive: BackgroundGenerationKeepAlive, provider: any IOSAgentTextProvider) {
        self.keepAlive = keepAlive
        self.provider = provider
        self.registersPersistedTasksOnStart = false
    }

    /// BGTaskScheduler requires every persisted dynamic identifier to be
    /// registered before applicationDidFinishLaunching returns. Install the
    /// handler first, then build the same runtime dependencies AppShell uses so
    /// a headless launch can hydrate the persisted handoff without a window.
    func prepareForApplicationLaunch() {
        let requestIds = Array(taskMap().keys)
        for requestId in requestIds {
            keepAlive.registerRestorationHandler(for: chatBackgroundAudioLeaseId(for: requestId)) { [weak self] task in
                self?.restoreKeepAliveTask(task, requestId: requestId)
            }
        }
        for requestId in requestIds where !register(requestId: requestId) {
            finish(requestId: requestId)
        }
        guard !requestIds.isEmpty, dependencies == nil else { return }

        _ = buildHeadlessChatViewModel()
        for requestId in requestIds where activeJobs[requestId] == nil {
            _ = job(for: requestId)
        }
    }

    private func restoreKeepAliveTask(_ task: BGContinuedProcessingTask, requestId: String) {
        guard activeBackgroundTasks[requestId] == nil,
              activeRunStates[requestId]?.isExpired != true else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let job = job(for: requestId) else {
            task.setTaskCompleted(success: false)
            return
        }
        if job.mode == .resumeResponse {
            beginChatBackgroundKeepAlive(requestId: requestId, subtitle: job.params.model.displayName)
            resumeDetachedResponsesIfNeeded()
            Task { await keepAlive.adopt(task, leaseId: chatBackgroundAudioLeaseId(for: requestId)) }
            return
        }
        let execution = IOSChatBackgroundExecution(
            identifier: requestId, systemTask: task, keepAlive: keepAlive,
            leaseId: chatBackgroundAudioLeaseId(for: requestId)
        )
        activeBackgroundTasks[requestId] = execution
        let restorationState = IOSChatBackgroundRunState()
        activeRunStates[requestId] = restorationState
        task.expirationHandler = {
            _ = restorationState.expireAndReserveTerminal()
            if restorationState.claimSystemTaskCompletion() { task.setTaskCompleted(success: false) }
        }
        Task { @MainActor in
            // Local execution may have advanced before the queued assertion
            // was adopted. Reconcile its recorded tool results before asking
            // the provider to continue from the persisted payload.
            if job.mode == .continueModel,
               await prepareOrdinaryJobForResume(job: job, requestId: requestId) == nil {
                if restorationState.claimSystemTaskCompletion() { task.setTaskCompleted(success: false) }
                if activeBackgroundTasks[requestId] === execution {
                    releaseRuntimeOwnership(requestId: requestId)
                }
                return
            }
            guard activeBackgroundTasks[requestId] === execution else { return }
            guard !restorationState.isExpired else {
                releaseRuntimeOwnership(requestId: requestId)
                return
            }
            await handle(execution)
        }
    }

    /// Builds the same provider/runtime composition used by a background
    /// launch so a Watch question can start before SwiftUI creates AppShell.
    /// The method intentionally returns nil once another composition root has
    /// installed dependencies; AppShell will attach normally in that case.
    func prepareHeadlessChatViewModelForWatch() async -> ChatViewModel? {
        if let headlessChatViewModel {
            if let conversationStore = headlessConversationStore,
               conversationStore.summaries.isEmpty {
                await conversationStore.bootstrap()
            }
            return headlessChatViewModel
        }
        guard dependencies == nil else { return nil }
        let chatViewModel = buildHeadlessChatViewModel()
        if let conversationStore = headlessConversationStore {
            await conversationStore.bootstrap()
        }
        return chatViewModel
    }

    var headlessSharedSettingsForWatch: IOSSharedSettingsStore? {
        headlessSharedSettings
    }

    var headlessCompositionForWatch: IOSChatHeadlessComposition? {
        headlessComposition
    }

    private func buildHeadlessChatViewModel() -> ChatViewModel {
        // A Watch or continued-processing launch can build this graph before
        // AppShell runs its normal startup load. Load once here so a headless
        // provider request sees the existing memory library instead of making
        // the first write fail with `notLoaded`.
        if IOSMemoryPersistence.shared.loadState == .notLoaded {
            IOSMemoryPersistence.shared.load()
        }

        let settingsStore = SettingsStore()
        let sharedSettings = IOSSharedSettingsStore()
        let conversationStore = IOSConversationStore()
        let permissionStore = IOSPermissionStore()
        let documentStore = DocumentAccessStore()
        let systemPermissionCoordinator = IOSSystemPermissionCoordinator()
        let localToolExecutor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: documentStore,
            workspaceStore: .shared,
            systemPermissionCoordinator: systemPermissionCoordinator,
            settingsStore: settingsStore
        )
        let chatViewModel = ChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor
        )
        chatViewModel.conversationStore = conversationStore
        dependencies = IOSChatBackgroundDependencies(
            conversationStore: conversationStore,
            toolRuntime: chatViewModel.makeBackgroundToolRuntime(),
            sharedSettings: sharedSettings,
            liveActivityController: .shared,
            saveMiniAppIfPresent: { [chatViewModel] messages, conversationId in
                chatViewModel.applyMiniAppOutputIfPresentPublic(
                    to: messages,
                    conversationId: conversationId
                )
            }
        )
        headlessChatViewModel = chatViewModel
        headlessConversationStore = conversationStore
        headlessSharedSettings = sharedSettings
        headlessComposition = IOSChatHeadlessComposition(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            conversationStore: conversationStore,
            permissionStore: permissionStore,
            documentStore: documentStore,
            systemPermissionCoordinator: systemPermissionCoordinator,
            localToolExecutor: localToolExecutor,
            chatViewModel: chatViewModel
        )
        return chatViewModel
    }

    /// 生命周期快照里属于本协调器的那一段：只读内存态，不碰磁盘。
    var lifecycleSnapshotDetail: String {
        "executions=\(activeBackgroundTasks.count)"
            + " bgTasks=\(activeBackgroundTasks.values.filter { $0.systemTask != nil }.count)"
            + " jobs=\(activeJobs.count)"
            + " runStates=\(activeRunStates.count)"
    }

    var restorableRunIds: Set<String> {
        Set(activeJobs.values.map(\.runId))
    }

    /// Live handlers and durable response owners remain outside generic W3
    /// recovery. `resumeDetachedResponse` performs the same ledger gate before
    /// contacting the server, so generic startup recovery must not first
    /// reclassify a resumable response as interrupted.
    var startupRecoveryExclusionRunIds: Set<String> {
        let persisted = taskMap()
        var requestIds = Set(activeBackgroundTasks.keys)
        requestIds.formUnion(activeDetachedResponseTasks.keys)
        requestIds.formUnion(activeJobs.compactMap { requestId, job in
            job.mode == .resumeResponse && job.responseId != nil ? requestId : nil
        })
        var runIds = Set(requestIds.compactMap { persisted[$0] ?? activeJobs[$0]?.runId })
        if let headlessRunId = headlessChatViewModel?.currentKernelRunId {
            runIds.insert(headlessRunId)
        }
        return runIds
    }

    var reconnectingWatchProjections: [WatchTaskReconnectProjection] {
        activeJobs.values.sorted(by: { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.runId < rhs.runId }
            return lhs.startedAt < rhs.startedAt
        }).map { job in
            WatchTaskReconnectProjection(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                startedAt: job.startedAt
            )
        }
    }

    func configure(
        conversationStore: IOSConversationStore? = nil,
        toolRuntime: ChatToolRuntime? = nil,
        sharedSettings: IOSSharedSettingsStore? = nil,
        liveActivityController: AgentLiveActivityController = .shared,
        saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)? = nil
    ) {
        if let conversationStore, let toolRuntime, let sharedSettings {
            dependencies = IOSChatBackgroundDependencies(
                conversationStore: conversationStore,
                toolRuntime: toolRuntime,
                sharedSettings: sharedSettings,
                liveActivityController: liveActivityController,
                saveMiniAppIfPresent: saveMiniAppIfPresent
            )
        }
        for requestId in taskMap().keys {
            if !register(requestId: requestId) {
                finish(requestId: requestId)
            } else if activeJobs[requestId] == nil {
                _ = job(for: requestId)
            }
        }
    }

    func start(
        handoff: IOSChatBackgroundHandoff,
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime,
        liveActivityController: AgentLiveActivityController,
        saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)? = nil
    ) -> Bool {
        WatchTaskCoordinator.shared.registerRun(
            runId: handoff.runId,
            startedAt: handoff.startedAt
        )
        if handoff.mode == .resumeResponse {
            let requestId = requestIdentifier(for: handoff.runId)
            let alreadyHeldAudio = keepAlive.holdsLease(
                chatBackgroundAudioLeaseId(for: requestId)
            )
            beginChatBackgroundKeepAlive(
                requestId: requestId,
                subtitle: handoff.params.model.displayName,
                submitSystemFallback: true
            )
            guard checkpointDurableResponse(handoff) else {
                if !alreadyHeldAudio {
                    endChatBackgroundAudioKeepAlive(requestId: requestId)
                }
                return false
            }
            activeJobs[requestId] = runtimeJob(
                handoff: handoff,
                conversationStore: conversationStore,
                toolRuntime: toolRuntime,
                liveActivityController: liveActivityController,
                saveMiniAppIfPresent: saveMiniAppIfPresent
            )
            return true
        }
        if registersPersistedTasksOnStart { configure() }

        let requestId = requestIdentifier(for: handoff.runId)
        guard activeJobs[requestId] == nil else { return true }
        return persistAndStartLocalExecution(
            handoff: handoff, requestId: requestId, conversationStore: conversationStore,
            toolRuntime: toolRuntime, liveActivityController: liveActivityController,
            saveMiniAppIfPresent: saveMiniAppIfPresent
        )
    }

    /// A foreground checkpoint can be hydrated without owning an execution task.
    /// Adopt only that same run; ordinary duplicate starts retain their existing policy.
    func startForegroundHandoff(
        handoff: IOSChatBackgroundHandoff,
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime,
        liveActivityController: AgentLiveActivityController,
        saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)? = nil
    ) -> Bool {
        guard handoff.mode == .continueModel else { return false }
        WatchTaskCoordinator.shared.registerRun(runId: handoff.runId, startedAt: handoff.startedAt)
        // Normal startup hydration may populate the cache, so validate after it.
        if registersPersistedTasksOnStart { configure() }
        let requestId = requestIdentifier(for: handoff.runId)
        if let cached = activeJobs[requestId] {
            guard cached.mode == .continueModel,
                  cached.runId == handoff.runId, taskMap()[requestId] == handoff.runId,
                  activeBackgroundTasks[requestId] == nil,
                  activeDetachedResponseTasks[requestId] == nil else { return false }
        }
        return persistAndStartLocalExecution(
            handoff: handoff, requestId: requestId, conversationStore: conversationStore,
            toolRuntime: toolRuntime, liveActivityController: liveActivityController,
            saveMiniAppIfPresent: saveMiniAppIfPresent
        )
    }

    /// Keep the previous owner intact until the next payload is durable.
    func persistAndStartLocalExecution(
        handoff: IOSChatBackgroundHandoff, requestId: String,
        conversationStore: IOSConversationStore, toolRuntime: ChatToolRuntime,
        liveActivityController: AgentLiveActivityController,
        saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
    ) -> Bool {
        do {
            try persist(handoff: handoff, requestId: requestId)
        } catch {
            NSLog("[AmberChatBG] Failed to persist background payload: \(error)")
            return false
        }
        activeJobs[requestId] = runtimeJob(
            handoff: handoff,
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            liveActivityController: liveActivityController,
            saveMiniAppIfPresent: saveMiniAppIfPresent
        )
        remember(runId: handoff.runId, requestId: requestId)
        startLocalExecution(requestId: requestId, subtitle: handoff.params.model.displayName)
        return true
    }

    /// Like the foreground kernel, child runs start while the App owns them.
    /// KeepAlive alone chooses audio or continued-processing execution rights.
    func startLocalExecution(requestId: String, subtitle: String) {
        let execution = IOSChatBackgroundExecution(
            identifier: requestId, keepAlive: keepAlive,
            leaseId: chatBackgroundAudioLeaseId(for: requestId)
        )
        activeBackgroundTasks[requestId] = execution
        beginChatBackgroundKeepAlive(
            requestId: requestId, subtitle: subtitle, submitSystemFallback: true,
            onExpire: { [weak self, weak execution] in
                guard let self, let execution,
                      self.activeBackgroundTasks[requestId] === execution else { return }
                execution.expirationHandler?()
            }
        )
        Task { @MainActor [weak self] in
            guard let self, self.activeBackgroundTasks[requestId] === execution else { return }
            await self.handle(execution)
        }
    }

    /// Persist the first server-owned Responses cursor without submitting a
    /// second model run. The existing payload/task map becomes the single
    /// cold-start owner; later sequence updates stay in memory because resume
    /// replays this response from its beginning.
    func checkpointDurableResponse(_ handoff: IOSChatBackgroundHandoff) -> Bool {
        guard handoff.mode == .resumeResponse,
              handoff.responseId != nil else {
            return false
        }
        WatchTaskCoordinator.shared.registerRun(
            runId: handoff.runId,
            startedAt: handoff.startedAt
        )
        let requestId = requestIdentifier(for: handoff.runId)
        guard register(requestId: requestId) else { return false }
        do {
            try persist(handoff: handoff, requestId: requestId)
        } catch {
            NSLog("[AmberChatBG] Failed to persist durable response checkpoint: \(error)")
            return false
        }
        remember(runId: handoff.runId, requestId: requestId)
        refreshCachedCheckpoint(handoff, requestId: requestId)
        return true
    }

    /// Advance the foreground owner's durable payload without starting or ending its run.
    func checkpointForegroundContinuation(_ handoff: IOSChatBackgroundHandoff) -> Bool {
        let requestId = requestIdentifier(for: handoff.runId)
        guard handoff.mode == .continueModel, handoff.responseId == nil,
              taskMap()[requestId] == handoff.runId,
              activeBackgroundTasks[requestId] == nil,
              activeDetachedResponseTasks[requestId] == nil else { return false }
        do {
            try persist(handoff: handoff, requestId: requestId)
        } catch {
            NSLog("[AmberChatBG] Failed to advance foreground checkpoint: \(error)")
            return false
        }
        refreshCachedCheckpoint(handoff, requestId: requestId)
        return true
    }

    private func refreshCachedCheckpoint(_ handoff: IOSChatBackgroundHandoff, requestId: String) {
        guard let cached = activeJobs[requestId], cached.runId == handoff.runId,
              activeBackgroundTasks[requestId] == nil,
              activeDetachedResponseTasks[requestId] == nil else { return }
        activeJobs[requestId] = runtimeJob(
            handoff: handoff, conversationStore: cached.conversationStore,
            toolRuntime: cached.toolRuntime, liveActivityController: cached.liveActivityController,
            saveMiniAppIfPresent: cached.saveMiniAppIfPresent
        )
    }

    func discardDurableResponse(runId: String) {
        let requestIds = taskMap().filter { $0.value == runId }.map(\.key)
        for requestId in requestIds {
            activeDetachedResponseTasks[requestId]?.cancel()
            activeDetachedResponseJobs.removeValue(forKey: requestId)?.cancel(cause: nil)
            activeDetachedResponseCompletions.removeValue(forKey: requestId)?
                .resolve(.disconnected("discarded"))
        }
        finish(runId: runId)
    }

    /// Reattach server-owned Responses runs left by suspension or process
    /// termination. Non-durable payloads remain owned by the existing stale
    /// sweep and are closed as retryable failures.
    func resumeDetachedResponsesIfNeeded() {
#if DEBUG
        if let override = resumeDetachedResponsesOverrideForTesting { override(); return }
#endif
        for (requestId, _) in taskMap() {
            guard activeBackgroundTasks[requestId] == nil,
                  activeDetachedResponseTasks[requestId] == nil,
                  let job = job(for: requestId),
                  job.mode == .resumeResponse,
                  job.responseId != nil else {
                continue
            }
            // Task { @MainActor } 要等下一拍才跑；退后台时这一拍就会被挂起。
            // 必须在派发前就把音频腿拉起来，不能等 resumeDetachedResponse 的首个 await。
            beginChatBackgroundKeepAlive(
                requestId: requestId,
                subtitle: job.params.model.displayName,
                submitSystemFallback: true
            )
            activeDetachedResponseTasks[requestId] = Task { @MainActor [weak self] in
                guard let self else { return }
                if Task.isCancelled {
                    return
                }
                await self.resumeDetachedResponse(job: job, requestId: requestId)
                self.activeDetachedResponseTasks.removeValue(forKey: requestId)
                self.activeDetachedResponseJobs.removeValue(forKey: requestId)
                self.activeDetachedResponseCompletions.removeValue(forKey: requestId)
            }
        }
    }

    /// Resume an ordinary provider stream after the system ended its background
    /// execution window. This is intentionally same-process and at most once.
    func resumeRecoverableJobsIfNeeded() {
        for requestId in backgroundInterruptedRequestIds {
            guard !foregroundResumeInFlightRequestIds.contains(requestId),
                  let job = activeJobs[requestId] else { continue }
            foregroundResumeInFlightRequestIds.insert(requestId)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.foregroundResumeInFlightRequestIds.remove(requestId) }
                await self.resumeRecoverableJob(job: job, requestId: requestId)
            }
        }
    }

    func hasActiveJob(conversationId: KotlinUuid) -> Bool {
        !jobs(conversationId: conversationId).isEmpty
    }

    func isWaitingForForegroundResume(conversationId: KotlinUuid) -> Bool {
        jobs(conversationId: conversationId).keys.contains { requestId in
            backgroundInterruptedRequestIds.contains(requestId)
                || foregroundResumeInFlightRequestIds.contains(requestId)
                || (automaticallyResumedRequestIds.contains(requestId)
                    && activeBackgroundTasks[requestId] == nil)
        }
    }

    /// P1-e: 后台活跃 job 总数（并发限额的活注册表计数源；与 restorableRunIds
    /// 同集合，activeJobs 内每个 job 均有持久化 payload）。
    var activeJobCount: Int {
        activeJobs.count
    }

    var activeSubAgentJobCount: Int {
        activeJobs.values.filter { $0.subAgentTimeoutSeconds != nil }.count
    }

    var activeModelCounts: [String: Int] {
        Dictionary(grouping: activeJobs.values, by: { $0.params.model.id.toHexDashString() }).mapValues(\.count)
    }

    var activeProviderCounts: [String: Int] {
        Dictionary(grouping: activeJobs.values, by: { $0.providerSetting.id.toHexDashString() }).mapValues(\.count)
    }

    /// A released runtime owner can still have a durable result waiting to be
    /// reconciled. Backup restore must wait for that write as well as live jobs.
    var hasPendingConversationWrites: Bool {
        !activeJobs.isEmpty || !activeDetachedResponseTasks.isEmpty || !taskMap().isEmpty
    }

    func activeRunId(conversationId: KotlinUuid) -> String? {
        jobs(conversationId: conversationId).values.max { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.runId < rhs.runId
            }
            return lhs.startedAt < rhs.startedAt
        }?.runId
    }

    /// P1-c: 按 hex-dash conversation id 查活跃后台 run（编排服务 interrupt 用，
    /// 避免在 Swift 侧重建 KotlinUuid）。
    func activeRunId(conversationHex: String) -> String? {
        activeJobs.values
            .filter { String(describing: $0.conversationId) == conversationHex }
            .max { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.runId < rhs.runId
                }
                return lhs.startedAt < rhs.startedAt
            }?
            .runId
    }

    /// Read-only presentation projection. Durable runs survive page/app reloads;
    /// a live owner wins while a newer run is entering or leaving the ledger.
    func subAgentRunStatuses(conversationHexes: [String]) async -> [String: String] {
        guard !conversationHexes.isEmpty else { return [:] }
        let requested = Set(conversationHexes.map { $0.lowercased() })
        let durable = await IOSThreadOrchestrationToolService.latestRunStatusByConversation(
            agentRuntimeDao: db.agentRuntimeDao()
        )
        var result: [String: String] = [:]
        for (id, status) in durable where requested.contains(id.lowercased()) {
            result[id.lowercased()] = status
        }
        for job in activeJobs.values {
            let id = job.conversationId.toHexDashString().lowercased()
            guard requested.contains(id) else { continue }
            // Ownership also survives permission/recovery pauses. Read this
            // exact run instead of presenting every retained job as running.
            let snapshot = try? await runStore.snapshot(runId: job.runId)
            result[id] = snapshot?.status.name ?? "running"
        }
        return result
    }

    /// Exact in-memory owner projection for the cross-conversation activity
    /// surface. The observer has already read the durable run row; this method
    /// only refines a durable `running` row when this coordinator owns the same
    /// run. It never hydrates a payload or invents an owner for an unknown id.
    func subAgentExecutionState(runId: String) -> String? {
        guard !runId.isEmpty,
              let active = activeJobs.first(where: { $0.value.runId == runId }) else {
            return nil
        }
        let requestId = active.key
        if outcomeUnknownRequestIds.contains(requestId) || toolRecoveryInFlightRequestIds.contains(requestId) {
            return "outcome_unknown"
        }
        if backgroundInterruptedRequestIds.contains(requestId)
            || foregroundResumeInFlightRequestIds.contains(requestId) {
            return "resumable"
        }
        if activeBackgroundTasks[requestId] != nil
            || activeDetachedResponseTasks[requestId] != nil
            || activeDetachedResponseJobs[requestId] != nil {
            return "running"
        }
        // The retained payload/system request exists, but no callback or
        // detached transport is executing it at this instant.
        return "created"
    }

    /// Public, run-bound output for the detail sheet. The returned messages are
    /// only the current run's suffix after its original display baseline;
    /// prompts, fork history and reasoning parts are never returned here.
    func subAgentPublicOutput(runId: String) -> IOSSubAgentOutputSnapshot? {
        guard let active = activeJobs.first(where: { $0.value.runId == runId }) else {
            return nil
        }
        let job = active.value
        let current = job.messagesSnapshot.messages
        let messages: [UIMessage]
        switch job.mode {
        case .continueModel:
            messages = Self.reconciledMessages(
                resultMessages: current,
                uploadMessageCount: job.uploadMessages.count,
                displayMessages: job.displayMessages
            )
        case .resumeResponse, .singleToolOnly:
            // Durable Responses already accumulate displayMessages as their
            // prefix. Their upload baseline may be shorter after compaction;
            // remapping through uploadMessages would turn old display content
            // into a false current-run suffix.
            messages = current
        }
        let generated = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: messages,
            displayMessages: job.runDisplayBaseline
        )
        return IOSSubAgentOutputProjection.snapshot(messages: generated, isFinal: false)
    }

    @discardableResult
    func cancelActiveJob(conversationId: KotlinUuid) -> Bool {
        if let runId = activeRunId(conversationId: conversationId) {
            return cancelJob(runId: runId)
        }
        for requestId in taskMap().keys where activeJobs[requestId] == nil {
            _ = job(for: requestId)
        }
        guard let runId = activeRunId(conversationId: conversationId) else { return false }
        return cancelJob(runId: runId)
    }

    func cancelJobs(conversationId: KotlinUuid) {
        let matchingJobs = jobs(conversationId: conversationId)
        for (requestId, job) in matchingJobs {
            _ = cancelJob(requestId: requestId, job: job)
        }
    }

    @discardableResult
    func cancelJob(runId: String) -> Bool {
        if let match = activeJobs.first(where: { $0.value.runId == runId }) {
            return cancelJob(requestId: match.key, job: match.value)
        }
        guard let requestId = taskMap().first(where: { $0.value == runId })?.key,
              let job = job(for: requestId) else {
            return false
        }
        return cancelJob(requestId: requestId, job: job)
    }

    @discardableResult
    private func cancelJob(requestId: String, job: IOSChatBackgroundRuntimeJob) -> Bool {
        guard !toolRecoveryInFlightRequestIds.contains(requestId),
              !outcomeUnknownRequestIds.contains(requestId) else { return false }
        let isWaitingForRecovery = backgroundInterruptedRequestIds.contains(requestId)
            || foregroundResumeInFlightRequestIds.contains(requestId)
        let expiredRunState = isWaitingForRecovery ? activeRunStates[requestId] : nil
        let runState = isWaitingForRecovery
            ? IOSChatBackgroundRunState()
            : (activeRunStates[requestId] ?? IOSChatBackgroundRunState())
        activeRunStates[requestId] = runState
        if isWaitingForRecovery {
            backgroundInterruptedRequestIds.remove(requestId)
            foregroundResumeInFlightRequestIds.remove(requestId)
            automaticallyResumedRequestIds.remove(requestId)
            publishStateEvent(for: job)
        }
        guard runState.cancelAndReserveTerminal(),
              runState.finalizeTerminal(as: .cancellation) else {
            return false
        }
        IOSPhoneControlController.shared.revoke(runID: job.runId)
        subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
        cancelDetachedResponseTransport(requestId: requestId, job: job)
        keepAlive.abandonSystemAssertion(chatBackgroundAudioLeaseId(for: requestId), preservingAdoptedTask: true)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)
        Task { @MainActor [originalJob = job] in
            await expiredRunState?.waitForExpiredOperationExit()
            await runState.waitForExpiredOperationExit()
            await IOSPhoneControlController.shared.stop(runID: originalJob.runId)
            let job: IOSChatBackgroundRuntimeJob
            if originalJob.mode == .continueModel {
                guard let prepared = await self.prepareOrdinaryJobForResume(job: originalJob, requestId: requestId) else {
                    if self.activeJobs[requestId]?.runId == originalJob.runId {
                        _ = await self.recordRun(originalJob.runId, status: .recoveryPending,
                                                conversationId: originalJob.conversationId)
                        self.releaseRuntimeOwnership(requestId: requestId)
                    }
                    return
                }
                job = prepared
            } else {
                job = originalJob
            }
            let latestMessages = Self.reconciledMessages(
                resultMessages: job.messagesSnapshot.messages,
                uploadMessageCount: job.uploadMessages.count,
                displayMessages: job.displayMessages
            )
            let cancelledMessages: [UIMessage]
            if job.toolRuntime.hasUnresolvedToolCall(in: latestMessages) {
                cancelledMessages = job.toolRuntime.messagesByFailingPendingToolCalls(
                    in: latestMessages,
                    failureReason: IOSAppLocalization.string(
                        "User cancelled.",
                        defaultValue: "User cancelled."
                    ),
                    denied: true
                )
            } else {
                cancelledMessages = latestMessages
            }
            let didPersistTerminal: Bool
            switch job.mode {
            case .continueModel, .resumeResponse:
                didPersistTerminal = await job.conversationStore.saveBackgroundCompletion(
                    baseMessages: job.runDisplayBaseline,
                    completedMessages: cancelledMessages,
                    to: job.conversationId
                )
            case .singleToolOnly:
                didPersistTerminal = await job.conversationStore.saveBackgroundToolCompletion(
                    baseMessages: job.displayMessages,
                    completedMessages: cancelledMessages,
                    to: job.conversationId
                )
            }
            if didPersistTerminal {
                await IOSRunRecovery.reconcilePersistedToolResults(runId: job.runId)
            }
            let runRecordResult = await self.recordRunResult(
                job.runId,
                status: didPersistTerminal ? .cancelled : .recoveryPending,
                conversationId: job.conversationId
            )
            guard runRecordResult == .recorded else {
                if runRecordResult == .conflict {
                    let backgroundTask = self.activeBackgroundTasks[requestId]
                    if runState.claimSystemTaskCompletion() {
                        backgroundTask?.setTaskCompleted(success: false)
                    }
                    self.finish(runId: job.runId, requestId: requestId)
                } else {
                    self.releaseRuntimeOwnership(requestId: requestId)
                }
                return
            }
            if didPersistTerminal {
                await self.notifyRunTerminal(job: job, runId: job.runId, finalMessages: cancelledMessages)
            }
            _ = job.liveActivityController.adoptExistingActivity(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString()
            )
            WatchTaskCoordinator.shared.publish(
                runId: job.runId,
                conversationId: job.conversationId.toHexDashString(),
                presentation: didPersistTerminal ? .cancelled() : .failed(),
                summary: didPersistTerminal
                    ? nil
                    : IOSAppLocalization.string(
                        "已停止生成，但工具取消状态保存失败。",
                        defaultValue: "已停止生成，但工具取消状态保存失败。"
                    )
            )
            await job.liveActivityController.end(
                runId: job.runId,
                presentation: didPersistTerminal ? .cancelled() : .failed()
            )
            let backgroundTask = self.activeBackgroundTasks[requestId]
            // 取消是不可恢复的远端语义：即便 transcript 保存失败、run 行需
            // 保留 recoveryPending 供本地对账，也不能留下 resumeResponse 的
            // task-map/payload owner，否则冷启动会把已取消的服务端响应重新拉起。
            if runState.claimSystemTaskCompletion() {
                self.finish(runId: job.runId, requestId: requestId)
                backgroundTask?.setTaskCompleted(success: false)
            }
        }
        return true
    }

    private func register(requestId: String) -> Bool {
#if DEBUG
        if let override = registerRequestOverrideForTesting { return override(requestId) }
#endif
        guard requestId.hasPrefix(requestPrefix) else {
            NSLog("[AmberChatBG] Refusing to register unexpected BGContinuedProcessingTask id \(requestId); expected prefix \(requestPrefix)")
            return false
        }
        guard !registeredRequestIds.contains(requestId) else { return true }

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: requestId, using: .main) { @MainActor [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // 显式使用主队列以匹配 MainActor；在把工作排进 async handler 前先登记，冷启动
            // sweep 才不会把刚被系统唤起的 request 当成 stale。
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let execution = IOSChatBackgroundExecution(
                identifier: task.identifier, systemTask: task, keepAlive: self.keepAlive,
                leaseId: self.chatBackgroundAudioLeaseId(for: task.identifier)
            )
            self.activeBackgroundTasks[task.identifier] = execution
            Task { @MainActor in
                await self.handle(execution)
            }
        }
        if registered {
            registeredRequestIds.insert(requestId)
        } else {
            NSLog("[AmberChatBG] BGContinuedProcessingTask registration failed for \(requestId); permitted pattern \(permittedIdentifier)")
        }
        return registered
    }

    /// Builds the background run's exposure bridge. When the handoff carries
    /// the full catalog the bridge is rebuilt over it (lazy mode stays on and
    /// tool_search can search everything); otherwise it falls back to the
    /// handoff's visible tool subset. Either way the bridge's initial exposure
    /// is seeded with the tools that were visible at handoff time, so the
    /// per-round `replacingTools(visibleTools())` refresh does not drop tools
    /// the foreground had already exposed.
    static func makeBackgroundToolExposureBridge(
        fullToolNames: [String],
        handoffVisibleTools: [Tool],
        additionalDeclarations: [Tool] = [],
        dynamicSearchInfo: [String: String] = [:]
    ) -> IosToolExposureBridge {
        let bridge: IosToolExposureBridge
        if !fullToolNames.isEmpty {
            var rebuilt = ToolKt.iosToolDeclarations(names: fullToolNames)
            let rebuiltNames = Set(rebuilt.map(\.name))
            // P0-b: dynamic `mcp__*` declarations cannot be rebuilt from a
            // name (the payload has no server/tool directory), so exclude them
            // from the static mismatch check and append the regenerated ones.
            let staticNames = fullToolNames.filter {
                !ToolKt.isExpandedMcpToolName(name: $0)
                    && !IOSDynamicToolRegistry.isDynamicWorkflowToolName($0)
                    && !IOSPhoneControlToolCatalog.isPhoneTool(name: $0)
            }
            if rebuiltNames != Set(staticNames) {
                backgroundToolExposureLogger.error(
                    "background bridge catalog mismatch: \(rebuilt.count)/\(staticNames.count) declarations rebuilt — a tool name is missing from KMP iosToolDeclaration"
                )
            }
            for tool in additionalDeclarations where !rebuiltNames.contains(tool.name) {
                rebuilt.append(tool)
            }
            bridge = IosToolExposureBridge(tools: rebuilt, recipeSearchInfo: dynamicSearchInfo)
        } else {
            bridge = IosToolExposureBridge(tools: handoffVisibleTools, recipeSearchInfo: dynamicSearchInfo)
        }
        bridge.exposeToolNames(names: handoffVisibleTools.map(\.name))
        return bridge
    }

    func runtimeJob(
        handoff: IOSChatBackgroundHandoff,
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime,
        liveActivityController: AgentLiveActivityController,
        saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
    ) -> IOSChatBackgroundRuntimeJob {
        // P0-a Fix C: rebuild the exposure bridge over the FULL catalog when
        // the handoff carried it (foreground bridges are built from the full
        // static declarations, so lazy mode stays on and tool_search searches
        // the whole catalog — hits become callable on the next round via
        // IOSAgentToolEngine's per-round params refresh). Legacy payloads
        // without fullToolNames fall back to the previous behavior (visible
        // subset from handoff.params.tools, which may disable lazy mode).
        let dynamicDescriptors = handoff.dynamicToolSnapshot?.backgroundEligibleDescriptors
            .filter { handoff.fullToolNames.contains($0.toolId) } ?? []
        let dynamicDeclarations = dynamicDescriptors.map { descriptor in
            IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
                toolId: descriptor.toolId,
                version: descriptor.version,
                description: descriptor.description,
                inputsJson: descriptor.inputsJSON,
                effectClass: descriptor.effectClassRawValue
            )
        }
        // Rebuild only the original run's phone catalog. A global switch or
        // a new pending grant must never expand a restored task's authority.
        let phoneDeclarations = IOSPhoneControlToolCatalog.declarations.filter {
            handoff.fullToolNames.contains($0.name)
        }
        let backgroundBridge = Self.makeBackgroundToolExposureBridge(
            fullToolNames: handoff.fullToolNames,
            handoffVisibleTools: handoff.params.tools,
            // P0-b: regenerate the dynamic MCP surface from the runtime's own
            // directory so background tool_search can expose (and the engine
            // can execute) `mcp__*` tools like the foreground run could.
            additionalDeclarations: {
                let mcpDeclarations = toolRuntime.mcpExpandedDeclarations()
                guard !handoff.fullToolNames.isEmpty else {
                    return mcpDeclarations + dynamicDeclarations + phoneDeclarations
                }
                return mcpDeclarations.filter { handoff.fullToolNames.contains($0.name) }
                    + dynamicDeclarations + phoneDeclarations
            }(),
            dynamicSearchInfo: Dictionary(uniqueKeysWithValues: dynamicDescriptors.map {
                ($0.toolId, $0.searchInfoJSON)
            })
        )
        return IOSChatBackgroundRuntimeJob(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: handoff.conversationId,
            providerSetting: handoff.providerSetting,
            params: handoff.params,
            uploadMessages: handoff.uploadMessages,
            displayMessages: handoff.displayMessages,
            runDisplayBaseline: handoff.runDisplayBaseline ?? handoff.displayMessages,
            mode: handoff.mode,
            fullToolNames: handoff.fullToolNames,
            dynamicToolSnapshot: handoff.dynamicToolSnapshot,
            responseId: handoff.responseId,
            responseSequenceNumber: handoff.responseSequenceNumber,
            generativeUiRequirement: handoff.generativeUiRequirement,
            generativeUiFallbackAttempted: handoff.generativeUiFallbackAttempted,
            executionPolicy: handoff.executionPolicy,
            subAgentTimeoutSeconds: handoff.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: handoff.phoneAutomaticReasoning,
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            liveActivityController: liveActivityController,
            saveMiniAppIfPresent: saveMiniAppIfPresent,
            messagesSnapshot: IOSChatBackgroundMessagesSnapshot(
                handoff.mode == .resumeResponse ? handoff.displayMessages : handoff.uploadMessages
            ),
            toolExposureBridge: backgroundBridge
        )
    }

    /// 可见输出续期 Live Activity 的过期时间。节流在 runState 锁内完成，
    /// 逐 chunk 调用只在满间隔时才开一个 MainActor 任务。
    nonisolated static func noteVisibleProgress(
        _ runState: IOSChatBackgroundRunState,
        job: IOSChatBackgroundRuntimeJob
    ) {
        guard runState.noteVisibleDelta() else { return }
        let runId = job.runId
        let controller = job.liveActivityController
        Task { @MainActor in
            controller.noteProgress(runId: runId)
        }
    }

    nonisolated func reportPhoneWorkProgress(
        units: Int64, runId: String, requestId: String,
        runState: IOSChatBackgroundRunState, execution: IOSChatBackgroundExecution
    ) {
        guard units > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeJobs[requestId]?.runId == runId,
                  self.activeRunStates[requestId] === runState,
                  self.activeBackgroundTasks[requestId] === execution,
                  runState.allowsRunningPresentation,
                  IOSPhoneControlController.shared.handoffState(runID: runId) != nil else { return }
            execution.advancePhoneWorkProgress(by: units)
        }
    }

    /// Phone receipts and engine stages must share the background stream. Direct ActivityKit
    /// updates could otherwise be overwritten by older stages still waiting in its consumer.
    static func routingPhoneActivity(
        executors: [String: any IOSToolExecutor],
        runID: String,
        events: AsyncStream<AgentActivityPresentation>.Continuation
    ) -> [String: any IOSToolExecutor] {
        var routed = executors
        let phoneExecutor = IOSPhoneControlToolExecutor(runID: runID, reportActivity: { phase in
            events.yield(.phoneControl(phase))
        })
        for name in IOSPhoneControlToolCatalog.toolNames where routed[name] != nil {
            routed[name] = phoneExecutor
        }
        return routed
    }

    func publishRunningPresentation(
        _ presentation: AgentActivityPresentation,
        for job: IOSChatBackgroundRuntimeJob,
        runState: IOSChatBackgroundRunState
    ) async {
        guard runState.allowsRunningPresentation else { return }
        WatchTaskCoordinator.shared.publish(
            runId: job.runId,
            conversationId: job.conversationId.toHexDashString(),
            presentation: presentation
        )
        await job.liveActivityController.update(
            runId: job.runId,
            presentation: presentation,
            force: true
        )
    }

    /// Release the in-process/system-task owner while retaining the task map
    /// and payload for the existing cold-start reconciliation pass.
    func releaseRuntimeOwnership(requestId: String) {
        subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
        let job = activeJobs[requestId]
        if let job { IOSPhoneControlController.shared.revoke(runID: job.runId) }
        if let backgroundTask = activeBackgroundTasks[requestId] {
            let runState = activeRunStates[requestId]
            if runState == nil || runState?.claimSystemTaskCompletion() == true {
                backgroundTask.setTaskCompleted(success: false)
            }
        }
        activeJobs.removeValue(forKey: requestId)
        activeRunStates.removeValue(forKey: requestId)
        activeBackgroundTasks.removeValue(forKey: requestId)
        backgroundInterruptedRequestIds.remove(requestId)
        foregroundResumeInFlightRequestIds.remove(requestId)
        automaticallyResumedRequestIds.remove(requestId)
        toolRecoveryInFlightRequestIds.remove(requestId)
        outcomeUnknownRequestIds.remove(requestId)
        endChatBackgroundAudioKeepAlive(requestId: requestId)
        if let job {
            publishStateEvent(for: job)
        }
    }

    /// Drop the expired system-task owner but keep the runtime job and payload
    /// for one foreground retry in this process.
    func pauseRuntimeOwnership(requestId: String) {
        if let job = activeJobs[requestId] { IOSPhoneControlController.shared.revoke(runID: job.runId) }
        subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
        activeBackgroundTasks.removeValue(forKey: requestId)
        endChatBackgroundAudioKeepAlive(requestId: requestId)
    }

    func job(for requestId: String) -> IOSChatBackgroundRuntimeJob? {
        if let job = activeJobs[requestId] { return job }
        guard let dependencies,
              let handoff = loadHandoff(requestId: requestId) else {
            return nil
        }
        WatchTaskCoordinator.shared.registerRun(
            runId: handoff.runId,
            startedAt: handoff.startedAt
        )
        let job = runtimeJob(
            handoff: handoff,
            conversationStore: dependencies.conversationStore,
            toolRuntime: dependencies.toolRuntime,
            liveActivityController: dependencies.liveActivityController,
            saveMiniAppIfPresent: dependencies.saveMiniAppIfPresent
        )
        activeJobs[requestId] = job
        return job
    }

    private func jobs(conversationId: KotlinUuid) -> [String: IOSChatBackgroundRuntimeJob] {
        return activeJobs.filter { _, job in
            String(describing: job.conversationId) == String(describing: conversationId)
        }
    }

#if DEBUG
    static func rehydratedModeForTesting(_ rawValue: String) -> IOSChatBackgroundHandoffMode? {
        rehydratedMode(rawValue)
    }

    static func canAutomaticallyResumeOrdinaryJobForTesting(
        mode: IOSChatBackgroundHandoffMode,
        hasDeclaredTools: Bool
    ) -> Bool {
        canAutomaticallyResumeOrdinaryJob(
            mode: mode,
            hasDeclaredTools: hasDeclaredTools
        )
    }

    static func ordinaryRecoveryAllowsResumeForTesting(
        actions: [IOSToolCallRecoveryAction]
    ) -> Bool {
        !actions.contains(where: isOutcomeUnknownRecoveryAction)
    }

    static func ordinaryRecoveryActionForTesting(
        state: IOSToolTransactionState,
        outcome: String?,
        planned: IOSToolCallRecoveryAction
    ) -> IOSToolCallRecoveryAction {
        ordinaryRecoveryAction(state: state, outcome: outcome, planned: planned)
    }

    static func rehydratedParamsForTesting(
        persistedParams: TextGenerationParams,
        providerSetting: ProviderSetting,
        assistantHeaders: [CustomHeader],
        assistantBodies: [CustomBody],
        conversationId: String? = nil
    ) -> TextGenerationParams? {
        rehydratedParams(
            persistedParams: persistedParams,
            providerSetting: providerSetting,
            assistantHeaders: assistantHeaders,
            assistantBodies: assistantBodies,
            conversationId: conversationId
        )
    }

    static func backgroundSummaryForTesting(messages: [UIMessage]) -> String? {
        backgroundSummary(from: messages)
    }

    static func backgroundTerminalStatusForTesting(
        didSave: Bool,
        singleToolFailureReason: String?,
        guardStopped: Bool,
        miniAppFailed: Bool = false,
        hitStepLimit: Bool = false,
        generativeUiRepairFailed: Bool = false
    ) -> String {
        backgroundTerminalStatus(
            didSave: didSave,
            singleToolFailureReason: singleToolFailureReason,
            guardStopped: guardStopped,
            miniAppFailed: miniAppFailed,
            hitStepLimit: hitStepLimit,
            generativeUiRepairFailed: generativeUiRepairFailed
        ).wireName
    }

    static func preservesOutcomeUnknownStaleRecoveryForTesting(
        runStatus: AgentRunStatus?,
        transactionStates: [IOSToolTransactionState]?
    ) -> Bool {
        preservesOutcomeUnknownStaleRecovery(
            runStatus: runStatus,
            transactionStates: transactionStates
        )
    }

    static func failedMessagesForTesting(
        displayMessages: [UIMessage],
        preservedGeneratedSuffix: [UIMessage] = [],
        partialAssistantText: String?,
        rawMessage: String,
        modelId: String
    ) -> [UIMessage] {
        failedMessages(
            displayMessages: displayMessages,
            preservedGeneratedSuffix: preservedGeneratedSuffix,
            partialAssistantText: partialAssistantText,
            rawMessage: rawMessage,
            modelId: modelId
        )
    }

    static func reconciledMessagesForTesting(
        resultMessages: [UIMessage],
        uploadMessageCount: Int,
        displayMessages: [UIMessage]
    ) -> [UIMessage] {
        reconciledMessages(
            resultMessages: resultMessages,
            uploadMessageCount: uploadMessageCount,
            displayMessages: displayMessages
        )
    }

    /// 只落盘 cursor owner，不进 `activeJobs`。对应生产 `checkpointDurableResponse`
    /// 在 detach 后、尚未 `start(.resumeResponse)` 的窗口；测试里绕过
    /// `BGTaskScheduler.register`（XCTest 进程里动态 id 常会失败）。
    @discardableResult
    func persistDurableResponseCheckpointForTesting(_ handoff: IOSChatBackgroundHandoff) -> Bool {
        guard handoff.mode == .resumeResponse, handoff.responseId != nil else {
            return false
        }
        return persistBackgroundCheckpointForTesting(handoff)
    }

    @discardableResult
    func persistBackgroundCheckpointForTesting(_ handoff: IOSChatBackgroundHandoff) -> Bool {
        let requestId = requestIdentifier(for: handoff.runId)
        do {
            try persist(handoff: handoff, requestId: requestId)
        } catch {
            return false
        }
        remember(runId: handoff.runId, requestId: requestId)
        return true
    }

    @discardableResult
    func hydrateDurableResponseForTesting(
        _ handoff: IOSChatBackgroundHandoff,
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime,
        sharedSettings: IOSSharedSettingsStore
    ) -> Bool {
        let requestId = requestIdentifier(for: handoff.runId)
        var didHydrate = false
        withDependenciesForTesting(
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            sharedSettings: sharedSettings
        ) {
            didHydrate = job(for: requestId) != nil
        }
        return didHydrate
    }

    /// Simulate the ownership barrier after a terminal background job without
    /// registering a real BGTask. The callback is scheduled only after
    /// `finish` has removed the active job, matching the production ordering.
    func finishForTesting(
        _ handoff: IOSChatBackgroundHandoff,
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime
    ) {
        let requestId = requestIdentifier(for: handoff.runId)
        activeJobs[requestId] = runtimeJob(
            handoff: handoff,
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            liveActivityController: .shared,
            saveMiniAppIfPresent: nil
        )
        remember(runId: handoff.runId, requestId: requestId)
        finish(requestId: requestId)
    }

    /// 临时换依赖供 `job(for:)` 水合，不走 `configure()` 的 task-map 预热
    /// （预热会把 payload 填进 `activeJobs`，掩盖「只按 runId 取消」的缺口）。
    func withDependenciesForTesting(
        conversationStore: IOSConversationStore,
        toolRuntime: ChatToolRuntime,
        sharedSettings: IOSSharedSettingsStore,
        _ body: () -> Void
    ) {
        let previous = dependencies
        dependencies = IOSChatBackgroundDependencies(
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            sharedSettings: sharedSettings,
            liveActivityController: .shared,
            saveMiniAppIfPresent: nil
        )
        defer { dependencies = previous }
        body()
    }
#endif

    private func requestIdentifier(for runId: String) -> String {
        requestPrefix + String(runId.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        })
    }

    private func remember(runId: String, requestId: String) {
        var map = taskMap()
        map[requestId] = runId
        UserDefaults.standard.set(map, forKey: taskMapKey)
    }

    func finish(
        runId: String? = nil,
        requestId: String? = nil,
        removePayload shouldRemovePayload: Bool = true
    ) {
        var map = taskMap()
        var finishedRunIds = Set<String>()
        if let runId {
            finishedRunIds.insert(runId)
        }
        if let requestId, let mappedRunId = map[requestId] {
            finishedRunIds.insert(mappedRunId)
        }
        var terminatedJobs: [IOSChatBackgroundRuntimeJob] = []
        if let requestId {
            backgroundInterruptedRequestIds.remove(requestId)
            foregroundResumeInFlightRequestIds.remove(requestId)
            automaticallyResumedRequestIds.remove(requestId)
            toolRecoveryInFlightRequestIds.remove(requestId)
            outcomeUnknownRequestIds.remove(requestId)
            if let job = activeJobs.removeValue(forKey: requestId) {
                terminatedJobs.append(job)
            }
            subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
            activeRunStates.removeValue(forKey: requestId)
            activeBackgroundTasks.removeValue(forKey: requestId)
            map.removeValue(forKey: requestId)
            endChatBackgroundAudioKeepAlive(requestId: requestId)
            if shouldRemovePayload {
                removePayload(requestId: requestId)
            }
        } else if let runId {
            let matching = map.filter { $0.value == runId }.map(\.key)
            for requestId in matching {
                backgroundInterruptedRequestIds.remove(requestId)
                foregroundResumeInFlightRequestIds.remove(requestId)
                automaticallyResumedRequestIds.remove(requestId)
                toolRecoveryInFlightRequestIds.remove(requestId)
                outcomeUnknownRequestIds.remove(requestId)
                if let job = activeJobs.removeValue(forKey: requestId) {
                    terminatedJobs.append(job)
                }
                subAgentTimeoutTasks.removeValue(forKey: requestId)?.cancel()
                activeRunStates.removeValue(forKey: requestId)
                activeBackgroundTasks.removeValue(forKey: requestId)
                map.removeValue(forKey: requestId)
                endChatBackgroundAudioKeepAlive(requestId: requestId)
                if shouldRemovePayload {
                    removePayload(requestId: requestId)
                }
            }
        }
        UserDefaults.standard.set(map, forKey: taskMapKey)
        for finishedRunId in finishedRunIds {
            IOSWebMountController.shared.releaseAgentOwnership(runId: finishedRunId)
            IOSPhoneControlController.shared.revoke(runID: finishedRunId)
        }
        for job in terminatedJobs {
            publishTerminalEvent(for: job)
            guard let resumePendingTasks = onRunFinishedWithPendingTasks else {
                continue
            }
            let conversationId = job.conversationId
            let providerSetting = job.providerSetting
            let params = job.params
            let toolExposureBridge = job.toolExposureBridge
            let executionPolicy = job.executionPolicy
            Task { @MainActor in
                await resumePendingTasks(
                    conversationId,
                    providerSetting,
                    params,
                    toolExposureBridge,
                    executionPolicy
                )
            }
        }
        IOSMemoryExtractionCoordinator.shared.resume()
    }

    private func publishTerminalEvent(for job: IOSChatBackgroundRuntimeJob) {
        NotificationCenter.default.post(
            name: .amberChatBackgroundJobDidTerminate,
            object: IOSChatBackgroundJobTerminalEvent(
                conversationId: String(describing: job.conversationId)
            )
        )
    }

    func publishStateEvent(for job: IOSChatBackgroundRuntimeJob) {
        NotificationCenter.default.post(
            name: .amberChatBackgroundJobStateDidChange,
            object: IOSChatBackgroundJobStateEvent(
                conversationId: String(describing: job.conversationId)
            )
        )
    }

    func taskMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: taskMapKey) as? [String: String] ?? [:]
    }

    func providerSetting(for providerId: String) -> ProviderSetting? {
        dependencies?.sharedSettings.snapshot.providers.first {
            $0.id.toHexDashString().caseInsensitiveCompare(providerId) == .orderedSame
        }
    }

    func chatBackgroundAudioLeaseId(for requestId: String) -> String {
        "chat-bg-\(requestId)"
    }

    /// New local runs and detached responses use the shared assertion owner.
    /// Legacy .chat handlers already have a system assertion and only borrow
    /// the UIKit/audio lease while persisting their terminal state.
    func beginChatBackgroundKeepAlive(
        requestId: String,
        subtitle: String,
        submitSystemFallback: Bool = false,
        onExpire: (() -> Void)? = nil
    ) {
        keepAlive.begin(
            chatBackgroundAudioLeaseId(for: requestId),
            title: IOSAppLocalization.string(
                "Amber 后台生成",
                defaultValue: "Amber 后台生成"
            ),
            subtitle: subtitle,
            onExpire: onExpire,
            submitSystemTask: submitSystemFallback
        )
    }

    func endChatBackgroundAudioKeepAlive(requestId: String) {
        keepAlive.end(chatBackgroundAudioLeaseId(for: requestId))
    }
}
