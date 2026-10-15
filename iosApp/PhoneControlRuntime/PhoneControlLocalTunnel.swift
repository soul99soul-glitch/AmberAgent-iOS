import Foundation
@preconcurrency import NetworkExtension
import Observation

/// Owns only Amber's packet-tunnel configuration. A connected tunnel is transport
/// readiness; pairing and runner readiness remain the controller's responsibility.
@MainActor
@Observable
final class IOSPhoneControlLocalTunnel: IOSPhoneControlLocalTunneling {
    enum State: Equatable {
        case unprepared, ready, connecting, connected, disconnecting
        case failed(String)
    }

    private(set) var state: State = .unprepared
    private(set) var isPrepared = false
    @ObservationIgnored private let driver: any IOSPhoneControlTunnelDriver
    @ObservationIgnored private let connectionTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var lastStartedOwner: UUID?
    @ObservationIgnored private var ownsConnection = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Error>?
    @ObservationIgnored private var stopTask: Task<Bool, Never>?
    @ObservationIgnored private var preparing = false
    @ObservationIgnored nonisolated(unsafe) private var statusObserver: NSObjectProtocol?

    convenience init() {
        self.init(driver: IOSPhoneControlSystemTunnelDriver())
    }

    init(
        driver: any IOSPhoneControlTunnelDriver,
        connectionTimeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.driver = driver
        self.connectionTimeout = connectionTimeout
        self.pollInterval = pollInterval
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed = self.state { return }
                self.updateConnectionState()
            }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    /// Read-only. During a run retain the same connection object and owner.
    func refresh() async {
        guard !preparing else { return }
        if owner != nil {
            updateConnectionState()
            return
        }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task {
            do {
                isPrepared = try await driver.load()
                updateConnectionState()
            } catch {
                setState(.failed(error.localizedDescription))
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Explicit settings action. Saving a new configuration can show iOS's VPN
    /// permission sheet. This does not maintain a connection or enable on-demand.
    func prepare() async throws {
        if let refreshTask { await refreshTask.value }
        try Task.checkCancellation()
        guard owner == nil, !preparing else { throw IOSPhoneControlLocalTunnelError.occupied }
        preparing = true
        defer { preparing = false }
        do {
            try await driver.prepare()
            isPrepared = true
            updateConnectionState()
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Re-enables an existing Amber configuration when another VPN disabled it.
    /// Missing configurations must be prepared explicitly in settings.
    func start(owner requestedOwner: UUID) async throws {
        if let refreshTask { await refreshTask.value }
        try Task.checkCancellation()
        guard owner == nil, !preparing else { throw IOSPhoneControlLocalTunnelError.occupied }
        owner = requestedOwner
        lastStartedOwner = requestedOwner
        let task = Task { try await connect(owner: requestedOwner) }
        startTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard owner == requestedOwner, stopTask == nil else { throw CancellationError() }
            startTask = nil
        } catch {
            _ = await stop(owner: requestedOwner)
            if owner == nil, lastStartedOwner == requestedOwner, !(error is CancellationError) {
                setState(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    /// The caller must close the native session before releasing its tunnel.
    /// The result reports the physical state, even when this owner has nothing
    /// left to stop. A stale owner cannot affect a newer run.
    @discardableResult
    func stop(owner requestedOwner: UUID) async -> Bool {
        guard owner == requestedOwner else { return isDisconnected }
        if let stopTask { return await stopTask.value }
        // Independent of the caller's cancellation so teardown can still wait.
        let task = Task { await disconnect(owner: requestedOwner) }
        stopTask = task
        return await task.value
    }

    private func connect(owner requestedOwner: UUID) async throws {
        do {
            isPrepared = try await driver.load()
        } catch {
            throw connectionError(error, stage: "读取 VPN 配置")
        }
        try checkOwner(requestedOwner)
        guard isPrepared else { throw IOSPhoneControlLocalTunnelError.notPrepared }
        if !driver.isEnabled {
            do {
                try await driver.enableExisting()
            } catch {
                throw connectionError(error, stage: "启用 VPN 配置")
            }
            try checkOwner(requestedOwner)
        }
        switch driver.status {
        case .connected:
            ownsConnection = true
            setState(.connected)
            return
        case .connecting, .reasserting, .disconnecting:
            throw IOSPhoneControlLocalTunnelError.connectionBusy
        default:
            break
        }
        try checkOwner(requestedOwner)
        ownsConnection = true
        do {
            try driver.start()
        } catch {
            throw connectionError(error, stage: "启动 VPN 扩展", status: driver.status)
        }
        setState(.connecting)
        let deadline = ContinuousClock.now.advanced(by: connectionTimeout)
        var sawConnecting = false
        while ContinuousClock.now < deadline {
            try checkOwner(requestedOwner)
            switch driver.status {
            case .connected:
                setState(.connected)
                return
            case .connecting, .reasserting:
                sawConnecting = true
            case .disconnected where sawConnecting:
                // Fetch before cleanup: our stop can replace the provider's cause.
                let cause = await driver.lastDisconnectError()
                try checkOwner(requestedOwner)
                let failure: Error
                if let cause { failure = cause }
                else { failure = IOSPhoneControlLocalTunnelError.connectionFailed }
                throw connectionError(failure,
                    stage: "等待 VPN 连接", status: .disconnected)
            case .disconnecting, .invalid:
                throw connectionError(IOSPhoneControlLocalTunnelError.connectionFailed,
                    stage: "等待 VPN 连接", status: driver.status)
            default:
                break
            }
            try await Task.sleep(for: pollInterval)
        }
        throw connectionError(IOSPhoneControlLocalTunnelError.connectionTimedOut,
            stage: "等待 VPN 连接", status: driver.status)
    }

    private func connectionError(_ error: Error, stage: String, status: NEVPNStatus? = nil) -> Error {
        if error is CancellationError { return error }
        let cause = error as NSError
        var description = "\(stage)失败：\(cause.localizedDescription)"
        if !(error is IOSPhoneControlLocalTunnelError) {
            description += "（domain=\(cause.domain), code=\(cause.code)）"
        }
        if let status {
            let name: String
            switch status {
            case .invalid: name = "invalid"
            case .disconnected: name = "disconnected"
            case .connecting: name = "connecting"
            case .connected: name = "connected"
            case .reasserting: name = "reasserting"
            case .disconnecting: name = "disconnecting"
            @unknown default: name = "unknown(\(status.rawValue))"
            }
            description += "；NEVPNStatus=\(name)"
        }
        return NSError(domain: cause.domain, code: cause.code,
            userInfo: [NSLocalizedDescriptionKey: description, NSUnderlyingErrorKey: cause])
    }

    private func disconnect(owner requestedOwner: UUID) async -> Bool {
        startTask?.cancel()
        _ = await startTask?.result
        guard owner == requestedOwner else { return isDisconnected }
        if ownsConnection {
            driver.stop()
            setState(.disconnecting)
        }
        let deadline = ContinuousClock.now.advanced(by: connectionTimeout)
        while ownsConnection, !isDisconnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        let disconnected = isDisconnected
        let disconnectionTimedOut = ownsConnection && !disconnected
        guard owner == requestedOwner else { return disconnected }
        owner = nil
        ownsConnection = false
        startTask = nil
        stopTask = nil
        if disconnectionTimedOut {
            setState(.failed(IOSPhoneControlLocalTunnelError.disconnectionTimedOut.localizedDescription))
        } else {
            updateConnectionState()
        }
        return disconnected
    }

    private var isDisconnected: Bool { driver.status == .disconnected || driver.status == .invalid }

    private func checkOwner(_ requestedOwner: UUID) throws {
        try Task.checkCancellation()
        guard owner == requestedOwner, stopTask == nil else { throw CancellationError() }
    }

    private func updateConnectionState() {
        guard isPrepared else {
            setState(.unprepared)
            return
        }
        switch driver.status {
        case .connected: setState(.connected)
        case .connecting, .reasserting: setState(.connecting)
        case .disconnecting: setState(.disconnecting)
        default: setState(.ready)
        }
    }

    private func setState(_ value: State) {
        if state != value { state = value }
    }
}

@MainActor
protocol IOSPhoneControlLocalTunneling: AnyObject {
    var state: IOSPhoneControlLocalTunnel.State { get }
    var isPrepared: Bool { get }
    func refresh() async
    func prepare() async throws
    func start(owner: UUID) async throws
    @discardableResult func stop(owner: UUID) async -> Bool
}

enum IOSPhoneControlLocalTunnelError: LocalizedError, Equatable {
    case occupied, notPrepared, duplicateConfiguration
    case connectionBusy, connectionFailed, connectionTimedOut, disconnectionTimedOut

    var errorDescription: String? {
        switch self {
        case .occupied: "本机连接正在被其他操作使用。"
        case .notPrepared: "请先在手机控制设置中准备本机连接，并允许 iOS 添加 VPN 配置。"
        case .duplicateConfiguration: "发现多个 Amber 本机连接配置，请在系统 VPN 设置中保留一个后重试。"
        case .connectionBusy: "本机连接仍在切换状态，请稍后重试。"
        case .connectionFailed: "本机连接启动失败，请检查系统 VPN 状态。"
        case .connectionTimedOut: "未在 10 秒内建立本机连接，请检查系统 VPN 状态。"
        case .disconnectionTimedOut: "本机连接尚未断开，请检查系统 VPN 状态。"
        }
    }
}

/// The small seam keeps ownership and cancellation tests independent of system
/// VPN permissions; the system implementation still owns all preferences I/O.
@MainActor
protocol IOSPhoneControlTunnelDriver: AnyObject {
    var status: NEVPNStatus { get }
    var isEnabled: Bool { get }
    func load() async throws -> Bool
    func prepare() async throws
    func enableExisting() async throws
    func start() throws
    func stop()
    func lastDisconnectError() async -> NSError?
}

@MainActor
private final class IOSPhoneControlSystemTunnelDriver: IOSPhoneControlTunnelDriver {
    private let providerBundleID: String
    private var manager: NETunnelProviderManager?

    init() {
        providerBundleID = (Bundle.main.bundleIdentifier ?? "app.amber.ios") + ".phone-control-tunnel"
    }

    var status: NEVPNStatus { manager?.connection.status ?? .invalid }
    var isEnabled: Bool { manager?.isEnabled == true }

    func load() async throws -> Bool {
        let loaded: LoadedTunnelManagers = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: LoadedTunnelManagers(values: managers ?? [])) }
            }
        }
        let own = loaded.values.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        }
        guard own.count <= 1 else { throw IOSPhoneControlLocalTunnelError.duplicateConfiguration }
        manager = own.first
        return manager != nil
    }

    func prepare() async throws {
        _ = try await load()
        try Task.checkCancellation()
        let configuration = manager ?? NETunnelProviderManager()
        if manager == nil {
            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = providerBundleID
            tunnelProtocol.serverAddress = "Amber Local iPhone"
            configuration.protocolConfiguration = tunnelProtocol
            configuration.localizedDescription = "Amber 本机连接"
        }
        configuration.isEnabled = true
        configuration.isOnDemandEnabled = false
        try await saveAndReload(configuration)
        manager = configuration
    }

    func enableExisting() async throws {
        guard let manager else { throw IOSPhoneControlLocalTunnelError.notPrepared }
        try Task.checkCancellation()
        manager.isEnabled = true
        try await saveAndReload(manager)
    }

    private func saveAndReload(_ configuration: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configuration.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configuration.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func start() throws {
        guard let manager else { throw IOSPhoneControlLocalTunnelError.notPrepared }
        try manager.connection.startVPNTunnel()
    }

    func stop() { manager?.connection.stopVPNTunnel() }

    func lastDisconnectError() async -> NSError? {
        guard let manager else { return nil }
        return await withCheckedContinuation { continuation in
            manager.connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error as NSError?)
            }
        }
    }
}

// Apple documents NETunnelProviderManager instances as thread-safe. Keep the
// callback-to-actor transfer local instead of adding a retroactive conformance.
private struct LoadedTunnelManagers: @unchecked Sendable {
    let values: [NETunnelProviderManager]
}
