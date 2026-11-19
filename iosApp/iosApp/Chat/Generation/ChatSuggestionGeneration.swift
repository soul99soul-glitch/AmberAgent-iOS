import Foundation
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {
    func generateChatSuggestions(state: ChatConversationRunState) {
        guard suggestionRequests.host == "local", !state.isOrchestratedChild,
              let context = ChatSuggestionContext.local(
                messages: state.messages, conversationID: state.conversationId?.toHexDashString(),
                summary: state.contextCompactState.status == .completed ? state.contextCompactState.summary : nil,
                waitingForChild: state.waitingForChildRunId != nil) else { return }
        generateSuggestion(context: context, conversationID: state.conversationId)
    }

    func setSuggestionHost(_ host: String) {
        guard suggestionRequests.host != host else { return }
        invalidateSuggestionRequest(reason: "host_changed", preserveCached: true)
        suggestionRequests.host = host
        if host == "local", let cached = suggestionRequests.cached,
           cached.source.host == host,
           cached.source.scope == (currentConversationId?.toHexDashString() ?? "draft"),
           messages.last.map({ String(describing: $0.id) }) == cached.source.turn,
           inputText.isEmpty, !isGenerationActive {
            publishSuggestions(cached.suggestions, source: cached.source, modelID: cached.modelID)
        }
    }

    func refreshCloudSuggestions(gateway: MacGatewayStore) {
        guard gateway.isCloudMainDialogueSelected,
              suggestionRequests.host == gateway.suggestionHostKey else { return }
        guard let replyID = gateway.cloudSuggestionReplyID,
              !gateway.isAwaitingCloudMainReply,
              gateway.selectedCloudDialogueWorkItemId == nil else {
            invalidateSuggestionRequest()
            return
        }
        let active = gateway.activeCloudDialogueWorkItemIds
        if let reply = gateway.cloudDialogueEvents.last(where: { $0.id == replyID }), reply.kind == .assistantReply,
           gateway.cloudDialogueReceipts.values.contains(where: {
               $0.topicId == reply.topicId && $0.workItemIds.contains(where: { active.contains($0) })
           }) {
            // A delegation acknowledgement is not a completed task that needs another user instruction.
            invalidateSuggestionRequest()
            return
        }
        let pending = active.prefix(8).map { id in
            gateway.cloudDialogueProgressByWorkItem[id]?.statusLine ?? "A cloud task is still running."
        }
        guard let context = ChatSuggestionContext.cloud(events: gateway.cloudDialogueEvents,
            host: gateway.suggestionHostKey, replyID: replyID, pendingWork: pending) else {
            invalidateSuggestionRequest()
            return
        }
        let host = context.source.host
        generateSuggestion(context: context, conversationID: nil) { [weak gateway] in
            gateway?.suggestionHostKey == host && gateway?.cloudSuggestionReplyID == replyID
                && gateway?.isAwaitingCloudMainReply == false && gateway?.selectedCloudDialogueWorkItemId == nil
        }
    }

    private func generateSuggestion(context: ChatSuggestionContext, conversationID: KotlinUuid?,
                                    sourceIsCurrent: (@MainActor () -> Bool)? = nil) {
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let cached = suggestionRequests.cached, cached.source == context.source {
            if chatSuggestions != cached.suggestions {
                publishSuggestions(cached.suggestions, source: cached.source, modelID: cached.modelID)
            }
            return
        }
        guard suggestionRequests.source != context.source else { return }
        let snapshot = sharedSettings.snapshot
        guard let model = resolveAuxModel(snapshot.suggestionModelId) else { return }
        invalidateSuggestionRequest(reason: "new_reply")
        let prompt = SuggestionKt.resolveSuggestionPrompt(storedPrompt: snapshot.suggestionPrompt)
            .replacingOccurrences(of: "{locale}", with: auxLocaleName())
            .replacingOccurrences(of: "{content}", with: context.content)
        let token = suggestionRequests.begin(source: context.source)
        suggestionRequests.sourceIsCurrent = sourceIsCurrent
        let modelID = String(describing: model.id)
        suggestionRequests.task = Task { [weak self] in
            guard let self else { return }
            let raw = await self.runAuxModel(model: model, prompt: prompt, conversationId: conversationID)
            guard !Task.isCancelled, self.suggestionRequests.token == token else { return }
            let suggestions = raw.map { ChatSuggestionFilter.candidates(from: $0, context: context) } ?? []
            self.suggestionRequests.cached = (context.source, suggestions, modelID)
            self.applySuggestions(suggestions, requestToken: token, conversationId: conversationID)
        }
    }

    func publishSuggestions(_ suggestions: [String], source: ChatSuggestionSource?, modelID: String) {
        if let source, !suggestions.isEmpty {
            recordSuggestionFeedback(suggestionRequests.feedback.prepare(source: source, suggestions: suggestions, modelID: modelID))
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { chatSuggestions = suggestions }
    }

    func suggestionDidAppear() {
        recordSuggestionFeedback(suggestionRequests.feedback.shown())
    }

    func suggestionMessageSubmitted(_ text: String) {
        recordSuggestionFeedback(suggestionRequests.feedback.submit(text))
        suggestionRequests.invalidate()
        chatSuggestions = []
    }

    func suggestionDraftChanged(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggestionRequests.invalidate()
        if !chatSuggestions.isEmpty { chatSuggestions = [] }
    }

    func recordSuggestionFeedback(_ events: [ChatSuggestionFeedbackEvent]) {
        guard !events.isEmpty else { return }
        Task { await ChatSuggestionFeedbackStore.shared.append(events) }
    }
}
