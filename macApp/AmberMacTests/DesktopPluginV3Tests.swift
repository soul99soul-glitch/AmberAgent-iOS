import Foundation
import XCTest
@testable import AmberMac

@MainActor
final class DesktopPluginV3Tests: XCTestCase {
    private var rootDirectory: URL!
    private var pluginsDirectory: URL!
    private var workspaceDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentials: DesktopMemoryCredentials!
    private var httpTransport: MockV3PluginHTTPTransport!

    override func setUp() async throws {
        try await super.setUp()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-plugin-v3-tests-\(UUID().uuidString)", isDirectory: true)
        pluginsDirectory = rootDirectory.appendingPathComponent("plugins", isDirectory: true)
        workspaceDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        suiteName = "amber.plugin.v3.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        credentials = DesktopMemoryCredentials()
        httpTransport = MockV3PluginHTTPTransport()
    }

    override func tearDown() async throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try await super.tearDown()
    }

    private func makeStore() -> DesktopPluginStore {
        DesktopPluginStore(
            directory: pluginsDirectory,
            workspaceDirectory: workspaceDirectory,
            defaults: defaults,
            credentials: credentials,
            httpTransport: httpTransport
        )
    }

    // MARK: - 1. Manifest v3 Validation & Permission Token Validation

    func testManifestV3ValidationAndInvalidPermissionOrViewEntryRejection() throws {
        let store = makeStore()

        // Invalid permission token should be rejected:
        let badPermDir = rootDirectory.appendingPathComponent("bad-perm", isDirectory: true)
        try FileManager.default.createDirectory(at: badPermDir, withIntermediateDirectories: true)
        let badPermManifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "bad-perm",
          "name": "Bad Perm",
          "version": "1.0.0",
          "description": "Invalid permission token test",
          "permissions": ["root.shell.exec"]
        }
        """
        try Data(badPermManifest.utf8).write(to: badPermDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: badPermDir.appendingPathComponent("main.js"))

        XCTAssertThrowsError(try store.inspectPluginPackage(at: badPermDir)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("未知") || error.localizedDescription.contains("权限"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        // View entry with '..' traversal should be rejected:
        let badViewDir = rootDirectory.appendingPathComponent("bad-view", isDirectory: true)
        try FileManager.default.createDirectory(at: badViewDir, withIntermediateDirectories: true)
        let badViewManifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "bad-view",
          "name": "Bad View",
          "version": "1.0.0",
          "description": "Traversal view entry test",
          "permissions": ["ui.views"],
          "ui": {
            "views": [
              {
                "id": "main_view",
                "slot": "workspace",
                "title": "Main",
                "entry": "../secret.html"
              }
            ]
          }
        }
        """
        try Data(badViewManifest.utf8).write(to: badViewDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: badViewDir.appendingPathComponent("main.js"))

        XCTAssertThrowsError(try store.inspectPluginPackage(at: badViewDir)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("入口资源路径无效") || error.localizedDescription.contains(".."),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - 2. Install / Upgrade Permission Consent & Summary

    func testInstallAndUpgradePermissionConsentFlow() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("consent-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let v1Manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "consent-demo",
          "name": "权限审批测试插件",
          "version": "1.0.0",
          "description": "测试安装与升级权限审批",
          "permissions": ["storage", "workspace.read"],
          "capabilities": {
            "workspaceReadPrefixes": ["docs/"]
          }
        }
        """
        try Data(v1Manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        let planV1 = try store.inspectPluginPackage(at: pkgDir)
        XCTAssertFalse(planV1.isUpgrade)
        XCTAssertTrue(planV1.requiresUserApproval)
        XCTAssertEqual(Set(planV1.permissions.map(\.token)), Set(["storage", "workspace.read"]))
        XCTAssertTrue(planV1.permissions.contains { $0.title.contains("读取") })

        // Importing v3 plugin with approvePermissions: false leaves permissions unapproved and blocks calls:
        let importedID = try store.importPlugin(from: pkgDir, approvePermissions: false)
        XCTAssertEqual(importedID, "consent-demo")
        XCTAssertEqual(store.approvedPermissions(for: "consent-demo"), [])
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "consent-demo",
                namespace: "storage",
                method: "get",
                args: ["k"]
            )
            XCTFail("Expected unapproved permission to be blocked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("尚未获得用户批准"))
        }

        // Approving permissions via approvePluginPermissions unlocks the capability:
        store.approvePluginPermissions(pluginID: "consent-demo", permissions: ["storage", "workspace.read"])
        XCTAssertEqual(store.approvedPermissions(for: "consent-demo"), Set(["storage", "workspace.read"]))
        _ = try await store.dispatchBridgeRPC(
            pluginID: "consent-demo",
            namespace: "storage",
            method: "set",
            args: ["k", "approved_ok"]
        )
        let got = try await store.dispatchBridgeRPC(
            pluginID: "consent-demo",
            namespace: "storage",
            method: "get",
            args: ["k"]
        )
        XCTAssertEqual(got, #""approved_ok""#)

        // Upgrade package adding high-risk 'workspace.write' and 'http:api.github.com':
        let v2Manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "consent-demo",
          "name": "权限审批测试插件",
          "version": "2.0.0",
          "description": "升级后新增高风险写权限",
          "permissions": ["storage", "workspace.read", "workspace.write", "http:api.github.com"],
          "capabilities": {
            "networkDomains": ["api.github.com"],
            "workspaceReadPrefixes": ["docs/"],
            "workspaceWritePrefixes": ["docs/"]
          }
        }
        """
        try Data(v2Manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))

        let planV2 = try store.inspectPluginPackage(at: pkgDir)
        XCTAssertTrue(planV2.isUpgrade)
        XCTAssertEqual(planV2.previousVersion, "1.0.0")
        XCTAssertEqual(
            Set(planV2.newlyRequestedPermissions.map(\.token)),
            Set(["workspace.write", "http:api.github.com"])
        )
        XCTAssertTrue(planV2.newlyRequestedPermissions.allSatisfy(\.isHighRisk))
    }

    // MARK: - 3. Undeclared Permission Immediate Rejection

    func testUndeclaredPermissionsAreRejectedImmediately() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("minimal-perm", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        // Only declare "storage", omit workspace.write, http, ui.views, commands, settings, agent.tools
        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "minimal-perm",
          "name": "最小权限插件",
          "version": "1.0.0",
          "description": "仅声明 storage 权限",
          "permissions": ["storage"]
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)

        // Allowed: storage.set / storage.get
        _ = try await store.dispatchBridgeRPC(pluginID: "minimal-perm", namespace: "storage", method: "set", args: ["k", "v"])
        let val = try await store.dispatchBridgeRPC(pluginID: "minimal-perm", namespace: "storage", method: "get", args: ["k"])
        XCTAssertEqual(val, #""v""#)

        // Denied: workspace.write
        do {
            _ = try await store.dispatchBridgeRPC(pluginID: "minimal-perm", namespace: "workspace", method: "write", args: ["a.txt", "hello"])
            XCTFail("Expected workspace.write to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("workspace.write"))
        }

        // Denied: http.fetch
        do {
            _ = try await store.dispatchBridgeRPC(pluginID: "minimal-perm", namespace: "http", method: "fetch", args: ["https://api.github.com/zen"])
            XCTFail("Expected http.fetch to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http:api.github.com"))
        }

        // Denied: ui.notice
        do {
            _ = try await store.dispatchBridgeRPC(pluginID: "minimal-perm", namespace: "ui", method: "notice", args: ["hi"])
            XCTFail("Expected ui.notice to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ui.views"))
        }

        // Denied: agent.registerTool
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "minimal-perm",
                namespace: "agent",
                method: "registerTool",
                args: [["name": "sneaky", "description": "no perm"]]
            )
            XCTFail("Expected agent.registerTool to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("agent.tools"))
        }
    }

    // MARK: - 4. Bridge RPC Across All Namespaces

    func testBridgeRPCAcrossAllNamespaces() async throws {
        let store = makeStore()
        var insertedPrompt: String?
        var openedView: (String, String)?
        store.onInsertToComposerRequest = { insertedPrompt = $0 }
        store.onOpenPluginViewRequest = { openedView = ($0, $1) }
        store.conversationSnapshotProvider = {
            DesktopPluginConversationSnapshot(
                id: "conv-123",
                title: "测试对话",
                messageCount: 4,
                messages: []
            )
        }

        let pkgDir = rootDirectory.appendingPathComponent("bridge-suite", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "bridge-suite",
          "name": "Bridge 全家桶测试",
          "version": "1.0.0",
          "description": "测试 8 大命名空间 RPC",
          "permissions": [
            "ui.views",
            "workspace.read",
            "workspace.write",
            "http:api.github.com",
            "agent.tools",
            "storage",
            "commands",
            "events",
            "settings"
          ],
          "capabilities": {
            "networkDomains": ["api.github.com"],
            "workspaceReadPrefixes": ["data/"],
            "workspaceWritePrefixes": ["data/"]
          },
          "settings_schema": [
            {
              "key": "theme_label",
              "title": "主题标签",
              "kind": "string",
              "defaultValue": "琥珀默认"
            },
            {
              "key": "api_secret",
              "title": "API 密钥",
              "kind": "secret",
              "defaultValue": ""
            }
          ],
          "ui": {
            "views": [
              {
                "id": "main_panel",
                "slot": "workspace",
                "title": "主面板",
                "entry": "index.html"
              }
            ]
          }
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: pkgDir.appendingPathComponent("main.js"))
        try Data("<html><head></head><body>Hello</body></html>".utf8).write(to: pkgDir.appendingPathComponent("index.html"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)

        // 1) storage: set, get, keys, all, remove
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "set", args: ["obj", ["count": 42]])
        let gotObjJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "get", args: ["obj"])
        XCTAssertTrue(gotObjJSON.contains("42"))
        let keysJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "keys", args: [])
        XCTAssertTrue(keysJSON.contains("obj"))
        let allJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "all", args: [])
        XCTAssertTrue(allJSON.contains("obj"))
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "remove", args: ["obj"])
        let afterRemoveJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "storage", method: "get", args: ["obj"])
        XCTAssertEqual(afterRemoveJSON, #""""#)

        // 2) settings: get, set, getAll (and secret redaction)
        try store.saveSettings(pluginID: "bridge-suite", values: ["api_secret": "top-secret-token", "theme_label": "琥珀默认"])
        let secretRead = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "settings", method: "get", args: ["api_secret"])
        XCTAssertEqual(secretRead, #""""#, "Secret settings must never be exposed to JS bridge")
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "settings", method: "set", args: ["theme_label", "深空琥珀"])
        let updatedSetting = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "settings", method: "get", args: ["theme_label"])
        XCTAssertEqual(updatedSetting, #""深空琥珀""#)
        let allSettingsJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "settings", method: "getAll", args: [])
        XCTAssertTrue(allSettingsJSON.contains("深空琥珀"))
        XCTAssertFalse(allSettingsJSON.contains("top-secret-token"))

        // 3) workspace: write, read, list, watch
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "workspace", method: "write", args: ["data/hello.txt", "Amber v3"])
        let readBack = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "workspace", method: "read", args: ["data/hello.txt"])
        XCTAssertEqual(readBack, #""Amber v3""#)
        let listedJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "workspace", method: "list", args: ["data/"])
        XCTAssertTrue(listedJSON.contains("data/hello.txt"))
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "workspace", method: "watch", args: ["data/"])

        // 4) commands: register, list
        _ = try await store.dispatchBridgeRPC(
            pluginID: "bridge-suite",
            namespace: "commands",
            method: "register",
            args: [["id": "cmd_hello", "title": "打招呼", "slash": "/hello-v3"]]
        )
        let cmdListJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "commands", method: "list", args: [])
        XCTAssertTrue(cmdListJSON.contains("cmd_hello"))
        XCTAssertTrue(store.activeSlashCommands.contains(where: { $0.id == "bridge-suite:cmd_hello" }))

        // 5) ui: notice, confirm, openView, openModal, closeModal
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "ui", method: "notice", args: ["保存成功", "info"])
        XCTAssertEqual(store.latestNotice?.message, "保存成功")
        store.onConfirmRequest = { title, _ in title == "确认操作" }
        let confirmedJSON = try await store.dispatchBridgeRPC(
            pluginID: "bridge-suite",
            namespace: "ui",
            method: "confirm",
            args: [["title": "确认操作", "message": "继续？"]]
        )
        XCTAssertEqual(confirmedJSON, "true")

        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "ui", method: "openView", args: ["main_panel"])
        XCTAssertEqual(openedView?.0, "bridge-suite")
        XCTAssertEqual(openedView?.1, "main_panel")

        _ = try await store.dispatchBridgeRPC(
            pluginID: "bridge-suite",
            namespace: "ui",
            method: "openModal",
            args: [["viewId": "modal_1", "title": "测试弹窗", "entry": "index.html"]]
        )
        XCTAssertEqual(store.activeModal?.pluginID, "bridge-suite")
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "ui", method: "closeModal", args: [])
        XCTAssertNil(store.activeModal)

        // 6) agent: getConversation, insertToComposer
        let convJSON = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "agent", method: "getConversation", args: [])
        XCTAssertTrue(convJSON.contains("conv-123"))
        _ = try await store.dispatchBridgeRPC(pluginID: "bridge-suite", namespace: "agent", method: "insertToComposer", args: ["测试填入输入框"])
        XCTAssertEqual(insertedPrompt, "测试填入输入框")

        // 7) Static asset loader (`amber-plugin://bridge-suite/index.html`) injects CSP & theme CSS tokens:
        let asset = try store.loadPluginStaticAsset(pluginID: "bridge-suite", rawPath: "index.html")
        let html = String(decoding: asset.data, as: UTF8.self)
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("--amber-bg-primary"))
    }

    // MARK: - 5. Path Traversal, Symlink & URL Scheme Static Asset Security

    func testWorkspacePathTraversalAndSymlinkEscapeAreBlocked() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("path-guard", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "path-guard",
          "name": "路径守卫测试",
          "version": "1.0.0",
          "description": "测试路径越界与符号链接防护",
          "permissions": ["ui.views", "workspace.read", "workspace.write"],
          "capabilities": {
            "workspaceReadPrefixes": ["safe/"],
            "workspaceWritePrefixes": ["safe/"]
          },
          "ui": {
            "views": [
              { "id": "v1", "slot": "workspace", "title": "V1", "entry": "index.html" }
            ]
          }
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: pkgDir.appendingPathComponent("main.js"))
        try Data("<html></html>".utf8).write(to: pkgDir.appendingPathComponent("index.html"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)

        // 1) '..' path traversal in workspace.read
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "path-guard",
                namespace: "workspace",
                method: "read",
                args: ["safe/../../outside.txt"]
            )
            XCTFail("Expected '..' path traversal to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("..") || error.localizedDescription.contains("工作区"))
        }

        // 2) Outside declared prefix in workspace.write
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "path-guard",
                namespace: "workspace",
                method: "write",
                args: ["other/file.txt", "nope"]
            )
            XCTFail("Expected write outside 'safe/' prefix to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权") || error.localizedDescription.contains("前缀"))
        }

        // 3) Symlink escape inside 'safe/' pointing outside workspace
        let outsideFile = rootDirectory.appendingPathComponent("outside-secret.txt")
        try Data("TOP_SECRET".utf8).write(to: outsideFile)
        let safeDir = workspaceDirectory.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safeDir, withIntermediateDirectories: true)
        let symlinkURL = safeDir.appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "path-guard",
                namespace: "workspace",
                method: "read",
                args: ["safe/leak.txt"]
            )
            XCTFail("Expected symlink escape to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("符号链接") || error.localizedDescription.contains("逃逸"))
        }

        // 4) Static asset loader '..' traversal rejected:
        XCTAssertThrowsError(try store.loadPluginStaticAsset(pluginID: "path-guard", rawPath: "../outside-secret.txt"))
    }

    // MARK: - 6. HTTP Domain Allowlist & HTTPS Enforcement

    func testHTTPDomainAllowlistAndHTTPSEnforcement() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("net-guard", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "net-guard",
          "name": "网络白名单测试",
          "version": "1.0.0",
          "description": "仅允许访问 api.github.com",
          "permissions": ["http:api.github.com"],
          "capabilities": {
            "networkDomains": ["api.github.com"]
          }
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)

        // Allowed domain over HTTPS:
        let resJSON = try await store.dispatchBridgeRPC(
            pluginID: "net-guard",
            namespace: "http",
            method: "fetch",
            args: ["https://api.github.com/zen"]
        )
        XCTAssertTrue(resJSON.contains("200"))

        // Plaintext HTTP must be rejected:
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "net-guard",
                namespace: "http",
                method: "fetch",
                args: ["http://api.github.com/zen"]
            )
            XCTFail("Expected http:// to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }

        // Unauthorized domain must be rejected:
        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "net-guard",
                namespace: "http",
                method: "fetch",
                args: ["https://evil.example.com/steal"]
            )
            XCTFail("Expected unauthorized domain to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("evil.example.com"))
        }
    }

    // MARK: - 7. Dynamic Agent Tool Registration & High-Risk Gate

    func testDynamicAgentToolRegistrationAndHighRiskApprovalGate() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("dyn-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "dyn-tools",
          "name": "动态工具插件",
          "version": "1.0.0",
          "description": "在 onload 中动态注册工具",
          "permissions": ["agent.tools", "workspace.write"],
          "capabilities": {
            "workspaceWritePrefixes": ["dyn/"]
          }
        }
        """
        let script = """
        function onload() {
          amber.agent.registerTool({
            name: "read_stat",
            description: "只读动态工具",
            effect: "pure",
            input_schema: { type: "object", properties: {}, additionalProperties: false },
            handler: function () {
              return { ok: true, mode: "pure_dynamic" };
            }
          });
          amber.agent.registerTool({
            name: "write_artifact",
            description: "高风险写入动态工具",
            effect: "sideEffect",
            input_schema: {
              type: "object",
              properties: { content: { type: "string" } },
              required: ["content"],
              additionalProperties: false
            },
            handler: function (input) {
              amber.workspace.write("dyn/out.txt", input.content);
              return { ok: true, written: true };
            }
          });
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(script.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)

        // Verify declarations and effects are projected into activeToolDeclarations & DesktopToolRegistry:
        let decls = store.activeToolDeclarations
        XCTAssertTrue(decls.contains { $0.name == "plugin__dyn-tools__read_stat" && !$0.needsApproval })
        XCTAssertTrue(decls.contains { $0.name == "plugin__dyn-tools__write_artifact" && $0.needsApproval })

        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__dyn-tools__read_stat"))
        XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__dyn-tools__write_artifact"))

        // Verify both tools execute properly when invoked:
        let readOut = try await store.executeTool(qualifiedName: "plugin__dyn-tools__read_stat", argumentsJSON: "{}")
        XCTAssertTrue(readOut.contains("pure_dynamic"))

        let writeOut = try await store.executeTool(
            qualifiedName: "plugin__dyn-tools__write_artifact",
            argumentsJSON: #"{"content":"dynamic tool write payload"}"#
        )
        XCTAssertTrue(writeOut.contains("written"))
        let savedText = try String(contentsOf: workspaceDirectory.appendingPathComponent("dyn/out.txt"), encoding: .utf8)
        XCTAssertEqual(savedText, "dynamic tool write payload")
    }

    // MARK: - 8. Persistent Lifecycle (onload / onunload) & Hot Reload

    func testLifecycleOnloadOnunloadAndHotReload() async throws {
        let store = makeStore()
        let pkgDir = rootDirectory.appendingPathComponent("hot-reload-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "hot-reload-demo",
          "name": "热重载测试插件",
          "version": "1.0.0",
          "description": "测试 onload/onunload 与 reloadPlugin",
          "dev_reload": true,
          "permissions": ["storage", "agent.tools"]
        }
        """
        let scriptV1 = """
        function onload() {
          amber.storage.set("lifecycle", "loaded_v1");
          amber.agent.registerTool({
            name: "ping",
            description: "Ping v1",
            effect: "pure",
            handler: function () { return { version: "v1" }; }
          });
        }
        function onunload() {
          amber.storage.set("unloaded_flag", "yes");
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(scriptV1.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        _ = try store.importPlugin(from: pkgDir, approvePermissions: true)
        XCTAssertEqual(store.readPluginStorage(pluginID: "hot-reload-demo")["lifecycle"], "loaded_v1")
        let outV1 = try await store.executeTool(qualifiedName: "plugin__hot-reload-demo__ping", argumentsJSON: "{}")
        XCTAssertTrue(outV1.contains("v1"))

        // Update installed main.js to v2 and trigger reloadPlugin(id:):
        let installedMain = pluginsDirectory.appendingPathComponent("hot-reload-demo/main.js")
        let scriptV2 = """
        function onload() {
          amber.storage.set("lifecycle", "loaded_v2");
          amber.agent.registerTool({
            name: "ping",
            description: "Ping v2",
            effect: "pure",
            handler: function () { return { version: "v2" }; }
          });
        }
        function onunload() {
          amber.storage.set("unloaded_flag", "yes_from_v2");
        }
        """
        try Data(scriptV2.utf8).write(to: installedMain, options: .atomic)
        try store.reloadPlugin(id: "hot-reload-demo")

        XCTAssertEqual(store.readPluginStorage(pluginID: "hot-reload-demo")["unloaded_flag"], "yes")
        XCTAssertEqual(store.readPluginStorage(pluginID: "hot-reload-demo")["lifecycle"], "loaded_v2")
        let outV2 = try await store.executeTool(qualifiedName: "plugin__hot-reload-demo__ping", argumentsJSON: "{}")
        XCTAssertTrue(outV2.contains("v2"))
    }

    // MARK: - 9. v2 Backward Compatibility Regression

    func testV2PluginBackwardCompatibility() async throws {
        let store = makeStore()
        let v2Dir = rootDirectory.appendingPathComponent("legacy_v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)

        let manifest = """
        {
          "schema": "amber.plugin.v2",
          "id": "legacy_v2",
          "name": "旧版 v2 插件",
          "version": "2.0.0",
          "description": "不带 permissions 数组的 v2 插件",
          "capabilities": {
            "networkDomains": [],
            "workspaceReadPrefixes": ["v2notes/"],
            "workspaceWritePrefixes": ["v2notes/"]
          },
          "tools": [
            {
              "name": "echo_v2",
              "description": "测试 v2 工具兼容",
              "effect": "sideEffect",
              "entry": "echoV2",
              "input_schema": {
                "type": "object",
                "properties": { "msg": { "type": "string" } },
                "required": ["msg"],
                "additionalProperties": false
              }
            }
          ]
        }
        """
        let script = """
        function echoV2(input) {
          amber.workspace.write("v2notes/test.txt", input.msg);
          return { ok: true, echo: amber.workspace.read("v2notes/test.txt") };
        }
        """
        try Data(manifest.utf8).write(to: v2Dir.appendingPathComponent("plugin.json"))
        try Data(script.utf8).write(to: v2Dir.appendingPathComponent("main.js"))

        // v2 plugin imports without requiring v3 permission approval:
        let id = try store.importPlugin(from: v2Dir, approvePermissions: false)
        XCTAssertEqual(id, "legacy_v2")
        let output = try await store.executeTool(
            qualifiedName: "plugin__legacy_v2__echo_v2",
            argumentsJSON: #"{"msg":"v2 works seamlessly"}"#
        )
        XCTAssertTrue(output.contains("v2 works seamlessly"))
    }

    // MARK: - 10. End-to-End `examples/plugins/kanban-board` Example Plugin Verification

    func testKanbanBoardExamplePluginEndToEnd() async throws {
        let store = makeStore()
        let candidateRoots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        ]
        let repoRoot = try XCTUnwrap(candidateRoots.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("examples/plugins/kanban-board/plugin.json").path)
        })
        let kanbanSourceDir = repoRoot.appendingPathComponent("examples/plugins/kanban-board", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kanbanSourceDir.appendingPathComponent("plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kanbanSourceDir.appendingPathComponent("index.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kanbanSourceDir.appendingPathComponent("board.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kanbanSourceDir.appendingPathComponent("styles.css").path))

        // 1) Inspect and import kanban-board
        let plan = try store.inspectPluginPackage(at: kanbanSourceDir)
        XCTAssertEqual(plan.manifest.id, "kanban-board")
        XCTAssertTrue(plan.manifest.isV3)
        let importedID = try store.importPlugin(from: kanbanSourceDir, approvePermissions: true)
        XCTAssertEqual(importedID, "kanban-board")

        // Verify custom WebView views are projected:
        XCTAssertTrue(store.activeCustomViews.contains { $0.id == "kanban-board:kanban_main" && $0.slot == .workspace })
        XCTAssertTrue(store.activeCustomViews.contains { $0.id == "kanban-board:kanban_sidebar" && $0.slot == .rightSidebar })

        // Verify onload initialized kanban/board.json and kanban/BOARD.md in the workspace:
        let boardJSONURL = workspaceDirectory.appendingPathComponent("kanban/board.json")
        let boardMDURL = workspaceDirectory.appendingPathComponent("kanban/BOARD.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: boardJSONURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boardMDURL.path))

        // 2) Add a new card via agent tool `plugin__kanban-board__kanban_add_card`
        let addOut = try await store.executeTool(
            qualifiedName: "plugin__kanban-board__kanban_add_card",
            argumentsJSON: #"{"title":"验证 Kanban 拖拽与持久化","description":"E2E 自动化验证","column":"todo","priority":"high","tags":["e2e","v3"]}"#
        )
        let addResult = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(addOut.utf8)) as? [String: Any])
        XCTAssertEqual(addResult["ok"] as? Bool, true)
        let addedCard = try XCTUnwrap(addResult["card"] as? [String: Any])
        let addedCardID = try XCTUnwrap(addedCard["id"] as? String)

        // 3) Move the card to 'in_progress' via `plugin__kanban-board__kanban_move_card`
        let moveOut = try await store.executeTool(
            qualifiedName: "plugin__kanban-board__kanban_move_card",
            argumentsJSON: #"{"card_id":"\#(addedCardID)","target_column":"in_progress","position":0}"#
        )
        XCTAssertTrue(moveOut.contains("in_progress"))

        // 4) Update the card via `plugin__kanban-board__kanban_update_card`
        let updateOut = try await store.executeTool(
            qualifiedName: "plugin__kanban-board__kanban_update_card",
            argumentsJSON: #"{"card_id":"\#(addedCardID)","title":"验证 Kanban 拖拽与持久化（已更新）"}"#
        )
        XCTAssertTrue(updateOut.contains("已更新"))

        // 5) Verify workspace JSON and Markdown reflect the moved & updated card
        let markdownText = try String(contentsOf: boardMDURL, encoding: .utf8)
        XCTAssertTrue(markdownText.contains("验证 Kanban 拖拽与持久化（已更新）"))
        XCTAssertTrue(markdownText.contains("#e2e"))

        // 6) Delete the card via `plugin__kanban-board__kanban_delete_card`
        let deleteOut = try await store.executeTool(
            qualifiedName: "plugin__kanban-board__kanban_delete_card",
            argumentsJSON: #"{"card_id":"\#(addedCardID)"}"#
        )
        XCTAssertTrue(deleteOut.contains(addedCardID))
    }

    // MARK: - 11. Scoped v3 Workspace Tokens & Unapproved Disk-Dropped v3 Gate

    func testScopedWorkspaceTokensAndUnapprovedDiskPluginGate() async throws {
        let store = makeStore()

        // Part A: v3 scoped `workspace.read:<prefix>` / `workspace.write:<prefix>` without legacy capabilities
        let scopedDir = rootDirectory.appendingPathComponent("scoped-ws", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedDir, withIntermediateDirectories: true)
        let scopedManifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "scoped-ws",
          "name": "前缀隔离测试",
          "version": "1.0.0",
          "description": "仅通过 v3 token 声明 notes 目录读写",
          "permissions": ["workspace.read:notes", "workspace.write:notes"]
        }
        """
        try Data(scopedManifest.utf8).write(to: scopedDir.appendingPathComponent("plugin.json"))
        try Data("function onload() {}".utf8).write(to: scopedDir.appendingPathComponent("main.js"))

        let plan = try store.inspectPluginPackage(at: scopedDir)
        XCTAssertTrue(plan.permissions.allSatisfy { $0.summary.contains("notes") })
        _ = try store.importPlugin(from: scopedDir, approvePermissions: true)

        _ = try await store.dispatchBridgeRPC(
            pluginID: "scoped-ws",
            namespace: "workspace",
            method: "write",
            args: ["notes/ok.md", "scoped-ok"]
        )
        let readScoped = try await store.dispatchBridgeRPC(
            pluginID: "scoped-ws",
            namespace: "workspace",
            method: "read",
            args: ["notes/ok.md"]
        )
        XCTAssertEqual(readScoped, #""scoped-ok""#)

        let secretURL = workspaceDirectory.appendingPathComponent("other/secret.md")
        try FileManager.default.createDirectory(at: secretURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("TOP_SECRET".utf8).write(to: secretURL)

        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "scoped-ws",
                namespace: "workspace",
                method: "read",
                args: ["other/secret.md"]
            )
            XCTFail("Expected read outside 'notes/' to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权") || error.localizedDescription.contains("前缀"))
        }

        do {
            _ = try await store.dispatchBridgeRPC(
                pluginID: "scoped-ws",
                namespace: "workspace",
                method: "write",
                args: ["other/escape.md", "nope"]
            )
            XCTFail("Expected write outside 'notes/' to be denied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权") || error.localizedDescription.contains("前缀"))
        }

        // Part B: Unapproved third-party v3 plugin dropped directly into pluginsDirectory
        let droppedDir = pluginsDirectory.appendingPathComponent("disk-drop", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedDir, withIntermediateDirectories: true)
        let droppedManifest = """
        {
          "manifest_version": 3,
          "schema": "amber.plugin.v3",
          "id": "disk-drop",
          "name": "未审批落盘插件",
          "version": "1.0.0",
          "description": "未经导入审批不得自动执行 onload 或挂载视图",
          "permissions": ["storage", "agent.tools", "ui.views"],
          "ui": {
            "views": [
              { "id": "side_panel", "slot": "right_sidebar", "title": "侧栏小组件", "entry": "sidebar.html" }
            ]
          }
        }
        """
        let droppedScript = """
        function onload() {
          amber.storage.set("booted", "yes");
          amber.agent.registerTool({
            name: "disk_ping",
            description: "Ping",
            effect: "pure",
            handler: function () { return { ok: true }; }
          });
        }
        """
        try Data(droppedManifest.utf8).write(to: droppedDir.appendingPathComponent("plugin.json"))
        try Data(droppedScript.utf8).write(to: droppedDir.appendingPathComponent("main.js"))
        try Data("<html><body>sidebar</body></html>".utf8).write(to: droppedDir.appendingPathComponent("sidebar.html"))

        try store.setPluginEnabled("feishu_calendar", enabled: false)
        store.reload()
        XCTAssertEqual(store.approvedPermissions(for: "disk-drop"), [])
        XCTAssertNil(store.readPluginStorage(pluginID: "disk-drop")["booted"])
        XCTAssertFalse(store.activeToolDeclarations.contains { $0.name == "plugin__disk-drop__disk_ping" })
        XCTAssertTrue(store.activeInspectorCustomViews.isEmpty)
        XCTAssertFalse(store.hasInspectorPluginItems)

        store.approvePluginPermissions(pluginID: "disk-drop", permissions: ["storage", "agent.tools", "ui.views"])
        XCTAssertEqual(store.readPluginStorage(pluginID: "disk-drop")["booted"], "yes")
        XCTAssertTrue(store.activeToolDeclarations.contains { $0.name == "plugin__disk-drop__disk_ping" })
        XCTAssertTrue(store.activeInspectorCustomViews.contains { $0.id == "disk-drop:side_panel" })
        XCTAssertTrue(store.hasInspectorPluginItems)

        store.revokePluginPermissions(pluginID: "disk-drop")
        XCTAssertFalse(store.activeToolDeclarations.contains { $0.name == "plugin__disk-drop__disk_ping" })
        XCTAssertTrue(store.activeInspectorCustomViews.isEmpty)
        XCTAssertFalse(store.hasInspectorPluginItems)
    }
}

private final class MockV3PluginHTTPTransport: DesktopPluginHTTPTransport, @unchecked Sendable {
    func send(request: URLRequest) async throws -> (Data, Int) {
        let urlString = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        let body = #"{"ok":true,"url":"\#(urlString)","method":"\#(method)"}"#
        return (Data(body.utf8), 200)
    }
}
