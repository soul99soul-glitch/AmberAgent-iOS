import Foundation
@preconcurrency import Shared

/// Owns one durable provider, response cursor, and persisted checkpoint gate.
@MainActor
final class ChatDurableResponseSession {
    struct Checkpoint {
        let handoff: IOSChatBackgroundHandoff
        let isNew: Bool
    }

    let provider: ChatKernelDurableTextProvider
    private let backgroundCoordinator: IOSChatBackgroundGenerationCoordinator
    private var cursor: (responseId: String, sequenceNumber: Int64)?
    private var persistedMode: IOSChatBackgroundHandoffMode?
    private var checkpointWriteFailed = false
    var hasPersistedOwner: Bool { persistedMode != nil }
    var requiresRecovery: Bool { checkpointWriteFailed }
    var checkpointPersisted: Bool { persistedMode == .resumeResponse && !checkpointWriteFailed }

    init(host: ChatKernelRunHost, runId: String,
         backgroundCoordinator: IOSChatBackgroundGenerationCoordinator = .shared) {
        self.backgroundCoordinator = backgroundCoordinator
        provider = ChatKernelDurableTextProvider(
            onCheckpoint: { [weak host] responseId, sequenceNumber, requestToken in
                Task { @MainActor in
                    host?.recordDurableResponseCheckpoint(
                        runId: runId, responseId: responseId,
                        sequenceNumber: sequenceNumber, requestToken: requestToken
                    )
                }
            },
            onDurableDisconnect: { [weak host] message, requestToken in
                Task { @MainActor in
                    host?.handleDurableDisconnect(runId: runId, message: message, requestToken: requestToken)
                }
            }
        )
    }

    func checkpoint(
        responseId: String,
        sequenceNumber: Int64,
        handoff source: IOSChatBackgroundHandoff,
        requestToken: UUID? = nil
    ) -> Checkpoint? {
        if let requestToken, !provider.isCurrentRequest(requestToken) { return nil }
        var handoff = source
        let isNew = handoff.responseId != responseId
            || handoff.responseSequenceNumber == nil
            || sequenceNumber > (handoff.responseSequenceNumber ?? -1)
        handoff.mode = .resumeResponse
        handoff.responseId = responseId
        handoff.responseSequenceNumber = sequenceNumber
        // Resume replays from event zero, so sequence-only progress stays with
        // this live cursor rather than advancing disk beyond its message snapshot.
        if persistedMode == .resumeResponse, cursor?.responseId == responseId, !checkpointWriteFailed {
            cursor = (responseId, sequenceNumber)
            return Checkpoint(handoff: handoff, isNew: isNew)
        }
        guard backgroundCoordinator.checkpointDurableResponse(handoff) else {
            checkpointWriteFailed = true
            return nil
        }
        cursor = (responseId, sequenceNumber)
        persistedMode = .resumeResponse
        checkpointWriteFailed = false
        return Checkpoint(handoff: handoff, isNew: isNew)
    }

    func persistContinuation(_ handoff: IOSChatBackgroundHandoff) -> Bool {
        guard hasPersistedOwner else { return true }
        // Queued cursor callbacks from the completed request cannot reclaim this round.
        provider.invalidateCompletedRequest()
        guard backgroundCoordinator.checkpointForegroundContinuation(handoff) else {
            checkpointWriteFailed = true
            return false
        }
        cursor = nil
        persistedMode = .continueModel
        checkpointWriteFailed = false
        return true
    }

    func canDetach(handoff: IOSChatBackgroundHandoff?) -> Bool {
        checkpointPersisted && handoff?.mode == .resumeResponse
            && handoff?.responseId == cursor?.responseId
    }

    func cancelRemote(handoff: IOSChatBackgroundHandoff?) {
        guard let cursor,
              let handoff,
              let openAI = handoff.providerSetting as? ProviderSetting.OpenAI else { return }
        provider.cancelLocalStream()
        _ = try? IOSSharedKmpProviders.openAIBackgroundTransport.cancelBackground(
            providerSetting: openAI,
            responseId: cursor.responseId,
            customHeaders: handoff.params.customHeaders,
            onComplete: {},
            onError: { _ in }
        )
    }
}
