import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class BackgroundFeatureRecipeWebMountRuntime: IOSWebMountRuntimeServicing {
    let webView: WKWebView? = nil
    let targetRef = "wm:recipe-checkout:pay-and-submit"
    private(set) var preflightCount = 0
    private(set) var dispatchCount = 0
    private(set) var lastActionAllowedHighConsequence = false
    var snapshot: IOSWebMountRuntimeSnapshot

    init(sessionId: String = "recipe-webmount-session") {
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: sessionId,
            status: .ready,
            requestedURL: "https://github.com/login",
            currentURL: "https://github.com/login",
            title: "Checkout",
            estimatedProgress: 1,
            canGoBack: false,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 1
        )
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        snapshot.currentURL = url.absoluteString
        return snapshot
    }

    func state() async throws -> [String: Any] {
        ["snapshot_id": "recipe-snapshot", "page_revision": 1]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        ["mode": mode, "snapshot_id": "recipe-snapshot"]
    }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] {
        ["ok": true, "snapshot_id": "recipe-snapshot"]
    }

    func interact(
        method: String,
        selector: String?,
        text: String?,
        options: [String: Any]
    ) async throws -> [String: Any] {
        guard selector == targetRef,
              options["snapshot_id"] as? String == "recipe-snapshot" else {
            return ["ok": false, "reason": "Target is not from the current observation."]
        }
        if options["_amber_preflight_only"] as? Bool == true {
            preflightCount += 1
            return [
                "ok": false,
                "needs_user_action": true,
                "reason": "This action may pay or submit.",
                "consequence": "Payment or order submission changes remote state.",
                "snapshot_id": "recipe-snapshot"
            ]
        }
        lastActionAllowedHighConsequence = options["_amber_allow_high_consequence"] as? Bool == true
        guard lastActionAllowedHighConsequence else {
            return [
                "ok": false,
                "needs_user_action": true,
                "reason": "This action may pay or submit.",
                "snapshot_id": "recipe-snapshot"
            ]
        }
        dispatchCount += 1
        return ["ok": true, "verified": true, "snapshot_id": "recipe-snapshot"]
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data(), width: 1, height: 1, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot { snapshot }
    func forward() async -> IOSWebMountRuntimeSnapshot { snapshot }
}

/// Sendable reduction of one `agent_event` row.
struct LedgerRowSnapshot: Sendable {
    let type: String
    let seq: Int64
    let payload: String
}

/// Scripted provider that records every `params` it was called with, so tests
/// can assert what the round declared (P0-a Fix C / Wave B2 canary).
final class ParamsRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private var script: [UIMessage]
    private(set) var recordedParams: [TextGenerationParams] = []
    init(_ script: [UIMessage]) { self.script = script }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        recordedParams.append(params)
        if !script.isEmpty {
            return chunk(with: script.removeFirst())
        }
        return chunk(with: UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "stop", metadata: nil)],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        ))
    }

    private func chunk(with message: UIMessage?) -> MessageChunk {
        MessageChunk(
            id: "chunk-\(UUID().uuidString)",
            model: "test-model",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
            usage: nil
        )
    }
}

/// Executes tool_search through a real KMP exposure bridge (local, no
/// network) so the hit becomes visible inside the bridge.
final class BridgeToolSearchExecutor: IOSToolExecutor {
    private let bridge: IosToolExposureBridge
    init(bridge: IosToolExposureBridge) { self.bridge = bridge }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        .filled(bridge.executeToolSearch(argumentsJson: arguments))
    }
}

/// Executes one `recipe__*` call through the REAL `ChatToolRuntime` recipe
/// route with the round's pinned snapshot (the production path; only the
/// provider is scripted).
@MainActor
final class RecipeRouteExecutor: IOSToolExecutor {
    private let runtime: ChatToolRuntime
    private let snapshot: IOSDynamicToolCatalogSnapshot
    private let bridge: IosToolExposureBridge
    private let runId: String
    private let providerSetting: ProviderSetting.OpenAI
    private let params: TextGenerationParams

    init(
        runtime: ChatToolRuntime,
        snapshot: IOSDynamicToolCatalogSnapshot,
        bridge: IosToolExposureBridge,
        runId: String
    ) {
        self.runtime = runtime
        self.snapshot = snapshot
        self.bridge = bridge
        self.runId = runId
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        self.providerSetting = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "recipe-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        self.params = TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "tc-\(name)-\(UUID().uuidString)",
            toolName: name,
            input: arguments,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        let baseMessages = [UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolCall],
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )]
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: baseMessages
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: snapshot
        )
        switch result {
        case .completed(let messages):
            let output = messages.flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output.compactMap { ($0 as? UIMessagePart.Text)?.text }
                .joined() ?? ""
            return .filled(output)
        case .waitingForApproval:
            return .needsApproval("Recipe step requires approval.")
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        case .outcomeUnknown(let messages):
            let output = messages.flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output ?? []
            return .outcomeUnknown(output)
        }
    }
}

/// 无网络搜索传输（同 IOSExecNestedNoopSearchTransport 模式）。
struct RecipeNoopSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (response, Data())
    }
}

struct RecipeUnusedProvider: IOSAgentTextProvider {
    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        throw NSError(domain: "IOSRecipeIntegrationTests", code: 1)
    }
}

final class RecipeUncheckedToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor

    init(_ base: any IOSToolExecutor) {
        self.base = base
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await base.execute(
            name: name,
            arguments: arguments,
            isUserInitiated: isUserInitiated
        )
    }
}
