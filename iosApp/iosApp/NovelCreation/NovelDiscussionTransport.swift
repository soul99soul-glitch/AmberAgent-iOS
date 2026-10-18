import Foundation
@preconcurrency import Shared

extension NovelLiveModelAdapter {
    /// Accumulates assistant text across the tool engine's multi-step loop.
    /// Each `streamStep` re-accumulates its own text from empty (see
    /// `IOSAgentToolEngine.StreamStepState`), so without this, a later step's
    /// `replacementChunk` (a full-replace signal) would erase any visible text
    /// the model produced in an earlier step before invoking a tool.
    /// `@unchecked Sendable` + `NSLock`: `onAssistantTurnStarted` fires from
    /// the `@MainActor` engine loop, but `onAssistantText` fires from whatever
    /// thread the KMP streaming bridge calls back on (not guaranteed MainActor).
    private final class DiscussionStepTextAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var committedSteps: [String] = []
        private var currentStep = ""

        func startNewTurn() {
            lock.lock()
            defer { lock.unlock() }
            if !currentStep.isEmpty {
                committedSteps.append(currentStep)
            }
            currentStep = ""
        }

        func update(currentStep text: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            currentStep = text
            return (committedSteps + [currentStep])
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }

    static func discussionSearchTransport(
        using provider: any IOSAgentTextProvider,
        executors: @escaping @MainActor @Sendable (NovelProjectToolRunContext?) -> [String: any IOSToolExecutor]
    ) -> NovelLiveTransport {
        { request, callbacks in
            let task = Task { @MainActor in
                // One automatic retry only when the first attempt dies before any
                // assistant text (typical NSURLError -1005 on the opening request).
                // Never retry after tools/partial text — that would double-write.
                final class VisibleTextFlag: @unchecked Sendable {
                    private let lock = NSLock()
                    private var value = false
                    func mark() {
                        lock.lock(); value = true; lock.unlock()
                    }
                    func reset() {
                        lock.lock(); value = false; lock.unlock()
                    }
                    var isSet: Bool {
                        lock.lock(); defer { lock.unlock() }
                        return value
                    }
                }
                var result: IOSAgentToolEngineResult!
                let producedVisibleText = VisibleTextFlag()
                var executorMap: [String: any IOSToolExecutor] = [:]
                for attempt in 0..<2 {
                    executorMap = executors(request.novelProjectContext)
                    let engine = IOSAgentToolEngine(
                        provider: provider,
                        executors: executorMap,
                        configuration: .init(maxSteps: 16, honorApprovalPause: true)
                    )
                    let stepText = DiscussionStepTextAccumulator()
                    let stepReasoning = DiscussionStepTextAccumulator()
                    producedVisibleText.reset()
                    result = await engine.run(
                        providerSetting: request.providerSetting,
                        messages: request.messages,
                        params: request.parameters,
                        onAssistantTurnStarted: {
                            stepText.startNewTurn()
                            stepReasoning.startNewTurn()
                        },
                        onAssistantText: { text in
                            producedVisibleText.mark()
                            callbacks.onChunk(replacementChunk(stepText.update(currentStep: text)))
                        },
                        onAssistantReasoning: { text in
                            callbacks.onChunk(reasoningReplacementChunk(stepReasoning.update(currentStep: text)))
                        }
                    )
                    guard !Task.isCancelled else { return }
                    if attempt == 0,
                       !producedVisibleText.isSet,
                       let failureMessage = result.providerFailureMessage,
                       NovelPresentation.looksLikeTransportFailure(failureMessage) {
                        continue
                    }
                    break
                }
                if let failureMessage = result.providerFailureMessage {
                    callbacks.onFailure(failure(
                        code: "discussion_provider_failed",
                        message: failureMessage,
                        isRetryable: true
                    ))
                    return
                }
                if result.hitStepLimit {
                    callbacks.onFailure(failure(
                        code: "discussion_tool_step_limit",
                        message: "讨论时连续搜索次数过多，请缩小问题后重试。",
                        isRetryable: true
                    ))
                    return
                }
                // I-5:守护停止不得伪装成正常完成——引擎因重复相同调用而停止时,
                // 与 hitStepLimit 同样按可重试失败呈现,而不是落进下面的完成分支。
                if result.guardStopped {
                    callbacks.onFailure(failure(
                        code: "discussion_tool_loop_guard",
                        message: "讨论时模型反复执行相同搜索，已停止。请换个问法后重试。",
                        isRetryable: true
                    ))
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "ask_user" {
                    do {
                        let prompt = try decodeAskUserPrompt(approval.arguments)
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    } catch {
                        callbacks.onFailure(failure(
                            code: "discussion_ask_user_invalid",
                            message: "模型提出的问题格式无法读取，请重试。",
                            isRetryable: true
                        ))
                    }
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "novel_revise_chapter" {
                    guard let projectExecutor = executorMap["novel_revise_chapter"]
                            as? IOSNovelProjectToolExecutor else {
                        callbacks.onFailure(failure(
                            code: "discussion_chapter_revision_unavailable",
                            message: "当前讨论无法准备改正文审批，请重试。",
                            isRetryable: true
                        ))
                        return
                    }
                    switch await projectExecutor.revisionApprovalPrompt(from: approval.arguments) {
                    case .success(let prompt):
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    case .failure(let issue):
                        callbacks.onFailure(failure(
                            code: "discussion_chapter_revision_invalid",
                            message: issue.message,
                            isRetryable: true
                        ))
                    }
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "novel_workspace_write" {
                    guard let projectExecutor = executorMap["novel_workspace_write"]
                            as? IOSNovelProjectToolExecutor else {
                        callbacks.onFailure(failure(
                            code: "discussion_workspace_write_unavailable",
                            message: "当前讨论无法准备工作区写入审批，请重试。",
                            isRetryable: true
                        ))
                        return
                    }
                    switch await projectExecutor.workspaceWriteApprovalPrompt(from: approval.arguments) {
                    case .success(let prompt):
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    case .failure(let issue):
                        callbacks.onFailure(failure(
                            code: "discussion_workspace_write_invalid",
                            message: issue.message,
                            isRetryable: true
                        ))
                    }
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "novel_revert_recent_chapters" {
                    guard let projectExecutor = executorMap["novel_revert_recent_chapters"]
                            as? IOSNovelProjectToolExecutor else {
                        callbacks.onFailure(failure(
                            code: "discussion_manuscript_revert_unavailable",
                            message: "当前讨论无法准备回退章节审批，请重试。",
                            isRetryable: true
                        ))
                        return
                    }
                    switch await projectExecutor.revertApprovalPrompt(from: approval.arguments) {
                    case .success(let prompt):
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    case .failure(let issue):
                        callbacks.onFailure(failure(
                            code: "discussion_manuscript_revert_invalid",
                            message: issue.message,
                            isRetryable: true
                        ))
                    }
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "novel_delete_chapters" {
                    guard let projectExecutor = executorMap["novel_delete_chapters"]
                            as? IOSNovelProjectToolExecutor else {
                        callbacks.onFailure(failure(
                            code: "discussion_manuscript_delete_unavailable",
                            message: "当前讨论无法准备抽章审批，请重试。",
                            isRetryable: true
                        ))
                        return
                    }
                    switch await projectExecutor.deleteApprovalPrompt(from: approval.arguments) {
                    case .success(let prompt):
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    case .failure(let issue):
                        callbacks.onFailure(failure(
                            code: "discussion_manuscript_delete_invalid",
                            message: issue.message,
                            isRetryable: true
                        ))
                    }
                    return
                }
                if let approval = result.pendingApproval,
                   approval.toolName == "novel_prepare_ghostwrite" {
                    guard let projectExecutor = executorMap["novel_prepare_ghostwrite"]
                            as? IOSNovelProjectToolExecutor else {
                        callbacks.onFailure(failure(
                            code: "discussion_ghostwrite_plan_unavailable",
                            message: "当前讨论无法准备代笔审批，请重试。",
                            isRetryable: true
                        ))
                        return
                    }
                    switch await projectExecutor.ghostwritePlanApprovalPrompt(from: approval.arguments) {
                    case .success(let prompt):
                        callbacks.onAskUser(prompt, joinedAssistantText(in: result.messages))
                    case .failure(let issue):
                        callbacks.onFailure(failure(
                            code: "discussion_ghostwrite_plan_invalid",
                            message: issue.message,
                            isRetryable: true
                        ))
                    }
                    return
                }
                if result.pendingApproval != nil {
                    callbacks.onFailure(failure(
                        code: "discussion_tool_approval_required",
                        message: "当前搜索需要额外确认，请检查搜索服务设置后重试。",
                        isRetryable: true
                    ))
                    return
                }
                let finalText = joinedAssistantText(in: result.messages)
                guard !finalText.isEmpty else {
                    callbacks.onFailure(failure(
                        code: "discussion_empty_response",
                        message: "模型完成了搜索，但没有返回讨论内容，请重试。",
                        isRetryable: true
                    ))
                    return
                }
                // 讨论过程中已经把思考和正文流出去了。循环结束后再整包重放思考，
                // 会在正文已经可见之后把思考卡重新打开，看起来像「写完了还在想」。
                // 只有正文从未出现时，才在终态补一次思考（先思考后正文）。
                let finalReasoning = joinedAssistantReasoning(in: result.messages)
                if !finalReasoning.isEmpty, !producedVisibleText.isSet {
                    callbacks.onChunk(reasoningReplacementChunk(finalReasoning))
                }
                callbacks.onChunk(replacementChunk(finalText))
                callbacks.onComplete()
            }
            return NovelLiveCancellationHandle {
                task.cancel()
            }
        }
    }
}

