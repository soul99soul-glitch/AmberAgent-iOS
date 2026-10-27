import AmberPhoneControl
import CryptoKit
import Foundation
import XCTest
@testable import iosApp

actor ReadinessSessionStub: IOSPhoneControlSessionServing {
    let fixture: ReadinessHTTPFixture
    let failStartup: Bool
    let blockStartup: Bool
    private var client: PhoneRunnerClient?
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    private(set) var startedScopes: [Set<String>] = []
    private(set) var connectionModes: [IOSPhoneControlConnectionMode] = []
    private(set) var endpoints: [String] = []

    init(fixture: ReadinessHTTPFixture, failStartup: Bool = false, blockStartup: Bool = false) {
        self.fixture = fixture
        self.failStartup = failStartup
        self.blockStartup = blockStartup
    }

    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus {
        startedScopes.append(configuration.allowedBundleIDs)
        connectionModes.append(configuration.connectionMode)
        endpoints.append(configuration.endpoint)
        started?.resume()
        started = nil
        if blockStartup { await withCheckedContinuation { blocked = $0 } }
        try Task.checkCancellation()
        if failStartup {
            let status = try JSONDecoder().decode(PhoneControlLaunchStatus.self,
                from: Data(#"{"phase":"failed","code":"ddi_not_ready","message":"开发映像尚未就绪"}"#.utf8))
            throw PhoneControlSessionError.nativeLaunch(status)
        }
        let configurationHTTP = URLSessionConfiguration.ephemeral
        configurationHTTP.protocolClasses = [ReadinessHTTPProtocol.self]
        let client = try PhoneRunnerClient(token: String(repeating: "a", count: 64),
            allowedBundleIDs: configuration.allowedBundleIDs, port: fixture.port, sessionConfiguration: configurationHTTP)
        self.client = client
        return try await client.status()
    }

    func runner(runID: UUID) throws -> PhoneRunnerClient { try XCTUnwrap(client) }
    func stop(runID: UUID) async {
        fixture.recordStop()
        await client?.stop()
    }
    func launchStatus(runID: UUID) -> PhoneControlLaunchStatus? { nil }
    func cachedApplications(runID: UUID) -> [PhoneControlInstalledApp] { [] }
    func waitUntilStarted() async {
        if !startedScopes.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseStartup() { blocked?.resume(); blocked = nil }
}

final class ReadinessHTTPFixture: @unchecked Sendable {
    let port: UInt16
    let bundleID: String
    let failSource: Bool
    let activatedBundleID: String?
    let failActivation: Bool
    let sourceBody: String?
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var recordedEvents: [String] = []
    private var activated = false
    private var validRequests = true
    var paths: [String] { lock.withLock { recordedPaths } }
    var events: [String] { lock.withLock { recordedEvents } }
    var onlySignedGETRequests: Bool { lock.withLock { validRequests } }

    init(bundleID: String, failSource: Bool = false, activatedBundleID: String? = nil,
         failActivation: Bool = false, sourceBody: String? = nil) {
        self.bundleID = bundleID
        self.failSource = failSource
        self.activatedBundleID = activatedBundleID
        self.failActivation = failActivation
        self.sourceBody = sourceBody
        port = ReadinessHTTPProtocol.nextPort()
        ReadinessHTTPProtocol.register(self)
    }
    func unregister() { ReadinessHTTPProtocol.remove(port) }
    func recordStop() { lock.withLock { recordedEvents.append("stop") } }
    func body(for request: URLRequest) throws -> String {
        let path = try XCTUnwrap(request.url?.path)
        lock.withLock {
            recordedPaths.append(path)
            recordedEvents.append(path)
            validRequests = validRequests && request.httpMethod == "GET"
                && request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("IPU-HMAC-SHA256 ") == true
        }
        switch path {
        case "/status": return #"{"value":{"ready":true,"sessionId":"check","auth":{"required":true,"scheme":"IPU-HMAC-SHA256"}}}"#
        case "/wda/activeAppInfo":
            let currentBundleID = lock.withLock { activated ? activatedBundleID ?? bundleID : bundleID }
            return "{\"value\":{\"bundleId\":\"\(currentBundleID)\",\"pid\":42}}"
        case "/wda/apps/activate" where activatedBundleID != nil:
            if failActivation { throw URLError(.networkConnectionLost) }
            lock.withLock { activated = true }
            return #"{"value":null}"#
        case "/window/size": return #"{"value":{"width":393,"height":852}}"#
        case "/source":
            if failSource { throw URLError(.cannotConnectToHost) }
            if let sourceBody { return sourceBody }
            return #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":393,"height":852},"children":[]}}"#
        default: XCTFail("Unexpected check request: \(path)"); throw URLError(.badURL)
        }
    }
}

private final class ReadinessHTTPProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var port: UInt16 = 32_000
        var fixtures: [UInt16: ReadinessHTTPFixture] = [:]
    }
    private static let registry = Registry()
    static func nextPort() -> UInt16 { registry.lock.withLock { registry.port += 1; return registry.port } }
    static func register(_ fixture: ReadinessHTTPFixture) { registry.lock.withLock { registry.fixtures[fixture.port] = fixture } }
    static func remove(_ port: UInt16) { _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: port) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock { request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] } }
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        do {
            let body = try fixture.body(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0"
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
