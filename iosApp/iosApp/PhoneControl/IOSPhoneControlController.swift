import AmberPhoneControl
import Foundation
import Observation

enum IOSPhoneControlPhase: String {
    case idle, authorized, pairing, starting, ready, stopping, failed
}

enum IOSPhoneControlError: LocalizedError {
    case disabled, unprepared, occupied, invalidScope, invalidDuration, unauthorized, expired

    var errorDescription: String? {
        switch self {
        case .disabled: "请先在设置中开启本机手机控制。"
        case .unprepared: "请先导入本机 RemotePairing 配对文件，并准备已签名的控制 runner。"
        case .occupied: "已有手机控制任务正在运行或关闭，请等原任务结束。"
        case .invalidScope: "请填写本次允许控制的目标 App bundle ID。"
        case .invalidDuration: "授权窗口只能选择 5 分钟、30 分钟、2 小时或不设软件到期。"
        case .unauthorized: "本任务没有手机控制授权。请在设置中开启授权窗口。"
        case .expired: "手机控制授权窗口已到期。"
        }
    }
}

/// The app owns the connection; a settings/chat page only observes it.
/// The authorization window is process-local and is never persisted or restored after process death.
@MainActor
@Observable
final class IOSPhoneControlController {
    static let shared = IOSPhoneControlController()
    static let enabledPreferenceKey = "app.amber.ios.phoneControl.enabled.v1"
    static let selectedBundleIDsPreferenceKey = "app.amber.ios.phoneControl.scope.v1"

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledPreferenceKey)
            if !enabled {
                discardPendingAuthorization()
                cancelPreparation()
                endCurrentTask()
            }
        }
    }
    var selectedBundleIDs: Set<String> {
        didSet {
            guard selectedBundleIDs != oldValue else { return }
            defaults.set(selectedBundleIDs.sorted(), forKey: Self.selectedBundleIDsPreferenceKey)
            // Editing the window scope revokes that window; an active run keeps its frozen scope.
            discardPendingAuthorization()
        }
    }
    private(set) var hasPreparedPairing = false
    private(set) var isUpdatingPairing = false
    private(set) var phase: IOSPhoneControlPhase = .idle
    private(set) var statusMessage = "尚未启动手机控制任务"
    private(set) var ownerRunID: String?
    private(set) var authorizationTargetSummary = ""
    private(set) var authorizedDurationSeconds: Int?
    private(set) var pairingStatus: PhoneControlLaunchStatus?

    var isOccupied: Bool { ownerRunID != nil }
    var isPreparingPairing: Bool { isUpdatingPairing && pairingOperationID != nil }
    var hasPendingAuthorization: Bool {
        guard let pending else { return false }
        guard enabled else { return false }
        return pending.validUntil.map({ $0 > Date() }) ?? true
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any IOSPhoneControlCredentialStoring
    @ObservationIgnored private let session: PhoneControlSession
    @ObservationIgnored private let pairingSession = PhoneControlPairingSession()
    @ObservationIgnored private var pairingTask: Task<Bool, Error>?
    @ObservationIgnored private var pairingOperationID: UUID?
    @ObservationIgnored private var pending: PendingGrant?
    @ObservationIgnored private var owner: Owner?
    @ObservationIgnored private var startTask: Task<StartedSession, Error>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var runnerClient: PhoneRunnerClient?
    @ObservationIgnored private var runnerStatus: PhoneRunnerStatus?
    @ObservationIgnored private var preparationRevision = 0
    @ObservationIgnored private var lastFailure: String?

    init(defaults: UserDefaults = .standard,
         credentials: any IOSPhoneControlCredentialStoring = IOSPhoneControlCredentials(),
         session: PhoneControlSession = PhoneControlSession()) {
        self.defaults = defaults
        self.credentials = credentials
        self.session = session
        enabled = defaults.bool(forKey: Self.enabledPreferenceKey)
        selectedBundleIDs = Set(defaults.stringArray(forKey: Self.selectedBundleIDsPreferenceKey) ?? [])
        Task { await refreshPreparation() }
    }

    func refreshPreparation() async {
        guard !isUpdatingPairing else { return }
        let revision = preparationRevision
        do {
            let prepared = try await credentials.loadPairing() != nil
            guard revision == preparationRevision else { return }
            hasPreparedPairing = prepared
        } catch {
            guard revision == preparationRevision else { return }
            hasPreparedPairing = false
            if !isOccupied {
                phase = .failed
                statusMessage = error.localizedDescription
            }
        }
    }

    func importPairing(_ data: Data) async throws {
        guard !isOccupied, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        isUpdatingPairing = true
        preparationRevision += 1
        defer { isUpdatingPairing = false }
        try await saveImportedPairing(data)
    }

    private func saveImportedPairing(_ data: Data) async throws {
        try Task.checkCancellation()
        try await credentials.savePairing(data)
        hasPreparedPairing = true
        discardPendingAuthorization()
        phase = .idle
        statusMessage = "配对文件已保存在本机钥匙串；runner 和同机开发服务仍须完成准备"
    }

    func importUSBPreparedPairing(from url: URL) async throws {
        try Task.checkCancellation()
        guard !isOccupied, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        isUpdatingPairing = true
        preparationRevision += 1
        defer { isUpdatingPairing = false }
        let data = try await Task.detached(priority: .userInitiated) {
            try IOSPhoneControlCredentials.readUSBPairingFile(url)
        }.value
        try await saveImportedPairing(data)
        do {
            try await Task.detached(priority: .userInitiated) {
                // Delete only the same task-owned file that was successfully saved.
                guard try IOSPhoneControlCredentials.readUSBPairingFile(url) == data else {
                    throw IOSPhoneControlCredentialError.usbMaterialChanged
                }
                try FileManager.default.removeItem(at: url)
            }.value
        } catch {
            statusMessage = "配对已保存在本机钥匙串；USB 暂存材料未能清理。"
            throw error
        }
    }

    /// Explicit preparation only. It does not install a runner or start any GUI control session.
    func preparePairing() async throws {
        guard !isOccupied, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        let id = UUID()
        isUpdatingPairing = true
        preparationRevision += 1
        pairingOperationID = id
        pairingStatus = nil
        discardPendingAuthorization()
        phase = .pairing
        statusMessage = "正在请求本机开发配对；如出现系统提示，请确认本次配对"
        let operation = Task { [self] in
            let existing = try await credentials.loadPairing()
            try Task.checkCancellation()
            if existing != nil { return false }
            hasPreparedPairing = false
            let data = try await pairingSession.prepare(id: id) { [weak self] status in
                await self?.recordPairingProgress(status, id: id)
            }
            try Task.checkCancellation()
            try await credentials.savePairing(data)
            return true
        }
        pairingTask = operation
        defer {
            pairingTask = nil
            pairingOperationID = nil
            isUpdatingPairing = false
        }
        do {
            let created = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            hasPreparedPairing = true
            phase = .idle
            statusMessage = created
                ? "首次配对已完成并保存在本机钥匙串；runner 仍须单独签名安装，尚未验证控制连接"
                : "已有有效的本机配对文件，未创建新的系统配对；runner 仍须单独准备"
        } catch {
            // The pairing actor has stopped and joined its native operation before returning.
            phase = error is CancellationError ? .idle : .failed
            statusMessage = error is CancellationError ? "首次配对已取消，本次未启动控制会话" : error.localizedDescription
            throw error
        }
    }

    func cancelPreparation() {
        guard let id = pairingOperationID, let pairingTask else { return }
        pairingTask.cancel()
        phase = .stopping
        statusMessage = "正在取消首次配对并关闭开发连接"
        Task { await pairingSession.cancel(id: id) }
    }

    private func recordPairingProgress(_ status: PhoneControlLaunchStatus, id: UUID) {
        guard pairingOperationID == id, pairingTask?.isCancelled == false else { return }
        pairingStatus = status
        statusMessage = "\(status.message)（\(status.diagnosticSummary)）"
    }

    func removePairing() async throws {
        guard !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        isUpdatingPairing = true
        preparationRevision += 1
        defer { isUpdatingPairing = false }
        discardPendingAuthorization()
        await stopCurrent()
        try await credentials.deletePairing()
        hasPreparedPairing = false
        phase = .idle
        statusMessage = "已移除本机配对文件"
    }

    func authorizeNextTask(durationSeconds: Int) throws {
        guard enabled else { throw IOSPhoneControlError.disabled }
        guard !isOccupied, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        guard hasPreparedPairing else { throw IOSPhoneControlError.unprepared }
        guard [0, 300, 1_800, 7_200].contains(durationSeconds) else {
            throw IOSPhoneControlError.invalidDuration
        }
        guard !selectedBundleIDs.isEmpty, selectedBundleIDs.allSatisfy(Self.validBundleID) else {
            throw IOSPhoneControlError.invalidScope
        }
        let grant = PendingGrant(
            scope: selectedBundleIDs,
            validUntil: durationSeconds == 0
                ? nil
                : Date().addingTimeInterval(TimeInterval(durationSeconds))
        )
        pending = grant
        expirationTask?.cancel()
        expirationTask = nil
        if let validUntil = grant.validUntil {
            expirationTask = Task { [weak self] in
                let delay = max(0, validUntil.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self else { return }
                if self.pending?.validUntil == validUntil {
                    self.expireAuthorizationWindow()
                } else if self.owner?.active == true, self.owner?.expiresAt == validUntil {
                    self.endCurrentTask()
                }
            }
        }
        authorizationTargetSummary = selectedBundleIDs.sorted().joined(separator: ", ")
        authorizedDurationSeconds = durationSeconds
        phase = .authorized
        statusMessage = durationSeconds == 0
            ? "授权窗口已开启；可供多个由你发起的任务复用，不设软件到期"
            : "授权窗口已开启；可供多个由你发起的任务复用，窗口固定持续 \(durationSeconds / 60) 分钟"
    }

    func discardPendingAuthorization() {
        clearAuthorizationWindow()
    }

    /// Clears the window only when the matching run still owns the slot.
    /// Call this before stopping a run whose action outcome is unknown.
    @discardableResult
    func revokeAuthorizationWindow(runID: String) -> Bool {
        guard owner?.runID == runID, owner?.active == true else { return false }
        discardPendingAuthorization()
        return true
    }

    private func clearAuthorizationWindow() {
        pending = nil
        if !isOccupied {
            expirationTask?.cancel()
            expirationTask = nil
            authorizationTargetSummary = ""
            authorizedDurationSeconds = nil
            if phase == .authorized {
                phase = .idle
                statusMessage = "手机控制授权窗口已撤销"
            }
        }
    }

    /// The host calls this only for a new user-started run, never on handoff or cold recovery.
    func claim(runID: String, onExpiration: @escaping @MainActor () -> Void) -> Bool {
        guard enabled, !isOccupied, !isUpdatingPairing,
              let pending else { return false }
        if let validUntil = pending.validUntil, validUntil <= Date() {
            expireAuthorizationWindow()
            return false
        }
        let context = Owner(runID: runID, sessionID: UUID(), scope: pending.scope,
                            expiresAt: pending.validUntil,
                            onExpiration: onExpiration)
        owner = context
        ownerRunID = runID
        lastFailure = nil
        phase = .authorized
        statusMessage = "本任务已取得授权窗口，正在等待本机连接启动"
        return true
    }

    func hasRequestedSession(runID: String) -> Bool {
        owner?.runID == runID && startTask != nil
    }

    @discardableResult
    func start(runID: String) async throws -> PhoneRunnerStatus {
        let context = try activeOwner(runID: runID)
        if let runnerStatus, phase == .ready { return runnerStatus }
        let startup: Task<StartedSession, Error>
        if let startTask {
            startup = startTask
        } else {
            phase = .starting
            statusMessage = "正在启动本机开发测试会话和签名控制连接"
            startup = Task { [self] in
                guard let pairing = try await credentials.loadPairing() else {
                    throw IOSPhoneControlError.unprepared
                }
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID)
                let validatedPairing = try IOSPhoneControlCredentials.validatedPairing(pairing)
                let discovery = IOSPhoneControlServiceInspection()
                let services = await discovery.inspectAndRecord(source: "control")
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID)
                let endpoint = try services.uniqueLocalIPv4Endpoint
                IOSBackgroundLifecycleLog.record("phoneControlResolvedEndpoint",
                    detail: "source=bonjour_self port=49152 loopback=\(endpoint == "127.0.0.1:49152")")
                let configuration = PhoneControlLaunchConfiguration(pairing: validatedPairing,
                                                                    endpoint: endpoint,
                                                                    allowedBundleIDs: context.scope)
                let status = try await session.start(runID: context.sessionID, configuration: configuration)
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID)
                let client = try await session.runner(runID: context.sessionID)
                return StartedSession(status: status, client: client)
            }
            startTask = startup
        }
        do {
            let started = try await startup.value
            _ = try activeOwner(runID: runID)
            runnerClient = started.client
            runnerStatus = started.status
            phase = .ready
            statusMessage = "本次启动已连接，实际可用性以新的界面观察为准；截图由任务单独请求"
            return started.status
        } catch {
            if owner?.runID == runID, owner?.active == true {
                lastFailure = error.localizedDescription
                revoke(runID: runID)
            }
            throw error
        }
    }

    func runner(runID: String) throws -> PhoneRunnerClient {
        _ = try activeOwner(runID: runID)
        guard phase == .ready, let runnerClient else { throw IOSPhoneControlError.unprepared }
        return runnerClient
    }

    /// A cached status read does not create a test session or touch Keychain/native services.
    func statusText(runID: String) -> String {
        guard let owner, owner.runID == runID, owner.active,
              owner.expiresAt.map({ $0 > Date() }) ?? true else {
            return "本任务没有有效的手机控制授权；状态读取不会启动或恢复控制会话。"
        }
        let remaining = owner.expiresAt.map {
            String(max(0, Int($0.timeIntervalSinceNow.rounded(.up))))
        } ?? "unlimited"
        let remainingLabel = owner.expiresAt == nil
            ? "authorization_remaining=unlimited"
            : "authorization_remaining_seconds=\(remaining)"
        return "phase=\(phase.rawValue)\n\(statusMessage)\n这是本次启动的最后状态；实际可用性以新观察为准。\nscope=\(owner.scope.sorted().joined(separator: ","))\n\(remainingLabel)"
    }

    /// Revoke synchronously; keep the slot until native runtime join finishes.
    func revoke(runID: String) {
        guard var owner, owner.runID == runID, owner.active else { return }
        owner.active = false
        self.owner = owner
        runnerClient = nil
        runnerStatus = nil
        if pending == nil {
            expirationTask?.cancel()
            expirationTask = nil
        }
        startTask?.cancel()
        phase = .stopping
        statusMessage = "正在关闭本任务的手机控制连接"
        let startup = startTask
        cleanupTask = Task { [self] in
            await session.stop(runID: owner.sessionID)
            // A cancelled actor hop must finish before this owner can hand its slot to another run.
            _ = await startup?.result
            await session.stop(runID: owner.sessionID)
            guard self.owner?.runID == runID else { return }
            self.owner = nil
            ownerRunID = nil
            startTask = nil
            cleanupTask = nil
            if let pending, pending.validUntil.map({ $0 > Date() }) ?? true {
                phase = .authorized
                statusMessage = lastFailure.map { "\($0)；授权窗口仍有效" }
                    ?? "本轮手机控制连接已关闭；授权窗口仍有效"
            } else {
                clearAuthorizationWindow()
                phase = lastFailure == nil ? .idle : .failed
                statusMessage = lastFailure ?? "本轮手机控制连接已关闭"
            }
        }
    }

    func stop(runID: String) async {
        guard owner?.runID == runID else { return }
        revoke(runID: runID)
        await cleanupTask?.value
    }

    /// The visible stop/disable operation also cancels the matching foreground or handed-off run.
    func stopCurrent() async {
        let runID = owner?.runID
        discardPendingAuthorization()
        endCurrentTask()
        if let runID { await stop(runID: runID) }
    }

    private func endCurrentTask() {
        guard let owner, owner.active else { return }
        revoke(runID: owner.runID)
        owner.onExpiration()
    }

    private func activeOwner(runID: String) throws -> Owner {
        guard let owner, owner.runID == runID, owner.active else { throw IOSPhoneControlError.unauthorized }
        guard owner.expiresAt.map({ $0 > Date() }) ?? true else {
            endCurrentTask()
            throw IOSPhoneControlError.expired
        }
        return owner
    }

    private func expireAuthorizationWindow() {
        guard pending != nil else { return }
        clearAuthorizationWindow()
        if owner?.active == true {
            endCurrentTask()
        }
    }

    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private struct PendingGrant {
        let scope: Set<String>
        let validUntil: Date?
    }
    private struct Owner {
        let runID: String
        let sessionID: UUID
        let scope: Set<String>
        let expiresAt: Date?
        let onExpiration: @MainActor () -> Void
        var active = true
    }
    private struct StartedSession: Sendable {
        let status: PhoneRunnerStatus
        let client: PhoneRunnerClient
    }
}
