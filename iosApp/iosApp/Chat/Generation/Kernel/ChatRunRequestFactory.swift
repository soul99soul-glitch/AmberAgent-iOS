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
    private let canClaimPhoneControl: Bool
    private let ensurePhoneControlClaimed: (@MainActor () -> Bool)?
    private let prepareUploadMessages: @MainActor ([UIMessage]) async throws -> [UIMessage]
    private let approvalDecider: @MainActor (ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision?

    init(
        bindings: ChatGenerationBindings,
        maxToolResumeCount: Int,
        executionPolicy: IOSExecutionPolicySnapshot?,
        phoneAutomaticReasoning: Bool,
        phoneControl: IOSPhoneControlController,
        canClaimPhoneControl: Bool = true,
        ensurePhoneControlClaimed: (@MainActor () -> Bool)? = nil,
        prepareUploadMessages: @escaping @MainActor ([UIMessage]) async throws -> [UIMessage],
        approvalDecider: @escaping @MainActor (ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision?
    ) {
        self.bindings = bindings
        self.maxToolResumeCount = maxToolResumeCount
        self.executionPolicy = executionPolicy
        self.phoneAutomaticReasoning = phoneAutomaticReasoning
        self.phoneControl = phoneControl
        self.canClaimPhoneControl = canClaimPhoneControl
        self.ensurePhoneControlClaimed = ensurePhoneControlClaimed
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
        let hasPhoneSurface = params.tools.contains { IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name) }
            || toolExposureBridge.fullToolDeclarations().contains { IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name) }
        let phoneUnavailableForRun = !phoneControl.enabled
            || !canClaimPhoneControl
            || (phoneControl.isOccupied && phoneControl.ownerRunID != runId)
            || phoneControl.isPreparingConnection
            || phoneControl.isUpdatingPairing
            || phoneControl.isLoadingApplications
        let effectiveParams: TextGenerationParams
        let effectiveBridge: IosToolExposureBridge
        let effectivePhoneAutomaticReasoning: Bool
        let effectiveEnsurePhoneControlClaimed: (@MainActor () -> Bool)?
        let effectivePrepareUploadMessages: @MainActor ([UIMessage]) async throws -> [UIMessage]
        if hasPhoneSurface, phoneControl.ownerRunID != runId, phoneUnavailableForRun {
            let filteredVisible = params.tools.filter { !IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name) }
            effectiveParams = params.replacingTools(filteredVisible)
            let filteredFull = toolExposureBridge.fullToolDeclarations().filter {
                !IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name)
            }
            let dynamicInfo = Dictionary(uniqueKeysWithValues: (recipeCatalogSnapshot?.recipeTools ?? []).map {
                ($0.toolId, $0.searchInfoJSON)
            })
            effectiveBridge = IosToolExposureBridge(tools: filteredFull, recipeSearchInfo: dynamicInfo)
            effectiveBridge.exposeToolNames(names: filteredVisible.map(\.name))
            effectivePhoneAutomaticReasoning = false
            effectiveEnsurePhoneControlClaimed = nil
            let reasonSummary = Self.phoneUnavailableReasonSummary(
                phoneControl: phoneControl,
                canClaimPhoneControl: canClaimPhoneControl,
                runId: runId
            )
            let basePrepareUploadMessages = prepareUploadMessages
            effectivePrepareUploadMessages = { messages in
                let prepared = try await basePrepareUploadMessages(messages)
                let notice = PromptTranscript.shared.sectionMessage(
                    name: "phoneControlUnavailable",
                    text: "[手机控制当前不可用] 本轮已移除 phone_* 手机控制工具，原因：\(reasonSummary)。请如实向用户说明当前无法操作手机及具体原因，不要承诺马上接管或继续操作手机，也不要编造手机执行进展。"
                )
                return [notice] + prepared
            }
        } else {
            effectiveParams = params
            effectiveBridge = toolExposureBridge
            effectivePhoneAutomaticReasoning = phoneAutomaticReasoning
            effectiveEnsurePhoneControlClaimed = ensurePhoneControlClaimed
            effectivePrepareUploadMessages = prepareUploadMessages
        }
        let reasoningLevels = bindings.foregroundReasoningLevels(effectiveParams.model)
        let workerReasoning = IOSSubAgentModelPool.preferredReasoning(in: reasoningLevels, fallback: effectiveParams.reasoningLevel)
        let hasActivePhoneTools = effectiveParams.tools.contains {
            IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name)
        }
        let lastAssistantHadTools =
            initialMessages.last(where: { $0.role == MessageRole.assistant })?.getTools().isEmpty == false
            || bindings.getMessages().last(where: { $0.role == MessageRole.assistant })?.getTools().isEmpty == false
        let routerReasoning: String?
        if hasActivePhoneTools || lastAssistantHadTools {
            routerReasoning = reasoningLevels.contains(.low) ? "LOW" : nil
        } else {
            routerReasoning = reasoningLevels.isEmpty || reasoningLevels.contains(.off)
                ? "OFF" : (reasoningLevels.contains(.low) ? "LOW" : nil)
        }
        return ChatRunKernelAdapter.RunRequest(
            provider: adapterProvider,
            providerSetting: providerSetting,
            params: effectiveParams,
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            initialMessages: initialMessages,
            toolExposureBridge: effectiveBridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot,
            recipeCatalogRefresh: {
                await IOSDynamicToolRegistry.shared.refresh()
            },
            executionPolicy: executionPolicy,
            phoneAutomaticReasoning: effectivePhoneAutomaticReasoning,
            phoneControl: phoneControl,
            ensurePhoneControlClaimed: effectiveEnsurePhoneControlClaimed,
            fastFirstReasoning: bindings.isForegroundRouterRun(),
            routerReasoningName: routerReasoning,
            workerReasoningName: workerReasoning.name,
            maxToolResumeCount: maxToolResumeCount,
            interjections: bindings.interjections,
            drainSteer: {
                let boxed = await bindingsBox.drainSteer(conversationBox)
                return boxed.values
            },
            mailboxDrain: {
                await bindingsBox.drainMailbox(conversationBox)
            },
            citationTracker: citationTracker,
            prepareUploadMessages: effectivePrepareUploadMessages,
            nestedToolRunner: nil,
            approvalDecider: approvalDecider
        )
    }

    private static func phoneUnavailableReasonSummary(
        phoneControl: IOSPhoneControlController,
        canClaimPhoneControl: Bool,
        runId: String
    ) -> String {
        var reasons: [String] = []
        if !phoneControl.enabled {
            reasons.append("手机控制已关闭")
        }
        if phoneControl.isOccupied && phoneControl.ownerRunID != runId {
            reasons.append("另一任务正在占用控制权")
        } else if !canClaimPhoneControl {
            reasons.append("当前任务未获得手机控制权")
        }
        if phoneControl.isPreparingConnection || phoneControl.isUpdatingPairing {
            reasons.append("正在准备连接或更新配对")
        }
        if phoneControl.isLoadingApplications {
            reasons.append("正在加载应用列表")
        }
        return reasons.isEmpty ? "手机控制暂不可用" : reasons.joined(separator: "；")
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
