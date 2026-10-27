import Foundation
@preconcurrency import Shared

public enum IOSSharedKmpProviders {
    nonisolated(unsafe) public static let openAI = OpenAIKmpProvider()
    nonisolated(unsafe) public static let claude = ClaudeKmpProvider()
    nonisolated(unsafe) static let openAIBackgroundTransport = OpenAIResponsesBackgroundTransport()
}

/// Wraps the real KMP providers behind `IOSAgentTextProvider`. Routes to
/// `OpenAIKmpProvider` or `ClaudeKmpProvider` based on the provider's sealed
/// type, so sub-agents/councils can run on either protocol.
public struct OpenAIKmpProviderAdapter: IOSAgentTextProvider, IOSAgentStreamingProvider {
    typealias GrokGenerator = @Sendable (
        ProviderSetting.OpenAI,
        [UIMessage],
        TextGenerationParams
    ) async throws -> MessageChunk

    private let openAIProvider: OpenAIKmpProvider
    private let claudeProvider: ClaudeKmpProvider
    private let grokGenerator: GrokGenerator

    public init(
        openAIProvider: OpenAIKmpProvider = IOSSharedKmpProviders.openAI,
        claudeProvider: ClaudeKmpProvider = IOSSharedKmpProviders.claude
    ) {
        self.openAIProvider = openAIProvider
        self.claudeProvider = claudeProvider
        self.grokGenerator = { provider, messages, params in
            try await Self.generateGrokText(
                providerSetting: provider,
                messages: messages,
                params: params
            )
        }
    }

    init(
        openAIProvider: OpenAIKmpProvider = IOSSharedKmpProviders.openAI,
        claudeProvider: ClaudeKmpProvider = IOSSharedKmpProviders.claude,
        grokGenerator: @escaping GrokGenerator
    ) {
        self.openAIProvider = openAIProvider
        self.claudeProvider = claudeProvider
        self.grokGenerator = grokGenerator
    }

    public func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        let resolvedProvider = try await IOSGrokWebProviderResolver.resolved(
            try await IOSCodexProviderResolver.resolved(providerSetting)
        )
        let resolvedParams = IOSGrokWebProviderResolver.augmentParamsForGrok(
            IOSCodexProviderResolver.augmentParamsForCodex(
                params,
                provider: resolvedProvider
            ),
            provider: resolvedProvider
        )
        if let openAI = resolvedProvider as? ProviderSetting.OpenAI,
           IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI) {
            return try await grokGenerator(openAI, messages, params)
        }
        if let openAI = resolvedProvider as? ProviderSetting.OpenAI {
            return try await openAIProvider.generateText(
                providerSetting: openAI,
                messages: messages,
                params: resolvedParams
            )
        }
        if let claude = resolvedProvider as? ProviderSetting.Claude {
            return try await claudeProvider.generateText(
                providerSetting: claude,
                messages: messages,
                params: resolvedParams
            )
        }
        if let google = resolvedProvider as? ProviderSetting.Google,
           IOSGeminiProviderResolver.supportsChat(google) {
            let boxed = UncheckedUIMessageBox(messages)
            return try await Task { @MainActor in
                try await IOSGeminiClient(provider: google).generateText(
                    messages: boxed.value,
                    params: resolvedParams
                )
            }.value
        }
        throw NSError(
            domain: "AmberAgent.AgentToolEngine",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: Self.unsupportedProviderMessage(providerSetting)]
        )
    }

    public func prepareRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> (ProviderSetting, TextGenerationParams) {
        let resolvedProvider = try await IOSGrokWebProviderResolver.resolved(
            try await IOSCodexProviderResolver.resolved(providerSetting)
        )
        let resolvedParams = IOSGrokWebProviderResolver.augmentParamsForGrok(
            IOSCodexProviderResolver.augmentParamsForCodex(
                params,
                provider: resolvedProvider
            ),
            provider: resolvedProvider
        )
        return (resolvedProvider, resolvedParams)
    }

    public func supportsStreaming(providerSetting: ProviderSetting) -> Bool {
        if providerSetting is ProviderSetting.Google { return false }
        guard let openAI = providerSetting as? ProviderSetting.OpenAI else { return true }
        return !IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI)
    }

    public func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        if let openAI = providerSetting as? ProviderSetting.OpenAI {
            return openAIProvider.streamTextCancellable(
                providerSetting: openAI, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError
            )
        }
        if let claude = providerSetting as? ProviderSetting.Claude {
            return claudeProvider.streamTextCancellable(
                providerSetting: claude, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError
            )
        }
        onError(KotlinThrowable(message: Self.unsupportedProviderMessage(providerSetting)))
        return nil
    }

    private static func unsupportedProviderMessage(_ provider: ProviderSetting) -> String {
        if provider is ProviderSetting.Google {
            return "Gemini 还不能用于子代理和 Council，请换用 OpenAI 或 Claude。"
        }
        return "当前服务商类型暂不支持子代理"
    }

    private static func generateGrokText(
        providerSetting: ProviderSetting.OpenAI,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        let prompt = messages.compactMap { message -> String? in
            let text = message.parts.compactMap { part in
                (part as? UIMessagePart.Text)?.text
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(String(describing: message.role).lowercased())]\n\(text)"
        }
        .joined(separator: "\n\n")
        let text = try await IOSGrokWebClient(
            providerId: IOSGrokWebProviderResolver.providerKey(providerSetting)
        ).generateText(prompt: prompt, modelId: params.model.modelId)
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: params.model.id,
            usage: nil,
            translation: nil
        )
        return MessageChunk(
            id: "",
            model: params.model.modelId,
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

/// The final state of an engine run.


/// Carries the canonical in-flight turn when streaming exits without complete.
