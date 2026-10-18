import Foundation

enum NovelDocumentCheckpointValidation {
    static func validateCheckpoints(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        var checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord] = [:]
        for checkpoint in document.checkpoints where checkpointByID[checkpoint.id] == nil {
            checkpointByID[checkpoint.id] = checkpoint
        }
        let operationIDs = Set(document.appliedOperations.map(\.operationID))
        let initialCheckpoints = document.checkpoints.filter { $0.kind == .initial }
        if initialCheckpoints.count != 1 {
            issues.append("Project must have exactly one initial checkpoint.")
        }
        // 预建索引，替代逐 checkpoint 的整表线性查找（语义同 first/contains(where:)）。
        struct ChapterVersionKey: Hashable {
            let versionID: NovelChapterVersionID
            let chapterID: NovelChapterID
        }
        let stateSnapshotIDs = Set(document.stateSnapshots.map(\.id))
        let chapterVersionKeys = Set(document.chapterVersions.map {
            ChapterVersionKey(versionID: $0.id, chapterID: $0.chapterID)
        })
        let messageSequencesBySessionID = Dictionary(
            document.sessions.map { ($0.id, Set($0.messages.map(\.sequence))) },
            uniquingKeysWith: { first, _ in first }
        )

        for checkpoint in document.checkpoints {
            if checkpoint.kind == .initial && checkpoint.parentCheckpointID != nil {
                issues.append("Initial checkpoint \(checkpoint.id) has a parent.")
            }
            if checkpoint.baseHeadRevision < 0 {
                issues.append("Checkpoint \(checkpoint.id) has a negative base head revision.")
            }
            if checkpoint.kind == .initial && checkpoint.baseHeadRevision != 0 {
                issues.append("Initial checkpoint \(checkpoint.id) has a nonzero base head revision.")
            }
            if checkpoint.kind != .initial && checkpoint.parentCheckpointID == nil {
                issues.append("Checkpoint \(checkpoint.id) has no parent.")
            }
            if let parent = checkpoint.parentCheckpointID, checkpointByID[parent] == nil {
                issues.append("Checkpoint \(checkpoint.id) has a missing parent.")
            }
            guard let sourceBranch = document.branches.first(where: {
                $0.id == checkpoint.createdOnBranchID
            }), let session = document.sessions.first(where: { $0.id == sourceBranch.sessionID }) else {
                issues.append("Checkpoint \(checkpoint.id) has no source branch Session.")
                continue
            }
            if case .through(let sequence) = checkpoint.sessionCursor,
               messageSequencesBySessionID[session.id]?.contains(sequence) != true {
                issues.append("Checkpoint \(checkpoint.id) has an invalid Session cursor.")
            }
            if !stateSnapshotIDs.contains(checkpoint.stateSnapshotID) {
                issues.append("Checkpoint \(checkpoint.id) has a missing state snapshot.")
            }
            if Set(checkpoint.chapterSelections.map(\.chapterID)).count != checkpoint.chapterSelections.count {
                issues.append("Checkpoint \(checkpoint.id) repeats a chapter.")
            }
            for selection in checkpoint.chapterSelections {
                if !chapterVersionKeys.contains(ChapterVersionKey(
                    versionID: selection.versionID,
                    chapterID: selection.chapterID
                )) {
                    issues.append("Checkpoint \(checkpoint.id) has an invalid chapter selection.")
                }
            }
            for revisionID in checkpoint.branchOverrideRevisionIDs where
                !document.materialRevisions.contains(where: { $0.id == revisionID }) {
                issues.append("Checkpoint \(checkpoint.id) has a missing override revision.")
            }
            let overrideMaterialIDs = checkpoint.branchOverrideRevisionIDs.compactMap { revisionID in
                document.materialRevisions.first(where: { $0.id == revisionID })?.materialID
            }
            if Set(checkpoint.branchOverrideRevisionIDs).count !=
                checkpoint.branchOverrideRevisionIDs.count ||
                Set(overrideMaterialIDs).count != overrideMaterialIDs.count {
                issues.append("Checkpoint \(checkpoint.id) repeats a material override.")
            }
            if !operationIDs.contains(checkpoint.operationID) {
                issues.append("Checkpoint \(checkpoint.id) has no applied operation.")
            }
            switch checkpoint.kind {
            case .collection, .polish:
                guard let candidateID = checkpoint.sourceCandidateID,
                      let candidate = document.candidates.first(where: { $0.id == candidateID }) else {
                    issues.append("Checkpoint \(checkpoint.id) has no source candidate.")
                    continue
                }
                let baseMatches: Bool
                if checkpoint.kind == .collection, let parentID = checkpoint.parentCheckpointID {
                    baseMatches = NovelCandidateSemantics.collectionBaseMatches(
                        candidate,
                        targetCheckpointID: parentID,
                        targetHeadRevision: checkpoint.baseHeadRevision,
                        in: document
                    )
                } else {
                    baseMatches = candidate.baseCheckpointID == checkpoint.parentCheckpointID &&
                        candidate.baseHeadRevision == checkpoint.baseHeadRevision
                }
                if candidate.branchID != checkpoint.createdOnBranchID ||
                    candidate.sessionID != sourceBranch.sessionID ||
                    !baseMatches {
                    issues.append("Checkpoint \(checkpoint.id) crosses its source candidate branch or base.")
                }
                guard let sourceMessage = session.messages.first(where: {
                    $0.id == candidate.sourceMessageID
                }) else {
                    continue
                }
                if checkpoint.sessionCursor != .through(sequence: sourceMessage.sequence) {
                    issues.append("Checkpoint \(checkpoint.id) cursor does not match its source candidate.")
                }
                if checkpoint.kind == .collection && candidate.kind != .prose {
                    issues.append("Collection checkpoint \(checkpoint.id) has a non-prose candidate.")
                }
                if checkpoint.kind == .polish && candidate.kind != .polish {
                    issues.append("Polish checkpoint \(checkpoint.id) has a non-polish candidate.")
                }
            case .initial, .manualSync, .discussionArchive, .identityClarification, .restore:
                if checkpoint.sourceCandidateID != nil {
                    issues.append("Checkpoint \(checkpoint.id) unexpectedly has a source candidate.")
                }
            }
            if checkpoint.kind == .identityClarification,
               let parentID = checkpoint.parentCheckpointID,
               let parent = checkpointByID[parentID] {
                validateIdentityClarificationCheckpoint(
                    checkpoint,
                    parent: parent,
                    document: document,
                    issues: &issues
                )
            }
            if checkpoint.kind == .polish || checkpoint.kind == .restore,
               let parentID = checkpoint.parentCheckpointID,
               let parent = checkpointByID[parentID] {
                NovelPolishDocumentValidator.validateFactPreservingCheckpoint(
                    checkpoint,
                    parent: parent,
                    document: document,
                    issues: &issues
                )
            }
        }

        for checkpoint in document.checkpoints {
            var visited: Set<NovelCheckpointID> = []
            var current: NovelBranchCheckpointRecord? = checkpoint
            while let node = current {
                guard visited.insert(node.id).inserted else {
                    issues.append("Checkpoint graph contains a cycle at \(node.id).")
                    break
                }
                current = node.parentCheckpointID.flatMap { checkpointByID[$0] }
            }
        }
        validateCheckpointLineage(
            document,
            checkpointByID: checkpointByID,
            initialCheckpoint: initialCheckpoints.first,
            issues: &issues
        )
    }

    private static func validateIdentityClarificationCheckpoint(
        _ checkpoint: NovelBranchCheckpointRecord,
        parent: NovelBranchCheckpointRecord,
        document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        guard let state = document.stateSnapshots.first(where: {
            $0.id == checkpoint.stateSnapshotID
        }), let parentState = document.stateSnapshots.first(where: {
            $0.id == parent.stateSnapshotID
        }), let clarification = state.characterIdentityClarifications.last else {
            issues.append("Identity clarification checkpoint \(checkpoint.id) has no state decision.")
            return
        }

        let mentionKey = NovelCharacterIdentityResolver.normalize(clarification.mention)
        let expectedUnresolved = parentState.unresolvedEntityNames.filter {
            NovelCharacterIdentityResolver.normalize($0) != mentionKey
        }
        if checkpoint.chapterSelections != parent.chapterSelections ||
            checkpoint.sessionCursor != parent.sessionCursor ||
            checkpoint.branchOverrideRevisionIDs != parent.branchOverrideRevisionIDs ||
            state.eventIDs != parentState.eventIDs ||
            state.summary != parentState.summary ||
            state.branchOutline != parentState.branchOutline ||
            state.settingProposalIDs != parentState.settingProposalIDs ||
            state.characterIdentityClarifications.dropLast() !=
                parentState.characterIdentityClarifications[...] ||
            clarification.operationID != checkpoint.operationID ||
            expectedUnresolved == parentState.unresolvedEntityNames ||
            state.unresolvedEntityNames != expectedUnresolved {
            issues.append("Identity clarification checkpoint \(checkpoint.id) rewrites unrelated state.")
        }
    }

    static func validateCandidates(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let checkpointByID = Dictionary(
            document.checkpoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidateByID = Dictionary(
            document.candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let initialCheckpoint = document.checkpoints.first(where: { $0.kind == .initial })

        for branch in document.branches {
            guard let session = document.sessions.first(where: { $0.id == branch.sessionID }) else {
                continue
            }
            for message in session.messages {
                guard let candidateID = message.candidateID else { continue }
                guard let candidate = candidateByID[candidateID],
                      candidate.clonedFromCandidateID == nil,
                      candidate.branchID == branch.id,
                      candidate.sessionID == session.id,
                      candidate.sourceMessageID == message.id else {
                    issues.append("Session message \(message.id) has an invalid candidate reference.")
                    continue
                }
            }
        }

        for candidate in document.candidates {
            guard let session = document.sessions.first(where: { $0.id == candidate.sessionID }),
                  session.branchID == candidate.branchID else {
                issues.append("Candidate \(candidate.id) has an invalid branch Session.")
                continue
            }
            guard let message = session.messages.first(where: { $0.id == candidate.sourceMessageID }) else {
                issues.append("Candidate \(candidate.id) has no source message.")
                continue
            }
            if message.candidateID != NovelCandidateSemantics.rootCandidateID(
                for: candidate,
                candidatesByID: candidateByID
            ) {
                issues.append("Candidate \(candidate.id) and source message disagree.")
            }
            if let sourceID = candidate.clonedFromCandidateID {
                guard let source = candidateByID[sourceID],
                      source.id != candidate.id,
                      source.branchID == candidate.branchID,
                      source.sessionID == candidate.sessionID,
                      source.sourceMessageID == candidate.sourceMessageID,
                      source.kind == candidate.kind,
                      source.content == candidate.content,
                      source.sourceChapterVersionID == candidate.sourceChapterVersionID,
                      NovelCandidateSemantics.cloneBaseMatches(
                          source,
                          currentCheckpointID: candidate.baseCheckpointID,
                          in: document
                      ),
                      source.createdAt <= candidate.createdAt,
                      source.collectedCheckpointID != nil,
                      candidate.status != .inheritedReadOnly else {
                    issues.append("Candidate \(candidate.id) has invalid clone provenance.")
                    continue
                }
                let cloneOwners = document.appliedOperations.filter { operation in
                    guard operation.kind == .cloneCandidate,
                          case let .candidateCloned(
                              _, branchID, sourceCandidateID, candidateID, _
                          ) = operation.outcome else {
                        return false
                    }
                    return branchID == candidate.branchID &&
                        sourceCandidateID == sourceID &&
                        candidateID == candidate.id
                }
                if cloneOwners.count != 1 {
                    issues.append("Candidate \(candidate.id) has no unique clone operation.")
                }
            }
            if !document.checkpoints.contains(where: { $0.id == candidate.baseCheckpointID }) {
                issues.append("Candidate \(candidate.id) has a missing base checkpoint.")
            }
            if candidate.status != .inheritedReadOnly,
               checkpointByID[candidate.baseCheckpointID] != nil,
               let initialCheckpoint,
               let branch = document.branches.first(where: { $0.id == candidate.branchID }) {
                let boundaryID = branch.forkOrigin?.checkpointID ?? initialCheckpoint.id
                if !checkpoint(
                    candidate.baseCheckpointID,
                    belongsTo: branch,
                    boundaryID: boundaryID,
                    checkpointByID: checkpointByID
                ) {
                    issues.append("Candidate \(candidate.id) base is outside its branch lineage.")
                }
            }
            if candidate.baseHeadRevision < 0 {
                issues.append("Candidate \(candidate.id) has a negative base head revision.")
            }
            if message.role != .assistant || message.content != candidate.content {
                issues.append("Candidate \(candidate.id) source message has invalid role or content.")
            }
            let rootCandidateID = NovelCandidateSemantics.rootCandidateID(
                for: candidate,
                candidatesByID: candidateByID
            )
            let matchingInterruptedRun = message.runID.flatMap { runID in
                document.activeRuns.first {
                    $0.id == runID &&
                        $0.status == .interrupted &&
                        ($0.kind == .prose || $0.kind == .regenerate) &&
                        $0.candidateID == rootCandidateID
                }
            } != nil
            // Quiet rest that over-pruned the interrupted run still leaves the
            // interrupted-draft candidate; the draft is collectable without a
            // live run to retry.
            let isInterruptedProseMessage = message.kind == .interruptedDraft &&
                (candidate.status == .interrupted || matchingInterruptedRun)
            if candidate.kind == .prose &&
                message.kind != .proseCandidate &&
                !isInterruptedProseMessage {
                issues.append("Prose candidate \(candidate.id) has the wrong message kind.")
            }
            if candidate.kind == .polish && message.kind != .polishCandidate {
                issues.append("Polish candidate \(candidate.id) has the wrong message kind.")
            }
            if let versionID = candidate.sourceChapterVersionID,
               !document.chapterVersions.contains(where: { $0.id == versionID }) {
                issues.append("Candidate \(candidate.id) has a missing source chapter version.")
            }
            if let checkpointID = candidate.collectedCheckpointID {
                guard let checkpoint = document.checkpoints.first(where: { $0.id == checkpointID }) else {
                    issues.append("Candidate \(candidate.id) has a missing collected checkpoint.")
                    continue
                }
                if checkpoint.sourceCandidateID != candidate.id {
                    issues.append("Candidate \(candidate.id) and collected checkpoint disagree.")
                }
                let baseMatches: Bool
                if checkpoint.kind == .collection, let parentID = checkpoint.parentCheckpointID {
                    baseMatches = NovelCandidateSemantics.collectionBaseMatches(
                        candidate,
                        targetCheckpointID: parentID,
                        targetHeadRevision: checkpoint.baseHeadRevision,
                        in: document
                    )
                } else {
                    baseMatches = checkpoint.parentCheckpointID == candidate.baseCheckpointID &&
                        checkpoint.baseHeadRevision == candidate.baseHeadRevision
                }
                if checkpoint.createdOnBranchID != candidate.branchID || !baseMatches {
                    issues.append("Candidate \(candidate.id) was collected across a branch or base.")
                }
            } else if candidate.status == .collected || candidate.status == .adopted {
                issues.append("Collected candidate \(candidate.id) has no checkpoint.")
            }
        }
        for checkpoint in document.checkpoints {
            guard let candidateID = checkpoint.sourceCandidateID,
                  let candidate = document.candidates.first(where: { $0.id == candidateID }) else {
                continue
            }
            if candidate.collectedCheckpointID != checkpoint.id {
                issues.append("Checkpoint \(checkpoint.id) and source candidate disagree.")
            }
        }
    }

    static func validateRunsAndPendingOperations(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let receiptIDs = Set(document.generationReceipts.map(\.id))
        for run in document.activeRuns {
            guard let branch = document.branches.first(where: { $0.id == run.branchID }),
                  let session = document.sessions.first(where: { $0.id == run.sessionID }) else {
                issues.append("Run \(run.id) has an invalid branch or Session.")
                continue
            }
            if session.id != branch.sessionID {
                issues.append("Run \(run.id) crosses branch Session ownership.")
            }
            if !receiptIDs.contains(run.receiptID) {
                issues.append("Run \(run.id) has no generation receipt.")
            }
            if run.status == .running && branch.activeRunID != run.id {
                issues.append("Running run \(run.id) is not the branch active run.")
            }
        }
        let runningGroups = Dictionary(grouping: document.activeRuns.filter {
            $0.status == .running
        }, by: \.sessionID)
        if runningGroups.values.contains(where: { $0.count > 1 }) {
            issues.append("A creation Session has multiple running runs.")
        }
        for branch in document.branches {
            guard let runID = branch.activeRunID else { continue }
            if !document.activeRuns.contains(where: {
                $0.id == runID && $0.branchID == branch.id && $0.sessionID == branch.sessionID && $0.status == .running
            }) {
                issues.append("Branch \(branch.id) active run reference is invalid.")
            }
        }

        let formalVersionIDs = Set(document.chapterVersions.map(\.id))
        let pendingOperationIDs = document.pendingOperations.map(\.operationID)
        if Set(pendingOperationIDs).count != pendingOperationIDs.count {
            issues.append("Pending operations repeat an operation ID.")
        }
        let appliedOperationIDs = Set(document.appliedOperations.map(\.operationID))
        if !Set(pendingOperationIDs).isDisjoint(with: appliedOperationIDs) {
            issues.append("A pending operation is already present in the applied ledger.")
        }
        let factAttemptOperationIDs = Set(document.factAttempts.map(\.attemptOperationID))
        if !Set(pendingOperationIDs).isDisjoint(with: factAttemptOperationIDs) {
            issues.append("A pending owner operation reuses a progress-attempt operation ID.")
        }
        let pendingBranchIDs = document.pendingOperations.map(\.branchID)
        if Set(pendingBranchIDs).count != pendingBranchIDs.count {
            issues.append("A branch has multiple pending fact transactions.")
        }
        let collectionPendings = document.pendingOperations.filter { $0.kind == .collection }
        let pendingCandidateIDs = collectionPendings.compactMap(\.candidateID)
        if Set(pendingCandidateIDs).count != pendingCandidateIDs.count {
            issues.append("A candidate has multiple pending collection operations.")
        }
        let proposedVersionIDs = collectionPendings.compactMap { $0.proposedChapterVersion?.id }
        if Set(proposedVersionIDs).count != proposedVersionIDs.count {
            issues.append("Pending collections repeat a proposed chapter version ID.")
        }
        let proposedCheckpointIDs = document.pendingOperations.compactMap(\.proposedCheckpointID)
        if Set(proposedCheckpointIDs).count != proposedCheckpointIDs.count {
            issues.append("Pending operations repeat a proposed checkpoint ID.")
        }
        let proposedStateSnapshotIDs = document.pendingOperations.compactMap(\.proposedStateSnapshotID)
        if Set(proposedStateSnapshotIDs).count != proposedStateSnapshotIDs.count {
            issues.append("Pending operations repeat a proposed state snapshot ID.")
        }
        let formalCheckpointIDs = Set(document.checkpoints.map(\.id))
        if !Set(proposedCheckpointIDs).isDisjoint(with: formalCheckpointIDs) {
            issues.append("A pending operation leaked its proposed checkpoint into formal history.")
        }
        let formalStateSnapshotIDs = Set(document.stateSnapshots.map(\.id))
        if !Set(proposedStateSnapshotIDs).isDisjoint(with: formalStateSnapshotIDs) {
            issues.append("A pending operation leaked its proposed state snapshot into formal history.")
        }
        for pending in document.pendingOperations {
            NovelManualSyncProgressValidator.validate(
                pending: pending,
                document: document,
                issues: &issues
            )
            guard let branch = document.branches.first(where: { $0.id == pending.branchID }) else {
                issues.append("Pending operation \(pending.id) has no branch.")
                continue
            }
            if !NovelDocumentValidator.isSHA256(pending.payloadSHA256) {
                issues.append("Pending operation \(pending.id) has an invalid payload hash.")
            }
            if pending.baseHeadRevision < 0 || pending.baseWorkingRevision < 0 {
                issues.append("Pending operation \(pending.id) has a negative base revision.")
            }
            if !document.checkpoints.contains(where: { $0.id == pending.baseCheckpointID }) {
                issues.append("Pending operation \(pending.id) has a missing base checkpoint.")
            }
            if pending.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Pending operation \(pending.id) has no durable selected manuscript.")
            }
            switch pending.status {
            case .pending where pending.lastError != nil:
                issues.append("Pending operation \(pending.id) has an error before becoming retryable.")
            case .retryable:
                if (pending.lastError ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    issues.append("Retryable pending operation \(pending.id) has no failure message.")
                }
            default:
                break
            }
            if pending.proposedCheckpointID == nil || pending.proposedStateSnapshotID == nil {
                issues.append("Pending operation \(pending.id) has no reserved final record IDs.")
            }
            if let proposed = pending.proposedChapterVersion,
               formalVersionIDs.contains(proposed.id) {
                issues.append("Pending operation \(pending.id) leaked its proposed version into formal history.")
            }
            switch pending.kind {
            case .collection:
                guard let candidateID = pending.candidateID,
                      let candidate = document.candidates.first(where: { $0.id == candidateID }),
                      candidate.branchID == pending.branchID else {
                    issues.append("Collection pending operation \(pending.id) has no source candidate.")
                    continue
                }
                guard let target = pending.collectionTarget,
                      let proposed = pending.proposedChapterVersion else {
                    issues.append("Collection pending operation \(pending.id) has no durable chapter target.")
                    continue
                }
                if branch.headCheckpointID != pending.baseCheckpointID ||
                    branch.headRevision != pending.baseHeadRevision ||
                    branch.workingRevision != pending.baseWorkingRevision ||
                    branch.syncStatus != .synchronized {
                    issues.append("Collection pending operation \(pending.id) is stale for its branch head.")
                }
                if pending.rebuildBaseCheckpointID != nil {
                    issues.append("Collection pending operation \(pending.id) contains a rebuild base.")
                }
                if !NovelCandidateSemantics.collectionBaseMatches(
                    candidate,
                    targetCheckpointID: pending.baseCheckpointID,
                    targetHeadRevision: pending.baseHeadRevision,
                    in: document
                ) {
                    issues.append("Pending operation \(pending.id) does not match its candidate base guard.")
                }
                if candidate.kind != .prose ||
                    (candidate.status != .available && candidate.status != .interrupted) ||
                    candidate.collectedCheckpointID != nil {
                    issues.append("Pending operation \(pending.id) source candidate is not collectable prose.")
                }
                if proposed.sourceCandidateID != candidate.id ||
                    proposed.operationID != pending.operationID ||
                    proposed.kind != .collected {
                    issues.append("Pending operation \(pending.id) proposed version does not match its source.")
                }
                if let session = document.sessions.first(where: { $0.id == candidate.sessionID }),
                   let message = session.messages.first(where: { $0.id == candidate.sourceMessageID }),
                   pending.sessionCursor != .through(sequence: message.sequence) {
                    issues.append("Collection pending operation \(pending.id) cursor does not match its candidate.")
                }
                switch target {
                case .appendToChapter(let chapterID):
                    guard let checkpoint = document.checkpoints.first(where: {
                        $0.id == pending.baseCheckpointID
                    }), let selection = checkpoint.chapterSelections.first(where: {
                        $0.chapterID == chapterID
                    }), let baseVersion = document.chapterVersions.first(where: {
                        $0.id == selection.versionID
                    }) else {
                        issues.append("Pending operation \(pending.id) has an invalid append target.")
                        continue
                    }
                    let expectedContent = NovelChapterText.appending(
                        pending.selectedText,
                        to: baseVersion.content
                    )
                    if proposed.chapterID != chapterID ||
                        proposed.title != baseVersion.title ||
                        proposed.content != expectedContent {
                        issues.append("Pending operation \(pending.id) has an invalid appended chapter version.")
                    }
                case .replaceChapter(let chapterID):
                    // 重新生成:内容是候选正文本身,不做追加拼接;标题沿用原章。
                    guard let checkpoint = document.checkpoints.first(where: {
                        $0.id == pending.baseCheckpointID
                    }), let selection = checkpoint.chapterSelections.first(where: {
                        $0.chapterID == chapterID
                    }), let baseVersion = document.chapterVersions.first(where: {
                        $0.id == selection.versionID
                    }) else {
                        issues.append("Pending operation \(pending.id) has an invalid replace target.")
                        continue
                    }
                    if proposed.chapterID != chapterID ||
                        proposed.title != baseVersion.title ||
                        proposed.content != pending.selectedText {
                        issues.append("Pending operation \(pending.id) has an invalid replaced chapter version.")
                    }
                case .createNextChapter(let chapterID, let title):
                    if proposed.chapterID != chapterID ||
                        proposed.title != title ||
                        proposed.content != pending.selectedText ||
                        document.chapters.contains(where: { $0.id == chapterID }) {
                        issues.append("Pending operation \(pending.id) has an invalid next-chapter target.")
                    }
                }
            case .manualSync:
                if pending.candidateID != nil ||
                    pending.collectionTarget != nil ||
                    pending.proposedChapterVersion != nil {
                    issues.append("Manual-sync pending operation \(pending.id) contains collection payload.")
                }
                if branch.headCheckpointID != pending.baseCheckpointID ||
                    branch.headRevision != pending.baseHeadRevision ||
                    branch.workingRevision != pending.baseWorkingRevision ||
                    branch.syncStatus != .needsSync {
                    issues.append("Manual-sync pending operation \(pending.id) is stale for its working branch.")
                }
                guard let rebuildBaseID = pending.rebuildBaseCheckpointID,
                      document.checkpoints.contains(where: { $0.id == rebuildBaseID }) else {
                    issues.append("Manual-sync pending operation \(pending.id) has no rebuild base checkpoint.")
                    continue
                }
                if !checkpointIsAncestorOrSelf(
                    rebuildBaseID,
                    of: pending.baseCheckpointID,
                    in: document
                ) {
                    issues.append("Manual-sync pending operation \(pending.id) rebuild base is outside its head lineage.")
                }
                if pending.sessionCursor == nil {
                    issues.append("Manual-sync pending operation \(pending.id) has no sync-start cursor.")
                } else if let session = document.sessions.first(where: { $0.id == branch.sessionID }),
                          case .through(let sequence) = pending.sessionCursor,
                          !session.messages.contains(where: { $0.sequence == sequence }) {
                    issues.append("Manual-sync pending operation \(pending.id) has an invalid sync-start cursor.")
                }
                do {
                    let chapters = try NovelFactTransactionReducer.decodeManualPayload(
                        pending.selectedText
                    )
                    try NovelFactTransactionReducer.validateManualPayload(
                        chapters,
                        pending: pending,
                        in: document
                    )
                } catch {
                    issues.append(
                        "Manual-sync pending operation \(pending.id) has an invalid durable rebuild payload."
                    )
                }
            }
        }
    }

    static func checkpointIsAncestorOrSelf(
        _ ancestorID: NovelCheckpointID,
        of descendantID: NovelCheckpointID,
        in document: NovelProjectDocumentV1
    ) -> Bool {
        var checkpoints: [NovelCheckpointID: NovelBranchCheckpointRecord] = [:]
        for checkpoint in document.checkpoints where checkpoints[checkpoint.id] == nil {
            checkpoints[checkpoint.id] = checkpoint
        }
        var currentID: NovelCheckpointID? = descendantID
        var visited: Set<NovelCheckpointID> = []
        while let candidateID = currentID, visited.insert(candidateID).inserted {
            if candidateID == ancestorID { return true }
            currentID = checkpoints[candidateID]?.parentCheckpointID
        }
        return false
    }

    private static func validateCheckpointLineage(
        _ document: NovelProjectDocumentV1,
        checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord],
        initialCheckpoint: NovelBranchCheckpointRecord?,
        issues: inout [String]
    ) {
        guard let initialCheckpoint else { return }
        let rootBranches = document.branches.filter { $0.forkOrigin == nil }
        if rootBranches.count != 1 || rootBranches.first?.id != initialCheckpoint.createdOnBranchID {
            issues.append("Project checkpoint history must have one root branch matching the initial checkpoint.")
        }

        for branch in document.branches {
            let boundaryID: NovelCheckpointID
            if let origin = branch.forkOrigin {
                if origin.parentBranchID == branch.id {
                    issues.append("Branch \(branch.id) forks from itself.")
                    continue
                }
                guard let parent = document.branches.first(where: { $0.id == origin.parentBranchID }) else {
                    continue
                }
                if checkpointByID[origin.checkpointID]?.kind == .initial {
                    issues.append("Branch \(branch.id) cannot fork from the internal initial checkpoint.")
                }
                let parentBoundary = parent.forkOrigin?.checkpointID ?? initialCheckpoint.id
                if !checkpoint(
                    origin.checkpointID,
                    belongsTo: parent,
                    boundaryID: parentBoundary,
                    checkpointByID: checkpointByID
                ) {
                    issues.append("Branch \(branch.id) fork checkpoint is outside its parent history.")
                }
                boundaryID = origin.checkpointID
            } else {
                boundaryID = initialCheckpoint.id
            }

            if !checkpoint(
                    branch.headCheckpointID,
                    belongsTo: branch,
                    boundaryID: boundaryID,
                    checkpointByID: checkpointByID
               ) {
                issues.append("Branch \(branch.id) head is outside its checkpoint lineage.")
            }

            validateBranchHeadTimeline(
                branch,
                boundaryID: boundaryID,
                document: document,
                checkpointByID: checkpointByID,
                issues: &issues
            )

            var visited: Set<NovelBranchID> = []
            var current: NovelBranchRecord? = branch
            while let node = current, let origin = node.forkOrigin {
                guard visited.insert(node.id).inserted else {
                    issues.append("Branch fork graph contains a cycle at \(node.id).")
                    break
                }
                current = document.branches.first(where: { $0.id == origin.parentBranchID })
            }
        }

        for checkpointRecord in document.checkpoints {
            guard let branch = document.branches.first(where: {
                $0.id == checkpointRecord.createdOnBranchID
            }) else {
                continue
            }
            let boundaryID = branch.forkOrigin?.checkpointID ?? initialCheckpoint.id
            if !checkpoint(
                checkpointRecord.id,
                belongsTo: branch,
                boundaryID: boundaryID,
                checkpointByID: checkpointByID
            ) {
                issues.append(
                    "Checkpoint \(checkpointRecord.id) is outside its creating branch lineage."
                )
            }
        }
    }

    private static func validateBranchHeadTimeline(
        _ branch: NovelBranchRecord,
        boundaryID: NovelCheckpointID,
        document: NovelProjectDocumentV1,
        checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord],
        issues: inout [String]
    ) {
        var headID = boundaryID
        var headRevision: Int64 = 0
        var workingRevision: Int64 = 0
        var consumedCheckpointIDs: Set<NovelCheckpointID> = []
        // 按 operation 预分组（保持文档顺序），替代逐 operation 整表 filter。
        var createdByOperationID: [NovelOperationID: [NovelBranchCheckpointRecord]] = [:]
        for checkpoint in document.checkpoints where
            checkpoint.kind != .initial && checkpoint.createdOnBranchID == branch.id {
            createdByOperationID[checkpoint.operationID, default: []].append(checkpoint)
        }

        for operation in document.appliedOperations {
            let created = createdByOperationID[operation.operationID] ?? []
            for checkpoint in created {
                if checkpoint.parentCheckpointID != headID ||
                    checkpoint.baseHeadRevision != headRevision {
                    issues.append(
                        "Branch \(branch.id) checkpoint timeline is not contiguous at \(checkpoint.id)."
                    )
                }
                headID = checkpoint.id
                headRevision += 1
                if checkpoint.kind == .collection ||
                    checkpoint.kind == .polish ||
                    checkpoint.kind == .restore {
                    workingRevision += 1
                }
                consumedCheckpointIDs.insert(checkpoint.id)
            }

            if operation.kind == .saveManualEdit,
               case let .manualEditSaved(
                   _, branchID, _, outcomeWorkingRevision, _
               ) = operation.outcome,
               branchID == branch.id {
                if outcomeWorkingRevision != workingRevision + 1 {
                    issues.append("Branch \(branch.id) working revision timeline is not contiguous.")
                }
                workingRevision += 1
            }

            if operation.kind == .deleteChapterFromManuscript,
               case let .chapterRemovedFromManuscript(
                   _, branchID, _, outcomeWorkingRevision, _
               ) = operation.outcome,
               branchID == branch.id {
                if outcomeWorkingRevision != workingRevision + 1 {
                    issues.append("Branch \(branch.id) working revision timeline is not contiguous.")
                }
                workingRevision += 1
            }

            guard operation.kind == .undoBranchHead,
                  case let .branchHeadMoved(
                      _, branchID, fromCheckpointID, toCheckpointID, outcomeHeadRevision, _
                  ) = operation.outcome,
                  branchID == branch.id else {
                continue
            }
            let current = checkpointByID[fromCheckpointID]
            let directParent = current.flatMap { checkpoint in
                checkpoint.parentCheckpointID.flatMap { checkpointByID[$0] }
            }
            let expectedTarget = current.flatMap {
                NovelBranchSemantics.undoTarget(
                    for: $0,
                    branch: branch,
                    checkpoints: document.checkpoints
                )
            }
            let validTargetIDs = Set([directParent?.id, expectedTarget?.id].compactMap { $0 })
            if fromCheckpointID != headID ||
                !validTargetIDs.contains(toCheckpointID) ||
                outcomeHeadRevision != headRevision + 1 {
                issues.append("Branch \(branch.id) undo timeline is not contiguous.")
            }
            headID = toCheckpointID
            headRevision += 1
            workingRevision += 1
        }

        let ownedCheckpointIDs = Set(document.checkpoints.filter {
            $0.kind != .initial && $0.createdOnBranchID == branch.id
        }.map(\.id))
        if consumedCheckpointIDs != ownedCheckpointIDs ||
            headID != branch.headCheckpointID ||
            headRevision != branch.headRevision ||
            workingRevision != branch.workingRevision {
            issues.append("Branch \(branch.id) head does not match its operation timeline.")
        }
    }

    private static func checkpoint(
        _ checkpointID: NovelCheckpointID,
        belongsTo branch: NovelBranchRecord,
        boundaryID: NovelCheckpointID,
        checkpointByID: [NovelCheckpointID: NovelBranchCheckpointRecord]
    ) -> Bool {
        var visited: Set<NovelCheckpointID> = []
        var currentID = checkpointID
        while currentID != boundaryID {
            guard visited.insert(currentID).inserted,
                  let checkpoint = checkpointByID[currentID],
                  checkpoint.createdOnBranchID == branch.id,
                  let parentID = checkpoint.parentCheckpointID else {
                return false
            }
            currentID = parentID
        }
        return checkpointByID[boundaryID] != nil
    }
}
