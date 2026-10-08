import Foundation
@preconcurrency import Shared

/// The reading pipeline only needs one model round. The original application
/// continues to use its existing engine; the standalone target supplies its own
/// provider composition without pulling in the chat and tool-execution shell.
enum IOSDeepReadSynthesisRunner {
    static func requestHeaders(for provider: ProviderSetting, model: [CustomHeader]) -> [CustomHeader] {
        ChatProviderConfiguration.requestHeaders(for: provider, model: model)
    }

    static func run(
        provider: any IOSAgentTextProvider,
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async -> IOSAgentToolEngineResult {
        await IOSAgentToolEngine(
            provider: provider,
            executors: [:],
            configuration: .init(maxSteps: 1, honorApprovalPause: false)
        ).run(providerSetting: providerSetting, messages: messages, params: params)
    }
}
