import CryptoKit
import XCTest
@testable import iosApp

extension NovelFactTransactionLifecycleTests {
    struct Harness {
        let repository: FactObservingRepository
        let adapter: ScriptedNovelModelAdapter
        let creation: DefaultNovelCreation
    }

    struct PreparedManualSyncScenario {
        let editedDocument: NovelProjectDocumentV1
        let pendingDocument: NovelProjectDocumentV1
        let command: NovelSyncManualEditsCommand
    }

    func makeHarness(
        document: NovelProjectDocumentV1,
        scripts: [NovelModelScript],
        resolvedModel: NovelResolvedModel? = nil,
        factRequestTimeout: TimeInterval = 60
    ) async throws -> Harness {
        let repository = FactObservingRepository()
        try await repository.seed(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: resolvedModel ?? NovelResolvedModel(
                providerID: "provider-id",
                ownerProviderID: "provider-id",
                modelID: "model-id",
                wireModelID: "novel-model",
                displayName: "Novel Model",
                contextWindowTokens: 128_000
            ),
            scripts: scripts
        )
        return Harness(
            repository: repository,
            adapter: adapter,
            creation: DefaultNovelCreation(
                repository: repository,
                modelRunner: adapter,
                factRequestTimeout: factRequestTimeout,
                now: { Date(timeIntervalSince1970: 1_700_002_000) }
            )
        )
    }

    func candidateDocument(
        content: String = "Mara opened the archive.\n\nThe bell rang twice."
    ) throws -> (
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord
    ) {
        var document = try NovelTestFixtures.document()
        let branch = document.branches[0]
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let message = NovelSessionMessageRecord(
            id: messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: content,
            createdAt: document.project.updatedAt,
            runID: nil,
            candidateID: candidateID
        )
        document.sessions[0].messages = [message]
        document.sessions[0].revision = 1
        let candidate = NovelCandidateRecord(
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
            createdAt: document.project.updatedAt
        )
        document.candidates = [candidate]
        try NovelDocumentValidator.validate(document)
        return (document, candidate)
    }

    /// 带已确认本章合同 + digest 绑定的候选，满足 systemAutoCollect 门禁。
    func autoCollectableCandidateDocument(
        content: String = "Mara opened the archive.\n\nThe bell rang twice."
    ) throws -> (
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord
    ) {
        var fixture = try candidateDocument(content: content)
        let branchID = fixture.document.branches[0].id
        let planID = NovelChapterPlanID()
        let now = fixture.document.project.updatedAt
        fixture.document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(
                configRevision: fixture.document.project.configRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branchID,
            planID: planID,
            status: .confirmed,
            outlinePlacement: "Chapter One",
            goalAndConflict: "Mara must open the archive",
            mustHappen: ["Open the archive"],
            mustNotHappen: ["Ignore the bell"],
            endingHook: "The bell rings twice",
            visibleFacts: ["The archive is sealed"]
        )), to: fixture.document, now: now).document
        let plan = try XCTUnwrap(fixture.document.confirmedChapterPlan(for: branchID))
        let unbound = fixture.document.candidates[0]
        let bound = NovelCandidateRecord(
            id: unbound.id,
            kind: unbound.kind,
            branchID: unbound.branchID,
            sessionID: unbound.sessionID,
            sourceMessageID: unbound.sourceMessageID,
            baseCheckpointID: unbound.baseCheckpointID,
            baseHeadRevision: unbound.baseHeadRevision,
            status: unbound.status,
            content: unbound.content,
            sourceChapterVersionID: unbound.sourceChapterVersionID,
            clonedFromCandidateID: unbound.clonedFromCandidateID,
            collectedCheckpointID: unbound.collectedCheckpointID,
            chapterPlanDigest: plan.contentDigest,
            ghostwritePlanID: unbound.ghostwritePlanID,
            createdAt: unbound.createdAt
        )
        fixture.document.candidates = [bound]
        try NovelDocumentValidator.validate(fixture.document)
        return (fixture.document, bound)
    }

    func ghostwriteAdjudicationCandidateDocument() throws -> (
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord
    ) {
        var fixture = try autoCollectableCandidateDocument()
        let plan = try XCTUnwrap(
            fixture.document.confirmedChapterPlan(for: fixture.document.branches[0].id)
        )
        let unbound = fixture.document.candidates[0]
        let bound = NovelCandidateRecord(
            id: unbound.id,
            kind: unbound.kind,
            branchID: unbound.branchID,
            sessionID: unbound.sessionID,
            sourceMessageID: unbound.sourceMessageID,
            baseCheckpointID: unbound.baseCheckpointID,
            baseHeadRevision: unbound.baseHeadRevision,
            status: unbound.status,
            content: unbound.content,
            sourceChapterVersionID: unbound.sourceChapterVersionID,
            clonedFromCandidateID: unbound.clonedFromCandidateID,
            collectedCheckpointID: unbound.collectedCheckpointID,
            chapterPlanDigest: plan.contentDigest,
            ghostwritePlanID: plan.id,
            createdAt: unbound.createdAt
        )
        fixture.document.candidates = [bound]
        try NovelDocumentValidator.validate(fixture.document)
        return (fixture.document, bound)
    }

    func preparedLongManualSync(
        repetitionCount: Int = 6_000
    ) throws -> PreparedManualSyncScenario {
        let fixture = try candidateDocument(content: "Mara waited.")
        let collect = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let preparedCollection = try NovelFactTransactionReducer.prepareCollection(
            collect,
            payloadSHA256: collect.canonicalPayloadSHA256(),
            in: fixture.document
        )
        let collected = try NovelFactTransactionReducer.finalizeCollection(
            pendingID: collect.pendingID,
            delta: NovelStateDeltaV1(
                schemaVersion: 1,
                stateSummary: "Mara waited.",
                events: [NovelStateEventV1(
                    id: "waited",
                    kind: "pause",
                    summary: "Mara waited.",
                    entityReferences: [],
                    evidence: "Mara waited."
                )],
                characterChanges: [],
                relationshipChanges: [],
                foreshadowingChanges: [],
                unresolvedEntityNames: [],
                branchOutlinePatch: "Mara waits.",
                settingProposals: []
            ),
            artifacts: try NovelTestFixtures.factTransactionArtifacts(
                document: preparedCollection.document,
                pendingID: collect.pendingID
            ),
            in: preparedCollection.document
        ).document
        let branch = collected.branches[0]
        let selection = try XCTUnwrap(branch.workingChapterSelections.first)
        let version = try XCTUnwrap(collected.chapterVersions.first(where: {
            $0.id == selection.versionID
        }))
        let longContent = Array(
            repeating: "Mara waited.",
            count: repetitionCount
        ).joined(separator: " ")
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: collected.project.revision,
                expectedConfigRevision: collected.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: collected.project.id,
            branchID: branch.id,
            chapterID: version.chapterID,
            versionID: NovelChapterVersionID(),
            title: version.title,
            content: longContent,
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let edited = try NovelFactTransactionReducer.saveManualEdit(
            edit,
            payloadSHA256: edit.canonicalPayloadSHA256(),
            in: collected
        ).document
        let editedBranch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: editedBranch.headRevision
            ),
            projectID: edited.project.id,
            branchID: editedBranch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: editedBranch.workingRevision
        )
        let prepared = try NovelFactTransactionReducer.prepareManualSync(
            sync,
            payloadSHA256: sync.canonicalPayloadSHA256(),
            in: edited
        ).document
        return PreparedManualSyncScenario(
            editedDocument: edited,
            pendingDocument: prepared,
            command: sync
        )
    }

    func collectCommand(
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord
    ) -> NovelCollectCandidateCommand {
        let branch = document.branches[0]
        let paragraphIDs = NovelParagraphParser.paragraphs(
            in: candidate.content
        ).map(\.id)
        return NovelCollectCandidateCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: document.project.revision,
                expectedConfigRevision: document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: document.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            candidateID: candidate.id,
            selection: NovelParagraphSelection(paragraphIDs: paragraphIDs),
            target: .createNextChapter(
                chapterID: NovelChapterID(),
                title: "Chapter One"
            ),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID()
        )
    }

    func retryCommand(
        document: NovelProjectDocumentV1,
        pendingID: NovelPendingOperationID
    ) -> NovelRetryPendingCommand {
        NovelRetryPendingCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: document.project.revision,
                expectedConfigRevision: document.project.configRevision,
                expectedBranchHeadRevision: document.branches[0].headRevision
            ),
            projectID: document.project.id,
            pendingID: pendingID
        )
    }

    func validDeltaJSON(
        summary: String = "Mara entered the archive.",
        evidence: String = "Mara opened the archive.",
        outlinePatch: String? = "Mara investigates the archive."
    ) -> String {
        let outlineField = outlinePatch.map { "\"branchOutlinePatch\": \"\($0)\"," }
            ?? "\"branchOutlinePatch\": null,"
        return """
        {
          "schemaVersion": 1,
          "stateSummary": "\(summary)",
          "events": [{
            "id": "event-archive",
            "kind": "discovery",
            "summary": "Mara entered the archive.",
            "entityReferences": ["Mara"],
            "evidence": "\(evidence)"
          }],
          "characterChanges": [],
          "relationshipChanges": [],
          "foreshadowingChanges": [],
          "unresolvedEntityNames": ["Mara"],
          \(outlineField)
          "settingProposals": []
        }
        """
    }

    func validRebuildJSON(summary: String = "The edited archive scene is canonical.") -> String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "\(summary)",
          "branchOutline": "Mara investigates the revised archive scene.",
          "events": [{
            "id": "event-rebuilt-archive",
            "kind": "discovery",
            "summary": "Mara entered the revised archive.",
            "entityReferences": ["Mara"],
            "evidence": "Mara forced open the archive door."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": ["Mara"],
          "settingProposals": []
        }
        """
    }

    func plotPointerScript() -> NovelModelScript {
        NovelModelScript(steps: [
            .delta("""
            # 本章
            - Collected chapter pointer

            # 当前
            The collected chapter is now part of the working manuscript.
            """),
            .complete,
        ])
    }

    func factSyncRequests(in requests: [NovelModelRequest]) -> [NovelModelRequest] {
        requests.filter { request in
            request.messages.contains {
                $0.content.contains("NEWLY COLLECTED MANUSCRIPT")
                    || $0.content.contains("ORDERED MANUSCRIPT INPUT")
            }
        }
    }

    /// Builds the legacy needsSync precondition with raw reducers only:
    /// collect without plot sync (branch → needsSync) + a plot-less manual
    /// edit (still needsSync). No model calls, no creation cache involved.
    /// Contract v1.1 D-B made production collect/edit commit their plot
    /// atomically, so the manual-sync engine tests fabricate the legacy
    /// document before the harness is created.
    func legacyCollectAndEditDocument(
        fixture: (document: NovelProjectDocumentV1, candidate: NovelCandidateRecord),
        editedContent: String? = nil
    ) throws -> NovelProjectDocumentV1 {
        let collect = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let collected = try NovelFactTransactionReducer.commitCollectionWithoutStateSync(
            collect,
            payloadSHA256: try NovelAction.collectCandidate(collect).canonicalPayloadSHA256(),
            in: fixture.document,
            now: Date()
        ).document
        let collectedBranch = collected.branches[0]
        let version = try XCTUnwrap(collected.chapterVersions.last)
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: collected.project.revision,
                expectedConfigRevision: collected.project.configRevision,
                expectedBranchHeadRevision: collectedBranch.headRevision
            ),
            projectID: collected.project.id,
            branchID: collectedBranch.id,
            chapterID: version.chapterID,
            versionID: NovelChapterVersionID(),
            title: version.title,
            content: editedContent ?? (version.content + "\n\nMara forced open the archive door."),
            factCompatibilityID: UUID(),
            expectedWorkingRevision: collectedBranch.workingRevision
        )
        return try NovelFactTransactionReducer.saveManualEdit(
            edit,
            payloadSHA256: try NovelAction.saveManualEdit(edit).canonicalPayloadSHA256(),
            in: collected,
            now: Date()
        ).document
    }

    func collectThenSync(
        edited: NovelProjectDocumentV1,
        harness: Harness
    ) async throws {
        let branch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: edited.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.workingRevision
        )
        guard case .manualSyncCommitted = try await harness.creation.perform(
            .syncManualEdits(sync)
        ) else {
            return XCTFail("Expected manual sync to commit after repair")
        }
    }

    func validArchiveRebuildJSON() -> String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "Mara entered the archive and heard the bell.",
          "branchOutline": "Mara investigates the archive.",
          "events": [{
            "id": "event-rebuilt-archive",
            "kind": "discovery",
            "summary": "Mara entered the archive.",
            "entityReferences": ["Mara"],
            "evidence": "Mara opened the archive."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": ["Mara"],
          "settingProposals": []
        }
        """
    }

    func validChunkRebuildJSON() -> String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "Mara continues waiting.",
          "branchOutline": "Mara remains in place while time passes.",
          "events": [{
            "id": "waited",
            "kind": "pause",
            "summary": "Mara waited.",
            "entityReferences": [],
            "evidence": "Mara waited."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": [],
          "settingProposals": []
        }
        """
    }

    func canonicalSHA256<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func eventually(
        timeout: TimeInterval = 1,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

actor FactObservingRepository: NovelProjectPersisting {
    private let base = InMemoryNovelProjectRepository()
    private var committedDocuments: [NovelProjectDocumentV1] = []
    private var remainingCommitFailures = 0
    private var shouldPauseAfterFactRequestReceiptCommit = false
    private var factRequestReceiptCommitPaused = false
    private var factRequestReceiptCommitContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseAfterManualProgressCommit = false
    private var manualProgressCommitPaused = false
    private var manualProgressCommitContinuation: CheckedContinuation<Void, Never>?

    func seed(_ document: NovelProjectDocumentV1) async throws {
        _ = try await base.createProject(document)
    }

    func document(_ projectID: NovelProjectID) async throws -> NovelProjectDocumentV1 {
        try await base.loadProject(id: projectID).document
    }

    func commits() -> [NovelProjectDocumentV1] { committedDocuments }

    func failNextCommits(_ count: Int) {
        remainingCommitFailures = count
    }

    func pauseAfterNextFactRequestReceiptCommit() {
        shouldPauseAfterFactRequestReceiptCommit = true
    }

    func isFactRequestReceiptCommitPaused() -> Bool {
        factRequestReceiptCommitPaused
    }

    func resumeFactRequestReceiptCommit() {
        factRequestReceiptCommitContinuation?.resume()
        factRequestReceiptCommitContinuation = nil
        factRequestReceiptCommitPaused = false
    }

    func pauseAfterNextManualProgressCommit() {
        shouldPauseAfterManualProgressCommit = true
    }

    func isManualProgressCommitPaused() -> Bool {
        manualProgressCommitPaused
    }

    func resumeManualProgressCommit() {
        manualProgressCommitContinuation?.resume()
        manualProgressCommitContinuation = nil
        manualProgressCommitPaused = false
    }

    func listProjects() async throws -> [NovelProjectSummary] {
        try await base.listProjects()
    }

    func loadProject(id: NovelProjectID) async throws -> NovelLoadedProject {
        try await base.loadProject(id: id)
    }

    func createProject(_ document: NovelProjectDocumentV1) async throws -> NovelLoadedProject {
        try await base.createProject(document)
    }

    func commitProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        if remainingCommitFailures > 0 {
            remainingCommitFailures -= 1
            throw NovelError.repositoryFailure("Injected fact transaction write failure.")
        }
        let previous = try await base.loadProject(id: document.project.id).document
        let previousChunkCount = previous.pendingOperations.reduce(0) {
            $0 + ($1.manualSyncProgress?.completedChunks.count ?? 0)
        }
        let nextChunkCount = document.pendingOperations.reduce(0) {
            $0 + ($1.manualSyncProgress?.completedChunks.count ?? 0)
        }
        let shouldPauseForFactRequest = shouldPauseAfterFactRequestReceiptCommit &&
            document.injectionReceipts.count == previous.injectionReceipts.count + 1 &&
            document.generationReceipts.count == previous.generationReceipts.count + 1 &&
            document.injectionReceipts.last?.factTransaction != nil &&
            document.pendingOperations == previous.pendingOperations
        let shouldPause = shouldPauseAfterManualProgressCommit &&
            nextChunkCount == previousChunkCount + 1
        let loaded = try await base.commitProject(
            document,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
        committedDocuments.append(loaded.document)
        if shouldPauseForFactRequest {
            shouldPauseAfterFactRequestReceiptCommit = false
            factRequestReceiptCommitPaused = true
            await withCheckedContinuation { continuation in
                factRequestReceiptCommitContinuation = continuation
            }
        }
        if shouldPause {
            shouldPauseAfterManualProgressCommit = false
            manualProgressCommitPaused = true
            await withCheckedContinuation { continuation in
                manualProgressCommitContinuation = continuation
            }
        }
        return loaded
    }

    func restorePreviousProject(
        id: NovelProjectID,
        expectedDocumentSHA256: String
    ) async throws -> NovelLoadedProject {
        try await base.restorePreviousProject(
            id: id,
            expectedDocumentSHA256: expectedDocumentSHA256
        )
    }

    func listRecoverySidecars() async throws -> [NovelRecoverySidecarV1] {
        try await base.listRecoverySidecars()
    }

    func writeRecoverySidecar(_ sidecar: NovelRecoverySidecarV1) async throws {
        try await base.writeRecoverySidecar(sidecar)
    }

    func removeRecoverySidecar(projectID: NovelProjectID, runID: NovelRunID) async throws {
        try await base.removeRecoverySidecar(projectID: projectID, runID: runID)
    }
}
