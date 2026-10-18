import XCTest
@testable import iosApp

class NovelManualEditSyncTestCase: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_200_000)

    func documentWithPendingManualSync() throws -> NovelProjectDocumentV1 {
        let collected = try documentWithTwoCollectedChapters()
        let firstChapter = collected.branches[0].workingChapterSelections[0].chapterID
        let edit = manualEditCommand(
            document: collected,
            chapterID: firstChapter,
            title: "Chapter One",
            content: "Mara rewrote the first fact."
        )
        let edited = try NovelFactTransactionReducer.saveManualEdit(
            edit,
            payloadSHA256: edit.canonicalPayloadSHA256(),
            in: collected,
            now: now
        ).document
        let command = NovelSyncManualEditsCommand(
            context: mutationContext(document: edited, operationID: NovelOperationID()),
            projectID: edited.project.id,
            branchID: edited.branches[0].id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: edited.branches[0].workingRevision
        )
        return try NovelFactTransactionReducer.prepareManualSync(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: edited,
            now: now.addingTimeInterval(1)
        ).document
    }

    func copyPending(
        _ pending: NovelPendingOperationRecord,
        selectedText: String,
        rebuildBaseCheckpointID: NovelCheckpointID?,
        sessionCursor: NovelSessionCursor?
    ) -> NovelPendingOperationRecord {
        NovelPendingOperationRecord(
            id: pending.id,
            kind: pending.kind,
            status: pending.status,
            branchID: pending.branchID,
            operationID: pending.operationID,
            payloadSHA256: pending.payloadSHA256,
            baseCheckpointID: pending.baseCheckpointID,
            baseHeadRevision: pending.baseHeadRevision,
            baseWorkingRevision: pending.baseWorkingRevision,
            candidateID: pending.candidateID,
            collectionTarget: pending.collectionTarget,
            selectedText: selectedText,
            proposedChapterVersion: pending.proposedChapterVersion,
            proposedCheckpointID: pending.proposedCheckpointID,
            proposedStateSnapshotID: pending.proposedStateSnapshotID,
            rebuildBaseCheckpointID: rebuildBaseCheckpointID,
            sessionCursor: sessionCursor,
            createdAt: pending.createdAt,
            lastError: pending.lastError
        )
    }

    func documentWithTwoCollectedChapters() throws -> NovelProjectDocumentV1 {
        var document = try NovelTestFixtures.document()
        document = try documentWithCandidate("Mara kept the first fact.", in: document)
        document = try collectLastCandidate(
            in: document,
            title: "Chapter One",
            evidence: "Mara kept the first fact."
        )
        document = try documentWithCandidate("Ivo kept the second fact.", in: document)
        return try collectLastCandidate(
            in: document,
            title: "Chapter Two",
            evidence: "Ivo kept the second fact."
        )
    }

    func collectLastCandidate(
        in document: NovelProjectDocumentV1,
        title: String,
        evidence: String
    ) throws -> NovelProjectDocumentV1 {
        let candidate = try XCTUnwrap(document.candidates.last)
        let command = collectCommand(document: document, candidate: candidate, title: title)
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: document,
            now: now
        )
        return try NovelFactTransactionReducer.finalizeCollection(
            pendingID: command.pendingID,
            delta: NovelStateDeltaV1(
                schemaVersion: 1,
                stateSummary: evidence,
                events: [NovelStateEventV1(
                    id: "event-\(document.checkpoints.count)",
                    kind: "fact",
                    summary: evidence,
                    entityReferences: [],
                    evidence: evidence
                )],
                characterChanges: [],
                relationshipChanges: [],
                foreshadowingChanges: [],
                unresolvedEntityNames: [],
                branchOutlinePatch: nil,
                settingProposals: []
            ),
            artifacts: try NovelTestFixtures.factTransactionArtifacts(
                document: prepared.document,
                pendingID: command.pendingID
            ),
            in: prepared.document,
            now: now.addingTimeInterval(1)
        ).document
    }

    func appendLastCandidate(
        in document: NovelProjectDocumentV1,
        chapterID: NovelChapterID,
        evidence: String
    ) throws -> NovelProjectDocumentV1 {
        let candidate = try XCTUnwrap(document.candidates.last)
        let command = NovelCollectCandidateCommand(
            context: mutationContext(document: document, operationID: NovelOperationID()),
            projectID: document.project.id,
            branchID: candidate.branchID,
            pendingID: NovelPendingOperationID(),
            candidateID: candidate.id,
            selection: NovelParagraphSelection(
                paragraphIDs: NovelParagraphParser.paragraphs(in: candidate.content).map(\.id)
            ),
            target: .appendToChapter(chapterID),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID()
        )
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: document,
            now: now
        )
        XCTAssertEqual(
            prepared.pending.proposedChapterVersion?.sourceChapterVersionID,
            document.branches[0].workingChapterSelections.first(where: {
                $0.chapterID == chapterID
            })?.versionID
        )
        return try NovelFactTransactionReducer.finalizeCollection(
            pendingID: command.pendingID,
            delta: NovelStateDeltaV1(
                schemaVersion: 1,
                stateSummary: evidence,
                events: [NovelStateEventV1(
                    id: "append-event",
                    kind: "fact",
                    summary: evidence,
                    entityReferences: [],
                    evidence: evidence
                )],
                characterChanges: [],
                relationshipChanges: [],
                foreshadowingChanges: [],
                unresolvedEntityNames: [],
                branchOutlinePatch: nil,
                settingProposals: []
            ),
            artifacts: try NovelTestFixtures.factTransactionArtifacts(
                document: prepared.document,
                pendingID: command.pendingID
            ),
            in: prepared.document,
            now: now.addingTimeInterval(1)
        ).document
    }

    func collectCommand(
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord,
        title: String = "Chapter Three",
        pendingID: NovelPendingOperationID = NovelPendingOperationID()
    ) -> NovelCollectCandidateCommand {
        NovelCollectCandidateCommand(
            context: mutationContext(document: document, operationID: NovelOperationID()),
            projectID: document.project.id,
            branchID: candidate.branchID,
            pendingID: pendingID,
            candidateID: candidate.id,
            selection: NovelParagraphSelection(
                paragraphIDs: NovelParagraphParser.paragraphs(in: candidate.content).map(\.id)
            ),
            target: .createNextChapter(chapterID: NovelChapterID(), title: title),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID()
        )
    }

    func manualEditCommand(
        document: NovelProjectDocumentV1,
        chapterID: NovelChapterID,
        title: String,
        content: String
    ) -> NovelSaveManualEditCommand {
        NovelSaveManualEditCommand(
            context: mutationContext(document: document, operationID: NovelOperationID()),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            chapterID: chapterID,
            versionID: NovelChapterVersionID(),
            title: title,
            content: content,
            factCompatibilityID: UUID(),
            expectedWorkingRevision: document.branches[0].workingRevision
        )
    }

    func mutationContext(
        document: NovelProjectDocumentV1,
        operationID: NovelOperationID
    ) -> NovelMutationContext {
        NovelMutationContext(
            operationID: operationID,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
    }

    /// `needsSync` 时正文 planner 会拒。本 helper 只挂一条可收录候选，不假装开过正式正文。
    func documentWithAvailableCandidate(
        _ content: String,
        in document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        var next = document
        let branch = next.branches[0]
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let sequence = (next.sessions[0].messages.last?.sequence ?? -1) + 1
        next.sessions[0].messages.append(NovelSessionMessageRecord(
            id: messageID,
            sequence: sequence,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: content,
            createdAt: now,
            runID: nil,
            candidateID: candidateID
        ))
        next.sessions[0].revision += 1
        next.candidates.append(NovelCandidateRecord(
            id: candidateID,
            kind: .prose,
            branchID: branch.id,
            sessionID: branch.sessionID,
            sourceMessageID: messageID,
            baseCheckpointID: branch.headCheckpointID,
            baseHeadRevision: branch.headRevision,
            status: .available,
            content: content,
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            createdAt: now
        ))
        try NovelDocumentValidator.validate(next)
        return next
    }

    func documentWithCandidate(
        _ content: String,
        in document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        let branch = document.branches[0]
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branch.id,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "Write a chapter.",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: NovelCandidateID(),
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
        let plan = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: branch.id,
                promptKind: .proseWholeChapter,
                userText: request.userText,
                budget: NovelInjectionBudget(
                    maxEstimatedInputTokens: request.inputBudgetTokens,
                    chapterTailCharacterLimit: 6_000,
                    maximumRecentSessionMessages: 12
                )
            )
        )
        let injection = NovelInjectionReceiptRecord(
            id: request.injectionReceiptID,
            runID: request.id,
            projectID: request.projectID,
            branchID: request.branchID,
            plan: plan,
            overrides: .none,
            providerID: "provider-id",
            modelID: "model-id",
            parameters: [:],
            createdAt: now
        )
        let generation = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: injection.providerID,
            modelID: injection.modelID,
            promptVersion: injection.promptVersion,
            injectionReceiptID: injection.id,
            parameters: [:],
            requestSHA256: NovelDocumentValidator.sha256(plan.canonicalInput + "\nMODEL REQUEST"),
            createdAt: now
        )
        let started = try NovelGenerationReducer.begin(
            request,
            artifacts: NovelGenerationStartArtifacts(
                injectionReceipt: injection,
                generationReceipt: generation
            ),
            in: document,
            now: now
        ).document
        return try NovelGenerationReducer.complete(
            runID: request.id,
            content: content,
            in: started,
            now: now.addingTimeInterval(1)
        ).document
    }

    func rebuildOutput() -> NovelStateRebuildV1 {
        NovelStateRebuildV1(
            schemaVersion: 1,
            stateSummary: "Mara rewrote the first fact while Ivo kept the second.",
            branchOutline: "Mara and Ivo continue from the rewritten opening.",
            events: [NovelStateEventV1(
                id: "rebuilt-event",
                kind: "revision",
                summary: "Mara rewrote the first fact.",
                entityReferences: ["Mara"],
                evidence: "Mara rewrote the first fact."
            )],
            characterStates: [NovelCharacterStateFactV1(
                id: "rebuilt-character",
                characterName: "Mara",
                attribute: "agency",
                value: "rewrote the fact",
                evidence: "Mara rewrote the first fact."
            )],
            relationships: [NovelRelationshipFactV1(
                id: "rebuilt-relationship",
                sourceEntity: "Mara",
                targetEntity: "Ivo",
                relationship: "continuity",
                state: "their facts coexist",
                evidence: "Ivo kept the second fact."
            )],
            foreshadowing: [NovelForeshadowingFactV1(
                id: "rebuilt-thread",
                thread: "second fact",
                status: .advanced,
                summary: "Ivo preserves the second fact.",
                evidence: "Ivo kept the second fact."
            )],
            unresolvedEntityNames: ["Mara", "Ivo"],
            settingProposals: [NovelSettingProposalDraftV1(
                id: "rebuilt-proposal",
                title: "Fact rules",
                content: "Clarify how facts can be rewritten.",
                evidence: "Mara rewrote the first fact."
            )]
        )
    }
}
