import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

extension ChatView {

    var currentRecap: ConversationRecap? {
        currentConversationIdString.flatMap {
            conversationStore.recapGenerator.recap(for: $0, messageIDs: chatListSummary.messageIDs)
        }
    }

    func requestRecap() {
        guard let id = conversationStore.currentConversation?.id else {
            showRecapError("对话已不存在，无法生成回顾。")
            return
        }
        let messages = viewModel.messages
        let summary = viewModel.contextCompactState.summary
        Task {
            await conversationStore.recapGenerator.request(
                conversationID: id, messages: messages, settings: sharedSettings, compactSummary: summary
            )
        }
    }

    func locateRecapNode(_ node: ConversationRecap.Node) -> Bool {
        guard let id = currentConversationIdString,
              let messageID = node.messageID,
              viewModel.messages.contains(where: { ChatMessageProjector.messageId(for: $0) == messageID }) else {
            showRecapError("原消息不在当前分支中，无法定位。")
            return false
        }
        requestedMessageAnchor = ChatMessageAnchor(
            conversationID: id, messageID: messageID, requestToken: UUID()
        )
        return true
    }

    func fillRecapNextStep(_ step: String) -> Bool {
        guard !hasPendingComposerGate, !viewModel.currentConversationIsOrchestratedChild else {
            showRecapError("当前对话暂不可输入，请先完成待处理操作。")
            return false
        }
        let draft = composerInputController.currentText() ?? viewModel.inputText
        viewModel.fillInputFromSuggestion(draft.isEmpty ? step : draft + "\n" + step)
        composerState.isInputFocused = true
        return true
    }

    private func showRecapError(_ message: String) {
        conversationStore.publishUserVisibleError(IOSUserVisibleError(
            title: "回顾", message: message, severity: .error
        ))
    }

    func updateArtifactShelf(_ action: (IOSConversationArtifactStore, String) throws -> Void) {
        guard let id = currentConversationIdString else { return }
        do {
            try action(conversationStore.artifactStore, id)
        } catch {
            showArtifactError(error.localizedDescription)
        }
    }

    func pinArtifactSnippet(messageID: String, text: String, kind: ChatArtifactPinKind, codeLanguage: String?) {
        guard let snippet = ChatArtifactPinning.snippet(
            messageID: messageID, text: text, kind: kind, codeLanguage: codeLanguage, messages: viewModel.messages
        ) else {
            showArtifactError("原消息已不在当前分支中。")
            return
        }
        updateArtifactShelf { store, id in
            try store.pin(snippet, for: id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func continueFromArtifact(_ action: ChatArtifactContinuation) async -> Bool {
        guard !hasPendingComposerGate, !viewModel.currentConversationIsOrchestratedChild else {
            showArtifactError("当前对话暂不可输入，请先完成待处理操作。")
            return false
        }
        if let text = composerInputController.currentText() { viewModel.inputText = text }
        do {
            // 图片达到上限时由既有输入区错误提示说明，面板照常关闭以露出提示。
            try await ChatArtifactComposerSupport.apply(action, to: viewModel)
            composerState.isInputFocused = true
            return true
        } catch {
            showArtifactError(error.localizedDescription)
            return false
        }
    }

    /// 消息集合只在点击时读取，避免 topBar 随流式内容重算；进度与失败由 `IOSShareActivity` 浮层呈现。
    func exportConversation(_ format: IOSConversationExportFormat) {
        let title = conversationStore.currentConversation?.title ?? ""
        let messages = viewModel.messages
        Task { @MainActor in
            await IOSConversationExporter.share(format: format, title: title, messages: messages)
        }
    }

    func showArtifactError(_ message: String) {
        conversationStore.publishUserVisibleError(IOSUserVisibleError(
            title: "产物架", message: message, severity: .error
        ))
    }

}
