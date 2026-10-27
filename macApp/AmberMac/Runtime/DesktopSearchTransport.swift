import Foundation
@preconcurrency import Shared

@MainActor enum DesktopSearchRuntime {
    static func execute(name: String, input: String, settings: DesktopSearchSettings) async throws -> String {
        if name == "scrape_web" { return try await IOSSearchExecutor.execute(toolName: name, toolInput: input) }
        let snapshot = try DesktopProviderBridge.shared.searchSettings(json: settings.requestJSON())
        return try await IOSSearchExecutor.execute(toolName: name, toolInput: input, settings: snapshot)
    }
}

// The original search executor and free-engine parsers are shared with iOS.
// Mac uses URLSession directly; no WebMount browser or private-address fallback.
@MainActor struct IOSURLSessionSearchHTTPTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        try await sendPublic(request, maximumResponseBytes: 8 * 1_024 * 1_024)
    }

    func sendPublic(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw IOSSearchExecutorError.invalidURL }
        _ = try await DesktopPublicSearchURL.validate(url)
        let session = URLSession(configuration: .ephemeral, delegate: DesktopPublicSearchRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw IOSSearchExecutorError.invalidHTTPResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw IOSSearchExecutorError.responseTooLarge(maximumResponseBytes) }
            data.append(byte)
        }
        return (response, data)
    }
}

private final class DesktopPublicSearchRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, (try? await DesktopPublicSearchURL.validate(url)) != nil else { return nil }
        return request
    }
}
