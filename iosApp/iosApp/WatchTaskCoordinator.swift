import Foundation
@preconcurrency import Shared

extension Notification.Name {
    static let amberWatchOpenTask = Notification.Name("app.amber.ios.watch.openTask")
}

struct WatchTaskReconnectProjection: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let startedAt: Int64
}

/// Owns the current watch-facing task snapshot and translates Watch intents
/// into ChatViewModel / ChatKernelRunHost actions.
@MainActor
final class WatchTaskCoordinator: WatchTaskActionHandling {
    static let shared = WatchTaskCoordinator()

    private weak var chatViewModel: ChatViewModel?
    private let bridge: WatchConnectivityBridge
    private var currentRunId: String?
    private var currentConversationId: String?
    private var currentPresentation: AgentActivityPresentation?
    private var currentDecision: WatchDecision?
    private var currentApprovalPrompt: ChatToolApprovalPrompt?
    private var currentSummary: String?
    private var pendingAskUser: WatchAskUserRequest?
    private var isAttached = false
    private var attachmentWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var runGeneration: [String: UInt64] = [:]
    private var runStartedAt: [String: Int64] = [:]
    private var nextRunGeneration: UInt64 = 0
    private struct ProcessedAction {
        let request: WatchTaskActionRequest
        let result: WatchTaskActionResult
    }
    private struct InFlightAction {
        let request: WatchTaskActionRequest
        let task: Task<WatchTaskActionResult, Never>
    }
    private var processedActions: [String: ProcessedAction] = [:]
    private var processedActionOrder: [String] = []
    private var inFlightActions: [String: InFlightAction] = [:]

    private var resolvedLanguageCode: String {
        IOSAppLanguagePreference.selected().resolvedLanguage().rawValue
    }

    init(bridge: WatchConnectivityBridge = .shared) {
        self.bridge = bridge
    }

    func attach(
        chatViewModel: ChatViewModel,
        reconnecting: [WatchTaskReconnectProjection] = []
    ) {
        self.chatViewModel = chatViewModel
        isAttached = true
        let waiters = attachmentWaiters.values
        attachmentWaiters.removeAll()
        waiters.forEach { $0.resume() }
        bridge.configure(actionHandler: self)
        bridge.activateIfNeeded()
        for projection in reconnecting.sorted(by: { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.runId < rhs.runId }
            return lhs.startedAt < rhs.startedAt
        }) {
            registerRun(runId: projection.runId, startedAt: projection.startedAt)
        }
        if currentPresentation == nil {
            if let reconnecting = reconnecting.max(by: { lhs, rhs in
                if lhs.startedAt == rhs.startedAt { return lhs.runId < rhs.runId }
                return lhs.startedAt < rhs.startedAt
            }) {
                publish(
                    runId: reconnecting.runId,
                    conversationId: reconnecting.conversationId,
                    presentation: .reconnecting(kind: .response)
                )
            } else {
                bridge.clear(languageCode: resolvedLanguageCode)
            }
        } else {
            republish()
        }
    }

    /// Records the durable run ordering token before any asynchronous Watch
    /// projection can arrive. Arrival order remains only a legacy fallback for
    /// call sites that do not own a persisted start time.
    func registerRun(runId: String, startedAt: Int64) {
        runStartedAt[runId] = startedAt
        if runGeneration[runId] == nil {
            nextRunGeneration &+= 1
            runGeneration[runId] = nextRunGeneration
        }
    }

    @discardableResult
    func publish(
        runId: String,
        conversationId: String?,
        presentation: AgentActivityPresentation,
        summary: String? = nil,
        decision: WatchDecision? = nil
    ) -> Bool {
        let isKnownRun = runGeneration[runId] != nil
        if !isKnownRun {
            nextRunGeneration &+= 1
            runGeneration[runId] = nextRunGeneration
        }
        if let currentRunId,
           currentRunId != runId,
           !isNewerRun(runId, than: currentRunId) {
            return false
        }
        if currentRunId != runId {
            currentSummary = nil
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        }
        currentRunId = runId
        currentConversationId = conversationId
        currentPresentation = presentation
        if let summary {
            currentSummary = WatchTaskText.clipped(summary, maxLength: 280)
        }
        if presentation.phase == .completed
            || presentation.phase == .failed
            || presentation.phase == .cancelled {
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        } else if let decision {
            currentDecision = decision
        } else if presentation.phase != .waitingForUser {
            // Running/tool stages replace a previous decision node.
            currentDecision = nil
            currentApprovalPrompt = nil
            pendingAskUser = nil
        }
        republish()
        return true
    }

    private func isNewerRun(_ incomingRunId: String, than currentRunId: String) -> Bool {
        if let incomingStartedAt = runStartedAt[incomingRunId],
           let currentStartedAt = runStartedAt[currentRunId] {
            if incomingStartedAt == currentStartedAt {
                return incomingRunId > currentRunId
            }
            return incomingStartedAt > currentStartedAt
        }
        return (runGeneration[incomingRunId] ?? 0) > (runGeneration[currentRunId] ?? 0)
    }

    func publishWaitingApproval(
        runId: String,
        conversationId: String?,
        prompt: ChatToolApprovalPrompt
    ) {
        pendingAskUser = nil
        let accepted = publish(
            runId: runId,
            conversationId: conversationId,
            presentation: .waitingForUser(kind: prompt.activityKind),
            decision: WatchTaskSnapshotBuilder.decision(
                from: prompt,
                languageCode: resolvedLanguageCode
            )
        )
        if accepted { currentApprovalPrompt = prompt }
    }

    func publishAskUser(
        runId: String,
        conversationId: String?,
        request: WatchAskUserRequest
    ) {
        currentApprovalPrompt = nil
        let accepted = publish(
            runId: runId,
            conversationId: conversationId,
            presentation: .waitingForUser(kind: .workflow),
            decision: WatchTaskSnapshotBuilder.askUserDecision(
                from: request,
                languageCode: resolvedLanguageCode
            )
        )
        if accepted { pendingAskUser = request }
    }

    func publishCompleted(
        runId: String,
        conversationId: String?,
        summary: String?,
        kind: AgentActivityKind = .response
    ) {
        publish(
            runId: runId,
            conversationId: conversationId,
            presentation: AgentActivityPresentation(
                kind: kind,
                phase: .completed,
                stage: .completed,
                action: .viewResult
            ),
            summary: summary,
            decision: nil
        )
    }

    func clear(runId: String? = nil) {
        if let runId, currentRunId != nil, currentRunId != runId {
            return
        }
        currentRunId = nil
        currentConversationId = nil
        currentPresentation = nil
        currentDecision = nil
        currentApprovalPrompt = nil
        currentSummary = nil
        pendingAskUser = nil
        bridge.clear(languageCode: resolvedLanguageCode)
    }

    func currentSnapshot() -> WatchTaskSnapshot {
        bridge.latestSnapshot
    }

    func refreshLanguage() {
        if let currentApprovalPrompt {
            currentDecision = WatchTaskSnapshotBuilder.decision(
                from: currentApprovalPrompt,
                languageCode: resolvedLanguageCode
            )
        } else if let pendingAskUser {
            currentDecision = WatchTaskSnapshotBuilder.askUserDecision(
                from: pendingAskUser,
                languageCode: resolvedLanguageCode
            )
        }
        republish()
    }

    func handleWatchAction(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        if !isAttached {
            await waitForAttachment()
        }
        if let processed = processedActions[request.requestId] {
            return processed.request == request
                ? processed.result
                : rejected(request, "请求标识已被另一项操作使用")
        }
        if let inFlight = inFlightActions[request.requestId] {
            guard inFlight.request == request else {
                return rejected(request, "请求标识已被另一项操作使用")
            }
            return await inFlight.task.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return WatchTaskActionResult(
                    requestId: request.requestId,
                    runId: request.runId,
                    accepted: false,
                    message: "iPhone 当前无法处理手表操作",
                    snapshot: nil
                )
            }
            return await self.handleWatchActionUncached(request)
        }
        inFlightActions[request.requestId] = InFlightAction(request: request, task: task)
        let result = await task.value
        inFlightActions.removeValue(forKey: request.requestId)
        processedActions[request.requestId] = ProcessedAction(request: request, result: result)
        processedActionOrder.append(request.requestId)
        if processedActionOrder.count > 64 {
            let expired = processedActionOrder.removeFirst()
            processedActions.removeValue(forKey: expired)
        }
        return result
    }

    private func waitForAttachment() async {
        guard !isAttached else { return }
        let waiterId = UUID()
        await withCheckedContinuation { continuation in
            attachmentWaiters[waiterId] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let continuation = self?.attachmentWaiters.removeValue(forKey: waiterId) else {
                    return
                }
                continuation.resume()
            }
        }
    }

    private func handleWatchActionUncached(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        switch request.action {
        case .refresh:
            return accepted(request, message: nil)
        case .openOnPhone:
            let conversationId: String
            if request.runId == currentRunId,
               let currentConversationId,
               !currentConversationId.isEmpty,
               request.conversationId == nil
                || request.conversationId?.caseInsensitiveCompare(currentConversationId) == .orderedSame {
                conversationId = currentConversationId
            } else if let requestedConversationId = request.conversationId,
                      !requestedConversationId.isEmpty,
                      let chatViewModel,
                      await chatViewModel.recordedAgentRunBelongsToConversation(
                        runId: request.runId,
                        conversationId: requestedConversationId
                      ) {
                conversationId = requestedConversationId
            } else {
                return rejected(request, "当前任务没有可打开的会话")
            }
            let focus: String
            if request.runId != currentRunId {
                focus = "result"
            } else if currentDecision?.type == .approval
                || currentDecision?.type == .askUser
                || currentDecision?.type == .voiceReply {
                focus = "confirmation"
            } else if currentPresentation?.phase == .completed {
                focus = "result"
            } else {
                focus = "task"
            }
            NotificationCenter.default.post(
                name: .amberWatchOpenTask,
                object: nil,
                userInfo: [
                    "runId": request.runId,
                    "conversationId": conversationId,
                    "focus": focus
                ]
            )
            return accepted(request, message: "已在 iPhone 打开任务")
        case .cancel:
            guard let currentRunId, request.runId == currentRunId else {
                return rejected(request, "当前没有可取消的任务")
            }
            // The run may already belong to the background coordinator. Only
            // report success after the current foreground/background owner accepts it.
            let acceptedByForeground = chatViewModel?.cancelGeneration(runId: currentRunId) == true
            let acceptedByBackground = acceptedByForeground
                ? false
                : IOSChatBackgroundGenerationCoordinator.shared.cancelJob(runId: currentRunId)
            guard acceptedByForeground || acceptedByBackground else {
                return rejected(request, "当前任务已经结束或不再由 iPhone 执行")
            }
            return accepted(request, message: "已取消")
        case .retry:
            guard let chatViewModel,
                  let runId = currentRunId,
                  request.runId == runId,
                  currentPresentation?.phase == .failed,
                  currentPresentation?.retryable == true,
                  let conversationId = currentConversationId,
                  request.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame else {
                return rejected(request, "这个失败任务已失效")
            }
            guard await chatViewModel.retryFailedGeneration(
                sourceRunId: runId,
                conversationId: conversationId
            ) else {
                return rejected(request, "当前无法重试这个任务")
            }
            return accepted(request, message: "已重试")
        case .approve, .deny:
            return await handleApproval(request)
        case .choose, .answer:
            return await handleAskUser(request)
        }
    }

    private func handleApproval(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        guard let decision = currentDecision,
              decision.type == .approval,
              request.decisionId == decision.id else {
            return rejected(request, "这个确认步骤已失效")
        }
        guard let chatViewModel else {
            return rejected(request, "iPhone 聊天状态不可用")
        }
        guard let runId = currentRunId,
              request.runId == runId,
              chatViewModel.canOpenActivityConfirmation(runId: runId) else {
            return rejected(request, "当前没有待确认的操作")
        }

        let allow: Bool
        switch request.action {
        case .approve:
            allow = true
        case .deny:
            allow = false
        default:
            if request.optionId == "approve" {
                allow = true
            } else if request.optionId == "deny" {
                allow = false
            } else {
                return rejected(request, "无法识别审批选项")
            }
        }

        guard chatViewModel.resolvePendingToolApprovalFromWatch(
            runId: runId,
            requestId: decision.id,
            allow: allow
        ) else {
            return rejected(request, "这个确认步骤已失效")
        }
        // Awaited finish/resume path publishes the next watch snapshot before we reply.
        return accepted(request, message: allow ? "已允许" : "已拒绝")
    }

    private func handleAskUser(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
        guard let decision = currentDecision,
              decision.type == .askUser || decision.type == .voiceReply,
              request.decisionId == decision.id else {
            return rejected(request, "这个确认步骤已失效")
        }
        guard let chatViewModel else {
            return rejected(request, "iPhone 聊天状态不可用")
        }
        guard let runId = currentRunId,
              request.runId == runId,
              let pendingAskUser else {
            return rejected(request, "当前没有等待回答的问题")
        }

        let answer: String
        if request.action == .choose, request.optionId == "skip" {
            answer = ""
        } else if request.action == .choose,
                  let optionId = request.optionId,
                  optionId.hasPrefix("choice-"),
                  let index = Int(optionId.dropFirst("choice-".count)),
                  pendingAskUser.options.indices.contains(index) {
            answer = pendingAskUser.options[index]
        } else if let text = WatchTaskText.clipped(request.text, maxLength: 500),
                  !text.isEmpty {
            answer = text
        } else {
            return rejected(request, "请先选择选项、跳过或语音输入")
        }

        // submitWatchUserAnswer returns true only after finish+resume ownership accepts.
        // resumeAfterApproval already publishes the next snapshot; do not clear locally
        // first or report success before that Bool is true.
        let acceptedSend = chatViewModel.submitWatchUserAnswer(
            runId: runId,
            requestId: decision.id,
            text: answer
        )
        guard acceptedSend else {
            return rejected(request, "当前无法提交回答")
        }
        return accepted(
            request,
            message: answer.isEmpty ? "已跳过" : "已提交回答"
        )
    }

    private func republish() {
        guard let runId = currentRunId,
              let presentation = currentPresentation else {
            bridge.clear(languageCode: resolvedLanguageCode)
            return
        }
        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: runId,
            conversationId: currentConversationId,
            presentation: presentation,
            summary: currentSummary,
            decision: currentDecision,
            languageCode: resolvedLanguageCode
        )
        bridge.publish(snapshot)
    }

    private func accepted(
        _ request: WatchTaskActionRequest,
        message: String?
    ) -> WatchTaskActionResult {
        WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: true,
            message: message.map {
                WatchTaskLocalization.string(
                    $0,
                    defaultValue: $0,
                    languageCode: resolvedLanguageCode
                )
            },
            snapshot: bridge.latestSnapshot
        )
    }

    private func rejected(
        _ request: WatchTaskActionRequest,
        _ message: String
    ) -> WatchTaskActionResult {
        WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: false,
            message: WatchTaskLocalization.string(
                message,
                defaultValue: message,
                languageCode: resolvedLanguageCode
            ),
            snapshot: bridge.latestSnapshot
        )
    }
}
