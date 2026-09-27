import Foundation
import Observation
import UIKit

/// Owns the Mac Gateway pairing: persistence, APNs token upload and the status shown in Settings.
@MainActor
@Observable
final class MacGatewayStore {
    static let shared = MacGatewayStore()

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private static let connectionKey = "macGateway.connection.v1"
    private static let tokenKey = "macGateway.deviceToken"

    /// Debug builds are signed with `aps-environment = development` (project.yml), Release with production.
    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private(set) var connection: MacGatewayConnection?
    private(set) var status: MacGatewayStatus?
    /// nil until the first refresh after launch or pairing.
    private(set) var isReachable: Bool?
    private(set) var isBusy = false
    private(set) var isSendingTestPush = false
    private(set) var pushError: String?
    var pendingPairing: MacGatewayPairingPayload?
    var notice: Notice?

    @ObservationIgnored private var client: MacGatewayClient?
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(MacGatewayConnection.self, from: data),
           let token = IOSCredentialSideTable.load(key: Self.tokenKey) {
            connection = saved
            client = MacGatewayClient(addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: token)
        }
    }

    // MARK: - App lifecycle

    /// Apple recommends re-registering on every launch; the token can change after restores and updates.
    func applicationDidFinishLaunching() {
        guard connection != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = hex
        guard connection != nil else { return }
        Task { await uploadPushToken(hex) }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        guard connection != nil else { return }
        pushError = error.localizedDescription
    }

    // MARK: - Pairing

    /// Deep link entry (system camera scan or AirDrop). Pairing still needs an explicit confirmation.
    func receivePairingLink(_ link: String) {
        guard let payload = MacGatewayPairingPayload.parse(link) else {
            notice = Notice(text: localized("配对链接无效，请在 Mac 上重新运行 amber-gateway pair"), isError: true)
            return
        }
        pendingPairing = payload
        notice = nil
    }

    func pasteLinkFromClipboard() {
        receivePairingLink(UIPasteboard.general.string ?? "")
    }

    func confirmPairing() async {
        guard let payload = pendingPairing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let pairingClient = MacGatewayClient(addrs: payload.addrs, port: payload.port, fingerprint: payload.fp, token: nil)
        do {
            let response = try await pairingClient.pair(secret: payload.s, deviceName: UIDevice.current.name)
            guard IOSCredentialSideTable.store(key: Self.tokenKey, value: response.token) else {
                notice = Notice(text: localized("无法把配对凭据写入钥匙串"), isError: true)
                return
            }
            let saved = MacGatewayConnection(gatewayId: response.gatewayId, name: response.gatewayName, addrs: payload.addrs,
                                             port: payload.port, fingerprint: payload.fp, deviceId: response.deviceId)
            defaults.set(try? JSONEncoder().encode(saved), forKey: Self.connectionKey)
            connection = saved
            client = MacGatewayClient(addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: response.token)
            pendingPairing = nil
            notice = nil
            await enablePush()
            await refresh()
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    func unpair() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Best effort: if the Mac is unreachable the device stays listed there until `devices revoke`.
        // 401 means the Mac already dropped this device, which is the outcome we wanted.
        var reachedMac = true
        do {
            try await client?.unpair()
        } catch MacGatewayError.unauthorized {
        } catch {
            reachedMac = false
        }
        forget()
        notice = reachedMac ? nil : Notice(text: localized("已在本机取消配对。Mac 当前不可达，可在 Mac 上运行 amber-gateway devices revoke 移除此设备"), isError: false)
    }

    // MARK: - Status & control

    func refresh() async {
        guard let client else { return }
        do {
            let latest = try await client.status()
            status = latest
            isReachable = true
            if latest.device.pushRegistered {
                pushError = nil
            } else if let apnsToken {
                // The Mac lost the token (or an earlier upload failed while it was offline): report it again.
                await uploadPushToken(apnsToken)
            }
        } catch is CancellationError {
        } catch {
            if !forgetIfRevoked(error) { isReachable = false }
        }
    }

    func setMonitored(_ session: MacGatewayStatus.Session, _ monitored: Bool) async {
        guard let client, let index = status?.sessions.firstIndex(where: { $0.key == session.key }) else { return }
        status?.sessions[index].monitored = monitored
        do {
            try await client.setMonitored(taskKey: session.key, monitored: monitored)
        } catch {
            if let i = status?.sessions.firstIndex(where: { $0.key == session.key }) { status?.sessions[i].monitored = !monitored }
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
    }

    func sendTestPush() async {
        guard let client, !isSendingTestPush else { return }
        isSendingTestPush = true
        defer { isSendingTestPush = false }
        do {
            try await client.testPush()
            notice = Notice(text: localized("测试推送已发出，锁屏后留意通知"), isError: false)
        } catch {
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
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
            pushError = nil
            if status?.device.pushRegistered == false { status?.device.pushRegistered = true }
        } catch is CancellationError {
        } catch {
            if !forgetIfRevoked(error) { pushError = error.localizedDescription }
        }
    }

    /// 401 means the Mac revoked this device: drop the pairing everywhere, with the same explanation.
    private func forgetIfRevoked(_ error: Error) -> Bool {
        guard case MacGatewayError.unauthorized = error else { return false }
        forget()
        notice = Notice(text: MacGatewayError.unauthorized.localizedDescription, isError: true)
        return true
    }

    private func forget() {
        IOSCredentialSideTable.delete(key: Self.tokenKey)
        defaults.removeObject(forKey: Self.connectionKey)
        connection = nil
        client = nil
        status = nil
        isReachable = nil
        pushError = nil
    }

    private func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }
}
