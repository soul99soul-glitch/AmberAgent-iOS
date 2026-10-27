import AmberPhoneControl
import CryptoKit
import Foundation
import XCTest
@testable import iosApp

final class IOSPhoneControlControllerTests: XCTestCase {
    func testLaunchDiagnosticDecodesTransportStageAndOlderStatus() throws {
        let data = Data(#"{"phase":"failed","code":"pairing_handshake_failed","message":"握手失败","native_error_code":1,"native_error_subcode":0,"native_io_kind":"UnexpectedEof","native_transport_stage":"read_magic","pair_verify_error":{"native_error_code":1,"native_error_subcode":0,"native_transport_stage":"read_body"}}"#.utf8)
        let status = try JSONDecoder().decode(PhoneControlLaunchStatus.self, from: data)
        XCTAssertTrue(status.diagnosticSummary.contains("transport=read_magic"))
        XCTAssertTrue(status.diagnosticSummary.contains("io=UnexpectedEof"))
        XCTAssertTrue(status.diagnosticSummary.contains("pair_verify=native=1, subcode=0, transport=read_body"))
        let oldData = Data(#"{"phase":"failed","message":"旧状态","native_error_code":1}"#.utf8)
        let old = try JSONDecoder().decode(PhoneControlLaunchStatus.self, from: oldData)
        XCTAssertNil(old.native_transport_stage)
        XCTAssertEqual(old.diagnosticSummary, "native=1")
    }

    func testNativeStartupFailureRemainsTypedAfterSessionCleanup() async throws {
        let session = PhoneControlSession()
        let runID = UUID()
        // Invalid material must fail before a connection is attempted.
        let configuration = PhoneControlLaunchConfiguration(
            pairing: Data([0]), allowedBundleIDs: ["app.amber.ios"]
        )
        do {
            _ = try await session.start(runID: runID, configuration: configuration)
            XCTFail("Invalid pairing must fail startup")
        } catch PhoneControlSessionError.nativeLaunch(let failure) {
            XCTAssertEqual(failure.phase, "failed")
            XCTAssertEqual(failure.code, "invalid_pairing")
            let closed = try await session.launchStatus(runID: runID)
            XCTAssertEqual(closed?.phase, "stopped")
            let unrelatedRunID = UUID()
            await session.stop(runID: unrelatedRunID)
            let unrelated = try await session.launchStatus(runID: unrelatedRunID)
            XCTAssertNil(unrelated, "A task which never started must not inherit another run's cleanup status")
        }
    }

    func testPairingRejectsLockdownAndMismatchedKeysBeforeStorage() throws {
        let lockdown = try PropertyListSerialization.data(fromPropertyList: ["HostID": "host"], format: .xml, options: 0)
        XCTAssertThrowsError(try IOSPhoneControlCredentials.validatedPairing(lockdown))
        var wrong = try pairingDictionary()
        wrong["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let mismatched = try PropertyListSerialization.data(fromPropertyList: wrong, format: .xml, options: 0)
        XCTAssertThrowsError(try IOSPhoneControlCredentials.validatedPairing(mismatched))
        var valid = try pairingDictionary()
        valid["unrelated_secret"] = "not persisted"
        let input = try PropertyListSerialization.data(fromPropertyList: valid, format: .binary, options: 0)
        let output = try IOSPhoneControlCredentials.validatedPairing(input)
        let canonical = try XCTUnwrap(PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
        XCTAssertEqual(Set(canonical.keys), ["public_key", "private_key", "identifier"])
    }

    @MainActor
    func testEnabledSwitchAllowsConsecutiveRunsWithoutReauthorization() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: try pairingData()), localTunnel: PhoneControlTunnelStub())
        controller.selectedBundleIDs = ["app.example.first"]
        XCTAssertFalse(controller.claim(runID: "run-a", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "run-a").contains("availability=disabled"))

        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "run-a", onStop: {}))
        XCTAssertFalse(controller.claim(runID: "run-b", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "run-b").contains("availability=occupied"))
        XCTAssertFalse(controller.hasRequestedSession(runID: "run-a"), "Claiming tools must not start a native session")
        await controller.stop(runID: "run-a")
        XCTAssertTrue(controller.enabled)
        XCTAssertTrue(controller.claim(runID: "run-b", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "run-b").contains("scope=app.example.first"))
        await controller.stop(runID: "run-b")
        XCTAssertTrue(controller.enabled)
    }

    @MainActor
    func testScopeIsFrozenUntilNextRunAndStaleRevocationCannotStopIt() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: try pairingData()), localTunnel: PhoneControlTunnelStub())
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.first"]
        XCTAssertTrue(controller.claim(runID: "run-a", onStop: {}))
        controller.selectedBundleIDs = ["app.example.second"]
        XCTAssertTrue(controller.statusText(runID: "run-a").contains("scope=app.example.first"))
        controller.revoke(runID: "run-a")
        XCTAssertFalse(controller.claim(runID: "run-b", onStop: {}), "The slot remains occupied until cleanup joins")
        await controller.stop(runID: "run-a")

        XCTAssertTrue(controller.claim(runID: "run-b", onStop: {}))
        controller.revoke(runID: "run-a")
        await controller.stop(runID: "run-a")
        XCTAssertEqual(controller.ownerRunID, "run-b")
        XCTAssertEqual(controller.phase, .authorized)
        XCTAssertTrue(controller.statusText(runID: "run-b").contains("scope=app.example.second"))
        await controller.stop(runID: "run-b")
    }

    @MainActor
    func testMissingPreparationOrScopeKeepsStatusAvailableButCannotStartControl() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: nil)
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials, localTunnel: PhoneControlTunnelStub())
        await controller.refreshPreparation()
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "run-empty", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "run-empty").contains("availability=unprepared"))
        do {
            _ = try await controller.start(runID: "run-empty")
            XCTFail("An empty scope must fail before starting native control")
        } catch IOSPhoneControlError.invalidScope { }
        XCTAssertFalse(controller.hasRequestedSession(runID: "run-empty"))
        await controller.stop(runID: "run-empty")

        try await credentials.savePairing(pairingData())
        await controller.refreshPreparation()
        XCTAssertTrue(controller.claim(runID: "run-prepared", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "run-prepared").contains("availability=no_scope"))
        await controller.stop(runID: "run-prepared")
        controller.selectedBundleIDs = ["invalid bundle id"]
        XCTAssertTrue(controller.claim(runID: "run-invalid", onStop: {}))
        do {
            _ = try await controller.start(runID: "run-invalid")
            XCTFail("An invalid scope must fail before starting native control")
        } catch IOSPhoneControlError.invalidScope { }
        XCTAssertFalse(controller.hasRequestedSession(runID: "run-invalid"))
        await controller.stop(runID: "run-invalid")
    }

    @MainActor
    func testSwitchAndScopePersistButOwnerDoesNotRestoreAndDisableRevokesSynchronously() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let first = IOSPhoneControlController(defaults: defaults, credentials: credentials, localTunnel: PhoneControlTunnelStub())
        first.enabled = true
        first.selectedBundleIDs = ["app.example.target"]
        var cancelled = 0
        XCTAssertTrue(first.claim(runID: "run-a", onStop: { cancelled += 1 }))
        let restored = IOSPhoneControlController(defaults: defaults, credentials: credentials, localTunnel: PhoneControlTunnelStub())
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.selectedBundleIDs, ["app.example.target"])
        XCTAssertNil(restored.ownerRunID)
        XCTAssertThrowsError(try restored.runner(runID: "run-a"))
        XCTAssertTrue(restored.statusText(runID: "run-a").contains("availability=no_active_run"))

        first.enabled = false
        XCTAssertEqual(first.phase, .stopping)
        XCTAssertEqual(cancelled, 1)
        XCTAssertThrowsError(try first.runner(runID: "run-a"))
        XCTAssertFalse(first.claim(runID: "run-b", onStop: {}))
        await first.stop(runID: "run-a")
        XCTAssertNil(first.ownerRunID)
        XCTAssertFalse(defaults.bool(forKey: IOSPhoneControlController.enabledPreferenceKey))
        first.enabled = true
        XCTAssertTrue(first.claim(runID: "run-b", onStop: { cancelled += 1 }))
        await first.stopCurrent()
        XCTAssertEqual(cancelled, 2)
        XCTAssertTrue(first.enabled, "Stopping one task must not disable future user-started tasks")
        XCTAssertNil(first.ownerRunID)
    }

    @MainActor
    func testApplicationDiscoveryAddsExactIDToCurrentRunAndPersistsNameWithoutRunner() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = [PhoneControlInstalledApp(bundleID: "com.example.office", name: "Office", isSystem: false)]
        let discovery = ControllerApplicationDiscovery(apps)
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials, applications: discovery, localTunnel: PhoneControlTunnelStub())
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "apps-run", onStop: {}))
        let catalog = try await controller.loadInstalledApplications(runID: "apps-run")
        XCTAssertEqual(catalog, apps)
        let cached = try await controller.loadInstalledApplications(runID: "apps-run")
        XCTAssertEqual(cached, apps)
        XCTAssertEqual(controller.phase, .authorized, "Listing metadata must not start XCTest")
        XCTAssertTrue(controller.hasRequestedSession(runID: "apps-run"))
        let added = try await controller.addInstalledApplication(bundleID: "com.example.office", runID: "apps-run")
        XCTAssertEqual(added, apps[0])
        XCTAssertEqual(controller.selectedBundleIDs, ["com.example.office"])
        XCTAssertEqual(controller.applicationName(for: "com.example.office"), "Office")
        XCTAssertTrue(controller.statusText(runID: "apps-run").contains("scope=com.example.office"))
        let calls = await discovery.callCount
        XCTAssertEqual(calls, 1, "Adding an ID from the current catalog must not open another tunnel")
        let restored = IOSPhoneControlController(defaults: defaults, credentials: credentials, applications: discovery, localTunnel: PhoneControlTunnelStub())
        XCTAssertEqual(restored.selectedBundleIDs, ["com.example.office"])
        XCTAssertEqual(restored.applicationName(for: "com.example.office"), "Office")
        XCTAssertNil(restored.ownerRunID)
        await controller.stop(runID: "apps-run")
        controller.selectedBundleIDs = []
        XCTAssertTrue(controller.applicationNames.isEmpty, "Removed apps must not leave persisted name entries")
    }

    @MainActor
    func testDiscoveryFailureIsNotEmptySuccessAndInvalidIDCannotExtendScope() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = ControllerApplicationDiscovery([PhoneControlInstalledApp(bundleID: "app.known", name: "Known")])
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: PhoneControlTunnelStub())
        _ = try await controller.loadInstalledApplications()
        do {
            _ = try await controller.addInstalledApplication(bundleID: "app.invented")
            XCTFail("An invented ID must not be persisted")
        } catch IOSPhoneControlError.applicationNotFound { }
        XCTAssertTrue(controller.selectedBundleIDs.isEmpty)
        await discovery.failQueries()
        do {
            _ = try await controller.loadInstalledApplications()
            XCTFail("A failed catalog query must propagate its error")
        } catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        XCTAssertFalse(controller.isLoadingApplications)
        do {
            _ = try await controller.addInstalledApplication(bundleID: "app.known")
            XCTFail("A failed refresh must invalidate old catalog data for additions")
        } catch is URLError { }
        XCTAssertTrue(controller.selectedBundleIDs.isEmpty)
    }

    @MainActor
    func testDisableDuringAppQueryJoinsBeforeReleasingRunAndDropsLateCatalog() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = ControllerApplicationDiscovery([PhoneControlInstalledApp(bundleID: "app.late", name: "Late")], blockFirst: true)
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: PhoneControlTunnelStub())
        controller.enabled = true
        var stopped = false
        XCTAssertTrue(controller.claim(runID: "old-run", onStop: { stopped = true }))
        let query = Task { try await controller.loadInstalledApplications(runID: "old-run") }
        await discovery.waitUntilStarted()
        XCTAssertTrue(controller.isLoadingApplications)
        XCTAssertTrue(controller.hasRequestedSession(runID: "old-run"))
        controller.enabled = false
        XCTAssertTrue(stopped)
        controller.enabled = true
        XCTAssertFalse(controller.claim(runID: "new-run", onStop: {}), "Native query must join before the next run may start")
        await discovery.release()
        do { _ = try await query.value; XCTFail("A late catalog must be discarded after disable") }
        catch is CancellationError { }
        await controller.stop(runID: "old-run")
        XCTAssertTrue(controller.installedApplications.isEmpty)
        XCTAssertTrue(controller.selectedBundleIDs.isEmpty)
        XCTAssertTrue(controller.claim(runID: "new-run", onStop: {}))
        do {
            _ = try await controller.addInstalledApplication(bundleID: "app.late", runID: "old-run")
            XCTFail("A stale caller must not extend the new owner's scope")
        } catch IOSPhoneControlError.unauthorized { }
        XCTAssertTrue(controller.selectedBundleIDs.isEmpty)
        await controller.stop(runID: "new-run")
    }

    @MainActor
    func testSettingsQueryCancellationBlocksConcurrentRunUntilJoin() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = ControllerApplicationDiscovery([], blockFirst: true)
        let controller = IOSPhoneControlController(defaults: defaults, credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: PhoneControlTunnelStub())
        controller.enabled = true
        let query = Task { try await controller.loadInstalledApplications() }
        await discovery.waitUntilStarted()
        XCTAssertFalse(controller.claim(runID: "run", onStop: {}))
        query.cancel()
        await discovery.release()
        do { _ = try await query.value; XCTFail("Cancelled settings query must not publish") }
        catch is CancellationError { }
        XCTAssertFalse(controller.isLoadingApplications)
        XCTAssertTrue(controller.claim(runID: "run", onStop: {}))
        await controller.stop(runID: "run")
    }

    @MainActor
    func testUSBImportSavesBeforeDeletingStagingAndInvalidInputPreservesBoth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("import.plist")
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryPairingStore(data: nil)
        let controller = IOSPhoneControlController(defaults: defaults, credentials: store, localTunnel: PhoneControlTunnelStub())
        let valid = try pairingData()
        try valid.write(to: url)
        try await controller.importUSBPreparedPairing(from: url)
        XCTAssertTrue(controller.hasPreparedPairing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let stored = await store.loadPairing()
        let saved = try XCTUnwrap(stored)
        let invalid = Data("not a pairing".utf8)
        try invalid.write(to: url)
        do {
            try await controller.importUSBPreparedPairing(from: url)
            XCTFail("Invalid material must not be imported")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        let stillSaved = await store.loadPairing()
        XCTAssertEqual(stillSaved, saved)
        let link = directory.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try IOSPhoneControlCredentials.readUSBPairingFile(link))
        XCTAssertThrowsError(try IOSPhoneControlCredentials.readUSBPairingFile(directory))
        try Data(repeating: 0, count: 1_048_577).write(to: url)
        XCTAssertThrowsError(try IOSPhoneControlCredentials.readPairingFile(url))
    }

    @MainActor
    func testUSBImportRetainsStagingWhenSaveFailsOrMaterialChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("import.plist")
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = try pairingData()
        try valid.write(to: url)
        let failingStore = MemoryPairingStore(data: nil, onSave: {
            throw IOSPhoneControlCredentialError.keychain(-1)
        })
        let failing = IOSPhoneControlController(defaults: defaults, credentials: failingStore, localTunnel: PhoneControlTunnelStub())
        do {
            try await failing.importUSBPreparedPairing(from: url)
            XCTFail("Failed storage must retain staging")
        } catch IOSPhoneControlCredentialError.keychain { }
        XCTAssertEqual(try Data(contentsOf: url), valid)
        let failedSave = await failingStore.loadPairing()
        XCTAssertNil(failedSave)
        XCTAssertFalse(failing.isUpdatingPairing)

        let replacement = Data("replacement owned by another transfer".utf8)
        let changedStore = MemoryPairingStore(data: nil, onSave: {
            try replacement.write(to: url)
        })
        let changed = IOSPhoneControlController(defaults: defaults, credentials: changedStore, localTunnel: PhoneControlTunnelStub())
        do {
            try await changed.importUSBPreparedPairing(from: url)
            XCTFail("Changed staging must not be removed")
        } catch IOSPhoneControlCredentialError.usbMaterialChanged { }
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        let successfulSave = await changedStore.loadPairing()
        XCTAssertEqual(successfulSave, try IOSPhoneControlCredentials.validatedPairing(valid))
        XCTAssertTrue(changed.hasPreparedPairing)
        XCTAssertFalse(changed.isUpdatingPairing)
    }

    @MainActor
    func testConnectionPreparationExcludesCompetingControllerOperations() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.isPrepared = false
        let gate = ControllerOperationGate()
        tunnel.prepareOperation = { await gate.suspend() }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: nil), localTunnel: tunnel)
        controller.enabled = true
        let preparation = Task { try await controller.prepareConnection() }
        await gate.waitUntilEntered()
        XCTAssertTrue(controller.isPreparingConnection)
        XCTAssertFalse(controller.claim(runID: "during-prepare", onStop: {}))
        for action in [
            { try await controller.prepareConnection() },
            { try await controller.preparePairing() },
            { try await controller.importPairing(Data()) },
            { try await controller.removePairing() },
            { _ = try await controller.loadInstalledApplications() },
        ] {
            do { try await action(); XCTFail("Connection preparation must exclude competing operations") }
            catch IOSPhoneControlError.occupied { }
        }
        gate.release()
        try await preparation.value
        XCTAssertFalse(controller.isPreparingConnection)
        XCTAssertTrue(tunnel.isPrepared)
        XCTAssertTrue(tunnel.startOwners.isEmpty, "Preparing config must not connect it")
        XCTAssertTrue(tunnel.stopOwners.isEmpty)
        XCTAssertTrue(controller.claim(runID: "after-prepare", onStop: {}))
        await controller.stop(runID: "after-prepare")
        XCTAssertTrue(tunnel.stopOwners.isEmpty, "An untouched claim must not stop any tunnel")
    }

    @MainActor
    func testExistingPairingAndInvalidStartupDoNotTouchTunnel() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials, localTunnel: tunnel)
        try await controller.preparePairing()
        XCTAssertTrue(controller.hasPreparedPairing)
        XCTAssertTrue(tunnel.startOwners.isEmpty)
        XCTAssertTrue(tunnel.stopOwners.isEmpty)
        await credentials.replaceUnchecked(Data([0]))
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example"]
        XCTAssertTrue(controller.claim(runID: "invalid", onStop: {}))
        do { _ = try await controller.start(runID: "invalid"); XCTFail("Invalid pairing must fail before transport") }
        catch is IOSPhoneControlCredentialError { }
        await controller.stop(runID: "invalid")
        XCTAssertTrue(tunnel.startOwners.isEmpty)
        XCTAssertTrue(tunnel.stopOwners.isEmpty)
        XCTAssertEqual(controller.phase, .failed)
    }

    @MainActor
    func testCancellingStartupCancelsTunnelBeforeNativeSessionStarts() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        let entered = ControllerOperationGate()
        var sawCancellation = false
        tunnel.startOperation = { _ in
            entered.markEntered()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { sawCancellation = true; throw error }
        }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), localTunnel: tunnel)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example"]
        XCTAssertTrue(controller.claim(runID: "cancel-start", onStop: {}))
        let startup = Task { try await controller.start(runID: "cancel-start") }
        await entered.waitUntilEntered()
        startup.cancel()
        do { _ = try await startup.value; XCTFail("Cancelling the caller must cancel tunnel startup") }
        catch is CancellationError { }
        await controller.stop(runID: "cancel-start")
        XCTAssertTrue(sawCancellation)
        XCTAssertEqual(tunnel.startOwners.count, 1)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertNil(controller.ownerRunID)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testApplicationQueryWaitsForNativeResultThenTunnelDisconnectBeforePublishing() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        let discovery = ControllerApplicationDiscovery([PhoneControlInstalledApp(bundleID: "app.known", name: "Known")])
        let closing = ControllerOperationGate()
        tunnel.stopOperation = { _ in
            let completed = await discovery.completedCount
            XCTAssertEqual(completed, 1, "The native query must return after joining, before tunnel teardown")
            await closing.suspend()
            return true
        }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
        controller.enabled = true
        let query = Task { try await controller.loadInstalledApplications() }
        await closing.waitUntilEntered()
        XCTAssertTrue(controller.isLoadingApplications)
        XCTAssertTrue(controller.installedApplications.isEmpty)
        XCTAssertFalse(controller.claim(runID: "too-early", onStop: {}))
        closing.release()
        let applications = try await query.value
        XCTAssertEqual(applications.map(\.bundleID), ["app.known"])
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
        XCTAssertFalse(controller.isLoadingApplications)
        XCTAssertTrue(controller.claim(runID: "next", onStop: {}))
        await controller.stop(runID: "next")
        XCTAssertEqual(tunnel.stopOwners.count, 1, "The standalone catalog owns and closes its own tunnel")
    }

    @MainActor
    func testApplicationQueryDisconnectFailureDoesNotPublishSuccessfulCatalog() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.stopOperation = { _ in false }
        let discovery = ControllerApplicationDiscovery([PhoneControlInstalledApp(bundleID: "app.known", name: "Known")])
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "apps", onStop: {}))
        do { _ = try await controller.loadInstalledApplications(runID: "apps"); XCTFail("Unfinished tunnel cleanup must not report success") }
        catch IOSPhoneControlLocalTunnelError.disconnectionTimedOut { }
        XCTAssertTrue(controller.installedApplications.isEmpty)
        XCTAssertEqual(controller.phase, .failed)
        await controller.stop(runID: "apps")
        XCTAssertEqual(controller.phase, .failed, "Revoking the claim must preserve the physical cleanup failure")
        XCTAssertEqual(tunnel.stopOwners.count, 1)
    }

    @MainActor
    func testQueryFailureSurvivesAdditionalTunnelCleanupFailure() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.stopOperation = { _ in false }
        let discovery = ControllerApplicationDiscovery([])
        await discovery.failQueries()
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
        do { _ = try await controller.loadInstalledApplications(); XCTFail("The original discovery failure must propagate") }
        catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.statusMessage, URLError(.cannotConnectToHost).localizedDescription)
        XCTAssertEqual(tunnel.stopOwners, tunnel.startOwners)
    }

    @MainActor
    func testStopReceiptPreservesCancelledQueryCleanupFailureAcrossNextClaim() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.stopOperation = { _ in false }
        let discovery = ControllerApplicationDiscovery([], blockFirst: true)
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "old", onStop: {}))
        let query = Task { try await controller.loadInstalledApplications(runID: "old") }
        await discovery.waitUntilStarted()
        let stopEntered = ControllerOperationGate()
        let consumeReceipt = ControllerOperationGate()
        let stopping = Task {
            stopEntered.markEntered()
            let result = await controller.stop(runID: "old")
            await consumeReceipt.suspend()
            return result
        }
        await stopEntered.waitUntilEntered()
        XCTAssertEqual(controller.phase, .stopping)
        await discovery.release()
        await consumeReceipt.waitUntilEntered()
        _ = await query.result
        XCTAssertTrue(controller.claim(runID: "new", onStop: {}))
        XCTAssertEqual(controller.phase, .authorized, "A new owner resets shared display state")
        consumeReceipt.release()
        let stopped = await stopping.value
        let result = try XCTUnwrap(stopped)
        XCTAssertFalse(result.cleanupComplete, "The old receipt must retain its actual failed teardown")
        XCTAssertEqual(result.cleanupFailure, IOSPhoneControlLocalTunnelError.disconnectionTimedOut.localizedDescription)
        XCTAssertEqual(controller.ownerRunID, "new")
        let newResult = await controller.stop(runID: "new")
        XCTAssertEqual(newResult?.cleanupComplete, true)
    }

    @MainActor
    func testStartupFailureDoesNotBecomeCleanupFailureWhenTunnelDisconnected() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.startOperation = { _ in throw URLError(.cannotConnectToHost) }
        let closing = ControllerOperationGate()
        tunnel.stopOperation = { _ in await closing.suspend(); return true }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), localTunnel: tunnel)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example"]
        XCTAssertTrue(controller.claim(runID: "failed-start", onStop: {}))
        let startup = Task { try await controller.start(runID: "failed-start") }
        await closing.waitUntilEntered()
        let stopEntered = ControllerOperationGate()
        let stopping = Task {
            stopEntered.markEntered()
            return await controller.stop(runID: "failed-start")
        }
        await stopEntered.waitUntilEntered()
        closing.release()
        let stopped = await stopping.value
        let result = try XCTUnwrap(stopped)
        do { _ = try await startup.value; XCTFail("Startup must retain its original failure") }
        catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertNil(result.cleanupFailure)
        XCTAssertEqual(controller.phase, .failed, "Startup failure remains visible separately from successful teardown")
        XCTAssertEqual(controller.statusMessage, URLError(.cannotConnectToHost).localizedDescription)
    }

    @MainActor
    func testLaterQuerySuccessfulDisconnectClearsPendingCleanupFailureInSameRun() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        var stopCount = 0
        tunnel.stopOperation = { _ in stopCount += 1; return stopCount > 1 }
        let discovery = ControllerApplicationDiscovery([PhoneControlInstalledApp(bundleID: "app.known", name: "Known")])
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "recover-query", onStop: {}))
        do { _ = try await controller.loadInstalledApplications(runID: "recover-query"); XCTFail("Initial disconnect must fail") }
        catch IOSPhoneControlLocalTunnelError.disconnectionTimedOut { }
        let apps = try await controller.loadInstalledApplications(runID: "recover-query")
        XCTAssertEqual(apps.map(\.bundleID), ["app.known"])
        let result = await controller.stop(runID: "recover-query")
        XCTAssertEqual(result?.cleanupComplete, true, "Later physical disconnect must supersede the earlier timeout")
        XCTAssertNil(result?.cleanupFailure)
        XCTAssertEqual(stopCount, 2)
    }

    @MainActor
    func testControlTeardownSuccessfulDisconnectSupersedesPriorQueryCleanupFailure() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        let closing = ControllerOperationGate()
        var stopCount = 0
        tunnel.stopOperation = { _ in
            stopCount += 1
            if stopCount == 1 { return false }
            await closing.suspend()
            return true
        }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()),
            applications: ControllerApplicationDiscovery([]), localTunnel: tunnel)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example"]
        XCTAssertTrue(controller.claim(runID: "recover-control", onStop: {}))
        do { _ = try await controller.loadInstalledApplications(runID: "recover-control"); XCTFail("Initial disconnect must fail") }
        catch IOSPhoneControlLocalTunnelError.disconnectionTimedOut { }
        // Exercise control teardown without allowing this unit test to start a native session.
        tunnel.startOperation = { _ in throw URLError(.cannotConnectToHost) }
        let startup = Task { try await controller.start(runID: "recover-control") }
        await closing.waitUntilEntered()
        let stopEntered = ControllerOperationGate()
        let stopping = Task {
            stopEntered.markEntered()
            return await controller.stop(runID: "recover-control")
        }
        await stopEntered.waitUntilEntered()
        closing.release()
        let result = await stopping.value
        _ = await startup.result
        XCTAssertEqual(result?.cleanupComplete, true, "The control owner's actual successful disconnect supersedes the old query timeout")
        XCTAssertNil(result?.cleanupFailure)
        XCTAssertEqual(stopCount, 2)
    }

    @MainActor
    func testHandoffWithNoToolPausesImmediatelyAndRetainsPendingFreshReadAcrossResume() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "thinking", onStop: {}))
        let originalScope = controller.selectedBundleIDs
        try controller.requestHumanTakeover(runID: "thinking")
        try controller.requestHumanTakeover(runID: "thinking")
        XCTAssertEqual(controller.handoffState(runID: "thinking"), .paused)
        XCTAssertEqual(controller.phase, .authorized)
        XCTAssertEqual(controller.ownerRunID, "thinking")
        XCTAssertFalse(controller.hasRequestedSession(runID: "thinking"))
        XCTAssertTrue(fixture.tunnel.startOwners.isEmpty)
        XCTAssertEqual(controller.selectedBundleIDs, originalScope)

        try controller.resumeAutomation(runID: "thinking")
        XCTAssertEqual(controller.handoffState(runID: "thinking"), .resuming)
        let nextTool = try controller.beginPhoneTool(runID: "thinking")
        XCTAssertEqual(nextTool.takeoverGeneration, 1, "Repeated pause requests must not create extra generations")
        XCTAssertTrue(try controller.requiresFreshObservation(nextTool), "A late old act or goal must return fresh UI to the main model")
        controller.endPhoneTool(nextTool)
        let generation = try await controller.waitForAutomationResume(nextTool)
        XCTAssertEqual(generation, 1)
        XCTAssertTrue(try controller.consumeFreshObservation(nextTool, generation: generation))
        XCTAssertEqual(controller.handoffState(runID: "thinking"), .automated)
        let replannedTool = try controller.beginPhoneTool(runID: "thinking")
        XCTAssertFalse(try controller.requiresFreshObservation(replannedTool))
        controller.endPhoneTool(replannedTool)
        XCTAssertEqual(fixture.activity.states, [.paused, .resuming, .automated])
        await controller.stop(runID: "thinking")
    }

    @MainActor
    func testHandoffWaitsForInFlightReceiptAndKeepsReadySessionUntilFreshReadConsumed() async throws {
        let http = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { http.unregister() }
        let fixture = try HandoffControllerFixture(pairing: pairingData(), session: ReadinessSessionStub(fixture: http))
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "inflight", onStop: {}))
        try await controller.start(runID: "inflight")
        XCTAssertTrue(controller.canDispatchAction(runID: "inflight"))
        let tool = try controller.beginPhoneTool(runID: "inflight")
        try controller.requestHumanTakeover(runID: "inflight")
        XCTAssertEqual(controller.handoffState(runID: "inflight"), .pausing)
        XCTAssertFalse(controller.canDispatchAction(runID: "inflight"))
        do { try controller.resumeAutomation(runID: "inflight"); XCTFail("Resume must wait for the dispatched action receipt") }
        catch IOSPhoneControlHandoffError.operationInFlight { }
        controller.endPhoneTool(tool)
        XCTAssertEqual(controller.handoffState(runID: "inflight"), .paused)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(fixture.tunnel.stopOwners.isEmpty)

        let entered = ControllerOperationGate()
        let waiting = Task {
            entered.markEntered()
            return try await controller.waitForAutomationResume(tool)
        }
        await entered.waitUntilEntered()
        try controller.resumeAutomation(runID: "inflight")
        let generation = try await waiting.value
        XCTAssertEqual(controller.handoffState(runID: "inflight"), .resuming)
        XCTAssertFalse(controller.canDispatchAction(runID: "inflight"), "Clicking resume alone must not dispatch an old ref")
        let client = try controller.runner(runID: "inflight")
        _ = try await client.observe(maxNodes: 200)
        XCTAssertTrue(try controller.consumeFreshObservation(tool, generation: generation))
        XCTAssertTrue(controller.canDispatchAction(runID: "inflight"))
        XCTAssertEqual(fixture.tunnel.startOwners.count, 1, "Human control must reuse the same native connection")
        XCTAssertEqual(fixture.activity.states, [.pausing, .paused, .resuming, .automated])
        await controller.stop(runID: "inflight")
    }

    @MainActor
    func testHandoffSecondPauseRejectsEarlierFreshReadGeneration() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "repeat", onStop: {}))
        let tool = try controller.beginPhoneTool(runID: "repeat")
        try controller.requestHumanTakeover(runID: "repeat")
        controller.endPhoneTool(tool)
        try controller.resumeAutomation(runID: "repeat")
        let oldGeneration = try await controller.waitForAutomationResume(tool)
        // Model a fresh runner read returning after the user requested control again.
        try controller.requestHumanTakeover(runID: "repeat")
        XCTAssertEqual(controller.handoffState(runID: "repeat"), .paused)
        XCTAssertFalse(try controller.consumeFreshObservation(tool, generation: oldGeneration))
        XCTAssertEqual(controller.handoffState(runID: "repeat"), .paused)
        XCTAssertTrue(try controller.requiresFreshObservation(tool))
        try controller.resumeAutomation(runID: "repeat")
        let nextGeneration = try await controller.waitForAutomationResume(tool)
        XCTAssertGreaterThan(nextGeneration, oldGeneration)
        XCTAssertTrue(try controller.consumeFreshObservation(tool, generation: nextGeneration))
        await controller.stop(runID: "repeat")
    }

    @MainActor
    func testLateResumeObservationFailureCannotChangeNewGenerationOrOwner() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "same-run", onStop: {}))
        let oldTool = try controller.beginPhoneTool(runID: "same-run")
        controller.endPhoneTool(oldTool)
        try controller.requestHumanTakeover(runID: "same-run")
        try controller.resumeAutomation(runID: "same-run")
        let oldGeneration = try await controller.waitForAutomationResume(oldTool)
        try controller.requestHumanTakeover(runID: "same-run")
        XCTAssertFalse(controller.failResumeObservation(oldTool, generation: oldGeneration, message: "late failure"))
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .paused)
        XCTAssertNil(controller.handoffFailure(runID: "same-run"))
        try controller.resumeAutomation(runID: "same-run")
        let newGeneration = try await controller.waitForAutomationResume(oldTool)
        XCTAssertFalse(controller.failResumeObservation(oldTool, generation: oldGeneration, message: "late failure"))
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .resuming)
        XCTAssertNil(controller.handoffFailure(runID: "same-run"))
        XCTAssertTrue(controller.failResumeObservation(oldTool, generation: newGeneration, message: "source failed"))
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .paused)
        XCTAssertTrue(try controller.requiresFreshObservation(oldTool))
        XCTAssertNotNil(controller.handoffFailure(runID: "same-run"))
        try controller.resumeAutomation(runID: "same-run")
        XCTAssertNil(controller.handoffFailure(runID: "same-run"))
        controller.revoke(runID: "same-run")
        XCTAssertFalse(controller.failResumeObservation(oldTool, generation: newGeneration, message: "stopped failure"))
        await controller.stop(runID: "same-run")

        XCTAssertTrue(controller.claim(runID: "same-run", onStop: {}))
        let newTool = try controller.beginPhoneTool(runID: "same-run")
        controller.endPhoneTool(newTool)
        try controller.requestHumanTakeover(runID: "same-run")
        try controller.resumeAutomation(runID: "same-run")
        let restartedGeneration = try await controller.waitForAutomationResume(newTool)
        XCTAssertFalse(controller.failResumeObservation(oldTool, generation: restartedGeneration, message: "old owner failed"))
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .resuming)
        XCTAssertNil(controller.handoffFailure(runID: "same-run"))
        let uncertainTool = try controller.beginPhoneTool(runID: "same-run")
        controller.endPhoneTool(uncertainTool, outcomeUnknown: true)
        XCTAssertFalse(controller.failResumeObservation(newTool, generation: restartedGeneration, message: "unknown must win"))
        XCTAssertNil(controller.handoffState(runID: "same-run"))
        XCTAssertNil(controller.handoffFailure(runID: "same-run"))
        await controller.stop(runID: "same-run")
    }

    @MainActor
    func testHandoffCancelledWaiterIsReleasedWithoutStoppingOwner() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "cancel-wait", onStop: {}))
        let tool = try controller.beginPhoneTool(runID: "cancel-wait")
        try controller.requestHumanTakeover(runID: "cancel-wait")
        controller.endPhoneTool(tool)
        let entered = ControllerOperationGate()
        let waiting = Task {
            entered.markEntered()
            return try await controller.waitForAutomationResume(tool)
        }
        await entered.waitUntilEntered()
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled waiter must return") }
        catch is CancellationError { }
        XCTAssertEqual(controller.ownerRunID, "cancel-wait")
        XCTAssertEqual(controller.handoffState(runID: "cancel-wait"), .paused)
        let secondEntered = ControllerOperationGate()
        let secondWait = Task {
            secondEntered.markEntered()
            return try await controller.waitForAutomationResume(tool)
        }
        await secondEntered.waitUntilEntered()
        try controller.resumeAutomation(runID: "cancel-wait")
        _ = try await secondWait.value
        await controller.stop(runID: "cancel-wait")
    }

    @MainActor
    func testHandoffStopReleasesWaiterAndOldLeaseCannotAffectReusedRunID() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "same-run", onStop: {}))
        let oldTool = try controller.beginPhoneTool(runID: "same-run")
        try controller.requestHumanTakeover(runID: "same-run")
        controller.endPhoneTool(oldTool)
        let entered = ControllerOperationGate()
        let waiting = Task {
            entered.markEntered()
            return try await controller.waitForAutomationResume(oldTool)
        }
        await entered.waitUntilEntered()
        await controller.stop(runID: "same-run")
        do { _ = try await waiting.value; XCTFail("Stopping must release its wait") }
        catch IOSPhoneControlError.unauthorized { }
        XCTAssertTrue(controller.claim(runID: "same-run", onStop: {}))
        let newTool = try controller.beginPhoneTool(runID: "same-run")
        XCTAssertNotEqual(oldTool.sessionID, newTool.sessionID)
        controller.endPhoneTool(oldTool, outcomeUnknown: true)
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .automated)
        do { _ = try controller.consumeFreshObservation(oldTool, generation: 1); XCTFail("Old completion must be rejected") }
        catch IOSPhoneControlError.unauthorized { }
        do { _ = try await controller.waitForAutomationResume(oldTool); XCTFail("Old waiter must be rejected") }
        catch IOSPhoneControlError.unauthorized { }
        // The late end above must not clear the new in-flight tool.
        try controller.requestHumanTakeover(runID: "same-run")
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .pausing)
        controller.endPhoneTool(newTool)
        XCTAssertEqual(controller.handoffState(runID: "same-run"), .paused)
        await controller.stop(runID: "same-run")
    }

    @MainActor
    func testHandoffDisableReleasesWaiterAndDoesNotRestoreOwner() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        var stopped = false
        XCTAssertTrue(controller.claim(runID: "disable-wait", onStop: { stopped = true }))
        let tool = try controller.beginPhoneTool(runID: "disable-wait")
        try controller.requestHumanTakeover(runID: "disable-wait")
        controller.endPhoneTool(tool)
        let entered = ControllerOperationGate()
        let waiting = Task {
            entered.markEntered()
            return try await controller.waitForAutomationResume(tool)
        }
        await entered.waitUntilEntered()
        controller.enabled = false
        do { _ = try await waiting.value; XCTFail("Disable must release its wait") }
        catch IOSPhoneControlError.unauthorized { }
        await controller.stopCurrent()
        XCTAssertTrue(stopped)
        XCTAssertNil(controller.ownerRunID)
        controller.enabled = true
        XCTAssertNil(controller.handoffState(runID: "disable-wait"))
    }

    @MainActor
    func testHandoffUnknownPreventsWaitResumeAndFreshObservationBeforeEngineTeardown() async throws {
        let fixture = try HandoffControllerFixture()
        defer { fixture.clear() }
        let controller = fixture.controller
        XCTAssertTrue(controller.claim(runID: "unknown", onStop: {}))
        let tool = try controller.beginPhoneTool(runID: "unknown")
        try controller.requestHumanTakeover(runID: "unknown")
        let entered = ControllerOperationGate()
        let waiting = Task {
            entered.markEntered()
            return try await controller.waitForAutomationResume(tool)
        }
        await entered.waitUntilEntered()
        controller.endPhoneTool(tool, outcomeUnknown: true)
        do { _ = try await waiting.value; XCTFail("Unknown must release an existing waiter") }
        catch IOSPhoneControlHandoffError.outcomeUnknown { }
        XCTAssertEqual(controller.ownerRunID, "unknown", "The existing engine remains responsible for recording unknown and teardown")
        XCTAssertNil(controller.handoffState(runID: "unknown"))
        XCTAssertFalse(controller.canDispatchAction(runID: "unknown"))
        XCTAssertEqual(fixture.activity.states, [.pausing], "Unknown must never be replaced with paused")
        do { _ = try await controller.waitForAutomationResume(tool); XCTFail("Unknown must not wait") }
        catch IOSPhoneControlHandoffError.outcomeUnknown { }
        do { _ = try controller.requiresFreshObservation(tool); XCTFail("Unknown must not request another observation") }
        catch IOSPhoneControlHandoffError.outcomeUnknown { }
        do { try controller.resumeAutomation(runID: "unknown"); XCTFail("Unknown must not resume") }
        catch IOSPhoneControlHandoffError.outcomeUnknown { }
        do { _ = try controller.consumeFreshObservation(tool, generation: 1); XCTFail("Unknown must not consume a fresh read") }
        catch IOSPhoneControlHandoffError.outcomeUnknown { }
        await controller.stop(runID: "unknown")
    }

    @MainActor
    func testHandoffIsUnavailableToReadinessOwner() async throws {
        let http = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { http.unregister() }
        let session = ReadinessSessionStub(fixture: http, blockStartup: true)
        let fixture = try HandoffControllerFixture(pairing: pairingData(), session: session)
        defer { fixture.clear() }
        let controller = fixture.controller
        let checking = Task { try await controller.checkReadiness() }
        await session.waitUntilStarted()
        let runID = try XCTUnwrap(controller.ownerRunID)
        XCTAssertNil(controller.handoffState(runID: runID))
        do { try controller.requestHumanTakeover(runID: runID); XCTFail("Readiness is not a user-controlled task") }
        catch IOSPhoneControlHandoffError.preparationCheck { }
        do { _ = try controller.beginPhoneTool(runID: runID); XCTFail("Readiness must not count as a tool lease") }
        catch IOSPhoneControlHandoffError.preparationCheck { }
        controller.cancelReadinessCheck()
        await session.releaseStartup()
        try await checking.value
        XCTAssertTrue(fixture.activity.states.isEmpty)
    }

    @MainActor
    func testExternalConnectionModePersistsAndNeverPreparesAmberVPN() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
        let tunnel = PhoneControlTunnelStub()
        tunnel.isPrepared = false
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), localTunnel: tunnel)
        await controller.refreshPreparation()
        XCTAssertEqual(controller.connectionMode, .existingVPN)
        XCTAssertTrue(controller.isConnectionPrepared)
        do { try await controller.prepareConnection(); XCTFail("External mode must not create a VPN configuration") }
        catch IOSPhoneControlError.externallyManagedConnection { }
        controller.enabled = true
        controller.selectedBundleIDs = ["app.amber.ios"]
        XCTAssertTrue(controller.claim(runID: "external", onStop: {}))
        XCTAssertTrue(controller.statusText(runID: "external").contains("availability=available"))
        XCTAssertThrowsError(try controller.setConnectionMode(.embedded))
        await controller.stop(runID: "external")
        assertNoTunnelCalls(tunnel)
        try controller.setConnectionMode(.embedded)
        XCTAssertEqual(defaults.string(forKey: IOSPhoneControlController.connectionModePreferenceKey), "embedded")
        XCTAssertFalse(controller.isConnectionPrepared)
    }

    @MainActor
    func testReturningFromExternalModeRefreshesExistingEmbeddedPreparation() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
        let tunnel = PhoneControlTunnelStub()
        tunnel.isPrepared = false
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), localTunnel: tunnel)
        await controller.refreshPreparation()
        assertNoTunnelCalls(tunnel)
        let refreshed = expectation(description: "Switching back reloads the saved Amber VPN configuration")
        tunnel.refreshOperation = {
            tunnel.isPrepared = true
            refreshed.fulfill()
        }
        try controller.setConnectionMode(.embedded)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertTrue(controller.isConnectionPrepared)
        XCTAssertEqual(tunnel.prepareCount, 0, "Reading an existing configuration must not save or enable it")
        XCTAssertTrue(tunnel.startOwners.isEmpty)
        XCTAssertTrue(tunnel.stopOwners.isEmpty)
    }

    @MainActor
    func testExternalReadinessUsesRealRunnerReadAndCleansUpWithoutTouchingVPN() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
        let http = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { http.unregister() }
        let session = ReadinessSessionStub(fixture: http)
        let tunnel = PhoneControlTunnelStub()
        tunnel.isPrepared = false
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        let modes = await session.connectionModes
        XCTAssertEqual(modes, [.existingVPN])
        XCTAssertNotNil(controller.readinessReport?.connectionVerifiedAt)
        XCTAssertNotNil(controller.readinessReport?.uiReadAt)
        XCTAssertNil(controller.readinessReport?.failureMessage)
        XCTAssertTrue(controller.readinessReport?.cleanupComplete == true)
        XCTAssertNil(controller.ownerRunID)
        XCTAssertTrue(http.paths.contains("/source"))
        assertNoTunnelCalls(tunnel)
        try controller.setConnectionMode(.embedded)
        XCTAssertNil(controller.readinessReport, "A different route must not inherit a previous readiness result")
    }

    @MainActor
    func testStartupUsesTheDynamicallyResolvedRemotePairingPort() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { http.unregister() }
        let session = ReadinessSessionStub(fixture: http)
        let tunnel = PhoneControlTunnelStub()
        // iOS may move RemotePairing off 49152 when that port is taken.
        tunnel.remotePairingPort = 62_043
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
        controller.enabled = true
        try await controller.checkReadiness()
        let endpoints = await session.endpoints
        XCTAssertEqual(endpoints, ["10.7.0.1:62043"])
    }

    @MainActor
    func testExternalStartupFailureAndCancellationLeaveVPNUntouched() async throws {
        for cancel in [false, true] {
            let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
            let http = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
            defer { http.unregister() }
            let session = ReadinessSessionStub(fixture: http, failStartup: !cancel, blockStartup: cancel)
            let tunnel = PhoneControlTunnelStub()
            let controller = IOSPhoneControlController(defaults: defaults,
                credentials: MemoryPairingStore(data: try pairingData()), session: session, localTunnel: tunnel)
            controller.enabled = true
            let checking = Task { try await controller.checkReadiness() }
            await session.waitUntilStarted()
            if cancel {
                XCTAssertThrowsError(try controller.setConnectionMode(.embedded))
                controller.cancelReadinessCheck()
                await session.releaseStartup()
            }
            try await checking.value
            XCTAssertNil(controller.ownerRunID)
            XCTAssertTrue(controller.readinessReport?.cleanupComplete == true)
            XCTAssertEqual(controller.readinessReport?.wasCancelled, cancel)
            XCTAssertNil(controller.readinessReport?.uiReadAt)
            assertNoTunnelCalls(tunnel)
        }
    }

    @MainActor
    func testExternalApplicationQuerySuccessFailureAndCancellationNeverManageVPN() async throws {
        for scenario in ["success", "failure", "cancel"] {
            let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
            let discovery = ControllerApplicationDiscovery([
                PhoneControlInstalledApp(bundleID: "app.example", name: "Example")
            ], blockFirst: scenario == "cancel")
            if scenario == "failure" { await discovery.failQueries() }
            let tunnel = PhoneControlTunnelStub()
            let controller = IOSPhoneControlController(defaults: defaults,
                credentials: MemoryPairingStore(data: try pairingData()), applications: discovery, localTunnel: tunnel)
            let querying = Task { try await controller.loadInstalledApplications() }
            await discovery.waitUntilStarted()
            if scenario == "cancel" {
                XCTAssertThrowsError(try controller.setConnectionMode(.embedded))
                querying.cancel()
                await discovery.release()
            }
            do {
                let applications = try await querying.value
                XCTAssertEqual(scenario, "success")
                XCTAssertEqual(applications.map(\.bundleID), ["app.example"])
            } catch {
                XCTAssertNotEqual(scenario, "success")
                XCTAssertTrue(controller.installedApplications.isEmpty)
            }
            let modes = await discovery.connectionModes
            XCTAssertEqual(modes, [.existingVPN])
            XCTAssertFalse(controller.isLoadingApplications)
            assertNoTunnelCalls(tunnel)
        }
    }

    @MainActor
    func testExternalFirstPairingSuccessFailureAndCancellationNeverManageVPN() async throws {
        for scenario in ["success", "failure", "cancel"] {
            let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("existingVPN", forKey: IOSPhoneControlController.connectionModePreferenceKey)
            let pairing = ExternalPairingStub(data: try pairingData(), scenario: scenario)
            let credentials = MemoryPairingStore(data: nil)
            let tunnel = PhoneControlTunnelStub()
            let controller = IOSPhoneControlController(defaults: defaults,
                credentials: credentials, localTunnel: tunnel, pairingSession: pairing)
            let preparing = Task { try await controller.preparePairing() }
            await pairing.waitUntilStarted()
            if scenario == "cancel" {
                XCTAssertThrowsError(try controller.setConnectionMode(.embedded))
                controller.cancelPreparation()
            }
            do {
                try await preparing.value
                XCTAssertEqual(scenario, "success")
            } catch { XCTAssertNotEqual(scenario, "success") }
            let modes = await pairing.connectionModes
            XCTAssertEqual(modes, [.existingVPN])
            let saved = await credentials.loadPairing()
            XCTAssertEqual(saved != nil, scenario == "success")
            XCTAssertFalse(controller.isUpdatingPairing)
            assertNoTunnelCalls(tunnel)
        }
    }

    @MainActor
    private func assertNoTunnelCalls(_ tunnel: PhoneControlTunnelStub, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tunnel.refreshCount, 0, file: file, line: line)
        XCTAssertEqual(tunnel.prepareCount, 0, file: file, line: line)
        XCTAssertTrue(tunnel.startOwners.isEmpty, file: file, line: line)
        XCTAssertTrue(tunnel.stopOwners.isEmpty, file: file, line: line)
    }

    private func pairingDictionary() throws -> [String: Any] {
        let key = Curve25519.Signing.PrivateKey()
        return ["public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                "identifier": UUID().uuidString]
    }

    func pairingData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: pairingDictionary(), format: .xml, options: 0)
    }
}

private actor ExternalPairingStub: PhoneControlPairingServing {
    let data: Data
    let scenario: String
    private(set) var connectionModes: [IOSPhoneControlConnectionMode] = []
    private var started: CheckedContinuation<Void, Never>?

    init(data: Data, scenario: String) { self.data = data; self.scenario = scenario }

    func prepare(id: UUID, connectionMode: IOSPhoneControlConnectionMode,
                 progress: @Sendable (PhoneControlLaunchStatus) async -> Void) async throws -> Data {
        connectionModes.append(connectionMode)
        started?.resume()
        started = nil
        if scenario == "cancel" { try await Task.sleep(for: .seconds(60)) }
        if scenario == "failure" { throw URLError(.cannotConnectToHost) }
        return data
    }

    func waitUntilStarted() async {
        if connectionModes.isEmpty { await withCheckedContinuation { started = $0 } }
    }

    func cancel(id: UUID) { }
}

actor MemoryPairingStore: IOSPhoneControlCredentialStoring {
    var data: Data?
    private let onSave: @Sendable () throws -> Void
    init(data: Data?, onSave: @escaping @Sendable () throws -> Void = {}) {
        self.data = data
        self.onSave = onSave
    }
    func loadPairing() -> Data? { data }
    func savePairing(_ data: Data) throws {
        let validated = try IOSPhoneControlCredentials.validatedPairing(data)
        try onSave()
        self.data = validated
    }
    func deletePairing() { data = nil }
    func replaceUnchecked(_ data: Data) { self.data = data }
}

private actor ControllerApplicationDiscovery: PhoneControlApplicationDiscovering {
    let applications: [PhoneControlInstalledApp]
    private let blockFirst: Bool
    private var shouldFail = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private(set) var completedCount = 0
    private(set) var connectionModes: [IOSPhoneControlConnectionMode] = []

    init(_ applications: [PhoneControlInstalledApp], blockFirst: Bool = false) {
        self.applications = applications
        self.blockFirst = blockFirst
    }

    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) async throws -> [PhoneControlInstalledApp] {
        callCount += 1
        connectionModes.append(connectionMode)
        started?.resume()
        started = nil
        if blockFirst && callCount == 1 {
            // Intentionally return a late result despite cancellation, like a native join finishing.
            await withCheckedContinuation { pending = $0 }
        }
        completedCount += 1
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return applications
    }

    func waitUntilStarted() async {
        if callCount > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { pending?.resume(); pending = nil }
    func failQueries() { shouldFail = true }
}

@MainActor
private final class ControllerOperationGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func markEntered() {
        hasEntered = true
        entered?.resume()
        entered = nil
    }

    func suspend() async {
        markEntered()
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class HandoffControllerFixture {
    let suite: String
    let defaults: UserDefaults
    let tunnel = PhoneControlTunnelStub()
    let activity = HandoffActivityRecorder()
    let controller: IOSPhoneControlController

    init(pairing: Data? = nil, session: any IOSPhoneControlSessionServing = PhoneControlSession()) throws {
        suite = "IOSPhoneControlHandoff.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recorder = activity
        controller = IOSPhoneControlController(defaults: defaults,
            credentials: MemoryPairingStore(data: pairing), session: session, localTunnel: tunnel,
            onHandoffChange: { runID, state in recorder.events.append((runID, state)) })
        controller.enabled = true
        controller.selectedBundleIDs = [try XCTUnwrap(Bundle.main.bundleIdentifier)]
    }

    func clear() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class HandoffActivityRecorder {
    var events: [(String, IOSPhoneControlHandoffState)] = []
    var states: [IOSPhoneControlHandoffState] { events.map(\.1) }
}
