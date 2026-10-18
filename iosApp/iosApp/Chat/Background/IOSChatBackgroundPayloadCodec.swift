@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    func persist(handoff: IOSChatBackgroundHandoff, requestId: String) throws {
#if DEBUG
        if let override = persistHandoffOverrideForTesting { try override(handoff, requestId); return }
#endif
        let json = IosChatBackgroundPayloadJsonBridge.shared.encode(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: handoff.conversationId,
            providerSetting: handoff.providerSetting,
            params: handoff.params,
            uploadMessages: handoff.uploadMessages,
            displayMessages: handoff.displayMessages,
            mode: handoff.mode.rawValue,
            responseId: handoff.responseId,
            responseSequenceNumber: handoff.responseSequenceNumber.map { KotlinLong(value: $0) },
            generativeUiRequired: handoff.generativeUiRequirement.required,
            generativeUiExpectSlides: handoff.generativeUiRequirement.expectSlides,
            generativeUiExpectFullHtmlDeck: handoff.generativeUiRequirement.expectFullHtmlDeck,
            generativeUiFallbackAttempted: handoff.generativeUiFallbackAttempted,
            fullToolNames: handoff.fullToolNames,
            executionPolicyJson: handoff.executionPolicy?.encodedJSON,
            subAgentTimeoutSeconds: handoff.subAgentTimeoutSeconds.map { KotlinDouble(value: $0) },
            runDisplayBaseline: handoff.runDisplayBaseline
        )
        let directory = try jobsDirectory()
        let url = payloadURL(for: requestId, in: directory)
        try Data(json.utf8).write(to: url, options: [.atomic])
    }

    func persistGenerativeUiRetryCheckpoint(
        for job: IOSChatBackgroundRuntimeJob,
        requestId: String,
        uploadMessages: [UIMessage],
        displayMessages: [UIMessage],
        params: TextGenerationParams
    ) -> Bool {
        let handoff = IOSChatBackgroundHandoff(
            runId: job.runId,
            startedAt: job.startedAt,
            inputDigest: job.inputDigest,
            conversationId: job.conversationId,
            providerId: job.providerSetting.id.toHexDashString(),
            providerSetting: job.providerSetting,
            params: params,
            uploadMessages: uploadMessages,
            displayMessages: displayMessages,
            mode: job.mode,
            generativeUiRequirement: job.generativeUiRequirement,
            generativeUiFallbackAttempted: true,
            fullToolNames: job.toolExposureBridge.fullToolDeclarations().map(\.name),
            dynamicToolSnapshot: job.dynamicToolSnapshot,
            executionPolicy: job.executionPolicy,
            subAgentTimeoutSeconds: job.subAgentTimeoutSeconds,
            phoneAutomaticReasoning: job.phoneAutomaticReasoning,
            runDisplayBaseline: job.runDisplayBaseline
        )
        do {
            try persist(handoff: handoff, requestId: requestId)
            return true
        } catch {
            NSLog("[AmberChatBG] Failed to persist generative UI retry checkpoint: \(error)")
            return false
        }
    }

    func loadHandoff(requestId: String) -> IOSChatBackgroundHandoff? {
        do {
            let url = payloadURL(for: requestId, in: try jobsDirectory())
            let data = try Data(contentsOf: url)
            guard let json = String(data: data, encoding: .utf8) else { return nil }
            let payload = try IosChatBackgroundPayloadJsonBridge.shared.decode(json: json)
            guard let providerSetting = providerSetting(for: payload.providerId) else {
                NSLog("[AmberChatBG] Missing background provider \(payload.providerId) for \(requestId)")
                return nil
            }
            guard let dependencies,
                  let persistedParams = Self.rehydratedParams(
                    persistedParams: payload.params,
                    providerSetting: providerSetting,
                    assistantHeaders: dependencies.sharedSettings.snapshot.getCurrentAssistant().customHeaders,
                    assistantBodies: dependencies.sharedSettings.snapshot.getCurrentAssistant().customBodies,
                    conversationId: payload.conversationId.toHexDashString()
                  ) else {
                NSLog("[AmberChatBG] Missing current background model for \(requestId)")
                return nil
            }
            let visibleTools = Self.rehydratedVisibleTools(
                names: payload.visibleToolNames,
                legacyTools: payload.params.tools,
                additionalDeclarations: dependencies.toolRuntime.mcpExpandedDeclarations()
            )
            let params = persistedParams.replacingTools(visibleTools)
            let executionPolicy: IOSExecutionPolicySnapshot?
            if let policyJSON = payload.executionPolicyJson {
                guard let decodedPolicy = IOSExecutionPolicySnapshot.decode(json: policyJSON) else {
                    NSLog("[AmberChatBG] Invalid execution policy for \(requestId)")
                    return nil
                }
                executionPolicy = decodedPolicy
            } else {
                executionPolicy = nil
            }
            guard let mode = Self.rehydratedMode(payload.mode) else {
                NSLog("[AmberChatBG] Invalid background mode \(payload.mode) for \(requestId)")
                return nil
            }
            return IOSChatBackgroundHandoff(
                runId: payload.runId,
                startedAt: payload.startedAt,
                inputDigest: payload.inputDigest,
                conversationId: payload.conversationId,
                providerId: payload.providerId,
                providerSetting: providerSetting,
                params: params,
                uploadMessages: payload.uploadMessages,
                displayMessages: payload.displayMessages,
                mode: mode,
                responseId: payload.responseId,
                responseSequenceNumber: payload.responseSequenceNumber?.int64Value,
                generativeUiRequirement: IOSGenerativeUiRequirement(
                    required: payload.generativeUiRequired,
                    expectSlides: payload.generativeUiExpectSlides,
                    expectFullHtmlDeck: payload.generativeUiExpectFullHtmlDeck
                ),
                generativeUiFallbackAttempted: payload.generativeUiFallbackAttempted,
                fullToolNames: payload.fullToolNames,
                dynamicToolSnapshot: nil,
                executionPolicy: executionPolicy,
                subAgentTimeoutSeconds: payload.subAgentTimeoutSeconds?.doubleValue,
                runDisplayBaseline: payload.runDisplayBaseline
            )
        } catch {
            NSLog("[AmberChatBG] Failed to load background payload \(requestId): \(error)")
            return nil
        }
    }

    func removePayload(requestId: String) {
        do {
            let url = payloadURL(for: requestId, in: try jobsDirectory())
            try? FileManager.default.removeItem(at: url)
        } catch {
            NSLog("[AmberChatBG] Failed to resolve payload URL for cleanup: \(error)")
        }
    }

    /// Persisted values are untrusted after a crash or version change. An
    /// unknown mode must not widen into a model/tool continuation.
    static func rehydratedMode(_ rawValue: String) -> IOSChatBackgroundHandoffMode? {
        IOSChatBackgroundHandoffMode(rawValue: rawValue)
    }

    private func jobsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("ChatBackgroundJobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func payloadURL(for requestId: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(IOSChatBackgroundJobFileNaming.sanitized(requestId))
            .appendingPathExtension("json")
    }

    static func rehydratedParams(
        persistedParams: TextGenerationParams,
        providerSetting: ProviderSetting,
        assistantHeaders: [CustomHeader],
        assistantBodies: [CustomBody],
        conversationId: String? = nil
    ) -> TextGenerationParams? {
        let persistedModel = persistedParams.model
        let configuredModel = providerSetting.models.first { candidate in
            candidate.id == persistedModel.id
                || (candidate.type == persistedModel.type && candidate.modelId == persistedModel.modelId)
        }
        guard let configuredModel else { return nil }

        let runtimeHeaders = ChatProviderConfiguration.requestHeaders(
            for: providerSetting,
            assistant: assistantHeaders,
            model: configuredModel.customHeaders,
            conversationId: conversationId
        )
        let runtimeBodies = assistantBodies + configuredModel.customBodies
        let runtimeModel = Model(
            modelId: configuredModel.modelId,
            displayName: configuredModel.displayName,
            id: configuredModel.id,
            type: configuredModel.type,
            customHeaders: configuredModel.customHeaders,
            customBodies: configuredModel.customBodies,
            inputModalities: configuredModel.inputModalities,
            outputModalities: configuredModel.outputModalities,
            abilities: configuredModel.abilities,
            tools: configuredModel.tools,
            contextWindowTokens: configuredModel.contextWindowTokens,
            providerOverwrite: configuredModel.providerOverwrite
        )
        return TextGenerationParams(
            model: runtimeModel,
            temperature: persistedParams.temperature,
            topP: persistedParams.topP,
            maxTokens: persistedParams.maxTokens,
            tools: persistedParams.tools,
            reasoningLevel: persistedParams.reasoningLevel,
            customHeaders: runtimeHeaders,
            customBody: runtimeBodies
        )
    }

    private static func rehydratedVisibleTools(
        names: [String],
        legacyTools: [Tool],
        additionalDeclarations: [Tool]
    ) -> [Tool] {
        guard !names.isEmpty else { return legacyTools }
        let declarations = ToolKt.iosToolDeclarations(names: names) + additionalDeclarations
        let byName = Dictionary(declarations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { byName[$0] }
    }

}
