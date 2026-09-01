import Foundation

@MainActor
final class AgentActivityRetryEligibilityStore {
    static let shared = AgentActivityRetryEligibilityStore()

    private struct Entry: Codable, Equatable {
        let runId: String
        let conversationId: String
    }

    private let defaults = UserDefaults.standard
    private let key = "app.amber.ios.agentActivity.retryEligibility.v1"
    private var entries: [Entry]

    private init() {
        entries = (defaults.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func setEligible(_ eligible: Bool, runId: String, conversationId: String?) {
        entries.removeAll { $0.runId == runId }
        if eligible, let conversationId, !conversationId.isEmpty {
            entries.append(Entry(runId: runId, conversationId: conversationId))
            if entries.count > 64 { entries.removeFirst(entries.count - 64) }
        }
        persist()
    }

    func isEligible(runId: String, conversationId: String) -> Bool {
        entries.contains {
            $0.runId == runId
                && $0.conversationId.caseInsensitiveCompare(conversationId) == .orderedSame
        }
    }

    @discardableResult
    func consume(runId: String, conversationId: String) -> Bool {
        guard isEligible(runId: runId, conversationId: conversationId) else { return false }
        entries.removeAll { $0.runId == runId }
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
final class AgentActivityControlCenter {
    static let shared = AgentActivityControlCenter()

    private weak var chatViewModel: ChatViewModel?
    private var ownerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {}

    func attach(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        let waiters = ownerWaiters.values
        ownerWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    @discardableResult
    func cancel(runId: String, conversationId: String) async -> Bool {
        guard AgentActivityDeepLink.makeURL(
            runId: runId,
            conversationId: conversationId,
            focus: .task
        ) != nil else { return false }
        if chatViewModel?.cancelGeneration(runId: runId) == true {
            return true
        }
        if IOSChatBackgroundGenerationCoordinator.shared.cancelJob(runId: runId) {
            return true
        }
        guard let owner = await waitForOwner() else { return false }
        return owner.cancelGeneration(runId: runId)
    }

    @discardableResult
    func retry(runId: String, conversationId: String) async -> Bool {
        guard AgentActivityDeepLink.makeURL(
            runId: runId,
            conversationId: conversationId,
            focus: .task
        ) != nil else { return false }
        guard AgentActivityRetryEligibilityStore.shared.isEligible(
            runId: runId,
            conversationId: conversationId
        ) else { return false }
        let owner: ChatViewModel?
        if let chatViewModel {
            owner = chatViewModel
        } else {
            owner = await waitForOwner()
        }
        guard let owner else { return false }
        return await owner.retryFailedGeneration(
            sourceRunId: runId,
            conversationId: conversationId
        )
    }

    private func waitForOwner() async -> ChatViewModel? {
        if let chatViewModel { return chatViewModel }
        let waiterId = UUID()
        await withCheckedContinuation { continuation in
            ownerWaiters[waiterId] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let continuation = self?.ownerWaiters.removeValue(forKey: waiterId) else {
                    return
                }
                continuation.resume()
            }
        }
        return chatViewModel
    }
}
