import XCTest
@testable import iosApp

@MainActor
final class IOSMcpClientTests: XCTestCase {
    func testConnectSendsInitializeRequestAndMarksConnected() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]]
        ])
        let client = IOSMcpClient(transport: transport)

        let connected = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        XCTAssertTrue(connected)
        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized"])
        XCTAssertEqual(client.status, .connected)
    }

    func testConnectReusesExistingConnectionForSameConfig() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]]
        ])
        let client = IOSMcpClient(transport: transport)
        let config = IOSMcpServerConfig.sse(name: "docs", url: "https://example.com/sse")

        _ = try await client.connect(config: config)
        _ = try await client.connect(config: config)

        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized"])
        XCTAssertTrue(transport.disconnectedServers.isEmpty)
    }

    func testResponseIDMismatchIsInvalidResponseBeforeRPCError() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 99, "error": ["message": "wrong request"]]
        ])
        let client = IOSMcpClient(transport: transport)

        do {
            _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))
            XCTFail("Expected a mismatched JSON-RPC response id to fail")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(transport.sentMethods, ["initialize"])
    }

    func testStreamableHTTPSessionIDIsCapturedAndSentToSubsequentRequests() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["tools": []]],
                ["jsonrpc": "2.0", "id": 3, "result": ["content": [["type": "text", "text": "ok"]]]],
            ],
            responseHeaders: [["mcp-session-id": "session-1"], [:], [:]]
        )
        let client = IOSMcpClient(transport: transport)
        let config = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://example.com/mcp",
            headers: [
                "Authorization": "Bearer test",
                "Mcp-Session-Id": "stale-session",
            ]
        )

        _ = try await client.connect(config: config)
        _ = try await client.listTools()
        _ = try await client.callTool(name: "echo", arguments: [:])

        XCTAssertNil(transport.sentRequestHeaders[0]["Mcp-Session-Id"])
        XCTAssertEqual(transport.sentRequestHeaders[0]["Authorization"], "Bearer test")
        XCTAssertEqual(transport.sentRequestHeaders[1]["Mcp-Session-Id"], "session-1")
        XCTAssertEqual(transport.sentRequestHeaders[2]["Mcp-Session-Id"], "session-1")
        XCTAssertEqual(transport.sentRequestHeaders[3]["Mcp-Session-Id"], "session-1")
    }

    func testMcpManagerBlocksRawBrowserCdpAndDevtoolsToolsFromExposureAndExecution() async throws {
        let config = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://example.com/mcp",
            tools: [
                IOSMcpTool(name: "search", description: "Search"),
                IOSMcpTool(name: "browser_click", description: "Browser click"),
                IOSMcpTool(name: "cdp_click", description: "CDP click"),
                IOSMcpTool(name: "devtools_click", description: "DevTools click"),
            ]
        )
        let manager = IOSMcpManager(serverProvider: { [config] })
        manager.refreshFromCurrentSettings()

        XCTAssertEqual(manager.tools.map(\.tool.name), ["search"])
        for toolName in ["browser_click", "cdp_click", "devtools_click"] {
            do {
                _ = try await manager.callTool(serverName: "docs", toolName: toolName, arguments: [:])
                XCTFail("Expected \(toolName) to be blocked")
            } catch let error as IOSMcpManagerError {
                XCTAssertEqual(error, .browserToolBlocked)
            } catch {
                XCTFail("Unexpected error for \(toolName): \(error)")
            }
        }
    }

    func testDisconnectClearsStreamableHTTPSessionIDBeforeNextHandshake() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
            ],
            responseHeaders: [["Mcp-Session-Id": "session-1"], ["Mcp-Session-Id": "session-2"]]
        )
        let client = IOSMcpClient(transport: transport)
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")

        _ = try await client.connect(config: config)
        client.disconnect()
        _ = try await client.connect(config: config)

        XCTAssertNil(transport.sentRequestHeaders[2]["Mcp-Session-Id"])
        XCTAssertEqual(transport.disconnectedServers, ["docs"])
    }

    func testStreamableHTTP404WithSessionIDMapsToStableSessionExpiredWithoutRetry() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "error": ["message": "not found"]],
            ],
            responseStatuses: [200, 404],
            responseHeaders: [["Mcp-Session-Id": "session-1"], [:]]
        )
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        do {
            _ = try await client.listTools()
            XCTFail("Expected the session-expired error")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error, .mcpSessionExpired)
            XCTAssertEqual(error.localizedDescription, "mcp_session_expired")
        }

        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized", "tools/list"])
    }

    func testMcpManagerFailsClosedForAmbiguousSameNameServersRegardlessOfSourceOrder() async throws {
        let urlA = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://a.example/mcp",
            headers: ["Authorization": "Bearer a"],
            tools: [IOSMcpTool(name: "search", description: "Search A")]
        )
        let urlB = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://b.example/mcp",
            headers: ["Authorization": "Bearer b"],
            tools: [IOSMcpTool(name: "search", description: "Search B")]
        )
        let headerB = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://a.example/mcp",
            headers: ["Authorization": "Bearer other"],
            tools: [IOSMcpTool(name: "search", description: "Search other")]
        )

        for configs in [[urlA, urlB], [urlB, urlA], [urlA, headerB], [headerB, urlA]] {
            let client = RecordingMcpClient()
            let manager = IOSMcpManager(
                serverProvider: { configs },
                clientFactory: { _ in client }
            )

            var thrownError: Error?
            do {
                _ = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
            } catch {
                thrownError = error
            }

            XCTAssertNotNil(thrownError)
            XCTAssertTrue(thrownError?.localizedDescription.contains("ambiguous") == true)
            XCTAssertTrue(client.connectedConfigs.isEmpty, "ambiguous configs must not reach either transport")
            XCTAssertEqual(client.callCount, 0)
        }
    }

    func testMcpManagerDeduplicatesIdenticalSameNameServers() async throws {
        let config = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://example.com/mcp",
            headers: ["Authorization": "Bearer same"],
            tools: [IOSMcpTool(name: "search", description: "Search")]
        )
        let client = RecordingMcpClient()
        let manager = IOSMcpManager(
            serverProvider: { [config, config] },
            clientFactory: { _ in client }
        )

        let output = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])

        XCTAssertEqual(output, "unexpected")
        XCTAssertEqual(client.connectedConfigs, [config])
        XCTAssertEqual(client.callCount, 1)
    }

    func testExpiredSessionReconnectsAndRetriesExplicitReadOnlyToolExactlyOnce() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["tools": [[
                    "name": "search",
                    "description": "Search docs",
                    "annotations": ["readOnlyHint": true],
                ]]]],
                ["jsonrpc": "2.0", "id": 3, "error": ["message": "expired"]],
                ["jsonrpc": "2.0", "id": 4, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 5, "result": ["tools": [[
                    "name": "search",
                    "description": "Fresh search docs",
                    "annotations": ["readOnlyHint": true],
                ]]]],
                ["jsonrpc": "2.0", "id": 6, "result": ["content": [["type": "text", "text": "fresh"]]]],
            ],
            responseStatuses: [200, 200, 404, 200, 200, 200],
            responseHeaders: [
                ["Mcp-Session-Id": "session-1"],
                [:],
                [:],
                ["Mcp-Session-Id": "session-2"],
                [:],
                [:],
            ]
        )
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
        let manager = IOSMcpManager(
            serverProvider: { [config] },
            clientFactory: { _ in IOSMcpClient(transport: transport) }
        )
        await manager.syncAll()

        let output = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])

        XCTAssertEqual(output, "fresh")
        XCTAssertEqual(transport.disconnectedServers, ["docs"])
        XCTAssertEqual(transport.sentMethods, [
            "initialize", "notifications/initialized", "tools/list", "tools/call",
            "initialize", "notifications/initialized", "tools/list", "tools/call",
        ])
        XCTAssertEqual(transport.sentRequestHeaders[3]["Mcp-Session-Id"], "session-1")
        XCTAssertNil(transport.sentRequestHeaders[4]["Mcp-Session-Id"])
        XCTAssertEqual(transport.sentRequestHeaders[7]["Mcp-Session-Id"], "session-2")
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
    }

    func testExpiredSessionReconnectsButNeverReplaysMutationOrUnknownSafetyTool() async throws {
        let scenarios: [(initial: [String: Bool], recovered: [String: Bool])] = [
            (["readOnlyHint": false], ["readOnlyHint": false]),
            ([:], [:]),
            (["readOnlyHint": true], ["readOnlyHint": false]),
            (["readOnlyHint": true], [:]),
        ]
        for scenario in scenarios {
            let transport = FakeMcpHTTPTransport(
                responses: [
                    ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                    ["jsonrpc": "2.0", "id": 2, "result": ["tools": [[
                        "name": "write",
                        "description": "Write docs",
                        "annotations": scenario.initial,
                    ]]]],
                    ["jsonrpc": "2.0", "id": 3, "error": ["message": "expired"]],
                    ["jsonrpc": "2.0", "id": 4, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                    ["jsonrpc": "2.0", "id": 5, "result": ["tools": [[
                        "name": "write",
                        "description": "Fresh write docs",
                        "annotations": scenario.recovered,
                    ]]]],
                ],
                responseStatuses: [200, 200, 404, 200, 200],
                responseHeaders: [
                    ["Mcp-Session-Id": "session-1"],
                    [:],
                    [:],
                    ["Mcp-Session-Id": "session-2"],
                    [:],
                ]
            )
            let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
            let manager = IOSMcpManager(
                serverProvider: { [config] },
                clientFactory: { _ in IOSMcpClient(transport: transport) }
            )
            await manager.syncAll()

            do {
                _ = try await manager.callTool(serverName: "docs", toolName: "write", arguments: [:])
                XCTFail("Expected the dispatched write to fail closed after session expiry")
            } catch let error as IOSMcpClientError {
                XCTAssertEqual(error, .mcpSessionExpired)
            }

            XCTAssertEqual(transport.disconnectedServers, ["docs"])
            XCTAssertEqual(transport.sentMethods, [
                "initialize", "notifications/initialized", "tools/list", "tools/call",
                "initialize", "notifications/initialized", "tools/list",
            ])
            XCTAssertEqual(manager.statusByServer["docs"], .connected)
        }
    }

    func testConcurrentExpiredCallsShareOneReconnectAndRefresh() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["tools": [[
                    "name": "search",
                    "annotations": ["readOnlyHint": true],
                ]]]],
                ["jsonrpc": "2.0", "id": 3, "error": ["message": "expired"]],
                ["jsonrpc": "2.0", "id": 4, "error": ["message": "expired"]],
                ["jsonrpc": "2.0", "id": 5, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 6, "result": ["tools": [[
                    "name": "search",
                    "annotations": ["readOnlyHint": true],
                ]]]],
                ["jsonrpc": "2.0", "id": 7, "result": ["content": [["type": "text", "text": "fresh-a"]]]],
                ["jsonrpc": "2.0", "id": 8, "result": ["content": [["type": "text", "text": "fresh-b"]]]],
            ],
            responseStatuses: [200, 200, 404, 404, 200, 200, 200, 200],
            responseHeaders: [
                ["Mcp-Session-Id": "session-1"], [:], [:], [:],
                ["Mcp-Session-Id": "session-2"], [:], [:], [:],
            ],
            delayedMethods: ["tools/call": 20_000_000]
        )
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
        let manager = IOSMcpManager(
            serverProvider: { [config] },
            clientFactory: { _ in IOSMcpClient(transport: transport) }
        )
        await manager.syncAll()

        let first = Task { try await manager.callTool(serverName: "docs", toolName: "search", arguments: ["q": "a"]) }
        let second = Task { try await manager.callTool(serverName: "docs", toolName: "search", arguments: ["q": "b"]) }
        let outputs = try await [first.value, second.value]

        XCTAssertEqual(outputs.sorted(), ["fresh-a", "fresh-b"])
        XCTAssertEqual(transport.sentMethods.filter { $0 == "initialize" }.count, 2)
        XCTAssertEqual(transport.sentMethods.filter { $0 == "tools/list" }.count, 2)
        XCTAssertEqual(transport.sentMethods.filter { $0 == "tools/call" }.count, 4)
        XCTAssertEqual(transport.disconnectedServers, ["docs"])
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
    }

    func testSequentialSessionExpiriesStartDistinctRecoveries() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["tools": [["name": "search", "annotations": ["readOnlyHint": true]]]]],
                ["jsonrpc": "2.0", "id": 3, "error": ["message": "expired-1"]],
                ["jsonrpc": "2.0", "id": 4, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 5, "result": ["tools": [["name": "search", "annotations": ["readOnlyHint": true]]]]],
                ["jsonrpc": "2.0", "id": 6, "result": ["content": [["type": "text", "text": "first"]]]],
                ["jsonrpc": "2.0", "id": 7, "error": ["message": "expired-2"]],
                ["jsonrpc": "2.0", "id": 8, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 9, "result": ["tools": [["name": "search", "annotations": ["readOnlyHint": true]]]]],
                ["jsonrpc": "2.0", "id": 10, "result": ["content": [["type": "text", "text": "second"]]]],
            ],
            responseStatuses: [200, 200, 404, 200, 200, 200, 404, 200, 200, 200],
            responseHeaders: [
                ["Mcp-Session-Id": "session-1"], [:], [:],
                ["Mcp-Session-Id": "session-2"], [:], [:], [:],
                ["Mcp-Session-Id": "session-3"], [:], [:],
            ]
        )
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://example.com/mcp")
        let manager = IOSMcpManager(
            serverProvider: { [config] },
            clientFactory: { _ in IOSMcpClient(transport: transport) }
        )
        await manager.syncAll()

        let first = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
        let second = try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])

        XCTAssertEqual([first, second], ["first", "second"])
        XCTAssertEqual(transport.sentMethods.filter { $0 == "initialize" }.count, 3)
        XCTAssertEqual(transport.sentMethods.filter { $0 == "tools/list" }.count, 3)
        XCTAssertEqual(transport.disconnectedServers, ["docs", "docs"])
    }

    func testCapabilityDisableInvalidatesInFlightRecoveryWithoutRepublishingState() async throws {
        let config = IOSMcpServerConfig.streamableHTTP(name: "docs", url: "https://old.example/mcp")
        let client = SuspendingRecoveryMcpClient()
        let manager = IOSMcpManager(
            serverProvider: { [config] },
            clientFactory: { _ in client }
        )
        await manager.syncAll()

        let call = Task {
            try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
        }
        for _ in 0..<1_000 where !client.recoveryConnectStarted {
            await Task.yield()
        }
        XCTAssertTrue(client.recoveryConnectStarted)

        await manager.syncAll(enabledOverride: false)
        client.resumeRecoveryConnect()

        do {
            _ = try await call.value
            XCTFail("Expected disabled capability to invalidate recovery")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(manager.servers.isEmpty)
        XCTAssertTrue(manager.tools.isEmpty)
        XCTAssertTrue(manager.statusByServer.isEmpty)
        XCTAssertEqual(client.listToolsCount, 1, "stale recovery must not list or republish tools")
    }

    func testConfigChangeInvalidatesInFlightRecoveryWithoutOverwritingNewServer() async throws {
        let oldConfig = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://old.example/mcp",
            headers: ["Authorization": "Bearer old"]
        )
        let newConfig = IOSMcpServerConfig.streamableHTTP(
            name: "docs",
            url: "https://new.example/mcp",
            headers: ["Authorization": "Bearer new"]
        )
        var currentConfig = oldConfig
        let oldClient = SuspendingRecoveryMcpClient()
        let newClient = RecordingMcpClient()
        let manager = IOSMcpManager(
            serverProvider: { [currentConfig] },
            clientFactory: { config -> IOSMcpClienting in
                config.url == oldConfig.url ? oldClient : newClient
            }
        )
        await manager.syncAll()

        let call = Task {
            try await manager.callTool(serverName: "docs", toolName: "search", arguments: [:])
        }
        for _ in 0..<1_000 where !oldClient.recoveryConnectStarted {
            await Task.yield()
        }
        XCTAssertTrue(oldClient.recoveryConnectStarted)

        currentConfig = newConfig
        await manager.sync(serverName: "docs")
        oldClient.resumeRecoveryConnect()

        do {
            _ = try await call.value
            XCTFail("Expected changed config to invalidate old recovery")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(manager.servers.count, 1)
        XCTAssertEqual(manager.servers.first?.url, newConfig.url)
        XCTAssertEqual(manager.servers.first?.headers, newConfig.headers)
        XCTAssertEqual(manager.statusByServer["docs"], .connected)
        XCTAssertEqual(manager.tools.map(\.serverName), ["docs"])
        XCTAssertEqual(oldClient.listToolsCount, 1, "old recovery must not publish after config replacement")
        XCTAssertEqual(newClient.connectedConfigs, [newConfig])
    }

    func testConnectDisconnectsPreviousConfigWhenServerChanges() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]]
        ])
        let client = IOSMcpClient(transport: transport)

        _ = try await client.connect(config: .sse(name: "docs", url: "https://example.com/sse"))
        _ = try await client.connect(config: .sse(name: "docs", url: "https://example.com/changed-sse"))

        XCTAssertEqual(transport.sentMethods, [
            "initialize",
            "notifications/initialized",
            "initialize",
            "notifications/initialized"
        ])
        XCTAssertEqual(transport.disconnectedServers, ["docs"])
    }

    func testListToolsMapsMcpToolResult() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "result": ["tools": [["name": "search", "description": "Search docs"]]]]
        ])
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        let tools = try await client.listTools()

        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized", "tools/list"])
        XCTAssertEqual(tools, [IOSMcpTool(name: "search", description: "Search docs")])
        XCTAssertNil(tools.first?.inputSchema, "legacy servers without inputSchema decode as nil")
    }

    /// G2: tools/list inputSchema is serialized and persisted on IOSMcpTool so
    /// mcp_describe_tool can serve it later without re-connecting.
    func testListToolsPersistsCompleteInputSchema() async throws {
        let bigSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": String(repeating: "x", count: 3_000)],
            ],
        ]
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "result": ["tools": [
                ["name": "search", "description": "Search docs", "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]]]],
                ["name": "big", "description": "Big schema tool", "inputSchema": bigSchema],
            ]]]
        ])
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        let tools = try await client.listTools()

        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(
            tools[0].inputSchema,
            #"{"properties":{"q":{"type":"string"}},"type":"object"}"#
        )
        let persistedBigSchema = try XCTUnwrap(tools[1].inputSchema)
        XCTAssertGreaterThan(persistedBigSchema.count, 2_048)
        let persistedData = try XCTUnwrap(persistedBigSchema.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        XCTAssertNotNil(decoded?["properties"], "mcp_describe_tool must receive a complete JSON schema")
    }

    func testCallToolReturnsTextContent() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "result": ["content": [["type": "text", "text": "hello"]]]]
        ])
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        let output = try await client.callTool(name: "echo", arguments: ["text": "hello"])

        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized", "tools/call"])
        XCTAssertEqual(output, "hello")
    }

    func testCallToolPreservesMcpErrorResult() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
            ["jsonrpc": "2.0", "id": 2, "result": [
                "isError": true,
                "content": [["type": "text", "text": "target is stale"]]
            ]]
        ])
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "browser", url: "https://example.com/mcp"))

        do {
            _ = try await client.callTool(name: "browser_click", arguments: ["target": "ref-1"])
            XCTFail("Expected MCP error result to throw")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error, .rpcError("target is stale"))
        }
    }

    func testCallToolSerializesNonTextContent() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "result": ["content": [["type": "image", "mimeType": "image/png"]]]]
        ])
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        let output = try await client.callTool(name: "image", arguments: [:])

        XCTAssertTrue(output.contains(#""type":"image""#))
    }

    func testCallToolTimesOutWhenTransportNeverProducesTerminalResponse() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]]
            ],
            hangingMethods: ["tools/call"]
        )
        let client = IOSMcpClient(transport: transport, requestTimeoutSeconds: 0.01)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        do {
            _ = try await client.callTool(name: "slow", arguments: [:])
            XCTFail("Expected MCP call to time out")
        } catch let error as IOSMcpClientError {
            XCTAssertEqual(error, .requestTimedOut("MCP request tools/call timed out after 0.01s"))
        }
    }

    func testCallerCancellationCancelsInFlightTransportWithoutWaitingForTimeout() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]]
            ],
            hangingMethods: ["tools/call"]
        )
        let cancellationObserved = expectation(description: "transport observes cancellation")
        transport.onCancellation = { method in
            if method == "tools/call" {
                cancellationObserved.fulfill()
            }
        }
        let client = IOSMcpClient(transport: transport, requestTimeoutSeconds: 5)
        _ = try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))

        let call = Task { try await client.callTool(name: "slow", arguments: [:]) }
        while !transport.sentMethods.contains("tools/call") {
            await Task.yield()
        }
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        XCTAssertTrue(transport.cancelledMethods.contains("tools/call"))
    }

    func testConcurrentCallsAreSerializedPerClient() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["content": [["type": "text", "text": "first"]]]],
                ["jsonrpc": "2.0", "id": 3, "result": ["content": [["type": "text", "text": "second"]]]],
            ],
            delayedMethods: ["tools/call": 20_000_000]
        )
        let client = IOSMcpClient(transport: transport)
        _ = try await client.connect(config: .sse(name: "legacy", url: "https://example.com/sse"))

        let first = Task { try await client.callTool(name: "one", arguments: [:]) }
        let second = Task { try await client.callTool(name: "two", arguments: [:]) }
        _ = try await (first.value, second.value)

        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
    }

    func testConnectHandshakeCannotBeInterleavedByToolRequest() async throws {
        let transport = FakeMcpHTTPTransport(
            responses: [
                ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:]]],
                ["jsonrpc": "2.0", "id": 2, "result": ["tools": []]],
            ],
            delayedMethods: ["initialize": 20_000_000]
        )
        let client = IOSMcpClient(transport: transport)
        let connect = Task {
            try await client.connect(config: .streamableHTTP(name: "docs", url: "https://example.com/mcp"))
        }
        while !transport.sentMethods.contains("initialize") {
            await Task.yield()
        }
        let list = Task { try await client.listTools() }

        _ = try await connect.value
        _ = try await list.value

        XCTAssertEqual(transport.sentMethods, ["initialize", "notifications/initialized", "tools/list"])
    }

    func testLegacyEndpointMustUseSecureSameOriginTransport() throws {
        XCTAssertEqual(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("/messages?id=1", relativeTo: "https://example.com/sse").absoluteString,
            "https://example.com/messages?id=1"
        )
        XCTAssertEqual(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("/messages", relativeTo: "http://127.0.0.1:8080/sse").absoluteString,
            "http://127.0.0.1:8080/messages"
        )
        XCTAssertEqual(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("/messages", relativeTo: "http://192.168.1.2:8080/sse").absoluteString,
            "http://192.168.1.2:8080/messages"
        )
        XCTAssertThrowsError(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("https://attacker.example/messages", relativeTo: "https://example.com/sse")
        )
        XCTAssertThrowsError(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("file:///tmp/messages", relativeTo: "https://example.com/sse")
        )
        XCTAssertThrowsError(
            try IOSMcpLegacyEndpointPolicy.validatedEndpoint("http://example.com/messages", relativeTo: "https://example.com/sse")
        )
    }

    func testDisconnectClearsTransportSession() async throws {
        let transport = FakeMcpHTTPTransport(responses: [
            ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "fake", "version": "1"]]]
        ])
        let client = IOSMcpClient(transport: transport)

        _ = try await client.connect(config: .sse(name: "docs", url: "https://example.com/sse"))
        client.disconnect()

        XCTAssertEqual(client.status, .idle)
        XCTAssertEqual(transport.disconnectedServers, ["docs"])
    }
}

private final class FakeMcpHTTPTransport: IOSMcpHTTPTransport {
    private var responses: [IOSMcpHTTPResponse]
    private let hangingMethods: Set<String>
    private let delayedMethods: [String: UInt64]
    private(set) var sentMethods: [String] = []
    private(set) var sentRequestHeaders: [[String: String]] = []
    private(set) var disconnectedServers: [String] = []
    private(set) var cancelledMethods: Set<String> = []
    var onCancellation: ((String) -> Void)?
    private(set) var maximumConcurrentRequests = 0
    private var activeRequests = 0

    init(
        responses: [[String: Any]],
        responseStatuses: [Int] = [],
        responseHeaders: [[String: String]] = [],
        hangingMethods: Set<String> = [],
        delayedMethods: [String: UInt64] = [:]
    ) {
        self.responses = responses.enumerated().map { index, object in
            let body = try! JSONSerialization.data(withJSONObject: object)
            let status = responseStatuses.indices.contains(index) ? responseStatuses[index] : 200
            let headers = responseHeaders.indices.contains(index) ? responseHeaders[index] : [:]
            return IOSMcpHTTPResponse(status: status, body: body, headers: headers)
        }
        self.hangingMethods = hangingMethods
        self.delayedMethods = delayedMethods
    }

    func sendJSONRPC(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        if let method = payload["method"] as? String {
            sentMethods.append(method)
            sentRequestHeaders.append(config.headers)
            activeRequests += 1
            maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
            defer { activeRequests -= 1 }
            do {
                if hangingMethods.contains(method) {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let body = try JSONSerialization.data(withJSONObject: [
                        "jsonrpc": "2.0", "id": payload["id"] as Any, "result": [:]
                    ])
                    return IOSMcpHTTPResponse(status: 200, body: body)
                }
                if let delay = delayedMethods[method] {
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch is CancellationError {
                cancelledMethods.insert(method)
                onCancellation?(method)
                throw CancellationError()
            }
        }
        return responses.removeFirst()
    }

    func sendJSONRPCNotification(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        if let method = payload["method"] as? String {
            sentMethods.append(method)
            sentRequestHeaders.append(config.headers)
        }
        return IOSMcpHTTPResponse(status: 200)
    }

    func disconnect(config: IOSMcpServerConfig) {
        disconnectedServers.append(config.name)
    }
}

private final class RecordingMcpClient: IOSMcpClienting {
    private(set) var connectedConfigs: [IOSMcpServerConfig] = []
    private(set) var callCount = 0

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        connectedConfigs.append(config)
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        [IOSMcpTool(name: "search", description: "Search")]
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        callCount += 1
        return "unexpected"
    }

    func disconnect() {}
}

private final class SuspendingRecoveryMcpClient: IOSMcpClienting {
    private(set) var connectCount = 0
    private(set) var listToolsCount = 0
    private(set) var recoveryConnectStarted = false
    private var recoveryContinuation: CheckedContinuation<Void, Never>?

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        connectCount += 1
        if connectCount == 2 {
            recoveryConnectStarted = true
            await withCheckedContinuation { continuation in
                recoveryContinuation = continuation
            }
        }
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        listToolsCount += 1
        return [IOSMcpTool(name: "search", description: "Search", readOnlyHint: true)]
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        throw IOSMcpClientError.mcpSessionExpired
    }

    func disconnect() {}

    func resumeRecoveryConnect() {
        recoveryContinuation?.resume()
        recoveryContinuation = nil
    }
}
