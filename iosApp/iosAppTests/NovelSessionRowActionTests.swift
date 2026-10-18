import Foundation
import XCTest
@testable import iosApp

final class NovelSessionRowActionTests: NovelSessionReplayTestCase {
    func testCandidateActionGatesAndOnlyCandidateActionDigestChanges() throws {
        let fixture = try makeFixture()
        let discussion = makeMessage(
            sequence: 0,
            role: .assistant,
            mode: .discussPlan,
            kind: .discussion,
            content: "我们可以先埋下线索。"
        )
        let candidateID = NovelCandidateID()
        let prose = makeMessage(
            sequence: 1,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "雨落在空荡的车站。",
            candidateID: candidateID
        )
        var session = fixture.session
        session.messages = [discussion, prose]
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: prose.id,
            kind: .prose,
            status: .available,
            content: prose.content
        )
        let available = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate]
        ))
        XCTAssertTrue(available.rows[0].actions.isEmpty)
        XCTAssertEqual(
            available.rows[1].actions,
            [.init(action: .collectProse(candidateID), blocker: nil)]
        )

        let ghostwritePlanID = NovelChapterPlanID()
        let ghostwriteCandidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: prose.id,
            kind: .prose,
            status: .available,
            content: prose.content,
            ghostwritePlanID: ghostwritePlanID
        )
        let reviewRequired = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [ghostwriteCandidate]
        ))
        XCTAssertEqual(
            reviewRequired.rows[1].actions.first?.blocker,
            .ghostwriteReviewRequired
        )

        let readOnly = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            access: .degradedPrevious(primaryFailure: "corrupt")
        ))
        XCTAssertEqual(readOnly.rows[1].actions.first?.blocker, .projectReadOnly)

        var needsSyncBranch = fixture.branch
        needsSyncBranch.syncStatus = .needsSync
        let needsSync = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: needsSyncBranch,
            session: session,
            candidates: [candidate]
        ))
        XCTAssertNil(
            needsSync.rows[1].actions.first?.blocker,
            "Collecting an already-generated candidate must not wait on plot sync."
        )

        let activeRun = makeRun(fixture: fixture, kind: .discussion)
        var runningBranch = fixture.branch
        runningBranch.activeRunID = activeRun.id
        let running = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: runningBranch,
            session: session,
            candidates: [candidate],
            runs: [activeRun]
        ))
        XCTAssertEqual(running.rows[1].actions.first?.blocker, .generationRunning)

        let startingRun = makeRun(fixture: fixture, kind: .discussion)
        let starting = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            tail: NovelSessionTransientTail(
                run: startingRun,
                content: "",
                renderRevision: 0,
                phase: .waitingForFirstToken
            )
        ))
        XCTAssertEqual(
            starting.rows[1].actions.first?.blocker,
            .generationRunning,
            "The pre-durable live tail must block history actions without disabling the entire Markdown row tree."
        )

        let pending = makePending(fixture: fixture, candidateID: candidateID, status: .retryable)
        let retryable = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            pending: [pending]
        ))
        XCTAssertEqual(
            retryable.rows[1].actions,
            [.init(action: .retryPending(pending.id), blocker: nil)]
        )

        let manualSyncPending = makePending(
            fixture: fixture,
            candidateID: nil,
            status: .retryable,
            kind: .manualSync
        )
        let blockedByStateSync = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            pending: [manualSyncPending]
        ))
        XCTAssertEqual(
            blockedByStateSync.rows[1].actions.first?.blocker,
            .branchNeedsSync
        )
        XCTAssertEqual(retryable.rows[0].digest, available.rows[0].digest)
        XCTAssertNotEqual(retryable.rows[1].digest, available.rows[1].digest)

        var discoveredPending = pending
        discoveredPending.status = .pending
        let resumableAfterRestart = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            pending: [discoveredPending]
        ))
        XCTAssertEqual(resumableAfterRestart.rows[1].actions, [
            .init(action: .retryPending(discoveredPending.id), blocker: nil)
        ])

        var staleBranch = fixture.branch
        staleBranch.headRevision += 1
        let stale = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: staleBranch,
            session: session,
            candidates: [candidate]
        ))
        XCTAssertEqual(stale.rows[1].actions.first?.blocker, .staleCandidate)
    }

    func testRegenerationCandidateCannotBeCollectedAfterItsSourceChapterIsDiscarded() throws {
        let fixture = try makeFixture()
        let sourceVersionID = NovelChapterVersionID()
        let candidateID = NovelCandidateID()
        let message = makeMessage(
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "重写后的整章正文",
            candidateID: candidateID
        )
        var session = fixture.session
        session.messages = [message]
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: message.id,
            kind: .prose,
            status: .available,
            content: message.content,
            sourceVersionID: sourceVersionID
        )
        var branch = fixture.branch
        branch.workingChapterSelections = [NovelChapterSelection(
            chapterID: NovelChapterID(),
            versionID: sourceVersionID
        )]

        let available = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [candidate]
        ))
        XCTAssertNil(available.rows[0].actions.first?.blocker)

        let discarded = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [candidate],
            discardedChapterVersionIDs: [sourceVersionID]
        ))
        XCTAssertEqual(
            discarded.rows[0].actions,
            [.init(action: .collectProse(candidateID), blocker: .sourceChapterChanged)]
        )
    }

    func testProseCandidateRowPreservesItsGenerationGranularity() throws {
        let fixture = try makeFixture()
        let candidateID = NovelCandidateID()
        let run = makeRun(
            fixture: fixture,
            kind: .prose,
            candidateID: candidateID,
            granularity: .continuation
        )
        let message = makeMessage(
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "雨水沿着屋檐落下。",
            runID: run.id,
            candidateID: candidateID
        )
        var session = fixture.session
        session.messages = [message]
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: message.id,
            kind: .prose,
            status: .available,
            content: message.content
        )

        let model = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            runs: [terminalRun(run)]
        ))

        XCTAssertEqual(model.rows.first?.granularity, .continuation)
    }

    func testCollectedCandidateProjectsCommittedStateChangeAndForkAction() throws {
        let fixture = try makeFixture()
        let candidateID = NovelCandidateID()
        let message = makeMessage(
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "她终于拆开了信。",
            candidateID: candidateID
        )
        let event = NovelStoryEventRecord(
            id: NovelEventID(),
            sequence: 0,
            kind: "discovery",
            summary: "主角发现失踪信件",
            entityReferences: ["主角"],
            createdAt: Self.now
        )
        let state = NovelStateSnapshotRecord(
            id: NovelStateSnapshotID(),
            eventIDs: [event.id],
            summary: "主角掌握了第一条线索。",
            branchOutline: "追查寄信人",
            unresolvedEntityNames: ["寄信人"],
            createdAt: Self.now
        )
        let checkpoint = NovelBranchCheckpointRecord(
            id: NovelCheckpointID(),
            kind: .collection,
            createdOnBranchID: fixture.branch.id,
            parentCheckpointID: fixture.branch.headCheckpointID,
            chapterSelections: [],
            stateSnapshotID: state.id,
            sessionCursor: .through(sequence: 0),
            branchOverrideRevisionIDs: [],
            sourceCandidateID: candidateID,
            baseHeadRevision: fixture.branch.headRevision,
            operationID: NovelOperationID(),
            createdAt: Self.now
        )
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: message.id,
            kind: .prose,
            status: .collected,
            content: message.content,
            collectedCheckpointID: checkpoint.id
        )
        var session = fixture.session
        session.messages = [message]
        let projected = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            checkpoints: fixture.document.checkpoints + [checkpoint],
            states: fixture.document.stateSnapshots + [state],
            events: [event]
        ))

        XCTAssertEqual(projected.rows[0].committedChange?.stateSummary, state.summary)
        XCTAssertEqual(projected.rows[0].committedChange?.eventSummaries ?? [], [event.summary])
        XCTAssertEqual(projected.rows[0].committedChange?.branchSyncStatus, .synchronized)
        XCTAssertTrue(projected.rows[0].actions.contains(
            NovelSessionRowActionAvailability(
                action: .forkFromCheckpoint(checkpoint.id),
                blocker: nil
            )
        ))

        var headBranch = fixture.branch
        headBranch.headCheckpointID = checkpoint.id
        headBranch.headRevision += 1
        let atHead = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: headBranch,
            session: session,
            candidates: [candidate],
            checkpoints: fixture.document.checkpoints + [checkpoint],
            states: fixture.document.stateSnapshots + [state],
            events: [event]
        ))
        XCTAssertTrue(atHead.rows[0].actions.contains(
            NovelSessionRowActionAvailability(
                action: .undoCommittedChange(checkpointID: checkpoint.id, kind: .prose),
                blocker: nil
            )
        ))
        XCTAssertEqual(atHead.rows[0].committedChange?.branchSyncStatus, .synchronized)

        headBranch.syncStatus = .needsSync
        let needsSync = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: headBranch,
            session: session,
            candidates: [candidate],
            checkpoints: fixture.document.checkpoints + [checkpoint],
            states: fixture.document.stateSnapshots + [state],
            events: [event]
        ))
        XCTAssertEqual(
            needsSync.rows[0].actions.first(where: {
                if case .undoCommittedChange = $0.action { return true }
                return false
            })?.blocker,
            .branchNeedsSync
        )
        // The branch's live syncStatus is a branch-level fact shared by every committed
        // row (see NovelSessionCommittedChangeSummary.branchSyncStatus doc comment) — it
        // is not a per-row history stamp, so it flips for this already-committed row too.
        XCTAssertEqual(needsSync.rows[0].committedChange?.branchSyncStatus, .needsSync)
    }

    func testQuickStartMessageLinksToItsUnresolvedSettingProposals() throws {
        let fixture = try makeFixture()
        let run = makeRun(fixture: fixture, kind: .quickStart)
        let message = makeMessage(
            id: run.messageID,
            sequence: 0,
            role: .assistant,
            mode: .discussPlan,
            kind: .discussion,
            content: "创作建议",
            runID: run.id
        )
        let proposal = NovelSettingProposalRecord(
            id: NovelProposalID(),
            branchID: fixture.branch.id,
            title: "角色",
            content: "角色建议",
            createdAt: Self.now,
            isResolved: false,
            origin: .quickStart(runID: run.id, suggestedKind: .character)
        )
        var session = fixture.session
        session.messages = [message]

        let projected = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [run],
            proposals: [proposal]
        ))

        XCTAssertEqual(
            projected.rows[0].actions,
            [NovelSessionRowActionAvailability(
                action: .viewSettingProposals(.characters),
                blocker: nil
            )]
        )
    }

    func testPolishActionsExposeDriftManualRewriteAndAbandonPaths() throws {
        let fixture = try makeFixture()
        let sourceVersionID = NovelChapterVersionID()
        var branch = fixture.branch
        branch.workingChapterSelections = [NovelChapterSelection(
            chapterID: NovelChapterID(),
            versionID: sourceVersionID
        )]
        let candidateID = NovelCandidateID()
        let message = makeMessage(
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .polishCandidate,
            content: "润色后的完整章节",
            candidateID: candidateID
        )
        var session = fixture.session
        session.messages = [message]
        let availableCandidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: message.id,
            kind: .polish,
            status: .available,
            content: message.content,
            sourceVersionID: sourceVersionID
        )
        let available = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [availableCandidate]
        ))
        XCTAssertEqual(
            available.rows[0].actions,
            [.init(action: .adoptPolish(candidateID), blocker: nil)]
        )

        let retryableTransaction = makePolishTransaction(
            fixture: fixture,
            candidate: availableCandidate,
            status: .retryable
        )
        let retryable = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [availableCandidate],
            polish: [retryableTransaction]
        ))
        XCTAssertEqual(retryable.rows[0].actions.map(\.action), [
            .retryPolish(retryableTransaction.id),
            .abandonPolish(retryableTransaction.id)
        ])
        XCTAssertTrue(retryable.rows[0].actions.allSatisfy(\.isEnabled))

        let discardedRetryable = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [availableCandidate],
            polish: [retryableTransaction],
            discardedChapterVersionIDs: [sourceVersionID]
        ))
        XCTAssertEqual(discardedRetryable.rows[0].actions, [
            .init(action: .retryPolish(retryableTransaction.id), blocker: .sourceChapterChanged),
            .init(action: .abandonPolish(retryableTransaction.id), blocker: nil),
        ])

        var incompatibleCandidate = availableCandidate
        incompatibleCandidate.status = .superseded
        var incompatibleTransaction = retryableTransaction
        incompatibleTransaction.status = .incompatible
        let incompatible = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [incompatibleCandidate],
            polish: [incompatibleTransaction]
        ))
        XCTAssertEqual(incompatible.rows[0].candidate?.polishTransactionStatus, .incompatible)
        XCTAssertEqual(incompatible.rows[0].actions, [
            .init(
                action: .convertPolishToManualRewrite(
                    candidateID: candidateID,
                    sourceChapterVersionID: sourceVersionID
                ),
                blocker: nil
            )
        ])

        var changedSourceBranch = branch
        changedSourceBranch.workingChapterSelections = []
        let staleManualRewrite = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: changedSourceBranch,
            session: session,
            candidates: [incompatibleCandidate],
            polish: [incompatibleTransaction]
        ))
        XCTAssertEqual(staleManualRewrite.rows[0].actions.first?.blocker, .sourceChapterChanged)

        var blockedTransaction = retryableTransaction
        blockedTransaction.status = .blocked
        let blocked = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: branch,
            session: session,
            candidates: [availableCandidate],
            polish: [blockedTransaction]
        ))
        XCTAssertEqual(
            blocked.rows[0].actions,
            [.init(action: .abandonPolish(blockedTransaction.id), blocker: nil)]
        )
    }

    func testInterruptedAndErrorRowsExposeRetryAvailability() throws {
        let fixture = try makeFixture()
        let retryableRun = terminalRun(makeRun(fixture: fixture, kind: .prose))
        let failedRun = terminalRun(
            makeRun(fixture: fixture, kind: .discussion),
            status: .failed,
            failure: NovelFailure(code: "bad_request", message: "Bad request", isRetryable: false)
        )
        let interrupted = makeMessage(
            id: retryableRun.messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .interruptedDraft,
            content: "保留下来的草稿",
            runID: retryableRun.id
        )
        let error = makeMessage(
            id: failedRun.messageID,
            sequence: 1,
            role: .assistant,
            mode: .discussPlan,
            kind: .error,
            content: "Bad request",
            runID: failedRun.id
        )
        var session = fixture.session
        session.messages = [interrupted, error]
        let projected = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [retryableRun, failedRun]
        ))

        XCTAssertEqual(projected.rows[0].actions, [
            .init(action: .retryGeneration(retryableRun.id), blocker: nil)
        ])
        XCTAssertEqual(projected.rows[1].actions, [
            .init(action: .retryGeneration(failedRun.id), blocker: .failureNotRetryable)
        ])
        XCTAssertEqual(projected.rows[1].content, "生成没有完成，请检查项目模型或输入后重试。")

        let retryablePartialFailure = terminalRun(
            makeRun(fixture: fixture, kind: .discussion),
            status: .failed,
            failure: NovelFailure(code: "network", message: "断线", isRetryable: true)
        )
        let nonretryablePartialFailure = terminalRun(
            makeRun(fixture: fixture, kind: .discussion),
            status: .failed,
            failure: NovelFailure(code: "invalid", message: "请求无效", isRetryable: false)
        )
        session.messages = [
            makeMessage(
                id: retryablePartialFailure.messageID,
                sequence: 0,
                role: .assistant,
                mode: .discussPlan,
                kind: .interruptedDraft,
                content: "保留的部分回复",
                runID: retryablePartialFailure.id
            ),
            makeMessage(
                id: nonretryablePartialFailure.messageID,
                sequence: 1,
                role: .assistant,
                mode: .discussPlan,
                kind: .interruptedDraft,
                content: "另一段部分回复",
                runID: nonretryablePartialFailure.id
            )
        ]
        let partialFailures = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [retryablePartialFailure, nonretryablePartialFailure]
        ))
        XCTAssertEqual(partialFailures.rows.map(\.runStatus), [.failed, .failed])
        XCTAssertEqual(partialFailures.rows[0].actions, [
            .init(action: .retryGeneration(retryablePartialFailure.id), blocker: nil)
        ])
        XCTAssertEqual(partialFailures.rows[1].actions, [
            .init(
                action: .retryGeneration(nonretryablePartialFailure.id),
                blocker: .failureNotRetryable
            )
        ])

        let quickStartFailure = NovelFailure(
            code: "schema",
            message: "创作建议格式无效",
            isRetryable: true
        )
        let failedQuickStart = terminalRun(
            makeRun(fixture: fixture, kind: .quickStart),
            status: .failed,
            failure: quickStartFailure
        )
        session.messages = [makeMessage(
            id: failedQuickStart.messageID,
            sequence: 0,
            role: .assistant,
            mode: .discussPlan,
            kind: .interruptedDraft,
            content: #"{"world":"half-written""#,
            runID: failedQuickStart.id
        )]
        let hiddenStructuredPartial = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [failedQuickStart]
        ))
        XCTAssertEqual(hiddenStructuredPartial.rows[0].content, quickStartFailure.message)

        session.messages = [interrupted, error]

        var advancedBranch = fixture.branch
        advancedBranch.headRevision += 1
        let staleRetry = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: advancedBranch,
            session: session,
            runs: [retryableRun, failedRun]
        ))
        XCTAssertEqual(staleRetry.rows[0].actions, [
            .init(action: .retryGeneration(retryableRun.id), blocker: .staleCandidate)
        ])

        let regeneratedSourceVersionID = NovelChapterVersionID()
        let regenerateRun = terminalRun(makeRun(
            fixture: fixture,
            kind: .regenerate,
            sourceVersionID: regeneratedSourceVersionID
        ))
        session.messages = [makeMessage(
            id: regenerateRun.messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .interruptedDraft,
            content: "保留的重写草稿",
            runID: regenerateRun.id
        )]
        var regenerateBranch = fixture.branch
        regenerateBranch.workingChapterSelections = [NovelChapterSelection(
            chapterID: NovelChapterID(),
            versionID: regeneratedSourceVersionID
        )]
        let exactRegenerateRetry = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: regenerateBranch,
            session: session,
            runs: [regenerateRun]
        ))
        XCTAssertEqual(exactRegenerateRetry.rows[0].actions, [
            .init(action: .retryGeneration(regenerateRun.id), blocker: nil)
        ])

        let discardedRegenerateSource = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: regenerateBranch,
            session: session,
            runs: [regenerateRun],
            discardedChapterVersionIDs: [regeneratedSourceVersionID]
        ))
        XCTAssertEqual(
            discardedRegenerateSource.rows[0].actions.first?.blocker,
            .sourceChapterChanged
        )

        regenerateBranch.headRevision += 1
        let staleRegenerateRetry = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: regenerateBranch,
            session: session,
            runs: [regenerateRun]
        ))
        XCTAssertEqual(staleRegenerateRetry.rows[0].actions.first?.blocker, .staleCandidate)

        regenerateBranch.headRevision = fixture.branch.headRevision
        regenerateBranch.workingChapterSelections = []
        let changedRegenerateSource = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: regenerateBranch,
            session: session,
            runs: [regenerateRun]
        ))
        XCTAssertEqual(
            changedRegenerateSource.rows[0].actions.first?.blocker,
            .sourceChapterChanged
        )

        let oldSourceVersionID = NovelChapterVersionID()
        let polishRun = terminalRun(makeRun(
            fixture: fixture,
            kind: .polish,
            sourceVersionID: oldSourceVersionID
        ))
        let polishMessage = makeMessage(
            id: polishRun.messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .interruptedDraft,
            content: "旧润色草稿",
            runID: polishRun.id
        )
        session.messages = [polishMessage]
        var sourceChangedBranch = fixture.branch
        sourceChangedBranch.workingChapterSelections = [NovelChapterSelection(
            chapterID: NovelChapterID(),
            versionID: NovelChapterVersionID()
        )]
        let sourceChanged = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: sourceChangedBranch,
            session: session,
            runs: [polishRun]
        ))
        XCTAssertEqual(sourceChanged.rows[0].actions, [
            .init(action: .retryGeneration(polishRun.id), blocker: .sourceChapterChanged)
        ])
    }

    func testPolishAndRegenerateRetryRespectTheSameBranchGatesAsStartingANewRun() throws {
        let fixture = try makeFixture()
        let sourceVersionID = NovelChapterVersionID()
        var branch = fixture.branch
        branch.workingChapterSelections = [NovelChapterSelection(
            chapterID: NovelChapterID(),
            versionID: sourceVersionID
        )]

        for kind in [NovelRunKind.polish, .regenerate] {
            let run = terminalRun(
                makeRun(fixture: fixture, kind: kind, sourceVersionID: sourceVersionID),
                status: .interrupted
            )
            var session = fixture.session
            session.messages = [makeMessage(
                id: run.messageID,
                sequence: 0,
                role: .assistant,
                mode: .writeProse,
                kind: .interruptedDraft,
                content: "保留的整章草稿",
                runID: run.id
            )]

            var needsSyncBranch = branch
            needsSyncBranch.syncStatus = .needsSync
            let needsSync = NovelSessionPresentation.project(makeInput(
                fixture: fixture,
                branch: needsSyncBranch,
                session: session,
                runs: [run]
            ))
            XCTAssertEqual(
                needsSync.rows[0].actions.first?.blocker,
                .branchNeedsSync,
                "\(kind) retry must not bypass the start gate for an unsynchronized branch."
            )

            let retryableManualSync = makePending(
                fixture: fixture,
                candidateID: nil,
                status: .retryable,
                kind: .manualSync
            )
            let pending = NovelSessionPresentation.project(makeInput(
                fixture: fixture,
                branch: branch,
                session: session,
                runs: [run],
                pending: [retryableManualSync]
            ))
            XCTAssertEqual(
                pending.rows[0].actions.first?.blocker,
                .branchNeedsSync,
                "\(kind) retry must wait for every branch operation, including retryable manual sync."
            )

            let transactionCandidate = makeCandidate(
                fixture: fixture,
                id: NovelCandidateID(),
                sourceMessageID: NovelMessageID(),
                kind: .polish,
                status: .available,
                content: "待检查的润色正文",
                sourceVersionID: sourceVersionID
            )
            let unresolvedTransaction = makePolishTransaction(
                fixture: fixture,
                candidate: transactionCandidate,
                status: .blocked
            )
            let unresolvedPolish = NovelSessionPresentation.project(makeInput(
                fixture: fixture,
                branch: branch,
                session: session,
                runs: [run],
                polish: [unresolvedTransaction]
            ))
            XCTAssertEqual(
                unresolvedPolish.rows[0].actions.first?.blocker,
                .pendingOperation,
                "\(kind) retry must not start while the previous polish check is unresolved."
            )
        }
    }

    func testProseRetryRespectsNeedsSyncLikeStartingANewRun() throws {
        let fixture = try makeFixture()
        let run = terminalRun(
            makeRun(fixture: fixture, kind: .prose, candidateID: NovelCandidateID()),
            status: .interrupted
        )
        var session = fixture.session
        session.messages = [makeMessage(
            id: run.messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .interruptedDraft,
            content: "保留的正文草稿",
            runID: run.id,
            candidateID: run.candidateID
        )]

        var needsSyncBranch = fixture.branch
        needsSyncBranch.syncStatus = .needsSync
        let needsSync = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            branch: needsSyncBranch,
            session: session,
            runs: [run]
        ))
        XCTAssertEqual(
            needsSync.rows[0].actions.first(where: {
                if case .retryGeneration = $0.action { return true }
                return false
            })?.blocker,
            .branchNeedsSync,
            "Prose retry must not bypass the start gate for an unsynchronized branch."
        )
    }

    func testInterruptedProseRowsExposeCollectBesideRetryAndKeepSyncBlocker() throws {
        let fixture = try makeFixture()
        let candidateID = NovelCandidateID()
        let run = terminalRun(
            makeRun(fixture: fixture, kind: .prose, candidateID: candidateID),
            status: .interrupted
        )
        let message = makeMessage(
            id: run.messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .interruptedDraft,
            content: "保留的正文",
            runID: run.id,
            candidateID: candidateID
        )
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: message.id,
            kind: .prose,
            status: .interrupted,
            content: message.content
        )
        var session = fixture.session
        session.messages = [message]

        let durable = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            runs: [run]
        ))
        XCTAssertEqual(durable.rows[0].actions, [
            .init(action: .collectProse(candidateID), blocker: nil),
            .init(action: .retryGeneration(run.id), blocker: nil),
        ])

        let manualSync = makePending(
            fixture: fixture,
            candidateID: nil,
            status: .retryable,
            kind: .manualSync
        )
        let blocked = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            runs: [run],
            pending: [manualSync]
        ))
        XCTAssertEqual(
            blocked.rows[0].actions.first?.blocker,
            .branchNeedsSync
        )
        XCTAssertNil(
            NovelSessionBubble.sharedActionBarBlocker(blocked.rows[0].actions)
        )

        let transientRun = makeRun(
            fixture: fixture,
            kind: .prose,
            candidateID: candidateID
        )
        let tail = NovelSessionTransientTail(
            run: transientRun,
            content: "保留的正文",
            renderRevision: 1,
            phase: .interrupted
        )
        let transient = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            runs: [transientRun],
            tail: tail
        ))
        XCTAssertEqual(transient.rows[0].actions, [
            .init(action: .collectProse(candidateID), blocker: nil),
            .init(action: .retryGeneration(transientRun.id), blocker: nil),
        ])
    }

    func testZeroTokenInterruptedRunSurvivesDurableRefreshAndReopen() throws {
        let fixture = try makeFixture()
        let interruptedRun = terminalRun(
            makeRun(fixture: fixture, kind: .prose),
            status: .interrupted
        )
        let user = makeMessage(
            id: interruptedRun.userMessageID,
            sequence: 0,
            role: .user,
            mode: .writeProse,
            kind: .userInput,
            content: "写这一章",
            runID: interruptedRun.id
        )
        var session = fixture.session
        session.messages = [user]

        let afterRefresh = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [interruptedRun]
        ))
        let afterReopen = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [interruptedRun],
            tail: nil
        ))

        XCTAssertEqual(afterRefresh, afterReopen)
        XCTAssertNil(afterReopen.activeTailID)
        XCTAssertEqual(afterReopen.rows.map(\.id), [user.id, interruptedRun.messageID])
        XCTAssertEqual(afterReopen.rows[1].kind, .interruptedDraft)
        XCTAssertEqual(afterReopen.rows[1].content, "")
        XCTAssertEqual(afterReopen.rows[1].actions, [
            .init(action: .retryGeneration(interruptedRun.id), blocker: nil)
        ])
    }

    func testTransientTerminalPhasesStopStreamingAndExposeExactRetry() throws {
        let fixture = try makeFixture()
        let run = makeRun(fixture: fixture, kind: .prose, candidateID: NovelCandidateID())
        let streamingTail = NovelSessionTransientTail(
            run: run,
            content: "第一段",
            renderRevision: 1,
            phase: .streaming
        )
        let streaming = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            runs: [run],
            tail: streamingTail
        )).rows[0]
        XCTAssertTrue(streaming.isStreaming)
        XCTAssertEqual(streaming.kind, .proseCandidate)

        let awaiting = streamingTail.updating(
            content: "完整章节",
            phase: .terminalAwaitingRefresh
        )
        let awaitingRow = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            runs: [run],
            tail: awaiting
        )).rows[0]
        XCTAssertFalse(awaitingRow.isStreaming)
        XCTAssertEqual(awaitingRow.kind, .proseCandidate)
        XCTAssertTrue(awaitingRow.actions.isEmpty)
        XCTAssertNotEqual(awaitingRow.digest, streaming.digest)

        let interrupted = awaiting.updating(content: "保留的部分", phase: .interrupted)
        let interruptedRow = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            runs: [run],
            tail: interrupted
        )).rows[0]
        XCTAssertFalse(interruptedRow.isStreaming)
        XCTAssertEqual(interruptedRow.kind, .interruptedDraft)
        XCTAssertEqual(interruptedRow.actions, [
            .init(action: .collectProse(try XCTUnwrap(run.candidateID)), blocker: nil),
            .init(action: .retryGeneration(run.id), blocker: nil)
        ])

        let failure = NovelFailure(code: "network", message: "断线", isRetryable: true)
        let failed = interrupted.updating(content: "", phase: .failed(failure))
        let failedRow = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            runs: [run],
            tail: failed
        )).rows[0]
        XCTAssertFalse(failedRow.isStreaming)
        XCTAssertEqual(failedRow.kind, .error)
        XCTAssertEqual(failedRow.actions, [
            .init(action: .retryGeneration(run.id), blocker: nil)
        ])
    }

    func testPolishRetryEntrypointsShareOwnedTaskWithVisibleStopFeedback() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionView = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift"),
            encoding: .utf8
        )
        let bubble = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionBubble.swift"),
            encoding: .utf8
        )
        let chrome = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionChrome.swift"),
            encoding: .utf8
        )
        let actionButtons = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionActionButtons.swift"),
            encoding: .utf8
        )

        let sessionViewModel = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "iosApp/NovelCreation/NovelSessionViewModel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(sessionView.contains("@State private var polishRetryTask"))
        XCTAssertTrue(sessionView.contains("NovelSessionChrome("))
        XCTAssertTrue(chrome.contains("viewModel.startPolishRetry(transaction.id)"))
        XCTAssertTrue(sessionView.contains("case .retryPolish(let transactionID):"))
        XCTAssertTrue(sessionView.contains("viewModel.startPolishRetry(transactionID)"))
        XCTAssertTrue(chrome.contains("viewModel.cancelPolishRetry()"))
        XCTAssertTrue(sessionViewModel.contains("@ObservationIgnored var polishRetryTask: Task<Void, Never>?"))
        XCTAssertTrue(sessionViewModel.contains("var polishRetryTransactionID"))
        XCTAssertTrue(chrome.contains("Text(\"正在检查剧情一致性…\")"))
        XCTAssertTrue(bubble.contains("NovelSessionActionButtons("))
        XCTAssertTrue(actionButtons.contains("Button(localized(\"停止检查\"))"))
        XCTAssertTrue(actionButtons.contains("onCancelPolishRetry()"))
    }

}
