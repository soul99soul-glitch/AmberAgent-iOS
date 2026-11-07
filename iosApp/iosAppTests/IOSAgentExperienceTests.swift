import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSAgentExperienceTests: XCTestCase {
    func testExperiencesAreGroundedDeduplicatedScopedAndExpire() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSAgentExperienceStore(directory: root)
        let source = IOSAgentTaskEvidence(sourceMessageId: "u", completionMessageId: "answer", task: "检查 alpha 主机",
                                         toolCallId: "ssh1", toolName: "terminal_execute", observation: "alpha 主机需要指定端口 2222 才能连接。")
        let candidate = IOSAgentExperienceCandidate(content: source.observation, toolCallId: source.toolCallId,
                                                   quote: source.observation, context: "alpha", expiresInDays: 1)
        let invented = IOSAgentExperienceCandidate(content: "alpha 主机需要端口 9999", toolCallId: source.toolCallId,
                                                   quote: source.observation, context: "alpha", expiresInDays: 1)
        try store.save([candidate, invented], evidence: [source], conversationId: "c", now: 100)
        try store.save([candidate], evidence: [source], conversationId: "c", now: 200)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.completionMessageId, "answer")
        XCTAssertEqual(IOSAgentExperienceStore(directory: root).records.count, 1)
        XCTAssertTrue(store.recall(task: "写一首诗", toolNames: [], now: 300).isEmpty)
        XCTAssertTrue(store.recall(task: "", toolNames: [source.toolName], now: 300).isEmpty)
        XCTAssertEqual(store.recall(task: "再检查 alpha 主机", toolNames: [], now: 300).count, 1)
        XCTAssertTrue(store.recall(task: "检查 alpha", toolNames: [], now: 200 + 86_400_000).isEmpty)
    }

    func testOnlyExecutedToolObservationsFromSelectedTaskAreOffered() throws {
        let user = UIMessage.companion.user(prompt: "检查 alpha")
        let tool = UIMessagePart.Tool(toolCallId: "ssh1", toolName: "terminal_execute", input: "alpha",
                                      output: [UIMessagePart.Text(text: "alpha 使用端口 2222", metadata: nil)],
                                      approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        let base = UIMessage.companion.assistant(prompt: "")
        let toolMessage = base.doCopy(id: base.id, role: base.role, parts: [tool], annotations: base.annotations,
                                      createdAt: base.createdAt, finishedAt: base.finishedAt,
                                      modelId: base.modelId, usage: base.usage, translation: base.translation)
        let answer = UIMessage.companion.assistant(prompt: "检查完成")
        let nextUser = UIMessage.companion.user(prompt: "无关任务")
        let messages = [user, toolMessage, answer, nextUser, toolMessage]
        let evidence = IOSAgentExperienceStore.evidence(messages: messages, sourceIds: [user.id.toHexDashString()])
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.completionMessageId, answer.id.toHexDashString())
        XCTAssertEqual(evidence.first?.toolCallId, "ssh1")
        XCTAssertFalse(try IOSAgentExperienceStore.prompt(evidence: evidence).isEmpty)
    }
}
