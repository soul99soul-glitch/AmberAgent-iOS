import Foundation
import Shared

enum NativeTimelineEntryKind: Equatable {
    case emptyState
    case configurationIssue(compact: Bool)
    case message
    case pendingAssistant
    case visionRecognition
    case contextMarker
    case bottomAnchor
}

/// Shared, renderer-agnostic timeline projection for the future Native chat
/// timeline. This intentionally mirrors `ChatTimelinePlan` instead of inventing
/// a second message model, so the Native path starts from the same identity,
/// streaming-memory, pending-assistant, and bottom-anchor semantics as the
/// current SwiftUI/UICollectionView paths.
struct NativeTimelineEntry: Identifiable, Equatable {
    let id: String
    let kind: NativeTimelineEntryKind
    let messageId: String?
    let message: UIMessage?
    let role: MessageRole?
    let index: Int?
    let isLastMessage: Bool
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let canAnimateInsertion: Bool
    let renderer: ChatTimelineRendererKind?
    let renderToken: String
    let variantInfo: NativeTimelineVariantInfo?
    let renderState: ChatRenderState?
    /// Base row digest, with the phone-group role folded in by `ChatPhoneToolGrouping`.
    var renderDigest: ChatRowDigest?

    var isAssistantContinuation: Bool = false
    var isCompactedHistory: Bool = false
    var compactState: ChatContextCompactState? = nil
    /// Phone automation step group this message belongs to (L1 projection).
    var phoneToolGroup: ChatPhoneToolGroupRole? = nil
    /// Digest before the group role was folded in; lets regrouping stay idempotent.
    var baseRenderDigest: ChatRowDigest? = nil

    var hasMultipleVariants: Bool {
        variantInfo?.hasMultipleVariants == true
    }

    var renderHasEverStreamed: Bool {
        renderState?.hasEverStreamed ?? hasEverStreamed
    }

    var liveMarkdownRenderingEnabled: Bool {
        renderState?.liveRenderingEnabled ?? true
    }

    var frozenMarkdownSnapshot: String? {
        renderState?.frozenMarkdownSnapshot
    }
}

struct NativeTimelineProjection: Equatable {
    let entries: [NativeTimelineEntry]
    let latestRenderToken: String

    func messageEntry(for messageId: String) -> NativeTimelineEntry? {
        entries.first { $0.messageId == messageId }
    }
}

struct NativeTimelineVariantInfo: Equatable {
    let variantCount: Int
    let selectedIndex: Int

    var hasMultipleVariants: Bool {
        variantCount > 1
    }
}

enum NativeTimelineProjector {
    static func build(
        messages: [UIMessage],
        event: ChatEvent,
        configurationIssue: ChatConfigurationIssue? = nil,
        isGenerationActive: Bool = false,
        isLoading: Bool = false,
        isRecognizingImages: Bool = false,
        contextCompactState: ChatContextCompactState = .idle,
        contextCompactBoundaries: [ChatContextCompactBoundary] = [],
        viewportState: ChatViewportState = ChatViewportState(),
        displaySettingSignature: String = "",
        generativeUiSettingSignature: String = "",
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        streamedMessageIDs: Set<String> = [],
        renderStateStore: ChatRenderStateStore? = nil,
        includePendingAssistant: Bool? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        startIndex: Int = 0,
        expandedPhoneToolGroupIDs: Set<String> = []
    ) -> NativeTimelineProjection {
        // Standard Chat already owns waiting/thinking/search status in the top island.
        // Keep the timeline for real message content so completion never removes a
        // duplicate status row after the final text has settled.
        let shouldIncludePendingAssistant = includePendingAssistant ?? false
        let plan = ChatTimelinePlanner.build(
            messages: messages,
            event: event,
            streamedMessageIDs: streamedMessageIDs,
            includePendingAssistant: shouldIncludePendingAssistant,
            startIndex: startIndex
        )

        var entries: [NativeTimelineEntry] = []
        if messages.isEmpty {
            if let configurationIssue {
                entries.append(
                    decorationEntry(
                        id: "configuration-issue-empty",
                        kind: .configurationIssue(compact: false),
                        renderToken: "configuration-empty-\(configurationIssue.title)-\(configurationIssue.message)"
                    )
                )
            } else {
                entries.append(decorationEntry(id: "empty-state", kind: .emptyState, renderToken: "empty"))
            }
            entries.append(nativeEntry(for: .bottomAnchor(id: ChatTimelinePlanner.bottomAnchorID)))
            return NativeTimelineProjection(entries: entries, latestRenderToken: plan.latestRenderToken)
        }

        if let configurationIssue {
            entries.append(
                decorationEntry(
                    id: "configuration-issue-compact",
                    kind: .configurationIssue(compact: true),
                    renderToken: "configuration-compact-\(configurationIssue.title)-\(configurationIssue.message)"
                )
            )
        }

        // Most conversations have no compaction markers. Keep their initial
        // projection proportional to the loaded history window, without bridging
        // every message ID just to validate an empty set of boundaries.
        let boundaries: [ChatContextCompactBoundary]
        if contextCompactBoundaries.isEmpty {
            boundaries = []
        } else {
            let existingIds = Set(messages.map(ChatMessageProjector.messageId(for:)))
            boundaries = contextCompactBoundaries.filter {
                $0.coveredMessageIds.isSubset(of: existingIds) && existingIds.contains($0.afterMessageId)
            }
        }
        let anchors = Set(boundaries.map(\.afterMessageId))
        let compactedEnd = anchors.isEmpty ? nil : messages.lastIndex {
            anchors.contains(ChatMessageProjector.messageId(for: $0))
        }
        let compactedIds = Set(messages.prefix(compactedEnd.map { $0 + 1 } ?? 0).map(ChatMessageProjector.messageId(for:)))
        let boundariesByAnchor = Dictionary(grouping: boundaries, by: \.afterMessageId)
        for entry in plan.entries {
            switch entry {
            case .message, .pendingAssistant:
                var projected = nativeEntry(
                        for: entry,
                        isGenerationActive: isGenerationActive,
                        viewportState: viewportState,
                        displaySettingSignature: displaySettingSignature,
                        generativeUiSettingSignature: generativeUiSettingSignature,
                        renderStateRevision: renderStateRevision,
                        reasoningLevelLabel: reasoningLevelLabel,
                        renderStateStore: renderStateStore,
                        variantInfoProvider: variantInfoProvider,
                        contentHashProvider: contentHashProvider
                    )
                projected.isCompactedHistory = projected.messageId.map(compactedIds.contains) ?? false
                entries.append(projected)
                if let messageId = projected.messageId {
                    for boundary in boundariesByAnchor[messageId] ?? [] {
                        var marker = decorationEntry(
                            id: "context-compact-\(boundary.id)", kind: .contextMarker,
                            renderToken: "\(boundary.id)-\(boundary.state.summary)"
                        )
                        marker.compactState = boundary.state
                        entries.append(marker)
                    }
                }
            case let .bottomAnchor(id):
                if isRecognizingImages {
                    entries.append(
                        decorationEntry(
                            id: "vision-recognition-indicator",
                            kind: .visionRecognition,
                            renderToken: "vision"
                        )
                    )
                }
                if contextCompactState.isVisible && contextCompactState.status != .completed {
                    let contextID = "context-compact-\(String(describing: contextCompactState.status))-\(contextCompactState.updatedAt.timeIntervalSince1970)"
                    entries.append(
                        decorationEntry(
                            id: contextID,
                            kind: .contextMarker,
                            renderToken: "\(contextID)-\(contextCompactState.summary)"
                        )
                    )
                }
                entries.append(nativeEntry(for: .bottomAnchor(id: id)))
            }
        }

        ChatPhoneToolGrouping.annotate(
            &entries,
            messages: messages,
            expandedGroupIDs: expandedPhoneToolGroupIDs,
            isGenerationActive: isGenerationActive
        )
        return NativeTimelineProjection(
            entries: entries,
            latestRenderToken: plan.latestRenderToken
        )
    }

    static func replacingStreamingTail(
        in previous: NativeTimelineProjection,
        messages: [UIMessage],
        event: ChatEvent,
        isGenerationActive: Bool,
        viewportState: ChatViewportState,
        displaySettingSignature: String = "",
        generativeUiSettingSignature: String = "",
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        streamedMessageIDs: Set<String> = [],
        renderStateStore: ChatRenderStateStore? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        expandedPhoneToolGroupIDs: Set<String> = []
    ) -> NativeTimelineProjection? {
        guard event == .assistantStreamDelta,
              let message = messages.last,
              message.role == MessageRole.assistant else { return nil }

        let messageID = ChatMessageProjector.messageId(for: message)
        guard let entryIndex = previous.entries.lastIndex(where: { $0.messageId == messageID }) else {
            return nil
        }

        let row = ChatMessageRowModel(
            rowId: messageID,
            messageId: messageID,
            message: message,
            role: message.role,
            parts: message.parts,
            index: messages.count - 1,
            isLast: true,
            isStreaming: true,
            hasEverStreamed: true,
            canAnimateInsertion: false,
            isAssistantContinuation: ChatMessageProjector.isAssistantContinuation(at: messages.count - 1, in: messages)
        )
        let renderState = renderStateStore?.stateForRow(
            row,
            isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom
        ) ?? ChatRenderState(
            rendererMode: viewportState.liveRenderingFarFromBottom ? .frozen : .streamingMarkdown,
            hasEverStreamed: true,
            liveRenderingEnabled: !viewportState.liveRenderingFarFromBottom,
            frozenMarkdownSnapshot: nil
        )
        let variantInfo = variantInfoProvider(row.index).map {
            NativeTimelineVariantInfo(
                variantCount: $0.variantCount,
                selectedIndex: $0.selectedIndex
            )
        }
        let contentHash = frozenStreamingContentHashIfNeeded(row: row, renderState: renderState) ??
            contentHashProvider(row, true)
        let digest = ChatRowDigests.digest(
            row: row,
            renderState: renderState,
            contentHash: contentHash,
            isGenerationActive: isGenerationActive,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: "\(generativeUiSettingSignature):renderState=\(renderStateRevision)",
            hasMultipleVariants: variantInfo?.hasMultipleVariants == true,
            reasoningLevelLabel: reasoningLevelLabel
        )

        var entries = previous.entries
        entries[entryIndex] = NativeTimelineEntry(
            id: "message-\(messageID)",
            kind: .message,
            messageId: messageID,
            message: message,
            role: message.role,
            index: row.index,
            isLastMessage: true,
            isStreaming: true,
            hasEverStreamed: true,
            canAnimateInsertion: false,
            renderer: .streamingAssistantMarkdown,
            renderToken: streamingTailRenderToken(row: row, streamedMessageIDs: streamedMessageIDs),
            variantInfo: variantInfo,
            renderState: renderState,
            renderDigest: digest,
            isAssistantContinuation: row.isAssistantContinuation
        )
        if ChatPhoneToolGrouping.tailMayAffectGroups(
            tail: message,
            previousRole: previous.entries[entryIndex].phoneToolGroup
        ) {
            ChatPhoneToolGrouping.annotate(
                &entries,
                messages: messages,
                expandedGroupIDs: expandedPhoneToolGroupIDs,
                isGenerationActive: isGenerationActive
            )
        }
        return NativeTimelineProjection(
            entries: entries,
            latestRenderToken: "\(messages.count):\(messageID):tail:\(row.parts.count):\(contentHash)"
        )
    }

    /// The cache verifies unchanged source shape before entering this path. Every
    /// changed loaded row is rebuilt through the same row/entry builders as a full
    /// projection, including non-tail tool backfills and mailbox result cards.
    static func replacingToolMessages(
        in previous: NativeTimelineProjection,
        messages: [UIMessage], event: ChatEvent, startIndex: Int, unchangedMessageIDs: Set<String>,
        isGenerationActive: Bool, viewportState: ChatViewportState,
        displaySettingSignature: String, generativeUiSettingSignature: String,
        renderStateRevision: UInt64, reasoningLevelLabel: String?,
        streamedMessageIDs: Set<String>, renderStateStore: ChatRenderStateStore,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?,
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int,
        expandedPhoneToolGroupIDs: Set<String> = []
    ) -> NativeTimelineProjection? {
        guard event == .toolCallStarted || event == .toolResultAppended || event == .assistantStreamClosed else {
            return nil
        }
        // Mailbox visibility is metadata-driven; it can change without replacing
        // a UIMessage object. A new/removed visible row requires the full planner.
        let visibleIndices = messages.indices.dropFirst(max(0, startIndex)).filter {
            ChatMessageProjector.isVisibleInTimeline(messages[$0])
        }
        guard visibleIndices == previous.entries.compactMap(\.index) else { return nil }
        let lastVisibleIndex = messages.lastIndex(where: ChatMessageProjector.isVisibleInTimeline)
        var entries = previous.entries
        for entryIndex in entries.indices {
            let old = entries[entryIndex]
            guard old.kind == .message, let index = old.index, let id = old.messageId else { continue }
            guard messages.indices.contains(index), ChatMessageProjector.messageId(for: messages[index]) == id else {
                return nil
            }
            // The tail also owns renderer/terminal state even if its payload did
            // not change. Insertion flags and stream-close state must not linger.
            if unchangedMessageIDs.contains(id), !old.isLastMessage, !old.isStreaming,
               !old.canAnimateInsertion, old.hasEverStreamed == streamedMessageIDs.contains(id),
               old.isAssistantContinuation == ChatMessageProjector.isAssistantContinuation(at: index, in: messages) {
                continue
            }
            guard let row = ChatMessageProjector.row(
                at: index, in: messages, event: event, streamedMessageIDs: streamedMessageIDs,
                lastVisibleIndex: lastVisibleIndex
            ) else { return nil }
            var entry = nativeEntry(
                for: .message(ChatTimelinePlanner.messageEntry(for: row)),
                isGenerationActive: isGenerationActive, viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision, reasoningLevelLabel: reasoningLevelLabel,
                renderStateStore: renderStateStore, variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider
            )
            entry.isCompactedHistory = old.isCompactedHistory
            entries[entryIndex] = entry
        }
        // A backfilled step anywhere in a run changes its head's header.
        ChatPhoneToolGrouping.annotate(
            &entries,
            messages: messages,
            expandedGroupIDs: expandedPhoneToolGroupIDs,
            isGenerationActive: isGenerationActive
        )
        let messageEntries = entries.filter { $0.kind == .message }
        let latestToken = messageEntries.last.map {
            "\(messageEntries.count):\($0.messageId ?? ""):\($0.renderToken):\(entries.contains { $0.kind == .pendingAssistant })"
        } ?? previous.latestRenderToken
        return NativeTimelineProjection(entries: entries, latestRenderToken: latestToken)
    }

    private static func nativeEntry(
        for entry: ChatTimelineEntry,
        isGenerationActive: Bool = false,
        viewportState: ChatViewportState = ChatViewportState(),
        displaySettingSignature: String = "",
        generativeUiSettingSignature: String = "",
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        renderStateStore: ChatRenderStateStore? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 }
    ) -> NativeTimelineEntry {
        switch entry {
        case let .message(message):
            let row = message.rowModel
            let renderState = renderStateStore?.stateForEntry(
                message,
                isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom
            ) ?? renderState(for: message, viewportState: viewportState)
            let variantInfo = variantInfoProvider(message.index).map {
                NativeTimelineVariantInfo(
                    variantCount: $0.variantCount,
                    selectedIndex: $0.selectedIndex
                )
            }
            let contentHash = frozenStreamingContentHashIfNeeded(row: row, renderState: renderState) ??
                contentHashProvider(row, row.isStreaming)
            let digest = ChatRowDigests.digest(
                row: row,
                renderState: renderState,
                contentHash: contentHash,
                isGenerationActive: isGenerationActive,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: row.isLast && row.role == MessageRole.assistant
                    ? "\(generativeUiSettingSignature):renderState=\(renderStateRevision)"
                    : generativeUiSettingSignature,
                hasMultipleVariants: variantInfo?.hasMultipleVariants == true,
                reasoningLevelLabel: reasoningLevelLabel
            )
            return NativeTimelineEntry(
                id: message.id,
                kind: .message,
                messageId: message.messageId,
                message: message.message,
                role: message.role,
                index: message.index,
                isLastMessage: message.isLast,
                isStreaming: message.isStreaming,
                hasEverStreamed: message.hasEverStreamed,
                canAnimateInsertion: message.canAnimateInsertion,
                renderer: message.renderer,
                renderToken: message.renderToken,
                variantInfo: variantInfo,
                renderState: renderState,
                renderDigest: digest,
                isAssistantContinuation: row.isAssistantContinuation
            )
        case let .pendingAssistant(id):
            return NativeTimelineEntry(
                id: id,
                kind: .pendingAssistant,
                messageId: nil,
                message: nil,
                role: nil,
                index: nil,
                isLastMessage: false,
                isStreaming: false,
                hasEverStreamed: false,
                canAnimateInsertion: false,
                renderer: nil,
                renderToken: id,
                variantInfo: nil,
                renderState: nil,
                renderDigest: nil
            )
        case let .bottomAnchor(id):
            return NativeTimelineEntry(
                id: id,
                kind: .bottomAnchor,
                messageId: nil,
                message: nil,
                role: nil,
                index: nil,
                isLastMessage: false,
                isStreaming: false,
                hasEverStreamed: false,
                canAnimateInsertion: false,
                renderer: nil,
                renderToken: id,
                variantInfo: nil,
                renderState: nil,
                renderDigest: nil
            )
        }
    }

    private static func frozenStreamingContentHashIfNeeded(
        row: ChatMessageRowModel,
        renderState: ChatRenderState
    ) -> Int? {
        guard row.isStreaming, !renderState.liveRenderingEnabled else { return nil }
        var hasher = Hasher()
        hasher.combine(row.messageId)
        hasher.combine(renderState.rendererMode.rawValue)
        hasher.combine(renderState.frozenMarkdownSnapshot?.utf16.count ?? 0)
        return hasher.finalize()
    }

    private static func streamingTailRenderToken(
        row: ChatMessageRowModel,
        streamedMessageIDs: Set<String>
    ) -> String {
        var hasher = Hasher()
        hasher.combine(row.messageId)
        hasher.combine(row.isAssistantContinuation)
        hasher.combine(row.parts.count)
        hasher.combine(streamedMessageIDs.contains(row.messageId))
        for part in row.parts {
            switch part {
            case let text as UIMessagePart.Text:
                hasher.combine("text")
                hasher.combine(text.text.utf16.count)
                hasher.combine(String(text.text.suffix(16)))
            case let reasoning as UIMessagePart.Reasoning:
                hasher.combine("reasoning")
                hasher.combine(reasoning.reasoning.utf16.count)
                hasher.combine(reasoning.finishedAt != nil)
            case let tool as UIMessagePart.Tool:
                hasher.combine("tool")
                hasher.combine(tool.toolCallId)
                hasher.combine(tool.output.count)
                hasher.combine(tool.isExecuted)
            default:
                hasher.combine(String(describing: type(of: part)))
            }
        }
        return "\(row.messageId):stream-tail:\(hasher.finalize())"
    }

    private static func renderState(
        for entry: ChatTimelineMessageEntry,
        viewportState: ChatViewportState
    ) -> ChatRenderState {
        guard entry.renderer == .streamingAssistantMarkdown else {
            return ChatRenderState(
                rendererMode: .staticMarkdown,
                hasEverStreamed: false,
                liveRenderingEnabled: true,
                frozenMarkdownSnapshot: nil
            )
        }
        let live = entry.isLast &&
            entry.role == MessageRole.assistant &&
            !viewportState.liveRenderingFarFromBottom
        return ChatRenderState(
            rendererMode: live ? .streamingMarkdown : .frozen,
            hasEverStreamed: true,
            liveRenderingEnabled: live,
            frozenMarkdownSnapshot: nil
        )
    }

    private static func decorationEntry(
        id: String,
        kind: NativeTimelineEntryKind,
        renderToken: String
    ) -> NativeTimelineEntry {
        NativeTimelineEntry(
            id: id,
            kind: kind,
            messageId: nil,
            message: nil,
            role: nil,
            index: nil,
            isLastMessage: false,
            isStreaming: false,
            hasEverStreamed: false,
            canAnimateInsertion: false,
            renderer: nil,
            renderToken: renderToken,
            variantInfo: nil,
            renderState: nil,
            renderDigest: nil
        )
    }
}

