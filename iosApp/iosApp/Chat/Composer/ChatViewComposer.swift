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

    var collapsesComposerForDuetPanel: Bool {
        composerState.activeDuetTab != .chat
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
        let _ = ChatRenderProbe.record("composer-body")
        return VStack(alignment: .leading, spacing: 6) {
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
                        },
                        showsStatus: false
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

                VStack(spacing: collapsesComposerForDuetPanel ? 0 : 8) {
                        // P1-a: 排队条与整行 dock 同宽（右缘对齐发送键），空队列零占位。
                        if !viewModel.steerQueue.isEmpty && !collapsesComposerForDuetPanel {
                            ChatSteerQueueStrip(
                                entries: viewModel.steerQueue,
                                onRemove: { viewModel.removeSteerMessage(id: $0) }
                            )
                        }

                        // Inline Argon Panels (02 Tasks / 03 Hubs) when composer input is collapsed
                        if collapsesComposerForDuetPanel {
                            let availableHeight = chatSize.height > 0 ? chatSize.height : 778
                            let topClearance = ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + artifactShelfStripHeight + 28
                            let panelHeight = min(
                                max(360, availableHeight - topClearance),
                                availableHeight * 0.78
                            )
                            let panelShape = UnevenRoundedRectangle(
                                topLeadingRadius: 28,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 28,
                                style: .continuous
                            )
                            let handleHeaderDragChanged: (DragGesture.Value) -> Void = { value in
                                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                composerState.inlineDuetPanelDragOffsetY = max(0, value.translation.height)
                            }
                            let handleHeaderDragEnded: (DragGesture.Value) -> Void = { value in
                                let shouldDismiss = ChatSheetDismissSmoothnessPolicy.shouldDismissInlineDuetPanel(
                                    translationY: value.translation.height,
                                    predictedEndTranslationY: value.predictedEndTranslation.height
                                )
                                withAnimation(.snappy(duration: 0.22)) {
                                    composerState.inlineDuetPanelDragOffsetY = 0
                                    if shouldDismiss {
                                        composerState.activeDuetTab = .chat
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 0) {
                                if composerState.activeDuetTab == .tasks {
                                    AmberDuetTaskCenterCard(
                                        gateway: MacGatewayStore.shared,
                                        subAgentStore: activityStore,
                                        hubStore: AmberHubStore.shared,
                                        onOpenFullTaskBoard: {
                                            composerState.activeDuetTab = .chat
                                            router.navigate(to: .macTasks)
                                        },
                                        onOpenTask: { task in
                                            composerState.activeDuetTab = .chat
                                            openUnifiedTask(task)
                                        },
                                        onFollowupTask: { task in
                                            withAnimation(.snappy(duration: 0.22)) {
                                                followupTaskInChat(task)
                                            }
                                        },
                                        onDismissPanel: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                composerState.activeDuetTab = .chat
                                            }
                                        },
                                        onHeaderDragChanged: handleHeaderDragChanged,
                                        onHeaderDragEnded: handleHeaderDragEnded
                                    )
                                } else if composerState.activeDuetTab == .hubs {
                                    AmberDuetHubsCard(
                                        hubStore: AmberHubStore.shared,
                                        conversationStore: conversationStore,
                                        gateway: MacGatewayStore.shared,
                                        subAgentStore: activityStore,
                                        onSelectHub: { _ in
                                            syncIslandPresentation()
                                        },
                                        onDismissPanel: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                composerState.activeDuetTab = .chat
                                            }
                                        },
                                        onHeaderDragChanged: handleHeaderDragChanged,
                                        onHeaderDragEnded: handleHeaderDragEnded
                                    )
                                }
                            }
                            .padding(.bottom, 64)
                            .frame(maxWidth: .infinity)
                            .frame(height: panelHeight, alignment: .top)
                            .clipShape(panelShape)
                            .background(AmberTheme.background, in: panelShape)
                            .overlay(panelShape.stroke(AmberTheme.border, lineWidth: 0.8))
                            .offset(y: max(0, composerState.inlineDuetPanelDragOffsetY))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        VStack(spacing: 6) {
                            if isCloudMainDialogueActive,
                               let targetWorkItemId = MacGatewayStore.shared.selectedCloudDialogueWorkItemId,
                               !collapsesComposerForDuetPanel {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AmberTheme.accent)
                                    Text("补充云端任务：\(targetWorkItemId)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        MacGatewayStore.shared.selectedCloudDialogueWorkItemId = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(AmberTheme.muted)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(AmberTheme.surface, in: Capsule(style: .continuous))
                            }

                            if isCloudMainDialogueActive,
                               let cloudError = composerState.cloudDialogueErrorMessage,
                               !collapsesComposerForDuetPanel {
                                Text(verbatim: cloudError)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }

                            // Apple Music dock：左侧输入胶囊 + 右侧发送键；
                            // 打开「任务」或「中心」面板时折叠高度为 0，但保持 UITextView 挂载以完整保留草稿。
                            // 独立成叶子 View，把高频变化的 inputText 与 composerInputHeight 观察范围锁死在行内，
                            // 避免每敲一个字或换行都触发整页 ChatView（顶栏、时间轴、底栏）重算 body。
                            ChatComposerInputDockRow(
                                viewModel: viewModel,
                                sharedSettings: sharedSettings,
                                composerInputController: composerInputController,
                                isAttachExpanded: composerState.isAttachExpanded,
                                hasPendingComposerGate: hasPendingComposerGate,
                                isRunActive: isCurrentConversationRunActive,
                                isCloudMainDialogueActive: isCloudMainDialogueActive,
                                isSubmittingCloudDialogue: composerState.isSubmittingCloudDialogue,
                                collapsesComposerForDuetPanel: collapsesComposerForDuetPanel,
                                inputPlaceholder: inputPlaceholder,
                                isInputFocused: inputFocusBinding,
                                onToggleAttach: {
                                    withAnimation(.bouncy(duration: 0.42, extraBounce: 0.14)) {
                                        composerState.isAttachExpanded.toggle()
                                    }
                                },
                                onSendMessage: sendComposerMessage,
                                onStopGeneration: {
                                    if viewModel.isRecognizingImages {
                                        viewModel.cancelVisionRecognition()
                                    } else {
                                        viewModel.cancelGeneration()
                                    }
                                }
                            )
                            .frame(height: collapsesComposerForDuetPanel ? 0 : nil, alignment: .top)
                            .opacity(collapsesComposerForDuetPanel ? 0 : 1)
                            .allowsHitTesting(!collapsesComposerForDuetPanel)
                            .accessibilityHidden(collapsesComposerForDuetPanel)

                            ZStack(alignment: .center) {
                                if !collapsesComposerForDuetPanel {
                                    AmberGlassGroup(spacing: 8) {
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
                                    }
                                    .padding(.horizontal, 2)
                                    .padding(.top, 10)
                                    .opacity(showsComposerMeta ? 1 : 0)
                                    .allowsHitTesting(showsComposerMeta)
                                    .accessibilityHidden(!showsComposerMeta)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsComposerMeta)
                                }

                                AmberDuetBottomSwitcher(
                                    selectedTab: composerState.activeDuetTab,
                                    gateway: MacGatewayStore.shared,
                                    subAgentStore: activityStore,
                                    hubStore: AmberHubStore.shared,
                                    onSelectTab: { tab in
                                        withAnimation(.snappy(duration: 0.24)) {
                                            selectDuetTab(tab)
                                        }
                                    },
                                    onOpenTasks: {
                                        withAnimation(.snappy(duration: 0.24)) {
                                            selectDuetTab(.tasks)
                                        }
                                    },
                                    onOpenWorkspace: {
                                        withAnimation(.snappy(duration: 0.24)) {
                                            selectDuetTab(.hubs)
                                        }
                                    },
                                    onSelectHost: { useCloud in
                                        withAnimation(.snappy(duration: 0.24)) {
                                            selectMainDialogueHost(useCloud: useCloud)
                                        }
                                    },
                                    onOpenCloudPairingSettings: {
                                        isPresentingCloudGatewaySettings = true
                                    }
                                )
                                .padding(.horizontal, collapsesComposerForDuetPanel ? 18 : 0)
                                .padding(.top, 8)
                                .padding(.bottom, collapsesComposerForDuetPanel ? 16 : 0)
                                .opacity(!collapsesComposerForDuetPanel && showsComposerMeta ? 0 : 1)
                                .allowsHitTesting(collapsesComposerForDuetPanel || !showsComposerMeta)
                                .accessibilityHidden(!collapsesComposerForDuetPanel && showsComposerMeta)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsComposerMeta)
                            }
                            .padding(.top, collapsesComposerForDuetPanel ? -66 : 0)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: viewModel.pendingWebMountApproval?.siteMemoryChanges != nil)
            .frame(height: collapsesComposerForSiteMemoryApproval ? 0 : nil, alignment: .top)
            // 只在折叠时贴边裁切；展开时不得加 .clipShape，否则父层 masksToBounds 会形成离屏组，导致后台恢复前台时 iOS 26 .glassEffect 失去 CABackdropLayer 采样约 1s。
            .modifier(ComposerCollapseClipModifier(isCollapsed: collapsesComposerForSiteMemoryApproval))
            .opacity(collapsesComposerForSiteMemoryApproval ? 0 : 1)
            .allowsHitTesting(!collapsesComposerForSiteMemoryApproval)
            .accessibilityHidden(collapsesComposerForSiteMemoryApproval)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard viewModel.hasPendingUserGate else { return }
                if abs(composerState.composerAuxiliaryHeight - height) > 0.5 { composerState.composerAuxiliaryHeight = height }
            }
        }
        .padding(.horizontal, collapsesComposerForDuetPanel ? 0 : ChatLayout.contentHorizontalInset)
        .padding(.top, collapsesComposerForDuetPanel ? 0 : (composerState.isSubAgentBarVisible ? 4 : 8))
        .padding(.bottom, collapsesComposerForDuetPanel ? 0 : 16)
        .background(alignment: .bottom) {
            if !collapsesComposerForDuetPanel {
                LinearGradient(
                    colors: [
                        AmberTheme.background.opacity(0),
                        AmberTheme.background.opacity(0.95),
                        AmberTheme.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .padding(.top, -18)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
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

    var duetActiveTaskCount: Int {
        unifiedTaskGroups.activeCount
    }

    var duetNeedsAttentionCount: Int {
        unifiedTaskGroups.needsAttention.count
    }

    /// The panel's own aggregation, so the badge and the list can never disagree.
    var unifiedTaskGroups: AmberUnifiedTaskBuilder.Groups {
        AmberUnifiedTaskBuilder.buildTasks(
            gateway: MacGatewayStore.shared,
            subAgentStore: activityStore,
            hubStore: AmberHubStore.shared
        )
    }

    func currentConversationTaskSegments() -> [ChatTaskRunSegment] {
        taskCountCache.taskSegments(messages: viewModel.messages, isGenerationActive: viewModel.isGenerationActive)
    }

    /// A task card always opens the surface that already owns that work: the
    /// child transcript, the execution record, or the Mac board. Never a chat
    /// invented for it.
    @MainActor
    func openUnifiedTask(_ task: AmberUnifiedTaskItem) {
        switch task.destination {
        case .subAgentConversation(let conversationId):
            router.navigate(to: .subAgentConversation(id: conversationId))
        case .wakeConversation(let conversationId):
            router.navigate(to: .subAgentConversation(id: conversationId))
        case .executionRecord(let recordId):
            router.navigate(to: .executionTask(id: recordId))
        case .macBoard:
            router.navigate(to: .macTasks)
        case .cloudTaskDetail, .none:
            break
        }
    }

    var isCloudMainDialogueActive: Bool {
        MacGatewayStore.shared.connection != nil && MacGatewayStore.shared.isCloudMainDialogueSelected
    }

    private func sendEnabled(for text: String) -> Bool {
        if isCloudMainDialogueActive {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !composerState.isSubmittingCloudDialogue
        }
        _ = sharedSettings.revision
        return viewModel.composerSendBlockReason(for: text) == nil
    }

    private func sendComposerMessage() {
        let committedText = composerInputController.committedText() ?? viewModel.inputText
        if committedText != viewModel.inputText {
            viewModel.inputText = committedText
        }
        guard sendEnabled(for: committedText) else { return }
        if isCloudMainDialogueActive {
            sendCloudDialogueFromComposer(text: committedText)
            return
        }
        viewportState.followPaused = false
        viewModel.sendMessage(startsGenerationAfterInsertion: true)
    }

    private func sendCloudDialogueFromComposer(text: String) {
        let store = MacGatewayStore.shared
        let targetWorkItemId = store.selectedCloudDialogueWorkItemId
        let fingerprint = "\(targetWorkItemId ?? "main")\u{0000}\(text)"
        if let last = composerState.lastCloudDialogueFingerprint, last != fingerprint {
            composerState.activeCloudDialogueRequestId = UUID().uuidString.lowercased()
        }
        composerState.lastCloudDialogueFingerprint = fingerprint
        let reqId = composerState.activeCloudDialogueRequestId
        composerState.isSubmittingCloudDialogue = true
        composerState.cloudDialogueErrorMessage = nil

        Task { @MainActor in
            let result: Result<MacGatewayCloudDialogueReceipt, Error>
            if let targetWorkItemId {
                result = await store.sendCloudWorkItemInput(workItemId: targetWorkItemId, text: text, requestId: reqId)
            } else {
                result = await store.sendCloudDialogueMessage(text: text, requestId: reqId)
            }
            composerState.isSubmittingCloudDialogue = false
            switch result {
            case .success:
                viewModel.inputText = ""
                store.selectedCloudDialogueWorkItemId = nil
                composerState.activeCloudDialogueRequestId = UUID().uuidString.lowercased()
                composerState.lastCloudDialogueFingerprint = nil
                _ = await store.pollCloudDialogueEvents()
            case .failure(let error):
                composerState.cloudDialogueErrorMessage = error.localizedDescription
            }
        }
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
        if isCloudMainDialogueActive {
            let cloudKey = MacGatewayStore.shared.selectedCloudDialogueWorkItemId == nil
                ? "发消息给云端真身..."
                : "向选中云端任务追加补充说明..."
            return IOSAppLocalization.string(cloudKey, defaultValue: cloudKey)
        }
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
            composerState.isModelSheetPresented
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

    private var composerQuickModels: [ComposerModelOption] {
        _ = sharedSettings.revision
        return ComposerProviderGroup.currentConfiguration(
            sharedSettings: sharedSettings,
            currentModel: composerCurrentModelSelection
        ).flatMap(\.models)
    }

    private func selectComposerQuickModel(_ model: ComposerModelOption) {
        sharedSettings.setCurrentAssistantChatModelId(model.id)
        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        viewModel.reasoningLevel = sharedSettings.currentAssistantReasoningLevel()
        viewModel.bumpMessageRevision(reason: .settingsRefresh)
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

    // MARK: - Argon 3+1 Mode & Host Switcher Actions

    func selectDuetTab(_ tab: AmberDuetModeTab) {
        ChatRenderProbe.record("panel-select-tab")
        ChatRenderProbe.measureUs("us:panel-select-tab") {
            if let committed = composerInputController.committedText(), committed != viewModel.inputText {
                viewModel.inputText = committed
            }
            if tab != .chat {
                composerState.activeComposerPanel = nil
                composerState.isAttachExpanded = false
                dismissKeyboard()
            }
            composerState.activeDuetTab = tab
        }
    }

    func selectMainDialogueHost(useCloud: Bool) {
        let store = MacGatewayStore.shared
        guard store.connection != nil || !useCloud else {
            isPresentingCloudGatewaySettings = true
            return
        }
        store.setCloudMainDialogueSelected(useCloud)
        composerState.cloudDialogueErrorMessage = nil
        if composerState.activeDuetTab != .chat {
            composerState.activeDuetTab = .chat
        }
        syncIslandPresentation()
        if useCloud {
            Task { @MainActor in
                await store.refresh()
                _ = await store.pollCloudDialogueEvents()
            }
        }
    }

    func followupTaskInChat(_ followupTask: AmberUnifiedTaskItem) {
        if let committed = composerInputController.committedText(), committed != viewModel.inputText {
            viewModel.inputText = committed
        }
        composerState.exitBackgroundHandoffModePreservingDraft()
        composerState.activeDuetTab = .chat
        if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let actionTitle = followupTask.actionTitle {
                viewModel.inputText = "请继续处理「\(followupTask.title)」（\(actionTitle)）："
            } else {
                viewModel.inputText = "跟进任务「\(followupTask.title)」："
            }
        }
        composerState.isInputFocused = true
    }
}

private struct ChatComposerInputDockRow: View {
    let viewModel: ChatViewModel
    let sharedSettings: IOSSharedSettingsStore
    let composerInputController: ComposerInputController
    let isAttachExpanded: Bool
    let hasPendingComposerGate: Bool
    let isRunActive: Bool
    let isCloudMainDialogueActive: Bool
    let isSubmittingCloudDialogue: Bool
    let collapsesComposerForDuetPanel: Bool
    let inputPlaceholder: String
    @Binding var isInputFocused: Bool
    let onToggleAttach: () -> Void
    let onSendMessage: () -> Void
    let onStopGeneration: () -> Void

    @State private var composerInputHeight: CGFloat = 40

    var body: some View {
        @Bindable var bindableViewModel = viewModel
        let currentInputText = viewModel.inputText
        let trimmedNonEmpty = !currentInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSendableContent = trimmedNonEmpty
            || (!isCloudMainDialogueActive && (!viewModel.pendingImages.isEmpty || viewModel.pendingSelectedFilePreview != nil))
        let _ = sharedSettings.revision
        let isSendEnabled = isCloudMainDialogueActive
            ? (trimmedNonEmpty && !isSubmittingCloudDialogue)
            : (viewModel.composerSendBlockReason(for: currentInputText) == nil)
        let isStopMode = isCloudMainDialogueActive
            ? false
            : ChatView.composerSendButtonIsStopMode(
                isRunActive: isRunActive,
                isRecognizingImages: viewModel.isRecognizingImages,
                hasSendableContent: hasSendableContent,
                sendEnabled: isSendEnabled
            )

        AmberGlassGroup(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    ComposerAttachToggleButton(
                        isExpanded: isAttachExpanded,
                        isBusy: viewModel.isAttachingSelectedFile,
                        // 生成中允许加附件以便入队；识图中/审批中/读文件中仍禁用。
                        isDisabled: viewModel.isRecognizingImages
                            || viewModel.isAttachingSelectedFile
                            || hasPendingComposerGate
                            || viewModel.currentConversationIsOrchestratedChild,
                        action: onToggleAttach
                    )

                    ZStack(alignment: .leading) {
                        ComposerInputTextView(
                            text: $bindableViewModel.inputText,
                            height: $composerInputHeight,
                            isFocused: $isInputFocused,
                            isEnabled: !hasPendingComposerGate
                                && !viewModel.currentConversationIsOrchestratedChild
                                && !collapsesComposerForDuetPanel,
                            sendOnEnter: sharedSettings.displaySetting.sendOnEnter,
                            controller: composerInputController,
                            onSubmit: onSendMessage
                        )
                        .frame(height: composerInputHeight)

                        if currentInputText.isEmpty {
                            ComposerPlaceholderText(text: inputPlaceholder)
                        }
                    }
                    .frame(minHeight: 40)
                }
                .padding(.leading, 8)
                .padding(.trailing, 18)
                .padding(.vertical, 5)
                .composerDockGlass(cornerRadius: 27)

                ComposerDockSendButton(
                    isLoading: isStopMode,
                    sendEnabled: isSendEnabled,
                    diameter: 54,
                    onSend: onSendMessage,
                    onStop: onStopGeneration
                )
            }
        }
    }
}


private struct ComposerCollapseClipModifier: ViewModifier {
    let isCollapsed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCollapsed {
            content.clipped()
        } else {
            content
        }
    }
}
