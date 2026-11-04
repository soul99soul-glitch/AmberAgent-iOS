import Foundation
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    /// Manual `✦ 新话题` entrypoint for the single-stream companion timeline.
    /// - Seals the current active messages into an archived `Episode` and inserts a lightweight divider.
    /// - Idempotent: returns `false` without inserting duplicate dividers when the stream is empty
    ///   or already sitting at an empty Episode boundary.
    /// - Triggers low-priority silent background distillation into memory/portrait when `>= 2` Q&A turns were completed.
    @discardableResult
    func startNewEpisode(
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) -> Bool {
        guard !currentConversationIsOrchestratedChild else { return false }
        guard let conversationId = currentConversationId else { return false }
        let conversationKey = conversationId.toHexDashString()

        // Idempotency guard: never insert a duplicate divider if already at an empty boundary.
        guard !ChatEpisodeStore.shared.isAtEmptyBoundary(
            conversationId: conversationKey,
            messages: messages
        ) else {
            invalidateSuggestionRequest()
            chatSuggestions = []
            return false
        }

        let episodeSlice = ChatEpisodeStore.shared.unsealedNonSystemMessages(
            for: conversationKey,
            in: messages
        )
        guard let sealed = ChatEpisodeStore.shared.sealCurrentEpisodeIfNeeded(
            conversationId: conversationKey,
            messages: messages,
            reason: .manualNewTopic,
            nowMillis: nowMillis
        ) else {
            return false
        }

        invalidateSuggestionRequest()
        chatSuggestions = []
        refreshContextCompactBoundaries()
        bumpMessageRevision(reason: .settingsRefresh)

        let memoryMode = conversationStore?.currentConversation?.memoryMode ?? .enabled
        ChatEpisodeDistiller.shared.scheduleDistillationIfEligible(
            episode: sealed,
            episodeMessages: episodeSlice,
            sharedSettings: sharedSettings,
            conversationMemoryMode: memoryMode,
            onDigestUpdated: { [weak self] in
                guard let self, self.currentConversationId == conversationId else { return }
                self.refreshContextCompactBoundaries()
            }
        )
        return true
    }

    /// Automatic 3-hour (`> 10800s`) idle-gap detector invoked right before appending a new user message.
    /// If the elapsed time since the last message in the active Episode exceeds 3 hours, seals the prior
    /// Episode into an archived window and triggers silent distillation before the new message enters.
    @discardableResult
    func sealActiveEpisodeForIdleGapIfNeeded(
        incomingTimestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) -> ChatEpisodeRecord? {
        guard !currentConversationIsOrchestratedChild,
              let conversationId = currentConversationId else {
            return nil
        }
        let conversationKey = conversationId.toHexDashString()
        let episodeSlice = ChatEpisodeStore.shared.unsealedNonSystemMessages(
            for: conversationKey,
            in: messages
        )
        guard let sealed = ChatEpisodeStore.shared.sealIfIdleTimeoutExceeded(
            conversationId: conversationKey,
            existingMessages: messages,
            incomingMessageTimestampMillis: incomingTimestampMillis
        ) else {
            return nil
        }

        refreshContextCompactBoundaries()
        let memoryMode = conversationStore?.currentConversation?.memoryMode ?? .enabled
        ChatEpisodeDistiller.shared.scheduleDistillationIfEligible(
            episode: sealed,
            episodeMessages: episodeSlice,
            sharedSettings: sharedSettings,
            conversationMemoryMode: memoryMode,
            onDigestUpdated: { [weak self] in
                guard let self, self.currentConversationId == conversationId else { return }
                self.refreshContextCompactBoundaries()
            }
        )
        return sealed
    }

    /// Records the authoritative wall-clock timestamp for a newly appended message so 3-hour gap checks remain exact.
    func recordEpisodeMessageTimestamp(
        _ message: UIMessage,
        conversationId: KotlinUuid?,
        timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) {
        guard let conversationId else { return }
        ChatEpisodeStore.shared.recordMessageTimestamp(
            conversationId: conversationId.toHexDashString(),
            messageId: ChatMessageProjector.messageId(for: message),
            timestampMillis: timestampMillis
        )
    }
}
