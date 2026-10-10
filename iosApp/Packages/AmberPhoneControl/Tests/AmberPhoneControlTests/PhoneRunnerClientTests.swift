import Foundation
import XCTest
@testable import AmberPhoneControl

final class PhoneRunnerClientTests: XCTestCase, @unchecked Sendable {
    private let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    func testSigningMatchesPinnedRunnerKnownAnswer() {
        XCTAssertEqual(RunnerSigning.authorization(
            token: token, method: "post", target: "/session/S/actions?x=1",
            body: Data(#"{"a":1}"#.utf8), timestamp: 1_700_000_000,
            nonce: "0123456789abcdef0123456789abcdef"
        ), "IPU-HMAC-SHA256 ts=1700000000, nonce=0123456789abcdef0123456789abcdef, sig=d45cade8fef49833329384ea5669106fce22a98fcc182db1ff3dc0eb946e6e11")
    }

    func testSignatureCoversExactlyEncodedQueryAndSortedBody() async throws {
        let fixture = Fixture([.json("POST", "/custom", #"{"value":null}"#)])
        let http = RunnerHTTP(token: token, port: fixture.port, configuration: fixture.configuration)
        _ = try await http.request(method: "POST", path: "/custom", query: ["z": "x/y", "a": "two words"],
                                   body: .object(["z": .number(1), "a": .string("/hello")]))
        let request = try XCTUnwrap(fixture.requests.first)
        let body = request.body
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"a":"/hello","z":1}"#)
        XCTAssertEqual(request.url.query, "a=two%20words&z=x/y")
        let authorization = try XCTUnwrap(request.authorization)
        let pieces = authorization.replacingOccurrences(of: "IPU-HMAC-SHA256 ", with: "")
            .components(separatedBy: ", ")
        let timestamp = try XCTUnwrap(Int64(pieces[0].dropFirst(3)))
        let nonce = String(pieces[1].dropFirst(6))
        XCTAssertEqual(authorization, RunnerSigning.authorization(
            token: token, method: "POST", target: "/custom?a=two%20words&z=x/y",
            body: body, timestamp: timestamp, nonce: nonce
        ))
        XCTAssertFalse(authorization.contains(token))
    }

    func testTreeObservationDoesNotTakeScreenshotAndRefsAreLocal() async throws {
        let fixture = Fixture(Fixture.observation)
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        XCTAssertEqual(observation.bundleID, "app.test")
        XCTAssertEqual(observation.backend, "private-ax")
        XCTAssertEqual(observation.nodes.count, 2)
        XCTAssertNil(observation.nodes[0].ref)
        XCTAssertTrue(try XCTUnwrap(observation.nodes[1].ref).hasPrefix(observation.observationID + ":"))
        XCTAssertEqual(observation.nodes[1].identifier, "submit-button")
        XCTAssertTrue(observation.compactText.contains("Button id=\"submit-button\" label=\"Submit\""))
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/source", "/wda/activeAppInfo"])
    }

    func testFreshUniqueLookupPrecedesOneMutationAndConsumesRef() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let ref = try XCTUnwrap(observation.nodes[1].ref)
        let result = await client.act(.tap(ref: ref))
        XCTAssertEqual(result, .completed)
        let lookup = try XCTUnwrap(fixture.requests.first { $0.path == "/elements" })
        let lookupJSON = try JSONDecoder().decode(JSONValue.self, from: lookup.body)
        XCTAssertEqual(lookupJSON["using"]?.string, "predicate string")
        XCTAssertTrue(lookupJSON["value"]?.string?.contains("rawIdentifier == 'submit-button'") == true)
        XCTAssertTrue(lookupJSON["value"]?.string?.contains("rect.y == 100.0") == true)
        let count = fixture.requests.count
        assertUnsent(await client.act(.tap(ref: ref)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, count)
    }

    func testNewObservationInvalidatesPreviousRefs() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.observation)
        let client = try makeClient(fixture)
        let first = try await client.observe()
        _ = try await client.observe()
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(first.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testAppSwitchBeforeActionRejectsWithoutLookupOrMutation() async throws {
        let fixture = Fixture(Fixture.observation + [.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"other.app","pid":9}}"#)])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .appChanged)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" || $0.path.hasSuffix("/click") })
    }

    func testAmbiguousFreshLookupNeverClicks() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", #"{"value":[{"ELEMENT":"A"},{"ELEMENT":"B"}]}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .ambiguousElement)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testResponseLossMakesOutcomeUnknownAndNeverRetries() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .networkConnectionLost)])
        let client = try makeClient(fixture)
        let result = await client.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown, got \(result)") }
        XCTAssertEqual(problem.kind, .transport)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMutationCancellationIsUnknownAndDoesNotReplay() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .cancelled)])
        let client = try makeClient(fixture)
        let result = await client.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.kind, .cancelled)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testHTTP200WithWebDriverErrorIsNotSuccess() async throws {
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":{"error":"unknown error","message":"activation failed"}}"#)])
        let result = await (try makeClient(fixture)).act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.statusCode, 200)
        XCTAssertEqual(problem.runnerCode, "unknown error")
        XCTAssertEqual(problem.message, "activation failed")
    }

    func testDroppedAndAuthenticationRefusalsAreUnsent() async throws {
        for (status, headers) in [(401, [:]), (503, ["X-IPU-Dropped": "1"])] {
            let fixture = Fixture([.json("POST", "/wda/apps/activate",
                                        #"{"value":{"error":"unknown error","message":"refused"}}"#,
                                        status: status, headers: headers)])
            let result = await (try makeClient(fixture)).act(.launch(bundleID: "app.test"))
            guard case .unsent(let problem) = result else { return XCTFail("Expected unsent") }
            XCTAssertEqual(problem.statusCode, status)
        }
    }

    func testStaleElementAfterMutationDispatchDoesNotPromiseNoSideEffect() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click",
                  #"{"value":{"error":"stale element reference","message":"gone after scrolling"}}"#, status: 404),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref)))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.runnerCode, "stale element reference")
    }

    func testStopBlocksActionsAndObservations() async throws {
        let fixture = Fixture([])
        let client = try makeClient(fixture)
        await client.stop()
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .stopped)
        do { _ = try await client.observe(); XCTFail("Expected stopped") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testStopDuringElementLookupPreventsMutation() async throws {
        let gate = ReplyGate()
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement, gate: gate),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let ref = try XCTUnwrap(observation.nodes[1].ref)
        let action = Task { await client.act(.tap(ref: ref)) }
        await fulfillment(of: [gate.started], timeout: 2)
        await client.stop()
        gate.release()
        assertUnsent(await action.value, kind: .stopped)
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testConcurrentActionCannotOvertakeInFlightMutation() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":null}"#, gate: gate)])
        let client = try makeClient(fixture)
        let first = Task { await client.act(.launch(bundleID: "app.test")) }
        await fulfillment(of: [gate.started], timeout: 2)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .busy)
        gate.release()
        let result = await first.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOutOfScopeObservationDoesNotReadTree() async throws {
        let fixture = Fixture([.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"personal.app","pid":77}}"#)])
        let client = try makeClient(fixture)
        do { _ = try await client.observe(); XCTFail("Expected scope refusal") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testScreenshotDecodesBase64OnlyWhenExplicitlyRequested() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2])
        let fixture = Fixture([Fixture.active,
            .json("GET", "/screenshot", "{\"value\":\"\(png.base64EncodedString())\"}"), Fixture.active,
        ])
        let screenshot = try await makeClient(fixture).screenshot()
        XCTAssertEqual(screenshot, png)
    }

    func testSessionTokensAreRandomAndValid() {
        let first = PhoneRunnerClient.newSessionToken()
        let second = PhoneRunnerClient.newSessionToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(RunnerSigning.validToken(first))
        XCTAssertNotEqual(first, second)
    }

    private func makeClient(_ fixture: Fixture) throws -> PhoneRunnerClient {
        try PhoneRunnerClient(token: token, allowedBundleIDs: ["app.test"], port: fixture.port,
                              sessionConfiguration: fixture.configuration)
    }

    private func assertUnsent(_ result: PhoneActionResult, kind: PhoneControlProblem.Kind,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .unsent(let problem) = result else {
            return XCTFail("Expected unsent, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(problem.kind, kind, file: file, line: line)
    }
}

private final class Fixture: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let body: Data
        var path: String { url.path }
    }

    struct Reply: Sendable {
        let method: String
        let path: String
        let data: Data
        let status: Int
        let headers: [String: String]
        let error: URLError.Code?
        let gate: ReplyGate?

        static func json(_ method: String, _ path: String, _ json: String,
                         status: Int = 200, headers: [String: String] = [:], gate: ReplyGate? = nil) -> Reply {
            Reply(method: method, path: path, data: Data(json.utf8), status: status, headers: headers, error: nil, gate: gate)
        }
        static func failure(_ method: String, _ path: String, _ error: URLError.Code) -> Reply {
            Reply(method: method, path: path, data: Data(), status: 0, headers: [:], error: error, gate: nil)
        }
    }

    static let active = Reply.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"app.test","pid":42}}"#)
    static let oneElement = #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#
    static var observation: [Reply] { [active, .json("GET", "/source", tree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let tree = #"{"value":{"type":"XCUIElementTypeApplication","isEnabled":"1","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"submit-button","label":"Submit","isEnabled":"1","isFocused":"0","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]}]}}"#

    let port: UInt16
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [Request] = []
    var requests: [Request] { lock.withLock { recorded } }
    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return config
    }

    init(_ replies: [Reply]) {
        self.replies = replies
        port = FixtureProtocol.nextPort()
        FixtureProtocol.register(self)
    }

    func reply(to request: URLRequest) -> Reply {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&bytes, maxLength: bytes.count)
                if read <= 0 { break }
                body.append(contentsOf: bytes.prefix(read))
            }
        }
        return lock.withLock {
            let item = Request(url: request.url!, method: request.httpMethod!,
                               authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
            recorded.append(item)
            guard !replies.isEmpty else {
                XCTFail("Unexpected request \(item.method) \(item.path)")
                return .failure(item.method, item.path, .badServerResponse)
            }
            let next = replies.removeFirst()
            XCTAssertEqual(item.method, next.method)
            XCTAssertEqual(item.path, next.path)
            return next
        }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [UInt16: Fixture] = [:]
        var port: UInt16 = 20_000
    }
    private static let registry = Registry()

    static func nextPort() -> UInt16 {
        registry.lock.withLock { registry.port += 1; return registry.port }
    }
    static func register(_ fixture: Fixture) {
        registry.lock.withLock { registry.fixtures[fixture.port] = fixture }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock {
            request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] }
        }
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = fixture.reply(to: request)
        let send: @Sendable () -> Void = { [self] in
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = reply.gate { gate.enqueue(send) } else { send() }
    }
    override func stopLoading() {}
}

private final class ReplyGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Request entered fixture")
    private let lock = NSLock()
    private var send: (@Sendable () -> Void)?

    func enqueue(_ send: @escaping @Sendable () -> Void) {
        lock.withLock { self.send = send }
        started.fulfill()
    }

    func release() {
        let pending = lock.withLock { let pending = send; send = nil; return pending }
        pending?()
    }
}
