import Foundation
import XCTest
@testable import iosApp

class NovelSessionReplayTestCase: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_710_000_000)

    struct Fixture {
        let document: NovelProjectDocumentV1
        let branch: NovelBranchRecord
        let session: NovelSessionRecord
    }

    func makeFixture() throws -> Fixture {
        let document = try NovelTestFixtures.document(now: Self.now)
        return Fixture(
            document: document,
            branch: try XCTUnwrap(document.branches.first),
            session: try XCTUnwrap(document.sessions.first)
        )
    }

    func makeInput(
        fixture: Fixture,
        branch: NovelBranchRecord? = nil,
        session: NovelSessionRecord? = nil,
        candidates: [NovelCandidateRecord] = [],
        runs: [NovelActiveRunRecord] = [],
        pending: [NovelPendingOperationRecord] = [],
        polish: [NovelPendingPolishTransactionRecord] = [],
        discardedChapterVersionIDs: Set<NovelChapterVersionID> = [],
        checkpoints: [NovelBranchCheckpointRecord]? = nil,
        states: [NovelStateSnapshotRecord]? = nil,
        events: [NovelStoryEventRecord] = [],
        proposals: [NovelSettingProposalRecord] = [],
        access: NovelProjectLoadAccess = .readWrite,
        expandedArchiveIDs: Set<NovelMessageID> = [],
        tail: NovelSessionTransientTail? = nil
    ) -> NovelSessionProjectionInput {
        NovelSessionProjectionInput(
            branch: branch ?? fixture.branch,
            session: session ?? fixture.session,
            candidates: candidates,
            runs: runs,
            pendingOperations: pending,
            polishTransactions: polish,
            discardedChapterVersionIDs: discardedChapterVersionIDs,
            checkpoints: checkpoints ?? fixture.document.checkpoints,
            stateSnapshots: states ?? fixture.document.stateSnapshots,
            events: events,
            settingProposals: proposals,
            access: access,
            expandedArchiveIDs: expandedArchiveIDs,
            transientTail: tail
        )
    }

    func makeMessage(
        id: NovelMessageID = NovelMessageID(),
        sequence: Int64,
        role: NovelSessionRole,
        mode: NovelSessionMode,
        kind: NovelSessionMessageKind,
        content: String,
        runID: NovelRunID? = nil,
        candidateID: NovelCandidateID? = nil,
        interaction: NovelSessionInteraction? = nil
    ) -> NovelSessionMessageRecord {
        NovelSessionMessageRecord(
            id: id,
            sequence: sequence,
            role: role,
            mode: mode,
            kind: kind,
            content: content,
            createdAt: Self.now,
            runID: runID,
            candidateID: candidateID,
            interaction: interaction
        )
    }

    func makeRun(
        fixture: Fixture,
        kind: NovelRunKind,
        candidateID: NovelCandidateID? = nil,
        sourceVersionID: NovelChapterVersionID? = nil,
        granularity: NovelGenerationGranularity? = nil
    ) -> NovelActiveRunRecord {
        NovelActiveRunRecord(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            requestPayloadSHA256: NovelTestFixtures.hashA,
            branchID: fixture.branch.id,
            sessionID: fixture.session.id,
            kind: kind,
            mode: kind == .discussion || kind == .quickStart ? .discussPlan : .writeProse,
            granularity: kind == .prose ? granularity ?? .wholeChapter : nil,
            userMessageID: NovelMessageID(),
            messageID: NovelMessageID(),
            candidateID: candidateID,
            sourceChapterVersionID: sourceVersionID,
            contextualCharacterMention: nil,
            baseCheckpointID: fixture.branch.headCheckpointID,
            baseHeadRevision: fixture.branch.headRevision,
            status: .running,
            partialContent: "",
            receiptID: NovelReceiptID(),
            startedAt: Self.now,
            terminalAt: nil,
            interruptionReason: nil,
            terminalFailure: nil,
            chapterPlanDigest: nil
        )
    }

    func terminalRun(
        _ run: NovelActiveRunRecord,
        status: NovelRunStatus = .completed,
        failure: NovelFailure? = nil
    ) -> NovelActiveRunRecord {
        NovelActiveRunRecord(
            id: run.id,
            operationID: run.operationID,
            requestPayloadSHA256: run.requestPayloadSHA256,
            branchID: run.branchID,
            sessionID: run.sessionID,
            kind: run.kind,
            mode: run.mode,
            granularity: run.granularity,
            userMessageID: run.userMessageID,
            messageID: run.messageID,
            candidateID: run.candidateID,
            sourceChapterVersionID: run.sourceChapterVersionID,
            contextualCharacterMention: run.contextualCharacterMention,
            baseCheckpointID: run.baseCheckpointID,
            baseHeadRevision: run.baseHeadRevision,
            status: status,
            partialContent: run.partialContent,
            receiptID: run.receiptID,
            startedAt: run.startedAt,
            terminalAt: Self.now,
            interruptionReason: status == .interrupted ? .user : nil,
            terminalFailure: failure,
            chapterPlanDigest: run.chapterPlanDigest
        )
    }

    func makeCandidate(
        fixture: Fixture,
        id: NovelCandidateID,
        sourceMessageID: NovelMessageID,
        kind: NovelCandidateKind,
        status: NovelCandidateStatus,
        content: String,
        sourceVersionID: NovelChapterVersionID? = nil,
        collectedCheckpointID: NovelCheckpointID? = nil,
        ghostwritePlanID: NovelChapterPlanID? = nil
    ) -> NovelCandidateRecord {
        NovelCandidateRecord(
            id: id,
            kind: kind,
            branchID: fixture.branch.id,
            sessionID: fixture.session.id,
            sourceMessageID: sourceMessageID,
            baseCheckpointID: fixture.branch.headCheckpointID,
            baseHeadRevision: fixture.branch.headRevision,
            status: status,
            content: content,
            sourceChapterVersionID: sourceVersionID,
            collectedCheckpointID: collectedCheckpointID,
            ghostwritePlanID: ghostwritePlanID,
            createdAt: Self.now
        )
    }

    func makePending(
        fixture: Fixture,
        candidateID: NovelCandidateID?,
        status: NovelPendingOperationStatus,
        kind: NovelPendingOperationKind = .collection
    ) -> NovelPendingOperationRecord {
        NovelPendingOperationRecord(
            id: NovelPendingOperationID(),
            kind: kind,
            status: status,
            branchID: fixture.branch.id,
            operationID: NovelOperationID(),
            payloadSHA256: NovelTestFixtures.hashA,
            baseCheckpointID: fixture.branch.headCheckpointID,
            baseHeadRevision: fixture.branch.headRevision,
            candidateID: candidateID,
            collectionTarget: nil,
            selectedText: "text",
            proposedChapterVersion: nil,
            createdAt: Self.now,
            lastError: status == .retryable ? "retry" : nil
        )
    }

    func makePolishTransaction(
        fixture: Fixture,
        candidate: NovelCandidateRecord,
        status: NovelPolishTransactionStatus
    ) -> NovelPendingPolishTransactionRecord {
        NovelPendingPolishTransactionRecord(
            id: NovelPendingOperationID(),
            operationID: NovelOperationID(),
            payloadSHA256: NovelTestFixtures.hashA,
            branchID: fixture.branch.id,
            candidateID: candidate.id,
            sourceChapterVersionID: candidate.sourceChapterVersionID ?? NovelChapterVersionID(),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            baseCheckpointID: candidate.baseCheckpointID,
            baseHeadRevision: candidate.baseHeadRevision,
            baseWorkingRevision: fixture.branch.workingRevision,
            sessionCursor: .through(sequence: 0),
            sourceContentSHA256: NovelTestFixtures.hashA,
            candidateContentSHA256: NovelTestFixtures.hashB,
            createdAt: Self.now,
            status: status,
            attemptCount: 1,
            lastFailure: status == .retryable
                ? NovelFailure(code: "retry", message: "Retry", isRetryable: true)
                : nil,
            lastFailureAttemptIndex: status == .retryable ? 0 : nil
        )
    }
}
