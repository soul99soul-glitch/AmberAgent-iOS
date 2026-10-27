import Darwin
import Foundation
import XCTest
@testable import AmberMac

@MainActor final class DesktopMCPTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "amber.mcp.tests.\(UUID().uuidString)")! }
    private func configuration() -> DesktopMCPServer {
        var server = DesktopMCPServer()
        server.name = "Fixture"
        server.url = "https://mcp.example.com/mcp"
        return server
    }
    /// /usr/bin/python3 is an xcrun shim that cannot resolve the toolchain inside the App Sandbox;
    /// use the interpreter shipped next to the XCTest framework that is running this test.
    private var python: String {
        let path = Bundle(for: XCTestCase.self).bundleURL.path
        // XCTest may load from Contents/Developer/... or Contents/SharedFrameworks/...
        guard let range = path.range(of: ".app/Contents/") else { return "/usr/bin/python3" }
        let candidate = String(path[..<range.upperBound]) + "Developer/usr/bin/python3"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/usr/bin/python3"
    }
    private func arguments(_ id: UUID, name: String = "echo", extra: [String: Any] = [:]) throws -> String {
        let object: [String: Any] = ["server_id": id.uuidString, "name": name, "arguments": extra]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testCredentialsStayInIndependentVaultAndToolTogglesSurviveDiscovery() throws {
        let defaults = defaults(), vault = DesktopMemoryCredentials()
        let store = DesktopMCPStore(defaults: defaults, credentials: vault)
        var server = configuration()
        server.headers = ["Authorization": "Bearer mcp-secret"]
        server.environment = ["SERVER_SECRET": "stdio-secret"]
        try store.upsert(server)
        try store.mergeTools(serverID: server.id, discovered: [IOSMcpTool(name: "echo", description: "first", inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)])
        try store.setToolEnabled(serverID: server.id, toolName: "echo", enabled: false)
        try store.mergeTools(serverID: server.id, discovered: [IOSMcpTool(name: "echo", description: "updated", inputSchema: #"{"type":"object","properties":{}}"#, readOnlyHint: true)])
        let restored = DesktopMCPStore(defaults: defaults, credentials: vault)
        let actual = try restored.runtimeServer(id: server.id)
        XCTAssertEqual(actual.headers, server.headers)
        XCTAssertEqual(actual.environment, server.environment)
        XCTAssertEqual(actual.tools.single?.description, "updated")
        XCTAssertEqual(actual.tools.single?.enabled, false)
        XCTAssertEqual(actual.tools.single?.readOnlyHint, true)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "app.amber.macos.mcpServers")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("mcp-secret"))
        XCTAssertFalse(persisted.contains("stdio-secret"))
        try restored.remove(id: server.id)
        XCTAssertEqual(try vault.load(id: server.id), "")
        XCTAssertTrue(restored.servers.isEmpty)
    }

    func testImportValidatesWholeBatchBeforePersistingAndRestoresStdioArguments() throws {
        let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
        XCTAssertThrowsError(try store.importJSON(#"{"mcpServers":{"good":{"url":"https://example.com/mcp"},"bad":{"command":"python3","args":"not-an-array"}}}"#))
        XCTAssertTrue(store.servers.isEmpty)
        try store.importJSON(#"{"mcpServers":{"stdio":{"command":"python3","args":["server.py"],"env":{"KEY":"value"}},"events":{"type":"sse","url":"https://example.com/sse"}}}"#)
        let stdio = try XCTUnwrap(store.servers.first { $0.transport == .stdio })
        XCTAssertEqual(stdio.command, "python3")
        XCTAssertEqual(stdio.arguments, ["server.py"])
        XCTAssertEqual(stdio.environment, ["KEY": "value"])
        XCTAssertEqual(store.servers.first { $0.name == "events" }?.transport, .sse)
        XCTAssertThrowsError(try store.importJSON(#"{"mcpServers":{"stdio":{"command":"other"}}}"#))
        XCTAssertEqual(store.servers.count, 2)
    }

    func testUnreadablePersistedConfigurationCannotBeOverwritten() throws {
        let defaults = defaults()
        let original = Data("{broken MCP config".utf8)
        defaults.set(original, forKey: "app.amber.macos.mcpServers")
        let store = DesktopMCPStore(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.upsert(configuration()))
        XCTAssertThrowsError(try store.importJSON(#"{"mcpServers":{"new":{"url":"https://example.com/mcp"}}}"#))
        XCTAssertEqual(defaults.data(forKey: "app.amber.macos.mcpServers"), original)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testMissingCredentialsCanBeRepairedWithoutKeepingStaleLoadError() throws {
        let defaults = defaults(), vault = DesktopMemoryCredentials()
        var server = configuration()
        server.headers = ["Authorization": "old"]
        try DesktopMCPStore(defaults: defaults, credentials: vault).upsert(server)
        try vault.delete(id: server.id)
        let restored = DesktopMCPStore(defaults: defaults, credentials: vault)
        XCTAssertNotNil(restored.loadError)
        XCTAssertThrowsError(try restored.runtimeServer(id: server.id))
        server.headers = ["Authorization": "repaired"]
        try restored.upsert(server)
        XCTAssertNil(restored.loadError)
        XCTAssertEqual(try restored.runtimeServer(id: server.id).headers, server.headers)
        XCTAssertEqual(try DesktopMCPStore(defaults: defaults, credentials: vault).runtimeServer(id: server.id).headers, server.headers)
    }

    func testRealSharedHTTPClientInitializesPaginatesUsesSessionAndCallsOnce() async throws {
        let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
        var server = configuration()
        server.headers = ["Authorization": "Bearer fixture"]
        try store.upsert(server)
        let transport = MCPFixtureTransport()
        let manager = DesktopMCPManager(store: store, transportFactory: { _ in transport })
        try await manager.connect(id: server.id)
        XCTAssertEqual(transport.methods, ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        XCTAssertEqual(transport.requests.dropFirst().last?.headers["Mcp-Session-Id"], "session-fixture")
        XCTAssertEqual(transport.requests.last?.headers["MCP-Protocol-Version"], "2025-11-25")
        XCTAssertEqual(store.servers.first?.tools.map(\.name), ["echo", "write"])
        XCTAssertTrue(store.servers.first?.tools.first?.inputSchema?.contains("text") == true)
        let output = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id, extra: ["text": "actual input"]))
        XCTAssertTrue(output.contains("actual input"))
        XCTAssertEqual(transport.methods.filter { $0 == "tools/call" }.count, 1)
        XCTAssertEqual(manager.statusByServer[server.id], .connected)
        try store.setToolEnabled(serverID: server.id, toolName: "echo", enabled: false)
        do {
            _ = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id))
            XCTFail("Disabled tools must not be dispatched")
        } catch { XCTAssertFalse(error is DesktopMCPOutcomeUnknown) }
        XCTAssertEqual(transport.methods.filter { $0 == "tools/call" }.count, 1)
    }

    func testOnlyUnconfirmedDispatchedCallsBecomeUnknownWithoutReplay() async throws {
        for failure in [MCPFixtureTransport.Failure.lostResponse, .rpcRejection] {
            let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
            let server = configuration()
            try store.upsert(server)
            let transport = MCPFixtureTransport()
            transport.failure = failure
            let manager = DesktopMCPManager(store: store, transportFactory: { _ in transport })
            try await manager.connect(id: server.id)
            do {
                _ = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id))
                XCTFail("Fixture must fail")
            } catch {
                XCTAssertEqual(error is DesktopMCPOutcomeUnknown, failure == .lostResponse)
                XCTAssertFalse(error.localizedDescription.contains("secret-from-server"))
            }
            XCTAssertEqual(transport.methods.filter { $0 == "tools/call" }.count, 1)
        }
    }

    func testOriginalSSEParserMatchesResponseIDAndRejectsCrossOriginEndpoint() throws {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n\n"
        let result = URLSessionMcpHTTPTransport.firstServerSentEventJSON(from: Data(body.utf8), matchingRequestID: 7)
        XCTAssertEqual(result?["id"] as? Int, 7)
        XCTAssertThrowsError(try IOSMcpLegacyEndpointPolicy.validatedEndpoint("https://other.example.com/messages", relativeTo: "https://example.com/sse"))
        XCTAssertEqual(try IOSMcpLegacyEndpointPolicy.validatedEndpoint("/messages", relativeTo: "https://example.com/sse").absoluteString, "https://example.com/messages")
    }

    func testActualStdioProcessHandshakeCallsAndCancelTermination() async throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(bundle.url(forResource: "mcp_stdio_fixture", withExtension: "py"))
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
        var server = configuration()
        server.transport = .stdio
        server.command = python
        server.arguments = ["-u", fixture.path]
        server.environment = ["AMBER_MCP_FIXTURE_VALUE": "environment-present", "AMBER_MCP_FIXTURE_MARKER": marker.path,
            "AMBER_MCP_FIXTURE_FRAGMENTS": "1"]
        try store.upsert(server)
        let manager = DesktopMCPManager(store: store)
        defer { manager.disconnect(id: server.id) }
        try await manager.connect(id: server.id)
        let output = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id, extra: ["text": "real pipe"]))
        XCTAssertTrue(output.contains("real pipe"))
        XCTAssertTrue(output.contains("environment-present"))
        let fragmentedText = String(repeating: "中文与换行\n", count: 100_000)
        let fragmented = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id, extra: ["text": fragmentedText]))
        let fragmentedResult = try JSONSerialization.jsonObject(with: Data(fragmented.utf8)) as! [String: Any]
        XCTAssertEqual((fragmentedResult["content"] as? [[String: Any]])?.first?["text"] as? String, fragmentedText + " environment-present")
        let outer = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let pid = try XCTUnwrap((outer["structuredContent"] as? [String: Any])?["pid"] as? Int32)
        let waiting = Task { try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id, name: "wait")) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled dispatched tool must not succeed") }
        catch { XCTAssertTrue(error is DesktopMCPOutcomeUnknown) }
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "The owned fixture process must terminate at cancel")
    }

    func testExitedStdioServerCannotRestartWithoutANewInitializeHandshake() async throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(bundle.url(forResource: "mcp_stdio_fixture", withExtension: "py"))
        let starts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: starts) }
        var server = configuration()
        server.transport = .stdio
        server.command = python
        server.arguments = ["-u", fixture.path]
        server.environment = ["AMBER_MCP_FIXTURE_STARTS": starts.path]
        let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
        try store.upsert(server)
        let manager = DesktopMCPManager(store: store)
        defer { manager.disconnect(id: server.id) }
        try await manager.connect(id: server.id)
        _ = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id, name: "exit"))
        let firstPID = try XCTUnwrap(Int32(String(contentsOf: starts, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<200 {
            if Darwin.kill(firstPID, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            _ = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id))
            XCTFail("A disconnected process cannot accept a tool call before initialize")
        } catch { XCTAssertFalse(error is DesktopMCPOutcomeUnknown) }
        XCTAssertEqual(try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count, 1)
        try await manager.connect(id: server.id)
        _ = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id))
        XCTAssertEqual(try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testCancelledInitializeCannotLaunchStdioProcess() async throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(bundle.url(forResource: "mcp_stdio_fixture", withExtension: "py"))
        let starts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: starts) }
        var server = configuration()
        server.transport = .stdio
        server.command = python
        server.arguments = ["-u", fixture.path]
        server.environment = ["AMBER_MCP_FIXTURE_STARTS": starts.path]
        let transport = DesktopMCPStdioTransport(configuration: server)
        let request = Task {
            try await transport.sendJSONRPC(["jsonrpc": "2.0", "id": 1, "method": "initialize"], to: server.clientConfiguration)
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled initialization must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: starts.path))
        transport.disconnect(config: server.clientConfiguration)
        await transport.terminationTask?.value
    }

    func testShutdownReapsAnOwnedProcessGroupThatIgnoresSIGTERM() async throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(bundle.url(forResource: "mcp_stdio_fixture", withExtension: "py"))
        var server = configuration()
        server.transport = .stdio
        server.command = python
        server.arguments = ["-u", fixture.path]
        server.environment = ["AMBER_MCP_FIXTURE_IGNORE_TERM": "1"]
        let store = DesktopMCPStore(defaults: defaults(), credentials: DesktopMemoryCredentials())
        try store.upsert(server)
        let manager = DesktopMCPManager(store: store)
        try await manager.connect(id: server.id)
        let output = try await manager.perform(name: "mcp_call_tool", argumentsJSON: arguments(server.id))
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let ids = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let pid = try XCTUnwrap(ids["pid"] as? Int32), childPID = try XCTUnwrap(ids["childPID"] as? Int32)
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertEqual(getpgid(childPID), pid)
        XCTAssertNotEqual(getpgrp(), pid)
        manager.disconnect(id: server.id)
        await manager.shutdown()
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) != 0 && Darwin.kill(childPID, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0)
    }
}

@MainActor private final class MCPFixtureTransport: IOSMcpHTTPTransport {
    enum Failure { case lostResponse, rpcRejection }
    var failure: Failure?
    var methods: [String] = []
    var requests: [IOSMcpServerConfig] = []
    func sendJSONRPC(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        let method = payload["method"] as! String
        methods.append(method)
        requests.append(config)
        let result: [String: Any]
        switch method {
        case "initialize": result = ["protocolVersion": (payload["params"] as? [String: Any])?["protocolVersion"] ?? "2024-11-05", "capabilities": [:], "serverInfo": ["name": "Fixture", "version": "1"]]
        case "tools/list":
            if (payload["params"] as? [String: Any])?["cursor"] == nil {
                result = ["tools": [["name": "echo", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]]], "annotations": ["readOnlyHint": true]]], "nextCursor": "page2"]
            } else { result = ["tools": [["name": "write", "inputSchema": ["type": "object", "properties": [:]]]]] }
        case "tools/call":
            if failure == .lostResponse { throw URLError(.networkConnectionLost) }
            if failure == .rpcRejection {
                return try response(["jsonrpc": "2.0", "id": payload["id"]!, "error": ["code": -32602, "message": "secret-from-server"]])
            }
            let params = payload["params"] as? [String: Any]
            let text = (params?["arguments"] as? [String: Any])?["text"] as? String ?? "ok"
            result = ["content": [["type": "text", "text": text]]]
        default: throw IOSMcpClientError.invalidResponse
        }
        return try response(["jsonrpc": "2.0", "id": payload["id"]!, "result": result], headers: method == "initialize" ? ["Mcp-Session-Id": "session-fixture"] : [:])
    }
    func sendJSONRPCNotification(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        methods.append(payload["method"] as! String)
        requests.append(config)
        return IOSMcpHTTPResponse(status: 202)
    }
    private func response(_ value: [String: Any], headers: [String: String] = [:]) throws -> IOSMcpHTTPResponse {
        IOSMcpHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value), headers: headers)
    }
}

private extension Array { var single: Element? { count == 1 ? first : nil } }

@MainActor final class DesktopUserToolchainTests: XCTestCase {
    func testShellToolResolvesUserLoginPATH() async throws {
        let result = try await DesktopCommandRunner.run("command -v git && echo $PATH", directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("/git"), result.output)
    }
}

extension DesktopUserToolchainTests {
    /// Opt-in: launches a real npx MCP server by bare command name, the way users configure it.
    func testBareNpxStdioServerConnectsThroughLoginShell() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_MAC_LIVE_MODEL"]?.isEmpty == false else {
            throw XCTSkip("Live toolchain check runs with the live E2E environment.")
        }
        var server = DesktopMCPServer()
        server.name = "everything"
        server.transport = .stdio
        server.command = "npx"
        server.arguments = ["-y", "@modelcontextprotocol/server-everything@2025.9.25", "stdio"]
        let store = DesktopMCPStore(defaults: UserDefaults(suiteName: "amber.mcp.live.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        try store.upsert(server)
        let manager = DesktopMCPManager(store: store)
        try await manager.connect(id: server.id)
        XCTAssertTrue(store.servers.first?.tools.contains { $0.name == "echo" } == true)
        await manager.shutdown()
    }
}

extension DesktopUserToolchainTests {
    func testLoginPATHIsResolvedWithoutShellOutputLeakingIntoIt() async {
        let path = await DesktopLoginEnvironment.path.value
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.contains("\n") ?? true)
        XCTAssertTrue(path?.split(separator: ":").contains("/usr/bin") ?? false)
    }
}
