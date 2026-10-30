import XCTest
@testable import iosApp

@MainActor
final class IOSMcpRecoveryLifecycleTests: XCTestCase {
    func testDirectoryReadsPreserveRecoveryAndTheDiscoveredCatalog() async throws {
        let client = GatedSessionRecoveryClient()
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
        let manager = IOSMcpManager(serverProvider: { [config] }, clientFactory: { _ in client })
        await manager.syncAll()
        let call = Task { try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:]) }
        await waitForRecovery(client)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "McpRecoveryReads-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let service = IOSSkillMcpToolService(
            skillStore: IOSSkillFileStore(baseDirectory: root.appendingPathComponent("skills")),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            workspaceStore: IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("workspace")),
            mcpConfigStore: IOSMcpConfigStore(userDefaults: defaults),
            mcpManager: manager
        )
        let listed = await service.execute(toolName: "mcp_list", arguments: "{}")
        let described = await service.execute(toolName: "mcp_describe_tool", arguments: #"{"server":"docs","tool":"read"}"#)

        XCTAssertTrue(listed.contains(#""name":"read""#), listed)
        XCTAssertFalse(described.contains("MCP tool not found"), described)
        XCTAssertEqual(client.disconnectCount, 0)
        client.resumeRecovery()
        let output = try await call.value
        XCTAssertEqual(output, "ok")
        XCTAssertEqual(client.reconnectCount, 1)
        XCTAssertEqual(client.successfulCalls, 1)
    }

    func testCancelledRecoveryCreatorLeavesTheSharedRecoveryForAnotherCall() async throws {
        let client = GatedSessionRecoveryClient()
        let manager = makeManager(client)
        await manager.syncAll()
        let cancelledReturned = expectation(description: "cancelled creator exits before reconnect completes")
        let creator = Task {
            defer { cancelledReturned.fulfill() }
            return try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:])
        }
        await waitForRecovery(client)
        creator.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 1)

        let survivor = Task { try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:]) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.reconnectCount, 1)
        XCTAssertTrue(client.isWaiting)
        client.resumeRecovery()

        do {
            _ = try await creator.value
            XCTFail("Expected creator cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let output = try await survivor.value
        XCTAssertEqual(output, "ok")
        XCTAssertEqual(client.successfulCalls, 1)
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
    }

    func testCancelledRecoveryJoinerDoesNotCancelTheCreatorOrOtherCallers() async throws {
        let client = GatedSessionRecoveryClient()
        let manager = makeManager(client)
        await manager.syncAll()
        let creator = Task { try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:]) }
        await waitForRecovery(client)
        let cancelledReturned = expectation(description: "cancelled joiner exits before reconnect completes")
        let joiner = Task {
            defer { cancelledReturned.fulfill() }
            return try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:])
        }
        for _ in 0..<20 { await Task.yield() }
        joiner.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 1)
        XCTAssertTrue(client.isWaiting)
        client.resumeRecovery()

        do {
            _ = try await joiner.value
            XCTFail("Expected joiner cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let output = try await creator.value
        XCTAssertEqual(output, "ok")
        XCTAssertEqual(client.reconnectCount, 1)
        XCTAssertEqual(client.successfulCalls, 1)
    }

    func testToolDisabledDuringRecoveryIsPreservedWithoutReconnectingAgainOrReplayingIt() async throws {
        let client = GatedSessionRecoveryClient()
        var config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
        let manager = IOSMcpManager(serverProvider: { [config] }, clientFactory: { _ in client })
        await manager.syncAll()
        let call = Task { try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:]) }
        await waitForRecovery(client)

        config = config.withTools([GatedSessionRecoveryClient.tool.withEnabled(false)])
        manager.refreshServers()
        XCTAssertEqual(client.disconnectCount, 0)
        client.resumeRecovery()

        do {
            _ = try await call.value
            XCTFail("A tool disabled while recovery runs must not be replayed")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error, .toolDisabled(server: "docs", tool: "read"))
        }
        XCTAssertEqual(client.reconnectCount, 1)
        XCTAssertEqual(client.successfulCalls, 0)
        XCTAssertFalse(try XCTUnwrap(manager.servers.first?.tools.first).enabled)
    }

    func testChangedConnectionInvalidatesRecoveryBeforeItCanPublish() async throws {
        let client = GatedSessionRecoveryClient()
        var config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://old.example/mcp")
        let manager = IOSMcpManager(serverProvider: { [config] }, clientFactory: { _ in client })
        await manager.syncAll()
        let call = Task { try await manager.callTool(serverName: "docs", toolName: "read", arguments: [:]) }
        await waitForRecovery(client)

        config = .sse(name: "docs", url: "https://new.example/mcp", headers: ["X-Endpoint": "new"])
        manager.refreshServers()
        client.resumeRecovery()

        do {
            _ = try await call.value
            XCTFail("Expected changed connection to invalidate the old recovery")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(client.successfulCalls, 0)
        XCTAssertEqual(manager.servers, [config])
    }

    private func makeManager(_ client: GatedSessionRecoveryClient) -> IOSMcpManager {
        IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp")] },
            clientFactory: { _ in client }
        )
    }

    private func waitForRecovery(_ client: GatedSessionRecoveryClient) async {
        for _ in 0..<1_000 where !client.isWaiting { await Task.yield() }
        XCTAssertTrue(client.isWaiting)
    }
}

@MainActor
private final class GatedSessionRecoveryClient: IOSMcpClienting {
    static let tool = IOSMcpTool(name: "read", description: "Read fixture", readOnlyHint: true)
    private(set) var reconnectCount = 0
    private(set) var disconnectCount = 0
    private(set) var successfulCalls = 0
    private var recovered = false
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !recoveryWaiters.isEmpty }

    func connect(config: IOSMcpServerConfig) async throws -> Bool { true }
    func reconnect(config: IOSMcpServerConfig) async throws -> Bool {
        reconnectCount += 1
        await withCheckedContinuation { recoveryWaiters.append($0) }
        recovered = true
        return true
    }
    func listTools() async throws -> [IOSMcpTool] { [Self.tool] }
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        guard recovered else { throw IOSMcpClientError.mcpSessionExpired }
        successfulCalls += 1
        return "ok"
    }
    func disconnect() { disconnectCount += 1 }
    func resumeRecovery() {
        let waiting = recoveryWaiters
        recoveryWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
