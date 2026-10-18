import XCTest
@preconcurrency import Shared
@testable import iosApp

extension IOSSkillMcpToolsTests {
    func testMcpImportFromSkillPersistsServer() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "mcp-import-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)

        let skillMd = """
        ---
        name: "mcp-pack"
        description: "Use when testing mcp import."
        ---

        # MCP Pack
        """
        let mcpJSON = """
        {
          "mcpServers": {
            "docs": {
              "type": "streamable_http",
              "url": "https://example.com/mcp"
            }
          }
        }
        """
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": skillMd,
            "mcp.json": mcpJSON,
        ])
        settings.setSkillEnabled(name: "mcp-pack", enabled: true)

        let mcpDefaults = UserDefaults(suiteName: "mcp-store-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)
        let counting = CountingMcpClient()
        var service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )
        service.ephemeralClientFactory = { _ in counting }

        let preview = await service.execute(
            toolName: "mcp_import_from_skill",
            arguments: #"{"skill_name":"mcp-pack"}"#
        )
        XCTAssertTrue(preview.contains(#""status":"preview"#), preview)
        XCTAssertTrue(mcpStore.servers.isEmpty)
        XCTAssertEqual(counting.connects, 0)

        let prepared = try service.prepareMcpImport(arguments: #"{"skill_name":"mcp-pack"}"#)
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": skillMd,
            "mcp.json": #"{"mcpServers":{"docs":{"type":"streamable_http","url":"https://example.com/changed"}}}"#,
        ])
        let stale = await service.applyPreparedMcpImport(prepared)
        XCTAssertEqual(try jsonObject(stale)["code"] as? String, "stale_candidate")
        XCTAssertTrue(mcpStore.servers.isEmpty)

        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": skillMd,
            "mcp.json": mcpJSON,
        ])
        counting.shouldFail = true
        let failed = await service.applyPreparedMcpImport(try service.prepareMcpImport(arguments: #"{"skill_name":"mcp-pack"}"#))
        XCTAssertEqual(try jsonObject(failed)["code"] as? String, "connectivity_failed")
        XCTAssertTrue(mcpStore.servers.isEmpty)

        counting.shouldFail = false
        counting.connects = 0
        counting.listCalls = 0
        counting.disconnects = 0
        let applied = await service.applyPreparedMcpImport(try service.prepareMcpImport(arguments: #"{"skill_name":"mcp-pack"}"#))
        XCTAssertEqual(try jsonObject(applied)["ok"] as? Bool, true)
        XCTAssertEqual(mcpStore.servers.map(\.name), ["docs"])
        XCTAssertEqual(counting.connects, 1)
        XCTAssertEqual(counting.listCalls, 1)
        XCTAssertEqual(counting.disconnects, 1)
    }

    func testSkillMcpParserUsesSharedTransportContractAndFailsClosed() throws {
        let parsed = try IOSSkillMcpToolService.parseSupportedMcpServers(json: """
        {
          "mcpServers": {
            "legacy": {
              "transport": " SSE ",
              "url": "https://example.com/sse"
            },
            "modern": {
              "type": "streamable-http",
              "url": "https://example.com/mcp"
            }
          }
        }
        """)
        XCTAssertEqual(parsed, [
            .sse(name: "legacy", url: "https://example.com/sse"),
            .streamableHTTP(name: "modern", url: "https://example.com/mcp"),
        ])

        XCTAssertThrowsError(try IOSSkillMcpToolService.parseSupportedMcpServers(json: """
        {
          "mcpServers": {
            "docs": {
              "type": "sse",
              "transport": "streamable_http",
              "url": "https://example.com/mcp"
            }
          }
        }
        """)) { error in
            XCTAssertEqual(
                error as? IOSMcpImportError,
                .invalidEntry(name: "docs", message: "MCP server type and transport disagree")
            )
        }
    }

    func testMcpImportApplyDoesNotConnectWhenNetworkDisabled() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let skillMd = """
        ---
        name: "mcp-off"
        description: "Use when testing disabled MCP import."
        ---

        # Off
        """
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": skillMd,
            "mcp.json": """
            {
              "mcpServers": {
                "docs": {
                  "type": "streamable_http",
                  "url": "https://example.com/mcp"
                }
              }
            }
            """,
        ])
        settings.setSkillEnabled(name: "mcp-off", enabled: true)

        let mcpStore = IOSMcpConfigStore(userDefaults: isolatedDefaults())
        let counting = CountingMcpClient()
        var service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )
        service.ephemeralClientFactory = { _ in counting }

        let prepared = try service.prepareMcpImport(arguments: #"{"skill_name":"mcp-off"}"#)
        let denied = await service.applyPreparedMcpImport(prepared) { false }
        XCTAssertEqual(try jsonObject(denied)["code"] as? String, "denied")
        XCTAssertEqual(counting.connects, 0)
        XCTAssertEqual(counting.listCalls, 0)
        XCTAssertTrue(mcpStore.servers.isEmpty)
    }

    /// P0-a: the chat declares the resident skill/MCP surface up front and
    /// defers the mutating/management tools (skill_validate/import/enable/
    /// disable, mcp_test, mcp_import_from_skill) behind tool_search in the
    /// default (>40 tools) config.
    func testChatDeclaresSkillAndMcpManagementTools() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
                documentStore: DocumentAccessStore()
            ),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())
        for tool in [
            "skills_list", "use_skill",
            "recipes_list",
            "mcp_list", "mcp_describe_tool", "mcp_call",
        ] {
            XCTAssertTrue(names.contains(tool), "\(tool) should be declared")
        }
        for tool in [
            "skill_validate", "skill_import", "soul_import", "skill_enable", "skill_disable",
            "mcp_test", "mcp_import_from_skill", "recipe_validate", "recipe_import",
            "recipe_enable", "recipe_disable", "recipe_delete",
        ] {
            XCTAssertFalse(names.contains(tool), "\(tool) should be deferred behind tool_search")
        }
        XCTAssertTrue(names.contains("tool_search"))

        // The deferred set is reachable through tool_search (next-step exposure).
        let bridge = viewModel.toolExposureBridgeForTesting()
        let skillPayload = bridge?.executeToolSearch(argumentsJson: #"{"query":"skill_import","limit":1}"#) ?? ""
        XCTAssertTrue(skillPayload.contains("skill_import"))
        let recipePayload = bridge?.executeToolSearch(argumentsJson: #"{"query":"recipe_import","limit":1}"#) ?? ""
        XCTAssertTrue(recipePayload.contains("recipe_import"))

        viewModel.inputText = "帮我创建一个本地 skill，并连接 MCP 服务器"
        viewModel.sendMessage()
        let writeNames = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(writeNames.contains("workspace_file_write"))
    }

    func testChatOmitsNetworkMcpToolsWhenCapabilityIsDisabled() throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.mcp.tool_call" }
        )
        permissionStore.setPolicy(.disabled, for: capability)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: permissionStore,
                documentStore: DocumentAccessStore()
            ),
            autoGenerateResponses: false
        )

        _ = viewModel.currentToolDeclarationNames()
        let names = Set(
            viewModel.toolExposureBridgeForTesting()?.fullToolDeclarations().map(\.name) ?? []
        )
        XCTAssertFalse(names.contains("mcp_call"))
        XCTAssertFalse(names.contains("mcp_test"))
        XCTAssertFalse(names.contains("mcp_import_from_skill"))
        XCTAssertTrue(names.contains("mcp_list"))
        XCTAssertTrue(names.contains("mcp_describe_tool"))
    }

    // MARK: - G2: schema persistence + mcp_describe_tool

    func testMcpToolSchemaIsPersistedAndReloaded() throws {
        let defaults = UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!
        let store = IOSMcpConfigStore(userDefaults: defaults)
        store.add(.streamableHTTP(name: "docs", url: "https://example.com/mcp", tools: []))
        let longDescription = String(repeating: "schema-detail-", count: 300)
        let schemaData = try JSONSerialization.data(withJSONObject: [
            "type": "object",
            "properties": ["q": ["type": "string", "description": longDescription]],
        ], options: [.sortedKeys])
        let schema = try XCTUnwrap(String(data: schemaData, encoding: .utf8))
        store.mergeDiscoveredTools(named: "docs", tools: [
            IOSMcpTool(name: "search", description: "Search docs", inputSchema: schema),
        ])

        // A fresh store over the same defaults must see the persisted schema.
        let reloaded = IOSMcpConfigStore(userDefaults: defaults)
        let tool = try XCTUnwrap(reloaded.servers.first(where: { $0.name == "docs" })?.tools.first)
        XCTAssertEqual(tool.name, "search")
        XCTAssertEqual(tool.inputSchema, schema)
    }

    func testMcpToolLegacyPersistedDataWithoutSchemaStillLoads() throws {
        let defaults = UserDefaults(suiteName: "mcp-legacy-\(UUID().uuidString)")!
        let legacyJSON = """
        [{"name":"docs","url":"https://example.com/mcp","transport":"streamable_http","headers":{},"enabled":true,"tools":[{"name":"search","description":"Search docs","enabled":true}]}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "app.amber.ios.mcpServers")

        let store = IOSMcpConfigStore(userDefaults: defaults)
        let tool = try XCTUnwrap(store.servers.first?.tools.first)
        XCTAssertEqual(tool.name, "search")
        XCTAssertEqual(tool.description, "Search docs")
        XCTAssertNil(tool.inputSchema, "legacy rows decode with a nil schema")
    }

    func testMcpDescribeToolReturnsDescriptionAndSchema() async throws {
        let longDescription = String(repeating: "schema-detail-", count: 300)
        let schemaData = try JSONSerialization.data(withJSONObject: [
            "type": "object",
            "properties": ["q": ["type": "string", "description": longDescription]],
        ], options: [.sortedKeys])
        let schema = try XCTUnwrap(String(data: schemaData, encoding: .utf8))
        let manager = IOSMcpManager(serverProvider: {
            [
                .streamableHTTP(
                    name: "docs",
                    url: "https://example.com/mcp",
                    tools: [
                        IOSMcpTool(name: "search", description: "Search docs", inputSchema: schema),
                        IOSMcpTool(name: "write_note", description: "Write a note"),
                    ]
                ),
            ]
        })
        let service = IOSSkillMcpToolService(
            skillStore: IOSSkillFileStore(baseDirectory: tempRoot()),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            workspaceStore: IOSWorkspaceStore(baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)),
            mcpConfigStore: IOSMcpConfigStore(userDefaults: UserDefaults(suiteName: "mcp-describe-store-\(UUID().uuidString)")!),
            mcpManager: manager
        )

        let result = await service.execute(
            toolName: "mcp_describe_tool",
            arguments: #"{"server":"docs","tool":"search"}"#
        )

        XCTAssertTrue(result.contains(#""ok":true"#), result)
        XCTAssertTrue(result.contains("Search docs"), result)
        XCTAssertTrue(result.contains(#""q""#), result)
        XCTAssertTrue(result.contains(#""input_schema""#), result)
        XCTAssertTrue(result.contains(#""untrusted":true"#), result)
        let resultData = try XCTUnwrap(result.data(using: .utf8))
        let resultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        let inputSchema = try XCTUnwrap(resultObject["input_schema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let query = try XCTUnwrap(properties["q"] as? [String: Any])
        XCTAssertEqual(query["description"] as? String, longDescription)
    }

    func testMcpDescribeToolReturnsStructuredErrorForIncompletePersistedSchema() async {
        let manager = IOSMcpManager(serverProvider: {
            [.streamableHTTP(
                name: "docs",
                url: "https://example.com/mcp",
                tools: [IOSMcpTool(name: "broken", description: nil, inputSchema: #"{"type":"object""#)]
            )]
        })
        let service = IOSSkillMcpToolService(
            skillStore: IOSSkillFileStore(baseDirectory: tempRoot()),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            workspaceStore: IOSWorkspaceStore(baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)),
            mcpConfigStore: IOSMcpConfigStore(userDefaults: UserDefaults(suiteName: "mcp-describe-invalid-\(UUID().uuidString)")!),
            mcpManager: manager
        )

        let result = await service.execute(
            toolName: "mcp_describe_tool",
            arguments: #"{"server":"docs","tool":"broken"}"#
        )

        XCTAssertTrue(result.contains(#""ok":false"#), result)
        XCTAssertTrue(result.contains(#""code":"invalid_persisted_schema""#), result)
    }

    func testMcpDescribeToolErrorsListValidValues() async throws {
        let manager = IOSMcpManager(serverProvider: {
            [
                .streamableHTTP(
                    name: "docs",
                    url: "https://example.com/mcp",
                    tools: [
                        IOSMcpTool(name: "search", description: "Search docs"),
                        IOSMcpTool(name: "write_note", description: "Write a note"),
                    ]
                ),
            ]
        })
        let service = IOSSkillMcpToolService(
            skillStore: IOSSkillFileStore(baseDirectory: tempRoot()),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            workspaceStore: IOSWorkspaceStore(baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)),
            mcpConfigStore: IOSMcpConfigStore(userDefaults: UserDefaults(suiteName: "mcp-describe-err-\(UUID().uuidString)")!),
            mcpManager: manager
        )

        let unknownServer = await service.execute(
            toolName: "mcp_describe_tool",
            arguments: #"{"server":"nope","tool":"search"}"#
        )
        XCTAssertTrue(unknownServer.contains(#""ok":false"#), unknownServer)
        XCTAssertTrue(unknownServer.contains("MCP server not found"), unknownServer)
        XCTAssertTrue(unknownServer.contains(#""valid_servers":["docs"]"#), unknownServer)

        let unknownTool = await service.execute(
            toolName: "mcp_describe_tool",
            arguments: #"{"server":"docs","tool":"nope"}"#
        )
        XCTAssertTrue(unknownTool.contains(#""ok":false"#), unknownTool)
        XCTAssertTrue(unknownTool.contains("MCP tool not found"), unknownTool)
        XCTAssertTrue(unknownTool.contains(#""valid_tools":["search","write_note"]"#), unknownTool)
    }

    // MARK: - G2: MCP catalog injection contract

    private func makeContextBuilder(mcpTools: [IOSMcpDiscoveredTool], mcpGateEnabled: Bool = true) -> ChatRuntimeContextBuilder {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setCapabilityGate(.mcp, enabled: mcpGateEnabled)
        var builder = ChatRuntimeContextBuilder(
            sharedSettings: sharedSettings,
            mcpTools: mcpTools,
            miniAppRepository: IOSMiniAppRepository(baseDirectory: tempRoot()),
            miniAppRuntimeEnabled: false
        )
        builder.skillFileStore = IOSSkillFileStore(baseDirectory: tempRoot())
        return builder
    }

    private func injectedSystemText(_ builder: ChatRuntimeContextBuilder) -> String {
        let prepared = builder.injectingRuntimeContext(
            into: [UIMessage.companion.user(prompt: "hello")],
            coalesceSystemMessages: true
        )
        return prepared
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
    }

    func testMcpCatalogInjectionHasNoCountCapAndInlinesSmallServerSchemas() {
        var tools: [IOSMcpDiscoveredTool] = []
        for index in 0..<3 {
            tools.append(IOSMcpDiscoveredTool(
                serverName: "small",
                tool: IOSMcpTool(name: "t\(index)", description: "Small tool \(index)", inputSchema: #"{"type":"object"}"#)
            ))
        }
        for index in 0..<60 {
            tools.append(IOSMcpDiscoveredTool(
                serverName: "big",
                tool: IOSMcpTool(name: "b\(index)", description: "Big tool \(index) does something")
            ))
        }

        let text = injectedSystemText(makeContextBuilder(mcpTools: tools))

        // No more `.prefix(40)`: the last tool of the 63-tool catalog is listed.
        XCTAssertTrue(text.contains("tool=b59"), text)
        XCTAssertTrue(text.contains("tool=t2"), text)
        // Small server (<=5 tools, <2KB schema total) inlines its schema.
        XCTAssertTrue(text.contains("schema={\"type\":\"object\"}"), text)
        // On-demand schema + naming + untrusted semantics are all stated.
        XCTAssertTrue(text.contains("mcp_describe_tool"), text)
        XCTAssertTrue(text.contains("Do not invent MCP servers or tool names"), text)
        XCTAssertTrue(text.contains("untrusted context"), text)
        // P0-b 管线闭环：直接调用路径（mcp__server__tool + tool_search）已写进引导。
        XCTAssertTrue(text.contains("mcp__server__tool"), text)
        XCTAssertTrue(text.contains("tool_search"), text)
        XCTAssertFalse(text.contains("未列出"), text)
    }

    func testMcpCatalogInjectionTruncatesUnderCharBudgetWithHint() {
        let longDescription = String(repeating: "这是一段很长的工具描述文本用于撑爆注入预算。", count: 80)
        var tools: [IOSMcpDiscoveredTool] = []
        for index in 0..<40 {
            tools.append(IOSMcpDiscoveredTool(
                serverName: "verbose",
                tool: IOSMcpTool(name: "v\(index)", description: longDescription)
            ))
        }

        let text = injectedSystemText(makeContextBuilder(mcpTools: tools))

        let listedLines = text.components(separatedBy: "- server=").count - 1
        XCTAssertLessThan(listedLines, 40, "catalog must be cut by the character budget")
        XCTAssertGreaterThan(listedLines, 0)
        XCTAssertTrue(text.contains("未列出"), text)
        XCTAssertTrue(text.contains("mcp_list"), text)
        XCTAssertTrue(text.contains("mcp_describe_tool"), text)
    }

    func testMcpCatalogInjectionRemainsAvailableWhenLegacyGateIsDisabled() {
        var tools: [IOSMcpDiscoveredTool] = []
        tools.append(IOSMcpDiscoveredTool(serverName: "docs", tool: IOSMcpTool(name: "search", description: "Search docs")))
        let text = injectedSystemText(makeContextBuilder(mcpTools: tools, mcpGateEnabled: false))
        XCTAssertTrue(text.contains("mcp-tools"), "capability gates are persisted-data compatibility only")
    }

}

@MainActor
private final class CountingMcpClient: IOSMcpClienting {
    var connects = 0
    var listCalls = 0
    var calls = 0
    var disconnects = 0
    var shouldFail = false

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        connects += 1
        if shouldFail { throw IOSMcpClientError.invalidResponse }
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        listCalls += 1
        if shouldFail { throw IOSMcpClientError.invalidResponse }
        return []
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        calls += 1
        return ""
    }

    func disconnect() {
        disconnects += 1
    }
}
