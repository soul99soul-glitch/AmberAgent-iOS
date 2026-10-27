import Foundation
import Network
import Security

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public var bearerToken: String? {
        guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst(7))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }
}

/// One request per connection (`Connection: close`), JSON bodies up to 64KB. That is all the gateway
/// API and the tests' push-service mocks need.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    static let maxRequest = 64 * 1024
    /// Clients read for 25 s, so a slow handler still answers before they give up and retry another address.
    static let connectionTimeout: TimeInterval = 20
    /// Reachable from the internet through the VPS tunnel: cap open sockets so idle connections can't exhaust
    /// the daemon's descriptors (hook socket, registry writes, push requests share them).
    static let maxConnections = 32

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler
    /// Touched only on `queue`.
    private var openConnections = 0

    public init(port: UInt16, identity: SecIdentity?, queue: DispatchQueue, handler: @escaping Handler) throws {
        let parameters: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.queue = queue
        self.handler = handler
    }

    public var port: UInt16? { listener.port?.rawValue }

    /// Blocks until the listener is ready (or failed) so callers can report bind errors synchronously.
    /// Must not be called on `queue`.
    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { throw failure }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard openConnections < Self.maxConnections else { return connection.cancel() }
        openConnections += 1
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed: connection?.cancel()
            case .cancelled: self?.openConnections -= 1
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequest) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequest {
                return self.respond(connection, .error(413, "request too large"))
            }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.handler(request) { self.respond(connection, $0) }
            case .invalid:
                self.respond(connection, .error(400, "bad request"))
            case .incomplete:
                if error != nil || isComplete { return connection.cancel() }
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 502: "Bad Gateway"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    enum ParseResult {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length))))
    }
}
