import XCTest
@testable import AmberMac

/// M2.6: read-only history search/fetch over the immutable transcript, including turns a summary folded away.
final class DesktopHistoryToolsTests: XCTestCase {
    private func transcript() -> [DesktopMessage] {
        [
            DesktopMessage(role: .user, text: "帮我修 macOS 打包；报错在 verify 目录"),
            DesktopMessage(role: .assistant, text: "先看日志：" + String(repeating: "前置说明。", count: 80)
                + "Error: PhaseScriptExecution failed，exit code 65"),
            DesktopMessage(role: .user, text: "继续"),
            DesktopMessage(role: .assistant, text: "已完成 verify 清理。", tools: [
                DesktopToolCall(id: "call-1", name: "shell_verify", input: "{\"path\":\"/tmp/verify\"}")
            ]),
        ]
    }

    func testSearchFindsFoldedTurnsAndMarksThemStale() {
        let messages = transcript()
        let covered: Set<UUID> = [messages[0].id, messages[1].id]
        let hits = DesktopHistoryTools.search(query: "verify", in: messages, covered: covered)
        XCTAssertEqual(hits.map(\.index), [0, 3], "hits keep transcript order")
        XCTAssertEqual(hits.map(\.stale), [true, false], "folded turns are reported as stale, not hidden")
        let toolHits = DesktopHistoryTools.search(query: "shell_verify", in: messages, covered: covered)
        XCTAssertEqual(toolHits.map(\.index), [3], "tool arguments are searchable too")
        XCTAssertTrue(toolHits.first?.snippet.contains("/tmp/verify") == true)
        XCTAssertTrue(DesktopHistoryTools.search(query: "   ", in: messages, covered: covered).isEmpty)
        XCTAssertNil(DesktopHistoryTools.search(query: "不存在的词", in: messages, covered: covered).first)
    }

    func testSearchBudgetCapsResultsAndSnippetLength() {
        let messages = (0..<40).map { DesktopMessage(role: .user, text: "keyword 第\($0)条" ) }
        let hits = DesktopHistoryTools.search(query: "keyword", in: messages, covered: [], limit: 99)
        XCTAssertEqual(hits.count, DesktopHistoryTools.maxResults)

        let long = [DesktopMessage(role: .assistant, text: String(repeating: "背景说明。", count: 400) + " needle 尾部")]
        let snippet = try? XCTUnwrap(DesktopHistoryTools.search(query: "needle", in: long, covered: []).first)
        XCTAssertLessThanOrEqual((snippet?.snippet.count ?? 0), DesktopHistoryTools.maxSnippetCharacters + 2)
    }

    func testFetchReturnsOriginalTextWithStaleFlagAndTruncation() throws {
        let messages = transcript()
        let folded = try DesktopHistoryTools.fetch(messages[1].id, in: messages, covered: [messages[1].id])
        XCTAssertEqual(folded["stale"] as? Bool, true)
        XCTAssertEqual(folded["role"] as? String, "assistant")
        XCTAssertTrue((folded["text"] as? String)?.contains("exit code 65") == true)

        var huge = messages
        huge[2].text = String(repeating: "长", count: DesktopHistoryTools.maxFetchCharacters + 50)
        let capped = try DesktopHistoryTools.fetch(huge[2].id, in: huge, covered: [])
        XCTAssertEqual((capped["text"] as? String)?.count, DesktopHistoryTools.maxFetchCharacters)
        XCTAssertEqual(capped["truncated"] as? Bool, true)
        XCTAssertThrowsError(try DesktopHistoryTools.fetch(UUID(), in: messages, covered: []))
    }

    func testHistoryToolsAreDeclaredReadOnly() throws {
        let names = DesktopToolRegistry.historyDeclarations.map(\.name)
        XCTAssertEqual(names, ["history_search", "history_fetch"])
        XCTAssertTrue(DesktopToolRegistry.historyDeclarations.allSatisfy { !$0.needsApproval })
        for name in names {
            XCTAssertEqual(DesktopToolRegistry.effect(for: name, arguments: "{}"), .pure)
        }
        let declarations = DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: false)
        XCTAssertTrue(Set(names).isSubset(of: Set(declarations.map(\.name))), "tools on must expose history search")
        XCTAssertFalse(DesktopToolRegistry.agentDeclarations(toolsEnabled: false, subagentsEnabled: false)
            .contains { names.contains($0.name) }, "tools off keeps them hidden")
    }

    func testSearchRedactsInlineSecretsAndCredentialStoreRejectsPlaceholders() throws {
        let secret = "sk-ant-api03-1234567890abcdefghijklmnop"
        let messages = [DesktopMessage(role: .user, text: "这是测试 key: \(secret) 请检查 verify")]
        let hits = DesktopHistoryTools.search(query: "verify", in: messages, covered: [])
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(hits[0].snippet.contains(secret))
        XCTAssertTrue(hits[0].snippet.contains(DesktopHistoryRedaction.mask))

        let creds = DesktopMemoryCredentials()
        let id = UUID()
        for placeholder in ["<redacted>", "[REDACTED]", "***", "••••", DesktopHistoryRedaction.mask] {
            XCTAssertThrowsError(try creds.save(placeholder, id: id))
        }
        try creds.save("real-secret-value", id: id)
        XCTAssertEqual(try creds.load(id: id), "real-secret-value")
    }
}
