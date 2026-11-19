import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSOutcomeUnknownAndFailureClassifierTests: XCTestCase {
    @MainActor
    func testRecheckRequestedReconcilesWithNeutralCopyAndUserRequestedRecheckOutcome() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-recheck-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-recheck-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()

        let toolPart = UIMessagePart.Tool(
            toolCallId: "tc-recheck-1",
            toolName: "workspace_file_write",
            input: #"{"path":"notes/plan.md","content":"hello"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantMsg = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolPart],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        await store.saveCurrent(messages: [assistantMsg])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let conversationIdStr = conversationId.toHexDashString()
        let runId = "run-recheck-\(UUID().uuidString)"

        let run = AgentRunEntity(
            runId: runId, parentRunId: nil,
            agentDescriptorId: IOSDurableRunStore.Descriptor.chat,
            agentVersion: IOSDurableRunStore.Descriptor.chatVersion,
            conversationId: conversationIdStr, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "running", inputDigest: "d", inputSnapshotRef: nil,
            inputSchemaVersion: 1, startedAt: 1, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-recheck-1",
            toolName: "workspace_file_write",
            argsDigest: "d-write",
            effectClass: .sideEffect
        )
        XCTAssertTrue(started)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false,
            agentRuntimeDao: dao
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        let sweep = await viewModel.applyToolCallLedgerRecovery(
            forInterruptedRuns: [(runId: runId, conversationId: conversationIdStr)]
        )
        XCTAssertTrue(sweep.outcomeUnknownRunIds.contains(runId))
        XCTAssertEqual(viewModel.pendingToolOutcomeUnknown?.localizedToolTitle, "写入 Workspace 文件")
        XCTAssertEqual(viewModel.pendingToolOutcomeUnknown?.redactedTargetSummary, "notes/plan.md")

        let originalDescriptor = try XCTUnwrap(viewModel.pendingToolOutcomeUnknown)
        await viewModel.reconcilePendingToolOutcome(resolution: .recheckRequested)

        XCTAssertNil(viewModel.pendingToolOutcomeUnknown)
        XCTAssertEqual(viewModel.outcomeUnknownFollowup?.resolution, .recheckRequested)

        let loadedPersisted = await store.messages(for: conversationId)
        let persisted = try XCTUnwrap(loadedPersisted)
        let persistedTool = try XCTUnwrap(persisted.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first)
        let rawText = persistedTool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        XCTAssertTrue(rawText.contains("user_requested_recheck"))
        XCTAssertTrue(rawText.contains(#""replay_prohibited":true"#))
        let reason = ChatToolOutputFormatter.failureReason(from: persistedTool.output) ?? ""
        XCTAssertFalse(reason.contains("没有生效"), "recheckRequested 文案必须中性，不能含'没有生效'")
        XCTAssertTrue(reason.contains("只读核查"))

        let loadedTransactions = await ledger.toolTransactions(runId: runId)
        let transactions = try XCTUnwrap(loadedTransactions)
        XCTAssertEqual(transactions.first?.state, .reconciled)
        XCTAssertEqual(transactions.first?.outcome, "user_requested_recheck")

        // A retained card/retry must not overwrite history after the ledger's immutable decision.
        viewModel.toolOutcomeUnknownDescriptors = [originalDescriptor]
        await viewModel.reconcilePendingToolOutcome(resolution: .notApplied)
        let afterConflict = await store.messages(for: conversationId) ?? []
        let conflictText = afterConflict.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
            .flatMap(\.output).compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        XCTAssertTrue(conflictText.contains("user_requested_recheck"))
        XCTAssertFalse(conflictText.contains("user_confirmed_not_applied"))

    }

    func testOutcomeUnknownDescriptorRedactsTokensAndLocalizesTitle() {
        let target = IOSToolOutcomeUnknownDescriptor.extractRedactedTargetSummary(
            from: #"{"target":"https://api.example.com?token=sk-1234567890abcdef"}"#
        )
        XCTAssertFalse(target?.contains("sk-1234567890abcdef") ?? true)
        XCTAssertTrue(target?.contains("[REDACTED]") ?? false)

        let descriptor = IOSToolOutcomeUnknownDescriptor(
            runId: "r1",
            conversationId: "c1",
            toolCallId: "t1",
            toolName: "calendar_event_create",
            targetSummary: "Team Sync"
        )
        XCTAssertEqual(descriptor.localizedToolTitle, "新建日历日程")
        XCTAssertEqual(descriptor.redactedTargetSummary, "Team Sync")
    }

    func testFailureClassifierPrefersStructuredFieldsOverTextFallbackAndSanitizesSnakeCase() {
        // Structured permission_denied overrides misleading "timeout" text.
        let structuredTool = UIMessagePart.Tool(
            toolCallId: "t-perm",
            toolName: "workspace_file_write",
            input: "{}",
            output: [UIMessagePart.Text(
                text: #"{"ok":false,"reason_code":"permission_denied","error":"network timeout happened"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let structuredResult = ChatTaskFailureClassifier.classify(tool: structuredTool, step: nil)
        XCTAssertEqual(structuredResult.kind, .permissionDenied)

        // Raw snake_case reason is replaced with localized copy.
        let snakeCaseTool = UIMessagePart.Tool(
            toolCallId: "t-snake",
            toolName: "mcp_call",
            input: "{}",
            output: [UIMessagePart.Text(
                text: #"{"ok":false,"error":"rate_limited"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let snakeResult = ChatTaskFailureClassifier.classify(tool: snakeCaseTool, step: nil)
        XCTAssertEqual(snakeResult.kind, .executionError)
        XCTAssertFalse(snakeResult.localizedReason.contains("rate_limited"))

        // Text fallback detects provider/network errors.
        let networkResult = ChatTaskFailureClassifier.classify(
            tool: nil,
            step: nil,
            fallbackReason: "HTTP 503 service temporarily unavailable"
        )
        XCTAssertEqual(networkResult.kind, .providerOrNetwork)

        // Unknown text falls back cleanly to executionError.
        let unknownResult = ChatTaskFailureClassifier.classify(
            tool: nil,
            step: nil,
            fallbackReason: "unexpected glitch xyz"
        )
        XCTAssertEqual(unknownResult.kind, .executionError)
    }
}
