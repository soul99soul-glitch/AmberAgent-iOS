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
    func testAuthorizationWindowIsReusableWithoutExtendingDeadline() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.first"]
        try controller.authorizeNextTask(durationSeconds: 300)
        XCTAssertTrue(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.claim(runID: "run-a", onExpiration: {}))
        let firstRemaining = try remainingSeconds(controller.statusText(runID: "run-a"))
        XCTAssertTrue(firstRemaining > 0)
        XCTAssertFalse(controller.claim(runID: "run-b", onExpiration: {}))
        await controller.stop(runID: "run-a")
        XCTAssertTrue(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.claim(runID: "run-b", onExpiration: {}))
        let secondRemaining = try remainingSeconds(controller.statusText(runID: "run-b"))
        XCTAssertLessThanOrEqual(secondRemaining, firstRemaining)
        XCTAssertTrue(controller.statusText(runID: "run-b").contains("scope=app.example.first"))
        await controller.stop(runID: "run-b")
        XCTAssertTrue(controller.hasPendingAuthorization)
        controller.discardPendingAuthorization()
        XCTAssertFalse(controller.hasPendingAuthorization)
    }

    @MainActor
    func testScopeDisableAndUnknownRevokeClearWindowWithStaleRunGuard() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.first"]
        try controller.authorizeNextTask(durationSeconds: 300)
        XCTAssertTrue(controller.claim(runID: "run-a", onExpiration: {}))
        controller.selectedBundleIDs = ["app.example.second"]
        XCTAssertFalse(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.statusText(runID: "run-a").contains("scope=app.example.first"))
        await controller.stop(runID: "run-a")

        try controller.authorizeNextTask(durationSeconds: 300)
        XCTAssertTrue(controller.claim(runID: "run-b", onExpiration: {}))
        XCTAssertFalse(controller.revokeAuthorizationWindow(runID: "run-a"))
        XCTAssertTrue(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.revokeAuthorizationWindow(runID: "run-b"))
        XCTAssertFalse(controller.hasPendingAuthorization)
        await controller.stop(runID: "run-b")

        try controller.authorizeNextTask(durationSeconds: 300)
        XCTAssertTrue(controller.hasPendingAuthorization)
        controller.enabled = false
        XCTAssertFalse(controller.hasPendingAuthorization)
        controller.enabled = true
        XCTAssertFalse(controller.hasPendingAuthorization)
    }

    @MainActor
    func testUnlimitedWindowIsReusableAndStatusIsExplicit() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.target"]
        try controller.authorizeNextTask(durationSeconds: 0)
        XCTAssertTrue(controller.claim(runID: "unlimited-a", onExpiration: {}))
        XCTAssertTrue(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.statusText(runID: "unlimited-a").contains("authorization_remaining=unlimited"))
        await controller.stop(runID: "unlimited-a")
        XCTAssertTrue(controller.hasPendingAuthorization)
        XCTAssertTrue(controller.claim(runID: "unlimited-b", onExpiration: {}))
        await controller.stop(runID: "unlimited-b")
        controller.discardPendingAuthorization()
    }

    @MainActor
    func testOnlyNonsecretConfigurationSurvivesControllerRecreationAndDisableRevokes() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let first = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await first.refreshPreparation()
        first.enabled = true
        first.selectedBundleIDs = ["app.example.target"]
        try first.authorizeNextTask(durationSeconds: 300)
        let restored = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await restored.refreshPreparation()
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.selectedBundleIDs, ["app.example.target"])
        XCTAssertFalse(restored.hasPendingAuthorization)
        XCTAssertNil(restored.ownerRunID)
        var cancelled = 0
        XCTAssertTrue(first.claim(runID: "run-a", onExpiration: { cancelled += 1 }))
        first.enabled = false
        XCTAssertEqual(first.phase, .stopping)
        XCTAssertEqual(cancelled, 1)
        XCTAssertThrowsError(try first.runner(runID: "run-a"))
        await first.stop(runID: "run-a")
        XCTAssertNil(first.ownerRunID)
        XCTAssertFalse(defaults.bool(forKey: IOSPhoneControlController.enabledPreferenceKey))
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
        let controller = IOSPhoneControlController(defaults: defaults, credentials: store)
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
        let failing = IOSPhoneControlController(defaults: defaults, credentials: failingStore)
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
        let changed = IOSPhoneControlController(defaults: defaults, credentials: changedStore)
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

    private func pairingDictionary() throws -> [String: Any] {
        let key = Curve25519.Signing.PrivateKey()
        return ["public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                "identifier": UUID().uuidString]
    }

    private func pairingData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: pairingDictionary(), format: .xml, options: 0)
    }

    private func remainingSeconds(_ status: String) throws -> Int {
        let line = try XCTUnwrap(status.split(separator: "\n").first { $0.hasPrefix("authorization_remaining_seconds=") })
        return try XCTUnwrap(Int(line.split(separator: "=").last!))
    }
}

private actor MemoryPairingStore: IOSPhoneControlCredentialStoring {
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
}
