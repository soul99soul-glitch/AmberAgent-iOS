import CryptoKit
import Foundation
import XCTest
@testable import iosApp

final class IOSPhoneControlControllerTests: XCTestCase {
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
    func testGrantIsConsumedByOneRunAndScopeDoesNotExpandWhenSettingsChange() async throws {
        let suite = "IOSPhoneControlControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryPairingStore(data: try pairingData())
        let controller = IOSPhoneControlController(defaults: defaults, credentials: credentials)
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.first"]
        try controller.authorizeNextTask(durationSeconds: 60)
        var cancelled = 0
        XCTAssertTrue(controller.claim(runID: "run-a", onExpiration: { cancelled += 1 }))
        XCTAssertFalse(controller.hasPendingAuthorization)
        XCTAssertFalse(controller.claim(runID: "run-b", onExpiration: {}))
        controller.selectedBundleIDs = ["app.example.second"]
        XCTAssertTrue(controller.statusText(runID: "run-a").contains("scope=app.example.first"))
        XCTAssertFalse(controller.statusText(runID: "run-a").contains("app.example.second"))
        controller.revoke(runID: "stale-run")
        XCTAssertEqual(controller.ownerRunID, "run-a")
        await controller.stop(runID: "run-a")
        XCTAssertNil(controller.ownerRunID)
        XCTAssertEqual(cancelled, 0, "Terminal cleanup must not cancel another layer's terminal transition.")
        try controller.authorizeNextTask(durationSeconds: 60)
        XCTAssertTrue(controller.claim(runID: "run-b", onExpiration: { cancelled += 1 }))
        await controller.stopCurrent()
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(controller.ownerRunID)
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
        try first.authorizeNextTask(durationSeconds: 120)
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

    private func pairingDictionary() throws -> [String: Any] {
        let key = Curve25519.Signing.PrivateKey()
        return ["public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                "identifier": UUID().uuidString]
    }

    private func pairingData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: pairingDictionary(), format: .xml, options: 0)
    }
}

private actor MemoryPairingStore: IOSPhoneControlCredentialStoring {
    var data: Data?
    init(data: Data?) { self.data = data }
    func loadPairing() -> Data? { data }
    func savePairing(_ data: Data) throws { self.data = try IOSPhoneControlCredentials.validatedPairing(data) }
    func deletePairing() { data = nil }
}
