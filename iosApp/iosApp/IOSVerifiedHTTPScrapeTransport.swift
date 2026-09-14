import Foundation
@preconcurrency import Network
import Security
import Darwin
import NIOCore
import NIOEmbedded
import NIOHTTP1

/// A deliberately narrow escape hatch for VPN Fake-IP DNS. It is reachable
/// only from `scrape_web`: the shared `sendPublic` transport remains strict and
/// never treats a Fake-IP address as a network destination.
@MainActor
protocol IOSVerifiedHTTPScrapeTransport {
    func sendVerifiedHTTPSGET(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (HTTPURLResponse, Data)
}

extension IOSURLSessionSearchHTTPTransport: IOSVerifiedHTTPScrapeTransport {
    func sendVerifiedHTTPSGET(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (HTTPURLResponse, Data) {
        guard request.httpMethod?.uppercased() == "GET", request.httpBody == nil else {
            throw IOSVerifiedHTTPScrapeNetworkError.onlyHTTPSGET
        }
        guard let url = request.url else { throw IOSSearchExecutorError.invalidURL }
        let validated = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
        guard let host = validated.host else { throw IOSSearchExecutorError.invalidURL }

        // Non-Fake-IP traffic remains on the existing URLSession path. The
        // scrape request is constructed without cookies or authorization, so
        // this does not broaden its existing session behavior.
        guard validated.scheme?.lowercased() == "https" else {
            return try await sendPublic(request, maximumResponseBytes: maximumResponseBytes)
        }
        let deadline = IOSVerifiedHTTPScrapeDeadline.forRequest(request)
        try IOSVerifiedHTTPScrapeDeadline.check(deadline)
        let systemAddresses = try await IOSVerifiedHTTPScrapeAddressResolver.resolveSystemAddresses(
            host,
            resolveHost: resolveHost,
            deadline: deadline
        )
        guard let verifiedAddresses = try await IOSVerifiedHTTPScrapeAddressResolver.initialFakeIPAddresses(
            systemAddresses,
            host: host,
            resolvePublicHost: resolvePublicHostForVerifiedScrape,
            deadline: deadline
        ) else {
            return try await sendPublic(request, maximumResponseBytes: maximumResponseBytes)
        }

        let loader = IOSVerifiedHTTPScrapeLoader(
            resolveHost: resolveHost,
            resolvePublicHost: resolvePublicHostForVerifiedScrape
        )
        return try await loader.load(
            request,
            initialVerifiedAddresses: verifiedAddresses,
            maximumResponseBytes: maximumResponseBytes,
            deadline: deadline
        )
    }
}

/// This resolver is intentionally separate from `IOSURLSessionSearchHTTPTransport`.
/// Its public-DNS result is returned to the caller as the actual connection
/// address, rather than serving as a gate for a later hostname lookup.
struct IOSVerifiedHTTPScrapeAddressResolver {
    /// Cancellation ends the wait, not libc's synchronous lookup. Late lookup
    /// results are ignored; its worker is released when getaddrinfo returns.
    static func resolveSystemAddresses(
        _ host: String,
        resolveHost: @escaping @Sendable (String) throws -> [String],
        deadline: Date? = nil
    ) async throws -> [String] {
        try check(deadline)
        return try await IOSVerifiedHTTPScrapeDNSWaiter().resolve(
            host, resolveHost: resolveHost, deadline: deadline
        )
    }

    /// `nil` preserves URLSession for a conventional all-public answer. A
    /// non-nil result is the verified public address set for direct dialing.
    static func initialFakeIPAddresses(
        _ systemAddresses: [String],
        host: String,
        resolvePublicHost: @escaping @Sendable (String) async throws -> [String],
        deadline: Date? = nil
    ) async throws -> [String]? {
        try check(deadline)
        guard !systemAddresses.isEmpty else {
            throw IOSSearchExecutorError.disallowedURL("host could not be resolved")
        }
        guard !systemAddresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
            return nil
        }
        return try await verifiedConnectionAddresses(
            systemAddresses,
            host: host,
            resolvePublicHost: resolvePublicHost,
            deadline: deadline
        )
    }

    /// Called for every redirect hop in a direct scrape. Public system answers
    /// are dialed as-is; a Fake-IP answer is replaced by the public-DNS answer.
    /// Any actual private/reserved answer remains a hard rejection.
    static func verifiedConnectionAddresses(
        _ systemAddresses: [String],
        host: String,
        resolvePublicHost: @escaping @Sendable (String) async throws -> [String],
        deadline: Date? = nil
    ) async throws -> [String] {
        try check(deadline)
        guard !systemAddresses.isEmpty else {
            throw IOSSearchExecutorError.disallowedURL("host could not be resolved")
        }
        if systemAddresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) {
            return unique(systemAddresses)
        }
        guard systemAddresses.contains(where: isStandardFakeIPAddress),
              systemAddresses.allSatisfy({
                  IOSSearchExecutor.publicHostAllowed($0) || isStandardFakeIPAddress($0)
              }) else {
            throw IOSSearchExecutorError.disallowedURL("host resolves to a non-public address")
        }
        do {
            try check(deadline)
            let publicAddresses: [String]
            if let deadline {
                // URLSession's public DNS request cooperates with cancellation.
                // Keep its existing request within this scrape's remaining time.
                publicAddresses = try await withThrowingTaskGroup(of: [String].self) { group in
                    group.addTask { try await resolvePublicHost(host) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } else {
                publicAddresses = try await resolvePublicHost(host)
            }
            try check(deadline)
            guard !publicAddresses.isEmpty,
                  publicAddresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
                throw IOSSearchExecutorError.disallowedURL("fake-IP host could not be verified by public DNS")
            }
            return unique(publicAddresses)
        } catch let error as IOSSearchExecutorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw IOSSearchExecutorError.disallowedURL("fake-IP host could not be verified by public DNS")
        }
    }

    private static func check(_ deadline: Date?) throws {
        try Task.checkCancellation()
        guard let deadline else { return }
        guard deadline.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
    }

    private static func isStandardFakeIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, value, &ipv4) == 1 else { return false }
        let address = UInt32(bigEndian: ipv4.s_addr)
        let first = Int((address >> 24) & 0xff)
        let second = Int((address >> 16) & 0xff)
        return first == 198 && (second == 18 || second == 19)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private enum IOSVerifiedHTTPScrapeDeadline {
    static func forRequest(_ request: URLRequest) -> Date {
        Date().addingTimeInterval(min(max(request.timeoutInterval, 1), 30))
    }

    static func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
    }
}

private final class IOSVerifiedHTTPScrapeDNSWaiter: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "app.amber.ios.verified-scrape.dns")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var result: Result<[String], Error>?

    func resolve(
        _ host: String,
        resolveHost: @escaping @Sendable (String) throws -> [String],
        deadline: Date?
    ) async throws -> [String] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                Task.detached(priority: .userInitiated) { [self] in
                    finish(Result { try resolveHost(host) })
                }
                if let deadline {
                    Self.queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                        self?.finish(.failure(URLError(.timedOut)))
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
private struct IOSVerifiedHTTPScrapeLoader {
    private static let maximumRedirects = 5

    let resolveHost: @Sendable (String) throws -> [String]
    let resolvePublicHost: @Sendable (String) async throws -> [String]

    func load(
        _ originalRequest: URLRequest,
        initialVerifiedAddresses: [String],
        maximumResponseBytes: Int,
        deadline: Date
    ) async throws -> (HTTPURLResponse, Data) {
        try IOSVerifiedHTTPScrapeDeadline.check(deadline)
        guard let originalURL = originalRequest.url else { throw IOSSearchExecutorError.invalidURL }
        var request = originalRequest
        var url = originalURL
        var initialAddresses: [String]? = initialVerifiedAddresses

        for redirectCount in 0...Self.maximumRedirects {
            try IOSVerifiedHTTPScrapeDeadline.check(deadline)
            let currentURL = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
            guard currentURL.scheme?.lowercased() == "https" else {
                throw IOSSearchExecutorError.disallowedURL("HTTPS redirects may not downgrade to HTTP")
            }
            guard let host = currentURL.host else { throw IOSSearchExecutorError.invalidURL }

            let addresses: [String]
            if let firstAddresses = initialAddresses {
                addresses = firstAddresses
                initialAddresses = nil
            } else {
                let systemAddresses = try await IOSVerifiedHTTPScrapeAddressResolver.resolveSystemAddresses(
                    host,
                    resolveHost: resolveHost,
                    deadline: deadline
                )
                addresses = try await IOSVerifiedHTTPScrapeAddressResolver.verifiedConnectionAddresses(
                    systemAddresses,
                    host: host,
                    resolvePublicHost: resolvePublicHost,
                    deadline: deadline
                )
            }

            let exchange = try await IOSVerifiedHTTPScrapeConnection.exchange(
                request: request,
                url: currentURL,
                addresses: addresses,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline
            )
            switch exchange {
            case .response(let response, let body):
                return (response, body)
            case .redirect(let location):
                guard redirectCount < Self.maximumRedirects else {
                    throw IOSVerifiedHTTPScrapeNetworkError.tooManyRedirects
                }
                guard let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    throw IOSSearchExecutorError.invalidURL
                }
                let validatedNextURL = try IOSSearchExecutor.allowedPublicHTTPURL(from: nextURL.absoluteString)
                guard validatedNextURL.scheme?.lowercased() == "https" else {
                    throw IOSSearchExecutorError.disallowedURL("HTTPS redirects may not downgrade to HTTP")
                }
                request = Self.redirectRequest(from: originalRequest, to: validatedNextURL)
                url = validatedNextURL
            }
        }
        throw IOSVerifiedHTTPScrapeNetworkError.tooManyRedirects
    }

    private static func redirectRequest(from original: URLRequest, to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = original.timeoutInterval
        if let userAgent = original.value(forHTTPHeaderField: "User-Agent") {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let accept = original.value(forHTTPHeaderField: "Accept") {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return request
    }
}

@MainActor
private final class IOSVerifiedHTTPScrapeConnection {
    fileprivate enum Exchange {
        case response(HTTPURLResponse, Data)
        case redirect(String)
    }

    private struct ReceivedData {
        let data: Data
        let isComplete: Bool
    }

    private static let maximumAddressAttempts = 8
    private static let receiveChunkBytes = 16 * 1_024
    private static let networkQueue = DispatchQueue(
        label: "app.amber.ios.verified-scrape.network",
        qos: .userInitiated
    )
    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func exchange(
        request: URLRequest,
        url: URL,
        addresses: [String],
        maximumResponseBytes: Int,
        deadline: Date
    ) async throws -> Exchange {
        try IOSVerifiedHTTPScrapeDeadline.check(deadline)
        guard let host = url.host else { throw IOSSearchExecutorError.invalidURL }
        let portValue = url.port ?? 443
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: portValue) ?? 0) else {
            throw IOSSearchExecutorError.invalidURL
        }
        var lastError: Error?

        // A fallback address is tried only if TLS never became ready. Once a
        // request could have been written, we surface the failure rather than
        // repeat even an idempotent scrape request.
        for address in addresses.prefix(Self.maximumAddressAttempts) {
            try IOSVerifiedHTTPScrapeDeadline.check(deadline)
            let attempt = makeConnection(address: address, host: host, port: port)
            do {
                try await attempt.start(deadline: deadline)
            } catch {
                attempt.cancel()
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                continue
            }
            defer { attempt.cancel() }
            return try await attempt.readResponse(
                request: request,
                url: url,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline
            )
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private static func makeConnection(
        address: String,
        host: String,
        port: NWEndpoint.Port
    ) -> IOSVerifiedHTTPScrapeConnection {
        let tls = NWProtocolTLS.Options()
        let tlsHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsHost)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        return IOSVerifiedHTTPScrapeConnection(connection: NWConnection(
            host: NWEndpoint.Host(address),
            port: port,
            using: parameters
        ))
    }

    func cancel() {
        connection.cancel()
    }

    private func start(deadline: Date) async throws {
        try Task.checkCancellation()
        let connection = connection
        let timeout = IOSVerifiedHTTPScrapeTimeoutFlag()
        let timeoutWork = DispatchWorkItem { @Sendable in
            timeout.markFired()
            connection.cancel()
        }
        Self.networkQueue.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            execute: timeoutWork
        )
        defer { timeoutWork.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let once = IOSVerifiedHTTPScrapeOnce()
                    connection.stateUpdateHandler = { @Sendable state in
                        switch state {
                        case .ready:
                            guard once.take() else { return }
                            connection.stateUpdateHandler = nil
                            continuation.resume()
                        case .failed(let error):
                            guard once.take() else { return }
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case .cancelled:
                            guard once.take() else { return }
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: URLError(.cancelled))
                        default:
                            break
                        }
                    }
                    connection.start(queue: Self.networkQueue)
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if timeout.fired { throw URLError(.timedOut) }
            throw error
        }
    }

    private func readResponse(
        request: URLRequest,
        url: URL,
        maximumResponseBytes: Int,
        deadline: Date
    ) async throws -> Exchange {
        try IOSVerifiedHTTPScrapeDeadline.check(deadline)
        let connection = connection
        let parser = try await IOSVerifiedHTTPScrapeHTTPResponseDecoder(
            maximumResponseBytes: maximumResponseBytes
        )

        let timeout = IOSVerifiedHTTPScrapeTimeoutFlag()
        let timeoutWork = DispatchWorkItem { @Sendable in
            timeout.markFired()
            connection.cancel()
        }
        Self.networkQueue.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            execute: timeoutWork
        )
        defer { timeoutWork.cancel() }

        return try await withTaskCancellationHandler {
            do {
                try await send(Self.requestBytes(for: request, url: url))
                while true {
                    try Task.checkCancellation()
                    let received = try await receive(maximumLength: Self.receiveChunkBytes)
                    if !received.data.isEmpty {
                        try await parser.append(received.data)
                    }
                    if let location = await parser.redirectLocation {
                        await parser.close()
                        return .redirect(location)
                    }
                    if let response = try await parser.completedResponse(url: url) {
                        await parser.close()
                        return .response(response.0, response.1)
                    }
                    if received.isComplete {
                        let response = try await parser.finish(url: url)
                        return .response(response.0, response.1)
                    }
                }
            } catch {
                await parser.close()
                if Task.isCancelled { throw CancellationError() }
                if timeout.fired { throw URLError(.timedOut) }
                throw error
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func requestBytes(for request: URLRequest, url: URL) throws -> Data {
        guard request.httpMethod?.uppercased() == "GET", request.httpBody == nil,
              let host = url.host else {
            throw IOSVerifiedHTTPScrapeNetworkError.onlyHTTPSGET
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if path.isEmpty { path = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }
        let port = url.port ?? 443
        let hostHeader = port == 443 ? host : "\(host):\(port)"
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? "Mozilla/5.0 AmberAgent-iOS Scrape"
        let accept = request.value(forHTTPHeaderField: "Accept")
            ?? "text/html,text/plain,application/xhtml+xml,application/json;q=0.8,*/*;q=0.3"
        guard !containsCRLF(userAgent), !containsCRLF(accept), !containsCRLF(hostHeader) else {
            throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
        }
        let message = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "User-Agent: \(userAgent)",
            "Accept: \(accept)",
            "Accept-Encoding: identity",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(message.utf8)
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(maximumLength: Int) async throws -> ReceivedData {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                @Sendable data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ReceivedData(data: data ?? Data(), isComplete: isComplete))
                }
            }
        }
    }

    private static func containsCRLF(_ value: String) -> Bool {
        value.contains("\r") || value.contains("\n")
    }
}

/// NIO's llhttp-backed decoder owns HTTP/1 framing, including fragmented
/// headers, chunked bodies, EOF framing and 1xx informational responses. The
/// async testing channel retains one parser across awaits without a thread-
/// bound EmbeddedChannel or repeated full-response decoding.
actor IOSVerifiedHTTPScrapeHTTPResponseDecoder {
    private static let maximumHeaderBytes = 32 * 1_024
    private static let maximumHeaderFields = 100

    private let maximumResponseBytes: Int
    private let channel: NIOAsyncTestingChannel
    private var head: HTTPResponseHead?
    private var body = Data()
    private var ended = false

    var redirectLocation: String? {
        guard let head, (300...399).contains(Int(head.status.code)) else { return nil }
        return head.headers[canonicalForm: "location"].first.map(String.init)
    }

    init(maximumResponseBytes: Int) async throws {
        self.maximumResponseBytes = maximumResponseBytes
        self.channel = try await Self.makeChannel()
        _ = try await channel.writeOutbound(HTTPClientRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        ))
        while let _: ByteBuffer = try await channel.readOutbound(as: ByteBuffer.self) {}
    }

    func append(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeInbound(buffer)
            try await drainInboundParts()
        } catch {
            await close()
            throw error
        }
    }

    func completedResponse(url: URL) throws -> (HTTPURLResponse, Data)? {
        guard ended else { return nil }
        return try response(url: url)
    }

    func finish(url: URL) async throws -> (HTTPURLResponse, Data) {
        _ = try await channel.finish(acceptAlreadyClosed: true)
        try await drainInboundParts()
        guard ended else { throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse }
        return try response(url: url)
    }

    func close() async {
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }

    private static func makeChannel() async throws -> NIOAsyncTestingChannel {
        let limits = Self.decoderLimits()
        return try await NIOAsyncTestingChannel { channel in
            try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                HTTPResponseDecoder(
                    leftOverBytesStrategy: .dropBytes,
                    informationalResponseStrategy: .drop,
                    limitConfiguration: limits
                )
            ))
        }
    }

    private static func decoderLimits() -> NIOHTTPDecoderLimitConfiguration {
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = Self.maximumHeaderBytes
        limits.maxHeaderListSize = Self.maximumHeaderBytes
        limits.maxHeaderFieldCount = Self.maximumHeaderFields
        return limits
    }

    private func drainInboundParts() async throws {
        while let part = try await channel.readInbound(as: HTTPClientResponsePart.self) {
            switch part {
            case .head(let nextHead):
                guard nextHead.status.code >= 200,
                      nextHead.status.code != 101,
                      head == nil else {
                    throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
                }
                try validateResponseHeaders(nextHead)
                head = nextHead
            case .body(var partBody):
                guard head != nil, !ended else {
                    throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
                }
                let count = partBody.readableBytes
                guard count <= maximumResponseBytes - body.count else {
                    throw IOSSearchExecutorError.responseTooLarge(maximumResponseBytes)
                }
                if let bytes = partBody.readBytes(length: count) {
                    body.append(contentsOf: bytes)
                }
            case .end:
                guard head != nil, !ended else {
                    throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
                }
                ended = true
            }
        }
    }

    private func validateResponseHeaders(_ head: HTTPResponseHead) throws {
        let encodings = head.headers[canonicalForm: "content-encoding"]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard encodings.isEmpty || encodings.allSatisfy({ $0 == "identity" }) else {
            throw IOSVerifiedHTTPScrapeNetworkError.unsupportedContentEncoding
        }
        for rawLength in head.headers[canonicalForm: "content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
            }
            guard length <= maximumResponseBytes else {
                throw IOSSearchExecutorError.responseTooLarge(maximumResponseBytes)
            }
        }
    }

    private func response(url: URL) throws -> (HTTPURLResponse, Data) {
        guard let head else {
            throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
        }
        var fields: [String: String] = [:]
        for header in head.headers {
            fields[header.name] = fields[header.name]
                .map { "\($0), \(header.value)" } ?? header.value
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: Int(head.status.code),
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headerFields: fields
        ) else {
            throw IOSVerifiedHTTPScrapeNetworkError.malformedHTTPResponse
        }
        return (response, body)
    }
}

private final class IOSVerifiedHTTPScrapeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

private final class IOSVerifiedHTTPScrapeTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }

    func markFired() {
        lock.lock()
        didFire = true
        lock.unlock()
    }
}

private enum IOSVerifiedHTTPScrapeNetworkError: LocalizedError {
    case onlyHTTPSGET
    case tooManyRedirects
    case malformedHTTPResponse
    case unsupportedContentEncoding

    var errorDescription: String? {
        switch self {
        case .onlyHTTPSGET:
            "Verified scraping only supports HTTPS GET requests."
        case .tooManyRedirects:
            "Scrape request exceeded the redirect limit."
        case .malformedHTTPResponse:
            "Scrape server returned a malformed HTTP response."
        case .unsupportedContentEncoding:
            "Scrape server ignored identity encoding and returned an unsupported content encoding."
        }
    }
}
