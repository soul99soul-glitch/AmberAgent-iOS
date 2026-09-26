import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ConversationActivityCenterTests: XCTestCase {
    private var directory: URL!
    private var store: IOSConversationStore!
    private var center: ConversationActivityCenter!
    private var dao: AgentRuntimeDao!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        dao = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runs.db").path)
            .agentRuntimeDao()
        center = ConversationActivityCenter(conversationStore: store, dao: dao, startedAt: .distantPast)
    }

    override func tearDown() async throws {
        center = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func conversation(_ title: String, messages: [UIMessage]) async throws -> KotlinUuid {
        let id = try XCTUnwrap(store.currentConversation?.id)
        let saved = await store.save(messages: messages, to: id)
        XCTAssertTrue(saved)
        await store.renameConversation(id: id, title: title)
        let created = await store.newConversation()
        XCTAssertTrue(created)
        return id
    }

    private func event(
        _ id: KotlinUuid, _ status: String, run: String = "run", time: Int64 = 1_000, pendingToken: String? = nil
    ) -> ConversationActivityCenter.RunEvent {
        .init(runId: run, conversationId: id.toHexDashString(), status: status,
              startedAt: time, finishedAt: status == "completed" || status == "failed" ? time + 100 : nil,
              pendingToken: pendingToken)
    }

    func testEventsProduceNoticesWithStoredTitleAndOneLinePreview() async throws {
        let question = IOSChatForegroundFixtures.assistantMessage(parts: [UIMessagePart.Tool(
            toolCallId: "question", toolName: "ask_user", input: #"{"question":"选择哪一项？\n请确认"}"#,
            output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        ), UIMessagePart.Tool(
            toolCallId: "later-question", toolName: "ask_user", input: #"{"question":"之后才要问的问题"}"#,
            output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )])
        let id = try await conversation("我的对话", messages: [question])
        await center.reconcile([event(id, "running")])
        XCTAssertTrue(center.notices.isEmpty)

        await center.reconcile([event(id, "awaiting_permission", pendingToken: "tool_call:question")])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)
        XCTAssertEqual(center.notices.first?.title, "我的对话")
        XCTAssertEqual(center.notices.first?.preview, "选择哪一项？ 请确认")

        let updated = await store.save(
            messages: [IOSChatForegroundFixtures.assistantText("更新后的预览")], to: id
        )
        XCTAssertTrue(updated)
        await center.reconcile([event(id, "awaiting_permission", pendingToken: "tool_call:question")])
        XCTAssertEqual(center.notices.first?.preview, "更新后的预览")

        let saved = await store.save(messages: [IOSChatForegroundFixtures.assistantText("回答第一行\n第二行")], to: id)
        XCTAssertTrue(saved)
        await center.reconcile([event(id, "failed")])
        XCTAssertEqual(center.notices.first?.kind, .failed)
        await center.reconcile([event(id, "completed")])
        XCTAssertEqual(center.notices.count, 1)
        XCTAssertEqual(center.notices.first?.kind, .completed)
        XCTAssertEqual(center.notices.first?.preview, "回答第一行 第二行")

        let latestMessage = await center.lastMessage(conversationId: id.toHexDashString())
        XCTAssertEqual(latestMessage?.toText(), "回答第一行\n第二行")
    }

    func testPriorityAndLatestRunPerConversation() async throws {
        let a = try await conversation("等待", messages: [IOSChatForegroundFixtures.assistantText("A")])
        let b = try await conversation("失败", messages: [IOSChatForegroundFixtures.assistantText("B")])
        let c = try await conversation("完成", messages: [IOSChatForegroundFixtures.assistantText("C")])
        await center.reconcile([event(c, "completed", time: 3_000), event(b, "failed", time: 2_000),
                                event(a, "awaiting_permission"), event(a, "failed", run: "old", time: 500)])
        XCTAssertEqual(center.notices.map(\.kind), [.awaitingUser, .failed, .completed])
        await center.reconcile([event(a, "completed", run: "new", time: 4_000),
                                event(b, "failed", time: 2_000), event(c, "completed", time: 3_000)])
        XCTAssertEqual(center.notices.map(\.conversationId), [b, a, c].map { $0.toHexDashString() })
    }

    func testEnteringConversationClearsNoticeAndRepeatedEventDoesNotRestoreIt() async throws {
        let id = try await conversation("完成", messages: [IOSChatForegroundFixtures.assistantText("答案")])
        let finished = event(id, "completed")
        await center.reconcile([finished])
        XCTAssertEqual(center.notices.count, 1)
        await store.selectConversation(id: id)
        center.conversationDidChange()
        XCTAssertTrue(center.notices.isEmpty)
        _ = await store.newConversation()
        await center.reconcile([finished])
        XCTAssertTrue(center.notices.isEmpty)
    }

    func testDidOpenConsumesCompletedAndFailedNoticesForBothRouteTypes() async throws {
        let ordinaryID = try await conversation("普通对话", messages: [IOSChatForegroundFixtures.assistantText("答案")])
        let transcriptID = try await conversation("子对话", messages: [IOSChatForegroundFixtures.assistantText("子答案")])
        let failed = event(ordinaryID, "failed")
        let completed = event(transcriptID, "completed")

        await center.reconcile([failed, completed])
        XCTAssertEqual(center.notices.count, 2)

        center.didOpenConversation(id: ordinaryID.toHexDashString(), succeeded: true, isTranscript: false)
        center.didOpenConversation(id: transcriptID.toHexDashString(), succeeded: true, isTranscript: true)
        center.transcriptConversationDidDisappear(id: transcriptID.toHexDashString())
        await center.reconcile([failed, completed])

        XCTAssertTrue(center.notices.isEmpty)
    }

    func testFailedOpenDoesNotConsumeNotice() async throws {
        let id = try await conversation("无法读取", messages: [IOSChatForegroundFixtures.assistantText("答案")])
        let failed = event(id, "failed")
        await center.reconcile([failed])
        XCTAssertEqual(center.notices.first?.kind, .failed)

        center.didOpenConversation(id: id.toHexDashString(), succeeded: false, isTranscript: true)
        await center.reconcile([failed])
        XCTAssertEqual(center.notices.first?.kind, .failed)

        center.didOpenConversation(id: id.toHexDashString(), succeeded: true, isTranscript: true)
        center.transcriptConversationDidDisappear(id: id.toHexDashString())
        await center.reconcile([failed])
        XCTAssertTrue(center.notices.isEmpty)
    }

    func testAwaitingNoticeReturnsAfterOrdinaryAndTranscriptRoutesClose() async throws {
        let ordinaryID = try await conversation("普通等待", messages: [IOSChatForegroundFixtures.assistantText("请确认")])
        let ordinaryWaiting = event(ordinaryID, "waiting_user")
        await center.reconcile([ordinaryWaiting])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)

        await store.selectConversation(id: ordinaryID)
        center.didOpenConversation(id: ordinaryID.toHexDashString(), succeeded: true, isTranscript: false)
        XCTAssertTrue(center.notices.isEmpty)
        _ = await store.newConversation()
        await center.reconcile([ordinaryWaiting])
        XCTAssertEqual(center.notices.first?.conversationId, ordinaryID.toHexDashString())

        let transcriptID = try await conversation("子对话等待", messages: [IOSChatForegroundFixtures.assistantText("请在子对话确认")])
        let transcriptWaiting = event(transcriptID, "waiting_user")
        await center.reconcile([ordinaryWaiting, transcriptWaiting])
        XCTAssertEqual(Set(center.notices.map(\.conversationId)), Set([
            ordinaryID.toHexDashString(), transcriptID.toHexDashString()
        ]))

        center.didOpenConversation(id: transcriptID.toHexDashString(), succeeded: true, isTranscript: true)
        await center.reconcile([ordinaryWaiting, transcriptWaiting])
        XCTAssertFalse(center.notices.contains { $0.conversationId == transcriptID.toHexDashString() })

        center.transcriptConversationDidDisappear(id: transcriptID.toHexDashString())
        await center.reconcile([ordinaryWaiting, transcriptWaiting])
        XCTAssertTrue(center.notices.contains {
            $0.conversationId == transcriptID.toHexDashString() && $0.kind == .awaitingUser
        })
    }

    func testDismissSuppressesReplayButAllowsNewEvent() async throws {
        let id = try await conversation("提醒", messages: [IOSChatForegroundFixtures.assistantText("答案")])
        let waiting = event(id, "awaiting_permission")
        await center.reconcile([waiting])
        center.dismiss(conversationId: id.toHexDashString())
        await center.reconcile([waiting])
        XCTAssertTrue(center.notices.isEmpty)
        await center.reconcile([event(id, "completed")])
        XCTAssertEqual(center.notices.first?.kind, .completed)
    }

    func testCurrentConversationEventsAreConsumedWithoutNotice() async throws {
        let id = try XCTUnwrap(store.currentConversation?.id)
        _ = await store.save(messages: [IOSChatForegroundFixtures.assistantText("答案")], to: id)
        for status in ["running", "awaiting_permission", "failed", "completed"] {
            await center.reconcile([event(id, status)])
            XCTAssertTrue(center.notices.isEmpty)
        }
        _ = await store.newConversation()
        await center.reconcile([event(id, "completed")])
        XCTAssertTrue(center.notices.isEmpty)
    }

    func testWaitingUserRunIsShownAfterLeavingConversation() async throws {
        let id = try XCTUnwrap(store.currentConversation?.id)
        _ = await store.save(messages: [IOSChatForegroundFixtures.assistantText("请先选择")], to: id)
        let waiting = event(id, "waiting_user", pendingToken: "tool_call:question")

        await center.reconcile([waiting])
        XCTAssertTrue(center.notices.isEmpty)

        _ = await store.newConversation()
        await center.reconcile([waiting])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)

        await store.selectConversation(id: id)
        // store 重算可能先于切会话观察回调清除已有提醒。
        await center.reconcile([waiting])
        center.conversationDidChange()
        XCTAssertTrue(center.notices.isEmpty)
        _ = await store.newConversation()
        await center.reconcile([waiting])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)
    }

    func testWaitingNoticeIsRemovedWhenRunResumesOrStops() async throws {
        let id = try await conversation("等待", messages: [IOSChatForegroundFixtures.assistantText("请确认")])
        let waiting = event(id, "waiting_user")
        await center.reconcile([waiting])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)

        await center.reconcile([event(id, "running")])
        XCTAssertTrue(center.notices.isEmpty)

        await center.reconcile([waiting])
        XCTAssertEqual(center.notices.first?.kind, .awaitingUser)
        for status in ["cancelled", "interrupted"] {
            await center.reconcile([event(id, status)])
            XCTAssertTrue(center.notices.isEmpty)
            await center.reconcile([waiting])
            XCTAssertEqual(center.notices.first?.kind, .awaitingUser)
        }
        XCTAssertNil(event(id, "timed_out").kind)
    }

    func testColdStartSuppressesHistoricalCompletedNotice() async throws {
        let id = try await conversation("历史完成", messages: [IOSChatForegroundFixtures.assistantText("旧答案")])
        center = ConversationActivityCenter(
            conversationStore: store,
            dao: dao,
            startedAt: Date(timeIntervalSince1970: 2)
        )

        await center.reconcile([event(id, "completed", time: 1_000)])

        XCTAssertTrue(center.notices.isEmpty)
    }

    func testEventWaitsForConversationSummariesInsteadOfBeingConsumed() async throws {
        let id = try await conversation("等待摘要", messages: [IOSChatForegroundFixtures.assistantText("完成内容")])
        let loadingStore = IOSConversationStore(baseDirectory: directory)
        let loadingCenter = ConversationActivityCenter(conversationStore: loadingStore, dao: dao, startedAt: .distantPast)
        let finished = event(id, "completed")
        await loadingCenter.reconcile([finished])
        XCTAssertTrue(loadingCenter.notices.isEmpty)

        await loadingStore.bootstrap()
        await loadingCenter.reconcile([finished])
        XCTAssertEqual(loadingCenter.notices.first?.conversationId, id.toHexDashString())
        XCTAssertEqual(loadingCenter.notices.first?.preview, "完成内容")
    }

    func testDurableRunNotificationsReachAppOwnedCenter() async throws {
        let id = try await conversation("后台对话", messages: [IOSChatForegroundFixtures.assistantText("后台回答")])
        center.start()
        let ledger = IOSDurableRunStore(dao: dao)
        let started = try await ledger.startChatRun(runId: "ordinary-run", startedAt: 1_000,
                                                  inputDigest: "test", conversationId: id.toHexDashString())
        XCTAssertTrue(started)
        let transitioned = try await ledger.transition(runId: "ordinary-run", expected: .running, to: .completed)
        XCTAssertTrue(transitioned)
        let deadline = Date().addingTimeInterval(5)
        while center.notices.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(center.notices.first?.kind, .completed)
        XCTAssertEqual(center.notices.first?.preview, "后台回答")
        await store.selectConversation(id: id)
        while !center.notices.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(center.notices.isEmpty)
    }
}
