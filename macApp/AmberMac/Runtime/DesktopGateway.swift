import AppKit
import Foundation
import Observation
import ServiceManagement
@preconcurrency import GatewayCore
@preconcurrency import GatewayPush
@preconcurrency import GatewayTransport

/// launchd registration of the bundled daemon; SMAppService in the app, a fake in tests.
@MainActor protocol DesktopGatewayService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: DesktopGatewayService {}

/// The embedded amber-gateway daemon: enable/disable, pairing, devices and push credentials.
/// Reads and writes the same state directory as the CLI; the daemon itself runs under launchd.
@MainActor @Observable final class DesktopGateway {
    static let agentPlistName = "app.amber.macos.gateway.plist"

    enum Status: Equatable {
        case off
        /// Registered, but macOS wants the user to allow it in System Settings › Login Items.
        case needsApproval
        case starting
        case running
        case failed(String)
    }

    struct PairingSession: Equatable {
        var url: String
        var fingerprint: String
        var addresses: [String]
        var expiresAt: Date
        var knownDeviceIds: Set<String>
        var pairedDeviceName: String?
    }

    private(set) var status: Status = .off
    private(set) var devices: [PairedDevice] = []
    private(set) var credentials: Set<CredentialKind> = []
    private(set) var pairing: PairingSession?
    private(set) var message: String?
    private(set) var isTestingPush = false
    var isEnabled: Bool { status != .off }

    @ObservationIgnored let paths: GatewayPaths
    @ObservationIgnored let installation: GatewayInstallation
    @ObservationIgnored private let service: any DesktopGatewayService
    @ObservationIgnored private let bundledBinary: URL
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// UI snapshots pin a status that launchd would otherwise overwrite on refresh.
    @ObservationIgnored private var frozenStatus: Status?

    init(paths: GatewayPaths = .resolve(), installation: GatewayInstallation = GatewayInstallation(),
         service: any DesktopGatewayService = SMAppService.agent(plistName: DesktopGateway.agentPlistName),
         bundledBinary: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/amber-gateway")) {
        self.paths = paths; self.installation = installation; self.service = service; self.bundledBinary = bundledBinary
        refresh()
        guard isEnabled, status != .needsApproval else { return }
        // The app may have moved or been rebuilt since it registered: hooks only know the stable symlink, and
        // launchd keeps the old bundle's registration (it refuses to spawn a re-signed binary, EX_CONFIG).
        if installation.linkTarget?.path != bundledBinary.path { try? installation.linkBinary(bundledBinary) }
        if !paths.daemonRunning { Task { await reregister() } }
    }

    /// launchd pins the code signature it saw at registration and refuses a rebuilt binary (EX_CONFIG) until the
    /// agent is registered again. Unregistering is asynchronous; registering before it finishes changes nothing.
    func reregister() async {
        try? await service.unregister()
        do { try service.register() } catch { message = "后台服务重新注册失败：\(error.localizedDescription)" }
        refresh()
    }

    // MARK: enable / disable

    func enable() {
        message = nil
        do {
            try installation.linkBinary(bundledBinary)
            try installation.installHooks()
            // One daemon per state directory: the app takes over from `amber-gateway install`.
            if installation.hasCLIDeployment { installation.removeCLIDeployment() }
            try service.register()
        } catch {
            if service.status != .enabled && service.status != .requiresApproval { removeOwnHooksAndLink() }
            message = "启用失败：\(error.localizedDescription)"
        }
        refresh()
        if service.status == .requiresApproval {
            message = nil
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @discardableResult
    func disable() -> Task<Void, Never> {
        message = nil
        // Hooks first: the daemon going away is what launchd does asynchronously.
        removeOwnHooksAndLink()
        pairing = nil
        return Task {
            do { try await service.unregister() } catch { message = "停止后台服务失败：\(error.localizedDescription)" }
            refresh()
        }
    }

    /// Hooks and the symlink are shared with a CLI install; leave them alone once the CLI has re-pointed the link.
    private func removeOwnHooksAndLink() {
        guard installation.linkTarget?.path == bundledBinary.path else { return }
        do {
            try installation.removeHooks()
            try installation.removeLink()
        } catch {
            message = "已停止服务，但移除 hooks 失败：\(error)"
        }
    }

    func refresh() {
        if let frozen = frozenStatus { status = frozen } else { refreshServiceStatus() }
        refreshFiles()
    }

    private func refreshServiceStatus() {
        switch service.status {
        case .enabled: status = paths.daemonRunning ? .running : .starting
        case .requiresApproval: status = .needsApproval
        case .notRegistered, .notFound: status = .off
        @unknown default: status = .off
        }
    }

    private func refreshFiles() {
        devices = DeviceStore(url: paths.devices).load().sorted { $0.pairedAt < $1.pairedAt }
        let store = CredentialStore(dir: paths.secretsDir)
        credentials = Set(CredentialKind.allCases.filter(store.exists))
        if var session = pairing {
            if session.pairedDeviceName == nil,
               let fresh = devices.first(where: { !session.knownDeviceIds.contains($0.id) }) {
                session.pairedDeviceName = fresh.name
                pairing = session
            } else if session.pairedDeviceName == nil, Date() >= session.expiresAt {
                pairing = nil
                message = "配对二维码已过期，需要时重新生成。"
            }
        }
    }

    /// Polls while the settings page is visible: daemon start-up and a phone finishing pairing both
    /// happen outside this process.
    func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() { poll?.cancel(); poll = nil }

    // MARK: pairing & devices

    func startPairing() {
        message = nil
        guard status == .running else { message = "后台服务尚未运行，稍等片刻再试。"; return }
        do {
            let issued = try PairingIssuer.issue(paths: paths)
            pairing = PairingSession(url: issued.payload.url, fingerprint: issued.payload.fp, addresses: issued.payload.addrs,
                expiresAt: issued.expiresAt, knownDeviceIds: issued.knownDeviceIds)
        } catch {
            message = "\(error)"
        }
    }

    func cancelPairing() {
        // The ticket is single-use and expires on its own; dropping it early just closes the window.
        try? FileManager.default.removeItem(at: paths.pairing)
        pairing = nil
    }

    func revoke(_ device: PairedDevice) {
        do {
            try DeviceStore(url: paths.devices).update { $0.removeAll { $0.id == device.id } }
            AuditLog(url: paths.audit).record("revoke", ["device": device.id, "name": device.name])
        } catch {
            message = "吊销失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func testPush(_ device: PairedDevice) async {
        guard !isTestingPush else { return }
        isTestingPush = true
        defer { isTestingPush = false }
        let name = GatewayIdentity.loadOrCreate(at: paths.identity).name
        let pushMessage = PushMessage(PushIntent(kind: .test, subject: "test", createdAt: Date()), gatewayName: name)
        let result = await PushDispatcher(store: CredentialStore(dir: paths.secretsDir)).deliver(pushMessage, to: device)
        switch result {
        case .delivered: message = "测试推送已发到 \(device.name)。"
        case .invalidToken(let reason):
            try? DeviceStore(url: paths.devices).update { list in
                if let i = list.firstIndex(where: { $0.id == device.id }) { list[i].pushToken = nil }
            }
            message = "\(device.name) 的推送 token 已失效（\(reason)），请在手机上重新打开 Amber。"
        case .failed(let reason): message = reason
        }
        refresh()
    }

    // MARK: credentials

    func importAPNs(key: URL, keyId: String, teamId: String, topic: String) -> String? {
        importing(.apns) {
            try CredentialImport.apns(keyPEM: try Self.read(key), keyId: keyId.trimmingCharacters(in: .whitespaces),
                teamId: teamId.trimmingCharacters(in: .whitespaces), topic: topic.trimmingCharacters(in: .whitespaces), into: $0)
        }
    }

    func importServiceAccount(_ kind: CredentialKind, file: URL) -> String? {
        importing(kind) { store in
            let data = try Self.read(file)
            if kind == .fcm { try CredentialImport.fcm(serviceAccount: data, into: store) }
            else {
                do { try CredentialImport.huawei(serviceAccount: data, projectId: nil, category: "MARKETING", into: store) }
                catch let error as CredentialError where "\(error)".contains("--project-id") {
                    throw CredentialError.invalid("密钥文件里没有 project_id，请在 AGC 控制台重新下载包含 project_id 的服务账号密钥")
                }
            }
        }
    }

    func deleteCredentials(_ kind: CredentialKind) {
        try? CredentialStore(dir: paths.secretsDir).delete(kind)
        AuditLog(url: paths.audit).record("creds-delete", ["kind": kind.rawValue])
        refresh()
    }

    private func importing(_ kind: CredentialKind, _ body: (CredentialStore) throws -> Void) -> String? {
        do {
            try paths.ensureDirectories()
            try body(CredentialStore(dir: paths.secretsDir))
            AuditLog(url: paths.audit).record("creds-import", ["kind": kind.rawValue])
            refresh()
            return nil
        } catch {
            return "导入失败：\(error)"
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

#if DEBUG || AMBER_MAC_PREVIEW
extension DesktopGateway {
    /// UI snapshots only: fix a state without touching launchd.
    func snapshotStatus(_ value: Status) { frozenStatus = value; status = value }
    func snapshotPairing(_ value: PairingSession) { pairing = value }
}
#endif

extension CredentialKind: @retroactive Identifiable {
    public var id: String { rawValue }
}
