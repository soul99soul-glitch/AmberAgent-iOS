import Foundation
@preconcurrency import Shared

@MainActor
final class ChatKernelApprovalResolver {
    private let runtime: ChatToolRuntime
    private let ledger: any IOSAgentRunLedgering
    private let onRunResumed: () async -> Bool
    private let onDurabilityFailure: () -> Void

    init(
        runtime: ChatToolRuntime,
        ledger: any IOSAgentRunLedgering,
        onRunResumed: @escaping () async -> Bool,
        onDurabilityFailure: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.ledger = ledger
        self.onRunResumed = onRunResumed
        self.onDurabilityFailure = onDurabilityFailure
    }

    /// 暂停点从 runtime 取走的 prepared 候选(对齐 CGC pauseForApproval
    /// :3755-3780 的交接纪律:候选与本次暂停绑定,取走即删除,绝不跨暂停复用)。
    /// internal 是 A2 聚焦单测的接缝(@testable):mcp/council/recipe 的暂停
    /// 无法用轻量具装端到端触发,由测试直接驱动 resolveApproval 钉纪律。
    struct PreparedApprovalCandidates {
        var skillImport: IOSPreparedSkillImport?
        var soulImport: IOSPreparedSoulImport?
        var mcpImport: IOSPreparedMcpImport?
        var recipeImport: IOSPreparedRecipeImport?
        var pluginImport: IOSPreparedPluginImport?
        var pluginInvocation: IOSPreparedPluginInvocation?
        var recipeExecution: IOSRecipeExecutionState?
    }

    enum ApprovalResolution {
        /// 回填完成,以返回消息重启引擎循环。
        case resumed([UIMessage])
        /// recipe mutation step 命中下一步暂停:同一 toolCallId 带新请求重进暂停。
        case rePause(ChatToolApprovalPrompt)
        case outcomeUnknown([UIMessage])
        /// 诚实失败,run 以 failed 收口。
        case failed
    }

    /// 按审批卡类目执行决定,账本纪律逐类对齐 CGC 的 finishPendingXxx:
    /// - 布尔类目(search/webMount/workspace/ish/mcp/council/recipe-import):
    ///   Started → resume → finisher → Finished(completed/denied)
    ///   (executeApprovedAsyncTool :4425-4471);
    /// - memory:Started → resume → finisher → Finished 恒 completed——deny
    ///   策略产出成功形态的结构化拒绝(CG-C :3953);
    /// - askUser:Started → resume → finishAskUserAnswer → Finished(completed);
    /// - recipe step:批准写 Started 后先恢复 run，再执行；若下一 mutation
    ///   step 仍需批准，则 Finished(paused_for_approval) 后重进暂停。拒绝不
    ///   新增 Started，而是关闭 executeBatch 已建立的 waitingUser 外层事务；
    ///   approval_denied 仍由 runtime recordToolApproval 漏斗写入。
    /// internal:A2 聚焦单测接缝(见 PreparedApprovalCandidates 注释)。
    func resolveApproval(
        prompt: ChatToolApprovalPrompt,
        decision: ChatKernelApprovalDecision,
        pending: ChatPendingToolApproval,
        candidates: PreparedApprovalCandidates,
        request: ChatRunKernelAdapter.RunRequest
    ) async -> ApprovalResolution {
        await runtime.withExecutionPolicy(pending.executionPolicy) {
            await self.resolveApprovalWithCurrentExecutionPolicy(
                prompt: prompt,
                decision: decision,
                pending: pending,
                candidates: candidates,
                request: request
            )
        }
    }

    private func resolveApprovalWithCurrentExecutionPolicy(
        prompt: ChatToolApprovalPrompt,
        decision: ChatKernelApprovalDecision,
        pending: ChatPendingToolApproval,
        candidates: PreparedApprovalCandidates,
        request: ChatRunKernelAdapter.RunRequest
    ) async -> ApprovalResolution {
        switch prompt {
        case .search, .webMount, .workspace, .ish, .mcp, .council:
            guard let allow = decision.boolValue else { return .failed }
            guard await recordApprovalAttemptStarted(
                pending: pending,
                effectClass: Self.resumeEffectClass(for: prompt, input: pending.toolCall.input)
            ) else { return .failed }
            // resume 录制点对齐 CGC claimRunAfterPermission;失败时账本补
            // Finished(not_executed_permission_claim_failed) 并诚实收口
            // (CG-C :4310-4325——Host 侧已呈现「无法恢复待确认任务」)。
            guard await onRunResumed() else {
                if !(await ledger.recordToolCallFinished(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    outcome: "not_executed_permission_claim_failed"
                )) {
                    onDurabilityFailure()
                }
                return .failed
            }
            let messages = await finishBoolApproval(
                prompt: prompt,
                allow: allow,
                pending: pending,
                candidates: candidates
            )
            if case .webMount = prompt,
               allow,
               runtime.isWebMountOutcomeUnknown(
                   in: messages,
                   toolCallId: pending.toolCall.toolCallId
               ) {
                guard await ledger.recordToolCallRecoveryTransition(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    expected: .started,
                    to: .outcomeUnknown,
                    outcome: "executor_reported_unknown_after_action"
                ) else {
                    onDurabilityFailure()
                    return .failed
                }
                return .outcomeUnknown(messages)
            }
            guard await recordToolTerminal(
                runId: pending.runId,
                toolCallId: pending.toolCall.toolCallId,
                outcome: allow ? "completed" : "denied",
                messages: messages
            ) else { return .failed }
            return .resumed(messages)

        case .memory(let memoryRequest):
            let writePolicy: IOSMemoryToolWritePolicy
            switch decision {
            case .approve:
                writePolicy = .allow
            case .deny:
                writePolicy = .deniedByUser("User denied memory write.")
            case .answer:
                return .failed
            }
            guard await recordApprovalAttemptStarted(
                pending: pending,
                effectClass: Self.resumeEffectClass(for: prompt, input: pending.toolCall.input)
            ) else { return .failed }
            guard await onRunResumed() else {
                if !(await ledger.recordToolCallFinished(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    outcome: "not_executed_permission_claim_failed"
                )) {
                    onDurabilityFailure()
                }
                return .failed
            }
            let messages = runtime.finishMemoryApproval(
                pending: pending,
                writePolicy: writePolicy,
                expectedUpdatedAt: memoryRequest.expectedUpdatedAt
            )
            guard await recordToolTerminal(
                runId: pending.runId,
                toolCallId: pending.toolCall.toolCallId,
                outcome: "completed",
                messages: messages
            ) else { return .failed }
            return .resumed(messages)

        case .askUser:
            guard case .answer(let answer) = decision else { return .failed }
            guard await recordApprovalAttemptStarted(pending: pending, effectClass: .pure) else {
                return .failed
            }
            guard await onRunResumed() else {
                if !(await ledger.recordToolCallFinished(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    outcome: "not_executed_permission_claim_failed"
                )) {
                    onDurabilityFailure()
                }
                return .failed
            }
            let messages = runtime.finishAskUserAnswer(pending: pending, answer: answer)
            guard await recordToolTerminal(
                runId: pending.runId,
                toolCallId: pending.toolCall.toolCallId,
                outcome: "completed",
                messages: messages
            ) else { return .failed }
            return .resumed(messages)

        case .recipe(let recipeRequest):
            switch recipeRequest.payload {
            case .recipeImport:
                guard let allow = decision.boolValue else { return .failed }
                guard await recordApprovalAttemptStarted(pending: pending, effectClass: .sideEffect) else {
                    return .failed
                }
                guard await onRunResumed() else {
                    if !(await ledger.recordToolCallFinished(
                        runId: pending.runId,
                        toolCallId: pending.toolCall.toolCallId,
                        outcome: "not_executed_permission_claim_failed"
                    )) {
                        onDurabilityFailure()
                    }
                    return .failed
                }
                let messages: [UIMessage]
                if recipeRequest.isPluginImport || candidates.pluginImport != nil {
                    messages = await runtime.finishPluginImportApproval(
                        pending: pending,
                        allow: allow,
                        prepared: candidates.pluginImport
                    )
                } else {
                    messages = await runtime.finishRecipeImportApproval(
                        pending: pending,
                        allow: allow,
                        prepared: candidates.recipeImport
                    )
                }
                guard await recordToolTerminal(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    outcome: allow ? "completed" : "denied",
                    messages: messages
                ) else { return .failed }
                return .resumed(messages)

            case .pluginInvocation(let payload):
                guard let allow = decision.boolValue else { return .failed }
                guard await recordApprovalAttemptStarted(
                    pending: pending,
                    effectClass: payload.effectClass
                ) else { return .failed }
                guard await onRunResumed() else {
                    if !(await ledger.recordToolCallFinished(
                        runId: pending.runId,
                        toolCallId: pending.toolCall.toolCallId,
                        outcome: "not_executed_permission_claim_failed"
                    )) {
                        onDurabilityFailure()
                    }
                    return .failed
                }
                let messages = await runtime.finishPluginInvocationApproval(
                    pending: pending,
                    allow: allow,
                    prepared: candidates.pluginInvocation,
                    toolExposureBridge: request.toolExposureBridge
                )
                if allow,
                   runtime.isPluginOutcomeUnknown(
                       in: messages,
                       toolCallId: pending.toolCall.toolCallId
                   ) {
                    guard await ledger.recordToolCallRecoveryTransition(
                        runId: pending.runId,
                        toolCallId: pending.toolCall.toolCallId,
                        expected: .started,
                        to: .outcomeUnknown,
                        outcome: "executor_reported_unknown_after_action"
                    ) else {
                        onDurabilityFailure()
                        return .failed
                    }
                    return .outcomeUnknown(messages)
                }
                guard await recordToolTerminal(
                    runId: pending.runId,
                    toolCallId: pending.toolCall.toolCallId,
                    outcome: allow ? "completed" : "denied",
                    messages: messages
                ) else { return .failed }
                return .resumed(messages)

            case .step:
                guard let execution = candidates.recipeExecution else {
                    // CG-C :4102-4117 fail-closed:无准备上下文,零账本对,
                    // 填结构化失败让循环继续,绝不退回普通 dispatch。
                    let failure = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "Recipe 执行上下文已失效,请重新发起调用。",
                        status: "failed"
                    )
                    let messages = runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: failure,
                        in: pending.baseMessages
                    )
                    let didResume = await onRunResumed()
                    guard await recordWaitingApprovalTerminal(
                        runId: pending.runId,
                        toolCallId: pending.toolCall.toolCallId,
                        outcome: "failed_context_lost",
                        messages: messages
                    ) else { return .failed }
                    return didResume ? .resumed(messages) : .failed
                }
                switch decision {
                case .answer:
                    return .failed
                case .deny:
                    let result = await runtime.finishRecipeStepApproval(
                        pending: pending,
                        allow: false,
                        executionContext: execution,
                        toolExposureBridge: request.toolExposureBridge
                    )
                    guard case .completed(let messages) = result else { return .failed }
                    // 用户拒绝已经是最终决定：先清掉 recipe checkpoint，再尝试
                    // 恢复 durable run；即使恢复声明失败，也必须关闭 outer tx。
                    let didResume = await onRunResumed()
                    guard await recordWaitingApprovalTerminal(
                        runId: pending.runId,
                        toolCallId: pending.toolCall.toolCallId,
                        outcome: "denied",
                        messages: messages
                    ) else { return .failed }
                    return didResume ? .resumed(messages) : .failed
                case .approve:
                    guard await recordApprovalAttemptStarted(pending: pending, effectClass: .sideEffect) else {
                        return .failed
                    }
                    guard await onRunResumed() else {
                        if !(await ledger.recordToolCallFinished(
                            runId: pending.runId,
                            toolCallId: pending.toolCall.toolCallId,
                            outcome: "not_executed_permission_claim_failed"
                        )) {
                            onDurabilityFailure()
                        }
                        return .failed
                    }
                    let result = await runtime.finishRecipeStepApproval(
                        pending: pending,
                        allow: true,
                        executionContext: execution,
                        toolExposureBridge: request.toolExposureBridge
                    )
                    switch result {
                    case .completed(let messages):
                        guard await recordToolTerminal(
                            runId: pending.runId,
                            toolCallId: pending.toolCall.toolCallId,
                            outcome: "completed",
                            messages: messages
                        ) else { return .failed }
                        return .resumed(messages)
                    case .pausedForNextStep(let nextRequest):
                        guard await ledger.recordToolCallFinished(
                            runId: pending.runId,
                            toolCallId: pending.toolCall.toolCallId,
                            outcome: "paused_for_approval"
                        ) else {
                            onDurabilityFailure()
                            return .failed
                        }
                        return .rePause(.recipe(nextRequest))
                    case .durabilityFailure:
                        onDurabilityFailure()
                        return .failed
                    case .outcomeUnknown(let messages):
                        guard await ledger.recordToolCallRecoveryTransition(
                            runId: pending.runId,
                            toolCallId: pending.toolCall.toolCallId,
                            expected: .started,
                            to: .outcomeUnknown,
                            outcome: "recipe_step_outcome_unknown"
                        ) else {
                            onDurabilityFailure()
                            return .failed
                        }
                        return .outcomeUnknown(messages)
                    }
                }
            }
        }
    }

    /// 布尔类目 finisher 分发(与 CGC finishPendingXxxToolApproval 一一对应)。
    /// mcp 的 prepared 候选在暂停点交接;缺失时 finisher 内部 fail-closed
    /// (「预览已失效」),账本对照常写——与 executeApprovedToolOrNested 一致。
    private func finishBoolApproval(
        prompt: ChatToolApprovalPrompt,
        allow: Bool,
        pending: ChatPendingToolApproval,
        candidates: PreparedApprovalCandidates
    ) async -> [UIMessage] {
        switch prompt {
        case .search:
            return await runtime.finishSearchApproval(pending: pending, allow: allow)
        case .webMount(let request):
            return await runtime.finishWebMountApproval(
                pending: pending,
                allow: allow,
                approvalRequest: request
            )
        case .workspace:
            return await runtime.finishWorkspaceApproval(pending: pending, allow: allow)
        case .ish(let request):
            return await runtime.finishIshHandoffApproval(
                pending: pending,
                allow: allow,
                approvalRequest: request
            )
        case .mcp:
            return await runtime.finishMcpApproval(
                pending: pending,
                allow: allow,
                preparedSkillImport: candidates.skillImport,
                preparedSoulImport: candidates.soulImport,
                preparedMcpImport: candidates.mcpImport
            )
        case .council:
            return await runtime.finishCouncilApproval(pending: pending, allow: allow)
        case .memory, .askUser, .recipe:
            // resolveApproval 已把非布尔类目分流;到达这里即适配层 bug。
            return runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "审批类目分发错误。",
                    denied: !allow
                ),
                in: pending.baseMessages
            )
        }
    }

    /// 暂停点的 prepared 候选交接(对齐 CGC pauseForApproval 的 switch:
    /// mcp 取 skill/soul/mcp 三件;recipe 按 payload 取 import 或执行状态)。
    func takePreparedCandidates(
        for prompt: ChatToolApprovalPrompt,
        toolCallId: String
    ) -> PreparedApprovalCandidates {
        var candidates = PreparedApprovalCandidates()
        switch prompt {
        case .mcp:
            candidates.skillImport = runtime.takePreparedSkillImportForApproval(toolCallId: toolCallId)
            candidates.soulImport = runtime.takePreparedSoulImportForApproval(toolCallId: toolCallId)
            candidates.mcpImport = runtime.takePreparedMcpImportForApproval(toolCallId: toolCallId)
        case .recipe(let recipeRequest):
            switch recipeRequest.payload {
            case .step:
                candidates.recipeExecution = runtime.takePreparedRecipeExecution(toolCallId: toolCallId)
            case .pluginInvocation:
                candidates.pluginInvocation = runtime.takePreparedPluginInvocationForApproval(toolCallId: toolCallId)
            case .recipeImport:
                if recipeRequest.isPluginImport {
                    candidates.pluginImport = runtime.takePreparedPluginImportForApproval(toolCallId: toolCallId)
                } else {
                    candidates.recipeImport = runtime.takePreparedRecipeImportForApproval(toolCallId: toolCallId)
                }
            }
        case .memory, .search, .webMount, .workspace, .ish, .council, .askUser:
            break
        }
        return candidates
    }

    /// 恢复半边的账本 Started(executeApprovedAsyncTool :4425 同款纪律:
    /// 本次尝试在同一 toolCallId 下先落 Started,再执行副作用)。
    private func recordApprovalAttemptStarted(
        pending: ChatPendingToolApproval,
        effectClass: IOSToolEffectClass
    ) async -> Bool {
        await ledger.recordToolCallStarted(
            runId: pending.runId,
            toolCallId: pending.toolCall.toolCallId,
            toolName: pending.toolCall.toolName,
            argsDigest: chatInputDigest(for: pending.toolCall.input),
            effectClass: effectClass
        )
    }

    func recordToolTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        messages: [UIMessage]
    ) async -> Bool {
        let parts = ChatRunKernelAdapter.toolPart(toolCallId: toolCallId, in: messages)?.output
        let recorded = await ledger.recordToolCallTerminal(
            runId: runId,
            toolCallId: toolCallId,
            outcome: outcome,
            resultPayload: parts.map { IosToolOutputJsonBridge.shared.encode(parts: $0) }
        )
        if !recorded { onDurabilityFailure() }
        return recorded
    }

    private func recordWaitingApprovalTerminal(
        runId: String,
        toolCallId: String,
        outcome: String,
        messages: [UIMessage]
    ) async -> Bool {
        let parts = ChatRunKernelAdapter.toolPart(toolCallId: toolCallId, in: messages)?.output
        let recorded = await ledger.recordWaitingToolApprovalTerminal(
            runId: runId,
            toolCallId: toolCallId,
            outcome: outcome,
            resultPayload: parts.map { IosToolOutputJsonBridge.shared.encode(parts: $0) }
        )
        if !recorded { onDurabilityFailure() }
        return recorded
    }

    /// CGC 恢复路径各审批类目的硬编码 effectClass——注意 search 在恢复
    /// 路径是 .pure(CG-C :3979),不同于 forChatKind 映射的 .networkRead。
    nonisolated static func resumeEffectClass(
        for prompt: ChatToolApprovalPrompt,
        input: String
    ) -> IOSToolEffectClass {
        switch prompt {
        case .search, .askUser:
            return .pure
        case .memory:
            return IOSToolEffectClassMapping.forChatKind(.memory, input: input)
        case .webMount, .workspace, .ish, .mcp, .council, .recipe:
            return .sideEffect
        }
    }

}
