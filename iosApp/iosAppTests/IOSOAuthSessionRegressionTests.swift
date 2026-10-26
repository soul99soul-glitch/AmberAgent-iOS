import XCTest
@testable import iosApp

@MainActor
final class IOSOAuthSessionRegressionTests: XCTestCase {
    func testAntigravityOnboardingCannotRestoreLoggedOutSession() async throws {
        let providerId = UUID().uuidString
        let gate = OAuthRegressionResponseGate(body: #"{"cloudaicompanionProject":"project-A","currentTier":{"id":"FREE"}}"#)
        let session = makeSession(providerId: providerId, gate: gate)
        defer { cleanup(providerId: providerId, session: session, gate: gate) }
        XCTAssertTrue(IOSAntigravityAuthStore.save(providerId: providerId, tokens: antigravityTokens("A")))
        let client = IOSAntigravityOAuthClient(providerId: providerId, session: session)
        let task = Task { try await client.ensureOnboarded() }
        let didStart = await gate.waitForRequest()
        XCTAssertTrue(didStart)
        client.logout()
        gate.release.signal()
        do {
            _ = try await task.value
            XCTFail("Onboarding from a logged-out session must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(IOSAntigravityAuthStore.load(providerId: providerId))
    }

    func testAntigravityOnboardingDoesNotOverwriteSameSessionRefresh() async throws {
        let providerId = UUID().uuidString
        let gate = OAuthRegressionResponseGate(body: #"{"cloudaicompanionProject":"project-A","currentTier":{"id":"FREE"}}"#)
        let session = makeSession(providerId: providerId, gate: gate)
        defer { cleanup(providerId: providerId, session: session, gate: gate) }
        let original = antigravityTokens("A")
        XCTAssertTrue(IOSAntigravityAuthStore.save(providerId: providerId, tokens: original))
        let client = IOSAntigravityOAuthClient(providerId: providerId, session: session)
        let task = Task { try await client.ensureOnboarded() }
        let didStart = await gate.waitForRequest()
        XCTAssertTrue(didStart)
        let refreshed = antigravityTokens("A-refreshed")
        _ = try IOSAntigravityOAuthClients.persist(
            providerId: providerId, tokens: refreshed,
            generation: IOSAntigravityOAuthClients.generation(providerId: providerId), replacing: original
        )
        gate.release.signal()
        let onboarded = try await task.value
        XCTAssertEqual(onboarded.accessToken, refreshed.accessToken)
        XCTAssertEqual(onboarded.refreshToken, refreshed.refreshToken)
        XCTAssertEqual(onboarded.projectId, "project-A")
        XCTAssertEqual(onboarded.onboardedTier, "FREE")
        XCTAssertEqual(IOSAntigravityAuthStore.load(providerId: providerId), onboarded)
    }

    func testAntigravityOldRefreshCannotInvalidateNewLogin() async throws {
        let providerId = UUID().uuidString
        let gate = OAuthRegressionResponseGate(status: 400, body: #"{"error":"invalid_grant"}"#)
        let session = makeSession(providerId: providerId, gate: gate)
        defer { cleanup(providerId: providerId, session: session, gate: gate) }
        XCTAssertTrue(IOSAntigravityAuthStore.save(providerId: providerId, tokens: antigravityTokens("A")))
        let client = IOSAntigravityOAuthClient(providerId: providerId, session: session)
        let task = Task { try await client.refresh() }
        let didStart = await gate.waitForRequest()
        XCTAssertTrue(didStart)
        client.logout()
        let replacement = antigravityTokens("B")
        XCTAssertTrue(IOSAntigravityAuthStore.save(providerId: providerId, tokens: replacement))
        gate.release.signal()
        do { _ = try await task.value; XCTFail("Expected the old refresh to fail") } catch {}
        XCTAssertEqual(IOSAntigravityAuthStore.load(providerId: providerId), replacement)
    }

    func testGrokOldRefreshCannotInvalidateNewLogin() async throws {
        let providerId = UUID().uuidString
        let gate = OAuthRegressionResponseGate(status: 400, body: #"{"error":"invalid_grant"}"#)
        let session = makeSession(providerId: providerId, gate: gate)
        defer { cleanup(providerId: providerId, session: session, gate: gate) }
        let original = grokTokens("A")
        XCTAssertTrue(IOSGrokOAuthAuthStore.save(providerId: providerId, tokens: original))
        let client = IOSGrokOAuthClient(providerId: providerId, session: session)
        let task = Task { try await client.refresh() }
        let didStart = await gate.waitForRequest()
        XCTAssertTrue(didStart)
        client.logout()
        let replacement = grokTokens("B")
        XCTAssertTrue(IOSGrokOAuthAuthStore.save(providerId: providerId, tokens: replacement))
        gate.release.signal()
        do { _ = try await task.value; XCTFail("Expected the old refresh to fail") } catch {}
        XCTAssertEqual(IOSGrokOAuthAuthStore.load(providerId: providerId), replacement)
    }

    private func antigravityTokens(_ account: String) -> IOSAntigravityAuthTokens {
        IOSAntigravityAuthTokens(
            accessToken: "access-\(account)", refreshToken: "refresh-\(account)",
            expiresAtMillis: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000
        )
    }

    private func grokTokens(_ account: String) -> IOSGrokOAuthTokens {
        IOSGrokOAuthTokens(
            accessToken: "access-\(account)", refreshToken: "refresh-\(account)",
            expiresAtMillis: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000
        )
    }

    private func makeSession(providerId: String, gate: OAuthRegressionResponseGate) -> URLSession {
        OAuthRegressionURLProtocol.register(gate, for: providerId)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthRegressionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Amber-Auth-Regression": providerId]
        return URLSession(configuration: configuration)
    }

    private func cleanup(providerId: String, session: URLSession, gate: OAuthRegressionResponseGate) {
        gate.release.signal()
        session.invalidateAndCancel()
        IOSAntigravityOAuthClients.logout(providerId: providerId)
        IOSGrokOAuthClients.logout(providerId: providerId)
        OAuthRegressionURLProtocol.unregister(providerId)
    }
}

private final class OAuthRegressionResponseGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func waitForRequest() async -> Bool {
        let wait: @Sendable () -> Bool = { self.started.wait(timeout: .now() + 2) == .success }
        return await Task.detached { wait() }.value
    }
}

private final class OAuthRegressionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: OAuthRegressionResponseGate] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    private var gate: OAuthRegressionResponseGate?

    static func register(_ gate: OAuthRegressionResponseGate, for providerId: String) {
        lock.lock(); defer { lock.unlock() }
        gates[providerId] = gate
    }

    static func unregister(_ providerId: String) {
        lock.lock(); defer { lock.unlock() }
        gates[providerId] = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let gate = request.value(forHTTPHeaderField: "X-Amber-Auth-Regression").flatMap { Self.gates[$0] }
        Self.lock.unlock()
        guard let gate else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        stateLock.lock()
        self.gate = gate
        stateLock.unlock()
        DispatchQueue.global().async { [self] in
            gate.started.signal()
            gate.release.wait()
            stateLock.lock()
            let stopped = self.stopped
            stateLock.unlock()
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: gate.status, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(gate.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let gate = self.gate
        stateLock.unlock()
        gate?.release.signal()
    }
}
