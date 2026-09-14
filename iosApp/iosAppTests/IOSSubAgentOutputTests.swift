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
        let snapshot = IOSSubAgentOutputSnapshot(summary: "已完成接口核对", steps: [], isFinal: true)
        await IOSSubAgentOutputArchive.archive(runId: "current", conversationId: child, snapshot: snapshot, database: db)
        let loaded = try await IOSSubAgentOutputArchive.load(runId: "current", database: db)
        XCTAssertEqual(loaded, snapshot)
        let anotherRun = try await IOSSubAgentOutputArchive.load(runId: "next", database: db)
        XCTAssertNil(anotherRun)
        let status = try await runs.snapshot(runId: "current")?.status
        XCTAssertEqual(status, .completed, "展示归档不能改变运行终态")
    }

}
