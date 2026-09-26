import XCTest
@testable import iosApp

@MainActor
final class IOSMcpManagerTests: XCTestCase {
    func testSyncAllConnectsEnabledServersAndPublishesTools() async {
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: "Search docs")])
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    .streamableHTTP(name: "docs", url: "https://example.com/mcp"),
                    .sse(name: "disabled", url: "https://example.com/sse", enabled: false)
                ]
            },
            clientFactory: { _ in fakeClient }
        )

        await manager.syncAll()

        XCTAssertEqual(manager.servers.count, 2)
        XCTAssertEqual(manager.tools, [IOSMcpDiscoveredTool(serverName: "docs", tool: IOSMcpTool(name: "search", description: "Search docs"))])
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
        XCTAssertEqual(manager.statusByServer["disabled"], .idle)
    }

    func testCallToolRoutesToOwningServer() async throws {
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "echo", description: nil)], callOutput: "hello")
        let manager = IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp")] },
            clientFactory: { _ in fakeClient }
        )
        await manager.syncAll()

        let output = try await manager.callTool(serverName: "docs", toolName: "echo", arguments: ["text": "hello"])

        XCTAssertEqual(output, "hello")
        XCTAssertEqual(fakeClient.calledTools, ["echo"])
    }

    func testCallToolSyncsBeforeCallingWhenChatDidNotOpenMcpPage() async throws {
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "echo", description: nil)], callOutput: "hello")
        let manager = IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp")] },
            clientFactory: { _ in fakeClient }
        )

        let output = try await manager.callTool(serverName: "docs", toolName: "echo", arguments: [:])

        XCTAssertEqual(output, "hello")
        XCTAssertTrue(fakeClient.didConnect)
        XCTAssertEqual(fakeClient.calledTools, ["echo"])
    }

    func testCallToolRejectsDisabledDiscoveredTool() async {
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil, enabled: false)])
        let manager = IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp")] },
            clientFactory: { _ in fakeClient }
        )
        await manager.syncAll()

        do {
            _ = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
            XCTFail("Disabled MCP tools must not be callable.")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error.localizedDescription, IOSMcpClientError.toolDisabled(server: "docs", tool: "search").localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDisabledGateDoesNotConnectServers() async {
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)])
        let manager = IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp")] },
            isEnabled: { false },
            clientFactory: { _ in fakeClient }
        )

        await manager.syncAll()

        XCTAssertTrue(manager.servers.isEmpty)
        XCTAssertTrue(manager.tools.isEmpty)
        XCTAssertTrue(manager.statusByServer.isEmpty)
        XCTAssertFalse(fakeClient.didConnect)

        await manager.syncAll(enabledOverride: true)

        XCTAssertTrue(fakeClient.didConnect)
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
    }

    func testSyncAllDisconnectsServerWhenConfigTurnsOff() async {
        var serverEnabled = true
        let fakeClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)], callOutput: "hello")
        let manager = IOSMcpManager(
            serverProvider: { [.streamableHTTP(name: "docs", url: "https://example.com/mcp", enabled: serverEnabled)] },
            clientFactory: { _ in fakeClient }
        )
        await manager.syncAll()

        XCTAssertTrue(fakeClient.didConnect)
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
        XCTAssertEqual(manager.tools, [IOSMcpDiscoveredTool(serverName: "docs", tool: IOSMcpTool(name: "search", description: nil))])

        serverEnabled = false
        await manager.syncAll()

        XCTAssertTrue(fakeClient.didDisconnect)
        XCTAssertEqual(manager.statusByServer["docs"], .idle)
        XCTAssertTrue(manager.tools.isEmpty)
        do {
            _ = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
            XCTFail("Disabled MCP servers must not accept tool calls.")
        } catch {
            XCTAssertTrue(error is IOSMcpClientError)
        }
    }

    func testSyncNamedServerDoesNotConnectOtherEnabledServers() async {
        let docsClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)])
        let privateClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "query", description: nil)])
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    .streamableHTTP(name: "docs", url: "https://example.com/docs"),
                    .streamableHTTP(name: "private", url: "https://example.com/private"),
                ]
            },
            clientFactory: { config in
                config.name == "docs" ? docsClient : privateClient
            }
        )

        await manager.sync(serverName: "docs")

        XCTAssertTrue(docsClient.didConnect)
        XCTAssertFalse(privateClient.didConnect)
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
        XCTAssertEqual(manager.statusByServer["private"], .idle)
    }

    func testSyncAllKeepsPreviousCatalogAndDoesNotSerializeBehindSlowServer() async throws {
        let fastClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)])
        let slowClient = GatedIOSMcpClient(tools: [IOSMcpTool(name: "query", description: nil)])
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    .streamableHTTP(name: "slow", url: "https://example.com/slow"),
                    .streamableHTTP(name: "fast", url: "https://example.com/fast"),
                ]
            },
            clientFactory: { config in
                config.name == "slow" ? slowClient as IOSMcpClienting : fastClient
            }
        )
        await manager.syncAll()
        let catalog = manager.tools
        XCTAssertEqual(catalog.map(\.id), ["slow::query", "fast::search"])

        slowClient.setGated(true)
        let fastListsBeforeResync = fastClient.listToolsCount
        let resync = Task { @MainActor in await manager.syncAll() }
        for _ in 0..<400 where !(slowClient.isWaiting && fastClient.listToolsCount > fastListsBeforeResync) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // `slow` is listed first and is still blocked, so a second `fast`
        // listing proves the servers are not synced one after another.
        XCTAssertTrue(slowClient.isWaiting)
        XCTAssertEqual(fastClient.listToolsCount, fastListsBeforeResync + 1)
        XCTAssertEqual(manager.statusByServer["slow"], .connecting)
        XCTAssertEqual(manager.tools, catalog)

        slowClient.setGated(false)
        await resync.value
        XCTAssertEqual(manager.tools.map(\.id), ["slow::query", "fast::search"])
        XCTAssertEqual(manager.statusByServer["slow"], .connected)
    }

    func testOverlappingSyncsPublishTheNewestConfig() async throws {
        let fastClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)])
        let slowClient = GatedIOSMcpClient(tools: [IOSMcpTool(name: "query", description: nil)])
        let config = McpServerListBox([
            .streamableHTTP(name: "slow", url: "https://example.com/slow"),
            .streamableHTTP(name: "fast", url: "https://example.com/fast"),
        ])
        let manager = IOSMcpManager(
            serverProvider: { config.servers },
            clientFactory: { server in
                server.name == "slow" ? slowClient as IOSMcpClienting : fastClient
            }
        )

        slowClient.setGated(true)
        let olderSync = Task { @MainActor in await manager.syncAll() }
        for _ in 0..<400 where !slowClient.isWaiting {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        config.servers = [.streamableHTTP(name: "fast", url: "https://example.com/fast")]
        let newerSync = Task { @MainActor in await manager.syncAll() }
        slowClient.setGated(false)
        await olderSync.value
        await newerSync.value

        XCTAssertEqual(manager.tools.map(\.id), ["fast::search"])
        XCTAssertNil(manager.statusByServer["slow"])
    }

    func testCancelledToolCallStopsWaitingForSlowSync() async throws {
        let fastClient = FakeIOSMcpClient(tools: [IOSMcpTool(name: "search", description: nil)])
        let slowClient = GatedIOSMcpClient(tools: [IOSMcpTool(name: "query", description: nil)])
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    .streamableHTTP(name: "slow", url: "https://example.com/slow"),
                    .streamableHTTP(name: "fast", url: "https://example.com/fast"),
                ]
            },
            clientFactory: { config in
                config.name == "slow" ? slowClient as IOSMcpClienting : fastClient
            }
        )
        await manager.syncAll()

        slowClient.setGated(true)
        let backgroundSync = Task { @MainActor in await manager.syncAll() }
        for _ in 0..<400 where !slowClient.isWaiting {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let call = Task { @MainActor in
            try await manager.callTool(serverName: "fast", toolName: "search", arguments: [:])
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("A cancelled call must not wait for the slow sync or reach the server")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(slowClient.isWaiting)
        XCTAssertEqual(fastClient.calledTools, [])

        slowClient.setGated(false)
        await backgroundSync.value
    }

    func testPersistedCatalogLoadsEnabledServersWithoutNetwork() {
        let client = FakeIOSMcpClient(tools: [])
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/docs")
                        .withTools([IOSMcpTool(name: "search", description: nil)]),
                    IOSMcpServerConfig.sse(name: "off", url: "https://example.com/off", enabled: false)
                        .withTools([IOSMcpTool(name: "query", description: nil)]),
                ]
            },
            clientFactory: { _ in client }
        )

        manager.loadPersistedCatalogIfNeeded()

        XCTAssertEqual(manager.tools.map(\.id), ["docs::search"])
        XCTAssertFalse(client.didConnect)
    }
}

private final class McpServerListBox {
    var servers: [IOSMcpServerConfig]

    init(_ servers: [IOSMcpServerConfig]) {
        self.servers = servers
    }
}

private final class FakeIOSMcpClient: IOSMcpClienting {
    let tools: [IOSMcpTool]
    let callOutput: String
    var calledTools: [String] = []
    var didConnect = false
    var didDisconnect = false
    var listToolsCount = 0

    init(tools: [IOSMcpTool], callOutput: String = "") {
        self.tools = tools
        self.callOutput = callOutput
    }

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        didConnect = true
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        listToolsCount += 1
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        calledTools.append(name)
        return callOutput
    }

    func disconnect() {
        didDisconnect = true
    }
}

private final class GatedIOSMcpClient: IOSMcpClienting, @unchecked Sendable {
    private let lock = NSLock()
    private let tools: [IOSMcpTool]
    private var gated = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(tools: [IOSMcpTool]) {
        self.tools = tools
    }

    var isWaiting: Bool {
        lock.withLock { waiter != nil }
    }

    func setGated(_ value: Bool) {
        let released: CheckedContinuation<Void, Never>? = lock.withLock {
            gated = value
            guard !value else { return nil }
            defer { waiter = nil }
            return waiter
        }
        released?.resume()
    }

    func connect(config: IOSMcpServerConfig) async throws -> Bool { true }

    func listTools() async throws -> [IOSMcpTool] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                guard gated else { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String { "" }

    func disconnect() {}
}
