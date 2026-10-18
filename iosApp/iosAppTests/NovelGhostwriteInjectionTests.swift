import XCTest
@testable import iosApp

final class NovelGhostwriteInjectionTests: NovelCollaborationModeTestCase {
    func testRecentWrittenHighlightsMergeDedupAndCap() {
        let merged = NovelStateSnapshotRecord.mergedHighlights(
            prior: ["祭坛下找到信物", "使者带来盟约"],
            newEventSummaries: ["祭坛下找到信物", "主角夺回信物", ""]
        )
        XCTAssertEqual(
            merged,
            ["祭坛下找到信物", "使者带来盟约", "主角夺回信物"]
        )

        let overflow = (0..<(NovelStateSnapshotRecord.maxRecentWrittenHighlights + 5)).map {
            "beat-\($0)"
        }
        let capped = NovelStateSnapshotRecord.normalizedHighlights(overflow)
        XCTAssertEqual(capped.count, NovelStateSnapshotRecord.maxRecentWrittenHighlights)
        XCTAssertEqual(capped.first, "beat-5")
        XCTAssertEqual(capped.last, "beat-\(NovelStateSnapshotRecord.maxRecentWrittenHighlights + 4)")
    }

    func testStateSnapshotDecodesMissingRecentWrittenHighlights() throws {
        let original = NovelStateSnapshotRecord(
            id: NovelStateSnapshotID(),
            eventIDs: [],
            summary: "s",
            branchOutline: "o",
            unresolvedEntityNames: [],
            createdAt: Date(timeIntervalSince1970: 0),
            recentWrittenHighlights: ["should-be-stripped"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "recentWrittenHighlights")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(
            NovelStateSnapshotRecord.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(decoded.recentWrittenHighlights.isEmpty)
    }

    func testWholeChapterInjectsRecentWrittenHighlights() throws {
        var document = try NovelTestFixtures.document()
        document.stateSnapshots[0] = NovelStateSnapshotRecord(
            id: document.stateSnapshots[0].id,
            eventIDs: document.stateSnapshots[0].eventIDs,
            summary: document.stateSnapshots[0].summary,
            branchOutline: document.stateSnapshots[0].branchOutline,
            unresolvedEntityNames: document.stateSnapshots[0].unresolvedEntityNames,
            createdAt: document.stateSnapshots[0].createdAt,
            recentWrittenHighlights: ["祭坛下找到信物", "使者带来盟约"]
        )

        let whole = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseWholeChapter,
                userText: "写下一章"
            )
        )
        XCTAssertTrue(whole.sections.contains { section in
            if case .recentWrittenHighlights = section.kind { return true }
            return false
        })
        XCTAssertTrue(whole.canonicalInput.contains("祭坛下找到信物"))
        XCTAssertTrue(whole.canonicalInput.contains("DO NOT REHASH"))

        let continuation = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseContinuation,
                userText: "续写一段"
            )
        )
        XCTAssertFalse(continuation.sections.contains { section in
            if case .recentWrittenHighlights = section.kind { return true }
            return false
        })
        XCTAssertLessThanOrEqual(whole.estimatedInputTokens, whole.maxEstimatedInputTokens)
    }

    func testUpsertAndClearUpcomingArc() throws {
        var document = try NovelTestFixtures.document()
        let branchID = document.branches[0].id

        document = try NovelReducer.apply(.upsertUpcomingArc(NovelUpsertUpcomingArcCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            beats: ["使者身份曝光", "夺回信物"]
        )), to: document).document
        XCTAssertEqual(document.upcomingArc(for: branchID)?.beats, ["使者身份曝光", "夺回信物"])

        document = try NovelReducer.apply(.clearUpcomingArc(NovelClearUpcomingArcCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID
        )), to: document).document
        XCTAssertNil(document.upcomingArc(for: branchID))
    }

    func testWholeChapterInjectsUpcomingArc() throws {
        var document = try NovelTestFixtures.document()
        document = try NovelReducer.apply(.upsertUpcomingArc(NovelUpsertUpcomingArcCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            beats: ["使者身份曝光"]
        )), to: document).document

        let whole = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseWholeChapter,
                userText: "写下一章"
            )
        )
        XCTAssertTrue(whole.sections.contains { section in
            if case .upcomingArc = section.kind { return true }
            return false
        })
        XCTAssertTrue(whole.canonicalInput.contains("UPCOMING ARC"))
        XCTAssertTrue(whole.canonicalInput.contains("使者身份曝光"))

        let continuation = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseContinuation,
                userText: "续写一段"
            )
        )
        XCTAssertFalse(continuation.sections.contains { section in
            if case .upcomingArc = section.kind { return true }
            return false
        })
    }

    func testGhostwriteBoardStepSummaryTracksPhase() {
        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        var progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .accepting,
            pauseReason: nil,
            detailMessage: nil,
            candidateID: nil,
            chapterPlanDigest: nil,
            autoCollectedCandidateIDs: [],
            startedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(progress.boardStepSummary, "写✓ · 审核收录中")

        progress.phase = .waitingUser
        progress.pauseReason = .chapterCompleted
        XCTAssertEqual(progress.boardStepSummary, "写✓审✓收✓同✓")

        progress.pauseReason = .obviousRepetition
        // 质量失败：看板标明继续将重写，避免「再验旧稿」误解。
        XCTAssertEqual(progress.boardStepSummary, "已中断·将重写")
    }

    func testGhostwriteBatchClampAndProgressLabels() {
        XCTAssertEqual(NovelGhostwriteBatch.clamp(0), 1)
        XCTAssertEqual(NovelGhostwriteBatch.clamp(3), 3)
        XCTAssertEqual(NovelGhostwriteBatch.clamp(99), 10)

        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        var progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .writing,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5,
            completedChapterCount: 2,
            currentChapterIndex: 3
        )
        XCTAssertEqual(progress.batchProgressLabel, "第 3/5 章")
        XCTAssertTrue(progress.statusLabel.contains("3/5"))
        XCTAssertTrue(progress.boardStepSummary.contains("已收2/5"))
        XCTAssertFalse(progress.isBatchComplete)

        progress.phase = .planning
        XCTAssertTrue(progress.boardStepSummary.contains("拟定下一章"))

        progress.completedChapterCount = 5
        progress.currentChapterIndex = 5
        progress.phase = .waitingUser
        progress.pauseReason = .batchCompleted
        XCTAssertTrue(progress.isBatchComplete)
        XCTAssertEqual(progress.boardStepSummary, "写✓审✓收✓同✓ · 已收5/5")
        XCTAssertEqual(progress.statusLabel, "本批已完成 · 5/5 章")
        progress.pauseReason = .chapterCompleted
        progress.targetChapterCount = 1
        progress.currentChapterIndex = 1
        progress.completedChapterCount = 1
        XCTAssertEqual(progress.statusLabel, "本章已完成")
        XCTAssertTrue(NovelGhostwritePauseReason.syncFailed.resumesWithoutConfirmedPlan)
        XCTAssertTrue(NovelGhostwritePauseReason.planProposalFailed.resumesWithoutConfirmedPlan)
        XCTAssertFalse(NovelGhostwritePauseReason.acceptanceFailed.resumesWithoutConfirmedPlan)
        progress.targetChapterCount = 5
        progress.completedChapterCount = 2
        progress.pauseReason = .syncFailed
        XCTAssertTrue(progress.canResumeWithoutConfirmedPlan)

        // syncFailed 待记账：续跑先计章，避免越过 N 再写。
        var pending = NovelGhostwriteProgress(
            binding: binding,
            phase: .failed,
            pauseReason: .syncFailed,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 1,
            completedChapterCount: 0,
            currentChapterIndex: 1,
            pendingSyncChapterCredit: true
        )
        XCTAssertTrue(pending.shouldContinueSameBatch)
        XCTAssertTrue(pending.canResumeWithoutConfirmedPlan)
        XCTAssertTrue(pending.applyPendingSyncChapterCredit())
        XCTAssertEqual(pending.completedChapterCount, 1)
        XCTAssertFalse(pending.pendingSyncChapterCredit)
        XCTAssertTrue(pending.isBatchComplete)
        XCTAssertFalse(pending.shouldContinueSameBatch)

        // N=2：记账后未达批上限，应继续同批（下一章拟合同），而不是完批。
        var mid = NovelGhostwriteProgress(
            binding: binding,
            phase: .failed,
            pauseReason: .syncFailed,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 2,
            completedChapterCount: 0,
            currentChapterIndex: 1,
            pendingSyncChapterCredit: true
        )
        XCTAssertFalse(mid.applyPendingSyncChapterCredit())
        XCTAssertEqual(mid.completedChapterCount, 1)
        XCTAssertFalse(mid.isBatchComplete)

        // 取消且无待记账：显示「开始」、不得续旧批。
        var cancelled = NovelGhostwriteProgress(
            binding: binding,
            phase: .paused,
            pauseReason: .cancelled,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 3,
            completedChapterCount: 1,
            currentChapterIndex: 2
        )
        XCTAssertFalse(cancelled.shouldContinueSameBatch)

        // 取消但有待同步记账：必须先续跑记账。
        cancelled.pendingSyncChapterCredit = true
        XCTAssertTrue(cancelled.shouldContinueSameBatch)

        // 用户点「结束」：先把待记账计入 completed，再标 cancelled，不得再续旧批。
        var abandoning = NovelGhostwriteProgress(
            binding: binding,
            phase: .syncing,
            pauseReason: .syncFailed,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 3,
            completedChapterCount: 1,
            currentChapterIndex: 2,
            pendingSyncChapterCredit: true
        )
        XCTAssertFalse(abandoning.applyPendingSyncChapterCredit())
        abandoning.phase = .paused
        abandoning.pauseReason = .cancelled
        XCTAssertEqual(abandoning.completedChapterCount, 2)
        XCTAssertFalse(abandoning.pendingSyncChapterCredit)
        XCTAssertFalse(abandoning.shouldContinueSameBatch)
    }

}
