package app.amber.cloud.orchestration

/** Reuse a settled session only within the same agent and subscribed topic, never concurrently. */
internal object WorkerSessionLifecycle {
    fun reusableSession(store: CloudOrchestrationStore, spec: WorkItemSubmissionSpec): String? {
        if (spec.subscribedThreadKeys.isEmpty()) return null
        val items = store.listWorkItems()
        val busySessions = items.filterNot { it.state.isTerminal }.mapNotNull { it.workerSessionId }.toSet()
        return items.asSequence()
            .filter { it.agentId == spec.agentId && it.state.isTerminal && it.subscribedThreadKeys.any(spec.subscribedThreadKeys::contains) }
            .sortedByDescending { it.updatedAtMs }
            .mapNotNull { it.workerSessionId }
            .firstOrNull { it !in busySessions }
    }
}
