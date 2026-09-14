import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P1 batch 2 tests: workspace file_edit/list/search/move + MCP auto-reconnect.
@MainActor
final class IOSP1Batch2Tests: XCTestCase {

    private func makeStore() throws -> (IOSWorkspaceStore, URL) {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSP1Batch2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return (IOSWorkspaceStore(baseDirectory: baseDirectory), baseDirectory)
    }

    // MARK: - Workspace tools

    func testFileEditReplacesSubstring() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Seed a file via workspace_file_write.
        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: "{\"path\":\"notes.md\",\"content\":\"hello world\",\"overwrite\":true}"
        )
        // Edit: replace "world" with "ios".
        let result = await store.executeTool(
            toolName: "workspace_file_edit",
            input: "{\"path\":\"notes.md\",\"find\":\"world\",\"replace\":\"ios\"}"
        )
        let payload = try XCTUnwrap(Self.jsonDict(result))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["changed"] as? Bool, true)
        XCTAssertEqual(payload["replacements"] as? Int, 1)
        XCTAssertEqual(payload["diff_truncated"] as? Bool, false)
        let diff = try XCTUnwrap(payload["diff_preview"] as? String)
        XCTAssertTrue(diff.contains("-hello world\n"))
        XCTAssertTrue(diff.contains("+hello ios\n"))
        // Verify the content changed by reading it back.
        let read = await store.executeTool(toolName: "workspace_file_read", input: "{\"path\":\"notes.md\"}")
        let readPayload = try XCTUnwrap(Self.jsonDict(read))
        XCTAssertEqual(readPayload["text"] as? String, "hello ios")
    }

    func testFileEditDisambiguatesContextAndRequiresExplicitGlobalReplacement() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = "上传:\r\n  timeout=30\r\n搜索:\r\n  timeout=30\r\n"
        let writeInput = try JSONSerialization.data(withJSONObject: ["path": "config.txt", "content": original])
        _ = await store.executeTool(toolName: "workspace_file_write", input: String(decoding: writeInput, as: UTF8.self))
        let record = try XCTUnwrap(store.fileRecord(idOrPath: "config.txt"))
        let url = store.fileURL(for: record)

        let ambiguous = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"config.txt","find":"timeout=30","replace":"timeout=60"}"#
        )
        let rejected = try XCTUnwrap(Self.jsonDict(ambiguous))
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["match_count"] as? Int, 2)
        XCTAssertEqual(rejected["matched_lines"] as? [Int], [2, 4])
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))

        let precise = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"config.txt","find":"上传:\r\n  timeout=30","replace":"上传:\r\n  timeout=60"}"#
        )
        XCTAssertEqual(Self.jsonDict(precise)?["replacements"] as? Int, 1)
        let expected = "上传:\r\n  timeout=60\r\n搜索:\r\n  timeout=30\r\n"
        XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8), "unrelated text and CRLF bytes must survive")

        let global = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"config.txt","find":"timeout","replace":"deadline","replace_all":true}"#
        )
        XCTAssertEqual(Self.jsonDict(global)?["replacements"] as? Int, 2)
        XCTAssertEqual(try Data(contentsOf: url), Data(expected.replacingOccurrences(of: "timeout", with: "deadline").utf8))

        // Distant edits must not produce a misleading diff by comparing two
        // independently clipped windows after a line-count-changing replacement.
        let spread = "target\n" + String(repeating: "unchanged\n", count: 150) + "target\n"
        let spreadInput = try JSONSerialization.data(withJSONObject: [
            "path": "spread.txt", "content": spread
        ])
        _ = await store.executeTool(toolName: "workspace_file_write", input: String(decoding: spreadInput, as: UTF8.self))
        let largeEdit = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"spread.txt","find":"target","replace":"first\nsecond","replace_all":true}"#
        )
        XCTAssertEqual(Self.jsonDict(largeEdit)?["ok"] as? Bool, true)
        XCTAssertEqual(Self.jsonDict(largeEdit)?["replacements"] as? Int, 2)
        XCTAssertEqual(Self.jsonDict(largeEdit)?["diff_truncated"] as? Bool, true)
    }

    func testFileEditDoesNotWriteOnMissingMatchOrUnreadableOriginal() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await store.executeTool(toolName: "workspace_file_write", input: #"{"path":"notes.md","content":"hello world"}"#)
        let record = try XCTUnwrap(store.fileRecord(idOrPath: "notes.md"))
        let url = store.fileURL(for: record)

        let missing = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"notes.md","find":"missing","replace":"replacement"}"#
        )
        XCTAssertEqual(Self.jsonDict(missing)?["ok"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world")

        let unchanged = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"notes.md","find":"hello","replace":"hello"}"#
        )
        XCTAssertEqual(Self.jsonDict(unchanged)?["ok"] as? Bool, true)
        XCTAssertEqual(Self.jsonDict(unchanged)?["changed"] as? Bool, false)

        // The saved preview still contains "hello world", but the original is no
        // longer UTF-8. Editing must not overwrite it with that cached preview.
        let binary = Data([0xFF, 0x00, 0x80, 0xFE])
        try binary.write(to: url)
        let unreadable = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"notes.md","find":"world","replace":"lost bytes"}"#
        )
        XCTAssertEqual(Self.jsonDict(unreadable)?["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: url), binary)
    }

    func testFileReadLineRangeReadsBeyondTruncatedPreview() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suffix = String(repeating: "x", count: 20)
        let content = (1...4_000).map { "line-\($0): \(suffix)" }.joined(separator: "\n")
        let writeJSON = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "path": "long.md",
                "content": content,
                "overwrite": true
            ]),
            encoding: .utf8
        ))
        _ = await store.executeTool(toolName: "workspace_file_write", input: writeJSON)

        let preview = await store.executeTool(toolName: "workspace_file_read", input: "{\"path\":\"long.md\"}")
        let previewPayload = try XCTUnwrap(Self.jsonDict(preview))
        XCTAssertFalse((previewPayload["text"] as? String ?? "").contains("line-3500:"))

        let rangeJSON = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "path": "long.md",
                "start_line": 3_500,
                "end_line": 3_501,
                "max_chars": 200
            ]),
            encoding: .utf8
        ))
        let result = await store.executeTool(toolName: "workspace_file_read", input: rangeJSON)
        let payload = try XCTUnwrap(Self.jsonDict(result))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["start_line"] as? Int, 3_500)
        XCTAssertEqual(payload["end_line"] as? Int, 3_501)
        XCTAssertEqual(payload["total_lines"] as? Int, 4_000)
        XCTAssertEqual(
            payload["text"] as? String,
            "line-3500: \(suffix)\nline-3501: \(suffix)\n"
        )
        XCTAssertEqual(payload["truncated"] as? Bool, false)

        let truncatedJSON = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "path": "long.md",
                "start_line": 3_500,
                "end_line": 3_503,
                "max_chars": ("line-3500: \(suffix)\n").count
            ]),
            encoding: .utf8
        ))
        let truncatedResult = await store.executeTool(toolName: "workspace_file_read", input: truncatedJSON)
        let truncatedPayload = try XCTUnwrap(Self.jsonDict(truncatedResult))
        XCTAssertEqual(truncatedPayload["ok"] as? Bool, true)
        XCTAssertEqual(truncatedPayload["start_line"] as? Int, 3_500)
        XCTAssertEqual(truncatedPayload["end_line"] as? Int, 3_500)
        XCTAssertEqual(truncatedPayload["total_lines"] as? Int, 4_000)
        XCTAssertEqual(truncatedPayload["truncated"] as? Bool, true)
    }

    func testFileListReturnsAllFiles() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await store.executeTool(toolName: "workspace_file_write", input: "{\"path\":\"a.md\",\"content\":\"alpha\",\"overwrite\":true}")
        _ = await store.executeTool(toolName: "workspace_file_write", input: "{\"path\":\"b.md\",\"content\":\"beta\",\"overwrite\":true}")

        let result = await store.executeTool(toolName: "workspace_file_list", input: "{}")
        let payload = try XCTUnwrap(Self.jsonDict(result))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["count"] as? Int, 2)
        let files = try XCTUnwrap(payload["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 2)
    }

    func testFileSearchFindsMatchingContent() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await store.executeTool(toolName: "workspace_file_write", input: "{\"path\":\"doc.md\",\"content\":\"The quick brown fox\",\"overwrite\":true}")

        let result = await store.executeTool(toolName: "workspace_file_search", input: "{\"query\":\"brown\"}")
        let payload = try XCTUnwrap(Self.jsonDict(result))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["matches"] as? Int, 1)
        let hits = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertTrue((hits.first?["snippet"] as? String ?? "").contains("brown"))
    }

    func testFileMoveRelocatesFile() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await store.executeTool(toolName: "workspace_file_write", input: "{\"path\":\"old.md\",\"content\":\"move me\",\"overwrite\":true}")

        let result = await store.executeTool(toolName: "workspace_file_move", input: "{\"path\":\"old.md\",\"destination_path\":\"renamed.md\"}")
        let payload = try XCTUnwrap(Self.jsonDict(result))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["path"] as? String, "/workspace/renamed.md")
        // The old path should no longer resolve.
        let oldRead = await store.executeTool(toolName: "workspace_file_read", input: "{\"path\":\"old.md\"}")
        let oldPayload = try XCTUnwrap(Self.jsonDict(oldRead))
        XCTAssertEqual(oldPayload["ok"] as? Bool, false)
    }

    // MARK: - MCP auto-reconnect

    /// A scripted MCP client that fails the first connect then succeeds.
    final class FlakyMcpClient: IOSMcpClienting, @unchecked Sendable {
        var connectShouldFail = true
        private(set) var connectAttempts = 0
        func connect(config: IOSMcpServerConfig) async throws -> Bool {
            connectAttempts += 1
            if connectShouldFail {
                throw IOSMcpClientError.invalidResponse
            }
            return true
        }
        func listTools() async throws -> [IOSMcpTool] { [] }
        func callTool(name: String, arguments: [String: Any]) async throws -> String { "" }
        func disconnect() {}
    }

    func testMcpReconnectRecoversFailedServer() async throws {
        let client = FlakyMcpClient()
        let server = IOSMcpServerConfig.sse(name: "test-server", url: "https://example.test/sse", enabled: true)
        let manager = IOSMcpManager(
            serverProvider: { [server] },
            isEnabled: { true },
            clientFactory: { _ in client }
        )
        await manager.syncAll()
        // Initial connect fails → error status.
        if case .error = manager.statusByServer["test-server"] {
            // expected
        } else {
            XCTFail("expected .error status after failed connect, got \(String(describing: manager.statusByServer["test-server"]))")
        }
        XCTAssertEqual(client.connectAttempts, 1)

        // Simulate backoff elapsing, make connects succeed, then reconnect.
        client.connectShouldFail = false
        manager.clearReconnectBackoffForTesting(serverName: "test-server")
        let retried = await manager.reconnectFailedServers()
        XCTAssertTrue(retried.contains("test-server"))
        XCTAssertEqual(manager.statusByServer["test-server"], .connected)
    }

    private static func jsonDict(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Clears the reconnect backoff window so a test can retry immediately.
    private static func clearReconnectBackoffForTesting(_ manager: IOSMcpManager, serverName: String) {
        manager.clearReconnectBackoffForTesting(serverName: serverName)
    }
}
