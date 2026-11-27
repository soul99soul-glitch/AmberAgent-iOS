import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import Observation
import UIKit

enum MacGatewayDecisionSource: Equatable, Sendable {
    case foregroundApp
    case notification
}

protocol MacGatewayBiometricAuthenticating: Sendable {
    func verifyForegroundApproval(reason: String) async -> Bool
}

struct MacGatewayLocalBiometricAuthenticator: MacGatewayBiometricAuthenticating {
    func verifyForegroundApproval(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
}

final class MacGatewayPersistenceCoordinator: @unchecked Sendable {
    struct PendingDialogueWrite: @unchecked Sendable {
        let generation: UInt64
        let epoch: UInt64
        let identity: String?
        let commit: @Sendable (UInt64) -> Void
    }

    private let lock = NSLock()
    private var sessionEpoch: UInt64 = 0
    private var activeIdentity: String?
    private var dialogueWriteGeneration: UInt64 = 0
    private var pendingDialogueWrite: PendingDialogueWrite?
    private var isDialogueDrainScheduled = false

    static func identity(for connection: MacGatewayConnection?) -> String? {
        guard let connection else { return nil }
        return "\(connection.gatewayId)\u{0000}\(connection.deviceId)"
    }

    @discardableResult
    func advance(connection: MacGatewayConnection?) -> (epoch: UInt64, identity: String?) {
        lock.lock()
        defer { lock.unlock() }
        sessionEpoch &+= 1
        activeIdentity = Self.identity(for: connection)
        dialogueWriteGeneration &+= 1
        pendingDialogueWrite = nil
        return (sessionEpoch, activeIdentity)
    }

    func snapshot() -> (epoch: UInt64, identity: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (sessionEpoch, activeIdentity)
    }

    func canCommit(epoch: UInt64, identity: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epoch == sessionEpoch && identity == activeIdentity
    }

    /// Replaces any queued async dialogue write with the newest snapshot (latest-wins).
    /// Returns `true` when the caller must schedule a drain pass on `persistenceQueue`.
    func enqueueLatestDialogueWrite(
        epoch: UInt64,
        identity: String?,
        commit: @escaping @Sendable (UInt64) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == sessionEpoch && identity == activeIdentity else { return false }
        dialogueWriteGeneration &+= 1
        pendingDialogueWrite = PendingDialogueWrite(
            generation: dialogueWriteGeneration,
            epoch: epoch,
            identity: identity,
            commit: commit
        )
        guard !isDialogueDrainScheduled else { return false }
        isDialogueDrainScheduled = true
        return true
    }

    func takeNextPendingDialogueWrite() -> PendingDialogueWrite? {
        lock.lock()
        defer { lock.unlock() }
        guard let write = pendingDialogueWrite else {
            isDialogueDrainScheduled = false
            return nil
        }
        pendingDialogueWrite = nil
        return write
    }

    /// Supersedes any pending async dialogue write before a synchronous commit.
    func claimImmediateDialogueWrite(epoch: UInt64, identity: String?) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == sessionEpoch && identity == activeIdentity else { return nil }
        dialogueWriteGeneration &+= 1
        pendingDialogueWrite = nil
        return dialogueWriteGeneration
    }

    func isLatestDialogueWrite(generation: UInt64, epoch: UInt64, identity: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == dialogueWriteGeneration
            && epoch == sessionEpoch
            && identity == activeIdentity
    }
}

/// Owns the Mac Gateway pairing: persistence, APNs token upload and the status shown in Settings.
@MainActor
@Observable
final class MacGatewayStore {
    static let shared = MacGatewayStore()

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    nonisolated static let legacyConnectionKey = "macGateway.connection.v1"
    nonisolated static let legacyTokenKey = "macGateway.deviceToken"
    nonisolated static let shareCalendarUpcomingKey = "macGateway.deviceContext.shareCalendar"
    nonisolated static let shareRemindersDueKey = "macGateway.deviceContext.shareReminders"
    nonisolated static let shareWorkspaceArtifactsKey = "macGateway.deviceContext.shareArtifacts"
    nonisolated static let pendingDeviceContextDeleteKey = "macGateway.deviceContext.pendingDelete"
    nonisolated static let cloudDialogueLastViewedSeqKey = "macGateway.cloudDialogue.lastViewedSeq"

    nonisolated let endpointRole: MacGatewayEndpointRole
    nonisolated var connectionStorageKey: String { endpointRole.connectionStorageKey }
    nonisolated var tokenStorageKey: String { endpointRole.tokenStorageKey }
    nonisolated var dialogueStorageKey: String { endpointRole.dialogueStorageKey }
    nonisolated var tasksStorageKey: String { endpointRole.tasksStorageKey }

    /// Independent local Mac slot owned by the root `.cloud` store so Cloud (`amberd`)
    /// and Mac (`amber-gateway`) stay paired and online simultaneously.
    @ObservationIgnored private(set) var macSlot: MacGatewayStore?
    var composerExecutionTarget: AmberComposerExecutionTarget = .local {
        didSet {
            if oldValue != composerExecutionTarget { notifyWatchRemoteStateChanged() }
        }
    }

    var effectiveComposerTarget: AmberComposerExecutionTarget {
        AmberHostSwitcherPillPolicy.normalizedTarget(composerExecutionTarget, cloudPaired: hasCloudConnection, macPaired: hasMacConnection)
    }

    /// Preferred tab when opening the unified "Amber 多终端" settings page (e.g. after scanning a QR link).
    var preferredMultiDeviceTab: AmberMultiDeviceTab = .cloud

    var mac: MacGatewayStore { macSlot ?? self }

    func slot(for role: MacGatewayEndpointRole) -> MacGatewayStore {
        switch role {
        case .cloud:
            return self
        case .mac:
            return macSlot ?? self
        }
    }

    var hasCloudConnection: Bool { connection != nil }
    var hasMacConnection: Bool { macSlot?.connection != nil }
    var hasAnyPairedEndpoint: Bool { hasCloudConnection || hasMacConnection }

    var multiDeviceSummaryText: String {
        switch (hasCloudConnection, hasMacConnection) {
        case (true, true):
            return localized("云端 · Mac")
        case (true, false):
            return localized("云端")
        case (false, true):
            return localized("Mac")
        case (false, false):
            return ""
        }
    }

    /// Debug builds are signed with `aps-environment = development` (project.yml), Release with production.
    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private(set) var connection: MacGatewayConnection? {
        didSet {
            publishBoard()
            if oldValue != connection {
                notifyWatchRemoteStateChanged()
            }
        }
    }
    private(set) var status: MacGatewayStatus? { didSet { publishBoard() } }
    /// nil until the first refresh after launch or pairing.
    var isReachable: Bool? {
        didSet {
            publishBoard()
            if oldValue != isReachable {
                notifyWatchRemoteStateChanged()
            }
        }
    }
    private(set) var isBusy = false
    private(set) var isSendingTestPush = false
    private(set) var pushError: String?
    /// Approvals being sent, by tool call id; their buttons show progress.
    private(set) var decidingCalls: Set<String> = []
    /// Tool call IDs whose remote approval was explicitly rejected with HTTP 403 by the Mac.
    /// Once marked, iOS locks the approval card to Mac-local-only approval and hides remote approve.
    private(set) var localApprovalOnlyCallIds: Set<String> = []
    /// Amber scheduled tasks on the Mac; nil until fetched, or when Amber isn't running there.
    private(set) var schedules: [MacGatewaySchedule]?
    private(set) var schedulesError: String?
    private(set) var busySchedules: Set<String> = []
    /// The Mac's task board; nil until fetched, or when Amber isn't running there (see `boardItems`).
    private(set) var board: [MacGatewayBoardItem]? { didSet { publishBoard() } }
    /// The board as shown: the Mac's, or without Amber a read-only one built from the gateway's sessions.
    /// Stored, and written only on change, so views don't re-render on every poll.
    private(set) var boardItems: [MacGatewayBoardItem] = []
    /// Cards waiting on the user; empty while unpaired or unreachable, so a stale count never shows on Home.
    private(set) var needsYouItems: [MacGatewayBoardItem] = []
    /// Why the board came from the gateway alone (Amber not running, or an older gateway).
    private(set) var boardError: String?
    /// Cloud Self (/v2) agents, per-agent activity snapshots, and persisted native tasks.
    var cloudAgents: [MacGatewayCloudAgent] = []
    var cloudAgentActivities: [String: MacGatewayCloudAgentActivity] = [:]
    var cloudTasks: [MacGatewayCloudTaskRecord] = []
    var busyCloudTaskIds: Set<String> = []
    /// Deep-linked cloud task workItemId waiting for board sheet presentation (`amber://cloud-task/{id}`).
    var pendingCloudTaskWorkItemId: String? = nil
    /// Foreground device-context sharing toggles (B1 / X3: ALL default false).
    var shareCalendarUpcomingEnabled: Bool = false
    var shareRemindersDueEnabled: Bool = false
    var shareWorkspaceArtifactsEnabled: Bool = false
    @ObservationIgnored var deviceContextMutationTask: Task<Void, Never>?
    var deviceContextMetadata: IOSDeviceContextSnapshotMetadata? = nil
    var isSyncingDeviceContext: Bool = false
    var pendingDeviceContextRemoteDelete: Bool = false
    @ObservationIgnored var lastDeviceContextPushAt: Date? = nil
    var cloudDialogueEncodedBytes: Int = 0
    var cloudDialogueLastViewedSeq: Int64 = 0
    /// Explicit Paired Cloud Main Dialogue (/v2/dialogue/* & /v2/work-items/{id}/inputs|stop) state.
    var isCloudMainDialogueSelected = false
    var cloudDialogueConversationId: String? = nil
    var cloudDialogueCursor: Int64 = 0
    var cloudDialogueEvents: [MacGatewayCloudDialogueEvent] = []
    var cloudDialogueTrimmedInputEventIds: Set<String> = []
    var cloudDialogueEntranceEventIds: Set<String> = []
    /// Low-frequency composer trigger; process/progress events do not change it.
    var cloudSuggestionReplyID: String?
    @ObservationIgnored var cloudSuggestionSequence: Int64 = 0
    var cloudDialogueReceipts: [String: MacGatewayCloudDialogueReceipt] = [:]
    var cloudDialogueFollowups: [MacGatewayCloudDialogueFollowupRecord] = []
    var cloudDialogueProgressByWorkItem: [String: MacGatewayCloudDialogueWorkItemProgress] = [:]
    var cloudDialogueSubmissions: [MacGatewayCloudDialoguePersistedSubmission] = []
    var cloudDialogueFirstSeenAtByEventId: [String: Date] = [:]
    @ObservationIgnored let cloudCompletionFeedback = ChatCompletionFeedback()
    var selectedCloudDialogueWorkItemId: String?
    var busyCloudDialogueRequestIds: Set<String> = []
    var dismissedUnifiedMacRunIds: Set<String> = []
    @ObservationIgnored var dismissedUnifiedMacRunIdOrder: [String] = []
    var cloudDialogueLastError: String?
    var cloudDialogueTransportState: MacGatewayCloudDialogueTransportState = .unknown
    /// Cloud configuration (/v2 config API): non-secret remote view plus fetch/
    /// import state. Owned here so behavior extensions in CloudConfigStore.swift
    /// stay tracked by @Observable.
    var cloudConfig: IOSCloudConfigSnapshot?
    var cloudConfigError: String?
    var cloudConfigLoading = false
    var cloudImporting = false
    /// The gateway's import kid no longer matches the pinned one — the UI shows
    /// the explicit re-trust action (`resetCloudImportKeyTrust`).
    var cloudImportKeyChanged = false
    /// Import idempotency state: the requestId is bound to the operation's
    /// semantic hash, so retries of the same selection replay while a changed
    /// selection gets a fresh id (same id + different operation → server 409).
    /// A successful receipt ends the operation — the next submit gets a new id.
    @ObservationIgnored var pendingImportOperation = IOSCloudPendingOperation()
    var pendingPairing: MacGatewayPairingPayload?
    /// Non-secret summary of the most recent single-scan pairing bootstrap sync.
    var lastBootstrapSyncSummary: IOSPairingBootstrapSyncSummary?
    var notice: Notice?

    struct TerminalCloudTaskDetailRetryState {
        var failureCount: Int = 0
        var nextRetryAt: Date = .distantPast
    }

    @ObservationIgnored var client: MacGatewayClient?
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored var cloudPollTask: Task<Void, Never>?
    @ObservationIgnored var cloudDialoguePollTask: Task<Void, Never>?
    @ObservationIgnored var isAppInBackground = false
    @ObservationIgnored var cloudDialogueIdlePollStreak = 0
    @ObservationIgnored var isCloudDialoguePollSleeping = false
    @ObservationIgnored var cloudDialoguePollStepDurations: [Duration] = [
        .seconds(1), .seconds(2), .seconds(3), .seconds(5)
    ]
    @ObservationIgnored var terminalCloudTaskDetailRetryState: [String: TerminalCloudTaskDetailRetryState] = [:]
    /// Bumped per request so a slower, older response never overwrites a newer one (polls, pull to refresh and
    /// the refresh after a decision overlap).
    @ObservationIgnored var requestGeneration = (status: 0, schedules: 0, board: 0, cloudAgents: 0)
    @ObservationIgnored var hasCheckedCloudSoulOnConnect = false
    @ObservationIgnored weak var boundSoulStore: AgentSoulStore?
    @ObservationIgnored weak var boundSharedSettings: IOSSharedSettingsStore? {
        didSet {
            macSlot?.boundSharedSettings = boundSharedSettings
        }
    }
    @ObservationIgnored var boundRuleStore: IOSProceduralRuleStore = .shared
    @ObservationIgnored let dialogueFiles: MacGatewayDialogueFiles?
    @ObservationIgnored let persistenceCoordinator = MacGatewayPersistenceCoordinator()
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let biometricAuthenticator: any MacGatewayBiometricAuthenticating
    @ObservationIgnored private let isApplicationForeground: @MainActor () -> Bool
    @ObservationIgnored private let loadToken: @Sendable (String) -> String?
    @ObservationIgnored private let saveToken: @Sendable (String, String) -> Bool
    @ObservationIgnored private let deleteToken: @Sendable (String) -> Void

    init(
        defaults: UserDefaults = .standard,
        dialogueDirectory: URL? = nil,
        biometricAuthenticator: any MacGatewayBiometricAuthenticating = MacGatewayLocalBiometricAuthenticator(),
        isApplicationForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        endpointRole: MacGatewayEndpointRole = .cloud,
        isChildSlot: Bool = false,
        loadToken: @escaping @Sendable (String) -> String? = { IOSCredentialSideTable.load(key: $0) },
        saveToken: @escaping @Sendable (String, String) -> Bool = { IOSCredentialSideTable.store(key: $0, value: $1) },
        deleteToken: @escaping @Sendable (String) -> Void = { IOSCredentialSideTable.delete(key: $0) }
    ) {
        let directory = dialogueDirectory ?? (defaults === UserDefaults.standard
            ? MacGatewayDialogueFiles.applicationDirectory : nil)
        self.dialogueFiles = directory.map { MacGatewayDialogueFiles(directory: $0, role: endpointRole) }
        self.endpointRole = endpointRole
        self.defaults = defaults
        self.biometricAuthenticator = biometricAuthenticator
        self.isApplicationForeground = isApplicationForeground
        self.loadToken = loadToken
        self.saveToken = saveToken
        self.deleteToken = deleteToken

        if !isChildSlot, endpointRole == .cloud {
            Self.migrateLegacySingleSlotIfNeeded(
                defaults: defaults,
                loadToken: loadToken,
                saveToken: saveToken,
                deleteToken: deleteToken
            )
        }

        if endpointRole == .cloud {
            self.shareCalendarUpcomingEnabled = defaults.bool(forKey: Self.shareCalendarUpcomingKey)
            self.shareRemindersDueEnabled = defaults.bool(forKey: Self.shareRemindersDueKey)
            self.shareWorkspaceArtifactsEnabled = defaults.bool(forKey: Self.shareWorkspaceArtifactsKey)
            self.pendingDeviceContextRemoteDelete = defaults.bool(forKey: Self.pendingDeviceContextDeleteKey)
            self.cloudDialogueLastViewedSeq = Int64(defaults.integer(forKey: Self.cloudDialogueLastViewedSeqKey))
            bindCloudSoulStoreIfNeeded()
        }

        loadPersistedConnection()

        if !isChildSlot, endpointRole == .cloud {
            self.macSlot = MacGatewayStore(
                defaults: defaults,
                dialogueDirectory: directory,
                biometricAuthenticator: biometricAuthenticator,
                isApplicationForeground: isApplicationForeground,
                endpointRole: .mac,
                isChildSlot: true,
                loadToken: loadToken,
                saveToken: saveToken,
                deleteToken: deleteToken
            )
        }

        #if DEBUG
        if !isChildSlot {
            if ProcessInfo.processInfo.environment["AMBER_MAC_BOARD_FIXTURE"] == "1" { loadBoardFixture() }
            if ProcessInfo.processInfo.environment["AMBER_CLOUD_CONFIG_FIXTURE"] == "1" { loadCloudConfigFixture() }
        }
        #endif
    }

    /// A notification can launch the app before the first unlock makes its Keychain token available.
    func restorePairingIfNeeded() {
        if connection == nil, client == nil,
           defaults.data(forKey: connectionStorageKey) != nil || defaults.data(forKey: Self.legacyConnectionKey) != nil {
            loadPersistedConnection()
        }
    }

    private func loadPersistedConnection() {
        if let data = defaults.data(forKey: connectionStorageKey),
           var saved = try? JSONDecoder().decode(MacGatewayConnection.self, from: data),
           let token = loadToken(tokenStorageKey) {
            if saved.role == nil {
                saved.role = endpointRole
            }
            persistenceCoordinator.advance(connection: saved)
            connection = saved
            client = MacGatewayClient(addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: token)
            loadPersistedCloudTasks()
            loadPersistedCloudDialogueState()
            return
        }
        // Fallback if migration could not write the new Keychain key: keep the legacy pairing alive in memory.
        if let legacyData = defaults.data(forKey: Self.legacyConnectionKey),
           var legacySaved = try? JSONDecoder().decode(MacGatewayConnection.self, from: legacyData),
           MacGatewayEndpointRole.inferMigrationRole(for: legacySaved) == endpointRole,
           let legacyToken = loadToken(Self.legacyTokenKey) {
            legacySaved.role = endpointRole
            persistenceCoordinator.advance(connection: legacySaved)
            connection = legacySaved
            client = MacGatewayClient(addrs: legacySaved.addrs, port: legacySaved.port, fingerprint: legacySaved.fingerprint, token: legacyToken)
            loadPersistedCloudTasks()
            loadPersistedCloudDialogueState()
            return
        }
        persistenceCoordinator.advance(connection: nil)
    }

    /// Migrates a pre-Plan-2 single-slot pairing (`macGateway.connection.v1` + `macGateway.deviceToken`)
    /// into its inferred dual-slot key (`.cloud` or `.mac`) without losing user credentials or state.
    private static func migrateLegacySingleSlotIfNeeded(
        defaults: UserDefaults,
        loadToken: @Sendable (String) -> String?,
        saveToken: @Sendable (String, String) -> Bool,
        deleteToken: @Sendable (String) -> Void
    ) {
        let hasCloudV2 = defaults.data(forKey: MacGatewayEndpointRole.cloud.connectionStorageKey) != nil
        let hasMacV2 = defaults.data(forKey: MacGatewayEndpointRole.mac.connectionStorageKey) != nil
        guard !hasCloudV2, !hasMacV2 else { return }
        guard let legacyData = defaults.data(forKey: legacyConnectionKey),
              var saved = try? JSONDecoder().decode(MacGatewayConnection.self, from: legacyData),
              let legacyToken = loadToken(legacyTokenKey),
              !legacyToken.isEmpty else {
            return
        }
        let targetRole = MacGatewayEndpointRole.inferMigrationRole(for: saved)
        saved.role = targetRole
        guard let encoded = try? JSONEncoder().encode(saved) else { return }
        guard saveToken(targetRole.tokenStorageKey, legacyToken) else {
            // Keep legacy keys intact so `loadPersistedConnection()` can still recover the pairing.
            return
        }
        defaults.set(encoded, forKey: targetRole.connectionStorageKey)
        if targetRole == .mac {
            if let oldDialogue = defaults.data(forKey: MacGatewayEndpointRole.cloud.dialogueStorageKey),
               defaults.data(forKey: MacGatewayEndpointRole.mac.dialogueStorageKey) == nil {
                defaults.set(oldDialogue, forKey: MacGatewayEndpointRole.mac.dialogueStorageKey)
                defaults.removeObject(forKey: MacGatewayEndpointRole.cloud.dialogueStorageKey)
            }
            if let oldTasks = defaults.data(forKey: MacGatewayEndpointRole.cloud.tasksStorageKey),
               defaults.data(forKey: MacGatewayEndpointRole.mac.tasksStorageKey) == nil {
                defaults.set(oldTasks, forKey: MacGatewayEndpointRole.mac.tasksStorageKey)
                defaults.removeObject(forKey: MacGatewayEndpointRole.cloud.tasksStorageKey)
            }
        }
        defaults.removeObject(forKey: legacyConnectionKey)
        deleteToken(legacyTokenKey)
    }

    func configureForTesting(
        role: MacGatewayEndpointRole = .cloud,
        connection: MacGatewayConnection,
        client: MacGatewayClient
    ) {
        if role != endpointRole {
            slot(for: role).configureForTesting(role: role, connection: connection, client: client)
            return
        }
        var tagged = connection
        tagged.role = endpointRole
        persistenceCoordinator.advance(connection: tagged)
        self.connection = tagged
        self.client = client
        self.isReachable = true
        self.localApprovalOnlyCallIds = []
        self.cloudDialogueTransportState = .unknown
        self.hasCheckedCloudSoulOnConnect = false
        if endpointRole == .cloud {
            let previousSoulStore = boundSoulStore ?? .shared
            bindCloudSoulStoreIfNeeded(previousSoulStore)
        }
        loadPersistedCloudTasks()
        loadPersistedCloudDialogueState()
    }

    #if DEBUG
    /// Simulator screenshots of every board group without a Mac: no client, so nothing is sent anywhere.
    func loadBoardFixture() {
        let now = Date()
        connection = MacGatewayConnection(gatewayId: "fixture", name: "Studio Mac", addrs: [], port: 1, fingerprint: "", deviceId: "d")
        client = nil
        isReachable = true
        let statusJSON = #"""
        {"gateway":{"id":"fixture","name":"Studio Mac"},"device":{"id":"d","name":"iPhone","pushRegistered":true},"serverTime":1800000000,"synaraURL":"https://synara.local/tasks",
         "health":{"sampledAt":1799999980,"diskFreeBytes":248000000000,"batteryPercent":86,"onBattery":false,"memoryPressure":"normal","thermal":"nominal"},
         "sessions":[]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        status = try? decoder.decode(MacGatewayStatus.self, from: Data(statusJSON.utf8))
        func item(_ id: String, _ kind: MacGatewayBoardItem.Kind, _ column: MacGatewayBoardItem.Column, _ title: String,
                  _ detail: String, ago: TimeInterval = 0, schedule: String? = nil, next: Date? = nil, reply: Bool = false,
                  failed: Bool = false, approval: MacGatewayBoardItem.Approval? = nil) -> MacGatewayBoardItem {
            MacGatewayBoardItem(id: id, kind: kind, column: column, title: title, detail: detail, updatedAt: now - ago,
                                scheduleId: schedule, nextRunAt: next, waitingForReply: reply, failed: failed, approval: approval)
        }
        board = [
            item("run:A", .run, .needsYou, "每日新闻汇总", "等你确认 · workspace_file_write", ago: 120, schedule: "A",
                 approval: .init(sessionKey: "amber:r1", toolCallId: "c1", tool: "workspace_file_write",
                                 detail: "path: notes/2026-10-27.md", highRisk: false)),
            item("run:B", .run, .needsYou, "清理下载文件夹", "等你确认 · shell_run", ago: 300, schedule: "B",
                 approval: .init(sessionKey: "amber:r2", toolCallId: "c2", tool: "shell_run",
                                 detail: "rm -rf ~/Downloads/tmp", highRisk: true)),
            item("session:claude:s1", .agentSession, .needsYou, "实现 iOS 任务看板", "Claude Code · Synara · 等你回复", ago: 60, reply: true),
            item("session:codex:s2", .agentSession, .running, "修复网关推送", "Codex · 运行中", ago: 30),
            item("schedule:C", .schedule, .scheduled, "周报", "每周五 17:30", schedule: "C", next: now + 3 * 3600),
            item("done:R1", .run, .done, "每日新闻汇总", "整理了 12 条新闻，没有需要你关注的", ago: 86_400, schedule: "A"),
            item("done:R2", .run, .done, "清理下载文件夹", "磁盘空间不足", ago: 2 * 86_400, schedule: "B", failed: true),
        ]
        schedules = [
            MacGatewaySchedule(id: "C", name: "周报", rule: "每周五 17:30", enabled: true, running: false, nextRunAt: now + 3 * 3600,
                               autoApprovesHighRisk: false),
            MacGatewaySchedule(id: "D", name: "备份照片", rule: "每天 03:00", enabled: false, running: false, autoApprovesHighRisk: false),
        ]
    }

    func resetBoardFixtureForTesting() {
        connection = nil
        status = nil
        isReachable = nil
        board = nil
        schedules = nil
        notice = nil
    }

    func loadCloudConfigFixture() {
        connection = MacGatewayConnection(
            gatewayId: "fixture-cloud",
            name: "Amber Cloud",
            addrs: [],
            port: 1,
            fingerprint: "",
            deviceId: "d"
        )
        client = nil
        isReachable = true
        cloudConfig = IOSCloudConfigSnapshot(
            gatewayId: "fixture-cloud",
            revision: 4,
            model: .init(
                provider: "openai",
                modelId: "deepseek-v4.1-flash",
                baseUrl: "https://opencode.ai/zen/v1",
                keyConfigured: true
            ),
            search: [
                .init(type: "bing", name: "Bing", enabled: true, requiresKey: false, keyConfigured: false),
                .init(type: "duckduckgo", name: "DuckDuckGo", enabled: true, requiresKey: false, keyConfigured: false),
                .init(type: "exa", name: "Exa", enabled: false, requiresKey: true, keyConfigured: false),
                .init(type: "brave", name: "Brave", enabled: false, requiresKey: true, keyConfigured: false),
            ],
            searchSources: ["bing", "duckduckgo"],
            searchMode: "fallback",
            supportedModelProviders: ["openai", "claude"],
            supportedSearchSources: ["bing", "duckduckgo", "exa", "brave"]
        )
    }

    func applyDebugFixtureModelSwitch(provider: String, providerName: String, modelId: String, baseUrl: String) {
        guard var next = cloudConfig else { return }
        next.revision += 1
        next.model = .init(provider: provider, modelId: modelId, baseUrl: baseUrl, keyConfigured: true)
        cloudConfig = next
        notice = Notice(text: "已切换云端配置为 \(providerName) · \(modelId)，新任务开始使用", isError: false)
    }
    #endif

    // MARK: - App lifecycle

    /// Apple recommends re-registering on every launch; the token can change after restores and updates.
    func applicationDidFinishLaunching() {
        guard hasAnyPairedEndpoint else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Coordinates foreground/background polling across both Cloud and Mac slots.
    /// Background only pauses polling when completely idle (no awaiting reply, no active workItem, no active cloudTask).
    func setAppInBackground(_ inBackground: Bool) {
        let changed = isAppInBackground != inBackground
        isAppInBackground = inBackground
        macSlot?.setAppInBackground(inBackground)

        if inBackground {
            if shouldSuspendCloudDialoguePollingInBackground {
                stopCloudDialoguePolling()
            }
            if !hasActiveCloudTasks {
                stopCloudTaskPolling()
            }
        } else {
            cloudDialogueIdlePollStreak = 0
            if changed {
                if cloudDialoguePollTask != nil {
                    stopCloudDialoguePolling()
                }
                if shouldPollCloudDialogue {
                    // Starting the loop runs an immediate catch-up poll before the 1s sleep.
                    startCloudDialoguePollingIfNeeded()
                }
            } else if shouldPollCloudDialogue {
                startCloudDialoguePollingIfNeeded()
            }
            if hasActiveCloudTasks {
                startCloudTaskPollingIfNeeded()
            }
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = hex
        macSlot?.apnsToken = hex
        if connection != nil {
            Task { await uploadPushToken(hex) }
        }
        if let macSlot, macSlot.connection != nil {
            Task { await macSlot.uploadPushToken(hex) }
        }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        if connection != nil {
            pushError = error.localizedDescription
        }
        if let macSlot, macSlot.connection != nil {
            macSlot.pushError = error.localizedDescription
        }
    }

    // MARK: - Pairing

    /// Deep link entry (system camera scan or AirDrop). Pairing still needs an explicit confirmation.
    func receivePairingLink(_ link: String, preferredRole: MacGatewayEndpointRole? = nil) {
        guard let payload = MacGatewayPairingPayload.parse(link) else {
            let errorNotice = Notice(text: localized("配对链接无效，请在终端重新生成配对链接"), isError: true)
            if let preferredRole, preferredRole != endpointRole {
                slot(for: preferredRole).notice = errorNotice
            } else {
                notice = errorNotice
            }
            return
        }
        let targetRole = preferredRole ?? MacGatewayEndpointRole.inferPairingRole(for: payload)
        if endpointRole == .cloud {
            preferredMultiDeviceTab = AmberMultiDeviceTab(role: targetRole)
        }
        let targetSlot = slot(for: targetRole)
        targetSlot.pendingPairing = payload
        targetSlot.notice = nil
    }

    func pasteLinkFromClipboard(for role: MacGatewayEndpointRole? = nil) {
        receivePairingLink(UIPasteboard.general.string ?? "", preferredRole: role ?? endpointRole)
    }

    func confirmPairing(
        for role: MacGatewayEndpointRole? = nil,
        sharedSettings: IOSSharedSettingsStore? = nil,
        soulStore: AgentSoulStore? = nil,
        ruleStore: IOSProceduralRuleStore? = nil,
        pairingTransport: MacGatewayClient.Transport? = nil,
        storeToken: ((String, String) -> Bool)? = nil
    ) async {
        let targetRole = role ?? endpointRole
        if targetRole != endpointRole {
            await slot(for: targetRole).confirmPairing(
                for: targetRole,
                sharedSettings: sharedSettings ?? boundSharedSettings,
                soulStore: soulStore ?? boundSoulStore,
                ruleStore: ruleStore ?? boundRuleStore,
                pairingTransport: pairingTransport,
                storeToken: storeToken
            )
            return
        }
        guard let payload = pendingPairing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let pairingClient = MacGatewayClient(
            addrs: payload.addrs, port: payload.port, fingerprint: payload.fp, token: nil, transport: pairingTransport
        )
        do {
            let wantsBootstrapSync = payload.bootstrap?.syncSupported == true
            let ephemeralKeyPair = wantsBootstrapSync ? try await Task.detached(priority: .userInitiated) {
                try IOSPairingBootstrapCrypto.generateEphemeralKeyPair()
            }.value : nil
            let response = try await pairingClient.pair(
                secret: payload.s,
                deviceName: UIDevice.current.name,
                requestBootstrapSync: wantsBootstrapSync,
                clientPublicJwk: ephemeralKeyPair?.publicJwk
            )
            guard !payload.id.isEmpty, response.gatewayId == payload.id else {
                throw IOSPairingBootstrapError.gatewayMismatch
            }
            guard !response.deviceId.isEmpty, !response.token.isEmpty else { throw MacGatewayError.invalidResponse }
            let tokenWriter = storeToken ?? saveToken
            let targetTokenKey = tokenStorageKey
            guard tokenWriter(targetTokenKey, response.token) else {
                notice = Notice(text: localized("无法把配对凭据写入钥匙串"), isError: true)
                return
            }
            let saved = MacGatewayConnection(
                gatewayId: response.gatewayId,
                name: response.gatewayName,
                addrs: payload.addrs,
                port: payload.port,
                fingerprint: payload.fp,
                deviceId: response.deviceId,
                role: endpointRole
            )
            let (epoch, identity) = persistenceCoordinator.advance(connection: saved)
            let targetDefaults = defaults
            nonisolated(unsafe) let sendableDefaults = targetDefaults
            let coordinator = persistenceCoordinator
            let targetConnectionKey = connectionStorageKey
            let savedData = try? JSONEncoder().encode(saved)
            targetDefaults.set(savedData, forKey: targetConnectionKey)
            Self.persistenceQueue.async {
                guard coordinator.canCommit(epoch: epoch, identity: identity) else { return }
                sendableDefaults.set(savedData, forKey: targetConnectionKey)
            }
            connection = saved
            let pairedClient = MacGatewayClient(
                addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: response.token, transport: pairingTransport
            )
            client = pairedClient
            loadPersistedCloudTasks()
            loadPersistedCloudDialogueState()
            if pendingPairing == payload { pendingPairing = nil }

            lastBootstrapSyncSummary = nil
            notice = nil
            do {
                var bootstrapSnapshot = response.bootstrap
                if bootstrapSnapshot == nil, wantsBootstrapSync {
                    bootstrapSnapshot = try await pairedClient.requestPairingBootstrapSync(clientPublicJwk: ephemeralKeyPair?.publicJwk)
                    guard self.client === pairedClient else { return }
                }
                if let bootstrapSnapshot {
                    let applied = try IOSPairingBootstrapImporter.apply(
                        snapshot: bootstrapSnapshot,
                        privateKey: ephemeralKeyPair?.privateKey,
                        gatewayId: response.gatewayId,
                        deviceId: response.deviceId,
                        sharedSettings: sharedSettings ?? boundSharedSettings,
                        soulStore: soulStore ?? boundSoulStore ?? .shared,
                        ruleStore: ruleStore ?? boundRuleStore
                    )
                    if endpointRole == .cloud, let remoteConfig = applied.remoteConfigSnapshot {
                        cloudConfig = remoteConfig
                    }
                    lastBootstrapSyncSummary = applied.summary
                    notice = Notice(text: applied.summary.summaryText, isError: false)
                }
            } catch {
                guard self.client === pairedClient else { return }
                notice = Notice(
                    text: localized("配对成功，但加密配置同步未完成：") + error.localizedDescription,
                    isError: true
                )
            }

            if pairingTransport == nil {
                await enablePush()
                await refresh()
            }
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    func unpair(role: MacGatewayEndpointRole? = nil) async {
        let targetRole = role ?? endpointRole
        if targetRole != endpointRole {
            await slot(for: targetRole).unpair(role: targetRole)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Best effort: if the gateway is unreachable the device stays listed there until `devices revoke`.
        // 401 means the gateway already dropped this device, which is the outcome we wanted.
        var reachedGateway = true
        do {
            try await client?.unpair()
        } catch MacGatewayError.unauthorized {
        } catch {
            reachedGateway = false
        }
        forget()
        let endpointName = endpointRole.displayName
        notice = reachedGateway ? nil : Notice(
            text: localized("已在本机取消配对。\(endpointName) 当前不可达，可在 \(endpointName) 上运行 amber-gateway devices revoke 移除此设备"),
            isError: false
        )
    }

    // MARK: - Status & control

    /// Refreshes both Cloud and Mac paired slots concurrently without blocking each other.
    func refreshAll() async {
        guard let macSlot else {
            await refresh()
            return
        }
        async let cloudRefresh: Void = refresh()
        async let macRefresh: Void = macSlot.refresh()
        _ = await (cloudRefresh, macRefresh)
    }

    func refresh(role: MacGatewayEndpointRole? = nil) async {
        let targetRole = role ?? endpointRole
        if targetRole != endpointRole {
            await slot(for: targetRole).refresh(role: targetRole)
            return
        }
        guard let client else { return }
        requestGeneration.status += 1
        let generation = requestGeneration.status
        do {
            let latest = try await client.status()
            guard self.client === client, generation == requestGeneration.status else { return }
            status = latest
            isReachable = true
            if endpointRole == .cloud {
                let forceSoulPull = !hasCheckedCloudSoulOnConnect
                hasCheckedCloudSoulOnConnect = true
                await syncCloudSoulIfNeeded(
                    observedRevision: latest.soulRevision,
                    forcePull: forceSoulPull,
                    soulStore: boundSoulStore ?? .shared
                )
                await refreshCloudAgents()
                await refreshCloudConfig()
                await boundRuleStore.syncFromGateway(syncClient: client)
                _ = await pollCloudDialogueEvents()
                await refreshActiveCloudTasks()
                startCloudTaskPollingIfNeeded()
                startCloudDialoguePollingIfNeeded()
                await refreshSchedules()
                await refreshBoard()
                await syncDeviceContextOnRefresh()
            } else {
                _ = await pollCloudDialogueEvents()
                startCloudDialoguePollingIfNeeded()
                await refreshSchedules()
                await refreshBoard()
            }
            if latest.device.pushRegistered {
                pushError = nil
            } else if let apnsToken {
                // The gateway lost the token (or an earlier upload failed while it was offline): report it again.
                await uploadPushToken(apnsToken)
            }
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.status else { return }
            if !forgetIfRevoked(error, for: client) { isReachable = false }
        }
    }

    func setMonitored(_ session: MacGatewayStatus.Session, _ monitored: Bool) async {
        guard let client, let index = status?.sessions.firstIndex(where: { $0.key == session.key }) else { return }
        status?.sessions[index].monitored = monitored
        do {
            try await client.setMonitored(taskKey: session.key, monitored: monitored)
        } catch {
            guard self.client === client else { return }
            if let i = status?.sessions.firstIndex(where: { $0.key == session.key }) { status?.sessions[i].monitored = !monitored }
            if !forgetIfRevoked(error, for: client) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
    }

    func sendTestPush() async {
        guard let client, !isSendingTestPush else { return }
        isSendingTestPush = true
        defer { isSendingTestPush = false }
        do {
            try await client.testPush()
            guard self.client === client else { return }
            notice = Notice(text: localized("测试推送已发出，锁屏后留意通知"), isError: false)
        } catch {
            guard self.client === client else { return }
            if !forgetIfRevoked(error, for: client) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
    }

    /// Phone-side answer to an Amber run's tool call.
    /// Foreground in-app approval runs LocalAuthentication biometric verification before sending trusted headers;
    /// notification decisions never carry trusted headers and high-risk notification approvals open the App instead.
    @discardableResult
    func decide(
        sessionKey: String,
        toolCallId: String,
        allow: Bool,
        source: MacGatewayDecisionSource = .foregroundApp,
        role: MacGatewayEndpointRole? = nil,
        refreshAfterDecision: Bool = true
    ) async -> Bool {
        // Cloud orchestration owns amber:wi: keys. Legacy Cloud runs and Mac runs both use amber:<runId>.
        let role = role ?? (sessionKey.hasPrefix("amber:wi:") ? .cloud : nil)
        if let role, role != endpointRole {
            guard role == .mac, let macSlot else {
                notice = Notice(text: localized("审批所属终端已变化，请重新打开任务"), isError: true)
                return false
            }
            let delivered = await macSlot.decide(
                sessionKey: sessionKey,
                toolCallId: toolCallId,
                allow: allow,
                source: source,
                role: role,
                refreshAfterDecision: refreshAfterDecision
            )
            notice = macSlot.notice
            return delivered
        }
        if source == .notification {
            restorePairingIfNeeded()
            if role == nil { macSlot?.restorePairingIfNeeded() }
        }
        if role == nil, endpointRole == .cloud, let macSlot {
            let macOwnsApproval = macSlot.boardItems.contains {
                $0.approval?.sessionKey == sessionKey && $0.approval?.toolCallId == toolCallId
            } || (macSlot.status?.sessions.contains {
                $0.key == sessionKey && $0.pendingApproval?.toolCallId == toolCallId
            } ?? false)
            let cloudOwnsApproval = boardItems.contains {
                $0.approval?.sessionKey == sessionKey && $0.approval?.toolCallId == toolCallId
            } || (status?.sessions.contains {
                $0.key == sessionKey && $0.pendingApproval?.toolCallId == toolCallId
            } ?? false)
            if client != nil, macSlot.client != nil, macOwnsApproval == cloudOwnsApproval {
                notice = Notice(text: localized("无法确定审批所属终端，请在任务看板中核对"), isError: true)
                return false
            }
            if (macOwnsApproval && !cloudOwnsApproval) || (client == nil && macSlot.client != nil) {
                let delivered = await macSlot.decide(
                    sessionKey: sessionKey,
                    toolCallId: toolCallId,
                    allow: allow,
                    source: source,
                    role: .mac,
                    refreshAfterDecision: refreshAfterDecision
                )
                notice = macSlot.notice
                return delivered
            }
        }
        if allow, requiresLocalApprovalOnly(sessionKey: sessionKey, toolCallId: toolCallId) {
            localApprovalOnlyCallIds.insert(toolCallId)
            notice = Notice(text: localized("此高危操作请在 Mac 上批准"), isError: true)
            return false
        }
        if allow, source == .notification, isKnownHighRiskApproval(sessionKey: sessionKey, toolCallId: toolCallId) {
            notice = Notice(text: localized("高风险操作，请在 App 前台核对后批准"), isError: true)
            return false
        }
        guard let client else {
            notice = Notice(text: localized(endpointRole == .cloud ? "尚未配对 Amber · 云端" : "未与 Mac 配对"), isError: true)
            return false
        }
        guard decidingCalls.insert(toolCallId).inserted else { return false }
        defer { decidingCalls.remove(toolCallId) }

        let trustContext: MacGatewayDecisionTrustContext
        switch source {
        case .notification:
            trustContext = .untrustedNotification
        case .foregroundApp:
            if allow {
                guard isApplicationForeground() else {
                    notice = Notice(text: localized("请在 App 前台核对后批准"), isError: true)
                    return false
                }
                let reason = localized("验证身份以批准远程工具调用")
                guard await biometricAuthenticator.verifyForegroundApproval(reason: reason) else {
                    notice = Notice(text: localized("未通过生物识别验证，已取消批准"), isError: true)
                    return false
                }
                // Authentication suspends: the App or pairing can change while the prompt is open.
                guard isApplicationForeground(), self.client === client, !Task.isCancelled else {
                    notice = Notice(text: localized("前台或配对状态已变化，请重新核对批准"), isError: true)
                    return false
                }
                guard !requiresLocalApprovalOnly(sessionKey: sessionKey, toolCallId: toolCallId) else {
                    notice = Notice(text: localized("此高危操作请在 Mac 上批准"), isError: true)
                    return false
                }
                trustContext = .verifiedForegroundApp()
            } else {
                trustContext = .unverifiedForegroundApp
            }
        }

        do {
            try await client.decide(
                sessionKey: sessionKey,
                toolCallId: toolCallId,
                allow: allow,
                trustContext: trustContext
            )
            guard self.client === client else { return false }
            notice = Notice(text: localized(allow ? "已批准，任务继续运行" : "已拒绝这次调用"), isError: false)
            if refreshAfterDecision { await refresh() }
            return true
        } catch {
            guard self.client === client else { return false }
            if case MacGatewayError.forbidden = error, endpointRole == .mac {
                localApprovalOnlyCallIds.insert(toolCallId)
                notice = Notice(text: localized("此高危操作请在 Mac 上批准"), isError: true)
            } else if !forgetIfRevoked(error, for: client) {
                notice = Notice(text: error.localizedDescription, isError: true)
            }
            if refreshAfterDecision { await refresh() }
            return false
        }
    }

    func requiresLocalApprovalOnly(sessionKey: String, toolCallId: String) -> Bool {
        if localApprovalOnlyCallIds.contains(toolCallId) {
            return true
        }
        if boardItems.contains(where: {
            $0.approval?.sessionKey == sessionKey && $0.approval?.toolCallId == toolCallId && $0.approval?.requiresLocalApproval == true
        }) { return true }
        if let session = status?.sessions.first(where: { $0.key == sessionKey }),
           let pending = session.pendingApproval,
           pending.toolCallId == toolCallId {
            return pending.requiresLocalApproval
        }
        return false
    }

    func isKnownHighRiskApproval(sessionKey: String, toolCallId: String) -> Bool {
        if boardItems.contains(where: {
            guard let approval = $0.approval, approval.sessionKey == sessionKey, approval.toolCallId == toolCallId else { return false }
            return approval.highRisk || MacApprovalRiskTier.resolve(rawLevel: approval.riskLevel, highRisk: approval.highRisk, requiresLocalApproval: approval.requiresLocalApproval) == .l3
        }) { return true }
        if let session = status?.sessions.first(where: { $0.key == sessionKey }),
           let pending = session.pendingApproval, pending.toolCallId == toolCallId {
            return pending.highRisk || MacApprovalRiskTier.resolve(rawLevel: pending.riskLevel, highRisk: pending.highRisk, requiresLocalApproval: pending.requiresLocalApproval) == .l3
        }
        return false
    }

    // MARK: - Task board

    var needsYouCount: Int { needsYouItems.count + (macSlot?.needsYouItems.count ?? 0) }

    private func publishBoard() {
        let items = board ?? Self.fallbackBoard(sessions: status?.sessions ?? [])
        var changed = false
        if items != boardItems {
            boardItems = items
            changed = true
        }
        let needsYou = connection != nil && isReachable == true ? items.filter { $0.column == .needsYou } : []
        if needsYou != needsYouItems {
            needsYouItems = needsYou
            changed = true
        }
        if changed {
            notifyWatchRemoteStateChanged()
        }
    }

    func notifyWatchRemoteStateChanged() {
        NotificationCenter.default.post(name: .amberWatchRemoteStateDidChange, object: self)
    }

    func refreshBoard() async {
        guard let client else { return }
        requestGeneration.board += 1
        let generation = requestGeneration.board
        do {
            let latest = try await client.board()
            guard self.client === client, generation == requestGeneration.board else { return }
            board = latest
            boardError = nil
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.board else { return }
            if forgetIfRevoked(error) { return }
            board = nil
            // Gateways older than the board answer 404 "not found".
            boardError = error as? MacGatewayError == .server("not found")
                ? localized("Mac 上的 amber-gateway 版本较旧，更新 Amber 后可查看定时任务和审批")
                : error.localizedDescription
        }
    }

    /// Claude Code / Codex sessions, plus Amber runs the gateway reports as waiting on a tool call (still answerable
    /// with `decide`). Schedules are unknown without Amber. Same grouping as the Mac's board.
    static func fallbackBoard(sessions: [MacGatewayStatus.Session]) -> [MacGatewayBoardItem] {
        let order = MacGatewayBoardItem.Column.allCases
        let approvals = sessions.compactMap { session -> MacGatewayBoardItem? in
            guard session.agent == "amber", let pending = session.pendingApproval else { return nil }
            return MacGatewayBoardItem(
                id: "run:\(session.key)", kind: .run, column: .needsYou, title: session.displayTitle,
                detail: IOSAppLocalization.string("等你确认", defaultValue: "等你确认") + " · " + pending.tool,
                updatedAt: session.updatedAt, scheduleId: nil, nextRunAt: nil, waitingForReply: false, failed: false,
                approval: .init(sessionKey: session.key, toolCallId: pending.toolCallId, tool: pending.tool,
                                detail: pending.detail, highRisk: pending.highRisk,
                                requiresLocalApproval: pending.requiresLocalApproval, summary: pending.summary,
                                diffPreview: pending.diffPreview, targetDeviceName: pending.targetDeviceName,
                                riskLevel: pending.riskLevel, workItemId: pending.workItemId,
                                conversationId: pending.conversationId ?? session.conversationId))
        }
        // Same rule as the Mac's board: sessions with no prompt have nothing to show but their directory name.
        let items = approvals + sessions.filter { $0.agent != "amber" && $0.agent != "run" }
            .filter { $0.summary != nil || $0.state == "waiting" }.map { session in
            let column: MacGatewayBoardItem.Column = switch session.state {
            case "waiting": .needsYou
            case "running", "stalled": .running
            default: .done
            }
            return MacGatewayBoardItem(
                id: "session:\(session.key)", kind: .agentSession, column: column, title: session.displayTitle,
                detail: fallbackDetail(session), updatedAt: session.updatedAt, scheduleId: nil, nextRunAt: nil,
                waitingForReply: session.state == "waiting" && session.waitReason != "permission",
                failed: session.abnormal, approval: nil)
        }
        return items.sorted { a, b in
            let (ai, bi) = (order.firstIndex(of: a.column) ?? 0, order.firstIndex(of: b.column) ?? 0)
            return ai != bi ? ai < bi : a.updatedAt > b.updatedAt
        }
    }

    private static func fallbackDetail(_ session: MacGatewayStatus.Session) -> String {
        let agent = switch session.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: IOSAppLocalization.string("任务", defaultValue: "任务")
        }
        let state = switch session.state {
        case "running": "运行中"
        case "waiting": session.waitReason == "permission" ? "等你确认" : "等你回复"
        case "stalled": "可能卡住了"
        case "completed": "已完成"
        default: session.abnormal ? "意外中断" : "已停止"
        }
        return [agent, session.host, IOSAppLocalization.string(state, defaultValue: state)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Amber scheduled tasks

    func refreshSchedules() async {
        guard let client else { return }
        requestGeneration.schedules += 1
        let generation = requestGeneration.schedules
        do {
            let latest = try await client.schedules()
            guard self.client === client, generation == requestGeneration.schedules else { return }
            schedules = latest
            schedulesError = nil
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.schedules else { return }
            if forgetIfRevoked(error) { return }
            schedules = nil
            schedulesError = error.localizedDescription
        }
    }

    func setScheduleEnabled(_ schedule: MacGatewaySchedule, _ enabled: Bool) async {
        // Show the new position at once; the refresh after the call corrects it if the Mac refused.
        if let i = schedules?.firstIndex(where: { $0.id == schedule.id }) { schedules?[i].enabled = enabled }
        await scheduleAction(schedule.id) { try await $0.setScheduleEnabled(id: schedule.id, enabled: enabled) }
    }

    func runSchedule(_ schedule: MacGatewaySchedule) async {
        await scheduleAction(schedule.id, success: localized("已在 Mac 上开始运行")) { try await $0.runSchedule(id: schedule.id) }
    }

    /// Returns whether the Mac accepted the task; the sheet stays open on failure so nothing typed is lost.
    func createSchedule(_ draft: MacGatewayScheduleDraft) async -> String? {
        guard let client else { return localized("未与 Mac 配对") }
        do {
            try await client.createSchedule(draft)
            guard self.client === client else { return nil }
            notice = Notice(text: localized("已在 Mac 上创建定时任务"), isError: false)
            await refreshSchedules()
            await refreshBoard()
            return nil
        } catch {
            guard self.client === client else { return nil }
            if forgetIfRevoked(error, for: client) { return MacGatewayError.unauthorized.localizedDescription }
            return error.localizedDescription
        }
    }

    private func scheduleAction(_ id: String, success: String? = nil, _ body: (MacGatewayClient) async throws -> Void) async {
        guard let client, busySchedules.insert(id).inserted else { return }
        defer { busySchedules.remove(id) }
        do {
            try await body(client)
            guard self.client === client else { return }
            if let success { notice = Notice(text: success, isError: false) }
        } catch {
            guard self.client === client else { return }
            if !forgetIfRevoked(error, for: client) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
        await refreshSchedules()
        await refreshBoard()
    }

    func enablePush() async {
        guard await IOSLocalNotificationService.shared.requestAuthorization() else {
            pushError = localized("通知权限未开启，请到系统设置 > Amber > 通知中开启")
            return
        }
        pushError = nil
        UIApplication.shared.registerForRemoteNotifications()
        if let apnsToken { await uploadPushToken(apnsToken) }
    }

    // MARK: - Private

    private func uploadPushToken(_ hex: String) async {
        guard let client else { return }
        do {
            try await client.registerPushToken(hex, environment: Self.apnsEnvironment)
            guard self.client === client else { return }
            pushError = nil
            if status?.device.pushRegistered == false { status?.device.pushRegistered = true }
        } catch is CancellationError {
        } catch {
            guard self.client === client else { return }
            if !forgetIfRevoked(error, for: client) { pushError = error.localizedDescription }
        }
    }

    /// 401 means the Mac revoked this device: drop the pairing everywhere, with the same explanation.
    func forgetIfRevoked(_ error: Error, for expectedClient: MacGatewayClient? = nil) -> Bool {
        if let expectedClient, self.client !== expectedClient {
            return false
        }
        guard self.client != nil, case MacGatewayError.unauthorized = error else { return false }
        forget()
        notice = Notice(text: MacGatewayError.unauthorized.localizedDescription, isError: true)
        return true
    }

    private func forget() {
        stopCloudTaskPolling()
        let (epoch, _) = persistenceCoordinator.advance(connection: nil)
        dialogueFiles?.clear()
        resetCloudDialogueMemoryState()
        let targetTokenKey = tokenStorageKey
        let targetConnectionKey = connectionStorageKey
        let targetTasksKey = tasksStorageKey
        let targetDialogueKey = dialogueStorageKey
        if let data = defaults.data(forKey: Self.legacyConnectionKey),
           let legacy = try? JSONDecoder().decode(MacGatewayConnection.self, from: data),
           MacGatewayEndpointRole.inferMigrationRole(for: legacy) == endpointRole {
            defaults.removeObject(forKey: Self.legacyConnectionKey)
            deleteToken(Self.legacyTokenKey)
        }
        deleteToken(targetTokenKey)
        let targetDefaults = defaults
        targetDefaults.removeObject(forKey: targetConnectionKey)
        targetDefaults.removeObject(forKey: targetTasksKey)
        targetDefaults.removeObject(forKey: targetDialogueKey)
        nonisolated(unsafe) let sendableDefaults = targetDefaults
        let coordinator = persistenceCoordinator
        Self.persistenceQueue.async {
            guard coordinator.canCommit(epoch: epoch, identity: nil) else { return }
            sendableDefaults.removeObject(forKey: targetConnectionKey)
            sendableDefaults.removeObject(forKey: targetTasksKey)
            sendableDefaults.removeObject(forKey: targetDialogueKey)
        }
        connection = nil
        client = nil
        status = nil
        schedules = nil
        schedulesError = nil
        board = nil
        boardError = nil
        cloudAgents = []
        cloudTasks = []
        busyCloudTaskIds = []
        terminalCloudTaskDetailRetryState.removeAll()
        localApprovalOnlyCallIds = []
        cloudConfig = nil
        cloudConfigError = nil
        cloudConfigLoading = false
        cloudImporting = false
        cloudImportKeyChanged = false
        lastBootstrapSyncSummary = nil
        pendingImportOperation = IOSCloudPendingOperation()
        cloudDialogueTransportState = .unknown
        hasCheckedCloudSoulOnConnect = false
        if endpointRole == .cloud {
            (boundSoulStore ?? .shared).handleGatewayUnpaired()
            shareCalendarUpcomingEnabled = false
            shareRemindersDueEnabled = false
            shareWorkspaceArtifactsEnabled = false
            pendingDeviceContextRemoteDelete = false
            deviceContextMetadata = nil
            lastDeviceContextPushAt = nil
            cloudDialogueEncodedBytes = 0
            targetDefaults.removeObject(forKey: Self.shareCalendarUpcomingKey)
            targetDefaults.removeObject(forKey: Self.shareRemindersDueKey)
            targetDefaults.removeObject(forKey: Self.shareWorkspaceArtifactsKey)
            targetDefaults.removeObject(forKey: Self.pendingDeviceContextDeleteKey)
            targetDefaults.removeObject(forKey: Self.cloudDialogueLastViewedSeqKey)
            cloudDialogueLastViewedSeq = 0
        }
        isReachable = nil
        pushError = nil
    }

    func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }
}
