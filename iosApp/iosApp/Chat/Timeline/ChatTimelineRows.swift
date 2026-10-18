import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

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
            lhs.row.isLast == rhs.row.isLast &&
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
}

struct NativeTimelineMessageBubble: View, @MainActor Equatable {
    let entryID: String
    let renderDigest: ChatRowDigest?
    let model: ChatListMessageRenderModel
    let displaySetting: DisplaySetting
    let generativeUiSetting: GenerativeUiSetting
    let displaySettingSignature: String
    let generativeUiSettingSignature: String
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let onAction: (ChatListAction) -> Void

    var body: some View {
        ChatMessageHostedBubble(
            model: model,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            onAction: onAction
        )
        .id(model.renderIdentity)
    }

    static func == (lhs: NativeTimelineMessageBubble, rhs: NativeTimelineMessageBubble) -> Bool {
        guard lhs.entryID == rhs.entryID,
              lhs.model.row.messageId == rhs.model.row.messageId,
              lhs.model.row.role == rhs.model.row.role,
              lhs.model.row.index == rhs.model.row.index,
              lhs.model.row.isAssistantContinuation == rhs.model.row.isAssistantContinuation,
              lhs.model.row.isLast == rhs.model.row.isLast,
              lhs.model.row.hasEverStreamed == rhs.model.row.hasEverStreamed,
              lhs.model.row.canAnimateInsertion == rhs.model.row.canAnimateInsertion,
              lhs.model.variantInfo == rhs.model.variantInfo,
              lhs.model.renderState == rhs.model.renderState,
              lhs.model.renderIdentity == rhs.model.renderIdentity,
              lhs.model.phoneToolGroup?.signature == rhs.model.phoneToolGroup?.signature,
              lhs.imageAccessibilityFocusToolCallID == rhs.imageAccessibilityFocusToolCallID
        else { return false }

        if lhs.usesLiveTail || rhs.usesLiveTail {
            return lhs.model.liveTailModel === rhs.model.liveTailModel &&
                lhs.displaySettingSignature == rhs.displaySettingSignature &&
                lhs.generativeUiSettingSignature == rhs.generativeUiSettingSignature &&
                lhs.reasoningLevelLabel == rhs.reasoningLevelLabel
        }

        return lhs.renderDigest == rhs.renderDigest &&
            lhs.model.isGenerationActive == rhs.model.isGenerationActive
    }

    private var usesLiveTail: Bool {
        model.liveTailModel != nil && model.renderState.liveRenderingEnabled
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
            isGenerating: model.row.isLast && isGenerationActive,
            isChatGenerationActive: isGenerationActive,
            isLastMessage: model.row.isLast,
            hasEverStreamed: renderState.hasEverStreamed,
            liveMarkdownRenderingEnabled: renderState.liveRenderingEnabled,
            frozenMarkdownSnapshot: renderState.frozenMarkdownSnapshot,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            phoneToolGroup: model.phoneToolGroup
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

