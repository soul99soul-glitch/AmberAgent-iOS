import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatSubagentConversationLinkTests: XCTestCase {
    func testSpawnAndListResultsExposeConversationDestinations() throws {
        let child = UUID().uuidString.lowercased()
        let spawn = try tool("spawn_agent", result: ["ok": true, "child_thread_id": child, "agent_path": "/root/research"])
        XCTAssertEqual(SubagentConversationLink.links(from: spawn), [.init(id: child, title: "research")])
        let list = try tool("list_agents", result: ["ok": true, "threads": [["child_thread_id": child, "agent_path": "/root/research"]]])
        XCTAssertEqual(SubagentConversationLink.links(from: list), [.init(id: child, title: "research")])
    }

    func testOrdinaryToolsAndInvalidIdsDoNotBecomeConversationLinks() throws {
        let unrelated = try tool("mcp_call", result: ["ok": true, "child_thread_id": UUID().uuidString])
        XCTAssertTrue(SubagentConversationLink.links(from: unrelated).isEmpty)
        let invalid = try tool("spawn_agent", result: ["ok": true, "child_thread_id": "not-a-uuid"])
        XCTAssertTrue(SubagentConversationLink.links(from: invalid).isEmpty)
    }

    private func tool(_ name: String, result: [String: Any]) throws -> UIMessagePart.Tool {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return UIMessagePart.Tool(
            toolCallId: UUID().uuidString, toolName: name, input: "{}",
            output: [UIMessagePart.Text(text: text, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
    }
}
