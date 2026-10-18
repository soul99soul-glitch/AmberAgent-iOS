import Foundation
@preconcurrency import Shared

/// Keeps queue sidecar and Room mailbox access together while each run state
/// remains the sole owner of its in-memory queue and child wait task.
@MainActor
final class ChatConversationInboxIO {
    private let steerQueueStore: IOSSteerQueueStore
    private let mailboxStore: IOSMailboxStore
    private let activityCenter: IOSMailboxActivityCenter

    init(
        steerQueueStore: IOSSteerQueueStore,
        mailboxStore: IOSMailboxStore,
        activityCenter: IOSMailboxActivityCenter
    ) {
        self.steerQueueStore = steerQueueStore
        self.mailboxStore = mailboxStore
        self.activityCenter = activityCenter
    }

    func persistQueue(_ queue: [IOSSteerQueueEntry], for id: KotlinUuid?) {
        steerQueueStore.persist(queue, for: id)
    }

    func loadQueue(conversationId: KotlinUuid?) -> [IOSSteerQueueEntry] {
        steerQueueStore.load(conversationId: conversationId)
    }

    func loadQueueOffMain(conversationId: String) async -> [IOSSteerQueueEntry] {
        let queueStore = steerQueueStore
        return await Task.detached(priority: .utility) {
            queueStore.load(conversationId: conversationId)
        }.value
    }

    func removeQueue(for id: KotlinUuid) {
        steerQueueStore.removeAll(for: id)
    }

    func pendingResults(forConversationId id: KotlinUuid) async throws -> [IOSMailboxStore.EnvelopeSnapshot] {
        try await mailboxStore.pendingResults(forConversationId: id)
    }

    func drainPending(forConversationId id: KotlinUuid?) async -> [IOSMailboxStore.EnvelopeSnapshot] {
        await mailboxStore.drainPending(forConversationId: id)
    }

    func events(for id: String) async -> AsyncStream<Void> {
        await activityCenter.events(for: id)
    }

    func signal(conversationIdHex id: String) async {
        await activityCenter.signal(conversationIdHex: id)
    }
}
