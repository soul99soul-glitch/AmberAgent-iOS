import Foundation
@preconcurrency import Shared

/// Freezes the run's background request and refreshes its display snapshot at transfer.
@MainActor
enum ChatRunBackgroundHandoffBuilder {
    static func displaySnapshot(
        _ source: IOSChatBackgroundHandoff?,
        messages: [UIMessage],
        baseline: [UIMessage]
    ) -> IOSChatBackgroundHandoff? {
        guard let handoff = source else { return nil }
        return IOSChatBackgroundHandoff(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: handoff.conversationId,
            providerId: handoff.providerId,
            providerSetting: handoff.providerSetting,
            params: handoff.params,
            uploadMessages: handoff.uploadMessages,
            displayMessages: IOSIntelligentUITerminal.markSourcesPending(
                messages, baseline: baseline, runID: handoff.runId
            ),
            mode: handoff.mode,
            responseId: handoff.responseId,
            responseSequenceNumber: handoff.responseSequenceNumber,
            generativeUiRequirement: handoff.generativeUiRequirement,
            generativeUiFallbackAttempted: handoff.generativeUiFallbackAttempted,
            fullToolNames: handoff.fullToolNames,
            dynamicToolSnapshot: handoff.dynamicToolSnapshot,
            executionPolicy: handoff.executionPolicy,
            subAgentTimeoutSeconds: handoff.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: handoff.phoneAutomaticReasoning,
            runDisplayBaseline: handoff.runDisplayBaseline ?? baseline
        )
    }

    static func continuingAfterResponse(
        _ source: IOSChatBackgroundHandoff, messages: [UIMessage]
    ) -> IOSChatBackgroundHandoff {
        let suffix = Array(messages.dropFirst(source.displayMessages.count))
        return IOSChatBackgroundHandoff(
            runId: source.runId, startedAt: source.startedAt, inputDigest: source.inputDigest,
            conversationId: source.conversationId, providerId: source.providerId,
            providerSetting: source.providerSetting, params: source.params,
            uploadMessages: source.uploadMessages + suffix, displayMessages: messages,
            mode: .continueModel, generativeUiRequirement: source.generativeUiRequirement,
            generativeUiFallbackAttempted: source.generativeUiFallbackAttempted,
            fullToolNames: source.fullToolNames, dynamicToolSnapshot: source.dynamicToolSnapshot,
            executionPolicy: source.executionPolicy, subAgentTimeoutSeconds: source.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: source.phoneAutomaticReasoning,
            runDisplayBaseline: source.runDisplayBaseline ?? source.displayMessages
        )
    }

    static func prepare(
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        uploadMessages: [UIMessage],
        displayMessages: [UIMessage],
        displayBaseline: [UIMessage],
        toolExposureBridge: IosToolExposureBridge?,
        dynamicSnapshot: IOSDynamicToolCatalogSnapshot?,
        executionPolicy: IOSExecutionPolicySnapshot?,
        phoneAutomaticReasoning: Bool,
        generativeUiRequirement: IOSGenerativeUiRequirement,
        generativeUiFallbackAttempted: Bool
    ) -> IOSChatBackgroundHandoff {

        let backgroundDynamicNames = Set(
            dynamicSnapshot?.backgroundEligibleDescriptors.map(\.toolId) ?? []
        )
        let backgroundVisibleTools = params.tools.filter { tool in
            !IOSDynamicToolRegistry.isDynamicWorkflowToolName(tool.name)
                || backgroundDynamicNames.contains(tool.name)
        }
        return IOSChatBackgroundHandoff(
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            providerId: providerSetting.id.toHexDashString(),
            providerSetting: providerSetting,
            params: params.replacingTools(backgroundVisibleTools),
            uploadMessages: IOSIntelligentUITerminal.markSourcesPending(
                uploadMessages, baseline: displayBaseline, runID: runId
            ),
            displayMessages: IOSIntelligentUITerminal.markSourcesPending(
                displayMessages, baseline: displayBaseline, runID: runId
            ),
            mode: .continueModel,
            generativeUiRequirement: generativeUiRequirement,
            generativeUiFallbackAttempted: generativeUiFallbackAttempted,
            fullToolNames: (toolExposureBridge?.fullToolDeclarations().map(\.name) ?? [])
                .filter {
                    !IOSDynamicToolRegistry.isDynamicWorkflowToolName($0)
                        || backgroundDynamicNames.contains($0)
                },
            dynamicToolSnapshot: dynamicSnapshot,
            executionPolicy: executionPolicy,
            phoneAutomaticReasoning: phoneAutomaticReasoning,
            runDisplayBaseline: displayBaseline
        )
    }

}
