import Foundation
@preconcurrency import Shared

enum IOSDeepReadSynthesisRunner {
    struct Result: @unchecked Sendable {
        var messages: [UIMessage]
        var providerFailureMessage: String?
        var hitOutputLimit = false
        var hitStepLimit = false
        var pendingApproval: Bool? = nil
    }

    static func requestHeaders(for provider: ProviderSetting, model: [CustomHeader]) -> [CustomHeader] {
        model
    }

    static func run(
        provider: any IOSAgentTextProvider,
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async -> Result {
        do {
            try Task.checkCancellation()
            let chunk = try await provider.generateText(providerSetting: providerSetting, messages: messages, params: params)
            try Task.checkCancellation()
            let choice = chunk.choices.first
            guard let response = choice?.message else {
                return Result(messages: messages, providerFailureMessage: "模型没有返回文章内容。")
            }
            let finish = choice?.finishReason?.lowercased() ?? ""
            let outputLimit = finish == "length" || finish == "max_tokens"
            let pendingTools = response.parts.contains { ($0 as? UIMessagePart.Tool)?.output.isEmpty == true }
            return Result(
                messages: messages + [response],
                providerFailureMessage: outputLimit ? "模型输出达到长度上限。" : nil,
                hitOutputLimit: outputLimit,
                hitStepLimit: pendingTools
            )
        } catch {
            return Result(messages: messages, providerFailureMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
