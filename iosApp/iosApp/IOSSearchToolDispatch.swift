import Foundation
@preconcurrency import Shared

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
        guard webSearchEnabled else {
            return IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: "Web search is disabled in settings."
            )
        }
        do {
            if toolCall.toolName == "search_web" {
                return try await executeSearchWebWithFallback(
                    toolCall,
                    settings: settings,
                    transport: transport
                )
            }
            return try await IOSSearchExecutor.execute(
                toolName: toolCall.toolName,
                toolInput: toolCall.input,
                settings: settings,
                transport: transport
            )
        } catch is CancellationError {
            return IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: "User cancelled.",
                cancelled: true
            )
        } catch {
            return IOSToolFailurePayload.json(
                toolName: toolCall.toolName,
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private static func executeSearchWebWithFallback(
        _ toolCall: UIMessagePart.Tool,
        settings: Settings,
        transport: any IOSSearchHTTPTransport
    ) async throws -> String {
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
            return IOSSearchExecutor.format(
                query: execution.request.query,
                results: execution.results,
                selection: execution.selection
            )
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
            return IOSSearchExecutor.format(
                query: request.query,
                results: results,
                selection: fallbackSelection
            )
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
