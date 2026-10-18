import XCTest
@testable import iosApp

final class NovelDomainIntegrityRegressionTests: NovelManualEditSyncTestCase {
    func testDeletingChapterFromParentKeepsForkManuscriptVisible() throws {
        let collected = try NovelBranchTestFixtures.documentWithCollectedCandidate()
        let parentID = collected.branches[0].id
        let fork = NovelBranchTestFixtures.forkCommand(
            document: collected,
            sourceBranchID: parentID,
            checkpointID: collected.branches[0].headCheckpointID,
            name: "Alternate manuscript"
        )
        let forked = try NovelReducer.apply(.forkBranch(fork), to: collected).document
        let childBefore = try NovelBranchTestFixtures.branch(fork.branchID, in: forked)
        let chapterID = try XCTUnwrap(childBefore.workingChapterSelections.first?.chapterID)
        let childMarkdown = try NovelMarkdownExporter.export(forked, branchID: fork.branchID)

        let deleted = try delete(chapterID, from: parentID, in: forked)
        let childAfter = try NovelBranchTestFixtures.branch(fork.branchID, in: deleted)

        XCTAssertEqual(childAfter, childBefore)
        XCTAssertNil(deleted.chapters.first { $0.id == chapterID }?.discardedAt)
        XCTAssertEqual(
            NovelWorkspaceLedger.liveWorkingSelections(branch: childAfter, in: deleted),
            childBefore.workingChapterSelections
        )
        XCTAssertEqual(
            try NovelMarkdownExporter.export(deleted, branchID: fork.branchID).markdown,
            childMarkdown.markdown
        )
        XCTAssertFalse(childMarkdown.markdown.isEmpty)
        XCTAssertTrue(try NovelBranchTestFixtures.branch(parentID, in: deleted)
            .workingChapterSelections.isEmpty)
    }

    func testClarifyingIdentityPreservesChapterPlotsAndStaleGate() throws {
        var document = try documentWithTwoCollectedChapters()
        let selections = document.branches[0].workingChapterSelections
        let modules = [
            NovelChapterPlotModule(chapterID: selections[0].chapterID, text: "Opening revised."),
            NovelChapterPlotModule(
                chapterID: selections[1].chapterID,
                text: "Later consequences await author resolution.",
                stale: true
            )
        ]
        try replaceCurrentPlots(modules, unresolvedNames: ["Mara"], in: &document)
        let branch = document.branches[0]
        XCTAssertTrue(NovelWorkspaceLedger.hasUnresolvedChapterPlots(branchID: branch.id, in: document))

        let clarified = try NovelReducer.apply(.clarifyCharacterIdentity(
            NovelClarifyCharacterIdentityCommand(
                context: mutationContext(document: document, operationID: NovelOperationID()),
                projectID: document.project.id,
                branchID: branch.id,
                checkpointID: NovelCheckpointID(),
                stateSnapshotID: NovelStateSnapshotID(),
                mention: "Mara",
                clarification: "Mara is the archive keeper."
            )
        ), to: document).document
        let snapshot = try currentSnapshot(in: clarified)

        XCTAssertEqual(snapshot.chapterPlots, modules)
        XCTAssertTrue(NovelWorkspaceLedger.hasUnresolvedChapterPlots(branchID: branch.id, in: clarified))
        XCTAssertFalse(snapshot.unresolvedEntityNames.contains("Mara"))
        XCTAssertEqual(snapshot.characterIdentityClarifications.last?.mention, "Mara")
    }

    func testGhostwriteAdjudicationPreservesPriorPlotsAndAddsCollectedChapter() throws {
        var document = try documentWithTwoCollectedChapters()
        let priorModules = document.branches[0].workingChapterSelections.enumerated().map {
            NovelChapterPlotModule(chapterID: $0.element.chapterID, text: "Curated chapter \($0.offset + 1).")
        }
        try replaceCurrentPlots(priorModules, in: &document)
        let branchID = document.branches[0].id
        let planID = NovelChapterPlanID()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: mutationContext(document: document, operationID: NovelOperationID()),
            projectID: document.project.id,
            branchID: branchID,
            planID: planID,
            status: .confirmed,
            outlinePlacement: "Chapter Three",
            goalAndConflict: "Mara opens the archive.",
            mustHappen: ["Mara opens the archive."],
            mustNotHappen: [],
            endingHook: "A bell rings.",
            visibleFacts: []
        )), to: document).document
        let plan = try XCTUnwrap(document.confirmedChapterPlan(for: branchID))
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branchID,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "Write the next chapter.",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: NovelCandidateID(),
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            ghostwritePlanID: plan.id,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
        let started = try NovelGenerationReducer.begin(
            request,
            artifacts: NovelBranchTestFixtures.generationArtifacts(document: document, request: request),
            in: document
        ).document
        document = try NovelGenerationReducer.complete(
            runID: request.id,
            content: "Mara opened the archive.",
            in: started
        ).document
        let candidate = try XCTUnwrap(document.candidates.first { $0.id == request.candidateID })
        var command = collectCommand(document: document, candidate: candidate)
        command.source = .systemAutoCollect
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: document
        )
        let collected = try NovelFactTransactionReducer.commitGhostwriteAdjudication(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            planID: plan.id,
            planDigest: plan.contentDigest,
            delta: NovelStateDeltaV1(
                schemaVersion: 1,
                stateSummary: "Mara opened the archive.",
                events: [NovelStateEventV1(
                    id: "archive-opened",
                    kind: "discovery",
                    summary: "Mara opened the archive.",
                    entityReferences: [],
                    evidence: "Mara opened the archive."
                )],
                characterChanges: [],
                relationshipChanges: [],
                foreshadowingChanges: [],
                unresolvedEntityNames: [],
                branchOutlinePatch: nil,
                settingProposals: []
            ),
            artifacts: NovelTestFixtures.factTransactionArtifacts(
                document: prepared.document,
                pendingID: command.pendingID
            ),
            in: document
        ).document
        let snapshot = try currentSnapshot(in: collected)
        let version = try XCTUnwrap(collected.chapterVersions.last)

        XCTAssertEqual(Array(snapshot.chapterPlots.prefix(priorModules.count)), priorModules)
        XCTAssertEqual(snapshot.chapterPlots.map(\.chapterID), collected.branches[0].workingChapterSelections.map(\.chapterID))
        XCTAssertEqual(snapshot.chapterPlots.last?.text, NovelWorkspaceLedger.excerpt(title: version.title, content: version.content))
        XCTAssertEqual(snapshot.chapterPlots.last?.stale, false)
        XCTAssertEqual(collected.checkpoints.last?.stateSnapshotID, snapshot.id)
        XCTAssertEqual(snapshot.summary, "Mara opened the archive.")
    }

    func testManualSyncRefreshesRebuiltChapterPlotsWithoutStaleFlags() throws {
        var document = try documentWithCandidate("Mara kept the first fact.", in: NovelTestFixtures.document())
        document = try collectLastCandidate(in: document, title: "Chapter One", evidence: "Mara kept the first fact.")
        let firstID = document.branches[0].workingChapterSelections[0].chapterID
        let curatedPlot = "Author-curated opening plot."
        document = try NovelWorkspacePlotCommit.applyChapterModule(
            to: document,
            branchID: document.branches[0].id,
            chapterID: firstID,
            chapterTitle: "Chapter One",
            chapterContent: "Mara kept the first fact.",
            moduleText: curatedPlot
        )
        let stableCheckpointID = document.branches[0].headCheckpointID
        document = try documentWithCandidate("Ivo kept the second fact.", in: document)
        document = try collectLastCandidate(in: document, title: "Chapter Two", evidence: "Ivo kept the second fact.")
        let secondID = try XCTUnwrap(document.branches[0].workingChapterSelections.last?.chapterID)
        try replaceCurrentPlots([
            NovelChapterPlotModule(chapterID: firstID, text: curatedPlot),
            NovelChapterPlotModule(chapterID: secondID, text: "Superseded plot.", stale: true)
        ], in: &document)
        let edit = manualEditCommand(
            document: document,
            chapterID: secondID,
            title: "Chapter Two",
            content: "Ivo rewrote the second fact."
        )
        document = try NovelFactTransactionReducer.saveManualEdit(
            edit,
            payloadSHA256: edit.canonicalPayloadSHA256(),
            in: document
        ).document
        let sync = synchronizationCommand(in: document)
        let prepared = try NovelFactTransactionReducer.prepareManualSync(
            sync,
            payloadSHA256: sync.canonicalPayloadSHA256(),
            in: document
        )
        let pending = try XCTUnwrap(prepared.pending)
        let input = try NovelFactTransactionReducer.manualRebuildInput(pendingID: pending.id, in: prepared.document)
        XCTAssertEqual(input.rebuildBaseCheckpoint.id, stableCheckpointID)
        XCTAssertEqual(input.chapters.map(\.chapterID), [secondID])
        let committed = try NovelFactTransactionReducer.finalizeManualSync(
            pendingID: pending.id,
            rebuild: NovelStateRebuildV1(
                schemaVersion: 1,
                stateSummary: "Mara kept the first fact while Ivo rewrote the second.",
                branchOutline: "Continue after Ivo's revision.",
                events: [NovelStateEventV1(
                    id: "second-fact-rewritten",
                    kind: "revision",
                    summary: "Ivo rewrote the second fact.",
                    entityReferences: [],
                    evidence: "Ivo rewrote the second fact."
                )],
                characterStates: [],
                relationships: [],
                foreshadowing: [],
                unresolvedEntityNames: [],
                settingProposals: []
            ),
            artifacts: NovelTestFixtures.factTransactionArtifacts(document: prepared.document, pendingID: pending.id),
            in: prepared.document
        ).document
        let snapshot = try currentSnapshot(in: committed)
        let selections = committed.branches[0].workingChapterSelections

        XCTAssertEqual(snapshot.chapterPlots.map(\.chapterID), selections.map(\.chapterID))
        XCTAssertEqual(snapshot.chapterPlots.map(\.text), [
            curatedPlot,
            NovelWorkspaceLedger.excerpt(title: "Chapter Two", content: "Ivo rewrote the second fact.")
        ])
        XCTAssertEqual(snapshot.chapterPlots.map(\.stale), [false, false])
        XCTAssertEqual(Array(committed.stateSnapshots.prefix(document.stateSnapshots.count)), document.stateSnapshots)
        XCTAssertEqual(committed.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(committed.pendingOperations.isEmpty)
    }

    func testStructuralManualSyncPreservesCompatibleBaseChapterPlots() throws {
        var document = try documentWithCandidate("Mara kept the first fact.", in: NovelTestFixtures.document())
        document = try collectLastCandidate(in: document, title: "Chapter One", evidence: "Mara kept the first fact.")
        let firstID = document.branches[0].workingChapterSelections[0].chapterID
        let edit = manualEditCommand(
            document: document,
            chapterID: firstID,
            title: "Chapter One",
            content: "Mara rewrote the first fact."
        )
        document = try NovelFactTransactionReducer.saveManualEditWithPlot(
            edit,
            payloadSHA256: edit.canonicalPayloadSHA256(),
            moduleText: nil,
            summaryOverride: nil,
            in: document
        ).document
        let baseModules = [NovelChapterPlotModule(chapterID: firstID, text: "Author-curated opening plot.")]
        try replaceCurrentPlots(baseModules, in: &document)
        document = try documentWithCandidate("Ivo kept the second fact.", in: document)
        document = try collectLastCandidate(in: document, title: "Chapter Two", evidence: "Ivo kept the second fact.")
        let secondID = try XCTUnwrap(document.branches[0].workingChapterSelections.last?.chapterID)
        let beforeDelete = document
        document = try delete(secondID, from: document.branches[0].id, in: document)
        let sync = synchronizationCommand(in: document)

        let prepared = try NovelFactTransactionReducer.prepareManualSync(
            sync,
            payloadSHA256: sync.canonicalPayloadSHA256(),
            in: document
        )
        guard case .completed(let committed, _) = prepared else {
            return XCTFail("An unchanged manuscript prefix must complete without a model request.")
        }

        XCTAssertEqual(try currentSnapshot(in: committed).chapterPlots, baseModules)
        XCTAssertEqual(committed.branches[0].workingChapterSelections.map(\.chapterID), [firstID])
        XCTAssertEqual(committed.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(committed.pendingOperations.isEmpty)

        let restored = try NovelReducer.apply(.undoBranchHead(NovelUndoBranchHeadCommand(
            context: mutationContext(document: committed, operationID: NovelOperationID()),
            projectID: committed.project.id,
            branchID: committed.branches[0].id,
            expectedWorkingRevision: committed.branches[0].workingRevision
        )), to: committed).document

        XCTAssertEqual(restored.branches[0].workingChapterSelections, beforeDelete.branches[0].workingChapterSelections)
        XCTAssertEqual(restored.chapters, beforeDelete.chapters)
        XCTAssertEqual(
            try NovelMarkdownExporter.export(restored, branchID: restored.branches[0].id).markdown,
            try NovelMarkdownExporter.export(beforeDelete, branchID: beforeDelete.branches[0].id).markdown
        )
        XCTAssertTrue(try NovelMarkdownExporter.export(restored, branchID: restored.branches[0].id)
            .markdown.contains("Ivo kept the second fact."))
    }

    private func delete(
        _ chapterID: NovelChapterID,
        from branchID: NovelBranchID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        let branch = try NovelBranchTestFixtures.branch(branchID, in: document)
        return try NovelReducer.apply(.deleteChapterFromManuscript(NovelDeleteChapterFromManuscriptCommand(
            context: NovelBranchTestFixtures.mutationContext(document: document, branchID: branchID),
            projectID: document.project.id,
            branchID: branchID,
            chapterID: chapterID,
            expectedWorkingRevision: branch.workingRevision
        )), to: document).document
    }

    private func synchronizationCommand(in document: NovelProjectDocumentV1) -> NovelSyncManualEditsCommand {
        NovelSyncManualEditsCommand(
            context: mutationContext(document: document, operationID: NovelOperationID()),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: document.branches[0].workingRevision
        )
    }

    private func currentSnapshot(in document: NovelProjectDocumentV1) throws -> NovelStateSnapshotRecord {
        try XCTUnwrap(document.stateSnapshots.first { $0.id == document.branches[0].currentStateSnapshotID })
    }

    private func replaceCurrentPlots(
        _ modules: [NovelChapterPlotModule],
        unresolvedNames: [String]? = nil,
        in document: inout NovelProjectDocumentV1
    ) throws {
        let index = try XCTUnwrap(document.stateSnapshots.firstIndex {
            $0.id == document.branches[0].currentStateSnapshotID
        })
        let old = document.stateSnapshots[index]
        document.stateSnapshots[index] = NovelStateSnapshotRecord(
            id: old.id,
            eventIDs: old.eventIDs,
            summary: old.summary,
            branchOutline: old.branchOutline,
            unresolvedEntityNames: unresolvedNames ?? old.unresolvedEntityNames,
            createdAt: old.createdAt,
            settingProposalIDs: old.settingProposalIDs,
            characterIdentityClarifications: old.characterIdentityClarifications,
            recentWrittenHighlights: old.recentWrittenHighlights,
            chapterPlots: modules
        )
        try NovelDocumentValidator.validate(document)
    }
}
