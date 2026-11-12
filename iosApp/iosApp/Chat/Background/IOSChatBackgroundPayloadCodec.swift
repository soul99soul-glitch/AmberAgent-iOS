@preconcurrency import BackgroundTasks
import CryptoKit
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    private static let inlineBlobScheme = "amber-bg-inline-blob://"
    private static let inlineBlobMinUTF8Bytes = 4_096

    func persist(handoff: IOSChatBackgroundHandoff, requestId: String) throws {
#if DEBUG
        if let override = persistHandoffOverrideForTesting { try override(handoff, requestId); return }
#endif
        let directory = try jobsDirectory()
        let sanitizedId = IOSChatBackgroundJobFileNaming.sanitized(requestId)
        let blobsDir = blobsDirectoryURL(forSanitizedId: sanitizedId, in: directory)
        let prepared = try InlineBlobMemo.shared.externalizeHandoffMessages(
            sanitizedRequestId: sanitizedId,
            blobsDirectory: blobsDir,
            uploadMessages: handoff.uploadMessages,
            displayMessages: handoff.displayMessages,
            runDisplayBaseline: handoff.runDisplayBaseline
        )
        let json = IosChatBackgroundPayloadJsonBridge.shared.encode(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: handoff.conversationId,
            providerSetting: handoff.providerSetting,
            params: handoff.params,
            uploadMessages: prepared.uploadMessages,
            displayMessages: prepared.displayMessages,
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
            runDisplayBaseline: prepared.runDisplayBaseline
        )
        let url = payloadURL(forSanitizedId: sanitizedId, in: directory)
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
            canClaimPhoneControl: job.canClaimPhoneControl,
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
            let directory = try jobsDirectory()
            let sanitizedId = IOSChatBackgroundJobFileNaming.sanitized(requestId)
            let url = payloadURL(forSanitizedId: sanitizedId, in: directory)
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
            let blobsDir = blobsDirectoryURL(forSanitizedId: sanitizedId, in: directory)
            var rehydratedImages: [String: UIMessagePart.Image] = [:]
            let uploadMessages = try Self.rehydrateInlineBlobs(
                in: payload.uploadMessages,
                blobsDirectory: blobsDir,
                cache: &rehydratedImages
            )
            let displayMessages = try Self.rehydrateInlineBlobs(
                in: payload.displayMessages,
                blobsDirectory: blobsDir,
                cache: &rehydratedImages
            )
            let runDisplayBaseline = try payload.runDisplayBaseline.map {
                try Self.rehydrateInlineBlobs(
                    in: $0,
                    blobsDirectory: blobsDir,
                    cache: &rehydratedImages
                )
            }
            return IOSChatBackgroundHandoff(
                runId: payload.runId,
                startedAt: payload.startedAt,
                inputDigest: payload.inputDigest,
                conversationId: payload.conversationId,
                providerId: payload.providerId,
                providerSetting: providerSetting,
                params: params,
                uploadMessages: uploadMessages,
                displayMessages: displayMessages,
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
                runDisplayBaseline: runDisplayBaseline
            )
        } catch {
            NSLog("[AmberChatBG] Failed to load background payload \(requestId): \(error)")
            return nil
        }
    }

    func removePayload(requestId: String) {
        let sanitizedId = IOSChatBackgroundJobFileNaming.sanitized(requestId)
        InlineBlobMemo.shared.evict(sanitizedRequestId: sanitizedId)
        do {
            let directory = try jobsDirectory()
            try? FileManager.default.removeItem(at: payloadURL(forSanitizedId: sanitizedId, in: directory))
            try? FileManager.default.removeItem(at: blobsDirectoryURL(forSanitizedId: sanitizedId, in: directory))
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

    private func payloadURL(forSanitizedId sanitizedId: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(sanitizedId)
            .appendingPathExtension("json")
    }

    private func blobsDirectoryURL(forSanitizedId sanitizedId: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent("\(sanitizedId).blobs", isDirectory: true)
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

    static func rehydratedVisibleTools(
        names: [String],
        legacyTools: [Tool],
        additionalDeclarations: [Tool]
    ) -> [Tool] {
        guard !names.isEmpty else { return legacyTools }
        let declarations = ToolKt.iosToolDeclarations(names: names)
            + IOSWakeToolCatalog.declarations.filter { names.contains($0.name) }
            + IOSShortcutAuthoringToolCatalog.declarations.filter { names.contains($0.name) }
            + AgentSoulToolDeclarationsKt.createAgentSoulToolDeclarations().filter { names.contains($0.name) }
            + additionalDeclarations
        let byName = Dictionary(declarations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { byName[$0] }
    }

    private enum InlineBlobError: Error {
        case invalidDigest
        case corruptedBlob
    }

    private static func rehydrateInlineBlobs(
        in messages: [UIMessage],
        blobsDirectory: URL,
        cache: inout [String: UIMessagePart.Image]
    ) throws -> [UIMessage] {
        var anyMessageChanged = false
        var output: [UIMessage] = []
        output.reserveCapacity(messages.count)
        for message in messages {
            let transformed = try rehydrateParts(
                message.parts,
                blobsDirectory: blobsDirectory,
                cache: &cache
            )
            if transformed.changed {
                anyMessageChanged = true
                output.append(UIMessage(
                    id: message.id,
                    role: message.role,
                    parts: transformed.parts,
                    annotations: message.annotations,
                    createdAt: message.createdAt,
                    finishedAt: message.finishedAt,
                    modelId: message.modelId,
                    usage: message.usage,
                    translation: message.translation
                ))
            } else {
                output.append(message)
            }
        }
        return anyMessageChanged ? output : messages
    }

    private static func rehydrateParts(
        _ parts: [UIMessagePart],
        blobsDirectory: URL,
        cache: inout [String: UIMessagePart.Image]
    ) throws -> (parts: [UIMessagePart], changed: Bool) {
        var changed = false
        var output: [UIMessagePart] = []
        output.reserveCapacity(parts.count)
        for part in parts {
            if let image = part as? UIMessagePart.Image,
               image.url.hasPrefix(inlineBlobScheme) {
                let digest = String(image.url.dropFirst(inlineBlobScheme.count))
                guard isValidSha256Hex(digest) else {
                    throw InlineBlobError.invalidDigest
                }
                let restored: UIMessagePart.Image
                if let hit = cache[digest] {
                    restored = hit
                } else {
                    let blobURL = blobsDirectory.appendingPathComponent("\(digest).dat", isDirectory: false)
                    let data = try Data(contentsOf: blobURL)
                    guard let restoredURL = String(data: data, encoding: .utf8),
                          restoredURL.hasPrefix("data:") else {
                        throw InlineBlobError.corruptedBlob
                    }
                    restored = UIMessagePart.Image(url: restoredURL, metadata: nil)
                    cache[digest] = restored
                }
                changed = true
                output.append(restored)
            } else if let tool = part as? UIMessagePart.Tool {
                let sub = try rehydrateParts(
                    tool.output,
                    blobsDirectory: blobsDirectory,
                    cache: &cache
                )
                if sub.changed {
                    changed = true
                    output.append(PromptTranscript.shared.doCopyTool(
                        tool: tool,
                        input: tool.input,
                        output: sub.parts
                    ))
                } else {
                    output.append(tool)
                }
            } else {
                output.append(part)
            }
        }
        return (changed ? output : parts, changed)
    }

    private static func isValidSha256Hex(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        for byte in value.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLowerHex = byte >= 0x61 && byte <= 0x66
            if !isDigit && !isLowerHex { return false }
        }
        return true
    }

    @MainActor
    private final class InlineBlobMemo {
        static let shared = InlineBlobMemo()

        struct PreparedHandoffMessages {
            let uploadMessages: [UIMessage]
            let displayMessages: [UIMessage]
            let runDisplayBaseline: [UIMessage]?
        }

        private final class CachedImageEntry: NSObject {
            let digest: String?
            let placeholder: UIMessagePart.Image
            init(digest: String?, placeholder: UIMessagePart.Image) {
                self.digest = digest
                self.placeholder = placeholder
            }
        }

        private final class CachedMessageEntry: NSObject {
            let externalizedMessage: UIMessage
            let blobs: [(digest: String, sourceImage: UIMessagePart.Image)]
            init(
                externalizedMessage: UIMessage,
                blobs: [(digest: String, sourceImage: UIMessagePart.Image)]
            ) {
                self.externalizedMessage = externalizedMessage
                self.blobs = blobs
            }
        }

        private let imageTable = NSMapTable<UIMessagePart.Image, CachedImageEntry>(
            keyOptions: [.weakMemory, .objectPointerPersonality],
            valueOptions: .strongMemory
        )
        private let messageTable = NSMapTable<UIMessage, CachedMessageEntry>(
            keyOptions: [.weakMemory, .objectPointerPersonality],
            valueOptions: .strongMemory
        )
        private var writtenDigestsByRequest: [String: Set<String>] = [:]

        func evict(sanitizedRequestId: String) {
            writtenDigestsByRequest.removeValue(forKey: sanitizedRequestId)
        }

        func externalizeHandoffMessages(
            sanitizedRequestId: String,
            blobsDirectory: URL,
            uploadMessages: [UIMessage],
            displayMessages: [UIMessage],
            runDisplayBaseline: [UIMessage]?
        ) throws -> PreparedHandoffMessages {
            var blobsDirExists = FileManager.default.fileExists(atPath: blobsDirectory.path)
            if !blobsDirExists {
                writtenDigestsByRequest.removeValue(forKey: sanitizedRequestId)
            }

            func ensureBlobWritten(digest: String, sourceImage: UIMessagePart.Image) throws {
                if writtenDigestsByRequest[sanitizedRequestId]?.contains(digest) == true {
                    return
                }
                if !blobsDirExists {
                    try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
                    blobsDirExists = true
                }
                let fileURL = blobsDirectory.appendingPathComponent("\(digest).dat", isDirectory: false)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data(sourceImage.url.utf8).write(to: fileURL, options: [.atomic])
                }
                if writtenDigestsByRequest.count >= 64, writtenDigestsByRequest[sanitizedRequestId] == nil {
                    writtenDigestsByRequest.removeAll(keepingCapacity: true)
                }
                writtenDigestsByRequest[sanitizedRequestId, default: []].insert(digest)
            }

            func transformList(_ messages: [UIMessage]) throws -> [UIMessage] {
                var anyChanged = false
                var out: [UIMessage] = []
                out.reserveCapacity(messages.count)
                for message in messages {
                    if let hit = messageTable.object(forKey: message) {
                        for blob in hit.blobs {
                            try ensureBlobWritten(digest: blob.digest, sourceImage: blob.sourceImage)
                        }
                        if hit.externalizedMessage !== message { anyChanged = true }
                        out.append(hit.externalizedMessage)
                        continue
                    }
                    let transformed = try transformParts(
                        message.parts,
                        ensureBlobWritten: ensureBlobWritten
                    )
                    let externalized: UIMessage
                    if transformed.changed {
                        anyChanged = true
                        externalized = UIMessage(
                            id: message.id,
                            role: message.role,
                            parts: transformed.parts,
                            annotations: message.annotations,
                            createdAt: message.createdAt,
                            finishedAt: message.finishedAt,
                            modelId: message.modelId,
                            usage: message.usage,
                            translation: message.translation
                        )
                    } else {
                        externalized = message
                    }
                    messageTable.setObject(
                        CachedMessageEntry(externalizedMessage: externalized, blobs: transformed.blobs),
                        forKey: message
                    )
                    out.append(externalized)
                }
                return anyChanged ? out : messages
            }

            let preparedUpload = try transformList(uploadMessages)
            let preparedDisplay = try transformList(displayMessages)
            let preparedBaseline = try runDisplayBaseline.map(transformList)
            return PreparedHandoffMessages(
                uploadMessages: preparedUpload,
                displayMessages: preparedDisplay,
                runDisplayBaseline: preparedBaseline
            )
        }

        private func transformParts(
            _ parts: [UIMessagePart],
            ensureBlobWritten: (String, UIMessagePart.Image) throws -> Void
        ) throws -> (
            parts: [UIMessagePart],
            changed: Bool,
            blobs: [(digest: String, sourceImage: UIMessagePart.Image)]
        ) {
            var changed = false
            var out: [UIMessagePart] = []
            out.reserveCapacity(parts.count)
            var blobs: [(digest: String, sourceImage: UIMessagePart.Image)] = []
            for part in parts {
                if let image = part as? UIMessagePart.Image {
                    let entry = imageEntry(for: image)
                    if let digest = entry.digest {
                        try ensureBlobWritten(digest, image)
                        blobs.append((digest: digest, sourceImage: image))
                        changed = true
                        out.append(entry.placeholder)
                    } else {
                        out.append(image)
                    }
                } else if let tool = part as? UIMessagePart.Tool {
                    let sub = try transformParts(tool.output, ensureBlobWritten: ensureBlobWritten)
                    if sub.changed {
                        changed = true
                        blobs.append(contentsOf: sub.blobs)
                        out.append(PromptTranscript.shared.doCopyTool(
                            tool: tool,
                            input: tool.input,
                            output: sub.parts
                        ))
                    } else {
                        out.append(tool)
                    }
                } else {
                    out.append(part)
                }
            }
            return (changed ? out : parts, changed, blobs)
        }

        private func imageEntry(for image: UIMessagePart.Image) -> CachedImageEntry {
            if let hit = imageTable.object(forKey: image) {
                return hit
            }
            let entry: CachedImageEntry
            if image.metadata == nil && !image.isMissingBlobPlaceholder() {
                let url = image.url
                if url.hasPrefix("data:"), url.utf8.count >= IOSChatBackgroundGenerationCoordinator.inlineBlobMinUTF8Bytes {
                    let digest = Self.sha256Hex(of: url)
                    let placeholder = UIMessagePart.Image(
                        url: "\(IOSChatBackgroundGenerationCoordinator.inlineBlobScheme)\(digest)",
                        metadata: nil
                    )
                    entry = CachedImageEntry(digest: digest, placeholder: placeholder)
                } else {
                    entry = CachedImageEntry(digest: nil, placeholder: image)
                }
            } else {
                entry = CachedImageEntry(digest: nil, placeholder: image)
            }
            imageTable.setObject(entry, forKey: image)
            return entry
        }

        private static func sha256Hex(of string: String) -> String {
            let digest: SHA256Digest = string.utf8.withContiguousStorageIfAvailable { buffer in
                SHA256.hash(data: buffer)
            } ?? SHA256.hash(data: Data(string.utf8))
            var hex = ""
            hex.reserveCapacity(64)
            let hexChars: [Character] = Array("0123456789abcdef")
            for byte in digest {
                hex.append(hexChars[Int(byte >> 4)])
                hex.append(hexChars[Int(byte & 0x0F)])
            }
            return hex
        }
    }

}
