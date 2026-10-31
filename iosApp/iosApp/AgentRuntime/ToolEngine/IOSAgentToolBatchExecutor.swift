import Foundation
@preconcurrency import Shared

struct IOSAgentToolBatchExecutor {
    private static let toolTerminalLedgerFailureMessage = "tool result ledger write failed"
    private let executors: [String: any IOSToolExecutor]
    private let ledger: IOSAgentRunLedgering?
    private let ledgerRunId: String?

    init(executors: [String: any IOSToolExecutor], ledger: IOSAgentRunLedgering?, ledgerRunId: String?) {
        self.executors = executors
        self.ledger = ledger
        self.ledgerRunId = ledgerRunId
    }

    func pendingToolCalls(in message: UIMessage?) -> [UIMessagePart.Tool] {
        guard let message, message.role == MessageRole.assistant else { return [] }
        return message.parts.compactMap { $0 as? UIMessagePart.Tool }.filter { $0.output.isEmpty }
    }

    /// toolCallKeys of every tool call in the transcript whose output is already
    /// filled. Used to suppress re-execution of a call the model echoes after it
    /// was completed earlier (background pre-execution or a buggy provider echo).
    func completedToolKeys(in messages: [UIMessage]) -> Set<String> {
        var keys = Set<String>()
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts where !tool.output.isEmpty {
                keys.insert(Self.toolCallKey(tool))
            }
        }
        return keys
    }

    /// Executes any empty-output tool calls that are ALREADY present in the
    /// input messages (across all assistant turns, not just the last), filling
    /// their results in place. See the call site in `run` for rationale.
    ///
    /// Routes through the same `executeBatch` + `applyToolOutputs` path as the
    /// main loop, so approval/denial/failure outcomes are handled identically.
    /// Returns the messages unchanged when there is nothing pre-existing to run.
    struct PreExistingExecutionResult {
        let messages: [UIMessage]
        let pendingApproval: IOSPendingToolApproval?
        let guardStopped: Bool
        let wasCancelled: Bool
        let durabilityFailureMessage: String?
        let toolOutcomeUnknown: IOSToolOutcomeUnknownSignal?
    }

    func executePreExistingPendingTools(
        in messages: [UIMessage],
        loopGuard: inout IOSToolLoopGuard,
        onToolExecutionStarted: (@MainActor @Sendable (String, String) async -> Void)?
    ) async -> PreExistingExecutionResult {
        let preExisting = messages.flatMap { message -> [UIMessagePart.Tool] in
            guard message.role == MessageRole.assistant else { return [] }
            return message.parts.compactMap { $0 as? UIMessagePart.Tool }.filter { $0.output.isEmpty }
        }
        // Only pre-execute tools this engine actually knows how to run. Scoped
        // engines (e.g. a subagent whose executor map is restricted to a read-only
        // allow-list) must NOT pre-fill a parent transcript's tools they were never
        // meant to handle — that would inject `[engine] no executor registered`
        // failure text into the history. Such tools are left untouched; they will
        // either be re-issued by the model (and then hit the executor map) or
        // simply ignored.
        let executable = preExisting.filter { executors[$0.toolName] != nil }
        guard !executable.isEmpty else {
            return PreExistingExecutionResult(
                messages: messages,
                pendingApproval: nil,
                guardStopped: false,
                wasCancelled: false,
                durabilityFailureMessage: nil,
                toolOutcomeUnknown: nil
            )
        }
        let batchResult = await executeBatch(
            executable,
            isUserInitiated: false,
            loopGuard: &loopGuard,
            onToolExecutionStarted: onToolExecutionStarted
        )
        // 前台审批恢复会以新 Engine 实例继续同一批剩余调用；这里必须把第二个
        // needsApproval 继续向 Adapter 冒泡。后台配置关闭 honorApprovalPause，
        // 保持其既有“不可发审批卡”语义。
        return PreExistingExecutionResult(
            messages: applyToolOutputs(batchResult.outputs, to: messages),
            pendingApproval: batchResult.pendingApproval,
            guardStopped: batchResult.guardStopped,
            wasCancelled: batchResult.wasCancelled,
            durabilityFailureMessage: batchResult.durabilityFailureMessage,
            toolOutcomeUnknown: batchResult.toolOutcomeUnknown
        )
    }

    struct BatchExecutionResult {
        /// One output per pending tool, keyed by toolCallKey (same definition
        /// as ChatViewModel.toolCallKey) so they can be applied in place.
        let outputs: [(tool: UIMessagePart.Tool, parts: [UIMessagePart])]
        let pendingApproval: IOSPendingToolApproval?
        /// I-5: set when `loopGuard` returned `.stop` for one of this batch's
        /// tools. The stopped tool's output already carries the stop
        /// explanation; remaining tools in the batch are left unfilled (same
        /// "leave the rest for the caller to decide" shape as `firstApproval`).
        let guardStopped: Bool
        /// The task was cancelled after durable setup but before the next
        /// executor could begin, so no further tool/model work should start.
        let wasCancelled: Bool
        /// The executor returned, but its durable terminal transaction could
        /// not be committed. The current tool output stays unfilled and the
        /// caller must keep the run recoverable instead of requesting another
        /// provider round or declaring completion.
        let durabilityFailureMessage: String?
        let toolOutcomeUnknown: IOSToolOutcomeUnknownSignal?
    }

    func executeBatch(
        _ tools: [UIMessagePart.Tool],
        isUserInitiated: Bool,
        loopGuard: inout IOSToolLoopGuard,
        resolveUnexposedToolCall: (@Sendable (UIMessagePart.Tool) async -> [UIMessagePart]?)? = nil,
        onToolExecutionStarted: (@MainActor @Sendable (String, String) async -> Void)?
    ) async -> BatchExecutionResult {
        var outputs: [(UIMessagePart.Tool, [UIMessagePart])] = []
        var firstApproval: IOSPendingToolApproval?
        var guardStopped = false
        var requiresReplan = false

        for tool in tools {
            if requiresReplan {
                // These calls were planned before the human changed the state.
                // Fill them before any exposure, guard, or ledger hook can run.
                outputs.append((tool, [UIMessagePart.Text(
                    text: toolReplanRequiredJSON(toolName: tool.toolName),
                    metadata: nil
                )]))
                continue
            }
            if firstApproval != nil {
                // Approval pauses this batch. The caller owns whether and when
                // the remaining calls resume after the user decides.
                continue
            }
            if guardStopped {
                // A guard stop is terminal, unlike an approval pause. Resolve
                // every remaining call explicitly so no later run can mistake
                // it for pending work and execute it out of context.
                outputs.append((tool, [UIMessagePart.Text(
                    text: toolLoopGuardSkippedJSON(toolName: tool.toolName),
                    metadata: nil
                )]))
                continue
            }
            // P0-2 hook: 未暴露工具的引导软失败(CG-C P0-a Fix B 语义)——在
            // I-2/I-5/I-1 全部闸门之前拦截(CG-C 的软失败同样发生在任何执行
            // 闸门之前):不写 Started(从未执行),只写 Finished(failed) 留痕,
            // 填引导输出,批内继续。nil = 不拦截(引擎现状:未注册名字由下游
            // no-executor 失败化)。
            if let resolveUnexposedToolCall,
               let guidedParts = await resolveUnexposedToolCall(tool) {
                if let ledger, let ledgerRunId {
                    await ledger.recordToolCallFinished(
                        runId: ledgerRunId,
                        toolCallId: tool.toolCallId,
                        outcome: "failed"
                    )
                }
                outputs.append((tool, guidedParts))
                continue
            }

            // I-2 fail-closed: refuse to dispatch a tool call whose `input` cannot
            // be parsed as a JSON object, *before* consulting the executor map. A
            // gateway that double-writes a call, truncates one mid-argument, or a
            // model that emits bare non-JSON text would otherwise reach the
            // executor with silently wrong (not absent) arguments — see
            // `parseInputStrict()`. Refusing costs one visible retry via the
            // model's next turn; executing anyway costs an invisible wrong answer.
            if let invalid = tool.parseInputStrict() as? ToolInputParse.Invalid {
                outputs.append((tool, [UIMessagePart.Text(
                    text: toolArgumentsInvalidJSON(
                        message: IOSSecretArgumentRedaction.carriesCredential(tool.toolName) ? "敏感工具参数不是有效的 JSON。" : invalid.message,
                        rawPrefix: IOSSecretArgumentRedaction.carriesCredential(tool.toolName) ? "[redacted]" : invalid.rawPrefix
                    ),
                    metadata: nil
                )]))
                continue
            }

            // I-5 打转守护:在 I-2 parse 闸门之后、I-1 账本段之前判断——参数解析
            // 失败的调用从未真正执行,不该计入重复签名;stop 分支不执行工具,
            // 也不进 I-1 账本(不留 Started 记录),直接写停止说明并终止整批。
            let loopGuardVerdict = loopGuard.check(toolName: tool.toolName, input: tool.input)
            if case .stop(let reason) = loopGuardVerdict {
                outputs.append((tool, [UIMessagePart.Text(
                    text: toolLoopGuardStoppedJSON(toolName: tool.toolName, reason: reason),
                    metadata: nil
                )]))
                guardStopped = true
                continue
            }

            // Durable tool transaction: PREPARED claims this run/toolCallId
            // before STARTED crosses the execution boundary. A competing
            // foreground/background writer either replays the stored terminal
            // result or gets a resolved failure; it never reaches the executor.
            if let ledger, let ledgerRunId {
                #if os(iOS)
                let effectClass = IOSToolEffectClassMapping.forToolName(
                    tool.toolName, input: tool.input
                )
                #else
                let effectClass = DesktopToolRegistry.effectClass(for: tool.toolName, arguments: tool.input)
                #endif
                let argsDigest = chatInputDigest(for: tool.input)
                switch await ledger.recordToolCallPrepared(
                    runId: ledgerRunId,
                    toolCallId: tool.toolCallId,
                    toolName: tool.toolName,
                    argsDigest: argsDigest,
                    effectClass: effectClass
                ) {
                case .ready:
                    break
                case .replay(let resultPayload, let replayRequiresReplan):
                    requiresReplan = replayRequiresReplan
                    if let replayed = Self.decodeToolOutput(resultPayload) {
                        outputs.append((tool, replayed))
                    } else {
                        outputs.append((tool, [UIMessagePart.Text(
                            text: "{\"ok\":false,\"error\":\"tool_result_replay_failed\",\"message\":\"stored tool result could not be decoded\"}",
                            metadata: nil
                        )]))
                    }
                    continue
                case .blocked(let reason):
                    outputs.append((tool, [UIMessagePart.Text(
                        text: "{\"ok\":false,\"error\":\"tool_transaction_blocked\",\"message\":\"\(sanitized(reason))\"}",
                        metadata: nil
                    )]))
                    continue
                }
                let didRecordStart = await ledger.recordToolCallStarted(
                    runId: ledgerRunId,
                    toolCallId: tool.toolCallId,
                    toolName: tool.toolName,
                    argsDigest: argsDigest,
                    effectClass: effectClass
                )
                guard didRecordStart else {
                    outputs.append((tool, [UIMessagePart.Text(
                        text: "{\"ok\":false,\"error\":\"tool_ledger_write_failed\",\"message\":\"could not durably record tool call start\"}",
                        metadata: nil
                    )]))
                    continue
                }
            }

            let executor = executors[tool.toolName]
            let result: IOSAgentToolOutcome
            let cancelledBeforeExecution: Bool
            if Task.isCancelled {
                cancelledBeforeExecution = true
            } else {
                if executor != nil {
                    await onToolExecutionStarted?(tool.toolName, tool.input)
                }
                cancelledBeforeExecution = Task.isCancelled
            }
            if cancelledBeforeExecution {
                var durabilityFailureMessage: String?
                if let ledger, let ledgerRunId {
                    let didRecordTerminal = await ledger.recordToolCallFinished(
                        runId: ledgerRunId,
                        toolCallId: tool.toolCallId,
                        outcome: "cancelled_before_execution"
                    )
                    if !didRecordTerminal {
                        durabilityFailureMessage = Self.toolTerminalLedgerFailureMessage
                    }
                }
                return BatchExecutionResult(
                    outputs: outputs,
                    pendingApproval: nil,
                    guardStopped: false,
                    wasCancelled: durabilityFailureMessage == nil,
                    durabilityFailureMessage: durabilityFailureMessage,
                    toolOutcomeUnknown: nil
                )
            }
            if let executor {
                result = await executor.execute(
                    tool: tool,
                    isUserInitiated: isUserInitiated
                )
            } else {
                result = .failed("[engine] no executor registered for tool `\(tool.toolName)`")
            }

            var resultParts: [UIMessagePart]?
            let outcome: String
            switch result {
            case .filled(let text):
                outcome = "completed"
                resultParts = [UIMessagePart.Text(text: text, metadata: nil)]
            case .filledParts(let parts):
                outcome = "completed"
                resultParts = parts
            case .replanRequired(let parts):
                outcome = "completed_requires_replan"
                resultParts = parts
                requiresReplan = true
            case .needsApproval(let reason):
                outcome = "paused_for_approval"
                firstApproval = IOSPendingToolApproval(
                    toolCallId: tool.toolCallId,
                    toolName: tool.toolName,
                    arguments: tool.input,
                    reason: reason
                )
            case .denied(let reason):
                outcome = "denied"
                resultParts = [UIMessagePart.Text(text: IOSToolFailurePayload.json(
                    toolName: tool.toolName, reason: reason, denied: true, status: "denied"
                ), metadata: nil)]
            case .failed(let reason):
                outcome = "failed"
                resultParts = [UIMessagePart.Text(text: IOSToolFailurePayload.json(
                    toolName: tool.toolName, reason: reason, status: "failed"
                ), metadata: nil)]
            case .durabilityFailure(let reason):
                return BatchExecutionResult(
                    outputs: outputs,
                    pendingApproval: nil,
                    guardStopped: false,
                    wasCancelled: false,
                    durabilityFailureMessage: reason,
                    toolOutcomeUnknown: nil
                )
            case .outcomeUnknown(let parts):
                if let ledger, let ledgerRunId {
                    guard await ledger.recordToolCallRecoveryTransition(
                        runId: ledgerRunId,
                        toolCallId: tool.toolCallId,
                        expected: .started,
                        to: .outcomeUnknown,
                        outcome: "executor_reported_unknown_after_action"
                    ) else {
                        return BatchExecutionResult(
                            outputs: outputs,
                            pendingApproval: nil,
                            guardStopped: false,
                            wasCancelled: false,
                            durabilityFailureMessage: Self.toolTerminalLedgerFailureMessage,
                            toolOutcomeUnknown: nil
                        )
                    }
                }
                outputs.append((tool, parts))
                return BatchExecutionResult(
                    outputs: outputs,
                    pendingApproval: nil,
                    guardStopped: false,
                    wasCancelled: false,
                    durabilityFailureMessage: nil,
                    toolOutcomeUnknown: IOSToolOutcomeUnknownSignal(
                        toolCallId: tool.toolCallId,
                        toolName: tool.toolName
                    )
                )
            }
            if let ledger, let ledgerRunId {
                let didRecordTerminal: Bool
                if let resultParts {
                    didRecordTerminal = await ledger.recordToolCallTerminal(
                        runId: ledgerRunId,
                        toolCallId: tool.toolCallId,
                        outcome: outcome,
                        resultPayload: Self.encodeToolOutput(resultParts)
                    )
                } else {
                    didRecordTerminal = await ledger.recordToolCallFinished(
                        runId: ledgerRunId,
                        toolCallId: tool.toolCallId,
                        outcome: outcome
                    )
                }
                guard didRecordTerminal else {
                    return BatchExecutionResult(
                        outputs: outputs,
                        pendingApproval: nil,
                        guardStopped: false,
                        wasCancelled: false,
                        durabilityFailureMessage: Self.toolTerminalLedgerFailureMessage,
                        toolOutcomeUnknown: nil
                    )
                }
            }
            if var parts = resultParts {
                // I-5 第 2 次相同签名:工具照常执行,把提醒追加为一个额外的
                // Text part(append,不替换),让模型下一轮看到自己在重复。
                if case .proceedAndRemind(let reminder) = loopGuardVerdict {
                    parts.append(UIMessagePart.Text(text: reminder, metadata: nil))
                }
                outputs.append((tool, parts))
            }
        }

        return BatchExecutionResult(
            outputs: outputs,
            pendingApproval: firstApproval,
            guardStopped: guardStopped,
            wasCancelled: requiresReplan && Task.isCancelled,
            durabilityFailureMessage: nil,
            toolOutcomeUnknown: nil
        )
    }

    /// Rebuilds the message list with tool outputs filled in place. Replaces
    /// ALL matching pending tool parts (by toolCallKey), generalizing
    /// `ChatViewModel.messagesByFinishingToolCall` which only fills the first.
    func applyToolOutputs(
        _ outputs: [(tool: UIMessagePart.Tool, parts: [UIMessagePart])],
        to messages: [UIMessage]
    ) -> [UIMessage] {
        guard !outputs.isEmpty else { return messages }
        var lookup: [String: [UIMessagePart]] = [:]
        for entry in outputs {
            lookup[Self.toolCallKey(entry.tool)] = entry.parts
        }
        return messages.map { message in
            guard message.role == MessageRole.assistant else { return message }
            var didChange = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let toolPart = part as? UIMessagePart.Tool,
                      toolPart.output.isEmpty,
                      let newOutput = lookup[Self.toolCallKey(toolPart)] else {
                    return part
                }
                didChange = true
                // 两个脱敏器都编进 Novel target：IOSSecretArgumentRedaction 不依赖主
                // App 类型，IOSProviderConfigToolCatalog 已在 Novel 源列表中。
                var input = toolPart.input
                if IOSSecretArgumentRedaction.carriesCredential(toolPart.toolName) {
                    input = IOSSecretArgumentRedaction.redactedArgumentsJSON(input)
                }
                #if os(iOS)
                if IOSProviderConfigToolCatalog.toolNames.contains(toolPart.toolName) {
                    input = IOSProviderConfigToolCatalog.redactedArgumentsJSON(input)
                }
                #endif
                return PromptTranscript.shared.doCopyTool(tool: toolPart, input: input, output: newOutput)
            }
            guard didChange else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    private func sanitized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func encodeToolOutput(_ parts: [UIMessagePart]) -> String? {
        IosToolOutputJsonBridge.shared.encode(parts: parts)
    }

    private static func decodeToolOutput(_ payload: String) -> [UIMessagePart]? {
        try? IosToolOutputJsonBridge.shared.decode(json: payload)
    }

    /// Structured stop notice for a tool call `IOSToolLoopGuard` refused to run
    /// a 3rd time with identical arguments (I-5). Same inline-JSON style as the
    /// other structured errors in this file — the call site does not execute
    /// the tool, so this is the only trace of "why" that ends up in the
    /// transcript.
    private func toolLoopGuardStoppedJSON(toolName: String, reason: String) -> String {
        "{\"ok\":false,\"error\":\"tool_loop_guard_stopped\",\"tool\":\"\(sanitized(toolName))\",\"reason\":\"\(sanitized(reason))\"}"
    }

    private func toolLoopGuardSkippedJSON(toolName: String) -> String {
        "{\"ok\":false,\"error\":\"tool_not_executed\",\"tool\":\"\(sanitized(toolName))\",\"reason\":\"batch stopped by repeated tool-call guard\"}"
    }

    private func toolReplanRequiredJSON(toolName: String) -> String {
        "{\"ok\":false,\"outcome\":\"not_sent\",\"reason_code\":\"replan_required\",\"tool\":\"\(sanitized(toolName))\",\"message\":\"The previous tool requires replanning; use its latest result before sending another action.\"}"
    }

    /// Structured error for a tool call whose `input` failed `parseInputStrict()`
    /// (I-2, fail-closed). Same inline-JSON style as the `.failed`/`.denied`
    /// cases above (`{"error": ...}`), extended with the `message` / `raw_prefix`
    /// fields the model needs to self-correct.
    private func toolArgumentsInvalidJSON(message: String, rawPrefix: String) -> String {
        "{\"ok\":false,\"error\":\"tool_arguments_invalid\",\"message\":\"\(sanitized(message))\",\"raw_prefix\":\"\(sanitized(rawPrefix))\"}"
    }

    /// Stable key matching `ChatViewModel.toolCallKey`: toolCallId when present,
    /// else "name:input".
    static func toolCallKey(_ toolCall: UIMessagePart.Tool) -> String {
        let id = toolCall.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        return "\(toolCall.toolName):\(toolCall.input)"
    }

}
