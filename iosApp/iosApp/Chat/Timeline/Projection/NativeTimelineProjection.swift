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

enum ChatAssistantTurnTrailingSignal: Equatable {
    case none
    case tool
    case thinking
    case replyText
}

struct NativeTimelineMessageFacts {
    let identity: ChatMessageContentIdentity
    let messageId: String
    var parts: [UIMessagePart] { identity.cachedParts }
    let rawRole: MessageRole
    let isVisibleInTimeline: Bool
    let isSubAgentResult: Bool
    let effectiveRole: MessageRole
    let isGlobalStatusOnly: Bool
    let contentObservesGenerationState: Bool
    let contentHasVisibleBodyText: Bool
    let partTokensBody: String
    let phoneMembership: ChatPhoneToolGrouping.Membership
    let phoneTools: [UIMessagePart.Tool]
    let turnToolParts: [UIMessagePart.Tool]
    let hasPendingTurnTool: Bool
    let hasRenderableReasoning: Bool
    let containsVisibleText: Bool
    let isTurnCollapsible: Bool
    let canHostTurnProgress: Bool
    let trailingTurnSignal: ChatAssistantTurnTrailingSignal

    init(message: UIMessage, index: Int? = nil) {
        let identity = ChatMessageContentIdentity(message, index: index)
        self.init(message: message, identity: identity)
    }

    init(message: UIMessage, identity: ChatMessageContentIdentity) {
        self.identity = identity
        self.messageId = ChatMessageProjector.messageId(for: message)
        let parts = identity.cachedParts
        let rawRole = message.role
        self.rawRole = rawRole
        let mailboxKind: String? = rawRole == MessageRole.user
            ? IosMailboxMessageBridge.shared.kind(message: message)
            : nil
        let visible = rawRole != MessageRole.user || mailboxKind != "MESSAGE"
        let subAgentResult = rawRole == MessageRole.user && mailboxKind == "FINAL_ANSWER"
        let effectiveRole = subAgentResult ? MessageRole.assistant : rawRole
        let annotationsEmpty = message.annotations.isEmpty

        self.isVisibleInTimeline = visible
        self.isSubAgentResult = subAgentResult
        self.effectiveRole = effectiveRole

        var observesGen = false
        var visibleText = false
        var renderableReasoning = false
        var allStatusOnlyParts = true
        var allCollapsibleParts = annotationsEmpty
        var phoneEligible = rawRole == MessageRole.assistant && annotationsEmpty
        var hasPhoneTool = false
        var phoneTools: [UIMessagePart.Tool] = []
        var turnTools: [UIMessagePart.Tool] = []
        var hasPendingTool = false
        var trailingSignal: ChatAssistantTurnTrailingSignal = .none

        for part in parts {
            switch part {
            case let text as UIMessagePart.Text:
                let hasNonWhitespace = text.text.contains(where: { !$0.isWhitespace })
                if hasNonWhitespace {
                    visibleText = true
                    phoneEligible = false
                    allCollapsibleParts = false
                    trailingSignal = .replyText
                }
                if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allStatusOnlyParts = false
                }
            case let reasoning as UIMessagePart.Reasoning:
                if !ReasoningMetadataKt.isEmptyProtocolReasoning(reasoning: reasoning) {
                    renderableReasoning = true
                    trailingSignal = .thinking
                }
            case let tool as UIMessagePart.Tool:
                turnTools.append(tool)
                if tool.output.isEmpty {
                    hasPendingTool = true
                }
                if tool.toolName == "generate_image" {
                    observesGen = true
                }
                let mediaBearing = ChatTaskStreamGrouping.isMediaBearing(tool)
                if mediaBearing {
                    allStatusOnlyParts = false
                    allCollapsibleParts = false
                }
                if ChatPhoneToolGrouping.isPhoneTool(tool.toolName) {
                    hasPhoneTool = true
                    if phoneEligible {
                        phoneTools.append(tool)
                    }
                } else {
                    phoneEligible = false
                }
                trailingSignal = .tool
            case is UIMessagePart.MiniApp:
                observesGen = true
                allStatusOnlyParts = false
                allCollapsibleParts = false
                phoneEligible = false
            default:
                allStatusOnlyParts = false
                allCollapsibleParts = false
                phoneEligible = false
            }
        }

        let isQueuedPlaceholder = parts.count == 1 &&
            (parts.first as? UIMessagePart.Text)?.text == ChatViewModel.queuedTaskPlaceholderText
        self.isGlobalStatusOnly = rawRole == MessageRole.assistant && annotationsEmpty &&
            (isQueuedPlaceholder || allStatusOnlyParts)
        self.contentObservesGenerationState = observesGen
        self.contentHasVisibleBodyText = effectiveRole != MessageRole.user && visibleText
        self.partTokensBody = visible ? ChatTimelinePlanner.partTokensBody(for: parts) : ""
        if phoneEligible {
            self.phoneMembership = hasPhoneTool ? .phone : .neutral
            self.phoneTools = hasPhoneTool ? phoneTools : []
        } else {
            self.phoneMembership = .breaking
            self.phoneTools = []
        }
        self.turnToolParts = turnTools
        self.hasPendingTurnTool = hasPendingTool
        self.hasRenderableReasoning = renderableReasoning
        self.containsVisibleText = visibleText
        self.isTurnCollapsible = allCollapsibleParts
        self.canHostTurnProgress = !turnTools.isEmpty || (renderableReasoning && !visibleText)
        self.trailingTurnSignal = trailingSignal
    }
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
    var isGlobalStatusOnly: Bool = false
    var isCompactedHistory: Bool = false
    var compactState: ChatContextCompactState? = nil
    /// Phone automation step group this message belongs to (L1 projection).
    var phoneToolGroup: ChatPhoneToolGroupRole? = nil
    /// Assistant turn with non-phone tools this message belongs to (L1 projection).
    var assistantTurn: ChatAssistantTurnRole? = nil
    /// Digest before the group role was folded in; lets regrouping stay idempotent.
    var baseRenderDigest: ChatRowDigest? = nil
    var isTaskLive: Bool = false
    var contentObservesGenerationState: Bool? = nil
    var contentHasVisibleBodyText: Bool? = nil

    /// Completed prose doesn't consume the chat-wide generation flag. Only
    /// live rows and media with modify controls need that flag to refresh.
    var observesGenerationState: Bool {
        if isLastMessage || isTaskLive || isStreaming { return true }
        if let contentObservesGenerationState { return contentObservesGenerationState }
        return message?.parts.contains { part in
            if part is UIMessagePart.MiniApp { return true }
            return (part as? UIMessagePart.Tool)?.toolName == "generate_image"
        } ?? false
    }

    /// Task mode changes only the fallback generator on the conversation tail.
    /// Explicit live-task rows already own their generation state.
    var observesIndependentTaskMode: Bool { isLastMessage && !isTaskLive }

    /// Occupies no space; its group head stands in for it.
    var isCollapsedGroupMember: Bool {
        phoneToolGroup?.isCollapsedMember == true || assistantTurn?.isCollapsedMember == true
    }

    var hasMultipleVariants: Bool {
        variantInfo?.hasMultipleVariants == true
    }

    var renderHasEverStreamed: Bool {
        renderState?.hasEverStreamed ?? hasEverStreamed
    }

    /// 该条目是否已经渲染了非空正文。用于判定锚点下方的单行动态进度是否该退场：
    /// 正文一旦上屏，进度行就不能再垫在气泡下面（否则流式结束时整块下坠）。
    var hasVisibleBodyText: Bool {
        if let contentHasVisibleBodyText { return contentHasVisibleBodyText }
        guard role != MessageRole.user, let message else { return false }
        return message.parts.contains { part in
            (part as? UIMessagePart.Text)?.text.contains { !$0.isWhitespace } == true
        }
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
        displaySettingSignature: Int = 0,
        generativeUiSettingSignature: Int = 0,
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        streamedMessageIDs: Set<String> = [],
        liveTaskTailIDs: Set<String> = [],
        renderStateStore: ChatRenderStateStore? = nil,
        includePendingAssistant: Bool? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        startIndex: Int = 0,
        expandedPhoneToolGroupIDs: Set<String> = [],
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]? = nil
    ) -> NativeTimelineProjection {
        // Standard Chat already owns waiting/thinking/search status in the top island.
        // Keep the timeline for real message content so completion never removes a
        // duplicate status row after the final text has settled.
        let shouldIncludePendingAssistant = includePendingAssistant ?? false
        func resolvedFacts(at index: Int) -> NativeTimelineMessageFacts {
            let message = messages[index]
            if let cached = factsByObjectID?[ObjectIdentifier(message)] {
                return cached
            }
            return NativeTimelineMessageFacts(message: message, index: index)
        }

        let lastMessageID = messages.isEmpty ? nil : resolvedFacts(at: messages.count - 1).messageId
        let eventForRows: ChatEvent = event == .assistantStreamDelta && !liveTaskTailIDs.isEmpty &&
            lastMessageID.map({ !liveTaskTailIDs.contains($0) }) == true ? .toolResultAppended : event

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
            if shouldIncludePendingAssistant {
                entries.append(nativeEntry(for: .pendingAssistant(id: ChatTimelinePlanner.pendingAssistantID)))
            }
            entries.append(nativeEntry(for: .bottomAnchor(id: ChatTimelinePlanner.bottomAnchorID)))
            return NativeTimelineProjection(
                entries: entries,
                latestRenderToken: shouldIncludePendingAssistant ? "empty:pending" : "empty"
            )
        }

        let clampedStart = max(0, min(startIndex, messages.count))
        var localFactsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts] = factsByObjectID ?? [:]
        if factsByObjectID == nil {
            localFactsByObjectID.reserveCapacity(messages.count - clampedStart)
        }
        func facts(at index: Int) -> NativeTimelineMessageFacts {
            let message = messages[index]
            let key = ObjectIdentifier(message)
            if let cached = localFactsByObjectID[key] {
                return cached
            }
            let computed = NativeTimelineMessageFacts(message: message, index: index)
            localFactsByObjectID[key] = computed
            return computed
        }

        var lastVisibleIndex: Int?
        for index in messages.indices.reversed() {
            if facts(at: index).isVisibleInTimeline {
                lastVisibleIndex = index
                break
            }
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
            let existingIds = Set(messages.indices.map { facts(at: $0).messageId })
            boundaries = contextCompactBoundaries.filter {
                $0.coveredMessageIds.isSubset(of: existingIds) && existingIds.contains($0.afterMessageId)
            }
        }
        let anchors = Set(boundaries.filter { !$0.isEpisodeBoundary }.map(\.afterMessageId))
        let compactedEnd = anchors.isEmpty ? nil : messages.indices.last {
            anchors.contains(facts(at: $0).messageId)
        }
        let compactedIds = Set((0 ..< (compactedEnd.map { $0 + 1 } ?? 0)).map { facts(at: $0).messageId })
        let boundariesByAnchor = Dictionary(grouping: boundaries, by: \.afterMessageId)

        var previousVisibleWasRawAssistant: Bool?
        var hasVisibleAssistantInTurn: Bool?
        var visibleMessageCount = 0

        for index in clampedStart ..< messages.count {
            let messageFacts = facts(at: index)
            guard messageFacts.isVisibleInTimeline else { continue }
            visibleMessageCount += 1

            if previousVisibleWasRawAssistant == nil {
                var foundPrevRawAssistant = false
                if index > 0 {
                    for prevIndex in (0 ..< index).reversed() {
                        let prevFacts = facts(at: prevIndex)
                        if prevFacts.isVisibleInTimeline {
                            foundPrevRawAssistant = prevFacts.rawRole == MessageRole.assistant
                            break
                        }
                    }
                }
                previousVisibleWasRawAssistant = foundPrevRawAssistant
            }
            if hasVisibleAssistantInTurn == nil {
                hasVisibleAssistantInTurn = hasVisibleAssistantBefore(
                    index: index,
                    in: messages,
                    factsAt: facts
                )
            }

            let message = messages[index]
            let messageId = messageFacts.messageId
            let isResult = messageFacts.isSubAgentResult
            let isLast = index == lastVisibleIndex
            let isStreaming = eventForRows == .assistantStreamDelta && isLast && messageFacts.rawRole == MessageRole.assistant
            let hasEverStreamed = !isResult && (isStreaming || streamedMessageIDs.contains(messageId))
            let canAnimateInsertion = (eventForRows == .toolResultAppended && isResult) ||
                (eventForRows == .userMessageAppended && isLast && messageFacts.rawRole == MessageRole.user && !isResult)
            let plannerContinuation = messageFacts.rawRole == MessageRole.assistant && (previousVisibleWasRawAssistant == true)

            let plannerRow = ChatMessageRowModel(
                rowId: messageId,
                messageId: messageId,
                message: message,
                role: messageFacts.effectiveRole,
                parts: messageFacts.parts,
                index: index,
                isLast: isLast,
                isStreaming: isStreaming,
                hasEverStreamed: hasEverStreamed,
                canAnimateInsertion: canAnimateInsertion,
                isAssistantContinuation: plannerContinuation
            )
            var chatEntry = ChatTimelinePlanner.messageEntry(
                for: plannerRow,
                partTokensBody: messageFacts.partTokensBody
            )
            previousVisibleWasRawAssistant = messageFacts.rawRole == MessageRole.assistant

            if chatEntry.role == MessageRole.assistant {
                chatEntry.isAssistantContinuation = hasVisibleAssistantInTurn == true
                if !messageFacts.isGlobalStatusOnly {
                    hasVisibleAssistantInTurn = true
                }
            } else {
                hasVisibleAssistantInTurn = false
            }

            var projected = nativeMessageEntry(
                for: chatEntry,
                parts: messageFacts.parts,
                facts: messageFacts,
                isGenerationActive: isGenerationActive,
                viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision,
                reasoningLevelLabel: reasoningLevelLabel,
                renderStateStore: renderStateStore,
                variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider,
                liveTaskTailIDs: liveTaskTailIDs
            )
            projected.isCompactedHistory = compactedIds.contains(messageId)
            entries.append(projected)

            for boundary in boundariesByAnchor[messageId] ?? [] {
                var marker = decorationEntry(
                    id: "context-compact-\(boundary.id)", kind: .contextMarker,
                    renderToken: "\(boundary.id)-\(boundary.state.summary)"
                )
                marker.compactState = boundary.state
                entries.append(marker)
            }
        }

        if shouldIncludePendingAssistant {
            entries.append(nativeEntry(for: .pendingAssistant(id: ChatTimelinePlanner.pendingAssistantID)))
        }
        appendTailDecorations(
            into: &entries,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState
        )

        ChatPhoneToolGrouping.annotate(
            &entries,
            messages: messages,
            expandedGroupIDs: expandedPhoneToolGroupIDs,
            isGenerationActive: isGenerationActive,
            fromEntryIndex: 0,
            factsByObjectID: localFactsByObjectID
        )
        let latestRenderToken: String
        if let lastMessageEntry = entries.last(where: { $0.kind == .message }),
           let lastID = lastMessageEntry.messageId {
            latestRenderToken = "\(visibleMessageCount):\(lastID):\(lastMessageEntry.renderToken):\(shouldIncludePendingAssistant)"
        } else {
            latestRenderToken = shouldIncludePendingAssistant ? "empty:pending" : "empty"
        }
        return NativeTimelineProjection(
            entries: entries,
            latestRenderToken: latestRenderToken
        )
    }

    static func replacingStreamingTail(
        in previous: NativeTimelineProjection,
        messages: [UIMessage],
        event: ChatEvent,
        isGenerationActive: Bool,
        viewportState: ChatViewportState,
        displaySettingSignature: Int = 0,
        generativeUiSettingSignature: Int = 0,
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        streamedMessageIDs: Set<String> = [],
        renderStateStore: ChatRenderStateStore? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        expandedPhoneToolGroupIDs: Set<String> = [],
        liveTaskTailIDs: Set<String> = [],
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]? = nil
    ) -> NativeTimelineProjection? {
        guard event == .assistantStreamDelta,
              let message = messages.last,
              message.role == MessageRole.assistant else { return nil }

        let tailFacts = factsByObjectID?[ObjectIdentifier(message)] ??
            NativeTimelineMessageFacts(message: message, index: messages.count - 1)
        let messageID = tailFacts.messageId
        guard liveTaskTailIDs.isEmpty || liveTaskTailIDs.contains(messageID) else { return nil }
        guard let entryIndex = previous.entries.lastIndex(where: { $0.messageId == messageID }) else {
            return nil
        }

        let row = ChatMessageRowModel(
            rowId: messageID,
            messageId: messageID,
            message: message,
            role: message.role,
            parts: tailFacts.parts,
            index: messages.count - 1,
            isLast: true,
            isStreaming: true,
            hasEverStreamed: true,
            canAnimateInsertion: false,
            isAssistantContinuation: previous.entries[entryIndex].isAssistantContinuation
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
            generativeUiSettingSignature: generativeUiSettingSignature,
            hasMultipleVariants: variantInfo?.hasMultipleVariants == true,
            reasoningLevelLabel: reasoningLevelLabel,
            renderStateRevision: renderStateRevision
        )

        let previousEntry = previous.entries[entryIndex]
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
            isAssistantContinuation: row.isAssistantContinuation,
            isGlobalStatusOnly: tailFacts.isGlobalStatusOnly,
            isCompactedHistory: previousEntry.isCompactedHistory,
            isTaskLive: liveTaskTailIDs.contains(messageID),
            contentObservesGenerationState: tailFacts.contentObservesGenerationState,
            contentHasVisibleBodyText: tailFacts.contentHasVisibleBodyText
        )
        if ChatPhoneToolGrouping.tailMayAffectGroups(
            tail: message,
            previousRole: previousEntry.phoneToolGroup,
            previousTurnRole: previousEntry.assistantTurn
        ) {
            let tailSplit = entries[..<entryIndex].lastIndex(where: {
                $0.kind == .message && $0.role == MessageRole.user
            }) ?? 0
            var updatedFacts = factsByObjectID
            updatedFacts?[ObjectIdentifier(message)] = tailFacts
            ChatPhoneToolGrouping.annotate(
                &entries,
                messages: messages,
                expandedGroupIDs: expandedPhoneToolGroupIDs,
                isGenerationActive: isGenerationActive,
                fromEntryIndex: tailSplit,
                factsByObjectID: updatedFacts
            )
        } else if previousEntry.phoneToolGroup != nil || previousEntry.assistantTurn != nil {
            entries[entryIndex].baseRenderDigest = digest
            entries[entryIndex].phoneToolGroup = previousEntry.phoneToolGroup
            entries[entryIndex].assistantTurn = previousEntry.assistantTurn
            entries[entryIndex].renderDigest = ChatPhoneToolGrouping.digest(
                base: digest,
                role: previousEntry.phoneToolGroup,
                turnRole: previousEntry.assistantTurn
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
        displaySettingSignature: Int, generativeUiSettingSignature: Int,
        renderStateRevision: UInt64, reasoningLevelLabel: String?,
        streamedMessageIDs: Set<String>, renderStateStore: ChatRenderStateStore,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?,
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int,
        expandedPhoneToolGroupIDs: Set<String> = [],
        liveTaskTailIDs: Set<String> = [],
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]? = nil
    ) -> NativeTimelineProjection? {
        guard event == .toolCallStarted || event == .toolResultAppended || event == .assistantStreamClosed else {
            return nil
        }
        func resolvedFacts(at index: Int) -> NativeTimelineMessageFacts {
            let message = messages[index]
            return factsByObjectID?[ObjectIdentifier(message)] ??
                NativeTimelineMessageFacts(message: message, index: index)
        }
        // Mailbox visibility is metadata-driven; it can change without replacing
        // a UIMessage object. A new/removed visible row requires the full planner.
        let visibleIndices = messages.indices.dropFirst(max(0, startIndex)).filter {
            resolvedFacts(at: $0).isVisibleInTimeline
        }
        guard visibleIndices == previous.entries.compactMap(\.index) else { return nil }
        let lastVisibleIndex = messages.indices.last { resolvedFacts(at: $0).isVisibleInTimeline }
        var entries = previous.entries
        var previousVisibleWasRawAssistant: Bool?
        for entryIndex in entries.indices {
            let old = entries[entryIndex]
            guard old.kind == .message, let index = old.index, let id = old.messageId else { continue }
            guard messages.indices.contains(index) else { return nil }
            let messageFacts = resolvedFacts(at: index)
            guard messageFacts.messageId == id else { return nil }

            if previousVisibleWasRawAssistant == nil {
                var foundPrevRawAssistant = false
                if index > 0 {
                    for prevIndex in (0 ..< index).reversed() {
                        let prevFacts = resolvedFacts(at: prevIndex)
                        if prevFacts.isVisibleInTimeline {
                            foundPrevRawAssistant = prevFacts.rawRole == MessageRole.assistant
                            break
                        }
                    }
                }
                previousVisibleWasRawAssistant = foundPrevRawAssistant
            }
            let plannerContinuation = messageFacts.rawRole == MessageRole.assistant && (previousVisibleWasRawAssistant == true)
            previousVisibleWasRawAssistant = messageFacts.rawRole == MessageRole.assistant

            if !unchangedMessageIDs.contains(id),
               old.isGlobalStatusOnly != messageFacts.isGlobalStatusOnly {
                return nil
            }
            // The tail also owns renderer/terminal state even if its payload did
            // not change. Insertion flags and stream-close state must not linger.
            if unchangedMessageIDs.contains(id), !old.isLastMessage, !old.isStreaming,
               !old.canAnimateInsertion, old.hasEverStreamed == (!messageFacts.isSubAgentResult && streamedMessageIDs.contains(id)) {
                continue
            }
            let message = messages[index]
            let isResult = messageFacts.isSubAgentResult
            let isLast = index == lastVisibleIndex
            let isStreaming = false
            let hasEverStreamed = !isResult && streamedMessageIDs.contains(id)
            let canAnimateInsertion = (event == .toolResultAppended && isResult)
            let plannerRow = ChatMessageRowModel(
                rowId: id,
                messageId: id,
                message: message,
                role: messageFacts.effectiveRole,
                parts: messageFacts.parts,
                index: index,
                isLast: isLast,
                isStreaming: isStreaming,
                hasEverStreamed: hasEverStreamed,
                canAnimateInsertion: canAnimateInsertion,
                isAssistantContinuation: plannerContinuation
            )
            var chatEntry = ChatTimelinePlanner.messageEntry(
                for: plannerRow,
                partTokensBody: messageFacts.partTokensBody
            )
            chatEntry.isAssistantContinuation = old.isAssistantContinuation
            var entry = nativeMessageEntry(
                for: chatEntry,
                parts: messageFacts.parts,
                facts: messageFacts,
                isGenerationActive: isGenerationActive, viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision, reasoningLevelLabel: reasoningLevelLabel,
                renderStateStore: renderStateStore, variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider,
                liveTaskTailIDs: liveTaskTailIDs
            )
            entry.isCompactedHistory = old.isCompactedHistory
            entries[entryIndex] = entry
        }
        // A backfilled step anywhere in a run changes its head's header.
        ChatPhoneToolGrouping.annotate(
            &entries,
            messages: messages,
            expandedGroupIDs: expandedPhoneToolGroupIDs,
            isGenerationActive: isGenerationActive,
            fromEntryIndex: 0,
            factsByObjectID: factsByObjectID
        )
        let messageEntries = entries.filter { $0.kind == .message }
        let latestToken = messageEntries.last.map {
            "\(messageEntries.count):\($0.messageId ?? ""):\($0.renderToken):\(entries.contains { $0.kind == .pendingAssistant })"
        } ?? previous.latestRenderToken
        return NativeTimelineProjection(entries: entries, latestRenderToken: latestToken)
    }

    static func projectingIncrementalTail(
        from previous: NativeTimelineProjection,
        splitEntryIndex: Int,
        splitMessageIndex: Int,
        commonUnchangedPrefixCount: Int,
        messages: [UIMessage],
        orderedFacts: [NativeTimelineMessageFacts],
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts],
        event: ChatEvent,
        isGenerationActive: Bool,
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState,
        viewportState: ChatViewportState,
        displaySettingSignature: Int,
        generativeUiSettingSignature: Int,
        renderStateRevision: UInt64,
        reasoningLevelLabel: String?,
        streamedMessageIDs: Set<String>,
        liveTaskTailIDs: Set<String>,
        renderStateStore: ChatRenderStateStore,
        includePendingAssistant: Bool? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?,
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int,
        expandedPhoneToolGroupIDs: Set<String>
    ) -> NativeTimelineProjection {
        let shouldIncludePendingAssistant = includePendingAssistant ?? false
        let lastMessageID = orderedFacts.last?.messageId
        let eventForRows: ChatEvent = event == .assistantStreamDelta && !liveTaskTailIDs.isEmpty &&
            lastMessageID.map({ !liveTaskTailIDs.contains($0) }) == true ? .toolResultAppended : event

        var lastVisibleIndex: Int?
        for index in orderedFacts.indices.reversed() {
            if orderedFacts[index].isVisibleInTimeline {
                lastVisibleIndex = index
                break
            }
        }

        var oldEntriesByIndex: [Int: NativeTimelineEntry] = [:]
        for entry in previous.entries[splitEntryIndex...] where entry.kind == .message {
            if let index = entry.index {
                oldEntriesByIndex[index] = entry
            }
        }

        var entries = Array(previous.entries[0 ..< splitEntryIndex])
        entries.reserveCapacity(splitEntryIndex + (messages.count - splitMessageIndex) + 3)

        var visibleMessageCount = entries.reduce(0) { $0 + ($1.kind == .message ? 1 : 0) }
        // `splitMessageIndex` is guaranteed to be a visible raw `.user` (`!isSubAgentResult`)
        // message, so both continuation trackers deterministically reset at `splitMessageIndex`.
        var previousVisibleWasRawAssistant = false
        var hasVisibleAssistantInTurn = false

        for index in splitMessageIndex ..< messages.count {
            let messageFacts = orderedFacts[index]
            guard messageFacts.isVisibleInTimeline else { continue }
            visibleMessageCount += 1

            let message = messages[index]
            let messageId = messageFacts.messageId
            let isResult = messageFacts.isSubAgentResult
            let isLast = index == lastVisibleIndex
            let isStreaming = eventForRows == .assistantStreamDelta && isLast && messageFacts.rawRole == MessageRole.assistant
            let hasEverStreamed = !isResult && (isStreaming || streamedMessageIDs.contains(messageId))
            let canAnimateInsertion = (eventForRows == .toolResultAppended && isResult) ||
                (eventForRows == .userMessageAppended && isLast && messageFacts.rawRole == MessageRole.user && !isResult)
            let plannerContinuation = messageFacts.rawRole == MessageRole.assistant && previousVisibleWasRawAssistant
            previousVisibleWasRawAssistant = messageFacts.rawRole == MessageRole.assistant

            let entryContinuation: Bool
            if messageFacts.effectiveRole == MessageRole.assistant {
                entryContinuation = hasVisibleAssistantInTurn
                if !messageFacts.isGlobalStatusOnly {
                    hasVisibleAssistantInTurn = true
                }
            } else {
                entryContinuation = false
                hasVisibleAssistantInTurn = false
            }

            if index < commonUnchangedPrefixCount,
               let old = oldEntriesByIndex[index],
               old.messageId == messageId,
               !old.isLastMessage,
               !isLast,
               !old.isStreaming,
               !isStreaming,
               !old.canAnimateInsertion,
               !canAnimateInsertion,
               old.hasEverStreamed == hasEverStreamed,
               old.isAssistantContinuation == entryContinuation,
               old.isTaskLive == liveTaskTailIDs.contains(messageId) {
                var reused = old
                reused.renderDigest = old.baseRenderDigest ?? old.renderDigest
                reused.baseRenderDigest = nil
                reused.phoneToolGroup = nil
                reused.assistantTurn = nil
                entries.append(reused)
                continue
            }

            let plannerRow = ChatMessageRowModel(
                rowId: messageId,
                messageId: messageId,
                message: message,
                role: messageFacts.effectiveRole,
                parts: messageFacts.parts,
                index: index,
                isLast: isLast,
                isStreaming: isStreaming,
                hasEverStreamed: hasEverStreamed,
                canAnimateInsertion: canAnimateInsertion,
                isAssistantContinuation: plannerContinuation
            )
            var chatEntry = ChatTimelinePlanner.messageEntry(
                for: plannerRow,
                partTokensBody: messageFacts.partTokensBody
            )
            chatEntry.isAssistantContinuation = entryContinuation

            let projected = nativeMessageEntry(
                for: chatEntry,
                parts: messageFacts.parts,
                facts: messageFacts,
                isGenerationActive: isGenerationActive,
                viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision,
                reasoningLevelLabel: reasoningLevelLabel,
                renderStateStore: renderStateStore,
                variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider,
                liveTaskTailIDs: liveTaskTailIDs
            )
            entries.append(projected)
        }

        if shouldIncludePendingAssistant {
            entries.append(nativeEntry(for: .pendingAssistant(id: ChatTimelinePlanner.pendingAssistantID)))
        }
        appendTailDecorations(
            into: &entries,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState
        )

        ChatPhoneToolGrouping.annotate(
            &entries,
            messages: messages,
            expandedGroupIDs: expandedPhoneToolGroupIDs,
            isGenerationActive: isGenerationActive,
            fromEntryIndex: splitEntryIndex,
            factsByObjectID: factsByObjectID
        )

        let latestRenderToken: String
        if let lastMessageEntry = entries.last(where: { $0.kind == .message }),
           let lastID = lastMessageEntry.messageId {
            latestRenderToken = "\(visibleMessageCount):\(lastID):\(lastMessageEntry.renderToken):\(shouldIncludePendingAssistant)"
        } else {
            latestRenderToken = shouldIncludePendingAssistant ? "empty:pending" : "empty"
        }
        return NativeTimelineProjection(entries: entries, latestRenderToken: latestRenderToken)
    }

    private static func appendTailDecorations(
        into entries: inout [NativeTimelineEntry],
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState
    ) {
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
        entries.append(nativeEntry(for: .bottomAnchor(id: ChatTimelinePlanner.bottomAnchorID)))
    }

    private static func nativeMessageEntry(
        for message: ChatTimelineMessageEntry,
        parts: [UIMessagePart],
        facts: NativeTimelineMessageFacts,
        isGenerationActive: Bool = false,
        viewportState: ChatViewportState = ChatViewportState(),
        displaySettingSignature: Int = 0,
        generativeUiSettingSignature: Int = 0,
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        renderStateStore: ChatRenderStateStore? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        liveTaskTailIDs: Set<String> = []
    ) -> NativeTimelineEntry {
        let row = ChatMessageRowModel(
            rowId: message.messageId,
            messageId: message.messageId,
            message: message.message,
            role: message.role,
            parts: parts,
            index: message.index,
            isLast: message.isLast,
            isStreaming: message.isStreaming,
            hasEverStreamed: message.hasEverStreamed,
            canAnimateInsertion: message.canAnimateInsertion,
            isAssistantContinuation: message.isAssistantContinuation
        )
        let isTaskLive = liveTaskTailIDs.contains(message.messageId)
        let renderState = renderStateStore?.stateForEntry(
            message,
            isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom,
            isLiveTask: isTaskLive
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
            generativeUiSettingSignature: generativeUiSettingSignature,
            hasMultipleVariants: variantInfo?.hasMultipleVariants == true,
            reasoningLevelLabel: reasoningLevelLabel,
            renderStateRevision: row.isLast && row.role == MessageRole.assistant && renderState.hasEverStreamed
                ? renderStateRevision : 0
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
            isAssistantContinuation: row.isAssistantContinuation,
            isGlobalStatusOnly: facts.isGlobalStatusOnly,
            isTaskLive: isTaskLive,
            contentObservesGenerationState: facts.contentObservesGenerationState,
            contentHasVisibleBodyText: facts.contentHasVisibleBodyText
        )
    }

    private static func nativeEntry(
        for entry: ChatTimelineEntry,
        isGenerationActive: Bool = false,
        viewportState: ChatViewportState = ChatViewportState(),
        displaySettingSignature: Int = 0,
        generativeUiSettingSignature: Int = 0,
        renderStateRevision: UInt64 = 0,
        reasoningLevelLabel: String? = nil,
        renderStateStore: ChatRenderStateStore? = nil,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo? = { _ in nil },
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int = { _, _ in 0 },
        liveTaskTailIDs: Set<String> = []
    ) -> NativeTimelineEntry {
        switch entry {
        case let .message(message):
            let facts = NativeTimelineMessageFacts(message: message.message, index: message.index)
            return nativeMessageEntry(
                for: message,
                parts: facts.parts,
                facts: facts,
                isGenerationActive: isGenerationActive,
                viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision,
                reasoningLevelLabel: reasoningLevelLabel,
                renderStateStore: renderStateStore,
                variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider,
                liveTaskTailIDs: liveTaskTailIDs
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

    static func hasVisibleAssistantBefore(
        index: Int,
        in messages: [UIMessage],
        factsAt: ((Int) -> NativeTimelineMessageFacts)? = nil
    ) -> Bool {
        guard index > 0 else { return false }
        if let factsAt {
            for prevIndex in (0 ..< index).reversed() {
                let prev = factsAt(prevIndex)
                guard prev.isVisibleInTimeline else { continue }
                guard prev.rawRole == MessageRole.assistant else { return false }
                if !prev.isGlobalStatusOnly { return true }
            }
            return false
        }
        for previous in messages[..<index].reversed() where ChatMessageProjector.isVisibleInTimeline(previous) {
            guard previous.role == MessageRole.assistant else { return false }
            if !isGlobalStatusOnly(previous) { return true }
        }
        return false
    }

    static func isGlobalStatusOnly(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.assistant, message.annotations.isEmpty else { return false }
        if message.parts.count == 1, let text = message.parts.first as? UIMessagePart.Text,
           text.text == ChatViewModel.queuedTaskPlaceholderText { return true }
        return message.parts.allSatisfy { part in
            if let text = part as? UIMessagePart.Text {
                return text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if part is UIMessagePart.Reasoning { return true }
            if let tool = part as? UIMessagePart.Tool { return !ChatTaskStreamGrouping.isMediaBearing(tool) }
            return false
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

