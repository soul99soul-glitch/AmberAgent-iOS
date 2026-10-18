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
        next.activeToolStep = activeToolStepForIsland(messages: messages)
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
        if resetTitleSeed || next.firstUserTitleSeed == nil {
            next.firstUserTitleSeed = messages.first(where: { $0.role == MessageRole.user })?
                .toText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if next != chatListSummary {
            chatListSummary = next
        }
    }

    private func activeToolStepForIsland(messages: [UIMessage]) -> ChatToolStepModel? {
        for message in messages.suffix(3).reversed() {
            let tools = message.parts.compactMap { $0 as? UIMessagePart.Tool }
            if let active = tools.reversed().first(where: { $0.output.isEmpty }) {
                return ChatToolStepModel(tool: active)
            }
        }
        return nil
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
        return "Amber"
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

}
