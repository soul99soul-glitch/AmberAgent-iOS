import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    func persistMessages(conversationId: KotlinUuid? = nil) async -> Bool {
        let state = conversationId.flatMap { runRegistry.run(for: $0)?.state } ?? currentRun.state
        return await persistMessages(state: state)
    }

    func persistMessages(state: ChatConversationRunState) async -> Bool {
        guard let store = conversationStore else { return true }
        let targetConversationId = state.conversationId
        return await persistMessagesSnapshot(
            state.messages,
            targetConversationId: targetConversationId,
            pendingRegeneration: state.pendingAssistantRegeneration,
            store: store,
            writeBaseline: targetConversationId.map { store.writeBaseline(for: $0) },
            state: state
        )
    }

    func persistMessages(
        _ snapshot: [UIMessage],
        conversationId: KotlinUuid? = nil,
        writeBaseline: IOSConversationWriteBaseline?
    ) async -> Bool {
        guard let store = conversationStore else { return true }
        let targetConversationId = conversationId ?? store.currentConversation?.id
        let pendingRegeneration = pendingAssistantRegeneration
        return await persistMessagesSnapshot(
            snapshot,
            targetConversationId: targetConversationId,
            pendingRegeneration: pendingRegeneration,
            store: store,
            writeBaseline: writeBaseline
        )
    }

    func persistMessagesSnapshot(
        _ snapshot: [UIMessage],
        targetConversationId: KotlinUuid?,
        pendingRegeneration: PendingAssistantRegeneration?,
        store: IOSConversationStore?,
        writeBaseline: IOSConversationWriteBaseline?,
        state: ChatConversationRunState? = nil
    ) async -> Bool {
        await ChatConversationPersistence.commit(
            snapshot, targetConversationId: targetConversationId,
            pendingRegeneration: pendingRegeneration, store: store,
            writeBaseline: writeBaseline, state: state ?? currentRun.state,
            isCurrentConversation: { self.isCurrentConversation($0) },
            onBranchApplied: { self.bumpMessageRevision(reason: .branchChange) }
        )
    }

}
