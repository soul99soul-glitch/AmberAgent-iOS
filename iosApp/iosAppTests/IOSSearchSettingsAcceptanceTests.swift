import SwiftUI
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSearchSettingsAcceptanceTests: XCTestCase {
    func testChoosingDefaultChangesRouteWithoutEnablingADisabledService() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = context.store
        store.addSearchProvider(name: "Tavily", apiKey: "tavily-test", serviceType: "tavily")
        let tavilyID = try XCTUnwrap(store.snapshot.searchServices.last).id.description()
        store.addSearchProvider(name: "Brave", apiKey: "brave-test", serviceType: "brave")
        let braveID = try XCTUnwrap(store.snapshot.searchServices.last).id.description()

        store.selectSearchProvider(serviceId: tavilyID)

        XCTAssertEqual(IOSSearchExecutor.searchProviderSelection(settings: store.snapshot).route, .tavilyAPI)
        XCTAssertTrue(try XCTUnwrap(store.configuredSearchProviders.first { $0.id == tavilyID }).selected)

        store.setSearchProviderEnabled(serviceId: tavilyID, enabled: false)
        store.selectSearchProvider(serviceId: braveID)
        let enabledBeforeSelection = store.snapshot.searchEnabledServiceIds.map { $0.description() }

        store.selectSearchProvider(serviceId: tavilyID)

        let disabledDefault = try XCTUnwrap(store.configuredSearchProviders.first { $0.id == tavilyID })
        XCTAssertTrue(disabledDefault.selected)
        XCTAssertFalse(disabledDefault.enabled)
        XCTAssertEqual(store.snapshot.searchEnabledServiceIds.map { $0.description() }, enabledBeforeSelection)
        XCTAssertNotEqual(IOSSearchExecutor.searchProviderSelection(settings: store.snapshot).route, .tavilyAPI)
        let restarted = context.makeStore()
        XCTAssertTrue(try XCTUnwrap(restarted.configuredSearchProviders.first { $0.id == tavilyID }).selected)
        XCTAssertFalse(try XCTUnwrap(restarted.configuredSearchProviders.first { $0.id == tavilyID }).enabled)
    }

    func testReorderingKeepsExplicitDefaultAndChangesUnavailableDefaultFallbackOrder() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = context.store
        store.addSearchProvider(name: "Tavily", apiKey: "tavily-test", serviceType: "tavily")
        let tavilyID = try XCTUnwrap(store.snapshot.searchServices.last).id.description()
        store.addSearchProvider(name: "Brave", apiKey: "brave-test", serviceType: "brave")
        let braveID = try XCTUnwrap(store.snapshot.searchServices.last).id.description()
        store.selectSearchProvider(serviceId: braveID)
        let tavilyIndex = try XCTUnwrap(store.configuredSearchProviders.first { $0.id == tavilyID }).index

        store.moveSearchProvider(fromIndex: tavilyIndex, toIndex: 0)

        XCTAssertEqual(store.configuredSearchProviders.first?.id, tavilyID)
        XCTAssertTrue(try XCTUnwrap(store.configuredSearchProviders.first { $0.id == braveID }).selected)
        XCTAssertEqual(IOSSearchExecutor.searchProviderSelection(settings: store.snapshot).route, .braveAPI)

        store.setSearchProviderEnabled(serviceId: braveID, enabled: false)

        let fallback = IOSSearchExecutor.searchProviderSelection(settings: store.snapshot)
        XCTAssertEqual(fallback.route, .tavilyAPI)
        XCTAssertEqual(fallback.serviceId, tavilyID)
        XCTAssertTrue(try XCTUnwrap(store.configuredSearchProviders.first { $0.id == braveID }).selected,
                      "Selecting a fallback must not rewrite the user's default")
    }

    /// Captures production pages for independent visual review. Geometry checks
    /// detect horizontal overflow; they do not establish visual correctness.
    func testSearchPagesAtRegularNarrowAndAccessibilityWidths() async throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.store.addSearchProvider(
            name: "资料研究与长篇网页检索使用的 Tavily 搜索服务",
            apiKey: "tavily-visual-test", serviceType: "tavily"
        )
        context.store.addSearchProvider(
            name: "用于核对英文与中文资料来源的 Brave 搜索服务",
            apiKey: "brave-visual-test", serviceType: "brave"
        )

        for (name, width, type) in [
            ("regular-393", CGFloat(393), DynamicTypeSize.large),
            ("narrow-320", CGFloat(320), DynamicTypeSize.large),
            ("accessibility3-320", CGFloat(320), DynamicTypeSize.accessibility3),
        ] {
            try await capturePages(
                SearchServicesView(sharedSettings: context.store)
                    .environment(RouterPath())
                    .defaultAppStorage(context.defaults),
                width: width, type: type, name: "search-services-\(name)"
            )
            try await capturePages(
                SearchProviderView(sharedSettings: context.store)
                    .defaultAppStorage(context.defaults),
                width: width, type: type, name: "search-providers-\(name)"
            )
            let provider = try XCTUnwrap(context.store.configuredSearchProviders.last)
            try await capturePages(
                IOSSearchProviderCredentialEditor(sharedSettings: context.store, provider: provider)
                    .defaultAppStorage(context.defaults),
                width: width, type: type, name: "search-credentials-\(name)"
            )
        }
    }

    private func capturePages<Content: View>(
        _ root: Content, width: CGFloat, type: DynamicTypeSize, name: String
    ) async throws {
        let fixture = try SwiftModularizationHostingFixture(root: root, width: width, height: 900, type: type)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.mainScrollView())
        fixture.assertNoHorizontalOverflow(scroll)
        let lastOrigin = max(0, scroll.contentSize.height - scroll.bounds.height)
        let pageStride = max(1, scroll.bounds.height * 0.75)
        let pageCount = Int(ceil(lastOrigin / pageStride)) + 1

        for page in 0..<pageCount {
            let origin = min(CGFloat(page) * pageStride, lastOrigin)
            if page > 0 {
                scroll.scrollRectToVisible(
                    CGRect(x: 0, y: origin, width: scroll.bounds.width, height: scroll.bounds.height),
                    animated: false
                )
            }
            try await fixture.settle()
            fixture.assertNoHorizontalOverflow(scroll)
            try fixture.capturePNG("\(name)-page-\(String(format: "%02d", page + 1))", in: self)
        }
    }

    private func makeContext() throws -> SearchSettingsAcceptanceContext {
        let suite = "SearchSettingsAcceptance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return SearchSettingsAcceptanceContext(suite: suite, defaults: defaults)
    }
}

@MainActor
private final class SearchSettingsAcceptanceContext {
    let suite: String
    let defaults: UserDefaults
    private let credentials = SearchSettingsAcceptanceCredentials()
    lazy var store = makeStore()

    init(suite: String, defaults: UserDefaults) {
        self.suite = suite
        self.defaults = defaults
    }

    func makeStore() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: credentials.load,
            storeCredential: credentials.store, deleteCredential: credentials.delete
        )
    }
}

private final class SearchSettingsAcceptanceCredentials {
    private var values: [String: String] = [:]
    func load(_ key: String) -> String? { values[key] }
    func store(_ key: String, _ value: String) -> Bool {
        values[key] = value
        return true
    }
    func delete(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}
