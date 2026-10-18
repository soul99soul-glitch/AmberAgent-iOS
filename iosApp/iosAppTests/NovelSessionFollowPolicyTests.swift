import Foundation
import XCTest
@testable import iosApp

final class NovelSessionFollowPolicyTests: NovelSessionReplayTestCase {
    /// 2026-07-26 撤锚更正的核心锁:`.sizeChanges` 底锚被真机录屏(−390px 结构性
    /// 跳变)推翻后,measured-geometry 回调重新成为流式跟随底部的唯一写者。这条
    /// canary 锁住两件事,任何一件被破坏都会让 PROJECT_STATE 2026-07-21 记录的
    /// 53pt「先欠账、再用 0.08s 动画追回」回归复发:
    /// 1. `.followingBottom` / `.settlingTerminal`(收口为 `.followingBottom`)下的
    ///    `.measuredStreamGrowth` 必须发出 `.followBottom` 命令(不能再是 no-op);
    /// 2. 该命令必须显式 `animated: false`——执行侧
    ///    `NovelSessionView.scrollToBottomWithoutAnimation()` 用
    ///    `Transaction(animation: nil)` 禁用动画,不经过
    ///    `startExplicitBottomAnimation()` 的 0.2s easeOut(那个动画只保留给
    ///    `.explicitBottomRequested` 这类用户主动点击回底的语义,两者不可混淆)。
    func testMeasuredStreamGrowthWhileFollowingRestoresUnanimatedFollowWriter() {
        let followingTransition = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .followingBottom),
            event: .measuredStreamGrowth(isAtBottom: false)
        )
        XCTAssertEqual(followingTransition.state.mode, .followingBottom)
        XCTAssertEqual(followingTransition.commands, [.followBottom(animated: false)])

        let settlingTransition = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .settlingTerminal(token: 7)),
            event: .measuredStreamGrowth(isAtBottom: false)
        )
        XCTAssertEqual(settlingTransition.state.mode, .followingBottom)
        XCTAssertEqual(settlingTransition.commands, [.followBottom(animated: false)])

        // 浏览历史时仍然必须保持静默:这条负向断言防止「恢复写者」的改动
        // 误伤既有「不拽用户回底」契约。
        let browsingTransition = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .browsingHistory),
            event: .measuredStreamGrowth(isAtBottom: false)
        )
        XCTAssertEqual(browsingTransition.state.mode, .browsingHistory)
        XCTAssertTrue(browsingTransition.commands.isEmpty)
    }

    func testBottomFollowIgnoresStaleQuietTimerAndNeverPullsHistory() {
        var state = NovelSessionBottomFollowState()
        var transition = NovelSessionBottomFollowPolicy.reduce(
            state: state,
            event: .initialRowsPresented(hasRows: true)
        )
        XCTAssertEqual(transition.commands, [.anchorBottom])
        state = transition.state

        transition = NovelSessionBottomFollowPolicy.reduce(
            state: state,
            event: .viewportChanged(isAtBottom: false)
        )
        XCTAssertEqual(transition.state.mode, .followingBottom)
        XCTAssertEqual(transition.commands, [.followBottom(animated: false)])
        state = transition.state

        state = NovelSessionBottomFollowPolicy.reduce(
            state: state,
            event: .userDragEnded(isAtBottom: false)
        ).state
        XCTAssertEqual(state.mode, .browsingHistory)
        transition = NovelSessionBottomFollowPolicy.reduce(
            state: state,
            event: .measuredStreamGrowth(isAtBottom: false)
        )
        XCTAssertTrue(transition.commands.isEmpty)
        transition = NovelSessionBottomFollowPolicy.reduce(
            state: transition.state,
            event: .viewportChanged(isAtBottom: true)
        )
        XCTAssertEqual(transition.state.mode, .browsingHistory)
        XCTAssertFalse(transition.state.showsBottomButton)
        XCTAssertFalse(transition.commands.contains { command in
            if case .followBottom = command { return true }
            return false
        })

        transition = NovelSessionBottomFollowPolicy.reduce(
            state: transition.state,
            event: .explicitBottomRequested
        )
        XCTAssertEqual(transition.state.mode, .followingBottom)
        XCTAssertTrue(transition.commands.contains(.followBottom(animated: true)))

        let firstTerminal = NovelSessionBottomFollowPolicy.reduce(
            state: transition.state,
            event: .terminalReached
        )
        guard case .settlingTerminal(let firstToken) = firstTerminal.state.mode else {
            return XCTFail("Expected terminal settle mode")
        }
        let lateGrowth = NovelSessionBottomFollowPolicy.reduce(
            state: firstTerminal.state,
            event: .terminalLayoutChanged
        )
        guard case .settlingTerminal(let secondToken) = lateGrowth.state.mode else {
            return XCTFail("Expected restarted terminal settle mode")
        }
        XCTAssertGreaterThan(secondToken, firstToken)
        let staleTimer = NovelSessionBottomFollowPolicy.reduce(
            state: lateGrowth.state,
            event: .terminalQuietElapsed(token: firstToken)
        )
        XCTAssertEqual(staleTimer.state.mode, .settlingTerminal(token: secondToken))
        XCTAssertTrue(staleTimer.commands.isEmpty)
        let settled = NovelSessionBottomFollowPolicy.reduce(
            state: staleTimer.state,
            event: .terminalQuietElapsed(token: secondToken)
        )
        XCTAssertEqual(settled.state.mode, .followingBottom)
        XCTAssertEqual(settled.commands, [.followBottom(animated: false)])

        let postQuietGrowth = NovelSessionBottomFollowPolicy.reduce(
            state: settled.state,
            event: .terminalLayoutChanged
        )
        guard case .settlingTerminal(let thirdToken) = postQuietGrowth.state.mode else {
            return XCTFail("Expected late Markdown growth to restart terminal settling")
        }
        XCTAssertGreaterThan(thirdToken, secondToken)
        // 终态 settle 现在发 terminateGeneration（driver 逐帧钉底），
        // 不再发 followBottom(animated:false)（旧一次性 snap）。
        XCTAssertTrue(postQuietGrowth.commands.contains(.terminateGeneration))
        XCTAssertTrue(postQuietGrowth.commands.contains(
            .scheduleTerminalQuietSettle(
                token: thirdToken,
                delay: NovelSessionBottomFollowPolicy.terminalQuietDelay
            )
        ))
    }

    func testStreamStartReanchorsTheUserMessageAndWaitingTail() {
        let transition = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .browsingHistory, showsBottomButton: true),
            event: .streamStarted
        )

        XCTAssertEqual(transition.state.mode, .followingBottom)
        XCTAssertFalse(transition.state.showsBottomButton)
        XCTAssertEqual(transition.commands, [
            .setBottomButton(false),
            .anchorBottom,
        ])
    }

    func testSessionViewPresentsAlreadyLoadedRowsFromAwaitingInitialState() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift"),
            encoding: .utf8
        )
        let transcriptScope = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionTranscriptComponents.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var followState = NovelSessionBottomFollowState()"))
        XCTAssertTrue(source.contains("NovelSessionTranscriptScope("))
        XCTAssertTrue(source.contains("onInitialRows: presentInitialRowsIfNeeded"))
        XCTAssertTrue(transcriptScope.contains(".task(id: listSignal.sessionID)"))
        XCTAssertTrue(transcriptScope.contains("onInitialRows(listSignal)"))
    }

    func testUserDragEndingNearBottomCommitsSemanticBottomFollow() {
        let state = NovelSessionBottomFollowState(
            mode: .browsingHistory,
            showsBottomButton: true
        )

        let transition = NovelSessionBottomFollowPolicy.reduce(
            state: state,
            event: .userDragEnded(isAtBottom: true)
        )

        XCTAssertEqual(transition.state.mode, .followingBottom)
        XCTAssertFalse(transition.state.showsBottomButton)
        XCTAssertTrue(transition.commands.contains(.followBottom(animated: false)))
    }

    func testSessionViewFeedsMeasuredTerminalContentGrowthIntoFollowPolicy() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift"),
            encoding: .utf8
        )
        let chrome = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionChrome.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("contentHeight: geometry.contentSize.height"))
        XCTAssertTrue(source.contains("NovelSessionScrollGeometryPolicy.events("))
        XCTAssertTrue(source.contains("for event in followEvents"))
        XCTAssertTrue(source.contains("NovelSessionChrome("))
        XCTAssertTrue(chrome.contains("!viewModel.retryableBranchPendingOperations.isEmpty"))
        XCTAssertTrue(source.contains("NativeTimelineScrollReturnPolicy.returnedToBottom("))
        XCTAssertTrue(source.contains("dispatchFollowEvent(.userDragEnded(isAtBottom: returnedToBottom))"))
        XCTAssertTrue(source.contains("ChatLayout.nearBottomResumeThreshold"))
        XCTAssertTrue(source.contains("NativeTimelineUserDragPolicy.shouldBegin("))
        XCTAssertTrue(
            source.contains("isUIKitUserInteracting: scrollDriver.isUIKitUserInteracting"),
            "程序化 setContentOffset 产生的 interacting 不能被小说页误判成用户拖拽。"
        )
        XCTAssertTrue(
            source.contains("oldValue.rowCount - oldValue.activeRunRowCount"),
            "窗口吸收必须按 historical 行数。钉住的完成 run 下一轮才进历史,那时由 limitAfterRowsAppended 吸收。"
        )
        XCTAssertFalse(
            source.contains("NovelSessionHistoryWindowPolicy.limitAfterActiveRunReturnsToHistory("),
            "退役时行还在活动栈;再调用一遍会把同一批行算进窗口两次。"
        )
    }

    func testMeasuredContentGrowthUsesLiveOrTerminalFollowEvent() {
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 120,
                currentContentHeight: 132,
                userDragging: false,
                isLiveTail: true,
                isSettlingTerminal: false,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.measuredStreamGrowth(isAtBottom: false)]
        )
        // 未跟随底：晚到高度只走 static，不抢滚动。
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 132,
                currentContentHeight: 148,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: false,
                isFollowingBottom: false,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.staticContentGrowth(isAtBottom: false)]
        )
        // 跟随底且此前贴底：讨论完成后人物问答卡晚到插入应继续贴底。
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 132,
                currentContentHeight: 148,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: false,
                isFollowingBottom: true,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.measuredStreamGrowth(isAtBottom: false)]
        )
        // 跟随底但此前已离底：勿每帧抢滚动（会与布局互踢）。
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 132,
                currentContentHeight: 148,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: false,
                isFollowingBottom: true,
                previousIsAtBottom: false,
                currentIsAtBottom: false
            ),
            []
        )
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 148,
                currentContentHeight: 164,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: true,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.measuredTerminalGrowth(isAtBottom: false)]
        )
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 164,
                currentContentHeight: 180,
                userDragging: true,
                isLiveTail: true,
                isSettlingTerminal: false,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            []
        )
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 180,
                currentContentHeight: 168,
                userDragging: false,
                isLiveTail: true,
                isSettlingTerminal: false,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.viewportChanged(isAtBottom: false)]
        )
    }

    func testStaticContentGrowthDoesNotFallThroughToViewportFollow() {
        // 未跟随底时：到底状态翻转只产生按钮语义，不落入会触发回底的 viewportChanged。
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 120,
                currentContentHeight: 180,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: false,
                isFollowingBottom: false,
                previousIsAtBottom: true,
                currentIsAtBottom: false
            ),
            [.staticContentGrowth(isAtBottom: false)]
        )
        // 未翻转的静态增长依旧完全静默。
        XCTAssertEqual(
            NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: 120,
                currentContentHeight: 180,
                userDragging: false,
                isLiveTail: false,
                isSettlingTerminal: false,
                isFollowingBottom: false,
                previousIsAtBottom: true,
                currentIsAtBottom: true
            ),
            []
        )
    }

    func testStaticContentGrowthOnlyUpdatesBottomButtonWithoutScrollCommands() {
        let shifted = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .followingBottom),
            event: .staticContentGrowth(isAtBottom: false)
        )
        XCTAssertEqual(shifted.state.mode, .followingBottom)
        XCTAssertTrue(shifted.state.showsBottomButton)
        XCTAssertEqual(shifted.commands, [.setBottomButton(true)])

        let browsing = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .browsingHistory, showsBottomButton: true),
            event: .staticContentGrowth(isAtBottom: true)
        )
        XCTAssertEqual(browsing.state.mode, .browsingHistory)
        XCTAssertFalse(browsing.state.showsBottomButton)
        XCTAssertEqual(browsing.commands, [.setBottomButton(false)])

        let awaiting = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(),
            event: .staticContentGrowth(isAtBottom: false)
        )
        XCTAssertEqual(awaiting.state.mode, .awaitingInitialRows)
        XCTAssertTrue(awaiting.commands.isEmpty)
    }

    func testViewportReturnToBottomClearsStaleBottomButtonWhileFollowing() {
        // staticContentGrowth 会在 followingBottom 下亮按钮；随后几何回底
        // （viewportChanged(true)）必须收掉按钮，否则箭头与真实位置不一致。
        let shifted = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(mode: .followingBottom),
            event: .staticContentGrowth(isAtBottom: false)
        )
        XCTAssertTrue(shifted.state.showsBottomButton)

        let returned = NovelSessionBottomFollowPolicy.reduce(
            state: shifted.state,
            event: .viewportChanged(isAtBottom: true)
        )
        XCTAssertEqual(returned.state.mode, .followingBottom)
        XCTAssertFalse(returned.state.showsBottomButton)
        XCTAssertEqual(returned.commands, [.setBottomButton(false)])
    }

    /// 不变量:会话进行中追加新行,已经渲染过的顶部行不得被窗口踢出。
    /// 违反时 `startIndex` 前移,顶部长正文行(可达数万 pt)从 contentSize 里
    /// 整体消失,而消失发生在视口上方且无锚点补偿 → 整列表大幅位移。
    func testAppendingRowsNeverEvictsAlreadyRenderedTopRows() {
        var limit = NovelSessionHistoryWindowPolicy.initialLimit
        var rowCount = limit
        let startIndexBefore = NovelSessionHistoryWindowPolicy.startIndex(
            totalCount: rowCount,
            limit: limit
        )
        // 连续追加 20 行(一次生成里 user/assistant/工具行很容易到这个量级)。
        for _ in 0..<20 {
            let previousRowCount = rowCount
            rowCount += 1
            limit = NovelSessionHistoryWindowPolicy.limitAfterRowsAppended(
                currentLimit: limit,
                previousRowCount: previousRowCount,
                currentRowCount: rowCount
            )
            XCTAssertEqual(
                NovelSessionHistoryWindowPolicy.startIndex(totalCount: rowCount, limit: limit),
                startIndexBefore,
                "追加第 \(rowCount) 行后窗口起点前移,已渲染的顶部行被踢出"
            )
        }
    }

    /// 视图侧不得再用「是否贴底」当作是否吸收新增行的条件:贴底只影响可见性,
    /// 不影响这条不变量。带条件的旧写法正是位移的来源。
    func testHistoryWindowAbsorbsAppendedRowsRegardlessOfBottomProximity() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("NovelSessionHistoryWindowPolicy.limitAfterRowsAppended("),
            "追加行的吸收必须走策略层,便于单测锁不变量"
        )
        XCTAssertFalse(
            source.contains("newValue.rowCount > oldValue.rowCount, !latestAtBottom"),
            "不得再用 !latestAtBottom 门控窗口吸收"
        )
    }

    func testCompletionRaisesHistoryWindowLimitOnlyForRowsThatBecameHistorical() {
        // 完成：run 的 2 行全部转入历史，窗口上限吸收 2 行，完成前可见的旧行保持可见。
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterActiveRunReturnsToHistory(
                currentLimit: 4,
                activeRunRowCount: 2,
                previousRowCount: 12,
                currentRowCount: 12
            ),
            6
        )
        // 启动失败恢复：临时行整体消失，没有行转入历史，不得扩窗。
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterActiveRunReturnsToHistory(
                currentLimit: 4,
                activeRunRowCount: 2,
                previousRowCount: 12,
                currentRowCount: 10
            ),
            4
        )
        // 部分留存（user 行已耐久、assistant 行消失）：只吸收留存的那一行。
        XCTAssertEqual(
            NovelSessionHistoryWindowPolicy.limitAfterActiveRunReturnsToHistory(
                currentLimit: 4,
                activeRunRowCount: 2,
                previousRowCount: 12,
                currentRowCount: 11
            ),
            5
        )
    }

    func testRawStreamDeltaDoesNotOwnScrollingAndDisabledFollowShowsBottomButtonAfterGrowth() {
        let following = NovelSessionBottomFollowState(mode: .followingBottom)

        let rawDelta = NovelSessionBottomFollowPolicy.reduce(
            state: following,
            event: .streamDelta
        )
        XCTAssertTrue(rawDelta.commands.isEmpty)

        let disabledGrowth = NovelSessionBottomFollowPolicy.reduce(
            state: following,
            event: .measuredStreamGrowth(isAtBottom: false),
            followEnabled: false
        )
        XCTAssertEqual(disabledGrowth.state.mode, .browsingHistory)
        XCTAssertTrue(disabledGrowth.state.showsBottomButton)
        XCTAssertFalse(disabledGrowth.commands.contains { command in
            if case .followBottom = command { return true }
            return false
        })

        let shortContentGrowth = NovelSessionBottomFollowPolicy.reduce(
            state: following,
            event: .measuredStreamGrowth(isAtBottom: true),
            followEnabled: false
        )
        XCTAssertEqual(shortContentGrowth.state.mode, .followingBottom)
        XCTAssertFalse(shortContentGrowth.state.showsBottomButton)
        XCTAssertTrue(shortContentGrowth.commands.isEmpty)

        let disabledTerminalGrowth = NovelSessionBottomFollowPolicy.reduce(
            state: following,
            event: .measuredTerminalGrowth(isAtBottom: false),
            followEnabled: false
        )
        XCTAssertEqual(disabledTerminalGrowth.state.mode, .browsingHistory)
        XCTAssertTrue(disabledTerminalGrowth.state.showsBottomButton)

        let disabledNearBottomDrag = NovelSessionBottomFollowPolicy.reduce(
            state: NovelSessionBottomFollowState(
                mode: .browsingHistory,
                showsBottomButton: true
            ),
            event: .userDragEnded(isAtBottom: true),
            followEnabled: false
        )
        XCTAssertEqual(disabledNearBottomDrag.state.mode, .browsingHistory)
        XCTAssertFalse(disabledNearBottomDrag.state.showsBottomButton)
        XCTAssertFalse(disabledNearBottomDrag.commands.contains { command in
            if case .followBottom = command { return true }
            return false
        })
    }

    func testExplicitBottomAnimationOwnsItsFullWindowAndReplaysOnePendingFollow() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/NovelCreation/NovelSessionView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("explicitBottomAnimationTask != nil"))
        XCTAssertTrue(source.contains("explicitBottomFollowPending = true"))
        XCTAssertTrue(source.contains("try await Task.sleep(for: .seconds(0.2))"))
        XCTAssertTrue(source.contains("if shouldReplay"))
        XCTAssertTrue(source.contains("case .reset, .userDragBegan:"))
    }

// 真机复现（2026-10-01）：终态收尾时刚退役的尾部行与冻结快照行交替上报可见性，
// 争抢单槽 streamingTailVisibility，每次写入触发整页重算 → 自激循环卡死。
    /// 按真机日志回放：没有活跃尾部，跟踪的是 tail 行；stale 行因结构翻转反复误报。
    func testStaleRowReportsCannotStealTailVisibilityOwnership() {
        var tracked: String? = "tail"
        let reports: [(row: String, visible: Bool)] = [
            ("tail", true), ("stale", false), ("stale", false), ("tail", false),
            ("tail", true), ("stale", false), ("tail", true), ("stale", false),
        ]
        var writes = 0
        for report in reports where NovelSessionStreamingTailVisibilityOwnership.accepts(
            reportingMessageID: report.row,
            activeTailMessageID: nil,
            trackedMessageID: tracked
        ) {
            tracked = report.row
            writes += 1
        }
        XCTAssertEqual(tracked, "tail", "非所有者的上报不得抢走跟踪身份")
        XCTAssertEqual(writes, 4, "只有所有者 tail 的 4 次上报可以写入")
    }

    func testActiveTailOwnsVisibilityOverStickyTrackedRow() {
        XCTAssertTrue(NovelSessionStreamingTailVisibilityOwnership.accepts(
            reportingMessageID: "new", activeTailMessageID: "new", trackedMessageID: "old"
        ))
        XCTAssertFalse(NovelSessionStreamingTailVisibilityOwnership.accepts(
            reportingMessageID: "old", activeTailMessageID: "new", trackedMessageID: "old"
        ))
    }

    /// 跟踪身份被重置后，分支翻转产生的 onDisappear 误报不得把身份复活。
    func testReportWithoutOwnerIsIgnored() {
        XCTAssertFalse(NovelSessionStreamingTailVisibilityOwnership.accepts(
            reportingMessageID: "row", activeTailMessageID: nil, trackedMessageID: nil
        ))
    }
}
