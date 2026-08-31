import Foundation
import XCTest
@testable import iosApp

@MainActor
private final class FakeRemoteNotificationRegistrar: IOSRemoteNotificationRegistering {
    private(set) var registerCallCount = 0
    func registerForRemoteNotifications() { registerCallCount += 1 }
}

private actor FakeBackendTransport: IOSBackendTransport {
    private(set) var pushTokens: [Data] = []
    private(set) var verifiedKeyIDs: [String] = []

    func registerPushToken(_ token: Data) async throws {
        pushTokens.append(token)
    }

    func appAttestChallenge() async throws -> Data {
        Data("server-challenge".utf8)
    }

    func verifyAppAttestation(keyID: String, attestation: Data) async throws {
        verifiedKeyIDs.append(keyID)
    }

    func recordedPushTokens() -> [Data] { pushTokens }
    func recordedVerifiedKeyIDs() -> [String] { verifiedKeyIDs }
}

private final class FakeAppAttestService: IOSAppAttesting, @unchecked Sendable {
    var isSupported = true
    private(set) var generateCallCount = 0
    private(set) var hashes: [Data] = []

    func generateKey() async throws -> String {
        generateCallCount += 1
        return "key-1"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        hashes.append(clientDataHash)
        return Data("attestation".utf8)
    }
}

private final class MemoryBackendStateStore: IOSBackendStateStoring {
    var values: [String: String] = [:]
    func value(for key: String) -> String? { values[key] }
    func setValue(_ value: String, for key: String) -> Bool {
        values[key] = value
        return true
    }
}

@MainActor
final class IOSBackendServicesTests: XCTestCase {
    func testAbsentBackendFailsClosedWithoutRegisteringOrAttesting() async {
        let registrar = FakeRemoteNotificationRegistrar()
        let attest = FakeAppAttestService()
        let coordinator = IOSBackendServicesCoordinator(
            configuration: nil,
            transport: nil,
            notificationRegistrar: registrar,
            appAttestService: attest,
            stateStore: MemoryBackendStateStore()
        )

        coordinator.startPushRegistration()
        await coordinator.attestDevice()

        XCTAssertEqual(registrar.registerCallCount, 0)
        XCTAssertEqual(attest.generateCallCount, 0)
        XCTAssertEqual(coordinator.pushState, .unavailable("未配置 HTTPS 后端"))
        XCTAssertEqual(coordinator.appAttestState, .unavailable("未配置 HTTPS 后端"))
    }

    func testConfiguredBackendCompletesPushAndAttestationStateMachines() async throws {
        let configuration = try XCTUnwrap(IOSBackendConfiguration(
            baseURL: URL(string: "https://backend.example.com"),
            clientID: "ios-client"
        ))
        let registrar = FakeRemoteNotificationRegistrar()
        let transport = FakeBackendTransport()
        let attest = FakeAppAttestService()
        let coordinator = IOSBackendServicesCoordinator(
            configuration: configuration,
            transport: transport,
            hasPushEntitlement: true,
            hasAppAttestEntitlement: true,
            notificationRegistrar: registrar,
            appAttestService: attest,
            stateStore: MemoryBackendStateStore()
        )

        coordinator.startPushRegistration()
        XCTAssertEqual(registrar.registerCallCount, 1)
        await coordinator.didRegisterForRemoteNotifications(deviceToken: Data([0x01, 0x02]))
        XCTAssertEqual(coordinator.pushState, .ready("APNs 令牌已安全注册"))
        let pushTokens = await transport.recordedPushTokens()
        XCTAssertEqual(pushTokens, [Data([0x01, 0x02])])

        await coordinator.attestDevice()
        XCTAssertEqual(coordinator.appAttestState, .ready("设备完整性已验证"))
        XCTAssertEqual(attest.generateCallCount, 1)
        let verifiedKeyIDs = await transport.recordedVerifiedKeyIDs()
        XCTAssertEqual(verifiedKeyIDs, ["key-1"])
        XCTAssertEqual(attest.hashes.first?.count, 32)
    }

    func testBackendConfigurationRejectsHTTPAndMissingClientID() {
        XCTAssertNil(IOSBackendConfiguration(
            baseURL: URL(string: "http://backend.example.com"),
            clientID: "client"
        ))
        XCTAssertNil(IOSBackendConfiguration(
            baseURL: URL(string: "https://backend.example.com"),
            clientID: ""
        ))
    }

    func testExperimentalTargetEntitlementMirrorFailsClosed() async throws {
        let info: [String: Any] = [
            "AmberAgentConfiguredEntitlements": [
                "aps-environment",
                "com.apple.developer.devicecheck.appattest-environment"
            ],
            "AmberAgentExperimentalConfiguredEntitlements": []
        ]
        XCTAssertTrue(IOSBackendServicesCoordinator.currentTargetHasEntitlementMirror(
            "aps-environment",
            bundleIdentifier: "app.amber.ios",
            infoDictionary: info
        ))
        XCTAssertFalse(IOSBackendServicesCoordinator.currentTargetHasEntitlementMirror(
            "aps-environment",
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: info
        ))

        let configuration = try XCTUnwrap(IOSBackendConfiguration(
            baseURL: URL(string: "https://backend.example.com"),
            clientID: "ios-client"
        ))
        let registrar = FakeRemoteNotificationRegistrar()
        let attest = FakeAppAttestService()
        let coordinator = IOSBackendServicesCoordinator(
            configuration: configuration,
            transport: FakeBackendTransport(),
            hasPushEntitlement: false,
            hasAppAttestEntitlement: false,
            notificationRegistrar: registrar,
            appAttestService: attest,
            stateStore: MemoryBackendStateStore()
        )

        coordinator.startPushRegistration()
        await coordinator.attestDevice()

        XCTAssertEqual(registrar.registerCallCount, 0)
        XCTAssertEqual(attest.generateCallCount, 0)
        XCTAssertEqual(coordinator.pushState, .unavailable("当前 target 未启用远程推送 entitlement"))
        XCTAssertEqual(coordinator.appAttestState, .unavailable("当前 target 未启用 App Attest entitlement"))
    }
}
