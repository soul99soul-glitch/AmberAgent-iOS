import CryptoKit
import ServiceManagement
import XCTest
@preconcurrency import GatewayCore
@preconcurrency import GatewayPush
@testable import AmberMac

/// State-directory side of the embedded gateway. Registration itself (SMAppService) is exercised on the real
/// Mac; here the service is an unregistered placeholder, so status stays `.off` unless pinned.
@MainActor final class DesktopGatewayTests: XCTestCase {
    private final class Service: DesktopGatewayService {
        var status: SMAppService.Status = .notRegistered
        var failRegister = false
        func register() throws {
            if failRegister { throw DesktopRuntimeError.message("register failed") }
            status = .enabled
        }
        func unregister() async throws { status = .notRegistered }
    }

    private var dir: URL!

    private func make(_ service: Service = Service(), binary: String = "A.app/Contents/MacOS/amber-gateway") throws -> (DesktopGateway, GatewayPaths) {
        if dir == nil {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-gateway-tests-\(UUID().uuidString)")
            let captured = dir!
            addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        }
        let paths = GatewayPaths(stateDir: dir.appendingPathComponent("state"))
        try paths.ensureDirectories()
        let gateway = DesktopGateway(paths: paths, installation: GatewayInstallation(home: dir),
            service: service, bundledBinary: dir.appendingPathComponent(binary))
        return (gateway, paths)
    }

    private func hooks(_ installation: GatewayInstallation) throws -> String {
        try String(contentsOf: installation.codexHooks, encoding: .utf8)
    }

    func testEnableMigratesCLIDeploymentLinksAndRegistersThenDisableUndoes() async throws {
        let service = Service()
        let (gateway, _) = try make(service)
        let install = gateway.installation
        try FileManager.default.createDirectory(at: install.cliPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: install.cliPlist)
        gateway.enable()
        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(gateway.isEnabled)
        XCTAssertNil(gateway.message)
        XCTAssertFalse(install.hasCLIDeployment, "the app takes over from the CLI LaunchAgent")
        XCTAssertEqual(install.linkTarget?.path, dir.appendingPathComponent("A.app/Contents/MacOS/amber-gateway").path)
        XCTAssertTrue(try hooks(install).contains("_amber_gateway"))

        await gateway.disable().value
        XCTAssertFalse(gateway.isEnabled)
        XCTAssertNil(install.linkTarget)
        XCTAssertFalse(try hooks(install).contains("_amber_gateway"))
    }

    func testFailedRegistrationRollsBackHooksAndKeepsTheCLIDeployment() throws {
        let service = Service()
        service.failRegister = true
        let (gateway, _) = try make(service)
        let install = gateway.installation
        try FileManager.default.createDirectory(at: install.cliPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: install.cliPlist)
        // A regular file at the link path makes linking fail before anything else is touched.
        try FileManager.default.createDirectory(at: install.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: install.link)
        gateway.enable()
        XCTAssertFalse(gateway.isEnabled)
        XCTAssertNotNil(gateway.message)
        XCTAssertTrue(install.hasCLIDeployment, "a failed enable must not leave the Mac without any daemon")
        try FileManager.default.removeItem(at: install.link)
        gateway.enable()
        XCTAssertFalse(gateway.isEnabled)
        XCTAssertNil(install.linkTarget, "register failed: own link and hooks are rolled back")
        let rolledBack = (try? hooks(install)) ?? ""
        XCTAssertFalse(rolledBack.contains("_amber_gateway"))
    }

    func testDisableLeavesHooksAloneWhenTheCLIOwnsTheLink() async throws {
        let service = Service()
        let (gateway, _) = try make(service)
        gateway.enable()
        let cli = gateway.installation.cliBinary
        try gateway.installation.linkBinary(cli)
        await gateway.disable().value
        XCTAssertEqual(gateway.installation.linkTarget?.path, cli.path)
        XCTAssertTrue(try hooks(gateway.installation).contains("_amber_gateway"))
    }

    func testLaunchReregistersWhenRegisteredButTheDaemonIsNotRunning() async throws {
        final class Counting: DesktopGatewayService {
            var status: SMAppService.Status = .enabled
            var registrations = 0
            func register() throws { registrations += 1; status = .enabled }
            func unregister() async throws { status = .notRegistered }
        }
        let service = Counting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-gateway-rereg-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let gateway = DesktopGateway(paths: GatewayPaths(stateDir: dir.appendingPathComponent("state")), installation: GatewayInstallation(home: dir),
            service: service, bundledBinary: dir.appendingPathComponent("A.app/Contents/MacOS/amber-gateway"))
        for _ in 0..<50 where service.registrations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.registrations, 1, "a rebuilt app re-registers so launchd accepts the new signature")
        XCTAssertTrue(gateway.isEnabled)
    }

    func testLaunchRepointsTheLinkWhenTheAppMoved() throws {
        let service = Service()
        let (first, _) = try make(service)
        first.enable()
        let (moved, _) = try make(service, binary: "B.app/Contents/MacOS/amber-gateway")
        XCTAssertEqual(moved.installation.linkTarget?.path, dir.appendingPathComponent("B.app/Contents/MacOS/amber-gateway").path)
    }

    private func device(_ id: String, _ name: String) -> PairedDevice {
        PairedDevice(id: id, name: name, platform: .ios, tokenHash: id, pairedAt: Date())
    }

    func testUnregisteredServiceIsOffAndPairingNeedsARunningDaemon() throws {
        let (gateway, _) = try make()
        XCTAssertEqual(gateway.status, .off)
        XCTAssertFalse(gateway.isEnabled)
        gateway.startPairing()
        XCTAssertNil(gateway.pairing)
        XCTAssertNotNil(gateway.message)
    }

    func testPairingNoticesTheNewDeviceAndIgnoresExistingOnes() throws {
        let (gateway, paths) = try make()
        try DeviceStore(url: paths.devices).update { $0 = [self.device("old", "iPad")] }
        gateway.refresh()
        gateway.snapshotPairing(.init(url: "amber://gateway/pair?p=x", fingerprint: "fp", addresses: ["a"],
            expiresAt: Date().addingTimeInterval(300), knownDeviceIds: ["old"]))
        gateway.refresh()
        XCTAssertNil(gateway.pairing?.pairedDeviceName, "an already-paired device is not the new one")
        try DeviceStore(url: paths.devices).update { $0.append(self.device("new", "iPhone 17 Pro")) }
        gateway.refresh()
        XCTAssertEqual(gateway.pairing?.pairedDeviceName, "iPhone 17 Pro")
        XCTAssertEqual(gateway.devices.map(\.name), ["iPad", "iPhone 17 Pro"])
    }

    func testExpiredPairingClosesWithAMessage() throws {
        let (gateway, _) = try make()
        gateway.snapshotPairing(.init(url: "u", fingerprint: "fp", addresses: [], expiresAt: Date().addingTimeInterval(-1), knownDeviceIds: []))
        gateway.refresh()
        XCTAssertNil(gateway.pairing)
        XCTAssertEqual(gateway.message, "配对二维码已过期，需要时重新生成。")
    }

    func testCancelPairingBurnsTheTicket() throws {
        let (gateway, paths) = try make()
        try Data("{}".utf8).write(to: paths.pairing)
        gateway.snapshotPairing(.init(url: "u", fingerprint: "fp", addresses: [], expiresAt: Date().addingTimeInterval(60), knownDeviceIds: []))
        gateway.cancelPairing()
        XCTAssertNil(gateway.pairing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairing.path))
    }

    func testRevokeRemovesOnlyThatDeviceAndAudits() throws {
        let (gateway, paths) = try make()
        try DeviceStore(url: paths.devices).update { $0 = [self.device("a", "iPhone"), self.device("b", "iPad")] }
        gateway.refresh()
        gateway.revoke(try XCTUnwrap(gateway.devices.first { $0.id == "a" }))
        XCTAssertEqual(gateway.devices.map(\.id), ["b"])
        let audit = try String(contentsOf: paths.audit, encoding: .utf8)
        XCTAssertTrue(audit.contains("\"action\":\"revoke\""))
    }

    func testCredentialImportValidatesAndReports() throws {
        let (gateway, paths) = try make()
        let bad = paths.stateDir.appendingPathComponent("bad.json")
        try Data("{\"project_id\":\"p\"}".utf8).write(to: bad)
        XCTAssertNotNil(gateway.importServiceAccount(.fcm, file: bad))
        XCTAssertFalse(gateway.credentials.contains(.fcm))

        let key = paths.stateDir.appendingPathComponent("AuthKey.p8")
        try Data(P256.Signing.PrivateKey().pemRepresentation.utf8).write(to: key)
        XCTAssertNil(gateway.importAPNs(key: key, keyId: " KEY123 ", teamId: "TEAM", topic: "app.amber.ios"))
        XCTAssertTrue(gateway.credentials.contains(.apns))
        let stored = try XCTUnwrap(CredentialStore(dir: paths.secretsDir).load(.apns, as: APNsCredentials.self))
        XCTAssertEqual(stored.keyId, "KEY123", "identifiers are trimmed")
        gateway.deleteCredentials(.apns)
        XCTAssertFalse(gateway.credentials.contains(.apns))
    }
}
