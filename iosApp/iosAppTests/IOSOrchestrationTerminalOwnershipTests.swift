import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSOrchestrationTerminalOwnershipTests: IOSOrchestrationToolTestCase {
    func testCancelledFollowupWithoutNewAssistantDoesNotDeliverPreviousReport() async throws {
        let oldReport = "上一轮已经完成的报告，不是新任务结果。"
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.user(prompt: "上一轮任务"),
            UIMessage.companion.assistant(prompt: oldReport),
            UIMessage.companion.user(prompt: "新一轮任务，尚未开始输出"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.service.notifyRunTerminal(
            conversationId: fixture.childID,
            runId: "cancelled-before-output",
            finalMessages: fixture.messages,
            displayBaseline: fixture.displayBaseline,
            terminalStatus: .cancelled
        )

        let envelope = try await finalEnvelope(in: fixture, runID: "cancelled-before-output")
        XCTAssertFalse(envelope.payload.contains(oldReport), "本轮无输出时，旧 assistant 不能成为新 run 的答复。")
        let metadata = try XCTUnwrap(terminalMetadata(in: envelope.payload))
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        XCTAssertEqual(metadata["run_ended"] as? Bool, true)
    }

    func testCancelledFollowupDeliversOnlyCurrentPartialWithTerminalStatusOnce() async throws {
        let oldReport = "旧轮报告不得重复投递。"
        let partial = "本轮目前只核实了这一条。"
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.assistant(prompt: oldReport),
            UIMessage.companion.user(prompt: "新的核查任务"),
            UIMessage.companion.assistant(prompt: partial),
        ], generatedMessageCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for _ in 0..<2 {
            await fixture.service.notifyRunTerminal(
                conversationId: fixture.childID,
                runId: "cancelled-with-partial",
                finalMessages: fixture.messages,
                displayBaseline: fixture.displayBaseline,
                terminalStatus: .cancelled
            )
        }

        let envelope = try await finalEnvelope(in: fixture, runID: "cancelled-with-partial")
        XCTAssertTrue(envelope.payload.contains(partial))
        XCTAssertFalse(envelope.payload.contains(oldReport))
        let metadata = try XCTUnwrap(terminalMetadata(in: envelope.payload))
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        let pending = try await fixture.database.mailboxDao().pendingForRecipient(
            recipientId: fixture.parentID.toHexDashString()
        )
        XCTAssertEqual(pending.filter { $0.parentTurnId == "cancelled-with-partial" }.count, 1)
    }

    func testInterruptedFollowupWithoutOutputReportsCurrentReasonInsteadOfOldReport() async throws {
        let oldReport = "很长的旧结论，不属于本轮。"
        let reason = "background_expired"
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.assistant(prompt: oldReport),
            UIMessage.companion.user(prompt: "等待执行的后续任务"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.service.notifyRunTerminal(
            conversationId: fixture.childID,
            runId: "interrupted-before-output",
            finalMessages: fixture.messages,
            displayBaseline: fixture.displayBaseline,
            terminalStatus: .interrupted,
            terminalReason: reason
        )

        let envelope = try await finalEnvelope(in: fixture, runID: "interrupted-before-output")
        XCTAssertFalse(envelope.payload.contains(oldReport))
        let metadata = try XCTUnwrap(terminalMetadata(in: envelope.payload))
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.interrupted.wireName)
        XCTAssertEqual(metadata["terminal_reason"] as? String, reason)
    }

    func testLongCurrentReportReferencesItsOwnStoredMessage() async throws {
        let report = String(repeating: "本轮完整报告。", count: 500)
        let currentMessage = UIMessage.companion.assistant(prompt: report)
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.assistant(prompt: "上一轮的旧报告。"),
            UIMessage.companion.user(prompt: "新任务"),
            currentMessage,
        ], generatedMessageCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.service.notifyRunTerminal(
            conversationId: fixture.childID,
            runId: "completed-current-report",
            finalMessages: fixture.messages,
            displayBaseline: fixture.displayBaseline,
            terminalStatus: .completed
        )

        let envelope = try await finalEnvelope(in: fixture, runID: "completed-current-report")
        XCTAssertTrue(envelope.payload.hasPrefix(String(report.prefix(IOSThreadOrchestrationToolService.finalAnswerMaxChars))))
        let referenceLine = try XCTUnwrap(envelope.payload.components(separatedBy: "\n").first {
            $0.hasPrefix("{") && $0.contains("\"session_read\"")
        })
        let metadata = parseJSON(referenceLine)
        let reference = try XCTUnwrap(metadata["session_read"] as? [String: Any])
        XCTAssertEqual(reference["conversation_id"] as? String, fixture.childID.toHexDashString())
        XCTAssertEqual(reference["message_id"] as? String, currentMessage.id.toHexDashString())
        XCTAssertEqual(metadata["total_chars"] as? Int, report.count)
    }

    func testForegroundCompositionForwardsFrozenBaselineAndDurableTerminalReason() async throws {
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.assistant(prompt: "旧报告不属于当前前台运行"),
            UIMessage.companion.user(prompt: "新任务尚未输出"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        let previousCallback = coordinator.onRunTerminal
        defer { coordinator.onRunTerminal = previousCallback }
        let viewModel = makeViewModel(for: fixture)
        let runID = "foreground-composition-cancelled"
        try await recordTerminal(runID: runID, reason: "user_cancelled", fixture: fixture)
        await fixture.store.selectConversation(id: fixture.parentID)
        viewModel.reloadFromStore()
        let state = ChatConversationRunState(conversationId: fixture.childID)
        state.messages = fixture.messages

        await viewModel.makeGenerationBindings(state: state).onRunTerminal(
            fixture.childID, runID, .cancelled, fixture.messages, fixture.displayBaseline
        )

        let envelope = try await finalEnvelope(in: fixture, runID: runID)
        XCTAssertFalse(envelope.payload.contains("旧报告不属于当前前台运行"))
        let metadata = try XCTUnwrap(terminalMetadata(in: envelope.payload))
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        XCTAssertEqual(metadata["terminal_reason"] as? String, "user_cancelled")
        XCTAssertEqual(viewModel.currentConversationId, fixture.parentID)
    }

    func testBackgroundViewModelConsumerForwardsFrozenBaselineAndDurableStatus() async throws {
        let fixture = try await makeChildFixture(messages: [
            UIMessage.companion.assistant(prompt: "旧报告不属于当前后台运行"),
            UIMessage.companion.user(prompt: "后台新任务尚未输出"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        let previousCallback = coordinator.onRunTerminal
        defer { coordinator.onRunTerminal = previousCallback }
        let viewModel = makeViewModel(for: fixture)
        let runID = "background-consumer-cancelled"
        try await recordTerminal(runID: runID, reason: "user_cancelled", fixture: fixture)
        await fixture.store.selectConversation(id: fixture.parentID)
        viewModel.reloadFromStore()
        let callback = try XCTUnwrap(coordinator.onRunTerminal)

        await callback(fixture.childID, runID, fixture.messages, fixture.displayBaseline)

        let envelope = try await finalEnvelope(in: fixture, runID: runID)
        XCTAssertFalse(envelope.payload.contains("旧报告不属于当前后台运行"))
        let metadata = try XCTUnwrap(terminalMetadata(in: envelope.payload))
        XCTAssertEqual(metadata["terminal_status"] as? String, AgentRunStatus.cancelled.wireName)
        XCTAssertEqual(metadata["terminal_reason"] as? String, "user_cancelled")
        XCTAssertEqual(viewModel.currentConversationId, fixture.parentID)
    }

    private struct ChildFixture {
        let directory: URL
        let store: IOSConversationStore
        let database: AgentRuntimeDatabase
        let service: IOSThreadOrchestrationToolService
        let parentID: KotlinUuid
        let childID: KotlinUuid
        let messages: [UIMessage]
        let displayBaseline: [UIMessage]
    }

    private func makeChildFixture(
        messages: [UIMessage],
        generatedMessageCount: Int = 0
    ) async throws -> ChildFixture {
        let directory = makeTempDirectory("TerminalOwnership")
        let store = makeStore(directory: directory)
        let database = makeDatabase(directory: directory)
        await store.newConversation()
        let parentID = try XCTUnwrap(store.currentConversation?.id)
        await store.newConversation()
        let childID = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: messages)
        try await database.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childID.toHexDashString(),
            parentThreadId: parentID.toHexDashString(),
            agentPath: "/root/worker",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: 1
        ))
        let service = makeService(
            store: store,
            db: database,
            scheduler: FakeBackgroundScheduler(),
            currentConversationId: { childID }
        )
        return ChildFixture(
            directory: directory,
            store: store,
            database: database,
            service: service,
            parentID: parentID,
            childID: childID,
            messages: messages,
            displayBaseline: Array(messages.dropLast(generatedMessageCount))
        )
    }

    private func makeViewModel(for fixture: ChildFixture) -> ChatViewModel {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            mailboxStore: IOSMailboxStore(mailboxDao: fixture.database.mailboxDao()),
            orchestrationToolService: fixture.service,
            agentRuntimeDao: fixture.database.agentRuntimeDao()
        )
        viewModel.conversationStore = fixture.store
        return viewModel
    }

    private func recordTerminal(runID: String, reason: String, fixture: ChildFixture) async throws {
        let store = IOSDurableRunStore(dao: fixture.database.agentRuntimeDao())
        let started = try await store.startChatRun(
            runId: runID, startedAt: 1, inputDigest: runID,
            conversationId: fixture.childID.toHexDashString()
        )
        XCTAssertTrue(started)
        let settled = try await store.transition(runId: runID, expected: .running, to: .cancelled, detail: reason)
        XCTAssertTrue(settled)
    }

    private func finalEnvelope(in fixture: ChildFixture, runID: String) async throws -> MailboxEnvelopeEntity {
        let pending = try await fixture.database.mailboxDao().pendingForRecipient(
            recipientId: fixture.parentID.toHexDashString()
        )
        return try XCTUnwrap(pending.first {
            $0.parentTurnId == runID && $0.type == MailboxEnvelopeType.finalAnswer.name
        })
    }

    private func terminalMetadata(in payload: String) -> [String: Any]? {
        payload.components(separatedBy: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["terminal_status"] != nil else { return nil }
            return object
        }.first
    }
}
