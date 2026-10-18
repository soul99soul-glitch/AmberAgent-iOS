import Foundation
@preconcurrency import Shared

/// Owns the snapshot/CAS/variant transaction for one conversation's run.
@MainActor
enum ChatConversationPersistence {
    static func commit(
        _ snapshot: [UIMessage],
        targetConversationId: KotlinUuid?,
        pendingRegeneration: PendingAssistantRegeneration?,
        store: IOSConversationStore?,
        writeBaseline: IOSConversationWriteBaseline?,
        state: ChatConversationRunState,
        isCurrentConversation: (KotlinUuid?) -> Bool,
        onBranchApplied: () -> Void
    ) async -> Bool {
        guard let store else { return true }
        if let pendingRegeneration,
           let targetConversationId,
           String(describing: targetConversationId) == String(describing: pendingRegeneration.conversationId) {
            guard let storedMessages = await store.messages(for: targetConversationId) else { return false }
            let generatedSuffix: [UIMessage] = pendingRegeneration.generatedMessageIndex >= 0 &&
                pendingRegeneration.generatedMessageIndex < snapshot.count
                ? Array(snapshot[pendingRegeneration.generatedMessageIndex...])
                : []
            let saved: Bool
            if let errorMessage = generatedSuffix.first(where: ChatViewModel.isLocalGenerationError) {
                saved = await store.save(
                    messages: storedMessages + [errorMessage],
                    to: targetConversationId,
                    ifUnchangedSince: writeBaseline
                )
            } else if let regeneratedIndex = generatedSuffix.lastIndex(where: ChatViewModel.isRegeneratedAnswerCandidate) {
                saved = await store.appendVariantAndTruncateAfter(
                    messageIndex: pendingRegeneration.targetMessageIndex,
                    message: generatedSuffix[regeneratedIndex],
                    trailingMessages: Array(generatedSuffix.dropFirst(regeneratedIndex + 1)),
                    conversationId: targetConversationId
                )
            } else if let outputLimitNotice = generatedSuffix.last(where: ChatViewModel.isOutputLimitNotice) {
                saved = await store.save(
                    messages: storedMessages + [outputLimitNotice],
                    to: targetConversationId,
                    ifUnchangedSince: writeBaseline
                )
            } else {
                saved = false
            }
            state.pendingAssistantRegeneration = nil
            if let persistedMessages = await store.messages(for: targetConversationId) {
                state.messages = persistedMessages
                if isCurrentConversation(targetConversationId) {
                    onBranchApplied()
                }
            }
            return saved
        }
        if let targetConversationId {
            return await store.save(
                messages: snapshot,
                to: targetConversationId,
                ifUnchangedSince: writeBaseline
            )
        }
        return true
    }
}
