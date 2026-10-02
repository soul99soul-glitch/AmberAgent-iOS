import Foundation
@preconcurrency import Shared

/// Discussion-agent tools for the standalone app: Ask User, the novel project
/// write tools for runs started with a project context, and web search when
/// the user keeps it enabled. Mirrors Amber's `ChatToolRuntime` tool set for
/// the same agent.
@MainActor
final class NovelAppToolHost: NovelDiscussionToolHost {
    weak var novelProjectCreation: DefaultNovelCreation?
    private let settings: NovelAppSettingsStore
    private let searchTransport: any IOSSearchHTTPTransport

    init(
        settings: NovelAppSettingsStore,
        searchTransport: any IOSSearchHTTPTransport = IOSURLSessionSearchHTTPTransport()
    ) {
        self.settings = settings
        self.searchTransport = searchTransport
    }

    func novelDiscussionToolExecutors(
        projectContext: NovelProjectToolRunContext?
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [
            "ask_user": ClosureExecutor { _, _ in .needsApproval("等待用户回答") }
        ]
        if let projectContext {
            let projectExecutor = IOSNovelProjectToolExecutor(
                projectContext: projectContext,
                creation: novelProjectCreation
            )
            for name in IOSNovelProjectToolExecutor.supportedToolNames {
                executors[name] = projectExecutor
            }
        }
        guard settings.snapshot.enableWebSearch else { return executors }
        for name in IOSSearchExecutor.supportedToolNames {
            executors[name] = ClosureExecutor { [weak self] toolName, arguments in
                guard let self else { return .failed("搜索暂不可用。") }
                let call = UIMessagePart.Tool(
                    toolCallId: "novel-\(toolName)-\(chatInputDigest(for: arguments))",
                    toolName: toolName,
                    input: arguments,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
                return .filled(await IOSSearchToolDispatch.dispatch(
                    call,
                    settings: self.settings.snapshot,
                    webSearchEnabled: self.settings.snapshot.enableWebSearch,
                    transport: self.searchTransport
                ))
            }
        }
        return executors
    }
}

private final class ClosureExecutor: IOSToolExecutor {
    private let handler: @MainActor (String, String) async -> IOSAgentToolOutcome

    init(_ handler: @escaping @MainActor (String, String) async -> IOSAgentToolOutcome) {
        self.handler = handler
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await handler(name, arguments)
    }
}
