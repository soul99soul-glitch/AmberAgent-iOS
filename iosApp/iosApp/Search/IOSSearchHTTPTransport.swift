import Foundation
import Darwin

struct IOSURLSessionSearchHTTPTransport: IOSSearchHTTPTransport {
    var session: URLSession
    var resolveHost: @Sendable (String) throws -> [String]
    /// Used only by the scrape-only direct Fake-IP transport. `sendPublic`
    /// itself remains strictly bound to system-public answers.
    var resolvePublicHostForVerifiedScrape: @Sendable (String) async throws -> [String]

    init(
        session: URLSession = .shared,
        resolveHost: @escaping @Sendable (String) throws -> [String] = IOSSearchExecutor.resolveIPAddresses,
        resolvePublicHostForVerifiedScrape: @escaping @Sendable (String) async throws -> [String] = {
            try await IOSWebMountPublicDNS.resolve($0)
        }
    ) {
        self.session = session
        self.resolveHost = resolveHost
        self.resolvePublicHostForVerifiedScrape = resolvePublicHostForVerifiedScrape
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IOSSearchExecutorError.invalidHTTPResponse
        }
        return (httpResponse, data)
    }

    func sendPublic(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw IOSSearchExecutorError.invalidURL }
        let validated = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
        guard let host = validated.host else { throw IOSSearchExecutorError.invalidURL }
        let deadline = Date(timeIntervalSinceNow: request.timeoutInterval)
        let addresses = try await IOSVerifiedHTTPScrapeAddressResolver.resolveSystemAddresses(
            host, resolveHost: resolveHost, deadline: deadline
        )
        try Task.checkCancellation()
        guard !addresses.isEmpty, addresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
            throw IOSSearchExecutorError.disallowedURL("host resolves to a non-public address")
        }
        let loader = IOSBoundedPublicURLSessionLoader(
            configuration: session.configuration,
            maximumResponseBytes: maximumResponseBytes,
            requiresHTTPS: validated.scheme?.lowercased() == "https",
            resolveHost: resolveHost
        )
        var boundedRequest = request
        boundedRequest.timeoutInterval = deadline.timeIntervalSinceNow
        guard boundedRequest.timeoutInterval > 0 else { throw URLError(.timedOut) }
        return try await loader.load(boundedRequest)
    }
}

final class IOSBoundedPublicURLSessionLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int
    private let requiresHTTPS: Bool
    private let resolveHost: @Sendable (String) throws -> [String]
    private let allowedRedirectDomains: [String]?
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var cancellationRequested = false

    init(
        configuration: URLSessionConfiguration,
        maximumResponseBytes: Int,
        requiresHTTPS: Bool,
        resolveHost: @escaping @Sendable (String) throws -> [String],
        allowedRedirectDomains: [String]? = nil
    ) {
        self.configuration = configuration
        self.maximumResponseBytes = maximumResponseBytes
        self.requiresHTTPS = requiresHTTPS
        self.resolveHost = resolveHost
        self.allowedRedirectDomains = allowedRedirectDomains
    }

    func load(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancellationRequested || Task.isCancelled {
                    cancellationRequested = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(IOSSearchExecutorError.invalidHTTPResponse))
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            completionHandler(.cancel)
            finish(.failure(IOSSearchExecutorError.responseTooLarge(maximumResponseBytes)))
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumResponseBytes - self.data.count else {
            dataTask.cancel()
            finish(.failure(IOSSearchExecutorError.responseTooLarge(maximumResponseBytes)))
            return
        }
        self.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        do {
            guard let url = request.url else { throw IOSSearchExecutorError.invalidURL }
            let validated = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
            if requiresHTTPS, validated.scheme?.lowercased() != "https" {
                throw IOSSearchExecutorError.disallowedURL("HTTPS redirects may not downgrade to HTTP")
            }
            guard let host = validated.host else { throw IOSSearchExecutorError.invalidURL }
            if let allowedRedirectDomains,
               !allowedRedirectDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                throw IOSSearchExecutorError.disallowedURL("redirect leaves the declared plugin domain scope")
            }
            let addresses = try resolveHost(host)
            guard !addresses.isEmpty, addresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
                throw IOSSearchExecutorError.disallowedURL("host resolves to a non-public address")
            }
            return request
        } catch {
            finish(.failure(error))
            return nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let response else {
            finish(.failure(IOSSearchExecutorError.invalidHTTPResponse))
            return
        }
        finish(.success((response, data)))
    }

    private func finish(_ result: Result<(HTTPURLResponse, Data), Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        switch result {
        case .success:
            session?.finishTasksAndInvalidate()
        case .failure:
            session?.invalidateAndCancel()
        }
        continuation.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        let hasContinuation = continuation != nil
        lock.unlock()
        task?.cancel()
        if hasContinuation {
            finish(.failure(CancellationError()))
        }
    }
}

