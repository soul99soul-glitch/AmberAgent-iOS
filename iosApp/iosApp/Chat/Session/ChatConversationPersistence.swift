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

    func persistMessages(state: ChatConversationRunState, appending: [UIMessage] = []) async -> Bool {
        guard let store = conversationStore else { return true }
        let targetConversationId = state.conversationId
        return await persistMessagesSnapshot(
            state.messages,
            targetConversationId: targetConversationId,
            pendingRegeneration: state.pendingAssistantRegeneration,
            store: store,
            writeBaseline: targetConversationId.map { store.writeBaseline(for: $0) },
            state: state, usesLiveMessages: true, appending: appending
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
        state: ChatConversationRunState? = nil,
        usesLiveMessages: Bool = false,
        appending: [UIMessage] = []
    ) async -> Bool {
        let owner = state ?? targetConversationId.flatMap { runRegistry.run(for: $0)?.state } ?? currentRun.state
        let predecessor = owner.messagePersistenceTail
        owner.messagePersistencePendingCount += 1
        let write = Task { @MainActor in
            let previous = await predecessor?.value
            defer { owner.messagePersistencePendingCount -= 1 }
            let queuedPlaceholderIds = Set(self.runRegistry.allRuns.flatMap { run in
                run.orderedSlots.compactMap(\.queuedPlaceholderMessageId)
            })
            var source = usesLiveMessages ? owner.messages : snapshot
            let sourceIds = Set(source.map(ChatMessageProjector.messageId(for:)))
            source.append(contentsOf: appending.filter { !sourceIds.contains(ChatMessageProjector.messageId(for: $0)) })
            let persistable = source.filter { !queuedPlaceholderIds.contains(ChatMessageProjector.messageId(for: $0)) }
            let baseline: IOSConversationWriteBaseline?
            if usesLiveMessages, let previous,
               writeBaseline.map { previous.acceptedBaselines.contains($0) } == true || writeBaseline == previous.after {
                baseline = previous.after
            } else {
                baseline = writeBaseline
            }
            let beforeWrite = targetConversationId.flatMap { store?.writeBaseline(for: $0) }
            let saved = await ChatConversationPersistence.commit(
                persistable, targetConversationId: targetConversationId,
                pendingRegeneration: pendingRegeneration, store: store,
                writeBaseline: baseline, state: owner,
                isCurrentConversation: { self.isCurrentConversation($0) },
                onBranchApplied: { self.bumpMessageRevision(reason: .branchChange) }
            )
            if saved, !appending.isEmpty {
                let publishedIds = Set(owner.messages.map(ChatMessageProjector.messageId(for:)))
                let additions = appending.filter { !publishedIds.contains(ChatMessageProjector.messageId(for: $0)) }
                if !additions.isEmpty {
                    owner.messages.append(contentsOf: additions)
                    if self.isCurrentConversation(owner.conversationId) { self.bumpMessageRevision(reason: .toolResultAppended) }
                }
            }
            let after = beforeWrite == baseline
                ? targetConversationId.flatMap { store?.writeBaseline(for: $0) } : baseline
            var accepted = owner.messagePersistencePendingCount > 1 ? previous?.acceptedBaselines ?? [] : []
            for value in [baseline, after].compactMap({ $0 }) where !accepted.contains(value) {
                accepted.append(value)
            }
            return ChatMessagePersistenceResult(saved: saved, acceptedBaselines: accepted, after: after)
        }
        owner.messagePersistenceTail = write
        return await write.value.saved
    }
}
