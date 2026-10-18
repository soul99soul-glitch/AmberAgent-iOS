import Foundation

struct NovelSessionCollectedCheckpointKey: Hashable, Sendable {
    let checkpointID: NovelCheckpointID
    let candidateID: NovelCandidateID
}

struct NovelSessionProjectionIndex: Sendable {
    let candidatesBySourceMessageID: [NovelMessageID: [NovelCandidateRecord]]
    let messageByID: [NovelMessageID: NovelSessionMessageRecord]
    let pendingCandidateIDs: Set<NovelCandidateID>
    let polishCandidateIDs: Set<NovelCandidateID>
    let pendingByCandidateID: [NovelCandidateID: NovelPendingOperationRecord]
    let polishByCandidateID: [NovelCandidateID: NovelPendingPolishTransactionRecord]
    let runByID: [NovelRunID: NovelActiveRunRecord]
    let unresolvedQuickStartProposalByRunID: [NovelRunID: NovelSettingProposalRecord]
    let collectedCheckpointByKey: [NovelSessionCollectedCheckpointKey: NovelBranchCheckpointRecord]
    let checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord]
    let stateByID: [NovelStateSnapshotID: NovelStateSnapshotRecord]
    let eventByID: [NovelEventID: NovelStoryEventRecord]
    let askUserResponseByPromptMessageID: [NovelMessageID: NovelAskUserResponse]
    let workingChapterVersionIDs: Set<NovelChapterVersionID>
    let runningRunIDs: Set<NovelRunID>
    let branchPendingOperationIDs: Set<NovelPendingOperationID>
    let branchManualSyncPendingOperationIDs: Set<NovelPendingOperationID>
    let branchProseBlockingPendingOperationIDs: Set<NovelPendingOperationID>
    let branchBlockingPolishTransactionIDs: Set<NovelPendingOperationID>
    let discardedChapterVersionIDs: Set<NovelChapterVersionID>

    init(input: NovelSessionProjectionInput) {
        var candidatesBySourceMessageID: [NovelMessageID: [NovelCandidateRecord]] = [:]
        for candidate in input.candidates
        where candidate.branchID == input.branch.id && candidate.sessionID == input.session.id {
            candidatesBySourceMessageID[candidate.sourceMessageID, default: []].append(candidate)
        }
        self.candidatesBySourceMessageID = candidatesBySourceMessageID

        var pendingCandidateIDs: Set<NovelCandidateID> = []
        var pendingByCandidateID: [NovelCandidateID: NovelPendingOperationRecord] = [:]
        var branchPendingOperationIDs: Set<NovelPendingOperationID> = []
        var branchManualSyncPendingOperationIDs: Set<NovelPendingOperationID> = []
        var branchProseBlockingPendingOperationIDs: Set<NovelPendingOperationID> = []
        for pending in input.pendingOperations {
            if let candidateID = pending.candidateID {
                pendingCandidateIDs.insert(candidateID)
                if pending.branchID == input.branch.id, pendingByCandidateID[candidateID] == nil {
                    pendingByCandidateID[candidateID] = pending
                }
            }
            if pending.branchID == input.branch.id {
                branchPendingOperationIDs.insert(pending.id)
                if pending.kind == .manualSync {
                    branchManualSyncPendingOperationIDs.insert(pending.id)
                }
                if pending.blocksProseGeneration {
                    branchProseBlockingPendingOperationIDs.insert(pending.id)
                }
            }
        }
        self.pendingCandidateIDs = pendingCandidateIDs
        self.pendingByCandidateID = pendingByCandidateID
        self.branchPendingOperationIDs = branchPendingOperationIDs
        self.branchManualSyncPendingOperationIDs = branchManualSyncPendingOperationIDs
        self.branchProseBlockingPendingOperationIDs = branchProseBlockingPendingOperationIDs

        var polishCandidateIDs: Set<NovelCandidateID> = []
        var polishByCandidateID: [NovelCandidateID: NovelPendingPolishTransactionRecord] = [:]
        var branchBlockingPolishTransactionIDs: Set<NovelPendingOperationID> = []
        for transaction in input.polishTransactions {
            polishCandidateIDs.insert(transaction.candidateID)
            if transaction.branchID == input.branch.id, polishByCandidateID[transaction.candidateID] == nil {
                polishByCandidateID[transaction.candidateID] = transaction
            }
            if transaction.branchID == input.branch.id,
               transaction.status == .pending || transaction.status == .retryable || transaction.status == .blocked {
                branchBlockingPolishTransactionIDs.insert(transaction.id)
            }
        }
        self.polishCandidateIDs = polishCandidateIDs
        self.polishByCandidateID = polishByCandidateID
        self.branchBlockingPolishTransactionIDs = branchBlockingPolishTransactionIDs
        self.discardedChapterVersionIDs = input.discardedChapterVersionIDs

        var runByID: [NovelRunID: NovelActiveRunRecord] = [:]
        var runningRunIDs: Set<NovelRunID> = []
        for run in input.runs {
            if runByID[run.id] == nil { runByID[run.id] = run }
            if run.branchID == input.branch.id, run.status == .running {
                runningRunIDs.insert(run.id)
            }
        }
        self.runByID = runByID
        self.runningRunIDs = runningRunIDs

        var unresolvedQuickStartProposalByRunID: [NovelRunID: NovelSettingProposalRecord] = [:]
        for proposal in input.settingProposals where
            !proposal.isResolved && proposal.supersededByRunID == nil {
            guard case .some(.quickStart(let runID, _)) = proposal.origin else { continue }
            if unresolvedQuickStartProposalByRunID[runID] == nil {
                unresolvedQuickStartProposalByRunID[runID] = proposal
            }
        }
        self.unresolvedQuickStartProposalByRunID = unresolvedQuickStartProposalByRunID

        var collectedCheckpointByKey: [
            NovelSessionCollectedCheckpointKey: NovelBranchCheckpointRecord
        ] = [:]
        var checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord] = [:]
        for checkpoint in input.checkpoints {
            if checkpointByID[checkpoint.id] == nil { checkpointByID[checkpoint.id] = checkpoint }
            if let candidateID = checkpoint.sourceCandidateID {
                let key = NovelSessionCollectedCheckpointKey(
                    checkpointID: checkpoint.id,
                    candidateID: candidateID
                )
                if collectedCheckpointByKey[key] == nil { collectedCheckpointByKey[key] = checkpoint }
            }
        }
        self.collectedCheckpointByKey = collectedCheckpointByKey
        self.checkpointByID = checkpointByID

        var stateByID: [NovelStateSnapshotID: NovelStateSnapshotRecord] = [:]
        for state in input.stateSnapshots where stateByID[state.id] == nil {
            stateByID[state.id] = state
        }
        self.stateByID = stateByID

        var eventByID: [NovelEventID: NovelStoryEventRecord] = [:]
        for event in input.events where eventByID[event.id] == nil {
            eventByID[event.id] = event
        }
        self.eventByID = eventByID
        var messageByID: [NovelMessageID: NovelSessionMessageRecord] = [:]
        var askResponses: [NovelMessageID: NovelAskUserResponse] = [:]
        for message in input.session.messages {
            if messageByID[message.id] == nil { messageByID[message.id] = message }
            guard case .some(.askUserAnswer(let response)) = message.interaction else { continue }
            if askResponses[response.promptMessageID] == nil {
                askResponses[response.promptMessageID] = response
            }
        }
        self.messageByID = messageByID
        askUserResponseByPromptMessageID = askResponses
        self.workingChapterVersionIDs = Set(input.branch.workingChapterSelections.map(\.versionID))
    }

    func hasRunningRun(excluding runID: NovelRunID?) -> Bool {
        runningRunIDs.count > (runID.map(runningRunIDs.contains) == true ? 1 : 0)
    }

    func pendingOperationBlocker(
        excluding pendingID: NovelPendingOperationID?
    ) -> NovelSessionActionBlocker? {
        let excludesPending = pendingID.map(branchPendingOperationIDs.contains) == true
        let remainingCount = branchPendingOperationIDs.count - (excludesPending ? 1 : 0)
        guard remainingCount > 0 else { return nil }

        let excludesManualSync = pendingID.map(branchManualSyncPendingOperationIDs.contains) == true
        let remainingManualSyncCount = branchManualSyncPendingOperationIDs.count -
            (excludesManualSync ? 1 : 0)
        if remainingCount == remainingManualSyncCount {
            return .branchNeedsSync
        }
        return .pendingOperation
    }

    func hasBlockingPolishTransaction(excluding transactionID: NovelPendingOperationID?) -> Bool {
        branchBlockingPolishTransactionIDs.count > (
            transactionID.map(branchBlockingPolishTransactionIDs.contains) == true ? 1 : 0
        )
    }
}
