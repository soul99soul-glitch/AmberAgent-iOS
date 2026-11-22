import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AmberMac

private final class InMemorySIWCSecretStore: DesktopSIWCSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func load(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    @discardableResult
    func store(key: String, value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
        return true
    }

    @discardableResult
    func delete(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
        return true
    }
}

final class DesktopChatGPTSIWCTests: XCTestCase {
    private func connect(to server: DesktopSIWCLoopbackServer) throws -> FileHandle {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = server.port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { throw POSIXError(.ECONNREFUSED) }
        return handle
    }

    func testLoopbackIgnoresOtherRequestsAndReadsFragmentedCallback() async throws {
        let server = DesktopSIWCLoopbackServer()
        _ = try server.start()
        let waiter = Task { try await server.waitForCallback(state: "wanted", timeout: 5) }
        defer { waiter.cancel() }
        for (target, status) in [("/favicon.ico", 404), ("/auth/callback?state=old&error=access_denied", 400)] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(target)"))
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
        }
        let client = try connect(to: server)
        try client.write(contentsOf: Data("GET /auth/call".utf8))
        try await Task.sleep(for: .milliseconds(30))
        try client.write(contentsOf: Data("back?state=wanted&code=local HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let payload = try await waiter.value
        XCTAssertEqual(payload.code, "local")
        let response = try XCTUnwrap(try client.readToEnd())
        let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(header.contains("Content-Length: \(response.count - separator.upperBound)\r\n"))
        XCTAssertThrowsError(try connect(to: server))
    }

    func testLoopbackReleasesIdleConnectionOnDeadlineAndCancellation() async throws {
        for cancel in [false, true] {
            let server = DesktopSIWCLoopbackServer()
            _ = try server.start()
            let client = try connect(to: server)
            let waiter = Task { try await server.waitForCallback(state: "wanted", timeout: cancel ? 5 : 0.15) }
            try client.write(contentsOf: Data("GET ".utf8))
            let start = ContinuousClock.now
            if cancel { try await Task.sleep(for: .milliseconds(50)); waiter.cancel() }
            do { _ = try await waiter.value; XCTFail("Expected the wait to end without a callback") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch DesktopSIWCError.timedOut { XCTAssertFalse(cancel) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            XCTAssertThrowsError(try connect(to: server))
        }
    }

    private func makeES256Fixture(
        kid: String = "test-ec-key-1",
        claims: [String: Any]
    ) throws -> (jwt: String, jwks: DesktopSIWCJWKS) {
        let privateKey = P256.Signing.PrivateKey()
        let rawPub = privateKey.publicKey.rawRepresentation
        let x = DesktopSIWCJWTVerifier.base64URLEncode(rawPub.prefix(32))
        let y = DesktopSIWCJWTVerifier.base64URLEncode(rawPub.suffix(32))
        let jwk = DesktopSIWCJWK(kty: "EC", kid: kid, alg: "ES256", use: "sig", n: nil, e: nil, crv: "P-256", x: x, y: y)

        let headerData = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": kid])
        let payloadData = try JSONSerialization.data(withJSONObject: claims)
        let signingInput = "\(DesktopSIWCJWTVerifier.base64URLEncode(headerData)).\(DesktopSIWCJWTVerifier.base64URLEncode(payloadData))"
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        let jwt = "\(signingInput).\(DesktopSIWCJWTVerifier.base64URLEncode(signature))"
        return (jwt, DesktopSIWCJWKS(keys: [jwk]))
    }

    func testPersistentExtAgentHostIDIsStableAndOpaque() throws {
        let store = InMemorySIWCSecretStore()
        let first = try DesktopSIWCAuthStore.getOrCreateExtAgentHostID(store: store)
        let second = try DesktopSIWCAuthStore.getOrCreateExtAgentHostID(store: store)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("urn:uuid:"))
        XCTAssertFalse(first.contains("@"))
    }

    func testAuthorizationURLDynamicRegistrationVsRelogin() {
        let dynamicURL = DesktopChatGPTSIWCClient.buildAuthorizationURL(
            redirectURI: "http://127.0.0.1:43210/auth/callback",
            codeChallenge: "challenge123",
            state: "state123",
            nonce: "nonce123",
            extAgentHostID: "urn:uuid:11111111-2222-4333-8444-555555555555",
            savedClientID: nil
        )
        let dynamicQuery = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: dynamicURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(dynamicURL.host, "auth.openai.com")
        XCTAssertEqual(dynamicURL.path, "/api/accounts/authorize")
        XCTAssertEqual(dynamicQuery["client_id"], "dynamic_agent_client")
        XCTAssertEqual(dynamicQuery["agent_name_hint"], "Amber")
        XCTAssertEqual(dynamicQuery["ext_agent_host_id"], "urn:uuid:11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(dynamicQuery["redirect_uri"], "http://127.0.0.1:43210/auth/callback")
        XCTAssertEqual(dynamicQuery["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(dynamicQuery["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(dynamicQuery["code_challenge_method"], "S256")
        XCTAssertNil(dynamicQuery["id_token_hint"])
        XCTAssertNil(dynamicQuery["login_hint"])

        let reloginURL = DesktopChatGPTSIWCClient.buildAuthorizationURL(
            redirectURI: "http://127.0.0.1:43210/auth/callback",
            codeChallenge: "challenge456",
            state: "state456",
            nonce: "nonce456",
            extAgentHostID: "urn:uuid:11111111-2222-4333-8444-555555555555",
            savedClientID: "oaiapp_issued_abc",
            idTokenHint: "prev.id.token",
            loginHint: "user@example.com"
        )
        let reloginQuery = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: reloginURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(reloginQuery["client_id"], "oaiapp_issued_abc")
        XCTAssertNil(reloginQuery["agent_name_hint"])
        XCTAssertEqual(reloginQuery["id_token_hint"], "prev.id.token")
        XCTAssertEqual(reloginQuery["login_hint"], "user@example.com")
    }

    func testDynamicClientIDIsNeverPersisted() {
        let store = InMemorySIWCSecretStore()
        let bad = DesktopSIWCCredentials(
            accessToken: "at",
            refreshToken: "rt",
            idToken: nil,
            clientId: "dynamic_agent_client",
            extAgentHostId: "urn:uuid:11111111-2222-4333-8444-555555555555",
            expiresAtMillis: 9999999999999,
            earliestRefreshAtMillis: 9999999999000,
            scopes: DesktopChatGPTSIWCConstants.scopes,
            subject: "sub-1",
            email: "a@b.com",
            name: nil,
            planType: "plus"
        )
        XCTAssertThrowsError(try DesktopSIWCAuthStore.retainClientID(bad.clientId, providerId: "p1", store: store))
        XCTAssertThrowsError(try DesktopSIWCAuthStore.save(providerId: "p1", credentials: bad, store: store))
        XCTAssertNil(DesktopSIWCAuthStore.load(providerId: "p1", store: store))
        XCTAssertNil(DesktopSIWCAuthStore.loadClientID(providerId: "p1", store: store))
    }

    func testEndToEndLoopbackSignInRefreshRotationAndRelogin() async throws {
        let store = InMemorySIWCSecretStore()
        let providerId = UUID().uuidString.lowercased()
        let nowBox = LockedBox<Int64>(1_800_000_000_000)
        let capturedAuthURLs = LockedBox<[URL]>([])
        let capturedTokenForms = LockedBox<[String]>([])
        let capturedNonce = LockedBox<String?>(nil)
        let failFirstExchange = LockedBox(true)
        let keysAvailable = LockedBox(true)
        let revoked = LockedBox<String?>(nil)
        let callbackClientID = LockedBox("oaiapp_issued_001")
        let subject = LockedBox("user_sub_42")

        let fixturePrivateKey = P256.Signing.PrivateKey()
        let rawPub = fixturePrivateKey.publicKey.rawRepresentation
        let jwk = DesktopSIWCJWK(
            kty: "EC", kid: "k1", alg: "ES256", use: "sig", n: nil, e: nil, crv: "P-256",
            x: DesktopSIWCJWTVerifier.base64URLEncode(rawPub.prefix(32)),
            y: DesktopSIWCJWTVerifier.base64URLEncode(rawPub.suffix(32))
        )
        let jwksData = try JSONEncoder().encode(DesktopSIWCJWKS(keys: [jwk]))

        let signIDToken: @Sendable (String, String?, Double) throws -> String = { clientId, nonce, exp in
            var claims: [String: Any] = [
                "iss": "https://auth.openai.com",
                "aud": [clientId],
                "sub": subject.withLock { $0 },
                "email": "siwc@example.com",
                "name": "SIWC Tester",
                "exp": exp,
                "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
            ]
            if let nonce { claims["nonce"] = nonce }
            let headerData = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": "k1"])
            let payloadData = try JSONSerialization.data(withJSONObject: claims)
            let input = "\(DesktopSIWCJWTVerifier.base64URLEncode(headerData)).\(DesktopSIWCJWTVerifier.base64URLEncode(payloadData))"
            let sig = try fixturePrivateKey.signature(for: Data(input.utf8)).rawRepresentation
            return "\(input).\(DesktopSIWCJWTVerifier.base64URLEncode(sig))"
        }

        let client = DesktopChatGPTSIWCClient(
            providerId: providerId,
            secretStore: store,
            transport: { request in
                let url = request.url!
                if url.absoluteString == DesktopChatGPTSIWCConstants.jwksEndpoint {
                    guard keysAvailable.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (jwksData, resp)
                }
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if url.absoluteString == DesktopChatGPTSIWCConstants.revocationEndpoint {
                    revoked.withLock { $0 = body }
                    return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                capturedTokenForms.withLock { $0.append(body) }
                if failFirstExchange.withLock({ value in defer { value = false }; return value }) {
                    return (Data(#"{"error":"invalid_grant"}"#.utf8),
                            HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
                }
                let isRefresh = body.contains("grant_type=refresh_token")
                let nowSec = Double(nowBox.withLock { $0 }) / 1000.0
                let idToken = try signIDToken(
                    "oaiapp_issued_001",
                    isRefresh ? nil : capturedNonce.withLock { $0 },
                    nowSec + 3600
                )
                let tokenPayload: [String: Any] = [
                    "access_token": isRefresh ? "at_refreshed_2" : "at_initial_1",
                    "refresh_token": isRefresh ? "rt_rotated_2" : "rt_initial_1",
                    "id_token": idToken,
                    "expires_in": 3600,
                    "earliest_refresh_at": nowSec + 60,
                    "scope": DesktopChatGPTSIWCConstants.scopeString,
                ]
                let data = try JSONSerialization.data(withJSONObject: tokenPayload)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            },
            openBrowser: { authURL in
                capturedAuthURLs.withLock { $0.append(authURL) }
                let items = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                )
                capturedNonce.withLock { $0 = items["nonce"] }
                guard let redirectURI = items["redirect_uri"],
                      let state = items["state"] else { return false }
                let callbackURLString = "\(redirectURI)?code=auth_code_xyz&state=\(state)&client_id=\(callbackClientID.withLock { $0 })"
                guard let callbackURL = URL(string: callbackURLString) else { return false }
                Task.detached {
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
                return true
            },
            nowMillis: { nowBox.withLock { $0 } }
        )

        do {
            _ = try await client.signIn(timeout: 10)
            XCTFail("Expected the first code exchange to fail")
        } catch DesktopSIWCError.tokenExchangeFailed {}
        XCTAssertEqual(DesktopSIWCAuthStore.loadClientID(providerId: providerId, store: store), "oaiapp_issued_001")
        XCTAssertNil(DesktopSIWCAuthStore.load(providerId: providerId, store: store))

        // Retry after the failed code exchange uses the registration already issued.
        let account = try await client.signIn(timeout: 10)
        XCTAssertFalse(try XCTUnwrap(capturedAuthURLs.withLock { $0.last }).absoluteString.contains("agent_name_hint"))
        XCTAssertEqual(account.email, "siwc@example.com")
        XCTAssertEqual(account.plan, "plus")
        XCTAssertTrue(account.planAvailable)

        let saved = try XCTUnwrap(DesktopSIWCAuthStore.load(providerId: providerId, store: store))
        XCTAssertEqual(saved.clientId, "oaiapp_issued_001")
        XCTAssertEqual(saved.accessToken, "at_initial_1")
        XCTAssertEqual(saved.refreshToken, "rt_initial_1")

        let firstForm = try XCTUnwrap(capturedTokenForms.withLock { $0.first })
        XCTAssertTrue(firstForm.contains("client_id=oaiapp_issued_001"))
        XCTAssertTrue(firstForm.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
        XCTAssertFalse(firstForm.contains("client_secret="))

        // Permission to refresh has started, but this access token is still fresh.
        nowBox.withLock { $0 += 120_000 }
        let cachedToken = try await client.getValidAccessToken()
        XCTAssertEqual(cachedToken, "at_initial_1")

        // 3. Advance clock past expiry -> refreshes and rotates refresh_token
        nowBox.withLock { $0 += 3_700_000 }
        keysAvailable.withLock { $0 = false }
        do {
            _ = try await client.getValidAccessToken()
            XCTFail("Cannot use the replacement until its ID token is verified")
        } catch DesktopSIWCError.jwksUnavailable {}
        keysAvailable.withLock { $0 = true }
        async let tokenA = client.getValidAccessToken()
        async let tokenB = client.getValidAccessToken()
        let refreshed = try await [tokenA, tokenB]
        XCTAssertEqual(refreshed, ["at_refreshed_2", "at_refreshed_2"])
        XCTAssertEqual(capturedTokenForms.withLock { $0.filter { $0.contains("grant_type=refresh_token") }.count }, 1)
        let rotated = try XCTUnwrap(DesktopSIWCAuthStore.load(providerId: providerId, store: store))
        XCTAssertEqual(rotated.refreshToken, "rt_rotated_2")

        // 4. Re-login reuses saved client_id, omits agent_name_hint, includes id_token_hint & login_hint
        _ = try await client.signIn(timeout: 10)
        let secondAuthURL = try XCTUnwrap(capturedAuthURLs.withLock { $0.last })
        let secondItems = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: secondAuthURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(secondItems["client_id"], "oaiapp_issued_001")
        XCTAssertNil(secondItems["agent_name_hint"])
        XCTAssertNotNil(secondItems["id_token_hint"])
        XCTAssertEqual(secondItems["login_hint"], "siwc@example.com")

        let exchanges = capturedTokenForms.withLock { $0.count }
        callbackClientID.withLock { $0 = "different_registration" }
        do {
            _ = try await client.signIn(timeout: 10)
            XCTFail("A reconnect must stay on its registration")
        } catch is DesktopSIWCError {}
        XCTAssertEqual(capturedTokenForms.withLock { $0.count }, exchanges)

        let hostID = saved.extAgentHostId
        try await client.endSession()
        XCTAssertTrue(revoked.withLock { $0?.contains("token=rt_initial_1") == true })
        XCTAssertNil(DesktopSIWCAuthStore.load(providerId: providerId, store: store))
        XCTAssertEqual(DesktopSIWCAuthStore.loadClientID(providerId: providerId, store: store), saved.clientId)
        callbackClientID.withLock { $0 = saved.clientId }
        subject.withLock { $0 = "different_subject" }
        do {
            _ = try await client.signIn(timeout: 10)
            XCTFail("The registration must retain its verified subject through logout")
        } catch DesktopSIWCError.identityMismatch {}
        try await client.endSession(deleteRegistration: true)
        XCTAssertNil(DesktopSIWCAuthStore.loadClientID(providerId: providerId, store: store))
        XCTAssertEqual(try DesktopSIWCAuthStore.getOrCreateExtAgentHostID(store: store), hostID)
    }

    func testMissingDirectTokenSharingScopeKeepsLoginButMarksPlanUnavailable() async throws {
        let store = InMemorySIWCSecretStore()
        let providerId = UUID().uuidString.lowercased()
        let nowSec = Date().timeIntervalSince1970
        let capturedNonce = LockedBox<String?>(nil)
        let privateKey = P256.Signing.PrivateKey()
        let rawPub = privateKey.publicKey.rawRepresentation
        let jwk = DesktopSIWCJWK(
            kty: "EC", kid: "k2", alg: "ES256", use: "sig", n: nil, e: nil, crv: "P-256",
            x: DesktopSIWCJWTVerifier.base64URLEncode(rawPub.prefix(32)),
            y: DesktopSIWCJWTVerifier.base64URLEncode(rawPub.suffix(32))
        )
        let jwksData = try JSONEncoder().encode(DesktopSIWCJWKS(keys: [jwk]))

        let client = DesktopChatGPTSIWCClient(
            providerId: providerId,
            secretStore: store,
            transport: { request in
                let url = request.url!
                if url.absoluteString == DesktopChatGPTSIWCConstants.jwksEndpoint {
                    return (jwksData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let claims: [String: Any] = [
                    "iss": "https://auth.openai.com",
                    "aud": "oaiapp_no_plan",
                    "sub": "sub_no_plan",
                    "email": "free@example.com",
                    "nonce": capturedNonce.withLock { $0 } ?? "",
                    "exp": nowSec + 3600,
                ]
                let headerData = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "k2"])
                let payloadData = try JSONSerialization.data(withJSONObject: claims)
                let input = "\(DesktopSIWCJWTVerifier.base64URLEncode(headerData)).\(DesktopSIWCJWTVerifier.base64URLEncode(payloadData))"
                let sig = try privateKey.signature(for: Data(input.utf8)).rawRepresentation
                let idToken = "\(input).\(DesktopSIWCJWTVerifier.base64URLEncode(sig))"
                let body: [String: Any] = [
                    "id_token": idToken,
                    "scope": "openid profile email",
                ]
                return (try JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            openBrowser: { authURL in
                let items = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                )
                capturedNonce.withLock { $0 = items["nonce"] }
                guard let redirect = items["redirect_uri"], let state = items["state"],
                      let cb = URL(string: "\(redirect)?code=c1&state=\(state)&client_id=oaiapp_no_plan") else { return false }
                Task.detached { _ = try? await URLSession.shared.data(from: cb) }
                return true
            }
        )

        let account = try await client.signIn(timeout: 10)
        XCTAssertFalse(account.planAvailable)
        XCTAssertNotNil(DesktopSIWCAuthStore.load(providerId: providerId, store: store))

        do {
            _ = try await client.getValidAccessToken()
            XCTFail("Expected planScopeUnavailable error")
        } catch let error as DesktopSIWCError {
            XCTAssertEqual(error, .planScopeUnavailable)
        }
    }

    func testJWTVerifierRejectsBadIssuerAudienceNonceAndExpiry() throws {
        let now = Date().timeIntervalSince1970
        let valid = try makeES256Fixture(claims: [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_123",
            "sub": "sub_1",
            "nonce": "n_ok",
            "exp": now + 600,
        ])
        let parsed = try DesktopSIWCJWTVerifier.verify(
            idToken: valid.jwt,
            expectedClientID: "oaiapp_123",
            expectedNonce: "n_ok",
            jwks: valid.jwks,
            nowSeconds: now
        )
        XCTAssertEqual(parsed.subject, "sub_1")
        XCTAssertThrowsError(try DesktopSIWCJWTVerifier.verify(
            idToken: valid.jwt, expectedIssuer: "https://other.example", expectedClientID: "oaiapp_123",
            expectedNonce: "n_ok", jwks: valid.jwks, nowSeconds: now))

        XCTAssertThrowsError(try DesktopSIWCJWTVerifier.verify(
            idToken: valid.jwt,
            expectedClientID: "wrong_client",
            expectedNonce: "n_ok",
            jwks: valid.jwks,
            nowSeconds: now
        ))
        XCTAssertThrowsError(try DesktopSIWCJWTVerifier.verify(
            idToken: valid.jwt,
            expectedClientID: "oaiapp_123",
            expectedNonce: "wrong_nonce",
            jwks: valid.jwks,
            nowSeconds: now
        ))
        XCTAssertThrowsError(try DesktopSIWCJWTVerifier.verify(
            idToken: valid.jwt,
            expectedClientID: "oaiapp_123",
            expectedNonce: "n_ok",
            jwks: valid.jwks,
            nowSeconds: now + 900
        ))
    }

    @MainActor
    func testFirstTimePlanConfirmationShowsOnlyOnceAndPersists() async {
        final class StubAuthorizer: DesktopSIWCAuthorizer {
            var nextAccount: DesktopSIWCAccount
            init(_ nextAccount: DesktopSIWCAccount) { self.nextAccount = nextAccount }
            func account(providerID: UUID) -> DesktopSIWCAccount? { nil }
            func signIn(providerID: UUID) async throws -> DesktopSIWCAccount { nextAccount }
            func logout(providerID: UUID) async throws {}
            func deleteProvider(providerID: UUID) async throws {}
        }

        let suiteName = "amber.siwc.confirm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authorizer = StubAuthorizer(DesktopSIWCAccount(email: "a@b.com", name: nil, subject: "s1", plan: "plus", planAvailable: true))
        let login = DesktopSIWCLogin(authorizer: authorizer, defaults: defaults)
        let id = UUID()

        login.login(id)
        await login.waitUntilIdle()
        XCTAssertTrue(login.showFirstTimePlanConfirmation)

        login.acknowledgePlanConfirmation()
        XCTAssertFalse(login.showFirstTimePlanConfirmation)
        XCTAssertTrue(defaults.bool(forKey: DesktopChatGPTSIWCConstants.planConfirmedDefaultsKey))

        // Second login with a fresh controller using same UserDefaults must NOT show the prompt again.
        let second = DesktopSIWCLogin(authorizer: authorizer, defaults: defaults)
        second.login(id)
        await second.waitUntilIdle()
        XCTAssertFalse(second.showFirstTimePlanConfirmation)
    }

    @MainActor
    func testSettingsPinsSIWCEndpointAndAllowsEmptyModelsBeforeLogin() throws {
        let suiteName = "amber.siwc.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())

        let valid = DesktopProviderConfiguration(
            name: "OpenAI",
            kind: .responses,
            baseURL: "https://custom.ignored.example/v1",
            models: [],
            authMode: .chatgptSiwc
        )
        try settings.saveProvider(valid, apiKey: "")
        let saved = try XCTUnwrap(settings.providers.first { $0.id == valid.id })
        XCTAssertEqual(saved.authMode, .chatgptSiwc)
        XCTAssertEqual(saved.baseURL, "https://api.openai.com/v1")

        let invalid = DesktopProviderConfiguration(
            name: "Wrong Protocol",
            kind: .openAI,
            baseURL: "https://api.openai.com/v1",
            models: [],
            authMode: .chatgptSiwc
        )
        XCTAssertThrowsError(try settings.saveProvider(invalid, apiKey: ""))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
