import XCTest
import SwiftUI
@testable import iosApp

@MainActor
final class ChatComposerStackBudgetTests: XCTestCase {
    func testInputBarStoredValueFitsOnePageOfParentStack() throws {
        struct EmptyKeys: SettingsAPIKeyStore {
            func loadApiKey() -> String? { nil }
            func saveApiKey(_ key: String) -> Bool { true }
        }
        let suite = "ComposerStackBudget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults, apiKeyStore: EmptyKeys())
        let shared = IOSSharedSettingsStore(userDefaults: defaults,
            loadCredential: { _ in nil }, storeCredential: { _, _ in true }, deleteCredential: { _ in true })
        let model = ChatViewModel(settingsStore: settings, sharedSettings: shared, autoGenerateResponses: false)
        let view = ChatView(settingsStore: settings, sharedSettings: shared, viewModel: model)
        // Query the actual opaque return type without evaluating the unmounted view's environments.
        // The device has a 1008 KiB main stack; parent builders must not embed this entire tree by value.
        let storedBytes = storedValueSize { view.inputBar }
        XCTAssertLessThanOrEqual(storedBytes, 4_096, "Composer value consumes \(storedBytes) bytes in each parent builder")
    }

    private func storedValueSize<Content: View>(_ build: () -> Content) -> Int {
        MemoryLayout<Content>.size
    }
}
