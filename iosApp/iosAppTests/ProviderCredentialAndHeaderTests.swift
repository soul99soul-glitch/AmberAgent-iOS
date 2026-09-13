import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ProviderCredentialAndHeaderTests: XCTestCase {
    func testOpenCodeConversationHeaderHonorsExplicitValueAndIgnoresOtherHosts() {
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Go", apiKey: "test", baseUrl: "https://opencode.ai/zen/go/v1",
            modelName: "Test", modelId: "test"
        )
        let headers = ChatProviderConfiguration.requestHeaders(
            for: provider,
            model: [CustomHeader(name: "X-OpenCode-Session", value: "configured-session")],
            conversationId: "conversation-a"
        )
        XCTAssertEqual(headers.map(\.value), ["configured-session"])

        let blank = ChatProviderConfiguration.requestHeaders(
            for: provider,
            model: [CustomHeader(name: "X-OpenCode-Session", value: "  ")],
            conversationId: "conversation-a"
        )
        XCTAssertEqual(blank.map(\.name), ["x-opencode-session"])
        XCTAssertEqual(blank.map(\.value), ["conversation-a"])

        let other = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "OpenCode Go", apiKey: "test", baseUrl: "https://example.com/v1",
            modelName: "Test", modelId: "test"
        )
        XCTAssertTrue(ChatProviderConfiguration.requestHeaders(
            for: other, conversationId: "conversation-a"
        ).isEmpty)
    }

    func testOpenCodeUserAgentIsVersioned() {
        let ua = OpenAICompatUserAgents.shared.OPENCODE
        XCTAssertTrue(ua.hasPrefix("opencode/"), ua)
        XCTAssertEqual(ua, "opencode/1.18.18")
        XCTAssertFalse(ua.hasSuffix("opencode/"), "User-Agent must include a version")
    }

    func testHeaderStorePersistsUserAgentAndDropsBlankRows() {
        let defaults = UserDefaults(suiteName: "ProviderHeaderTests-\(UUID().uuidString)")!
        let providerId = UUID().uuidString
        IOSProviderRequestHeaderStore.save(
            providerId: providerId,
            userAgent: "  \(OpenAICompatUserAgents.shared.OPENCODE)  ",
            extra: [
                .init(name: "X-Title", value: "AmberAgent"),
                .init(name: "  ", value: "skip"),
            ],
            defaults: defaults
        )

        let headers = IOSProviderRequestHeaderStore.headers(for: providerId, defaults: defaults)
        XCTAssertEqual(headers.map(\.name), ["User-Agent", "X-Title"])
        XCTAssertEqual(headers.map(\.value), [OpenAICompatUserAgents.shared.OPENCODE, "AmberAgent"])
        XCTAssertEqual(ProviderUserAgentPreset.matching(userAgent: OpenAICompatUserAgents.shared.OPENCODE), .opencode)
        XCTAssertEqual(ProviderUserAgentPreset.matching(userAgent: "MyAgent/1"), .custom)
        XCTAssertNil(ProviderUserAgentPreset.matching(userAgent: nil))
        XCTAssertNil(ProviderUserAgentPreset.matching(userAgent: "  "))
    }

    func testApiKeyProviderHasUsableCredentialAndCodexDoesNotWithoutLogin() {
        let keyed = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "keyed",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://api.openai.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.openai
        )
        XCTAssertTrue(ChatProviderConfiguration.hasUsableCredential(keyed))
        XCTAssertEqual(ChatProviderConfiguration.credentialStatusTitle(keyed), "已配置")

        let codex = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "codex",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "",
            baseUrl: "https://chatgpt.com/backend-api/codex",
            chatCompletionsPath: "/responses",
            useResponseApi: true,
            authMode: OpenAIAuthMode.codexOauth,
            brand: OpenAIBrand.openai
        )
        XCTAssertFalse(ChatProviderConfiguration.hasUsableCredential(codex))
        XCTAssertEqual(ChatProviderConfiguration.credentialStatusTitle(codex), "未填写")
    }
}
