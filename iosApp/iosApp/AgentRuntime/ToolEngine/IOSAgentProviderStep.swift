import Foundation
@preconcurrency import Shared

struct StreamStepFailure: Error, @unchecked Sendable {
    let underlying: Error
    let assistant: UIMessage?
}

private final class StreamStepState: @unchecked Sendable {
    struct AssistantUpdate {
        let text: String?
        let reasoning: String?
        let stage: AgentActivityStage?
    }

    let accumulator: MessageStreamAccumulator
    private let lock = NSLock()
    private var assistantText = ""
    private var assistantReasoning = ""
    private var assistantStage: AgentActivityStage?
    private var finishReason: String?
    private var continuation: CheckedContinuation<MessageChunk, Error>?
    private var job: Kotlinx_coroutines_coreJob?
    private var cancellationRequested = false
    private var resumed = false
    private var lastAssistantSnapshotAt: ContinuousClock.Instant?

    init(accumulator: MessageStreamAccumulator) { self.accumulator = accumulator }

    func append(_ chunk: MessageChunk) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, !cancellationRequested else { return false }
        accumulator.append(chunk: chunk)
        return true
    }

    func assistantSnapshot() -> UIMessage? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = accumulator.snapshot().last,
              last.role == MessageRole.assistant else { return nil }
        return last
    }

    /// B2 provisional 快照的推送节流(前台内核路径专属;hook 为 nil 的后台/
    /// 子代理流根本不调 snapshot——O(n²) 红线由
    /// testStreamingAssistantTextDoesNotSnapshotOnEveryChunk 钉住)。
    /// 认领即盖章:同一窗口内的后续 chunk 不再快照。
    func claimAssistantSnapshotPublish(minimumInterval: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let last = lastAssistantSnapshotAt, now < last + minimumInterval { return false }
        lastAssistantSnapshotAt = now
        return true
    }

    func appendAssistantDelta(
        from chunk: MessageChunk,
        collectText: Bool = true,
        collectReasoning: Bool = true
    ) -> AssistantUpdate {
        // The accumulator remains the source of truth for the final message
        // and optional snapshots. Only callbacks that actually consume
        // cumulative text need a second growing String here; otherwise each
        // chunk would maintain an unused duplicate of the response.
        lock.lock()
        defer { lock.unlock() }
        var textChanged = false
        var reasoningChanged = false
        var hasReasoningDelta = false
        var hasTextDelta = false
        for choice in chunk.choices {
            if let reason = choice.finishReason {
                finishReason = reason
            }
            if let delta = choice.delta, delta.role == MessageRole.assistant {
                let hasReasoning = Self.hasReasoning(in: delta)
                hasReasoningDelta = hasReasoningDelta || hasReasoning
                let hasText = Self.hasText(in: delta)
                hasTextDelta = hasTextDelta || hasText
                if hasReasoning {
                    if collectReasoning {
                        assistantReasoning += Self.reasoning(in: delta)
                    }
                    reasoningChanged = true
                }
                if hasText {
                    if collectText {
                        assistantText += Self.text(in: delta)
                    }
                    textChanged = true
                }
            } else if let message = choice.message, message.role == MessageRole.assistant {
                let hasReasoning = Self.hasReasoning(in: message)
                hasReasoningDelta = hasReasoningDelta || hasReasoning
                let hasText = Self.hasText(in: message)
                hasTextDelta = hasTextDelta || hasText
                if hasReasoning {
                    if collectReasoning {
                        assistantReasoning = Self.reasoning(in: message)
                    }
                    reasoningChanged = true
                }
                if hasText {
                    if collectText {
                        assistantText = Self.text(in: message)
                    }
                    textChanged = true
                }
            }
        }
        var publishedStage: AgentActivityStage?
        if let candidate = AgentActivityResponseStagePolicy.updatedStage(
            hasReasoningDelta: hasReasoningDelta,
            hasTextDelta: hasTextDelta
        ), let nextStage = AgentActivityResponseStagePolicy.nextPublishedStage(
            current: assistantStage,
            candidate: candidate
        ) {
            assistantStage = nextStage
            publishedStage = nextStage
        }
        return AssistantUpdate(
            text: collectText && textChanged && !assistantText.isEmpty ? assistantText : nil,
            reasoning: collectReasoning && reasoningChanged && !assistantReasoning.isEmpty ? assistantReasoning : nil,
            stage: publishedStage
        )
    }

    func terminalFinishReason() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return finishReason
    }

    func install(continuation: CheckedContinuation<MessageChunk, Error>) {
        lock.lock()
        if cancellationRequested {
            resumed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func install(job: Kotlinx_coroutines_coreJob?) {
        guard let job else { return }
        lock.lock()
        let shouldCancel = cancellationRequested
        if !shouldCancel, !resumed {
            self.job = job
        }
        lock.unlock()
        if shouldCancel {
            job.cancel(cause: nil)
        }
    }

    func resume(returning chunk: MessageChunk) {
        let continuation: CheckedContinuation<MessageChunk, Error>?
        lock.lock()
        if !resumed {
            resumed = true
            continuation = self.continuation
            self.continuation = nil
            job = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: chunk)
    }

    func resume(throwing error: Error) {
        let continuation: CheckedContinuation<MessageChunk, Error>?
        lock.lock()
        if !resumed {
            resumed = true
            continuation = self.continuation
            self.continuation = nil
            job = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func cancel() {
        let continuation: CheckedContinuation<MessageChunk, Error>?
        let job: Kotlinx_coroutines_coreJob?
        lock.lock()
        cancellationRequested = true
        job = self.job
        self.job = nil
        if !resumed, self.continuation != nil {
            resumed = true
            continuation = self.continuation
            self.continuation = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        job?.cancel(cause: nil)
        continuation?.resume(throwing: CancellationError())
    }

    private static func text(in message: UIMessage) -> String {
        message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
    }

    private static func hasText(in message: UIMessage) -> Bool {
        message.parts.contains {
            guard let text = $0 as? UIMessagePart.Text else { return false }
            return !text.text.isEmpty
        }
    }

    private static func hasReasoning(in message: UIMessage) -> Bool {
        message.parts.contains {
            guard let reasoning = $0 as? UIMessagePart.Reasoning else { return false }
            return !reasoning.reasoning.isEmpty
        }
    }

    private static func reasoning(in message: UIMessage) -> String {
        message.parts.compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning }.joined()
    }
}


struct IOSAgentProviderStep: Sendable {
    private let provider: any IOSAgentTextProvider

    init(provider: any IOSAgentTextProvider) {
        self.provider = provider
    }

    private static let assistantSnapshotPublishInterval: Duration = .milliseconds(48)

    enum PreparedStepMode {
        case grokWeb
        case gemini
        case blocking
        case streaming
    }

    struct PreparedStepRequest {
        let providerSetting: ProviderSetting
        let params: TextGenerationParams
        let mode: PreparedStepMode
    }

    /// Resolve the same provider/params pair that the transport will consume.
    /// Keeping preparation ahead of the durable snapshot means a failed
    /// prepare never leaves an event that claims a request was sent.
    func prepareStepRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> PreparedStepRequest {
        if let openAI = providerSetting as? ProviderSetting.OpenAI,
           IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI) {
            return PreparedStepRequest(providerSetting: providerSetting, params: params, mode: .grokWeb)
        }
        if let google = providerSetting as? ProviderSetting.Google,
           IOSGeminiProviderResolver.supportsChat(google) {
            return PreparedStepRequest(providerSetting: providerSetting, params: params, mode: .gemini)
        }
        guard let streaming = provider as? IOSAgentStreamingProvider else {
            return PreparedStepRequest(providerSetting: providerSetting, params: params, mode: .blocking)
        }
        let (requestProvider, requestParams) = try await streaming.prepareRequest(
            providerSetting: providerSetting,
            params: params
        )
        guard streaming.supportsStreaming(providerSetting: requestProvider) else {
            // Preserve the provider's blocking fallback contract: it receives
            // the original pair, exactly as before request snapshots existed.
            return PreparedStepRequest(providerSetting: providerSetting, params: params, mode: .blocking)
        }
        return PreparedStepRequest(providerSetting: requestProvider, params: requestParams, mode: .streaming)
    }

    private static func deliverAssistantSnapshotIfDue(
        state: StreamStepState,
        hook: (@Sendable (UIMessage) -> Void)?
    ) {
        guard let hook,
              state.claimAssistantSnapshotPublish(minimumInterval: assistantSnapshotPublishInterval),
              let provisional = state.assistantSnapshot() else { return }
        hook(provisional)
    }

    /// Streams one model turn, accumulating chunks via the shared (500-fixed)
    /// MessageStreamAccumulator and surfacing the accumulating assistant text to
    /// [onAssistantText] token-by-token. Returns a MessageChunk wrapping the final
    /// assistant message so the rest of the loop stays unchanged.
    ///
    /// - Parameter citationTracker: P2-c. When non-nil, every incoming chunk is
    ///   passed through `IOSMemoryCitationTracker.stripped` BEFORE the
    ///   accumulator sees it (same semantics as the foreground sink: only
    ///   assistant Text deltas are stripped; tool output / harness text never
    ///   is), so the terminal snapshot carries no `<amber-mem-cite>` markers.
    ///   Default nil keeps every existing caller (SubAgent, Novel) byte-identical.
    func streamStep(
        request: PreparedStepRequest,
        messages: [UIMessage],
        citationTracker: IOSMemoryCitationTracker?,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)?,
        onAssistantText: (@Sendable (String) -> Void)?,
        onAssistantReasoning: (@Sendable (String) -> Void)?,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)?
    ) async throws -> MessageChunk {
        // Register only memory ids carried by this exact provider request. The
        // tracker reads request metadata and successful memory_tool outputs;
        // ordinary system/user text is never treated as an authorization source.
        citationTracker?.allowCitationIds(from: messages)
        switch request.mode {
        case .grokWeb:
            guard let openAI = request.providerSetting as? ProviderSetting.OpenAI else {
                throw NSError(domain: "IOSAgentToolEngine.PreparedRequest", code: 1)
            }
            return try await streamGrokWebStep(
                provider: openAI,
                messages: messages,
                params: request.params,
                citationTracker: citationTracker,
                onAssistantStage: onAssistantStage,
                onAssistantText: onAssistantText,
                onAssistantReasoning: onAssistantReasoning,
                onAssistantMessageSnapshot: onAssistantMessageSnapshot
            )
        case .gemini:
            guard let google = request.providerSetting as? ProviderSetting.Google else {
                throw NSError(domain: "IOSAgentToolEngine.PreparedRequest", code: 2)
            }
            return try await streamGeminiStep(
                provider: google,
                messages: messages,
                params: request.params,
                citationTracker: citationTracker,
                onAssistantStage: onAssistantStage,
                onAssistantText: onAssistantText,
                onAssistantReasoning: onAssistantReasoning,
                onAssistantMessageSnapshot: onAssistantMessageSnapshot
            )
        case .blocking:
            return try await provider.generateText(
                providerSetting: request.providerSetting,
                messages: messages,
                params: request.params
            )
        case .streaming:
            break
        }
        let streaming = provider as! IOSAgentStreamingProvider
        // Seed with a single NON-assistant placeholder so the streamed turn
        // forms exactly one fresh assistant message (returned as `.last`),
        // instead of merging into `messages`' trailing assistant turn — which on
        // turn ≥2 would make `run`'s `working.append(...)` duplicate that prior
        // turn. The real `messages` are still sent to the provider for context.
        // (Also avoids the accumulator's non-empty `require` on empty input.)
        let seed = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [],
            annotations: [],
            createdAt: IOSAgentToolEngine.nowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        // Box the accumulator + resume flag as @unchecked Sendable: the KMP
        // streaming bridge invokes onChunk/onComplete/onError serially on a single
        // coroutine (no concurrent access), but Swift 6 can't prove it. The box
        // also makes the @Sendable callbacks legal.
        let state = StreamStepState(accumulator: MessageStreamAccumulator(initialMessages: [seed], model: nil))
        let collectAssistantText = onAssistantText != nil
        let collectAssistantReasoning = onAssistantReasoning != nil
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MessageChunk, Error>) in
                    state.install(continuation: continuation)
                    guard !Task.isCancelled else {
                        state.cancel()
                        return
                    }
                    let job = streaming.streamText(
                        providerSetting: request.providerSetting,
                        messages: messages,
                        params: request.params,
                        onChunk: { chunk in
                            // P2-c: 后台流在进入 accumulator 前剥离 citation 隐藏
                            // 标记（与前台 sink 同语义——所有下游消费者只见到已剥离的
                            // 可见文本；nil → 原样零变化）。
                            let strippedChunk = citationTracker?.stripped(chunk) ?? chunk
                            guard state.append(strippedChunk) else { return }
                            let update = state.appendAssistantDelta(
                                from: strippedChunk,
                                collectText: collectAssistantText,
                                collectReasoning: collectAssistantReasoning
                            )
                            if let stage = update.stage {
                                onAssistantStage?(stage)
                            }
                            if let reasoning = update.reasoning {
                                onAssistantReasoning?(reasoning)
                            }
                            if let text = update.text {
                                onAssistantText?(text)
                            }
                            // B2 前台内核投影:节流后的在途 assistant 累加器快照
                            // (与终态消息同 id;citation 已在上游剥离)。
                            Self.deliverAssistantSnapshotIfDue(
                                state: state,
                                hook: onAssistantMessageSnapshot
                            )
                        },
                        onComplete: {
                            let last = state.assistantSnapshot()
                            let finalMessage: UIMessage = (last?.role == MessageRole.assistant) ? last! : Self.emptyAssistant()
                            state.resume(returning: MessageChunk(
                                id: "",
                                model: "",
                                choices: [UIMessageChoice(
                                    index: 0,
                                    delta: nil,
                                    message: finalMessage,
                                    finishReason: state.terminalFinishReason() ?? "stop"
                                )],
                                usage: nil
                            ))
                        },
                        onError: { error in
                            state.resume(throwing: NSError(
                                domain: "AmberAgent.SubAgentStream",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: error.message ?? "stream failed"]
                            ))
                        }
                    )
                    state.install(job: job)
                }
            } onCancel: {
                state.cancel()
            }
        } catch {
            state.cancel()
            throw StreamStepFailure(underlying: error, assistant: state.assistantSnapshot())
        }
    }

    private func streamGrokWebStep(
        provider: ProviderSetting.OpenAI,
        messages: [UIMessage],
        params: TextGenerationParams,
        citationTracker: IOSMemoryCitationTracker?,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)?,
        onAssistantText: (@Sendable (String) -> Void)?,
        onAssistantReasoning: (@Sendable (String) -> Void)?,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)?
    ) async throws -> MessageChunk {
        let seed = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [],
            annotations: [],
            createdAt: IOSAgentToolEngine.nowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let state = StreamStepState(
            accumulator: MessageStreamAccumulator(initialMessages: [seed], model: nil)
        )
        let collectAssistantText = onAssistantText != nil
        let collectAssistantReasoning = onAssistantReasoning != nil
        let boxed = UncheckedUIMessageBox(messages)
        let task = Task { @MainActor in
            try await IOSGrokWebClient(
                providerId: IOSGrokWebProviderResolver.providerKey(provider)
            ).streamText(messages: boxed.value, params: params) { chunk in
                let strippedChunk = citationTracker?.stripped(chunk) ?? chunk
                guard state.append(strippedChunk) else { return }
                let update = state.appendAssistantDelta(
                    from: strippedChunk,
                    collectText: collectAssistantText,
                    collectReasoning: collectAssistantReasoning
                )
                if let stage = update.stage { onAssistantStage?(stage) }
                if let reasoning = update.reasoning { onAssistantReasoning?(reasoning) }
                if let text = update.text { onAssistantText?(text) }
                Self.deliverAssistantSnapshotIfDue(
                    state: state,
                    hook: onAssistantMessageSnapshot
                )
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                state.cancel()
                task.cancel()
            }
        } catch {
            state.cancel()
            throw StreamStepFailure(underlying: error, assistant: state.assistantSnapshot())
        }
        let last = state.assistantSnapshot()
        let finalMessage: UIMessage = last?.role == MessageRole.assistant
            ? last!
            : Self.emptyAssistant()
        return MessageChunk(
            id: "",
            model: params.model.modelId,
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: finalMessage,
                finishReason: state.terminalFinishReason() ?? "stop"
            )],
            usage: nil
        )
    }

    private func streamGeminiStep(
        provider: ProviderSetting.Google,
        messages: [UIMessage],
        params: TextGenerationParams,
        citationTracker: IOSMemoryCitationTracker?,
        onAssistantStage: (@Sendable (AgentActivityStage) -> Void)?,
        onAssistantText: (@Sendable (String) -> Void)?,
        onAssistantReasoning: (@Sendable (String) -> Void)?,
        onAssistantMessageSnapshot: (@Sendable (UIMessage) -> Void)?
    ) async throws -> MessageChunk {
        let seed = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [],
            annotations: [],
            createdAt: IOSAgentToolEngine.nowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let state = StreamStepState(
            accumulator: MessageStreamAccumulator(initialMessages: [seed], model: nil)
        )
        let collectAssistantText = onAssistantText != nil
        let collectAssistantReasoning = onAssistantReasoning != nil
        let boxed = UncheckedUIMessageBox(messages)
        let task = Task { @MainActor in
            try await IOSGeminiClient(provider: provider).streamText(
                messages: boxed.value,
                params: params
            ) { chunk in
                let strippedChunk = citationTracker?.stripped(chunk) ?? chunk
                guard state.append(strippedChunk) else { return }
                let update = state.appendAssistantDelta(
                    from: strippedChunk,
                    collectText: collectAssistantText,
                    collectReasoning: collectAssistantReasoning
                )
                if let stage = update.stage {
                    onAssistantStage?(stage)
                }
                if let reasoning = update.reasoning {
                    onAssistantReasoning?(reasoning)
                }
                if let text = update.text {
                    onAssistantText?(text)
                }
                // 与 streamStep 通用路径同款:B2 前台内核投影的在途快照。
                Self.deliverAssistantSnapshotIfDue(
                    state: state,
                    hook: onAssistantMessageSnapshot
                )
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                state.cancel()
                task.cancel()
            }
        } catch {
            state.cancel()
            throw StreamStepFailure(underlying: error, assistant: state.assistantSnapshot())
        }
        let last = state.assistantSnapshot()
        let finalMessage: UIMessage = (last?.role == MessageRole.assistant) ? last! : Self.emptyAssistant()
        return MessageChunk(
            id: "",
            model: params.model.modelId,
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: finalMessage,
                finishReason: state.terminalFinishReason() ?? "stop"
            )],
            usage: nil
        )
    }

    private static func emptyAssistant() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [],
            annotations: [],
            createdAt: IOSAgentToolEngine.nowLocalDateTime(),
            finishedAt: IOSAgentToolEngine.nowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

}
