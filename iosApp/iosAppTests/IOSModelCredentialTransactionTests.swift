import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSModelCredentialTransactionTests: XCTestCase {
    func testFailedModelHeaderUpdateReturnsNilAndPreservesCommittedConfiguration() throws {
        let fixture = try ModelCredentialFixture()
        defer { fixture.cleanUp() }
        let previousJSON = fixture.persistedJSON
        let previousSnapshot = fixture.snapshotJSON
        let previousRevision = fixture.store.revision
        let previousCredentials = fixture.credentials.loadedValues
        fixture.credentials.rejectedValue = "Bearer rejected-replacement"

        let result = fixture.store.upsertProviderChatModel(
            providerId: fixture.providerID,
            modelUuid: fixture.firstModel.id.description(),
            modelId: fixture.firstModel.modelId,
            displayName: "Uncommitted rename",
            contextWindowTokens: nil,
            modelType: .chat,
            headers: [("Authorization", "Bearer rejected-replacement")]
        )

        XCTAssertNil(result, "An uncommitted model must not be offered to callers for selection.")
        XCTAssertEqual(fixture.snapshotJSON, previousSnapshot)
        XCTAssertEqual(fixture.persistedJSON, previousJSON)
        XCTAssertEqual(fixture.store.revision, previousRevision)
        XCTAssertNotNil(fixture.store.credentialPersistenceError)
        XCTAssertEqual(fixture.credentials.loadedValues, previousCredentials)
        try fixture.assertHeadersSurviveRestart()
    }

    func testFailedModelRemovalKeepsBothCredentialsAcrossRestart() throws {
        let fixture = try ModelCredentialFixture()
        defer { fixture.cleanUp() }

        try assertRejectedMutationPreservesCredentials(fixture) {
            fixture.store.removeProviderChatModel(
                providerId: fixture.providerID,
                modelUuid: fixture.firstModel.id.description()
            )
        }
    }

    func testFailedCatalogReplacementKeepsBothCredentialsAcrossRestart() throws {
        let fixture = try ModelCredentialFixture()
        defer { fixture.cleanUp() }

        try assertRejectedMutationPreservesCredentials(fixture) {
            fixture.store.updateProviderChatModels(
                providerId: fixture.providerID,
                models: [(fixture.secondModel.modelId, fixture.secondModel.displayName)]
            )
        }
    }

    func testSuccessfulRemovalDeletesOnlyRemovedCredentialAndRetainsReindexedHeader() throws {
        let fixture = try ModelCredentialFixture()
        defer { fixture.cleanUp() }
        let removedKeys = fixture.credentials.loadedValues.keys.filter {
            $0.contains(fixture.firstModel.id.description())
        }
        XCTAssertFalse(removedKeys.isEmpty)

        let result = fixture.store.removeProviderChatModel(
            providerId: fixture.providerID,
            modelUuid: fixture.firstModel.id.description()
        )

        let committed = try XCTUnwrap(result)
        XCTAssertFalse(committed.models.contains { $0.id == fixture.firstModel.id })
        XCTAssertTrue(removedKeys.allSatisfy { IOSCredentialSideTable.load(key: $0) == nil })
        let restartedProvider = try XCTUnwrap(fixture.restartedStore().snapshot.providers.first {
            $0.id.description() == fixture.providerID
        })
        XCTAssertFalse(restartedProvider.models.contains { $0.id == fixture.firstModel.id })
        let remaining = try XCTUnwrap(restartedProvider.models.first { $0.id == fixture.secondModel.id })
        XCTAssertEqual(remaining.customHeaders.first?.value, ModelCredentialFixture.secondSecret)
    }

    private func assertRejectedMutationPreservesCredentials(
        _ fixture: ModelCredentialFixture,
        mutation: () -> ProviderSetting?
    ) throws {
        let previousJSON = fixture.persistedJSON
        let previousSnapshot = fixture.snapshotJSON
        let previousRevision = fixture.store.revision
        let previousCredentials = fixture.credentials.loadedValues
        // Removing the first model shifts the second model's indexed credential
        // ref. Reject only that migration, after both original headers were saved.
        fixture.credentials.rejectedValue = ModelCredentialFixture.secondSecret

        let result = mutation()

        XCTAssertNil(result)
        XCTAssertEqual(fixture.snapshotJSON, previousSnapshot)
        XCTAssertEqual(fixture.persistedJSON, previousJSON)
        XCTAssertEqual(fixture.store.revision, previousRevision)
        XCTAssertNotNil(fixture.store.credentialPersistenceError)
        XCTAssertEqual(fixture.credentials.loadedValues, previousCredentials)
        try fixture.assertHeadersSurviveRestart()
    }
}

@MainActor
private final class ModelCredentialFixture {
    static let firstSecret = "Bearer retained-first"
    static let secondSecret = "Bearer retained-second"
    let suiteName: String
    let defaults: UserDefaults
    let credentials: ModelCredentialKeychain
    let store: IOSSharedSettingsStore
    let providerID: String
    let firstModel: Model
    let secondModel: Model

    var persistedJSON: String? { defaults.string(forKey: "app.amber.ios.sharedSettingsJson") }
    var snapshotJSON: String { IosSettingsJsonBridge.shared.encode(settings: store.snapshot) }

    init() throws {
        let suiteName = "IOSModelCredentialTransactionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let credentials = ModelCredentialKeychain()
        let store = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: credentials.load,
            storeCredential: credentials.store,
            deleteCredential: credentials.delete
        )
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Credential transaction", apiKey: "", baseUrl: "https://example.com/v1",
            modelName: "First", modelId: "credential-first"
        )
        let providerID = provider.id.description()
        store.addProvider(provider)
        let initialModel = try XCTUnwrap(provider.models.first)
        let withFirst = try XCTUnwrap(store.upsertProviderChatModel(
            providerId: providerID, modelUuid: initialModel.id.description(),
            modelId: initialModel.modelId, displayName: "First", contextWindowTokens: nil,
            modelType: .chat, headers: [("Authorization", Self.firstSecret)]
        ))
        let firstModel = try XCTUnwrap(withFirst.models.first { $0.modelId == "credential-first" })
        let withSecond = try XCTUnwrap(store.upsertProviderChatModel(
            providerId: providerID, modelUuid: nil,
            modelId: "credential-second", displayName: "Second", contextWindowTokens: nil,
            modelType: .chat, headers: [("Authorization", Self.secondSecret)]
        ))
        let secondModel = try XCTUnwrap(withSecond.models.first { $0.modelId == "credential-second" })
        self.suiteName = suiteName
        self.defaults = defaults
        self.credentials = credentials
        self.store = store
        self.providerID = providerID
        self.firstModel = firstModel
        self.secondModel = secondModel
    }

    func restartedStore() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: credentials.load,
            storeCredential: credentials.store,
            deleteCredential: credentials.delete
        )
    }

    func assertHeadersSurviveRestart(file: StaticString = #filePath, line: UInt = #line) throws {
        let provider = try XCTUnwrap(restartedStore().snapshot.providers.first {
            $0.id.description() == providerID
        }, file: file, line: line)
        XCTAssertEqual(provider.models.first { $0.id == firstModel.id }?.customHeaders.first?.value,
                       Self.firstSecret, file: file, line: line)
        XCTAssertEqual(provider.models.first { $0.id == secondModel.id }?.customHeaders.first?.value,
                       Self.secondSecret, file: file, line: line)
    }

    func cleanUp() {
        credentials.cleanUp()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Real, randomly provider-scoped entries also detect premature deletion that
/// bypasses the injected transaction closures. Writes use the existing injection
/// seam to reject the required credential migration.
private final class ModelCredentialKeychain {
    var rejectedValue: String?
    private var keys = Set<String>()

    var loadedValues: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            IOSCredentialSideTable.load(key: key).map { (key, $0) }
        })
    }

    func load(_ key: String) -> String? { IOSCredentialSideTable.load(key: key) }

    func store(_ key: String, _ value: String) -> Bool {
        guard value != rejectedValue else { return false }
        keys.insert(key)
        return IOSCredentialSideTable.store(key: key, value: value)
    }

    func delete(_ key: String) -> Bool { IOSCredentialSideTable.delete(key: key) }

    func cleanUp() {
        keys.forEach { IOSCredentialSideTable.delete(key: $0) }
    }
}
