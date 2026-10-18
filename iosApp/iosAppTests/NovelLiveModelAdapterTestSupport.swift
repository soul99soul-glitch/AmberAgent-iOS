import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

extension NovelLiveModelAdapterTests {
    struct Fixture: @unchecked Sendable {
        let model: Model
        let provider: ProviderSetting.OpenAI
        let catalog: NovelLiveModelCatalog
    }

    func makeFixture(
        apiKey: String,
        reasoning: Bool = false,
        modelID: String = "novel-live",
        contextWindowTokens: Int? = 128_000
    ) -> Fixture {
        let model = makeModel(
            modelID: modelID,
            reasoning: reasoning,
            contextWindowTokens: contextWindowTokens
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Novel Test",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: apiKey,
            baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        return Fixture(
            model: model,
            provider: provider,
            catalog: NovelLiveModelCatalog(currentModel: model, providers: [provider])
        )
    }

    func makeResponsesFixture() -> Fixture {
        let model = makeModel()
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "OpenAI Responses",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://api.openai.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: true,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        return Fixture(
            model: model,
            provider: provider,
            catalog: NovelLiveModelCatalog(currentModel: model, providers: [provider])
        )
    }

    func makeModel(
        modelID: String = "novel-live",
        reasoning: Bool = false,
        customBodies: [CustomBody] = [],
        contextWindowTokens: Int? = 128_000
    ) -> Model {
        Model(
            modelId: modelID,
            displayName: "Novel Live",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [CustomHeader(name: "X-Novel", value: "1")],
            customBodies: customBodies,
            inputModalities: [],
            outputModalities: [],
            abilities: reasoning ? [.reasoning] : [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: contextWindowTokens.map { KotlinInt(value: Int32($0)) },
            providerOverwrite: nil
        )
    }

    func makeAdapter(fixture: Fixture) -> NovelLiveModelAdapter {
        NovelLiveModelAdapter(
            catalogProvider: { fixture.catalog },
            kmpTransport: { _, callbacks in
                callbacks.onComplete()
                return nil
            }
        )
    }

    func makeRequest(
        model: NovelResolvedModel,
        purpose: NovelModelPurpose = .prose,
        reasoning: NovelModelReasoningLevel = .off,
        withProjectContext: Bool = false
    ) -> NovelModelRequest {
        NovelModelRequest(
            runID: NovelRunID(),
            model: model,
            purpose: purpose,
            messages: [
                NovelModelMessage(role: .system, content: "仅使用小说上下文。"),
                NovelModelMessage(role: .user, content: "继续写。"),
            ],
            parameters: NovelModelParameters(
                temperature: 0.8,
                topP: 0.95,
                maxOutputTokens: 4_096,
                reasoningLevel: reasoning
            ),
            projectID: withProjectContext ? NovelProjectID() : nil,
            branchID: withProjectContext ? NovelBranchID() : nil
        )
    }

    static func deltaChunk(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: UIMessage.companion.assistant(prompt: text),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    static func replacementChunk(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: UIMessage.companion.assistant(prompt: text),
                finishReason: "stop"
            )],
            usage: nil
        )
    }

    static func reasoningChunk(_ text: String, isReplacement: Bool = false) -> MessageChunk {
        let createdAt = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Reasoning(
                reasoning: text,
                createdAt: createdAt,
                finishedAt: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 8,
                day: 4,
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
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: isReplacement ? nil : message,
                message: isReplacement ? message : nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    static func usageChunk() -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [],
            usage: TokenUsage(
                promptTokens: 21,
                completionTokens: 8,
                cachedTokens: 5,
                totalTokens: 29,
                generationDurationMs: 0
            )
        )
    }

    static func collect(_ stream: AsyncStream<NovelModelEvent>) async -> [NovelModelEvent] {
        var events: [NovelModelEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

final class RecordingNovelSearchExecutor: IOSToolExecutor, @unchecked Sendable {
    private let recordedCalls = LockedBox<[String]>([])

    var calls: [String] {
        recordedCalls.value
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        recordedCalls.mutate { $0.append(name) }
        return .filled(#"{"results":[{"title":"史料","url":"https://example.test"}]}"#)
    }
}

final class ScriptedNovelDiscussionProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let state = LockedBox((calls: 0, receivedToolOutput: false))

    var callCount: Int {
        state.value.calls
    }

    var secondTurnReceivedToolOutput: Bool {
        state.value.receivedToolOutput
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        var currentCall = 0
        state.mutate { state in
            state.calls += 1
            currentCall = state.calls
            if currentCall == 2 {
                state.receivedToolOutput = messages
                .flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .contains { !$0.output.isEmpty }
            }
        }

        if currentCall == 1 {
            return chunk(parts: [UIMessagePart.Tool(
                toolCallId: "novel-search-1",
                toolName: "search_web",
                input: #"{"query":"唐代凌烟阁功臣名单"}"#,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )])
        }
        return chunk(parts: [UIMessagePart.Text(
            text: "根据检索结果，建议先核对史料再调整人物动机。",
            metadata: nil
        )])
    }

    private func chunk(parts: [UIMessagePart]) -> MessageChunk {
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: parts,
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 7,
                day: 14,
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
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: message,
                finishReason: "stop"
            )],
            usage: nil
        )
    }
}

/// Streaming variant of `ScriptedNovelDiscussionProvider`: step 1 streams
/// visible text before its tool call, step 2 streams its final answer token
/// by token. Used to prove the engine's per-step `onAssistantText` callbacks
/// don't lose earlier steps' text across the tool-loop boundary.
final class ScriptedStreamingNovelDiscussionProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
    static let step1Text = "我先搜索一下相关设定。"
    static let step2Text = "根据检索结果，建议先核对史料再调整人物动机。"

    private let state = LockedBox(0)

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        XCTFail("Streaming test double must not fall back to non-streaming generateText.")
        return MessageChunk(id: "unused", model: "novel-live", choices: [], usage: nil)
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        var currentCall = 0
        state.mutate { calls in
            calls += 1
            currentCall = calls
        }

        if currentCall == 1 {
            onChunk(Self.finalChunk(parts: [
                UIMessagePart.Text(text: Self.step1Text, metadata: nil),
                UIMessagePart.Tool(
                    toolCallId: "novel-search-1",
                    toolName: "search_web",
                    input: #"{"query":"唐代凌烟阁功臣名单"}"#,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
            ]))
        } else {
            onChunk(Self.deltaChunk("根据"))
            onChunk(Self.deltaChunk("检索结果，"))
            onChunk(Self.finalChunk(parts: [
                UIMessagePart.Text(text: Self.step2Text, metadata: nil),
            ]))
        }
        onComplete()
        return nil
    }

    private static func deltaChunk(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: UIMessage.companion.assistant(prompt: text),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    private static func finalChunk(parts: [UIMessagePart]) -> MessageChunk {
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: parts,
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 7,
                day: 14,
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
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: message,
                finishReason: "stop"
            )],
            usage: nil
        )
    }
}

/// One-step discussion stream that emits thinking before visible answer text.
final class ScriptedStreamingReasoningDiscussionProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
    static let answerText = "建议先核对史料再调整人物动机。"

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        XCTFail("Streaming test double must not fall back to non-streaming generateText.")
        return MessageChunk(id: "unused", model: "novel-live", choices: [], usage: nil)
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        onChunk(Self.reasoningDelta("先想动机"))
        onChunk(Self.reasoningDelta("再核对史料"))
        onChunk(Self.textDelta("建议先核对"))
        onChunk(Self.finalAnswer(Self.answerText))
        onComplete()
        return nil
    }

    private static func reasoningDelta(_ text: String) -> MessageChunk {
        let createdAt = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Reasoning(
                reasoning: text,
                createdAt: createdAt,
                finishedAt: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 8,
                day: 23,
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
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: message,
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    private static func textDelta(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: UIMessage.companion.assistant(prompt: text),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    private static func finalAnswer(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "novel-live",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: UIMessage.companion.assistant(prompt: text),
                finishReason: "stop"
            )],
            usage: nil
        )
    }
}
