@preconcurrency import Shared

@MainActor
final class ChatConversationRun {
    let state: ChatConversationRunState
    var host: ChatKernelRunHost?

    init(conversationId: KotlinUuid?) {
        state = ChatConversationRunState(conversationId: conversationId)
    }
}

/// Owns the conversation-to-run identity map for the App-held view model.
@MainActor
final class ChatConversationRunRegistry {
    private var runs: [String: ChatConversationRun] = [:]

    var allRuns: [ChatConversationRun] { Array(runs.values) }

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

    func host(for conversationId: KotlinUuid) -> ChatKernelRunHost? {
        run(for: conversationId)?.host
    }

    func host(runId: String) -> ChatKernelRunHost? {
        runs.values.compactMap(\.host).first { $0.currentRunId == runId }
    }

    func retainActive(keeping selected: ChatConversationRun) {
        runs = runs.filter { _, run in
            run === selected || run.host?.isRunning == true
                || run.state.waitingForChildRunId != nil || !run.state.inputText.isEmpty
        }
    }
}
