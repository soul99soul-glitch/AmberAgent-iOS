import Foundation
@preconcurrency import Shared

public protocol IOSAgentTextProvider: Sendable {
    func generateText(providerSetting: ProviderSetting, messages: [UIMessage],
                      params: TextGenerationParams) async throws -> MessageChunk
}

enum DeepReadSharedProviders {
    nonisolated(unsafe) static let openAI = OpenAIKmpProvider()
    nonisolated(unsafe) static let claude = ClaudeKmpProvider()
}

public struct OpenAIKmpProviderAdapter: IOSAgentTextProvider {
    private let openAI: OpenAIKmpProvider
    private let claude: ClaudeKmpProvider
    public init() {
        openAI = DeepReadSharedProviders.openAI
        claude = DeepReadSharedProviders.claude
    }

    public func generateText(providerSetting: ProviderSetting, messages: [UIMessage],
                             params: TextGenerationParams) async throws -> MessageChunk {
        if let provider = providerSetting as? ProviderSetting.OpenAI {
            guard provider.authMode == .apiKey else {
                throw AdapterError.unsupportedAuthentication
            }
            return try await openAI.generateText(providerSetting: provider, messages: messages, params: params)
        }
        if let provider = providerSetting as? ProviderSetting.Claude {
            return try await claude.generateText(providerSetting: provider, messages: messages, params: params)
        }
        throw AdapterError.unsupportedProvider
    }

    private enum AdapterError: LocalizedError {
        case unsupportedAuthentication, unsupportedProvider
        var errorDescription: String? {
            switch self {
            case .unsupportedAuthentication: "独立阅读应用目前支持 API Key 认证，请配置 API 服务。"
            case .unsupportedProvider: "当前阅读应用支持 OpenAI 兼容 API 与 Claude API。"
            }
        }
    }
}
