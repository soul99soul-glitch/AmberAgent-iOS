import XCTest
@preconcurrency import Shared
@testable import iosApp

final class NovelAppSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentials: MemoryCredentials!

    override func setUp() {
        suiteName = "novel.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        credentials = MemoryCredentials()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> NovelAppSettingsStore {
        NovelAppSettingsStore(defaults: defaults, credentials: credentials)
    }

    private func service(
        _ protocolType: NovelModelProtocol = .openAI,
        key: String = "sk-test",
        models: [String] = ["gpt-test"]
    ) -> NovelModelService {
        var service = NovelModelService()
        service.name = "Test"
        service.protocolType = protocolType
        service.baseURL = protocolType.defaultBaseURL
        service.apiKey = key
        service.models = models.map { NovelModelEntry(modelID: $0) }
        return service
    }

    @discardableResult
    private func save(
        _ store: NovelAppSettingsStore,
        services: [NovelModelService],
        defaultModelID: UUID? = nil,
        search: [NovelSearchService]? = nil,
        webSearch: Bool = true
    ) -> String? {
        store.save(
            services: services,
            defaultModelID: defaultModelID,
            searchServices: search ?? store.searchServices,
            selectedSearchID: (search ?? store.searchServices).first?.id,
            resultSize: 8,
            webSearchEnabled: webSearch
        )
    }

    func testFreshStoreHasNoUsableModel() {
        let store = makeStore()
        XCTAssertFalse(store.hasUsableModel)
        XCTAssertTrue(store.snapshot.providers.isEmpty)
    }

    func testSavePublishesProviderModelAndDefaultModel() throws {
        let store = makeStore()
        let saved = service(models: ["gpt-a", "gpt-b"])
        XCTAssertNil(save(store, services: [saved], defaultModelID: saved.models[1].id))

        XCTAssertEqual(store.revision, 1)
        XCTAssertTrue(store.hasUsableModel)
        let current = try XCTUnwrap(store.snapshot.getCurrentChatModel())
        XCTAssertEqual(current.modelId, "gpt-b")
        let provider = try XCTUnwrap(store.snapshot.providers.first as? ProviderSetting.OpenAI)
        XCTAssertEqual(provider.apiKey, "sk-test")
        XCTAssertEqual(provider.models.map(\.modelId), ["gpt-a", "gpt-b"])
        XCTAssertEqual(provider.authMode, .apiKey)
    }

    func testMissingDefaultFallsBackToFirstEnabledModel() throws {
        let store = makeStore()
        let saved = service(models: ["first", "second"])
        XCTAssertNil(save(store, services: [saved], defaultModelID: UUID()))
        XCTAssertEqual(store.defaultModelID, saved.models[0].id)
        XCTAssertEqual(try XCTUnwrap(store.snapshot.getCurrentChatModel()).modelId, "first")
    }

    func testDisablingTheDefaultServiceFallsBackToAnEnabledModel() throws {
        let store = makeStore()
        var first = service(models: ["old-default"])
        let second = service(models: ["still-on"])
        XCTAssertNil(save(store, services: [first, second], defaultModelID: first.models[0].id))

        first.enabled = false
        XCTAssertNil(save(store, services: [first, second], defaultModelID: store.defaultModelID))

        XCTAssertEqual(store.defaultModelID, second.models[0].id)
        XCTAssertTrue(store.hasUsableModel)
        XCTAssertEqual(try XCTUnwrap(store.snapshot.getCurrentChatModel()).modelId, "still-on")
    }

    func testFailedCredentialReadBlocksSavesSoKeysAreNotWiped() {
        let store = makeStore()
        XCTAssertNil(save(store, services: [service(key: "sk-keep")]))

        let failing = FailingReadCredentials(backing: credentials)
        let restarted = NovelAppSettingsStore(defaults: defaults, credentials: failing)
        XCTAssertNotNil(restarted.loadErrorMessage)
        XCTAssertNotNil(save(restarted, services: restarted.services))
        XCTAssertTrue(credentials.values.values.contains("sk-keep"))
    }

    func testBlankBaseURLUsesTheOfficialEndpoint() throws {
        let store = makeStore()
        var blank = service(.claude, models: ["claude-x"])
        blank.baseURL = "  "
        XCTAssertNil(save(store, services: [blank]))
        let provider = try XCTUnwrap(store.snapshot.providers.first as? ProviderSetting.Claude)
        XCTAssertEqual(provider.baseUrl, NovelModelProtocol.claude.defaultBaseURL)
    }

    func testBaseURLFollowsTheRequestEndpointPolicy() {
        let store = makeStore()
        var lan = service()
        lan.baseURL = "http://192.168.1.20:11434/v1"
        XCTAssertNil(save(store, services: [lan]))

        var hostname = service()
        hostname.baseURL = "http://localhost:11434/v1"
        XCTAssertNotNil(save(store, services: [hostname]))
        XCTAssertEqual(store.services.first?.baseURL, "http://192.168.1.20:11434/v1")
    }

    func testUnreadableSettingsErrorClearsAfterASuccessfulSave() {
        defaults.set(Data("not json".utf8), forKey: NovelAppSettingsStore.persistenceKey)
        let store = makeStore()
        XCTAssertNotNil(store.loadErrorMessage)
        XCTAssertNil(save(store, services: [service()]))
        XCTAssertNil(store.loadErrorMessage)
    }

    func testDefaultFallsBackToAServiceThatHasAKey() throws {
        let store = makeStore()
        let keyless = service(key: "", models: ["no-key"])
        let keyed = service(key: "sk", models: ["has-key"])
        XCTAssertNil(save(store, services: [keyless, keyed]))
        XCTAssertEqual(try XCTUnwrap(store.snapshot.getCurrentChatModel()).modelId, "has-key")
    }

    func testServiceWithoutKeyIsNotUsable() {
        let store = makeStore()
        XCTAssertNil(save(store, services: [service(key: "")]))
        XCTAssertFalse(store.hasUsableModel)
    }

    func testClaudeAndGeminiMapToTheirProviderTypes() {
        let store = makeStore()
        XCTAssertNil(save(store, services: [service(.claude, models: ["claude-x"]), service(.gemini, models: ["gemini-x"])]))
        XCTAssertTrue(store.snapshot.providers[0] is ProviderSetting.Claude)
        XCTAssertTrue(store.snapshot.providers[1] is ProviderSetting.Google)
    }

    func testCredentialsLiveOnlyInCredentialStorageAndReloadAfterRestart() throws {
        let store = makeStore()
        XCTAssertNil(save(store, services: [service(key: "sk-secret")]))

        let persisted = try XCTUnwrap(defaults.data(forKey: NovelAppSettingsStore.persistenceKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("sk-secret"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.services.first?.apiKey, "sk-secret")
        XCTAssertTrue(reloaded.hasUsableModel)
    }

    func testInvalidServiceIsRejectedWithoutChangingState() {
        let store = makeStore()
        XCTAssertNil(save(store, services: [service()]))
        var broken = service()
        broken.baseURL = "not a url"
        XCTAssertNotNil(save(store, services: [broken]))
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.services.count, 1)
        XCTAssertEqual(store.services.first?.baseURL, NovelModelProtocol.openAI.defaultBaseURL)
    }

    func testRemovingServiceDeletesItsCredential() {
        let store = makeStore()
        let saved = service(key: "sk-gone")
        XCTAssertNil(save(store, services: [saved]))
        XCTAssertTrue(credentials.values.values.contains("sk-gone"))
        XCTAssertNil(save(store, services: []))
        XCTAssertFalse(credentials.values.values.contains("sk-gone"))
    }

    func testWebSearchToggleAndSearchKeyReachSnapshot() throws {
        let store = makeStore()
        var tavily = NovelSearchService()
        tavily.kind = .tavily
        tavily.apiKey = "tv-key"
        XCTAssertNil(save(store, services: [service()], search: [tavily], webSearch: false))

        XCTAssertFalse(store.snapshot.enableWebSearch)
        XCTAssertEqual(store.snapshot.searchCommonOptions.resultSize, 8)
        let saved = try XCTUnwrap(store.snapshot.searchServices.first as? SearchServiceOptions.TavilyOptions)
        XCTAssertEqual(saved.apiKey, "tv-key")
    }
}

private final class FailingReadCredentials: NovelCredentialStorage {
    let backing: MemoryCredentials
    init(backing: MemoryCredentials) { self.backing = backing }
    func read(account: String) throws -> String? { throw NSError(domain: "keychain", code: -25308) }
    func write(_ value: String, account: String) throws { try backing.write(value, account: account) }
}

final class MemoryCredentials: NovelCredentialStorage {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func write(_ value: String, account: String) throws {
        if value.isEmpty { values[account] = "" } else { values[account] = value }
    }
}
