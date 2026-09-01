import SwiftUI
@preconcurrency import Shared

/// Live output model for a running subagent, observed by `ChatToolDetailSheet`.
///
/// The subagent engine (`IOSAgentToolEngine`) streams each turn and pushes the
/// accumulating assistant text here via `ingest`. The sheet shows `text` live and
/// flips off the running spinner on `finish`. When no live model is registered
/// for a tool call (e.g. the run finished before the app session, or it was
/// evicted), the sheet falls back to the stored `tool.output`.
@MainActor
@Observable
final class SubAgentLiveModel {
    private(set) var text: String = ""
    private(set) var isRunning: Bool = true
    @ObservationIgnored private let pendingText = SubAgentLiveTextBuffer()

    /// The provider publishes the full accumulated text for every token. Keep
    /// only the newest snapshot and schedule at most one main-actor publisher,
    /// instead of queueing one UI task per token.
    nonisolated func ingest(_ newText: String) {
        guard pendingText.offer(newText) else { return }
        Task { [weak self, pendingText] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 64_000_000)
                guard let latest = pendingText.takeLatest() else { return }
                await self?.publish(latest)
            }
        }
    }

    func finish() {
        if let latest = pendingText.finish() {
            text = latest
        }
        isRunning = false
    }

    private func publish(_ newText: String) {
        guard isRunning else { return }
        text = newText
    }

    // The engine drives updates; these satisfy the sheet's `.task` / `.onDisappear`.
    func start() async {}
    func stop() {}
}

private final class SubAgentLiveTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?
    private var publisherScheduled = false
    private var isFinished = false

    /// Returns true only for the update that must start the single publisher.
    func offer(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        pending = text
        guard !publisherScheduled else { return false }
        publisherScheduled = true
        return true
    }

    func takeLatest() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }
        guard let latest = pending else {
            publisherScheduled = false
            return nil
        }
        pending = nil
        return latest
    }

    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        publisherScheduled = false
        defer { pending = nil }
        return pending
    }
}

/// Process-wide registry linking a subagent dispatch tool call (by `toolCallId`)
/// to its live model, so the chat detail sheet can find the live stream for the
/// capsule the user tapped. The engine path (SubAgentRunner) registers a model
/// when a dispatch starts; the sheet looks it up by the tool's id.
@MainActor
final class SubAgentLiveRegistry {
    static let shared = SubAgentLiveRegistry()

    private var models: [String: SubAgentLiveModel] = [:]
    // Insertion order, for bounded FIFO eviction.
    private var order: [String] = []
    private let capacity = 64

    func register(toolCallId: String, _ model: SubAgentLiveModel) {
        guard !toolCallId.isEmpty else { return }
        if models[toolCallId] == nil {
            order.append(toolCallId)
        }
        models[toolCallId] = model
        // Evict only the OLDEST entries past the cap. The previous blunt
        // `removeAll()` wiped every live model — including the one currently
        // streaming — so a capsule opened mid-run lost its live text. FIFO
        // eviction keeps recent/active streams intact.
        while order.count > capacity {
            let oldest = order.removeFirst()
            models.removeValue(forKey: oldest)
        }
    }

    func model(forToolCallId id: String) -> SubAgentLiveModel? {
        models[id]
    }
}
