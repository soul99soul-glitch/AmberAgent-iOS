import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine
import SwiftStreamingMarkdown

struct ChatSwiftUIMessageBubble: View, @MainActor Equatable {
    let entryID: String
    let renderDigest: ChatRowDigest
    let updatesSuspended: Bool
    let row: ChatMessageRowModel
    let variantInfo: IOSConversationStore.VariantInfo?
    let renderState: ChatRenderState
    let isGenerationActive: Bool
    let displaySetting: DisplaySetting
    let generativeUiSetting: GenerativeUiSetting
    let reasoningLevelLabel: String?
    let onAction: (ChatListAction) -> Void

    var body: some View {
        MessageBubbleView(
            message: row.message,
            messageIndex: row.index,
            isAssistantContinuation: row.isAssistantContinuation,
            variantInfo: variantInfo,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            onRegenerate: { onAction(.regenerate(messageId: row.messageId)) },
            onRequestEdit: { currentText in
                onAction(.requestEdit(messageId: row.messageId, currentText: currentText))
            },
            onEdit: { newText in onAction(.edit(messageId: row.messageId, newText: newText)) },
            onDelete: { onAction(.delete(messageId: row.messageId)) },
            onSelectVariant: { variantIndex in
                onAction(.selectVariant(messageId: row.messageId, variantIndex: variantIndex))
            },
            onGenerativeWidgetAction: { prompt in onAction(.generativeWidget(prompt: prompt)) },
            onModifyGeneratedImage: { imageURL, prompt, aspectRatio in
                onAction(.modifyGeneratedImage(urlString: imageURL, prompt: prompt, aspectRatio: aspectRatio))
            },
            onOpenMiniApp: { appId in onAction(.openMiniApp(appId: appId)) },
            onOpenMiniApps: { onAction(.openMiniApps) },
            onOpenSubagentConversation: { onAction(.openSubagentConversation(id: $0)) },
            isGenerating: row.isLast && isGenerationActive,
            isChatGenerationActive: isGenerationActive,
            isLastMessage: row.isLast,
            hasEverStreamed: renderState.hasEverStreamed,
            liveMarkdownRenderingEnabled: renderState.liveRenderingEnabled,
            frozenMarkdownSnapshot: renderState.frozenMarkdownSnapshot,
            reasoningLevelLabel: reasoningLevelLabel
        )
    }

    static func == (lhs: ChatSwiftUIMessageBubble, rhs: ChatSwiftUIMessageBubble) -> Bool {
        guard lhs.entryID == rhs.entryID,
              lhs.row.isAssistantContinuation == rhs.row.isAssistantContinuation,
              lhs.updatesSuspended == rhs.updatesSuspended else { return false }
        if lhs.updatesSuspended {
            return true
        }
        return lhs.row.messageId == rhs.row.messageId &&
            lhs.row.role == rhs.row.role &&
            lhs.row.index == rhs.row.index &&
            (lhs.row.isLast && lhs.isGenerationActive) == (rhs.row.isLast && rhs.isGenerationActive) &&
            lhs.row.hasEverStreamed == rhs.row.hasEverStreamed &&
            lhs.row.canAnimateInsertion == rhs.row.canAnimateInsertion &&
            lhs.variantInfo == rhs.variantInfo &&
            lhs.renderState == rhs.renderState &&
            lhs.renderDigest == rhs.renderDigest &&
            lhs.isGenerationActive == rhs.isGenerationActive
    }
}

struct ChatListMessageRenderModel {
    let row: ChatMessageRowModel
    let variantInfo: IOSConversationStore.VariantInfo?
    let renderState: ChatRenderState
    let isGenerationActive: Bool
    let renderIdentity: String
    let liveTailModel: ChatLiveTailModel?
    /// Set only on a phone-step group's head row.
    var phoneToolGroup: ChatPhoneToolGroupSummary? = nil
    var assistantTurn: ChatAssistantTurnRole? = nil
    var isTaskLive = false
    var usesIndependentTasks = false
    var contentObservesGenerationState = false
}

struct NativeTimelineMessageBubble: View, @MainActor Equatable {
    let entryID: String
    let renderDigest: ChatRowDigest?
    let model: ChatListMessageRenderModel
    let displaySetting: DisplaySetting
    let generativeUiSetting: GenerativeUiSetting
    let displaySettingSignature: Int
    let generativeUiSettingSignature: Int
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let onAction: (ChatListAction) -> Void

    private var rowLayoutSignature: Int {
        var hasher = Hasher()
        hasher.combine(model.renderIdentity)
        hasher.combine(model.phoneToolGroup?.signature)
        hasher.combine(model.variantInfo?.selectedIndex)
        hasher.combine(model.variantInfo?.variantCount)
        hasher.combine(displaySettingSignature)
        hasher.combine(generativeUiSettingSignature)
        return hasher.finalize()
    }

    var body: some View {
        let _ = ChatRenderProbe.record("row", id: model.row.messageId)
        ChatTimelineRowLayout(
            messageID: model.row.messageId,
            tracksRowInvalidation: true,
            layoutSignature: rowLayoutSignature
        ) {
            ChatMessageHostedBubble(
                model: model,
                displaySetting: displaySetting,
                generativeUiSetting: generativeUiSetting,
                reasoningLevelLabel: reasoningLevelLabel,
                imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
                onAction: onAction
            )
            .environment(\.markdownLayoutInvalidationID, model.row.messageId)
            .id(model.renderIdentity)
        }
    }

    static func == (lhs: NativeTimelineMessageBubble, rhs: NativeTimelineMessageBubble) -> Bool {
        ChatRenderProbe.record("row-compare", id: lhs.model.row.messageId)
        guard lhs.entryID == rhs.entryID,
              lhs.model.row.messageId == rhs.model.row.messageId,
              lhs.model.row.role == rhs.model.row.role,
              lhs.model.row.index == rhs.model.row.index,
              lhs.model.row.isAssistantContinuation == rhs.model.row.isAssistantContinuation,
              lhs.model.row.hasEverStreamed == rhs.model.row.hasEverStreamed,
              lhs.model.row.canAnimateInsertion == rhs.model.row.canAnimateInsertion,
              lhs.model.variantInfo == rhs.model.variantInfo,
              lhs.model.renderIdentity == rhs.model.renderIdentity,
              lhs.model.phoneToolGroup?.signature == rhs.model.phoneToolGroup?.signature,
              lhs.model.assistantTurn == rhs.model.assistantTurn,
              lhs.model.isTaskLive == rhs.model.isTaskLive,
              lhs.effectiveIsGenerating == rhs.effectiveIsGenerating,
              lhs.displaySettingSignature == rhs.displaySettingSignature,
              lhs.generativeUiSettingSignature == rhs.generativeUiSettingSignature,
              lhs.imageAccessibilityFocusToolCallID == rhs.imageAccessibilityFocusToolCallID
        else {
            #if DEBUG
            ChatRenderProbe.recordRowDifferences(lhs, rhs)
            #endif
            return false
        }

        if lhs.usesLiveTail && rhs.usesLiveTail {
            return lhs.model.liveTailModel === rhs.model.liveTailModel &&
                lhs.reasoningLevelLabel == rhs.reasoningLevelLabel
        }

        // Settled tail -> history transition (`isLast: true -> false` on send/append):
        // keep the already-mounted body & Markdown subtree untouched when neither side
        // is generating/streaming and the underlying message + frozen snapshot match.
        if lhs.model.row.isLast != rhs.model.row.isLast {
            let lhsHasMeta = ChatMessageContentIdentity.containsNonNilMetadata(in: lhs.model.row.parts)
            let rhsHasMeta = ChatMessageContentIdentity.containsNonNilMetadata(in: rhs.model.row.parts)
            let samePartMetadata = (!lhsHasMeta && !rhsHasMeta) || ChatMessageContentIdentity.sameMetadata(
                ChatMessageContentIdentity.metadata(in: lhs.model.row.parts),
                ChatMessageContentIdentity.metadata(in: rhs.model.row.parts)
            )
            let settledTransition = !lhs.effectiveIsGenerating &&
                !rhs.effectiveIsGenerating &&
                !rhs.model.row.isStreaming &&
                (!lhs.model.row.isStreaming || lhs.usesLiveTail) &&
                lhs.effectiveMessage === rhs.effectiveMessage &&
                samePartMetadata &&
                lhs.effectiveRenderState.hasEverStreamed == rhs.effectiveRenderState.hasEverStreamed &&
                lhs.effectiveRenderState.frozenMarkdownSnapshot == rhs.effectiveRenderState.frozenMarkdownSnapshot &&
                lhs.reasoningLevelLabel == rhs.reasoningLevelLabel &&
                (!(lhs.model.contentObservesGenerationState || rhs.model.contentObservesGenerationState) ||
                    lhs.effectiveIsGenerationActive == rhs.effectiveIsGenerationActive)
            #if DEBUG
            if !settledTransition { ChatRenderProbe.recordRowDifferences(lhs, rhs) }
            #endif
            return settledTransition
        }

        if lhs.usesLiveTail || rhs.usesLiveTail {
            return lhs.model.liveTailModel === rhs.model.liveTailModel &&
                lhs.reasoningLevelLabel == rhs.reasoningLevelLabel
        }

        let equal = lhs.model.renderState == rhs.model.renderState &&
            lhs.renderDigest == rhs.renderDigest &&
            lhs.model.isGenerationActive == rhs.model.isGenerationActive &&
            lhs.reasoningLevelLabel == rhs.reasoningLevelLabel
        #if DEBUG
        if !equal { ChatRenderProbe.recordRowDifferences(lhs, rhs) }
        #endif
        return equal
    }

    private var usesLiveTail: Bool {
        model.row.isLast && model.liveTailModel != nil && model.renderState.liveRenderingEnabled
    }

    private var effectiveMessage: UIMessage {
        (model.row.isLast ? model.liveTailModel?.message : nil) ?? model.row.message
    }

    private var effectiveIsGenerationActive: Bool {
        (model.row.isLast ? model.liveTailModel?.isGenerationActive : nil) ?? model.isGenerationActive
    }

    private var effectiveRenderState: ChatRenderState {
        (model.row.isLast ? model.liveTailModel?.renderState : nil) ?? model.renderState
    }

    private var effectiveIsGenerating: Bool {
        (model.isTaskLive || (model.row.isLast && !model.usesIndependentTasks)) && effectiveIsGenerationActive
    }
}

private struct ChatMessageHostedBubble: View {
    let model: ChatListMessageRenderModel
    let displaySetting: DisplaySetting
    let generativeUiSetting: GenerativeUiSetting
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let onAction: (ChatListAction) -> Void

    var body: some View {
        let _ = ChatRenderProbe.record("hosted", id: model.row.messageId)
        if let liveTailModel = model.liveTailModel {
            ChatLiveTailBubble(
                model: model,
                liveTailModel: liveTailModel,
                displaySetting: displaySetting,
                generativeUiSetting: generativeUiSetting,
                reasoningLevelLabel: reasoningLevelLabel,
                imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
                onAction: onAction
            )
        } else {
            messageBubble(
                message: model.row.message,
                isGenerationActive: model.isGenerationActive,
                renderState: model.renderState
            )
        }
    }

    @ViewBuilder
    fileprivate func messageBubble(
        message: UIMessage,
        isGenerationActive: Bool,
        renderState: ChatRenderState
    ) -> some View {
        MessageBubbleView(
            message: message,
            messageIndex: model.row.index,
            isAssistantContinuation: model.row.isAssistantContinuation,
            variantInfo: model.variantInfo,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            onRegenerate: { onAction(.regenerate(messageId: model.row.messageId)) },
            onRequestEdit: { currentText in
                onAction(.requestEdit(messageId: model.row.messageId, currentText: currentText))
            },
            onEdit: { newText in onAction(.edit(messageId: model.row.messageId, newText: newText)) },
            onDelete: { onAction(.delete(messageId: model.row.messageId)) },
            onSelectVariant: { variantIndex in
                onAction(.selectVariant(messageId: model.row.messageId, variantIndex: variantIndex))
            },
            onGenerativeWidgetAction: { prompt in onAction(.generativeWidget(prompt: prompt)) },
            onModifyGeneratedImage: { imageURL, prompt, aspectRatio in
                onAction(.modifyGeneratedImage(urlString: imageURL, prompt: prompt, aspectRatio: aspectRatio))
            },
            onOpenMiniApp: { appId in onAction(.openMiniApp(appId: appId)) },
            onOpenMiniApps: { onAction(.openMiniApps) },
            onOpenSubagentConversation: { onAction(.openSubagentConversation(id: $0)) },
            isGenerating: (model.isTaskLive || (model.row.isLast && !model.usesIndependentTasks)) && isGenerationActive,
            isChatGenerationActive: isGenerationActive,
            isLastMessage: model.row.isLast || model.isTaskLive,
            hasEverStreamed: renderState.hasEverStreamed,
            liveMarkdownRenderingEnabled: renderState.liveRenderingEnabled,
            frozenMarkdownSnapshot: renderState.frozenMarkdownSnapshot,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            phoneToolGroup: model.phoneToolGroup,
            assistantTurn: model.assistantTurn
        )
    }
}

private struct ChatLiveTailBubble: View {
    let model: ChatListMessageRenderModel
    @ObservedObject var liveTailModel: ChatLiveTailModel
    let displaySetting: DisplaySetting
    let generativeUiSetting: GenerativeUiSetting
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let onAction: (ChatListAction) -> Void

    var body: some View {
        let _ = ChatRenderProbe.record("live-tail", id: model.row.messageId)
        ChatMessageHostedBubble(
            model: model,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            onAction: onAction
        )
        .messageBubble(
            message: model.row.isLast ? liveTailModel.message : model.row.message,
            isGenerationActive: model.row.isLast ? liveTailModel.isGenerationActive : model.isGenerationActive,
            renderState: model.row.isLast ? liveTailModel.renderState : model.renderState
        )
    }
}

