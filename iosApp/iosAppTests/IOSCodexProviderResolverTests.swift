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

    func testRefreshCommitCannotRestoreCredentialsAfterLogoutOrNewLogin() {
        let providerId = "refresh-race-test-\(UUID().uuidString)"
        defer { IOSCodexAuthStore.clear(providerId: providerId) }
        let original = IOSCodexAuthTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAtMillis: 1,
            accountId: "old-account",
            email: nil,
            planType: nil,
            idToken: nil
        )
        let refreshed = IOSCodexAuthTokens(
            accessToken: "stale-refreshed-access",
            refreshToken: "stale-refreshed-refresh",
            expiresAtMillis: 2,
            accountId: "old-account",
            email: nil,
            planType: nil,
            idToken: nil
        )
        let newLogin = IOSCodexAuthTokens(
            accessToken: "new-login-access",
            refreshToken: "new-login-refresh",
            expiresAtMillis: 3,
            accountId: "new-account",
            email: nil,
            planType: nil,
            idToken: nil
        )

        IOSCodexAuthStore.save(providerId: providerId, tokens: original)
        XCTAssertEqual(IOSCodexAuthStore.load(providerId: providerId), original)
        XCTAssertEqual(
            IOSCodexAuthStore.saveRefreshedTokens(
                providerId: providerId,
                expected: original,
                refreshed: refreshed
            ),
            .saved
        )
        XCTAssertEqual(IOSCodexAuthStore.load(providerId: providerId), refreshed)

        IOSCodexAuthStore.clear(providerId: providerId)
        XCTAssertEqual(
            IOSCodexAuthStore.saveRefreshedTokens(
                providerId: providerId,
                expected: original,
                refreshed: refreshed
            ),
            .credentialsChanged
        )
        XCTAssertNil(IOSCodexAuthStore.load(providerId: providerId))

        IOSCodexAuthStore.save(providerId: providerId, tokens: newLogin)
        XCTAssertEqual(
            IOSCodexAuthStore.saveRefreshedTokens(
                providerId: providerId,
                expected: original,
                refreshed: refreshed
            ),
            .credentialsChanged
        )
        XCTAssertEqual(IOSCodexAuthStore.load(providerId: providerId), newLogin)
    }

    func testConcurrentClientsShareOneRefreshRequest() async throws {
        let providerId = "shared-refresh-test-\(UUID().uuidString)"
        let original = IOSCodexAuthTokens(
            accessToken: "expired-access",
            refreshToken: "shared-refresh-token",
            expiresAtMillis: 1,
            accountId: "shared-account",
            email: nil,
            planType: nil,
            idToken: nil
        )
        XCTAssertTrue(IOSCodexAuthStore.save(providerId: providerId, tokens: original))
        defer { IOSCodexAuthStore.clear(providerId: providerId) }

        CodexRefreshURLProtocol.reset()
        let firstSession = makeRefreshSession()
        let secondSession = makeRefreshSession()
        defer {
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        let firstClient = IOSCodexOAuthClient(providerId: providerId, session: firstSession)
        let secondClient = IOSCodexOAuthClient(providerId: providerId, session: secondSession)

        async let firstToken = firstClient.getValidAccessToken()
        async let secondToken = secondClient.getValidAccessToken()
        let (first, second) = try await (firstToken, secondToken)

        XCTAssertEqual(first, "shared-refreshed-access")
        XCTAssertEqual(second, first)
        XCTAssertEqual(CodexRefreshURLProtocol.requestCount, 1)
        XCTAssertEqual(IOSCodexAuthStore.load(providerId: providerId)?.accessToken, first)
    }

    func testValidCachedTokenReturnsDirectlyWhileForceRefreshUsesNetwork() async throws {
        let providerId = "forced-refresh-test-\(UUID().uuidString)"
        let original = IOSCodexAuthTokens(
            accessToken: "still-valid-access",
            refreshToken: "force-refresh-token",
            expiresAtMillis: Int64(Date().timeIntervalSince1970 * 1000) + 60 * 60 * 1000,
            accountId: "force-account",
            email: nil,
            planType: nil,
            idToken: nil
        )
        XCTAssertTrue(IOSCodexAuthStore.save(providerId: providerId, tokens: original))
        defer { IOSCodexAuthStore.clear(providerId: providerId) }

        CodexRefreshURLProtocol.reset()
        let session = makeRefreshSession()
        defer { session.invalidateAndCancel() }
        let client = IOSCodexOAuthClient(providerId: providerId, session: session)

        let cachedToken = try await client.getValidAccessToken()
        XCTAssertEqual(cachedToken, original.accessToken)
        XCTAssertEqual(CodexRefreshURLProtocol.requestCount, 0)

        let forcedToken = try await client.getValidAccessToken(forceRefresh: true)
        XCTAssertEqual(forcedToken, "shared-refreshed-access")
        XCTAssertEqual(CodexRefreshURLProtocol.requestCount, 1)
    }

    private func makeRefreshSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRefreshURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CodexRefreshURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func reset() {
        lock.lock()
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.openai.com" && request.url?.path == "/oauth/token"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequestCount += 1
        Self.lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"access_token":"shared-refreshed-access","refresh_token":"shared-new-refresh-token"}"#.utf8)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
