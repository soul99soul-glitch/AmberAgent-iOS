import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSearchSettingsTests: XCTestCase {
    func testJinaSearchConfigurationRequiresAPIKey() throws {
        let service = IosSettingsMutations.shared.buildSearchService(serviceType: "jina", apiKey: "")
        let type = try XCTUnwrap(SearchProviderType(service: service))

        XCTAssertEqual(type, .jina)
        XCTAssertTrue(type.requiresAPIKey)
        XCTAssertFalse(SearchProviderType.bing.requiresAPIKey)
    }

    func testRestoredServicesCanBeIdentifiedDisabledAndDeletedWithoutLocalMirror() throws {
        try withStores { source, restored, defaults in
            source.addSearchProvider(name: "My Brave", serviceType: "brave")
            let sourceService = try XCTUnwrap(source.snapshot.searchServices.last)
            let serviceId = sourceService.id.description()

            XCTAssertTrue(restored.restoreSnapshot(source.snapshot))
            XCTAssertTrue(restored.savedSearchProviders.isEmpty)
            let displayed = try XCTUnwrap(restored.configuredSearchProviders.first { $0.id == serviceId })
            XCTAssertEqual(displayed.name, "Brave")
            XCTAssertEqual(displayed.typeLabel, "brave")
            XCTAssertTrue(displayed.selected)
            XCTAssertTrue(displayed.enabled)

            restored.setSearchProviderEnabled(serviceId: serviceId, enabled: false)
            XCTAssertFalse(try XCTUnwrap(restored.configuredSearchProviders.first { $0.id == serviceId }).enabled)
            XCTAssertTrue(restored.removeSearchProvider(serviceId: serviceId))
            XCTAssertFalse(restored.snapshot.searchServices.contains { $0.id.description() == serviceId })

            let reloaded = makeStore(defaults: defaults)
            XCTAssertFalse(reloaded.configuredSearchProviders.contains { $0.id == serviceId })
        }
    }

    func testCustomNamesEnhanceSnapshotServicesAndDoNotCreateOrphanRows() throws {
        try withStore { store, _ in
            store.addSearchProvider(name: "Work Exa", serviceType: "exa")
            let id = try XCTUnwrap(store.snapshot.searchServices.last).id.description()
            store.savedSearchProviders += [[
                "serviceId": UUID().uuidString,
                "name": "Orphan mirror",
                "serviceType": "tavily"
            ]]

            XCTAssertEqual(store.configuredSearchProviders.count, store.snapshot.searchServices.count)
            XCTAssertEqual(try XCTUnwrap(store.configuredSearchProviders.first { $0.id == id }).name, "Work Exa")
            XCTAssertFalse(store.configuredSearchProviders.contains { $0.name == "Orphan mirror" })

            XCTAssertTrue(store.removeSearchProvider(serviceId: id))
            XCTAssertFalse(store.savedSearchProviders.contains { $0["serviceId"] == id })
        }
    }

    func testChoosingDefaultPersistsAndReorderingKeepsThatServiceSelected() throws {
        try withStore { store, defaults in
            store.addSearchProvider(name: "Tavily", serviceType: "tavily")
            let tavilyId = try XCTUnwrap(store.snapshot.searchServices.last).id.description()
            store.addSearchProvider(name: "Brave", serviceType: "brave")

            store.selectSearchProvider(serviceId: tavilyId)
            store.moveSearchProvider(fromIndex: store.snapshot.searchServices.count - 1, toIndex: 0)

            let selected = try XCTUnwrap(store.configuredSearchProviders.first { $0.selected })
            XCTAssertEqual(selected.id, tavilyId)
            let reloaded = makeStore(defaults: defaults)
            XCTAssertEqual(try XCTUnwrap(reloaded.configuredSearchProviders.first { $0.selected }).id, tavilyId)
        }
    }

    func testIOSResultSizeClampsWritesAndDisplaysEffectiveLimitAfterRestore() throws {
        try withStore { store, defaults in
            for (input, expected) in [(-1, 1), (1, 1), (5, 5), (10, 10), (50, 10)] {
                store.setSearchResultSize(input)
                XCTAssertEqual(store.searchResultSize, expected)
                XCTAssertEqual(Int(store.snapshot.searchCommonOptions.resultSize), expected)
            }
            let restored = IosSettingsMutations.shared.setSearchResultSize(settings: store.snapshot, size: 50)
            XCTAssertTrue(store.restoreSnapshot(restored))
            XCTAssertEqual(Int(store.snapshot.searchCommonOptions.resultSize), 50, "Keep the shared settings format compatible.")
            XCTAssertEqual(store.searchResultSize, 10)
            XCTAssertEqual(makeStore(defaults: defaults).searchResultSize, 10)
        }
    }

    func testBingConfigurationNamesTheAggregateControlledByTheMasterSwitch() throws {
        try withStore { store, _ in
            let builtin = try XCTUnwrap(store.configuredSearchProviders.first { $0.isFreeAggregate })
            XCTAssertEqual(builtin.name, IOSFreeSearchAggregator.providerName)
            XCTAssertEqual(builtin.typeLabel, "bing_local")
        }
    }

    private func withStore(_ body: (IOSSharedSettingsStore, UserDefaults) throws -> Void) throws {
        let suite = "SearchSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(makeStore(defaults: defaults), defaults)
    }

    private func withStores(_ body: (IOSSharedSettingsStore, IOSSharedSettingsStore, UserDefaults) throws -> Void) throws {
        try withStore { source, _ in
            try withStore { restored, defaults in
                try body(source, restored, defaults)
            }
        }
    }

    private func makeStore(defaults: UserDefaults) -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { _ in nil },
            storeCredential: { _, _ in true },
            deleteCredential: { _ in true }
        )
    }
}
