import AmberPhoneControl
import CryptoKit
import Foundation
import XCTest
@testable import iosApp

extension IOSPhoneControlControllerTests {
    @MainActor
    func testReadinessStartsOneSessionReadsFreshUIAndClosesWithoutPersistingSelfScope() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let fixture = ReadinessHTTPFixture(bundleID: bundleID)
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture)
        let tunnel = PhoneControlTunnelStub()
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.saved"]
        await controller.refreshPreparation()
        try await controller.checkReadiness()

        let report = try XCTUnwrap(controller.readinessReport)
        XCTAssertNotNil(report.connectionVerifiedAt)
        XCTAssertNotNil(report.uiReadAt)
        XCTAssertEqual(report.observedBundleID, bundleID)
        XCTAssertEqual(report.nodeCount, 1)
        XCTAssertNotNil(report.completedAt)
        XCTAssertTrue(report.cleanupComplete)
        XCTAssertNil(report.failureStage)
        XCTAssertNil(controller.ownerRunID)
        XCTAssertFalse(controller.isCheckingReadiness)
        XCTAssertEqual(controller.selectedBundleIDs, ["app.saved"])
        XCTAssertEqual(defaults.stringArray(forKey: IOSPhoneControlController.selectedBundleIDsPreferenceKey), ["app.saved"])
        let scopes = await session.startedScopes
        XCTAssertEqual(scopes, [["app.saved", bundleID]])
        XCTAssertEqual(tunnel.startOwners.count, 1)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertEqual(fixture.paths, ["/status", "/wda/activeAppInfo", "/source", "/wda/activeAppInfo"])
        XCTAssertTrue(fixture.onlySignedGETRequests, "The check must not launch or interact with an app")
    }

    @MainActor
    func testReadinessMissingPairingFailsConfigurationWithoutConnecting() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: nil), localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        XCTAssertEqual(controller.readinessReport?.failureStage, .configuration)
        XCTAssertNil(controller.readinessReport?.connectionVerifiedAt)
        XCTAssertNil(controller.readinessReport?.uiReadAt)
        XCTAssertNotNil(controller.readinessReport?.completedAt)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertTrue(tunnel.startOwners.isEmpty)
        XCTAssertNil(controller.ownerRunID)
    }

    @MainActor
    func testReadinessTunnelFailureReportsConnectionStageAndCleansOwner() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.startOperation = { _ in throw URLError(.cannotConnectToHost) }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        XCTAssertEqual(controller.readinessReport?.failureStage, .connection)
        XCTAssertNil(controller.readinessReport?.connectionVerifiedAt)
        XCTAssertNil(controller.readinessReport?.uiReadAt)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertNil(controller.ownerRunID)
    }

    @MainActor
    func testReadinessRunnerFailureDoesNotClaimConnectionOrDDIVerified() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture, failStartup: true)
        let tunnel = PhoneControlTunnelStub()
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        XCTAssertEqual(controller.readinessReport?.failureStage, .runner)
        XCTAssertTrue(controller.readinessReport?.failureMessage?.contains("ddi_not_ready") == true)
        XCTAssertNil(controller.readinessReport?.connectionVerifiedAt)
        XCTAssertNil(controller.readinessReport?.uiReadAt)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertTrue(fixture.paths.isEmpty)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
    }

    @MainActor
    func testReadinessObservationFailurePreservesVerifiedConnectionAndCloses() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier), failSource: true)
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture)
        let tunnel = PhoneControlTunnelStub()
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        XCTAssertNotNil(controller.readinessReport?.connectionVerifiedAt)
        XCTAssertNil(controller.readinessReport?.uiReadAt)
        XCTAssertEqual(controller.readinessReport?.failureStage, .observation)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertNil(controller.ownerRunID)
    }

    @MainActor
    func testReadinessSuccessfulObservationRetainsFailedCleanup() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture)
        let tunnel = PhoneControlTunnelStub()
        tunnel.stopOperation = { _ in false }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        XCTAssertNotNil(controller.readinessReport?.uiReadAt)
        XCTAssertEqual(controller.readinessReport?.failureStage, .cleanup)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, false)
        XCTAssertNil(controller.ownerRunID)
    }

    @MainActor
    func testDisableDuringReadinessCancelsAndJoinsBeforeAnotherOwnerCanStart() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture, blockStartup: true)
        let tunnel = PhoneControlTunnelStub()
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        let checking = Task { try await controller.checkReadiness() }
        await session.waitUntilStarted()
        XCTAssertTrue(controller.isCheckingReadiness)
        do { try await controller.checkReadiness(); XCTFail("Another check must not take the owner") }
        catch IOSPhoneControlError.occupied { }
        controller.enabled = false
        XCTAssertEqual(controller.phase, .stopping)
        controller.enabled = true
        XCTAssertFalse(controller.claim(runID: "next", onStop: {}))
        await session.releaseStartup()
        try await checking.value
        XCTAssertEqual(controller.readinessReport?.wasCancelled, true)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertNil(controller.readinessReport?.uiReadAt)
        XCTAssertNil(controller.ownerRunID)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertTrue(controller.claim(runID: "next", onStop: {}))
        await controller.stop(runID: "next")
    }

    @MainActor
    func testSettingsOwnerCancellationStopsOnlyItsReadinessCheck() async throws {
        let suite = "IOSPhoneControlReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture, blockStartup: true)
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: PhoneControlTunnelStub())
        controller.enabled = true
        let checking = Task { try await controller.checkReadiness() }
        await session.waitUntilStarted()
        controller.cancelReadinessCheck()
        await session.releaseStartup()
        try await checking.value
        XCTAssertEqual(controller.readinessReport?.wasCancelled, true)
        XCTAssertEqual(controller.readinessReport?.cleanupComplete, true)
        XCTAssertTrue(controller.claim(runID: "chat", onStop: {}))
        controller.cancelReadinessCheck()
        XCTAssertEqual(controller.ownerRunID, "chat", "An old settings check must not stop a new chat owner")
        await controller.stop(runID: "chat")
    }

}
