import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatForegroundTerminalBoundaryTests: IOSChatKernelRunHostTestCase {
    func testCompletedHostReportsItsFrozenBaselineAlongsideFullTranscript() async {
        let baseline = [
            F.userMessage("上一轮任务"),
            F.assistantText("上一轮报告"),
            F.userMessage("本轮任务"),
        ]
        let harness = makeHarness(seedMessages: baseline)
        var terminal: TerminalSnapshot?
        harness.bindings.onRunTerminal = { conversationID, runID, status, messages, displayBaseline in
            terminal = TerminalSnapshot(
                conversationID: conversationID,
                runID: runID,
                status: status,
                messages: messages,
                displayBaseline: displayBaseline
            )
        }
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: [textRound("本轮新报告")]))

        start(host, harness: harness)
        let reported = await waitForCondition { terminal != nil }

        XCTAssertTrue(reported)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(terminal?.conversationID, harness.conversationId)
        XCTAssertEqual(terminal?.runID, harness.capturedRunId)
        XCTAssertEqual(terminal?.status, .completed)
        XCTAssertEqual(terminal?.displayBaseline.map { $0.id.toHexDashString() }, baseline.map { $0.id.toHexDashString() })
        XCTAssertEqual(terminal?.messages.last?.toText(), "本轮新报告")
        XCTAssertTrue(terminal?.messages.contains { $0.toText() == "上一轮报告" } == true)
        if let terminal {
            XCTAssertEqual(IOSSubAgentOutputProjection.generatedMessages(
                finalMessages: terminal.messages,
                displayMessages: terminal.displayBaseline
            ).map { $0.toText() }, ["本轮新报告"])
        }
    }

    func testCancelledHostBeforeOutputKeepsHistoryOutsideCurrentRunBoundary() async {
        let baseline = [F.assistantText("旧报告不能作为取消结果"), F.userMessage("尚未输出的新任务")]
        let harness = makeHarness(seedMessages: baseline)
        var terminal: TerminalSnapshot?
        harness.bindings.onRunTerminal = { conversationID, runID, status, messages, displayBaseline in
            terminal = TerminalSnapshot(
                conversationID: conversationID,
                runID: runID,
                status: status,
                messages: messages,
                displayBaseline: displayBaseline
            )
        }
        let provider = HostBlockingProvider()
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)

        host.cancel()
        let reported = await waitForCondition { terminal != nil }

        XCTAssertTrue(reported)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(terminal?.status, .cancelled)
        XCTAssertEqual(terminal?.displayBaseline.map { $0.id.toHexDashString() }, baseline.map { $0.id.toHexDashString() })
        XCTAssertTrue(terminal?.messages.contains { $0.toText() == "旧报告不能作为取消结果" } == true)
        if let terminal {
            let generated = IOSSubAgentOutputProjection.generatedMessages(
                finalMessages: terminal.messages,
                displayMessages: terminal.displayBaseline
            )
            XCTAssertTrue(generated.allSatisfy { $0.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    private struct TerminalSnapshot {
        let conversationID: KotlinUuid?
        let runID: String
        let status: AgentRunStatus
        let messages: [UIMessage]
        let displayBaseline: [UIMessage]
    }
}
