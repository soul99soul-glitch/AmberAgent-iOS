import XCTest
@testable import iosApp

final class IOSCodexProviderResolverTests: XCTestCase {
    func testModelDiscoveryReadsCodexSlugsAndLegacyIds() throws {
        let codex = Data(#"{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra"},{"slug":"gpt-5.6-sol"},{"slug":"  "}]}"#.utf8)
        let models = IOSCodexOAuthClient.parseModels(codex)
        XCTAssertEqual(models.map(\.modelId), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(models.map(\.displayName), ["GPT-6-Astra", "gpt-5.6-sol"])
        XCTAssertEqual(IOSCodexOAuthClient.parseModels(Data(#"{"data":[{"id":"gpt-5.5"}]}"#.utf8)).first?.modelId, "gpt-5.5")
    }

    func testRequestDiagnosticLineRedactsBearerAndHeaderValues() {
        let line = IOSCodexProviderResolver.requestDiagnosticLine(
            originalAuthMode: "CODEX_OAUTH",
            resolvedBaseUrl: "https://chatgpt.com/backend-api/codex",
            finalURL: "https://chatgpt.com/backend-api/codex/responses",
            bearer: "eyJhbGciOiJub25lIn0.eyJhY2NvdW50IjoiYSJ9.signature",
            model: "gpt-5.5",
            headers: [
                "Authorization": "Bearer secret-token",
                "OpenAI-Beta": "responses=experimental",
                "ChatGPT-Account-Id": "account-secret",
                "": "empty-secret",
                "   ": "space-secret"
            ]
        )

        XCTAssertTrue(line.contains("original.authMode=CODEX_OAUTH"))
        XCTAssertTrue(line.contains("resolved.baseUrl=https://chatgpt.com/backend-api/codex"))
        XCTAssertTrue(line.contains("url=https://chatgpt.com/backend-api/codex/responses"))
        XCTAssertTrue(line.contains("bearer=JWT(len="))
        XCTAssertTrue(line.contains("model=gpt-5.5"))
        XCTAssertTrue(line.contains("headers=[Authorization,ChatGPT-Account-Id,OpenAI-Beta]"))
        XCTAssertFalse(line.contains("secret-token"))
        XCTAssertFalse(line.contains("account-secret"))
        XCTAssertFalse(line.contains("eyJhbGci"))
    }
}
