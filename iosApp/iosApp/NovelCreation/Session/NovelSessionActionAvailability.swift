import Foundation

extension NovelSessionPresentation {
    static func actions(
        for message: NovelSessionMessageRecord,
        candidate: NovelCandidateRecord?,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> [NovelSessionRowActionAvailability] {
        guard message.role == .assistant else { return [] }
        if let candidate {
            var result = candidateActions(candidate, input: input, index: index)
            if candidate.status == .interrupted,
               let runID = message.runID,
               let run = index.runByID[runID] {
                result.append(availability(
                    .retryGeneration(runID),
                    blocker: retryBlocker(for: run, input: input, index: index)
                ))
            }
            return result
        }
        if let runID = message.runID,
           index.runByID[runID]?.kind == .quickStart,
           let proposal = index.unresolvedQuickStartProposalByRunID[runID] {
            return [availability(
                .viewSettingProposals(NovelSettingProposalRoute(kind: proposal.suggestedMaterialKind)),
                blocker: nil
            )]
        }
        guard message.kind == .interruptedDraft || message.kind == .error,
              let runID = message.runID,
              let run = index.runByID[runID] else {
            return []
        }
        if run.status == .failed, run.terminalFailure?.isRetryable != true {
            return [availability(.retryGeneration(runID), blocker: .failureNotRetryable)]
        }
        return [availability(
            .retryGeneration(runID),
            blocker: retryBlocker(for: run, input: input, index: index)
        )]
    }

    private static func candidateActions(
        _ candidate: NovelCandidateRecord,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> [NovelSessionRowActionAvailability] {
        if let pending = index.pendingByCandidateID[candidate.id] {
            return [availability(
                .retryPending(pending.id),
                blocker: baseMutationBlocker(
                    input: input,
                    index: index,
                    includePending: true,
                    excludingPendingID: pending.id
                )
            )]
        }

        if let transaction = index.polishByCandidateID[candidate.id] {
            switch transaction.status {
            case .pending:
                let baseBlocker = baseMutationBlocker(
                    input: input,
                    index: index,
                    includePending: true,
                    excludingPolishTransactionID: transaction.id
                )
                let retryBlocker = baseBlocker ??
                    polishTransactionSourceBlocker(transaction, index: index) ??
                    staleBlocker(candidate, input: input)
                return [
                    availability(.retryPolish(transaction.id), blocker: retryBlocker),
                    availability(.abandonPolish(transaction.id), blocker: baseBlocker)
                ]
            case .retryable:
                let baseBlocker = baseMutationBlocker(
                    input: input,
                    index: index,
                    includePending: true,
                    excludingPolishTransactionID: transaction.id
                )
                let retryBlocker = baseBlocker ??
                    polishTransactionSourceBlocker(transaction, index: index) ??
                    staleBlocker(candidate, input: input)
                return [
                    availability(.retryPolish(transaction.id), blocker: retryBlocker),
                    availability(.abandonPolish(transaction.id), blocker: baseBlocker)
                ]
            case .blocked:
                return [availability(
                    .abandonPolish(transaction.id),
                    blocker: baseMutationBlocker(
                        input: input,
                        index: index,
                        includePending: true,
                        excludingPolishTransactionID: transaction.id
                    )
                )]
            case .incompatible:
                guard let sourceID = candidate.sourceChapterVersionID else { return [] }
                return [availability(
                    .convertPolishToManualRewrite(
                        candidateID: candidate.id,
                        sourceChapterVersionID: sourceID
                    ),
                    blocker: manualRewriteBlocker(
                        sourceChapterVersionID: sourceID,
                        input: input,
                        index: index
                    )
                )]
            case .completed, .abandoned:
                break
            }
        }

        switch candidate.status {
        case .available:
            let blocker = candidateMutationBlocker(candidate, input: input, index: index)
            switch candidate.kind {
            case .prose:
                return [availability(.collectProse(candidate.id), blocker: blocker)]
            case .polish:
                return [availability(.adoptPolish(candidate.id), blocker: blocker)]
            }
        case .collected, .adopted:
            var result: [NovelSessionRowActionAvailability] = []
            if undoRemovesCandidateCheckpoint(candidate, input: input, index: index) {
                result.append(availability(
                    .undoCommittedChange(
                        checkpointID: input.branch.headCheckpointID,
                        kind: candidate.kind
                    ),
                    blocker: undoBlocker(input: input, index: index)
                ))
            }
            if let checkpointID = candidate.collectedCheckpointID {
                result.append(availability(
                    .forkFromCheckpoint(checkpointID),
                    blocker: forkBlocker(input: input, index: index)
                ))
            }
            if candidate.kind == .prose,
               candidate.status == .collected,
               NovelCandidateSemantics.cloneBaseMatches(
                   candidate,
                   currentCheckpointID: input.branch.headCheckpointID,
                   checkpointByID: index.checkpointByID,
                   sourceMessage: index.messageByID[candidate.sourceMessageID]
               ) {
                result.append(availability(
                    .cloneCollectedProse(candidate.id),
                    blocker: candidateMutationBlocker(
                        candidate,
                        input: input,
                        index: index,
                        requiresCurrentBase: false
                    )
                ))
            }
            return result
        case .interrupted:
            guard candidate.kind == .prose else { return [] }
            return [availability(
                .collectProse(candidate.id),
                blocker: candidateMutationBlocker(candidate, input: input, index: index)
            )]
        case .superseded, .inheritedReadOnly:
            return []
        }
    }

    private static func undoRemovesCandidateCheckpoint(
        _ candidate: NovelCandidateRecord,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> Bool {
        guard let candidateCheckpointID = candidate.collectedCheckpointID,
              let head = index.checkpointByID[input.branch.headCheckpointID],
              let target = NovelBranchSemantics.undoTarget(
                  for: head,
                  branch: input.branch,
                  checkpointByID: index.checkpointByID
              ) else {
            return false
        }
        if candidateCheckpointID == head.id { return true }
        guard head.parentCheckpointID == candidateCheckpointID,
              let candidateCheckpoint = index.checkpointByID[candidateCheckpointID] else {
            return false
        }
        return target.id == candidateCheckpoint.parentCheckpointID
    }

    private static func retryBlocker(
        for run: NovelActiveRunRecord,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex,
        excludingRunID: NovelRunID? = nil
    ) -> NovelSessionActionBlocker? {
        if let blocker = baseMutationBlocker(
            input: input,
            index: index,
            includePending: false,
            excludingRunID: excludingRunID
        ) {
            return blocker
        }
        if run.kind == .polish || run.kind == .regenerate || run.kind == .prose {
            if input.branch.syncStatus == .needsSync {
                return .branchNeedsSync
            }
            if run.kind == .prose,
               run.granularity == .wholeChapter,
               input.collaborationMode == .ghostwrite,
               !input.hasConfirmedChapterPlan {
                return .chapterPlanRequired
            }
            if run.kind == .polish || run.kind == .regenerate {
                if let blocker = index.pendingOperationBlocker(excluding: nil) {
                    return blocker
                }
                if index.hasBlockingPolishTransaction(excluding: nil) { return .pendingOperation }
            } else if !index.branchProseBlockingPendingOperationIDs.isEmpty {
                return .pendingOperation
            }
        }
        if run.kind == .prose || run.kind == .polish || run.kind == .regenerate {
            if input.branch.headCheckpointID != run.baseCheckpointID ||
                input.branch.headRevision != run.baseHeadRevision {
                return .staleCandidate
            }
            if run.kind == .polish || run.kind == .regenerate {
                guard let sourceVersionID = run.sourceChapterVersionID,
                      index.workingChapterVersionIDs.contains(sourceVersionID),
                      !input.discardedChapterVersionIDs.contains(sourceVersionID) else {
                    return .sourceChapterChanged
                }
            }
        }
        return nil
    }

    static func transientRetryBlocker(
        tail: NovelSessionTransientTail,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        if let run = index.runByID[tail.runID] {
            return retryBlocker(
                for: run,
                input: input,
                index: index,
                excludingRunID: tail.runID
            )
        }
        if let blocker = baseMutationBlocker(
            input: input,
            index: index,
            includePending: false,
            excludingRunID: tail.runID
        ) {
            return blocker
        }
        if tail.kind == .proseCandidate || tail.kind == .polishCandidate {
            if input.branch.syncStatus == .needsSync {
                return .branchNeedsSync
            }
            if tail.kind == .proseCandidate,
               tail.granularity == .wholeChapter,
               input.collaborationMode == .ghostwrite,
               !input.hasConfirmedChapterPlan {
                return .chapterPlanRequired
            }
            if !index.branchProseBlockingPendingOperationIDs.isEmpty {
                return .pendingOperation
            }
        }
        return nil
    }

    static func transientCollectionBlocker(
        tail: NovelSessionTransientTail,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        if let blocker = baseMutationBlocker(
            input: input,
            index: index,
            includePending: true,
            excludingRunID: tail.runID
        ) {
            return blocker
        }
        if input.branch.syncStatus == .needsSync,
           !NovelWorkspaceLedger.isPointerOnlyRelink(
               branch: input.branch,
               checkpoints: input.checkpoints
           ) {
            return .branchNeedsSync
        }
        guard let run = index.runByID[tail.runID],
              run.baseCheckpointID == input.branch.headCheckpointID,
              run.baseHeadRevision == input.branch.headRevision else {
            return .staleCandidate
        }
        return nil
    }

    private static func candidateMutationBlocker(
        _ candidate: NovelCandidateRecord,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex,
        requiresCurrentBase: Bool = true
    ) -> NovelSessionActionBlocker? {
        if let blocker = baseMutationBlocker(
            input: input,
            index: index,
            includePending: true
        ) {
            return blocker
        }
        if candidate.kind == .prose, candidate.ghostwritePlanID != nil {
            return .ghostwriteReviewRequired
        }
        if input.branch.syncStatus == .needsSync {
            let pointerOnlyRelink = candidate.kind == .prose &&
                NovelWorkspaceLedger.isPointerOnlyRelink(
                    branch: input.branch,
                    checkpoints: input.checkpoints
                )
            if !pointerOnlyRelink { return .branchNeedsSync }
        }
        if requiresCurrentBase {
            let baseMatches: Bool
            if candidate.kind == .prose {
                let sourceMessage = index.messageByID[candidate.sourceMessageID]
                baseMatches = NovelCandidateSemantics.collectionBaseMatches(
                    candidate,
                    targetCheckpointID: input.branch.headCheckpointID,
                    targetHeadRevision: input.branch.headRevision,
                    checkpointByID: index.checkpointByID,
                    sourceMessage: sourceMessage
                )
            } else {
                baseMatches = candidate.baseCheckpointID == input.branch.headCheckpointID &&
                    candidate.baseHeadRevision == input.branch.headRevision
            }
            if !baseMatches { return .staleCandidate }
        }
        if requiresCurrentBase,
           let sourceID = candidate.sourceChapterVersionID,
           index.discardedChapterVersionIDs.contains(sourceID) {
            return .sourceChapterChanged
        }
        if candidate.kind == .polish,
           let sourceID = candidate.sourceChapterVersionID,
           !index.workingChapterVersionIDs.contains(sourceID) {
            return .sourceChapterChanged
        }
        return nil
    }

    static func baseMutationBlocker(
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex,
        includePending: Bool,
        excludingPendingID: NovelPendingOperationID? = nil,
        excludingPolishTransactionID: NovelPendingOperationID? = nil,
        excludingRunID: NovelRunID? = nil
    ) -> NovelSessionActionBlocker? {
        if input.access != .readWrite { return .projectReadOnly }
        if input.branch.lifecycle != .active { return .branchInactive }
        if input.hasLiveTail {
            return .generationRunning
        }
        if (input.branch.activeRunID != nil && input.branch.activeRunID != excludingRunID) ||
            index.hasRunningRun(excluding: excludingRunID) {
            return .generationRunning
        }
        if includePending {
            if let blocker = index.pendingOperationBlocker(
                excluding: excludingPendingID
            ) {
                return blocker
            }
            if index.hasBlockingPolishTransaction(excluding: excludingPolishTransactionID) {
                return .pendingOperation
            }
        }
        return nil
    }

    private static func manualRewriteBlocker(
        sourceChapterVersionID: NovelChapterVersionID,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        if let blocker = baseMutationBlocker(input: input, index: index, includePending: true) {
            return blocker
        }
        guard index.workingChapterVersionIDs.contains(sourceChapterVersionID) else {
            return .sourceChapterChanged
        }
        return nil
    }

    private static func staleBlocker(
        _ candidate: NovelCandidateRecord,
        input: NovelSessionProjectionInput
    ) -> NovelSessionActionBlocker? {
        candidate.baseCheckpointID == input.branch.headCheckpointID &&
            candidate.baseHeadRevision == input.branch.headRevision
            ? nil
            : .staleCandidate
    }

    static func polishTransactionSourceBlocker(
        _ transaction: NovelPendingPolishTransactionRecord,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        guard index.workingChapterVersionIDs.contains(transaction.sourceChapterVersionID),
              !index.discardedChapterVersionIDs.contains(transaction.sourceChapterVersionID) else {
            return .sourceChapterChanged
        }
        return nil
    }

    private static func forkBlocker(
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        baseMutationBlocker(input: input, index: index, includePending: false)
    }

    private static func undoBlocker(
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionActionBlocker? {
        if let blocker = baseMutationBlocker(input: input, index: index, includePending: true) {
            return blocker
        }
        guard input.branch.syncStatus == .needsSync else { return nil }
        guard let head = index.checkpointByID[input.branch.headCheckpointID],
              NovelBranchSemantics.canUndoHead(
                  head,
                  branch: input.branch,
                  checkpointByID: index.checkpointByID
              ) else {
            return .branchNeedsSync
        }
        return nil
    }

    static func availability(
        _ action: NovelSessionRowAction,
        blocker: NovelSessionActionBlocker?
    ) -> NovelSessionRowActionAvailability {
        NovelSessionRowActionAvailability(action: action, blocker: blocker)
    }

    static func digest(
        messageID: NovelMessageID,
        transientRevision: UInt64?,
        transientPhase: NovelSessionTransientTailPhase?,
        runStatus: NovelRunStatus?,
        granularity: NovelGenerationGranularity?,
        candidate: NovelSessionCandidatePresentation?,
        committedChange: NovelSessionCommittedChangeSummary?,
        askUser: NovelAskUserPresentation?,
        actions: [NovelSessionRowActionAvailability]
    ) -> NovelSessionRowDigest {
        let contentToken: String
        if let transientRevision {
            contentToken = "tail:\(messageID):\(transientRevision):\(phaseToken(transientPhase))"
        } else {
            // Session messages are immutable after append; identity is therefore a complete
            // durable-content revision and avoids re-hashing historical whole chapters.
            contentToken = "durable:\(messageID)"
        }
        let candidateToken = candidate.map {
            "\($0.id):\($0.status.rawValue):\($0.pendingStatus?.rawValue ?? "-"):" +
                "\($0.polishTransactionStatus?.rawValue ?? "-")"
        } ?? "none"
        let committedToken = committedChange.map {
            "\($0.checkpointID):\($0.stateSnapshotID):\($0.eventSummaries.count):" +
                "\($0.branchSyncStatus.rawValue)"
        } ?? "none"
        let askUserToken = askUser.map { presentation in
            "ask:\(presentation.prompt.question):" +
                (presentation.isAnswered ? "answered" : "pending")
        } ?? "none"
        let actionToken = actions.map(actionToken).joined(separator: "|")
        return NovelSessionRowDigest(
            layout: "\(contentToken);\(runStatus?.rawValue ?? "-");" +
                "\(granularity?.rawValue ?? "-");\(candidateToken);" +
                "\(committedToken);\(askUserToken);\(actionToken)",
            presentation: actionToken
        )
    }

    static func transientRunStatus(
        for phase: NovelSessionTransientTailPhase
    ) -> NovelRunStatus {
        switch phase {
        case .interrupted:
            .interrupted
        case .failed:
            .failed
        case .waitingForFirstToken, .streaming, .terminalAwaitingRefresh, .persistenceBlocked:
            .running
        }
    }

    private static func phaseToken(_ phase: NovelSessionTransientTailPhase?) -> String {
        switch phase {
        case .waitingForFirstToken: "waiting"
        case .streaming: "streaming"
        case .terminalAwaitingRefresh: "terminal-awaiting-refresh"
        case .interrupted: "interrupted"
        case .failed(let failure):
            "failed:\(failure.code):\(failure.isRetryable)"
        case .persistenceBlocked(let failure):
            "blocked:\(failure.code):\(failure.isRetryable)"
        case nil: "none"
        }
    }

    private static func actionToken(_ availability: NovelSessionRowActionAvailability) -> String {
        let actionToken: String = switch availability.action {
        case .collectProse(let candidateID): "collect-prose:\(candidateID)"
        case .adoptPolish(let candidateID): "adopt-polish:\(candidateID)"
        case .retryGeneration(let runID): "retry-generation:\(runID)"
        case .retryTerminalPersistence(let runID): "retry-terminal-persistence:\(runID)"
        case .retryPending(let operationID): "retry-pending:\(operationID)"
        case .retryPolish(let operationID): "retry-polish:\(operationID)"
        case .abandonPolish(let operationID): "abandon-polish:\(operationID)"
        case .convertPolishToManualRewrite(let candidateID, let versionID):
            "convert-polish-to-manual-rewrite:\(candidateID):\(versionID)"
        case .cloneCollectedProse(let candidateID): "clone-collected-prose:\(candidateID)"
        case .forkFromCheckpoint(let checkpointID): "fork-from-checkpoint:\(checkpointID)"
        case .viewSettingProposals(let route):
            "view-setting-proposals:\(settingProposalRouteToken(route))"
        case .undoCommittedChange(let checkpointID, let kind):
            "undo-committed-change:\(checkpointID):\(kind.rawValue)"
        }
        return "\(actionToken):\(availability.blocker?.rawValue ?? "enabled")"
    }

    private static func settingProposalRouteToken(_ route: NovelSettingProposalRoute) -> String {
        switch route {
        case .characters: "characters"
        case .world: "world"
        case .story: "story"
        case .more: "more"
        }
    }
}
