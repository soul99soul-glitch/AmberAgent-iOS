package app.amber.cloud.tasks

/** Created only from a live, authenticated Worker principal, never from model arguments. */
data class TaskCallContext(val workItemId: String, val agentId: String, val sessionId: String, val allowedTools: Set<String>)

class TaskCapabilityUnavailable(message: String) : IllegalStateException(message)
