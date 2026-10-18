import Foundation

enum NovelSessionPresentation {
    static func project(_ input: NovelSessionProjectionInput) -> NovelSessionListModel {
        let index = NovelSessionProjectionIndex(input: input)
        return project(input, index: index)
    }

    static func prepareDurable(_ input: NovelSessionProjectionInput) -> NovelSessionPreparedProjection {
        let index = NovelSessionProjectionIndex(input: input)
        return NovelSessionPreparedProjection(
            model: project(input, index: index),
            index: index
        )
    }

    private static func project(
        _ input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionListModel {
        let messages = input.session.messages.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.id.description < rhs.id.description
        }
        let durableIDs = Set(messages.map(\.id))
        let visibleTail = input.transientTail.flatMap { tail in
            tail.branchID == input.branch.id && tail.sessionID == input.session.id ? tail : nil
        }
        let missingInterruptedRuns = input.runs
            .filter { run in
                run.branchID == input.branch.id &&
                    run.sessionID == input.session.id &&
                    run.status == .interrupted &&
                    !durableIDs.contains(run.messageID) &&
                    input.transientTail?.runID != run.id
            }
            .sorted(by: runOrder)
        let interruptedRunsByUserMessage = Dictionary(
            grouping: missingInterruptedRuns,
            by: \.userMessageID
        )
        var projectedInterruptedRunIDs: Set<NovelRunID> = []
        var rows: [NovelSessionRowModel] = []
        rows.reserveCapacity(messages.count + missingInterruptedRuns.count + 2)
        for message in messages where message.id != visibleTail?.messageID {
            rows.append(durableRow(message: message, input: input, index: index))
            for run in interruptedRunsByUserMessage[message.id] ?? [] {
                rows.append(interruptedWithoutOutputRow(
                    run: run,
                    sequence: message.sequence,
                    input: input,
                    index: index
                ))
                projectedInterruptedRunIDs.insert(run.id)
            }
        }
        for run in missingInterruptedRuns where !projectedInterruptedRunIDs.contains(run.id) {
            rows.append(interruptedWithoutOutputRow(
                run: run,
                sequence: Int64(messages.count),
                input: input,
                index: index
            ))
        }
        rows = foldingArchivedDiscussionRows(rows, input: input)
        var activeTailID: NovelMessageID?

        if let tail = visibleTail {
            if let startingUserContent = tail.startingUserContent,
               !durableIDs.contains(tail.userMessageID) {
                rows.append(startingUserRow(
                    tail: tail,
                    content: startingUserContent,
                    sequence: Int64(rows.count)
                ))
            }
            rows.append(transientRow(
                tail: tail,
                sequence: Int64(rows.count),
                input: input,
                index: index
            ))
            activeTailID = tail.messageID
        }

        return NovelSessionListModel(
            sessionID: input.session.id,
            rows: rows,
            activeTailID: activeTailID
        )
    }

    /// The durable projection is built off the main actor. A new run only needs
    /// its two transient rows, even while a newer durable revision is building.
    static func applyingTransientTail(
        to durable: NovelSessionPreparedProjection,
        input: NovelSessionProjectionInput
    ) -> NovelSessionListModel {
        guard let tail = input.transientTail,
              tail.branchID == input.branch.id,
              tail.sessionID == input.session.id else { return durable.model }
        var rows = durable.model.rows.filter { $0.id != tail.messageID }
        if let startingUserContent = tail.startingUserContent,
           !rows.contains(where: { $0.id == tail.userMessageID }) {
            rows.append(startingUserRow(
                tail: tail,
                content: startingUserContent,
                sequence: Int64(rows.count)
            ))
        }
        rows.append(transientRow(
            tail: tail,
            sequence: Int64(rows.count),
            input: input,
            index: durable.index
        ))
        return NovelSessionListModel(
            sessionID: input.session.id,
            rows: rows,
            activeTailID: tail.messageID
        )
    }

    /// While a detached live-tail projection is building, block mutations on
    /// the cached durable rows immediately. Their content and order stay put.
    static func blockingDurableActionsForLiveTail(
        in model: NovelSessionListModel,
        access: NovelProjectLoadAccess,
        lifecycle: NovelBranchLifecycle
    ) -> NovelSessionListModel {
        var changed = false
        let rows = model.rows.map { row -> NovelSessionRowModel in
            guard !row.isTransient, !row.actions.isEmpty else { return row }
            let actions = row.actions.map { availability -> NovelSessionRowActionAvailability in
                if case .viewSettingProposals = availability.action { return availability }
                if availability.blocker == .failureNotRetryable { return availability }
                let blocker: NovelSessionActionBlocker = if access != .readWrite {
                    .projectReadOnly
                } else if lifecycle != .active {
                    .branchInactive
                } else {
                    .generationRunning
                }
                return NovelSessionRowActionAvailability(
                    action: availability.action,
                    blocker: blocker
                )
            }
            guard actions != row.actions else { return row }
            changed = true
            return NovelSessionRowModel(
                id: row.id,
                sequence: row.sequence,
                role: row.role,
                mode: row.mode,
                granularity: row.granularity,
                kind: row.kind,
                content: row.content,
                reasoningContent: row.reasoningContent,
                isReasoningLive: row.isReasoningLive,
                createdAt: row.createdAt,
                runID: row.runID,
                runStatus: row.runStatus,
                candidate: row.candidate,
                committedChange: row.committedChange,
                askUser: row.askUser,
                archive: row.archive,
                transientPhase: row.transientPhase,
                actions: actions,
                digest: digest(
                    messageID: row.id,
                    transientRevision: nil,
                    transientPhase: nil,
                    runStatus: row.runStatus,
                    granularity: row.granularity,
                    candidate: row.candidate,
                    committedChange: row.committedChange,
                    askUser: row.askUser,
                    actions: actions
                ),
                lagAllowance: row.lagAllowance
            )
        }
        return changed
            ? NovelSessionListModel(
                sessionID: model.sessionID,
                rows: rows,
                activeTailID: model.activeTailID
            )
            : model
    }

    /// A paced stream changes only the transient row's content/revision. Reuse the
    /// already-projected durable rows instead of sorting/indexing the whole session
    /// again at ~21 Hz.
    static func updatingTransientTail(
        in model: NovelSessionListModel,
        with tail: NovelSessionTransientTail,
        input: NovelSessionProjectionInput?,
        prepared: NovelSessionPreparedProjection,
        localAskUserResponse: NovelAskUserResponse?
    ) -> NovelSessionListModel? {
        guard model.activeTailID == tail.messageID,
              model.activeTailIndex != nil,
              let current = model.activeTailRow else {
            return nil
        }
        guard current.runID == tail.runID else { return nil }
        if current.transientPhase != tail.phase {
            guard let input else { return nil }
            let row = transientRow(
                tail: tail,
                sequence: current.sequence,
                input: input,
                index: prepared.index
            )
            return model.replacingActiveTail(with: row)
        }
        var askUser = tail.askUser ?? current.askUser
        if let currentAskUser = askUser,
           currentAskUser.response == nil,
           let localAskUserResponse {
            askUser = NovelAskUserPresentation(
                prompt: currentAskUser.prompt,
                response: localAskUserResponse
            )
        }

        let updatedTail = NovelSessionRowModel(
            id: current.id,
            sequence: current.sequence,
            role: current.role,
            mode: current.mode,
            granularity: current.granularity,
            kind: current.kind,
            content: presentedContent(for: tail),
            reasoningContent: tail.reasoningContent,
            isReasoningLive: tail.isReasoningLive,
            createdAt: tail.startedAt,
            runID: current.runID,
            runStatus: current.runStatus,
            candidate: current.candidate,
            committedChange: current.committedChange,
            askUser: askUser,
            archive: current.archive,
            transientPhase: tail.phase,
            actions: current.actions,
            digest: digest(
                messageID: tail.messageID,
                transientRevision: tail.renderRevision,
                transientPhase: tail.phase,
                runStatus: current.runStatus,
                granularity: current.granularity,
                candidate: current.candidate,
                committedChange: current.committedChange,
                askUser: askUser,
                actions: current.actions
            ),
            lagAllowance: tail.lagAllowance
        )
        return model.replacingActiveTail(with: updatedTail)
    }

    static func durableDisplayContent(
        for kind: NovelSessionMessageKind,
        runKind: NovelRunKind?,
        content: String
    ) -> String {
        switch kind {
        case .proseCandidate, .polishCandidate:
            return NovelPromptCatalog.normalizedCandidateProse(content)
        case .interruptedDraft:
            switch runKind {
            case .prose, .regenerate, .polish:
                return NovelPromptCatalog.normalizedCandidateProse(content)
            case .quickStart, .characterProposal, .discussion, nil:
                return content
            }
        case .discussion, .userInput, .error:
            return content
        }
    }
}

extension NovelSessionPresentation {
    private static func startingUserRow(
        tail: NovelSessionTransientTail,
        content: String,
        sequence: Int64
    ) -> NovelSessionRowModel {
        NovelSessionRowModel(
            id: tail.userMessageID,
            sequence: sequence,
            role: .user,
            mode: tail.mode,
            granularity: tail.granularity,
            kind: .userInput,
            content: content,
            createdAt: tail.startedAt,
            runID: tail.runID,
            runStatus: .running,
            candidate: nil,
            committedChange: nil,
            askUser: nil,
            archive: nil,
            transientPhase: nil,
            actions: [],
            digest: digest(
                messageID: tail.userMessageID,
                transientRevision: nil,
                transientPhase: nil,
                runStatus: .running,
                granularity: tail.granularity,
                candidate: nil,
                committedChange: nil,
                askUser: nil,
                actions: []
            )
        )
    }
}

extension NovelSessionPresentation {
    private static func foldingArchivedDiscussionRows(
        _ rows: [NovelSessionRowModel],
        input: NovelSessionProjectionInput
    ) -> [NovelSessionRowModel] {
        guard case .some(.through(let archiveCursor)) = input.session.archiveCursor,
              let archives = input.session.discussionArchives,
              !archives.isEmpty else { return rows }

        let checkpointByID = Dictionary(
            input.checkpoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var activeCheckpointIDs: Set<NovelCheckpointID> = []
        var checkpointID: NovelCheckpointID? = input.branch.headCheckpointID
        while let currentID = checkpointID,
              activeCheckpointIDs.insert(currentID).inserted,
              let checkpoint = checkpointByID[currentID] {
            checkpointID = checkpoint.parentCheckpointID
        }
        let activeArchives = archives.filter {
            $0.throughSequence <= archiveCursor && activeCheckpointIDs.contains($0.checkpointID)
        }.sorted { lhs, rhs in
            if lhs.throughSequence != rhs.throughSequence {
                return lhs.throughSequence < rhs.throughSequence
            }
            return lhs.id.description < rhs.id.description
        }
        guard !activeArchives.isEmpty else { return rows }

        var result: [NovelSessionRowModel] = []
        result.reserveCapacity(rows.count + activeArchives.count)
        var rowIndex = 0
        var lowerSequence: Int64 = 0
        for archive in activeArchives {
            while rowIndex < rows.count, rows[rowIndex].sequence < lowerSequence {
                result.append(rows[rowIndex])
                rowIndex += 1
            }
            let rangeStart = rowIndex
            while rowIndex < rows.count, rows[rowIndex].sequence <= archive.throughSequence {
                rowIndex += 1
            }
            guard rangeStart < rowIndex else {
                lowerSequence = archive.throughSequence + 1
                continue
            }
            let isExpanded = input.expandedArchiveIDs.contains(archive.id)
            let range = rows[rangeStart..<rowIndex]
            let collapsedRows = range.filter(remainsVisibleWhileArchiveCollapsed)
            let revealedRowCount = range.count - collapsedRows.count
            result.append(archiveRow(
                archive,
                input: input,
                revealedRowCount: revealedRowCount,
                isExpanded: isExpanded
            ))
            if isExpanded {
                result.append(contentsOf: range)
            } else {
                // Keep uncollected prose visible so collect remains reachable without expanding.
                result.append(contentsOf: collapsedRows)
            }
            lowerSequence = archive.throughSequence + 1
        }
        result.append(contentsOf: rows[rowIndex...])
        return result
    }

    private static func remainsVisibleWhileArchiveCollapsed(_ row: NovelSessionRowModel) -> Bool {
        guard let candidate = row.candidate, candidate.kind == .prose else { return false }
        return candidate.status == .available || candidate.status == .interrupted
    }

    private static func archiveRow(
        _ archive: NovelDiscussionArchiveRecord,
        input: NovelSessionProjectionInput,
        revealedRowCount: Int,
        isExpanded: Bool
    ) -> NovelSessionRowModel {
        let chapterTitle: String
        if let chapterID = archive.chapterID,
           let index = input.branch.workingChapterSelections.firstIndex(where: {
               $0.chapterID == chapterID
           }) {
            chapterTitle = "第 \(index + 1) 章讨论已归档"
        } else {
            chapterTitle = "讨论已归档"
        }
        let presentation = NovelDiscussionArchivePresentation(
            id: archive.id,
            title: "\(chapterTitle)（\(archive.messageCount) 条）",
            summary: archive.summary,
            messageCount: archive.messageCount,
            revealedRowCount: revealedRowCount,
            isExpanded: isExpanded
        )
        return NovelSessionRowModel(
            id: archive.id,
            sequence: archive.throughSequence,
            role: .system,
            mode: .discussPlan,
            granularity: nil,
            kind: .discussion,
            content: archive.summary,
            createdAt: archive.createdAt,
            runID: nil,
            runStatus: nil,
            candidate: nil,
            committedChange: nil,
            askUser: nil,
            archive: presentation,
            transientPhase: nil,
            actions: [],
            digest: NovelSessionRowDigest(
                layout: "discussion-archive:\(archive.id.description)",
                presentation: "\(isExpanded ? "expanded" : "collapsed"):\(revealedRowCount)"
            )
        )
    }
}

extension NovelSessionPresentation {
    private static func runOrder(_ lhs: NovelActiveRunRecord, _ rhs: NovelActiveRunRecord) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.description < rhs.id.description
    }

    private static func interruptedWithoutOutputRow(
        run: NovelActiveRunRecord,
        sequence: Int64,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionRowModel {
        durableRow(
            message: NovelSessionMessageRecord(
                id: run.messageID,
                sequence: sequence,
                role: .assistant,
                mode: run.mode,
                kind: .interruptedDraft,
                content: "",
                createdAt: run.terminalAt ?? run.startedAt,
                runID: run.id,
                candidateID: nil
            ),
            input: input,
            index: index
        )
    }

    private static func durableRow(
        message: NovelSessionMessageRecord,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionRowModel {
        let candidate = presentedCandidate(for: message, index: index)
        let presentedCandidate: NovelSessionCandidatePresentation?
        let changeSummary: NovelSessionCommittedChangeSummary?
        if let candidate {
            presentedCandidate = candidatePresentation(for: candidate, index: index)
            changeSummary = committedChange(
                for: candidate,
                index: index,
                branchSyncStatus: input.branch.syncStatus
            )
        } else {
            presentedCandidate = nil
            changeSummary = nil
        }
        let actions = actions(
            for: message,
            candidate: candidate,
            input: input,
            index: index
        )
        let run = message.runID.flatMap { runID in
            index.runByID[runID]
        }
        let runStatus = run?.status
        let askUser: NovelAskUserPresentation?
        if case .some(.askUser(let prompt)) = message.interaction {
            askUser = NovelAskUserPresentation(
                prompt: prompt,
                response: index.askUserResponseByPromptMessageID[message.id]
            )
        } else {
            askUser = nil
        }
        let presentedContent: String
        if message.kind == .error, let failure = run?.terminalFailure {
            presentedContent = NovelPresentation.failureMessage(failure)
        } else if run?.kind == .quickStart, message.kind == .interruptedDraft {
            presentedContent = runStatus == .failed
                ? run?.terminalFailure.map(NovelPresentation.failureMessage) ?? ""
                : ""
        } else {
            presentedContent = message.content
        }
        let displayContent = NovelSessionPresentation.durableDisplayContent(
            for: message.kind,
            runKind: run?.kind,
            content: presentedContent
        )
        let digest = digest(
            messageID: message.id,
            transientRevision: nil,
            transientPhase: nil,
            runStatus: runStatus,
            granularity: run?.granularity,
            candidate: presentedCandidate,
            committedChange: changeSummary,
            askUser: askUser,
            actions: actions
        )
        return NovelSessionRowModel(
            id: message.id,
            sequence: message.sequence,
            role: message.role,
            mode: message.mode,
            granularity: run?.granularity,
            kind: message.kind,
            content: displayContent,
            createdAt: message.createdAt,
            runID: message.runID,
            runStatus: runStatus,
            candidate: presentedCandidate,
            committedChange: changeSummary,
            askUser: askUser,
            archive: nil,
            transientPhase: nil,
            actions: actions,
            digest: digest
        )
    }

    private static func transientRow(
        tail: NovelSessionTransientTail,
        sequence: Int64,
        input: NovelSessionProjectionInput,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionRowModel {
        let actions: [NovelSessionRowActionAvailability]
        switch tail.phase {
        case .persistenceBlocked:
            actions = [availability(
                .retryTerminalPersistence(tail.runID),
                blocker: baseMutationBlocker(
                    input: input,
                    index: index,
                    includePending: false,
                    excludingRunID: tail.runID
                )
            )]
        case .interrupted:
            var interruptedActions: [NovelSessionRowActionAvailability] = []
            if tail.kind == .proseCandidate,
               !tail.content.isEmpty,
               let candidateID = tail.candidateID {
                interruptedActions.append(availability(
                    .collectProse(candidateID),
                    blocker: transientCollectionBlocker(tail: tail, input: input, index: index)
                ))
            }
            interruptedActions.append(availability(
                .retryGeneration(tail.runID),
                blocker: transientRetryBlocker(tail: tail, input: input, index: index)
            ))
            actions = interruptedActions
        case .failed(let failure):
            actions = [availability(
                .retryGeneration(tail.runID),
                blocker: failure.isRetryable
                    ? transientRetryBlocker(tail: tail, input: input, index: index)
                    : .failureNotRetryable
            )]
        case .waitingForFirstToken, .streaming, .terminalAwaitingRefresh:
            actions = []
        }
        let presentedKind: NovelSessionMessageKind = switch tail.phase {
        case .interrupted, .failed:
            tail.content.isEmpty ? .error : .interruptedDraft
        case .waitingForFirstToken, .streaming, .terminalAwaitingRefresh, .persistenceBlocked:
            tail.kind
        }
        let askUser = tail.askUser ?? durableAskUser(
            messageID: tail.messageID,
            index: index
        )
        return NovelSessionRowModel(
            id: tail.messageID,
            sequence: sequence,
            role: .assistant,
            mode: tail.mode,
            granularity: tail.granularity,
            kind: presentedKind,
            content: presentedContent(for: tail),
            reasoningContent: tail.reasoningContent,
            isReasoningLive: tail.isReasoningLive,
            createdAt: tail.startedAt,
            runID: tail.runID,
            runStatus: transientRunStatus(for: tail.phase),
            candidate: nil,
            committedChange: nil,
            askUser: askUser,
            archive: nil,
            transientPhase: tail.phase,
            actions: actions,
            digest: digest(
                messageID: tail.messageID,
                transientRevision: tail.renderRevision,
                transientPhase: tail.phase,
                runStatus: transientRunStatus(for: tail.phase),
                granularity: tail.granularity,
                candidate: nil,
                committedChange: nil,
                askUser: askUser,
                actions: actions
            )
        )
    }

    private static func durableAskUser(
        messageID: NovelMessageID,
        index: NovelSessionProjectionIndex
    ) -> NovelAskUserPresentation? {
        guard let message = index.messageByID[messageID],
              case .some(.askUser(let prompt)) = message.interaction else {
            return nil
        }
        return NovelAskUserPresentation(
            prompt: prompt,
            response: index.askUserResponseByPromptMessageID[message.id]
        )
    }

    private static func presentedContent(for tail: NovelSessionTransientTail) -> String {
        switch tail.phase {
        case .failed(let failure):
            // Prefer humanized failure copy when there is no draft yet, or when
            // content accidentally carries a raw NSError/URL dump.
            if tail.content.isEmpty
                || NovelPresentation.looksLikeTechnicalFailureDump(tail.content) {
                return NovelPresentation.failureMessage(failure)
            }
            return tail.content
        case .persistenceBlocked(let failure):
            if tail.content.isEmpty
                || NovelPresentation.looksLikeTechnicalFailureDump(tail.content) {
                return NovelPresentation.failureMessage(failure)
            }
            return tail.content
        default:
            return tail.content
        }
    }

    private static func presentedCandidate(
        for message: NovelSessionMessageRecord,
        index: NovelSessionProjectionIndex
    ) -> NovelCandidateRecord? {
        guard let matches = index.candidatesBySourceMessageID[message.id] else { return nil }

        if let pending = matches.first(where: { index.pendingCandidateIDs.contains($0.id) }) {
            return pending
        }
        if let transaction = matches.first(where: { index.polishCandidateIDs.contains($0.id) }) {
            return transaction
        }
        if let available = matches
            .filter({ $0.status == .available })
            .max(by: candidateOrder) {
            return available
        }
        if let messageCandidateID = message.candidateID,
           let direct = matches.first(where: { $0.id == messageCandidateID }) {
            return direct
        }
        return matches.max(by: candidateOrder)
    }

    private static func candidateOrder(
        _ lhs: NovelCandidateRecord,
        _ rhs: NovelCandidateRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.description < rhs.id.description
    }

    private static func candidatePresentation(
        for candidate: NovelCandidateRecord,
        index: NovelSessionProjectionIndex
    ) -> NovelSessionCandidatePresentation {
        NovelSessionCandidatePresentation(
            id: candidate.id,
            kind: candidate.kind,
            status: candidate.status,
            sourceChapterVersionID: candidate.sourceChapterVersionID,
            pendingStatus: index.pendingByCandidateID[candidate.id]?.status,
            polishTransactionStatus: index.polishByCandidateID[candidate.id]?.status
        )
    }

    static func committedChange(
        for candidate: NovelCandidateRecord,
        index: NovelSessionProjectionIndex,
        branchSyncStatus: NovelBranchSyncStatus
    ) -> NovelSessionCommittedChangeSummary? {
        guard let checkpointID = candidate.collectedCheckpointID,
              let checkpoint = index.collectedCheckpointByKey[NovelSessionCollectedCheckpointKey(
                  checkpointID: checkpointID,
                  candidateID: candidate.id
              )],
              let state = index.stateByID[checkpoint.stateSnapshotID] else {
            return nil
        }
        let parentEventIDs: Set<NovelEventID>
        if let parentID = checkpoint.parentCheckpointID,
           let parent = index.checkpointByID[parentID],
           let parentState = index.stateByID[parent.stateSnapshotID] {
            parentEventIDs = Set(parentState.eventIDs)
        } else {
            parentEventIDs = []
        }
        let eventSummaries = state.eventIDs.compactMap { id -> String? in
            guard !parentEventIDs.contains(id) else { return nil }
            return index.eventByID[id]?.summary
        }
        return NovelSessionCommittedChangeSummary(
            checkpointID: checkpoint.id,
            stateSnapshotID: state.id,
            stateSummary: state.summary,
            eventSummaries: eventSummaries,
            branchSyncStatus: branchSyncStatus
        )
    }

}
