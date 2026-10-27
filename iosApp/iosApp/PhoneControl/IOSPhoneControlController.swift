import AmberPhoneControl
import Foundation
import Observation
import UIKit

/// Explicit device-delivery check, unavailable to tools and normal launches.
/// UI inspections are read-only; catalog inspection writes only to its disposable preferences suite.
enum IOSPhoneControlReadinessInspection {
    static let diagnosticLaunchArgument = "-amber-phone-readiness-inspection-once"
    static let inputDiagnosticLaunchArgument = "-amber-phone-input-inspection-once"
    static let applicationsDiagnosticLaunchArgument = "-amber-phone-apps-inspection-once"
    static let existingVPNDiagnosticLaunchArgument = "-amber-phone-existing-vpn-inspection-once"

    @MainActor
    static func runExistingVPNOnce() async {
        guard !IOSPhoneControlController.shared.isOccupied else { return }
        let suite = "PhoneControlExistingVPNInspection.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: IOSPhoneControlController.enabledPreferenceKey)
        defaults.set(IOSPhoneControlConnectionMode.existingVPN.rawValue,
                     forKey: IOSPhoneControlController.connectionModePreferenceKey)
        let controller = IOSPhoneControlController(defaults: defaults)
        IOSBackgroundLifecycleLog.record("phoneControlExistingVPNInspection", detail: "stage=start")
        do {
            try await controller.checkReadiness()
            let report = controller.readinessReport
            IOSBackgroundLifecycleLog.record("phoneControlExistingVPNInspection",
                detail: "stage=finished connection=\(report?.connectionVerifiedAt != nil) ui_read=\(report?.uiReadAt != nil) nodes=\(report?.nodeCount ?? 0) cleanup=\(report?.cleanupComplete == true) failure_stage=\(String(describing: report?.failureStage))")
        } catch {
            let error = error as NSError
            IOSBackgroundLifecycleLog.record("phoneControlExistingVPNInspection",
                detail: "stage=failed domain=\(error.domain) code=\(error.code)")
        }
    }

    @MainActor
    static func runApplicationsOnce() async {
        guard !IOSPhoneControlController.shared.isOccupied else {
            print("phoneControlAppsInspection result=busy")
            return
        }
        let operation = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let suite = "PhoneControlAppsInspection.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                print("phoneControlAppsInspection result=preferences_unavailable")
                return
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let credentials = IOSPhoneControlCredentials()
            let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials)
            controller.enabled = true
            let runID = UUID().uuidString
            guard controller.claim(runID: runID, onStop: {}) else {
                print("phoneControlAppsInspection result=claim_failed")
                return
            }
            let executor = IOSPhoneControlToolExecutor(runID: runID, controller: controller, reportActivity: { _ in })
            var toolsSucceeded = true
            for (name, arguments) in [
                ("phone_apps", #"{"query":"app.amber.ios","limit":100}"#),
                ("phone_add_app", #"{"bundle_id":"app.amber.ios"}"#),
            ] {
                let outcome = await executor.execute(name: name, arguments: arguments, isUserInitiated: true)
                let classification: String
                switch outcome {
                case .filled: classification = "filled"
                case .failed: classification = "failed"
                case .denied: classification = "denied"
                default: classification = "other"
                }
                var valid = false
                if case .filled(let text) = outcome,
                   let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    if name == "phone_apps" {
                        valid = (object["applications"] as? [[String: Any]])?.contains { $0["bundle_id"] as? String == "app.amber.ios" } == true
                    } else {
                        valid = object["bundle_id"] as? String == "app.amber.ios"
                            && object["selected"] as? Bool == true && object["outcome"] as? String == "completed"
                    }
                }
                print("phoneControlAppsInspection stage=\(name) outcome=\(classification) success=\(valid) count=\(controller.installedApplications.count) cancelled=\(Task.isCancelled)")
                if !valid || Task.isCancelled { toolsSucceeded = false; break }
            }
            if toolsSucceeded {
                let restored = IOSPhoneControlController(defaults: defaults, credentials: credentials)
                let nameMatches = controller.installedApplications.first { $0.bundleID == "app.amber.ios" }
                    .map { !$0.name.isEmpty && restored.applicationNames["app.amber.ios"] == $0.name } ?? false
                let scopeMatches = restored.selectedBundleIDs == ["app.amber.ios"]
                let noOwner = restored.ownerRunID == nil
                let noRunner = controller.phase == .authorized
                let passed = restored.enabled && scopeMatches && nameMatches && noOwner && noRunner
                print("phoneControlAppsInspection stage=restored success=\(passed) enabled=\(restored.enabled) scope_matches=\(scopeMatches) name_matches=\(nameMatches) owner_absent=\(noOwner) runner_not_started=\(noRunner)")
                await restored.stopCurrent()
            }
            await controller.stop(runID: runID)
            print("phoneControlAppsInspection result=finished owner_absent=\(controller.ownerRunID == nil)")
        }
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PhoneAppsInspection") {
            operation.cancel()
            print("phoneControlAppsInspection result=background_expired")
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        if backgroundTask == .invalid {
            operation.cancel()
            print("phoneControlAppsInspection result=background_budget_unavailable")
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            operation.cancel()
            print("phoneControlAppsInspection result=timeout")
        }
        await operation.value
        deadline.cancel()
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }

    @MainActor
    static func runOnce(inspectInput: Bool = false) async {
        let operation = Task { await inspectOnce(inspectInput: inspectInput) }
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        if inspectInput {
            // Keep the user's chat in front. Expiration cancels pending reads and
            // releases the OS assertion immediately, before async session cleanup.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PhoneInputInspection") {
                operation.cancel()
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
            if backgroundTask == .invalid {
                operation.cancel()
                IOSBackgroundLifecycleLog.record("phoneControlReadinessInspection", detail: "result=background_budget_unavailable")
            }
        }
        await operation.value
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }

    @MainActor
    private static func inspectOnce(inspectInput: Bool) async {
        let session = PhoneControlSession()
        let tunnel = IOSPhoneControlLocalTunnel()
        let runID = UUID()
        let bundleID = inspectInput ? "com.dancesuite.dance.ka.saxmsa667" : "app.amber.ios"
        IOSBackgroundLifecycleLog.record("phoneControlReadinessInspectionStarted", detail: "input=\(inspectInput)")
        do {
            try Task.checkCancellation()
            guard let pairing = try await IOSPhoneControlCredentials().loadPairing() else {
                IOSBackgroundLifecycleLog.record("phoneControlReadinessInspection", detail: "result=missing_pairing")
                return
            }
            let configuration = PhoneControlLaunchConfiguration(
                pairing: pairing, allowedBundleIDs: [bundleID]
            )
            try await tunnel.start(owner: runID)
            try Task.checkCancellation()
            let status = try await session.start(runID: runID, configuration: configuration)
            IOSBackgroundLifecycleLog.record("phoneControlReadinessInspection",
                detail: "result=runner_ready ready=\(status.ready) authenticated=\(status.requiresAuthentication)")
            let client = try await session.runner(runID: runID)
            for budget in inspectInput ? [500, 2000] : [200] {
                let observation = try await client.observe(maxNodes: budget)
                let inputTypes: Set<String> = ["XCUIElementTypeTextField", "XCUIElementTypeSecureTextField",
                                                "XCUIElementTypeTextView", "XCUIElementTypeSearchField"]
                let inputs = observation.nodes.filter { inputTypes.contains($0.type) && $0.enabled && $0.ref != nil }
                IOSBackgroundLifecycleLog.record("phoneControlReadinessInspection",
                    detail: "result=tree app_matches=\(observation.bundleID == bundleID) budget=\(budget) nodes=\(observation.nodes.count) truncated=\(observation.truncated) backend=\(observation.backend) inputs=\(inputs.count)")
            }
        } catch {
            // Only native fixed metadata and a typed client code may leave this
            // diagnostic. UI labels, Keychain data and tokens are never logged.
            let status: PhoneControlLaunchStatus?
            if case PhoneControlSessionError.nativeLaunch(let failure) = error {
                status = failure
            } else {
                status = try? await session.launchStatus(runID: runID)
            }
            let clientCode = (error as? PhoneControlProblem)?.kind.rawValue ?? "none"
            IOSBackgroundLifecycleLog.record("phoneControlReadinessInspection",
                detail: "result=failed client=\(clientCode) phase=\(status?.phase ?? "none") \(status?.diagnosticSummary ?? "no_native_status")")
        }
        await session.stop(runID: runID)
        let disconnected = await tunnel.stop(owner: runID)
        IOSBackgroundLifecycleLog.record("phoneControlReadinessInspectionFinished", detail: "disconnected=\(disconnected)")
    }
}

enum IOSPhoneControlPhase: String {
    case idle, authorized, pairing, starting, ready, stopping, failed
}

struct IOSPhoneControlStopResult: Sendable, Equatable {
    let cleanupFailure: String?
    var cleanupComplete: Bool { cleanupFailure == nil }
}

enum IOSPhoneControlError: LocalizedError {
    case disabled, unprepared, occupied, invalidScope, unauthorized, applicationNotFound, externallyManagedConnection

    var errorDescription: String? {
        switch self {
        case .disabled: "请先在设置中开启本机手机控制。"
        case .unprepared: "请先导入本机 RemotePairing 配对文件，并准备已签名的控制 runner。"
        case .occupied: "已有手机控制任务正在运行或关闭，请等原任务结束。"
        case .invalidScope: "请先添加允许控制的 App。"
        case .applicationNotFound: "未在本机应用列表中找到该 Bundle ID，请先查询应用并使用返回的准确 ID。"
        case .unauthorized: "本任务没有有效的手机控制连接权限，请重新发起任务。"
        case .externallyManagedConnection: "请在你使用的 VPN 中启用本地回环，并保持连接。"
        }
    }
}

/// The app owns the connection; a settings/chat page only observes it.
/// The switch persists; ownership belongs only to a new user-started run and is never restored after process death.
@MainActor
@Observable
final class IOSPhoneControlController {
    static let shared = IOSPhoneControlController()
    static let enabledPreferenceKey = "app.amber.ios.phoneControl.enabled.v1"
    static let applicationNamesPreferenceKey = "app.amber.ios.phoneControl.applicationNames.v1"
    static let selectedBundleIDsPreferenceKey = "app.amber.ios.phoneControl.scope.v1"
    static let connectionModePreferenceKey = "app.amber.ios.phoneControl.connectionMode.v1"

    private(set) var connectionMode: IOSPhoneControlConnectionMode
    var isConnectionPrepared: Bool { connectionMode == .existingVPN || localTunnel.isPrepared }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledPreferenceKey)
            if !enabled {
                applicationsTask?.cancel()
                cancelPreparation()
                endCurrentTask()
            }
        }
    }
    var selectedBundleIDs: Set<String> {
        didSet {
            guard selectedBundleIDs != oldValue else { return }
            defaults.set(selectedBundleIDs.sorted(), forKey: Self.selectedBundleIDsPreferenceKey)
            let names = applicationNames.filter { selectedBundleIDs.contains($0.key) }
            if applicationNames != names { applicationNames = names }
            // Settings changes apply to the next run; explicit app additions also extend its scope.
        }
    }
    private(set) var applicationNames: [String: String] {
        didSet {
            if applicationNames != oldValue {
                defaults.set(applicationNames, forKey: Self.applicationNamesPreferenceKey)
            }
        }
    }
    private(set) var installedApplications: [PhoneControlInstalledApp] = []
    private(set) var isLoadingApplications = false
    private(set) var hasPreparedPairing = false
    private(set) var isUpdatingPairing = false
    private(set) var isPreparingConnection = false
    let localTunnel: any IOSPhoneControlLocalTunneling
    private(set) var phase: IOSPhoneControlPhase = .idle
    private(set) var statusMessage = "尚未启动手机控制任务"
    private(set) var ownerRunID: String?
    private(set) var pairingStatus: PhoneControlLaunchStatus?
    private(set) var readinessReport: IOSPhoneControlReadinessReport?

    var isCheckingReadiness: Bool { readinessRunID != nil }

    var isOccupied: Bool { ownerRunID != nil }
    var isPreparingPairing: Bool { isUpdatingPairing && pairingOperationID != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any IOSPhoneControlCredentialStoring
    @ObservationIgnored private let applicationDiscoverer: any PhoneControlApplicationDiscovering
    @ObservationIgnored private let session: any IOSPhoneControlSessionServing
    @ObservationIgnored private let pairingSession: any PhoneControlPairingServing
    @ObservationIgnored private var pairingTask: Task<Bool, Error>?
    @ObservationIgnored private var pairingOperationID: UUID?
    private var owner: Owner?
    @ObservationIgnored private var startTask: Task<StartedSession, Error>?
    @ObservationIgnored private var applicationsTask: Task<[PhoneControlInstalledApp], Error>?
    @ObservationIgnored private var hasApplicationCatalog = false
    @ObservationIgnored private var cleanupTask: Task<IOSPhoneControlStopResult, Never>?
    @ObservationIgnored private var runnerClient: PhoneRunnerClient?
    @ObservationIgnored private var runnerStatus: PhoneRunnerStatus?
    @ObservationIgnored private var preparationRevision = 0
    @ObservationIgnored private var lastFailure: String?
    private var readinessRunID: String?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var readinessCleanupResult: IOSPhoneControlStopResult?
    @ObservationIgnored private let onHandoffChange: @MainActor (String, IOSPhoneControlHandoffState) -> Void

    init(defaults: UserDefaults = .standard,
         credentials: any IOSPhoneControlCredentialStoring = IOSPhoneControlCredentials(),
         session: any IOSPhoneControlSessionServing = PhoneControlSession(),
         applications: any PhoneControlApplicationDiscovering = PhoneControlApplications(),
         localTunnel: any IOSPhoneControlLocalTunneling = IOSPhoneControlLocalTunnel(),
         pairingSession: any PhoneControlPairingServing = PhoneControlPairingSession(),
         onHandoffChange: @escaping @MainActor (String, IOSPhoneControlHandoffState) -> Void = { runID, _ in
             // The activity update entry point overlays the current owner's handoff state.
             Task { await AgentLiveActivityController.shared.updatePhoneControl(runID: runID, phase: .waitingForModel) }
         }) {
        self.defaults = defaults
        self.credentials = credentials
        self.session = session
        self.applicationDiscoverer = applications
        self.localTunnel = localTunnel
        self.pairingSession = pairingSession
        self.onHandoffChange = onHandoffChange
        connectionMode = defaults.string(forKey: Self.connectionModePreferenceKey)
            .flatMap(IOSPhoneControlConnectionMode.init(rawValue:)) ?? .embedded
        enabled = defaults.bool(forKey: Self.enabledPreferenceKey)
        let selected = Set(defaults.stringArray(forKey: Self.selectedBundleIDsPreferenceKey) ?? [])
        selectedBundleIDs = selected
        applicationNames = (defaults.dictionary(forKey: Self.applicationNamesPreferenceKey) as? [String: String] ?? [:])
            .filter { selected.contains($0.key) }
        Task { await refreshPreparation() }
    }

    func refreshPreparation() async {
        guard !isUpdatingPairing, !isPreparingConnection else { return }
        let revision = preparationRevision
        if connectionMode == .embedded { await localTunnel.refresh() }
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

    /// Creates only Amber's connection configuration; the task starts it when needed.
    func prepareConnection() async throws {
        guard !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else {
            throw IOSPhoneControlError.occupied
        }
        guard connectionMode == .embedded else { throw IOSPhoneControlError.externallyManagedConnection }
        isPreparingConnection = true
        defer { isPreparingConnection = false }
        do {
            try await localTunnel.prepare()
            try Task.checkCancellation()
            readinessReport = nil
            phase = .idle
            statusMessage = "本机连接已准备，手机控制任务会自动连接并在结束后关闭"
        } catch {
            phase = error is CancellationError ? .idle : .failed
            statusMessage = error is CancellationError ? "本机连接准备已取消" : error.localizedDescription
            throw error
        }
    }

    func setConnectionMode(_ mode: IOSPhoneControlConnectionMode) throws {
        guard !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else {
            throw IOSPhoneControlError.occupied
        }
        guard mode != connectionMode else { return }
        connectionMode = mode
        defaults.set(mode.rawValue, forKey: Self.connectionModePreferenceKey)
        preparationRevision += 1
        readinessReport = nil
        hasApplicationCatalog = false
        installedApplications = []
        lastFailure = nil
        phase = .idle
        statusMessage = mode == .embedded ? "已选择内置本机连接" : "已选择现有 VPN；请确认已启用本地回环并连接"
        Task { await refreshPreparation() }
    }

    func importPairing(_ data: Data) async throws {
        guard !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else { throw IOSPhoneControlError.occupied }
        isUpdatingPairing = true
        preparationRevision += 1
        defer { isUpdatingPairing = false }
        try await saveImportedPairing(data)
    }

    private func saveImportedPairing(_ data: Data) async throws {
        try Task.checkCancellation()
        try await credentials.savePairing(data)
        hasPreparedPairing = true
        readinessReport = nil
        hasApplicationCatalog = false
        installedApplications = []
        phase = .idle
        statusMessage = "配对文件已保存在本机钥匙串；runner 和同机开发服务仍须完成准备"
    }

    func importUSBPreparedPairing(from url: URL) async throws {
        try Task.checkCancellation()
        guard !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else { throw IOSPhoneControlError.occupied }
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
        guard !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else { throw IOSPhoneControlError.occupied }
        let id = UUID()
        let connectionMode = self.connectionMode
        isUpdatingPairing = true
        preparationRevision += 1
        pairingOperationID = id
        pairingStatus = nil
        phase = .pairing
        statusMessage = "正在请求本机开发配对；如出现系统提示，请确认本次配对"
        let operation = Task { [self] in
            let existing = try await credentials.loadPairing()
            try Task.checkCancellation()
            if existing != nil { return false }
            hasPreparedPairing = false
            do {
                if connectionMode == .embedded { try await localTunnel.start(owner: id) }
                try Task.checkCancellation()
                _ = await localTunnel.resolveRemotePairingPort()
                try Task.checkCancellation()
                let data = try await pairingSession.prepare(id: id, connectionMode: connectionMode) { [weak self] status in
                    await self?.recordPairingProgress(status, id: id)
                }
                try Task.checkCancellation()
                // Preserve a completed system pairing even if tunnel disconnection later fails.
                try await credentials.savePairing(data)
            } catch {
                // prepare() returns only after its native handle has stopped and joined.
                let disconnected = connectionMode == .embedded ? await localTunnel.stop(owner: id) : true
                if !disconnected, error is CancellationError {
                    throw IOSPhoneControlLocalTunnelError.disconnectionTimedOut
                }
                throw error
            }
            let disconnected = connectionMode == .embedded ? await localTunnel.stop(owner: id) : true
            guard disconnected else {
                throw IOSPhoneControlLocalTunnelError.disconnectionTimedOut
            }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            hasPreparedPairing = true
            readinessReport = nil
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
        guard !isPreparingConnection, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        isUpdatingPairing = true
        preparationRevision += 1
        defer { isUpdatingPairing = false }
        await stopCurrent()
        try await credentials.deletePairing()
        hasPreparedPairing = false
        readinessReport = nil
        hasApplicationCatalog = false
        installedApplications = []
        phase = .idle
        statusMessage = "已移除本机配对文件"
    }

    /// The host calls this only for a new user-started run, never on handoff or cold recovery.
    /// An empty scope still permits status and app discovery; starting control requires selected apps.
    func claim(runID: String, onStop: @escaping @MainActor () -> Void) -> Bool {
        guard enabled, !isOccupied, !isPreparingConnection, !isUpdatingPairing, !isLoadingApplications else { return false }
        owner = Owner(runID: runID, sessionID: UUID(), scope: selectedBundleIDs, onStop: onStop)
        ownerRunID = runID
        hasApplicationCatalog = false
        lastFailure = nil
        phase = .authorized
        statusMessage = "本任务可使用手机控制工具，连接将在首次操作时启动"
        return true
    }

    func handoffState(runID: String) -> IOSPhoneControlHandoffState? {
        guard let owner, owner.runID == runID, owner.active, !owner.outcomeUnknown,
              readinessRunID != runID else { return nil }
        return owner.handoffState
    }

    func handoffFailure(runID: String) -> String? {
        try? handoffOwner(runID: runID).handoffFailure
    }

    func requestHumanTakeover(runID: String) throws {
        var context = try handoffOwner(runID: runID)
        guard context.handoffState != .pausing, context.handoffState != .paused else { return }
        context.takeoverGeneration += 1
        context.needsFreshObservation = true
        context.handoffState = context.activeTool == nil ? .paused : .pausing
        owner = context
        onHandoffChange(runID, context.handoffState)
    }

    func resumeAutomation(runID: String) throws {
        var context = try handoffOwner(runID: runID)
        if context.handoffState == .resuming { return }
        guard context.handoffState == .paused else {
            throw context.handoffState == .pausing
                ? IOSPhoneControlHandoffError.operationInFlight : IOSPhoneControlHandoffError.notPaused
        }
        context.handoffState = .resuming
        context.handoffFailure = nil
        let waiter = context.resumeWaiter
        context.resumeWaiter = nil
        owner = context
        waiter?.continuation.resume(returning: context.takeoverGeneration)
        onHandoffChange(runID, .resuming)
    }

    /// The executor registers the entire tool, including reads that may start the runner.
    /// It ends this lease after the receipt, before waiting for the user to resume.
    func beginPhoneTool(runID: String) throws -> IOSPhoneControlToolLease {
        var context = try handoffOwner(runID: runID)
        guard context.activeTool == nil, context.resumeWaiter == nil else { throw IOSPhoneControlError.occupied }
        let lease = IOSPhoneControlToolLease(runID: runID, sessionID: context.sessionID,
            operationID: UUID(), takeoverGeneration: context.takeoverGeneration)
        context.activeTool = lease
        owner = context
        return lease
    }

    /// Unknown stays authoritative; the existing engine records it and owns teardown.
    func endPhoneTool(_ lease: IOSPhoneControlToolLease, outcomeUnknown: Bool = false) {
        guard var context = owner, context.active, context.runID == lease.runID,
              context.sessionID == lease.sessionID, context.activeTool == lease else { return }
        context.activeTool = nil
        if outcomeUnknown {
            context.outcomeUnknown = true
            let waiter = context.resumeWaiter
            context.resumeWaiter = nil
            owner = context
            waiter?.continuation.resume(throwing: IOSPhoneControlHandoffError.outcomeUnknown)
            return
        }
        let paused = context.handoffState == .pausing
        if paused { context.handoffState = .paused }
        owner = context
        if paused { onHandoffChange(lease.runID, .paused) }
    }

    func canDispatchAction(runID: String) -> Bool {
        guard let context = owner, context.runID == runID, context.active, !context.outcomeUnknown,
              readinessRunID != runID else { return false }
        return phase == .ready && context.handoffState == .automated && !context.needsFreshObservation
    }

    func requiresFreshObservation(_ lease: IOSPhoneControlToolLease) throws -> Bool {
        let context = try handoffOwner(runID: lease.runID, sessionID: lease.sessionID)
        return context.needsFreshObservation || context.takeoverGeneration != lease.takeoverGeneration
    }

    /// A single waiter belongs to this owner, never to a settings page or a recovered run.
    func waitForAutomationResume(_ lease: IOSPhoneControlToolLease) async throws -> Int {
        try Task.checkCancellation()
        let context = try handoffOwner(runID: lease.runID, sessionID: lease.sessionID)
        if context.handoffState == .automated || context.handoffState == .resuming {
            return context.takeoverGeneration
        }
        guard context.resumeWaiter == nil else { throw IOSPhoneControlError.occupied }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can precede the handler's MainActor hop.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard var current = owner, current.active, current.sessionID == lease.sessionID,
                      current.runID == lease.runID, !current.outcomeUnknown else {
                    continuation.resume(throwing: IOSPhoneControlError.unauthorized)
                    return
                }
                current.resumeWaiter = ResumeWaiter(id: waiterID, continuation: continuation)
                owner = current
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelResumeWaiter(lease, waiterID: waiterID)
            }
        }
    }

    /// Called only after the executor has obtained a fresh runner observation.
    /// A second pause during that await cannot be consumed by the older read.
    @discardableResult
    func consumeFreshObservation(_ lease: IOSPhoneControlToolLease, generation: Int) throws -> Bool {
        var context = try handoffOwner(runID: lease.runID, sessionID: lease.sessionID)
        guard context.takeoverGeneration == generation, context.handoffState == .resuming,
              context.needsFreshObservation else { return false }
        context.needsFreshObservation = false
        context.handoffState = .automated
        owner = context
        onHandoffChange(lease.runID, .automated)
        return true
    }

    /// A failed read must wait for another explicit resume, without changing a
    /// newer takeover or the authoritative unknown/stopped outcome.
    @discardableResult
    func failResumeObservation(_ lease: IOSPhoneControlToolLease, generation: Int, message: String) -> Bool {
        guard var context = try? handoffOwner(runID: lease.runID, sessionID: lease.sessionID),
              context.takeoverGeneration == generation, context.handoffState == .resuming,
              context.needsFreshObservation else { return false }
        context.handoffState = .paused
        context.handoffFailure = "重新读取界面失败：\(String(message.prefix(160)))"
        owner = context
        onHandoffChange(lease.runID, .paused)
        return true
    }

    private func handoffOwner(runID: String, sessionID: UUID? = nil) throws -> Owner {
        let context = try activeOwner(runID: runID, sessionID: sessionID)
        guard readinessRunID != runID else { throw IOSPhoneControlHandoffError.preparationCheck }
        guard !context.outcomeUnknown else { throw IOSPhoneControlHandoffError.outcomeUnknown }
        return context
    }

    private func cancelResumeWaiter(_ lease: IOSPhoneControlToolLease, waiterID: UUID) {
        guard var context = owner, context.runID == lease.runID, context.sessionID == lease.sessionID,
              context.resumeWaiter?.id == waiterID else { return }
        let waiter = context.resumeWaiter
        context.resumeWaiter = nil
        owner = context
        waiter?.continuation.resume(throwing: CancellationError())
    }

    /// A user-requested self check owns one temporary session and reads only a fresh UI tree.
    /// Amber is added to this owner's scope only; the saved app selection stays unchanged.
    func checkReadiness() async throws {
        guard enabled else { throw IOSPhoneControlError.disabled }
        guard !isCheckingReadiness else { throw IOSPhoneControlError.occupied }
        let runID = "readiness-\(UUID().uuidString)"
        guard claim(runID: runID, onStop: { [weak self] in self?.readinessTask?.cancel() }) else {
            throw IOSPhoneControlError.occupied
        }
        if let bundleID = Bundle.main.bundleIdentifier, Self.validBundleID(bundleID) {
            owner?.scope.insert(bundleID)
        }
        readinessRunID = runID
        readinessCleanupResult = nil
        readinessReport = IOSPhoneControlReadinessReport(startedAt: Date())
        let operation = Task { [self] in await performReadinessCheck(runID: runID) }
        readinessTask = operation
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        readinessTask = nil
        readinessRunID = nil
    }

    func cancelReadinessCheck() {
        guard let runID = readinessRunID else { return }
        readinessTask?.cancel()
        revoke(runID: runID)
    }

    private func performReadinessCheck(runID: String) async {
        do {
            try Task.checkCancellation()
            _ = try await start(runID: runID)
            try Task.checkCancellation()
            readinessReport?.connectionVerifiedAt = Date()
            readinessReport?.stage = .observation
            let client = try runner(runID: runID)
            let observation = try await client.observe(maxNodes: 200)
            try Task.checkCancellation()
            _ = try activeOwner(runID: runID)
            readinessReport?.uiReadAt = Date()
            readinessReport?.observedBundleID = observation.bundleID
            readinessReport?.nodeCount = observation.nodes.count
        } catch {
            readinessReport?.wasCancelled = error is CancellationError || Task.isCancelled
            if readinessReport?.wasCancelled == false {
                let failedStage = readinessReport?.stage
                readinessReport?.failureStage = failedStage
                readinessReport?.failureMessage = error.localizedDescription
            }
        }
        readinessReport?.stage = .cleanup
        let stopped = await stop(runID: runID) ?? readinessCleanupResult
        readinessReport?.cleanupComplete = stopped?.cleanupComplete == true
        if let failure = stopped?.cleanupFailure {
            // Keep the original failure and also make failed teardown explicit.
            if readinessReport?.failureStage == nil { readinessReport?.failureStage = .cleanup }
            let original = readinessReport?.failureMessage
            readinessReport?.failureMessage = original.map { "\($0)\n关闭临时连接失败：\(failure)" } ?? failure
        }
        readinessReport?.completedAt = Date()
    }

    func hasRequestedSession(runID: String) -> Bool {
        owner?.runID == runID && (startTask != nil || owner?.requestedApplications == true)
    }

    @discardableResult
    func start(runID: String) async throws -> PhoneRunnerStatus {
        _ = try await applicationsTask?.value
        try Task.checkCancellation()
        let context = try activeOwner(runID: runID)
        let connectionMode = self.connectionMode
        guard !context.scope.isEmpty, context.scope.allSatisfy(Self.validBundleID) else {
            throw IOSPhoneControlError.invalidScope
        }
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
                _ = try activeOwner(runID: runID, sessionID: context.sessionID)
                let validatedPairing = try IOSPhoneControlCredentials.validatedPairing(pairing)
                if readinessRunID == runID { readinessReport?.stage = .connection }
                if connectionMode == .embedded {
                    owner?.requestedTunnel = true
                    try await localTunnel.start(owner: context.sessionID)
                }
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID, sessionID: context.sessionID)
                let port = await localTunnel.resolveRemotePairingPort()
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID, sessionID: context.sessionID)
                let endpoint = "\(IOSPhoneControlLoopbackRoute.peer):\(port)"
                IOSBackgroundLifecycleLog.record("phoneControlResolvedEndpoint",
                    detail: "source=\(connectionMode.rawValue) port=\(port)")
                let configuration = PhoneControlLaunchConfiguration(pairing: validatedPairing,
                                                                    endpoint: endpoint,
                                                                    connectionMode: connectionMode,
                                                                    allowedBundleIDs: context.scope)
                if readinessRunID == runID { readinessReport?.stage = .runner }
                let status = try await session.start(runID: context.sessionID, configuration: configuration)
                try Task.checkCancellation()
                _ = try activeOwner(runID: runID, sessionID: context.sessionID)
                let client = try await session.runner(runID: context.sessionID)
                return StartedSession(status: status, client: client)
            }
            startTask = startup
        }
        do {
            let started = try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            try Task.checkCancellation()
            _ = try activeOwner(runID: runID, sessionID: context.sessionID)
            runnerClient = started.client
            runnerStatus = started.status
            phase = .ready
            statusMessage = "本次启动已连接，实际可用性以新的界面观察为准；截图由任务单独请求"
            return started.status
        } catch {
            if owner?.sessionID == context.sessionID, owner?.active == true {
                lastFailure = error is CancellationError ? nil : error.localizedDescription
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

    func applicationName(for bundleID: String) -> String {
        applicationNames[bundleID] ?? bundleID
    }

    /// Lists metadata through the same local development route, without launching an app or runner.
    /// Once control has started, reuse its InstallationProxy result instead of opening another tunnel.
    func loadInstalledApplications(runID: String? = nil) async throws -> [PhoneControlInstalledApp] {
        try Task.checkCancellation()
        guard !isPreparingConnection, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        let context: Owner?
        if let runID {
            context = try activeOwner(runID: runID)
            owner?.requestedApplications = true
            if hasApplicationCatalog { return installedApplications }
        } else {
            guard !isOccupied else { throw IOSPhoneControlError.occupied }
            context = nil
        }
        guard !isLoadingApplications else { throw IOSPhoneControlError.occupied }
        let revision = preparationRevision
        let connectionMode = self.connectionMode
        let existingStartup = startTask
        isLoadingApplications = true
        hasApplicationCatalog = false
        let operation = Task { [self] in
            if let context, let existingStartup {
                _ = try await existingStartup.value
                try Task.checkCancellation()
                _ = try activeOwner(runID: context.runID, sessionID: context.sessionID)
                return try await session.cachedApplications(runID: context.sessionID)
            }
            guard let pairing = try await credentials.loadPairing() else {
                throw IOSPhoneControlError.unprepared
            }
            try Task.checkCancellation()
            if let context { _ = try activeOwner(runID: context.runID, sessionID: context.sessionID) }
            let queryID = UUID()
            let applications: [PhoneControlInstalledApp]
            do {
                if connectionMode == .embedded { try await localTunnel.start(owner: queryID) }
                try Task.checkCancellation()
                if let context { _ = try activeOwner(runID: context.runID, sessionID: context.sessionID) }
                _ = await localTunnel.resolveRemotePairingPort()
                try Task.checkCancellation()
                if let context { _ = try activeOwner(runID: context.runID, sessionID: context.sessionID) }
                applications = try await applicationDiscoverer.installedApplications(pairing: pairing, connectionMode: connectionMode)
            } catch {
                // The discoverer has joined its native operation before its result is available.
                let disconnected = connectionMode == .embedded ? await localTunnel.stop(owner: queryID) : true
                if let context, owner?.sessionID == context.sessionID {
                    owner?.cleanupFailure = disconnected ? nil
                        : IOSPhoneControlLocalTunnelError.disconnectionTimedOut.localizedDescription
                }
                if !disconnected {
                    let failure: Error = error is CancellationError
                        ? IOSPhoneControlLocalTunnelError.disconnectionTimedOut : error
                    lastFailure = lastFailure ?? failure.localizedDescription
                    phase = .failed
                    statusMessage = lastFailure ?? failure.localizedDescription
                    throw failure
                }
                throw error
            }
            let disconnected = connectionMode == .embedded ? await localTunnel.stop(owner: queryID) : true
            guard disconnected else {
                let error = IOSPhoneControlLocalTunnelError.disconnectionTimedOut
                if let context, owner?.sessionID == context.sessionID { owner?.cleanupFailure = error.localizedDescription }
                lastFailure = lastFailure ?? error.localizedDescription
                phase = .failed
                statusMessage = lastFailure ?? error.localizedDescription
                throw error
            }
            if let context, owner?.sessionID == context.sessionID { owner?.cleanupFailure = nil }
            try Task.checkCancellation()
            return applications
        }
        applicationsTask = operation
        defer {
            applicationsTask = nil
            isLoadingApplications = false
        }
        let applications = try await withTaskCancellationHandler {
            let result = try await operation.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
        guard !operation.isCancelled, preparationRevision == revision else { throw CancellationError() }
        if let context {
            guard try activeOwner(runID: context.runID).sessionID == context.sessionID else {
                throw IOSPhoneControlError.unauthorized
            }
        } else {
            guard !isOccupied else { throw IOSPhoneControlError.occupied }
        }
        let sorted = applications.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
        if installedApplications != sorted { installedApplications = sorted }
        hasApplicationCatalog = true
        var names = applicationNames
        for app in sorted where selectedBundleIDs.contains(app.bundleID) { names[app.bundleID] = app.name }
        if names != applicationNames { applicationNames = names }
        return sorted
    }

    /// Exact IDs must come from this device's catalog. A model cannot authorize an invented ID.
    @discardableResult
    func addInstalledApplication(bundleID: String, runID: String? = nil) async throws -> PhoneControlInstalledApp {
        if let runID {
            _ = try activeOwner(runID: runID)
        } else {
            guard !isOccupied, !isPreparingConnection, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        }
        guard !isLoadingApplications else { throw IOSPhoneControlError.occupied }
        if !hasApplicationCatalog { _ = try await loadInstalledApplications(runID: runID) }
        try Task.checkCancellation()
        guard Self.validBundleID(bundleID),
              let app = installedApplications.first(where: { $0.bundleID == bundleID }) else {
            throw IOSPhoneControlError.applicationNotFound
        }
        if let runID {
            let context = try activeOwner(runID: runID)
            if let startTask {
                let started = try await startTask.value
                _ = try activeOwner(runID: runID)
                try await started.client.allowApplication(bundleID)
            }
            guard try activeOwner(runID: runID).sessionID == context.sessionID else {
                throw IOSPhoneControlError.unauthorized
            }
            owner?.scope.insert(bundleID)
        } else {
            guard !isOccupied, !isPreparingConnection, !isUpdatingPairing else { throw IOSPhoneControlError.occupied }
        }
        if !selectedBundleIDs.contains(bundleID) { selectedBundleIDs.insert(bundleID) }
        if applicationNames[bundleID] != app.name { applicationNames[bundleID] = app.name }
        return app
    }

    /// A cached status read does not create a test session or touch Keychain/native services.
    func statusText(runID: String) -> String {
        guard enabled else {
            return "enabled=false\navailability=disabled\n手机控制已关闭，请在设置中开启。状态读取不会启动连接。"
        }
        guard let owner, owner.runID == runID, owner.active else {
            if isOccupied {
                return "enabled=true\navailability=occupied\n已有手机控制任务正在运行或关闭，请等原任务结束。"
            }
            return "enabled=true\navailability=no_active_run\n本任务没有有效的手机控制权限；请重新发起任务。状态读取不会启动或恢复连接。"
        }
        let availability: String
        let preparation: String
        if !hasPreparedPairing {
            availability = "unprepared"
            preparation = "尚未保存配对文件，请先在手机控制设置中完成准备。"
        } else if !isConnectionPrepared {
            availability = "connection_unprepared"
            preparation = "请先在手机控制设置中准备本机连接；只需首次允许 iOS 添加 VPN 配置。"
        } else if owner.scope.isEmpty || !owner.scope.allSatisfy(Self.validBundleID) {
            availability = "no_scope"
            preparation = "尚未添加允许控制的 App；可先查询并添加应用，再开始控制。"
        } else {
            availability = "available"
            preparation = "这是本次启动的最后状态；实际可用性以新观察为准。"
        }
        let handoff = [owner.handoffState.statusMessage, owner.handoffFailure].compactMap { $0 }.joined(separator: "\n")
        return "enabled=true\nphase=\(phase.rawValue)\navailability=\(availability)\nhandoff=\(owner.handoffState.rawValue)\n\(handoff)\n\(statusMessage)\n\(preparation)\nscope=\(owner.scope.sorted().joined(separator: ","))"
    }

    /// Revoke synchronously; keep the slot until native runtime join finishes.
    func revoke(runID: String) {
        guard var owner, owner.runID == runID, owner.active else { return }
        owner.active = false
        let resumeWaiter = owner.resumeWaiter
        owner.resumeWaiter = nil
        self.owner = owner
        resumeWaiter?.continuation.resume(throwing: IOSPhoneControlError.unauthorized)
        runnerClient = nil
        runnerStatus = nil
        startTask?.cancel()
        applicationsTask?.cancel()
        phase = .stopping
        statusMessage = "正在关闭本任务的手机控制连接"
        let startup = startTask
        let applicationQuery = applicationsTask
        cleanupTask = Task { [self] in
            await session.stop(runID: owner.sessionID)
            // A cancelled actor hop must finish before this owner can hand its slot to another run.
            _ = await startup?.result
            _ = await applicationQuery?.result
            await session.stop(runID: owner.sessionID)
            let closedStatus = try? await session.launchStatus(runID: owner.sessionID)
            let disconnected = owner.requestedTunnel ? await localTunnel.stop(owner: owner.sessionID) : true
            // The query can record its teardown failure while cleanup awaits its join.
            let pendingQueryFailure = self.owner?.sessionID == owner.sessionID
                ? self.owner?.cleanupFailure : owner.cleanupFailure
            // A later control teardown can prove the same tunnel has recovered and closed.
            let queryCleanupFailure = owner.requestedTunnel && disconnected ? nil : pendingQueryFailure
            let nativeCleanupFailure = closedStatus?.code == "runner_shutdown_failed" ? closedStatus?.message : nil
            let result = IOSPhoneControlStopResult(cleanupFailure: nativeCleanupFailure ?? queryCleanupFailure
                ?? (disconnected ? nil : IOSPhoneControlLocalTunnelError.disconnectionTimedOut.localizedDescription))
            if readinessRunID == owner.runID { readinessCleanupResult = result }
            guard self.owner?.sessionID == owner.sessionID else { return result }
            lastFailure = lastFailure ?? result.cleanupFailure
            self.owner = nil
            ownerRunID = nil
            startTask = nil
            cleanupTask = nil
            phase = lastFailure == nil ? .idle : .failed
            statusMessage = lastFailure ?? "本轮手机控制连接已关闭"
            return result
        }
    }

    @discardableResult
    func stop(runID: String) async -> IOSPhoneControlStopResult? {
        guard owner?.runID == runID else { return nil }
        revoke(runID: runID)
        // Capture this owner's receipt before cleanup releases the slot to the next run.
        let cleanup = cleanupTask
        return await cleanup?.value
    }

    /// The visible stop/disable operation also cancels the matching foreground or handed-off run.
    func stopCurrent() async {
        let runID = owner?.runID
        let applicationQuery = applicationsTask
        applicationQuery?.cancel()
        endCurrentTask()
        if let runID { await stop(runID: runID) }
        _ = await applicationQuery?.result
    }

    private func endCurrentTask() {
        guard let owner, owner.active else { return }
        revoke(runID: owner.runID)
        owner.onStop()
    }

    private func activeOwner(runID: String, sessionID: UUID? = nil) throws -> Owner {
        guard let owner, owner.runID == runID, owner.active,
              sessionID == nil || owner.sessionID == sessionID else { throw IOSPhoneControlError.unauthorized }
        return owner
    }

    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private struct Owner {
        let runID: String
        let sessionID: UUID
        var scope: Set<String>
        var requestedApplications = false
        var requestedTunnel = false
        var cleanupFailure: String?
        let onStop: @MainActor () -> Void
        var active = true
        var handoffState: IOSPhoneControlHandoffState = .automated
        var handoffFailure: String?
        var takeoverGeneration = 0
        var needsFreshObservation = false
        var activeTool: IOSPhoneControlToolLease?
        var resumeWaiter: ResumeWaiter?
        var outcomeUnknown = false
    }
    private struct ResumeWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Int, Error>
    }
    private struct StartedSession: Sendable {
        let status: PhoneRunnerStatus
        let client: PhoneRunnerClient
    }
}
