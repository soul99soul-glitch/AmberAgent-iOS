import SwiftUI
import Shared
import SwiftStreamingMarkdown

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

struct MessageBubbleView: View {

    let message: UIMessage
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

    @Environment(IOSWorkspaceStore.self) private var workspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.chatMessageEditingAllowed) private var messageEditingAllowed
    @Environment(\.chatArtifactPinAction) private var artifactPinAction
    @Environment(\.chatMessageAnchorHighlighted) private var chatMessageAnchorHighlighted
    @State private var workspaceSaveAlert: WorkspaceSaveAlert?
    @State private var toolDetailTarget: ToolDetailTarget?
    @AccessibilityFocusState private var focusedGeneratedImageToolCallID: String?

    private var isUser: Bool {
        message.role == MessageRole.user
    }

    private var canBranch: Bool {
        // Disable branch actions while a run is active, including tool approval
        // pauses where no stream job is currently running.
        messageEditingAllowed && !isGenerating
    }

    var body: some View {
        Group {
            if ChatMessageProjector.isSubAgentResult(message) {
                ChatSubAgentResultCard(message: message, displaySetting: displaySetting)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isUser {
                HStack {
                    Spacer(minLength: 48)

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
                ChatAssistantStack {
                    if !isAssistantContinuation || variantInfo?.hasMultipleVariants == true {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !isAssistantContinuation {
                                ChatAgentName()
                            }
                            if variantInfo?.hasMultipleVariants == true {
                                variantBadge
                            }
                        }
                    }
                    variantSwitcher
                    fallbackThinkingCard
                    messagePartsWithAnchorHighlight
                    annotationsBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        // 只注入可判等的值：新建闭包每次都不相等，会让所有代码块与 Markdown 随气泡重算失效。
        .environment(\.chatArtifactMessageID, artifactPinAction == nil ? nil : ChatMessageProjector.messageId(for: message))
        // vendor 默认「复制」只有文字可点；Amber 显式放大到整组图标+文字、约 44pt 高（不改布局）。
        .environment(\.swiftStreamingMarkdownCodeCopyHitOutset, 13)
        // 流式 block 渲染路径的代码块头部同样放“收进产物架”，与 AmberMarkdownView 一致。
        .environment(
            \.swiftStreamingMarkdownCodeBlockHeaderAccessory,
            artifactPinAction == nil ? nil : ChatCodeBlockHeaderAccessory.streamingHeaderProvider
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
            UIPasteboard.general.string = message.toText()
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
        ForEach(Array(message.parts.enumerated()), id: \.offset) { partIndex, part in
            if let textPart = part as? UIMessagePart.Text, !textPart.text.isEmpty {
                if isUser {
                    // 气泡现在是内容尺寸(已移除其内部的 300pt 框),contextMenu 的高亮平台贴合气泡。
                    // 再用 .contentShape(.contextMenuPreview, 气泡圆角) 把平台裁成气泡形状,消除灰角。
                    ChatUserBubble(
                        text: GenerativeUiPlanner.shared.stripVisualRouteTagsForDisplay(
                            text: IosMailboxMessageBridge.shared.displayText(part: textPart)
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
                    ChatAssistantText {
                        ChatAssistantMarkdownView(
                            markdown: textPart.text,
                            renderCacheNamespace: "\(message.id):text:\(partIndex)",
                            displaySetting: displaySetting,
                            generativeUiSetting: generativeUiSetting,
                            isStreaming: isGenerating && isLastMessage,
                            hasEverStreamed: hasEverStreamed,
                            liveRenderingEnabled: liveMarkdownRenderingEnabled,
                            frozenMarkdownSnapshot: nonEmptyTextPartCount == 1 ? frozenMarkdownSnapshot : nil,
                            onGenerativeWidgetAction: onGenerativeWidgetAction
                        )
                    }
                    .chatLiveEntrance(key: "\(message.id):text:\(partIndex)", isLive: isLiveTail)
                }
            } else if let reasoning = part as? UIMessagePart.Reasoning {
                if Self.shouldRenderReasoningCard(reasoning) {
                    ChatReasoningCard(
                        bodyText: reasoning.reasoning,
                        isThinking: reasoning.finishedAt == nil && isGenerating && isLastMessage,
                        startedAt: Self.instantToDate(reasoning.createdAt),
                        finishedSeconds: Self.reasoningDurationSeconds(reasoning),
                        levelLabel: reasoningLevelLabel,
                        autoCloseThinking: displaySetting?.autoCloseThinking ?? true
                    )
                    .chatLiveEntrance(key: reasoningEntranceKey(partIndex: partIndex), isLive: isLiveTail)
                }
            } else if let image = part as? UIMessagePart.Image {
                if isUser {
                    ChatUserImageTile(urlString: image.url)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ChatGeneratedImageGrid(
                        images: [image],
                        onModify: onModifyGeneratedImage,
                        allowsModify: !isChatGenerationActive
                    )
                }
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
                if tool.toolName == "generate_image" {
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

    @ViewBuilder
    private var fallbackThinkingCard: some View {
        if !isUser, isGenerating, isLastMessage, !hasVisibleAssistantContent {
            ChatReasoningCard(
                bodyText: "",
                isThinking: true,
                levelLabel: reasoningLevelLabel,
                autoCloseThinking: displaySetting?.autoCloseThinking ?? true
            )
            .transition(.opacity)
            .chatLiveEntrance(key: thinkingEntranceKey, isLive: true)
        }
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

private struct ChatGeneratedImageGrid: View {
    let images: [UIMessagePart.Image]
    var toolCallID: String? = nil
    var toolInput: String?
    var onModify: (String, String, String) -> Void = { _, _, _ in }
    var allowsModify: Bool = true

    private var display: ChatGeneratedImageRequestDisplay {
        ChatGeneratedImageRequestDisplay(toolInput: toolInput)
    }

    var body: some View {
        Group {
            if images.count <= 1 {
                if let image = images.first {
                    singleCard {
                        ChatGeneratedImageTile(
                            urlString: image.url,
                            display: display,
                            onModify: onModify,
                            allowsModify: allowsModify,
                            toolCallID: toolCallID
                        )
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            ChatGeneratedImageTile(
                                urlString: image.url,
                                display: display,
                                onModify: onModify,
                                allowsModify: allowsModify,
                                toolCallID: toolCallID
                            )
                                .frame(width: display.multiCardWidth)
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func singleCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let maxWidth = display.singleCardMaxWidth {
            content().frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatGeneratedImageLoadingPlaceholder: View {
    let toolInput: String
    let isAnimating: Bool
    let toolCallID: String

    private var display: ChatGeneratedImageRequestDisplay {
        ChatGeneratedImageRequestDisplay(toolInput: toolInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholder
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var placeholder: some View {
        if display.requestedCount > 1 {
            // Match ChatGeneratedImageGrid success layout (horizontal strip).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<display.requestedCount, id: \.self) { _ in
                        ChatGeneratedImageDotPlaceholder(
                            aspectRatio: display.aspectRatio,
                            isAnimating: isAnimating
                        )
                            .frame(width: display.multiCardWidth)
                            .chatIslandToolAnchorHighlight(
                                toolCallID: toolCallID,
                                cornerRadius: AmberTheme.radiusXLarge
                            )
                    }
                }
                .padding(.trailing, 16)
            }
        } else if let maxWidth = display.singleCardMaxWidth {
            ChatGeneratedImageDotPlaceholder(
                aspectRatio: display.aspectRatio,
                isAnimating: isAnimating
            )
                .frame(maxWidth: maxWidth, alignment: .leading)
                .chatIslandToolAnchorHighlight(
                    toolCallID: toolCallID,
                    cornerRadius: AmberTheme.radiusXLarge
                )
        } else {
            ChatGeneratedImageDotPlaceholder(
                aspectRatio: display.aspectRatio,
                isAnimating: isAnimating
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatIslandToolAnchorHighlight(
                    toolCallID: toolCallID,
                    cornerRadius: AmberTheme.radiusXLarge
                )
        }
    }
}

private struct ChatGeneratedImageFailureCard: View {
    let reason: String
    let toolCallID: String

    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(width: 18, height: 18)

                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(AmberTheme.accentRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AmberTheme.accentRed.opacity(0.20), lineWidth: 0.5)
            }
            .chatIslandToolAnchorHighlight(toolCallID: toolCallID, cornerRadius: 10)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatGeneratedImageRequestDisplay {
    var aspectRatio: CGFloat
    var aspectRatioTitle: String
    var requestedCount: Int

    var singleCardMaxWidth: CGFloat? {
        aspectRatio < 1 ? 236 : nil
    }

    let multiCardWidth: CGFloat = 280

    init(toolInput: String?) {
        let object = Self.jsonObject(from: toolInput)
        let parsedAspect = IOSImageAspectRatio(toolValue: object?["aspect_ratio"] as? String)
        self.aspectRatio = CGFloat(parsedAspect.renderedAspectRatio)
        self.aspectRatioTitle = parsedAspect.title
        self.requestedCount = min(max(Self.intValue(object?["count"]) ?? 1, 1), 4)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func jsonObject(from input: String?) -> [String: Any]? {
        guard let input else { return nil }
        guard let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

}

/// Shared animated dot surface used by image generation placeholders and MiniApp
/// streaming cards. Kept internal so chat surfaces can reuse the same motion language.
struct ChatGeneratedImageDotPlaceholder: View {
    let aspectRatio: CGFloat
    var cornerRadius: CGFloat = AmberTheme.radiusXLarge
    var showsChrome: Bool = true
    /// When false, freeze at a calm phase (no 30fps TimelineView).
    var isAnimating: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let period: TimeInterval = 2.2

    var body: some View {
        Group {
            if reduceMotion || !isAnimating {
                Canvas { context, size in
                    drawDots(context: context, size: size, phase: 0.28)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        drawDots(context: context, size: size, phase: phase(at: timeline.date))
                    }
                }
            }
        }
        .modifier(ChatWidthDrivenAspectRatio(aspectRatio: aspectRatio))
        .background(
            showsChrome ? AmberTheme.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            if showsChrome {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    private func drawDots(context: GraphicsContext, size: CGSize, phase: CGFloat) {
        let padding: CGFloat = 20
        let spacing: CGFloat = 14
        let dotRadius: CGFloat = 1.6
        let drawingWidth = max(size.width - padding * 2, spacing)
        let drawingHeight = max(size.height - padding * 2, spacing)
        let columns = max(Int(drawingWidth / spacing), 1)
        let rows = max(Int(drawingHeight / spacing), 1)
        let xOffset = padding + (drawingWidth - CGFloat(columns - 1) * spacing) / 2
        let yOffset = padding + (drawingHeight - CGFloat(rows - 1) * spacing) / 2
        let diagonalRange = max(CGFloat(columns + rows), 1)

        for column in 0..<columns {
            for row in 0..<rows {
                let diagonal = CGFloat(column + row) / diagonalRange
                let wavePhase = (phase + diagonal).truncatingRemainder(dividingBy: 1)
                let distance = abs(wavePhase - 0.5) * 2
                let energy = max(0, 1 - distance)
                let alpha = min(max(0.10 + 0.40 * energy, 0.08), 0.54)
                let radius = dotRadius + 0.7 * energy
                let color = energy > 0.64
                    ? AmberTheme.accent.opacity(0.18 + 0.18 * energy)
                    : AmberTheme.muted.opacity(alpha)
                let x = xOffset + CGFloat(column) * spacing
                let y = yOffset + CGFloat(row) * spacing
                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(color)
                )
            }
        }
    }
}

/// 宽度驱动的宽高比:自定义 Layout 在同一布局 pass 内由宽度 proposal 直接推导
/// 高度(height = width / aspectRatio),首帧即正确,消除旧实现「fallback 220 →
/// onGeometryChange 回填宽度再修正」的一帧高度跳变(cell 新建/复用重进视口都会重演)。
/// UIHostingConfiguration self-sizing 的垂直 proposal 是 estimated cell 高度,不可信;
/// 宽度 proposal 始终正确,所以只信宽度。
private struct ChatWidthDrivenAspectRatio: ViewModifier {
    let aspectRatio: CGFloat

    func body(content: Content) -> some View {
        ChatWidthAspectLayout(aspectRatio: aspectRatio) {
            content
        }
    }
}

private struct ChatWidthAspectLayout: Layout {
    let aspectRatio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let safeAspect = max(aspectRatio, 0.1)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            // 宽度 proposal 缺失/无穷时的兜底,等效旧实现的 220 高 fallback。
            width = 220 * safeAspect
        }
        return CGSize(width: width, height: width / safeAspect)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

struct ChatGeneratedImageAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.985)
            .onAppear {
                guard !appeared else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
                    appeared = true
                }
            }
    }
}

private struct ChatGeneratedImageActionLabel: View {
    let title: String
    let systemImage: String
    let foreground: Color
    let fill: Color
    var isWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(foreground)
            } else {
                Image(systemName: systemImage)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }

            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(fill, in: Capsule())
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: title)
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: systemImage)
    }
}

private struct ChatGeneratedImageTile: View {
    let urlString: String
    var display = ChatGeneratedImageRequestDisplay(toolInput: nil)
    var onModify: (String, String, String) -> Void = { _, _, _ in }
    var allowsModify: Bool = true
    var toolCallID: String? = nil
    @Environment(\.chatMessageEditingAllowed) private var messageEditingAllowed

    private var canModify: Bool { allowsModify && messageEditingAllowed }
    @State private var saveState: ChatGeneratedImagePhotoSaveState = .idle
    @State private var saveAlert: ChatGeneratedImageSaveAlert?
    @State private var dataImageState: ChatDataImageLoadState = .loading
    @State private var previewTarget: ChatGeneratedImagePreviewTarget?
    @State private var editTarget: ChatGeneratedImageEditTarget?

    private var isDataURL: Bool { urlString.hasPrefix("data:") }

    private var url: URL? {
        IOSImageGenerationRepository.resolvedImageURL(from: urlString)
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isDataURL {
                    switch dataImageState {
                    case .success(let decodedDataImage):
                        Image(uiImage: decodedDataImage)
                            .resizable()
                            .scaledToFit()
                            .modifier(ChatGeneratedImageAppearModifier())
                    case .loading:
                        ProgressView()
                            .tint(AmberTheme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .modifier(ChatGeneratedImageAppearModifier())
                        case .failure:
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AmberTheme.accentRed)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .empty:
                            ProgressView()
                                .tint(AmberTheme.accent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ChatWidthDrivenAspectRatio(aspectRatio: display.aspectRatio))
            .contentShape(Rectangle())
            .onTapGesture {
                let image: UIImage?
                if case .success(let loadedImage) = dataImageState {
                    image = loadedImage
                } else {
                    image = nil
                }
                previewTarget = ChatGeneratedImagePreviewTarget(urlString: urlString, image: image)
            }
            .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }
            .task(id: urlString) {
                guard isDataURL else { return }
                dataImageState = .loading
                let resolved = await ChatDataImageLoadState.resolve(urlString: urlString)
                guard !Task.isCancelled else { return }
                dataImageState = resolved
            }

            if url != nil || isDataURL {
                HStack(spacing: 6) {
                    if let url {
                        ShareLink(item: url) {
                            generatedImageShareLabel
                        }
                        .accessibilityLabel("分享图片")
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.94, haptic: .lightImpact))
                    } else if case .success(let decodedDataImage) = dataImageState {
                        let sharedImage = Image(uiImage: decodedDataImage)
                        ShareLink(item: sharedImage, preview: SharePreview("生成的图片", image: sharedImage)) {
                            generatedImageShareLabel
                        }
                        .accessibilityLabel("分享图片")
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.94, haptic: .lightImpact))
                    } else {
                        // 解码完成前先占住同尺寸的位置，避免出现时挤动保存/修改按钮。
                        generatedImageShareLabel
                            .opacity(0.4)
                            .accessibilityHidden(true)
                    }

                    Button {
                        saveImageToPhotos()
                    } label: {
                        ChatGeneratedImageActionLabel(
                            title: saveState.title,
                            systemImage: saveState.systemImage,
                            foreground: saveState == .saved ? AmberTheme.accentGreen : AmberTheme.accent,
                            fill: saveState == .saved ? AmberTheme.accentGreen.opacity(0.10) : AmberTheme.accentTint,
                            isWorking: saveState == .saving
                        )
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .lightImpact))
                    .disabled(saveState != .idle)
                    .accessibilityLabel("保存图片到相册")

                    Button {
                        editTarget = ChatGeneratedImageEditTarget(
                            urlString: urlString,
                            aspectRatio: display.aspectRatioTitle
                        )
                    } label: {
                        ChatGeneratedImageActionLabel(
                            title: "修改",
                            systemImage: "wand.and.stars",
                            foreground: canModify ? AmberTheme.accent : AmberTheme.muted,
                            fill: canModify ? AmberTheme.accentTint : AmberTheme.surface2
                        )
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
                    .disabled(!canModify)
                    .accessibilityLabel(canModify ? "修改图片" : (messageEditingAllowed ? "生成中，暂不可修改图片" : "只读会话中不可修改图片"))
                }
            }
        }
        .chatIslandToolAnchorHighlight(
            toolCallID: toolCallID,
            cornerRadius: AmberTheme.radiusXLarge
        )
        .fullScreenCover(item: $previewTarget) { target in
            ChatGeneratedImagePreview(urlString: target.urlString, image: target.image)
        }
        .sheet(item: $editTarget) { target in
            ChatGeneratedImageEditSheet { prompt in
                onModify(target.urlString, prompt, target.aspectRatio)
            }
        }
        .alert(item: $saveAlert) { alert in
            Alert(
                title: Text("保存失败"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var generatedImageShareLabel: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .frame(width: 36, height: 28)
            .background(AmberTheme.accentTint, in: Capsule())
    }

    private func saveImageToPhotos() {
        guard saveState == .idle else { return }
        saveState = .saving
        Task {
            do {
                try await ChatGeneratedImagePhotoWriter.write(urlString)
                await MainActor.run {
                    saveState = .saved
                    AmberHaptics.trigger(.success)
                }
            } catch {
                await MainActor.run {
                    saveState = .idle
                    saveAlert = ChatGeneratedImageSaveAlert(message: error.localizedDescription)
                    AmberHaptics.trigger(.error)
                }
            }
        }
    }

}

private enum ChatGeneratedImagePhotoSaveState: Equatable {
    case idle
    case saving
    case saved

    var title: String {
        switch self {
        case .idle: "保存"
        case .saving: "保存中"
        case .saved: "已保存"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "square.and.arrow.down"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark"
        }
    }
}

private struct ChatGeneratedImageSaveAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct ChatGeneratedImagePreviewTarget: Identifiable {
    let id = UUID()
    let urlString: String
    let image: UIImage?
}

private struct ChatGeneratedImageEditTarget: Identifiable {
    let id = UUID()
    let urlString: String
    let aspectRatio: String
}

struct ChatGeneratedImagePreview: View {
    let urlString: String
    @Environment(\.dismiss) private var dismiss
    @State private var dataImageState: ChatDataImageLoadState = .loading
    @State private var dragOffset: CGFloat = 0

    init(urlString: String, image: UIImage?) {
        self.urlString = urlString
        _dataImageState = State(initialValue: image.map(ChatDataImageLoadState.success) ?? .loading)
    }

    private var isDataURL: Bool { urlString.hasPrefix("data:") }
    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            imageContent
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset)
                .opacity(max(0.45, 1 - abs(dragOffset) / 360))
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            dragOffset = value.translation.height
                        }
                        .onEnded { value in
                            let shouldDismiss = abs(value.translation.height) > 140
                                || abs(value.predictedEndTranslation.height) > 220
                            if shouldDismiss {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )

            HStack(spacing: 12) {
                previewShareButton

                Button {
                    dismiss()
                } label: {
                    previewControlLabel(systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭大图")
            }
            // 36pt 圆放在 44pt 热区内，padding 各减 4，可见圆位置与改动前一致。
            .padding(.top, 16)
            .padding(.trailing, 12)
        }
        .task(id: urlString) {
            guard isDataURL else { return }
            if case .success = dataImageState { return }
            dataImageState = .loading
            let resolved = await ChatDataImageLoadState.resolve(urlString: urlString)
            guard !Task.isCancelled else { return }
            dataImageState = resolved
        }
    }

    @ViewBuilder
    private var previewShareButton: some View {
        if case .success(let image) = dataImageState {
            let sharedImage = Image(uiImage: image)
            ShareLink(item: sharedImage, preview: SharePreview("生成的图片", image: sharedImage)) {
                previewControlLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享图片")
        } else if !isDataURL, let url {
            ShareLink(item: url) {
                previewControlLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享图片")
        }
    }

    private func previewControlLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.18), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var imageContent: some View {
        if isDataURL {
            switch dataImageState {
            case .success(let decodedDataImage):
                Image(uiImage: decodedDataImage)
                    .resizable()
                    .scaledToFit()
            case .loading:
                ProgressView()
                    .tint(.white)
            case .failure:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                case .empty:
                    ProgressView()
                        .tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

}

private struct ChatGeneratedImageEditSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @FocusState private var focused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("修改要求")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 160)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                        }

                    if prompt.isEmpty {
                        Text("例如：保留构图，把背景改成雪山，把服装改成蓝色。")
                            .font(.body)
                            .foregroundStyle(AmberTheme.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .navigationTitle("修改图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") {
                        let value = trimmedPrompt
                        guard !value.isEmpty else { return }
                        onSubmit(value)
                        dismiss()
                    }
                    .disabled(trimmedPrompt.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            focused = true
        }
    }
}

/// A user-sent image attachment, right-aligned and width-constrained like a chat bubble
/// (no share/save chrome). Sized to the image's real aspect ratio so the rounded clip
/// hugs the picture (no transparent letterbox). Decodes `data:` base64 URLs.
private struct ChatUserImageTile: View {
    let urlString: String
    @State private var dataImageState: ChatDataImageLoadState = .loading
    @State private var previewTarget: ChatGeneratedImagePreviewTarget?

    private var isDataURL: Bool { urlString.hasPrefix("data:") }
    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

    private static let maxW: CGFloat = 220
    private static let maxH: CGFloat = 300

    var body: some View {
        imageView
            .contentShape(Rectangle())
            .onTapGesture {
                let image: UIImage?
                if case .success(let loadedImage) = dataImageState {
                    image = loadedImage
                } else {
                    image = nil
                }
                previewTarget = ChatGeneratedImagePreviewTarget(urlString: urlString, image: image)
            }
            .task(id: urlString) {
                guard isDataURL else { return }
                dataImageState = .loading
                let resolved = await ChatDataImageLoadState.resolve(urlString: urlString)
                guard !Task.isCancelled else { return }
                dataImageState = resolved
            }
            .fullScreenCover(item: $previewTarget) { target in
                ChatGeneratedImagePreview(urlString: target.urlString, image: target.image)
            }
    }

    @ViewBuilder
    private var imageView: some View {
        if isDataURL {
            switch dataImageState {
            case .success(let decoded):
            // Fixed frame sized to the image's real aspect (fitted within max), so the
            // view bounds == the picture and the rounded clip hugs it — no letterbox.
                let size = Self.fittedSize(decoded.size)
                Image(uiImage: decoded)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                    )
            case .loading:
                placeholder(failed: false)
            case .failure:
                placeholder(failed: true)
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(maxWidth: Self.maxW, maxHeight: Self.maxH)
                        .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
                case .failure:
                    placeholder(failed: true)
                default:
                    placeholder(failed: false)
                }
            }
        } else {
            placeholder(failed: true)
        }
    }

    private func placeholder(failed: Bool) -> some View {
        RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
            .fill(AmberTheme.surface2)
            .frame(width: 150, height: 190)
            .overlay(
                Group {
                    if failed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                    } else {
                        ProgressView().tint(AmberTheme.accent)
                    }
                }
            )
    }

    private static func fittedSize(_ s: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return CGSize(width: maxW, height: maxW) }
        let scale = min(maxW / s.width, maxH / s.height)
        return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }
}
