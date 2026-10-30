import Foundation

extension NovelSessionViewModel {
    func stop(reason: NovelRunInterruptionReason = .user) async {
        _ = await interruptBoundRun(reason: reason)
    }

    @discardableResult
    func interruptForRouteExit() async -> Bool {
        if binding == nil {
            await bindToCurrentSelection()
        }
        guard !isPerformingAction,
              !workspace.isPerforming || isStarting else { return false }
        if activeRunID != nil {
            guard await interruptBoundRun(reason: .routeExit) else { return false }
        }
        detachConsumer()
        return true
    }

    func interruptForBackground(deadline: Date = Date().addingTimeInterval(5)) async {
        if binding == nil {
            await bindToCurrentSelection()
        }
        guard let projectID = binding?.projectID else { return }
        let ownsSessionAction = !isPerformingAction
        let backgroundOwnerID = UUID()
        let ownsWorkspaceBusy = workspace.acquireSessionOperation(ownerID: backgroundOwnerID)
        if ownsSessionAction { isPerformingAction = true }
        defer {
            if ownsWorkspaceBusy {
                workspace.releaseSessionOperation(ownerID: backgroundOwnerID)
            }
            if ownsSessionAction { isPerformingAction = false }
        }
        let startingRunID = isStarting ? activeRunID : nil
        if let startingRunID, sessionStartingRunID == startingRunID {
            cancelledStartRunIDs.insert(startingRunID)
        }
        await workspace.interruptSessionForBackground(
            projectID: projectID,
            runID: activeRunID,
            deadline: deadline
        )
        let refreshed = await refreshDurable(binding: binding, token: bindingToken)
        if refreshed,
           let startingRunID,
           workspace.projectSnapshot?.activeRuns.contains(where: {
               $0.id == startingRunID && $0.status == .running
           }) != true {
            releaseSessionStartOwnership(runID: startingRunID)
            if transientTail?.runID == startingRunID {
                clearTransientTail()
            }
            operationErrorMessage = nil
        }
    }

    @discardableResult
    func retryLastTerminal() async -> Bool {
        guard let runID = lastRetryRunID else {
            operationErrorMessage = "没有可重试的生成，请重新发送。"
            return false
        }
        return await retryGeneration(runID: runID)
    }

    @discardableResult
    func retryGeneration(runID: NovelRunID) async -> Bool {
        guard retryingRunID == nil else { return false }
        guard !isBusy else {
            operationErrorMessage = "当前还有操作在进行，请稍候再试。"
            return false
        }
        retryingRunID = runID
        defer { retryingRunID = nil }

        guard let run = workspace.projectSnapshot?.activeRuns.first(where: {
            $0.id == runID && $0.branchID == binding?.branchID &&
                ($0.status == .failed || $0.status == .interrupted)
        }), isEligibleForExactRetry(run) else {
            if operationErrorMessage == nil {
                operationErrorMessage = "这次生成已不可精确重试（分支或检查点已变化）。请重新发送。"
            }
            return false
        }
        if run.kind == .quickStart {
            // 精确重试:从持久化的 user 消息取回本次请求原文(含用户填写的调整方向)
            // 原样重发。此前这里调的是无参版本,会退回默认文案、把调整方向静默丢掉,
            // 与 isEligibleForExactRetry 的「精确」契约相悖。取不到就退回默认行为。
            let originalUserText = workspace.branchSnapshot?.session.messages.first(where: {
                $0.runID == run.id && $0.id == run.userMessageID && $0.role == .user
            })?.content
            guard let retryRunID = await workspace.startQuickStartSuggestions(
                exactUserText: originalUserText
            ), retryRunID != runID else { return false }
            operationErrorMessage = nil
            refreshErrorMessage = nil
            lastFailure = nil
            lastRetryDraft = nil
            lastRetryRunID = nil
            await bindToCurrentSelection()
            return true
        }
        guard let draft = draft(for: run) else {
            if operationErrorMessage == nil {
                operationErrorMessage = "找不到原请求内容，请重新发送。"
            }
            return false
        }
        // Keep composer chrome aligned with the run being retried so the dock
        // does not still show "讨论" while an exact prose/polish retry starts.
        mode = draft.mode
        if let granularity = draft.granularity {
            self.granularity = granularity
        }
        let started = await start(draft, retryingRunID: runID)
        guard !started, Self.isRevisionMismatch(lastStartFailure) else { return started }

        // Retry against the current snapshot only when the first start was
        // rejected by an explicit revision mismatch. Other failures keep their
        // original error and do not trigger a refresh/replay.
        let expectedBinding = binding
        let token = bindingToken
        guard await refreshDurable(binding: expectedBinding, token: token),
              binding == expectedBinding,
              bindingToken == token,
              let refreshedRun = workspace.projectSnapshot?.activeRuns.first(where: {
                  $0.id == runID && $0.branchID == binding?.branchID &&
                      ($0.status == .failed || $0.status == .interrupted)
              }), isEligibleForExactRetry(refreshedRun),
              let refreshedDraft = self.draft(for: refreshedRun) else {
            if operationErrorMessage == nil {
                operationErrorMessage = "项目状态已变化，无法按原请求重试。请重新发送。"
            }
            return false
        }
        if refreshedDraft.mode != mode { mode = refreshedDraft.mode }
        if let granularity = refreshedDraft.granularity {
            self.granularity = granularity
        }
        let retried = await start(refreshedDraft, retryingRunID: runID)
        if !retried, operationErrorMessage == nil {
            operationErrorMessage = "项目刷新后仍无法按原请求重试。请重新发送。"
        }
        return retried
    }

    func retryPendingTerminal() async {
        guard let runID = transientTail?.runID,
              canRetryPendingTerminal,
              beginAction() else { return }
        defer { endAction() }
        do {
            try await workspace.retrySessionTerminal(runID: runID)
            operationErrorMessage = nil
            if transientTail?.runID == runID {
                updateTail(phase: .terminalAwaitingRefresh)
                terminalAwaitingRefresh = true
            }
        } catch {
            operationErrorMessage = describe(error)
        }
        _ = await refreshDurable(binding: binding, token: bindingToken)
    }


    private static func isRevisionMismatch(_ error: Error?) -> Bool {
        guard let error = error as? NovelError else { return false }
        return switch error {
        case .staleProjectRevision, .staleConfigRevision, .staleBranchHeadRevision:
            true
        default:
            false
        }
    }

    var snapshotMatchesBinding: Bool {
        guard let binding,
              workspace.selectedProjectID == binding.projectID,
              workspace.selectedBranchID == binding.branchID,
              workspace.projectSnapshot?.project.id == binding.projectID,
              workspace.branchSnapshot?.branch.id == binding.branchID else { return false }
        return true
    }

    var activeRun: NovelActiveRunRecord? {
        guard let branchID = binding?.branchID else { return nil }
        return workspace.projectSnapshot?.activeRuns.first {
            $0.branchID == branchID && $0.status == .running
        }
    }

    var boundQuickStartStartingRun: NovelActiveRunRecord? {
        guard let binding,
              workspace.quickStartStartingProjectID == binding.projectID,
              let run = workspace.quickStartStartingRun,
              run.branchID == binding.branchID else { return nil }
        return run
    }

    func isEligibleForExactRetry(_ run: NovelActiveRunRecord) -> Bool {
        guard run.branchID == binding?.branchID,
              run.status == .failed || run.status == .interrupted,
              run.status != .failed || run.terminalFailure?.isRetryable == true,
              let branch = workspace.branchSnapshot?.branch else { return false }
        if run.kind == .prose || run.kind == .polish || run.kind == .regenerate {
            guard run.baseCheckpointID == branch.headCheckpointID,
                  run.baseHeadRevision == branch.headRevision else { return false }
        }
        if run.kind == .polish || run.kind == .regenerate {
            guard let sourceID = run.sourceChapterVersionID,
                  branch.workingChapterSelections.contains(where: { $0.versionID == sourceID }),
                  let sourceVersion = workspace.projectSnapshot?.chapterVersions.first(where: {
                      $0.id == sourceID
                  }),
                  workspace.projectSnapshot?.chapters.contains(where: {
                      $0.id == sourceVersion.chapterID && $0.discardedAt == nil
                  }) == true else {
                return false
            }
        }
        return true
    }

    func candidates(kind: NovelCandidateKind) -> [NovelCandidateRecord] {
        guard let branchID = binding?.branchID else { return [] }
        return workspace.projectSnapshot?.candidates.filter {
            $0.branchID == branchID && $0.kind == kind
        } ?? []
    }

    func canStart(
        kind: NovelRunKind,
        granularity: NovelGenerationGranularity? = nil
    ) -> Bool {
        startBlockerMessage(kind: kind, granularity: granularity) == nil
    }

    /// Human-readable gate reason when generation cannot start. `nil` means open.
    func startBlockerMessage(
        kind: NovelRunKind,
        granularity: NovelGenerationGranularity? = nil,
        allowingRetryRunID: NovelRunID? = nil
    ) -> String? {
        guard snapshotMatchesBinding else {
            return "项目状态尚未对齐，请先点「重新载入」。"
        }
        guard access == .readWrite else {
            return "当前项目是只读状态，无法生成。"
        }
        if workspace.requiresReload {
            return "项目需要重新载入后才能继续生成。"
        }
        if let refreshErrorMessage {
            return refreshErrorMessage
        }
        if terminalAwaitingRefresh {
            return "上一轮结果还在保存，请稍候再试或点「重新载入」。"
        }
        let isRetryStart = allowingRetryRunID != nil && allowingRetryRunID == retryingRunID
        if isBusy && !isBatchStartingRun && !isRetryStart {
            return "当前还有操作在进行，请稍候。"
        }
        if isRunning {
            return "已有生成在进行中。"
        }
        guard let branch = workspace.branchSnapshot?.branch else {
            return "分支尚未就绪，请重新载入项目。"
        }
        guard branch.lifecycle == .active else {
            return "当前分支不可用，无法生成。"
        }
        if branch.activeRunID != nil || activeRun != nil {
            return "分支上还有未结束的生成，请稍候或重新载入。"
        }
        // Contract v1.1 D-D: forward runs are gated while later chapters'
        // plot modules are unresolved after a middle-chapter edit.
        // Discussion stays open (planning is allowed; writing is not).
        if kind != .discussion,
           workspace.branchSnapshot?.currentState.hasStaleChapterPlots == true {
            return NovelWorkspaceLedger.unresolvedPlotGateMessage
        }
        switch kind {
        case .discussion:
            return nil
        case .characterProposal:
            guard branch.syncStatus == .synchronized,
                  branchPendingOperations.isEmpty,
                  unresolvedBranchPolishTransactions.isEmpty else {
                return "请先完成剧情同步或处理未完成的操作，再继续。"
            }
            return nil
        case .prose:
            guard branch.syncStatus == .synchronized,
                  !branchPendingOperations.contains(where: \.blocksProseGeneration) else {
                return "正文生成前需要先同步剧情状态。"
            }
            if isGhostwriting && !isGhostwriteStartingRun {
                return "代笔进行中，请先暂停或等当前章完成。"
            }
            let proseGranularity = granularity ?? self.granularity
            if workspace.projectSnapshot?.project.collaborationMode == .ghostwrite,
               proseGranularity == .wholeChapter,
               workspace.projectSnapshot?.confirmedChapterPlan(for: branch.id) == nil {
                return "代笔写整章需要先确认本章计划。"
            }
            return nil
        case .regenerate:
            guard branch.syncStatus == .synchronized,
                  branchPendingOperations.isEmpty,
                  unresolvedBranchPolishTransactions.isEmpty else {
                return "重新生成前需要先同步剧情并完成未落地操作。"
            }
            return nil
        case .polish:
            guard branch.syncStatus == .synchronized,
                  branchPendingOperations.isEmpty,
                  unresolvedBranchPolishTransactions.isEmpty else {
                return "润色前需要先同步剧情并完成未落地操作。"
            }
            return nil
        case .quickStart:
            return "开局建议请从项目入口发起，不能从会话直接重试。"
        }
    }

    @discardableResult
    func start(
        _ draft: NovelSessionRunDraft,
        retryingRunID: NovelRunID? = nil
    ) async -> Bool {
        lastStartFailure = nil
        if draft.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            operationErrorMessage = "请求内容为空，请重新输入后再试。"
            return false
        }
        if draft.inputBudgetTokens <= 0 {
            operationErrorMessage = "模型输入预算无效，请检查项目模型设置后重试。"
            return false
        }
        if let blocker = startBlockerMessage(
            kind: draft.kind,
            granularity: draft.granularity,
            allowingRetryRunID: retryingRunID
        ) {
            operationErrorMessage = blocker
            return false
        }
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else {
            operationErrorMessage = "项目尚未就绪，请重新载入后再试。"
            return false
        }
        let previousTail = transientTail
        let previousRunRecord = transientRunRecord
        let previousTerminalAwaitingRefresh = terminalAwaitingRefresh
        let expectedBindingToken = bindingToken

        let candidateID: NovelCandidateID? = switch draft.kind {
        case .prose, .polish, .regenerate: NovelCandidateID()
        case .quickStart, .characterProposal, .discussion: nil
        }
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: project.project.id,
            branchID: branch.branch.id,
            kind: draft.kind,
            mode: draft.mode,
            granularity: draft.granularity,
            userText: draft.userText,
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: candidateID,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: draft.sourceChapterVersionID,
            askUserResponse: draft.askUserResponse,
            contextualCharacterMention: draft.contextualCharacterMention,
            ghostwritePlanID: draft.ghostwritePlanID,
            injectionOverrides: draft.injectionOverrides,
            inputBudgetTokens: draft.inputBudgetTokens,
            suppressRecentSessionMessages: draft.suppressRecentSessionMessages,
            expectedProjectRevision: project.project.revision,
            expectedConfigRevision: project.project.configRevision,
            expectedBranchHeadRevision: branch.branch.headRevision
        )
        guard workspace.acquireSessionOperation(ownerID: request.id.rawValue) else {
            operationErrorMessage = "当前会话正忙，请稍候再试。"
            return false
        }
        let placeholderRun = NovelActiveRunRecord(
            id: request.id,
            operationID: request.operationID,
            requestPayloadSHA256: (try? request.canonicalPayloadSHA256()) ?? "",
            branchID: request.branchID,
            sessionID: branch.session.id,
            kind: request.kind,
            mode: request.mode,
            granularity: request.granularity,
            userMessageID: request.userMessageID,
            messageID: request.assistantMessageID,
            candidateID: request.candidateID,
            sourceChapterVersionID: request.sourceChapterVersionID,
            contextualCharacterMention: request.contextualCharacterMention,
            baseCheckpointID: branch.branch.headCheckpointID,
            baseHeadRevision: branch.branch.headRevision,
            status: .running,
            partialContent: "",
            receiptID: request.generationReceiptID,
            startedAt: Date(),
            terminalAt: nil,
            interruptionReason: nil,
            terminalFailure: nil,
            chapterPlanDigest: nil,
            ghostwritePlanID: draft.ghostwritePlanID
        )
        installTail(
            run: placeholderRun,
            content: "",
            startingUserContent: draft.userText,
            phase: .waitingForFirstToken
        )
        sessionStartingRunID = request.id
        let requestID = request.id
        defer {
            releaseSessionStartOwnership(runID: requestID)
            cancelledStartRunIDs.remove(requestID)
        }
        do {
            let run = try await workspace.startSessionRun(request)
            guard !cancelledStartRunIDs.contains(request.id) else { return false }
            currentRunDraft = draft
            lastStartFailure = nil
            operationErrorMessage = nil
            refreshErrorMessage = nil
            lastFailure = nil
            lastRetryDraft = nil
            lastRetryRunID = nil
            if consumerAttachmentDesired,
               bindingToken == expectedBindingToken,
               binding?.projectID == request.projectID,
               binding?.branchID == request.branchID {
                consume(run, draft: draft, token: expectedBindingToken)
            }
            return true
        } catch {
            lastStartFailure = error
            if stoppingRunID != request.id {
                transientTail = previousTail
                transientRunRecord = previousRunRecord
                terminalAwaitingRefresh = previousTerminalAwaitingRefresh
                if let previousTail,
                   !previousTerminalAwaitingRefresh,
                   !isActiveTailPhase(previousTail.phase) {
                    // installTail cancels the old quiet-window task. If the new run
                    // fails before it starts, restore that terminal tail's retirement
                    // as well as its visible state so it can still hand off to durable.
                    retireTerminalTransientTail(runID: previousTail.runID, token: bindingToken)
                }
            }
            if cancelledStartRunIDs.contains(request.id) {
                operationErrorMessage = nil
            } else {
                operationErrorMessage = describe(error)
            }
            return false
        }
    }

    func consume(_ run: NovelRun, draft: NovelSessionRunDraft, token: UUID) {
        // installTail may already hold raw manuscript text from a restored run.
        // Replacing its subscription must preserve that matching presentation source.
        let installedBuffer: NovelSessionPresentationBuffer?
        if let tail = transientTail,
           let buffer = presentationBuffer,
           buffer.matches(runID: run.id, messageID: tail.messageID, bindingToken: token) {
            installedBuffer = buffer
        } else {
            installedBuffer = nil
        }
        clearConsumer()
        presentationBuffer = installedBuffer
        let nextConsumerID = UUID()
        consumerID = nextConsumerID
        consumerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in run.events {
                guard !Task.isCancelled, self.bindingToken == token else { return }
                await self.consume(event, runID: run.id, draft: draft, token: token)
            }
            guard self.consumerID == nextConsumerID else { return }
            self.consumerID = nil
            self.consumerTask = nil
        }
    }

    func consume(
        _ event: NovelRunEvent,
        runID: NovelRunID,
        draft: NovelSessionRunDraft,
        token: UUID
    ) async {
        guard transientTail?.runID == runID else { return }
        switch event {
        case .started:
            if draft.ghostwritePlanID != nil {
                advanceGhostwriteBackgroundProgress(by: 1)
            }
            guard let expectedBinding = binding else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.binding == expectedBinding,
                      self.bindingToken == token,
                      !self.terminalAwaitingRefresh,
                      let tail = self.transientTail,
                      tail.runID == runID,
                      self.isActiveTailPhase(tail.phase) else { return }
                let refreshed = await self.refreshDurable(
                    binding: expectedBinding,
                    token: token,
                    onlyIfRunStillActive: runID
                )
                guard refreshed,
                      self.binding == expectedBinding,
                      self.bindingToken == token,
                      !self.terminalAwaitingRefresh,
                      self.transientTail?.runID == runID else { return }
                self.adoptDurableRunRecord(runID: runID)
            }
        case .reasoningDelta(let text):
            if draft.ghostwritePlanID != nil, !text.isEmpty {
                advanceGhostwriteBackgroundProgress(by: Int64(text.utf8.count))
            }
            applyReasoningPresentation(text, runID: runID, token: token)
        case .reasoningReplacement(let text):
            if draft.ghostwritePlanID != nil, !text.isEmpty {
                advanceGhostwriteBackgroundProgress(by: Int64(text.utf8.count))
            }
            replaceReasoningPresentation(text, runID: runID, token: token)
        case .delta(let text):
            if draft.ghostwritePlanID != nil, !text.isEmpty {
                advanceGhostwriteBackgroundProgress(by: Int64(text.utf8.count))
            }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            if draft.kind == .quickStart {
                appendQuickStartStructuredDelta(text, runID: runID, token: token)
            } else if draft.kind == .characterProposal {
                appendCharacterProposalStructuredDelta(text, runID: runID, token: token)
            } else {
                enqueuePresentationDelta(text, runID: runID, token: token)
            }
        case .replaced(let text):
            if draft.ghostwritePlanID != nil, !text.isEmpty {
                advanceGhostwriteBackgroundProgress(by: Int64(text.utf8.count))
            }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            if draft.kind == .quickStart {
                replaceQuickStartStructuredContent(text, runID: runID, token: token)
            } else if draft.kind == .characterProposal {
                replaceCharacterProposalStructuredContent(text, runID: runID, token: token)
            } else {
                enqueuePresentationReplacement(text, runID: runID, token: token)
            }
        case .completed(let snapshot):
            if stoppingRunID == runID { return }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            attachAskUserIfNeeded(from: snapshot)
            guard await publishTerminalPresentation(
                runID: runID,
                token: token,
                authoritativeContent: snapshot.message.content,
                phase: .terminalAwaitingRefresh
            ) else { return }
            lastRetryDraft = nil
            lastRetryRunID = nil
            currentRunDraft = nil
            let refreshed = await refreshDurable(binding: binding, token: token)
            if refreshed { retireTerminalTransientTail(runID: runID, token: token) }
        case .interrupted(let snapshot):
            if stoppingRunID == runID { return }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            guard await publishTerminalPresentation(
                runID: runID,
                token: token,
                authoritativeContent: draft.kind == .quickStart || draft.kind == .characterProposal
                    ? ""
                    : snapshot?.message.content,
                phase: .interrupted
            ) else { return }
            lastRetryDraft = draft
            lastRetryRunID = runID
            currentRunDraft = nil
            let refreshed = await refreshDurable(binding: binding, token: token)
            if refreshed { retireTerminalTransientTail(runID: runID, token: token) }
        case .failed(let failure):
            if stoppingRunID == runID { return }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            guard await publishTerminalPresentation(
                runID: runID,
                token: token,
                authoritativeContent: draft.kind == .quickStart || draft.kind == .characterProposal
                    ? ""
                    : nil,
                phase: .failed(failure)
            ) else { return }
            lastFailure = failure
            operationErrorMessage = NovelPresentation.failureMessage(failure)
            lastRetryDraft = failure.isRetryable ? draft : nil
            lastRetryRunID = failure.isRetryable ? runID : nil
            currentRunDraft = nil
            let refreshed = await refreshDurable(binding: binding, token: token)
            if refreshed { retireTerminalTransientTail(runID: runID, token: token) }
        case .persistenceBlocked(let failure):
            if stoppingRunID == runID { return }
            markReasoningFinishedIfNeeded(runID: runID, token: token)
            guard await publishTerminalPresentation(
                runID: runID,
                token: token,
                authoritativeContent: draft.kind == .quickStart || draft.kind == .characterProposal
                    ? ""
                    : nil,
                phase: .persistenceBlocked(failure)
            ) else { return }
            terminalAwaitingRefresh = false
            lastFailure = failure
            operationErrorMessage = NovelPresentation.failureMessage(failure)
        }
    }

    func attach(to run: NovelActiveRunRecord) async {
        guard consumerAttachmentDesired else { return }
        let expectedToken = bindingToken
        if attachingRunID == run.id,
           attachingBindingToken == expectedToken {
            return
        }
        let attemptID = UUID()
        attachAttemptID = attemptID
        attachingRunID = run.id
        attachingBindingToken = expectedToken
        defer {
            if attachAttemptID == attemptID {
                attachAttemptID = nil
                attachingRunID = nil
                attachingBindingToken = nil
            }
        }
        guard let draft = draft(for: run),
              let projectID = workspace.projectSnapshot?.project.id else {
            refreshErrorMessage = "无法恢复正在生成的消息订阅。"
            return
        }
        let expectedBinding = binding
        let initialContent: String = switch run.kind {
        case .quickStart:
            NovelQuickStartStreamingPresentation.markdown(from: run.partialContent)
        case .characterProposal:
            NovelQuickStartStreamingPresentation.characterProposalMarkdown(
                from: run.partialContent
            )
        case .discussion, .prose, .polish, .regenerate:
            run.partialContent
        }
        installTail(
            run: run,
            content: initialContent,
            phase: run.partialContent.isEmpty ? .waitingForFirstToken : .streaming
        )
        do {
            let observed = try await workspace.observeSessionRun(projectID: projectID, run: run)
            guard attachAttemptID == attemptID,
                  consumerAttachmentDesired,
                  binding == expectedBinding,
                  bindingToken == expectedToken,
                  transientTail?.runID == run.id else { return }
            currentRunDraft = draft
            consume(observed, draft: draft, token: expectedToken)
        } catch {
            guard attachAttemptID == attemptID,
                  binding == expectedBinding,
                  bindingToken == expectedToken,
                  transientTail?.runID == run.id else { return }
            if case .runNotFound(let missingID) = error as? NovelError,
               missingID == run.id {
                // A detached run may finish and be pruned while this workspace
                // still holds its running snapshot. Reload the durable result
                // instead of reconstructing or restarting the old request.
                guard await refreshDurable(
                    binding: expectedBinding,
                    token: expectedToken,
                    retireTerminalTail: false
                ) else { return }
                guard attachAttemptID == attemptID,
                      consumerAttachmentDesired,
                      binding == expectedBinding,
                      bindingToken == expectedToken,
                      transientTail?.runID == run.id else { return }
                if workspace.projectSnapshot?.activeRuns.contains(where: {
                    $0.id == run.id && $0.status == .running
                }) == false,
                   workspace.branchSnapshot?.branch.activeRunID != run.id {
                    await clearTransientTailAfterDurableProjection(runID: run.id, token: expectedToken)
                    return
                }
            }
            refreshErrorMessage = describe(error)
            await clearTransientTailAfterDurableProjection(
                runID: run.id,
                token: expectedToken
            )
        }
    }

    func draft(for run: NovelActiveRunRecord) -> NovelSessionRunDraft? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let user = branch.session.messages.first(where: {
                  $0.runID == run.id && $0.id == run.userMessageID && $0.role == .user
              }), let injection = project.injectionReceipts.first(where: {
                  $0.runID == run.id
              }) else { return nil }
        // Exact retry must not re-apply Ask User. The failed run already durably
        // wrote the answer interaction; replaying askUserResponse hits
        // "already been answered" and surfaces as a generic state mismatch.
        // Re-send the same user text as a normal follow-up turn instead.
        return NovelSessionRunDraft(
            kind: run.kind,
            mode: run.mode,
            granularity: run.granularity,
            userText: user.content,
            sourceChapterVersionID: run.sourceChapterVersionID,
            askUserResponse: nil,
            injectionOverrides: NovelInjectionOverrides(
                forceIncludeMaterialIDs: injection.forceIncludeMaterialIDs,
                forceExcludeMaterialIDs: injection.forceExcludeMaterialIDs
            ),
            inputBudgetTokens: injection.requestedInputBudgetTokens,
            contextualCharacterMention: run.contextualCharacterMention,
            ghostwritePlanID: run.ghostwritePlanID
        )
    }

    private func request(
        for run: NovelActiveRunRecord,
        draft: NovelSessionRunDraft
    ) -> NovelRunRequest? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let injection = project.injectionReceipts.first(where: { $0.runID == run.id }) else {
            return nil
        }
        return NovelRunRequest(
            id: run.id,
            operationID: run.operationID,
            projectID: project.project.id,
            branchID: branch.branch.id,
            kind: run.kind,
            mode: run.mode,
            granularity: run.granularity,
            userText: draft.userText,
            userMessageID: run.userMessageID,
            assistantMessageID: run.messageID,
            candidateID: run.candidateID,
            generationReceiptID: run.receiptID,
            injectionReceiptID: injection.id,
            sourceChapterVersionID: run.sourceChapterVersionID,
            askUserResponse: draft.askUserResponse,
            contextualCharacterMention: run.contextualCharacterMention,
            ghostwritePlanID: run.ghostwritePlanID,
            injectionOverrides: draft.injectionOverrides,
            inputBudgetTokens: draft.inputBudgetTokens,
            suppressRecentSessionMessages: draft.suppressRecentSessionMessages,
            expectedProjectRevision: project.project.revision,
            expectedConfigRevision: project.project.configRevision,
            expectedBranchHeadRevision: branch.branch.headRevision
        )
    }

    @discardableResult
    func refreshDurable(
        binding expected: NovelSessionBinding?,
        token: UUID,
        onlyIfRunStillActive runID: NovelRunID? = nil,
        retireTerminalTail: Bool = true
    ) async -> Bool {
        guard let expected,
              binding == expected,
              bindingToken == token,
              workspace.selectedProjectID == expected.projectID,
              workspace.selectedBranchID == expected.branchID else { return false }
        do {
            try await workspace.refreshCurrentSelection(
                projectID: expected.projectID,
                refreshProjectList: false
            )
            guard binding == expected,
                  bindingToken == token,
                  snapshotMatchesBinding else { return false }
            if let runID {
                // A started refresh may finish after the terminal event began
                // draining. Only the terminal consumer may retire that tail.
                guard !terminalAwaitingRefresh,
                      let tail = transientTail,
                      tail.runID == runID,
                      isActiveTailPhase(tail.phase),
                      workspace.projectSnapshot?.activeRuns.first(where: {
                          $0.id == runID
                      })?.status == .running else { return false }
            }
            guard let project = workspace.projectSnapshot,
                  let branch = workspace.branchSnapshot,
                  await warmProjectionCache(
                      project: project,
                      branch: branch,
                      expandedArchiveIDs: projectionExpandedArchiveIDs
                  ),
                  binding == expected,
                  bindingToken == token,
                  snapshotMatchesBinding else { return false }
            if let runID {
                guard !terminalAwaitingRefresh,
                      transientTail?.runID == runID,
                      workspace.projectSnapshot?.activeRuns.first(where: {
                          $0.id == runID
                      })?.status == .running else { return false }
            }
            refreshErrorMessage = nil
            hydrateTerminalState()
            if retireTerminalTail,
               terminalAwaitingRefresh,
               let tail = transientTail,
               workspace.projectSnapshot?.activeRuns.first(where: { $0.id == tail.runID })?.status != .running {
                retireTerminalTransientTail(runID: tail.runID, token: token)
            } else if retireTerminalTail,
                      terminalAwaitingRefresh,
                      transientTail == nil,
                      workspace.branchSnapshot?.branch.activeRunID == nil {
                terminalAwaitingRefresh = false
            }
            return true
        } catch {
            guard bindingToken == token else { return false }
            refreshErrorMessage = describe(error)
            return false
        }
    }

    func hydrateTerminalState() {
        guard let branchID = binding?.branchID,
              let runs = workspace.projectSnapshot?.activeRuns.filter({ $0.branchID == branchID }) else {
            return
        }
        guard let latest = runs.max(by: { $0.startedAt < $1.startedAt }) else {
            updateTerminalState(draft: nil, runID: nil, failure: nil)
            return
        }
        switch latest.status {
        case .failed:
            let retryDraft = latest.terminalFailure?.isRetryable == true ? draft(for: latest) : nil
            updateTerminalState(
                draft: retryDraft,
                runID: retryDraft == nil ? nil : latest.id,
                failure: latest.terminalFailure
            )
        case .interrupted:
            let retryDraft = draft(for: latest)
            updateTerminalState(
                draft: retryDraft,
                runID: retryDraft == nil ? nil : latest.id,
                failure: latest.terminalFailure
            )
        case .running, .completed:
            updateTerminalState(draft: nil, runID: nil, failure: latest.terminalFailure)
        }
    }

    private func updateTerminalState(
        draft: NovelSessionRunDraft?,
        runID: NovelRunID?,
        failure: NovelFailure?
    ) {
        if lastRetryDraft != draft { lastRetryDraft = draft }
        if lastRetryRunID != runID { lastRetryRunID = runID }
        if lastFailure != failure { lastFailure = failure }
    }

    func applyPolishAdoption(_ command: NovelAdoptPolishCandidateCommand) async {
        _ = await perform(.adoptPolishCandidate(command))
    }

    @discardableResult
    func perform(_ action: NovelAction) async -> NovelOutcome? {
        guard beginAction() else { return nil }
        defer { endAction() }
        let outcome: NovelOutcome?
        do {
            outcome = try await workspace.performSessionAction(action)
            operationErrorMessage = nil
        } catch {
            outcome = nil
            operationErrorMessage = describe(error)
        }
        _ = await refreshDurable(binding: binding, token: bindingToken)
        return outcome
    }

    func beginAction() -> Bool {
        guard !isPerformingAction,
              !workspace.requiresReload else { return false }
        let ownerID = UUID()
        guard workspace.acquireSessionOperation(ownerID: ownerID) else { return false }
        sessionActionOwnerID = ownerID
        isPerformingAction = true
        return true
    }

    func endAction() {
        if let ownerID = sessionActionOwnerID {
            workspace.releaseSessionOperation(ownerID: ownerID)
            sessionActionOwnerID = nil
        }
        isPerformingAction = false
    }

    func mutationContext(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot
    ) -> NovelMutationContext {
        NovelMutationContext(
            operationID: NovelOperationID(),
            expectedProjectRevision: project.project.revision,
            expectedConfigRevision: project.project.configRevision,
            expectedBranchHeadRevision: branch.branch.headRevision
        )
    }

    /// Presentation-only thinking stream. Never touches manuscript presentation buffer.
    ///
    /// 48ms 拍节流（与正文 presentationFlush 同源）：chunk 先并入 pendingReasoningText
    /// （按既有前缀去重语义累积），每拍一次合并进 row.reasoningContent。终态/正文切换
    /// 前由 markReasoningFinishedIfNeeded 同步收口最后一段思考——presentation 延迟
    /// ≤48ms，lifecycle broadcast 语义与 storage 均不变。

    func interruptBoundRun(
        reason: NovelRunInterruptionReason,
        runID explicitRunID: NovelRunID? = nil
    ) async -> Bool {
        guard let bound = binding,
              let runID = explicitRunID ?? activeRunID else { return true }
        let token = bindingToken
        if reason == .user, stoppingRunID == runID { return false }
        guard !isPerformingAction,
              !workspace.isPerforming || isStarting else { return false }
        let isCancellingSessionStart = sessionStartingRunID == runID
        let isCancellingQuickStart = boundQuickStartStartingRun?.id == runID
        let actionOwnerID: UUID?
        if isCancellingSessionStart || isCancellingQuickStart {
            actionOwnerID = nil
        } else {
            let ownerID = UUID()
            guard workspace.acquireSessionOperation(ownerID: ownerID) else { return false }
            actionOwnerID = ownerID
        }
        if isCancellingSessionStart {
            cancelledStartRunIDs.insert(runID)
        }
        isPerformingAction = true
        let isUserStop = reason == .user
        if isUserStop {
            stoppingRunID = runID
            terminalAwaitingRefresh = true
            pausePresentationForStop()
            if transientTail?.runID == runID {
                updateTail(phase: .interrupted)
            }
        }
        defer {
            if let actionOwnerID {
                workspace.releaseSessionOperation(ownerID: actionOwnerID)
            }
            isPerformingAction = false
        }
        let command = NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: bound.projectID,
            runID: runID,
            reason: reason
        )
        do {
            try await workspace.interruptSessionRun(command)
            operationErrorMessage = nil
            if isCancellingSessionStart {
                releaseSessionStartOwnership(runID: runID)
            }
        } catch {
            operationErrorMessage = describe(error)
            if isCancellingSessionStart {
                cancelledStartRunIDs.remove(runID)
            }
            if isUserStop {
                let refreshed = await refreshDurable(
                    binding: bound,
                    token: token,
                    retireTerminalTail: false
                )
                guard binding == bound, bindingToken == token else { return false }
                let remainsRunning = refreshed &&
                    workspace.projectSnapshot?.activeRuns.contains(where: {
                        $0.id == runID && $0.status == .running
                    }) == true
                if remainsRunning {
                    resumePresentationAfterFailedStop(runID: runID)
                    if consumerTask == nil, let activeRun {
                        await attach(to: activeRun)
                    }
                } else if refreshed {
                    return await finishStoppedRunPresentation(runID: runID, token: token)
                } else {
                    resumePresentationAfterFailedStop(runID: runID)
                    if consumerTask == nil, let activeRun {
                        await attach(to: activeRun)
                    }
                }
            } else if isCancellingSessionStart {
                _ = await refreshDurable(binding: bound, token: bindingToken)
                await bindToCurrentSelection()
            }
            return false
        }
        if !isUserStop, transientTail?.runID == runID {
            clearTransientTail()
        }
        if isUserStop {
            guard binding == bound, bindingToken == token else { return false }
            let refreshed = await refreshDurable(
                binding: bound,
                token: token,
                retireTerminalTail: false
            )
            guard binding == bound, bindingToken == token else { return false }
            let runIsTerminal = workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) != true
            if refreshed,
               runIsTerminal,
               workspace.branchSnapshot?.branch.activeRunID == nil {
                return await finishStoppedRunPresentation(runID: runID, token: token)
            }
            if refreshed {
                resumePresentationAfterFailedStop(runID: runID)
                if operationErrorMessage == nil {
                    operationErrorMessage = "生成仍在运行，请稍候后重试停止。"
                }
            } else {
                stoppingRunID = nil
            }
            return false
        }
        currentRunDraft = nil
        guard snapshotMatchesBinding else { return true }
        let refreshed = await refreshDurable(binding: bound, token: bindingToken)
        return refreshed &&
            workspace.branchSnapshot?.branch.activeRunID == nil &&
            workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) != true
    }

    private func finishStoppedRunPresentation(runID: NovelRunID, token: UUID) async -> Bool {
        guard bindingToken == token,
              let run = workspace.projectSnapshot?.activeRuns.first(where: { $0.id == runID }),
              run.status != .running,
              workspace.branchSnapshot?.branch.activeRunID == nil else { return false }
        let durableContent: String = switch run.kind {
        case .quickStart:
            NovelQuickStartStreamingPresentation.markdown(from: run.partialContent)
        case .characterProposal:
            NovelQuickStartStreamingPresentation.characterProposalMarkdown(from: run.partialContent)
        case .discussion, .prose, .regenerate, .polish:
            workspace.branchSnapshot?.session.messages.first(where: {
                $0.id == run.messageID
            })?.content ?? run.partialContent
        }
        if transientTail?.runID == runID {
            guard await publishTerminalPresentation(
                runID: runID,
                token: token,
                authoritativeContent: durableContent,
                phase: .interrupted
            ) else { return false }
        }
        guard bindingToken == token else { return false }
        currentRunDraft = nil
        stoppingRunID = nil
        operationErrorMessage = nil
        retireTerminalTransientTail(runID: runID, token: token)
        return true
    }

    private func pausePresentationForStop() {
        presentationFlushTask?.cancel()
        presentationFlushTask = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        reasoningFlushToken = UUID()
    }

    private func resumePresentationAfterFailedStop(runID: NovelRunID) {
        guard transientTail?.runID == runID else {
            stoppingRunID = nil
            terminalAwaitingRefresh = false
            return
        }
        stoppingRunID = nil
        terminalAwaitingRefresh = false
        let tail = transientTail
        updateTail(phase: tail?.content.isEmpty == true ? .waitingForFirstToken : .streaming)
        if let tail, let buffer = presentationBuffer,
           buffer.matches(
               runID: runID,
               messageID: tail.messageID,
               bindingToken: bindingToken
           ), buffer.displayedCharacterCount < buffer.targetCharacterCount {
            schedulePresentationFlush(
                runID: runID,
                messageID: tail.messageID,
                token: bindingToken
            )
        } else if quickStartStructuredPresentationDirty || characterProposalStructuredPresentationDirty {
            scheduleStructuredPresentationFlush(runID: runID, token: bindingToken)
        }
        if pendingReasoningText != nil {
            scheduleReasoningFlush(runID: runID, token: bindingToken)
        }
    }

    private func releaseSessionStartOwnership(runID: NovelRunID) {
        if sessionStartingRunID == runID {
            sessionStartingRunID = nil
        }
        workspace.releaseSessionOperation(ownerID: runID.rawValue)
    }

    func resetBinding() async {
        await cancelPolishRetryForBindingChange(from: binding)
        await cancelBatchPolishForBindingChange(from: binding)
        await cancelGhostwriteForBindingChange(from: binding)
        detachConsumer()
        cancelProjectionBuild()
        bindingToken = UUID()
        binding = nil
        stoppingRunID = nil
        retryingRunID = nil
        cloningCandidateID = nil
        undoingCheckpointID = nil
        clearTransientTail()
        currentRunDraft = nil
        lastRetryDraft = nil
        lastRetryRunID = nil
        advanceLoadStage(to: .idle)
        projectionCache = nil
        locallyResolvedAskUser = [:]
    }

    func cancelPolishRetryForBindingChange(
        from expectedBinding: NovelSessionBinding?
    ) async {
        guard let expectedBinding,
              polishRetryTaskBinding == expectedBinding,
              let task = polishRetryTask else { return }
        task.cancel()
        await task.value
    }

    func describe(_ error: Error) -> String {
        NovelPresentation.operationErrorMessage(error)
    }
}
