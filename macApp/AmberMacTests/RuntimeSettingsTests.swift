import XCTest
@testable import AmberMac

@MainActor final class RuntimeSettingsTests: XCTestCase {
    private final class FailingCredentials: DesktopCredentialStore {
        func load(id: UUID) throws -> String { "existing" }
        func save(_ value: String, id: UUID) throws { throw DesktopRuntimeError.message("测试写入失败") }
        func delete(id: UUID) throws { throw DesktopRuntimeError.message("测试删除失败") }
    }

    func testFailedCredentialWritePreservesConfig() throws {
        let defaults = UserDefaults(suiteName: "amber.settings.tests.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: FailingCredentials())
        let initial = try XCTUnwrap(settings.selectedProvider)
        var changed = initial
        changed.baseURL = "https://example.com/v1"
        changed.modelID = "test-model"
        XCTAssertThrowsError(try settings.saveProvider(changed, apiKey: "secret"))
        XCTAssertEqual(settings.selectedProvider, initial)
        XCTAssertThrowsError(try settings.deleteProvider(initial.id))
        XCTAssertEqual(settings.selectedProvider, initial)
    }

    func testCredentialsStayOutOfPersistedJSONAndModelSelectionRestores() throws {
        let defaults = UserDefaults(suiteName: "amber.settings.tests.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let config = DesktopProviderConfiguration(name: "私有模型", kind: .claude, baseURL: "https://example.com/v1", modelID: "model-id")
        try settings.saveProvider(config, apiKey: "secret-not-for-json")
        settings.selectedProviderID = config.id
        settings.systemPrompt = "系统提示"
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProvider, config)
        XCTAssertEqual(try restored.apiKey(for: config.id), "secret-not-for-json")
        XCTAssertEqual(restored.systemPrompt, "系统提示")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "desktop.settings.v1")!, as: UTF8.self).contains("secret-not-for-json"))
    }

    func testEditedProviderAndCredentialReplacePersistedValuesTogether() throws {
        let defaults = UserDefaults(suiteName: "amber.settings.tests.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        var config = try XCTUnwrap(settings.selectedProvider)
        config.modelID = "first-model"
        try settings.saveProvider(config, apiKey: "first-secret")
        config.name = "  私有服务商  "
        config.baseURL = " https://example.com/v1/// "
        config.modelID = " second-model "
        try settings.saveProvider(config, apiKey: " second-secret ")
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProvider?.name, "私有服务商")
        XCTAssertEqual(restored.selectedProvider?.baseURL, "https://example.com/v1")
        XCTAssertEqual(restored.selectedProvider?.modelID, "second-model")
        XCTAssertEqual(try restored.apiKey(for: config.id), "second-secret")
        let json = String(decoding: try XCTUnwrap(defaults.data(forKey: "desktop.settings.v1")), as: UTF8.self)
        XCTAssertFalse(json.contains("first-secret"))
        XCTAssertFalse(json.contains("second-secret"))
    }

    func testInvalidModelDoesNotReplaceExistingConfigOrCredential() throws {
        let defaults = UserDefaults(suiteName: "amber.settings.tests.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        var config = try XCTUnwrap(settings.selectedProvider)
        config.modelID = "working-model"
        try settings.saveProvider(config, apiKey: "working-secret")
        var invalid = config
        invalid.modelID = " \n "
        XCTAssertThrowsError(try settings.saveProvider(invalid, apiKey: "replacement-secret"))
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProvider, config)
        XCTAssertEqual(try restored.apiKey(for: config.id), "working-secret")
    }

    func testDeletingSelectedProviderRestoresRemainingSelectionAndRemovesCredential() throws {
        let defaults = UserDefaults(suiteName: "amber.settings.tests.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        var first = try XCTUnwrap(settings.selectedProvider)
        first.modelID = "first-model"
        try settings.saveProvider(first, apiKey: "first-secret")
        let second = DesktopProviderConfiguration(name: "第二个", kind: .claude,
            baseURL: "https://example.com/v1", modelID: "second-model")
        try settings.saveProvider(second, apiKey: "second-secret")
        settings.selectedProviderID = second.id
        try settings.deleteProvider(second.id)
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProvider, first)
        XCTAssertEqual(try restored.apiKey(for: second.id), "")
        XCTAssertEqual(try restored.apiKey(for: first.id), "first-secret")
    }

    func testEndpointValidationAllowsLocalModelsAndRejectsCredentialURLs() {
        XCTAssertNoThrow(try DesktopSettings.validateEndpoint("http://localhost:8080/v1"))
        XCTAssertNoThrow(try DesktopSettings.validateEndpoint("http://127.0.0.1:8080/v1"))
        XCTAssertNoThrow(try DesktopSettings.validateEndpoint("https://example.com/v1"))
        XCTAssertThrowsError(try DesktopSettings.validateEndpoint("http://example.com/v1"))
        XCTAssertThrowsError(try DesktopSettings.validateEndpoint("https://key@example.com/v1"))
        XCTAssertThrowsError(try DesktopSettings.validateEndpoint("https://example.com/v1?key=secret"))
    }
}

@MainActor final class DesktopSendShortcutTests: XCTestCase {
    func testSendShortcutDefaultsToCommandReturnAndPersists() {
        let defaults = UserDefaults(suiteName: "amber.send.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertEqual(settings.sendShortcut, .commandReturn)
        settings.sendShortcut = .returnKey
        XCTAssertEqual(DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials()).sendShortcut, .returnKey)
        XCTAssertEqual(DesktopSendShortcut.returnKey.newlineLabel, "⇧Return")
        XCTAssertEqual(DesktopSendShortcut.shiftReturn.newlineLabel, "Return")
    }
}
