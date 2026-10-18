import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


/// Council runner mechanics tests. The iOS Room runner is the formal execution
/// path; fake streamers/researchers keep these tests offline and deterministic.
@MainActor
final class IOSCouncilRunnerMechanicsTests: IOSCouncilMechanicsTestCase {
    func testCouncilRuntimeOwnershipAndBackgroundLeaseLifecycleAreWired() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosRoot = testsDirectory.deletingLastPathComponent()
        let shell = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/AppShell.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/Council/CouncilChatViewModel.swift"),
            encoding: .utf8
        )
        let background = try sourceBlock(shell, from: "case .background:", to: "case .active:")
        let start = try sourceBlock(runtime, from: "func startPendingDiscussion(", to: "\n    func cancelDiscussion")
        let begin = try sourceBlock(runtime, from: "private func beginBackgroundKeepAlive(",
                                    to: "\n    private func endBackgroundKeepAlive")
        let expiration = try sourceBlock(runtime, from: "private func handleBackgroundKeepAliveExpiration(",
                                         to: "\n    var hasPendingMaterials")

        XCTAssertTrue(shell.contains("@State private var councilChatViewModel: CouncilChatViewModel"))
        XCTAssertTrue(shell.contains("councilChatViewModel: councilChatViewModel"))
        XCTAssertEqual(shell.components(separatedBy: "viewModel: councilChatViewModel").count - 1, 1)
        XCTAssertFalse(shell.contains("case councilChat"))
        XCTAssertTrue(background.contains("councilChatViewModel.runtimeWillEnterBackground()"))
        XCTAssertFalse(shell.contains("councilChatViewModel.runtimeDidBecomeActive()"))
        XCTAssertTrue(start.contains("beginBackgroundKeepAlive(for: discussionID)"))
        XCTAssertTrue(begin.contains("let leaseId = keepAliveLeaseId(for: discussionID)"))
        XCTAssertTrue(runtime.contains("beginMaterialsKeepAlive()"))
        XCTAssertTrue(runtime.contains("\"council-materials\""))
        let expirationCallbacks = begin.components(separatedBy: "handleBackgroundKeepAliveExpiration(for: discussionID)")
        XCTAssertEqual(expirationCallbacks.count - 1, 2)
        XCTAssertTrue(expiration.contains("stopAndCheckpointActiveDiscussion("))

        let stop = try sourceBlock(runtime, from: "private func stopAndCheckpointActiveDiscussion(",
                                   to: "\n    private func stopActiveDiscussion")
        assertOrdered(stop,
            "runner.markActiveTaskTerminal",
            "stopActiveDiscussion(releaseBackgroundLease: false)",
            "persistTranscript()",
            "archiveCurrentRoom()",
            "endBackgroundKeepAlive(for: discussionID)")
    }

    func testCouncilProductionStreamerKeepsFIFOAndProviderRouting() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Council/CouncilTextStreaming.swift"),
            encoding: .utf8
        )
        let activeStream = try sourceBlock(source, from: "private final class IOSCouncilActiveTextStream",
                                           to: "final class IOSCouncilTextStreamer")
        let streamer = try sourceBlock(source, from: "final class IOSCouncilTextStreamer",
                                       to: "\n}\n")
        let dispatch = try sourceBlock(streamer, from: "private func dispatchCouncilStream(",
                                       to: "\n    func cancel()")
        let cancel = try sourceBlock(streamer, from: "func cancel()",
                                     to: "\n    private func clearActiveStreamIfNeeded")
        let chunkCallback = try sourceBlock(streamer, from: "onChunk: { chunk in", to: "onComplete:")

        XCTAssertTrue(streamer.contains("AsyncStream<ChatStreamEvent>(bufferingPolicy: .unbounded)"))
        XCTAssertTrue(streamer.contains("eventSink.bind(continuation)"))
        XCTAssertTrue(streamer.contains("eventSink.claim(event)"))
        XCTAssertTrue(chunkCallback.contains("eventSink.yield(.chunk(chunk))"))
        XCTAssertFalse(chunkCallback.contains("snapshot()"))
        XCTAssertFalse(chunkCallback.contains("Task { @MainActor"))

        assertOrdered(activeStream,
            "eventSink.finish()",
            "eventSink.takePendingChunks()",
            "presentation.flushAndClose()")
        XCTAssertTrue(cancel.contains("flushAndClose(drainingQueuedChunks: true)"))

        XCTAssertTrue(streamer.contains("IOSCodexProviderResolver.resolved(providerSetting)"))
        XCTAssertTrue(streamer.contains("IOSCodexProviderResolver.augmentParamsForCodex("))
        XCTAssertTrue(streamer.contains("providerSetting: effectiveProvider"))
        XCTAssertTrue(streamer.contains("params: effectiveParams"))
        assertOrdered(dispatch,
            "IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI)",
            "IOSGrokWebClient(providerId: providerId).streamText(",
            "return openAIProvider.streamTextCancellable(")
        let grokBranch = try sourceBlock(dispatch, from: "IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI)",
                                         to: "return openAIProvider.streamTextCancellable(")
        XCTAssertTrue(grokBranch.contains("onChunk: onChunk"))
    }

    func testCouncilPresentationSessionCoalescesSnapshotsUntilFlushWindow() async throws {
        let probe = CouncilPresentationProbe()
        let didPublish = expectation(description: "Council presentation window flushed")
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 20_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: { text, _ in
                probe.published.append(text)
                didPublish.fulfill()
            }
        )

        probe.authoritativeText = "A"
        session.scheduleFlush()
        probe.authoritativeText = "AB"
        session.scheduleFlush()
        probe.authoritativeText = "ABC"
        session.scheduleFlush()

        XCTAssertEqual(probe.snapshotCount, 0, "Chunk intake must not snapshot before the presentation window flushes.")
        await fulfillment(of: [didPublish], timeout: 1)
        XCTAssertEqual(probe.snapshotCount, 1)
        XCTAssertEqual(probe.published, ["ABC"], "One window should publish only the latest cumulative snapshot.")
    }

    func testCouncilPresentationSessionTerminalFlushIsExactAndCancelsDelayedFlush() async throws {
        let probe = CouncilPresentationProbe(authoritativeText: "partial")
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 1_000_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: { text, _ in probe.published.append(text) }
        )

        session.scheduleFlush()
        probe.authoritativeText = "authoritative final"
        let final = session.flushAndClose()

        XCTAssertEqual(final, "authoritative final")
        XCTAssertEqual(probe.snapshotCount, 1)
        XCTAssertEqual(probe.published, ["authoritative final"])
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(probe.snapshotCount, 1, "The cancelled delayed flush must not snapshot after terminal close.")
        XCTAssertEqual(probe.published, ["authoritative final"])
    }

    /// 停止发生在 `drainAndClose` 已关闭、全文尚未发完时：`flushAndClose`
    /// 必须立刻把权威全文推给 onUpdate。否则 runner.cancel 看到已关闭就
    /// 直接返回，视图只留半截前缀。
    func testFlushAndClosePublishesFinalTextWhenDrainAlreadyClosed() async throws {
        let prefix = "已显示"
        let fullText = prefix + String(repeating: "字", count: 2_000)
        let probe = CouncilPresentationProbe(authoritativeText: prefix)
        var published: [String] = []
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 20_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: { text, _ in published.append(text) }
        )

        session.scheduleFlush()
        let prefixDeadline = Date().addingTimeInterval(1)
        while published.last != prefix, Date() < prefixDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(published.last, prefix)

        probe.authoritativeText = fullText
        let drainTask = Task { await session.drainAndClose() }
        let closedDeadline = Date().addingTimeInterval(1)
        while !session.isClosed, Date() < closedDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(session.isClosed)
        XCTAssertNotEqual(published.last, fullText, "precondition: 排空尚未发完全文")

        let flushed = session.flushAndClose()
        XCTAssertEqual(flushed, fullText)
        XCTAssertEqual(published.last, fullText, "已关闭时 flushAndClose 必须立刻发布权威全文")

        drainTask.cancel()
        _ = await drainTask
    }

    // MARK: - 流式节奏层与终态排空契约（StreamPresentationPacingPolicy 同源）

    /// 流式爆发：provider 一次吐出大积压，展示侧按 48ms 节奏拍逐拍追平——
    /// 单拍推进 ≤ 流式上限、前缀单调、流式拍 allowance 恒为 1（与 Chat 语义一致）。
    func testCouncilPresentationSessionPacesBurstAcrossBeats() async throws {
        let fullText = "已显示" + String(repeating: "长", count: 300)
        let probe = CouncilPresentationProbe(authoritativeText: fullText)
        var published: [String] = []
        var allowances: [CGFloat] = []
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 20_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: {
                published.append($0)
                allowances.append($1)
            }
        )

        session.scheduleFlush()
        let deadline = Date().addingTimeInterval(3)
        while published.last != fullText, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            published.last,
            fullText,
            "流式拍必须逐拍追平权威快照（300 字积压应在 ~9 拍内完成）"
        )
        XCTAssertGreaterThan(published.count, 1, "大积压必须分多拍输出，不能一拍倒完")
        for (previous, next) in zip(published, published.dropFirst()) {
            XCTAssertTrue(
                next.hasPrefix(previous),
                "流式前缀必须单调增长：\(previous.prefix(12))… → \(next.prefix(12))…"
            )
        }
        let advances = zip(published, published.dropFirst()).map { $1.count - $0.count }
        XCTAssertLessThanOrEqual(
            advances.max() ?? 0,
            StreamPresentationPacingPolicy.maximumTextAdvance,
            "流式单拍推进不得超过流式上限（36 字），否则 TextKit 高度与底部跟随追不上"
        )
        XCTAssertTrue(
            allowances.allSatisfy { $0 == 1 },
            "流式拍 allowance 必须恒为 1，只有终态排空才收紧：\(allowances)"
        )
    }

    /// 终态排空契约：完成时积压一次定锚（whoosh 中段 > 流式上限），尾段随剩余
    /// 连续减速到打字节奏（末拍 ≤ 12 字），lagAllowance 随剩余单调衰减到 0。
    func testCouncilTerminalDrainDeceleratesGracefulTailAndTightensAllowance() async throws {
        let fullText = "已显示" + String(repeating: "字", count: 2_000)
        let probe = CouncilPresentationProbe(authoritativeText: fullText)
        var published: [String] = []
        var allowances: [CGFloat] = []
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 1_000_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: {
                published.append($0)
                allowances.append($1)
            }
        )

        let final = await session.drainAndClose()

        XCTAssertEqual(final, fullText, "排空必须返回权威全文")
        XCTAssertEqual(published.last, fullText, "最后一拍必须落定权威全文")
        XCTAssertGreaterThan(published.count, 1)
        for (previous, next) in zip(published, published.dropFirst()) {
            XCTAssertTrue(next.hasPrefix(previous), "排空前缀必须单调增长")
        }
        let advances = zip(published, published.dropFirst()).map { $1.count - $0.count }
        XCTAssertGreaterThan(
            advances.first ?? 0,
            StreamPresentationPacingPolicy.maximumTextAdvance,
            "大积压排空中段必须 whoosh（拍速超过流式上限，避免 2000 字拖十几秒）"
        )
        XCTAssertLessThanOrEqual(
            advances.last ?? Int.max,
            StreamPresentationPacingPolicy.minimumTextAdvance,
            "末拍必须回到打字节奏（优雅尾），最后一个字逐字落定"
        )
        XCTAssertEqual(allowances.last, 0, "最后一拍落定后 allowance 必须归零")
        XCTAssertLessThanOrEqual(allowances.first ?? 1, 1)
        XCTAssertTrue(
            zip(allowances, allowances.dropFirst()).allSatisfy { $0 >= $1 },
            "allowance 必须随剩余积压单调衰减（连续收紧，无分档回跳）：\(allowances)"
        )
    }

    /// 完成零跳变契约（driver 级，议会议会无 UI 回放基建——真实回放形态参考
    /// ChatSwiftUIStreamReplayTests.testTerminalDrainLagAllowanceLandsViewportWithoutCompletionHop；
    /// UI 级逐帧复核留待真机）。
    ///
    /// 用生产排空拍序列（真实 IOSCouncilTextPresentationSession.drainAndClose）
    /// 驱动共享 NativeTimelineScrollCore：流式→排空→完成全窗帧间位移连续、
    /// 无单帧瞬移、无回跳，终态收敛贴底。
    func testCouncilCompletionDrainCommitsContinuousDisplacementAndPinsDriver() async throws {
        // 与 Chat 回放同口径：排空段从 ~576 字积压开始（锚速 36 字/拍），
        // whoosh 中段由排空契约（上一条）锁定拍速，这里锁视口运动连续性。
        let fullText = "已显示" + String(repeating: "字", count: 576)
        let probe = CouncilPresentationProbe(authoritativeText: fullText)
        var beats: [(advance: Int, allowance: CGFloat)] = []
        var previousLength = 0
        let session = IOSCouncilTextPresentationSession(
            flushDelayNanoseconds: 1_000_000_000,
            snapshotProvider: {
                probe.snapshotCount += 1
                return probe.authoritativeText
            },
            onUpdate: { text, allowance in
                let length = text.count
                beats.append((advance: length - previousLength, allowance: allowance))
                previousLength = length
            }
        )
        _ = await session.drainAndClose()
        XCTAssertGreaterThan(beats.count, 1)

        // —— 核心模拟：1 字 ≈ 1pt 高度（单调模型，只锁运动连续性）——
        let viewport: CGFloat = 800
        let bottomInset: CGFloat = 120
        let visibleHeight = viewport - bottomInset
        var now: TimeInterval = 1_000
        // 排空前视口已贴底：bottomTarget = contentHeight - visibleHeight。
        var contentHeight: CGFloat = visibleHeight + 400
        var offsetY: CGFloat = 400
        func geometry() -> NativeTimelineScrollGeometry {
            NativeTimelineScrollGeometry(
                offsetY: offsetY,
                contentHeight: contentHeight,
                viewportHeight: viewport,
                adjustedInsetTop: 0,
                adjustedInsetBottom: bottomInset,
                distanceToBottom: max(0, contentHeight - offsetY - visibleHeight),
                userInteracting: false
            )
        }
        func apply(_ actions: [NativeTimelineScrollAction]) {
            for action in actions {
                if case let .writeOffsetY(y) = action {
                    offsetY = y
                }
            }
        }
        var state: NativeTimelineScrollState = .followingBottom(
            virtualOffset: offsetY,
            target: contentHeight - visibleHeight,
            lastFollowRequestAt: now,
            lagAllowance: 1
        )
        var samples: [CGFloat] = [offsetY]
        for beat in beats {
            contentHeight += CGFloat(beat.advance)
            let reduced = NativeTimelineScrollCore.reduce(
                state: state,
                intent: .streamContentGrew(lagAllowance: beat.allowance),
                geometry: geometry(),
                now: now
            )
            state = reduced.state
            apply(reduced.actions)
            // 一拍 ≈ 48ms ≈ 3 帧 @60Hz。
            for _ in 0..<3 {
                now += 1.0 / 60.0
                let ticked = NativeTimelineScrollCore.tick(
                    state: state,
                    geometry: geometry(),
                    now: now,
                    dt: 1.0 / 60.0
                )
                state = ticked.state
                apply(ticked.actions)
                samples.append(offsetY)
            }
        }
        // 完成：generationTerminated → settlingAfterTerminal 逐帧钉底 + 静默交还。
        // 完成窗从最后一拍排空的帧起算（与 Chat 回放的 paragraphLength==final 同口径）。
        let completionWindowStart = samples.count - 3
        let terminal = NativeTimelineScrollCore.reduce(
            state: state,
            intent: .generationTerminated,
            geometry: geometry(),
            now: now
        )
        state = terminal.state
        apply(terminal.actions)
        for _ in 0..<120 {
            now += 1.0 / 60.0
            let ticked = NativeTimelineScrollCore.tick(
                state: state,
                geometry: geometry(),
                now: now,
                dt: 1.0 / 60.0
            )
            state = ticked.state
            apply(ticked.actions)
            samples.append(offsetY)
        }

        // 契约一：完成窗（最后一拍排空 + generationTerminated + settle）帧间位移
        // ≤ 14pt——与 ChatSwiftUIStreamReplayTests 的完成窗校准同口径：排空收尾
        // 的收紧值已让视口在最后一拍前贴回底部，完成瞬间不得再有任何单帧瞬移。
        let completionWindowShifts = zip(
            samples.dropFirst(completionWindowStart),
            samples.dropFirst(completionWindowStart - 1)
        ).map { abs($0 - $1) }
        XCTAssertLessThanOrEqual(
            completionWindowShifts.max() ?? 0,
            14.0,
            "完成窗的帧间位移必须连续（缓动追入），不允许单帧瞬移：\(completionWindowShifts.max() ?? 0)"
        )
        // 契约二：全窗（流式→排空→完成）帧间位移 ≤ 24pt——合成模型 60Hz 下
        // whoosh 中段的指数追底稳态滞后首帧 ~16pt（速度连续，非瞬移），
        // 24pt 上限仍能抓住旧病（完成瞬间瞬时钉底一帧清 30–50pt 欠账）。
        // 本断言只锁「无单帧瞬移」：排空拍速的 whoosh/减速曲线由
        // testCouncilTerminalDrainDeceleratesGracefulTailAndTightensAllowance 锁定。
        let maximumFrameShift = zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumFrameShift,
            24.0,
            "流式→排空→完成序列不得出现单帧瞬移（指数追底速度连续）：\(maximumFrameShift)"
        )
        XCTAssertTrue(
            zip(samples.dropFirst(), samples).allSatisfy { $0 >= $1 },
            "完成序列不得回跳（单调贴底）"
        )
        let finalDistance = max(0, contentHeight - offsetY - visibleHeight)
        XCTAssertLessThanOrEqual(
            finalDistance,
            2.0,
            "完成序列必须收敛贴底：\(finalDistance)"
        )
    }

    /// 生产接线锁：完成路径必须走 drainAndClose（优雅排空），失败/取消仍走
    /// flushAndClose（精确落定）；updateMessage 事件携带 lagAllowance，视图提交
    /// streamContentGrew(lagAllowance:) 并让整轮结束走 generationTerminated。
    func testCouncilPacingWiringCarriesAllowanceToDriverCommit() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosRoot = testsDirectory.deletingLastPathComponent()
        let streamingSource = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/Council/CouncilTextStreaming.swift"),
            encoding: .utf8
        )
        let eventSource = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/Council/CouncilRoomRunTypes.swift"),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/Council/CouncilChatViewModel.swift"),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: iosRoot.appendingPathComponent("iosApp/CouncilChatRuntimeView.swift"),
            encoding: .utf8
        )

        let completePath = try sourceBlock(
            streamingSource,
            from: "case .complete:",
            to: "clearActiveStreamIfNeeded(stream)"
        )
        XCTAssertTrue(
            completePath.contains("await stream.drainAndClose(drainingQueuedChunks: false)"),
            "完成路径必须走优雅排空（drainAndClose），而不是精确整段落定"
        )
        XCTAssertTrue(
            eventSource.contains("case updateMessage(id: UUID, body: String, status: IOSCouncilRoomMessageStatus, lagAllowance: CGFloat)"),
            "updateMessage 事件必须携带 lagAllowance"
        )
        XCTAssertTrue(
            viewModelSource.contains("activeTailLagAllowance = lagAllowance"),
            "视图模型必须接收排空拍收紧值"
        )
        XCTAssertTrue(
            runtimeSource.contains("scrollDriver.submit(.streamContentGrew(lagAllowance: viewModel.activeTailLagAllowance))"),
            "驱动提交必须携带当前收紧值（默认 1 会把同拍先发的收紧逐拍打回）"
        )
        XCTAssertTrue(
            runtimeSource.contains("scrollDriver.submit(.generationTerminated)"),
            "整轮结束必须走 driver 的 generationTerminated（逐帧钉底 + 静默交还）"
        )
    }

    /// 完成事件必须携带排空收尾的收紧值（0），不得把默认 1 打回；流式拍透传 1。
    func testCouncilRunnerCarriesDrainAllowanceIntoCompletionEvents() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let runner = IOSCouncilRoomRunner(
            streamer: PacedCouncilStreamer(),
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var events: [IOSCouncilRoomEvent] = []
        _ = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .denied
            ),
            onEvent: { events.append($0) }
        )
        let allowances = events.compactMap { event -> CGFloat? in
            guard case let .updateMessage(_, _, _, lagAllowance) = event else { return nil }
            return lagAllowance
        }
        XCTAssertTrue(allowances.contains(1), "流式拍必须透传 allowance 1")
        XCTAssertTrue(allowances.contains(0.5), "排空拍必须透传中间收紧值")
        XCTAssertEqual(
            allowances.last,
            0,
            "完成事件必须携带排空收尾的收紧值（0），否则默认 1 会把最后一拍的收紧打回"
        )
    }

    func testCouncilGeneratedTextSnapshotDoesNotExposeInputBeforeAssistantOutput() {
        let inputMessages = [
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.system,
                parts: [UIMessagePart.Text(text: "内部主持提示", metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            ),
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.user,
                parts: [UIMessagePart.Text(text: "内部议会请求", metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            )
        ]
        let accumulator = MessageStreamAccumulator(initialMessages: inputMessages, model: nil)

        XCTAssertEqual(
            IOSCouncilGeneratedTextSnapshot.text(from: accumulator.snapshot()),
            "",
            "Usage-only, empty completion, error, or cancellation before the first assistant chunk must not publish the internal user prompt."
        )

        let assistant = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "对用户可见的生成结果", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        XCTAssertEqual(
            IOSCouncilGeneratedTextSnapshot.text(from: inputMessages + [assistant]),
            "对用户可见的生成结果"
        )
    }

    func testCouncilMarkdownPresentationMarksOnlyModelOutputAsStreamed() {
        let hostID = UUID()
        let host = CouncilChatMessage(
            id: hostID,
            kind: .host,
            author: "主持人",
            body: "正在生成",
            systemImage: "crown",
            tint: .red,
            subtitle: nil,
            status: .speaking
        )
        let system = CouncilChatMessage(
            kind: .system,
            author: "议会",
            body: "系统消息",
            systemImage: "info.circle",
            tint: .gray,
            subtitle: nil,
            status: .completed
        )

        XCTAssertTrue(host.usesStreamingMarkdown)
        XCTAssertTrue(host.isStreamingMarkdown)
        XCTAssertTrue(host.hasEverStreamedMarkdown)
        XCTAssertEqual(host.markdownRenderCacheNamespace, "council:\(hostID.uuidString)")
        XCTAssertFalse(system.usesStreamingMarkdown)
        XCTAssertFalse(system.isStreamingMarkdown)
        XCTAssertFalse(system.hasEverStreamedMarkdown)
    }

    func testCouncilMeasuredGrowthFollowRequiresActiveUnpausedFollowing() {
        XCTAssertTrue(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 101,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 99,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ), "Content shrink is handled by terminal settle, not live-growth animation.")
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 120,
            followEnabled: true,
            followPaused: true,
            userDragging: false,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 120,
            followEnabled: true,
            followPaused: false,
            userDragging: true,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 120,
            followEnabled: false,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
    }

    func testCouncilMeasuredGrowthFollowSkipsWhenAlreadyPinnedToBottom() {
        // The `.sizeChanges` anchor already pins content within the same layout
        // transaction; a redundant 0.08s scrollTo(edge:.bottom) command re-creates
        // the "double bottom-scroll command" anti-pattern from the novel-page fix.
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 101,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: true
        ), "Already-at-bottom growth must not re-issue a redundant follow animation.")
        XCTAssertTrue(CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
            previousContentHeight: 100,
            currentContentHeight: 101,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
    }

    func testCouncilViewportShrinkReanchorsOnlyWhileFollowing() {
        XCTAssertTrue(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 600,
            currentVisibleHeight: 500,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 500,
            currentVisibleHeight: 600,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 600,
            currentVisibleHeight: 500,
            followEnabled: true,
            followPaused: true,
            userDragging: false,
            alreadyAtBottom: false
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 600,
            currentVisibleHeight: 500,
            followEnabled: true,
            followPaused: false,
            userDragging: true,
            alreadyAtBottom: false
        ))
    }

    func testCouncilViewportShrinkSkipsWhenAlreadyPinnedToBottom() {
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 600,
            currentVisibleHeight: 500,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: true
        ))
        XCTAssertTrue(CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
            previousVisibleHeight: 600,
            currentVisibleHeight: 500,
            followEnabled: true,
            followPaused: false,
            userDragging: false,
            alreadyAtBottom: false
        ))
    }

    func testFollowPauseDoesNotFreezeCouncilMarkdown() {
        // `followPaused` only owns automatic scrolling. Council has one bounded,
        // sequential speaking row, so pausing follow must not visibly freeze that
        // row while it is still on screen.
        XCTAssertTrue(
            CouncilTranscriptFollowPolicy.liveRenderingEnabled,
            "A scroll-follow signal is not proof that the speaking row is offscreen."
        )
    }

    func testCouncilPendingLabelsStayOutOfMarkdownBody() {
        for placeholder in ["思考中...", "调研和完善议题中...", "点评中...", "总结中..."] {
            let speaking = CouncilChatMessage(
                kind: .host,
                author: "主持人",
                body: placeholder,
                systemImage: "crown",
                tint: .red,
                subtitle: nil,
                status: .speaking
            )

            XCTAssertNil(
                speaking.streamingMarkdownBody,
                "Pending UI copy must not become the old prefix of the first model output."
            )

            let interrupted = CouncilChatMessage(
                kind: .host,
                author: "主持人",
                body: placeholder,
                systemImage: "crown",
                tint: .red,
                subtitle: nil,
                status: .failed
            )
            XCTAssertNil(interrupted.streamingMarkdownBody)
            XCTAssertEqual(interrupted.displayBody, "未生成内容")
        }

        let output = CouncilChatMessage(
            kind: .guest,
            author: "议员",
            body: "真实模型输出",
            systemImage: "person",
            tint: .blue,
            subtitle: nil,
            status: .speaking
        )
        XCTAssertEqual(output.streamingMarkdownBody, "真实模型输出")
    }

    func testCouncilUserDragResumesFollowWithinNearBottomThreshold() {
        XCTAssertGreaterThan(
            ChatLayout.nearBottomResumeThreshold,
            ChatLayout.bottomStickThreshold,
            "Resume intent must stay distinct from physical true-bottom."
        )
        XCTAssertTrue(CouncilTranscriptFollowPolicy.shouldResumeFollowing(
            distanceToBottom: ChatLayout.nearBottomResumeThreshold
        ))
        XCTAssertFalse(CouncilTranscriptFollowPolicy.shouldResumeFollowing(
            distanceToBottom: ChatLayout.nearBottomResumeThreshold + 0.5
        ))
    }

}
