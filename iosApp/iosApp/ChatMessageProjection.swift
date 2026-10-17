import Foundation
import Shared

extension UIMessage {
    var singleNonEmptyTextPart: String? {
        var result: String?
        for part in parts {
            guard let text = part as? UIMessagePart.Text, !text.text.isEmpty else { continue }
            guard result == nil else { return nil }
            result = text.text
        }
        return result
    }
}

struct ChatMessageAnchor: Hashable, Sendable {
    let conversationID: String
    let messageID: String
    let toolCallID: String?
    let requestToken: UUID?

    init(
        conversationID: String,
        messageID: String,
        toolCallID: String? = nil,
        requestToken: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.toolCallID = toolCallID
        self.requestToken = requestToken
    }
}

enum ChatImageGenerationAnchorTarget {
    static func id(messageID: String, toolCallID: String) -> String {
        "image-tool-\(messageID)-\(toolCallID)"
    }
}

enum ChatToolCallAnchorTarget {
    static func id(messageID: String, toolCallID: String) -> String {
        "tool-call-\(messageID)-\(toolCallID)"
    }
}

enum ChatImageGenerationResumeState: Equatable, Sendable {
    case running
    case completed
}

struct ChatImageGenerationResumeContext: Equatable, Sendable, Identifiable {
    let id: String
    let conversationID: String
    let messageID: String
    let toolCallID: String
    let prompt: String
    let state: ChatImageGenerationResumeState
    let updatedAt: Date
}

enum ChatImageGenerationResumeProjection {
    static func latest(
        in messages: [UIMessage],
        conversationID: String,
        isGenerationActive: Bool
    ) -> ChatImageGenerationResumeContext? {
        preferred(in: contexts(
            in: messages,
            conversationID: conversationID,
            isGenerationActive: isGenerationActive
        ))
    }

    static func matching(
        in messages: [UIMessage],
        conversationID: String,
        messageID: String,
        toolCallID: String,
        isGenerationActive: Bool
    ) -> ChatImageGenerationResumeContext? {
        contexts(
            in: messages,
            conversationID: conversationID,
            isGenerationActive: isGenerationActive
        ).first {
            $0.messageID == messageID && $0.toolCallID == toolCallID
        }
    }

    private static func contexts(
        in messages: [UIMessage],
        conversationID: String,
        isGenerationActive: Bool
    ) -> [ChatImageGenerationResumeContext] {
        messages.enumerated().flatMap { index, message -> [ChatImageGenerationResumeContext] in
            guard message.role == MessageRole.assistant else { return [] }
            let messageID = ChatMessageProjector.messageId(for: message)
            return message.parts.compactMap { part -> ChatImageGenerationResumeContext? in
                guard let tool = part as? UIMessagePart.Tool,
                      tool.toolName == "generate_image" else {
                    return nil
                }

                let state: ChatImageGenerationResumeState
                let timestamp: Kotlinx_datetimeLocalDateTime
                if tool.output.contains(where: { $0 is UIMessagePart.Image }) {
                    state = .completed
                    timestamp = message.finishedAt ?? message.createdAt
                } else if tool.output.isEmpty,
                          isGenerationActive,
                          index == messages.count - 1 {
                    state = .running
                    timestamp = message.createdAt
                } else {
                    return nil
                }
                guard let updatedAt = date(from: timestamp) else { return nil }

                return ChatImageGenerationResumeContext(
                    id: "\(conversationID)|\(messageID)|\(tool.toolCallId)",
                    conversationID: conversationID,
                    messageID: messageID,
                    toolCallID: tool.toolCallId,
                    prompt: prompt(from: tool.input),
                    state: state,
                    updatedAt: updatedAt
                )
            }
        }
    }

    static func preferred(
        in contexts: [ChatImageGenerationResumeContext]
    ) -> ChatImageGenerationResumeContext? {
        contexts.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .running }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }.first
    }

    private static func prompt(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String else {
            return trimmed
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(from localDateTime: Kotlinx_datetimeLocalDateTime) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = Int(localDateTime.year)
        components.month = Int(localDateTime.month.ordinal) + 1
        components.day = Int(localDateTime.day)
        components.hour = Int(localDateTime.hour)
        components.minute = Int(localDateTime.minute)
        components.second = Int(localDateTime.second)
        components.nanosecond = Int(localDateTime.nanosecond)
        return components.date
    }
}

enum ChatImageGenerationResumeConsumption {
    static let viewedCompletionIDKey = "app.amber.ios.home.viewedImageGeneration.v1"

    @discardableResult
    static func markViewedIfCompleted(
        anchor: ChatMessageAnchor,
        messages: [UIMessage],
        isGenerationActive: Bool,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard let toolCallID = anchor.toolCallID,
              let context = ChatImageGenerationResumeProjection.matching(
                in: messages,
                conversationID: anchor.conversationID,
                messageID: anchor.messageID,
                toolCallID: toolCallID,
                isGenerationActive: isGenerationActive
              ),
              context.state == .completed else {
            return nil
        }
        userDefaults.set(context.id, forKey: viewedCompletionIDKey)
        return context.id
    }
}

struct ChatMessageRowModel: Identifiable {
    let rowId: String
    let messageId: String
    let message: UIMessage
    let role: MessageRole
    let parts: [UIMessagePart]
    let index: Int
    let isLast: Bool
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let canAnimateInsertion: Bool

    var isAssistantContinuation: Bool = false

    var id: String { rowId }
}

enum ChatTimelineRendererKind: Equatable {
    case user
    case staticAssistantMarkdown
    case streamingAssistantMarkdown
}

enum ChatTimelineEntry: Equatable {
    case message(ChatTimelineMessageEntry)
    case pendingAssistant(id: String)
    case bottomAnchor(id: String)

    var id: String {
        switch self {
        case let .message(entry):
            return entry.id
        case let .pendingAssistant(id), let .bottomAnchor(id):
            return id
        }
    }
}

struct ChatTimelineMessageEntry: Equatable {
    let id: String
    let messageId: String
    let message: UIMessage
    let role: MessageRole
    let index: Int
    let isLast: Bool
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let canAnimateInsertion: Bool
    let renderer: ChatTimelineRendererKind
    let renderToken: String

    var isAssistantContinuation: Bool = false

    var rowModel: ChatMessageRowModel {
        ChatMessageRowModel(
            rowId: messageId,
            messageId: messageId,
            message: message,
            role: role,
            parts: message.parts,
            index: index,
            isLast: isLast,
            isStreaming: isStreaming,
            hasEverStreamed: hasEverStreamed,
            canAnimateInsertion: canAnimateInsertion,
            isAssistantContinuation: isAssistantContinuation
        )
    }
}

struct ChatTimelinePlan: Equatable {
    let entries: [ChatTimelineEntry]
    let latestRenderToken: String

    func messageEntry(for messageId: String) -> ChatTimelineMessageEntry? {
        entries.lazy.compactMap { entry -> ChatTimelineMessageEntry? in
            guard case let .message(message) = entry else { return nil }
            return message.messageId == messageId ? message : nil
        }.first
    }
}

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

enum ChatTimelinePlanner {
    static let bottomAnchorID = ChatLayout.bottomAnchorID
    static let pendingAssistantID = "timeline-pending-assistant"
    static let messageEntryIDPrefix = "message-"

    /// `includeRenderTokens` 控制是否计算逐行 renderToken。Native timeline
    /// projection 消费 token；旧 SwiftUI/collection 路径只取 row model，传 false
    /// 跳过尾行每个 chunk 都要 O(文本长度) 扫一遍的 token 计算。
    static func build(
        messages: [UIMessage],
        event: ChatEvent,
        streamedMessageIDs: Set<String> = [],
        includePendingAssistant: Bool = false,
        includeRenderTokens: Bool = true,
        startIndex: Int = 0
    ) -> ChatTimelinePlan {
        let rows = ChatMessageProjector.rows(
            messages: messages,
            event: event,
            streamedMessageIDs: streamedMessageIDs,
            startIndex: startIndex
        )
        var entries = rows.map { row in
            ChatTimelineEntry.message(messageEntry(for: row, includeRenderToken: includeRenderTokens))
        }

        if includePendingAssistant {
            entries.append(.pendingAssistant(id: pendingAssistantID))
        }
        entries.append(.bottomAnchor(id: bottomAnchorID))

        return ChatTimelinePlan(
            entries: entries,
            latestRenderToken: includeRenderTokens
                ? latestRenderToken(rows: rows, includePendingAssistant: includePendingAssistant)
                : ""
        )
    }

    static func messageEntry(for row: ChatMessageRowModel, includeRenderToken: Bool = true) -> ChatTimelineMessageEntry {
        ChatTimelineMessageEntry(
            id: messageEntryIDPrefix + row.messageId, messageId: row.messageId,
            message: row.message, role: row.role, index: row.index,
            isLast: row.isLast, isStreaming: row.isStreaming, hasEverStreamed: row.hasEverStreamed,
            canAnimateInsertion: row.canAnimateInsertion, renderer: rendererKind(for: row),
            renderToken: includeRenderToken ? renderToken(for: row) : "",
            isAssistantContinuation: row.isAssistantContinuation
        )
    }

    private static func rendererKind(for row: ChatMessageRowModel) -> ChatTimelineRendererKind {
        switch row.role {
        case MessageRole.user:
            return .user
        case MessageRole.assistant:
            return row.isStreaming || row.hasEverStreamed ? .streamingAssistantMarkdown : .staticAssistantMarkdown
        default:
            return .staticAssistantMarkdown
        }
    }

    private static func latestRenderToken(rows: [ChatMessageRowModel], includePendingAssistant: Bool) -> String {
        guard let row = rows.last else {
            return includePendingAssistant ? "empty:pending" : "empty"
        }
        return "\(rows.count):\(row.messageId):\(renderToken(for: row)):\(includePendingAssistant)"
    }

    private static func renderToken(for row: ChatMessageRowModel) -> String {
        let partTokens = row.parts.map { compactRenderToken(for: $0) }.joined(separator: "|")
        return "\(row.messageId):\(row.role.name):\(row.isStreaming):\(row.hasEverStreamed):\(row.isAssistantContinuation):\(partTokens)"
    }

    private static func compactRenderToken(for part: UIMessagePart) -> String {
        switch part {
        case let text as UIMessagePart.Text:
            // utf16.count 而非 count:Character 计数是 O(n) 字素簇遍历,流式尾行
            // 每个 chunk 都要为 32KB 级文本付一次;token 只需要"长度变了就变"。
            return "text:\(text.text.utf16.count):\(String(text.text.suffix(16)))"
        case let reasoning as UIMessagePart.Reasoning:
            return "reasoning:\(reasoning.reasoning.utf16.count):\(reasoning.finishedAt != nil)"
        case let image as UIMessagePart.Image:
            // Bounded: never walk graphemes of a base64 data URL or stringify metadata.
            return "image:\(ChatPartSignature.hash(image, exactText: false))"
        case let document as UIMessagePart.Document:
            return "document:\(document.fileName):\(ChatPartSignature.hash(document, exactText: false))"
        case let miniApp as UIMessagePart.MiniApp:
            return "mini_app:\(miniApp.appId):\(miniApp.version):\(miniApp.htmlHash ?? ""):\(miniApp.title)"
        case let tool as UIMessagePart.Tool:
            let outputToken = tool.output.last.map { compactRenderToken(for: $0) } ?? "empty"
            return "tool:\(tool.toolCallId):\(tool.toolName):\(tool.isExecuted):\(tool.output.count):\(outputToken)"
        default:
            return "\(type(of: part)):\(ChatPartSignature.hash(part, exactText: false))"
        }
    }
}

enum ChatMessageProjector {
    /// Internal progress stays in context; completed results have a dedicated
    /// agent-side card while retaining their provider transport role.
    static func isVisibleInTimeline(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.user else { return true }
        switch IosMailboxMessageBridge.shared.kind(message: message) {
        case "MESSAGE": return false
        default: return true
        }
    }

    static func isSubAgentResult(_ message: UIMessage) -> Bool {
        message.role == MessageRole.user &&
            IosMailboxMessageBridge.shared.kind(message: message) == "FINAL_ANSWER"
    }

    static func isConversationMessage(_ message: UIMessage) -> Bool {
        isVisibleInTimeline(message) && !isSubAgentResult(message)
    }

    static func messageId(for message: UIMessage) -> String {
        // String(describing:) 走桥接 description 路径(单次 ~25µs,逐行×每 delta);
        // toHexDashString() 是直接访问器,产出同样的 8-4-4-4-12 字符串
        // (格式等价由 ChatMessageProjectionTests 的 canary 锁定)。
        message.id.toHexDashString()
    }

    static func isAssistantContinuation(at index: Int, in messages: [UIMessage]) -> Bool {
        guard index > 0, messages[index].role == MessageRole.assistant else { return false }
        for previous in messages[..<index].reversed() where isVisibleInTimeline(previous) {
            return previous.role == MessageRole.assistant
        }
        return false
    }

    static func rows(
        messages: [UIMessage],
        event: ChatEvent,
        streamedMessageIDs: Set<String> = [],
        startIndex: Int = 0
    ) -> [ChatMessageRowModel] {
        let lastVisibleIndex = messages.lastIndex(where: isVisibleInTimeline)
        return messages.indices.dropFirst(max(0, startIndex)).compactMap { index in
            row(at: index, in: messages, event: event, streamedMessageIDs: streamedMessageIDs,
                lastVisibleIndex: lastVisibleIndex)
        }
    }

    static func row(
        at index: Int, in messages: [UIMessage], event: ChatEvent,
        streamedMessageIDs: Set<String>, lastVisibleIndex: Int?
    ) -> ChatMessageRowModel? {
        let message = messages[index]
        guard isVisibleInTimeline(message) else { return nil }
        let messageId = messageId(for: message)
        let isResult = isSubAgentResult(message)
        let isLast = index == lastVisibleIndex
        let isStreaming = event == .assistantStreamDelta && isLast && message.role == MessageRole.assistant
        let hasEverStreamed = !isResult && (isStreaming || streamedMessageIDs.contains(messageId))
        let canAnimateInsertion = (event == .toolResultAppended && isResult) ||
            (event == .userMessageAppended && isLast && message.role == MessageRole.user && !isResult)
        return ChatMessageRowModel(
            rowId: messageId, messageId: messageId, message: message,
            role: isResult ? MessageRole.assistant : message.role, parts: message.parts, index: index,
            isLast: isLast, isStreaming: isStreaming, hasEverStreamed: hasEverStreamed,
            canAnimateInsertion: canAnimateInsertion,
            isAssistantContinuation: isAssistantContinuation(at: index, in: messages)
        )
    }

}

enum ChatInsertionAnimationPolicy {
    static func animatedInsertionItemIDs(
        previousItemIDs: [String],
        rows: [ChatMessageRowModel]
    ) -> [String] {
        let previous = Set(previousItemIDs)
        return rows.compactMap { row in
            guard row.canAnimateInsertion else { return nil }
            let itemID = "message-\(row.messageId)"
            return previous.contains(itemID) ? nil : itemID
        }
    }
}

/// L1 content signatures for message parts.
///
/// Tool outputs in phone automation carry 100–200 KB base64 screenshots per step
/// (16–20 MB per conversation). Signatures must never stringify (`String(describing:)`
/// runs Kotlin `toString()` over the whole payload), walk graphemes (`.count`) or
/// hash those payloads in full.
/// - Text (tool output text, reasoning, tool input, approval text) is hashed exactly
///   up to `textExactLimit`; the per-part identity cache bounds how often that runs.
/// - Media URLs, `data:` payloads and texts above the limit are sampled: UTF-16
///   length (O(1) via the bridged `NSString`) plus fixed head/tail/interior windows.
/// - Top-level message text/reasoning (`exactText: true`) is always exact: user edits
///   can change one character in the middle of a long message without changing its length.
enum ChatPartSignature {
    typealias Metadata = [String: Kotlinx_serialization_jsonJsonElement]

    /// Text-like strings up to this many UTF-16 units are hashed exactly.
    static let textExactLimit = 65_536
    /// URL/base64-like payload strings up to this many UTF-16 units are hashed exactly.
    static let payloadExactLimit = 2_048
    private static let edgeWindow = 256
    private static let interiorWindowCount = 16
    private static let interiorWindowLength = 32

    static func hash(_ part: UIMessagePart, exactText: Bool) -> Int {
        var hasher = Hasher()
        combine(part, exactText: exactText, into: &hasher)
        return hasher.finalize()
    }

    /// Text-like content: exact up to `textExactLimit`, sampled above; `data:`
    /// payloads embedded as text are treated as media.
    static func combineText(_ string: String, into hasher: inout Hasher) {
        let bridged = string as NSString
        let isPayload = bridged.length > payloadExactLimit && bridged.hasPrefix("data:")
        combineBounded(bridged, exactLimit: isPayload ? payloadExactLimit : textExactLimit, into: &hasher)
    }

    /// Media URLs / base64 payloads: exact only when short.
    static func combinePayload(_ string: String, into hasher: inout Hasher) {
        combineBounded(string as NSString, exactLimit: payloadExactLimit, into: &hasher)
    }

    /// Bounded work regardless of string size above `exactLimit`: at most
    /// `2 * edgeWindow + interiorWindowCount * interiorWindowLength` UTF-16 units.
    static func combineBounded(_ bridged: NSString, exactLimit: Int, into hasher: inout Hasher) {
        let length = bridged.length
        hasher.combine(length)
        guard length > 0 else { return }
        guard length > exactLimit else {
            hasher.combine(bridged as String)
            return
        }
        hasher.combine(bridged.substring(with: NSRange(location: 0, length: edgeWindow)))
        hasher.combine(bridged.substring(with: NSRange(location: length - edgeWindow, length: edgeWindow)))
        let span = length - 2 * edgeWindow - interiorWindowLength
        for index in 1...interiorWindowCount {
            let location = edgeWindow + span * index / (interiorWindowCount + 1)
            hasher.combine(bridged.substring(with: NSRange(location: location, length: interiorWindowLength)))
        }
    }

    static func combine(_ part: UIMessagePart, exactText: Bool, into hasher: inout Hasher) {
        switch part {
        case let text as UIMessagePart.Text:
            hasher.combine(0)
            if exactText { hasher.combine(text.text) } else { combineText(text.text, into: &hasher) }
        case let reasoning as UIMessagePart.Reasoning:
            hasher.combine(1)
            if exactText {
                hasher.combine(reasoning.reasoning)
            } else {
                combineText(reasoning.reasoning, into: &hasher)
            }
            hasher.combine(reasoning.createdAt.hash)
            hasher.combine(reasoning.finishedAt?.hash ?? 0)
            hasher.combine(reasoning.finishedAt != nil)
        case let image as UIMessagePart.Image:
            hasher.combine(2)
            combinePayload(image.url, into: &hasher)
        case let video as UIMessagePart.Video:
            hasher.combine(3)
            combinePayload(video.url, into: &hasher)
        case let audio as UIMessagePart.Audio:
            hasher.combine(4)
            combinePayload(audio.url, into: &hasher)
            hasher.combine(audio.fileName)
        case let document as UIMessagePart.Document:
            hasher.combine(5)
            combinePayload(document.url, into: &hasher)
            hasher.combine(document.fileName)
            hasher.combine(document.mime)
        case let tool as UIMessagePart.Tool:
            hasher.combine(6)
            hasher.combine(tool.toolCallId)
            hasher.combine(tool.toolName)
            combineText(tool.input, into: &hasher)
            combineApproval(tool.approvalState, into: &hasher)
            hasher.combine(tool.streamIndex?.intValue ?? -1)
            let output = tool.output
            hasher.combine(output.count)
            for outputPart in output {
                // Tool output text is exact up to textExactLimit; media/base64 is sampled.
                combine(outputPart, exactText: false, into: &hasher)
            }
        default:
            // MiniApp and future part kinds carry no bulk payload (MiniApp stores
            // only an html hash), so their description is small.
            hasher.combine(7)
            hasher.combine(String(describing: part))
        }
        combineMetadata(part.metadata, into: &hasher)
    }

    static func combineApproval(_ state: ToolApprovalState, into hasher: inout Hasher) {
        switch state {
        case is ToolApprovalState.Pending:
            hasher.combine("pending")
        case is ToolApprovalState.Approved:
            hasher.combine("approved")
        case let denied as ToolApprovalState.Denied:
            hasher.combine("denied")
            combineText(denied.reason, into: &hasher)
        case let answered as ToolApprovalState.Answered:
            hasher.combine("answered")
            combineText(answered.answer, into: &hasher)
        default:
            hasher.combine("auto")
        }
    }

    /// Metadata is small and mutable in place; Kotlin `hashCode()` is content based.
    static func combineMetadata(_ metadata: Metadata?, into hasher: inout Hasher) {
        guard let metadata else {
            hasher.combine(-1)
            return
        }
        hasher.combine(metadata.count)
        for key in metadata.keys.sorted() {
            hasher.combine(key)
            hasher.combine(metadata[key]?.hash ?? 0)
        }
    }
}

// MARK: - Phone automation step grouping (L1)

/// Something inside a phone-step group the user must see without expanding it.
/// Raw values order severity.
enum ChatPhoneToolGroupAttention: Int, Equatable {
    /// The latest step failed.
    case failed = 1
    /// A step's action may have run but its result was lost; the user must check the phone.
    case outcomeUnknown = 2
    /// A step is waiting for the user's approval.
    case approvalPending = 3
}

/// Projection of one run of consecutive phone-automation tool steps, rendered as
/// one collapsible row by its head message. Pure value: produced by
/// `ChatPhoneToolGrouping.annotate` from the L0 messages + expansion state.
struct ChatPhoneToolGroupSummary {
    /// UUID of the run's first phone message (even when it precedes the loaded
    /// window). Stable while the run grows and across history reveal; expansion key.
    let id: String
    let headMessageID: String
    let stepCount: Int
    let latestTool: UIMessagePart.Tool
    let attention: ChatPhoneToolGroupAttention?
    let attentionCount: Int
    /// The run is still being extended by the active generation.
    let isLive: Bool
    let startedAt: Date?
    /// nil while live.
    let finishedAt: Date?
    let isExpanded: Bool
    /// Content (height-affecting) signature of the collapsed/expanded header.
    let signature: Int

    var anchorID: String { "phone-tool-group-\(id)" }
}

/// Role of a timeline message entry inside a phone-step group.
///
/// Every member keeps its own `message-<id>` entry so render identity (L4), the
/// streaming tail paths and absolute indices are untouched while a run grows.
/// The head renders the group header (and, expanded, its own steps); the other
/// members render nothing while collapsed and their normal bubble when expanded.
enum ChatPhoneToolGroupRole: Equatable {
    case head(ChatPhoneToolGroupSummary)
    case member(groupID: String, isExpanded: Bool)

    var groupID: String {
        switch self {
        case let .head(summary): summary.id
        case let .member(groupID, _): groupID
        }
    }

    var headSummary: ChatPhoneToolGroupSummary? {
        if case let .head(summary) = self { return summary }
        return nil
    }

    var isCollapsedMember: Bool {
        if case let .member(_, isExpanded) = self { return !isExpanded }
        return false
    }

    var isExpandedMember: Bool {
        if case let .member(_, isExpanded) = self { return isExpanded }
        return false
    }

    var signature: Int {
        var hasher = Hasher()
        switch self {
        case let .head(summary):
            hasher.combine("head")
            hasher.combine(summary.signature)
        case let .member(groupID, isExpanded):
            hasher.combine("member")
            hasher.combine(groupID)
            hasher.combine(isExpanded)
        }
        return hasher.finalize()
    }

    /// Signature equality only: never compare the Kotlin tool payload (MBs of base64).
    static func == (lhs: ChatPhoneToolGroupRole, rhs: ChatPhoneToolGroupRole) -> Bool {
        lhs.signature == rhs.signature
    }
}

enum ChatPhoneToolGrouping {
    enum Membership: Equatable {
        /// Assistant message whose only visible content is phone tool steps (+ reasoning).
        case phone
        /// Reasoning-only / empty assistant message: extends an open run, never starts one.
        case neutral
        /// Anything the user must see as its own row: text, other tools, media, user turns.
        case breaking
    }

    static func isPhoneTool(_ name: String) -> Bool {
        IOSPhoneControlToolCatalog.isPhoneTool(name: name) || name.hasPrefix("phone_")
    }

    static func membership(of message: UIMessage) -> Membership {
        // Citations render under the message; a collapsed member would hide them.
        guard message.role == MessageRole.assistant, message.annotations.isEmpty else { return .breaking }
        var hasPhoneTool = false
        for part in message.parts {
            switch part {
            case let tool as UIMessagePart.Tool:
                guard isPhoneTool(tool.toolName) else { return .breaking }
                hasPhoneTool = true
            case is UIMessagePart.Reasoning:
                continue
            case let text as UIMessagePart.Text:
                if text.text.contains(where: { !$0.isWhitespace }) { return .breaking }
            default:
                return .breaking
            }
        }
        return hasPhoneTool ? .phone : .neutral
    }

    /// Whether a tail update can change any group: the tail joins/extends a run, or
    /// it previously belonged to one. Plain text streaming skips the regrouping pass.
    static func tailMayAffectGroups(tail: UIMessage, previousRole: ChatPhoneToolGroupRole?) -> Bool {
        previousRole != nil || membership(of: tail) != .breaking
    }

    static func digest(base: ChatRowDigest?, role: ChatPhoneToolGroupRole?) -> ChatRowDigest? {
        guard let base, let role else { return base }
        var hasher = Hasher()
        hasher.combine(base.layout)
        hasher.combine(role.signature)
        return ChatRowDigest(layout: String(hasher.finalize()), presentation: base.presentation)
    }

    /// Pure regrouping pass over message entries. Idempotent: recomputes every
    /// entry's role and folds the role signature into its digest from the entry's
    /// base (ungrouped) digest.
    ///
    /// `messages` is the full L0 snapshot (entries only cover the loaded history
    /// window): a run that started before the window keeps its true first message
    /// (group id), step count and start time, so revealing earlier history never
    /// re-keys or collapses an expanded group.
    static func annotate(
        _ entries: inout [NativeTimelineEntry],
        messages: [UIMessage],
        expandedGroupIDs: Set<String>,
        isGenerationActive: Bool
    ) {
        struct Run {
            /// First phone message of the whole run (may precede the window).
            var firstMessage: UIMessage?
            var memberIndices: [Int] = []
            var tools: [UIMessagePart.Tool] = []
        }
        var runs: [Run] = []
        var current: Run?
        func close() {
            if let run = current, !run.tools.isEmpty, run.firstMessage != nil { runs.append(run) }
            current = nil
        }
        // A run open at the window start continues from outside the window.
        if let windowStart = entries.first(where: { $0.kind == .message })?.index {
            current = prefixRun(messages: messages, before: windowStart).map {
                Run(firstMessage: $0.firstMessage, memberIndices: [], tools: $0.tools)
            }
        }
        for index in entries.indices {
            let entry = entries[index]
            guard entry.kind == .message else {
                // A compaction marker is visible between rows; top/bottom decorations
                // (configuration notice, pending, bottom anchor) are not between steps.
                if entry.kind == .contextMarker { close() }
                continue
            }
            guard let message = entry.message,
                  !entry.hasMultipleVariants,
                  !ChatMessageProjector.isSubAgentResult(message) else {
                close()
                continue
            }
            switch membership(of: message) {
            case .phone:
                if current == nil { current = Run(firstMessage: message) }
                current?.memberIndices.append(index)
                for part in message.parts {
                    if let tool = part as? UIMessagePart.Tool { current?.tools.append(tool) }
                }
            case .neutral:
                // Reasoning-only steps (e.g. thinking before the next phone action)
                // stay inside an open run; they never start one.
                current?.memberIndices.append(index)
            case .breaking:
                close()
            }
        }
        close()

        let language = ChatPhoneToolPresentation.currentLanguageKey()
        var roles = [ChatPhoneToolGroupRole?](repeating: nil, count: entries.count)
        for run in runs {
            // The head is the first loaded member that has a phone step (it draws the
            // header); leading reasoning-only members of a run continued from before
            // the window are ordinary members.
            guard let firstMessage = run.firstMessage,
                  let headIndex = run.memberIndices.first(where: { index in
                      entries[index].message.map { membership(of: $0) == .phone } ?? false
                  }),
                  let lastIndex = run.memberIndices.last,
                  let latestTool = run.tools.last,
                  let headMessageID = entries[headIndex].messageId else { continue }
            // Keyed on the run's first message UUID: provider toolCallIds (e.g. "call_0")
            // are not unique across conversations.
            let groupID = ChatMessageProjector.messageId(for: firstMessage)
            let isExpanded = expandedGroupIDs.contains(groupID)
            let summary = summary(
                id: groupID,
                headMessageID: headMessageID,
                firstMessage: firstMessage,
                lastEntry: entries[lastIndex],
                tools: run.tools,
                latestTool: latestTool,
                isExpanded: isExpanded,
                isGenerationActive: isGenerationActive,
                language: language
            )
            for memberIndex in run.memberIndices {
                roles[memberIndex] = memberIndex == headIndex
                    ? .head(summary)
                    : .member(groupID: groupID, isExpanded: isExpanded)
            }
        }

        for index in entries.indices where entries[index].kind == .message {
            let role = roles[index]
            guard entries[index].phoneToolGroup != role || entries[index].baseRenderDigest == nil else { continue }
            let base = entries[index].baseRenderDigest ?? entries[index].renderDigest
            entries[index].baseRenderDigest = base
            entries[index].phoneToolGroup = role
            entries[index].renderDigest = digest(base: base, role: role)
        }
    }

    /// The part of a run that lies before the loaded window, scanning backward
    /// from `index - 1` until a breaking message. Hidden (non-timeline) messages
    /// are transparent, as they are for assistant continuation.
    static func prefixRun(
        messages: [UIMessage],
        before index: Int
    ) -> (firstMessage: UIMessage, tools: [UIMessagePart.Tool])? {
        var firstMessage: UIMessage?
        var reversedTools: [UIMessagePart.Tool] = []
        var cursor = min(index, messages.count) - 1
        while cursor >= 0 {
            let message = messages[cursor]
            cursor -= 1
            guard ChatMessageProjector.isVisibleInTimeline(message) else { continue }
            guard !ChatMessageProjector.isSubAgentResult(message) else { break }
            switch membership(of: message) {
            case .breaking:
                cursor = -1
            case .neutral:
                continue
            case .phone:
                firstMessage = message
                for part in message.parts.reversed() {
                    if let tool = part as? UIMessagePart.Tool { reversedTools.append(tool) }
                }
            }
        }
        guard let firstMessage, !reversedTools.isEmpty else { return nil }
        return (firstMessage, reversedTools.reversed())
    }

    private static func summary(
        id: String,
        headMessageID: String,
        firstMessage: UIMessage,
        lastEntry: NativeTimelineEntry,
        tools: [UIMessagePart.Tool],
        latestTool: UIMessagePart.Tool,
        isExpanded: Bool,
        isGenerationActive: Bool,
        language: String
    ) -> ChatPhoneToolGroupSummary {
        let isLive = isGenerationActive && lastEntry.isLastMessage

        // Never hide something the user must act on: approvals and unknown
        // outcomes anywhere in the run, and a failure of the current (latest) step.
        var attention: ChatPhoneToolGroupAttention?
        var attentionCount = 0
        func record(_ kind: ChatPhoneToolGroupAttention) {
            if attention == nil || kind.rawValue > attention!.rawValue {
                attention = kind
                attentionCount = 1
            } else if kind == attention {
                attentionCount += 1
            }
        }
        for (offset, tool) in tools.enumerated() {
            if tool.output.isEmpty {
                if tool.approvalState is ToolApprovalState.Pending { record(.approvalPending) }
                continue
            }
            let presentation = ChatPhoneToolPresentation.cached(
                toolName: tool.toolName,
                executed: true,
                analysis: ChatToolOutputFormatter.analysis(for: tool),
                language: language
            )
            if presentation.isOutcomeUnknown {
                record(.outcomeUnknown)
            } else if offset == tools.count - 1, presentation.state == .failed {
                record(.failed)
            }
        }

        let startedAt = ChatImageGenerationResumeProjection.date(from: firstMessage.createdAt)
        let finishedAt: Date? = isLive ? nil : lastEntry.message.flatMap { message in
            ChatImageGenerationResumeProjection.date(from: message.finishedAt ?? message.createdAt)
        }

        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(headMessageID)
        hasher.combine(tools.count)
        hasher.combine(latestTool.toolCallId)
        // Latest step status/output only: streaming tool arguments do not change the header.
        hasher.combine(latestTool.toolName)
        ChatPartSignature.combineApproval(latestTool.approvalState, into: &hasher)
        let output = latestTool.output
        hasher.combine(output.count)
        for part in output {
            ChatPartSignature.combine(part, exactText: false, into: &hasher)
        }
        hasher.combine(attention?.rawValue ?? 0)
        hasher.combine(attentionCount)
        hasher.combine(isLive)
        hasher.combine(startedAt.map { Int($0.timeIntervalSince1970) } ?? 0)
        hasher.combine(finishedAt.map { Int($0.timeIntervalSince1970) } ?? 0)
        hasher.combine(isExpanded)

        return ChatPhoneToolGroupSummary(
            id: id,
            headMessageID: headMessageID,
            stepCount: tools.count,
            latestTool: latestTool,
            attention: attention,
            attentionCount: attentionCount,
            isLive: isLive,
            startedAt: startedAt,
            finishedAt: finishedAt,
            isExpanded: isExpanded,
            signature: hasher.finalize()
        )
    }
}
