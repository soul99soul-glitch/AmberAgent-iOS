import XCTest
@preconcurrency import Shared
@testable import iosApp

extension IOSSkillMcpToolsTests {
    func testSkillEnableRejectsMissingSkill() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-enable-missing-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: IOSMcpConfigStore(userDefaults: UserDefaults(suiteName: "mcp-enable-\(UUID().uuidString)")!),
            mcpManager: IOSMcpManager(
                sharedSettings: settings,
                configStore: IOSMcpConfigStore(userDefaults: UserDefaults(suiteName: "mcp-enable-mgr-\(UUID().uuidString)")!)
            )
        )
        let result = await service.execute(
            toolName: "skill_enable",
            arguments: #"{"name":"does-not-exist"}"#
        )
        XCTAssertTrue(result.contains(#""ok":false"#), result)
        XCTAssertFalse(settings.isSkillEnabled("does-not-exist"))
    }

    func testUseSkillWorksWhenFrontmatterNameDiffersFromDirName() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-name-key-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let mcpDefaults = UserDefaults(suiteName: "mcp-name-key-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)

        let markdown = """
        ---
        name: "Demo Skill"
        description: "Use when testing name-key parity."
        ---

        # Demo Skill
        Body for Demo Skill.
        """
        let packageName = try skillStore.saveSkillFiles(files: ["SKILL.md": markdown])
        XCTAssertEqual(packageName, "demo-skill")
        settings.setSkillEnabled(name: packageName, enabled: true)

        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )

        let listed = await service.execute(toolName: "skills_list", arguments: "{}")
        XCTAssertTrue(listed.contains(#""name":"demo-skill"#), listed)
        XCTAssertFalse(listed.contains(#""name":"Demo Skill"#), listed)

        let usedByDisplay = await service.execute(
            toolName: "use_skill",
            arguments: #"{"name":"Demo Skill"}"#
        )
        XCTAssertTrue(usedByDisplay.contains("Body for Demo Skill."), usedByDisplay)

        let usedByDir = await service.execute(
            toolName: "use_skill",
            arguments: #"{"name":"demo-skill"}"#
        )
        XCTAssertTrue(usedByDir.contains("Body for Demo Skill."), usedByDir)
    }

    func testUseSkillDoesNotExposeMcpConfigOrOversizedFiles() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-sensitive-file-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let markdown = """
        ---
        name: "guarded-skill"
        description: "Use when testing guarded skill reads."
        ---

        # Guarded
        """
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": markdown,
            "mcp.json": #"{"headers":{"Authorization":"Bearer secret-value"}}"#,
            "references/large.txt": String(repeating: "x", count: 256 * 1024 + 1),
        ])
        settings.setSkillEnabled(name: "guarded-skill", enabled: true)
        let mcpStore = IOSMcpConfigStore(
            userDefaults: UserDefaults(suiteName: "skill-sensitive-mcp-\(UUID().uuidString)")!
        )
        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )

        let sensitive = await service.execute(
            toolName: "use_skill",
            arguments: #"{"name":"guarded-skill","path":"mcp.json"}"#
        )
        XCTAssertTrue(sensitive.contains(#""ok":false"#), sensitive)
        XCTAssertFalse(sensitive.contains("secret-value"), sensitive)

        let oversized = await service.execute(
            toolName: "use_skill",
            arguments: #"{"name":"guarded-skill","path":"references/large.txt"}"#
        )
        XCTAssertTrue(oversized.contains(#""ok":false"#), oversized)
        XCTAssertTrue(oversized.contains("exceeds the use_skill limit"), oversized)
    }

    func testMcpTestTargetsOneServerAndRedactsURLSecrets() async {
        let defaults = UserDefaults(suiteName: "mcp-targeted-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let mcpStore = IOSMcpConfigStore(
            userDefaults: UserDefaults(suiteName: "mcp-targeted-store-\(UUID().uuidString)")!
        )
        let targetClient = SkillMcpFakeClient()
        let otherClient = SkillMcpFakeClient()
        let manager = IOSMcpManager(
            serverProvider: {
                [
                    .streamableHTTP(
                        name: "target",
                        url: "https://user:password@example.com/mcp?token=secret"
                    ),
                    .streamableHTTP(name: "other", url: "https://example.com/other"),
                ]
            },
            clientFactory: { config in
                config.name == "target" ? targetClient : otherClient
            }
        )
        let service = IOSSkillMcpToolService(
            skillStore: IOSSkillFileStore(baseDirectory: tempRoot()),
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: manager
        )

        let result = await service.execute(
            toolName: "mcp_test",
            arguments: #"{"server_id":"target"}"#
        )

        XCTAssertTrue(targetClient.didConnect)
        XCTAssertFalse(otherClient.didConnect)
        XCTAssertTrue(result.contains(#""status":"connected""#), result)
        let data = result.data(using: .utf8)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let server = object?["server"] as? [String: Any]
        XCTAssertEqual(server?["url"] as? String, "https://example.com/mcp")
        XCTAssertFalse(result.contains("password"), result)
        XCTAssertFalse(result.contains("token=secret"), result)
    }

    func testSkillImportRootSingleFileAlsoCollectsSiblingMcpJSON() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-sibling-mcp-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let mcpDefaults = UserDefaults(suiteName: "mcp-sibling-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)

        let markdown = """
        ---
        name: "sibling-pack"
        description: "Use when testing sibling mcp.json import."
        ---

        # Sibling
        """
        let mcpJSON = """
        {
          "mcpServers": {
            "sibling-docs": {
              "type": "streamable_http",
              "url": "https://example.com/sibling"
            }
          }
        }
        """
        for (path, content) in [
            "/workspace/SKILL.md": markdown,
            "/workspace/mcp.json": mcpJSON,
        ] {
            let input = try JSONSerialization.data(
                withJSONObject: ["path": path, "content": content, "overwrite": true] as [String: Any],
                options: []
            )
            let writeResult = await workspace.executeTool(
                toolName: "workspace_file_write",
                input: String(data: input, encoding: .utf8) ?? "{}"
            )
            XCTAssertTrue(writeResult.contains(#""ok":true"#), writeResult)
        }

        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )
        let prepared = try service.prepareSkillImport(
            arguments: #"{"workspace_path":"/workspace/SKILL.md"}"#
        )
        let imported = try service.applyPreparedSkillImport(prepared)
        XCTAssertTrue(imported.contains(#""success":true"#), imported)
        XCTAssertTrue(imported.contains(#""contains_mcp_config":true"#), imported)
        XCTAssertTrue(skillStore.containsMcpConfig(name: "sibling-pack"))
    }

    func testMcpImportFromSkillSkipsExistingServer() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "mcp-skip-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)

        let skillMd = """
        ---
        name: "mcp-skip"
        description: "Use when testing skip-existing mcp import."
        ---

        # MCP Skip
        """
        let mcpJSON = """
        {
          "mcpServers": {
            "docs": {
              "type": "streamable_http",
              "url": "https://example.com/new"
            }
          }
        }
        """
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": skillMd,
            "mcp.json": mcpJSON,
        ])
        settings.setSkillEnabled(name: "mcp-skip", enabled: true)

        let mcpDefaults = UserDefaults(suiteName: "mcp-skip-store-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)
        mcpStore.add(.streamableHTTP(
            name: "docs",
            url: "https://example.com/old",
            headers: [:],
            enabled: true,
            tools: []
        ))

        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("ws", isDirectory: true)
            ),
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )

        do {
            _ = try service.prepareMcpImport(arguments: #"{"skill_name":"mcp-skip"}"#)
            XCTFail("duplicate live names must fail closed")
        } catch let error as IOSMcpImportError {
            XCTAssertEqual(error, .liveNameConflict("docs"))
        }
        XCTAssertEqual(
            mcpStore.servers.first(where: { $0.name == "docs" })?.url,
            "https://example.com/old"
        )
    }

    func testOralSkillCreatePhraseUnlocksWorkspaceWrite() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
                documentStore: DocumentAccessStore()
            ),
            autoGenerateResponses: false
        )
        viewModel.inputText = "帮我做一个 skill"
        viewModel.sendMessage()
        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(names.contains("workspace_file_write"))
    }

}

@MainActor
private final class SkillMcpFakeClient: IOSMcpClienting {
    var didConnect = false

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        didConnect = true
        return true
    }

    func listTools() async throws -> [IOSMcpTool] { [] }
    func callTool(name: String, arguments: [String: Any]) async throws -> String { "" }
    func disconnect() {}
}
