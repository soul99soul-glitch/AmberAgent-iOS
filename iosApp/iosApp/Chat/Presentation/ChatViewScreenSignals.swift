import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

extension ChatView {

    func refreshArtifactShelf(reason: ChatMessageUpdateReason) {
        let isReload = reason == .initialLoad || reason == .conversationSwitch || reason == .branchChange
            || reason == .settingsRefresh
        artifactShelf.update(
            ConversationArtifactIndex.make(
                from: viewModel.messages,
                widgetSettings: IOSGenerativeWidgetSettings(sharedSettings.agentRuntime.generativeUi),
                contentCache: artifactContentCache
            ),
            conversationID: currentConversationIdString,
            isForegroundRunning: scenePhase == .active && viewModel.artifactUpdateWasRunning,
            allowArrival: !isReload
        )
    }

    func refreshChatListSummary(resetTitleSeed: Bool = false) {
        let messages = viewModel.messages
        var next = chatListSummary
        next.hasMessages = !messages.isEmpty
        next.awaitingFirstAssistantChunk = isStreamingFollowActive && messages.last(where: ChatMessageProjector.isConversationMessage)?.role == MessageRole.user
        next.activeToolStep = activeToolStepForIsland(
            messages: messages, focusedMessages: viewModel.focusedActiveTask.map { Array($0.generatedMessages.suffix(3)) }
        )
        next.failedToolStep = failedToolStepForIsland(messages: messages)
        next.lastAssistantHasOpenReasoning = lastAssistantHasOpenReasoning(messages: messages)
        next.webMountRecentUserTurnStartMillis = Self.webMountRecentUserTurnStartMillis(from: messages)
        next.browserTaskTitleCandidate = Self.browserTaskTitleCandidate(messages: messages)
        next.messageIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
        next.userMessageCount = messages.filter {
            $0.role == MessageRole.user && ChatMessageProjector.isConversationMessage($0)
        }.count
        next.lastMessageID = messages.last.map(ChatMessageProjector.messageId(for:))
        next.recapBranchID = conversationStore.currentRecapBranchID ?? ""
        let taskCounts = taskCountCache.counts(messages: messages, isGenerationActive: viewModel.isGenerationActive)
        next.inChatActiveTaskCount = taskCounts.active
        next.inChatNeedsAttentionCount = taskCounts.needsAttention
        if resetTitleSeed || next.firstUserTitleSeed == nil {
            next.firstUserTitleSeed = messages.first(where: { $0.role == MessageRole.user })?
                .toText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if next != chatListSummary {
            chatListSummary = next
        }
    }

    private func activeToolStepForIsland(messages: [UIMessage], focusedMessages: [UIMessage]?) -> ChatToolStepModel? {
        func activeStep(in candidates: [UIMessage]) -> ChatToolStepModel? {
            for message in candidates.reversed() {
                let hasAssistantReplyText = message.parts.contains { part in
                    guard let text = part as? UIMessagePart.Text else { return false }
                    return text.text.contains { !$0.isWhitespace }
                }
                let tools = message.parts.compactMap { $0 as? UIMessagePart.Tool }
                if let active = tools.reversed().first(where: { tool in
                    guard tool.output.isEmpty else { return false }
                    if hasAssistantReplyText {
                        let lower = tool.toolName.lowercased()
                        if lower.contains("subagent") || lower.contains("cloud") || lower.contains("background") {
                            return false
                        }
                    }
                    return true
                }) {
                    return ChatToolStepModel(tool: active)
                }
            }
            return nil
        }
        if let focusedMessages, let active = activeStep(in: focusedMessages) {
            return active
        }
        return activeStep(in: Array(messages.suffix(3)))
    }

    func refreshStreamingChatListSummary() {
        let last = viewModel.focusedActiveTask?.generatedMessages.last ?? viewModel.messages.last
        guard let last, last.role == .assistant else { return }
        if chatListSummary.awaitingFirstAssistantChunk { chatListSummary.awaitingFirstAssistantChunk = false }
        let hasOpenReasoning = last.parts.contains {
            guard let reasoning = $0 as? UIMessagePart.Reasoning else { return false }
            return reasoning.finishedAt == nil
        }
        if chatListSummary.lastAssistantHasOpenReasoning != hasOpenReasoning {
            chatListSummary.lastAssistantHasOpenReasoning = hasOpenReasoning
        }
    }

    /// 最近一个失败的工具（suffix(3) 窗口内）：输出含失败原因时才构造模型，
    /// 仅供岛在 active→idle 边缘匹配 terminalHold，不参与渲染。
    private func failedToolStepForIsland(messages: [UIMessage]) -> ChatToolStepModel? {
        for message in messages.suffix(3).reversed() {
            let tools = message.parts.compactMap { $0 as? UIMessagePart.Tool }
            if let failed = tools.reversed().first(where: {
                ChatToolOutputFormatter.analysis(for: $0).failureReason != nil
            }) {
                return ChatToolStepModel(tool: failed)
            }
        }
        return nil
    }

    /// 活动岛呈现的唯一入口：topIslandState 变化 → presentation（含 settle/terminalHold）。
    func syncIslandPresentation() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = islandPresentation ?? .idle(topIslandState)
        let next = ChatIslandPresentationReducer.stateChanged(
            prev: previous,
            next: topIslandState,
            failedToolID: chatListSummary.failedToolStep?.id,
            now: now,
            reduceMotion: reduceMotion
        )
        guard next != previous else { return }
        islandPresentation = next
        guard let deadline = next.holdDeadline else { return }
        islandHoldToken &+= 1
        let token = islandHoldToken
        Task {
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled, token == islandHoldToken else { return }
            islandPresentation = ChatIslandPresentationReducer.timeout(
                prev: islandPresentation ?? .idle(topIslandState),
                now: ProcessInfo.processInfo.systemUptime
            )
        }
    }

    private func lastAssistantHasOpenReasoning(messages: [UIMessage]) -> Bool {
        guard let last = messages.last(where: ChatMessageProjector.isConversationMessage), last.role == MessageRole.assistant else { return false }
        return last.parts.contains { part in
            guard let reasoning = part as? UIMessagePart.Reasoning else { return false }
            return reasoning.finishedAt == nil
        }
    }

    var conversationTitleForIsland: String {
        let soulName = AgentSoulStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSoulName = soulName.isEmpty ? "Amber" : soulName
        if MacGatewayStore.shared.connection != nil && MacGatewayStore.shared.isCloudMainDialogueSelected {
            return "\(resolvedSoulName) · 云端"
        }
        _ = conversationStore.currentRevision
        let storedTitle = conversationStore.currentConversation?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedTitle.isEmpty {
            return storedTitle.replacingOccurrences(of: "\n", with: " ")
        }
        if let firstUserText = chatListSummary.firstUserTitleSeed,
           !firstUserText.isEmpty {
            return firstUserText.replacingOccurrences(of: "\n", with: " ")
        }
        if let activeHubTitle = AmberHubStore.shared.activeHub?.title,
           !activeHubTitle.isEmpty {
            return activeHubTitle
        }
        return resolvedSoulName
    }

    func compactIslandText(_ raw: String, limit: Int) -> String {
        ChatActivityIslandMapping.compactText(raw, limit: limit)
    }

    func islandTint(for step: ChatToolStepModel) -> ChatActivityIslandTint {
        switch step.state {
        case .failed:
            return .red
        case .done:
            return .green
        case .cancelled:
            return .neutral
        case .active:
            return step.visualKind.activeIslandTint
        }
    }

    var topIslandState: ChatActivityIslandState {
        .conversationTitle(conversationTitleForIsland)
    }

    var timelineActivityState: ChatActivityIslandState {
        activeTimelinePresentation ?? .conversationTitle(conversationTitleForIsland)
    }

    var activeTimelinePresentation: ChatActivityIslandState? {
        if viewModel.hasPendingUserGate {
            return ChatActivityIslandState.activity(
                kind: .awaitingUser,
                title: IOSAppLocalization.string("等待确认", defaultValue: "等待确认"),
                detail: viewModel.pendingAskUser != nil
                    ? IOSAppLocalization.string("回答问题", defaultValue: "回答问题")
                    : (viewModel.pendingToolOutcomeUnknown != nil
                        ? IOSAppLocalization.string("确认操作结果", defaultValue: "确认操作结果")
                        : IOSAppLocalization.string("工具审批", defaultValue: "工具审批")),
                systemImage: "checkmark.circle",
                tint: .amber,
                toolID: pendingUserGateRequestID
            )
        }

        if viewModel.isBackgroundGenerationWaitingForForegroundResume {
            return ChatActivityIslandState.activity(
                kind: .waiting,
                title: IOSAppLocalization.string("正在恢复", defaultValue: "正在恢复"),
                detail: IOSAppLocalization.string(
                    "正在检查可安全恢复方式",
                    defaultValue: "正在检查可安全恢复方式"
                ),
                systemImage: "arrow.triangle.2.circlepath",
                tint: .amber
            )
        }

        if showsTaskFailure && viewModel.focusedActiveTask == nil {
            return ChatActivityIslandState.activity(
                kind: .waiting, title: IOSAppLocalization.string("任务未完成", defaultValue: "任务未完成"),
                systemImage: "exclamationmark.circle", tint: .red
            )
        }

        if let record = displayedWebMountSession {
            let toolID = "webmount:\(record.id)"
            if record.controlOwner == .user {
                return .activity(kind: .awaitingUser,
                                 title: IOSAppLocalization.string("浏览器等待你处理", defaultValue: "浏览器等待你处理"),
                                 systemImage: "person.crop.circle.badge.exclamationmark", tint: .amber, toolID: toolID)
            }
            if viewModel.focusedActiveTask == nil && record.needsReopen {
                return .activity(kind: .awaitingUser,
                                 title: IOSAppLocalization.string("浏览器需要重新打开", defaultValue: "浏览器需要重新打开"),
                                 systemImage: "arrow.clockwise", tint: .amber, toolID: toolID)
            }
            if viewModel.focusedActiveTask == nil && record.status == IOSWebMountRuntimeStatus.failed.rawValue {
                return .activity(kind: .waiting,
                                 title: IOSAppLocalization.string("浏览失败", defaultValue: "浏览失败"),
                                 systemImage: "exclamationmark.triangle", tint: .red, toolID: toolID)
            }
        }

        if viewModel.contextCompactState.isVisible && viewModel.contextCompactState.status != .completed {
            let summary = viewModel.contextCompactState.summary
            let title = summary.isEmpty ? "正在准备上下文" : compactIslandText(summary, limit: 18)
            return ChatActivityIslandState.activity(
                kind: .waiting,
                title: title,
                systemImage: "text.badge.checkmark", tint: .amber
            )
        }

        if let task = viewModel.focusedActiveTask {
            if task.isQueuedForConcurrencySlot {
                return ChatActivityIslandState.activity(
                    kind: .waiting, title: IOSAppLocalization.string("等待执行", defaultValue: "等待执行"),
                    systemImage: "clock", tint: .amber
                )
            }
            switch task.activityStage {
            case .thinking:
                return ChatActivityIslandState.activity(
                    kind: .thinking, title: "正在思考",
                    systemImage: "brain.head.profile", tint: .amber
                )
            case .generating:
                if let step = chatListSummary.activeToolStep {
                    return ChatActivityIslandState.activity(
                        kind: step.visualKind.isImageTool ? .image : .tool,
                        title: compactIslandText(ChatToolStepModel.runningActivityTitle(step.title), limit: 18),
                        detail: step.detail.map { compactIslandText($0, limit: 20) },
                        systemImage: step.systemImage, tint: islandTint(for: step), toolID: step.id
                    )
                }
                return ChatActivityIslandState.activity(
                    kind: .generating, title: IOSAppLocalization.string("正在整理回复", defaultValue: "正在整理回复"),
                    systemImage: "text.bubble", tint: .accent
                )
            case .failed:
                return ChatActivityIslandState.activity(
                    kind: .waiting, title: IOSAppLocalization.string("任务未完成", defaultValue: "任务未完成"),
                    systemImage: "exclamationmark.circle", tint: .red
                )
            case .runningTool:
                if let title = task.activeToolTitle {
                    return ChatActivityIslandState.activity(
                        kind: .tool, title: title,
                        systemImage: "wrench.and.screwdriver", tint: .amber
                    )
                }
                if let step = chatListSummary.activeToolStep,
                   task.activeToolName == nil || step.tool?.toolName == task.activeToolName {
                    return ChatActivityIslandState.activity(
                        kind: step.visualKind.isImageTool ? .image : .tool,
                        title: compactIslandText(ChatToolStepModel.runningActivityTitle(step.title), limit: 18),
                        detail: step.detail.map { compactIslandText($0, limit: 20) },
                        systemImage: step.systemImage, tint: islandTint(for: step), toolID: step.id
                    )
                }
                if let name = task.activeToolName {
                    return ChatActivityIslandState.activity(
                        kind: .tool, title: ChatToolStepModel.runningActivityTitle(ChatToolStepModel.friendlyToolTitle(name, executed: false)),
                        systemImage: "wrench.and.screwdriver", tint: .amber
                    )
                }
                return ChatActivityIslandState.activity(
                    kind: .waiting, title: IOSAppLocalization.string("正在执行工具", defaultValue: "正在执行工具"),
                    systemImage: "wrench.and.screwdriver", tint: .amber
                )
            default:
                return ChatActivityIslandState.activity(
                    kind: .thinking, title: "正在思考",
                    systemImage: "brain.head.profile", tint: .amber
                )
            }
        }

        if let record = displayedWebMountSession,
           record.controlOwner == .agent || record.status == IOSWebMountRuntimeStatus.loading.rawValue {
            return .activity(kind: .tool,
                             title: IOSAppLocalization.string("正在浏览网页", defaultValue: "正在浏览网页"), systemImage: "globe",
                             tint: .amber, toolID: "webmount:\(record.id)")
        }

        if (viewModel.isGenerationActive || viewModel.isLoading), let step = chatListSummary.activeToolStep {
            return ChatActivityIslandState.activity(
                kind: step.visualKind.isImageTool ? .image : .tool,
                title: compactIslandText(ChatToolStepModel.runningActivityTitle(step.title), limit: 18),
                detail: step.detail.map { compactIslandText($0, limit: 20) },
                systemImage: step.systemImage,
                tint: islandTint(for: step),
                toolID: step.id
            )
        }

        if viewModel.isRecognizingImages {
            return ChatActivityIslandState.activity(
                kind: .image,
                title: IOSAppLocalization.string("识别图片", defaultValue: "识别图片"),
                detail: viewModel.visionRecognitionImageCount > 1
                    ? IOSAppLocalization.formatted(
                        "共 %lld 张",
                        defaultValue: "共 %lld 张",
                        arguments: [Int64(viewModel.visionRecognitionImageCount)]
                    ) : nil,
                systemImage: "viewfinder",
                tint: .cyan
            )
        }

        if chatListSummary.awaitingFirstAssistantChunk {
            return ChatActivityIslandState.activity(
                kind: .thinking,
                title: IOSAppLocalization.string("正在思考", defaultValue: "正在思考"),
                systemImage: "brain.head.profile",
                tint: .amber
            )
        }

        if viewModel.isGenerationActive {
            if chatListSummary.lastAssistantHasOpenReasoning {
                return ChatActivityIslandState.activity(
                    kind: .thinking,
                    title: IOSAppLocalization.string("正在思考", defaultValue: "正在思考"),
                    systemImage: "brain.head.profile",
                    tint: .amber
                )
            }
            return ChatActivityIslandState.activity(
                kind: .generating,
                title: IOSAppLocalization.string("正在生成回复", defaultValue: "正在生成回复"),
                systemImage: "text.bubble",
                tint: .accent
            )
        }

        return nil
    }

    var currentTimelineActivity: ChatTimelineActivity? {
        guard let presentation = activeTimelinePresentation else { return nil }
        let task = viewModel.focusedActiveTask
        let assistant = task?.generatedMessages.last(where: { $0.role == .assistant })
        guard let anchor = (showsTaskFailure && task == nil ? failureMessageID : nil)
            ?? assistant.map(ChatMessageProjector.messageId(for:))
            ?? task?.anchorUserMessageId ?? chatListSummary.lastMessageID else { return nil }
        let tool: UIMessagePart.Tool?
        if let step = chatListSummary.activeToolStep,
           (presentation.kind == .tool || presentation.kind == .image),
           task?.activeToolName == nil || task?.activeToolName == step.tool?.toolName {
            tool = step.tool
        } else {
            tool = nil
        }
        let tracksTaskLiveness = task != nil && task?.isQueuedForConcurrencySlot == false &&
            !viewModel.hasPendingUserGate && !viewModel.isBackgroundGenerationWaitingForForegroundResume &&
            !(viewModel.contextCompactState.isVisible && viewModel.contextCompactState.status != .completed) &&
            presentation.tint != .red
        let showsThought = tracksTaskLiveness &&
            (presentation.kind == .thinking || (presentation.kind == .waiting && presentation.title == "正在思考"))
        return ChatTimelineActivity(anchorMessageID: anchor, hasAssistant: assistant != nil,
                                    presentation: presentation, tool: tool, taskSlot: task,
                                    plannedStages: task?.plannedActivityStages ?? [],
                                    stagePlanStartedUptime: task?.stagePlanStartedUptime,
                                    liveReasoningSummary: task?.liveReasoningSummary,
                                    tracksTaskLiveness: tracksTaskLiveness, showsThought: showsThought)
    }

    var pendingUserGateRequestID: String? {
        [viewModel.pendingAskUser?.id, viewModel.pendingMemoryApproval?.id,
         viewModel.pendingSearchApproval?.id, viewModel.pendingWebMountApproval?.id,
         viewModel.pendingWorkspaceApproval?.id, viewModel.pendingIshHandoffApproval?.id,
         viewModel.pendingMcpApproval?.id, viewModel.pendingCouncilApproval?.id,
         viewModel.pendingRecipeApproval?.id, viewModel.pendingToolOutcomeUnknown?.toolCallId]
            .compactMap { $0 }.first
    }

    func handleIslandTap(_ presentation: ChatIslandPresentation) {
        if let record = displayedWebMountSession,
           presentation.displayedState.toolID == "webmount:\(record.id)" {
            openWebMountSession(sessionId: record.id)
            return
        }
        if presentation.displayedState.kind == .tool {
            isPresentingDuetTasks = true
            return
        }
        guard let conversationID = currentConversationIdString else { return }
        switch ChatIslandNavigation.target(
            for: presentation, conversationID: conversationID, messages: viewModel.messages,
            pendingRequestID: pendingUserGateRequestID, requestToken: UUID()
        ) {
        case .none: break
        case .bottom:
            scrollToBottomSource = .button
            scrollToBottomTrigger &+= 1
        case .anchor(let anchor):
            requestedMessageAnchor = anchor
        case .pendingGate:
            guard viewModel.hasPendingUserGate else { return }
            dismissKeyboard()
            composerState.gateHighlightRequest = UUID()
        }
    }

    func openActivityConversation(_ id: String) async -> Bool {
        let opened = await openSubAgentSourceConversation(id)
        conversationActivityCenter.didOpenConversation(
            id: id, succeeded: opened, isTranscript: opened && currentConversationIdString != id
        )
        if !opened && conversationStore.lastUserVisibleError == nil {
            conversationStore.publishUserVisibleError(IOSUserVisibleError(
                title: "无法打开对话", message: "该对话已不存在或暂时无法读取。", severity: .warning
            ))
        }
        return opened
    }

    func handleChatListAction(_ action: ChatListAction) {
        switch action {
        case let .regenerate(messageId):
            viewModel.regenerate(messageId: messageId)
        case let .requestEdit(messageId, currentText):
            messageEditDraft = ChatMessageEditDraft(messageId: messageId, text: currentText)
        case let .edit(messageId, newText):
            viewModel.editMessage(messageId: messageId, newText: newText)
        case let .delete(messageId):
            pendingDeleteMessageId = messageId
        case let .selectVariant(messageId, variantIndex):
            viewModel.selectVariant(messageId: messageId, variantIndex: variantIndex)
        case let .generativeWidget(prompt):
            guard !viewModel.isGenerationActive else { return }
            viewModel.inputText = prompt
            viewportState.followPaused = false
            viewModel.sendMessage(startsGenerationAfterInsertion: true)
        case let .modifyGeneratedImage(urlString, prompt, aspectRatio):
            guard !viewModel.isGenerationActive else { return }
            viewportState.followPaused = false
            viewModel.modifyGeneratedImage(
                sourceImageURL: urlString,
                prompt: prompt,
                aspectRatio: aspectRatio
            )
        case let .openMiniApp(appId):
            router.navigate(to: .miniAppRunner(appId: appId))
        case .openMiniApps:
            router.navigate(to: .miniApps)
        case let .openSubagentConversation(id):
            router.navigate(to: .subAgentConversation(id: id))
        case let .openToolDetail(tool):
            duetSelectedToolTarget = ToolDetailTarget(tool: tool)
        case .primaryConfiguration:
            openPrimaryConfigurationAction()
        case .modelDefaults:
            openModelDefaults()
        }
    }

    func openPrimaryConfigurationAction() {
        switch configurationIssue {
        case .some(.missingModel):
            openModelDefaults()
        case .some(.missingAPIKey), .some(.invalidBaseURL), .some(.missingProvider),
             .some(.unsupportedProvider), .some(.codexNotSignedIn), .some(.grokNotSignedIn),
             .some(.geminiNotSignedIn), .some(.providerDisabled), .none:
            router.navigate(to: .providers)
        }
    }

    func openModelDefaults() {
        router.navigate(to: .modelDefaults)
    }

    @discardableResult
    func repairCurrentChatModelIfNeeded() -> Bool {
        sharedSettings.repairCurrentChatModelIfNeeded(settingsStore)
    }

    func popoverBinding(for panel: ComposerPanel) -> Binding<Bool> {
        Binding(
            get: { composerState.activeComposerPanel == panel },
            set: { isPresented in
                if isPresented {
                    composerState.activeComposerPanel = panel
                } else if composerState.activeComposerPanel == panel {
                    composerState.activeComposerPanel = nil
                }
            }
        )
    }

    var isStreamingFollowActive: Bool {
        viewModel.isGenerationActive || viewModel.isLoading
    }

    func dismissKeyboard() {
        composerState.isInputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    func applyCollectionViewportState(_ newState: ChatViewportState) {
        guard viewportState != newState else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            viewportState = newState
        }
    }

}
