import XCTest
@testable import AmberMac

@MainActor final class DesktopModelSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "amber.models.tests.\(UUID().uuidString)")!
    }

    func testUnconfiguredInitialTemplateIsNotOfferedAsCallableModel() throws {
        let settings = DesktopSettings(defaults: defaults(), credentials: DesktopMemoryCredentials())
        XCTAssertNotNil(settings.selectedProvider)
        XCTAssertTrue(settings.modelSelections.isEmpty)
        XCTAssertNil(settings.selectedModelID)
        let configured = DesktopProviderConfiguration(name: "First configured", kind: .openAI,
            baseURL: "https://example.com/v1", modelID: "configured")
        try settings.saveProvider(configured, apiKey: "key")
        XCTAssertEqual(settings.modelSelections.count, 1)
        XCTAssertEqual(settings.selectedProviderID, configured.id)
        XCTAssertEqual(settings.selectedModelID, configured.selectedModel?.id)
    }

    func testLegacySingleModelMigrationCommitsStableIndependentUUID() throws {
        let defaults = defaults()
        let providerID = UUID()
        let record: [String: Any] = ["providers": [["id": providerID.uuidString, "name": "Legacy",
            "kind": "openai", "baseURL": "https://example.com/v1", "modelID": "legacy-model"]],
            "selectedProviderID": providerID.uuidString, "systemPrompt": "", "appearance": "system"]
        defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: "desktop.settings.v1")
        let first = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        let modelID = try XCTUnwrap(first.selectedModelID)
        XCTAssertNotEqual(modelID, providerID)
        let restored = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertEqual(restored.selectedModelID, modelID)
        XCTAssertEqual(restored.selectedProvider?.modelID, "legacy-model")
        let committed = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "desktop.settings.v1"))) as? [String: Any]
        let providers = try XCTUnwrap(committed?["providers"] as? [[String: Any]])
        XCTAssertNotNil(providers[0]["models"])
    }

    func testMultipleModelsKeepStableParametersAndGlobalSelection() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let first = DesktopModelConfiguration(modelID: "fast", name: "快", contextWindowTokens: 32_000, temperature: 0.6, maxOutputTokens: 2_000, reasoning: .low)
        let second = DesktopModelConfiguration(modelID: "deep", name: "深", contextWindowTokens: 128_000, temperature: 1.2, maxOutputTokens: 8_000, reasoning: .high)
        let provider = DesktopProviderConfiguration(name: "Models", kind: .responses, baseURL: "https://example.com/v1", models: [first, second])
        try settings.saveProvider(provider, apiKey: "test")
        settings.selectModel(second.id)
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProviderID, provider.id)
        XCTAssertEqual(restored.selectedModelID, second.id)
        XCTAssertEqual(restored.selectedProvider?.selectedModel, second)
        XCTAssertEqual(restored.configuration(forModelID: first.id)?.selectedModel, first)
        XCTAssertEqual(restored.modelSelections.filter { $0.providerID == provider.id }.map(\.id), [first.id, second.id])
    }

    func testDisabledAndDeletedModelRepairSelectionAndAuxiliaryMapping() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let first = DesktopModelConfiguration(modelID: "first"), second = DesktopModelConfiguration(modelID: "second")
        var provider = DesktopProviderConfiguration(name: "Models", kind: .openAI, baseURL: "https://example.com/v1", models: [first, second])
        try settings.saveProvider(provider, apiKey: "test")
        settings.selectModel(second.id)
        settings.setAuxiliaryModel(second.id, for: .recap)
        XCTAssertEqual(settings.configuration(for: .recap)?.selectedModel?.id, second.id)
        provider.selectedModelID = second.id
        provider.models[1].enabled = false
        try settings.saveProvider(provider, apiKey: "test")
        XCTAssertEqual(settings.selectedModelID, first.id)
        XCTAssertNil(settings.auxiliaryModelIDs[DesktopAuxiliaryModelTask.recap.rawValue])
        XCTAssertEqual(settings.configuration(for: .recap)?.selectedModel?.id, first.id)
        settings.setAuxiliaryModel(first.id, for: .suggestions)
        try settings.deleteProvider(provider.id)
        XCTAssertNil(settings.auxiliaryModelIDs[DesktopAuxiliaryModelTask.suggestions.rawValue])
        XCTAssertNil(settings.configuration(forModelID: first.id))
    }

    func testInvalidModelAndAuthDoNotOverwriteCredentials() throws {
        let settings = DesktopSettings(defaults: defaults(), credentials: DesktopMemoryCredentials())
        var provider = DesktopProviderConfiguration(name: "Models", kind: .claude, baseURL: "https://example.com/v1", models: [DesktopModelConfiguration(modelID: "model")])
        try settings.saveProvider(provider, apiKey: "existing")
        provider.models[0].temperature = 1.1
        XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        provider.models[0].temperature = 0.5
        provider.models[0].maxOutputTokens = 0
        XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        provider.models[0].maxOutputTokens = 1024
        provider.models.append(provider.models[0])
        XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        provider.models.removeLast()
        provider.authMode = .codexOAuth
        XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        XCTAssertEqual(try settings.apiKey(for: provider.id), "existing")
        XCTAssertEqual(settings.providers.first(where: { $0.id == provider.id })?.models[0].temperature, nil)
    }

    func testOAuthCanBeSavedBeforeFetchingModelsAndPreservesEndpoint() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let provider = DesktopProviderConfiguration(name: "Codex", kind: .responses, baseURL: "https://chatgpt.com/backend-api/codex", models: [], authMode: .codexOAuth)
        try settings.saveProvider(provider, apiKey: "")
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.providers.first(where: { $0.id == provider.id }), provider)
    }

    func testCatalogMergeKeepsExistingUUIDAliasAndParameters() {
        let old = DesktopModelConfiguration(modelID: "one", name: "我的别名", enabled: false, contextWindowTokens: 64_000, temperature: 0.7, maxOutputTokens: 4_000, reasoning: .high)
        let result = DesktopModelCatalogMerge.merge([
            DesktopCatalogModel(modelID: "one", name: "Remote one", contextWindowTokens: 1_000),
            DesktopCatalogModel(modelID: "two", name: "Remote two", contextWindowTokens: 128_000),
            DesktopCatalogModel(modelID: "two", name: "Duplicate")], into: [old])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], old)
        XCTAssertEqual(result[1].modelID, "two")
        XCTAssertEqual(result[1].contextWindowTokens, 128_000)
        XCTAssertNotEqual(result[1].id, old.id)
    }

    func testBackupProviderCopiesUseNewIDsPreserveSelectionAndNeverTouchCredentials() throws {
        final class Credentials: DesktopCredentialStore {
            var writes = 0
            func load(id: UUID) throws -> String { "existing" }
            func save(_ value: String, id: UUID) throws { writes += 1 }
            func delete(id: UUID) throws { writes += 1 }
        }
        let credentials = Credentials(), defaults = defaults()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let models = [DesktopModelConfiguration(modelID: "first"), DesktopModelConfiguration(modelID: "second", temperature: 0.4)]
        let original = DesktopProviderConfiguration(name: "Imported", kind: .responses, baseURL: "https://example.com/v1", models: models, selectedModelID: models[1].id)
        let before = settings.providers
        let ids = try settings.importProviderCopies([original])
        let copy = try XCTUnwrap(settings.providers.first(where: { $0.id == ids[0] }))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(Set(copy.models.map(\.id)).isDisjoint(with: models.map(\.id)))
        XCTAssertEqual(copy.selectedModel?.modelID, "second")
        XCTAssertEqual(copy.selectedModel?.temperature, 0.4)
        XCTAssertEqual(credentials.writes, 0)
        var invalid = original
        invalid.baseURL = "https://secret@example.com/v1"
        XCTAssertThrowsError(try settings.importProviderCopies([original, invalid]))
        XCTAssertEqual(settings.providers.count, before.count + 1)
        settings.removeImportedProviders(ids)
        XCTAssertEqual(settings.providers, before)
        XCTAssertEqual(credentials.writes, 0)
    }

    func testDisplayPreferencesPersistAndRestoreActualValues() {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        settings.messageFontFamily = .serif
        settings.messageFontSize = 19
        settings.assistantName = "工作助手"
        settings.userNickname = "Amber用户"
        settings.reasoningExpandedByDefault = true
        settings.automaticallyFollowGeneration = false
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.messageFontFamily, .serif)
        XCTAssertEqual(restored.messageFontSize, 19)
        XCTAssertEqual(restored.assistantDisplayName, "工作助手")
        XCTAssertEqual(restored.userDisplayName, "Amber用户")
        XCTAssertTrue(restored.reasoningExpandedByDefault)
        XCTAssertFalse(restored.automaticallyFollowGeneration)
    }

    func testDisplaySizeBoundsAndEmptyNamesHaveExplicitDefaults() {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(settings.messageFontFamily, .system)
        XCTAssertEqual(settings.messageFontSize, 14)
        XCTAssertFalse(settings.reasoningExpandedByDefault)
        XCTAssertTrue(settings.automaticallyFollowGeneration)
        settings.messageFontSize = 100
        XCTAssertEqual(settings.messageFontSize, 22)
        settings.messageFontSize = 3
        XCTAssertEqual(settings.messageFontSize, 12)
        settings.assistantName = "  "
        settings.userNickname = "\n"
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.messageFontSize, 12)
        XCTAssertEqual(restored.assistantDisplayName, "Amber")
        XCTAssertEqual(restored.userDisplayName, "你")
    }

    func testExistingModelRecordWithoutNewFieldsSurvivesSettingsReopen() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let providerID = UUID(), modelID = UUID()
        let record: [String: Any] = ["providers": [["id": providerID.uuidString, "name": "Existing", "kind": "openai",
            "baseURL": "https://example.com/v1", "models": [["id": modelID.uuidString, "modelID": "previous", "name": "Old", "enabled": true,
            "reasoning": "low"]], "selectedModelID": modelID.uuidString]], "selectedProviderID": providerID.uuidString,
            "systemPrompt": "saved prompt", "appearance": "dark"]
        defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: "desktop.settings.v1")
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.selectedProviderID, providerID)
        XCTAssertEqual(restored.selectedModelID, modelID)
        XCTAssertEqual(restored.selectedProvider?.selectedModel?.customHeaders, [:])
        XCTAssertNil(restored.selectedProvider?.selectedModel?.customBody)
        XCTAssertNil(restored.selectedProvider?.selectedModel?.supportsVision)
        XCTAssertEqual(restored.systemPrompt, "saved prompt")
    }

    func testModelOverridesValidateAndPersistWithoutReplacingCredentialsOnInvalidJSON() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        var model = DesktopModelConfiguration(modelID: "custom", customHeaders: ["X-Feature": "enabled"],
            customBody: " {\"top_p\":0.8,\"metadata\":{\"source\":\"desktop\"}} ", supportsVision: false)
        var provider = DesktopProviderConfiguration(name: "Custom", kind: .openAI, baseURL: "https://example.com/v1", models: [model])
        try settings.saveProvider(provider, apiKey: "original")
        let reopened = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(reopened.configuration(forModelID: model.id)?.selectedModel?.customHeaders, ["X-Feature": "enabled"])
        XCTAssertEqual(reopened.configuration(forModelID: model.id)?.selectedModel?.supportsVision, false)
        XCTAssertEqual(reopened.configuration(forModelID: model.id)?.selectedModel?.customBody?.first, "{")
        for invalidBody in ["[]", "true", "{bad"] {
            model.customBody = invalidBody; provider.models = [model]
            XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        }
        model.customBody = "{}"
        for headers in [["Bad Header": "value"], ["X-Value": "line\r\ninjected"], ["": "value"]] {
            model.customHeaders = headers; provider.models = [model]
            XCTAssertThrowsError(try settings.saveProvider(provider, apiKey: "replacement"))
        }
        XCTAssertEqual(try settings.apiKey(for: provider.id), "original")
    }

    func testExplicitVisionTitleAndImageRolesPersistWithoutImplicitImageFallback() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let model = DesktopModelConfiguration(modelID: "special")
        let provider = DesktopProviderConfiguration(name: "Aux", kind: .openAI, baseURL: "https://example.com/v1", models: [model])
        try settings.saveProvider(provider, apiKey: "key")
        XCTAssertNil(settings.configuredAuxiliaryModel(for: .imageGeneration))
        XCTAssertNotNil(settings.configuration(for: .recap))
        for role: DesktopAuxiliaryModelTask in [.vision, .title, .imageGeneration] { settings.setAuxiliaryModel(model.id, for: role) }
        let reopened = DesktopSettings(defaults: defaults, credentials: credentials)
        for role: DesktopAuxiliaryModelTask in [.vision, .title, .imageGeneration] {
            XCTAssertEqual(reopened.configuredAuxiliaryModel(for: role)?.selectedModel?.id, model.id)
        }
    }
}

@MainActor final class DesktopCatalogRequestTests: XCTestCase {
    private final class Catalog: DesktopModelCatalog {
        var requests: [(DesktopProviderConfiguration, String)] = []
        var continuations: [CheckedContinuation<[DesktopCatalogModel], any Error>] = []
        var testCount = 0
        var holdsConnection = false
        var connection: CheckedContinuation<Void, any Error>?
        func models(for configuration: DesktopProviderConfiguration, apiKey: String) async throws -> [DesktopCatalogModel] {
            requests.append((configuration, apiKey))
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func testConnection(for configuration: DesktopProviderConfiguration, apiKey: String) async throws {
            testCount += 1
            if holdsConnection { try await withCheckedThrowingContinuation { connection = $0 } }
        }
    }
    private func config(_ name: String) -> DesktopProviderConfiguration {
        DesktopProviderConfiguration(name: name, kind: .openAI, baseURL: "https://example.com/v1", modelID: "model")
    }
    func testLateCatalogResponseCannotOverwriteNewDraftRequest() async {
        let catalog = Catalog(), request = DesktopCatalogRequest()
        request.fetch(configuration: config("old"), apiKey: "old-key", catalog: catalog)
        await Task.yield()
        request.fetch(configuration: config("new"), apiKey: "new-key", catalog: catalog)
        await Task.yield()
        XCTAssertEqual(catalog.requests.map { $0.1 }, ["old-key", "new-key"])
        catalog.continuations[1].resume(returning: [DesktopCatalogModel(modelID: "new", name: "New")])
        await request.waitUntilIdle()
        catalog.continuations[0].resume(returning: [DesktopCatalogModel(modelID: "old", name: "Old")])
        await Task.yield()
        XCTAssertEqual(request.models.map(\.modelID), ["new"])
        XCTAssertFalse(request.isLoading)
    }
    func testFailureHidesRemoteBodyAndGenerateTestUsesSeparateConsumer() async {
        let catalog = Catalog(), request = DesktopCatalogRequest()
        request.fetch(configuration: config("test"), apiKey: "secret", catalog: catalog)
        await Task.yield()
        catalog.continuations[0].resume(throwing: DesktopRuntimeError.message("remote body containing secret"))
        await request.waitUntilIdle()
        XCTAssertTrue(request.failed)
        XCTAssertFalse(request.status?.contains("secret") ?? true)
        request.fetch(configuration: config("test"), apiKey: "secret", catalog: catalog, testOnly: true)
        await request.waitUntilIdle()
        XCTAssertEqual(catalog.testCount, 1)
        XCTAssertEqual(catalog.requests.count, 1)
        XCTAssertFalse(request.failed)
        XCTAssertTrue(request.models.isEmpty)
    }
    func testChangedModelCanInvalidateCapturedConnectionTestWithoutAcceptingLateSuccess() async {
        let catalog = Catalog(), request = DesktopCatalogRequest()
        catalog.holdsConnection = true
        request.fetch(configuration: config("A"), apiKey: "key", catalog: catalog, testOnly: true)
        await Task.yield()
        XCTAssertTrue(request.isTestingConnection)
        request.cancel()
        catalog.connection?.resume()
        await Task.yield()
        XCTAssertFalse(request.isTestingConnection)
        XCTAssertNil(request.status)
        XCTAssertFalse(request.isLoading)
    }
}

@MainActor final class DesktopOAuthTests: XCTestCase {
    private final class Authorizer: DesktopCodexAuthorizer {
        var cached: [UUID: DesktopOAuthAccount] = [:]
        var polls: [UUID: CheckedContinuation<DesktopOAuthAccount, any Error>] = [:]
        var logouts: [UUID] = []
        var failPolling = false
        func account(providerID: UUID) -> DesktopOAuthAccount? { cached[providerID] }
        func requestCode(providerID: UUID) async throws -> DesktopDeviceAuthorization {
            DesktopDeviceAuthorization(verificationURL: URL(string: "https://example.com/device")!, userCode: "CODE", deviceAuthID: "device", intervalSeconds: 1)
        }
        func poll(providerID: UUID, code: DesktopDeviceAuthorization) async throws -> DesktopOAuthAccount {
            if failPolling { throw DesktopRuntimeError.message("secret raw failure") }
            let result = try await withCheckedThrowingContinuation { polls[providerID] = $0 }
            cached[providerID] = result
            return result
        }
        func logout(providerID: UUID) async throws { logouts.append(providerID); cached[providerID] = nil }
    }
    func testProviderSwitchDiscardsOldLoginPresentation() async {
        let auth = Authorizer(), login = DesktopCodexLogin(authorizer: auth)
        let first = UUID(), second = UUID()
        login.login(first)
        await Task.yield()
        XCTAssertNotNil(login.authorization)
        login.selectProvider(second)
        let old = DesktopOAuthAccount(email: "old@example.com", plan: "plus")
        auth.polls[first]?.resume(returning: old)
        await Task.yield()
        XCTAssertEqual(login.providerID, second)
        XCTAssertNil(login.account)
        XCTAssertNil(login.authorization)
        XCTAssertNil(login.status)
    }
    func testLogoutAwaitsEvenPreviouslyCancelledPollingBeforeRemovingTokens() async {
        let auth = Authorizer(), login = DesktopCodexLogin(authorizer: auth)
        let id = UUID()
        login.login(id)
        await Task.yield()
        login.cancel()
        login.logout(id)
        await Task.yield()
        XCTAssertTrue(auth.logouts.isEmpty)
        auth.polls[id]?.resume(returning: DesktopOAuthAccount(email: "a@example.com", plan: nil))
        await login.waitUntilIdle()
        XCTAssertEqual(auth.logouts, [id])
        XCTAssertNil(auth.cached[id])
        XCTAssertNil(login.account)
        XCTAssertFalse(login.isBusy)
        XCTAssertFalse(login.failed)
    }
    func testPollingOrCredentialFailureCannotPresentLoggedInSuccess() async {
        let auth = Authorizer(), login = DesktopCodexLogin(authorizer: auth)
        auth.failPolling = true
        login.login(UUID())
        await login.waitUntilIdle()
        XCTAssertTrue(login.failed)
        XCTAssertNil(login.account)
        XCTAssertFalse(login.status?.contains("secret") ?? true)
        XCTAssertNil(login.authorization)
    }
    func testCredentialRemovalWaitsForPollEvenIfViewCancelsPresentation() async throws {
        let auth = Authorizer(), login = DesktopCodexLogin(authorizer: auth)
        let id = UUID()
        login.login(id)
        await Task.yield()
        let removal = Task { try await login.removeCredentials(id) }
        await Task.yield()
        login.cancel()
        XCTAssertTrue(auth.logouts.isEmpty)
        auth.polls[id]?.resume(returning: DesktopOAuthAccount(email: "a@example.com", plan: nil))
        try await removal.value
        XCTAssertNil(auth.cached[id])
        XCTAssertEqual(auth.logouts, [id])
    }
}
