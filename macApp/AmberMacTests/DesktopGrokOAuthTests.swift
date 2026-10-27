import XCTest
@preconcurrency import Shared
@testable import AmberMac

@MainActor final class DesktopGrokOAuthTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "amber.grok.tests.\(UUID().uuidString)")!
    }

    func testGrokOAuthPersistsWithoutModelsAndRequiresOpenAICompatibleKind() throws {
        let defaults = defaults(), credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let provider = DesktopProviderConfiguration(name: "xAI", kind: .openAI,
            baseURL: IOSGrokOAuthConstants.cliProxyBaseUrl, models: [], authMode: .grokOAuth)
        try settings.saveProvider(provider, apiKey: "")
        let restored = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.providers.first(where: { $0.id == provider.id }), provider)
        XCTAssertEqual(restored.providers.first(where: { $0.id == provider.id })?.authMode, .grokOAuth)

        for kind in [DesktopProviderKind.responses, .claude, .gemini] {
            var wrong = provider
            wrong.kind = kind
            XCTAssertThrowsError(try settings.saveProvider(wrong, apiKey: "")) { error in
                XCTAssertEqual(error.localizedDescription, "Grok 登录须使用 OpenAI 兼容协议。")
            }
        }
        XCTAssertEqual(settings.providers.first(where: { $0.id == provider.id })?.kind, .openAI)
    }

    func testBridgeAcceptsGrokOAuthOnlyForOpenAICompatible() throws {
        let id = UUID().uuidString
        let bridge = DesktopProviderBridge.shared
        let grok = try bridge.configurationWithAuth(kind: "openai", id: id, name: "xAI",
            baseUrl: IOSGrokOAuthConstants.cliProxyBaseUrl, apiKey: "", authMode: "grokOAuth")
        XCTAssertTrue(grok is ProviderSetting.OpenAI)
        XCTAssertThrowsError(try bridge.configurationWithAuth(kind: "responses", id: id, name: "xAI",
            baseUrl: IOSGrokOAuthConstants.cliProxyBaseUrl, apiKey: "", authMode: "grokOAuth"))
    }

    func testPrepareRequestAppliesGrokTokenProxyAndIdentityHeaders() async throws {
        let uuid = UUID()
        let key = uuid.uuidString.lowercased()
        defer { IOSGrokOAuthAuthStore.clear(providerId: key) }
        // Far-future expiry: the resolver must return the cached token without a network refresh.
        let tokens = IOSGrokOAuthTokens(accessToken: "grok-fixture-token", refreshToken: "refresh",
            expiresAtMillis: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000, idToken: nil, email: "a@example.com")
        XCTAssertTrue(IOSGrokOAuthAuthStore.save(providerId: key, tokens: tokens))

        let bridge = DesktopProviderBridge.shared
        let setting = try bridge.configurationWithAuth(kind: "openai", id: uuid.uuidString, name: "xAI",
            baseUrl: IOSGrokOAuthConstants.cliProxyBaseUrl, apiKey: "", authMode: "grokOAuth")
        let (provider, params) = try await DesktopEngineTransport().prepareRequest(
            providerSetting: setting, params: bridge.params(modelID: "grok-4.6"))
        let openAI = try XCTUnwrap(provider as? ProviderSetting.OpenAI)
        XCTAssertEqual(openAI.apiKey, "grok-fixture-token")
        XCTAssertEqual(openAI.baseUrl, IOSGrokOAuthConstants.cliProxyBaseUrl)
        XCTAssertTrue(openAI.useResponseApi)
        let headers = Dictionary(params.customHeaders.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(headers["x-grok-client-identifier"], IOSGrokCliProxyIdentity.clientIdentifier)
        XCTAssertEqual(headers["X-XAI-Token-Auth"], IOSGrokOAuthConstants.tokenAuthHeader)
        XCTAssertEqual(headers["x-grok-model-override"], "grok-4.6")
    }

    func testPrepareRequestLeavesPlainOpenAIProviderUntouched() async throws {
        let bridge = DesktopProviderBridge.shared
        let setting = try bridge.configurationWithAuth(kind: "openai", id: UUID().uuidString, name: "Other",
            baseUrl: "https://example.com/v1", apiKey: "key", authMode: "apiKey")
        let (provider, params) = try await DesktopEngineTransport().prepareRequest(
            providerSetting: setting, params: bridge.params(modelID: "model"))
        let openAI = try XCTUnwrap(provider as? ProviderSetting.OpenAI)
        XCTAssertEqual(openAI.apiKey, "key")
        XCTAssertEqual(openAI.baseUrl, "https://example.com/v1")
        XCTAssertTrue(params.customHeaders.isEmpty)
    }
}
