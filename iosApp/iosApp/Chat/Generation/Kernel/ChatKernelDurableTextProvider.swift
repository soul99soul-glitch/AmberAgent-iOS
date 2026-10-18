import Foundation
@preconcurrency import Shared

final class ChatKernelDurableTextProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
    private let base = OpenAIKmpProviderAdapter()
    private let onCheckpoint: @Sendable (String, Int64, UUID) -> Void
    private let onDurableDisconnect: @Sendable (String, UUID) -> Void
    private let lock = NSLock()
    private var activeJob: Kotlinx_coroutines_coreJob?
    private var activeOnError: (@Sendable (KotlinThrowable) -> Void)?
    private var hasCheckpoint = false
    private var requestToken = UUID()

    init(
        onCheckpoint: @escaping @Sendable (String, Int64, UUID) -> Void,
        onDurableDisconnect: @escaping @Sendable (String, UUID) -> Void
    ) {
        self.onCheckpoint = onCheckpoint
        self.onDurableDisconnect = onDurableDisconnect
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        try await base.generateText(
            providerSetting: providerSetting,
            messages: messages,
            params: params
        )
    }

    func prepareRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> (ProviderSetting, TextGenerationParams) {
        try await base.prepareRequest(providerSetting: providerSetting, params: params)
    }

    func supportsStreaming(providerSetting: ProviderSetting) -> Bool {
        if let openAI = providerSetting as? ProviderSetting.OpenAI,
           Self.usesBackgroundResponses(openAI) {
            return true
        }
        return base.supportsStreaming(providerSetting: providerSetting)
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        guard let openAI = providerSetting as? ProviderSetting.OpenAI,
              Self.usesBackgroundResponses(openAI) else {
            return base.streamText(
                providerSetting: providerSetting,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError
            )
        }

        lock.lock()
        hasCheckpoint = false
        let token = UUID()
        requestToken = token
        activeOnError = onError
        lock.unlock()
        do {
            let job = try IOSSharedKmpProviders.openAIBackgroundTransport.startBackground(
                providerSetting: openAI,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onCheckpoint: { [weak self] responseId, sequenceNumber in
                    guard let self else { return }
                    self.lock.lock()
                    self.hasCheckpoint = true
                    self.lock.unlock()
                    self.onCheckpoint(responseId, sequenceNumber.int64Value, token)
                },
                onComplete: { [weak self] in
                    self?.clearActiveJob()
                    onComplete()
                },
                onDisconnected: { [weak self] error in
                    guard let self else { return }
                    self.lock.lock()
                    let canDetach = self.hasCheckpoint
                    self.lock.unlock()
                    if canDetach {
                        self.onDurableDisconnect(error.message ?? String(describing: error), token)
                    } else {
                        self.clearActiveJob()
                        onError(KotlinThrowable(message: error.message ?? String(describing: error)))
                    }
                },
                onFailure: { [weak self] error in
                    self?.clearActiveJob()
                    onError(KotlinThrowable(message: error.message ?? String(describing: error)))
                }
            )
            lock.lock()
            activeJob = job
            lock.unlock()
            return job
        } catch {
            clearActiveJob()
            onError(KotlinThrowable(message: (error as NSError).localizedDescription))
            return nil
        }
    }

#if DEBUG
    var requestTokenForTesting: UUID { lock.withLock { requestToken } }
#endif

    func isCurrentRequest(_ token: UUID) -> Bool {
        lock.withLock { requestToken == token }
    }

    func invalidateCompletedRequest() {
        lock.withLock { requestToken = UUID() }
    }

    func cancelLocalStream() {
        lock.lock()
        let job = activeJob
        activeJob = nil
        activeOnError = nil
        lock.unlock()
        job?.cancel(cause: nil)
    }

    /// 服务端已有 checkpoint、但本地持久化/接管失败时，必须恢复 Engine 的
    /// continuation；否则 provider 已断线而 Host 又没有后台 owner，run 会挂住。
    func failLocalStream(message: String) {
        lock.lock()
        let job = activeJob
        let onError = activeOnError
        activeJob = nil
        activeOnError = nil
        lock.unlock()
        job?.cancel(cause: nil)
        onError?(KotlinThrowable(message: message))
    }

    private func clearActiveJob() {
        lock.lock()
        activeJob = nil
        activeOnError = nil
        lock.unlock()
    }

    private static func usesBackgroundResponses(_ provider: ProviderSetting.OpenAI) -> Bool {
        guard provider.useResponseApi,
              provider.authMode != OpenAIAuthMode.codexOauth,
              let url = URL(string: provider.baseUrl),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.openai.com",
              url.port == nil,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}
