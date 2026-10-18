import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

extension ChatView {

    // MARK: - Input Bar

    var collapsesComposerForSiteMemoryApproval: Bool {
        guard let id = composerState.collapsedSiteMemoryComposerRequestId else { return false }
        return viewModel.pendingWebMountApproval?.id == id
    }

    func collapseSiteMemoryComposerIfNeeded() {
        guard let request = viewModel.pendingWebMountApproval, request.siteMemoryChanges != nil,
              composerState.collapsedSiteMemoryComposerRequestId == nil, composerState.approvalContainerHeight > 0,
              let minimumHeight = composerState.siteMemoryApprovalMinimumHeights[request.id], minimumHeight > 0,
              siteMemoryApprovalMaximumHeight + 1 < minimumHeight else { return }
        // Keep the text view mounted and the draft intact. The request owns the collapsed state;
        // releasing space must not immediately expand the dock and start a layout feedback loop.
        composerState.collapsedSiteMemoryComposerRequestId = request.id
    }

    var siteMemoryApprovalLayoutSignal: SiteMemoryApprovalLayoutSignal {
        let id = viewModel.pendingWebMountApproval?.id
        return .init(requestID: id, availableHeight: siteMemoryApprovalMaximumHeight,
                     minimumHeight: id.flatMap { composerState.siteMemoryApprovalMinimumHeights[$0] } ?? 0)
    }

    private var siteMemoryApprovalMaximumHeight: CGFloat {
        guard composerState.approvalContainerHeight > 0 else { return .infinity }
        // Measure the non-approval area directly. Subtracting total/card measurements from
        // separate layout callbacks feeds an animating card's height back into its own budget.
        let composerChrome: CGFloat = 6 + (composerState.isSubAgentBarVisible ? 4 : 8) + 8
        let topControls = ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + artifactShelfStripHeight
        return max(0, composerState.approvalContainerHeight - topControls - composerState.composerAuxiliaryHeight - composerChrome - composerState.subAgentActivityBarHeight)
    }

    private var pendingUserGateCards: some View {
        ChatComposerApprovalCards(
            viewModel: viewModel,
            onOpenSession: { webMountSessionAction(sessionId: $0) },
            maximumHeight: siteMemoryApprovalMaximumHeight,
            webMountApprovalTransition: webMountApprovalTransition,
            ishApprovalTransition: ishApprovalTransition,
            ishApprovalVisibilityAnimation: ishApprovalVisibilityAnimation,
            gateHighlightRequest: $composerState.gateHighlightRequest,
            siteMemoryApprovalMinimumHeights: $composerState.siteMemoryApprovalMinimumHeights
        )
    }

    var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if viewModel.hasPendingUserGate {
                    pendingUserGateCards
                        .transition(webMountApprovalTransition)
                }
            }
            .animation(webMountApprovalVisibilityAnimation, value: viewModel.pendingWebMountApproval?.id)

            // Keep auxiliary cards and the UIKit input mounted while making room for
            // a short approval viewport. Their state and attachment controls return together.
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.showsJevCompletionNotice {
                    JevCompletionCheckNotice {
                        viewModel.requestCompletionVerification()
                    }
                    .transition(.opacity)
                }

                if let record = displayedWebMountSession,
                   !webMountSessionIsCompact(record) {
                    AgentBrowserTaskCard(
                        record: record,
                        onCollapse: {
                            browserState.collapsedWebMountSessionId = record.id
                            browserState.expandedWebMountSessionId = nil
                        },
                        onHide: {
                            webMountController.sessionStore.hideCard(sessionId: record.id)
                            browserState.collapsedWebMountSessionId = nil
                            browserState.expandedWebMountSessionId = nil
                        }
                    ) {
                        openWebMountSession(sessionId: record.id)
                    }
                    .id(record.id)
                    .transition(browserTaskTransition)
                }

                if !viewModel.pendingImages.isEmpty {
                    ComposerPendingImageStrip(
                        items: viewModel.pendingImages.map {
                            .init(id: $0.id, previewData: $0.previewData)
                        },
                        onRemove: { viewModel.removePendingImage($0) },
                        status: chatImageAttachmentStatus
                    )
                }

                if let preview = viewModel.pendingSelectedFilePreview {
                    ComposerPendingFileCard(
                        fileName: preview.fileName,
                        byteSummary: preview.byteSummary,
                        isTruncated: preview.isTruncated,
                        footnote: IOSAppLocalization.string(
                            "发送后，已解析文本会保存进此会话上下文。",
                            defaultValue: "发送后，已解析文本会保存进此会话上下文。"
                        ),
                        onRemove: { viewModel.clearPendingSelectedFilePreview() }
                    )
                }

                if let error = viewModel.selectedFileContextError {
                    ComposerAttachmentStatusLabel(status: .error(error))
                }

                if viewModel.currentConversationIsOrchestratedChild,
                   let message = ChatComposerSendBlockReason.orchestratedThread.userVisibleMessage {
                    ComposerAttachmentStatusLabel(
                        status: .muted(message, systemImage: "arrow.triangle.branch")
                    )
                }

                if let error = viewModel.configurationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentAmber)
                        .lineLimit(3)
                }

                if composerState.isAttachExpanded {
                    attachmentGlassPanel
                        .transition(.scale(scale: 0.75, anchor: .bottomLeading).combined(with: .opacity))
                }

                if !viewModel.chatSuggestions.isEmpty, !viewModel.isGenerationActive {
                    ChatSuggestionStrip(suggestions: viewModel.chatSuggestions) { suggestion in
                        viewModel.fillInputFromSuggestion(suggestion)
                        composerState.isInputFocused = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 8) {
                        // P1-a: 排队条与整行 dock 同宽（右缘对齐发送键），空队列零占位。
                        if !viewModel.steerQueue.isEmpty {
                            ChatSteerQueueStrip(
                                entries: viewModel.steerQueue,
                                onRemove: { viewModel.removeSteerMessage(id: $0) }
                            )
                        }

                        VStack(spacing: 0) {
                            // Apple Music dock：左侧输入胶囊 + 右侧发送键；底对齐。
                            HStack(alignment: .bottom, spacing: 8) {
                                HStack(alignment: .center, spacing: 6) {
                                    ComposerAttachToggleButton(
                                        isExpanded: composerState.isAttachExpanded,
                                        isBusy: viewModel.isAttachingSelectedFile,
                                        // 生成中允许加附件以便入队；识图中/审批中/读文件中仍禁用。
                                        isDisabled: viewModel.isRecognizingImages
                                            || viewModel.isAttachingSelectedFile
                                            || hasPendingComposerGate
                                            || viewModel.currentConversationIsOrchestratedChild
                                    ) {
                                        withAnimation(.bouncy(duration: 0.42, extraBounce: 0.14)) {
                                            composerState.isAttachExpanded.toggle()
                                        }
                                    }

                                    ZStack(alignment: .leading) {
                                        ComposerInputTextView(
                                            text: $viewModel.inputText,
                                            height: $composerState.composerInputHeight,
                                            isFocused: inputFocusBinding,
                                            isEnabled: !hasPendingComposerGate
                                                && !viewModel.currentConversationIsOrchestratedChild,
                                            sendOnEnter: sharedSettings.displaySetting.sendOnEnter,
                                            controller: composerInputController,
                                            onSubmit: sendComposerMessage
                                        )
                                        .frame(height: composerState.composerInputHeight)

                                        if viewModel.inputText.isEmpty {
                                            Text(inputPlaceholder)
                                                .font(.body)
                                                .foregroundStyle(AmberTheme.muted2)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .frame(minHeight: 40)
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, 18)
                                .padding(.vertical, 5)
                                .composerDockGlass(cornerRadius: 27)

                                ComposerDockSendButton(
                                    isLoading: isComposerStopMode,
                                    sendEnabled: sendEnabled,
                                    diameter: 54,
                                    onSend: sendComposerMessage,
                                    onStop: {
                                        if viewModel.isRecognizingImages {
                                            viewModel.cancelVisionRecognition()
                                        } else {
                                            viewModel.cancelGeneration()
                                        }
                                    }
                                )
                            }

                                HStack {
                                    Button {
                                        openComposerModelSheet()
                                    } label: {
                                        Text(composerModelLabel)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AmberTheme.foreground2)
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .frame(height: 30)
                                            .composerDockGlass(cornerRadius: 15)
                                    }
                                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
                                    .frame(minHeight: 44)
                                    .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .accessibilityLabel("切换模型，当前 \(composerModelLabel)")

                                    Spacer()

                                    HStack(spacing: 8) {
                                        ComposerIconButton(
                                            koboyo: .solidThoughtCloud,
                                            accessibilityLabel: "设置思考等级",
                                            size: 34,
                                            symbolSize: 15
                                        ) {
                                            toggleComposerPanel(.thinking)
                                        }
                                        .accessibilityValue(reasoningAccessibilityValue)
                                        .popover(isPresented: popoverBinding(for: .thinking), arrowEdge: .bottom) {
                                            ComposerThinkingPanel(
                                                selectedOption: selectedReasoningBinding,
                                                options: availableReasoningOptions,
                                                isAvailable: reasoningIsAvailable
                                            ) { _ in composerState.activeComposerPanel = nil }
                                            .presentationCompactAdaptation(.popover)
                                        }

                                        ChatContextControl(
                                            viewModel: viewModel,
                                            isPresented: popoverBinding(for: .context),
                                            jevSummaryRunId: jevSummaryRunId,
                                            onOpen: { toggleComposerPanel(.context) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 2)
                                .padding(.top, 10)
                                // 常驻布局、只折叠高度：收键盘时整个 dock 随键盘下移，被移除的视图
                                // 不跟随这段位移，会停在原地/往上飞。顶对齐折叠让它贴着输入行一起下沉并渐隐。
                                .frame(height: showsComposerMeta ? nil : 0, alignment: .top)
                                .opacity(showsComposerMeta ? 1 : 0)
                                .allowsHitTesting(showsComposerMeta)
                                .accessibilityHidden(!showsComposerMeta)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: viewModel.pendingWebMountApproval?.siteMemoryChanges != nil)
            .frame(height: collapsesComposerForSiteMemoryApproval ? 0 : nil, alignment: .top)
            // 只在折叠时贴边裁切；展开时外扩裁切框，避免削掉发送键/输入胶囊的玻璃边缘。
            .clipShape(Rectangle().inset(by: collapsesComposerForSiteMemoryApproval ? 0 : -20))
            .opacity(collapsesComposerForSiteMemoryApproval ? 0 : 1)
            .allowsHitTesting(!collapsesComposerForSiteMemoryApproval)
            .accessibilityHidden(collapsesComposerForSiteMemoryApproval)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(composerState.composerAuxiliaryHeight - height) > 0.5 { composerState.composerAuxiliaryHeight = height }
            }
        }
        .padding(.horizontal, ChatLayout.contentHorizontalInset)
        .padding(.top, composerState.isSubAgentBarVisible ? 4 : 8)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: showsComposerMeta)
        // 完成瞬间建议条插入会让 composer 长高一截：旧实现里转场动画只管建议条
        // 自己，时间轴可用高度一帧被吃掉 → 底部锚定内容跳一下。给建议条显隐加
        // 布局动画，高度连续变化，滚动层逐帧重锚，内容平滑上移。
        .animation(.easeOut(duration: 0.2), value: viewModel.chatSuggestions.isEmpty)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: viewModel.showsJevCompletionNotice)
        .animation(browserTaskVisibilityAnimation, value: displayedWebMountSession?.id)
    }

    var browserTaskTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 12))
                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(y: 6))
                .combined(with: .scale(scale: 0.99, anchor: .bottom))
        )
    }

    var browserTaskVisibilityAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var ishApprovalTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(y: 4))
                .combined(with: .scale(scale: 0.995, anchor: .bottom))
        )
    }

    private var webMountApprovalTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .offset(y: 4))
        )
    }

    private var webMountApprovalVisibilityAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return viewModel.pendingWebMountApproval == nil
            ? .easeIn(duration: 0.16)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var ishApprovalVisibilityAnimation: Animation? {
        if reduceMotion { return .easeOut(duration: 0.12) }
        if viewModel.pendingIshHandoffApproval == nil {
            return .easeIn(duration: 0.16)
        }
        return .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var sendEnabled: Bool {
        sendEnabled(for: viewModel.inputText)
    }

    private func sendEnabled(for text: String) -> Bool {
        _ = sharedSettings.revision
        return viewModel.composerSendBlockReason(for: text) == nil
    }

    private func sendComposerMessage() {
        let committedText = composerInputController.committedText() ?? viewModel.inputText
        if committedText != viewModel.inputText {
            viewModel.inputText = committedText
        }
        guard sendEnabled(for: committedText) else { return }
        viewportState.followPaused = false
        viewModel.sendMessage(startsGenerationAfterInsertion: true)
    }

    private func openComposerModelSheet() {
        composerState.activeComposerPanel = nil
        if let currentText = composerInputController.currentText(),
           currentText != viewModel.inputText {
            viewModel.inputText = currentText
        }
        composerState.isModelSheetPresented = true
        Task { @MainActor in
            await Task.yield()
            dismissKeyboard()
        }
    }

    var configurationIssue: ChatConfigurationIssue? {
        _ = sharedSettings.revision
        return viewModel.configurationIssue
    }

    private var inputPlaceholder: String {
        let key: String = switch configurationIssue {
        case .some(.missingAPIKey):
            "先添加 API Key"
        case .some(.invalidBaseURL):
            "先修正服务商地址"
        case .some(.missingModel):
            "先选择模型"
        case .some(.missingProvider):
            "先配置服务商"
        case .some(.unsupportedProvider):
            "先切换服务商"
        case .some(.codexNotSignedIn):
            "先登录 Codex"
        case .some(.grokNotSignedIn):
            "先登录 Grok"
        case .some(.geminiNotSignedIn):
            "先登录 Antigravity"
        case .some(.providerDisabled):
            "先启用服务商"
        case .none:
            "发消息给 Amber..."
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    private var hasPendingToolApproval: Bool {
        viewModel.pendingMemoryApproval != nil ||
            viewModel.pendingSearchApproval != nil ||
            viewModel.pendingWebMountApproval != nil ||
            viewModel.pendingWorkspaceApproval != nil ||
            viewModel.pendingIshHandoffApproval != nil ||
            viewModel.pendingMcpApproval != nil ||
            viewModel.pendingCouncilApproval != nil ||
            viewModel.pendingAskUser != nil ||
            viewModel.pendingRecipeApproval != nil
    }

    var hasPendingComposerGate: Bool {
        hasPendingToolApproval || viewModel.pendingToolOutcomeUnknown != nil
    }

    private var isCurrentConversationRunActive: Bool {
        viewModel.isGenerationActiveForCurrentConversation ||
            hasPendingToolApproval ||
            viewModel.isLoading
    }

    /// P1-a: 生成中且有可入队内容（文本/图/文件）时，发送键翻转为「发送（加入队列）」；
    /// 无内容时保持「停止」。run 激活但发送被拦截（队列满）时保持停止键。
    private var isComposerStopMode: Bool {
        Self.composerSendButtonIsStopMode(
            isRunActive: isCurrentConversationRunActive,
            isRecognizingImages: viewModel.isRecognizingImages,
            hasSendableContent: hasComposerSendableContent,
            sendEnabled: sendEnabled
        )
    }

    static func composerSendButtonIsStopMode(
        isRunActive: Bool,
        isRecognizingImages: Bool,
        hasSendableContent: Bool,
        sendEnabled: Bool
    ) -> Bool {
        guard isRunActive || isRecognizingImages else { return false }
        if isRecognizingImages { return true }
        return !hasSendableContent || !sendEnabled
    }

    private var hasComposerSendableContent: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.pendingImages.isEmpty
            || viewModel.pendingSelectedFilePreview != nil
    }

    private var showsComposerMeta: Bool {
        composerState.isInputFocused ||
            composerState.activeComposerPanel != nil ||
            composerState.isModelSheetPresented ||
            configurationIssue != nil
    }

    private var composerModelLabel: String {
        let modelId = composerCurrentModelID
        return modelId.isEmpty ? "未选择模型" : modelId
    }

    private var composerCurrentModelID: String {
        let modelId = sharedSettings.snapshot.getCurrentChatModel()?.modelId ?? settingsStore.modelId
        return modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var composerCurrentModelSelection: String {
        _ = sharedSettings.revision
        return sharedSettings.snapshot.getCurrentChatModel()?.id.description() ?? composerCurrentModelID
    }

    private var selectedReasoningOption: ComposerReasoningOption {
        _ = sharedSettings.revision
        return ComposerReasoningOption(reasoningLevel: sharedSettings.currentAssistantReasoningLevel())
    }

    private var availableReasoningOptions: [ComposerReasoningOption] {
        _ = sharedSettings.revision
        let options = sharedSettings.currentAssistantReasoningLevels().map(ComposerReasoningOption.init)
        var seen = Set<ComposerReasoningOption>()
        let unique = options.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.off] : unique
    }

    private var reasoningIsAvailable: Bool {
        availableReasoningOptions.contains { $0 != .off }
    }

    // Reasoning effort shown on the thinking pill (e.g. "Auto"); nil when reasoning is off.
    var composerReasoningLabel: String? {
        let option = selectedReasoningOption
        guard option != .off else { return nil }
        return option.title
    }

    private var selectedReasoningBinding: Binding<ComposerReasoningOption> {
        Binding(
            get: { selectedReasoningOption },
            set: { option in
                sharedSettings.updateCurrentAssistantReasoningLevel(option.reasoningLevel)
                viewModel.reasoningLevel = sharedSettings.currentAssistantReasoningLevel()
            }
        )
    }

    private var inputFocusBinding: Binding<Bool> {
        Binding(
            get: { composerState.isInputFocused },
            set: { composerState.isInputFocused = $0 }
        )
    }

    private var reasoningAccessibilityValue: String {
        reasoningIsAvailable
            ? selectedReasoningOption.title
            : IOSAppLocalization.string(
                "当前模型未标记 Reasoning",
                defaultValue: "当前模型未标记 Reasoning"
            )
    }

    private func toggleComposerPanel(_ panel: ComposerPanel) {
        composerState.activeComposerPanel = composerState.activeComposerPanel == panel ? nil : panel
    }

}
