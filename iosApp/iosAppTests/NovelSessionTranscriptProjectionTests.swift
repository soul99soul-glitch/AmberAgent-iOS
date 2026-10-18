import Foundation
import XCTest
@testable import iosApp

final class NovelSessionTranscriptProjectionTests: NovelSessionReplayTestCase {
    func testTranscriptUsesEagerStacksForWindowedHistory() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift")
                .path,
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("Keep it eager so multi-thousand-pt chapter bubbles"),
            "Novel session transcript must document why history is eager."
        )
        XCTAssertFalse(
            source.contains("LazyVStack(alignment: .leading, spacing: 14)"),
            "Windowed novel history must not use LazyVStack (blank-gap source)."
        )
        XCTAssertTrue(
            source.contains("source: .streamGrowth"),
            "Live follow must snap via explicitBottom(.streamGrowth), not eased streamContentGrew only."
        )
        XCTAssertTrue(
            source.contains("!scrollDriver.isUIKitUserInteracting"),
            "Stream-growth snap must not fire during UIKit user interaction."
        )
        XCTAssertTrue(
            source.contains("ForEach(visibleHistoricalRows)"),
            "Windowed history must stay in its own eager stack."
        )
        XCTAssertTrue(
            source.contains("ForEach(activeRunRows)"),
            "The live/pinned run must stay in a sibling stack so stream ticks do not remeasure history."
        )
        XCTAssertFalse(
            source.contains("visibleTranscriptRows("),
            "Do not merge history and the active run into one VStack."
        )
    }

    func testDragResumeUsesSharedNearBottomThreshold() {
        let threshold = ChatLayout.nearBottomResumeThreshold

        XCTAssertEqual(threshold, 96)
        XCTAssertGreaterThan(threshold, ChatLayout.bottomStickThreshold)
        XCTAssertTrue(NovelSessionBottomProximityPolicy.isNearBottom(
            distanceToBottom: threshold
        ))
        XCTAssertFalse(NovelSessionBottomProximityPolicy.isNearBottom(
            distanceToBottom: threshold + 0.5
        ))
    }

    func testLongHistoryWindowStartsAtRecentRowsAndExpandsInBoundedPages() {
        XCTAssertEqual(NovelSessionHistoryWindowPolicy.coldOpenLimit, 2)
        XCTAssertEqual(NovelSessionHistoryWindowPolicy.initialLimit, 4)
        XCTAssertEqual(NovelSessionHistoryWindowPolicy.pageSize, 12)
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterColdOpenSettles(currentLimit: 2),
            NovelSessionHistoryWindowPolicy.initialLimit
        )
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterColdOpenSettles(currentLimit: 40),
            40,
            "User-expanded history must not shrink when cold open settles."
        )
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.startIndex(
                totalCount: 160,
                limit: NovelSessionHistoryWindowPolicy.initialLimit
            ),
            156
        )
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.expandedLimit(currentLimit: 4, totalCount: 160),
            16
        )
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.expandedLimit(currentLimit: 4, totalCount: 20),
            16
        )
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.startIndex(totalCount: 4, limit: 4),
            0
        )
        XCTAssertLessThan(
            NovelSessionLoadStage.idle,
            NovelSessionLoadStage.coreTranscript
        )
        XCTAssertLessThan(
            NovelSessionLoadStage.coreTranscript,
            NovelSessionLoadStage.secondaryChrome
        )
    }

    func testDiscussionArchiveCardCountsAsOneRowAndExpansionPreservesRawRowIdentity() throws {
        let fixture = try makeFixture()
        let messages = (0..<4).map { index in
            makeMessage(
                sequence: Int64(index),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                mode: .discussPlan,
                kind: index.isMultiple(of: 2) ? .userInput : .discussion,
                content: "讨论 \(index)"
            )
        }
        let archiveID = NovelMessageID()
        var session = fixture.session
        session.messages = messages
        session.archiveCursor = .through(sequence: 1)
        session.discussionArchives = [NovelDiscussionArchiveRecord(
            id: archiveID,
            checkpointID: fixture.branch.headCheckpointID,
            throughSequence: 1,
            messageCount: 2,
            chapterID: nil,
            summary: "确认主角在第三章末揭示身世。",
            createdAt: Self.now
        )]

        let collapsed = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session
        ))
        XCTAssertEqual(collapsed.rows.map(\.id), [archiveID, messages[2].id, messages[3].id])
        XCTAssertEqual(collapsed.historicalRows.count, 3)
        XCTAssertEqual(collapsed.rows.first?.archive?.messageCount, 2)
        XCTAssertEqual(collapsed.rows.first?.archive?.isExpanded, false)

        let expanded = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            expandedArchiveIDs: [archiveID]
        ))
        XCTAssertEqual(
            expanded.rows.map(\.id),
            [archiveID, messages[0].id, messages[1].id, messages[2].id, messages[3].id]
        )
        XCTAssertEqual(expanded.rows.first?.archive?.isExpanded, true)
        XCTAssertEqual(collapsed.rows.first?.digest.layout, expanded.rows.first?.digest.layout)
        XCTAssertNotEqual(
            collapsed.rows.first?.digest.presentation,
            expanded.rows.first?.digest.presentation
        )
    }

    func testCollapsedArchiveKeepsUncollectedProseVisibleForCollect() throws {
        let fixture = try makeFixture()
        let candidateID = NovelCandidateID()
        let discussionUser = makeMessage(
            sequence: 0,
            role: .user,
            mode: .discussPlan,
            kind: .userInput,
            content: "先讨论再写"
        )
        let discussionAssistant = makeMessage(
            sequence: 1,
            role: .assistant,
            mode: .discussPlan,
            kind: .discussion,
            content: "同意先埋伏笔"
        )
        let proseMessage = makeMessage(
            sequence: 2,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "未收录正文仍应可点收录",
            candidateID: candidateID
        )
        let laterDiscussion = makeMessage(
            sequence: 3,
            role: .user,
            mode: .discussPlan,
            kind: .userInput,
            content: "就按这个定"
        )
        let candidate = makeCandidate(
            fixture: fixture,
            id: candidateID,
            sourceMessageID: proseMessage.id,
            kind: .prose,
            status: .interrupted,
            content: proseMessage.content
        )
        let archiveID = NovelMessageID()
        var session = fixture.session
        session.messages = [discussionUser, discussionAssistant, proseMessage, laterDiscussion]
        session.archiveCursor = .through(sequence: 3)
        session.discussionArchives = [NovelDiscussionArchiveRecord(
            id: archiveID,
            checkpointID: fixture.branch.headCheckpointID,
            throughSequence: 3,
            messageCount: 4,
            chapterID: nil,
            summary: "讨论归档后未收录正文仍可见。",
            createdAt: Self.now
        )]

        let collapsed = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate]
        ))
        XCTAssertEqual(collapsed.rows.map(\.id), [archiveID, proseMessage.id])
        XCTAssertEqual(collapsed.rows.last?.candidate?.status, .interrupted)
        XCTAssertTrue(collapsed.rows.last?.actions.contains {
            if case .collectProse = $0.action { return true }
            return false
        } == true)
        let revealedRowCount = try XCTUnwrap(
            collapsed.rows.first?.archive?.revealedRowCount
        )
        XCTAssertEqual(revealedRowCount, 3)
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterArchiveExpansion(
                currentLimit: 4,
                revealedRowCount: revealedRowCount
            ),
            7
        )

        let expanded = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            candidates: [candidate],
            expandedArchiveIDs: [archiveID]
        ))
        XCTAssertEqual(
            expanded.rows.map(\.id),
            [archiveID, discussionUser.id, discussionAssistant.id, proseMessage.id, laterDiscussion.id]
        )
    }

    func testProjectionUsesOneStableAssistantRowFromStreamingThroughDurableTerminal() throws {
        let fixture = try makeFixture()
        let run = makeRun(fixture: fixture, kind: .discussion)
        let user = makeMessage(
            id: run.userMessageID,
            sequence: 0,
            role: .user,
            mode: .discussPlan,
            kind: .userInput,
            content: "接下来该怎么安排？",
            runID: run.id
        )
        var session = fixture.session
        session.messages = [user]
        let tail = NovelSessionTransientTail(
            run: run,
            content: "先让主角",
            renderRevision: 1,
            phase: .streaming
        )

        let streaming = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [run],
            tail: tail
        ))
        XCTAssertEqual(streaming.rows.map(\.id), [user.id, run.messageID])
        XCTAssertEqual(streaming.activeTailID, run.messageID)
        XCTAssertTrue(streaming.rows[1].isStreaming)

        let terminal = makeMessage(
            id: run.messageID,
            sequence: 1,
            role: .assistant,
            mode: .discussPlan,
            kind: .discussion,
            content: "先让主角发现失踪信件。",
            runID: run.id
        )
        session.messages.append(terminal)
        let terminalTail = tail.updating(
            content: terminal.content,
            renderRevision: 2,
            phase: .terminalAwaitingRefresh
        )
        let settling = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [terminalRun(run)],
            tail: terminalTail
        ))

        XCTAssertEqual(settling.rows.map(\.id), [user.id, terminal.id])
        XCTAssertEqual(settling.activeTailID, terminal.id)
        XCTAssertTrue(settling.rows[1].isTransient)
        XCTAssertEqual(settling.rows[1].transientPhase, .terminalAwaitingRefresh)
        XCTAssertEqual(settling.rows[1].content, terminal.content)
        XCTAssertNotEqual(streaming.rows[1].digest, settling.rows[1].digest)

        let durable = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [terminalRun(run)],
            tail: nil
        ))
        XCTAssertEqual(durable.rows.map(\.id), [user.id, terminal.id])
        XCTAssertNil(durable.activeTailID)
        XCTAssertFalse(durable.rows[1].isTransient)
        XCTAssertEqual(durable.rows[1].content, terminal.content)
    }

    func testTransientTailSurfacesAskUserBeforeDurableHandoff() throws {
        let fixture = try makeFixture()
        let run = makeRun(fixture: fixture, kind: .discussion)
        let user = makeMessage(
            id: run.userMessageID,
            sequence: 0,
            role: .user,
            mode: .discussPlan,
            kind: .userInput,
            content: "帮我梳理人物动机",
            runID: run.id
        )
        let prompt = NovelAskUserPrompt(
            question: "他此刻更害怕失去谁？",
            options: ["家人", "同伴"]
        )
        let terminal = makeMessage(
            id: run.messageID,
            sequence: 1,
            role: .assistant,
            mode: .discussPlan,
            kind: .discussion,
            content: "先确认人物动机。",
            runID: run.id,
            interaction: .askUser(prompt)
        )
        var session = fixture.session
        session.messages = [user, terminal]
        let overlayAfterPersist = NovelSessionTransientTail(
            run: run,
            content: "先确认",
            renderRevision: 1,
            phase: .streaming
        )
        let afterPersist = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [terminalRun(run)],
            tail: overlayAfterPersist
        ))
        XCTAssertEqual(afterPersist.rows.last?.askUser?.prompt, prompt)
        XCTAssertEqual(afterPersist.rows.last?.content, "先确认")

        var streamingSession = fixture.session
        streamingSession.messages = [user]
        let overlayBeforePersist = NovelSessionTransientTail(
            run: run,
            content: "先确认",
            renderRevision: 2,
            phase: .streaming,
            askUser: NovelAskUserPresentation(prompt: prompt, response: nil)
        )
        let beforePersist = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: streamingSession,
            runs: [run],
            tail: overlayBeforePersist
        ))
        XCTAssertEqual(beforePersist.rows.last?.askUser?.prompt, prompt)
        XCTAssertEqual(beforePersist.rows.last?.content, "先确认")
        XCTAssertTrue(beforePersist.rows.last?.isTransient == true)
    }

    func testStreamingTailFreezeReleasesForBottomButDefersOffscreenTerminal() {
        XCTAssertFalse(
            NovelSessionStreamingTailFreezePolicy.shouldHoldFrozenSnapshot(
                isFollowingBottom: true,
                isTerminalPresenting: false,
                renderPolicyWouldSuspend: true
            ),
            "Watching the live tail must not freeze remaining text."
        )
        XCTAssertTrue(
            NovelSessionStreamingTailFreezePolicy.shouldHoldFrozenSnapshot(
                isFollowingBottom: false,
                isTerminalPresenting: true,
                renderPolicyWouldSuspend: true
            ),
            "Completion must not force an off-screen Markdown backlog into one layout pass."
        )
        XCTAssertTrue(
            NovelSessionStreamingTailFreezePolicy.shouldHoldFrozenSnapshot(
                isFollowingBottom: false,
                isTerminalPresenting: false,
                renderPolicyWouldSuspend: true
            )
        )
        XCTAssertFalse(
            NovelSessionStreamingTailFreezePolicy.shouldHoldFrozenSnapshot(
                isFollowingBottom: false,
                isTerminalPresenting: false,
                renderPolicyWouldSuspend: false
            )
        )
    }

    func testWholeChapterStreamOnlyInvalidatesTailAndRespectsHistoryPause() throws {
        let fixture = try makeFixture()
        var session = fixture.session
        session.messages = (0..<24).map { index in
            makeMessage(
                sequence: Int64(index),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                mode: index.isMultiple(of: 2) ? .writeProse : .discussPlan,
                kind: index.isMultiple(of: 2) ? .userInput : .discussion,
                content: "历史消息 \(index)"
            )
        }
        let run = makeRun(fixture: fixture, kind: .prose, candidateID: NovelCandidateID())
        var baseline = NovelSessionPresentation.project(makeInput(
            fixture: fixture,
            session: session,
            runs: [run],
            tail: NovelSessionTransientTail(
                run: run,
                content: "",
                renderRevision: 0,
                phase: .waitingForFirstToken
            )
        ))
        let historicalDigests = baseline.rows.dropLast().map(\.digest)
        var priorTailDigest = try XCTUnwrap(baseline.rows.last?.digest)

        var follow = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(),
            event: .initialRowsPresented(hasRows: true)
        ).state
        var chapter = ""
        for index in 1...240 {
            chapter += "第 \(index) 段，主角沿着线索继续前行。\n\n"
            let projected = NovelSessionPresentation.project(makeInput(
                fixture: fixture,
                session: session,
                runs: [run],
                tail: NovelSessionTransientTail(
                    run: run,
                    content: chapter,
                    renderRevision: UInt64(index),
                    phase: .streaming
                )
            ))
            XCTAssertEqual(projected.rows.dropLast().map(\.digest), historicalDigests)
            XCTAssertNotEqual(projected.rows.last?.digest, priorTailDigest)
            XCTAssertEqual(projected.rows.filter { $0.id == run.messageID }.count, 1)
            priorTailDigest = try XCTUnwrap(projected.rows.last?.digest)
            baseline = projected

            if index == 30 {
                follow = NovelSessionBottomFollowPolicy.reduce(
                    state: follow,
                    event: .userDragBegan(isAtBottom: false)
                ).state
            } else if index == 90 {
                follow = NovelSessionBottomFollowPolicy.reduce(
                    state: follow,
                    event: .explicitBottomRequested
                ).state
            }
            let wasBrowsingHistory = follow.mode == .browsingHistory
            let transition = NovelSessionBottomFollowPolicy.reduce(
                state: follow,
                event: .measuredStreamGrowth(isAtBottom: false)
            )
            if wasBrowsingHistory {
                // 「respects history pause」的真正契约:用户上滑浏览历史时,
                // 测得的流式增长不得把视口拽回底部。
                XCTAssertFalse(transition.commands.contains { command in
                    if case .followBottom = command { return true }
                    return false
                })
            } else {
                // 2026-07-26 撤锚更正:sizeChanges 底锚不再是流式增长的写者
                // (真机录屏实测 -390px 结构性跳变,详见 NovelSessionView.swift
                // 撤锚注释)。measured-geometry 回调重新成为跟随底部的唯一写者,
                // 命令必须是 animated:false——执行侧 scrollToBottomWithoutAnimation()
                // 用 Transaction(animation: nil) 禁用动画,不经过 startExplicitBottomAnimation()
                // 的 0.2s easeOut,这正是 PROJECT_STATE 2026-07-21 记录的「先欠账
                // 0.08s 动画追回」53pt 回归不复发的关键。
                XCTAssertTrue(transition.commands.contains(.followBottom(animated: false)))
            }
            follow = transition.state
        }

        XCTAssertGreaterThan(baseline.rows.last?.content.count ?? 0, 4_000)
        XCTAssertEqual(follow.mode, .followingBottom)
    }

    func testLargeSessionProjectsAllRows() throws {
        let fixture = try makeFixture()
        var session = fixture.session
        var messages: [NovelSessionMessageRecord] = []
        var candidates: [NovelCandidateRecord] = []
        var pendingOperations: [NovelPendingOperationRecord] = []
        messages.reserveCapacity(500)
        candidates.reserveCapacity(500)
        pendingOperations.reserveCapacity(500)

        for index in 0..<500 {
            let candidateID = NovelCandidateID()
            let message = makeMessage(
                sequence: Int64(index),
                role: .assistant,
                mode: .writeProse,
                kind: .proseCandidate,
                content: "长会话候选正文 \(index)",
                candidateID: candidateID
            )
            messages.append(message)
            candidates.append(makeCandidate(
                fixture: fixture,
                id: candidateID,
                sourceMessageID: message.id,
                kind: .prose,
                status: .available,
                content: message.content
            ))
            pendingOperations.append(makePending(
                fixture: fixture,
                candidateID: candidateID,
                status: .retryable
            ))
        }
        session.messages = messages
        let input = makeInput(
            fixture: fixture,
            session: session,
            candidates: candidates,
            pending: pendingOperations
        )
        XCTAssertEqual(NovelSessionPresentation.project(input).rows.count, messages.count)
    }

}
