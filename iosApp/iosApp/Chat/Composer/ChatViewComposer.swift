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

                VStack(spacing: collapsesComposerForDuetPanel ? 0 : 8) {
                        // P1-a: 排队条与整行 dock 同宽（右缘对齐发送键），空队列零占位。
                        if !viewModel.steerQueue.isEmpty && !collapsesComposerForDuetPanel {
                            ChatSteerQueueStrip(
                                entries: viewModel.steerQueue,
                                onRemove: { viewModel.removeSteerMessage(id: $0) }
                            )
                        }

                        if composerState.isBackgroundHandoffMode && !collapsesComposerForDuetPanel,
                           (composerState.handoffFollowupTask != nil || composerState.handoffErrorMessage != nil) {
                            handoffContextBanner
                        }

                        // Inline Argon Panels (02 Tasks / 03 Hubs) when composer input is collapsed
                        if collapsesComposerForDuetPanel {
                            VStack(alignment: .leading, spacing: 18) {
                                if composerState.activeDuetTab == .tasks {
                                    AmberDuetTaskCenterCard(
                                        conversationSegments: currentConversationTaskSegments(),
                                        gateway: MacGatewayStore.shared,
                                        subAgentStore: activityStore,
                                        hubStore: AmberHubStore.shared,
                                        onOpenFullTaskBoard: {
                                            composerState.activeDuetTab = .chat
                                            router.navigate(to: .macTasks)
                                        },
                                        onSelectTool: { tool in
                                            composerState.activeDuetTab = .chat
                                            duetSelectedToolTarget = ToolDetailTarget(tool: tool)
                                        },
                                        onFollowupTask: { task in
                                            withAnimation(.snappy(duration: 0.22)) {
                                                enterBackgroundHandoffMode(followupTask: task)
                                            }
                                        },
                                        onDismissPanel: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                composerState.activeDuetTab = .chat
                                            }
                                        }
                                    )
                                } else if composerState.activeDuetTab == .hubs {
                                    AmberDuetHubsCard(
                                        hubStore: AmberHubStore.shared,
                                        conversationStore: conversationStore,
                                        conversationSegments: currentConversationTaskSegments(),
                                        gateway: MacGatewayStore.shared,
                                        subAgentStore: activityStore,
                                        onSelectHub: { _ in
                                            syncIslandPresentation()
                                        },
                                        onDismissPanel: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                composerState.activeDuetTab = .chat
                                            }
                                        }
                                    )
                                }

                                Spacer(minLength: 0)

                                AmberDuetBottomSwitcher(
                                    selectedTab: composerState.activeDuetTab,
                                    activeTaskCount: duetActiveTaskCount,
                                    needsAttentionCount: duetNeedsAttentionCount,
                                    isBackgroundHandoffMode: false,
                                    handoffExecutionTarget: composerState.handoffExecutionTarget,
                                    activeHubTitle: AmberHubStore.shared.activeHub?.title,
                                    hubs: AmberHubStore.shared.hubs,
                                    cloudAgents: MacGatewayStore.shared.cloudAgents,
                                    selectedCloudAgentId: composerState.handoffSelectedCloudAgentId,
                                    onSelectTab: { tab in
                                        withAnimation(.snappy(duration: 0.22)) {
                                            selectDuetTab(tab)
                                        }
                                    },
                                    onOpenTasks: {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            selectDuetTab(.tasks)
                                        }
                                    },
                                    onOpenWorkspace: {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            selectDuetTab(.hubs)
                                        }
                                    },
                                    onDelegateCloudTask: {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            enterBackgroundHandoffMode()
                                        }
                                    },
                                    onSelectHub: { hubId in
                                        AmberHubStore.shared.selectHub(hubId)
                                        syncIslandPresentation()
                                    },
                                    onSelectExecutionTarget: { target in
                                        composerState.handoffExecutionTarget = target
                                        composerState.handoffErrorMessage = nil
                                    },
                                    onSelectCloudAgent: { agentId in
                                        composerState.handoffSelectedCloudAgentId = agentId
                                    },
                                    onExitHandoffMode: {
                                        withAnimation(.snappy(duration: 0.2)) {
                                            composerState.exitBackgroundHandoffModePreservingDraft()
                                        }
                                    }
                                )
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                                .padding(.bottom, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: max(420, (chatSize.height > 0 ? chatSize.height : 832) - 220))
                            .background(
                                AmberTheme.background,
                                in: UnevenRoundedRectangle(
                                    topLeadingRadius: 28,
                                    bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0,
                                    topTrailingRadius: 28,
                                    style: .continuous
                                )
                            )
                            .overlay(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 28,
                                    bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0,
                                    topTrailingRadius: 28,
                                    style: .continuous
                                )
                                .stroke(AmberTheme.border, lineWidth: 0.8)
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        VStack(spacing: 0) {
                            if composerState.isBackgroundHandoffMode, let followup = composerState.handoffFollowupTask, !collapsesComposerForDuetPanel {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AmberTheme.accent)
                                    Text("定向跟进任务：\(followup.title)")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button {
                                        withAnimation(.snappy(duration: 0.18)) {
                                            composerState.handoffFollowupTask = nil
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(AmberTheme.muted)
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("取消定向跟进")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AmberTheme.surface2.opacity(0.92))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(AmberTheme.accent.opacity(0.32), lineWidth: 0.8)
                                )
                                .padding(.horizontal, 6)
                                .padding(.bottom, 6)
                                .accessibilityIdentifier("chat.duet.followupTargetPill")
                            }

                            // Apple Music dock：左侧输入胶囊 + 右侧发送键（或在后台交办模式下原地变形为「交办 ↗」）；
                            // 打开「任务」或「中心」面板时折叠高度为 0，但保持 UITextView 挂载以完整保留草稿。
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
                                                && !viewModel.currentConversationIsOrchestratedChild
                                                && !collapsesComposerForDuetPanel,
                                            sendOnEnter: sharedSettings.displaySetting.sendOnEnter,
                                            controller: composerInputController,
                                            onSubmit: composerState.isBackgroundHandoffMode ? submitBackgroundHandoff : sendComposerMessage
                                        )
                                        .frame(height: composerState.composerInputHeight)

                                        if viewModel.inputText.isEmpty {
                                            ComposerPlaceholderText(
                                                text: composerState.isBackgroundHandoffMode ? "描述要后台交办的目标…" : inputPlaceholder
                                            )
                                        }
                                    }
                                    .frame(minHeight: 40)

                                    if composerState.isBackgroundHandoffMode {
                                        Button {
                                            withAnimation(.snappy(duration: 0.2)) {
                                                composerState.exitBackgroundHandoffModePreservingDraft()
                                            }
                                        } label: {
                                            ZStack {
                                                Circle()
                                                    .fill(AmberTheme.surface.opacity(0.85))
                                                    .frame(width: 24, height: 24)
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(AmberTheme.muted)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("退出后台交办模式并保留草稿")
                                        .accessibilityIdentifier("chat.duet.handoffExitButton")
                                    }
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, composerState.isBackgroundHandoffMode ? 12 : 18)
                                .padding(.vertical, 5)
                                .composerDockGlass(cornerRadius: 27)
                                .overlay {
                                    if composerState.isBackgroundHandoffMode {
                                        RoundedRectangle(cornerRadius: AmberTheme.controlRadius(27), style: .continuous)
                                            .strokeBorder(AmberTheme.accent.opacity(0.45), lineWidth: 1.0)
                                            .allowsHitTesting(false)
                                    }
                                }

                                if composerState.isBackgroundHandoffMode {
                                    ComposerDockHandoffButton(
                                        isSubmitting: composerState.isSubmittingHandoff,
                                        needsRetry: composerState.handoffNeedsRetry,
                                        isEnabled: !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                        height: 54,
                                        onSubmit: submitBackgroundHandoff
                                    )
                                } else {
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
                            }
                            .frame(height: collapsesComposerForDuetPanel ? 0 : nil, alignment: .top)
                            .clipped()
                            .opacity(collapsesComposerForDuetPanel ? 0 : 1)
                            .allowsHitTesting(!collapsesComposerForDuetPanel)
                            .accessibilityHidden(collapsesComposerForDuetPanel)

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
                                .frame(height: (showsComposerMeta && !collapsesComposerForDuetPanel) ? nil : 0, alignment: .top)
                                .opacity((showsComposerMeta && !collapsesComposerForDuetPanel) ? 1 : 0)
                                .allowsHitTesting(showsComposerMeta && !collapsesComposerForDuetPanel)
                                .accessibilityHidden(!(showsComposerMeta && !collapsesComposerForDuetPanel))

                                if !showsComposerMeta && !collapsesComposerForDuetPanel {
                                    AmberDuetBottomSwitcher(
                                        selectedTab: composerState.activeDuetTab,
                                        activeTaskCount: duetActiveTaskCount,
                                        needsAttentionCount: duetNeedsAttentionCount,
                                        isBackgroundHandoffMode: composerState.isBackgroundHandoffMode && composerState.activeDuetTab == .chat,
                                        handoffExecutionTarget: composerState.handoffExecutionTarget,
                                        activeHubTitle: AmberHubStore.shared.activeHub?.title,
                                        hubs: AmberHubStore.shared.hubs,
                                        cloudAgents: MacGatewayStore.shared.cloudAgents,
                                        selectedCloudAgentId: composerState.handoffSelectedCloudAgentId,
                                        onSelectTab: { tab in
                                            withAnimation(.snappy(duration: 0.22)) {
                                                selectDuetTab(tab)
                                            }
                                        },
                                        onOpenTasks: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                selectDuetTab(.tasks)
                                            }
                                        },
                                        onOpenWorkspace: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                selectDuetTab(.hubs)
                                            }
                                        },
                                        onDelegateCloudTask: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                enterBackgroundHandoffMode()
                                            }
                                        },
                                        onSelectHub: { hubId in
                                            AmberHubStore.shared.selectHub(hubId)
                                            syncIslandPresentation()
                                        },
                                        onSelectExecutionTarget: { target in
                                            composerState.handoffExecutionTarget = target
                                            composerState.handoffErrorMessage = nil
                                        },
                                        onSelectCloudAgent: { agentId in
                                            composerState.handoffSelectedCloudAgentId = agentId
                                        },
                                        onExitHandoffMode: {
                                            withAnimation(.snappy(duration: 0.2)) {
                                                composerState.exitBackgroundHandoffModePreservingDraft()
                                            }
                                        }
                                    )
                                    .padding(.top, 8)
                                    .transition(.opacity)
                                }
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

    var duetActiveTaskCount: Int {
        let localRunning = activityStore.items.filter { $0.status == .running || $0.status == .queued }.count
        let cloudRunning = MacGatewayStore.shared.cloudTasks.filter { $0.workItemId != nil && !$0.isTerminal }.count
        return max(localRunning + cloudRunning, chatListSummary.inChatActiveTaskCount)
    }

    var duetNeedsAttentionCount: Int {
        let pendingGate = viewModel.hasPendingUserGate ? 1 : 0
        let cloudFailed = MacGatewayStore.shared.cloudTasks.filter { $0.state == .failed || $0.needsSubmissionRetry }.count
        let gatewayNeedsYou = MacGatewayStore.shared.needsYouItems.count
        return chatListSummary.inChatNeedsAttentionCount + pendingGate + cloudFailed + gatewayNeedsYou
    }

    func currentConversationTaskSegments() -> [ChatTaskRunSegment] {
        let messages = viewModel.messages
        guard !messages.isEmpty else { return [] }
        let lastID = messages.last.map(ChatMessageProjector.messageId(for:))
        var collected: [ChatTaskRunSegment] = []
        for message in messages where message.role == MessageRole.assistant {
            let msgID = ChatMessageProjector.messageId(for: message)
            let isTail = viewModel.isGenerationActive && (msgID == lastID)
            let segs = ChatTaskStreamGrouping.segments(for: message, messageID: msgID, isGeneratingTail: isTail)
            for case .taskGroup(let group) in segs where group.hasTools {
                collected.append(group)
            }
        }
        return collected.reversed()
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
        guard !composerState.isBackgroundHandoffMode else { return false }
        return composerState.isInputFocused ||
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

    // MARK: - Argon 3+1 Mode & Background Handoff Actions

    @ViewBuilder
    private var handoffContextBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let followup = composerState.handoffFollowupTask {
                HStack(spacing: 6) {
                    Text("跟进任务：\(followup.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        composerState.handoffFollowupTask = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AmberTheme.surface.opacity(0.92), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                }
            }

            if let errorMessage = composerState.handoffErrorMessage {
                HStack(spacing: 6) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentRed)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AmberTheme.accentRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AmberTheme.accentRed.opacity(0.28), lineWidth: 0.8)
                }
            }
        }
    }

    func selectDuetTab(_ tab: AmberDuetModeTab) {
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

    func enterBackgroundHandoffMode(followupTask: AmberUnifiedTaskItem? = nil) {
        if let committed = composerInputController.committedText(), committed != viewModel.inputText {
            viewModel.inputText = committed
        }
        composerState.enterBackgroundHandoffMode(followupTask: followupTask)
        if let followupTask, viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let actionTitle = followupTask.actionTitle {
                viewModel.inputText = "请继续处理「\(followupTask.title)」（\(actionTitle)）："
            } else {
                viewModel.inputText = "跟进任务「\(followupTask.title)」："
            }
        }
    }

    func submitBackgroundHandoff() {
        let committedText = composerInputController.committedText() ?? viewModel.inputText
        if committedText != viewModel.inputText {
            viewModel.inputText = committedText
        }
        let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !composerState.isSubmittingHandoff else { return }

        let activeHubId = AmberHubStore.shared.activeHubId
        let followupId = composerState.handoffFollowupTask?.id
        let requestId = composerState.prepareHandoffRequestId(
            for: trimmed,
            target: composerState.handoffExecutionTarget,
            hubId: activeHubId,
            followupTaskId: followupId
        )

        let composedPrompt: String
        if let followup = composerState.handoffFollowupTask {
            composedPrompt = "[跟进任务 \(followup.title)] \(trimmed)"
        } else {
            composedPrompt = trimmed
        }
        let shortTitle = String(trimmed.prefix(36))

        switch composerState.handoffExecutionTarget {
        case .cloud:
            let gateway = MacGatewayStore.shared
            guard gateway.connection != nil else {
                // Never silently switch host or discard draft when cloud is disconnected.
                composerState.markHandoffSubmissionFailed(
                    IOSAppLocalization.string(
                        "云端未连接，草稿与请求标识已保留。请检查连接后点按「重试」，或切为本机执行。",
                        defaultValue: "云端未连接，草稿与请求标识已保留。请检查连接后点按「重试」，或切为本机执行。"
                    )
                )
                return
            }

            composerState.isSubmittingHandoff = true
            composerState.handoffErrorMessage = nil
            let targetAgent = composerState.handoffSelectedCloudAgentId

            Task { @MainActor in
                let request = MacGatewayCloudTaskRequest(
                    requestId: requestId,
                    text: composedPrompt,
                    agentId: targetAgent,
                    title: shortTitle
                )
                let result = await gateway.submitCloudTask(request)
                switch result {
                case .success(let record):
                    composerState.activeHandoffCloudTaskId = UUID(uuidString: record.requestId)
                    if let workItemId = record.workItemId {
                        AmberHubStore.shared.assignTask(workItemId, toHub: activeHubId)
                    }
                    AmberHubStore.shared.assignTask(record.requestId, toHub: activeHubId)

                    if record.state == .failed || record.needsSubmissionRetry {
                        composerState.markHandoffSubmissionFailed(
                            record.lastError ?? "交办结果未确认，请直接点按「重试」（不会重复创建任务）。"
                        )
                    } else {
                        viewModel.inputText = ""
                        composerState.completeHandoffSubmission()
                    }
                case .failure(let error):
                    AmberHubStore.shared.assignTask(requestId, toHub: activeHubId)
                    composerState.markHandoffSubmissionFailed(error.localizedDescription)
                }
            }

        case .cloudMainDialogue:
            let gateway = MacGatewayStore.shared
            guard gateway.connection != nil else {
                composerState.markHandoffSubmissionFailed(
                    IOSAppLocalization.string(
                        "云端未连接，草稿与请求标识已保留。请检查连接后点按「重试」，或切为本机执行。",
                        defaultValue: "云端未连接，草稿与请求标识已保留。请检查连接后点按「重试」，或切为本机执行。"
                    )
                )
                return
            }

            gateway.setCloudMainDialogueSelected(true)
            composerState.isSubmittingHandoff = true
            composerState.handoffErrorMessage = nil
            let followupWorkItemId = composerState.handoffFollowupTask?.id

            Task { @MainActor in
                let result: Result<MacGatewayCloudDialogueReceipt, Error>
                if let followupWorkItemId {
                    result = await gateway.sendCloudWorkItemInput(
                        workItemId: followupWorkItemId,
                        text: trimmed,
                        requestId: requestId
                    )
                } else {
                    result = await gateway.sendCloudDialogueMessage(
                        text: trimmed,
                        requestId: requestId
                    )
                }
                switch result {
                case .success(let receipt):
                    for workItemId in receipt.workItemIds {
                        AmberHubStore.shared.assignTask(workItemId, toHub: activeHubId)
                    }
                    AmberHubStore.shared.assignTask(receipt.requestId, toHub: activeHubId)
                    viewModel.inputText = ""
                    composerState.completeHandoffSubmission()
                    _ = await gateway.pollCloudDialogueEvents()
                case .failure(let error):
                    AmberHubStore.shared.assignTask(requestId, toHub: activeHubId)
                    composerState.markHandoffSubmissionFailed(error.localizedDescription)
                }
            }

        case .localBackground:
            guard sendEnabled(for: composedPrompt) else {
                composerState.markHandoffSubmissionFailed(
                    viewModel.configurationError ?? "当前本机模型配置未就绪，草稿已保留。"
                )
                return
            }
            if let convId = currentConversationIdString {
                AmberHubStore.shared.assignConversation(convId, toHub: activeHubId)
            }
            AmberHubStore.shared.assignTask(requestId, toHub: activeHubId)
            viewModel.inputText = composedPrompt
            viewportState.followPaused = false
            viewModel.sendMessage(startsGenerationAfterInsertion: true)
            composerState.completeHandoffSubmission()
        }
    }
}
