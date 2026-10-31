import XCTest
@testable import AmberMac

@MainActor
final class DesktopPluginInstallToolsTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentials: DesktopMemoryCredentials!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-plugin-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "amber.plugin.install." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        credentials = DesktopMemoryCredentials()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testV3ManifestPathInstallIncludesPermissionConsentAndNestedViewAssets() async throws {
        let workspace = tempDirectory.appendingPathComponent("workspace")
        let source = workspace.appendingPathComponent("drafts/view-helper")
        let installedRoot = tempDirectory.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("views"), withIntermediateDirectories: true)
        let manifest = #"""
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "view-helper",
          "name": "视图助手",
          "version": "1.0.0",
          "description": "验证智能体安装 v3 插件",
          "main": "scripts/main.js",
          "permissions": ["ui.views", "storage", "agent.tools", "workspace.write:notes", "http:api.example.com"],
          "tools": [{"name":"ping", "description":"检查运行时", "effect":"pure", "entry":"ping", "input_schema":{"type":"object"}}],
          "ui": {"views":[{"id":"board", "title":"任务板", "slot":"workspace", "entry":"views/index.html"}]}
        }
        """#
        try Data(manifest.utf8).write(to: source.appendingPathComponent("plugin.json"))
        try Data("function ping() { return {ok: true}; }".utf8).write(to: source.appendingPathComponent("scripts/main.js"))
        try Data("<html><body>Board</body></html>".utf8).write(to: source.appendingPathComponent("views/index.html"))

        let store = DesktopPluginStore(directory: installedRoot, workspaceDirectory: workspace,
                                       defaults: defaults, credentials: credentials)
        let arguments = #"{"path":"drafts/view-helper/plugin.json"}"#
        let prepared = try store.preparePluginInstall(argumentsJSON: arguments)
        XCTAssertTrue(prepared.manifest.isV3)
        XCTAssertTrue(prepared.approvalReason.contains("自定义界面视图"))
        XCTAssertTrue(prepared.approvalReason.contains("插件私有存储"))
        XCTAssertTrue(prepared.approvalReason.contains("【高风险】"))
        XCTAssertTrue(prepared.approvalReason.contains("api.example.com"))
        XCTAssertTrue(prepared.approvalReason.contains("notes"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedRoot.appendingPathComponent("view-helper").path))

        _ = try store.executePluginInstall(argumentsJSON: arguments)
        let installed = installedRoot.appendingPathComponent("view-helper")
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("views/index.html")),
                       try Data(contentsOf: source.appendingPathComponent("views/index.html")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("scripts/main.js").path))
        XCTAssertTrue(store.activeCustomViews.contains { $0.id == "view-helper:board" })
        let toolOutput = try await store.executeTool(qualifiedName: "plugin__view-helper__ping", argumentsJSON: "{}")
        let toolJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(toolOutput.utf8)) as? [String: Any])
        XCTAssertEqual(toolJSON["ok"] as? Bool, true)

        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.executePluginList().utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(list["plugins"] as? [[String: Any]])
        let item = try XCTUnwrap(plugins.first { ($0["id"] as? String) == "view-helper" })
        XCTAssertEqual(item["schema"] as? String, "amber.plugin.v3")
        let permissions = try XCTUnwrap(item["permissions"] as? [String])
        XCTAssertTrue(permissions.contains("ui.views"))
        XCTAssertEqual(item["approved_permissions"] as? [String], permissions)
        let views = try XCTUnwrap(item["views"] as? [[String: String]])
        XCTAssertEqual(views.first?["entry"], "views/index.html")
    }

    func testPluginInstallAndPluginListAgentToolsWithDuplicateUpgradeAndOverwrite() async throws {
        let pluginsRoot = tempDirectory.appendingPathComponent("installed_agent_tools", isDirectory: true)
        let workspaceDir = tempDirectory.appendingPathComponent("workspace_agent_tools", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let store = DesktopPluginStore(
            directory: pluginsRoot,
            workspaceDirectory: workspaceDir,
            defaults: defaults,
            credentials: credentials
        )

        // 1. Initial plugin_list contains the 3 built-in plugins:
        let initialListRaw = try store.executePluginList()
        let initialList = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(initialListRaw.utf8)) as? [String: Any])
        XCTAssertEqual(initialList["ok"] as? Bool, true)
        XCTAssertEqual(initialList["count"] as? Int, 3)

        // 2. Write a v1.0.0 plugin inside the conversation workspace:
        let pluginFolder = workspaceDir.appendingPathComponent("drafts/summary_helper", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
        func writeWorkspacePlugin(version: String, prefixText: String) throws {
            let manifest = """
            {
              "schema": "amber.plugin.v2",
              "id": "summary_helper",
              "name": "摘要助手",
              "version": "\(version)",
              "description": "在会话工作区整理摘要并同步指定接口。",
              "capabilities": {
                "networkDomains": ["api.example.com"],
                "workspaceReadPrefixes": ["notes/"],
                "workspaceWritePrefixes": ["notes/out/"]
              },
              "tools": [
                {
                  "name": "summarize",
                  "description": "生成带前缀的摘要文本",
                  "effect": "pure",
                  "entry": "summarizeText",
                  "input_schema": {
                    "type": "object",
                    "properties": { "text": { "type": "string" } },
                    "required": ["text"]
                  }
                }
              ]
            }
            """
            let script = """
            function summarizeText(input) {
              return { ok: true, result: "\(prefixText)" + String((input && input.text) || "") };
            }
            """
            try Data(manifest.utf8).write(to: pluginFolder.appendingPathComponent("plugin.json"))
            try Data(script.utf8).write(to: pluginFolder.appendingPathComponent("main.js"))
        }
        try writeWorkspacePlugin(version: "1.0.0", prefixText: "[v1.0]")

        // 3. Prepare install and verify human-readable approval reason:
        let preparedFresh = try store.preparePluginInstall(
            argumentsJSON: #"{"path":"drafts/summary_helper"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertEqual(preparedFresh.installKind, .fresh)
        XCTAssertNil(preparedFresh.versionComparison)
        XCTAssertTrue(preparedFresh.approvalReason.contains("摘要助手"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("summary_helper"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("v1.0.0"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("api.example.com"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("notes/"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("notes/out/"))
        XCTAssertTrue(preparedFresh.approvalReason.contains("summarize(pure)"))

        // 4. Execute fresh install -> auto-enabled (consistent with manual import) and reload() registers tool:
        let installOutRaw = try store.executePluginInstall(
            argumentsJSON: #"{"path":"drafts/summary_helper"}"#,
            workspaceDirectory: workspaceDir
        )
        let installOut = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(installOutRaw.utf8)) as? [String: Any])
        XCTAssertEqual(installOut["ok"] as? Bool, true)
        XCTAssertEqual(installOut["id"] as? String, "summary_helper")
        XCTAssertEqual(installOut["version"] as? String, "1.0.0")
        XCTAssertEqual(installOut["enabled"] as? Bool, true)
        XCTAssertEqual(installOut["action"] as? String, "install")

        // Verify via plugin_list and tool execution:
        let afterInstallList = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(store.executePluginList().utf8)) as? [String: Any])
        XCTAssertEqual(afterInstallList["count"] as? Int, 4)
        let pluginsArray = try XCTUnwrap(afterInstallList["plugins"] as? [[String: Any]])
        let listedSummary = try XCTUnwrap(pluginsArray.first { ($0["id"] as? String) == "summary_helper" })
        XCTAssertEqual(listedSummary["version"] as? String, "1.0.0")
        XCTAssertEqual(listedSummary["enabled"] as? Bool, true)
        XCTAssertEqual(listedSummary["is_built_in"] as? Bool, false)

        let v1Exec = try await store.executeTool(
            qualifiedName: "plugin__summary_helper__summarize",
            argumentsJSON: #"{"text":"周会结论"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertTrue(v1Exec.contains("[v1.0]周会结论"))

        // 5. Duplicate install with v1.1.0 WITHOUT overwrite=true must be rejected with version comparison:
        try writeWorkspacePlugin(version: "1.1.0", prefixText: "[v1.1]")
        do {
            _ = try store.preparePluginInstall(
                argumentsJSON: #"{"path":"drafts/summary_helper"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected duplicate plugin without overwrite=true to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("升级安装"))
            XCTAssertTrue(error.localizedDescription.contains("v1.0.0 → v1.1.0"))
            XCTAssertTrue(error.localizedDescription.contains("overwrite=true"))
        }

        // 6. Duplicate install with v1.1.0 and overwrite=true -> succeeds as upgrade with version comparison:
        let preparedUpgrade = try store.preparePluginInstall(
            argumentsJSON: #"{"path":"drafts/summary_helper/plugin.json","overwrite":true}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertEqual(preparedUpgrade.installKind, .upgrade(previousVersion: "1.0.0"))
        XCTAssertEqual(preparedUpgrade.versionComparison, "v1.0.0 → v1.1.0")
        XCTAssertTrue(preparedUpgrade.approvalReason.contains("即将升级已有插件「摘要助手」"))
        XCTAssertTrue(preparedUpgrade.approvalReason.contains("v1.0.0 → v1.1.0"))

        let upgradeOutRaw = try store.executePluginInstall(
            argumentsJSON: #"{"path":"drafts/summary_helper/plugin.json","overwrite":true}"#,
            workspaceDirectory: workspaceDir
        )
        let upgradeOut = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(upgradeOutRaw.utf8)) as? [String: Any])
        XCTAssertEqual(upgradeOut["action"] as? String, "upgrade")
        XCTAssertEqual(upgradeOut["previous_version"] as? String, "1.0.0")
        XCTAssertEqual(upgradeOut["version_comparison"] as? String, "v1.0.0 → v1.1.0")

        let v11Exec = try await store.executeTool(
            qualifiedName: "plugin__summary_helper__summarize",
            argumentsJSON: #"{"text":"周会结论"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertTrue(v11Exec.contains("[v1.1]周会结论"))

        // 7. Same-version reinstall with overwrite=true -> reports overwrite (v1.1.0 → v1.1.0):
        try writeWorkspacePlugin(version: "1.1.0", prefixText: "[v1.1-hotfix]")
        let overwriteOutRaw = try store.executePluginInstall(
            argumentsJSON: #"{"path":"drafts/summary_helper","overwrite":true}"#,
            workspaceDirectory: workspaceDir
        )
        let overwriteOut = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(overwriteOutRaw.utf8)) as? [String: Any])
        XCTAssertEqual(overwriteOut["action"] as? String, "overwrite")
        XCTAssertEqual(overwriteOut["version_comparison"] as? String, "v1.1.0 → v1.1.0")
    }

    func testPluginInstallRejectsOutsideWorkspaceTraversalAndSymlinks() throws {
        let pluginsRoot = tempDirectory.appendingPathComponent("installed_security", isDirectory: true)
        let workspaceDir = tempDirectory.appendingPathComponent("workspace_security", isDirectory: true)
        let outsideDir = tempDirectory.appendingPathComponent("outside_secret_plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let outsideManifest = """
        {
          "schema": "amber.plugin.v2",
          "id": "outside_secret_plugin",
          "name": "外部越界插件",
          "version": "1.0.0",
          "description": "不应从工作区外部被安装",
          "tools": []
        }
        """
        try Data(outsideManifest.utf8).write(to: outsideDir.appendingPathComponent("plugin.json"))
        try Data("function noop() {}".utf8).write(to: outsideDir.appendingPathComponent("main.js"))

        let store = DesktopPluginStore(
            directory: pluginsRoot,
            workspaceDirectory: workspaceDir,
            defaults: defaults,
            credentials: credentials
        )

        // 1. Reject traversal, absolute path, tilde, and current directory:
        for invalidPath in [
            "../outside_secret_plugin",
            "sub/../../outside_secret_plugin",
            outsideDir.path,
            "~/outside_secret_plugin",
            ".",
            "./outside_secret_plugin",
            "sub\\outside_secret_plugin"
        ] {
            XCTAssertThrowsError(
                try store.preparePluginInstall(
                    argumentsJSON: #"{"path":"\#(invalidPath)"}"#,
                    workspaceDirectory: workspaceDir
                ),
                "Path should be rejected: \(invalidPath)"
            )
        }

        // 2. Reject symlinked plugin directory inside workspace pointing outside:
        let symlinkedDir = workspaceDir.appendingPathComponent("linked_plugin")
        try FileManager.default.createSymbolicLink(at: symlinkedDir, withDestinationURL: outsideDir)
        XCTAssertThrowsError(
            try store.preparePluginInstall(
                argumentsJSON: #"{"path":"linked_plugin"}"#,
                workspaceDirectory: workspaceDir
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }

        // 3. Reject real directory inside workspace whose plugin.json or main.js is a symlink pointing outside:
        let realDirWithLinkedFile = workspaceDir.appendingPathComponent("outside_secret_plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirWithLinkedFile, withIntermediateDirectories: true)
        try Data(outsideManifest.utf8).write(to: realDirWithLinkedFile.appendingPathComponent("plugin.json"))
        try FileManager.default.createSymbolicLink(
            at: realDirWithLinkedFile.appendingPathComponent("main.js"),
            withDestinationURL: outsideDir.appendingPathComponent("main.js")
        )
        XCTAssertThrowsError(
            try store.preparePluginInstall(
                argumentsJSON: #"{"path":"outside_secret_plugin"}"#,
                workspaceDirectory: workspaceDir
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }
        XCTAssertThrowsError(
            try store.preparePluginInstall(
                argumentsJSON: #"{"path":"outside_secret_plugin/plugin.json"}"#,
                workspaceDirectory: workspaceDir
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }
    }
    func testCustomPluginImportExecutionAndRemoval() async throws {
        let pluginsRoot = tempDirectory.appendingPathComponent("installed", isDirectory: true)
        let store = DesktopPluginStore(
            directory: pluginsRoot,
            defaults: defaults,
            credentials: credentials
        )

        let pkgDir = tempDirectory.appendingPathComponent("staging_note_helper", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
          "schema": "amber.plugin.v2",
          "id": "note_helper",
          "name": "会议纪要助手",
          "version": "1.0.0",
          "description": "统计纪要字数并附带前缀配置。",
          "settings_schema": [
            { "key": "prefix", "title": "纪要前缀", "kind": "string", "defaultValue": "【飞书纪要】" }
          ],
          "tools": [
            {
              "name": "format_note",
              "description": "格式化会议纪要",
              "effect": "pure",
              "entry": "formatNote",
              "input_schema": {
                "type": "object",
                "properties": { "text": { "type": "string" } },
                "required": ["text"],
                "additionalProperties": false
              }
            }
          ]
        }
        """
        let scriptJS = """
        function formatNote(input) {
            const p = amber.settings.get("prefix") || "";
            const count = Number(amber.storage.get("runs") || "0") + 1;
            amber.storage.set("runs", String(count));
            return { formatted: p + String(input.text || ""), run_count: count };
        }
        """
        try Data(manifestJSON.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(scriptJS.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        let importedID = try store.importPlugin(from: pkgDir)
        XCTAssertEqual(importedID, "note_helper")
        XCTAssertTrue(store.plugins.contains { $0.id == "note_helper" && $0.enabled })
        XCTAssertEqual(
            DesktopToolRegistry.effect(for: "plugin__note_helper__format_note", arguments: "{}"),
            .pure
        )

        let out1 = try await store.executeTool(
            qualifiedName: "plugin__note_helper__format_note",
            argumentsJSON: #"{"text":"确认明日上线"}"#
        )
        let obj1 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out1.utf8)) as? [String: Any])
        XCTAssertEqual(obj1["formatted"] as? String, "【飞书纪要】确认明日上线")
        XCTAssertEqual(obj1["run_count"] as? Int, 1)

        let activity = DesktopToolActivity(DesktopToolCall(
            id: "1",
            name: "plugin__feishu_calendar__create_event",
            input: #"{"summary":"产品周会"}"#,
            output: "{}",
            status: .complete
        ))
        XCTAssertEqual(activity.title, "已创建飞书日程")
        XCTAssertEqual(activity.detail, "产品周会")

        try store.removePlugin(id: "note_helper")
        XCTAssertFalse(store.plugins.contains { $0.id == "note_helper" })
    }

}
