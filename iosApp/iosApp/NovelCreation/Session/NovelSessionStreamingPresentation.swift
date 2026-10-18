import Foundation

extension NovelSessionViewModel {
    func applyReasoningPresentation(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard !text.isEmpty,
              bindingToken == token,
              let current = transientTail,
              current.runID == runID else { return }
        pendingReasoningText = (pendingReasoningText ?? current.reasoningContent) + text
        scheduleReasoningFlush(runID: runID, token: token)
    }

    func replaceReasoningPresentation(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard bindingToken == token,
              transientTail?.runID == runID else { return }
        pendingReasoningText = text
        scheduleReasoningFlush(runID: runID, token: token)
    }

    func markReasoningFinishedIfNeeded(runID: NovelRunID, token: UUID) {
        guard bindingToken == token,
              let current = transientTail,
              current.runID == runID else { return }
        reasoningClosedAfterVisibleOutput = true
        // 即使卡片已经不是直播态，也要把尚未发布的思考尾巴同步合进去。
        // 否则正文之后再来的 reasoning delta 会停在 pending 里，complete 时被丢掉。
        guard current.isReasoningLive || pendingReasoningText != nil else { return }
        flushPendingReasoning(runID: runID, token: token, finishing: true)
    }

    func scheduleReasoningFlush(runID: NovelRunID, token: UUID) {
        guard reasoningFlushTask == nil, stoppingRunID != runID else { return }
        let flushToken = UUID()
        reasoningFlushToken = flushToken
        reasoningFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.presentationFlushDelayNanos)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.reasoningFlushToken == flushToken else { return }
            self.reasoningFlushTask = nil
            self.flushPendingReasoning(runID: runID, token: token, finishing: false)
        }
    }

    /// 一拍合并：pendingReasoningText 与当前 tail 合并为一次可见发布。
    /// finishing=true 时（终态/正文切换）同步收口并在同一拍翻转 isReasoningLive=false。
    func flushPendingReasoning(
        runID: NovelRunID,
        token: UUID,
        finishing: Bool
    ) {
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        guard bindingToken == token,
              stoppingRunID != runID,
              let current = transientTail,
              current.runID == runID else { return }
        if isTailPresentationSuspended, !finishing { return }
        let pending = pendingReasoningText
        pendingReasoningText = nil
        if pending == nil, !finishing { return }
        let merged = pending ?? current.reasoningContent
        let nextLive = finishing || reasoningClosedAfterVisibleOutput
            ? false
            : current.content.isEmpty
        guard merged != current.reasoningContent || current.isReasoningLive != nextLive else { return }
        // Promote waiting placeholder once thinking is visible.
        let nextPhase: NovelSessionTransientTailPhase =
            current.phase == .waitingForFirstToken ? .streaming : current.phase
        transientTail = current.updating(
            content: current.content,
            renderRevision: current.renderRevision &+ 1,
            phase: nextPhase,
            reasoningContent: merged,
            isReasoningLive: nextLive
        )
    }

    func enqueuePresentationDelta(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard !text.isEmpty,
              let current = transientTail,
              current.runID == runID,
              bindingToken == token else { return }
        preparePresentationBuffer(for: current, token: token)
        presentationBuffer?.append(text)
        normalizePresentationBufferIfNeeded(runKind: transientRunRecord?.kind)
        schedulePresentationFlush(
            runID: runID,
            messageID: current.messageID,
            token: token
        )
    }

    func enqueuePresentationReplacement(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard let current = transientTail,
              current.runID == runID,
              bindingToken == token else { return }
        preparePresentationBuffer(for: current, token: token)
        presentationBuffer?.replace(with: text)
        normalizePresentationBufferIfNeeded(runKind: transientRunRecord?.kind)
        schedulePresentationFlush(
            runID: runID,
            messageID: current.messageID,
            token: token
        )
    }

    /// Keep buffer target in the same form the bubble displays for manuscript kinds.
    private func normalizePresentationBufferIfNeeded(runKind: NovelRunKind?) {
        guard var buffer = presentationBuffer else { return }
        let normalized = NovelSessionPresentationPacer.presentationContent(
            buffer.rawContent,
            runKind: runKind
        )
        guard normalized != buffer.targetContent else { return }
        buffer.replacePresentationTarget(with: normalized)
        presentationBuffer = buffer
    }

    private func preparePresentationBuffer(
        for tail: NovelSessionTransientTail,
        token: UUID
    ) {
        guard presentationBuffer?.matches(
            runID: tail.runID,
            messageID: tail.messageID,
            bindingToken: token
        ) != true else { return }
        cancelPendingPresentation()
        presentationBuffer = NovelSessionPresentationBuffer(
            runID: tail.runID,
            messageID: tail.messageID,
            bindingToken: token,
            baseContent: tail.content
        )
    }

    func schedulePresentationFlush(
        runID: NovelRunID,
        messageID: NovelMessageID,
        token: UUID
    ) {
        guard presentationFlushTask == nil, stoppingRunID != runID else { return }
        presentationFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.presentationFlushDelayNanos)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.presentationFlushTask = nil
            self.flushPendingPresentation(
                runID: runID,
                messageID: messageID,
                token: token
            )
        }
    }

    func flushPendingPresentation(
        runID: NovelRunID,
        messageID: NovelMessageID,
        token: UUID
    ) {
        guard bindingToken == token,
              stoppingRunID != runID,
              let current = transientTail,
              current.runID == runID,
              current.messageID == messageID else {
            cancelPendingPresentation()
            return
        }
        if isTailPresentationSuspended {
            // 屏外：只推进节拍游标，不解析结构化输出、不写 transientTail。
            if var buffer = presentationBuffer,
               buffer.matches(runID: runID, messageID: messageID, bindingToken: token) {
                let step = buffer.step()
                presentationBuffer = buffer
                if !step.isCaughtUp {
                    schedulePresentationFlush(runID: runID, messageID: messageID, token: token)
                }
            }
            return
        }
        publishDirtyStructuredPresentation(for: current, token: token)
        guard var buffer = presentationBuffer,
              buffer.matches(runID: runID, messageID: messageID, bindingToken: token) else {
            return
        }
        let step = buffer.step()
        presentationBuffer = buffer
        if step.content != current.content || current.phase != .streaming {
            updateTail(content: step.content, phase: .streaming)
        }
        // Keep a caught-up cursor so the next delta can append at its existing
        // target index instead of rebuilding counts and grapheme positions.
        if !step.isCaughtUp {
            // Keep absolute target and keep draining on the 48ms clock.
            schedulePresentationFlush(
                runID: runID,
                messageID: messageID,
                token: token
            )
        }
    }

    private func publishQuickStartStreamingPhaseIfNeeded(
        runID: NovelRunID,
        token: UUID
    ) {
        guard bindingToken == token,
              let current = transientTail,
              current.runID == runID else { return }
        presentationBuffer = nil
        guard current.phase != .streaming || !current.content.isEmpty else { return }
        updateTail(content: "", phase: .streaming)
    }

    func appendQuickStartStructuredDelta(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard !text.isEmpty,
              bindingToken == token,
              transientTail?.runID == runID else { return }
        quickStartStructuredContent = (quickStartStructuredContent ?? "") + text
        quickStartStructuredPresentationDirty = true
        scheduleStructuredPresentationFlush(runID: runID, token: token)
    }

    func replaceQuickStartStructuredContent(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard bindingToken == token,
              transientTail?.runID == runID else { return }
        quickStartStructuredContent = text
        quickStartStructuredPresentationDirty = true
        scheduleStructuredPresentationFlush(runID: runID, token: token)
    }

    func appendCharacterProposalStructuredDelta(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard transientTail?.runID == runID, bindingToken == token else { return }
        characterProposalStructuredContent = (characterProposalStructuredContent ?? "") + text
        characterProposalStructuredPresentationDirty = true
        scheduleStructuredPresentationFlush(runID: runID, token: token)
    }

    func replaceCharacterProposalStructuredContent(
        _ text: String,
        runID: NovelRunID,
        token: UUID
    ) {
        guard transientTail?.runID == runID, bindingToken == token else { return }
        characterProposalStructuredContent = text
        characterProposalStructuredPresentationDirty = true
        scheduleStructuredPresentationFlush(runID: runID, token: token)
    }

    func scheduleStructuredPresentationFlush(runID: NovelRunID, token: UUID) {
        guard let current = transientTail, current.runID == runID else { return }
        schedulePresentationFlush(runID: runID, messageID: current.messageID, token: token)
    }

    private func publishDirtyStructuredPresentation(
        for current: NovelSessionTransientTail,
        token: UUID
    ) {
        if quickStartStructuredPresentationDirty, transientRunRecord?.kind == .quickStart {
            quickStartStructuredPresentationDirty = false
            let markdown = NovelQuickStartStreamingPresentation.markdown(
                from: quickStartStructuredContent ?? ""
            )
            if markdown.isEmpty {
                publishQuickStartStreamingPhaseIfNeeded(runID: current.runID, token: token)
            } else {
                preparePresentationBuffer(for: current, token: token)
                presentationBuffer?.replace(with: markdown)
            }
        } else if characterProposalStructuredPresentationDirty,
                  transientRunRecord?.kind == .characterProposal {
            characterProposalStructuredPresentationDirty = false
            let markdown = NovelQuickStartStreamingPresentation.characterProposalMarkdown(
                from: characterProposalStructuredContent ?? ""
            )
            preparePresentationBuffer(for: current, token: token)
            presentationBuffer?.replace(with: markdown)
        }
    }

    func publishTerminalPresentation(
        runID: NovelRunID,
        token: UUID,
        authoritativeContent: String?,
        phase: NovelSessionTransientTailPhase
    ) async -> Bool {
        presentationFlushTask?.cancel()
        presentationFlushTask = nil
        quickStartStructuredPresentationDirty = false
        characterProposalStructuredPresentationDirty = false
        guard bindingToken == token,
              let current = transientTail,
              current.runID == runID else {
            presentationBuffer = nil
            return false
        }
        let bufferedContent: String?
        if let buffer = presentationBuffer,
           buffer.matches(
               runID: runID,
               messageID: current.messageID,
               bindingToken: token
        ) {
            bufferedContent = buffer.rawContent
        } else {
            bufferedContent = nil
        }
        presentationBuffer = nil
        let rawTarget = authoritativeContent ?? bufferedContent ?? current.content
        let targetContent = NovelSessionPresentationPacer.presentationContent(
            rawTarget,
            runKind: transientRunRecord?.kind
        )
        terminalAwaitingRefresh = true
        var didPublishTerminal = false
        defer {
            if !didPublishTerminal,
               bindingToken == token,
               transientTail?.runID == runID {
                terminalAwaitingRefresh = false
            }
        }

        // 与标准 Chat 的终态语义一致：complete/error/cancel 到达时，模型全文可能
        // 已领先可见文本很多拍。不能绕过 pacer 一次发布全部积压，否则正文高度会在
        // 单帧暴涨，滚动驱动只能随后追赶。先按 Chat 同源终态连续曲线逐拍追平，
        // 再切终态和刷新 durable（完成时积压一次定锚，不逐拍衰减回慢节拍）。
        // 每拍随剩余积压透出 lagAllowance（1→0 连续衰减）：driver 据此收紧跟随
        // 时间常数（τ_eff = τ × allowance），最后一拍前视口已贴回底部——完成瞬间
        // 的钉底不再需要一次性清掉跟随滞后（与 Chat 的 ChatMessageUpdateSignal.
        // lagAllowance 同源，复用 StreamPresentationPacingPolicy.lagAllowance）。
        let initialBase = NovelSessionPresentationPacer.terminalPacingBase(
            displayedContent: current.content,
            targetContent: targetContent,
            runKind: transientRunRecord?.kind
        )
        var terminalCursor = NovelSessionPresentationPacer.Cursor(
            displayedContent: initialBase,
            targetContent: targetContent
        )
        let initialBacklog = terminalCursor.terminalDrainStartBacklog
        let drainAdvance = NovelSessionPresentationPacer.terminalDrainAdvance(
            backlogCount: initialBacklog
        )
        while !Task.isCancelled,
              bindingToken == token,
              let visibleTail = transientTail,
              visibleTail.runID == runID {
            let step = terminalCursor.step(
                mode: .terminalDrain,
                fixedTerminalAdvance: drainAdvance
            )
            if step.isCaughtUp {
                if step.content != visibleTail.content || visibleTail.phase != phase {
                    updateTail(content: step.content, phase: phase)
                }
                didPublishTerminal = true
                return true
            }
            let remainingBacklog = terminalCursor.backlogCount
            let allowance = StreamPresentationPacingPolicy.lagAllowance(
                remainingBacklog: remainingBacklog,
                drainStartBacklog: initialBacklog
            )
            updateTail(content: step.content, phase: .streaming, lagAllowance: allowance)
            do {
                // 拍间隔跟随优雅尾的实际拍速逐拍重算（8ms 连续放宽到 48ms），
                // 不能用完成时的锚速定值——否则末段减速拍被 8ms 压缩、尾拍仍砸。
                let beatAdvance = StreamPresentationPacingPolicy.terminalTextAdvance(
                    backlogCount: remainingBacklog,
                    fixedAdvance: drainAdvance
                )
                try await Task.sleep(
                    nanoseconds: NovelSessionPresentationPacer.terminalDrainDelayNanos(
                        advance: beatAdvance
                    )
                )
            } catch {
                return false
            }
        }
        return false
    }

    /// 清空全部「尚未发布的呈现工作」：正文 presentation buffer 与思考流 pending。
    /// 思考流的 finish 收口走 markReasoningFinishedIfNeeded（同一拍合并+翻转 live），
    /// 这里只处理 run 边界（install/terminal/clear）与 buffer 失效路径。
    func cancelPendingPresentation() {
        presentationFlushTask?.cancel()
        presentationFlushTask = nil
        presentationBuffer = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        reasoningFlushToken = UUID()
        pendingReasoningText = nil
    }

    func installTail(
        run: NovelActiveRunRecord,
        content: String,
        renderRevision: UInt64 = 0,
        startingUserContent: String? = nil,
        phase: NovelSessionTransientTailPhase
    ) {
        let nextRenderRevision: UInt64
        if let previous = transientTail,
           previous.runID == run.id,
           previous.messageID == run.messageID {
            nextRenderRevision = max(renderRevision, previous.renderRevision &+ 1)
        } else {
            nextRenderRevision = renderRevision
        }
        // 新 run 开始:取消上一场可能仍在静窗里等待的 tail 退役任务。
        terminalTailRetirementTask?.cancel()
        terminalTailRetirementTask = nil
        cancelPendingPresentation()
        reasoningClosedAfterVisibleOutput = false
        quickStartStructuredContent = run.kind == .quickStart ? run.partialContent : nil
        characterProposalStructuredContent = run.kind == .characterProposal
            ? run.partialContent
            : nil
        quickStartStructuredPresentationDirty = false
        characterProposalStructuredPresentationDirty = false
        transientRunRecord = run
        let presentationContent = NovelSessionPresentationPacer.presentationContent(content, runKind: run.kind)
        transientTail = NovelSessionTransientTail(
            run: run,
            content: presentationContent,
            renderRevision: nextRenderRevision,
            startingUserContent: startingUserContent,
            phase: phase
        )
        if !content.isEmpty, run.kind == .prose || run.kind == .polish || run.kind == .regenerate {
            presentationBuffer = NovelSessionPresentationBuffer(
                runID: run.id,
                messageID: run.messageID,
                bindingToken: bindingToken,
                baseContent: presentationContent,
                rawContent: content
            )
        }
        terminalAwaitingRefresh = false
    }

    func updateTail(
        content: String? = nil,
        phase: NovelSessionTransientTailPhase? = nil,
        lagAllowance: Double? = nil
    ) {
        guard let current = transientTail else { return }
        transientTail = current.updating(
            content: content ?? current.content,
            phase: phase ?? current.phase,
            lagAllowance: lagAllowance
        )
    }

    /// The live tail hides the durable message with the same id, so Ask User /
    /// 审批卡 from the completed snapshot must ride on the tail until retire.
    func attachAskUserIfNeeded(from snapshot: NovelSessionMessageSnapshot) {
        guard let current = transientTail,
              current.messageID == snapshot.message.id,
              case .some(.askUser(let prompt)) = snapshot.message.interaction else {
            return
        }
        let presentation = NovelAskUserPresentation(prompt: prompt, response: nil)
        guard current.askUser != presentation else { return }
        transientTail = current.updating(
            content: current.content,
            renderRevision: current.renderRevision &+ 1,
            phase: current.phase,
            askUser: presentation
        )
    }

    func adoptDurableRunRecord(runID: NovelRunID) {
        guard let durable = workspace.projectSnapshot?.activeRuns.first(where: { $0.id == runID }),
              let current = transientTail else { return }
        transientRunRecord = durable
        transientTail = NovelSessionTransientTail(
            run: durable,
            content: current.content,
            renderRevision: current.renderRevision,
            startingUserContent: current.startingUserContent,
            phase: current.phase,
            reasoningContent: current.reasoningContent,
            isReasoningLive: current.isReasoningLive
        )
    }

    func clearTransientTail() {
        terminalTailRetirementTask?.cancel()
        terminalTailRetirementTask = nil
        cancelPendingPresentation()
        reasoningClosedAfterVisibleOutput = false
        quickStartStructuredContent = nil
        characterProposalStructuredContent = nil
        quickStartStructuredPresentationDirty = false
        characterProposalStructuredPresentationDirty = false
        transientTail = nil
        transientRunRecord = nil
        stoppingRunID = nil
        terminalAwaitingRefresh = false
    }

    func clearTransientTailAfterDurableProjection(
        runID: NovelRunID,
        token: UUID
    ) async {
        guard let expected = binding,
              bindingToken == token,
              transientTail?.runID == runID,
              snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return }
        // Batch/ghostwrite cleanup also runs from cancelled tasks. Keep the
        // durable handoff alive after that caller is cancelled.
        let warmed = await Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.warmProjectionCache(
                  project: project,
                  branch: branch,
                  expandedArchiveIDs: self.projectionExpandedArchiveIDs
            )
        }.value
        guard warmed,
              binding == expected,
              bindingToken == token,
              transientTail?.runID == runID else { return }
        clearTransientTail()
    }

    /// 终态(完成/中断/失败)且 durable 刷新成功后的 tail 退役:不立即清空,而是保留到
    /// 静窗(与底部跟随 terminalQuietDelay 对齐)过去再退役,避免生成完成、durable 正文
    /// 接管的一瞬间 tail 突然消失导致整屏「跳一下」的闪烁。输入区立即解锁
    /// (terminalAwaitingRefresh=false)——tail 的终态 phase 本身仍把 isRunning 置假,
    /// 不会误判为还在生成。静窗内若开新 run(installTail)或切 binding,退役任务会被取消。
    func retireTerminalTransientTail(runID: NovelRunID, token: UUID) {
        terminalAwaitingRefresh = false
        terminalTailRetirementTask?.cancel()
        guard terminalQuietDelay > 0 else {
            // 零静窗(测试快路径):立即退役,保持旧的「完成即清空」契约。
            if bindingToken == token, transientTail?.runID == runID {
                clearTransientTail()
            }
            return
        }
        let delayNanos = UInt64(terminalQuietDelay * 1_000_000_000)
        terminalTailRetirementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled, let self,
                  self.bindingToken == token,
                  self.transientTail?.runID == runID else { return }
            self.clearTransientTail()
        }
    }

    func isActiveTailPhase(_ phase: NovelSessionTransientTailPhase?) -> Bool {
        return switch phase {
        case .waitingForFirstToken, .streaming: true
        case .persistenceBlocked, .terminalAwaitingRefresh, .interrupted, .failed, nil: false
        }
    }

}
