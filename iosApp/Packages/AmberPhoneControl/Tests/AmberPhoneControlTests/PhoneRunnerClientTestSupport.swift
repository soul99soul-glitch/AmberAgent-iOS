import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

final class Fixture: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let body: Data
        let timeoutInterval: TimeInterval
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
    static func settle(stable: Bool = true, blank: Bool = false, gate: ReplyGate? = nil) -> Reply {
        .json("GET", "/wda/settle", #"{"value":{"stable":\#(stable),"blank":\#(blank),"waited_ms":180,"frames":6,"changed_px":0,"capture_ms":4,"budget_ms":800}}"#,
              headers: ["Server-Timing": "other;dur=1, runner;dur=182.5"], gate: gate)
    }
    static var observation: [Reply] { [active, .json("GET", "/source", tree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let tree = #"{"value":{"type":"XCUIElementTypeApplication","isEnabled":"1","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"submit-button","label":"Submit","isEnabled":"1","isFocused":"0","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]}]}}"#
    static var anchoredObservation: [Reply] { [active, .json("GET", "/source", anchoredTree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let anchoredTree = #"{"value":{"type":"XCUIElementTypeApplication","isEnabled":"1","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"submit-button","label":"Submit","isEnabled":"1","isFocused":"0","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Q1","value":"Q1","isEnabled":"0","isFocused":"0","rect":{"x":20,"y":20,"width":80,"height":24},"children":[]}]}}"#
    static func inputObservation(type: String = "XCUIElementTypeTextField", enabled: Bool = true) -> [Reply] {
        let source = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"\#(type)","rawIdentifier":"query","value":"existing","isEnabled":\#(enabled),"rect":{"x":20,"y":100,"width":300,"height":44},"children":[]}]}}"#
        return [active, .json("GET", "/source", source, headers: ["X-IPU-Pid": "42"]), active]
    }
    static func alertObservation(names: [String] = ["Cancel", "Allow"], supported: Bool = true) throws -> [Reply] {
        let rect = ["x": 20, "y": 100, "width": 300, "height": 300]
        var children: [[String: Any]] = [
            ["type": "XCUIElementTypeStaticText", "label": "Allow access?", "rect": rect, "children": []],
            ["type": "XCUIElementTypeStaticText", "label": "Only while using the app", "rect": rect, "children": []],
        ]
        children += names.enumerated().map { index, name in
            ["type": "XCUIElementTypeButton", "label": name, "isEnabled": true,
             "rect": ["x": 20 + index * 100, "y": 300, "width": 90, "height": 44], "children": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["value": [
            "type": "XCUIElementTypeApplication", "rect": rect, "children": [
                ["type": "XCUIElementTypeAlert", "label": "Alert", "rect": rect, "children": children],
            ],
        ]])
        var headers = ["X-IPU-Pid": "42"]
        if supported { headers["X-IPU-Alert-Guard"] = "context-v1" }
        return [active, .json("GET", "/source", String(decoding: data, as: UTF8.self), headers: headers), active]
    }
    static let popupTree = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeWindow","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeOther","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeOther","rect":{"x":0,"y":0,"width":402,"height":139},"children":[]}]}]}]}}"#
    static var popupObservation: [Reply] { [active, .json("GET", "/source", popupTree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let screen = Reply.json("GET", "/window/size", #"{"value":{"width":402,"height":874}}"#)
    static let landscapeScreen = Reply.json("GET", "/window/size", #"{"value":{"width":874,"height":402}}"#)
    static let png = makePNG(width: 1206, height: 2622)
    static let image = Reply.json("GET", "/screenshot", "{\"value\":\"\(png.base64EncodedString())\"}")
    static var screenshot: [Reply] { [active, screen, image, screen, active] }
    static var pointPreflight: [Reply] { [active, screen, active] }

    static func makePNG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

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
                               authorization: request.value(forHTTPHeaderField: "Authorization"), body: body,
                               timeoutInterval: request.timeoutInterval)
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

final class ReplyGate: @unchecked Sendable {
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
