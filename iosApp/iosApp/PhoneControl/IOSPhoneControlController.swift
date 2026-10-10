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
        case .invalidDuration: "本次授权时长须在 60 到 300 秒之间。"
        case .unauthorized: "本任务没有手机控制授权。请在设置中授权下一次用户发起的任务。"
        case .expired: "本次手机控制授权已到期。"
        }
    }
}

/// The app owns the connection; a settings/chat page only observes it.
/// A grant is consumed by one user-started run and is never persisted or restored after process death.
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
            // Editing the next-task scope cannot expand an already frozen run's scope.
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
        return enabled && pending.validUntil > Date()
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
        try await credentials.savePairing(data)
        hasPreparedPairing = true
        discardPendingAuthorization()
        phase = .idle
        statusMessage = "配对文件已保存在本机钥匙串；runner 和同机开发服务仍须完成准备"
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
        guard (60...300).contains(durationSeconds) else { throw IOSPhoneControlError.invalidDuration }
        guard !selectedBundleIDs.isEmpty, selectedBundleIDs.allSatisfy(Self.validBundleID) else {
            throw IOSPhoneControlError.invalidScope
        }
        let grant = PendingGrant(scope: selectedBundleIDs, duration: durationSeconds,
                                 validUntil: Date().addingTimeInterval(300))
        pending = grant
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
            guard let self, self.pending?.validUntil == grant.validUntil else { return }
            self.discardPendingAuthorization()
        }
        authorizationTargetSummary = selectedBundleIDs.sorted().joined(separator: ", ")
        authorizedDurationSeconds = durationSeconds
        phase = .authorized
        statusMessage = "已授权下一次用户发起的任务；请在 5 分钟内开始，任务授权持续 \(durationSeconds) 秒"
    }

    func discardPendingAuthorization() {
        pending = nil
        if !isOccupied {
            expirationTask?.cancel()
            expirationTask = nil
            authorizationTargetSummary = ""
            authorizedDurationSeconds = nil
            if phase == .authorized {
                phase = .idle
                statusMessage = "下一次任务的手机控制授权已撤销"
            }
        }
    }

    /// The host calls this only for a new user-started run, never on handoff or cold recovery.
    func claim(runID: String, onExpiration: @escaping @MainActor () -> Void) -> Bool {
        guard enabled, !isOccupied, !isUpdatingPairing,
              let pending, pending.validUntil > Date() else { return false }
        self.pending = nil
        expirationTask?.cancel()
        let context = Owner(runID: runID, sessionID: UUID(), scope: pending.scope,
                            expiresAt: Date().addingTimeInterval(TimeInterval(pending.duration)),
                            onExpiration: onExpiration)
        owner = context
        ownerRunID = runID
        lastFailure = nil
        phase = .authorized
        statusMessage = "本任务已取得手机控制授权，正在等待本机连接启动"
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(pending.duration)) }
            catch { return }
            guard let self, self.owner?.runID == runID, self.owner?.active == true else { return }
            self.endCurrentTask()
        }
        return true
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
                let configuration = PhoneControlLaunchConfiguration(pairing: pairing,
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
        guard let owner, owner.runID == runID, owner.active, owner.expiresAt > Date() else {
            return "本任务没有有效的手机控制授权；状态读取不会启动或恢复控制会话。"
        }
        let remaining = max(0, Int(owner.expiresAt.timeIntervalSinceNow.rounded(.up)))
        return "phase=\(phase.rawValue)\n\(statusMessage)\n这是本次启动的最后状态；实际可用性以新观察为准。\nscope=\(owner.scope.sorted().joined(separator: ","))\nauthorization_remaining_seconds=\(remaining)"
    }

    /// Revoke synchronously; keep the slot until native runtime join finishes.
    func revoke(runID: String) {
        guard var owner, owner.runID == runID, owner.active else { return }
        owner.active = false
        self.owner = owner
        runnerClient = nil
        runnerStatus = nil
        expirationTask?.cancel()
        expirationTask = nil
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
            authorizationTargetSummary = ""
            authorizedDurationSeconds = nil
            phase = lastFailure == nil ? .idle : .failed
            statusMessage = lastFailure ?? "本轮手机控制连接已关闭"
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
        guard owner.expiresAt > Date() else {
            endCurrentTask()
            throw IOSPhoneControlError.expired
        }
        return owner
    }

    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private struct PendingGrant {
        let scope: Set<String>
        let duration: Int
        let validUntil: Date
    }
    private struct Owner {
        let runID: String
        let sessionID: UUID
        let scope: Set<String>
        let expiresAt: Date
        let onExpiration: @MainActor () -> Void
        var active = true
    }
    private struct StartedSession: Sendable {
        let status: PhoneRunnerStatus
        let client: PhoneRunnerClient
    }
}
