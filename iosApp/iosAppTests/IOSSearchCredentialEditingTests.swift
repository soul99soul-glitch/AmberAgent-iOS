import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSearchCredentialEditingTests: XCTestCase {
    func testRestoredServiceCanReceiveAKeyWithoutChangingItsConfiguration() throws {
        let fixture = try SearchCredentialEditingFixture()
        defer { fixture.cleanUp() }
        let previousSelected = fixture.store.snapshot.searchServiceSelected
        let previousEnabled = fixture.store.snapshot.searchEnabledServiceIds.map { $0.description() }

        XCTAssertTrue(fixture.store.savedSearchProviders.isEmpty)
        XCTAssertTrue(fixture.store.searchProviderSupportsAPIKey(serviceId: fixture.serviceID))
        XCTAssertTrue(fixture.store.updateSearchProviderApiKey(
            serviceId: fixture.serviceID, apiKey: "  tvly-replacement-key \n"
        ))

        let updated = try fixture.service(in: fixture.store)
        XCTAssertEqual(updated.id.description(), fixture.serviceID)
        XCTAssertEqual(updated.apiKey, "tvly-replacement-key")
        XCTAssertEqual(updated.depth, "basic")
        XCTAssertEqual(fixture.store.snapshot.searchServiceSelected, previousSelected)
        XCTAssertEqual(fixture.store.snapshot.searchEnabledServiceIds.map { $0.description() }, previousEnabled)
        XCTAssertFalse(previousEnabled.contains(fixture.serviceID), "Updating a key must not enable a disabled service.")
        XCTAssertTrue(fixture.store.savedSearchProviders.isEmpty)
        XCTAssertFalse((fixture.persistedJSON ?? "").contains("tvly-replacement-key"))

        let reloaded = fixture.restartedStore()
        let persistedService = try fixture.service(in: reloaded)
        XCTAssertEqual(persistedService.apiKey, "tvly-replacement-key")
        XCTAssertEqual(persistedService.depth, "basic")
        XCTAssertEqual(reloaded.snapshot.searchServiceSelected, previousSelected)
        XCTAssertEqual(reloaded.snapshot.searchEnabledServiceIds.map { $0.description() }, previousEnabled)
        XCTAssertTrue(reloaded.savedSearchProviders.isEmpty)
    }

    func testFailedKeyWriteDoesNotCommitSnapshotSettingsOrCredentials() throws {
        let fixture = try SearchCredentialEditingFixture(initialKey: "retained-search-key")
        defer { fixture.cleanUp() }
        let previousSnapshot = fixture.snapshotJSON
        let previousPersisted = fixture.persistedJSON
        let previousCredentials = fixture.credentials.values
        let previousRevision = fixture.store.revision
        fixture.credentials.rejectedValue = "uncommitted-search-key"

        XCTAssertFalse(fixture.store.updateSearchProviderApiKey(
            serviceId: fixture.serviceID, apiKey: "uncommitted-search-key"
        ))

        XCTAssertEqual(fixture.snapshotJSON, previousSnapshot)
        XCTAssertEqual(fixture.persistedJSON, previousPersisted)
        XCTAssertEqual(fixture.credentials.values, previousCredentials)
        XCTAssertEqual(fixture.store.revision, previousRevision)
        XCTAssertNotNil(fixture.store.credentialPersistenceError)
        XCTAssertTrue(fixture.store.savedSearchProviders.isEmpty)
        XCTAssertEqual(try fixture.service(in: fixture.restartedStore()).apiKey, "retained-search-key")
    }

    func testBlankReplacementKeepsTheExistingKeyWithoutWriting() throws {
        let fixture = try SearchCredentialEditingFixture(initialKey: "retained-search-key")
        defer { fixture.cleanUp() }
        let previousSnapshot = fixture.snapshotJSON
        let previousPersisted = fixture.persistedJSON
        let previousCredentials = fixture.credentials.values
        let previousWrites = fixture.credentials.writeCount

        XCTAssertFalse(fixture.store.updateSearchProviderApiKey(serviceId: fixture.serviceID, apiKey: " \n\t "))

        XCTAssertEqual(try fixture.service(in: fixture.store).apiKey, "retained-search-key")
        XCTAssertEqual(fixture.snapshotJSON, previousSnapshot)
        XCTAssertEqual(fixture.persistedJSON, previousPersisted)
        XCTAssertEqual(fixture.credentials.values, previousCredentials)
        XCTAssertEqual(fixture.credentials.writeCount, previousWrites)
        XCTAssertTrue(fixture.store.savedSearchProviders.isEmpty)
    }
}

@MainActor
private final class SearchCredentialEditingFixture {
    let suite: String
    let defaults: UserDefaults
    let credentials: SearchCredentialEditingStore
    let store: IOSSharedSettingsStore
    let serviceID: String

    var persistedJSON: String? { defaults.string(forKey: "app.amber.ios.sharedSettingsJson") }
    var snapshotJSON: String { IosSettingsJsonBridge.shared.encode(settings: store.snapshot) }

    init(initialKey: String = "") throws {
        let suite = "SearchCredentialEditing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let credentials = SearchCredentialEditingStore()
        let store = IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: credentials.load,
            storeCredential: credentials.store, deleteCredential: credentials.delete
        )
        let prototype = IosSettingsMutations.shared.buildSearchService(serviceType: "tavily", apiKey: "")
        let service = SearchServiceOptions.TavilyOptions(id: prototype.id, apiKey: initialKey, depth: "basic")
        let serviceID = service.id.description()
        let added = IosSettingsMutations.shared.addSearchServiceAndSelect(settings: store.snapshot, service: service)
        let disabled = IosSettingsMutations.shared.setSearchServiceEnabled(settings: added, id: serviceID, enabled: false)
        XCTAssertTrue(store.restoreSnapshot(disabled))

        self.suite = suite
        self.defaults = defaults
        self.credentials = credentials
        self.store = store
        self.serviceID = serviceID
    }

    func service(in store: IOSSharedSettingsStore) throws -> SearchServiceOptions.TavilyOptions {
        try XCTUnwrap(store.snapshot.searchServices.first {
            $0.id.description() == serviceID
        } as? SearchServiceOptions.TavilyOptions)
    }

    func restartedStore() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: credentials.load,
            storeCredential: credentials.store, deleteCredential: credentials.delete
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class SearchCredentialEditingStore {
    var values: [String: String] = [:]
    var rejectedValue: String?
    var writeCount = 0

    func load(_ key: String) -> String? { values[key] }

    func store(_ key: String, _ value: String) -> Bool {
        writeCount += 1
        guard value != rejectedValue else { return false }
        values[key] = value
        return true
    }

    func delete(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}
