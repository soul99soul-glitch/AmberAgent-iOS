import CryptoKit
@preconcurrency import DeviceCheck
import Foundation
import Observation
import UIKit

struct IOSBackendConfiguration: Equatable, Sendable {
    let baseURL: URL
    let clientID: String

    init?(baseURL: URL?, clientID: String?) {
        guard let baseURL,
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientID.isEmpty else { return nil }
        self.baseURL = baseURL
        self.clientID = clientID
    }

    static func current(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Self? {
        let base = (infoDictionary?["AmberBackendBaseURL"] as? String).flatMap(URL.init(string:))
        return Self(baseURL: base, clientID: infoDictionary?["AmberBackendClientID"] as? String)
    }
}

enum IOSBackendServiceState: Equatable {
    case unavailable(String)
    case idle
    case working(String)
    case ready(String)
    case failed(String)
}

protocol IOSBackendTransport: Sendable {
    func registerPushToken(_ token: Data) async throws
    func appAttestChallenge() async throws -> Data
    func verifyAppAttestation(keyID: String, attestation: Data) async throws
}

struct IOSURLSessionBackendTransport: IOSBackendTransport {
    let configuration: IOSBackendConfiguration
    let session: URLSession

    init(configuration: IOSBackendConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func registerPushToken(_ token: Data) async throws {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        _ = try await request(
            path: "v1/apple/push/register",
            body: ["device_token": tokenHex]
        )
    }

    func appAttestChallenge() async throws -> Data {
        let data = try await request(path: "v1/apple/app-attest/challenge", body: [:])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = object?["challenge"] as? String,
              let challenge = Data(base64Encoded: value),
              !challenge.isEmpty else {
            throw IOSBackendServicesError.invalidResponse
        }
        return challenge
    }

    func verifyAppAttestation(keyID: String, attestation: Data) async throws {
        _ = try await request(
            path: "v1/apple/app-attest/verify",
            body: [
                "key_id": keyID,
                "attestation": attestation.base64EncodedString()
            ]
        )
    }

    private func request(path: String, body: [String: String]) async throws -> Data {
        let url = configuration.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.clientID, forHTTPHeaderField: "X-Amber-Client-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw IOSBackendServicesError.requestFailed
        }
        return data
    }
}

@MainActor
protocol IOSRemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

@MainActor
final class IOSSystemRemoteNotificationRegistrar: IOSRemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

protocol IOSAppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
}

struct IOSSystemAppAttestService: IOSAppAttesting, @unchecked Sendable {
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let keyID {
                    continuation.resume(returning: keyID)
                } else {
                    continuation.resume(throwing: error ?? IOSBackendServicesError.invalidResponse)
                }
            }
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? IOSBackendServicesError.invalidResponse)
                }
            }
        }
    }
}

enum IOSBackendServicesError: LocalizedError, Equatable {
    case notConfigured
    case invalidResponse
    case requestFailed
    case appAttestUnsupported

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "未配置 HTTPS 后端。"
        case .invalidResponse:
            "后端响应格式无效。"
        case .requestFailed:
            "后端请求失败。"
        case .appAttestUnsupported:
            "此设备不支持 App Attest。"
        }
    }
}

protocol IOSBackendStateStoring: AnyObject {
    func value(for key: String) -> String?
    func setValue(_ value: String, for key: String) -> Bool
}

final class IOSKeychainBackendStateStore: IOSBackendStateStoring {
    func value(for key: String) -> String? {
        IOSCredentialSideTable.load(key: key)
    }

    func setValue(_ value: String, for key: String) -> Bool {
        IOSCredentialSideTable.store(key: key, value: value)
    }
}

@MainActor
@Observable
final class IOSBackendServicesCoordinator {
    static let shared = IOSBackendServicesCoordinator()

    private(set) var pushState: IOSBackendServiceState
    private(set) var appAttestState: IOSBackendServiceState

    @ObservationIgnored private let configuration: IOSBackendConfiguration?
    @ObservationIgnored private let transport: (any IOSBackendTransport)?
    @ObservationIgnored private let hasPushEntitlement: Bool
    @ObservationIgnored private let hasAppAttestEntitlement: Bool
    @ObservationIgnored private let notificationRegistrar: any IOSRemoteNotificationRegistering
    @ObservationIgnored private let appAttestService: any IOSAppAttesting
    @ObservationIgnored private let stateStore: any IOSBackendStateStoring

    private static let appAttestKeyIDStoreKey = "backend.app-attest.key-id"
    private static let appAttestVerifiedStoreKey = "backend.app-attest.verified"

    init(
        configuration: IOSBackendConfiguration? = .current(),
        transport: (any IOSBackendTransport)? = nil,
        hasPushEntitlement: Bool? = nil,
        hasAppAttestEntitlement: Bool? = nil,
        notificationRegistrar: any IOSRemoteNotificationRegistering = IOSSystemRemoteNotificationRegistrar(),
        appAttestService: any IOSAppAttesting = IOSSystemAppAttestService(),
        stateStore: any IOSBackendStateStoring = IOSKeychainBackendStateStore()
    ) {
        self.configuration = configuration
        let resolvedTransport = transport ?? configuration.map {
            IOSURLSessionBackendTransport(configuration: $0)
        }
        self.transport = resolvedTransport
        let pushEntitlement = hasPushEntitlement ?? Self.currentTargetHasEntitlementMirror("aps-environment")
        let appAttestEntitlement = hasAppAttestEntitlement
            ?? Self.currentTargetHasEntitlementMirror("com.apple.developer.devicecheck.appattest-environment")
        self.hasPushEntitlement = pushEntitlement
        self.hasAppAttestEntitlement = appAttestEntitlement
        self.notificationRegistrar = notificationRegistrar
        self.appAttestService = appAttestService
        self.stateStore = stateStore
        let backendUnavailable = IOSBackendServiceState.unavailable("未配置 HTTPS 后端")
        let backendConfigured = configuration != nil && resolvedTransport != nil
        if !backendConfigured {
            self.pushState = backendUnavailable
        } else if !pushEntitlement {
            self.pushState = .unavailable("当前 target 未启用远程推送 entitlement")
        } else {
            self.pushState = .idle
        }
        if !backendConfigured {
            self.appAttestState = backendUnavailable
        } else if !appAttestEntitlement {
            self.appAttestState = .unavailable("当前 target 未启用 App Attest entitlement")
        } else if stateStore.value(for: Self.appAttestVerifiedStoreKey) == "true" {
            self.appAttestState = .ready("设备完整性已验证")
        } else {
            self.appAttestState = .idle
        }
    }

    var isConfigured: Bool { configuration != nil && transport != nil }
    var configuredHost: String? { configuration?.baseURL.host }
    var canRegisterPush: Bool { isConfigured && hasPushEntitlement }
    var canAttestDevice: Bool { isConfigured && hasAppAttestEntitlement }

    func startPushRegistration() {
        guard canRegisterPush else {
            pushState = .unavailable(
                isConfigured ? "当前 target 未启用远程推送 entitlement" : "未配置 HTTPS 后端"
            )
            return
        }
        pushState = .working("等待 APNs 返回设备令牌")
        notificationRegistrar.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        guard canRegisterPush, case .working = pushState, let transport else { return }
        do {
            try await transport.registerPushToken(deviceToken)
            pushState = .ready("APNs 令牌已安全注册")
        } catch {
            pushState = .failed(error.localizedDescription)
        }
    }

    func didFailRemoteNotificationRegistration(_ error: Error) {
        guard canRegisterPush else { return }
        pushState = .failed(error.localizedDescription)
    }

    func attestDevice() async {
        guard canAttestDevice, let transport else {
            appAttestState = .unavailable(
                isConfigured ? "当前 target 未启用 App Attest entitlement" : "未配置 HTTPS 后端"
            )
            return
        }
        guard appAttestService.isSupported else {
            appAttestState = .failed(IOSBackendServicesError.appAttestUnsupported.localizedDescription)
            return
        }
        if stateStore.value(for: Self.appAttestVerifiedStoreKey) == "true" {
            appAttestState = .ready("设备完整性已验证")
            return
        }

        appAttestState = .working("正在验证设备完整性")
        do {
            let challenge = try await transport.appAttestChallenge()
            let keyID = try await appAttestService.generateKey()
            let hash = Data(SHA256.hash(data: challenge))
            let attestation = try await appAttestService.attestKey(keyID, clientDataHash: hash)
            try await transport.verifyAppAttestation(keyID: keyID, attestation: attestation)
            guard stateStore.setValue(keyID, for: Self.appAttestKeyIDStoreKey),
                  stateStore.setValue("true", for: Self.appAttestVerifiedStoreKey) else {
                throw IOSBackendServicesError.requestFailed
            }
            appAttestState = .ready("设备完整性已验证")
        } catch {
            appAttestState = .failed(error.localizedDescription)
        }
    }

    static func currentTargetHasEntitlementMirror(
        _ entitlement: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        let key = bundleIdentifier?.hasSuffix(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let configured = infoDictionary?[key] as? [String] ?? []
        return configured.contains(entitlement)
    }
}
