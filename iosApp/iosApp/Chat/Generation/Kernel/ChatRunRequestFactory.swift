import Foundation
@preconcurrency import Shared

/// Builds one frozen adapter request while retaining the established mailbox/steer boxes.
@MainActor
final class ChatRunRequestFactory {
    private let bindings: ChatGenerationBindings
    private let maxToolResumeCount: Int
    private let executionPolicy: IOSExecutionPolicySnapshot?
    private let phoneAutomaticReasoning: Bool
    private let phoneControl: IOSPhoneControlController
    private let prepareUploadMessages: @MainActor ([UIMessage]) async throws -> [UIMessage]
    private let approvalDecider: @MainActor (ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision?

    init(
        bindings: ChatGenerationBindings,
        maxToolResumeCount: Int,
        executionPolicy: IOSExecutionPolicySnapshot?,
        phoneAutomaticReasoning: Bool,
        phoneControl: IOSPhoneControlController,
        prepareUploadMessages: @escaping @MainActor ([UIMessage]) async throws -> [UIMessage],
        approvalDecider: @escaping @MainActor (ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision?
    ) {
        self.bindings = bindings
        self.maxToolResumeCount = maxToolResumeCount
        self.executionPolicy = executionPolicy
        self.phoneAutomaticReasoning = phoneAutomaticReasoning
        self.phoneControl = phoneControl
        self.prepareUploadMessages = prepareUploadMessages
        self.approvalDecider = approvalDecider
    }

    func make(
        adapterProvider: any IOSAgentTextProvider,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        initialMessages: [UIMessage],
        toolExposureBridge: IosToolExposureBridge,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        citationTracker: IOSMemoryCitationTracker
    ) -> ChatRunKernelAdapter.RunRequest {
        let bindingsBox = UncheckedHostBindingsBox(bindings)
        let conversationBox = UncheckedHostConversationIdBox(conversationId)
        return ChatRunKernelAdapter.RunRequest(
            provider: adapterProvider,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            initialMessages: initialMessages,
            toolExposureBridge: toolExposureBridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot,
            recipeCatalogRefresh: {
                await IOSDynamicToolRegistry.shared.refresh()
            },
            executionPolicy: executionPolicy,
            phoneAutomaticReasoning: phoneAutomaticReasoning,
            phoneControl: phoneControl,
            maxToolResumeCount: maxToolResumeCount,
            drainSteer: {
                let boxed = await bindingsBox.drainSteer(conversationBox)
                return boxed.values
            },
            mailboxDrain: {
                await bindingsBox.drainMailbox(conversationBox)
            },
            citationTracker: citationTracker,
            prepareUploadMessages: prepareUploadMessages,
            nestedToolRunner: nil,
            approvalDecider: approvalDecider
        )
    }

}

/// 引擎 @Sendable 钩子捕获 bindings(非 Sendable 闭包结构体)的跨边界盒;
/// 所有实际访问都经 MainActor.run 回到主 actor。
private struct UncheckedHostBindingsBox: @unchecked Sendable {
    let value: ChatGenerationBindings
    init(_ value: ChatGenerationBindings) { self.value = value }

    @MainActor
    func drainSteer(_ conversation: UncheckedHostConversationIdBox) async -> IOSMailboxDrainResult {
        IOSMailboxDrainResult(values: await value.drainSteerQueue(conversation.value))
    }

    @MainActor
    func drainMailbox(_ conversation: UncheckedHostConversationIdBox) async -> IOSMailboxDrainResult {
        IOSMailboxDrainResult(values: await value.drainMailbox(conversation.value))
    }
}

/// 会话 id(KMP KotlinUuid 非 Sendable)的同款跨边界盒。
private struct UncheckedHostConversationIdBox: @unchecked Sendable {
    let value: KotlinUuid?
    init(_ value: KotlinUuid?) { self.value = value }
}
