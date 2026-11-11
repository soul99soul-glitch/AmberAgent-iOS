import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSubAgentOutputTests: XCTestCase {
    private func message(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func testProjectionUsesOnlyGeneratedPublicTextAndToolSteps() throws {
        let baseline = message(
            role: .assistant,
            parts: [UIMessagePart.Text(text: "历史 fork 结论", metadata: nil)]
        )
        let tool = UIMessagePart.Tool(
            toolCallId: "tool-current",
            toolName: "search_web",
            input: #"{"query":"secret-raw-parameter"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"results":[{"title":"公开来源"}]}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let generated = message(
            role: .assistant,
            parts: [
                UIMessagePart.Reasoning(
                    reasoning: "SECRET_REASONING_SHOULD_NOT_APPEAR",
                    createdAt: KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0),
                    finishedAt: nil,
                    metadata: nil
                ),
                tool,
                UIMessagePart.Text(text: "本次公开结论", metadata: nil)
            ]
        )

        let suffix = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: [baseline, generated],
            displayMessages: [baseline]
        )
        let output = try XCTUnwrap(
            IOSSubAgentOutputProjection.snapshot(messages: suffix, isFinal: true)
        )
        XCTAssertEqual(output.summary, "本次公开结论")
        XCTAssertEqual(output.steps.count, 1)
        XCTAssertEqual(output.steps.first?.status, .completed)
        XCTAssertFalse(output.summary.contains("SECRET_REASONING"))
        let encoded = String(data: try JSONEncoder().encode(output), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("secret-raw-parameter"))
        XCTAssertFalse(encoded.contains("SECRET_REASONING"))
        XCTAssertFalse(encoded.contains("历史 fork"))
    }

    func testGeneratedSuffixUsesDisplayedBaselineAfterResumeCompression() {
        let display = [
            message(role: .user, parts: [UIMessagePart.Text(text: "历史输入", metadata: nil)]),
            message(role: .assistant, parts: [UIMessagePart.Text(text: "历史输出", metadata: nil)]),
            message(role: .user, parts: [UIMessagePart.Text(text: "本轮输入", metadata: nil)])
        ]
        // A durable Responses resume may upload a shorter compacted baseline,
        // but its live accumulator still returns display + new response.
        let final = display + [
            message(role: .assistant, parts: [UIMessagePart.Text(text: "本轮结果", metadata: nil)])
        ]
        let generated = IOSSubAgentOutputProjection.generatedMessages(
            finalMessages: final,
            displayMessages: display
        )
        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated.first?.singleNonEmptyTextPart, "本轮结果")
    }

    func testReportSummaryAcceptsOnlyCompletePublicFields() {
        let report = #"{"summary":"最终结论","findings":["发现一","发现二"],"reasoning":"SECRET_REASONING"}"#
        let summary = IOSSubAgentOutputProjection.summaryFromStoredResult(report)
        XCTAssertEqual(summary, "最终结论\n发现一\n发现二")
        XCTAssertFalse(summary?.contains("SECRET_REASONING") == true)

        XCTAssertNil(
            IOSSubAgentOutputProjection.summaryFromStoredResult(#"{"summary":"截断"#)
        )
        XCTAssertNil(IOSSubAgentOutputProjection.summaryFromStoredResult(#"{"reasoning":"PRIVATE"}"#))
    }

    func testJSONLookingMarkdownLinksRemainReadableAtEveryDisplayBoundary() throws {
        let markdown = #"[{"run_ended":true}](https://example.com/report)"#
        XCTAssertFalse(IOSSubAgentOutputProjection.isKnownSubAgentResultEnvelope(markdown))
        XCTAssertEqual(IOSSubAgentOutputProjection.extractUserFacingResult(from: markdown), markdown)
        XCTAssertEqual(IOSSubAgentOutputProjection.sanitizeAssistantDisplayTextIfEnvelope(markdown), markdown)
        let mailbox = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/test/reviewer", type: "FINAL_ANSWER", payload: markdown
        )
        let part = try XCTUnwrap(mailbox.parts.first as? UIMessagePart.Text)
        XCTAssertEqual(IOSSubAgentOutputProjection.userFacingMailboxDisplayText(part: part), markdown)
        XCTAssertTrue(IOSConversationExporter.shareText(for: mailbox).contains(markdown))
        let assistant = message(role: .assistant, parts: [UIMessagePart.Text(text: markdown, metadata: nil)])
        XCTAssertEqual(IOSSubAgentOutputProjection.unpreparedDisplayTexts(in: assistant)[0], markdown)
        for otherLink in [
            #"[[nested]](https://example.com/path_(one))"#,
            #"[{"run_ended":true}][report]"#,
            #"[{"run_ended":true}](https://example.com/report)"# + "\n\n[Amber host: child run ended]\n{\"run_ended\":true}"
        ] {
            let expected = otherLink.components(separatedBy: "\n\n")[0]
            XCTAssertEqual(IOSSubAgentOutputProjection.extractUserFacingResult(from: otherLink), expected)
        }
        XCTAssertNil(IOSSubAgentOutputProjection.extractUserFacingResult(from: #"[{"run_ended":true}]"#))
        XCTAssertNil(IOSSubAgentOutputProjection.extractUserFacingResult(from: #"[{"run_ended":true"#))
    }

    func testActivityGeneratedSnapshotsSanitizeBeforeBoundingAndSelection() throws {
        let raw = "Readable result\n\n[Amber host: child run ended]\n{\"run_ended\":true,\"session_read\":{\"offset\":0}}"
        let output = try XCTUnwrap(IOSSubAgentOutputProjection.snapshot(
            messages: [message(role: .assistant, parts: [UIMessagePart.Text(text: raw, metadata: nil)])],
            isFinal: false
        ))
        XCTAssertEqual(output.summary, "Readable result", "活动详情与其文字选择复制必须使用净化正文")
        let unknown = IOSSubAgentOutputProjection.snapshot(
            messages: [message(role: .assistant, parts: [UIMessagePart.Text(text: #"{"run_ended":true}"#, metadata: nil)])],
            isFinal: false
        )
        XCTAssertNil(unknown)
    }

    func testLiveOutputRequiresMatchingExecutionIdentity() async throws {
        let suiteName = "subagent-output-live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let task = tasks.startTask(
            kind: .subAgent,
            title: "live",
            objective: "live output",
            metadata: [
                "execution_id": "execution-current",
                "tool_call_id": "call-\(UUID().uuidString)"
            ]
        )
        let activity = try XCTUnwrap(IOSSubAgentActivityStore.activity(task))
        let callId = task.metadata["tool_call_id"]!

        let stale = SubAgentLiveModel(executionId: "execution-old")
        stale.replacePublicOutput(IOSSubAgentOutputSnapshot(
            summary: "旧执行",
            steps: [],
            isFinal: false
        ))
        SubAgentLiveRegistry.shared.register(toolCallId: callId, stale)
        let staleOutput = try await IOSSubAgentOutputLoader.load(activity: activity, task: task)
        XCTAssertNil(staleOutput)

        let current = SubAgentLiveModel(executionId: "execution-current")
        current.replacePublicOutput(IOSSubAgentOutputSnapshot(
            summary: "本次执行",
            steps: [],
            isFinal: false
        ))
        SubAgentLiveRegistry.shared.register(toolCallId: callId, current)
        let currentOutput = try await IOSSubAgentOutputLoader.load(activity: activity, task: task)
        let loaded = try XCTUnwrap(currentOutput)
        XCTAssertEqual(loaded.summary, "本次执行")
    }

    func testActivityLoaderSanitizesLiveAndLegacyTerminalPublicSnapshots() async throws {
        let suiteName = "subagent-output-sanitized-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let executionId = UUID().uuidString
        let callId = UUID().uuidString
        let task = tasks.startTask(kind: .subAgent, title: "test", objective: "test", metadata: [
            "execution_id": executionId, "tool_call_id": callId
        ])
        let raw = "Readable result\n\n[Amber host: child run ended]\n{\"run_ended\":true,\"session_read\":{\"offset\":0}}"
        let live = SubAgentLiveModel(executionId: executionId)
        live.replacePublicOutput(IOSSubAgentOutputSnapshot(summary: raw, steps: [], isFinal: false))
        SubAgentLiveRegistry.shared.register(toolCallId: callId, live)
        let activity = try XCTUnwrap(IOSSubAgentActivityStore.activity(task))
        let loadedLive = try await IOSSubAgentOutputLoader.load(activity: activity, task: task)
        XCTAssertEqual(loadedLive?.summary, "Readable result")
        let terminal = IOSSubAgentOutputSnapshot(summary: raw, steps: [], isFinal: true)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(terminal), encoding: .utf8))
        let finished = try XCTUnwrap(tasks.updateTask(id: task.id, status: .completed, metadata: ["public_output": encoded]))
        let finishedActivity = try XCTUnwrap(IOSSubAgentActivityStore.activity(finished))
        let loadedFinal = try await IOSSubAgentOutputLoader.load(activity: finishedActivity, task: finished)
        XCTAssertEqual(loadedFinal?.summary, "Readable result")
        XCTAssertEqual(loadedFinal?.isFinal, true)
        XCTAssertTrue(finished.metadata["public_output"]?.contains("run_ended") == true,
                      "读取展示净化不能重写原有 task 元数据")
        let fallback = IOSSubAgentOutputProjection.snapshot(task: task, liveText: raw)
        XCTAssertEqual(fallback?.summary, "Readable result")
    }

    func testTerminalPublicSnapshotSurvivesOwnerReleaseAndStaysRunBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("output.db").path)
        defer {
            db.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let child = KotlinUuid.companion.random()
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: child.toHexDashString(), parentThreadId: UUID().uuidString,
            agentPath: "/root/check", nickname: nil, roleAssistantId: nil,
            forkTurns: "all", status: "Open", createdAt: 100
        ))
        let runs = IOSDurableRunStore(dao: db.agentRuntimeDao())
        let started = try await runs.startChatRun(runId: "current", startedAt: 100, inputDigest: "test", conversationId: child.toHexDashString())
        XCTAssertTrue(started)
        let finished = try await runs.transition(runId: "current", expected: .running, to: .completed, at: 200)
        XCTAssertTrue(finished)
        let raw = "已完成接口核对\n\n[Amber host: child run ended]\n{\"run_ended\":true}"
        let snapshot = IOSSubAgentOutputSnapshot(summary: raw, steps: [], isFinal: true)
        await IOSSubAgentOutputArchive.archive(runId: "current", conversationId: child, snapshot: snapshot, database: db)
        let loaded = try await IOSSubAgentOutputArchive.load(runId: "current", database: db)
        XCTAssertEqual(loaded, IOSSubAgentOutputSnapshot(summary: "已完成接口核对", steps: [], isFinal: true))
        // Old persisted public snapshots predate display normalization.
        let legacyPayload = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        let legacy = AgentRunEvent(
            eventId: "legacy-public-output", type: IOSSubAgentOutputProjection.eventType,
            payloadType: IOSSubAgentOutputProjection.eventType, payload: legacyPayload,
            payloadSchemaVersion: 1, isFinal: false, ts: 300,
            turnId: nil, stepId: nil, toolCallId: nil
        )
        let events = RoomAgentEventStore(dao: db.agentRuntimeDao())
        let inserted = await withCheckedContinuation { continuation in
            events.appendRunEvent(runId: "current", event: legacy) { value, error in
                continuation.resume(returning: error == nil && (value?.boolValue ?? false))
            }
        }
        XCTAssertTrue(inserted)
        let legacyLoaded = try await IOSSubAgentOutputArchive.load(runId: "current", database: db)
        XCTAssertEqual(legacyLoaded?.summary, "已完成接口核对")
        let anotherRun = try await IOSSubAgentOutputArchive.load(runId: "next", database: db)
        XCTAssertNil(anotherRun)
        let status = try await runs.snapshot(runId: "current")?.status
        XCTAssertEqual(status, .completed, "展示归档不能改变运行终态")
    }

}
