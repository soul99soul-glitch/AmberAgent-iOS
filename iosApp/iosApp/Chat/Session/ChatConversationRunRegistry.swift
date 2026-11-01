@preconcurrency import Shared

@MainActor
final class ChatConversationRun {
    let state: ChatConversationRunState
    var primaryHost: ChatKernelRunHost?
    private(set) var taskSlots: [String: ChatAsyncTaskSlot] = [:]
    private(set) var taskOrder: [String] = []

    var host: ChatKernelRunHost? {
        get {
            if let runningSlotHost = orderedSlots.last(where: { $0.host?.isRunning == true })?.host {
                return runningSlotHost
            }
            if let primaryHost, primaryHost.isRunning {
                return primaryHost
            }
            return primaryHost ?? orderedSlots.last?.host
        }
        set {
            primaryHost = newValue
        }
    }

    var orderedSlots: [ChatAsyncTaskSlot] {
        var seen = Set<String>()
        var result: [ChatAsyncTaskSlot] = []
        for id in taskOrder {
            guard let slot = taskSlots[id], seen.insert(slot.slotId).inserted else { continue }
            result.append(slot)
        }
        return result
    }

    var allActiveHosts: [ChatKernelRunHost] {
        var hosts: [ChatKernelRunHost] = []
        for slot in orderedSlots {
            if let h = slot.host, h.isRunning, !hosts.contains(where: { $0 === h }) {
                hosts.append(h)
            }
        }
        if let primaryHost, primaryHost.isRunning, !hosts.contains(where: { $0 === primaryHost }) {
            hosts.append(primaryHost)
        }
        return hosts
    }

    var hasActiveOrQueuedTask: Bool {
        orderedSlots.contains(where: \.isActiveOrQueued) || primaryHost?.isRunning == true
    }

    func registerSlot(_ slot: ChatAsyncTaskSlot) {
        taskSlots[slot.slotId] = slot
        taskSlots[slot.runId] = slot
        if !taskOrder.contains(slot.slotId) {
            taskOrder.append(slot.slotId)
        }
    }

    func rebindSlotRunId(slot: ChatAsyncTaskSlot, newRunId: String) {
        slot.runId = newRunId
        taskSlots[slot.slotId] = slot
        taskSlots[newRunId] = slot
    }

    func slot(forRunId runId: String) -> ChatAsyncTaskSlot? {
        if let direct = taskSlots[runId] { return direct }
        return orderedSlots.first { $0.runId == runId || $0.slotId == runId || $0.host?.currentRunId == runId }
    }

    func host(forRunId runId: String) -> ChatKernelRunHost? {
        if let slotHost = slot(forRunId: runId)?.host {
            return slotHost
        }
        if primaryHost?.currentRunId == runId {
            return primaryHost
        }
        return nil
    }

    init(conversationId: KotlinUuid?) {
        state = ChatConversationRunState(conversationId: conversationId)
    }
}

/// Owns the conversation-to-run identity map and local task concurrency queue for the App-held view model.
@MainActor
final class ChatConversationRunRegistry {
    private var runs: [String: ChatConversationRun] = [:]
    var maxConcurrentLocalRuns: Int = 2
    private(set) var pendingTaskQueue: [(conversationKey: String, slotId: String)] = []

    var allRuns: [ChatConversationRun] { Array(runs.values) }

    var activeForegroundRunCount: Int {
        runs.values.reduce(0) { count, run in
            count + run.allActiveHosts.count
        }
    }

    func current(for conversationId: KotlinUuid?) -> ChatConversationRun {
        let key = conversationId?.toHexDashString() ?? ""
        if let run = runs[key] { return run }
        let run = ChatConversationRun(conversationId: conversationId)
        runs[key] = run
        return run
    }

    func run(for conversationId: KotlinUuid) -> ChatConversationRun? {
        runs[conversationId.toHexDashString()]
    }

    func run(forHex conversationId: String) -> ChatConversationRun? {
        runs[conversationId]
    }

    func findSlot(runId: String) -> (ChatConversationRun, ChatAsyncTaskSlot)? {
        for run in runs.values {
            if let slot = run.slot(forRunId: runId) {
                return (run, slot)
            }
        }
        return nil
    }

    func enqueuePendingTask(conversationKey: String, slotId: String) {
        guard !pendingTaskQueue.contains(where: { $0.slotId == slotId }) else { return }
        pendingTaskQueue.append((conversationKey: conversationKey, slotId: slotId))
    }

    func popNextPendingTask() -> (conversationKey: String, slotId: String)? {
        guard !pendingTaskQueue.isEmpty else { return nil }
        return pendingTaskQueue.removeFirst()
    }

    func removePendingTask(slotId: String) {
        pendingTaskQueue.removeAll { $0.slotId == slotId }
    }

    func host(for conversationId: KotlinUuid) -> ChatKernelRunHost? {
        run(for: conversationId)?.host
    }

    func host(runId: String) -> ChatKernelRunHost? {
        for run in runs.values {
            if let matched = run.host(forRunId: runId) {
                return matched
            }
        }
        return nil
    }

    func retainActive(keeping selected: ChatConversationRun) {
        runs = runs.filter { _, run in
            run === selected || run.hasActiveOrQueuedTask
                || run.state.steerQueueAutoContinueTask != nil
                || run.state.waitingForChildRunId != nil || !run.state.inputText.isEmpty
        }
    }
}
