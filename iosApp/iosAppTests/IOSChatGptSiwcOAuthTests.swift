import Foundation
import Security
import Shared
import XCTest
@testable import iosApp

final class IOSChatGptSiwcOAuthTests: XCTestCase {
    // MARK: - Authorization URL construction

    func testInitialAuthorizationURLUsesDynamicAgentClientAndLoopback127() throws {
        let hostId = "urn:uuid:11111111-2222-4333-8444-555555555555"
        let request = try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
            redirectUri: "http://127.0.0.1:43210/auth/callback",
            registration: nil,
            hostId: hostId,
            state: "state-123",
            nonce: "nonce-456",
            codeVerifier: "verifier-abcdef0123456789"
        )

        XCTAssertTrue(request.isDynamicRegistration)
        XCTAssertEqual(request.clientId, "dynamic_agent_client")

        let components = try XCTUnwrap(URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/api/accounts/authorize")

        let query = queryMap(from: components)
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "dynamic_agent_client")
        XCTAssertEqual(query["agent_name_hint"], "Amber")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:43210/auth/callback")
        XCTAssertEqual(query["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(
            query["scope"],
            "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        )
        XCTAssertEqual(query["state"], "state-123")
        XCTAssertEqual(query["nonce"], "nonce-456")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(
            query["code_challenge"],
            IOSChatGptSiwcOAuthClient.pkceS256Challenge(for: "verifier-abcdef0123456789")
        )
        XCTAssertEqual(query["ext_agent_host_id"], hostId)
        XCTAssertNil(query["id_token_hint"])
        XCTAssertNil(query["login_hint"])
    }

    func testReauthURLReusesIssuedClientIdOmitsAgentNameHintAndIncludesHints() throws {
        let registration = IOSChatGptSiwcRegistrationRecord(
            clientId: "oaiapp_existing_12345",
            lastIdToken: "prior.id.token",
            lastEmail: "alice@example.com"
        )
        let request = try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
            redirectUri: "http://127.0.0.1:51000/auth/callback",
            registration: registration,
            hostId: "urn:uuid:11111111-2222-4333-8444-555555555555",
            state: "state-reauth",
            nonce: "nonce-reauth",
            codeVerifier: "verifier-reauth"
        )

        XCTAssertFalse(request.isDynamicRegistration)
        XCTAssertEqual(request.clientId, "oaiapp_existing_12345")

        let components = try XCTUnwrap(URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false))
        let query = queryMap(from: components)
        XCTAssertEqual(query["client_id"], "oaiapp_existing_12345")
        XCTAssertNil(query["agent_name_hint"], "Re-authentication must omit agent_name_hint")
        XCTAssertEqual(query["id_token_hint"], "prior.id.token")
        XCTAssertEqual(query["login_hint"], "alice@example.com")
    }

    func testAuthorizationURLRejectsLocalhostRedirectUri() {
        XCTAssertThrowsError(
            try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
                redirectUri: "http://localhost:43210/auth/callback",
                registration: nil
            )
        )
    }

    func testHostIdIsStableAcrossSignOut() {
        let providerId = "siwc-hostid-test-\(UUID().uuidString)"
        defer { IOSChatGptSiwcAuthStore.clearAll(providerId: providerId) }

        let first = IOSChatGptSiwcHostIdStore.hostId()
        XCTAssertTrue(IOSChatGptSiwcHostIdStore.isValidHostId(first))
        IOSChatGptSiwcAuthStore.clearSession(providerId: providerId)
        IOSChatGptSiwcAuthStore.clearAll(providerId: providerId)
        let second = IOSChatGptSiwcHostIdStore.hostId()
        XCTAssertEqual(first, second)
    }

    // MARK: - Callback parsing & validation

    func testCallbackValidationAcceptsDynamicRegistrationAndRejectsBadStateOrMissingClientId() throws {
        let validURL = URL(string: "http://127.0.0.1:43210/auth/callback?code=auth_code_1&state=expected&client_id=oaiapp_new_999")!
        let parsed = try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
            url: validURL,
            expectedState: "expected",
            requestedClientId: "dynamic_agent_client",
            isDynamicRegistration: true
        )
        XCTAssertEqual(parsed.code, "auth_code_1")
        XCTAssertEqual(parsed.state, "expected")
        XCTAssertEqual(parsed.issuedClientId, "oaiapp_new_999")

        // Mismatched state
        let badStateURL = URL(string: "http://127.0.0.1:43210/auth/callback?code=auth_code_1&state=wrong&client_id=oaiapp_new_999")!
        XCTAssertThrowsError(
            try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
                url: badStateURL,
                expectedState: "expected",
                requestedClientId: "dynamic_agent_client",
                isDynamicRegistration: true
            )
        )

        // Missing issued client_id on initial dynamic registration
        let missingClientIdURL = URL(string: "http://127.0.0.1:43210/auth/callback?code=auth_code_1&state=expected")!
        XCTAssertThrowsError(
            try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
                url: missingClientIdURL,
                expectedState: "expected",
                requestedClientId: "dynamic_agent_client",
                isDynamicRegistration: true
            )
        )

        // Error query parameter
        let errorURL = URL(string: "http://127.0.0.1:43210/auth/callback?error=access_denied&error_description=User%20cancelled&state=expected")!
        XCTAssertThrowsError(
            try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
                url: errorURL,
                expectedState: "expected",
                requestedClientId: "dynamic_agent_client",
                isDynamicRegistration: true
            )
        )

        // Returning sign-in reuses requested client_id if callback omits it
        let reauthURL = URL(string: "http://127.0.0.1:43210/auth/callback?code=auth_code_2&state=expected")!
        let reauthParsed = try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
            url: reauthURL,
            expectedState: "expected",
            requestedClientId: "oaiapp_existing",
            isDynamicRegistration: false
        )
        XCTAssertEqual(reauthParsed.issuedClientId, "oaiapp_existing")
    }

    // MARK: - JWKS verification (RSA + EC) & Token exchange / scope validation

    func testJwtVerifierValidatesRealRS256AndES256SignaturesAndRejectsInvalidClaims() throws {
        let rsaPair = try SiwcTestKeyPair.generateRSA(kid: "rsa-kid-1")
        let ecPair = try SiwcTestKeyPair.generateECP256(kid: "ec-kid-1")
        let now = Date()
        let exp = Int(now.timeIntervalSince1970 + 3600)

        let validPayload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_test_client",
            "sub": "user_abc",
            "nonce": "nonce-ok",
            "exp": exp,
            "email": "tester@example.com",
            "name": "Tester",
        ]

        let rsToken = try rsaPair.signJWT(payload: validPayload)
        let rsClaims = try IOSChatGptSiwcJwtVerifier.verifyIdToken(
            rsToken,
            expectedClientId: "oaiapp_test_client",
            expectedNonce: "nonce-ok",
            jwks: [rsaPair.jwk],
            now: now
        )
        XCTAssertEqual(rsClaims.subject, "user_abc")
        XCTAssertEqual(rsClaims.email, "tester@example.com")

        let esToken = try ecPair.signJWT(payload: validPayload)
        let esClaims = try IOSChatGptSiwcJwtVerifier.verifyIdToken(
            esToken,
            expectedClientId: "oaiapp_test_client",
            expectedNonce: "nonce-ok",
            jwks: [ecPair.jwk],
            now: now
        )
        XCTAssertEqual(esClaims.subject, "user_abc")

        // Tampered signature must fail
        let tampered = rsToken + "A"
        XCTAssertThrowsError(
            try IOSChatGptSiwcJwtVerifier.verifyIdToken(
                tampered,
                expectedClientId: "oaiapp_test_client",
                expectedNonce: "nonce-ok",
                jwks: [rsaPair.jwk],
                now: now
            )
        )

        // Wrong nonce must fail
        XCTAssertThrowsError(
            try IOSChatGptSiwcJwtVerifier.verifyIdToken(
                rsToken,
                expectedClientId: "oaiapp_test_client",
                expectedNonce: "wrong-nonce",
                jwks: [rsaPair.jwk],
                now: now
            )
        )

        // Wrong audience must fail
        XCTAssertThrowsError(
            try IOSChatGptSiwcJwtVerifier.verifyIdToken(
                rsToken,
                expectedClientId: "oaiapp_other",
                expectedNonce: "nonce-ok",
                jwks: [rsaPair.jwk],
                now: now
            )
        )

        // Expired token must fail
        var expiredPayload = validPayload
        expiredPayload["exp"] = Int(now.timeIntervalSince1970 - 300)
        let expiredToken = try rsaPair.signJWT(payload: expiredPayload)
        XCTAssertThrowsError(
            try IOSChatGptSiwcJwtVerifier.verifyIdToken(
                expiredToken,
                expectedClientId: "oaiapp_test_client",
                expectedNonce: "nonce-ok",
                jwks: [rsaPair.jwk],
                now: now
            )
        )
    }

    func testTokenExchangeVerifiesScopeAndJwksAndPersistsRegistration() async throws {
        let providerId = "siwc-exchange-test-\(UUID().uuidString)"
        defer { IOSChatGptSiwcAuthStore.clearAll(providerId: providerId) }

        let rsaPair = try SiwcTestKeyPair.generateRSA(kid: "siwc-kid-1")
        let jwksData = try JSONEncoder().encode(IOSChatGptSiwcJwksDocument(keys: [rsaPair.jwk]))
        let idToken = try rsaPair.signJWT(payload: [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_issued_01",
            "sub": "sub_01",
            "nonce": "nonce_01",
            "exp": Int(Date().timeIntervalSince1970 + 3600),
            "email": "siwc@example.com",
        ])

        SiwcMockURLProtocol.reset()
        SiwcMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url == IOSChatGptSiwcConstants.jwksEndpoint {
                return (200, jwksData)
            }
            if url == IOSChatGptSiwcConstants.tokenEndpoint {
                let bodyText = Self.readRequestBody(request)
                XCTAssertTrue(bodyText.contains("grant_type=authorization_code"))
                XCTAssertTrue(bodyText.contains("client_id=oaiapp_issued_01"))
                XCTAssertTrue(bodyText.contains("code_verifier=verifier_01"))
                let json: [String: Any] = [
                    "access_token": "siwc_access_1",
                    "refresh_token": "siwc_refresh_1",
                    "id_token": idToken,
                    "expires_in": 3600,
                    "scope": IOSChatGptSiwcConstants.scope,
                ]
                return (200, try JSONSerialization.data(withJSONObject: json))
            }
            return (404, Data())
        }

        let session = makeMockSession()
        let client = IOSChatGptSiwcOAuthClient(
            providerId: providerId,
            session: session,
            jwksCache: IOSChatGptSiwcJwksCache()
        )
        let authRequest = try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
            redirectUri: "http://127.0.0.1:45678/auth/callback",
            registration: nil,
            hostId: "urn:uuid:11111111-2222-4333-8444-555555555555",
            state: "state_01",
            nonce: "nonce_01",
            codeVerifier: "verifier_01"
        )
        let callback = IOSChatGptSiwcCallbackResult(
            code: "code_01",
            state: "state_01",
            issuedClientId: "oaiapp_issued_01"
        )

        let creds = try await client.exchangeAuthorizationCode(request: authRequest, callback: callback)
        XCTAssertEqual(creds.clientId, "oaiapp_issued_01")
        XCTAssertEqual(creds.accessToken, "siwc_access_1")
        XCTAssertEqual(creds.refreshToken, "siwc_refresh_1")
        XCTAssertEqual(creds.email, "siwc@example.com")

        // Registration persists across logout so re-auth reuses oaiapp_issued_01
        await client.logout()
        XCTAssertNil(IOSChatGptSiwcAuthStore.load(providerId: providerId))
        let registration = IOSChatGptSiwcAuthStore.loadRegistration(providerId: providerId)
        XCTAssertEqual(registration?.clientId, "oaiapp_issued_01")
        XCTAssertEqual(registration?.lastEmail, "siwc@example.com")
    }

    func testTokenExchangeRejectsMissingDirectTokenScope() async throws {
        let providerId = "siwc-scope-test-\(UUID().uuidString)"
        defer { IOSChatGptSiwcAuthStore.clearAll(providerId: providerId) }

        let rsaPair = try SiwcTestKeyPair.generateRSA(kid: "siwc-kid-2")
        let jwksData = try JSONEncoder().encode(IOSChatGptSiwcJwksDocument(keys: [rsaPair.jwk]))
        let idToken = try rsaPair.signJWT(payload: [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_issued_02",
            "sub": "sub_02",
            "nonce": "nonce_02",
            "exp": Int(Date().timeIntervalSince1970 + 3600),
        ])

        SiwcMockURLProtocol.reset()
        SiwcMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url == IOSChatGptSiwcConstants.jwksEndpoint {
                return (200, jwksData)
            }
            let json: [String: Any] = [
                "access_token": "siwc_access_no_scope",
                "refresh_token": "siwc_refresh_no_scope",
                "id_token": idToken,
                "expires_in": 3600,
                "scope": "openid profile email offline_access",
            ]
            return (200, try JSONSerialization.data(withJSONObject: json))
        }

        let client = IOSChatGptSiwcOAuthClient(
            providerId: providerId,
            session: makeMockSession(),
            jwksCache: IOSChatGptSiwcJwksCache()
        )
        let authRequest = try IOSChatGptSiwcOAuthClient.buildAuthorizationRequest(
            redirectUri: "http://127.0.0.1:45679/auth/callback",
            registration: nil,
            state: "state_02",
            nonce: "nonce_02",
            codeVerifier: "verifier_02"
        )
        let callback = IOSChatGptSiwcCallbackResult(
            code: "code_02",
            state: "state_02",
            issuedClientId: "oaiapp_issued_02"
        )

        do {
            _ = try await client.exchangeAuthorizationCode(request: authRequest, callback: callback)
            XCTFail("Expected missing chatgpt.tokens.use.direct scope to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("chatgpt.tokens.use.direct"))
        }
        XCTAssertNil(IOSChatGptSiwcAuthStore.load(providerId: providerId))
    }

    // MARK: - Refresh token rotation & concurrency coalescing

    func testRefreshRotatesRefreshTokenAndCoalescesConcurrentCallers() async throws {
        let providerId = "siwc-refresh-test-\(UUID().uuidString)"
        defer { IOSChatGptSiwcAuthStore.clearAll(providerId: providerId) }

        let expired = IOSChatGptSiwcCredentials(
            clientId: "oaiapp_refresh_1",
            accessToken: "expired_access",
            refreshToken: "refresh_v1",
            expiresAtMillis: 1,
            scope: IOSChatGptSiwcConstants.scope,
            idToken: "id_v1",
            subject: "sub_r",
            email: "rotate@example.com",
            name: nil
        )
        XCTAssertTrue(IOSChatGptSiwcAuthStore.save(providerId: providerId, credentials: expired))

        let callCountLock = NSLock()
        var refreshRequests = 0
        SiwcMockURLProtocol.reset()
        SiwcMockURLProtocol.handler = { request in
            let body = Self.readRequestBody(request)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("refresh_token=refresh_v1"))
            XCTAssertTrue(body.contains("client_id=oaiapp_refresh_1"))
            callCountLock.lock()
            refreshRequests += 1
            callCountLock.unlock()
            Thread.sleep(forTimeInterval: 0.08)
            let json: [String: Any] = [
                "access_token": "fresh_access_v2",
                "refresh_token": "refresh_v2_rotated",
                "expires_in": 3600,
                "scope": IOSChatGptSiwcConstants.scope,
            ]
            return (200, try JSONSerialization.data(withJSONObject: json))
        }

        let session1 = makeMockSession()
        let session2 = makeMockSession()
        let client1 = IOSChatGptSiwcOAuthClient(providerId: providerId, session: session1)
        let client2 = IOSChatGptSiwcOAuthClient(providerId: providerId, session: session2)

        async let token1 = client1.getValidAccessToken()
        async let token2 = client2.getValidAccessToken()
        let (t1, t2) = try await (token1, token2)

        XCTAssertEqual(t1, "fresh_access_v2")
        XCTAssertEqual(t2, "fresh_access_v2")
        XCTAssertEqual(refreshRequests, 1)

        let persisted = IOSChatGptSiwcAuthStore.load(providerId: providerId)
        XCTAssertEqual(persisted?.accessToken, "fresh_access_v2")
        XCTAssertEqual(persisted?.refreshToken, "refresh_v2_rotated")
    }

    // MARK: - Model list filtering & ordering

    func testParseModelsFiltersVisibilityListPreservesOrderAndMapsSlugDisplayName() {
        let payload = Data("""
        {
          "models": [
            {"slug": "hidden-model", "display_name": "Hidden", "visibility": "hide"},
            {"slug": "gpt-5.4", "display_name": "GPT-5.4", "visibility": "list"},
            {"slug": "no-visibility", "display_name": "No Vis"},
            {"slug": "gpt-5.4-mini", "display_name": "GPT-5.4 mini", "visibility": "list"},
            {"slug": "gpt-5.4", "display_name": "Duplicate", "visibility": "list"},
            {"slug": "o4-mini", "display_name": "  ", "visibility": "list"}
          ]
        }
        """.utf8)

        let items = IOSChatGptSiwcOAuthClient.parseModels(payload)
        XCTAssertEqual(items.map(\.slug), ["gpt-5.4", "gpt-5.4-mini", "o4-mini"])
        XCTAssertEqual(items.map(\.displayName), ["GPT-5.4", "GPT-5.4 mini", "o4-mini"])
    }

    // MARK: - Provider resolver & configuration

    func testResolverInjectsSiwcBearerWithoutCodexHeaders() async throws {
        let provider = IosSettingsMutations.shared.buildChatGptSiwcProvider(name: "ChatGPT")
        let providerId = provider.id.description()
        defer { IOSChatGptSiwcAuthStore.clearAll(providerId: providerId) }

        let model = Model(
            modelId: "gpt-5.4",
            displayName: "GPT-5.4",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [ModelAbility.tool],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )

        XCTAssertEqual(
            ChatProviderConfiguration.issue(for: model, provider: provider),
            .chatGptSiwcNotSignedIn
        )

        let validCreds = IOSChatGptSiwcCredentials(
            clientId: "oaiapp_res_1",
            accessToken: "siwc_live_bearer",
            refreshToken: "siwc_live_refresh",
            expiresAtMillis: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
            scope: IOSChatGptSiwcConstants.scope,
            idToken: "id_token",
            subject: "sub",
            email: "user@example.com",
            name: nil
        )
        XCTAssertTrue(IOSChatGptSiwcAuthStore.save(providerId: providerId, credentials: validCreds))
        XCTAssertNil(ChatProviderConfiguration.issue(for: model, provider: provider))

        let resolved = try await IOSCodexProviderResolver.resolved(provider)
        let resolvedOpenAI = try XCTUnwrap(resolved as? ProviderSetting.OpenAI)
        XCTAssertEqual(resolvedOpenAI.apiKey, "siwc_live_bearer")
        XCTAssertEqual(resolvedOpenAI.baseUrl, "https://api.openai.com/v1")
        XCTAssertTrue(resolvedOpenAI.useResponseApi)
        XCTAssertEqual(resolvedOpenAI.authMode, OpenAIAuthMode.chatgptSiwc)

        // augmentParamsForCodex must remain a no-op for SIWC (no Codex-private headers)
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .auto_,
            customHeaders: [],
            customBody: []
        )
        let augmented = IOSCodexProviderResolver.augmentParamsForCodex(params, provider: resolvedOpenAI)
        XCTAssertTrue(augmented.customHeaders.isEmpty)
    }

    // MARK: - Loopback NWListener callback server

    func testLoopbackServerBinds127001IgnoresFaviconAndDeliversAuthCallback() async throws {
        let server = IOSChatGptSiwcLoopbackServer()
        defer { server.stop() }

        let redirectUri = try await server.start()
        XCTAssertTrue(redirectUri.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(redirectUri.hasSuffix("/auth/callback"))

        let callbackTask = Task { try await server.waitForCallback() }

        // Unrelated path should return 404 without terminating the wait
        let faviconURL = URL(string: redirectUri.replacingOccurrences(of: "/auth/callback", with: "/favicon.ico"))!
        let (_, faviconResp) = try await URLSession.shared.data(from: faviconURL)
        XCTAssertEqual((faviconResp as? HTTPURLResponse)?.statusCode, 404)

        // Real callback should return 200 HTML and resolve waitForCallback
        let callbackURL = URL(string: "\(redirectUri)?code=cb_123&state=st_456&client_id=oaiapp_cb")!
        let (htmlData, cbResp) = try await URLSession.shared.data(from: callbackURL)
        XCTAssertEqual((cbResp as? HTTPURLResponse)?.statusCode, 200)
        let html = String(data: htmlData, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("Sign-in complete"))

        let delivered = try await callbackTask.value
        let parsed = try IOSChatGptSiwcOAuthClient.parseAndValidateCallback(
            url: delivered,
            expectedState: "st_456",
            requestedClientId: "dynamic_agent_client",
            isDynamicRegistration: true
        )
        XCTAssertEqual(parsed.code, "cb_123")
        XCTAssertEqual(parsed.issuedClientId, "oaiapp_cb")
    }

    // MARK: - Helpers

    private func queryMap(from components: URLComponents) -> [String: String] {
        (components.queryItems ?? []).reduce(into: [:]) { result, item in
            result[item.name] = item.value ?? ""
        }
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiwcMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func readRequestBody(_ request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 { data.append(buffer, count: count) }
            else { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Mock URLProtocol

private final class SiwcMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let currentHandler = Self.handler
        Self.lock.unlock()
        guard let currentHandler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try currentHandler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Real RSA / EC P-256 test key generator for JWKS verification tests

private struct SiwcTestKeyPair {
    let privateKey: SecKey
    let jwk: IOSChatGptSiwcJwk
    let alg: String
    let secAlg: SecKeyAlgorithm
    let isEC: Bool

    static func generateRSA(kid: String) throws -> SiwcTestKeyPair {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw NSError(domain: "SiwcTestKeyPair", code: 1)
        }
        let (modulus, exponent) = try parsePKCS1RSAPublicKey(pkcs1)
        let jwk = IOSChatGptSiwcJwk(
            kty: "RSA",
            kid: kid,
            alg: "RS256",
            use: "sig",
            n: base64URL(modulus),
            e: base64URL(exponent),
            crv: nil,
            x: nil,
            y: nil
        )
        return SiwcTestKeyPair(
            privateKey: privateKey,
            jwk: jwk,
            alg: "RS256",
            secAlg: .rsaSignatureMessagePKCS1v15SHA256,
            isEC: false
        )
    }

    static func generateECP256(kid: String) throws -> SiwcTestKeyPair {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              x963.count == 65, x963[0] == 0x04 else {
            throw NSError(domain: "SiwcTestKeyPair", code: 2)
        }
        let x = x963.subdata(in: 1..<33)
        let y = x963.subdata(in: 33..<65)
        let jwk = IOSChatGptSiwcJwk(
            kty: "EC",
            kid: kid,
            alg: "ES256",
            use: "sig",
            n: nil,
            e: nil,
            crv: "P-256",
            x: base64URL(x),
            y: base64URL(y)
        )
        return SiwcTestKeyPair(
            privateKey: privateKey,
            jwk: jwk,
            alg: "ES256",
            secAlg: .ecdsaSignatureMessageX962SHA256,
            isEC: true
        )
    }

    func signJWT(payload: [String: Any]) throws -> String {
        let header: [String: Any] = ["alg": alg, "typ": "JWT", "kid": jwk.kid ?? ""]
        let headerB64 = Self.base64URL(try JSONSerialization.data(withJSONObject: header))
        let payloadB64 = Self.base64URL(try JSONSerialization.data(withJSONObject: payload))
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)

        var error: Unmanaged<CFError>?
        guard let rawSig = SecKeyCreateSignature(privateKey, secAlg, signingInput as CFData, &error) as Data? else {
            throw NSError(domain: "SiwcTestKeyPair", code: 3)
        }
        let jwtSig = isEC ? try Self.derECDSASignatureToRaw(rawSig, coordinateBytes: 32) : rawSig
        return "\(headerB64).\(payloadB64).\(Self.base64URL(jwtSig))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parsePKCS1RSAPublicKey(_ der: Data) throws -> (Data, Data) {
        let bytes = [UInt8](der)
        var offset = 0
        guard bytes[offset] == 0x30 else { throw NSError(domain: "DER", code: 1) }
        offset += 1
        _ = readDERLength(bytes, offset: &offset)
        let modulus = try readDERInteger(bytes, offset: &offset)
        let exponent = try readDERInteger(bytes, offset: &offset)
        return (modulus, exponent)
    }

    private static func derECDSASignatureToRaw(_ der: Data, coordinateBytes: Int) throws -> Data {
        let bytes = [UInt8](der)
        var offset = 0
        guard bytes[offset] == 0x30 else { throw NSError(domain: "DER", code: 2) }
        offset += 1
        _ = readDERLength(bytes, offset: &offset)
        let r = try readDERInteger(bytes, offset: &offset)
        let s = try readDERInteger(bytes, offset: &offset)
        return fixedWidth(r, length: coordinateBytes) + fixedWidth(s, length: coordinateBytes)
    }

    private static func readDERLength(_ bytes: [UInt8], offset: inout Int) -> Int {
        let first = Int(bytes[offset])
        offset += 1
        if first < 0x80 { return first }
        let count = first & 0x7F
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }

    private static func readDERInteger(_ bytes: [UInt8], offset: inout Int) throws -> Data {
        guard bytes[offset] == 0x02 else { throw NSError(domain: "DER", code: 3) }
        offset += 1
        let length = readDERLength(bytes, offset: &offset)
        var slice = Data(bytes[offset..<(offset + length)])
        offset += length
        while slice.count > 1 && slice.first == 0x00 {
            slice.removeFirst()
        }
        return slice
    }

    private static func fixedWidth(_ data: Data, length: Int) -> Data {
        if data.count == length { return data }
        if data.count < length { return Data(repeating: 0, count: length - data.count) + data }
        return Data(data.suffix(length))
    }
}
