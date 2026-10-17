import Foundation
@preconcurrency import Shared

/// Keeps display-only search thumbnails in durable metadata so providers continue
/// receiving the text summary rather than treating candidate thumbnails as vision input.
struct IOSSearchToolOutput {
    let text: String
    let parts: [UIMessagePart]

    init(text: String, results: [IOSSearchResult] = []) {
        self.text = text
        var seen = Set<String>()
        let images: [[String: String]] = results.compactMap { result in
            guard let url = result.images.first(where: { raw in
                guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
                return ["https", "http"].contains(scheme) && url.host != nil
            }), seen.insert(url).inserted else { return nil }
            return ["id": url, "url": url, "title": result.title, "sourceURL": result.url]
        }
        let part = UIMessagePart.Text(text: text, metadata: nil)
        if !images.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: images),
           let json = String(data: data, encoding: .utf8) {
            parts = [IosToolOutputJsonBridge.shared.mergeTextMetadata(part: part, updates: [
                "app.amber.media.origin": "search",
                "app.amber.media.images": json
            ])]
        } else {
            parts = [part]
        }
    }
}

/// Executes `search_web` / `scrape_web` tool calls against the configured search
/// services, falling back to the free aggregate when the selected service fails.
/// Shared by Amber's chat tool runtime and the standalone Novel discussion agent.
/// Main-actor isolated like the chat runtime it was extracted from.
@MainActor
enum IOSSearchToolDispatch {
    static func dispatch(
        _ toolCall: UIMessagePart.Tool,
        settings: Settings,
        webSearchEnabled: Bool,
        transport: any IOSSearchHTTPTransport
    ) async -> String {
        await dispatchOutput(toolCall, settings: settings, webSearchEnabled: webSearchEnabled, transport: transport).text
    }

    static func dispatchOutput(
        _ toolCall: UIMessagePart.Tool,
        settings: Settings,
        webSearchEnabled: Bool,
        transport: any IOSSearchHTTPTransport
    ) async -> IOSSearchToolOutput {
        guard webSearchEnabled else {
            return IOSSearchToolOutput(text: IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: "Web search is disabled in settings."
            ))
        }
        do {
            if toolCall.toolName == "search_web" {
                return try await executeSearchWebWithFallback(
                    toolCall,
                    settings: settings,
                    transport: transport
                )
            }
            return IOSSearchToolOutput(text: try await IOSSearchExecutor.execute(
                toolName: toolCall.toolName,
                toolInput: toolCall.input,
                settings: settings,
                transport: transport
            ))
        } catch is CancellationError {
            return IOSSearchToolOutput(text: IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: "User cancelled.",
                cancelled: true
            ))
        } catch {
            return IOSSearchToolOutput(text: IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ))
        }
    }

    private static func executeSearchWebWithFallback(
        _ toolCall: UIMessagePart.Tool,
        settings: Settings,
        transport: any IOSSearchHTTPTransport
    ) async throws -> IOSSearchToolOutput {
        let maxResults = Int(settings.searchCommonOptions.resultSize)
        let request = try IOSSearchExecutor.searchRequest(
            from: toolCall.input,
            defaultMaxResults: maxResults
        )
        let initialSelection = IOSSearchExecutor.searchProviderSelection(settings: settings)
        do {
            let execution = try await IOSSearchExecutor.searchResults(
                toolInput: toolCall.input,
                maxResults: maxResults,
                settings: settings,
                transport: transport
            )
            return IOSSearchToolOutput(text: IOSSearchExecutor.format(
                query: execution.request.query,
                results: execution.results,
                selection: execution.selection
            ), results: execution.results)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard let fallbackSelection = fallbackSelection(
                after: initialSelection,
                settings: settings,
                initialError: error
            ) else {
                throw error
            }
            let results = try await IOSSearchExecutor.searchFreeAggregate(
                query: request.query,
                maxResults: request.maxResults,
                settings: settings,
                transport: transport
            )
            return IOSSearchToolOutput(text: IOSSearchExecutor.format(
                query: request.query,
                results: results,
                selection: fallbackSelection
            ), results: results)
        }
    }

    private static func fallbackSelection(
        after selection: IOSSearchProviderSelection,
        settings: Settings,
        initialError: Error
    ) -> IOSSearchProviderSelection? {
        let reason = "原搜索服务 \(selection.providerName) 失败：\(errorSummary(initialError))"
        guard selection.route != .freeAggregate, IOSSearchExecutor.freeAggregateEnabled(settings) else { return nil }
        return IOSSearchProviderSelection(
            route: .freeAggregate,
            providerName: IOSFreeSearchAggregator.providerName,
            providerType: IOSFreeSearchAggregator.providerType,
            serviceId: nil,
            fallbackReason: reason
        )
    }

    private static func errorSummary(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard message.count > 120 else { return message }
        return String(message.prefix(120)) + "..."
    }
}
