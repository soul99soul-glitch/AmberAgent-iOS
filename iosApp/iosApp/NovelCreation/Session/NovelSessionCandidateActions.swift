import Foundation

extension NovelSessionViewModel {
    func candidate(id: NovelCandidateID) -> NovelCandidateRecord? {
        guard let branchID = binding?.branchID else { return nil }
        return workspace.projectSnapshot?.candidates.first {
            $0.id == id && $0.branchID == branchID
        }
    }

    func collectionGranularity(for candidateID: NovelCandidateID) -> NovelGenerationGranularity {
        guard let project = workspace.projectSnapshot else { return granularity }
        if let direct = project.activeRuns.first(where: { $0.candidateID == candidateID })?.granularity {
            return direct
        }
        guard let candidate = project.candidates.first(where: { $0.id == candidateID }) else {
            return project.project.lastGenerationGranularity
        }
        let sourceRunID = project.sessions
            .first(where: { $0.id == candidate.sessionID })?
            .messages
            .first(where: { $0.id == candidate.sourceMessageID })?
            .runID
        if let sourceRunID,
           let sourceGranularity = project.activeRuns.first(where: {
               $0.id == sourceRunID
           })?.granularity {
            return sourceGranularity
        }
        if let sourceCandidateID = candidate.clonedFromCandidateID,
           let sourceGranularity = project.activeRuns.first(where: {
               $0.candidateID == sourceCandidateID
           })?.granularity {
            return sourceGranularity
        }
        return project.project.lastGenerationGranularity
    }

    func paragraphs(candidateID: NovelCandidateID) -> [NovelParagraphRecord] {
        guard let candidate = candidate(id: candidateID) else { return [] }
        return NovelParagraphParser.paragraphs(in: candidate.content)
    }

    @discardableResult
    func collectCandidate(
        _ candidateID: NovelCandidateID,
        selection: NovelParagraphSelection,
        target: NovelCollectionTarget,
        source: NovelCollectionSource = .user
    ) async -> Bool {
        guard snapshotMatchesBinding else {
            operationErrorMessage = "会话已切换，无法收录。"
            return false
        }
        guard workspace.projectSnapshot != nil,
              let currentBranch = workspace.branchSnapshot else {
            operationErrorMessage = "项目未就绪，无法收录。"
            return false
        }
        guard let candidate = candidate(id: candidateID),
              candidate.kind == .prose,
              candidate.status == .available || candidate.status == .interrupted else {
            operationErrorMessage = "没有可收录的完整正文候选。"
            return false
        }
        if !branchPendingOperations.isEmpty || !unresolvedBranchPolishTransactions.isEmpty {
            operationErrorMessage = "仍有未完成的同步、正文或润色事务，无法收录。"
            return false
        }
        let pointerOnlyRelink = currentBranch.branch.syncStatus == .needsSync &&
            NovelWorkspaceLedger.isPointerOnlyRelink(
                branch: currentBranch.branch,
                checkpoints: workspace.projectSnapshot?.checkpoints ?? []
            )
        guard currentBranch.branch.syncStatus == .synchronized || pointerOnlyRelink else {
            operationErrorMessage = "剧情状态尚未按最新正文同步，无法收录。"
            return false
        }
        guard currentBranch.branch.activeRunID == nil else {
            operationErrorMessage = "生成尚未完全结束，无法收录。"
            return false
        }
        do {
            _ = try NovelParagraphParser.selectedText(for: selection, in: candidate.content)
        } catch {
            operationErrorMessage = describe(error)
            return false
        }
        if pointerOnlyRelink {
            await workspace.finishPlotRelinkIfNeeded()
        }
        // beginAction 失败时 perform 会静默返回 nil，这里先占锁并给出明确原因。
        guard beginAction() else {
            operationErrorMessage = workspace.requiresReload
                ? "项目需要重新载入，无法收录。"
                : "有其他操作进行中，无法收录。"
            return false
        }
        guard snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let candidate = self.candidate(id: candidateID),
              candidate.kind == .prose,
              candidate.status == .available || candidate.status == .interrupted,
              branch.branch.syncStatus == .synchronized else {
            endAction()
            operationErrorMessage = "收录前项目状态已变化，请重试。"
            return false
        }
        if workspace.projectSnapshot?.pendingOperations.contains(where: {
            $0.branchID == branch.branch.id
        }) == true {
            endAction()
            operationErrorMessage = "仍有未完成的同步或正文事务，无法收录。"
            return false
        }
        let action = NovelAction.collectCandidate(NovelCollectCandidateCommand(
            context: mutationContext(project: project, branch: branch),
            projectID: project.project.id,
            branchID: branch.branch.id,
            pendingID: NovelPendingOperationID(),
            candidateID: candidate.id,
            selection: selection,
            target: target,
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID(),
            source: source
        ))
        let outcome: NovelOutcome?
        do {
            outcome = try await workspace.performSessionAction(action)
            operationErrorMessage = nil
        } catch {
            outcome = nil
            operationErrorMessage = describe(error)
        }
        endAction()
        _ = await refreshDurable(binding: binding, token: bindingToken)
        guard outcome != nil else { return false }
        if workspace.branchSnapshot?.branch.syncStatus == .needsSync {
            workspace.scheduleAutomaticStateSyncIfNeeded()
        }
        return true
    }

    func distillDiscussionArchive(
        chapterID: NovelChapterID?
    ) async -> NovelDiscussionArchiveDraft? {
        guard let binding,
              snapshotMatchesBinding,
              beginAction() else { return nil }
        defer { endAction() }
        do {
            let draft = try await workspace.distillDiscussionArchive(
                projectID: binding.projectID,
                branchID: binding.branchID,
                chapterID: chapterID
            )
            operationErrorMessage = nil
            return draft
        } catch is CancellationError {
            return nil
        } catch let error as NovelStructuredModelExecutionFailure
            where error.failure.code == "cancelled" {
            return nil
        } catch {
            operationErrorMessage = describe(error)
            return nil
        }
    }

    func confirmDiscussionArchive(
        _ draft: NovelDiscussionArchiveDraft,
        decisions: [NovelDiscussionArchiveDraftDecision],
        summary: String
    ) async -> Bool {
        guard !decisions.isEmpty,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let binding,
              draft.projectID == binding.projectID,
              draft.branchID == binding.branchID,
              draft.sessionID == branch.session.id,
              snapshotMatchesBinding else { return false }
        let confirmed = decisions.map {
            NovelConfirmedDiscussionDecision(
                materialID: NovelMaterialID(),
                revisionID: NovelMaterialRevisionID(),
                topic: $0.topic,
                decision: $0.decision,
                relatedMaterialID: $0.relatedMaterialID
            )
        }
        let action = NovelAction.archiveDiscussion(NovelArchiveDiscussionCommand(
            context: mutationContext(project: project, branch: branch),
            projectID: binding.projectID,
            branchID: binding.branchID,
            archiveID: NovelMessageID(),
            checkpointID: NovelCheckpointID(),
            throughSequence: draft.throughSequence,
            chapterID: draft.chapterID,
            summary: summary,
            decisions: confirmed
        ))
        return await perform(action) != nil
    }

    func cloneCollectedProse(_ candidateID: NovelCandidateID) async -> NovelCandidateID? {
        guard cloningCandidateID == nil else { return nil }
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let source = candidate(id: candidateID),
              source.kind == .prose,
              source.status == .collected,
              snapshotMatchesBinding else {
            operationErrorMessage = "这条收录记录已变化，无法再次收录。请重新载入后再试。"
            return nil
        }
        cloningCandidateID = candidateID
        defer { cloningCandidateID = nil }
        let clonedID = NovelCandidateID()
        let outcome = await perform(.cloneCandidate(NovelCloneCandidateCommand(
            context: mutationContext(project: project, branch: branch),
            projectID: project.project.id,
            branchID: branch.branch.id,
            sourceCandidateID: candidateID,
            candidateID: clonedID
        )))
        guard case .candidateCloned(_, _, let sourceCandidateID, let actualID, _) = outcome,
              sourceCandidateID == source.id,
              actualID == clonedID else {
            if operationErrorMessage == nil {
                operationErrorMessage = "无法再次收录这段正文，请重新载入后重试。"
            }
            return nil
        }
        return clonedID
    }

    func undoCommittedChange(
        checkpointID: NovelCheckpointID,
        kind: NovelCandidateKind
    ) async -> Bool {
        guard undoingCheckpointID == nil else { return false }
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              snapshotMatchesBinding,
              branch.branch.headCheckpointID == checkpointID else {
            operationErrorMessage = "当前分支已经变化，请重新选择要撤销的记录。"
            return false
        }
        undoingCheckpointID = checkpointID
        defer { undoingCheckpointID = nil }
        guard beginAction() else {
            operationErrorMessage = workspace.requiresReload
                ? "项目需要重新载入，无法撤销这次\(kind == .polish ? "润色" : "收录")。"
                : "有其他操作进行中，无法撤销这次\(kind == .polish ? "润色" : "收录")。"
            return false
        }
        defer { endAction() }
        do {
            let outcome = try await workspace.performSessionAction(.undoBranchHead(
                NovelUndoBranchHeadCommand(
                    context: mutationContext(project: project, branch: branch),
                    projectID: project.project.id,
                    branchID: branch.branch.id,
                    expectedWorkingRevision: branch.branch.workingRevision
                )
            ))
            let refreshed = await refreshDurable(binding: binding, token: bindingToken)
            guard refreshed else { return false }
            guard case .branchHeadMoved(
                let projectID,
                let branchID,
                let fromCheckpointID,
                _,
                _,
                _
            ) = outcome,
                  projectID == project.project.id,
                  branchID == branch.branch.id,
                  fromCheckpointID == checkpointID else {
                operationErrorMessage = "撤销没有完成，请重新载入项目后再试。"
                return false
            }
            operationErrorMessage = nil
            return true
        } catch {
            operationErrorMessage = describe(error)
            return false
        }
    }

    @discardableResult
    func forkFromCheckpoint(
        _ checkpointID: NovelCheckpointID,
        name: String
    ) async -> NovelBranchID? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              project.checkpoints.contains(where: {
                  $0.id == checkpointID && $0.kind != .initial
              }), snapshotMatchesBinding,
              !isRunning else {
            operationErrorMessage = "当前状态不能从这个存档点创建分支。"
            return nil
        }
        let branchID = await workspace.forkBranch(
            from: branch.branch.id,
            checkpointID: checkpointID,
            name: name
        )
        operationErrorMessage = branchID == nil ? workspace.presentedMessage : nil
        await bindToCurrentSelection()
        return branchID
    }

    func retryPending(_ pendingID: NovelPendingOperationID) async {
        guard let project = workspace.projectSnapshot,
              let pending = project.pendingOperations.first(where: { $0.id == pendingID }),
              snapshotMatchesBinding else { return }
        if pending.kind == .manualSync {
            await workspace.retryPending(pendingID)
            return
        }
        _ = await perform(.retryPending(NovelRetryPendingCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: project.project.revision,
                expectedConfigRevision: project.project.configRevision,
                expectedBranchHeadRevision: workspace.branchSnapshot?.branch.headRevision
            ),
            projectID: project.project.id,
            pendingID: pendingID
        )))
    }

    @discardableResult
    func startWholeChapterPolish(chapterID: NovelChapterID? = nil) async -> Bool {
        let source: NovelChapterVersionRecord?
        if let chapterID {
            source = currentChapterVersions.first { $0.chapterID == chapterID }
        } else {
            source = currentChapterVersions.last
        }
        guard let source else {
            operationErrorMessage = "当前分支还没有可润色的正式章节。"
            return false
        }
        let draft = NovelSessionRunDraft(
            kind: .polish,
            mode: .writeProse,
            granularity: nil,
            userText: "请在不改变任何剧情事实的前提下润色《\(source.title)》。",
            sourceChapterVersionID: source.id,
            askUserResponse: nil,
            injectionOverrides: .none,
            inputBudgetTokens: 16_000
        )
        return await start(draft)
    }

    /// 整章重新生成:与润色的区别是**允许改变剧情事实**,因此不走润色事务的
    /// 漂移闸,而是产出普通 prose 候选,由用户确认后以 `.replaceChapter` 收录为
    /// 该章新版本(版本类型 `.collected`,另起事实兼容链)。
    func startWholeChapterRegeneration(chapterID: NovelChapterID) async -> Bool {
        guard let source = currentChapterVersions.first(where: { $0.chapterID == chapterID }) else {
            operationErrorMessage = "这一章还没有正式版本，无法重新生成。"
            return false
        }
        let draft = NovelSessionRunDraft(
            kind: .regenerate,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "请重写《\(source.title)》这一整章。允许调整剧情以消除与前后章节的矛盾或重复，"
                + "但必须与其余章节保持一致。",
            sourceChapterVersionID: source.id,
            askUserResponse: nil,
            injectionOverrides: .none,
            inputBudgetTokens: 16_000
        )
        return await start(draft)
    }

    /// 候选若由「整章重新生成」产生,它会带着被重写章节的版本 id;收录面板据此
    /// 提供「替换该章」。返回 nil 表示这是普通候选,只能追加或新建章节。
    func regenerationTargetChapterID(for candidateID: NovelCandidateID) -> NovelChapterID? {
        guard let candidate = candidate(id: candidateID),
              candidate.kind == .prose,
              let versionID = candidate.sourceChapterVersionID else { return nil }
        return currentChapterVersions.first { $0.id == versionID }?.chapterID
    }

    func adoptPolishCandidate(_ candidateID: NovelCandidateID) async {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let candidate = candidate(id: candidateID),
              candidate.kind == .polish,
              candidate.status == .available,
              snapshotMatchesBinding else { return }
        let command = NovelAdoptPolishCandidateCommand(
            context: mutationContext(project: project, branch: branch),
            projectID: project.project.id,
            branchID: branch.branch.id,
            transactionID: NovelPendingOperationID(),
            candidateID: candidate.id,
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            expectedWorkingRevision: branch.branch.workingRevision
        )
        adoptingPolishCandidateID = candidateID
        defer { adoptingPolishCandidateID = nil }
        await applyPolishAdoption(command)
    }

    func retryPolishTransaction(_ transactionID: NovelPendingOperationID) async {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let transaction = project.polishTransactions.first(where: {
                  $0.id == transactionID && $0.branchID == branch.branch.id &&
                      ($0.status == .pending || $0.status == .retryable)
              }), snapshotMatchesBinding,
              polishTransactionSourceBlocker(transactionID) == nil else { return }
        let chapterID = project.chapterVersions.first {
            $0.id == transaction.sourceChapterVersionID
        }?.chapterID
        let command = NovelAdoptPolishCandidateCommand(
            context: NovelMutationContext(
                operationID: transaction.operationID,
                expectedProjectRevision: project.project.revision,
                expectedConfigRevision: project.project.configRevision,
                expectedBranchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            transactionID: transaction.id,
            candidateID: transaction.candidateID,
            proposedChapterVersionID: transaction.proposedChapterVersionID,
            checkpointID: transaction.checkpointID,
            expectedWorkingRevision: branch.branch.workingRevision
        )
        await applyPolishAdoption(command)
        let durableStatus = workspace.projectSnapshot?.polishTransactions.first(where: {
            $0.id == transactionID
        })?.status
        if Task.isCancelled,
           durableStatus != .completed,
           durableStatus != .incompatible {
            operationErrorMessage = nil
            return
        }
        reconcileBatchPolishResult(transactionID: transactionID, chapterID: chapterID)
    }

    @discardableResult
    func startPolishRetry(_ transactionID: NovelPendingOperationID) -> Bool {
        guard polishRetryTask == nil,
              let binding,
              unresolvedBranchPolishTransactions.contains(where: {
                  $0.id == transactionID &&
                      ($0.status == .pending || $0.status == .retryable)
              }),
              polishTransactionSourceBlocker(transactionID) == nil else { return false }
        polishRetryTransactionID = transactionID
        polishRetryTaskBinding = binding
        polishRetryTask = Task { @MainActor [weak self] in
            await self?.retryPolishTransaction(transactionID)
            guard let self,
                  self.polishRetryTransactionID == transactionID else { return }
            self.polishRetryTransactionID = nil
            self.polishRetryTask = nil
            self.polishRetryTaskBinding = nil
        }
        return true
    }

    func cancelPolishRetry() {
        polishRetryTask?.cancel()
    }

    func polishTransactionSourceBlocker(
        _ transactionID: NovelPendingOperationID
    ) -> NovelSessionActionBlocker? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let transaction = project.polishTransactions.first(where: {
                  $0.id == transactionID && $0.branchID == branch.branch.id
              }),
              let source = project.chapterVersions.first(where: {
                  $0.id == transaction.sourceChapterVersionID
              }),
              branch.branch.workingChapterSelections.contains(where: {
                  $0.chapterID == source.chapterID && $0.versionID == source.id
              }),
              project.chapters.contains(where: {
                  $0.id == source.chapterID && $0.discardedAt == nil
              }) else {
            return .sourceChapterChanged
        }
        return nil
    }

    @discardableResult
    func abandonPolishTransaction(_ transactionID: NovelPendingOperationID) async -> Bool {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              let transaction = project.polishTransactions.first(where: {
                  $0.id == transactionID && $0.branchID == branch.branch.id
              }), snapshotMatchesBinding else {
            operationErrorMessage = workspace.requiresReload
                ? "项目已变化，请重新载入后再试。"
                : "这项润色已经处理，或当前分支已经变化。"
            return false
        }
        let chapterID = project.chapterVersions.first {
            $0.id == transaction.sourceChapterVersionID
        }?.chapterID
        operationErrorMessage = nil
        let outcome = await perform(.abandonPolishTransaction(
            NovelAbandonPolishTransactionCommand(
                context: mutationContext(project: project, branch: branch),
                projectID: project.project.id,
                branchID: branch.branch.id,
                transactionID: transactionID
            )
        ))
        reconcileBatchPolishResult(transactionID: transactionID, chapterID: chapterID)
        guard let outcome,
              case .polishTransactionAbandoned = outcome else {
            if operationErrorMessage == nil {
                operationErrorMessage = workspace.requiresReload
                    ? "项目已变化，请重新载入后再试。"
                    : "当前有其他操作正在处理，请稍后再试。"
            }
            return false
        }
        return true
    }

    @discardableResult
    func abandonPolishTransactions(
        _ transactionIDs: [NovelPendingOperationID]
    ) async -> Int {
        let ownerBinding = binding
        var abandonedCount = 0
        for transactionID in transactionIDs {
            guard !Task.isCancelled,
                  binding == ownerBinding else { break }
            guard await abandonPolishTransaction(transactionID) else { break }
            abandonedCount += 1
        }
        return abandonedCount
    }


    @discardableResult
    func convertPolishCandidateToManualRewrite(_ candidateID: NovelCandidateID) async -> Bool {
        guard !workspace.requiresReload,
              let candidate = candidate(id: candidateID),
              candidate.kind == .polish,
              let sourceID = candidate.sourceChapterVersionID,
              let source = workspace.projectSnapshot?.chapterVersions.first(where: { $0.id == sourceID }),
              currentChapterVersions.contains(where: { $0.id == source.id }) else {
            return false
        }
        isPerformingAction = true
        workspace.clearError()
        let saved = await workspace.saveManualRewrite(
            chapterID: source.chapterID,
            title: source.title,
            content: candidate.content
        )
        isPerformingAction = false
        operationErrorMessage = workspace.errorMessage
        _ = await refreshDurable(binding: binding, token: bindingToken)
        return saved
    }

}
