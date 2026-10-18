import Foundation
@preconcurrency import Shared

struct NovelLiveModelCatalog: @unchecked Sendable {
    let currentModel: Model?
    let providers: [ProviderSetting]
}

struct NovelGrokIsolationOptions: Equatable, Sendable {
    let disableSearch: Bool
    let disableMemory: Bool

    static let novel = NovelGrokIsolationOptions(
        disableSearch: true,
        disableMemory: true
    )

    static let discussion = NovelGrokIsolationOptions(
        disableSearch: false,
        disableMemory: true
    )

    static func forPurpose(
        _ purpose: NovelModelPurpose,
        searchEnabled: Bool
    ) -> NovelGrokIsolationOptions {
        purpose == .discussion && searchEnabled ? .discussion : .novel
    }
}

struct NovelLiveTransportRequest: @unchecked Sendable {
    let providerSetting: ProviderSetting
    let messages: [UIMessage]
    let parameters: TextGenerationParams
    let grokIsolation: NovelGrokIsolationOptions?
    /// Discussion-only: owning project + current branch for the novel project
    /// write tools. Nil for every other purpose — zero impact on non-discussion
    /// transports.
    let novelProjectContext: NovelProjectToolRunContext?

    init(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        parameters: TextGenerationParams,
        grokIsolation: NovelGrokIsolationOptions?,
        novelProjectContext: NovelProjectToolRunContext? = nil
    ) {
        self.providerSetting = providerSetting
        self.messages = messages
        self.parameters = parameters
        self.grokIsolation = grokIsolation
        self.novelProjectContext = novelProjectContext
    }
}

struct NovelLiveTransportCallbacks: @unchecked Sendable {
    let onChunk: @Sendable (MessageChunk) -> Void
    let onCheckpoint: @Sendable (NovelResponsesResumeCursor) -> Void
    let onAskUser: @Sendable (NovelAskUserPrompt, String) -> Void
    let onComplete: @Sendable () -> Void
    let onFailure: @Sendable (NovelModelFailure) -> Void
    let onDisconnected: @Sendable (NovelModelFailure) -> Void

    init(
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onCheckpoint: @escaping @Sendable (NovelResponsesResumeCursor) -> Void = { _ in },
        onAskUser: @escaping @Sendable (NovelAskUserPrompt, String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (NovelModelFailure) -> Void,
        onDisconnected: @escaping @Sendable (NovelModelFailure) -> Void = { _ in }
    ) {
        self.onChunk = onChunk
        self.onCheckpoint = onCheckpoint
        self.onAskUser = onAskUser
        self.onComplete = onComplete
        self.onFailure = onFailure
        self.onDisconnected = onDisconnected
    }
}

struct NovelLiveCancellationHandle: @unchecked Sendable {
    private let action: @Sendable () -> Void
    private let remoteAction: @Sendable () -> Void

    init(
        _ action: @escaping @Sendable () -> Void,
        remoteAction: @escaping @Sendable () -> Void = {}
    ) {
        self.action = action
        self.remoteAction = remoteAction
    }

    func cancel() {
        action()
    }

    func cancelRemote() {
        remoteAction()
    }
}

typealias NovelLiveTransport = @Sendable (
    NovelLiveTransportRequest,
    NovelLiveTransportCallbacks
) -> NovelLiveCancellationHandle?

typealias NovelDurableResumeTransport = @Sendable (
    NovelModelResumeRequest,
    ProviderSetting,
    [CustomHeader],
    NovelLiveTransportCallbacks
) -> NovelLiveCancellationHandle?

struct NovelLiveCodexHooks: @unchecked Sendable {
    let isCodex: @Sendable (ProviderSetting) -> Bool
    let resolve: @Sendable (ProviderSetting) async throws -> ProviderSetting
    let augment: @Sendable (TextGenerationParams, ProviderSetting) -> TextGenerationParams
    let diagnose: @Sendable (ProviderSetting, ProviderSetting, TextGenerationParams) -> Void

    static let production = NovelLiveCodexHooks(
        isCodex: { IOSCodexProviderResolver.isCodexProvider($0) },
        resolve: {
            try await IOSGrokWebProviderResolver.resolved(
                try await IOSCodexProviderResolver.resolved($0)
            )
        },
        augment: { params, provider in
            IOSGrokWebProviderResolver.augmentParamsForGrok(
                IOSCodexProviderResolver.augmentParamsForCodex(params, provider: provider),
                provider: provider
            )
        },
        diagnose: {
            IOSCodexProviderResolver.writeRequestDiagnostic(
                originalProvider: $0,
                resolvedProvider: $1,
                params: $2
            )
        }
    )

    static let passthrough = NovelLiveCodexHooks(
        isCodex: { _ in false },
        resolve: { $0 },
        augment: { parameters, _ in parameters },
        diagnose: { _, _, _ in }
    )
}

/// The production bridge from the Novel domain request to the existing provider
/// runtimes. It owns only transport state; prompts, persistence, and terminal
/// project mutations remain in the Novel module.
