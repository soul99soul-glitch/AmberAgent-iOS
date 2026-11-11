import SwiftUI
import Shared
import SwiftStreamingMarkdown

private struct IOSWorkspaceStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: IOSWorkspaceStore? = nil
}

extension EnvironmentValues {
    @MainActor
    var workspaceStore: IOSWorkspaceStore {
        get { self[IOSWorkspaceStoreEnvironmentKey.self] ?? .shared }
        set { self[IOSWorkspaceStoreEnvironmentKey.self] = newValue }
    }
}

extension View {
    @MainActor
    func environment(_ object: IOSWorkspaceStore) -> some View {
        environment(\.workspaceStore, object)
    }
}

/// Parent text/tool updates must not reconstruct every completed tool card.
/// The callback captures this row's stable State location and the same Tool.
private struct ChatToolPartRow: View, @MainActor Equatable {
    let tool: UIMessagePart.Tool
    let localeIdentifier: String
    let onTap: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tool === rhs.tool && lhs.localeIdentifier == rhs.localeIdentifier
    }

    var body: some View {
        ChatToolTimeline(steps: [ChatToolStepModel(tool: tool)], onTapStep: { _ in onTap() })
    }
}

private final class MessageBubbleActionBox {
    var onRegenerate: () -> Void = {}
    var onRequestEdit: (String) -> Void = { _ in }
    var onEdit: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onSelectVariant: (Int) -> Void = { _ in }
    var onGenerativeWidgetAction: (String) -> Void = { _ in }
    var onModifyGeneratedImage: (String, String, String) -> Void = { _, _, _ in }
    var onOpenMiniApp: (String) -> Void = { _ in }
    var onOpenMiniApps: () -> Void = {}
    var onOpenSubagentConversation: ((String) -> Void)? = nil
    var artifactPinAction: ChatArtifactPinHandler? = nil
    var workspaceStore: IOSWorkspaceStore? = nil
    var completionFeedback: ChatCompletionFeedback? = nil
}

struct MessageBubbleView: View {

    let message: UIMessage
    var displayTexts: [Int: String] = [:]
    var messageIndex: Int = 0
    var isAssistantContinuation: Bool = false
    var variantInfo: IOSConversationStore.VariantInfo? = nil
    var displaySetting: DisplaySetting? = nil
    var generativeUiSetting: GenerativeUiSetting? = nil
    // Branching actions (Android ChatService parity). Defaults are no-ops so
    // existing call sites / previews that don't supply them still compile.
    var onRegenerate: () -> Void = {}
    var onRequestEdit: (String) -> Void = { _ in }
    var onEdit: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onSelectVariant: (Int) -> Void = { _ in }
    var onGenerativeWidgetAction: (String) -> Void = { _ in }
    var onModifyGeneratedImage: (String, String, String) -> Void = { _, _, _ in }
    var onOpenMiniApp: (String) -> Void = { _ in }
    var onOpenMiniApps: () -> Void = {}
    var onOpenSubagentConversation: ((String) -> Void)? = nil
    var isGenerating: Bool = false
    /// Global chat busy flag (any in-flight generation), used by MiniApp modify gate.
    var isChatGenerationActive: Bool = false
    /// True only for the last message — gates the live "thinking" timer so a stopped/older
    /// reasoning (whose finishedAt was never set on cancel) doesn't keep counting.
    var isLastMessage: Bool = false
    /// 这条消息「曾经流式过」的记忆(来自 projection 层)。控制层用它让完成后的
    /// 可见行继续走同一套流式 renderer,避免回收后切回同步 renderer 造成行高跳变。
    var hasEverStreamed: Bool = false
    /// False only when the live assistant message is far below the current viewport.
    /// That lets the offscreen stream freeze its last rendered snapshot instead of reparsing
    /// growing Markdown/widget payloads while the user is reading history.
    var liveMarkdownRenderingEnabled: Bool = true
    /// Snapshot captured when the streaming assistant row left the viewport.
    /// When present, offscreen/frozen rows render this stable text instead of the
    /// ever-growing live message payload.
    var frozenMarkdownSnapshot: String? = nil
    /// Reasoning effort label (e.g. "Auto") shown on the thinking pill. nil hides the suffix.
    var reasoningLevelLabel: String? = nil
    /// One-shot VoiceOver focus target issued after an external image anchor scroll succeeds.
    var imageAccessibilityFocusToolCallID: String? = nil
    /// Set when this message heads a phone-automation step group (L1 projection):
    /// the group header renders first; the message's own parts render only when
    /// the group is expanded.
    var phoneToolGroup: ChatPhoneToolGroupSummary? = nil
    /// Set when this message belongs to a turn drawn as one progress line: only the
    /// head draws it, on its first task run; every other run keeps just its media.
    var assistantTurn: ChatAssistantTurnRole? = nil
    /// Set when this message heads a continuous automation process screenshot batch.
    var automationScreenshotGroup: ChatAutomationScreenshotBatchSummary? = nil

    @Environment(\.workspaceStore) private var workspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.chatMessageEditingAllowed) private var messageEditingAllowed
    @Environment(\.chatCompletionFeedback) private var completionFeedback
    @Environment(\.chatArtifactPinAction) private var artifactPinAction
    @Environment(\.chatMessageAnchorHighlighted) private var chatMessageAnchorHighlighted
    @State private var actionBox = MessageBubbleActionBox()
    private var renderPreferences: IOSChatRenderPreferences { IOSChatRenderPreferences.shared }

    var body: some View {
        let _ = {
            actionBox.onRegenerate = onRegenerate
            actionBox.onRequestEdit = onRequestEdit
            actionBox.onEdit = onEdit
            actionBox.onDelete = onDelete
            actionBox.onSelectVariant = onSelectVariant
            actionBox.onGenerativeWidgetAction = onGenerativeWidgetAction
            actionBox.onModifyGeneratedImage = onModifyGeneratedImage
            actionBox.onOpenMiniApp = onOpenMiniApp
            actionBox.onOpenMiniApps = onOpenMiniApps
            actionBox.onOpenSubagentConversation = onOpenSubagentConversation
            actionBox.artifactPinAction = artifactPinAction
            actionBox.workspaceStore = workspaceStore
            actionBox.completionFeedback = completionFeedback
        }()
        let prefs = renderPreferences
        MessageBubbleEquatableContent(
            message: message,
            displayTexts: displayTexts,
            contentIdentity: ChatMessageContentIdentity(message, index: messageIndex),
            messageIndex: messageIndex,
            isAssistantContinuation: isAssistantContinuation,
            variantInfo: variantInfo,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            displaySignature: Self.displaySignature(displaySetting, prefs: prefs),
            generativeSignature: Self.generativeSignature(generativeUiSetting),
            isGenerating: isGenerating,
            isChatGenerationActive: isChatGenerationActive,
            isLastMessage: isLastMessage,
            hasEverStreamed: hasEverStreamed,
            liveMarkdownRenderingEnabled: liveMarkdownRenderingEnabled,
            frozenMarkdownSnapshot: frozenMarkdownSnapshot,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            phoneToolGroup: phoneToolGroup,
            assistantTurn: assistantTurn,
            automationScreenshotGroup: automationScreenshotGroup,
            workspaceStoreID: ObjectIdentifier(workspaceStore),
            reduceMotion: reduceMotion,
            locale: locale,
            messageEditingAllowed: messageEditingAllowed,
            hasArtifactPinAction: artifactPinAction != nil,
            chatMessageAnchorHighlighted: chatMessageAnchorHighlighted,
            appLanguage: prefs.appLanguage,
            actions: actionBox
        )
        .equatable()
    }

    private static func displaySignature(_ setting: DisplaySetting?, prefs: IOSChatRenderPreferences) -> Int {
        var hasher = Hasher()
        hasher.combine(prefs.fontScale)
        hasher.combine(prefs.chatFont)
        hasher.combine(prefs.agentName)
        hasher.combine(prefs.appLanguage)
        hasher.combine(prefs.replyDeliveryMode)
        if let setting {
            hasher.combine(ObjectIdentifier(setting))
            hasher.combine(setting.hash)
        } else {
            hasher.combine(0)
        }
        return hasher.finalize()
    }

    /// Called only by the copy action; raw protocol text remains available to storage/model paths.
    static func copyText(for message: UIMessage) -> String {
        message.role == MessageRole.assistant ? IOSConversationExporter.shareText(for: message) : message.toText()
    }

    private static func generativeSignature(_ setting: GenerativeUiSetting?) -> Int {
        guard let setting else { return 0 }
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(setting))
        hasher.combine(setting.hash)
        return hasher.finalize()
    }

    static func shouldRenderReasoningCard(_ reasoning: UIMessagePart.Reasoning) -> Bool {
        !ReasoningMetadataKt.isEmptyProtocolReasoning(reasoning: reasoning)
    }

    static func firstVisibleReasoningIndex(in parts: [UIMessagePart]) -> Int? {
        parts.firstIndex { part in
            guard let reasoning = part as? UIMessagePart.Reasoning else { return false }
            return shouldRenderReasoningCard(reasoning)
        }
    }

    static func hasVisibleAssistantContent(in parts: [UIMessagePart]) -> Bool {
        parts.contains { part in
            if let text = part as? UIMessagePart.Text {
                return text.text.contains { !$0.isWhitespace }
            }
            if let reasoning = part as? UIMessagePart.Reasoning {
                return shouldRenderReasoningCard(reasoning)
            }
            return true
        }
    }

    static func instantToDate(_ instant: KotlinInstant) -> Date {
        Date(timeIntervalSince1970:
            Double(instant.epochSeconds) + Double(instant.nanosecondsOfSecond) / 1_000_000_000)
    }
}

private struct MessageBubbleEquatableContent: View, @MainActor Equatable {
    let message: UIMessage
    let displayTexts: [Int: String]
    let contentIdentity: ChatMessageContentIdentity
    let messageIndex: Int
    let isAssistantContinuation: Bool
    let variantInfo: IOSConversationStore.VariantInfo?
    let displaySetting: DisplaySetting?
    let generativeUiSetting: GenerativeUiSetting?
    let displaySignature: Int
    let generativeSignature: Int
    let isGenerating: Bool
    let isChatGenerationActive: Bool
    let isLastMessage: Bool
    let hasEverStreamed: Bool
    let liveMarkdownRenderingEnabled: Bool
    let frozenMarkdownSnapshot: String?
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let phoneToolGroup: ChatPhoneToolGroupSummary?
    let assistantTurn: ChatAssistantTurnRole?
    let automationScreenshotGroup: ChatAutomationScreenshotBatchSummary?
    let workspaceStoreID: ObjectIdentifier
    let reduceMotion: Bool
    let locale: Locale
    let messageEditingAllowed: Bool
    let hasArtifactPinAction: Bool
    let chatMessageAnchorHighlighted: Bool
    let appLanguage: String
    let actions: MessageBubbleActionBox

    private var observesChatGenerationActive: Bool {
        contentIdentity.cachedParts.contains { part in
            if part is UIMessagePart.MiniApp { return true }
            return (part as? UIMessagePart.Tool)?.toolName == "generate_image"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Isolate `isLastMessage`: flipping `isLastMessage` (`true -> false`) on an
        // idle/settled message does not change `isGenerating && isLastMessage` and
        // must never re-evaluate body text or Markdown subtrees.
        lhs.message === rhs.message &&
            lhs.displayTexts == rhs.displayTexts &&
            lhs.contentIdentity.matches(rhs.message) &&
            lhs.isAssistantContinuation == rhs.isAssistantContinuation &&
            lhs.variantInfo == rhs.variantInfo &&
            lhs.displaySignature == rhs.displaySignature &&
            lhs.generativeSignature == rhs.generativeSignature &&
            lhs.isGenerating == rhs.isGenerating &&
            (lhs.isGenerating && lhs.isLastMessage) == (rhs.isGenerating && rhs.isLastMessage) &&
            (!(lhs.observesChatGenerationActive || rhs.observesChatGenerationActive) ||
                lhs.isChatGenerationActive == rhs.isChatGenerationActive) &&
            lhs.hasEverStreamed == rhs.hasEverStreamed &&
            (lhs.liveMarkdownRenderingEnabled == rhs.liveMarkdownRenderingEnabled ||
                (!lhs.isGenerating && !rhs.isGenerating &&
                 lhs.frozenMarkdownSnapshot == nil && rhs.frozenMarkdownSnapshot == nil)) &&
            lhs.frozenMarkdownSnapshot == rhs.frozenMarkdownSnapshot &&
            lhs.reasoningLevelLabel == rhs.reasoningLevelLabel &&
            lhs.imageAccessibilityFocusToolCallID == rhs.imageAccessibilityFocusToolCallID &&
            lhs.phoneToolGroup?.signature == rhs.phoneToolGroup?.signature &&
            lhs.assistantTurn == rhs.assistantTurn &&
            lhs.automationScreenshotGroup?.signature == rhs.automationScreenshotGroup?.signature &&
            lhs.workspaceStoreID == rhs.workspaceStoreID &&
            lhs.reduceMotion == rhs.reduceMotion &&
            lhs.locale == rhs.locale &&
            lhs.messageEditingAllowed == rhs.messageEditingAllowed &&
            lhs.hasArtifactPinAction == rhs.hasArtifactPinAction &&
            lhs.chatMessageAnchorHighlighted == rhs.chatMessageAnchorHighlighted
    }

    var body: some View {
        MessageBubbleStatefulContent(
            message: message,
            displayTexts: displayTexts,
            contentIdentity: contentIdentity,
            messageIndex: messageIndex,
            isAssistantContinuation: isAssistantContinuation,
            variantInfo: variantInfo,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            displaySignature: displaySignature,
            generativeSignature: generativeSignature,
            isGenerating: isGenerating,
            isChatGenerationActive: isChatGenerationActive,
            isLastMessage: isLastMessage,
            hasEverStreamed: hasEverStreamed,
            liveMarkdownRenderingEnabled: liveMarkdownRenderingEnabled,
            frozenMarkdownSnapshot: frozenMarkdownSnapshot,
            reasoningLevelLabel: reasoningLevelLabel,
            imageAccessibilityFocusToolCallID: imageAccessibilityFocusToolCallID,
            phoneToolGroup: phoneToolGroup,
            assistantTurn: assistantTurn,
            automationScreenshotGroup: automationScreenshotGroup,
            workspaceStore: actions.workspaceStore ?? .shared,
            reduceMotion: reduceMotion,
            locale: locale,
            messageEditingAllowed: messageEditingAllowed,
            completionFeedback: actions.completionFeedback,
            hasArtifactPinAction: hasArtifactPinAction,
            chatMessageAnchorHighlighted: chatMessageAnchorHighlighted,
            appLanguage: appLanguage,
            actions: actions
        )
    }
}

private struct MessageBubbleStatefulContent: View {
    let message: UIMessage
    let displayTexts: [Int: String]
    let contentIdentity: ChatMessageContentIdentity
    let messageIndex: Int
    let isAssistantContinuation: Bool
    let variantInfo: IOSConversationStore.VariantInfo?
    let displaySetting: DisplaySetting?
    let generativeUiSetting: GenerativeUiSetting?
    let displaySignature: Int
    let generativeSignature: Int
    let isGenerating: Bool
    let isChatGenerationActive: Bool
    let isLastMessage: Bool
    let hasEverStreamed: Bool
    let liveMarkdownRenderingEnabled: Bool
    let frozenMarkdownSnapshot: String?
    let reasoningLevelLabel: String?
    let imageAccessibilityFocusToolCallID: String?
    let phoneToolGroup: ChatPhoneToolGroupSummary?
    let assistantTurn: ChatAssistantTurnRole?
    let automationScreenshotGroup: ChatAutomationScreenshotBatchSummary?
    let workspaceStore: IOSWorkspaceStore
    let reduceMotion: Bool
    let locale: Locale
    let messageEditingAllowed: Bool
    let completionFeedback: ChatCompletionFeedback?
    let hasArtifactPinAction: Bool
    let chatMessageAnchorHighlighted: Bool
    let appLanguage: String
    let actions: MessageBubbleActionBox

    @State private var workspaceSaveAlert: WorkspaceSaveAlert?
    @State private var toolDetailTarget: ToolDetailTarget?
    @State private var taskStepCache = ChatTaskToolStepCache()
    @AccessibilityFocusState private var focusedGeneratedImageToolCallID: String?

    private var onRegenerate: () -> Void { actions.onRegenerate }
    private var onRequestEdit: (String) -> Void { actions.onRequestEdit }
    private var onEdit: (String) -> Void { actions.onEdit }
    private var onDelete: () -> Void { actions.onDelete }
    private var onSelectVariant: (Int) -> Void { actions.onSelectVariant }
    private var onGenerativeWidgetAction: (String) -> Void { actions.onGenerativeWidgetAction }
    private var onModifyGeneratedImage: (String, String, String) -> Void { actions.onModifyGeneratedImage }
    private var onOpenMiniApp: (String) -> Void { actions.onOpenMiniApp }
    private var onOpenMiniApps: () -> Void { actions.onOpenMiniApps }
    private var onOpenSubagentConversation: ((String) -> Void)? { actions.onOpenSubagentConversation }
    private var artifactPinAction: ChatArtifactPinHandler? { actions.artifactPinAction }

    private var isUser: Bool {
        message.role == MessageRole.user
    }

    private var canBranch: Bool {
        // Disable branch actions while a run is active, including tool approval
        // pauses where no stream job is currently running.
        messageEditingAllowed && !isGenerating
    }

    private func streamingBoundaryKey(
        text: String,
        partIndex: Int,
        nonEmptyTextPartCount: Int,
        isSourceMessageComplete: Bool
    ) -> Int {
        let isLiveStreaming = isGenerating && isLastMessage
        let isSegmented = IOSChatRenderPreferences.shared.isSegmentedReplyDelivery
        var hasher = Hasher()
        if isSegmented && isLiveStreaming && liveMarkdownRenderingEnabled {
            hasher.combine(ChatSegmentedMarkdownCommitPolicy.committedUTF16Count(in: text, isStreaming: true))
        } else {
            hasher.combine(text)
        }
        hasher.combine(isSegmented)
        hasher.combine(partIndex)
        hasher.combine(isLiveStreaming)
        hasher.combine(reduceMotion)
        hasher.combine(liveMarkdownRenderingEnabled)
        hasher.combine(hasEverStreamed)
        hasher.combine(nonEmptyTextPartCount == 1 ? frozenMarkdownSnapshot : nil)
        hasher.combine(isSourceMessageComplete)
        hasher.combine(displaySignature)
        hasher.combine(generativeSignature)
        return hasher.finalize()
    }

    private var hasNonTextVisibleAssistantParts: Bool {
        message.parts.contains { part in
            if part is UIMessagePart.Text || part is UIMessagePart.Reasoning { return false }
            if let tool = part as? UIMessagePart.Tool {
                return ChatTaskStreamGrouping.isMediaBearing(tool)
            }
            return true
        }
    }

    private func isAwaitingSegmentedFirstBlock(messageHexID: String) -> Bool {
        guard !isUser,
              isGenerating && isLastMessage,
              liveMarkdownRenderingEnabled,
              IOSChatRenderPreferences.shared.isSegmentedReplyDelivery,
              !hasNonTextVisibleAssistantParts else {
            return false
        }
        return !ChatSegmentedBubbleReadiness.shared.isReady(messageID: messageHexID)
    }

    var body: some View {
        let messageHexID = message.id.toHexDashString()
        let _ = ChatTimelineRowLayoutInvalidation.markRowDirty(messageHexID)
        #if DEBUG
        let _ = ChatRenderProbe.record("message", id: messageHexID)
        #endif
        Group {
            if ChatMessageProjector.isSubAgentResult(message) {
                ChatSubAgentResultCard(
                    sender: IosMailboxMessageBridge.shared.sender(message: message) ?? "subagent",
                    displayText: message.parts.enumerated().compactMap { index, part in
                        guard let text = part as? UIMessagePart.Text else { return nil }
                        return displayText(for: text, at: index)
                    }.joined(separator: "\n\n"),
                    displaySetting: displaySetting
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isUser {
                HStack(spacing: 0) {
                    Spacer(minLength: 56)

                    VStack(alignment: .trailing, spacing: 4) {
                        if let sender = IosMailboxMessageBridge.shared.sender(message: message) {
                            Label(mailboxSourceTitle(sender), systemImage: "arrow.turn.down.right")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.mailbox.source")
                        }
                        variantSwitcher
                        messagePartsWithAnchorHighlight
                    }
                    .frame(maxWidth: ChatLayout.userMaxWidth, alignment: .trailing)
                }
            } else {
                let awaitingSegmentedFirstBlock = isAwaitingSegmentedFirstBlock(messageHexID: messageHexID)
                let animateSegmentedHeader = IOSChatRenderPreferences.shared.isSegmentedReplyDelivery
                    && isGenerating && isLastMessage && !reduceMotion
                ChatAssistantStack {
                    if !awaitingSegmentedFirstBlock,
                       (!isAssistantContinuation || variantInfo?.hasMultipleVariants == true) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !isAssistantContinuation {
                                ChatAgentName()
                            }
                            if variantInfo?.hasMultipleVariants == true {
                                variantBadge
                            }
                        }
                        .modifier(ChatSegmentedHeaderEntranceModifier(enabled: animateSegmentedHeader))
                    }
                    if !awaitingSegmentedFirstBlock {
                        variantSwitcher
                    }
                    messagePartsWithAnchorHighlight
                    if !awaitingSegmentedFirstBlock {
                        annotationsBlock
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: awaitingSegmentedFirstBlock ? 0 : nil, alignment: .top)
                .opacity(awaitingSegmentedFirstBlock ? 0 : 1)
                .clipped()
                .allowsHitTesting(!awaitingSegmentedFirstBlock)
                .accessibilityHidden(awaitingSegmentedFirstBlock)
                .contextMenu { messageActions }
            }
        }
        .onChange(of: imageAccessibilityFocusToolCallID) { _, toolCallID in
            guard let toolCallID,
                  message.parts.contains(where: { part in
                    guard let tool = part as? UIMessagePart.Tool else { return false }
                    return tool.toolName == "generate_image" && tool.toolCallId == toolCallID
                  }) else { return }
            Task { @MainActor in
                await Task.yield()
                focusedGeneratedImageToolCallID = toolCallID
            }
        }
        .alert(item: $workspaceSaveAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .environment(\.markdownLayoutInvalidationID, messageHexID)
        .environment(\.chatArtifactMessageID, hasArtifactPinAction ? ChatMessageProjector.messageId(for: message) : nil)
        .environment(\.swiftStreamingMarkdownCodeCopyHitOutset, 13)
        .environment(
            \.swiftStreamingMarkdownCodeBlockHeaderAccessory,
            hasArtifactPinAction ? ChatCodeBlockHeaderAccessory.streamingHeaderProvider : nil
        )
    }

    // MARK: - Annotations (URL citations)

    /// Renders URL-citation annotations the provider attaches to an assistant
    /// message (Android MessageAnnotations parity). The provider already parses
    /// these into `message.annotations`; iOS was just never rendering them.
    @ViewBuilder
    private var annotationsBlock: some View {
        let citations = Self.urlCitations(in: message)
        if !citations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                    if let url = Self.safeExternalURL(from: citation.url) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                Text("[\(index + 1)] \(citation.title)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(AmberTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Extracts URL-citation annotations from a message. `annotations` is a
    /// Kotlin `List<UIMessageAnnotation>` bridged as NSArray; each URL citation
    /// is a `UIMessageAnnotation.UrlCitation` sealed subclass instance.
    private static func urlCitations(in message: UIMessage) -> [(title: String, url: String)] {
        message.annotations.compactMap { annotation in
            // The sealed subclass UrlCitation bridges as
            // UIMessageAnnotation.UrlCitation in Swift.
            if let citation = annotation as? UIMessageAnnotation.UrlCitation {
                return (title: citation.title, url: citation.url)
            }
            return nil
        }
    }

    private static func safeExternalURL(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    // MARK: - Branching controls

    private func mailboxSourceTitle(_ sender: String) -> String {
        let source = sender == "/root" ? "主会话" : String(sender.split(separator: "/").last ?? Substring(sender))
        switch IosMailboxMessageBridge.shared.kind(message: message) {
        case "NEW_TASK": return "来自\(source)的任务"
        case "FINAL_ANSWER": return "来自\(source)的结果"
        default: return "来自\(source)的消息"
        }
    }

    @ViewBuilder
    private var variantSwitcher: some View {
        if let info = variantInfo, info.hasMultipleVariants, canBranch {
            HStack(spacing: 4) {
                Button {
                    let next = info.selectedIndex - 1
                    if next >= 0 { onSelectVariant(next) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(info.selectedIndex <= 0)

                Text("\(info.selectedIndex + 1)/\(info.variantCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)

                Button {
                    let next = info.selectedIndex + 1
                    if next < info.variantCount { onSelectVariant(next) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(info.selectedIndex >= info.variantCount - 1)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private var variantBadge: some View {
        Text("\((variantInfo?.selectedIndex ?? 0) + 1)/\(variantInfo?.variantCount ?? 1)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(AmberTheme.muted2)
    }

    @ViewBuilder
    private var messageActions: some View {
        if canBranch {
            if isUser {
                Button {
                    onRequestEdit(message.toText())
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
            } else {
                Button {
                    onRegenerate()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                if assistantArtifactText != nil {
                    Button {
                        saveAssistantMessageToWorkspace()
                    } label: {
                        Label("保存到 Workspace", systemImage: "tray.and.arrow.down")
                    }
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Divider()
        }
        if let artifactPinAction {
            Button {
                artifactPinAction(ChatMessageProjector.messageId(for: message), message.toText(), .message, nil)
            } label: {
                Label("收进产物架", systemImage: "pin")
            }
        }
        Button {
            UIPasteboard.general.string = MessageBubbleView.copyText(for: message)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        // contextMenu 的内容在每次 body 求值时构建；文本只在点击时取，避免流式期间逐帧拼全文。
        // 正在流式生成的消息不提供分享：内容未完成，也避免每个 chunk 多构建菜单项。
        if !(isGenerating && isLastMessage && !isUser) {
            Button {
                shareMessage(asImage: false)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button {
                shareMessage(asImage: true)
            } label: {
                Label("分享为图片", systemImage: "photo.on.rectangle")
            }
        }
    }

    private func shareMessage(asImage: Bool) {
        let text = IOSConversationExporter.shareText(for: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isUser = isUser
        Task { @MainActor in
            let activity = IOSShareActivity.shared
            guard !text.isEmpty else {
                activity.notify("这条消息没有可分享的文字。")
                return
            }
            // 与整段导出共用同一状态：避免两个分享面板相互顶掉，进行中时排队提示而不是静默忽略。
            // 分享文本是瞬时操作，不显示进度，只占住互斥。
            guard activity.begin(asImage ? "正在生成分享图片…" : nil) else {
                activity.notify(IOSConversationExporter.busyMessage)
                return
            }
            let item: Any
            if asImage {
                guard let image = IOSMessageImageRenderer.render(text: text, isUser: isUser) else {
                    activity.end(failure: "生成分享图片失败，请稍后重试。")
                    return
                }
                item = image
            } else {
                item = text
            }
            let presented = await IOSShareSheet.present([item])
            activity.end(failure: presented ? nil : "当前无法弹出分享面板，请稍后重试。")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var messageParts: some View {
        Group {
            if !isUser {
                assistantTaskGroupedRows
            } else {
                messagePartRows
            }
        }
        .sheet(item: $toolDetailTarget) { target in
            let currentTool = toolPart(toolCallId: target.toolCallId) ?? target.initialTool
            ChatToolDetailSheet(
                tool: currentTool,
                live: currentTool.toolName.contains("subagent_dispatch")
                    ? SubAgentLiveRegistry.shared.model(forToolCallId: currentTool.toolCallId)
                    : nil,
                onOpenSubagentConversation: onOpenSubagentConversation
            )
        }
    }

    private func displayText(for part: UIMessagePart.Text, at index: Int) -> String {
        if let projected = displayTexts[index] { return projected }
        // Preview/unprojected callers may render ordinary prose, but never decode or expose an envelope.
        let text = IosMailboxMessageBridge.shared.displayText(part: part)
        if IOSSubAgentOutputProjection.isKnownSubAgentResultEnvelope(text)
            || IosToolOutputJsonBridge.shared.metadataString(part: part, key: "kind") == "FINAL_ANSWER" {
            return ""
        }
        return text
    }

    @ViewBuilder
    private var assistantTaskGroupedRows: some View {
        let messageID = ChatMessageProjector.messageId(for: message)
        let currentTools = message.parts.compactMap { $0 as? UIMessagePart.Tool } +
            (assistantTurn?.progress?.tools ?? [])
        let _ = taskStepCache.prepare(
            tools: currentTools,
            languageKey: "\(appLanguage)|\(locale.identifier)"
        )
        let segments = ChatTaskStreamGrouping.segments(
            for: message,
            messageID: messageID,
            isGeneratingTail: isGenerating && isLastMessage,
            stepCache: taskStepCache,
            usesTurnProgress: true
        )
        ForEach(segments) { segment in
            switch segment {
            case .text(_, let partIndex, let textPart):
                if Self.shouldRenderMiniAppStreamingCard(
                    textPart.text,
                    isLiveStream: isGenerating && isLastMessage
                ) {
                    ChatMiniAppStreamingCard(
                        text: textPart.text,
                        isGenerating: true
                    )
                    .transition(.opacity)
                } else {
                    // 逐字平滑吐字：上游 delta 成块到达，直接整块上屏会一次撑高多行，
                    // 观感是「黑框先跳、文字后亮」。按帧小步推进让折行自然逐行上推。
                    let messageHexID = message.id.toHexDashString()
                    let isSourceComplete = IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: IOSIntelligentUITerminal.completedKey) == "completed"
                    let sanitizedText = displayText(for: textPart, at: partIndex)
                    ChatStreamingGraphBoundary(
                        isStreaming: isGenerating && isLastMessage,
                        messageID: messageHexID,
                        contentKey: streamingBoundaryKey(
                            text: sanitizedText,
                            partIndex: partIndex,
                            nonEmptyTextPartCount: nonEmptyTextPartCount,
                            isSourceMessageComplete: isSourceComplete
                        )
                    ) {
                        ChatStreamingRevealPacer(
                            text: sanitizedText,
                            isStreaming: isGenerating && isLastMessage,
                            reduceMotion: reduceMotion,
                            liveRenderingEnabled: liveMarkdownRenderingEnabled,
                            completionFeedback: completionFeedback,
                            messageID: messageHexID,
                            textPartIndex: partIndex
                        ) { revealedText, isPacingReveal in
                            ChatAssistantText {
                                ChatAssistantMarkdownView(
                                    markdown: revealedText,
                                    renderCacheNamespace: "\(message.id):text:\(partIndex)",
                                    displaySetting: displaySetting,
                                    generativeUiSetting: generativeUiSetting,
                                    isStreaming: (isGenerating && isLastMessage) || isPacingReveal,
                                    hasEverStreamed: hasEverStreamed,
                                    liveRenderingEnabled: liveMarkdownRenderingEnabled,
                                    frozenMarkdownSnapshot: nonEmptyTextPartCount == 1 ? frozenMarkdownSnapshot : nil,
                                    onGenerativeWidgetAction: onGenerativeWidgetAction,
                                    isSourceMessageComplete: isSourceComplete,
                                    sourceMessageID: messageHexID,
                                    sourceTextPartIndex: partIndex
                                )
                            }
                        }
                    }
                    // 流式正文不做整块透明度淡入：上游 delta 是成块到达的，逐块淡入会
                    // 让气泡先撑高、文字以暗灰鬼影过半秒才浮现（黑框先跳、字后亮）。
                    // 只有「该消息首段正文」保留一次入场，其余一律实色立即可读。
                    .chatLiveEntrance(
                        key: "\(message.id):text:\(partIndex)",
                        isLive: isLiveTail && nonEmptyTextPartCount == 1 && !IOSChatRenderPreferences.shared.isSegmentedReplyDelivery
                    )
                }
            case .taskGroup(let taskSegment):
                toolSegmentMediaViews(
                    tools: taskSegment.mediaBearingTools,
                    segmentID: taskSegment.id,
                    isFirstMediaSegment: segments.firstIndex(where: {
                        switch $0 {
                        case .taskGroup(let s): !s.mediaBearingTools.isEmpty
                        case .groupedTools(_, let tools): !tools.isEmpty
                        default: false
                        }
                    }).map { segments[$0].id == segment.id } ?? false
                )
            case .groupedTools(let segID, let mediaBearingTools):
                toolSegmentMediaViews(
                    tools: mediaBearingTools,
                    segmentID: segID,
                    isFirstMediaSegment: segments.firstIndex(where: {
                        switch $0 {
                        case .taskGroup(let s): !s.mediaBearingTools.isEmpty
                        case .groupedTools(_, let tools): !tools.isEmpty
                        default: false
                        }
                    }).map { segments[$0].id == segment.id } ?? false
                )
            case .imageGallery(_, let startIndex, let images):
                ChatMediaGallery(items: images.enumerated().map { offset, image in
                    .image(image, id: "\(message.id):image:\(startIndex + offset)")
                }, compact: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .video(_, let partIndex, let video):
                ChatVideoCard(video: ChatVideoDescriptor(part: video, id: "\(message.id):video:\(partIndex)"))
            case .miniApp(_, _, let miniApp):
                IOSMiniAppChatCard(
                    part: miniApp,
                    onRun: { onOpenMiniApp(miniApp.appId) },
                    onOpenList: onOpenMiniApps,
                    onModify: { prompt in
                        guard messageEditingAllowed && !isChatGenerationActive else { return false }
                        onGenerativeWidgetAction(prompt)
                        return true
                    }
                )
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: message.parts.map(Self.partAnimationKey).joined(separator: "|"))
    }

    @ViewBuilder
    private func toolSegmentMediaViews(
        tools: [UIMessagePart.Tool],
        segmentID: String,
        isFirstMediaSegment: Bool
    ) -> some View {
        let messageID = ChatMessageProjector.messageId(for: message)
        let nonAutomationTools = tools.filter {
            !ChatAutomationScreenshotGrouping.isAutomationScreenshotTool($0, allowDiskLookup: false)
        }
        if let batch = automationScreenshotGroup {
            if isFirstMediaSegment {
                ChatAutomationScreenshotAlbumView(
                    items: batch.items,
                    toggleID: batch.toggleID,
                    controlledExpanded: batch.isExpanded
                )
            }
        } else {
            let inlineShots = tools.flatMap {
                ChatAutomationScreenshotGrouping.screenshotItems(for: $0, messageID: messageID, allowDiskLookup: false)
            }
            if !inlineShots.isEmpty {
                ChatAutomationScreenshotAlbumView(
                    items: inlineShots,
                    toggleID: "automation-shots-\(messageID)-\(segmentID)"
                )
            }
        }
        ForEach(nonAutomationTools, id: \.toolCallId) { tool in
            toolMediaView(for: tool)
        }
    }

    @ViewBuilder
    private func toolMediaView(for tool: UIMessagePart.Tool) -> some View {
        if tool.toolName != "generate_image" {
            ChatToolMediaGallery(tool: tool).equatable()
            ForEach(Array(tool.output.enumerated()), id: \.offset) { index, output in
                if let video = output as? UIMessagePart.Video {
                    ChatVideoCard(video: ChatVideoDescriptor(part: video, id: "\(tool.toolCallId):video:\(index)"))
                }
            }
        } else {
            let images = tool.output.compactMap { $0 as? UIMessagePart.Image }
            if !images.isEmpty {
                ChatGeneratedImageGrid(
                    images: images,
                    toolCallID: tool.toolCallId,
                    toolInput: tool.input,
                    onModify: onModifyGeneratedImage,
                    allowsModify: !isChatGenerationActive
                )
                .id(ChatImageGenerationAnchorTarget.id(
                    messageID: ChatMessageProjector.messageId(for: message),
                    toolCallID: tool.toolCallId
                ))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("图片已生成")
                .accessibilityFocused($focusedGeneratedImageToolCallID, equals: tool.toolCallId)
                .transition(.opacity)
            } else if tool.output.isEmpty {
                ChatGeneratedImageLoadingPlaceholder(
                    toolInput: tool.input,
                    isAnimating: isGenerating && isLastMessage,
                    toolCallID: tool.toolCallId
                )
                .id(ChatImageGenerationAnchorTarget.id(
                    messageID: ChatMessageProjector.messageId(for: message),
                    toolCallID: tool.toolCallId
                ))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在生成图片")
                .accessibilityFocused($focusedGeneratedImageToolCallID, equals: tool.toolCallId)
                .transition(.opacity)
            } else {
                ChatGeneratedImageFailureCard(
                    reason: ChatToolOutputFormatter.imageFailureReason(from: tool.output)
                        ?? "图片生成工具没有返回图片。",
                    toolCallID: tool.toolCallId
                )
                .id(ChatImageGenerationAnchorTarget.id(
                    messageID: ChatMessageProjector.messageId(for: message),
                    toolCallID: tool.toolCallId
                ))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "图片生成失败：" + (
                        ChatToolOutputFormatter.imageFailureReason(from: tool.output)
                            ?? "图片生成工具没有返回图片。"
                    )
                )
                .accessibilityFocused($focusedGeneratedImageToolCallID, equals: tool.toolCallId)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var messagePartRows: some View {
        ForEach(Array(message.parts.enumerated()), id: \.offset) { partIndex, part in
            if let textPart = part as? UIMessagePart.Text, !textPart.text.isEmpty {
                if isUser {
                    // 气泡现在是内容尺寸(已移除其内部的 300pt 框),contextMenu 的高亮平台贴合气泡。
                    // 再用 .contentShape(.contextMenuPreview, 气泡圆角) 把平台裁成气泡形状,消除灰角。
                    ChatUserBubble(
                        text: GenerativeUiPlanner.shared.stripVisualRouteTagsForDisplay(
                            text: displayText(for: textPart, at: partIndex)
                        )
                    )
                        .contentShape(
                            .contextMenuPreview,
                            ChatUserBubble.bubbleShape
                        )
                        .contextMenu { messageActions }
                } else if Self.shouldRenderMiniAppStreamingCard(
                    textPart.text,
                    isLiveStream: isGenerating && isLastMessage
                ) {
                    // Only hijack the live stream. Idle HTML/markdown stays readable text
                    // unless apply already replaced it with UIMessagePart.MiniApp.
                    ChatMiniAppStreamingCard(
                        text: textPart.text,
                        isGenerating: true
                    )
                    .transition(.opacity)
                } else {
                    // 逐字平滑吐字：上游 delta 成块到达，直接整块上屏会一次撑高多行，
                    // 观感是「黑框先跳、文字后亮」。按帧小步推进让折行自然逐行上推。
                    let messageHexID = message.id.toHexDashString()
                    let isSourceComplete = IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: IOSIntelligentUITerminal.completedKey) == "completed"
                    let sanitizedText = displayText(for: textPart, at: partIndex)
                    ChatStreamingGraphBoundary(
                        isStreaming: isGenerating && isLastMessage,
                        messageID: messageHexID,
                        contentKey: streamingBoundaryKey(
                            text: sanitizedText,
                            partIndex: partIndex,
                            nonEmptyTextPartCount: nonEmptyTextPartCount,
                            isSourceMessageComplete: isSourceComplete
                        )
                    ) {
                        ChatStreamingRevealPacer(
                            text: sanitizedText,
                            isStreaming: isGenerating && isLastMessage,
                            reduceMotion: reduceMotion,
                            liveRenderingEnabled: liveMarkdownRenderingEnabled,
                            completionFeedback: completionFeedback,
                            messageID: messageHexID,
                            textPartIndex: partIndex
                        ) { revealedText, isPacingReveal in
                            ChatAssistantText {
                                ChatAssistantMarkdownView(
                                    markdown: revealedText,
                                    renderCacheNamespace: "\(message.id):text:\(partIndex)",
                                    displaySetting: displaySetting,
                                    generativeUiSetting: generativeUiSetting,
                                    isStreaming: (isGenerating && isLastMessage) || isPacingReveal,
                                    hasEverStreamed: hasEverStreamed,
                                    liveRenderingEnabled: liveMarkdownRenderingEnabled,
                                    frozenMarkdownSnapshot: nonEmptyTextPartCount == 1 ? frozenMarkdownSnapshot : nil,
                                    onGenerativeWidgetAction: onGenerativeWidgetAction,
                                    isSourceMessageComplete: isSourceComplete,
                                    sourceMessageID: messageHexID,
                                    sourceTextPartIndex: partIndex
                                )
                            }
                        }
                    }
                    // 流式正文不做整块透明度淡入：上游 delta 是成块到达的，逐块淡入会
                    // 让气泡先撑高、文字以暗灰鬼影过半秒才浮现（黑框先跳、字后亮）。
                    // 只有「该消息首段正文」保留一次入场，其余一律实色立即可读。
                    .chatLiveEntrance(
                        key: "\(message.id):text:\(partIndex)",
                        isLive: isLiveTail && nonEmptyTextPartCount == 1 && !IOSChatRenderPreferences.shared.isSegmentedReplyDelivery
                    )
                }
            } else if part is UIMessagePart.Reasoning {
                EmptyView()
            } else if part is UIMessagePart.Image {
                if partIndex == 0 || !(message.parts[partIndex - 1] is UIMessagePart.Image) {
                    let images = message.parts[partIndex...].prefix { $0 is UIMessagePart.Image }
                    ChatMediaGallery(items: images.enumerated().compactMap { offset, part in
                        guard let image = part as? UIMessagePart.Image else { return nil }
                        return .image(image, id: "\(message.id):image:\(partIndex + offset)")
                    }, compact: isUser)
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }
            } else if let video = part as? UIMessagePart.Video {
                ChatVideoCard(video: ChatVideoDescriptor(part: video, id: "\(message.id):video:\(partIndex)"))
            } else if let miniApp = part as? UIMessagePart.MiniApp {
                IOSMiniAppChatCard(
                    part: miniApp,
                    onRun: { onOpenMiniApp(miniApp.appId) },
                    onOpenList: onOpenMiniApps,
                    onModify: { prompt in
                        guard messageEditingAllowed && !isChatGenerationActive else { return false }
                        onGenerativeWidgetAction(prompt)
                        return true
                    }
                )
            } else if let tool = part as? UIMessagePart.Tool {
                ChatToolPartRow(tool: tool, localeIdentifier: locale.identifier,
                    onTap: { toolDetailTarget = ToolDetailTarget(tool: tool) })
                    .equatable()
                    .id(ChatToolCallAnchorTarget.id(
                        messageID: ChatMessageProjector.messageId(for: message),
                        toolCallID: tool.toolCallId
                    ))
                    .chatLiveEntrance(key: "tool:\(tool.toolCallId)", isLive: isLiveTail)
                if tool.toolName != "generate_image" {
                    ChatToolMediaGallery(tool: tool).equatable()
                    ForEach(Array(tool.output.enumerated()), id: \.offset) { index, output in
                        if let video = output as? UIMessagePart.Video {
                            ChatVideoCard(video: ChatVideoDescriptor(part: video, id: "\(tool.toolCallId):video:\(index)"))
                        }
                    }
                } else {
                    let images = tool.output.compactMap { $0 as? UIMessagePart.Image }
                    if !images.isEmpty {
                        ChatGeneratedImageGrid(
                            images: images,
                            toolCallID: tool.toolCallId,
                            toolInput: tool.input,
                            onModify: onModifyGeneratedImage,
                            allowsModify: !isChatGenerationActive
                        )
                            .id(ChatImageGenerationAnchorTarget.id(
                                messageID: ChatMessageProjector.messageId(for: message),
                                toolCallID: tool.toolCallId
                            ))
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("图片已生成")
                            .accessibilityFocused(
                                $focusedGeneratedImageToolCallID,
                                equals: tool.toolCallId
                            )
                            .transition(.opacity)
                    } else if tool.output.isEmpty {
                        ChatGeneratedImageLoadingPlaceholder(
                            toolInput: tool.input,
                            isAnimating: isGenerating && isLastMessage,
                            toolCallID: tool.toolCallId
                        )
                            .id(ChatImageGenerationAnchorTarget.id(
                                messageID: ChatMessageProjector.messageId(for: message),
                                toolCallID: tool.toolCallId
                            ))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("正在生成图片")
                            .accessibilityFocused(
                                $focusedGeneratedImageToolCallID,
                                equals: tool.toolCallId
                            )
                            .transition(.opacity)
                    } else {
                        ChatGeneratedImageFailureCard(
                            reason: ChatToolOutputFormatter.imageFailureReason(from: tool.output)
                                ?? "图片生成工具没有返回图片。",
                            toolCallID: tool.toolCallId
                        )
                        .id(ChatImageGenerationAnchorTarget.id(
                            messageID: ChatMessageProjector.messageId(for: message),
                            toolCallID: tool.toolCallId
                        ))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "图片生成失败：" + (
                                ChatToolOutputFormatter.imageFailureReason(from: tool.output)
                                    ?? "图片生成工具没有返回图片。"
                            )
                        )
                        .accessibilityFocused(
                            $focusedGeneratedImageToolCallID,
                            equals: tool.toolCallId
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: message.parts.map(Self.partAnimationKey).joined(separator: "|"))
    }

    private var messagePartsWithAnchorHighlight: some View {
        messageParts
            .overlay {
                if chatMessageAnchorHighlighted {
                    Group {
                        if isUser {
                            ChatUserBubble.bubbleShape
                                .stroke(AmberTheme.accentAmber, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: AmberTheme.radiusMedium, style: .continuous)
                                .stroke(AmberTheme.accentAmber, lineWidth: 2)
                        }
                    }
                    .shadow(color: AmberTheme.accentAmber.opacity(0.5), radius: 7)
                    .allowsHitTesting(false)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: chatMessageAnchorHighlighted
            )
    }

    private var isLiveTail: Bool { isGenerating && isLastMessage }

    /// 占位思考卡与首个真实思考卡共用 key：占位被真实卡替换时不重播入场。
    private var thinkingEntranceKey: String { "\(message.id):thinking" }

    private func reasoningEntranceKey(partIndex: Int) -> String {
        let firstReasoningIndex = Self.firstVisibleReasoningIndex(in: message.parts)
        return partIndex == firstReasoningIndex ? thinkingEntranceKey : "\(message.id):reasoning:\(partIndex)"
    }

    private var hasVisibleAssistantContent: Bool {
        Self.hasVisibleAssistantContent(in: message.parts)
    }

    static func shouldRenderReasoningCard(_ reasoning: UIMessagePart.Reasoning) -> Bool {
        !ReasoningMetadataKt.isEmptyProtocolReasoning(reasoning: reasoning)
    }

    static func firstVisibleReasoningIndex(in parts: [UIMessagePart]) -> Int? {
        parts.firstIndex { part in
            guard let reasoning = part as? UIMessagePart.Reasoning else { return false }
            return shouldRenderReasoningCard(reasoning)
        }
    }

    static func hasVisibleAssistantContent(in parts: [UIMessagePart]) -> Bool {
        parts.contains { part in
            if let text = part as? UIMessagePart.Text {
                return text.text.contains { !$0.isWhitespace }
            }
            if let reasoning = part as? UIMessagePart.Reasoning {
                return shouldRenderReasoningCard(reasoning)
            }
            return true
        }
    }

    private var nonEmptyTextPartCount: Int {
        message.parts.reduce(0) { count, part in
            guard let text = part as? UIMessagePart.Text, !text.text.isEmpty else { return count }
            return count + 1
        }
    }

    private func toolPart(toolCallId: String) -> UIMessagePart.Tool? {
        message.parts.lazy
            .compactMap { $0 as? UIMessagePart.Tool }
            .first { $0.toolCallId == toolCallId }
    }

    /// Streaming MiniApp card is live-only: same shape as apply's "in-flight" window,
    /// without inventing a second turn-context gate in the bubble.
    private static func shouldRenderMiniAppStreamingCard(_ text: String, isLiveStream: Bool) -> Bool {
        isLiveStream && IOSMiniAppChatMessageFactory.mightContainMiniApp(text)
    }

    private static func partAnimationKey(_ part: UIMessagePart) -> String {
        if let tool = part as? UIMessagePart.Tool {
            let imageCount = tool.output.compactMap { $0 as? UIMessagePart.Image }.count
            return "tool:\(tool.toolCallId):\(tool.output.isEmpty):\(imageCount)"
        }
        if let miniApp = part as? UIMessagePart.MiniApp {
            return "mini_app:\(miniApp.appId):\(miniApp.version):\(miniApp.htmlHash ?? "")"
        }
        if let text = part as? UIMessagePart.Text,
           IOSMiniAppChatMessageFactory.mightContainMiniApp(text.text) {
            // Coarse key so streaming length growth does not thrash every token.
            return "mini_app_stream:\(text.text.count / 64)"
        }
        return String(describing: type(of: part))
    }

    private var assistantArtifactText: String? {
        guard !isUser else { return nil }
        let text = message.parts.compactMap { part -> String? in
            guard let textPart = part as? UIMessagePart.Text else { return nil }
            let trimmed = textPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : textPart.text
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func saveAssistantMessageToWorkspace() {
        guard let text = assistantArtifactText else { return }
        do {
            _ = try workspaceStore.saveArtifact(
                title: artifactTitle(for: text),
                content: text,
                type: .chat,
                sourceKind: "chat_message",
                sourceId: String(describing: message.id)
            )
            workspaceSaveAlert = .saved
        } catch {
            workspaceSaveAlert = .failed(error.localizedDescription)
        }
    }

    private func artifactTitle(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return "Chat Artifact" }
        return String(firstLine.prefix(80))
    }

    private static func reasoningDurationSeconds(_ reasoning: UIMessagePart.Reasoning) -> Double? {
        guard let end = reasoning.finishedAt else { return nil }
        let start = instantToDate(reasoning.createdAt)
        let endDate = instantToDate(end)
        return max(0, endDate.timeIntervalSince(start))
    }

    static func instantToDate(_ instant: KotlinInstant) -> Date {
        Date(timeIntervalSince1970:
            Double(instant.epochSeconds) + Double(instant.nanosecondsOfSecond) / 1_000_000_000)
    }
}

private enum WorkspaceSaveAlert: Identifiable {
    case saved
    case failed(String)

    var id: String {
        switch self {
        case .saved: "saved"
        case .failed(let message): "failed-\(message)"
        }
    }

    var title: String {
        switch self {
        case .saved: "已保存"
        case .failed: "保存失败"
        }
    }

    var message: String {
        switch self {
        case .saved:
            "助手回复已保存到 Workspace。"
        case .failed(let message):
            message
        }
    }
}

private struct ChatSegmentedHeaderEntranceModifier: ViewModifier {
    let enabled: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        let settled = !enabled || appeared
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 6)
            .onAppear {
                guard enabled, !appeared else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    appeared = true
                }
            }
    }
}

