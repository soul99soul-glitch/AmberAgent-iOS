import Foundation
@preconcurrency import Shared

@MainActor enum DesktopSearchRuntime {
    static func execute(
        name: String,
        input: String,
        settings: DesktopSearchSettings,
        transport: DesktopSearchHTTPHandler? = nil
    ) async throws -> String {
        let output = try await executeOutput(name: name, input: input, settings: settings, transport: transport)
        return output.text
    }

    static func executeTool(
        name: String,
        input: String,
        settings: DesktopSearchSettings,
        transport: DesktopSearchHTTPHandler? = nil
    ) async throws -> [UIMessagePart] {
        let output = try await executeOutput(name: name, input: input, settings: settings, transport: transport)
        if let metadata = output.mediaMetadataEntries {
            return [IosToolOutputJsonBridge().textPartWithMetadata(text: output.text, entries: metadata)]
        }
        return [UIMessagePart.Text(text: output.text, metadata: nil)]
    }

    static func executeOutput(
        name: String,
        input: String,
        settings: DesktopSearchSettings,
        transport: DesktopSearchHTTPHandler? = nil
    ) async throws -> DesktopSearchExecutionOutput {
        let freeHandler: DesktopFreeSearchHandler? = transport == nil ? { query, maxResults, _ in
            let results = try await IOSFreeSearchAggregator.search(
                query: query,
                maxResults: maxResults,
                googleFallbackEnabled: false
            )
            return results.map { item in
                DesktopSearchHit(
                    title: item.title,
                    url: item.url,
                    snippet: item.snippet,
                    images: item.images.map { imgURL in
                        DesktopSearchImage(
                            url: imgURL,
                            title: item.title,
                            alt: item.title,
                            sourceURL: item.url,
                            snippet: item.snippet
                        )
                    },
                    sourceService: "免费聚合搜索"
                )
            }
        } : nil

        return try await DesktopSearchEngine.execute(
            name: name,
            input: input,
            settings: settings,
            transport: transport,
            freeSearch: freeHandler
        )
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

final class DesktopPublicSearchRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, (try? await DesktopPublicSearchURL.validate(url)) != nil else { return nil }
        return request
    }
}
