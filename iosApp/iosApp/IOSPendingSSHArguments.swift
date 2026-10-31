import Foundation

/// Owned by one ChatToolRuntime. Raw arguments never enter messages or durable checkpoints.
@MainActor
final class IOSPendingSSHArguments {
    private var runs: [String: [String: String]] = [:]

    func stage(runId: String, toolCallId: String, arguments: String) {
        guard !IOSSecretArgumentRedaction.containsRedactedSecretArgument(arguments),
              IOSSecretArgumentRedaction.redactedArgumentsJSON(arguments) != arguments else { return }
        runs[runId, default: [:]][toolCallId] = arguments
    }

    func take(runId: String, toolCallId: String) -> String? {
        let value = runs[runId]?.removeValue(forKey: toolCallId)
        if runs[runId]?.isEmpty == true { runs.removeValue(forKey: runId) }
        return value
    }

    func discard(runId: String) { runs.removeValue(forKey: runId) }

    var count: Int { runs.values.reduce(0) { $0 + $1.count } }
}
