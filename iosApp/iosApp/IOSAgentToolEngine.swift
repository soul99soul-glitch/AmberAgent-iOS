import Foundation
@preconcurrency import Shared

/// Runs one cancellable model/tool loop at a time. The run owns its transcript,
/// tool-loop guard and current executor registry; provider steps and batches
/// receive only the state needed for that round.
public final class IOSAgentToolEngine: @unchecked Sendable {

    public struct Configuration: Sendable {
        public let maxSteps: Int
        /// When true, tools returning `.needsApproval` pause the loop and
        /// surface `pendingApproval`. When false, an approval request is
        /// treated as a denial (engine does not block).
        public let honorApprovalPause: Bool

        public init(maxSteps: Int = 8, honorApprovalPause: Bool = true) {
            self.maxSteps = maxSteps
            self.honorApprovalPause = honorApprovalPause
        }
    }

    private let providerStep: IOSAgentProviderStep
    /// Executor table. Frozen by default (SubAgent/Novel paths). M2: when the
    /// run carries `toolExposureBridge` + `executorRebuilder` (chat background
    /// only), the table is rebuilt from the CURRENT round's effective params
    /// after every executed batch — a tool_search hit from this round gets an
    /// executor for the next round, so exposed tools are never "declared but
    /// not executable".
    private var executors: [String: any IOSToolExecutor]
    /// M2: rebuilds `executors` from a params snapshot (same registration entry
    /// point the caller used at init — see the background coordinator). Nil
    /// keeps the frozen-table behavior for every existing caller.
    private let executorRebuilder: ((TextGenerationParams) -> [String: any IOSToolExecutor])?
    private let configuration: Configuration
    private var batchExecutor: IOSAgentToolBatchExecutor {
        IOSAgentToolBatchExecutor(executors: executors, ledger: ledger, ledgerRunId: ledgerRunId)
    }
    // W1 durable ledger (I-1), optional and off by default so every existing
    // caller/test keeps building an engine with zero ledger traffic. Only
    // `IOSChatBackgroundGenerationCoordinator` passes one, reusing the SAME
    // runId the foreground run already started under — a background-continued
    // tool execution should account itself against that run, not a new one.
    // `SubAgentRunner` and the (currently unused) novel-discussion executor set
    // deliberately do NOT: their inner loop has no surfaced "run" a user can
    // recover — a crash there is invisible to the user, so the durable writes
    // would buy nothing. See docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md §W1.
    private let ledger: IOSAgentRunLedgering?
    private let ledgerRunId: String?
    private let phoneAutomaticReasoning: Bool
    private let phoneSessionIsActive: (@MainActor @Sendable (String) -> Bool)?

    public init(
        provider: any IOSAgentTextProvider,
        executors: [String: any IOSToolExecutor],
        configuration: Configuration = .init(),
        ledger: IOSAgentRunLedgering? = nil,
        ledgerRunId: String? = nil,
        phoneAutomaticReasoning: Bool = false,
        phoneSessionIsActive: (@MainActor @Sendable (String) -> Bool)? = nil,
        executorRebuilder: ((TextGenerationParams) -> [String: any IOSToolExecutor])? = nil
    ) {
        self.providerStep = IOSAgentProviderStep(provider: provider)
        self.executors = executors
        self.configuration = configuration
        self.ledger = ledger
        self.ledgerRunId = ledgerRunId
        self.phoneAutomaticReasoning = phoneAutomaticReasoning
        self.phoneSessionIsActive = phoneSessionIsActive
        self.executorRebuilder = executorRebuilder
    }

    private func phoneRequestParams(
        _ params: TextGenerationParams, providerSetting: ProviderSetting
    ) async -> TextGenerationParams {
        guard phoneAutomaticReasoning, let runId = ledgerRunId else { return params }
        let active = await MainActor.run {
            self.phoneSessionIsActive?(runId) ?? false
        }
        return IOSPhoneAutomationRequestPolicy.requestParams(
            params, provider: providerSetting,
            automaticReasoning: phoneAutomaticReasoning, activePhoneSession: active
        )
    }

    /// B2 前台内核投影:按节拍推送在途 assistant 的累加器快照。快照只在
    /// hook 非 nil(前台 kernel run)时生成——后台/子代理/小说流保持零快照
    /// 开销;48ms 与 CGC 的 streamSnapshotFlushDelayNanos 同一发布节拍,
    /// 快照成本与前台现状同阶(不是逐 chunk)。
    private static func uniqueMailboxMessages(
        _ messages: [UIMessage],
        excluding existing: [UIMessage]
    ) -> [UIMessage] {
        var seen = Set(existing.map { $0.id.toHexDashString().lowercased() })
        return messages.filter { message in
            seen.insert(message.id.toHexDashString().lowercased()).inserted
        }
    }

    /// `wait_agent` uses a strict JSON control marker for the foreground root
    /// only. Keep this recognition local to the engine: ordinary background
    /// wait results (timeout/activity/interruption) remain normal tool output
    /// and continue through the provider loop.
    private static func isForegroundYield(
        tool: UIMessagePart.Tool,
        parts: [UIMessagePart]
    ) -> Bool {
        guard tool.toolName == "wait_agent" else { return false }
        return parts.contains { part in
            guard let text = (part as? UIMessagePart.Text)?.text,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return object["ok"] as? Bool == true
                && object["tool"] as? String == "wait_agent"
                && object["yielded"] as? Bool == true
        }
    }

    /// Runs the loop to completion (or until approval is required / the step
    /// limit is hit). Pure function over `messages`: returns the new list,
    /// never mutates the caller's array.
    ///
    /// - Parameter toolExposureBridge: P0-a Fix C. When non-nil, each executed
    ///   batch is followed by `params.replacingTools(bridge.visibleTools())`
    ///   before the NEXT model step — a `tool_search` hit expanded inside one
    ///   round becomes declared on the next. Default nil keeps every existing
    ///   caller (SubAgent, Novel) on the frozen-params behavior.
    /// - Parameter mailboxDrain: P1-d. When non-nil, after each executed batch
    ///   (same point as the toolExposureBridge refresh, before the next
    ///   `streamStep`) or before a no-tool final return, the engine calls this
    ///   closure and appends the returned messages (rendered mailbox envelopes)
    ///   to the working list for the next round's upload; persisting the drained
    ///   envelopes into the conversation is the closure's job (background runs
    ///   have no UI, so fold = persist + working copy only). No input parameter:
    ///   KMP `UIMessage` is
    ///   non-Sendable, so the closure only ever RETURNS messages (wrapped in an
    ///   @unchecked Sendable box, same precedent as
    ///   `IOSChatBackgroundRetryMessages`) and never receives them. Default nil
    ///   keeps every existing caller (SubAgent, Novel) behavior unchanged.
    /// - Parameter refreshToolExposure: Runs after an executed batch and before
    ///   the next round reads `visibleTools()`. Chat uses this to publish
    ///   Recipe lifecycle changes into the existing run-scoped bridge.
    /// - Parameter citationTracker: P2-c. When non-nil, every streamed chunk in
    ///   every step is stripped of `<amber-mem-cite>` markers before
    ///   accumulation (see `streamStep`), and the run-terminal `finish()` flush
    ///   merges any unclosed-tag remainder into the final messages — one
    ///   per-run tracker, so the caller reads `citationIds` after `run`
    ///   returns. Default nil keeps every existing caller (SubAgent, Novel)
    ///   behavior byte-identical.
    public func run(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        citationTracker: IOSMemoryCitationTracker? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        refreshToolExposure: (@MainActor @Sendable () async -> Void)? = nil,
        mailboxDrain: (@Sendable () async -> IOSMailboxDrainResult)? = nil,
        drainSteer: (@Sendable () async -> [UIMessage])? = nil,
        prepareRequestMessages: (@Sendable ([UIMessage]) async throws -> [UIMessage])? = nil,
        sortPendingToolCalls: (@Sendable ([UIMessagePart.Tool]) -> [UIMessagePart.Tool])? = nil,
        preemptToolBatch: (@Sendable ([UIMessagePart.Tool]) async -> String?)? = nil,
        resolveUnexposedToolCall: (@Sendable (UIMessagePart.Tool) async -> [UIMessagePart]?)? = nil,
        onAssistantTurnStarted: (@MainActor @Sendable () async -> Void)? = nil,
        onAssistantTurnCompleted: (@Sendable ([UIMessage]) async -> Bool)? = nil,
        onToolExecutionStarted: (@MainActor @Sendable (String, String) async -> Void)? = nil,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)? = nil,
        onAssistantText: (@Sendable (String) -> Void)? = nil,
        onAssistantReasoning: (@Sendable (String) -> Void)? = nil,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)? = nil,
        onMessagesUpdated: (@Sendable ([UIMessage]) -> Void)? = nil
    ) async -> IOSAgentToolEngineResult {
        let result = await runInternal(
            providerSetting: providerSetting,
            messages: messages,
            params: params,
            citationTracker: citationTracker,
            toolExposureBridge: toolExposureBridge,
            refreshToolExposure: refreshToolExposure,
            mailboxDrain: mailboxDrain,
            drainSteer: drainSteer,
            prepareRequestMessages: prepareRequestMessages,
            sortPendingToolCalls: sortPendingToolCalls,
            preemptToolBatch: preemptToolBatch,
            resolveUnexposedToolCall: resolveUnexposedToolCall,
            onAssistantTurnStarted: onAssistantTurnStarted,
            onAssistantTurnCompleted: onAssistantTurnCompleted,
            onToolExecutionStarted: onToolExecutionStarted,
            onAssistantStage: onAssistantStage,
            onAssistantText: onAssistantText,
            onAssistantReasoning: onAssistantReasoning,
            onAssistantMessageSnapshot: onAssistantMessageSnapshot,
            onMessagesUpdated: onMessagesUpdated
        )
        return Self.finishingCitation(result, tracker: citationTracker)
    }

    private func providerFailureResult(
        _ error: Error,
        working: [UIMessage],
        steps: Int,
        onMessagesUpdated: (@Sendable ([UIMessage]) -> Void)?
    ) -> IOSAgentToolEngineResult {
        let failureMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "[engine] provider error: \(error.localizedDescription)", metadata: nil)],
            annotations: [],
            createdAt: Self.nowLocalDateTime(),
            finishedAt: Self.nowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let failedMessages = working + [failureMessage]
        onMessagesUpdated?(failedMessages)
        return IOSAgentToolEngineResult(
            messages: failedMessages,
            stepsExecuted: steps,
            pendingApproval: nil,
            hitStepLimit: false,
            providerFailureMessage: error.localizedDescription
        )
    }

    /// The loop body; every terminal return path funnels through the `run`
    /// wrapper's `finishingCitation` so the citation flush (P2-c) happens
    /// exactly once per run regardless of how the run ended.
    private func runInternal(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        citationTracker: IOSMemoryCitationTracker?,
        toolExposureBridge: IosToolExposureBridge?,
        refreshToolExposure: (@MainActor @Sendable () async -> Void)?,
        mailboxDrain: (@Sendable () async -> IOSMailboxDrainResult)?,
        drainSteer: (@Sendable () async -> [UIMessage])?,
        prepareRequestMessages: (@Sendable ([UIMessage]) async throws -> [UIMessage])?,
        sortPendingToolCalls: (@Sendable ([UIMessagePart.Tool]) -> [UIMessagePart.Tool])?,
        preemptToolBatch: (@Sendable ([UIMessagePart.Tool]) async -> String?)?,
        resolveUnexposedToolCall: (@Sendable (UIMessagePart.Tool) async -> [UIMessagePart]?)?,
        onAssistantTurnStarted: (@MainActor @Sendable () async -> Void)?,
        onAssistantTurnCompleted: (@Sendable ([UIMessage]) async -> Bool)?,
        onToolExecutionStarted: (@MainActor @Sendable (String, String) async -> Void)?,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)?,
        onAssistantText: (@Sendable (String) -> Void)?,
        onAssistantReasoning: (@Sendable (String) -> Void)?,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)?,
        onMessagesUpdated: (@Sendable ([UIMessage]) -> Void)?
    ) async -> IOSAgentToolEngineResult {
        var working = messages
        var effectiveParams = params
        var steps = 0
        // I-5: one guard per `run()` invocation, never carried across runs.
        // The engine instance itself is long-lived/reused (SubAgent, chat
        // background handoff), so this must be a local — a guard stored on
        // `self` would leak one run's repeat-count into the next.
        var loopGuard = IOSToolLoopGuard()

        // Background handoff parity: the input may carry assistant turns whose
        // tool calls were never executed — e.g. the model already decided to
        // generate_image, but the foreground executor was interrupted (lock
        // screen) before it ran. Execute those pre-existing empty-output tools
        // ONCE here, before any streaming, and fill their results in place.
        //
        // Without this, the loop below would first re-prompt the model, which —
        // seeing an unanswered tool call — typically re-issues it, causing the
        // executor to run the SAME call a second time. For costly side effects
        // (image generation burning a Codex credit, a network search) this is a
        // real waste and a correctness hazard. Pre-execution does not consume
        // the `steps` budget: it is finishing work the prior (foreground) run
        // already started, not a fresh reasoning round.
        let preExistingResult = await batchExecutor.executePreExistingPendingTools(
            in: working,
            loopGuard: &loopGuard,
            onToolExecutionStarted: onToolExecutionStarted
        )
        working = preExistingResult.messages
        onMessagesUpdated?(working)
        if let durabilityFailure = preExistingResult.durabilityFailureMessage {
            return IOSAgentToolEngineResult(
                messages: working,
                stepsExecuted: 0,
                pendingApproval: nil,
                hitStepLimit: false,
                durabilityFailureMessage: durabilityFailure
            )
        }
        if let outcomeUnknown = preExistingResult.toolOutcomeUnknown {
            return IOSAgentToolEngineResult(
                messages: working,
                stepsExecuted: 0,
                pendingApproval: nil,
                hitStepLimit: false,
                toolOutcomeUnknown: outcomeUnknown
            )
        }
        if preExistingResult.wasCancelled {
            return IOSAgentToolEngineResult(
                messages: working,
                stepsExecuted: 0,
                pendingApproval: nil,
                hitStepLimit: false,
                wasCancelled: true
            )
        }
        if preExistingResult.guardStopped {
            return await finalizeAfterToolLoopGuardStop(
                providerSetting: providerSetting,
                messages: working,
                params: effectiveParams,
                stepsExecuted: 0,
                citationTracker: citationTracker,
                prepareRequestMessages: prepareRequestMessages,
                onAssistantTurnStarted: onAssistantTurnStarted,
                onAssistantStage: onAssistantStage,
                onAssistantText: onAssistantText,
                onAssistantReasoning: onAssistantReasoning,
                onAssistantMessageSnapshot: onAssistantMessageSnapshot,
                onMessagesUpdated: onMessagesUpdated
            )
        }
        if let approval = preExistingResult.pendingApproval,
           configuration.honorApprovalPause {
            return IOSAgentToolEngineResult(
                messages: working,
                stepsExecuted: 0,
                pendingApproval: approval,
                hitStepLimit: false
            )
        }

        while steps < configuration.maxSteps {
            let chunk: MessageChunk
            let cancelledBeforeProvider: Bool
            var transcriptRequest: PromptTranscriptRequest?
            if Task.isCancelled {
                cancelledBeforeProvider = true
            } else {
                await onAssistantTurnStarted?()
                cancelledBeforeProvider = Task.isCancelled
            }
            if cancelledBeforeProvider {
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    wasCancelled: true
                )
            }
            do {
                // P0-2 hook: request-only transform before every provider round.
                // `working` stays the canonical transcript (tool outputs appended
                // in place below); whatever the hook injects/compacts is what the
                // model actually sees this round. Default (nil) = identity.
                // B1: 钩子可抛(如上下文压缩失败)——落入下方通用 catch,与本轮
                // provider 失败同路径收口(CG-C prepareAndStartStreaming 压缩失败
                // → presentStreamError 的引擎侧等价)。
                // Add guidance before the existing upload budget/compaction hook, so
                // its fixed overhead is included without changing canonical messages.
                let plannedMessages = IOSPhoneAutomationRequestPolicy.requestMessages(
                    working, tools: effectiveParams.tools
                )
                var requestMessages = try await prepareRequestMessages?(plannedMessages) ?? plannedMessages
                let requestParams = await phoneRequestParams(effectiveParams, providerSetting: providerSetting)
                let preparedRequest = try await providerStep.prepareStepRequest(
                    providerSetting: providerSetting,
                    params: requestParams
                )
                let transcriptCapabilities = PromptTranscriptCapabilities.companion.resolve(
                    setting: preparedRequest.providerSetting,
                    model: preparedRequest.params.model
                )
                if transcriptCapabilities.systemUpdates {
                    let prepared = PromptTranscript.shared.prepare(
                        canonicalMessages: working,
                        preparedMessages: requestMessages,
                        tools: preparedRequest.params.tools
                    )
                    requestMessages = prepared.messages
                    transcriptRequest = prepared
                }
                if let ledger, let ledgerRunId {
                    let snapshot = IOSRunRequestSnapshot.make(
                        roundIndex: steps + 1,
                        providerSetting: preparedRequest.providerSetting,
                        messages: requestMessages,
                        params: preparedRequest.params
                    )
                    guard await ledger.recordRequestSnapshot(
                        runId: ledgerRunId,
                        snapshot: snapshot
                    ) else {
                        throw NSError(
                            domain: "IOSAgentToolEngine.RequestSnapshot",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "request snapshot ledger write failed"]
                        )
                    }
                }
                chunk = try await providerStep.streamStep(
                    request: preparedRequest,
                    messages: requestMessages,
                    citationTracker: citationTracker,
                    onAssistantStage: onAssistantStage,
                    onAssistantText: onAssistantText,
                    onAssistantReasoning: onAssistantReasoning,
                    onAssistantMessageSnapshot: onAssistantMessageSnapshot
                )
            } catch let failure as StreamStepFailure {
                let cancelled = failure.underlying is CancellationError || Task.isCancelled
                if let assistant = failure.assistant {
                    let recorded = transcriptRequest.map {
                        PromptTranscript.shared.recordResponse(message: assistant, request: $0)
                    } ?? assistant
                    working.append(recorded)
                    let outputs = batchExecutor.pendingToolCalls(in: assistant).map { tool in
                        (tool: tool, parts: [UIMessagePart.Text(text: IOSToolFailurePayload.json(
                            toolName: tool.toolName,
                            reason: cancelled ? "Generation cancelled." : "Generation failed before the tool call completed.",
                            denied: cancelled,
                            status: cancelled ? "denied" : "failed"
                        ), metadata: nil)] as [UIMessagePart])
                    }
                    working = batchExecutor.applyToolOutputs(outputs, to: working)
                }
                if cancelled {
                    onMessagesUpdated?(working)
                    return IOSAgentToolEngineResult(messages: working, stepsExecuted: steps,
                                                    pendingApproval: nil, hitStepLimit: false, wasCancelled: true)
                }
                return providerFailureResult(failure.underlying, working: working, steps: steps, onMessagesUpdated: onMessagesUpdated)
            } catch is CancellationError {
                return IOSAgentToolEngineResult(messages: working, stepsExecuted: steps,
                                                pendingApproval: nil, hitStepLimit: false, wasCancelled: true)
            } catch {
                return providerFailureResult(error, working: working, steps: steps, onMessagesUpdated: onMessagesUpdated)
            }

            let rawAssistantMessage = assistantMessage(from: chunk)
            if Self.reachedOutputLimit(chunk) {
                let recorded = rawAssistantMessage.map { message in
                    transcriptRequest.map { PromptTranscript.shared.recordResponse(message: message, request: $0) } ?? message
                }
                let limitedMessages = recorded.map { working + [$0] } ?? working
                onMessagesUpdated?(limitedMessages)
                return IOSAgentToolEngineResult(
                    messages: limitedMessages,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    providerFailureMessage: "模型回复达到输出上限，请重试。",
                    hitOutputLimit: true
                )
            }
            let emittedTools = batchExecutor.pendingToolCalls(in: rawAssistantMessage)
            let alreadyCompleted = batchExecutor.completedToolKeys(in: working)
            let assistantMessage: UIMessage? = rawAssistantMessage.flatMap { message in
                let retained: UIMessage?
                if message.role != MessageRole.assistant || alreadyCompleted.isEmpty {
                    retained = message
                } else {
                    let retainedParts = message.parts.filter { part in
                        guard let tool = part as? UIMessagePart.Tool, tool.output.isEmpty else {
                            return true
                        }
                        return !alreadyCompleted.contains(IOSAgentToolBatchExecutor.toolCallKey(tool))
                    }
                    if retainedParts.isEmpty {
                        retained = nil
                    } else if retainedParts.count == message.parts.count {
                        retained = message
                    } else {
                        retained = UIMessage(
                            id: message.id,
                            role: message.role,
                            parts: retainedParts,
                            annotations: message.annotations,
                            createdAt: message.createdAt,
                            finishedAt: message.finishedAt,
                            modelId: message.modelId,
                            usage: message.usage,
                            translation: message.translation
                        )
                    }
                }
                guard let retained else { return nil }
                return transcriptRequest.map {
                    PromptTranscript.shared.recordResponse(message: retained, request: $0)
                } ?? retained
            }
            if let assistantMessage {
                working.append(assistantMessage)
                onMessagesUpdated?(working)
            }

            // The response owner must durably retire its server cursor before any
            // tool or later model round can advance this same run.
            if let onAssistantTurnCompleted, !(await onAssistantTurnCompleted(working)) {
                return IOSAgentToolEngineResult(
                    messages: working, stepsExecuted: steps + 1, pendingApproval: nil,
                    hitStepLimit: false, durabilityFailureMessage: "response continuation checkpoint write failed"
                )
            }

            // Only fresh pending tools remain in the retained assistant turn.
            // Completed echoes are removed without discarding concurrent text
            // or a different tool call emitted by the same provider response.
            let pendingTools = batchExecutor.pendingToolCalls(in: assistantMessage)
            if pendingTools.isEmpty {
                let hasAssistantContent = assistantMessage?.parts.contains { part in
                    if let text = part as? UIMessagePart.Text {
                        return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if let tool = part as? UIMessagePart.Tool {
                        return !tool.output.isEmpty
                    }
                    return true
                } ?? false
                if !emittedTools.isEmpty, !hasAssistantContent {
                    // The provider only echoed calls that were already completed.
                    // Drop any whitespace-only remainder and ask for the final answer.
                    if assistantMessage != nil {
                        working.removeLast()
                        onMessagesUpdated?(working)
                    }
                    steps += 1
                    continue
                }
                // A child can receive a followup while the provider is
                // producing a plain-text turn. Give the mailbox one final
                // boundary before returning, while reserving a round to let
                // the provider consume any newly delivered messages.
                if let mailboxDrain, steps + 1 < configuration.maxSteps {
                    let drained = Self.uniqueMailboxMessages(
                        (await mailboxDrain()).values,
                        excluding: working
                    )
                    if !drained.isEmpty {
                        working.append(contentsOf: drained)
                        onMessagesUpdated?(working)
                        steps += 1
                        continue
                    }
                }
                // No more tool calls — the model is done.
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false
                )
            }

            // P0-2 hook: 批量准入闸门(前台预算/硬失败语义)。CGC 在流完成后、
            // 执行前裁定本轮未决调用——预算耗尽或彻底未知的名字不进入执行,
            // 整批以失败文案原地收口并终止 run。nil = 放行(引擎现状)。
            if let preemptToolBatch,
               let batchFailureText = await preemptToolBatch(pendingTools) {
                let preemptedOutputs: [(tool: UIMessagePart.Tool, parts: [UIMessagePart])] = pendingTools.map {
                    (tool: $0, parts: [UIMessagePart.Text(text: batchFailureText, metadata: nil)])
                }
                working = batchExecutor.applyToolOutputs(preemptedOutputs, to: working)
                onMessagesUpdated?(working)
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    guardStopped: true
                )
            }

            // Execute every pending tool in this turn (batch), then fill all
            // of them in place before the next round — mirrors Android's
            // AgentToolDispatcher.executeBatch.
            // P0-2 hook: `sortPendingToolCalls` may re-order the batch before
            // execution (foreground pins kind-priority today); default nil
            // keeps the model's emission order (engine status quo).
            let orderedPendingTools = sortPendingToolCalls?(pendingTools) ?? pendingTools
            let batchResult = await batchExecutor.executeBatch(
                orderedPendingTools,
                isUserInitiated: false,
                loopGuard: &loopGuard,
                resolveUnexposedToolCall: resolveUnexposedToolCall,
                onToolExecutionStarted: onToolExecutionStarted
            )
            if let durabilityFailure = batchResult.durabilityFailureMessage {
                working = batchExecutor.applyToolOutputs(batchResult.outputs, to: working)
                onMessagesUpdated?(working)
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    durabilityFailureMessage: durabilityFailure
                )
            }
            if let outcomeUnknown = batchResult.toolOutcomeUnknown {
                working = batchExecutor.applyToolOutputs(batchResult.outputs, to: working)
                onMessagesUpdated?(working)
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    toolOutcomeUnknown: outcomeUnknown
                )
            }
            if batchResult.wasCancelled {
                working = batchExecutor.applyToolOutputs(batchResult.outputs, to: working)
                onMessagesUpdated?(working)
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    wasCancelled: true
                )
            }
            if let approval = batchResult.pendingApproval, configuration.honorApprovalPause {
                working = batchExecutor.applyToolOutputs(batchResult.outputs, to: working)
                onMessagesUpdated?(working)
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: approval,
                    hitStepLimit: false
                )
            }
            working = batchExecutor.applyToolOutputs(batchResult.outputs, to: working)
            onMessagesUpdated?(working)

            // All calls in this batch have completed and their outputs have
            // been applied above. A yielded wait must now release the run
            // before either exposure refresh or mailbox/steer drain: the host
            // terminal path owns the queued user input and starts the next
            // foreground run. This also preserves every later tool result
            // from the same provider batch.
            let yielded = !batchResult.guardStopped && batchResult.outputs.contains {
                Self.isForegroundYield(tool: $0.tool, parts: $0.parts)
            }
            if yielded {
                return IOSAgentToolEngineResult(
                    messages: working,
                    stepsExecuted: steps + 1,
                    pendingApproval: nil,
                    hitStepLimit: false,
                    yielded: true
                )
            }

            // P0-a Fix C: re-derive the request params from the run bridge's
            // CURRENT exposure after every executed batch, so a tool_search
            // hit from THIS round is declared on the NEXT round (background
            // handoff closed loop). Without a bridge the params stay frozen.
            if let bridge = toolExposureBridge {
                await refreshToolExposure?()
                effectiveParams = effectiveParams.replacingTools(bridge.visibleTools())
                // M2: same refresh point — rebuild the executor table for the
                // current round's visible tools (chat background only; the
                // rebuilder re-registers through backgroundToolExecutors with
                // the round's params/bridge captured inside the closures).
                // Without a rebuilder the table stays frozen (SubAgent/Novel).
                if let executorRebuilder {
                    executors = executorRebuilder(effectiveParams)
                }
            }

            // P1-d: mailbox drain 与 replacingTools 同点——每轮批量执行后、下一轮
            // streamStep 之前。drain 闭包把本会话信封渲染为 user 消息返回，
            // 追加进 working（下一轮 upload 折入），闭包内完成持久化（后台无 UI
            // 上屏）。SubAgent/Novel 不传 → 零影响；Room drain 的事务加固保证
            // 同会话前后台双 drain 最多折入一次（loser 返回空）。
            // There must be another provider round after a drain.  At the
            // final allowed tool round, marking a mailbox envelope delivered
            // would make it disappear from pending without ever reaching the
            // model.  The coordinator's terminal continuation will retry it
            // after this run is released.
            if let mailboxDrain,
               !batchResult.guardStopped,
               steps + 1 < configuration.maxSteps {
                let drained = Self.uniqueMailboxMessages(
                    (await mailboxDrain()).values,
                    excluding: working
                )
                if !drained.isEmpty {
                    working.append(contentsOf: drained)
                    onMessagesUpdated?(working)
                }
            }

            // P0-2 hook: steer drain 与 mailbox 同点、紧随其后——顺序对齐前台
            // CGC 的轮边界消费（先 mailbox 后 steer）。drained steer 消息折入
            // 下一轮 upload；不传 = 零影响（SubAgent/Novel 现状）。
            if let drainSteer {
                let steered = await drainSteer()
                if !steered.isEmpty {
                    working.append(contentsOf: steered)
                    onMessagesUpdated?(working)
                }
            }

            // I-5: do not execute a truly stationary third call, but still give
            // the model one bounded, tool-free turn to explain what was learned
            // and what remains incomplete. Ending immediately after the red tool
            // capsule leaves the user with no answer at all.
            if batchResult.guardStopped {
                return await finalizeAfterToolLoopGuardStop(
                    providerSetting: providerSetting,
                    messages: working,
                    params: effectiveParams,
                    stepsExecuted: steps + 1,
                    citationTracker: citationTracker,
                    prepareRequestMessages: prepareRequestMessages,
                    onAssistantTurnStarted: onAssistantTurnStarted,
                    onAssistantStage: onAssistantStage,
                    onAssistantText: onAssistantText,
                    onAssistantReasoning: onAssistantReasoning,
                    onAssistantMessageSnapshot: onAssistantMessageSnapshot,
                    onMessagesUpdated: onMessagesUpdated
                )
            }

            steps += 1
        }

        // Reached the step limit with tool calls still pending.
        return IOSAgentToolEngineResult(
            messages: working,
            stepsExecuted: steps,
            pendingApproval: nil,
            hitStepLimit: true
        )
    }

    /// A loop-guard stop is a failed run, but it must still be a readable one.
    /// Give the provider exactly one extra request with an empty tool list and a
    /// request-only instruction to summarize. The instruction is not persisted
    /// into the conversation; only the final assistant answer is.
    private func finalizeAfterToolLoopGuardStop(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        stepsExecuted: Int,
        citationTracker: IOSMemoryCitationTracker?,
        prepareRequestMessages: (@Sendable ([UIMessage]) async throws -> [UIMessage])?,
        onAssistantTurnStarted: (@MainActor @Sendable () async -> Void)?,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)?,
        onAssistantText: (@Sendable (String) -> Void)?,
        onAssistantReasoning: (@Sendable (String) -> Void)?,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)?,
        onMessagesUpdated: (@Sendable ([UIMessage]) -> Void)?
    ) async -> IOSAgentToolEngineResult {
        guard !Task.isCancelled else {
            return IOSAgentToolEngineResult(
                messages: messages,
                stepsExecuted: stepsExecuted,
                pendingApproval: nil,
                hitStepLimit: false,
                wasCancelled: true,
                guardStopped: true
            )
        }

        var transcriptRequest: PromptTranscriptRequest?
        do {
            await onAssistantTurnStarted?()
            try Task.checkCancellation()

            let summaryMessages = IOSPhoneAutomationRequestPolicy.requestMessages(messages, tools: [])
            let preparedMessages = try await prepareRequestMessages?(summaryMessages) ?? summaryMessages
            var requestMessages = [Self.toolLoopGuardFinalizationInstruction()] + preparedMessages
            let preparedRequest = try await providerStep.prepareStepRequest(
                providerSetting: providerSetting,
                params: params.replacingTools([])
            )
            let transcriptCapabilities = PromptTranscriptCapabilities.companion.resolve(
                setting: preparedRequest.providerSetting,
                model: preparedRequest.params.model
            )
            if transcriptCapabilities.systemUpdates {
                let prepared = PromptTranscript.shared.prepare(
                    canonicalMessages: messages,
                    preparedMessages: requestMessages,
                    tools: preparedRequest.params.tools
                )
                requestMessages = prepared.messages
                transcriptRequest = prepared
            }
            if let ledger, let ledgerRunId {
                let snapshot = IOSRunRequestSnapshot.make(
                    roundIndex: stepsExecuted + 1,
                    providerSetting: preparedRequest.providerSetting,
                    messages: requestMessages,
                    params: preparedRequest.params
                )
                guard await ledger.recordRequestSnapshot(runId: ledgerRunId, snapshot: snapshot) else {
                    throw NSError(
                        domain: "IOSAgentToolEngine.RequestSnapshot",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "request snapshot ledger write failed"]
                    )
                }
            }

            let chunk = try await providerStep.streamStep(
                request: preparedRequest,
                messages: requestMessages,
                citationTracker: citationTracker,
                onAssistantStage: onAssistantStage,
                onAssistantText: onAssistantText,
                onAssistantReasoning: onAssistantReasoning,
                onAssistantMessageSnapshot: onAssistantMessageSnapshot
            )
            let reachedOutputLimit = Self.reachedOutputLimit(chunk)
            var finalMessages = messages
            if let rawAssistant = toolFreeAssistantMessage(from: assistantMessage(from: chunk)) {
                let assistant = transcriptRequest.map {
                    PromptTranscript.shared.recordResponse(message: rawAssistant, request: $0)
                } ?? rawAssistant
                finalMessages.append(assistant)
            } else {
                finalMessages.append(Self.toolLoopGuardFallbackMessage())
            }
            onMessagesUpdated?(finalMessages)
            return IOSAgentToolEngineResult(
                messages: finalMessages,
                stepsExecuted: stepsExecuted + 1,
                pendingApproval: nil,
                hitStepLimit: false,
                providerFailureMessage: reachedOutputLimit ? "模型收尾回复达到输出上限，请重试。" : nil,
                hitOutputLimit: reachedOutputLimit,
                guardStopped: true
            )
        } catch let failure as StreamStepFailure {
            let cancelled = failure.underlying is CancellationError || Task.isCancelled
            var finalMessages = messages
            if let assistant = failure.assistant {
                let parts = assistant.parts.filter { !($0 is UIMessagePart.Tool) }
                if !parts.isEmpty {
                    let toolFreeAssistant = UIMessage(
                        id: assistant.id, role: assistant.role, parts: parts,
                        annotations: assistant.annotations, createdAt: assistant.createdAt,
                        finishedAt: assistant.finishedAt, modelId: assistant.modelId,
                        usage: assistant.usage, translation: assistant.translation
                    )
                    let recorded = transcriptRequest.map {
                        PromptTranscript.shared.recordResponse(message: toolFreeAssistant, request: $0)
                    } ?? toolFreeAssistant
                    finalMessages.append(recorded)
                }
            }
            if !cancelled {
                finalMessages.append(Self.toolLoopGuardFallbackMessage(error: failure.underlying.localizedDescription))
            }
            onMessagesUpdated?(finalMessages)
            return IOSAgentToolEngineResult(
                messages: finalMessages, stepsExecuted: stepsExecuted,
                pendingApproval: nil, hitStepLimit: false,
                providerFailureMessage: cancelled ? nil : failure.underlying.localizedDescription,
                wasCancelled: cancelled, guardStopped: true
            )
        } catch is CancellationError {
            return IOSAgentToolEngineResult(
                messages: messages,
                stepsExecuted: stepsExecuted,
                pendingApproval: nil,
                hitStepLimit: false,
                wasCancelled: true,
                guardStopped: true
            )
        } catch {
            let fallback = Self.toolLoopGuardFallbackMessage(error: error.localizedDescription)
            let finalMessages = messages + [fallback]
            onMessagesUpdated?(finalMessages)
            return IOSAgentToolEngineResult(
                messages: finalMessages,
                stepsExecuted: stepsExecuted,
                pendingApproval: nil,
                hitStepLimit: false,
                providerFailureMessage: error.localizedDescription,
                guardStopped: true
            )
        }
    }

    /// A provider may ignore the empty tool list. Never persist another pending
    /// call from the one-shot finalization request; keep only its readable text.
    private func toolFreeAssistantMessage(from message: UIMessage?) -> UIMessage? {
        guard let message, message.role == MessageRole.assistant else { return nil }
        let parts = message.parts.filter { !($0 is UIMessagePart.Tool) }
        let hasText = parts.contains { part in
            guard let text = part as? UIMessagePart.Text else { return false }
            return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasText else { return nil }
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

    private static func toolLoopGuardFinalizationInstruction() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.system,
            parts: [UIMessagePart.Text(
                text: "工具循环保护刚拒绝了一个连续重复调用。不要再调用任何工具；仅根据已有对话和工具结果直接给用户最终答复，明确说明已确认的信息、未完成的部分及原因，并给出简短的下一步。",
                metadata: nil
            )],
            annotations: [],
            createdAt: Self.nowLocalDateTime(),
            finishedAt: Self.nowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private static func toolLoopGuardFallbackMessage(error: String? = nil) -> UIMessage {
        let suffix = error.map { "收尾回复失败：\($0)" }
            ?? "模型没有返回可显示的收尾内容。"
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(
                text: "已停止连续重复的工具调用，并保留现有结果。\(suffix)",
                metadata: nil
            )],
            annotations: [],
            createdAt: Self.nowLocalDateTime(),
            finishedAt: Self.nowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// P2-c: run 终结统一收口——完成/失败/取消/限步/审批暂停的每个返回路径都
    /// 经 `run` 包装层走到这里。`finish()` 幂等；flush 出的剩余可见文本（未闭合
    /// 标签在 EOF 时按 codex 同款 auto-close 整段吞进 citation，不外泄）并入终态
    /// 消息快照。nil → 原样返回，SubAgent/Novel 零变化。
    private static func finishingCitation(
        _ result: IOSAgentToolEngineResult,
        tracker: IOSMemoryCitationTracker?
    ) -> IOSAgentToolEngineResult {
        guard let tracker else { return result }
        let remainder = tracker.finish()
        guard !remainder.isEmpty else { return result }
        return IOSAgentToolEngineResult(
            messages: IOSMemoryCitationTracker.appendingCitationRemainder(remainder, to: result.messages),
            stepsExecuted: result.stepsExecuted,
            pendingApproval: result.pendingApproval,
            hitStepLimit: result.hitStepLimit,
            providerFailureMessage: result.providerFailureMessage,
            durabilityFailureMessage: result.durabilityFailureMessage,
            toolOutcomeUnknown: result.toolOutcomeUnknown,
            hitOutputLimit: result.hitOutputLimit,
            wasCancelled: result.wasCancelled,
            guardStopped: result.guardStopped
        )
    }

    /// Executes only the pending tool calls already present in `messages`.
    /// Used by direct image-edit background handoff where no follow-up model
    /// turn should be requested after the tool result is filled.
    public func executePreExistingToolsOnly(messages: [UIMessage]) async -> IOSAgentToolEngineResult {
        // Standalone entry point (bypasses `run()`), so it needs its own
        // fresh, local guard — same "never carried across runs" rule as `run`.
        var loopGuard = IOSToolLoopGuard()
        let result = await batchExecutor.executePreExistingPendingTools(
            in: messages,
            loopGuard: &loopGuard,
            onToolExecutionStarted: nil
        )
        return IOSAgentToolEngineResult(
            messages: result.messages,
            stepsExecuted: 0,
            pendingApproval: result.pendingApproval,
            hitStepLimit: false,
            durabilityFailureMessage: result.durabilityFailureMessage,
            toolOutcomeUnknown: result.toolOutcomeUnknown,
            wasCancelled: result.wasCancelled,
            guardStopped: result.guardStopped
        )
    }

    // MARK: - Internals

    private func assistantMessage(from chunk: MessageChunk) -> UIMessage? {
        for choice in chunk.choices {
            if let message = choice.message ?? choice.delta {
                return message
            }
        }
        return nil
    }

    private static func reachedOutputLimit(_ chunk: MessageChunk) -> Bool {
        let reasons = Set(chunk.choices.compactMap { $0.finishReason?.lowercased() })
        return !reasons.isDisjoint(with: ["length", "max_tokens", "max_output_tokens"])
    }

    /// Mirrors `ChatViewModel.nowLocalDateTime()` for KMP message construction.
    static func nowLocalDateTime() -> Kotlinx_datetimeLocalDateTime {
        let now = Date()
        let cal = Calendar.current
        return Kotlinx_datetimeLocalDateTime(
            year: Int32(cal.component(.year, from: now)),
            month: Int32(cal.component(.month, from: now)),
            day: Int32(cal.component(.day, from: now)),
            hour: Int32(cal.component(.hour, from: now)),
            minute: Int32(cal.component(.minute, from: now)),
            second: Int32(cal.component(.second, from: now)),
            nanosecond: Int32(cal.component(.nanosecond, from: now))
        )
    }

}
