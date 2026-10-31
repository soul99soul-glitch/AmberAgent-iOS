import Foundation
@preconcurrency import Shared

/// Owns exactly one pending prompt and continuation for a foreground run.
@MainActor
final class ChatRunApprovalSession {
    enum Category {
        case memory, search, webMount, workspace, ish, mcp, council, askUser, recipe
    }

    struct Claim {
        let prompt: ChatToolApprovalPrompt
        let waiter: CheckedContinuation<ChatKernelApprovalDecision?, Never>
    }

    private(set) var prompt: ChatToolApprovalPrompt?
    private var waiter: CheckedContinuation<ChatKernelApprovalDecision?, Never>?
    var hasPendingApproval: Bool { waiter != nil }

    func wait(for prompt: ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision? {
        self.prompt = prompt
        let decision = await withCheckedContinuation {
            (continuation: CheckedContinuation<ChatKernelApprovalDecision?, Never>) in
            waiter = continuation
        }
        waiter = nil
        self.prompt = nil
        return decision
    }

    func claim(category: Category, requestId: String?, runId: String) -> Claim? {
        guard let waiter, let prompt, Self.category(of: prompt) == category else { return nil }
        if let requestId, Self.requestId(of: prompt) != requestId { return nil }
        if case .webMount(let request) = prompt,
           let requestRunId = request.runId, requestRunId != runId { return nil }
        if case .ish(let request) = prompt,
           let requestRunId = request.runId, requestRunId != runId { return nil }
        self.waiter = nil
        self.prompt = nil
        return Claim(prompt: prompt, waiter: waiter)
    }

    func cancel() {
        waiter?.resume(returning: nil)
        waiter = nil
        prompt = nil
    }

    enum PauseResult {
        case decision(ChatKernelApprovalDecision?)
        case storageFailure(String)
    }

    func pause(
        prompt: ChatToolApprovalPrompt,
        runId: String,
        toolCallId: String,
        conversationId: KotlinUuid?,
        bindings: ChatGenerationBindings,
        projection: ChatKernelProjection,
        backgroundExecution: BackgroundGenerationKeepAlive,
        liveActivityController: AgentLiveActivityController,
        isCurrentRun: () -> Bool,
        onKeepAliveReleased: () -> Void
    ) async -> PauseResult {
        guard isCurrentRun() else { return .decision(nil) }
        bindings.bumpMessageRevision(.awaitingToolApproval, 1)
        let writeBaseline = bindings.capturePersistMessagesBaseline(conversationId)
        let didMark = await bindings.markRunAwaitingPermission(runId, toolCallId)
        guard isCurrentRun() else { return .decision(nil) }
        guard didMark else {
            projection.clearAllApprovals()
            return .storageFailure(IOSAppLocalization.string(
                "无法保存待确认恢复信息，请重试。",
                defaultValue: "无法保存待确认恢复信息，请重试。"
            ))
        }
        // Provider apply 入参的 api_key 与 SSH profile 入参的密码/私钥都不得随
        // 待确认快照落盘。
        let approvalMessages = IOSSSHProfileToolCatalog.redactedApprovalMessages(
            IOSProviderConfigToolCatalog.redactedApprovalMessages(bindings.getMessages())
        )
        let didPersist = await bindings.persistMessagesSnapshot(approvalMessages, conversationId, writeBaseline)
        guard isCurrentRun() else { return .decision(nil) }
        guard didPersist else {
            projection.clearAllApprovals()
            return .storageFailure(IOSAppLocalization.string(
                "无法保存待确认状态，请检查存储空间后重试。",
                defaultValue: "无法保存待确认状态，请检查存储空间后重试。"
            ))
        }

        backgroundExecution.end(runId)
        onKeepAliveReleased()
        await liveActivityController.update(
            runId: runId,
            presentation: .waitingForUser(
                kind: prompt.activityKind,
                approval: Self.activityApproval(for: prompt)
            ),
            force: true
        )
        guard isCurrentRun() else { return .decision(nil) }
        bindings.setIsLoading(false)
        if case .askUser(let request) = prompt {
            WatchTaskCoordinator.shared.publishAskUser(
                runId: runId,
                conversationId: conversationId?.toHexDashString(),
                request: WatchAskUserRequest(
                    id: request.id, question: request.question, options: request.options
                )
            )
        } else {
            WatchTaskCoordinator.shared.publishWaitingApproval(
                runId: runId,
                conversationId: conversationId?.toHexDashString(),
                prompt: prompt
            )
        }
        projection.publishApproval(prompt)
        return .decision(await wait(for: prompt))
    }

    static func category(of prompt: ChatToolApprovalPrompt) -> Category {
        switch prompt {
        case .memory: return .memory
        case .search: return .search
        case .webMount: return .webMount
        case .workspace: return .workspace
        case .ish: return .ish
        case .mcp: return .mcp
        case .council: return .council
        case .askUser: return .askUser
        case .recipe: return .recipe
        }
    }

    /// 提问（askUser）需要打字作答，不在灵动岛上给「允许 / 拒绝」。
    ///
    /// 锁屏 / 灵动岛属于“无人监督”场景，绝不能批准高风险写操作：
    /// 隐藏按钮只是外观，真正的闸门在 `remoteApprovalAllowsResolve`（resolve 入口），
    /// 同时内联「允许」按钮与 Watch 口径对齐。
    static func activityApproval(for prompt: ChatToolApprovalPrompt) -> AgentActivityApproval? {
        guard category(of: prompt) != .askUser,
              allowsRemoteApproval(prompt),
              let requestId = requestId(of: prompt) else { return nil }
        return AgentActivityApproval(
            requestId: requestId,
            title: prompt.toolTitle,
            allowsInlineApprove: WatchTaskSnapshotBuilder.allowsApprovalOnWatch(prompt)
        )
    }

    /// 远端（锁屏 Live Activity / 灵动岛 / 手表）是否可以为此 prompt 提供
    /// 「允许」入口。只有非高风险卡可以；高风险的 SSH profile 写、
    /// 破坏性 Apple 动作、provider 密钥写等必须在 App 内确认。
    static func allowsRemoteApproval(_ prompt: ChatToolApprovalPrompt) -> Bool {
        guard category(of: prompt) != .askUser else { return false }
        if case .mcp(let request) = prompt {
            return !request.isHighRiskLocalMutation
                && !request.isDestructiveAppleAction
        }
        return true
    }

    /// resolve 入口的硬闸门：拒绝远端传来的 `allow == true`，无论按钮是否
    /// 被隐藏；`allow == false` 总是允许——拒绝永远安全。askUser 不是审批卡，
    /// 两种决定都不得由此路径收口（它走答题路径）。
    static func remoteApprovalAllowsResolve(
        _ prompt: ChatToolApprovalPrompt,
        allow: Bool
    ) -> Bool {
        guard category(of: prompt) != .askUser else { return false }
        return allow ? allowsRemoteApproval(prompt) : true
    }

    static func requestId(of prompt: ChatToolApprovalPrompt) -> String? {
        switch prompt {
        case .memory(let request): return request.id
        case .search(let request): return request.id
        case .webMount(let request): return request.id
        case .workspace(let request): return request.id
        case .ish(let request): return request.id
        case .mcp(let request): return request.id
        case .council(let request): return request.id
        case .askUser(let request): return request.id
        case .recipe(let request): return request.id
        }
    }

}
