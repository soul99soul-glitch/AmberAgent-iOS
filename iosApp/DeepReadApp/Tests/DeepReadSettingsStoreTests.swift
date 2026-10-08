import XCTest
@preconcurrency import Shared
@testable import AmberDeepRead

@MainActor
final class DeepReadSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var credentials: FakeCredentials!

    override func setUp() async throws {
        suiteName = "DeepReadSettingsStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
        credentials = FakeCredentials()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testModelAndSearchCredentialsSurviveRestartWithoutPlaintextDefaults() throws {
        let store = makeStore()
        var model = DeepReadModelConfiguration()
        model.apiKey = "model-secret-sentinel"
        model.baseURL = "https://my.example/v1"
        model.useResponsesAPI = true
        store.models = [model]
        store.selectedModelID = model.id
        var search = DeepReadSearchConfiguration()
        search.kind = .tavily
        search.apiKey = "search-secret-sentinel"
        store.searchServices = [search]
        store.selectedSearchID = search.id
        XCTAssertTrue(store.save(), store.errorMessage ?? "")

        let data = try XCTUnwrap(defaults.data(forKey: DeepReadSettingsStore.persistenceKey))
        let persisted = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(persisted.contains("model-secret-sentinel"))
        XCTAssertFalse(persisted.contains("search-secret-sentinel"))
        let reloaded = makeStore()
        let resolved = try XCTUnwrap(reloaded.resolvedModel)
        let provider = try XCTUnwrap(resolved.provider as? ProviderSetting.OpenAI)
        XCTAssertEqual(provider.apiKey, model.apiKey)
        XCTAssertEqual(provider.authMode, .apiKey)
        XCTAssertEqual(provider.baseUrl, model.baseURL)
        XCTAssertTrue(provider.useResponseApi)
        XCTAssertEqual(resolved.model.modelId, model.modelID)
        XCTAssertEqual((reloaded.searchSettings.searchServices.first as? SearchServiceOptions.TavilyOptions)?.apiKey,
                       search.apiKey)
    }

    func testAllSharedSearchKindsKeepTypedConfigurationAndSelectedEnabledIdentity() throws {
        let store = makeStore()
        store.searchServices = DeepReadSearchKind.allCases.map { kind in
            var service = DeepReadSearchConfiguration()
            service.kind = kind
            service.enabled = kind != .exa
            service.apiKey = "search-key"
            if kind == .searxng {
                service.fields = ["url": "https://search.example", "engines": "bing", "username": "reader"]
                service.password = "searxng-password-sentinel"
            }
            if kind == .tavily { service.fields = ["depth": "basic"] }
            return service
        }
        let tavilyIndex = try XCTUnwrap(store.searchServices.firstIndex { $0.kind == .tavily })
        store.selectedSearchID = store.searchServices[tavilyIndex].id
        XCTAssertTrue(store.save(), store.errorMessage ?? "")
        let snapshot = makeStore().searchSettings
        XCTAssertEqual(snapshot.searchServices.count, DeepReadSearchKind.allCases.count)
        XCTAssertEqual(Int(snapshot.searchServiceSelected), tavilyIndex)
        XCTAssertEqual(snapshot.searchEnabledServiceIds.count, DeepReadSearchKind.allCases.count - 1)
        XCTAssertEqual((snapshot.searchServices[tavilyIndex] as? SearchServiceOptions.TavilyOptions)?.depth, "basic")
        let searx = try XCTUnwrap(snapshot.searchServices.first { $0 is SearchServiceOptions.SearXNGOptions }
                                as? SearchServiceOptions.SearXNGOptions)
        XCTAssertEqual(searx.password, "searxng-password-sentinel")
        XCTAssertEqual(searx.url, "https://search.example")
        let text = String(decoding: try XCTUnwrap(defaults.data(forKey: DeepReadSettingsStore.persistenceKey)), as: UTF8.self)
        XCTAssertFalse(text.contains("searxng-password-sentinel"))
    }

    func testSearchAndReadingControlsPersistAndReachSharedRuntime() {
        let store = makeStore()
        store.resultSize = 23
        store.searchBuiltinDuckDuckGoEnabled = false
        store.searchBuiltinBingEnabled = false
        store.searchBuiltinJinaEnabled = false
        store.searchBuiltinWikipediaEnabled = false
        store.searchBuiltinHackerNewsEnabled = false
        store.searchGoogleWebViewFallbackEnabled = false
        store.fontScale = 1.35
        store.fontMode = "system"
        store.templateId = "custom:reader"
        XCTAssertTrue(store.save(), store.errorMessage ?? "")
        let reloaded = makeStore()
        let settings = reloaded.searchSettings
        XCTAssertEqual(settings.searchCommonOptions.resultSize, 23)
        XCTAssertFalse(settings.searchBuiltinDuckDuckGoEnabled)
        XCTAssertFalse(settings.searchBuiltinBingEnabled)
        XCTAssertFalse(settings.searchBuiltinJinaEnabled)
        XCTAssertFalse(settings.searchBuiltinWikipediaEnabled)
        XCTAssertFalse(settings.searchBuiltinHackerNewsEnabled)
        XCTAssertFalse(settings.searchGoogleWebViewFallbackEnabled)
        XCTAssertEqual(reloaded.fontScale, 1.35)
        XCTAssertEqual(reloaded.fontMode, "system")
        XCTAssertEqual(reloaded.templateId, "custom:reader")
    }

    func testClaudeUsesRealSharedProviderWithAPIKeyAndPromptCaching() throws {
        let store = makeStore()
        var model = DeepReadModelConfiguration()
        model.protocolType = .claude
        model.baseURL = "https://api.anthropic.com/v1"
        model.modelID = "test-claude"
        model.apiKey = "test-key"
        model.promptCaching = true
        store.models = [model]
        store.selectedModelID = model.id
        XCTAssertTrue(store.save(), store.errorMessage ?? "")
        let resolved = try XCTUnwrap(makeStore().resolvedModel)
        let provider = try XCTUnwrap(resolved.provider as? ProviderSetting.Claude)
        XCTAssertEqual(provider.apiKey, "test-key")
        XCTAssertTrue(provider.promptCaching)
        XCTAssertEqual(resolved.model.modelId, "test-claude")
    }

    func testMissingKeyAndDisabledModelCannotResolveGenerationProvider() {
        let store = makeStore()
        var model = DeepReadModelConfiguration()
        store.models = [model]
        store.selectedModelID = model.id
        XCTAssertTrue(store.save())
        XCTAssertNil(store.resolvedModel)
        model.apiKey = "key"
        model.enabled = false
        store.models = [model]
        XCTAssertTrue(store.save())
        XCTAssertNil(store.resolvedModel)
    }

    func testPartialCredentialWriteFailurePreservesPreviouslySavedSecretsAcrossRestart() throws {
        let store = makeStore()
        var first = DeepReadModelConfiguration()
        first.apiKey = "previous-key"
        store.models = [first]
        store.selectedModelID = first.id
        XCTAssertTrue(store.save())
        let previousData = defaults.data(forKey: DeepReadSettingsStore.persistenceKey)
        store.models[0].apiKey = "unsaved-key"
        var second = DeepReadModelConfiguration()
        second.apiKey = "second-key"
        store.models.append(second)
        credentials.failOnWriteNumber = credentials.writeCount + 2
        XCTAssertFalse(store.save())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(defaults.data(forKey: DeepReadSettingsStore.persistenceKey), previousData)
        XCTAssertEqual((store.resolvedModel?.provider as? ProviderSetting.OpenAI)?.apiKey, "previous-key")
        let reloaded = makeStore()
        XCTAssertEqual((reloaded.resolvedModel?.provider as? ProviderSetting.OpenAI)?.apiKey, "previous-key")
        XCTAssertEqual(reloaded.models.count, 1)
    }

    func testCredentialReadFailureIsVisibleAndBlocksAccidentalBlankOverwrite() {
        let store = makeStore()
        var model = DeepReadModelConfiguration()
        model.apiKey = "retained-key"
        store.models = [model]
        store.selectedModelID = model.id
        XCTAssertTrue(store.save())
        let oldData = defaults.data(forKey: DeepReadSettingsStore.persistenceKey)
        credentials.readFailure = true
        let reloaded = makeStore()
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertFalse(reloaded.save())
        XCTAssertEqual(defaults.data(forKey: DeepReadSettingsStore.persistenceKey), oldData)
        credentials.readFailure = false
        reloaded.reloadCredentials()
        XCTAssertNil(reloaded.errorMessage, "a successful retry clears the failure")
        XCTAssertEqual((reloaded.resolvedModel?.provider as? ProviderSetting.OpenAI)?.apiKey, "retained-key",
                       "generation can use the reloaded key without another save")
        XCTAssertTrue(reloaded.save())
        XCTAssertEqual((reloaded.resolvedModel?.provider as? ProviderSetting.OpenAI)?.apiKey, "retained-key")
    }

    private func makeStore() -> DeepReadSettingsStore {
        DeepReadSettingsStore(defaults: defaults, credentials: credentials)
    }

    private final class FakeCredentials: DeepReadCredentialStorage {
        var values: [String: String] = [:]
        var readFailure = false
        var failOnWriteNumber: Int?
        var writeCount = 0
        func read(account: String) throws -> String? {
            if readFailure { throw FakeError.unavailable }
            return values[account]
        }
        func write(_ value: String, account: String) throws {
            writeCount += 1
            if writeCount == failOnWriteNumber { throw FakeError.unavailable }
            if value.isEmpty { values.removeValue(forKey: account) }
            else { values[account] = value }
        }
        enum FakeError: Error { case unavailable }
    }
}
