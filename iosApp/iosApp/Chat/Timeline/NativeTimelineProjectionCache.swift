import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

@MainActor
final class NativeTimelineProjectionCache {
    private var cachedProjection: NativeTimelineProjection?
    private var structuralKey = ""
    private var messageCount = 0
    private var lastMessageID: String?
    private var sourceRevision: Int?
    private var renderRevision: UInt64 = 0
    private var startIndex = 0
    private var sourceMessages: [UIMessage] = []
    private var contentIdentities: [String: ChatMessageContentIdentity] = [:]
    private var compactBoundaries: [ChatContextCompactBoundary] = []

    func projection(
        messages: [UIMessage],
        event: ChatEvent,
        sourceRevision: Int,
        startIndex: Int,
        configurationIssue: ChatConfigurationIssue?,
        isGenerationActive: Bool,
        isLoading: Bool,
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState,
        contextCompactBoundaries: [ChatContextCompactBoundary],
        viewportState: ChatViewportState,
        displaySettingSignature: String,
        generativeUiSettingSignature: String,
        renderStateRevision: UInt64,
        reasoningLevelLabel: String?,
        streamedMessageIDs: Set<String>,
        renderStateStore: ChatRenderStateStore,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?,
        expandedPhoneToolGroupIDs: Set<String> = [],
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int
    ) -> NativeTimelineProjection {
        let lastID = messages.last.map(ChatMessageProjector.messageId(for:))
        let key = Self.structuralKey(
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs,
            configurationIssue: configurationIssue,
            isGenerationActive: isGenerationActive,
            isLoading: isLoading,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState,
            contextCompactBoundaries: contextCompactBoundaries,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: generativeUiSettingSignature,
            reasoningLevelLabel: reasoningLevelLabel
        )

        let canReuseStructure = key == structuralKey &&
            messageCount == messages.count && lastMessageID == lastID &&
            self.startIndex == startIndex && compactBoundaries == contextCompactBoundaries
        defer {
            self.sourceRevision = sourceRevision
            self.renderRevision = renderStateRevision
            self.startIndex = startIndex
            self.sourceMessages = messages
            self.compactBoundaries = contextCompactBoundaries
        }
        if canReuseStructure,
           self.sourceRevision == sourceRevision,
           renderRevision == renderStateRevision,
           let cachedProjection {
            return cachedProjection
        }

        if canReuseStructure,
           event == .assistantStreamDelta,
           let cachedProjection,
           streamingHistoryIsUnchanged(messages: messages, startIndex: startIndex, projection: cachedProjection),
           let increment = NativeTimelineProjector.replacingStreamingTail(
            in: cachedProjection,
            messages: messages,
            event: event,
            isGenerationActive: isGenerationActive,
            viewportState: viewportState,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: generativeUiSettingSignature,
            renderStateRevision: renderStateRevision,
            reasoningLevelLabel: reasoningLevelLabel,
            streamedMessageIDs: streamedMessageIDs,
            renderStateStore: renderStateStore,
            variantInfoProvider: variantInfoProvider,
            contentHashProvider: contentHashProvider,
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs
           ) {
            self.cachedProjection = increment
            if let last = increment.entries.last(where: { $0.kind == .message }),
               let message = last.message, let id = last.messageId {
                contentIdentities[id] = ChatMessageContentIdentity(message, index: last.index)
            }
            return increment
        }

        // Tool callbacks may replace any assistant message, including a historical
        // one. Reuse only after checking the complete source shape and the loaded
        // rows' mutable metadata; never assume that a tool result belongs to the tail.
        if canReuseStructure, renderRevision == renderStateRevision,
           sourceMessages.count == messages.count,
           zip(sourceMessages, messages).allSatisfy({ old, new in
               old === new || (old.id == new.id && old.role == MessageRole.assistant && new.role == old.role)
           }),
           let cachedProjection,
           let increment = NativeTimelineProjector.replacingToolMessages(
               in: cachedProjection, messages: messages, event: event, startIndex: startIndex,
               unchangedMessageIDs: Set(contentIdentities.compactMap { id, snapshot in
                   guard let index = snapshot.index, messages.indices.contains(index),
                         snapshot.matches(messages[index]) else { return nil }
                   return id
               }),
               isGenerationActive: isGenerationActive, viewportState: viewportState,
               displaySettingSignature: displaySettingSignature,
               generativeUiSettingSignature: generativeUiSettingSignature,
               renderStateRevision: renderStateRevision, reasoningLevelLabel: reasoningLevelLabel,
               streamedMessageIDs: streamedMessageIDs, renderStateStore: renderStateStore,
               variantInfoProvider: variantInfoProvider, contentHashProvider: contentHashProvider,
               expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs
           ) {
            self.cachedProjection = increment
            rememberContentIdentities(in: increment)
            return increment
        }

        let projection = NativeTimelineProjector.build(
            messages: messages,
            event: event,
            configurationIssue: configurationIssue,
            isGenerationActive: isGenerationActive,
            isLoading: isLoading,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState,
            contextCompactBoundaries: contextCompactBoundaries,
            viewportState: viewportState,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: generativeUiSettingSignature,
            renderStateRevision: renderStateRevision,
            reasoningLevelLabel: reasoningLevelLabel,
            streamedMessageIDs: streamedMessageIDs,
            renderStateStore: renderStateStore,
            variantInfoProvider: variantInfoProvider,
            contentHashProvider: contentHashProvider,
            startIndex: startIndex,
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs
        )
        cachedProjection = projection
        structuralKey = key
        messageCount = messages.count
        lastMessageID = lastID
        rememberContentIdentities(in: projection)
        return projection
    }

    private func rememberContentIdentities(in projection: NativeTimelineProjection) {
        contentIdentities = Dictionary(uniqueKeysWithValues: projection.entries.compactMap { entry in
            guard let message = entry.message, let id = entry.messageId else { return nil }
            return (id, ChatMessageContentIdentity(message, index: entry.index))
        })
    }

    private func streamingHistoryIsUnchanged(
        messages: [UIMessage], startIndex: Int, projection: NativeTimelineProjection
    ) -> Bool {
        // SwiftUI can coalesce tool-result and text-delta notifications into one
        // render. A final stream event does not prove that only the tail changed.
        guard sourceMessages.count == messages.count,
              sourceMessages.dropLast().elementsEqual(messages.dropLast(), by: { $0 === $1 }) else { return false }
        let visibleIndices = messages.indices.dropFirst(max(0, startIndex)).filter {
            ChatMessageProjector.isVisibleInTimeline(messages[$0])
        }
        guard visibleIndices == projection.entries.compactMap(\.index) else { return false }
        return projection.entries.allSatisfy { entry in
            guard let index = entry.index, let id = entry.messageId, index != messages.count - 1 else { return true }
            return contentIdentities[id]?.matches(messages[index]) == true &&
                entry.isAssistantContinuation == ChatMessageProjector.isAssistantContinuation(at: index, in: messages)
        }
    }

    /// Tool-call anchors hidden inside collapsed phone-step groups, mapped to the
    /// group id that must expand before the anchor exists. On demand (anchor
    /// requests only).
    func collapsedPhoneToolGroupIDsByAnchor() -> [String: String] {
        guard let entries = cachedProjection?.entries else { return [:] }
        var groupIDs: [String: String] = [:]
        for entry in entries {
            guard let role = entry.phoneToolGroup, let message = entry.message,
                  let messageID = entry.messageId else { continue }
            let isExpanded: Bool
            switch role {
            case let .head(summary): isExpanded = summary.isExpanded
            case let .member(_, expanded): isExpanded = expanded
            }
            guard !isExpanded else { continue }
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool,
                      ChatPhoneToolGrouping.isPhoneTool(tool.toolName) else { continue }
                groupIDs[ChatToolCallAnchorTarget.id(messageID: messageID, toolCallID: tool.toolCallId)] = role.groupID
            }
        }
        return groupIDs
    }

    func reset() {
        cachedProjection = nil
        structuralKey = ""
        messageCount = 0
        lastMessageID = nil
        sourceRevision = nil
        sourceMessages = []
        contentIdentities.removeAll()
        compactBoundaries = []
    }

    private static func structuralKey(
        expandedPhoneToolGroupIDs: Set<String>,
        configurationIssue: ChatConfigurationIssue?,
        isGenerationActive: Bool,
        isLoading: Bool,
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState,
        contextCompactBoundaries: [ChatContextCompactBoundary],
        displaySettingSignature: String,
        generativeUiSettingSignature: String,
        reasoningLevelLabel: String?
    ) -> String {
        [
            configurationIssue.map { "\($0.title)|\($0.message)" } ?? "no-issue",
            "generation=\(isGenerationActive)",
            "loading=\(isLoading)",
            "vision=\(isRecognizingImages)",
            "context=\(String(describing: contextCompactState.status)):\(contextCompactState.updatedAt.timeIntervalSince1970):\(contextCompactState.summary)",
            "boundaries=\(contextCompactBoundaries.map { $0.id + "@" + $0.afterMessageId }.joined(separator: ","))",
            "display=\(displaySettingSignature)",
            "generative=\(generativeUiSettingSignature)",
            "reasoning=\(reasoningLevelLabel ?? "")",
            // Expanding/collapsing a phone-step group legitimately changes row content once.
            "phoneGroups=\(expandedPhoneToolGroupIDs.sorted().joined(separator: ","))"
        ].joined(separator: "||")
    }
}

