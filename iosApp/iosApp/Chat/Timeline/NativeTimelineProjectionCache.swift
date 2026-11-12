import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

@MainActor
final class NativeTimelineProjectionCache {
    private var cachedProjection: NativeTimelineProjection?
    private var structuralKey: Int?
    private var cachedBaseConfigKey: Int?
    let settings = NativeTimelineSettingsCache()
    private var messageCount = 0
    var cachedMessageCount: Int { messageCount }
    private var lastMessageID: String?
    private var sourceRevision: Int?
    private var renderRevision: UInt64 = 0
    private var startIndex = 0
    private var sourceMessages: [UIMessage] = []
    private var orderedFacts: [NativeTimelineMessageFacts] = []
    private var factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts] = [:]
    private var compactBoundaries: [ChatContextCompactBoundary] = []
    private var liveTaskTailIDs: Set<String> = []
    private var cachedStreamedMessageIDs: Set<String> = []
    private var cachedEvent: ChatEvent?
    private var cachedIsGenerationActive = false
    private(set) var lastResetRevision: Int?

    /// Called by the message-event owner, before publishing any render signal.
    /// Reuse the existing facts/identity cache; body-side projection only reads prepared text.
    func prepareDisplayTexts(messages: [UIMessage]) {
        var prepared: [ObjectIdentifier: NativeTimelineMessageFacts] = [:]
        for (index, message) in messages.enumerated() {
            ChatRenderProbe.record("display-facts:visit")
            let key = ObjectIdentifier(message)
            if let cached = factsByObjectID[key], cached.hasPreparedDisplayTexts, cached.identity.matches(message) {
                prepared[key] = cached
            } else {
                prepared[key] = NativeTimelineMessageFacts(
                    message: message, identity: ChatMessageContentIdentity(message, index: index),
                    displayTexts: IOSSubAgentOutputProjection.displayTexts(in: message)
                )
            }
        }
        factsByObjectID = prepared
    }

    func prepareTailDisplayTexts(_ message: UIMessage, replacing previous: UIMessage) {
        ChatRenderProbe.record("display-facts:visit")
        factsByObjectID.removeValue(forKey: ObjectIdentifier(previous))
        factsByObjectID[ObjectIdentifier(message)] = NativeTimelineMessageFacts(
            message: message, identity: ChatMessageContentIdentity(message),
            displayTexts: IOSSubAgentOutputProjection.displayTexts(in: message)
        )
    }

    func displayTexts(for message: UIMessage) -> [Int: String] {
        guard let facts = factsByObjectID[ObjectIdentifier(message)], facts.identity.matches(message) else {
            return IOSSubAgentOutputProjection.unpreparedDisplayTexts(in: message)
        }
        return facts.displayTexts
    }

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
        displaySettingSignature: Int,
        generativeUiSettingSignature: Int,
        renderStateRevision: UInt64,
        reasoningLevelLabel: String?,
        streamedMessageIDs: Set<String>,
        liveTaskTailIDs: Set<String> = [],
        renderStateStore: ChatRenderStateStore,
        variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?,
        expandedPhoneToolGroupIDs: Set<String> = [],
        contentHashProvider: (ChatMessageRowModel, Bool) -> Int
    ) -> NativeTimelineProjection {
        let lastID: String? = {
            guard let last = messages.last else { return nil }
            if let cached = factsByObjectID[ObjectIdentifier(last)] {
                return cached.messageId
            }
            return ChatMessageProjector.messageId(for: last)
        }()
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
        let baseConfigKey = Self.baseConfigKey(
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs,
            configurationIssue: configurationIssue,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState,
            contextCompactBoundaries: contextCompactBoundaries,
            viewportFarFromBottom: viewportState.liveRenderingFarFromBottom,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: generativeUiSettingSignature,
            renderStateRevision: renderStateRevision,
            reasoningLevelLabel: reasoningLevelLabel,
            startIndex: startIndex,
            liveTaskTailIDs: liveTaskTailIDs,
            renderStateStore: renderStateStore
        )

        let canReuseStructure = key == structuralKey &&
            baseConfigKey == cachedBaseConfigKey &&
            messageCount == messages.count && lastMessageID == lastID &&
            self.startIndex == startIndex && compactBoundaries == contextCompactBoundaries &&
            self.liveTaskTailIDs == liveTaskTailIDs

        if canReuseStructure,
           self.sourceRevision == sourceRevision,
           renderRevision == renderStateRevision,
           cachedStreamedMessageIDs == streamedMessageIDs,
           let cachedProjection {
            return cachedProjection
        }

        if canReuseStructure,
           event == .assistantStreamDelta,
           let cachedProjection,
           streamingHistoryIsUnchanged(messages: messages),
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
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs,
            liveTaskTailIDs: liveTaskTailIDs,
            factsByObjectID: factsByObjectID
           ) {
            if let tail = messages.last {
                let tailFacts = factsByObjectID[ObjectIdentifier(tail)] ?? NativeTimelineMessageFacts(message: tail, index: messages.count - 1)
                if orderedFacts.count == messages.count {
                    orderedFacts[messages.count - 1] = tailFacts
                }
                factsByObjectID[ObjectIdentifier(tail)] = tailFacts
            }
            recordState(
                projection: increment,
                messages: messages,
                lastID: lastID,
                structuralKey: key,
                baseConfigKey: baseConfigKey,
                sourceRevision: sourceRevision,
                renderStateRevision: renderStateRevision,
                startIndex: startIndex,
                compactBoundaries: contextCompactBoundaries,
                liveTaskTailIDs: liveTaskTailIDs,
                streamedMessageIDs: streamedMessageIDs,
                event: event,
                isGenerationActive: isGenerationActive
            )
            return increment
        }

        let (
            nextOrderedFacts,
            nextFactsByObjectID,
            commonUnchangedPrefixCount,
            unchangedFlags
        ) = resolveFacts(
            for: messages,
            startIndex: startIndex,
            hasCompactBoundaries: !contextCompactBoundaries.isEmpty,
            canReuseStructure: canReuseStructure
        )

        // Tool callbacks may replace any assistant message, including a historical
        // one. Reuse only after checking the complete source shape and the loaded
        // rows' mutable metadata; never assume that a tool result belongs to the tail.
        if canReuseStructure, renderRevision == renderStateRevision,
           sourceMessages.count == messages.count,
           zip(orderedFacts, nextOrderedFacts).allSatisfy({ old, new in
               old.identity.message === new.identity.message ||
                   (old.messageId == new.messageId &&
                    old.rawRole == MessageRole.assistant &&
                    new.rawRole == old.rawRole)
           }),
           let cachedProjection {
            var unchangedMessageIDs = Set<String>()
            unchangedMessageIDs.reserveCapacity(messages.count)
            for index in messages.indices where index < orderedFacts.count && unchangedFlags[index] {
                unchangedMessageIDs.insert(orderedFacts[index].messageId)
            }
            if let increment = NativeTimelineProjector.replacingToolMessages(
                in: cachedProjection, messages: messages, event: event, startIndex: startIndex,
                unchangedMessageIDs: unchangedMessageIDs,
                isGenerationActive: isGenerationActive, viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision, reasoningLevelLabel: reasoningLevelLabel,
                streamedMessageIDs: streamedMessageIDs, renderStateStore: renderStateStore,
                variantInfoProvider: variantInfoProvider, contentHashProvider: contentHashProvider,
                expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs,
                liveTaskTailIDs: liveTaskTailIDs,
                factsByObjectID: nextFactsByObjectID
            ) {
                self.orderedFacts = nextOrderedFacts
                self.factsByObjectID = nextFactsByObjectID
                recordState(
                    projection: increment,
                    messages: messages,
                    lastID: lastID,
                    structuralKey: key,
                    baseConfigKey: baseConfigKey,
                    sourceRevision: sourceRevision,
                    renderStateRevision: renderStateRevision,
                    startIndex: startIndex,
                    compactBoundaries: contextCompactBoundaries,
                    liveTaskTailIDs: liveTaskTailIDs,
                    streamedMessageIDs: streamedMessageIDs,
                    event: event,
                    isGenerationActive: isGenerationActive
                )
                return increment
            }
        }

        // Incremental prefix reuse across structural appends, user sends, stream starts,
        // and generation completion: slice unchanged history before the active turn's
        // breaking user message and project only the tail turn.
        if baseConfigKey == cachedBaseConfigKey,
           contextCompactBoundaries.isEmpty,
           !sourceMessages.isEmpty,
           !messages.isEmpty,
           commonUnchangedPrefixCount > max(0, startIndex),
           let cachedProjection,
           let (splitEntryIndex, splitMessageIndex) = findIncrementalSplitPoint(
               in: cachedProjection,
               commonUnchangedPrefixCount: commonUnchangedPrefixCount,
               startIndex: startIndex,
               event: event,
               isGenerationActive: isGenerationActive,
               streamedMessageIDs: streamedMessageIDs
           ) {
            let increment = NativeTimelineProjector.projectingIncrementalTail(
                from: cachedProjection,
                splitEntryIndex: splitEntryIndex,
                splitMessageIndex: splitMessageIndex,
                commonUnchangedPrefixCount: commonUnchangedPrefixCount,
                messages: messages,
                orderedFacts: nextOrderedFacts,
                factsByObjectID: nextFactsByObjectID,
                event: event,
                isGenerationActive: isGenerationActive,
                isRecognizingImages: isRecognizingImages,
                contextCompactState: contextCompactState,
                viewportState: viewportState,
                displaySettingSignature: displaySettingSignature,
                generativeUiSettingSignature: generativeUiSettingSignature,
                renderStateRevision: renderStateRevision,
                reasoningLevelLabel: reasoningLevelLabel,
                streamedMessageIDs: streamedMessageIDs,
                liveTaskTailIDs: liveTaskTailIDs,
                renderStateStore: renderStateStore,
                variantInfoProvider: variantInfoProvider,
                contentHashProvider: contentHashProvider,
                expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs
            )
            self.orderedFacts = nextOrderedFacts
            self.factsByObjectID = nextFactsByObjectID
            recordState(
                projection: increment,
                messages: messages,
                lastID: lastID,
                structuralKey: key,
                baseConfigKey: baseConfigKey,
                sourceRevision: sourceRevision,
                renderStateRevision: renderStateRevision,
                startIndex: startIndex,
                compactBoundaries: contextCompactBoundaries,
                liveTaskTailIDs: liveTaskTailIDs,
                streamedMessageIDs: streamedMessageIDs,
                event: event,
                isGenerationActive: isGenerationActive
            )
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
            liveTaskTailIDs: liveTaskTailIDs,
            renderStateStore: renderStateStore,
            variantInfoProvider: variantInfoProvider,
            contentHashProvider: contentHashProvider,
            startIndex: startIndex,
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs,
            factsByObjectID: nextFactsByObjectID
        )
        self.orderedFacts = nextOrderedFacts
        self.factsByObjectID = nextFactsByObjectID
        recordState(
            projection: projection,
            messages: messages,
            lastID: lastID,
            structuralKey: key,
            baseConfigKey: baseConfigKey,
            sourceRevision: sourceRevision,
            renderStateRevision: renderStateRevision,
            startIndex: startIndex,
            compactBoundaries: contextCompactBoundaries,
            liveTaskTailIDs: liveTaskTailIDs,
            streamedMessageIDs: streamedMessageIDs,
            event: event,
            isGenerationActive: isGenerationActive
        )
        return projection
    }

    private func recordState(
        projection: NativeTimelineProjection,
        messages: [UIMessage],
        lastID: String?,
        structuralKey: Int,
        baseConfigKey: Int,
        sourceRevision: Int,
        renderStateRevision: UInt64,
        startIndex: Int,
        compactBoundaries: [ChatContextCompactBoundary],
        liveTaskTailIDs: Set<String>,
        streamedMessageIDs: Set<String>,
        event: ChatEvent,
        isGenerationActive: Bool
    ) {
        self.cachedProjection = projection
        self.structuralKey = structuralKey
        self.cachedBaseConfigKey = baseConfigKey
        self.messageCount = messages.count
        self.lastMessageID = lastID
        self.sourceRevision = sourceRevision
        self.renderRevision = renderStateRevision
        self.startIndex = startIndex
        self.sourceMessages = messages
        self.compactBoundaries = compactBoundaries
        self.liveTaskTailIDs = liveTaskTailIDs
        self.cachedStreamedMessageIDs = streamedMessageIDs
        self.cachedEvent = event
        self.cachedIsGenerationActive = isGenerationActive
    }

    private func resolveFacts(
        for messages: [UIMessage],
        startIndex: Int,
        hasCompactBoundaries: Bool,
        canReuseStructure: Bool
    ) -> ([NativeTimelineMessageFacts], [ObjectIdentifier: NativeTimelineMessageFacts], Int, [Bool]) {
        var nextOrdered: [NativeTimelineMessageFacts] = []
        nextOrdered.reserveCapacity(messages.count)
        var nextByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts] = [:]
        nextByObjectID.reserveCapacity(messages.count)
        var unchangedFlags: [Bool] = []
        unchangedFlags.reserveCapacity(messages.count)

        let sharedCount = min(sourceMessages.count, messages.count)
        let isPureAppend = !canReuseStructure && messages.count > sourceMessages.count
        let lazyMetadataCutoff: Int
        if !hasCompactBoundaries,
           self.compactBoundaries.isEmpty,
           self.startIndex == startIndex,
           isPureAppend || startIndex > 0 {
            let upper = isPureAppend
                ? min(orderedFacts.count, sharedCount)
                : min(startIndex, min(orderedFacts.count, sharedCount))
            var foundCutoff = 0
            if upper > 0 {
                for idx in stride(from: upper - 1, through: 0, by: -1) {
                    let fact = orderedFacts[idx]
                    if sourceMessages[idx] === messages[idx],
                       fact.isVisibleInTimeline,
                       fact.rawRole == MessageRole.user,
                       !fact.isSubAgentResult {
                        foundCutoff = idx
                        break
                    }
                }
            }
            lazyMetadataCutoff = foundCutoff
        } else {
            lazyMetadataCutoff = 0
        }

        var commonPrefixCount = 0
        var prefixBroken = false

        for (index, message) in messages.enumerated() {
            let key = ObjectIdentifier(message)
            let resolved: NativeTimelineMessageFacts
            if index < lazyMetadataCutoff,
               !prefixBroken,
               sourceMessages[index] === message {
                resolved = orderedFacts[index]
                unchangedFlags.append(true)
                commonPrefixCount = index + 1
            } else if index < orderedFacts.count,
               sourceMessages[index] === message,
               orderedFacts[index].identity.matches(message) {
                resolved = orderedFacts[index]
                unchangedFlags.append(true)
                if !prefixBroken && index < sharedCount {
                    commonPrefixCount = index + 1
                }
            } else {
                prefixBroken = true
                unchangedFlags.append(false)
                if let cached = factsByObjectID[key], cached.identity.matches(message) {
                    resolved = cached
                } else {
                    resolved = NativeTimelineMessageFacts(message: message, index: index)
                }
            }
            nextOrdered.append(resolved)
            nextByObjectID[key] = resolved
        }
        return (nextOrdered, nextByObjectID, commonPrefixCount, unchangedFlags)
    }

    private func findIncrementalSplitPoint(
        in projection: NativeTimelineProjection,
        commonUnchangedPrefixCount: Int,
        startIndex: Int,
        event: ChatEvent,
        isGenerationActive: Bool,
        streamedMessageIDs: Set<String>
    ) -> (entryIndex: Int, messageIndex: Int)? {
        let clampedStart = max(0, startIndex)
        var candidateEntryIndex: Int?
        var candidateMessageIndex: Int?
        for entryIndex in projection.entries.indices.reversed() {
            let entry = projection.entries[entryIndex]
            guard entry.kind == .message,
                  let msgIndex = entry.index,
                  msgIndex < commonUnchangedPrefixCount,
                  msgIndex >= clampedStart else { continue }
            // `entry.role == .user` already excludes subagent result rows (which project as `.assistant`).
            if entry.role == MessageRole.user, !entry.isLastMessage, !entry.canAnimateInsertion {
                candidateEntryIndex = entryIndex
                candidateMessageIndex = msgIndex
                break
            }
        }
        guard let splitEntryIndex = candidateEntryIndex,
              let splitMessageIndex = candidateMessageIndex,
              splitEntryIndex > 0 else { return nil }

        let changedStreamIDs = cachedStreamedMessageIDs.symmetricDifference(streamedMessageIDs)
        if !changedStreamIDs.isEmpty {
            for entry in projection.entries[0 ..< splitEntryIndex] {
                if let id = entry.messageId, changedStreamIDs.contains(id) {
                    return nil
                }
            }
        }

        if (event == .toolResultAppended) != (cachedEvent == .toolResultAppended) {
            if orderedFacts[clampedStart ..< splitMessageIndex].contains(where: \.isSubAgentResult) {
                return nil
            }
        }

        if isGenerationActive != cachedIsGenerationActive {
            for entry in projection.entries[0 ..< splitEntryIndex] {
                if case let .head(progress) = entry.assistantTurn, progress.hasPendingToolCall {
                    return nil
                }
            }
        }

        return (splitEntryIndex, splitMessageIndex)
    }

    /// Off-window prefix strictly before the paginated viewport's last preceding user boundary.
    /// Callers still enforce `===` pointer identity on every message, so any replaced message is
    /// detected in O(1) without bridging Kotlin `JsonObject` metadata on off-screen history rows.
    func streamingUnchangedHistoryMetadataCutoff(messageCount: Int) -> Int {
        guard compactBoundaries.isEmpty, startIndex > 0 else { return 0 }
        let upper = min(startIndex, min(orderedFacts.count, min(sourceMessages.count, messageCount)))
        guard upper > 0 else { return 0 }
        for idx in stride(from: upper - 1, through: 0, by: -1) {
            let fact = orderedFacts[idx]
            if fact.isVisibleInTimeline, fact.rawRole == MessageRole.user, !fact.isSubAgentResult {
                return idx
            }
        }
        return 0
    }

    private func streamingHistoryIsUnchanged(messages: [UIMessage]) -> Bool {
        // SwiftUI can coalesce tool-result and text-delta notifications into one
        // render. A final stream event does not prove that only the tail changed.
        guard sourceMessages.count == messages.count,
              orderedFacts.count == messages.count else { return false }
        let historyCount = max(0, messages.count - 1)
        let cutoff = min(streamingUnchangedHistoryMetadataCutoff(messageCount: messages.count), historyCount)
        for index in 0 ..< cutoff {
            guard sourceMessages[index] === messages[index] else { return false }
        }
        for index in cutoff ..< historyCount {
            guard sourceMessages[index] === messages[index],
                  orderedFacts[index].identity.matches(messages[index]) else { return false }
        }
        return true
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

    func reset(forRevision revision: Int? = nil, preservingPreparedFacts: Bool = false) {
        cachedProjection = nil
        structuralKey = nil
        cachedBaseConfigKey = nil
        messageCount = 0
        lastMessageID = nil
        sourceRevision = nil
        sourceMessages = []
        orderedFacts = []
        if !preservingPreparedFacts { factsByObjectID.removeAll() }
        compactBoundaries = []
        liveTaskTailIDs = []
        cachedStreamedMessageIDs.removeAll()
        cachedEvent = nil
        cachedIsGenerationActive = false
        lastResetRevision = revision
    }

    private static func baseConfigKey(
        expandedPhoneToolGroupIDs: Set<String>,
        configurationIssue: ChatConfigurationIssue?,
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState,
        contextCompactBoundaries: [ChatContextCompactBoundary],
        viewportFarFromBottom: Bool,
        displaySettingSignature: Int,
        generativeUiSettingSignature: Int,
        renderStateRevision: UInt64,
        reasoningLevelLabel: String?,
        startIndex: Int,
        liveTaskTailIDs: Set<String>,
        renderStateStore: ChatRenderStateStore
    ) -> Int {
        var key = Hasher()
        key.combine(configurationIssue?.title)
        key.combine(configurationIssue?.message)
        key.combine(isRecognizingImages)
        key.combine(String(describing: contextCompactState.status))
        key.combine(contextCompactState.updatedAt)
        key.combine(contextCompactState.summary)
        for boundary in contextCompactBoundaries {
            key.combine(boundary.id)
            key.combine(boundary.afterMessageId)
            key.combine(boundary.state.summary)
            key.combine(String(describing: boundary.state.status))
        }
        key.combine(viewportFarFromBottom)
        key.combine(displaySettingSignature)
        key.combine(generativeUiSettingSignature)
        key.combine(renderStateRevision)
        key.combine(reasoningLevelLabel)
        key.combine(expandedPhoneToolGroupIDs)
        key.combine(startIndex)
        key.combine(liveTaskTailIDs)
        key.combine(ObjectIdentifier(renderStateStore))
        key.combine(renderStateStore.stateMutationCount)
        return key.finalize()
    }

    private static func structuralKey(
        expandedPhoneToolGroupIDs: Set<String>,
        configurationIssue: ChatConfigurationIssue?,
        isGenerationActive: Bool,
        isLoading: Bool,
        isRecognizingImages: Bool,
        contextCompactState: ChatContextCompactState,
        contextCompactBoundaries: [ChatContextCompactBoundary],
        displaySettingSignature: Int,
        generativeUiSettingSignature: Int,
        reasoningLevelLabel: String?
    ) -> Int {
        var key = Hasher()
        key.combine(configurationIssue?.title)
        key.combine(configurationIssue?.message)
        key.combine(isGenerationActive)
        key.combine(isLoading)
        key.combine(isRecognizingImages)
        key.combine(String(describing: contextCompactState.status))
        key.combine(contextCompactState.updatedAt)
        key.combine(contextCompactState.summary)
        for boundary in contextCompactBoundaries {
            key.combine(boundary.id)
            key.combine(boundary.afterMessageId)
        }
        key.combine(displaySettingSignature)
        key.combine(generativeUiSettingSignature)
        key.combine(reasoningLevelLabel)
        key.combine(expandedPhoneToolGroupIDs)
        return key.finalize()
    }
}
