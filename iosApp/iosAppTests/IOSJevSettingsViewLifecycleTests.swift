import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSJevSettingsViewLifecycleTests: XCTestCase {
    func testMountAndUnmountPreserveConfiguredPhoneActions() async throws {
        let suite = "JevSettingsLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = IOSSharedSettingsStore(userDefaults: defaults)
        var fixture = store.jevSettings
        fixture.setPinnedModelVersion("jev-1.13.0")
        fixture.setProviderModel("typesafe-ai/jev-preserved")
        fixture.setMode(.active, for: .phoneActions)
        let scopes = IOSJevUseCase.phoneActions.defaultDataScopes.union([.phoneScreenshots])
        fixture.setScopes(scopes, for: .phoneActions)
        store.updateJevSettings(fixture)
        XCTAssertEqual(fixture.effectiveMode(for: .phoneActions), .active)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let appeared = expectation(description: "Jev settings view appeared")
        let disappeared = expectation(description: "Jev settings view disappeared")
        let content = IOSJevSettingsView(sharedSettings: store)
            .onAppear { appeared.fulfill() }
            .onDisappear { disappeared.fulfill() }
            .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: AnyView(content))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        await fulfillment(of: [appeared], timeout: 2)

        host.rootView = AnyView(EmptyView())
        window.layoutIfNeeded()
        await fulfillment(of: [disappeared], timeout: 2)

        // Reopen the store to detect configuration cleared by page teardown.
        let saved = IOSSharedSettingsStore(userDefaults: defaults).jevSettings
        XCTAssertEqual(saved.pinnedModelVersion, fixture.pinnedModelVersion)
        XCTAssertEqual(saved.providerModel, fixture.providerModel)
        XCTAssertEqual(saved.effectiveMode(for: .phoneActions), .active)
        XCTAssertEqual(saved.allowedScopes(for: .phoneActions), scopes)
    }
}
