import Foundation
@preconcurrency import Shared

@MainActor
final class ChatRecipeExecution {
    unowned let runtime: ChatToolRuntime
    private var preparedImports: [String: IOSPreparedRecipeImport] = [:]
    private var preparedExecutions: [String: IOSRecipeExecutionState] = [:]
    private let checkpointStore: IOSRecipeExecutionCheckpointStore

    init(runtime: ChatToolRuntime, baseDirectory: URL?) {
        self.runtime = runtime
        let resolvedDirectory = baseDirectory
            ?? (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ))
            ?? FileManager.default.temporaryDirectory
        checkpointStore = IOSRecipeExecutionCheckpointStore(
            baseDirectory: resolvedDirectory, fileManager: .default
        )
    }

    func storePreparedImport(_ value: IOSPreparedRecipeImport, toolCallId: String) {
        preparedImports[toolCallId] = value
    }

    func takePreparedImport(toolCallId: String) -> IOSPreparedRecipeImport? {
        preparedImports.removeValue(forKey: toolCallId)
    }

    func discardPreparedImport(toolCallId: String) {
        preparedImports.removeValue(forKey: toolCallId)
    }

    func takePreparedExecution(toolCallId: String) -> IOSRecipeExecutionState? {
        preparedExecutions.removeValue(forKey: toolCallId)
    }

    func discardPreparedExecution(toolCallId: String) {
        preparedExecutions.removeValue(forKey: toolCallId)
        checkpointStore.remove(toolCallId: toolCallId)
    }


    func executeRecipeToolCall(
        _ pending: ChatPendingToolApproval,
        snapshot: IOSDynamicToolCatalogSnapshot?,
        bridge: IosToolExposureBridge?,
        candidate: IOSDynamicRecipeToolDescriptor? = nil,
        argumentsJSON: String? = nil,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> ChatToolRuntimeResult {
        let toolName = pending.toolCall.toolName
        let recipeCallFailure = { (reason: String) -> ChatToolRuntimeResult in
            .completed(self.runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolName,
                    reason: reason,
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }

        // At most one recipe pause can be live per process; any checkpoint
        // file on disk at the start of a new execution is an orphan from a
        // crashed pause (cold-start recovery terminates approvals fail-closed,
        // so it is never resumed — sweep instead of resurrecting).
        checkpointStore.sweepOrphans()

        // Fail closed: the round's snapshot does not declare this recipe
        // (rolled back, or the model used a stale name). Never execute from
        // the live store — a call the model saw must match what it saw.
        guard let descriptor = candidate ?? snapshot?.recipeTools.first(where: { $0.toolId == toolName }) else {
            return recipeCallFailure("此 Recipe 不在当前工具目录中（可能已被回退或版本已更新）。请先调用 tool_search 获取最新工具。")
        }
        guard case .recipe(let recipeManifest) = descriptor.implementation else {
            return recipeCallFailure("动态工具处理器类型不匹配，请刷新工具目录后重试。")
        }
        guard preparedExecutions[pending.toolCall.toolCallId] == nil else {
            // Continuations go through the finisher, never through a second
            // dispatch of the same call; a re-entry is a stale round.
            return recipeCallFailure("此 Recipe 调用已在审批中，请先在审批卡上确认。")
        }

        let inputs: [String: IOSRecipeJSONValue]
        do {
            let value = try JSONDecoder().decode(IOSRecipeJSONValue.self, from: Data((argumentsJSON ?? pending.toolCall.input).utf8))
            guard case .object(let object) = value else {
                return recipeCallFailure("Recipe 调用参数必须是 JSON 对象。")
            }
            inputs = object
        } catch {
            return recipeCallFailure("Recipe 调用参数不是合法的 JSON：\(error.localizedDescription)")
        }

        let runner = makeRecipeRunner(manifest: recipeManifest, context: pending, bridge: bridge)
        let plan: IOSRecipeExecutionPlan
        do {
            plan = try runner.resolvePlan(inputs: inputs)
        } catch let error as IOSRecipeRunError {
            await recordRecipeLevelFinished(
                recipeName: descriptor.recipeName,
                recipeVersion: descriptor.version,
                executionId: "recipe-\(UUID().uuidString)",
                outcome: "failed", outcomeKind: "error",
                errorCode: Self.recipeErrorCode(for: error),
                runId: pending.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(failedStep: nil, error: error, completedSteps: [])
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: "Recipe 执行计划校验失败。",
                        status: "failed"
                    ),
                in: pending.baseMessages
            ))
        } catch {
            return recipeCallFailure("Recipe 执行计划无法解析：\(error.localizedDescription)")
        }

        var state = IOSRecipeExecutionState(
            toolCallId: pending.toolCall.toolCallId,
            executionId: "recipe-\(UUID().uuidString)",
            recipeName: descriptor.recipeName,
            recipeVersion: descriptor.version,
            pluginId: descriptor.pluginId,
            pluginPackageHash: descriptor.pluginId == nil ? nil : descriptor.manifestHash,
            capabilityBroker: descriptor.capabilityBroker,
            catalogRevision: snapshot?.revision,
            manifest: recipeManifest,
            plan: plan,
            inputs: inputs,
            stepOutputs: [:],
            completedSteps: [],
            nextStepIndex: 0
        )
        state.candidateTest = candidateTest
        switch await advanceRecipeExecution(state: &state, context: pending, bridge: bridge) {
        case .completed(let messages):
            return .completed(messages)
        case .needsApproval(let request):
            return .waitingForApproval(.recipe(request))
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        case .outcomeUnknown(let messages):
            return .outcomeUnknown(messages)
        }
    }

    /// Runs steps from `state.nextStepIndex` until the next approval-requiring
    /// step or completion. When a step needs approval the checkpoint is
    /// persisted and the state is stashed (keyed by toolCallId) so the
    /// finisher can continue the recipe on approval (§10.3.5: each mutation
    /// step pauses again). On completion/failure the checkpoint and the
    /// stashed state are removed here.
    ///
    /// `skipGateForFirstStep`: the finisher's allow path resumes AT the step
    /// the user just approved — re-gating it would pause the same step again
    /// (an approval loop). The approved step bypasses the gate exactly like
    /// the top-level post-approval path (`isUserInitiated: true`); every
    /// LATER step is gated normally.
    private func advanceRecipeExecution(
        state: inout IOSRecipeExecutionState,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        skipGateForFirstStep: Bool = false
    ) async -> RecipeAdvanceOutcome {
        var runner = makeRecipeRunner(manifest: state.manifest, context: context, bridge: bridge)
        var skipGate = skipGateForFirstStep
        while state.nextStepIndex < state.plan.steps.count {
            let step = state.plan.steps[state.nextStepIndex]
            runner = makeRecipeRunner(
                manifest: state.manifest,
                context: context,
                bridge: bridge,
                searchStepApproved: skipGate
            )

            // Resolve the step's arguments BEFORE the approval gate so the
            // card can show what the step will actually call with.
            let argsJSON: String
            do {
                argsJSON = try runner.resolveArguments(
                    step: step,
                    inputs: state.inputs,
                    stepOutputs: state.stepOutputs
                )
            } catch let error as IOSRecipeRunError {
                // Same Finished-only trace as the pre-refactor runner (the
                // step never Started), then stop the recipe.
                await recordRecipeStepFinishedOnly(
                    state: state, step: step, errorCode: "argument_binding", runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: Self.recipeErrorCode(for: error),
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: error, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤参数解析失败。",
                            status: "failed"
                        )
                ))
            } catch {
                let runError = IOSRecipeRunError.argumentBinding(
                    stepId: step.id, key: "", reason: error.localizedDescription
                )
                await recordRecipeStepFinishedOnly(
                    state: state, step: step, errorCode: "argument_binding", runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: "argument_binding",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: runError, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤参数解析失败。",
                            status: "failed"
                        )
                ))
            }

            if let broker = state.capabilityBroker,
               let reason = broker.authorize(tool: step.tool, argumentsJSON: argsJSON) {
                let error = IOSRecipeRunError.stepFailed(
                    stepId: step.id,
                    tool: step.tool,
                    message: reason
                )
                await recordRecipeStepFinishedOnly(
                    state: state,
                    step: step,
                    errorCode: "capability_denied",
                    runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed",
                    outcomeKind: "denied",
                    errorCode: "capability_denied",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id,
                    error: error,
                    completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state,
                    context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: reason,
                            status: "failed"
                        )
                ))
            }

            if !skipGate {
                switch await recipeStepGate(
                    tool: step.tool,
                    argsJSON: argsJSON,
                    context: context
                ) {
                case .unsupported(let reason):
                    let error = IOSRecipeRunError.stepFailed(stepId: step.id, tool: step.tool, message: reason)
                    await recordRecipeLevelFinished(
                        recipeName: state.recipeName,
                        recipeVersion: state.recipeVersion,
                        executionId: state.executionId,
                        outcome: "failed", outcomeKind: "error",
                        errorCode: "unsupported_step",
                        runId: context.runId
                    )
                    let outcome = IOSRecipeRunOutcome.failed(
                        failedStep: step.id, error: error, completedSteps: state.completedSteps
                    )
                    return .completed(finishRecipeCall(
                        state: state, context: context,
                        outputText: runner.structuredErrorJSON(for: outcome)
                            ?? ChatToolOutputFormatter.toolFailureJSON(
                                toolName: context.toolCall.toolName,
                                reason: reason,
                                status: "failed"
                            )
                    ))
                case .approvalRequired(let reason):
                    // Durable pause: the checkpoint is on disk BEFORE the
                    // coordinator marks the run awaiting permission.
                    guard checkpointStore.save(state.checkpoint()) else {
                        let failureReason = "无法保存 Recipe 待确认状态，请检查存储空间后重试。"
                        let error = IOSRecipeRunError.stepFailed(
                            stepId: step.id,
                            tool: step.tool,
                            message: failureReason
                        )
                        await recordRecipeStepFinishedOnly(
                            state: state,
                            step: step,
                            errorCode: "checkpoint_write",
                            runId: context.runId
                        )
                        await recordRecipeLevelFinished(
                            recipeName: state.recipeName,
                            recipeVersion: state.recipeVersion,
                            executionId: state.executionId,
                            outcome: "failed",
                            outcomeKind: "error",
                            errorCode: "checkpoint_write",
                            runId: context.runId
                        )
                        let outcome = IOSRecipeRunOutcome.failed(
                            failedStep: step.id,
                            error: error,
                            completedSteps: state.completedSteps
                        )
                        return .completed(finishRecipeCall(
                            state: state,
                            context: context,
                            outputText: runner.structuredErrorJSON(for: outcome)
                                ?? ChatToolOutputFormatter.toolFailureJSON(
                                    toolName: context.toolCall.toolName,
                                    reason: failureReason,
                                    status: "failed"
                                )
                        ))
                    }
                    preparedExecutions[state.toolCallId] = state
                    let payload = RecipeStepApprovalPayload(
                        stepId: step.id,
                        tool: step.tool,
                        argumentsPreview: recipeArgumentsPreview(argsJSON),
                        effectClass: step.effectClass
                    )
                    return .needsApproval(RecipeToolApprovalRequestBuilder.stepRequest(
                        for: context.toolCall,
                        recipeName: state.recipeName,
                        recipeVersion: state.recipeVersion,
                        payload: payload,
                        reason: reason,
                        executionId: state.executionId
                    ))
                case .proceed:
                    break
                }
            }
            // Only the resumed (just-approved) step bypasses the gate; from
            // here on every step is gated again.
            skipGate = false

            do {
                let output = try await runner.runStep(
                    plan: state.plan, step: step, executionId: state.executionId,
                    inputs: state.inputs, stepOutputs: state.stepOutputs
                )
                state.stepOutputs[step.id] = output
                state.completedSteps.append(step.id)
                state.nextStepIndex += 1
            } catch let error as IOSRecipePrimitiveOutcomeUnknownError {
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "outcome_unknown",
                    outcomeKind: "unknown",
                    errorCode: "unknown_after_action",
                    runId: context.runId
                )
                let resultText = IOSWebMountController.json([
                    "ok": false,
                    "tool": context.toolCall.toolName,
                    "status": "unknown_after_action",
                    "error_code": "unknown_after_action",
                    "may_have_applied": true,
                    "failed_step": step.id,
                    "completed_steps": state.completedSteps,
                    "reason": "Recipe 中的 WebMount 操作已发出，但无法确认是否生效；后续步骤已停止。",
                    "step_output": error.outputText
                ])
                return .outcomeUnknown(finishRecipeCall(
                    state: state,
                    context: context,
                    outputText: resultText
                ))
            } catch is IOSRecipeToolTerminalPersistenceError {
                discardPreparedExecution(toolCallId: state.toolCallId)
                return .durabilityFailure("tool result ledger write failed")
            } catch let error as IOSRecipeRunError {
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: Self.recipeErrorCode(for: error),
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: error, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤执行失败。",
                            status: "failed"
                        )
                ))
            } catch {
                let runError = IOSRecipeRunError.stepFailed(
                    stepId: step.id, tool: step.tool, message: error.localizedDescription
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: "step_failed",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: runError, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤执行失败。",
                            status: "failed"
                        )
                ))
            }
        }

        // All steps completed: resolve the recipe outputs (§10.3.1).
        do {
            let outputs = try runner.resolveOutputs(plan: state.plan, stepOutputs: state.stepOutputs)
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "completed", outcomeKind: "success",
                errorCode: nil,
                runId: context.runId
            )
            let resultText = recipeResultJSON(outputs: outputs, completedSteps: state.completedSteps)
            return .completed(finishRecipeCall(state: state, context: context, outputText: resultText))
        } catch let error as IOSRecipeRunError {
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "failed", outcomeKind: "error",
                errorCode: Self.recipeErrorCode(for: error),
                runId: context.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(
                failedStep: nil, error: error, completedSteps: state.completedSteps
            )
            return .completed(finishRecipeCall(
                state: state, context: context,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: context.toolCall.toolName,
                        reason: "Recipe 输出解析失败。",
                        status: "failed"
                    )
            ))
        } catch {
            let runError = IOSRecipeRunError.outputResolution(outputName: "", reason: error.localizedDescription)
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "failed", outcomeKind: "error",
                errorCode: "output_resolution",
                runId: context.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(
                failedStep: nil, error: runError, completedSteps: state.completedSteps
            )
            return .completed(finishRecipeCall(
                state: state, context: context,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: context.toolCall.toolName,
                        reason: "Recipe 输出解析失败。",
                        status: "failed"
                    )
            ))
        }
    }

    /// Finisher continuation of a paused mutation step. `allow`:
    /// - executes the approved step (its policy gate is bypassed via
    ///   `isUserInitiated: true`, the existing post-approval contract) and
    ///   CONTINUES the recipe — a later mutation step pauses again;
    /// - deny: the step fails, the recipe stops, a structured error with the
    ///   completed-side-effects list is returned (§10.3.6) and the
    ///   `approval_denied` ledger event is written through `recordToolApproval`
    ///   (the Phase 0 evidence funnel).
    func finishRecipeStepApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        executionContext: IOSRecipeExecutionState?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> RecipeApprovalFinishResult {
        let toolCallId = pending.toolCall.toolCallId
        guard var state = executionContext ?? preparedExecutions[toolCallId] else {
            // Fail closed: the prepared execution is gone (cold start or run
            // replaced); never fall back to a fresh preview/execution.
            let failure = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "Recipe 执行上下文已失效，请重新发起调用。",
                status: "failed"
            )
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: failure,
                in: pending.baseMessages
            ))
        }

        guard !allow else {
            runtime.recordToolApproval(
                capabilityId: "ios.agent.recipe_execution",
                toolCall: pending.toolCall,
                action: .allowed,
                reason: "User approved recipe step.",
                runId: pending.runId,
                executionPolicy: pending.executionPolicy
            )
            // The resumed step is the one the user just approved — skip its
            // gate (the top-level post-approval contract); later steps gate
            // normally (§10.3.5: each mutation step pauses again).
            let executionPolicy = pending.executionPolicy ?? IOSExecutionPolicyContext.snapshot
            let advanceOutcome = await runtime.withExecutionPolicy(executionPolicy) {
                await advanceRecipeExecution(
                    state: &state, context: pending, bridge: toolExposureBridge,
                    skipGateForFirstStep: true
                )
            }
            switch advanceOutcome {
            case .completed(let messages):
                return .completed(messages)
            case .needsApproval(let request):
                return .pausedForNextStep(request)
            case .durabilityFailure(let message):
                return .durabilityFailure(message)
            case .outcomeUnknown(let messages):
                return .outcomeUnknown(messages)
            }
        }

        // Denial: the approved step fails, the recipe stops (§10.3.6).
        runtime.recordToolApproval(
            capabilityId: "ios.agent.recipe_execution",
            toolCall: pending.toolCall,
            action: .denied,
            reason: "User denied recipe step.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        discardPreparedExecution(toolCallId: toolCallId)
        let step = state.plan.steps[state.nextStepIndex]
        let error = IOSRecipeRunError.stepFailed(
            stepId: step.id, tool: step.tool, message: "用户拒绝了该步骤，Recipe 已停止。"
        )
        await recordRecipeLevelFinished(
            recipeName: state.recipeName,
            recipeVersion: state.recipeVersion,
            executionId: state.executionId,
            outcome: "failed", outcomeKind: "denied",
            errorCode: "step_denied",
            runId: pending.runId
        )
        let runner = makeRecipeRunner(manifest: state.manifest, context: pending, bridge: toolExposureBridge)
        let outcome = IOSRecipeRunOutcome.failed(
            failedStep: step.id, error: error, completedSteps: state.completedSteps
        )
        return .completed(runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: runner.structuredErrorJSON(for: outcome)
                ?? ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "用户拒绝了该步骤，Recipe 已停止。",
                    denied: true
                ),
            in: pending.baseMessages
        ))
    }

    /// `recipe_import` approval resolution: re-reads the Workspace candidate,
    /// re-validates base/candidate CAS + semantics, applies (zero writes on
    /// any stale change) and refreshes the registry so the next model round
    /// sees the promotion. Denial records the `approval_denied` ledger event.
    func finishRecipeImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedRecipeImport?
    ) async -> [UIMessage] {
        runtime.recordToolApproval(
            capabilityId: "ios.agent.recipe_import",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved recipe import." : "User denied recipe import.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            if let prepared {
                do {
                    resultText = try await runtime.recipeToolService.applyPreparedRecipeImport(prepared)
                } catch {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    )
                }
            } else {
                // 冷启动或审批内存态丢失时 fail closed；绝不能退回普通 dispatch。
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "Recipe 导入预览已失效，请重新发起导入并确认最新变更。",
                    status: "failed"
                )
            }
        } else {
            resultText = "用户拒绝导入 Recipe。"
        }
        return runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    private func makeRecipeRunner(
        manifest: IOSRecipeManifest,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        searchStepApproved: Bool = false
    ) -> IOSRecipeRunner {
        IOSRecipeRunner(
            manifest: manifest,
            artifactId: context.toolCall.toolName,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            executePrimitive: { [weak self] tool, argsJSON in
                guard let self else {
                    throw IOSRecipeRunError.stepFailed(
                        stepId: "", tool: tool, message: "Chat runtime is unavailable."
                    )
                }
                switch await self.executeRecipePrimitiveStep(
                    tool: tool,
                    argsJSON: argsJSON,
                    isUserInitiated: IOSSearchExecutor.supportedToolNames.contains(tool)
                        ? searchStepApproved : true,
                    context: context,
                    bridge: bridge
                ) {
                case .output(let text):
                    return text
                case .failure(let reason):
                    throw IOSRecipeRunError.stepFailed(stepId: "", tool: tool, message: reason)
                case .needsApproval:
                    throw IOSRecipeRunError.stepFailed(
                        stepId: "", tool: tool,
                        message: "步骤需要批准但未通过审批前置检查。"
                    )
                case .outcomeUnknown(let outputText):
                    throw IOSRecipePrimitiveOutcomeUnknownError(outputText: outputText)
                }
            },
            ledger: runtime.ledger,
            runId: context.runId
        )
    }

    /// One step routed through the existing dispatcher (post-approval path).
    /// The gate was already checked by `advanceRecipeExecution`; this only
    /// executes and formats the output.
    func executeRecipePrimitiveStep(
        tool: String,
        argsJSON: String,
        isUserInitiated: Bool,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?
    ) async -> RecipePrimitiveStepResult {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "recipe-step-\(UUID().uuidString)",
            toolName: tool,
            input: argsJSON,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        switch IOSRecipePrimitiveCatalog.route(for: tool) {
        case .workspace:
            let output = await runtime.workspaceToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
            if case .needsUserAction(let reason) = output {
                return .needsApproval(reason: reason)
            }
            let text = ChatToolOutputFormatter.workspaceResultText(for: toolCall, output: output)
            // Slice A / §10.3.6：recipe step 是 stop-on-failure 语义，workspace
            // 的 ok:false 必须冒泡为 step 失败（否则路径/参数错误永远不产生
            // typed evidence，自进化诊断无从归因）。普通聊天工具路径不变——
            // 那里 ok:false 是给模型看的正常输出。
            if let failure = ChatToolOutputFormatter.workspaceFailureReason(inOutputJSON: text) {
                return .failure(failure)
            }
            return .output(text)
        case .search:
            switch runtime.searchToolPermission(isUserInitiated: isUserInitiated) {
            case .denied(let reason): return .failure(reason)
            case .needsApproval(let reason): return .needsApproval(reason: reason)
            case .allow: break
            }
            return recipePrimitiveResult(await runtime.dispatchSearchToolCall(
                toolCall,
                isUserInitiated: isUserInitiated
            ))
        case .memory:
            let policy = runtime.memoryToolWritePolicy(input: argsJSON, isUserInitiated: isUserInitiated)
            if case .needsUserAction(let reason) = policy {
                return .needsApproval(reason: reason)
            }
            return recipePrimitiveResult(runtime.dispatchMemoryToolCall(toolCall, writePolicy: policy))
        case .ish:
            let output = await runtime.ishToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
            switch output {
            case .needsUserAction(let reason):
                return .needsApproval(reason: reason)
            case .denied(let reason), .failed(let reason):
                return .failure(reason)
            default:
                return recipePrimitiveResult(
                    ChatToolOutputFormatter.ishHandoffResultText(for: toolCall, output: output)
                )
            }
        case .webMount:
            let output = await runtime.webMountToolExecutionOutput(
                toolCall,
                isUserInitiated: isUserInitiated,
                runId: context.runId,
                conversationId: context.conversationId
            )
            if case .needsUserAction(let reason) = output {
                return .needsApproval(reason: reason)
            }
            if output.isWebMountOutcomeUnknown {
                return .outcomeUnknown(ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output))
            }
            return recipePrimitiveResult(
                ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
            )
        case .sessionRead:
            return recipePrimitiveResult(await runtime.dispatchSessionReadToolCall(
                toolCall, conversationId: context.conversationId
            ))
        case .discovery:
            guard let bridge else {
                return .failure("\(tool) 当前不可用（缺少工具目录）。")
            }
            if tool == "tools_list" {
                return recipePrimitiveResult(bridge.executeToolsList())
            }
            // Jev Phase 1：Recipe discovery 与前台/后台共用语义发现服务。
            let result = await IOSJevToolDiscoveryService.execute(
                argumentsJson: argsJSON,
                selectedTaskText: context.baseMessages.reversed().first(where: { $0.role == MessageRole.user })?.toText() ?? "",
                bridge: bridge,
                identity: IOSJevToolDiscoveryService.RunIdentity(
                    runId: context.runId,
                    turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: context.runId)
                )
            )
            return recipePrimitiveResult(result)
        case .skill:
            let result = await runtime.skillMcpToolService.execute(
                toolName: tool,
                arguments: argsJSON,
                mcpEnabledOverride: runtime.isMcpNetworkAllowed()
            )
            return recipePrimitiveResult(result)
        case .advanced:
            if (tool == "exec" || tool == "wait"), !runtime.effectiveExecJavaScriptEnabled {
                return .failure("\(tool) 未开启。请先在设置中启用对应能力。")
            }
            return recipePrimitiveResult(await runtime.dispatchAdvancedToolCall(
                toolCall,
                providerSetting: context.providerSetting,
                params: context.params,
                runId: context.runId,
                conversationId: context.conversationId,
                nestedTools: nil,
                toolExposureBridge: bridge
            ))
        case .recipeImport, .unsupported:
            return .failure("工具「\(tool)」不支持作为 Recipe step。")
        }
    }

    private func recipePrimitiveResult(_ output: String) -> RecipePrimitiveStepResult {
        let part = UIMessagePart.Text(text: output, metadata: nil)
        if let reason = ChatToolOutputFormatter.failureReason(from: [part]) {
            return .failure(reason)
        }
        return .output(output)
    }

    /// Step-level approval gate, mirroring the TOP-LEVEL approval decisions
    /// (`executeWorkspaceToolCall` / `executeSearchToolCall` /
    /// `executeAdvancedToolCall` / the local executor's policy gates). The
    /// execution itself is never duplicated — only the "would this need a
    /// card" decision, so a recipe step cannot silently skip a gate.
    private func recipeStepGate(
        tool: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate {
        switch IOSRecipePrimitiveCatalog.route(for: tool) {
        case .workspace:
            return workspaceRecipeStepGate(toolName: tool)
        case .search:
            switch runtime.searchToolPermission() {
            case .denied(let reason): return .unsupported(reason: reason)
            case .needsApproval(let reason): return .approvalRequired(reason: reason)
            case .allow: return .proceed
            }
        case .memory:
            if case .needsUserAction(let reason) = runtime.memoryToolWritePolicy(input: argsJSON, isUserInitiated: false) {
                return .approvalRequired(reason: reason)
            }
            return .proceed
        case .ish:
            if runtime.isIshToolAutoApproved(
                toolName: tool,
                input: argsJSON,
                runId: context.runId,
                conversationId: context.conversationId
            ) {
                return .proceed
            }
            return .approvalRequired(reason: "终端执行需要显式批准。")
        case .webMount:
            return await webMountRecipeStepGate(
                toolName: tool,
                argsJSON: argsJSON,
                context: context
            )
        case .advanced:
            if IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(tool) {
                return .approvalRequired(reason: appleCapabilityApprovalReason(toolName: tool))
            }
            switch tool {
            case "mcp_call":
                guard runtime.effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。")
                }
                return .proceed
            case let name where ToolKt.isExpandedMcpToolName(name: name):
                guard runtime.effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。")
                }
                return .proceed
            case let name where IOSProviderConfigToolCatalog.highRiskToolNames.contains(name):
                guard runtime.effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(
                        reason: IOSProviderConfigToolCatalog.approvalReason(argumentsJSON: argsJSON)
                    )
                }
                return .proceed
            case let name where IOSThemePackToolCatalog.highRiskToolNames.contains(name):
                return .approvalRequired(
                    reason: "主题试穿会立刻换皮，需要你确认套用或还原。"
                )
            case "subagent_dispatch":
                return .proceed
            case "model_council_run":
                if runtime.requiresCouncilApproval {
                    return .approvalRequired(reason: "模型议会会发起多次模型请求，需要你确认。")
                }
                return .proceed
            case "exec", "wait":
                guard runtime.effectiveExecJavaScriptEnabled else {
                    return .unsupported(reason: "\(tool) 未开启。请先在设置中启用对应能力。")
                }
                return .proceed
            default:
                // 编排工具（spawn/list/interrupt/send/followup/wait_agent）：
                // 顶层路径无审批卡，步骤同样直接执行。
                return .proceed
            }
        case .skill:
            let mutating = IOSSkillToolCatalog.mutatingToolNames.contains(tool)
            if mutating, !runtime.effectiveGlobalAutoApproveEnabled,
               !runtime.effectiveHighRiskAutoApproveEnabled {
                return .approvalRequired(reason: "将写入本机 Skill 或 MCP 配置，需要你确认。")
            }
            return .proceed
        case .sessionRead, .discovery:
            return .proceed
        case .recipeImport:
            return .unsupported(reason: "recipe_import 需要单独的候选预览审批，不支持作为 Recipe step。")
        case .unsupported:
            return .unsupported(reason: "工具「\(tool)」不支持作为 Recipe step。")
        }
    }

    func appleCapabilityApprovalReason(toolName: String) -> String {
        if IOSAppleAgentToolCatalog.alarmToolNames.contains(toolName) {
            return IOSAppleAgentToolCatalog.mutatingToolNames.contains(toolName)
                ? IOSAlarmCopy.mutatingReason
                : IOSAlarmCopy.listReason
        }
        return IOSAppleAgentToolCatalog.mutatingToolNames.contains(toolName)
            ? "该操作会读取或修改你在 iPhone 上的私密 Apple 数据，需要你确认。"
            : "该操作会读取你在 iPhone 上的私密 Apple 数据，并交给当前 Agent 处理，需要你确认。"
    }

    /// Mirror of `IOSLocalToolExecutor.resolveWorkspace`'s gate: the policy
    /// check that decides whether the workspace call needs a card. The
    /// execution itself (when allowed) happens through the existing path.
    private func workspaceRecipeStepGate(toolName: String) -> RecipeStepGate {
        guard let localToolExecutor = runtime.localToolExecutor,
              let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else {
            return .proceed
        }
        guard let policy = IOSExecutionPolicyContext.snapshot?.policy(for: capability)
            ?? localToolExecutor.permissionPolicy(capabilityId: capability.id) else {
            return .proceed
        }
        if policy == .disabled {
            // Execution will fail with the disabled message; no card needed.
            return .proceed
        }
        if policy == .autoApprove || policy == .autoApproveHighRisk {
            return .proceed
        }
        if IOSWorkspaceToolCatalog.writeToolNames.contains(toolName) {
            if runtime.effectiveGlobalAutoApproveEnabled
                && (capability.risk != .high || runtime.effectiveHighRiskAutoApproveEnabled) {
                return .proceed
            }
            return .approvalRequired(reason: "Workspace 写入与删除需要显式批准。")
        }
        if policy == .askEveryTime || capability.gate.requiresFreshUserPresence {
            if runtime.effectiveGlobalAutoApproveEnabled
                && (capability.risk != .high || runtime.effectiveHighRiskAutoApproveEnabled) {
                return .proceed
            }
            return .approvalRequired(reason: "Workspace 读取需要显式批准。")
        }
        return .proceed
    }

    /// Reuse the same WebMount gate as top-level execution so recipe steps do
    /// not drift from the executor's policy or explicit-user-action rules.
    private func webMountRecipeStepGate(
        toolName: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate {
        guard let localToolExecutor = runtime.localToolExecutor else {
            return .unsupported(reason: "WebMount executor is unavailable.")
        }
        switch localToolExecutor.webMountGateDecision(
            toolName: toolName,
            isUserInitiated: false,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        ) {
        case .allow:
            return await webMountRecipeActionPreflight(
                toolName: toolName,
                argsJSON: argsJSON,
                context: context
            ) ?? .proceed
        case .deny(let reason):
            return .unsupported(reason: reason)
        case .needsUserAction(let reason):
            if let preflight = await webMountRecipeActionPreflight(
                toolName: toolName,
                argsJSON: argsJSON,
                context: context
            ), case .approvalRequired = preflight {
                return preflight
            }
            return .approvalRequired(reason: reason)
        }
    }

    private func webMountRecipeActionPreflight(
        toolName: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate? {
        guard let localToolExecutor = runtime.localToolExecutor,
              let output = await localToolExecutor.webMountActionPreflight(
                  toolName: toolName,
                  input: argsJSON,
                  runId: context.runId,
                  conversationId: context.conversationId?.toHexDashString() ?? "",
                  executionPolicy: IOSExecutionPolicyContext.snapshot
              ) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unsupported(reason: "WebMount action preflight returned invalid output.")
        }

        let reason = (object["reason"] as? String)?.nilIfBlank
            ?? (object["consequence"] as? String)?.nilIfBlank
            ?? (object["error"] as? String)?.nilIfBlank
            ?? "WebMount action preflight failed."
        if object["requires_human"] as? Bool == true {
            return .approvalRequired(reason: "human_handoff: \(reason)")
        }
        if object["needs_user_action"] as? Bool == true {
            return .approvalRequired(reason: reason)
        }
        if object["ok"] as? Bool == false {
            return .unsupported(reason: reason)
        }
        return .proceed
    }

    /// Recipe-level ledger record (§15 Phase 0 attribution): one Finished row
    /// per recipe call under `recipe-level-<executionId>` carrying
    /// artifactId/artifactVersion/outcomeKind, so evidence projection can
    /// attribute the whole run to the exact recipe version. The per-step
    /// Started/Finished pairs come from `IOSRecipeRunner.runStep` under
    /// `recipe-<executionId>-<stepId>` (the distinct prefix keeps the two
    /// namespaces unambiguous in the ledger).
    private func recordRecipeLevelFinished(
        recipeName: String,
        recipeVersion: String,
        executionId: String,
        outcome: String,
        outcomeKind: String,
        errorCode: String?,
        runId: String
    ) async {
        guard let ledger = runtime.ledger else { return }
        await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "recipe-level-\(executionId)",
            outcome: outcome,
            artifactId: Self.dynamicArtifactId(recipeName),
            artifactVersion: recipeVersion,
            outcomeKind: outcomeKind,
            errorCode: errorCode,
            sourceRef: executionId
        )
    }

    /// Finished-only trace for a step that failed before it ever Started
    /// (argument resolution failure), matching the runner's pre-refactor
    /// record shape so old and new ledgers read identically.
    private func recordRecipeStepFinishedOnly(
        state: IOSRecipeExecutionState,
        step: IOSRecipePlanStep,
        errorCode: String,
        runId: String
    ) async {
        guard let ledger = runtime.ledger else { return }
        await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "recipe-\(state.executionId)-\(step.id)",
            outcome: "failed",
            artifactId: Self.dynamicArtifactId(state.recipeName),
            artifactVersion: state.recipeVersion,
            outcomeKind: "error",
            errorCode: errorCode,
            sourceRef: state.executionId
        )
    }

    /// Fills the recipe tool call's output and clears the paused state
    /// (checkpoint + in-memory) — the terminal resolution of the call.
    private func finishRecipeCall(
        state: IOSRecipeExecutionState,
        context: ChatPendingToolApproval,
        outputText: String
    ) -> [UIMessage] {
        preparedExecutions.removeValue(forKey: state.toolCallId)
        checkpointStore.remove(toolCallId: state.toolCallId)
        if state.candidateTest == nil { recordRecipePluginHealth(output: outputText, state: state) }
        return runtime.messagesByFinishingToolCall(
            context.toolCall,
            outputText: state.candidateTest?.resultJSON(outputText) ?? outputText,
            in: context.baseMessages
        )
    }

    private func recordRecipePluginHealth(
        output: String,
        state: IOSRecipeExecutionState
    ) {
        guard let pluginId = state.pluginId,
              let packageHash = state.pluginPackageHash,
              let object = ChatToolCallParsing.jsonObject(output) else { return }
        if object["ok"] as? Bool == true {
            _ = runtime.pluginHealthStore.recordSuccess(pluginId: pluginId, packageHash: packageHash)
            return
        }
        let status = object["status"] as? String ?? ""
        let errorCode = object["error_code"] as? String ?? ""
        let reason = (object["reason"] as? String) ?? (object["error"] as? String) ?? "插件运行失败。"
        let kind: IOSPluginDiagnosticKind?
        if status == "timeout" || status == "timed_out" || errorCode == "step_timeout" || reason.localizedCaseInsensitiveContains("超时") {
            kind = .timeout
        } else if errorCode == "output_resolution" || reason.contains("输出解析") {
            kind = .schema
        } else {
            kind = nil
        }
        guard let kind else { return }
        let transition = runtime.pluginHealthStore.recordFailure(
            pluginId: pluginId,
            packageHash: packageHash,
            toolId: state.recipeName,
            kind: kind,
            detail: reason
        )
        if transition.didQuarantine {
            Task { [recipeRegistry = runtime.recipeRegistry] in _ = await recipeRegistry.refresh() }
        }
    }

    private static func dynamicArtifactId(_ recipeName: String) -> String {
        recipeName.hasPrefix("plugin__") ? recipeName : "recipe__\(recipeName)"
    }

    func recipeResultJSON(
        outputs: [String: IOSRecipeJSONValue],
        completedSteps: [String]
    ) -> String {
        let outputsObject: Any
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(outputs)
            outputsObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            outputsObject = [:]
        }
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": "completed",
            "steps": completedSteps,
            "outputs": outputsObject,
        ])
    }

    func recipeArgumentsPreview(_ argsJSON: String) -> String {
        guard argsJSON.count > 360 else { return argsJSON }
        return String(argsJSON.prefix(360)) + "…"
    }

    private static func recipeErrorCode(for error: IOSRecipeRunError) -> String {
        switch error {
        case .planInvalid: "plan_invalid"
        case .inputInvalid: "input_invalid"
        case .argumentBinding: "argument_binding"
        case .stepFailed: "step_failed"
        case .stepTimeout: "step_timeout"
        case .outputResolution: "output_resolution"
        }
    }

}
