import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Shared fixtures for the reusable multi-turn tool execution engine.
///
/// These exercise the engine's loop mechanics with a scripted provider (no
/// live HTTP). The engine generalizes ChatViewModel's single-tool-per-round
/// loop; real provider + real tool wiring is validated by the chat/SubAgent/
/// Deep Read integration tests.
class IOSAgentToolEngineTestCase: XCTestCase {

    enum GrokStubError: Error {
        case invoked
    }

    // MARK: - Fixtures

    func makeProviderSetting() -> ProviderSetting.OpenAI {
        // Full initializer: the KMP ProviderSetting.OpenAI bridge does not
        // expose Kotlin default args (same pattern as IOSLiveProviderSmokeTests).
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "engine-test",
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
    }

    func makeGrokProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Grok Web",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "",
            baseUrl: IOSGrokWebConstants.webBaseUrl,
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    func makeParams(tools: [String]) -> TextGenerationParams {
        // The engine decides whether to continue based on the tool calls the
        // model returns in each chunk, NOT on params.tools (the schema is only
        // sent to the model, which is scripted in tests). So an empty tool list
        // is fine here. Kotlin `Tool` cannot be constructed directly in Swift
        // anyway (its function-type fields don't bridge), so we pass [].
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
        return TextGenerationParams(
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

    func makePromptTranscriptProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "DeepSeek transcript test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://api.deepseek.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.deepseek
        )
    }

    func makePromptTranscriptParams() -> TextGenerationParams {
        let model = Model(
            modelId: "deepseek-v4-pro",
            displayName: "deepseek-v4-pro",
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
        return TextGenerationParams(
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

    func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        // KMP UIMessage bridge does not expose Kotlin default args; pass the
        // full initializer (same pattern as ChatViewModel).
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 6, day: 19, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func userMessage(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.user, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    func assistantText(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    func assistantReasoning(_ text: String) -> UIMessage {
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        return makeMessage(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Reasoning(
                reasoning: text,
                createdAt: instant,
                finishedAt: nil,
                metadata: nil
            )]
        )
    }

    func toolCallMessage(toolCallId: String, toolName: String, input: String) -> UIMessage {
        makeMessage(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallId,
                toolName: toolName,
                input: input,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )]
        )
    }

    func chunk(with message: UIMessage?) -> MessageChunk {
        MessageChunk(
            id: "chunk-\(UUID().uuidString)",
            model: "test-model",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
            usage: nil
        )
    }

    /// A scripted provider that returns a queue of assistant turns. The last
    /// turn is repeated if the engine keeps calling after the queue empties
    /// (lets us assert the loop terminated for the right reason).
    final class ScriptedProvider: IOSAgentTextProvider, @unchecked Sendable {
        private var script: [UIMessage]
        private(set) var callCount = 0
        init(_ script: [UIMessage]) { self.script = script }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            if !script.isEmpty {
                return chunk(with: script.removeFirst())
            }
            // If the engine over-runs, return a plain text turn (no tools) so
            // the loop stops cleanly rather than looping forever.
            return chunk(with: UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: "stop", metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 6, day: 19, hour: 0, minute: 0, second: 0, nanosecond: 0),
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

    /// A scripted provider that also records every `params` it was called
    /// with, so tests can assert what the engine declared on later rounds
    /// (P0-a: tool_search hits must be visible on the NEXT round's params).
    final class ParamsRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
        private var script: [UIMessage]
        private(set) var recordedParams: [TextGenerationParams] = []
        private(set) var recordedMessages: [[UIMessage]] = []
        init(_ script: [UIMessage]) { self.script = script }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            recordedParams.append(params)
            recordedMessages.append(messages)
            if !script.isEmpty {
                return chunk(with: script.removeFirst())
            }
            return chunk(with: UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: "stop", metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 6, day: 19, hour: 0, minute: 0, second: 0, nanosecond: 0),
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

        func execute(
            name: String,
            arguments: String,
            isUserInitiated: Bool
        ) async -> IOSAgentToolOutcome {
            .filled(bridge.executeToolSearch(argumentsJson: arguments))
        }
    }

    /// Every tool name `iosToolDeclaration` can materialize (>40 → lazy mode).
    func fullIosDeclarations() -> [Tool] {
        let names =
            IOSWorkspaceToolCatalog.supportedToolNames
            .union(IOSAgentTerminalToolCatalog.supportedToolNames)
            .union(IOSWebMountToolCatalog.supportedToolNames)
            .union(IOSSkillToolCatalog.toolNames)
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([
                "search_web", "scrape_web", "memory_tool", "generate_image",
                "mcp_call", "subagent_dispatch", "model_council_run", "ask_user",
            ])
        return ToolKt.iosToolDeclarations(names: Array(names).sorted())
    }

    final class ThrowingProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            throw NSError(
                domain: "AgentToolEngineTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "upstream unavailable"]
            )
        }
    }

    final class ScriptedStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        let chunks: [MessageChunk]

        init(_ chunks: [MessageChunk]) {
            self.chunks = chunks
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            chunks.last ?? MessageChunk(id: "empty", model: "test-model", choices: [], usage: nil)
        }

        func streamText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            chunks.forEach(onChunk)
            onComplete()
            return nil
        }
    }

    final class InterruptedStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        private let lock = NSLock()
        private let chunks: [MessageChunk]
        private let fails: Bool
        private var prelude: [MessageChunk]
        private var catalogs: [[String]] = []
        private var emitted = false
        private var lateComplete: (@Sendable () -> Void)?
        var didEmit: Bool { lock.withLock { emitted } }
        var toolCatalogs: [[String]] { lock.withLock { catalogs } }

        init(_ chunks: [MessageChunk], fails: Bool, prelude: [MessageChunk] = []) {
            self.chunks = chunks
            self.fails = fails
            self.prelude = prelude
        }

        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            chunks[0]
        }

        func streamText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
                        onChunk: @escaping @Sendable (MessageChunk) -> Void,
                        onComplete: @escaping @Sendable () -> Void,
                        onError: @escaping @Sendable (KotlinThrowable) -> Void) -> Kotlinx_coroutines_coreJob? {
            let initial = lock.withLock { () -> MessageChunk? in
                catalogs.append(params.tools.map(\.name))
                return prelude.isEmpty ? nil : prelude.removeFirst()
            }
            if let initial {
                onChunk(initial)
                onComplete()
                return nil
            }
            chunks.forEach(onChunk)
            lock.withLock { emitted = true; lateComplete = onComplete }
            if fails { onError(KotlinThrowable(message: "connection lost")) }
            return nil
        }

        func completeLate() { lock.withLock { lateComplete }?() }
    }

    final class DelayedCompletingStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        let delayNanos: UInt64

        init(delayNanos: UInt64) {
            self.delayNanos = delayNanos
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            MessageChunk(id: "unused", model: "test-model", choices: [], usage: nil)
        }

        func streamText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            Task {
                try? await Task.sleep(nanoseconds: delayNanos)
                onComplete()
            }
            return nil
        }
    }

    final class PreparingStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        private(set) var streamedAPIKey: String?

        func prepareRequest(
            providerSetting: ProviderSetting,
            params: TextGenerationParams
        ) async throws -> (ProviderSetting, TextGenerationParams) {
            guard let openAI = providerSetting as? ProviderSetting.OpenAI else {
                return (providerSetting, params)
            }
            return (
                ProviderSetting.OpenAI(
                    id: openAI.id,
                    enabled: openAI.enabled,
                    name: openAI.name,
                    models: openAI.models,
                    balanceOption: openAI.balanceOption,
                    builtIn: openAI.builtIn,
                    descriptionText: openAI.descriptionText,
                    shortDescriptionText: openAI.shortDescriptionText,
                    apiKey: "prepared-token",
                    baseUrl: openAI.baseUrl,
                    chatCompletionsPath: openAI.chatCompletionsPath,
                    useResponseApi: openAI.useResponseApi,
                    authMode: openAI.authMode,
                    brand: openAI.brand
                ),
                params
            )
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            Self.chunk(text: "fallback")
        }

        func streamText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            streamedAPIKey = (providerSetting as? ProviderSetting.OpenAI)?.apiKey
            onChunk(Self.chunk(text: "streamed"))
            onComplete()
            return nil
        }

        private static func chunk(text: String) -> MessageChunk {
            let message = UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: text, metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(
                    year: 2026,
                    month: 6,
                    day: 19,
                    hour: 0,
                    minute: 0,
                    second: 0,
                    nanosecond: 0
                ),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            return MessageChunk(
                id: "chunk-\(UUID().uuidString)",
                model: "test-model",
                choices: [
                    UIMessageChoice(
                        index: 0,
                        delta: nil,
                        message: message,
                        finishReason: "stop"
                    ),
                ],
                usage: nil
            )
        }
    }

    final class AssistantTextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    final class AssistantStageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentActivityStage] = []

        func append(_ value: AgentActivityStage) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [AgentActivityStage] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    actor ToolStageGate {
        private var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilEntered() async {
            while !entered {
                await Task.yield()
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    actor RecordingLedger: IOSAgentRunLedgering {
        private let preparation: IOSToolTransactionPreparation
        private let requestSnapshotResult: Bool
        private let terminalResult: Bool
        private var finishedOutcomes: [String] = []
        private var preparedCallIDs: [String] = []
        private var startedCount = 0
        private var requestSnapshots: [IOSRunRequestSnapshot] = []

        init(
            preparation: IOSToolTransactionPreparation = .ready,
            requestSnapshotResult: Bool = true,
            terminalResult: Bool = true
        ) {
            self.preparation = preparation
            self.requestSnapshotResult = requestSnapshotResult
            self.terminalResult = terminalResult
        }

        func recordRequestSnapshot(
            runId: String,
            snapshot: IOSRunRequestSnapshot
        ) async -> Bool {
            guard requestSnapshotResult else { return false }
            requestSnapshots.append(snapshot)
            return true
        }

        func recordToolCallPrepared(
            runId: String,
            toolCallId: String,
            toolName: String,
            argsDigest: String,
            effectClass: IOSToolEffectClass
        ) async -> IOSToolTransactionPreparation {
            preparedCallIDs.append(toolCallId)
            return preparation
        }

        func recordToolCallStarted(
            runId: String,
            toolCallId: String,
            toolName: String,
            argsDigest: String,
            effectClass: IOSToolEffectClass
        ) async -> Bool {
            startedCount += 1
            return true
        }

        func recordToolCallFinished(
            runId: String,
            toolCallId: String,
            outcome: String
        ) async -> Bool {
            await recordToolCallFinished(
                runId: runId, toolCallId: toolCallId, outcome: outcome,
                artifactId: nil, artifactVersion: nil, outcomeKind: nil, errorCode: nil, sourceRef: nil
            )
        }

        func recordToolCallFinished(
            runId: String,
            toolCallId: String,
            outcome: String,
            artifactId: String? = nil,
            artifactVersion: String? = nil,
            outcomeKind: String? = nil,
            errorCode: String? = nil,
            sourceRef: String? = nil
        ) async -> Bool {
            finishedOutcomes.append(outcome)
            return terminalResult
        }

        func recordApprovalDenied(
            runId: String,
            toolCallId: String,
            toolName: String,
            reason: String,
            capabilityId: String?
        ) async {
        }

        func outcomes() -> [String] {
            finishedOutcomes
        }

        func starts() -> Int { startedCount }
        func preparedIDs() -> [String] { preparedCallIDs }
        func snapshots() -> [IOSRunRequestSnapshot] { requestSnapshots }
    }

    /// A scripted executor that returns a fixed result per tool name, and
    /// records every call so tests can assert dispatch.
    final class RecordingExecutor: IOSToolExecutor {
        let result: IOSAgentToolOutcome
        private let events: AssistantTextRecorder?
        private let cancelOnExecute: Bool
        private(set) var calls: [(name: String, arguments: String, isUserInitiated: Bool)] = []
        init(_ result: IOSAgentToolOutcome, events: AssistantTextRecorder? = nil, cancelOnExecute: Bool = false) {
            self.result = result
            self.events = events
            self.cancelOnExecute = cancelOnExecute
        }

        func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
            calls.append((name, arguments, isUserInitiated))
            events?.append("execute:\(name)")
            if cancelOnExecute {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return result
        }
    }
}
