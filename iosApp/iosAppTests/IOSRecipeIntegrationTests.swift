import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Phase 1 Wave B2 integration tests (§15 Phase 1 acceptance 2-6):
/// the production `recipe__*` route, mutation-step approval pause/resume with
/// a durable checkpoint, `recipe_import` promotion, lease pinning and the
/// round-by-round hot-reload canary.
///
/// The foreground Adapter is exercised with a scripted provider so import,
/// approval, registry refresh, lazy exposure and execution all cross the same
/// production round boundaries as a real chat run.
@MainActor
final class IOSRecipeIntegrationTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    func testPrimitiveCatalogMatchesExecutableRecipeRoutes() {
        for supported in [
            "workspace_file_read",
            "tools_list",
            "skill_validate",
            "ios_shell_execute",
            "mcp_call",
            "provider_config_status",
            "theme_pack_status",
        ] {
            XCTAssertNotNil(
                IOSDynamicToolRegistry.primitiveCatalogEntry(for: supported),
                "\(supported) has a real recipe adapter"
            )
        }

        for rejected in [
            "skill_import",
            "provider_config_apply",
            "theme_pack_import",
            "recipe_import",
            "generate_image",
            "mcp__unknown__missing",
            "wm_eval",
            "wm_site_memory",
        ] {
            XCTAssertNil(
                IOSDynamicToolRegistry.primitiveCatalogEntry(for: rejected),
                "\(rejected) must fail validation instead of changing semantics at runtime"
            )
        }
    }

    func testMalformedRecipeReportsFieldInValidationAndImportWithoutWrites() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let workspace = makeWorkspaceStore(root: root)
        let service = IOSRecipeToolService(
            workspaceStore: workspace,
            recipeStore: store,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            refreshRegistry: { nil }
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: listingRecipeJSON(version: "1.0.0")
        ) as? [String: Any])
        object["steps"] = [["id": "list", "tool": "tools_list"]]
        let missingArguments = try JSONSerialization.data(withJSONObject: object)
        object["steps"] = [["id": "list", "tool": "tools_list", "arguments": [:]]]
        object["inputs"] = ["query": ["type": "string"]]
        let wrongInputType = try JSONSerialization.data(withJSONObject: object)
        let before = directorySnapshot(store.recipesDirectory)
        for (data, path) in [(missingArguments, "steps[0].arguments"), (wrongInputType, "inputs.query")] {
            try await seedWorkspaceRecipe(
                workspace: workspace, json: data,
                workspacePath: "/workspace/recipes/invalid/recipe.json"
            )
            let args = #"{"workspace_path":"/workspace/recipes/invalid/recipe.json"}"#
            let result = await service.execute(toolName: "recipe_validate", arguments: args)
            let parsed = try XCTUnwrap(parse(result))
            XCTAssertEqual(parsed["ok"] as? Bool, false, result)
            XCTAssertEqual(parsed["path"] as? String, path, result)
            XCTAssertEqual(parsed["code"] as? String, "invalidManifestJSON", result)
            XCTAssertThrowsError(try service.prepareRecipeImport(arguments: args)) { error in
                XCTAssertEqual((error as? IOSRecipeValidationIssue)?.path, path)
                XCTAssertTrue(error.localizedDescription.contains(path))
            }
            XCTAssertEqual(IOSRecipeValidator.validate(
                data: data, catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
            ).issues.first?.path, path)
        }
        XCTAssertEqual(directorySnapshot(store.recipesDirectory), before)
    }

    func testRecipeLifecycleSeparatesInstalledPackagesFromEnabledCatalog() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let hash = try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))

        XCTAssertEqual(store.listInstalledRecipes().map(\.package.name), ["catalog_probe"])
        XCTAssertTrue(store.isRecipeEnabled(name: "catalog_probe"))
        let enabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(enabledSnapshot.recipeTools.map(\.toolId), ["recipe__catalog_probe"])

        let disabled = try store.setRecipeEnabled(
            name: "catalog_probe",
            enabled: false,
            expectedHash: hash
        )
        XCTAssertTrue(disabled.changed)
        XCTAssertEqual(store.listInstalledRecipes().map(\.isEnabled), [false])
        let disabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(disabledSnapshot.recipeTools.isEmpty)
        XCTAssertGreaterThan(disabledSnapshot.revision, enabledSnapshot.revision)

        XCTAssertThrowsError(try store.setRecipeEnabled(
            name: "catalog_probe",
            enabled: true,
            expectedHash: "stale"
        ))

        _ = try store.setRecipeEnabled(name: "catalog_probe", enabled: true, expectedHash: hash)
        let reenabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(reenabledSnapshot.recipeTools.map(\.toolId), ["recipe__catalog_probe"])

        _ = try store.deleteRecipe(name: "catalog_probe", expectedHash: hash)
        XCTAssertTrue(store.listInstalledRecipes().isEmpty)
        let deletedSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(deletedSnapshot.recipeTools.isEmpty)
    }

    func testRecipeLifecycleToolsAreDeclaredWithExpectedRisk() {
        XCTAssertEqual(IOSRecipeToolCatalog.toolNames, [
            "recipes_list", "recipe_validate", "recipe_import",
            "recipe_enable", "recipe_disable", "recipe_delete",
        ])
        for name in IOSRecipeToolCatalog.toolNames {
            XCTAssertNotNil(ToolKt.iosToolDeclaration(name: name), "missing declaration for \(name)")
        }
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipes_list", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipe_validate", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipe_delete", input: "{}"), .sideEffect)
    }

    func testPluginPackageRegistersMultipleToolsOnlyAfterExplicitEnable() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let files = try pluginFiles(version: "1.0.0")
        let preparation = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: preparation.candidate.hash
        )
        XCTAssertFalse(receipt.enabled, "new agent-authored plugins install disabled")

        let registry = IOSDynamicToolRegistry(baseDirectory: root)
        let disabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(disabledSnapshot.recipeTools.isEmpty)
        _ = try store.setPluginEnabled(
            id: "workspace_kit",
            enabled: true,
            expectedHash: receipt.hash
        )
        let snapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(
            snapshot.recipeTools.map(\.toolId).sorted(),
            ["plugin__workspace_kit__count_tools", "plugin__workspace_kit__list_tools"]
        )
        XCTAssertEqual(snapshot.recipeDeclarations().map(\.name).sorted(), snapshot.recipeTools.map(\.toolId).sorted())
        XCTAssertTrue(snapshot.recipeTools.allSatisfy { $0.pluginId == "workspace_kit" })

        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )
        bridge.exposeToolNames(names: ["plugin__workspace_kit__list_tools"])
        let call = makeRecipeToolCall(name: "plugin__workspace_kit__list_tools", input: "{}")
        let (_, dao) = makeDatabase(root: root)
        let runId = "plugin-execute-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let result = await executeRecipeCall(
            runtime: makeRuntime(root: root, ledger: IOSAgentRunLedger(dao: dao)),
            toolCall: call,
            snapshot: snapshot,
            bridge: bridge,
            runId: runId
        )
        guard case .completed(let messages) = result else {
            return XCTFail("expected plugin workflow completion, got \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try parse(output)
        XCTAssertEqual(parsed?["ok"] as? Bool, true, output)
    }

    func testPluginCapabilityBrokerRejectsUndeclaredPathDomainAndWebAction() throws {
        let broker = IOSPluginCapabilityBroker(
            pluginId: "safe_plugin",
            primitiveTools: ["workspace_file_read", "scrape_web", "wm_click"],
            capabilities: IOSPluginCapabilities(
                workspaceReadPrefixes: ["/workspace/plugin-data"],
                networkDomains: ["example.com"],
                webMountActions: []
            )
        )
        XCTAssertNil(broker.authorize(
            tool: "workspace_file_read",
            argumentsJSON: #"{"path":"/workspace/plugin-data/a.txt"}"#
        ))
        XCTAssertNotNil(broker.authorize(
            tool: "workspace_file_read",
            argumentsJSON: #"{"path":"/workspace/private/a.txt"}"#
        ))
        XCTAssertNotNil(broker.authorize(
            tool: "scrape_web",
            argumentsJSON: #"{"url":"https://evil.example.org/a"}"#
        ))
        XCTAssertNotNil(broker.authorize(tool: "wm_click", argumentsJSON: "{}"))
        XCTAssertNotNil(broker.authorize(tool: "calendar_event_create", argumentsJSON: "{}"))
    }

    func testPluginCapabilityBrokerFailsClosedForObjectIdsAndHostlessNetwork() {
        let broker = IOSPluginCapabilityBroker(
            pluginId: "safe_plugin",
            primitiveTools: ["workspace_file_read", "workspace_file_list", "workspace_file_move", "scrape_web"],
            capabilities: IOSPluginCapabilities(
                workspaceReadPrefixes: ["/workspace/plugin-data"],
                workspaceWritePrefixes: ["/workspace/plugin-data"],
                networkDomains: ["example.com"]
            )
        )
        XCTAssertNotNil(broker.authorize(
            tool: "workspace_file_read",
            argumentsJSON: #"{"file_id":"opaque-id"}"#
        ))
        XCTAssertNotNil(broker.authorize(tool: "workspace_file_list", argumentsJSON: "{}"))
        XCTAssertNotNil(broker.authorize(
            tool: "workspace_file_move",
            argumentsJSON: #"{"path":"/workspace/plugin-data/a","destination_path":"/workspace/private/a"}"#
        ))
        XCTAssertNotNil(broker.authorize(tool: "scrape_web", argumentsJSON: #"{"query":"hostless"}"#))
        XCTAssertNil(broker.authorize(
            tool: "scrape_web",
            argumentsJSON: #"{"url":"https://docs.example.com/a"}"#
        ))
    }

    func testPublicPluginRejectsPrivilegedPrimitivesAmbiguousIdsAndHiddenFiles() throws {
        let privileged = try IOSRecipeManifest.decode(singleStepRecipeJSON(
            name: "terminal_probe",
            tool: IOSAmberShellToolCatalog.executeToolName,
            arguments: ["command": "true"]
        ))
        let manifest = IOSPluginManifest(
            id: "safe_plugin",
            name: "Safe Plugin",
            version: "1.0.0",
            description: "Must reject privileged tools.",
            tools: [IOSPluginToolManifest(name: "terminal_probe", recipe: "recipes/terminal.json")]
        )
        let validation = IOSPluginValidator.validate(
            manifest: manifest,
            recipes: ["recipes/terminal.json": privileged],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        )
        XCTAssertFalse(validation.isValid)

        let listing = try IOSRecipeManifest.decode(listingRecipeJSON(version: "1.0.0", name: "safe_tool"))
        let ambiguous = IOSPluginManifest(
            id: "safe__plugin",
            name: "Ambiguous",
            version: "1.0.0",
            description: "Must reject ambiguous separators.",
            tools: [IOSPluginToolManifest(name: "safe_tool", recipe: "recipes/safe.json")]
        )
        XCTAssertFalse(IOSPluginValidator.validate(
            manifest: ambiguous,
            recipes: ["recipes/safe.json": listing],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        ).isValid)

        var hidden = try pluginFiles(version: "1.0.0")
        hidden["assets/.secret"] = Data("secret".utf8)
        XCTAssertThrowsError(try IOSPluginFileStore(baseDirectory: tempRoot()).preparePlugin(files: hidden))
    }

    func testPluginInvalidPathIsZeroWriteAndPermissionExpansionDisablesUpdate() throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        var unsafe = try pluginFiles(version: "1.0.0")
        unsafe["../escape"] = Data()
        XCTAssertThrowsError(try store.preparePlugin(files: unsafe))
        XCTAssertTrue(store.listInstalledPlugins().isEmpty)

        let v1 = try pluginFiles(version: "1.0.0")
        let p1 = try store.preparePlugin(files: v1)
        let r1 = try store.applyPlugin(files: v1, expectedBaseHash: nil, expectedCandidateHash: p1.candidate.hash)
        XCTAssertFalse(store.canRollbackPlugin(id: "workspace_kit"))
        _ = try store.setPluginEnabled(id: "workspace_kit", enabled: true, expectedHash: r1.hash)

        let v2 = try pluginFiles(version: "2.0.0", readPrefixes: ["/workspace", "/workspace/private"])
        let p2 = try store.preparePlugin(files: v2)
        XCTAssertTrue(p2.permissionExpanded)
        let r2 = try store.applyPlugin(
            files: v2,
            expectedBaseHash: r1.hash,
            expectedCandidateHash: p2.candidate.hash
        )
        XCTAssertFalse(r2.enabled, "permission expansion must require a separate enable approval")
        XCTAssertTrue(store.canRollbackPlugin(id: "workspace_kit"))
        let rollback = try store.rollbackPlugin(id: "workspace_kit", expectedCurrentHash: r2.hash)
        XCTAssertEqual(rollback.hash, r1.hash)
        XCTAssertTrue(rollback.enabled)
        XCTAssertFalse(store.canRollbackPlugin(id: "workspace_kit"))
    }

    func testPluginManagementToolsAreDeclared() {
        for name in IOSPluginToolCatalog.toolNames {
            XCTAssertNotNil(ToolKt.iosToolDeclaration(name: name), "missing declaration for \(name)")
        }
        XCTAssertFalse(ToolKt.iosToolDeclaration(name: "plugin_import")?.allowsAutoApproval ?? true)
        XCTAssertFalse(ToolKt.iosToolDeclaration(name: "plugin_export")?.allowsAutoApproval ?? true)
        XCTAssertFalse(ToolKt.iosToolDeclaration(name: "plugin_restore")?.allowsAutoApproval ?? true)
    }

    func testAgentAuthoredPluginCanTestApproveActivateAndCallAfterReload() async throws {
        let root = tempRoot()
        let workspace = makeWorkspaceStore(root: root)
        let registry = IOSDynamicToolRegistry(baseDirectory: root)
        let store = IOSPluginFileStore(baseDirectory: root)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "plugin-authoring-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger, workspaceStore: workspace, recipeRegistry: registry)
        let example = IOSPluginDevelopmentSDK.javascriptExample()
        let directory = try XCTUnwrap(example["workspace_directory"] as? String)
        let files = try XCTUnwrap(example["files"] as? [String: Any])
        for (path, value) in files {
            let data = try (value as? String).map { Data($0.utf8) }
                ?? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try await seedWorkspaceRecipe(workspace: workspace, json: data, workspacePath: "\(directory)/\(path)")
        }
        let service = IOSPluginToolService(workspaceStore: workspace, pluginStore: store, refreshRegistry: { await registry.refresh() })
        let validation = await service.execute(toolName: "plugin_validate", arguments: IOSWorkspaceStore.json(["workspace_directory": directory]))
        XCTAssertEqual(try parse(validation)?["valid"] as? Bool, true, validation)

        var testArguments = try XCTUnwrap(example["test"] as? [String: Any])
        testArguments["workspace_directory"] = directory
        let testCall = makeRecipeToolCall(name: "plugin_test", input: IOSWorkspaceStore.json(testArguments))
        let tested = await executeRecipeCall(runtime: runtime, toolCall: testCall, snapshot: nil, bridge: nil, runId: runId)
        guard case .completed(let testMessages) = tested else { return XCTFail("试运行未完成：\(tested)") }
        let testOutput = try XCTUnwrap(toolOutputText(in: testMessages, toolCallId: testCall.toolCallId))
        let testPayload = try XCTUnwrap(parse(testOutput))
        XCTAssertEqual(testPayload["ok"] as? Bool, true, testOutput)
        XCTAssertEqual(testPayload["expected_match"] as? Bool, true, testOutput)
        XCTAssertEqual(testPayload["registered"] as? Bool, false)
        let hash = try XCTUnwrap(testPayload["candidate_hash"] as? String)
        XCTAssertTrue(store.listInstalledPlugins().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pluginsDirectory.path))

        let importCall = makeRecipeToolCall(name: "plugin_import", input: IOSWorkspaceStore.json([
            "workspace_directory": directory, "expected_candidate_hash": hash, "enable": true,
        ]))
        let imported = await executeRecipeCall(runtime: runtime, toolCall: importCall, snapshot: nil, bridge: nil, runId: runId)
        guard case .waitingForApproval(.recipe(let request)) = imported,
              case .recipeImport(let preview) = request.payload else { return XCTFail("安装应等待一次明确审批。") }
        XCTAssertTrue(preview.activationNotice.contains("安装并启用"))
        XCTAssertTrue(store.listInstalledPlugins().isEmpty)
        let approved = await resolveRecipeApproval(
            runtime: runtime, ledger: ledger, request: request, decision: .approve, toolCall: importCall, runId: runId
        )
        guard case .resumed(let importMessages) = approved else { return XCTFail("安装审批未恢复：\(approved)") }
        let importOutput = try XCTUnwrap(toolOutputText(in: importMessages, toolCallId: importCall.toolCallId))
        XCTAssertEqual(try parse(importOutput)?["enabled"] as? Bool, true, importOutput)

        // A new registry reconstructs tools from disk, as on a later App launch.
        let reloaded = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: root).refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(from: IosToolExposureBridge(tools: fullIosDeclarations()), snapshot: reloaded)
        let search = bridge.executeToolSearch(argumentsJson: #"{"query":"plugin__text_metrics__summarize"}"#)
        XCTAssertTrue((try parse(search)?["expanded_tools"] as? [String] ?? []).contains("plugin__text_metrics__summarize"), search)
        let call = makeRecipeToolCall(name: "plugin__text_metrics__summarize", input: #"{"texts":[" a ","a","b"]}"#)
        let execution = await executeRecipeCall(runtime: runtime, toolCall: call, snapshot: reloaded, bridge: bridge, runId: runId)
        guard case .completed(let messages) = execution else { return XCTFail("注册工具未执行：\(execution)") }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let result = try XCTUnwrap(try parse(output)?["result"] as? [String: Any])
        XCTAssertEqual(result["count"] as? Int, 3)
        XCTAssertEqual(result["unique"] as? [String], ["a", "b"])

        testArguments["expected_result"] = ["count": 0, "unique": []] as [String: Any]
        let mismatch = makeRecipeToolCall(name: "plugin_test", input: IOSWorkspaceStore.json(testArguments))
        let mismatchResult = await executeRecipeCall(runtime: runtime, toolCall: mismatch, snapshot: reloaded, bridge: bridge, runId: runId)
        guard case .completed(let mismatchMessages) = mismatchResult else { return XCTFail("预期不匹配应返回测试失败。") }
        let mismatchOutput = try XCTUnwrap(toolOutputText(in: mismatchMessages, toolCallId: mismatch.toolCallId))
        XCTAssertEqual(try parse(mismatchOutput)?["ok"] as? Bool, false, mismatchOutput)
        XCTAssertEqual(store.listInstalledPlugins().first?.health.consecutiveFailures, 0)
        XCTAssertTrue(store.isPluginEnabled(id: "text_metrics"))

        try await seedWorkspaceRecipe(workspace: workspace, json: Data("return {};".utf8), workspacePath: "\(directory)/scripts/summarize.js")
        XCTAssertThrowsError(try service.preparePluginImport(arguments: importCall.input)) { error in
            XCTAssertEqual(error as? IOSPluginFileStoreError, .candidateChanged)
        }
        XCTAssertEqual(try store.readLivePlugin(id: "text_metrics").hash, hash)
    }

    func testCandidateCommandApprovalExecutesPinnedScriptAndInputWithoutInstalling() async throws {
        let root = tempRoot()
        let (executor, workspace, _) = makeWorkspaceExecutor(root: root)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "plugin-command-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor, workspaceStore: workspace)
        let example = IOSPluginDevelopmentSDK.commandExample()
        let directory = try XCTUnwrap(example["workspace_directory"] as? String)
        for (path, value) in try XCTUnwrap(example["files"] as? [String: Any]) {
            let data = try (value as? String).map { Data($0.utf8) }
                ?? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try await seedWorkspaceRecipe(workspace: workspace, json: data, workspacePath: "\(directory)/\(path)")
        }
        var args = try XCTUnwrap(example["test"] as? [String: Any])
        args["workspace_directory"] = directory
        let call = makeRecipeToolCall(name: "plugin_test", input: IOSWorkspaceStore.json(args))
        let trial = await executeRecipeCall(runtime: runtime, toolCall: call, snapshot: nil, bridge: nil, runId: runId)
        guard case .waitingForApproval(.recipe(let request)) = trial,
              case .pluginInvocation(let payload) = request.payload else { return XCTFail("本地命令试跑必须经过执行审批。") }
        XCTAssertEqual(payload.effectClass, .sideEffect)
        // The approval owns the candidate bytes, not the mutable Workspace entry.
        try await seedWorkspaceRecipe(workspace: workspace, json: Data("echo changed".utf8), workspacePath: "\(directory)/scripts/unique.sh")
        let approved = await resolveRecipeApproval(runtime: runtime, ledger: ledger, request: request, decision: .approve, toolCall: call, runId: runId)
        guard case .resumed(let messages) = approved else { return XCTFail("命令审批未恢复：\(approved)") }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, true, output)
        XCTAssertEqual(parsed["expected_match"] as? Bool, true, output)
        XCTAssertEqual(parsed["result"] as? String, "a\nb\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: IOSPluginFileStore(baseDirectory: root).pluginsDirectory.path))
    }

    func testPluginRecognizesAmberShellUnknownOutcomeInFinishedMessages() {
        let runtime = makeRuntime(root: tempRoot(), ledger: IOSRunEventLogLedger(log: IOSRunEventLog()))
        let call = UIMessagePart.Tool(
            toolCallId: "command-unknown", toolName: "plugin__unique_lines__deduplicate", input: "{}",
            output: [UIMessagePart.Text(
                text: #"{"ok":false,"status":"unknown_after_action","may_have_applied":true}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        XCTAssertTrue(runtime.isPluginOutcomeUnknown(
            in: [makeAssistantMessage(parts: [call])], toolCallId: call.toolCallId
        ))
    }

    func testCommandNonZeroExitsAutomaticallyQuarantinePlugin() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let example = IOSPluginDevelopmentSDK.commandExample()
        var files: [String: Data] = [:]
        for (path, value) in try XCTUnwrap(example["files"] as? [String: Any]) {
            files[path] = try (value as? String).map { Data($0.utf8) }
                ?? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        files["scripts/unique.sh"] = Data("command-that-does-not-exist".utf8)
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(files: files, expectedBaseHash: nil, expectedCandidateHash: prepared.candidate.hash)
        _ = try store.setPluginEnabled(id: "unique_lines", enabled: true, expectedHash: receipt.hash)
        let registry = IOSDynamicToolRegistry(baseDirectory: root)
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let (executor, workspace, _) = makeWorkspaceExecutor(root: root)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor, workspaceStore: workspace, recipeRegistry: registry)

        for attempt in 0..<IOSPluginHealthSnapshot.quarantineThreshold {
            let runId = "command-failure-\(attempt)"
            try await seedDurableRun(runId, dao: dao)
            let call = makeRecipeToolCall(name: "plugin__unique_lines__deduplicate", input: #"{"text":"a"}"#)
            let result = await executeRecipeCall(runtime: runtime, toolCall: call, snapshot: snapshot, bridge: nil, runId: runId)
            guard case .waitingForApproval(.recipe(let request)) = result else {
                return XCTFail("命令调用应等待审批。")
            }
            let resolution = await resolveRecipeApproval(runtime: runtime, ledger: ledger, request: request, decision: .approve, toolCall: call, runId: runId)
            guard case .resumed(let messages) = resolution else { return XCTFail("命令审批未恢复。") }
            let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
            XCTAssertEqual(try parse(output)?["status"] as? String, "failed", output)
            XCTAssertEqual(try parse(output)?["exit_code"] as? Int, 127, output)
        }

        let installed = try XCTUnwrap(store.listInstalledPlugins().first)
        XCTAssertEqual(installed.health.consecutiveFailures, IOSPluginHealthSnapshot.quarantineThreshold)
        XCTAssertTrue(installed.health.isQuarantined)
        let refreshed = try unwrapSnapshot(await registry.refresh())
        XCTAssertFalse(refreshed.recipeTools.contains { $0.pluginId == "unique_lines" })
    }

    func testPluginHealthQuarantinesAfterThreeFailuresAndKeepsBoundedDiagnostics() throws {
        let root = tempRoot()
        let health = IOSPluginHealthStore(baseDirectory: root)
        let id = "health_kit"
        let hash = "hash-v1"

        for index in 0..<60 {
            _ = health.recordFailure(
                pluginId: id,
                packageHash: hash,
                toolId: "plugin__health_kit__probe",
                kind: index.isMultiple(of: 2) ? .timeout : .schema,
                detail: String(repeating: "x", count: 900)
            )
        }
        let quarantined = health.snapshot(pluginId: id, packageHash: hash)
        XCTAssertTrue(quarantined.isQuarantined)
        XCTAssertEqual(quarantined.diagnostics.count, 50)
        XCTAssertTrue(quarantined.diagnostics.allSatisfy { $0.detail.count <= 500 })

        _ = health.recordSuccess(pluginId: id, packageHash: hash)
        XCTAssertTrue(
            health.snapshot(pluginId: id, packageHash: hash).isQuarantined,
            "success must not silently clear an explicit quarantine"
        )
        _ = health.restore(pluginId: id, packageHash: hash)
        XCTAssertFalse(health.snapshot(pluginId: id, packageHash: hash).isQuarantined)
        XCTAssertEqual(health.snapshot(pluginId: id, packageHash: hash).consecutiveFailures, 0)
        XCTAssertFalse(
            health.snapshot(pluginId: id, packageHash: "hash-v2").isQuarantined,
            "a package update must not inherit the previous version's faults"
        )
    }

    func testPluginHealthRemainsQuarantinedInProcessWhenJournalWriteFails() throws {
        let blockedRoot = tempRoot().appendingPathComponent("blocked-root")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let health = IOSPluginHealthStore(baseDirectory: blockedRoot)
        let id = "volatile_health_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let hash = "hash-v1"
        defer { health.remove(pluginId: id) }

        for _ in 0..<IOSPluginHealthSnapshot.quarantineThreshold {
            _ = health.recordFailure(
                pluginId: id,
                packageHash: hash,
                toolId: "plugin__volatile__probe",
                kind: .timeout,
                detail: "timeout"
            )
        }

        XCTAssertTrue(
            health.snapshot(pluginId: id, packageHash: hash).isQuarantined,
            "a transient disk failure must not re-expose the plugin in the current process"
        )
    }

    func testPluginQuarantineRemovesCatalogUntilExplicitRestore() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let files = try pluginFiles(version: "1.0.0")
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "workspace_kit", enabled: true, expectedHash: receipt.hash)
        let health = IOSPluginHealthStore(baseDirectory: root)
        for _ in 0..<IOSPluginHealthSnapshot.quarantineThreshold {
            _ = health.recordFailure(
                pluginId: "workspace_kit",
                packageHash: receipt.hash,
                toolId: "plugin__workspace_kit__list_tools",
                kind: .timeout,
                detail: "timeout"
            )
        }
        let registry = IOSDynamicToolRegistry(baseDirectory: root)
        let quarantinedSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(quarantinedSnapshot.recipeTools.isEmpty)
        XCTAssertEqual(store.listInstalledPlugins().first?.isConfiguredEnabled, true)
        XCTAssertEqual(store.listInstalledPlugins().first?.health.isQuarantined, true)

        _ = try store.restorePlugin(id: "workspace_kit", expectedHash: receipt.hash)
        let restored = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(restored.recipeTools.count, 2)
        XCTAssertTrue(store.listInstalledPlugins().first?.isEnabled == true)
    }

    func testPluginBackgroundWhitelistRequiresExplicitReadOnlyDeclarativeOrRemoteHandler() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let files = try pluginFiles(version: "1.0.0", backgroundAllowed: true)
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "workspace_kit", enabled: true, expectedHash: receipt.hash)
        let snapshot = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: root).refresh())
        XCTAssertEqual(snapshot.backgroundEligibleDescriptors.count, 2)
        XCTAssertTrue(snapshot.backgroundEligibleDescriptors.allSatisfy { descriptor in
            if case .recipe = descriptor.implementation { return true }
            return false
        })

        let bridge = IosToolExposureBridge(tools: snapshot.recipeDeclarations())
        let params = makeParams(tools: snapshot.recipeDeclarations())
        let runtime = makeRuntime(
            root: root,
            ledger: IOSRunEventLogLedger(log: IOSRunEventLog()),
            recipeRegistry: IOSDynamicToolRegistry(baseDirectory: root)
        )
        let executors = runtime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "background-plugin-\(UUID().uuidString)",
            toolExposureBridge: bridge,
            dynamicToolSnapshot: snapshot
        )
        XCTAssertEqual(Set(executors.keys), Set(snapshot.recipeTools.map(\.toolId)))
        let executable = RecipeUncheckedToolExecutorBox(
            try XCTUnwrap(executors["plugin__workspace_kit__list_tools"])
        )
        guard case .filled(let output) = await executable.execute(
            name: "plugin__workspace_kit__list_tools",
            arguments: "{}",
            isUserInitiated: false
        ) else {
            return XCTFail("eligible declarative plugin must execute in the process-local background handoff")
        }
        XCTAssertEqual(try parse(output)?["ok"] as? Bool, true, output)
        XCTAssertTrue(
            runtime.backgroundToolExecutors(
                providerSetting: makeProviderSetting(),
                params: params,
                runId: "cold-background-plugin",
                toolExposureBridge: bridge,
                dynamicToolSnapshot: nil
            ).keys.allSatisfy { !$0.hasPrefix("plugin__") },
            "cold-restored name-only handoffs must fail closed"
        )

        let scriptRoot = tempRoot()
        let scriptStore = IOSPluginFileStore(baseDirectory: scriptRoot)
        let scriptFiles = try scriptPluginFiles(backgroundAllowed: true)
        let scriptPrepared = try scriptStore.preparePlugin(files: scriptFiles)
        let scriptReceipt = try scriptStore.applyPlugin(
            files: scriptFiles,
            expectedBaseHash: nil,
            expectedCandidateHash: scriptPrepared.candidate.hash
        )
        _ = try scriptStore.setPluginEnabled(id: "script_kit", enabled: true, expectedHash: scriptReceipt.hash)
        let scriptSnapshot = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: scriptRoot).refresh())
        XCTAssertTrue(scriptSnapshot.backgroundEligibleDescriptors.isEmpty)
        let scriptParams = makeParams(tools: scriptSnapshot.recipeDeclarations())
        XCTAssertTrue(
            makeRuntime(root: scriptRoot, ledger: IOSRunEventLogLedger(log: IOSRunEventLog()))
                .backgroundToolExecutors(
                    providerSetting: makeProviderSetting(),
                    params: scriptParams,
                    runId: "background-js-plugin",
                    dynamicToolSnapshot: scriptSnapshot
                )
                .keys.allSatisfy { !$0.hasPrefix("plugin__") }
        )
    }

    func testPluginDirectoryMetadataRejectsInsecureLinksAndInvalidAge() {
        let manifest = IOSPluginManifest(
            id: "directory_kit",
            name: "Directory Kit",
            version: "1.0.0",
            description: "Directory metadata validation.",
            tools: [IOSPluginToolManifest(
                name: "lookup",
                remote: IOSPluginRemoteManifest(
                    kind: .openapi,
                    url: "https://api.example.com/lookup",
                    method: "GET"
                )
            )],
            capabilities: IOSPluginCapabilities(networkDomains: ["example.com"]),
            directory: IOSPluginDirectoryMetadata(
                publisher: "Publisher",
                homepageURL: "http://example.com",
                minimumAge: 15
            )
        )
        let validation = IOSPluginValidator.validate(
            manifest: manifest,
            recipes: [:],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        )
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.issues.contains { $0.contains("HTTPS") })
        XCTAssertTrue(validation.issues.contains { $0.contains("minimum_age") })

        let longName = IOSPluginManifest(
            id: "long_name_kit",
            name: String(repeating: "A", count: 81),
            version: "1.0.0",
            description: "Display-bound metadata validation.",
            tools: manifest.tools,
            capabilities: manifest.capabilities
        )
        XCTAssertTrue(IOSPluginValidator.validate(
            manifest: longName,
            recipes: [:],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        ).issues.contains { $0.contains("80") })
    }

    func testPluginDirectoryPolicyPersistsBoundedLocalBlockAndReportIntent() throws {
        let root = tempRoot()
        let store = IOSPluginDirectoryPolicyStore(baseDirectory: root)
        try store.setBlocked(pluginId: "directory_kit", blocked: true)
        for index in 0..<45 {
            try store.recordLocalReport(
                pluginId: "directory_kit",
                reason: "report-\(index)-" + String(repeating: "x", count: 400)
            )
        }

        let reloaded = IOSPluginDirectoryPolicyStore(baseDirectory: root).snapshot()
        XCTAssertTrue(reloaded.blockedPluginIds.contains("directory_kit"))
        XCTAssertEqual(reloaded.reports.count, 40)
        XCTAssertTrue(reloaded.reports.allSatisfy { $0.reason.count <= 240 })
        XCTAssertEqual(reloaded.reports.last?.pluginId, "directory_kit")
    }

    func testRestrictedJavaScriptPluginExecutesPinnedSourceAndValidatesOutput() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let files = try scriptPluginFiles()
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "script_kit", enabled: true, expectedHash: receipt.hash)
        let snapshot = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: root).refresh())
        let call = makeRecipeToolCall(
            name: "plugin__script_kit__greet",
            input: #"{"name":"Amber"}"#
        )
        let result = await executeRecipeCall(
            runtime: makeRuntime(root: root, ledger: IOSRunEventLogLedger(log: IOSRunEventLog())),
            toolCall: call,
            snapshot: snapshot,
            bridge: IosToolExposureBridge(tools: fullIosDeclarations()),
            runId: "script-plugin-\(UUID().uuidString)"
        )
        guard case .completed(let messages) = result else {
            return XCTFail("expected JS plugin completion, got \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let payload = try XCTUnwrap(parse(output))
        XCTAssertEqual(payload["ok"] as? Bool, true, output)
        let value = try XCTUnwrap(payload["result"] as? [String: Any])
        XCTAssertEqual(value["greeting"] as? String, "hi Amber")
        XCTAssertEqual(value["dynamic"] as? String, "undefined")

        let bad = makeRecipeToolCall(name: call.toolName, input: #"{"name":42}"#)
        let badResult = await executeRecipeCall(
            runtime: makeRuntime(root: root, ledger: IOSRunEventLogLedger(log: IOSRunEventLog())),
            toolCall: bad,
            snapshot: snapshot,
            bridge: nil,
            runId: "script-plugin-bad-\(UUID().uuidString)"
        )
        guard case .completed(let badMessages) = badResult else { return XCTFail("expected input failure") }
        let badOutput = try XCTUnwrap(toolOutputText(in: badMessages, toolCallId: bad.toolCallId))
        XCTAssertEqual(try parse(badOutput)?["status"] as? String, "failed")
    }

    func testRuntimeOutputSchemaFailuresAutomaticallyQuarantinePlugin() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        var files = try scriptPluginFiles()
        files["scripts/greet.js"] = Data(#"return "not-an-object";"#.utf8)
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "script_kit", enabled: true, expectedHash: receipt.hash)
        let registry = IOSDynamicToolRegistry(baseDirectory: root)
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let runtime = makeRuntime(
            root: root,
            ledger: IOSRunEventLogLedger(log: IOSRunEventLog()),
            recipeRegistry: registry
        )

        for attempt in 0..<IOSPluginHealthSnapshot.quarantineThreshold {
            let call = makeRecipeToolCall(
                name: "plugin__script_kit__greet",
                input: #"{"name":"Amber"}"#
            )
            let result = await executeRecipeCall(
                runtime: runtime,
                toolCall: call,
                snapshot: snapshot,
                bridge: nil,
                runId: "schema-quarantine-\(attempt)"
            )
            guard case .completed(let messages) = result else {
                return XCTFail("schema failure must close the tool call")
            }
            let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
            XCTAssertEqual(try parse(output)?["ok"] as? Bool, false)
        }

        let installed = try XCTUnwrap(store.listInstalledPlugins().first)
        XCTAssertTrue(installed.health.isQuarantined)
        XCTAssertTrue(installed.isConfiguredEnabled)
        XCTAssertFalse(installed.isEnabled)
        let refreshed = try unwrapSnapshot(await registry.refresh())
        XCTAssertFalse(refreshed.recipeTools.contains { $0.pluginId == "script_kit" })
    }

    func testRestrictedJavaScriptPluginApprovalDenialClosesWithToolResult() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let files = try sideEffectScriptPluginFiles()
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "writer_kit", enabled: true, expectedHash: receipt.hash)
        let snapshot = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: root).refresh())
        let (_, dao) = makeDatabase(root: root)
        let runId = "script-plugin-approval-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)
        let call = makeRecipeToolCall(
            name: "plugin__writer_kit__write_note",
            input: #"{"text":"hello"}"#
        )
        let result = await executeRecipeCall(
            runtime: runtime,
            toolCall: call,
            snapshot: snapshot,
            bridge: IosToolExposureBridge(tools: fullIosDeclarations()),
            runId: runId,
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: true,
                highRiskAutoApproveEnabled: false,
                execJavaScriptEnabled: false,
                webSearchEnabled: true,
                mcpEnabled: true
            )
        )
        guard case .waitingForApproval(.recipe(let request)) = result,
              case .pluginInvocation(let payload) = request.payload else {
            return XCTFail("expected plugin invocation approval, got \(result)")
        }
        XCTAssertEqual(payload.effectClass, .sideEffect)
        XCTAssertTrue(payload.capabilities.contains("workspace_file_write"))
        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .deny,
            toolCall: call,
            runId: runId
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("denial must resume with a terminal tool result")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        XCTAssertEqual(try parse(output)?["denied"] as? Bool, true, output)
    }

    func testRestrictedJavaScriptPluginCannotCatchCapabilityDenialAndReportSuccess() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        var files = try sideEffectScriptPluginFiles()
        files["scripts/write.js"] = Data(#"try { tools.workspace_file_write({path: "/workspace/outside/note.txt", content: input.text}); } catch (_) {} return { fake_success: true };"#.utf8)
        let prepared = try store.preparePlugin(files: files)
        let receipt = try store.applyPlugin(
            files: files,
            expectedBaseHash: nil,
            expectedCandidateHash: prepared.candidate.hash
        )
        _ = try store.setPluginEnabled(id: "writer_kit", enabled: true, expectedHash: receipt.hash)
        let snapshot = try unwrapSnapshot(await IOSDynamicToolRegistry(baseDirectory: root).refresh())
        let call = makeRecipeToolCall(
            name: "plugin__writer_kit__write_note",
            input: #"{"text":"hello"}"#
        )
        let autoApprovePolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true,
            execJavaScriptEnabled: false,
            webSearchEnabled: true,
            mcpEnabled: true
        )
        let result = await executeRecipeCall(
            runtime: makeRuntime(root: root, ledger: IOSRunEventLogLedger(log: IOSRunEventLog())),
            toolCall: call,
            snapshot: snapshot,
            bridge: IosToolExposureBridge(tools: fullIosDeclarations()),
            runId: "script-plugin-caught-denial-\(UUID().uuidString)",
            executionPolicy: autoApprovePolicy
        )
        guard case .completed(let messages) = result else { return XCTFail("expected terminal failure") }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let payload = try XCTUnwrap(parse(output))
        XCTAssertEqual(payload["ok"] as? Bool, false, output)
        XCTAssertEqual(payload["status"] as? String, "failed", output)
        XCTAssertNil(payload["fake_success"], output)
    }

    func testPluginRemoteDefinitionsAreFixedAndCapabilityScoped() throws {
        let openAPI = IOSPluginManifest(
            id: "remote_kit",
            name: "Remote Kit",
            version: "1.0.0",
            description: "Fixed endpoint.",
            tools: [IOSPluginToolManifest(
                name: "lookup",
                remote: IOSPluginRemoteManifest(kind: .openapi, url: "https://api.example.com/v1/lookup", method: "GET"),
                inputs: ["query": .string],
                output: .object
            )],
            capabilities: IOSPluginCapabilities(networkDomains: ["example.com"])
        )
        let valid = IOSPluginValidator.validate(
            manifest: openAPI,
            recipes: [:],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        )
        XCTAssertTrue(valid.isValid, valid.issues.joined(separator: " | "))
        XCTAssertEqual(valid.permissionEnvelope, .networkRead)

        let unsafe = IOSPluginManifest(
            id: "remote_bad",
            name: "Remote Bad",
            version: "1.0.0",
            description: "Wrong host.",
            tools: [IOSPluginToolManifest(
                name: "lookup",
                remote: IOSPluginRemoteManifest(kind: .openapi, url: "http://evil.example.org/x", method: "GET")
            )],
            capabilities: IOSPluginCapabilities(networkDomains: ["example.com"])
        )
        XCTAssertFalse(IOSPluginValidator.validate(
            manifest: unsafe,
            recipes: [:],
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        ).isValid)
    }

    func testSignedAmberPluginRejectsTamperingAndTrustDowngradeDisables() async throws {
        let root = tempRoot()
        let store = IOSPluginFileStore(baseDirectory: root)
        let rawFiles = try scriptPluginFiles(includeAsset: true)
        let canonical = try store.preparePlugin(files: rawFiles).candidate
        let key = Curve25519.Signing.PrivateKey()
        let archive = try IOSPluginArchiveCodec.encode(
            files: canonical.files,
            packageHash: canonical.hash,
            signingKey: key
        )
        let signed = try store.prepareArchive(data: archive)
        XCTAssertEqual(signed.preparation.candidateTrust.tier, .signed)
        let receipt = try store.applyPlugin(
            files: signed.files,
            expectedBaseHash: nil,
            expectedCandidateHash: signed.preparation.candidate.hash,
            trust: signed.preparation.candidateTrust
        )
        _ = try store.setPluginEnabled(id: "script_kit", enabled: true, expectedHash: receipt.hash)
        XCTAssertEqual(store.trustRecord(id: "script_kit").tier, .signed)

        let exported = try store.exportArchive(id: "script_kit")
        let secondRoot = tempRoot()
        let secondStore = IOSPluginFileStore(baseDirectory: secondRoot)
        let secondPrepared = try secondStore.prepareArchive(data: exported)
        XCTAssertEqual(secondPrepared.preparation.candidateTrust.tier, .signed)
        let secondReceipt = try secondStore.applyPlugin(
            files: secondPrepared.files,
            expectedBaseHash: nil,
            expectedCandidateHash: secondPrepared.preparation.candidate.hash,
            trust: secondPrepared.preparation.candidateTrust
        )
        _ = try secondStore.setPluginEnabled(
            id: "script_kit",
            enabled: true,
            expectedHash: secondReceipt.hash
        )
        try Data("changed after install".utf8).write(
            to: secondRoot
                .appendingPathComponent("plugins/script_kit/assets/note.txt")
        )
        XCTAssertEqual(secondStore.listInstalledPlugins().first?.isEnabled, false)
        let tamperedSnapshot = try unwrapSnapshot(
            await IOSDynamicToolRegistry(baseDirectory: secondRoot).refresh()
        )
        XCTAssertFalse(tamperedSnapshot.recipeTools.contains { $0.toolId == "plugin__script_kit__greet" })
        XCTAssertThrowsError(try secondStore.setPluginEnabled(
            id: "script_kit",
            enabled: true,
            expectedHash: try secondStore.readLivePlugin(id: "script_kit").hash
        )) {
            XCTAssertEqual($0 as? IOSPluginFileStoreError, .signatureInvalid)
        }

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var members = try XCTUnwrap(object["files"] as? [[String: Any]])
        let index = try XCTUnwrap(members.firstIndex { $0["path"] as? String == "assets/note.txt" })
        members[index]["dataBase64"] = Data("tampered".utf8).base64EncodedString()
        object["files"] = members
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try IOSPluginFileStore(baseDirectory: tempRoot()).prepareArchive(data: tampered)) {
            XCTAssertEqual($0 as? IOSPluginFileStoreError, .signatureInvalid)
        }

        var wrongKeyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var wrongSignature = try XCTUnwrap(wrongKeyObject["signature"] as? [String: Any])
        let wrongPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        wrongSignature["publicKeyBase64"] = wrongPublicKey.base64EncodedString()
        wrongSignature["keyId"] = String(
            SHA256.hash(data: wrongPublicKey)
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
        wrongKeyObject["signature"] = wrongSignature
        let wrongKeyArchive = try JSONSerialization.data(withJSONObject: wrongKeyObject, options: [.sortedKeys])
        XCTAssertThrowsError(try IOSPluginFileStore(baseDirectory: tempRoot()).prepareArchive(data: wrongKeyArchive)) {
            XCTAssertEqual($0 as? IOSPluginFileStoreError, .signatureInvalid)
        }

        let missingTrustRoot = tempRoot()
        let missingTrustStore = IOSPluginFileStore(baseDirectory: missingTrustRoot)
        let unsignedPrepared = try missingTrustStore.preparePlugin(files: rawFiles)
        let unsignedReceipt = try missingTrustStore.applyPlugin(
            files: rawFiles,
            expectedBaseHash: nil,
            expectedCandidateHash: unsignedPrepared.candidate.hash
        )
        _ = try missingTrustStore.setPluginEnabled(
            id: "script_kit",
            enabled: true,
            expectedHash: unsignedReceipt.hash
        )
        try FileManager.default.removeItem(
            at: missingTrustRoot.appendingPathComponent("plugins/.metadata/script_kit.json")
        )
        XCTAssertEqual(missingTrustStore.listInstalledPlugins().first?.isEnabled, false)
        XCTAssertThrowsError(try missingTrustStore.setPluginEnabled(
            id: "script_kit",
            enabled: true,
            expectedHash: unsignedReceipt.hash
        )) {
            XCTAssertEqual($0 as? IOSPluginFileStoreError, .signatureInvalid)
        }

        let downgrade = try store.applyPlugin(
            files: canonical.files,
            expectedBaseHash: receipt.hash,
            expectedCandidateHash: receipt.hash
        )
        XCTAssertTrue(downgrade.permissionExpanded)
        XCTAssertFalse(downgrade.enabled)
        XCTAssertEqual(downgrade.trust.tier, .localUnsigned)
    }

    func testAmberPluginArchiveRejectsPathTraversalBeforeWriting() throws {
        let envelope: [String: Any] = [
            "schema": IOSPluginArchiveCodec.schema,
            "files": [[
                "path": "../plugin.json",
                "dataBase64": Data("{}".utf8).base64EncodedString(),
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let store = IOSPluginFileStore(baseDirectory: tempRoot())
        XCTAssertThrowsError(try store.prepareArchive(data: data))
        XCTAssertTrue(store.listInstalledPlugins().isEmpty)
    }

    func testCheckpointSaveReportsFailureBeforeApprovalCanPause() {
        let root = tempRoot()
        let blockingFile = root.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockingFile.path, contents: Data()))
        let store = IOSRecipeExecutionCheckpointStore(baseDirectory: blockingFile)
        let checkpoint = IOSRecipeExecutionCheckpoint(
            schemaVersion: IOSRecipeExecutionCheckpointStore.schemaVersion,
            toolCallId: "checkpoint-write-failure",
            recipeName: "checkpoint_probe",
            recipeVersion: "1.0.0",
            catalogRevision: 1,
            inputs: [:],
            stepOutputs: [:],
            completedSteps: [],
            nextStepIndex: 0,
            executionId: "execution-checkpoint-write-failure"
        )

        XCTAssertFalse(store.save(checkpoint))
    }

    // MARK: - Acceptance 2: hot-reload e2e canary (search → promote → call → final)

    func testRecipeStepTerminalFailurePropagatesDurabilityFailure() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await makeRegistry(store: store).refresh())
        let log = IOSRunEventLog()
        let ledger = IOSRunEventLogLedger(log: log)
        ledger.failTerminals = true
        let runtime = makeRuntime(root: root, ledger: ledger)
        let toolCall = makeRecipeToolCall(name: "recipe__catalog_probe", input: "{}")

        let result = await executeRecipeCall(
            runtime: runtime,
            toolCall: toolCall,
            snapshot: snapshot,
            bridge: IosToolExposureBridge(tools: fullIosDeclarations()),
            runId: "recipe-durability-\(UUID().uuidString)"
        )

        guard case .durabilityFailure(let message) = result else {
            return XCTFail("recipe step terminal failure must not become a normal tool output")
        }
        XCTAssertEqual(message, "tool result ledger write failed")
    }

    func testRecipePrimitiveFailureTerminalFailurePropagatesDurabilityFailure() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await makeRegistry(store: store).refresh())
        let ledger = IOSRunEventLogLedger(log: IOSRunEventLog())
        ledger.failTerminals = true
        let runtime = makeRuntime(root: root, ledger: ledger)
        let toolCall = makeRecipeToolCall(name: "recipe__catalog_probe", input: "{}")

        let result = await executeRecipeCall(
            runtime: runtime,
            toolCall: toolCall,
            snapshot: snapshot,
            bridge: nil,
            runId: "recipe-failed-step-durability-\(UUID().uuidString)"
        )

        guard case .durabilityFailure(let message) = result else {
            return XCTFail("failed recipe primitive must not hide a terminal ledger failure")
        }
        XCTAssertEqual(message, "tool result ledger write failed")
    }

    func testHotReloadCanarySearchPromoteCallResultRoundByRound() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "canary-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)

        // Round 1: the recipe is NOT published. The run bridge covers only the
        // static catalog; the scripted model searches for it and misses.
        let staticDeclarations = fullIosDeclarations()
        var bridge = IosToolExposureBridge(tools: staticDeclarations)
        let provider1 = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "tc-search-1", toolName: "tool_search",
                            input: #"{"query":"catalog_probe","limit":5}"#),
        ])
        let engine1 = IOSAgentToolEngine(
            provider: provider1,
            executors: ["tool_search": BridgeToolSearchExecutor(bridge: bridge)],
            configuration: .init(maxSteps: 1)
        )
        let r1 = await engine1.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("先找一下 catalog_probe 工具")],
            params: makeParams(tools: staticDeclarations),
            toolExposureBridge: bridge
        )
        XCTAssertFalse(
            Set(bridge.fullToolDeclarations().map(\.name)).contains("recipe__catalog_probe"),
            "round 1 must start without the recipe"
        )
        XCTAssertFalse(
            Set(provider1.recordedParams[0].tools.map(\.name)).contains("recipe__catalog_probe")
        )
        let search1 = try XCTUnwrap(toolOutputText(in: r1.messages, toolCallId: "tc-search-1"))
        XCTAssertTrue(toolSearchHitNames(search1).isEmpty, "round 1 search must miss: \(search1)")

        // Between rounds: promote + registry.refresh() → new revision; rebuild
        // the run bridge over the new snapshot (the Adapter seam does this
        // at the round boundary).
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let promotedSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertGreaterThan(promotedSnapshot.revision, 1)
        bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(from: bridge, snapshot: promotedSnapshot)
        XCTAssertTrue(
            Set(bridge.fullToolDeclarations().map(\.name)).contains("recipe__catalog_probe"),
            "after promotion the full catalog must contain the recipe"
        )
        XCTAssertFalse(
            Set(bridge.visibleTools().map(\.name)).contains("recipe__catalog_probe"),
            "the recipe stays default-deferred until tool_search exposes it"
        )

        // Round 2: the scripted model searches again → hit with descriptor +
        // version + permission summary + source=custom.recipe (no manifest
        // body); the search itself exposes the recipe for the NEXT round.
        let provider2 = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "tc-search-2", toolName: "tool_search",
                            input: #"{"query":"catalog_probe","limit":5}"#),
        ])
        let engine2 = IOSAgentToolEngine(
            provider: provider2,
            executors: ["tool_search": BridgeToolSearchExecutor(bridge: bridge)],
            configuration: .init(maxSteps: 1)
        )
        let r2 = await engine2.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("再找一次")],
            params: makeParams(tools: bridge.visibleTools()),
            toolExposureBridge: bridge
        )
        let search2 = try XCTUnwrap(toolOutputText(in: r2.messages, toolCallId: "tc-search-2"))
        let hit = try XCTUnwrap(searchHit(search2, name: "recipe__catalog_probe"))
        XCTAssertEqual(hit["version"] as? String, "1.0.0")
        XCTAssertEqual(hit["source"] as? String, "custom.recipe")
        XCTAssertEqual(hit["permission_summary"] as? String,
                       IOSDynamicToolRegistry.permissionSummary(for: .pure))
        XCTAssertNil(hit["manifest"], "search results must not carry the manifest body")
        XCTAssertTrue(
            Set(bridge.visibleTools().map(\.name)).contains("recipe__catalog_probe"),
            "the tool_search hit must expose the recipe for the next round"
        )

        // Round 3: the scripted model CALLS recipe__catalog_probe. The
        // executor routes through the REAL ChatToolRuntime recipe route with
        // the round's pinned snapshot; the step runs the REAL tools_list
        // primitive through the REAL bridge.
        let recipeExecutors: [String: any IOSToolExecutor] = [
            "tool_search": BridgeToolSearchExecutor(bridge: bridge),
            "recipe__catalog_probe": RecipeRouteExecutor(
                runtime: runtime,
                snapshot: promotedSnapshot,
                bridge: bridge,
                runId: runId
            ),
        ]
        let provider3 = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "tc-recipe-1", toolName: "recipe__catalog_probe", input: "{}"),
        ])
        let engine3 = IOSAgentToolEngine(
            provider: provider3,
            executors: recipeExecutors,
            configuration: .init(maxSteps: 1)
        )
        let r3 = await engine3.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("调用 catalog_probe")],
            params: makeParams(tools: bridge.visibleTools()),
            toolExposureBridge: bridge
        )
        let recipeOutput = try XCTUnwrap(toolOutputText(in: r3.messages, toolCallId: "tc-recipe-1"))
        let recipeResult = try XCTUnwrap(parse(recipeOutput))
        XCTAssertEqual(recipeResult["ok"] as? Bool, true, recipeOutput)
        XCTAssertEqual(recipeResult["status"] as? String, "completed")
        XCTAssertEqual(recipeResult["steps"] as? [String], ["list"])
        let outputs = try XCTUnwrap(recipeResult["outputs"] as? [String: Any])
        let toolCount = try XCTUnwrap(outputs["tool_count"] as? Int)
        XCTAssertGreaterThan(toolCount, 0, "the real tools_list total must flow into the recipe output")

        // Ledger: step-level Started/Finished with artifact attribution AND a
        // recipe-level Finished row with artifactId/artifactVersion.
        let rows = await ledgerRows(runId: runId, dao: dao)
        let stepStarted = rows.filter { $0.type == IOSToolCallLedgerClassifier.startedType }
        let stepFinished = rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
        XCTAssertEqual(stepStarted.count, 1, "one step Started")
        XCTAssertEqual(stepFinished.count, 2, "one step Finished + one recipe-level Finished")
        let finishedPayloads = rows
            .filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
            .compactMap { parsedPayload($0.payload) }
        let stepFinishedPayload = try XCTUnwrap(
            finishedPayloads.first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-recipe-") == true }
        )
        XCTAssertEqual(stepFinishedPayload["artifactId"] as? String, "recipe__catalog_probe")
        XCTAssertEqual(stepFinishedPayload["artifactVersion"] as? String, "1.0.0")
        XCTAssertEqual(stepFinishedPayload["outcomeKind"] as? String, "success")
        let recipeLevelPayload = try XCTUnwrap(
            finishedPayloads.first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true }
        )
        XCTAssertEqual(recipeLevelPayload["artifactId"] as? String, "recipe__catalog_probe")
        XCTAssertEqual(recipeLevelPayload["artifactVersion"] as? String, "1.0.0")
        XCTAssertEqual(recipeLevelPayload["outcomeKind"] as? String, "success")

        // Round 4: final text to a durable terminal; the recipe stays visible.
        let provider4 = ParamsRecordingProvider([assistantText("done")])
        let engine4 = IOSAgentToolEngine(
            provider: provider4,
            executors: recipeExecutors,
            configuration: .init(maxSteps: 1)
        )
        let r4 = await engine4.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("收尾")],
            params: makeParams(tools: bridge.visibleTools()),
            toolExposureBridge: bridge
        )
        XCTAssertEqual(r4.messages.last?.role, MessageRole.assistant)
        XCTAssertEqual(r4.messages.last?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertNil(r4.pendingApproval)
        XCTAssertFalse(r4.hitStepLimit)
        XCTAssertTrue(
            Set(provider4.recordedParams[0].tools.map(\.name)).contains("recipe__catalog_probe"),
            "the already-exposed recipe stays visible on later rounds"
        )
    }

    func testForegroundAdapterPublishesApprovedRecipeImportOnNextModelRound() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let workspace = makeWorkspaceStore(root: root)
        let runId = "adapter-hot-reload-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        try await seedWorkspaceRecipe(workspace: workspace, json: listingRecipeJSON(version: "1.0.0"))

        let initialSnapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: initialSnapshot
        )
        bridge.exposeToolNames(names: ["recipe_import"])
        let provider = ParamsRecordingProvider([
            toolCallMessage(
                toolCallId: "tc-adapter-import",
                toolName: "recipe_import",
                input: #"{"workspace_path":"/workspace/recipes/catalog_probe/recipe.json"}"#
            ),
            toolCallMessage(
                toolCallId: "tc-adapter-search",
                toolName: "tool_search",
                input: #"{"query":"catalog_probe","limit":5}"#
            ),
            toolCallMessage(
                toolCallId: "tc-adapter-recipe",
                toolName: "recipe__catalog_probe",
                input: "{}"
            ),
            assistantText("done"),
        ])
        let runtime = makeRuntime(
            root: root,
            ledger: ledger,
            workspaceStore: workspace,
            recipeRegistry: registry
        )
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: ledger)
        let request = ChatRunKernelAdapter.RunRequest(
            provider: provider,
            providerSetting: makeProviderSetting(),
            params: makeParams(tools: bridge.visibleTools()),
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            initialMessages: [userMessage("导入并运行 catalog_probe")],
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: initialSnapshot,
            recipeCatalogRefresh: { await registry.refresh() },
            maxToolResumeCount: 8,
            drainSteer: nil,
            mailboxDrain: nil,
            citationTracker: nil,
            prepareUploadMessages: nil,
            nestedToolRunner: nil,
            approvalDecider: { prompt in
                guard case .recipe(let request) = prompt,
                      case .recipeImport = request.payload else { return nil }
                return .approve
            }
        )

        let messages = await adapter.run(request)
        let imported = try store.readLiveRecipe(name: "catalog_probe")
        XCTAssertEqual(imported.version, "1.0.0")
        XCTAssertTrue(bridge.fullToolDeclarations().contains { $0.name == "recipe__catalog_probe" })
        XCTAssertTrue(bridge.visibleTools().contains { $0.name == "recipe__catalog_probe" })
        XCTAssertTrue(
            provider.recordedParams.dropFirst(2).contains { params in
                params.tools.contains { $0.name == "recipe__catalog_probe" }
            },
            "tool_search exposure must reach the immediately following provider round"
        )
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: "tc-adapter-recipe"))
        XCTAssertEqual(try parse(output)?["ok"] as? Bool, true, output)
        XCTAssertEqual(messages.last?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    // MARK: - Acceptance 3: lease pinning (v1 call keeps v1 despite promotion)

    func testLeasePinningV1CallCompletesWithPinnedManifestDespiteV2Promotion() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)
        let runId = "lease-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let v1Snapshot = try unwrapSnapshot(await registry.refresh())
        let v1Bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: v1Snapshot
        )

        // Promote v2 while the v1 snapshot is held.
        try apply(store: store, json: try listingRecipeV2JSON(version: "2.0.0"))
        let v2Snapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(v2Snapshot.recipeTools.first?.version, "2.0.0")

        // The pinned v1 call runs AFTER the promotion and still uses the v1
        // manifest: one step, not v2's two steps.
        let call = makeRecipeToolCall(name: "recipe__catalog_probe", input: "{}")
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: v1Snapshot, bridge: v1Bridge,
            runId: runId
        )
        guard case .completed(let messages) = result else {
            return XCTFail("expected completion, got \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["steps"] as? [String], ["list"],
                       "the v1 call must use the v1 (one-step) manifest, not v2")
        XCTAssertEqual(parsed["status"] as? String, "completed")

        let rows = await ledgerRows(runId: runId, dao: dao)
        let recipeLevel = try XCTUnwrap(
            rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
                .compactMap { parsedPayload($0.payload) }
                .first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true }
        )
        XCTAssertEqual(recipeLevel["artifactVersion"] as? String, "1.0.0",
                       "the recipe-level record attributes the run to the pinned v1")

        // The NEXT round acquires v2 (declaration reflects the promotion).
        XCTAssertEqual(v2Snapshot.recipeTools.first?.toolId, "recipe__catalog_probe")
    }

    // MARK: - Acceptance 4: stale base/candidate fail closed with zero writes

    func testStaleCandidateFailsClosedZeroWriteOnRecipeImportApproval() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let workspace = makeWorkspaceStore(root: root)
        let runtime = makeRuntime(root: root, ledger: ledger, workspaceStore: workspace)
        let runId = "stale-candidate-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try await seedWorkspaceRecipe(workspace: workspace, json: try listingRecipeJSON(version: "1.0.0"))
        let previewCall = makeRecipeToolCall(name: "recipe_import",
                                             input: #"{"workspace_path":"/workspace/recipes/catalog_probe/recipe.json"}"#)
        let previewResult = await executeRecipeCall(
            runtime: runtime, toolCall: previewCall, snapshot: nil, bridge: nil,
            runId: runId
        )
        guard case .waitingForApproval(.recipe(let request)) = previewResult,
              case .recipeImport(let payload) = request.payload else {
            return XCTFail("expected recipe import approval, got \(previewResult)")
        }
        let candidateHashAtPreview = payload.candidateHash

        // The candidate changes while the card is open.
        try await seedWorkspaceRecipe(workspace: workspace, json: try listingRecipeJSON(version: "1.0.1"))

        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .approve,
            toolCall: previewCall,
            runId: runId
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("expected resolved stale candidate failure, got \(resolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: previewCall.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["success"] as? Bool, false, output)
        XCTAssertEqual(parsed["code"] as? String, "stale_candidate")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.recipesDirectory.path),
            "a stale-candidate approval must write nothing"
        )
        XCTAssertNotEqual(candidateHashAtPreview, (try? store.prepareRecipe(recipeJSON: try listingRecipeJSON(version: "1.0.1")))?.candidate.hash)
    }

    func testStaleBaseFailsClosedOnRecipeImportApproval() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let workspace = makeWorkspaceStore(root: root)

        // v1 installed through the store (live base), then a v2 candidate in
        // Workspace whose preview pins base = v1.
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0", name: "base_stale"))
        let v1Hash = try store.readLiveRecipe(name: "base_stale").hash
        try await seedWorkspaceRecipe(
            workspace: workspace,
            json: try listingRecipeJSON(version: "2.0.0", name: "base_stale"),
            workspacePath: "/workspace/recipes/base_stale/recipe.json"
        )
        let service = IOSRecipeToolService(
            workspaceStore: workspace,
            recipeStore: store,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            refreshRegistry: { nil }
        )
        let prepared = try service.prepareRecipeImport(
            arguments: #"{"workspace_path":"/workspace/recipes/base_stale/recipe.json"}"#
        )
        XCTAssertEqual(prepared.preview.baseHash, v1Hash)

        // Live base changes after the preview.
        try apply(store: store, json: try listingRecipeJSON(version: "3.0.0", name: "base_stale"))
        let afterV3 = directorySnapshot(store.recipesDirectory)

        let result = try await service.applyPreparedRecipeImport(prepared)
        let parsed = try XCTUnwrap(parse(result))
        XCTAssertEqual(parsed["code"] as? String, "stale_base", result)
        XCTAssertEqual(
            directorySnapshot(store.recipesDirectory), afterV3,
            "a stale-base apply must not change the live package"
        )
        XCTAssertEqual(try store.readLiveRecipe(name: "base_stale").version, "3.0.0")
    }

    // MARK: - Acceptance 5: rollback → next round sees previous; in-flight not replaced

    func testRollbackNextRoundSeesPreviousAndInFlightCallNotReplaced() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)
        let runId = "rollback-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        _ = try unwrapSnapshot(await registry.refresh())
        try apply(store: store, json: try listingRecipeV2JSON(version: "2.0.0"))
        let v2Snapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(v2Snapshot.recipeTools.first?.version, "2.0.0")
        let v2Bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: v2Snapshot
        )

        // The in-flight v2 call completes BEFORE the rollback takes effect.
        let call = makeRecipeToolCall(name: "recipe__catalog_probe", input: "{}")
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: v2Snapshot, bridge: v2Bridge,
            runId: runId
        )
        guard case .completed(let messages) = result else {
            return XCTFail("expected completion, got \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["steps"] as? [String], ["list", "list_again"],
                       "the started v2 call must use the v2 manifest")
        let rows = await ledgerRows(runId: runId, dao: dao)
        let recipeLevel = try XCTUnwrap(
            rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
                .compactMap { parsedPayload($0.payload) }
                .first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true }
        )
        XCTAssertEqual(recipeLevel["artifactVersion"] as? String, "2.0.0",
                       "the in-flight v2 call is attributed to v2, never replaced")

        // Rollback publishes a NEW revision restoring v1; the next round sees
        // the previous version.
        let availability = try store.rollbackAvailability(name: "catalog_probe")
        guard case .available(let expectedManifest) = availability else {
            return XCTFail("expected rollback availability, got \(availability)")
        }
        _ = try store.rollbackRecipe(name: "catalog_probe", expectedManifest: expectedManifest)
        let rolledBack = try unwrapSnapshot(await registry.refresh())
        XCTAssertGreaterThan(rolledBack.revision, v2Snapshot.revision)
        XCTAssertEqual(rolledBack.recipeTools.first?.version, "1.0.0",
                       "the next round sees the previous version")
    }

    // MARK: - Acceptance 6: mutation step uses the existing approval machinery

    func testMutationStepDeniedStopsRecipeWithStructuredErrorAndLedgerDenial() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let (executor, workspace, _) = makeWorkspaceExecutor(root: root)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor, workspaceStore: workspace)
        let runId = "mutation-deny-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try apply(store: store, json: try mutatingRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )

        let call = makeRecipeToolCall(
            name: "recipe__digest_save",
            input: #"{"output_path":"/workspace/notes/out.md"}"#
        )
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge,
            runId: runId
        )
        guard case .waitingForApproval(.recipe(let request)) = result else {
            return XCTFail("expected step approval, got \(result)")
        }
        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .deny,
            toolCall: call,
            runId: runId,
            toolExposureBridge: bridge
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("expected denied recipe result, got \(resolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, false, output)
        XCTAssertEqual(parsed["step"] as? String, "save")
        XCTAssertNil(workspace.fileRecord(idOrPath: "/workspace/notes/out.md"),
                     "the denied step must never execute")
        let checkpointDir = root.appendingPathComponent("recipes/.checkpoints", isDirectory: true)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: checkpointDir.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "checkpoint must be removed on denial")

        // Phase 0 evidence: the denial must write a REAL approval_denied row
        // and the recipe-level Finished must carry the denied outcome. The
        // denial event is fire-and-forget in production (same tier as
        // Finished), so poll briefly for it.
        let rows = await waitForApprovalDenied(runId: runId, dao: dao)
        let denials = rows.filter { $0.type == IOSAgentRunLedger.approvalDeniedEventType }
        XCTAssertEqual(denials.count, 1, "approval_denied must be a real ledger event")
        let recipeLevel = try XCTUnwrap(
            rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
                .compactMap { parsedPayload($0.payload) }
                .first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true }
        )
        XCTAssertEqual(recipeLevel["outcomeKind"] as? String, "denied")
        XCTAssertEqual(recipeLevel["errorCode"] as? String, "step_denied")
        XCTAssertEqual(recipeLevel["artifactId"] as? String, "recipe__digest_save")
    }

    func testAutoHighRiskWebMountRecipePreflightsPayAndSubmitBeforeDispatch() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let webMountDefaults = UserDefaults(suiteName: "recipe-webmount-\(UUID().uuidString)")!
        let webMountRegistry = IOSWebMountRegistry(userDefaults: webMountDefaults)
        let webMountSettings = IOSWebMountSettings(userDefaults: webMountDefaults)
        webMountSettings.globalEnabled = true
        let site = try XCTUnwrap(webMountRegistry.site(id: "github"))
        webMountRegistry.setEnabled(id: site.id, enabled: true)
        let webMountRuntime = BackgroundFeatureRecipeWebMountRuntime(sessionId: "recipe-session")
        let controller = IOSWebMountController(
            registry: webMountRegistry,
            settings: webMountSettings,
            runtime: webMountRuntime,
            runtimeFactory: { BackgroundFeatureRecipeWebMountRuntime() },
            sessionDefaults: webMountDefaults
        )
        controller.sessionStore.tag(sessionId: webMountRuntime.snapshot.sessionId, site: site)

        let runId = "webmount-recipe-\(UUID().uuidString)"
        let conversationId = KotlinUuid.companion.random()
        try controller.sessionStore.acquireAgentControl(
            sessionId: webMountRuntime.snapshot.sessionId,
            runId: runId,
            conversationId: conversationId.toHexDashString()
        )
        let permissionStore = IOSPermissionStore(
            userDefaults: UserDefaults(suiteName: "recipe-webmount-perm-\(UUID().uuidString)")!
        )
        let webMountCapability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.webmount.browser" }
        )
        permissionStore.setPolicy(.autoApproveHighRisk, for: webMountCapability)
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            webMountController: controller
        )
        let executionPolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [
                webMountCapability.id: IOSAgentPermissionPolicy.autoApproveHighRisk.rawValue
            ],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )
        try apply(
            store: store,
            json: try webMountHighRiskRecipeJSON(
                version: "1.0.0",
                sessionId: webMountRuntime.snapshot.sessionId,
                snapshotId: "recipe-snapshot"
            )
        )
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )
        let call = makeRecipeToolCall(name: "recipe__webmount_checkout", input: "{}")
        let pending = pendingContext(
            for: call,
            runId: runId,
            conversationId: conversationId,
            executionPolicy: executionPolicy
        )
        let runtime = makeRuntime(
            root: root,
            ledger: IOSRunEventLogLedger(log: IOSRunEventLog()),
            localToolExecutor: executor
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: call),
            context: pending,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: snapshot
        )
        guard case .waitingForApproval(.recipe(let request)) = result,
              case .step(let payload) = request.payload else {
            return XCTFail("auto-high-risk payment/submit recipe must pause before dispatch, got \(result)")
        }
        XCTAssertEqual(payload.stepId, "pay_and_submit")
        XCTAssertEqual(payload.tool, "wm_click")
        XCTAssertTrue(request.reason.localizedCaseInsensitiveContains("pay or submit"))
        XCTAssertEqual(webMountRuntime.preflightCount, 1)
        XCTAssertEqual(webMountRuntime.dispatchCount, 0)
    }

    /// Checker-requested coverage (§10.3.5): a recipe with TWO mutation steps
    /// must pause once per mutation step — approving the first CONTINUES the
    /// recipe, which pauses again at the second (the Adapter's
    /// `pausedForNextStep` branch + the runtime's resumable loop), then
    /// completes on the second approval. Checkpoint is persisted at each
    /// pause and cleaned at the terminal.
    func testTwoMutationStepsPauseTwiceThenCompleteWithCleanCheckpointAndAttribution() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let (executor, workspace, permissionStore) = makeWorkspaceExecutor(root: root)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor, workspaceStore: workspace)
        let runId = "two-mutation-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try apply(store: store, json: try twoMutationRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )

        let call = makeRecipeToolCall(
            name: "recipe__double_save",
            input: #"{"path_a":"/workspace/notes/a.md","path_b":"/workspace/notes/b.md"}"#
        )
        let firstResult = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge,
            runId: runId
        )
        // First pause: step save_a (the pure list step ran without a card).
        guard case .waitingForApproval(.recipe(let firstRequest)) = firstResult,
              case .step(let firstPayload) = firstRequest.payload else {
            return XCTFail("expected first step approval, got \(firstResult)")
        }
        XCTAssertEqual(firstPayload.stepId, "save_a")
        XCTAssertEqual(firstPayload.tool, "workspace_file_write")
        let checkpointDir = root.appendingPathComponent("recipes/.checkpoints", isDirectory: true)
        XCTAssertEqual(checkpointFileCount(checkpointDir), 1,
                       "first pause must persist its checkpoint")

        var resumeCount = 0
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunResumed = {
            resumeCount += 1
            return true
        }

        // Approve save_a → the recipe must CONTINUE and pause AGAIN at save_b.
        let firstResolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: firstRequest,
            decision: .approve,
            toolCall: call,
            runId: runId,
            toolExposureBridge: bridge,
            callbacks: callbacks
        )
        guard case .rePause(.recipe(let secondRequest)) = firstResolution else {
            return XCTFail("approving the first mutation step must re-pause at the second, got \(firstResolution)")
        }
        guard case .step(let secondPayload) = secondRequest.payload else {
            return XCTFail("expected a second step approval, got \(secondRequest.payload)")
        }
        XCTAssertEqual(secondPayload.stepId, "save_b")
        XCTAssertEqual(secondPayload.tool, "workspace_file_write")
        XCTAssertEqual(checkpointFileCount(checkpointDir), 1,
                       "the second pause must refresh (not duplicate) the checkpoint")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.fileURL(for: try XCTUnwrap(
                    workspace.fileRecord(idOrPath: "/workspace/notes/a.md")
                )).path
            ),
            "the first approved step must have executed before the second pause"
        )

        let secondResolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: secondRequest,
            decision: .approve,
            toolCall: call,
            runId: runId,
            toolExposureBridge: bridge,
            callbacks: callbacks
        )
        guard case .resumed(let messages) = secondResolution else {
            return XCTFail("expected recipe completion after second approval, got \(secondResolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, true, output)
        XCTAssertEqual(parsed["status"] as? String, "completed")
        XCTAssertEqual(parsed["steps"] as? [String], ["list", "save_a", "save_b"])
        let outputs = try XCTUnwrap(parsed["outputs"] as? [String: Any])
        XCTAssertEqual(outputs["path_a_out"] as? String, "/workspace/notes/a.md")
        XCTAssertEqual(outputs["path_b_out"] as? String, "/workspace/notes/b.md")
        for path in ["/workspace/notes/a.md", "/workspace/notes/b.md"] {
            let record = try XCTUnwrap(workspace.fileRecord(idOrPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.fileURL(for: record).path),
                          "the approved step must have written \(path)")
        }

        // Terminal: the checkpoint is cleaned.
        XCTAssertEqual(checkpointFileCount(checkpointDir), 0,
                       "the checkpoint must be removed when the recipe completes")

        // Ledger attribution: per-step Started/Finished pairs + the recipe-level
        // Finished(completed) + the two finisher attempts (Started →
        // paused_for_approval for cycle 1, Started → completed for cycle 2).
        let rows = await ledgerRows(runId: runId, dao: dao)
        let started = rows.filter { $0.type == IOSToolCallLedgerClassifier.startedType }
        let finished = rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
        XCTAssertEqual(started.count, 5, "3 steps + 2 finisher Started")
        XCTAssertEqual(finished.count, 6, "3 step Finished + recipe-level Finished + 2 finisher Finished")
        let finishedPayloads = rows
            .filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
            .compactMap { parsedPayload($0.payload) }
        let stepAttributions = finishedPayloads.filter {
            ($0["toolCallId"] as? String)?.hasPrefix("recipe-recipe-") == true
        }
        XCTAssertEqual(stepAttributions.count, 3)
        for payload in stepAttributions {
            XCTAssertEqual(payload["artifactId"] as? String, "recipe__double_save")
            XCTAssertEqual(payload["artifactVersion"] as? String, "1.0.0")
            XCTAssertEqual(payload["outcomeKind"] as? String, "success")
        }
        let recipeLevel = try XCTUnwrap(
            finishedPayloads.first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true }
        )
        XCTAssertEqual(recipeLevel["artifactId"] as? String, "recipe__double_save")
        XCTAssertEqual(recipeLevel["artifactVersion"] as? String, "1.0.0")
        XCTAssertEqual(recipeLevel["outcomeKind"] as? String, "success")

        // Both approvals went through the recordToolApproval funnel: two
        // .allowed records for the recipe execution capability.
        let approvals = permissionStore.approvalRecords.filter {
            $0.capabilityId == "ios.agent.recipe_execution"
        }
        XCTAssertEqual(approvals.count, 2, "one allowed record per approved mutation step")
        XCTAssertTrue(approvals.allSatisfy { $0.action == .allowed })
        XCTAssertEqual(resumeCount, 2, "each approved mutation step must reclaim the durable run")
    }

    func testApplePrivateReadAndWriteRecipeStepsAlwaysPauseForApproval() async throws {
        let cases: [(name: String, tool: String, arguments: [String: Any], mutating: Bool)] = [
            ("health_reader", IOSHealthAgentToolCatalog.toolName, [:], false),
            ("calendar_writer", IOSAppleAgentToolCatalog.calendarEventCreate, [
                "title": "Review",
                "start": "2026-09-03T09:00:00+08:00",
                "end": "2026-09-03T10:00:00+08:00",
            ], true),
        ]

        for item in cases {
            let root = tempRoot()
            let store = makeStore(root: root)
            let registry = makeRegistry(store: store)
            let (_, dao) = makeDatabase(root: root)
            let ledger = IOSAgentRunLedger(dao: dao)
            let runtime = makeRuntime(root: root, ledger: ledger)
            let runId = "apple-gate-\(item.name)-\(UUID().uuidString)"
            try await seedDurableRun(runId, dao: dao)
            try apply(store: store, json: try singleStepRecipeJSON(
                name: item.name,
                tool: item.tool,
                arguments: item.arguments
            ))
            let snapshot = try unwrapSnapshot(await registry.refresh())
            let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
                from: IosToolExposureBridge(tools: fullIosDeclarations()),
                snapshot: snapshot
            )
            let call = makeRecipeToolCall(name: "recipe__\(item.name)", input: "{}")

            let result = await executeRecipeCall(
                runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge, runId: runId
            )
            guard case .waitingForApproval(.recipe(let request)) = result,
                  case .step(let payload) = request.payload else {
                return XCTFail("\(item.tool) must pause before touching Apple data, got \(result)")
            }
            XCTAssertEqual(payload.tool, item.tool)
            XCTAssertEqual(payload.effectClass == .sideEffect, item.mutating)
            XCTAssertTrue(request.reason.contains("Apple 数据"), request.reason)
        }
    }

    func testDisabledApplePrimitiveFailureIsNotReportedAsRecipeSuccess() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let (executor, _, permissionStore) = makeWorkspaceExecutor(root: root)
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capability(forToolName: IOSAppleAgentToolCatalog.calendarEventCreate)
        )
        permissionStore.setPolicy(.disabled, for: capability)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor)
        let runId = "apple-disabled-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        try apply(store: store, json: try singleStepRecipeJSON(
            name: "disabled_calendar",
            tool: IOSAppleAgentToolCatalog.calendarEventCreate,
            arguments: [
                "title": "Never created",
                "start": "2026-09-03T09:00:00+08:00",
                "end": "2026-09-03T10:00:00+08:00",
            ]
        ))
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )
        let call = makeRecipeToolCall(name: "recipe__disabled_calendar", input: "{}")
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge, runId: runId
        )
        guard case .waitingForApproval(.recipe(let request)) = result else {
            return XCTFail("private Apple write must pause first, got \(result)")
        }
        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .approve,
            toolCall: call,
            runId: runId,
            toolExposureBridge: bridge
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("expected terminal recipe result, got \(resolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, false, output)
        XCTAssertEqual(parsed["step"] as? String, "action")
        XCTAssertTrue(output.contains("未开启"), output)
    }

    // MARK: - recipe_import promotion through the approval card

    func testRecipeImportApprovalAppliesAndPublishesToRegistry() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let workspace = makeWorkspaceStore(root: root)
        let runtime = makeRuntime(root: root, ledger: ledger, workspaceStore: workspace)
        let runId = "import-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try await seedWorkspaceRecipe(workspace: workspace, json: try listingRecipeJSON(version: "1.0.0"))

        let highRiskKey = "app.amber.ios.highRiskAutoApprove"
        let previousHighRisk = UserDefaults.standard.object(forKey: highRiskKey)
        UserDefaults.standard.set(false, forKey: highRiskKey)
        defer {
            if let previousHighRisk {
                UserDefaults.standard.set(previousHighRisk, forKey: highRiskKey)
            } else {
                UserDefaults.standard.removeObject(forKey: highRiskKey)
            }
        }

        let call = makeRecipeToolCall(
            name: "recipe_import",
            input: #"{"workspace_path":"/workspace/recipes/catalog_probe/recipe.json"}"#
        )
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: nil, bridge: nil,
            runId: runId
        )
        guard case .waitingForApproval(.recipe(let request)) = result,
              case .recipeImport(let payload) = request.payload else {
            return XCTFail("expected recipe import approval, got \(result)")
        }
        XCTAssertEqual(payload.mutationKind, .new)
        XCTAssertNil(payload.baseHash)
        XCTAssertEqual(payload.stepsSummary, ["list → tools_list"])
        XCTAssertEqual(payload.effectClassRawValue, IOSToolEffectClass.pure.rawValue)

        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .approve,
            toolCall: call,
            runId: runId
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("expected approved recipe import result, got \(resolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["success"] as? Bool, true, output)
        XCTAssertEqual(parsed["name"] as? String, "catalog_probe")
        XCTAssertEqual(parsed["version"] as? String, "1.0.0")

        // The store published the package and the registry serves it.
        let live = try store.readLiveRecipe(name: "catalog_probe")
        XCTAssertEqual(live.version, "1.0.0")
        let published = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(published.recipeTools.first?.toolId, "recipe__catalog_probe")
    }

    // MARK: - Stale snapshot call + handoff fail-closed

    func testStaleSnapshotCallFailsClosedWithStructuredError() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)
        let runId = "stale-call-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        // A snapshot that does not declare the recipe (rolled back / stale).
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let emptySnapshot = IOSDynamicToolCatalogSnapshot(
            revision: 99,
            recipeTools: [],
            contentHash: IOSDynamicToolRegistry.emptyContentHash
        )
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: emptySnapshot
        )
        let call = makeRecipeToolCall(name: "recipe__catalog_probe", input: "{}")
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: emptySnapshot, bridge: bridge,
            runId: runId
        )
        guard case .completed(let messages) = result else {
            return XCTFail("stale calls must fail closed, not crash, got \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, false, output)
        XCTAssertTrue((parsed["reason"] as? String)?.contains("不在当前工具目录中") == true, output)

        // Nothing was executed and no recipe-level record was written.
        let rows = await ledgerRows(runId: runId, dao: dao)
        XCTAssertTrue(
            rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
                .compactMap { parsedPayload($0.payload) }
                .first { ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true } == nil,
            "a stale-snapshot call must not record a recipe run"
        )
    }

    func testInFlightRecipeCallClassifiesSideEffectAndBackgroundHasNoRecipeExecutor() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)

        // Fail-closed handoff classification: an in-flight recipe__* call is
        // sideEffect (never auto-handed-off/replayed, §16.2).
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName("recipe__catalog_probe", input: "{}"),
            .sideEffect
        )
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName("recipe_import", input: "{}"),
            .sideEffect
        )

        // The background bridge never declares recipes (B1 handoff filter), so
        // the background executor table must not register recipe names either;
        // recipe_import is denied in the background.
        try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await registry.refresh())
        var declarations = fullIosDeclarations()
        declarations.append(contentsOf: snapshot.recipeDeclarations())
        if let importDeclaration = ToolKt.iosToolDeclaration(name: "recipe_import") {
            declarations.append(importDeclaration)
        }
        let params = makeParams(tools: declarations)
        let executors = runtime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "bg-run-\(UUID().uuidString)",
            executionPolicy: manualApprovalPolicy
        )
        XCTAssertNil(executors["recipe__catalog_probe"],
                     "background must not register recipe executors (B1 filter)")
        XCTAssertNotNil(executors["recipe_import"],
                        "recipe_import is declared-but-denied in the background")

        // Drive the denial through the REAL background path (the engine is
        // nonisolated, exactly how production invokes background executors).
        let engine = IOSAgentToolEngine(
            provider: ParamsRecordingProvider([
                toolCallMessage(toolCallId: "tc-bg-import", toolName: "recipe_import", input: "{}"),
            ]),
            executors: executors,
            configuration: .init(maxSteps: 1)
        )
        let r = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("后台导入")],
            params: params,
            toolExposureBridge: nil
        )
        let output = try XCTUnwrap(toolOutputText(in: r.messages, toolCallId: "tc-bg-import"))
        XCTAssertTrue(
            output.contains("需要回到 App 确认"),
            "recipe_import must be denied in the background without high-risk auto-approve: \(output)"
        )
    }

    /// 收口 Slice A 红测试：Workspace primitive 的 ok:false 输出在 recipe step
    /// 语义里必须是诚实的 step 失败（§10.3.6 stop-on-failure），而不是「步骤
    /// 成功、输出恰好是失败 JSON」的 false-green——否则真实路径错误永远不产生
    /// typed evidence，差分评测无从谈起（plan §2.2）。
    func testWorkspaceStepFailureInsideRecipeIsHonestStepFailureNotFalseGreen() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let (executor, workspace, _) = makeWorkspaceExecutor(root: root)
        let runtime = makeRuntime(root: root, ledger: ledger, localToolExecutor: executor, workspaceStore: workspace)
        let runId = "ws-honest-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)

        try apply(store: store, json: try readMissingRecipeJSON(version: "1.0.0"))
        let snapshot = try unwrapSnapshot(await registry.refresh())
        let bridge = IOSDynamicToolBridgeRebuilder.rebuiltBridge(
            from: IosToolExposureBridge(tools: fullIosDeclarations()),
            snapshot: snapshot
        )

        let call = makeRecipeToolCall(
            name: "recipe__missing_reader",
            input: #"{"path":"missing/nope.txt"}"#
        )
        let result = await executeRecipeCall(
            runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge,
            runId: runId
        )
        // 现行 catalog 把 workspace_file_read 归 sideEffect——先过审批卡，
        // 批准后读取必然缺失的文件。
        guard case .waitingForApproval(.recipe(let request)) = result else {
            return XCTFail("expected step approval, got \(result)")
        }
        let resolution = await resolveRecipeApproval(
            runtime: runtime,
            ledger: ledger,
            request: request,
            decision: .approve,
            toolCall: call,
            runId: runId,
            toolExposureBridge: bridge
        )
        guard case .resumed(let messages) = resolution else {
            return XCTFail("expected failed recipe result after approved read, got \(resolution)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, false,
                       "workspace ok:false 必须冒泡为 recipe 级失败：\(output)")
        XCTAssertEqual(parsed["step"] as? String, "read")

        // typed evidence：step Finished(error) + recipe-level Finished(failed)。
        let rows = await ledgerRows(runId: runId, dao: dao)
        let stepFinish = rows
            .filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
            .compactMap { parsedPayload($0.payload) }
            .first { ($0["toolCallId"] as? String)?.hasSuffix("-read") == true }
        XCTAssertEqual(stepFinish?["outcome"] as? String, "failed")
        XCTAssertEqual(stepFinish?["outcomeKind"] as? String, "error")
        XCTAssertEqual(stepFinish?["artifactId"] as? String, "recipe__missing_reader")
        XCTAssertEqual(stepFinish?["artifactVersion"] as? String, "1.0.0")
    }

    /// 单 step pure 读 recipe：读取必然缺失的文件（隔离 temp workspace 为空）。
    private func readMissingRecipeJSON(version: String) throws -> Data {
        let dict: [String: Any] = [
            "schema": "amber.recipe.v1",
            "name": "missing_reader",
            "version": version,
            "description": "读取一个必然不存在的文件。",
            "inputs": ["path": "string"],
            "steps": [
                ["id": "read", "tool": "workspace_file_read",
                 "arguments": ["path": "${input.path}"]],
            ],
            "outputs": ["text": "${step.read.output.text}"],
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    // MARK: - Fixtures

    /// XCTUnwrap cannot take `await` in its autoclosure; this wrapper keeps
    /// `unwrapSnapshot(await registry.refresh())` readable at call sites.
    private func unwrapSnapshot(
        _ value: IOSDynamicToolCatalogSnapshot?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IOSDynamicToolCatalogSnapshot {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-recipe-integration-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func makeStore(root: URL) -> IOSRecipeFileStore {
        IOSRecipeFileStore(baseDirectory: root)
    }

    private func makeRegistry(store: IOSRecipeFileStore) -> IOSDynamicToolRegistry {
        IOSDynamicToolRegistry(baseDirectory: store.recipesDirectory.deletingLastPathComponent())
    }

    private func makeDatabase(root: URL) -> (db: AgentRuntimeDatabase, dao: AgentRuntimeDao) {
        // The temp directory MUST exist before Room creates the DB file.
        let path = root.appendingPathComponent("agent_runtime.db").path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: path)
        return (db, db.agentRuntimeDao())
    }

    private func seedDurableRun(_ runId: String, dao: AgentRuntimeDao) async throws {
        let started = try await IOSDurableRunStore(dao: dao).startChatRun(
            runId: runId,
            startedAt: 1,
            inputDigest: "recipe-integration-test",
            conversationId: "recipe-integration-test"
        )
        XCTAssertTrue(started)
    }

    private func makeRuntime(
        root: URL,
        ledger: IOSAgentRunLedgering,
        localToolExecutor: IOSLocalToolExecutor? = nil,
        workspaceStore: IOSWorkspaceStore? = nil,
        recipeRegistry: IOSDynamicToolRegistry? = nil
    ) -> ChatToolRuntime {
        let defaults = UserDefaults(suiteName: "recipe-runtime-\(UUID().uuidString)")!
        return ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            localToolExecutor: localToolExecutor,
            searchTransport: RecipeNoopSearchTransport(),
            mcpManager: IOSMcpManager(
                sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
                configStore: .shared
            ),
            workspaceStore: workspaceStore ?? .shared,
            ledger: ledger,
            recipeStoreBaseDirectory: root,
            recipeRegistry: recipeRegistry
        )
    }

    private func makeWorkspaceStore(root: URL) -> IOSWorkspaceStore {
        IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("ws", isDirectory: true))
    }

    private func makeWorkspaceExecutor(
        root: URL
    ) -> (executor: IOSLocalToolExecutor, workspace: IOSWorkspaceStore, permissionStore: IOSPermissionStore) {
        let workspace = makeWorkspaceStore(root: root)
        let permissionStore = IOSPermissionStore(
            userDefaults: UserDefaults(suiteName: "recipe-perm-\(UUID().uuidString)")!
        )
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            workspaceStore: workspace
        )
        return (executor, workspace, permissionStore)
    }

    private func makeRecipeToolCall(name: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "tc-\(name)-\(UUID().uuidString)",
            toolName: name,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func pendingContext(
        for toolCall: UIMessagePart.Tool,
        runId: String,
        conversationId: KotlinUuid? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> ChatPendingToolApproval {
        ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: makeProviderSetting(),
            params: makeParams(tools: []),
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: conversationId,
            baseMessages: [makeAssistantMessage(parts: [toolCall])],
            executionPolicy: executionPolicy ?? manualApprovalPolicy
        )
    }

    private func resolveRecipeApproval(
        runtime: ChatToolRuntime,
        ledger: IOSAgentRunLedgering,
        request: RecipeToolApprovalRequest,
        decision: ChatKernelApprovalDecision,
        toolCall: UIMessagePart.Tool,
        runId: String,
        toolExposureBridge: IosToolExposureBridge? = nil,
        callbacks: ChatRunKernelAdapter.Callbacks = .init()
    ) async -> ChatRunKernelAdapter.ApprovalResolution {
        let pending = pendingContext(for: toolCall, runId: runId)
        var candidates = ChatRunKernelAdapter.PreparedApprovalCandidates()
        var directRuntimeApprovalEffect: IOSToolEffectClass?
        switch request.payload {
        case .recipeImport:
            if request.isPluginImport {
                candidates.pluginImport = runtime.takePreparedPluginImportForApproval(toolCallId: toolCall.toolCallId)
                directRuntimeApprovalEffect = .sideEffect
            } else {
                candidates.recipeImport = runtime.takePreparedRecipeImportForApproval(toolCallId: toolCall.toolCallId)
            }
        case .pluginInvocation(let payload):
            candidates.pluginInvocation = runtime.takePreparedPluginInvocationForApproval(
                toolCallId: toolCall.toolCallId
            )
            directRuntimeApprovalEffect = payload.effectClass
        case .step:
            candidates.recipeExecution = runtime.takePreparedRecipeExecution(
                toolCallId: toolCall.toolCallId
            )
            directRuntimeApprovalEffect = .sideEffect
        }
        // Production executeBatch has already closed its Started attempt as
        // paused_for_approval. These tests enter through ChatToolRuntime
        // directly, so seed the same durable state before resolving.
        let existing = await ledger.toolTransactions(runId: runId)?
            .contains { $0.toolCallId == toolCall.toolCallId } == true
        if let effectClass = directRuntimeApprovalEffect, !existing {
            let argsDigest = chatInputDigest(for: toolCall.input)
            _ = await ledger.recordToolCallPrepared(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: effectClass
            )
            _ = await ledger.recordToolCallStarted(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: effectClass
            )
            _ = await ledger.recordToolCallFinished(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                outcome: "paused_for_approval"
            )
        }
        let bridge = toolExposureBridge ?? IosToolExposureBridge(tools: fullIosDeclarations())
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: ledger, callbacks: callbacks)
        let runRequest = ChatRunKernelAdapter.RunRequest(
            provider: RecipeUnusedProvider(),
            providerSetting: pending.providerSetting,
            params: pending.params,
            runId: runId,
            startedAt: pending.startedAt,
            inputDigest: pending.inputDigest,
            conversationId: pending.conversationId,
            initialMessages: pending.baseMessages,
            toolExposureBridge: bridge,
            maxToolResumeCount: 1,
            drainSteer: nil,
            mailboxDrain: nil,
            citationTracker: nil,
            prepareUploadMessages: nil,
            nestedToolRunner: nil,
            approvalDecider: { _ in nil }
        )
        return await adapter.resolveApproval(
            prompt: .recipe(request),
            decision: decision,
            pending: pending,
            candidates: candidates,
            request: runRequest
        )
    }

    private func executeRecipeCall(
        runtime: ChatToolRuntime,
        toolCall: UIMessagePart.Tool,
        snapshot: IOSDynamicToolCatalogSnapshot?,
        bridge: IosToolExposureBridge?,
        runId: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        let pending = pendingContext(
            for: toolCall,
            runId: runId,
            executionPolicy: executionPolicy ?? manualApprovalPolicy
        )
        return await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: snapshot
        )
    }

    private var manualApprovalPolicy: IOSExecutionPolicySnapshot {
        IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: true,
            mcpEnabled: true
        )
    }

    @discardableResult
    private func apply(store: IOSRecipeFileStore, json: Data) throws -> String {
        let prep = try store.prepareRecipe(recipeJSON: json)
        let receipt = try store.applyRecipe(
            name: prep.candidate.name,
            recipeJSON: json,
            expectedBaseHash: prep.base?.hash,
            expectedCandidateHash: prep.candidate.hash
        )
        return receipt.promotedHash
    }

    private func seedWorkspaceRecipe(
        workspace: IOSWorkspaceStore,
        json: Data,
        workspacePath: String = "/workspace/recipes/catalog_probe/recipe.json"
    ) async throws {
        let content = String(data: json, encoding: .utf8) ?? "{}"
        let input = String(data: try JSONSerialization.data(
            withJSONObject: [
                "path": workspacePath,
                "content": content,
                "overwrite": true,
            ] as [String: Any]
        ), encoding: .utf8) ?? "{}"
        let result = await workspace.executeTool(toolName: "workspace_file_write", input: input)
        XCTAssertTrue(result.contains(#""ok":true"#), result)
    }

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "recipe-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    private func makeParams(tools: [Tool]) -> TextGenerationParams {
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: tools,
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    private func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func userMessage(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.user, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    private func assistantText(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    private func makeAssistantMessage(parts: [UIMessagePart]) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: parts)
    }

    private func toolCallMessage(toolCallId: String, toolName: String, input: String) -> UIMessage {
        makeMessage(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallId,
                toolName: toolName,
                input: input,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )]
        )
    }

    private func fullIosDeclarations() -> [Tool] {
        let names =
            IOSWorkspaceToolCatalog.supportedToolNames
            .union(IOSAgentTerminalToolCatalog.supportedToolNames)
            .union(IOSWebMountToolCatalog.supportedToolNames)
            .union(IOSSkillToolCatalog.toolNames)
            .union(IOSRecipeToolCatalog.toolNames)
            .union(IOSPluginToolCatalog.toolNames)
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([
                "search_web", "scrape_web", "memory_tool", "generate_image",
                "mcp_call", "subagent_dispatch", "model_council_run", "ask_user",
                "spawn_agent", "list_agents", "interrupt_agent", "send_message",
                "followup_task", "wait_agent", "session_search", "session_read",
                "exec", "wait", "tools_list", "subagent_report",
                "permissions_status", "file_read_selected",
            ])
        return ToolKt.iosToolDeclarations(names: Array(names).sorted())
    }

    // MARK: Manifest builders (test data, not assertions)

    private func listingRecipeJSON(version: String, name: String = "catalog_probe") throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": name,
            "version": version,
            "description": "列出当前工具目录并返回总数。",
            "inputs": [:],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
            ],
            "outputs": ["tool_count": "${step.list.output.total}"],
        ])
    }

    private func pluginFiles(
        version: String,
        readPrefixes: [String] = ["/workspace/plugin-data"],
        backgroundAllowed: Bool = false
    ) throws -> [String: Data] {
        let first = try jsonData([
            "schema": "amber.recipe.v1",
            "name": "list_tools",
            "version": version,
            "description": "List tools.",
            "inputs": [:],
            "steps": [["id": "list", "tool": "tools_list", "arguments": [:]]],
            "outputs": ["count": "${step.list.output.total}"],
        ])
        let second = try jsonData([
            "schema": "amber.recipe.v1",
            "name": "count_tools",
            "version": version,
            "description": "Count tools.",
            "inputs": [:],
            "steps": [["id": "list", "tool": "tools_list", "arguments": [:]]],
            "outputs": ["count": "${step.list.output.total}"],
        ])
        let plugin = try jsonData([
            "schema": "amber.plugin.v1",
            "id": "workspace_kit",
            "name": "Workspace Kit",
            "version": version,
            "description": "Two safe catalog helpers.",
            "tools": [
                ["name": "list_tools", "recipe": "recipes/list.json"],
                ["name": "count_tools", "recipe": "recipes/count.json"],
            ],
            "capabilities": [
                "workspaceReadPrefixes": readPrefixes,
                "workspaceWritePrefixes": [],
                "networkDomains": [],
                "webMountActions": [],
            ],
            "backgroundAllowed": backgroundAllowed,
        ])
        return [
            "plugin.json": plugin,
            "recipes/list.json": first,
            "recipes/count.json": second,
            "README.md": Data("# Workspace Kit\n".utf8),
        ]
    }

    private func scriptPluginFiles(
        includeAsset: Bool = false,
        backgroundAllowed: Bool = false
    ) throws -> [String: Data] {
        let plugin = try jsonData([
            "schema": "amber.plugin.v1",
            "id": "script_kit",
            "name": "Script Kit",
            "version": "1.0.0",
            "description": "A restricted JavaScript helper.",
            "tools": [[
                "name": "greet",
                "description": "Build a greeting.",
                "script": "scripts/greet.js",
                "host_tools": [],
                "inputs": ["name": "string"],
                "output": "object",
                "timeout_ms": 2_000,
                "max_output_chars": 4_000,
            ]],
            "capabilities": [
                "workspaceReadPrefixes": [],
                "workspaceWritePrefixes": [],
                "networkDomains": [],
                "webMountActions": [],
            ],
            "backgroundAllowed": backgroundAllowed,
        ])
        var files: [String: Data] = [
            "plugin.json": plugin,
            "scripts/greet.js": Data(#"return { greeting: "hi " + input.name, dynamic: typeof eval };"#.utf8),
            "README.md": Data("# Script Kit\n".utf8),
        ]
        if includeAsset { files["assets/note.txt"] = Data("signed".utf8) }
        return files
    }

    private func sideEffectScriptPluginFiles() throws -> [String: Data] {
        [
            "plugin.json": try jsonData([
                "schema": "amber.plugin.v1",
                "id": "writer_kit",
                "name": "Writer Kit",
                "version": "1.0.0",
                "description": "A scoped writer.",
                "tools": [[
                    "name": "write_note",
                    "script": "scripts/write.js",
                    "host_tools": ["workspace_file_write"],
                    "inputs": ["text": "string"],
                    "output": "object",
                ]],
                "capabilities": [
                    "workspaceReadPrefixes": [],
                    "workspaceWritePrefixes": ["/workspace/plugin-data"],
                    "networkDomains": [],
                    "webMountActions": [],
                ],
                "backgroundAllowed": false,
            ]),
            "scripts/write.js": Data(#"return tools.workspace_file_write({path: "/workspace/plugin-data/note.txt", content: input.text});"#.utf8),
        ]
    }

    private func listingRecipeV2JSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "catalog_probe",
            "version": version,
            "description": "列出工具目录两次。",
            "inputs": [:],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "list_again", "tool": "tools_list", "arguments": [:]],
            ],
            "outputs": ["tool_count": "${step.list_again.output.total}"],
        ])
    }

    private func twoMutationRecipeJSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "double_save",
            "version": version,
            "description": "列出工具目录并写入两个 Workspace 文件。",
            "inputs": ["path_a": "string", "path_b": "string"],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "save_a", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.path_a}", "content": "${step.list.output.status}"]],
                ["id": "save_b", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.path_b}", "content": "${step.save_a.output.id}"]],
            ],
            "outputs": [
                "path_a_out": "${step.save_a.output.path}",
                "path_b_out": "${step.save_b.output.path}",
            ],
        ])
    }

    private func singleStepRecipeJSON(
        name: String,
        tool: String,
        arguments: [String: Any]
    ) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": name,
            "version": "1.0.0",
            "description": "Apple capability gate regression.",
            "inputs": [:],
            "steps": [["id": "action", "tool": tool, "arguments": arguments]],
            "outputs": ["status": "${step.action.output.status}"],
        ])
    }

    private func mutatingRecipeJSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "digest_save",
            "version": version,
            "description": "列出工具目录并把结果写入 Workspace。",
            "inputs": ["output_path": "string"],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "save", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.output_path}", "content": "${step.list.output.status}"]],
            ],
            "outputs": ["file_path": "${step.save.output.path}"],
        ])
    }

    private func webMountHighRiskRecipeJSON(
        version: String,
        sessionId: String,
        snapshotId: String
    ) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "webmount_checkout",
            "version": version,
            "description": "检查付款并提交订单。",
            "inputs": [:],
            "steps": [[
                "id": "pay_and_submit",
                "tool": "wm_click",
                "arguments": [
                    "session_id": sessionId,
                    "snapshot_id": snapshotId,
                    "target": "Pay and submit order",
                ],
            ]],
            "outputs": ["status": "${step.pay_and_submit.output.status}"],
        ])
    }

    private func jsonData(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private func parse(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func toolOutputText(in messages: [UIMessage], toolCallId: String) -> String? {
        for message in messages {
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool, tool.toolCallId == toolCallId else { continue }
                let text = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    private func toolSearchHitNames(_ output: String) -> [String] {
        guard let object = try? parse(output),
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }

    private func searchHit(_ output: String, name: String) -> [String: Any]? {
        guard let object = try? parse(output),
              let tools = object["tools"] as? [[String: Any]] else { return nil }
        return tools.first { ($0["name"] as? String) == name }
    }

    private func parsedPayload(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func checkpointFileCount(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }

    /// The `approval_denied` event is written fire-and-forget by the runtime
    /// (same tier as Finished); poll briefly until it lands.
    private func waitForApprovalDenied(runId: String, dao: AgentRuntimeDao) async -> [LedgerRowSnapshot] {
        for _ in 0..<40 {
            let rows = await ledgerRows(runId: runId, dao: dao)
            if rows.contains(where: { $0.type == IOSAgentRunLedger.approvalDeniedEventType }) {
                return rows
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await ledgerRows(runId: runId, dao: dao)
    }

    private func ledgerRows(runId: String, dao: AgentRuntimeDao) async -> [LedgerRowSnapshot] {
        await withCheckedContinuation { continuation in
            dao.listEventsForRun(id: runId) { result, error in
                guard error == nil, let result else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: result.map {
                    LedgerRowSnapshot(type: $0.type, seq: $0.seq, payload: $0.payload)
                })
            }
        }
    }

    private func directorySnapshot(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var entries: [String] = []
        while let item = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            let kind = isDirectory.boolValue ? "dir" : "file"
            entries.append("\(kind):\(item.lastPathComponent)")
        }
        return entries.sorted()
    }
}

@MainActor
private final class BackgroundFeatureRecipeWebMountRuntime: IOSWebMountRuntimeServicing {
    let webView: WKWebView? = nil
    private(set) var preflightCount = 0
    private(set) var dispatchCount = 0
    var snapshot: IOSWebMountRuntimeSnapshot

    init(sessionId: String = "recipe-webmount-session") {
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: sessionId,
            status: .ready,
            requestedURL: "https://github.com/login",
            currentURL: "https://github.com/login",
            title: "Checkout",
            estimatedProgress: 1,
            canGoBack: false,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 1
        )
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        snapshot.currentURL = url.absoluteString
        return snapshot
    }

    func state() async throws -> [String: Any] {
        ["snapshot_id": "recipe-snapshot", "page_revision": 1]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        ["mode": mode, "snapshot_id": "recipe-snapshot"]
    }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] {
        ["ok": true, "snapshot_id": "recipe-snapshot"]
    }

    func interact(
        method: String,
        selector: String?,
        text: String?,
        options: [String: Any]
    ) async throws -> [String: Any] {
        if options["_amber_preflight_only"] as? Bool == true {
            preflightCount += 1
            return [
                "ok": false,
                "needs_user_action": true,
                "reason": "This action may pay or submit.",
                "consequence": "Payment or order submission changes remote state.",
                "snapshot_id": "recipe-snapshot"
            ]
        }
        dispatchCount += 1
        return ["ok": true, "verified": true, "snapshot_id": "recipe-snapshot"]
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data(), width: 1, height: 1, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot { snapshot }
    func forward() async -> IOSWebMountRuntimeSnapshot { snapshot }
}

/// Sendable reduction of one `agent_event` row.
private struct LedgerRowSnapshot: Sendable {
    let type: String
    let seq: Int64
    let payload: String
}

/// Scripted provider that records every `params` it was called with, so tests
/// can assert what the round declared (P0-a Fix C / Wave B2 canary).
private final class ParamsRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private var script: [UIMessage]
    private(set) var recordedParams: [TextGenerationParams] = []
    init(_ script: [UIMessage]) { self.script = script }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        recordedParams.append(params)
        if !script.isEmpty {
            return chunk(with: script.removeFirst())
        }
        return chunk(with: UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "stop", metadata: nil)],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        ))
    }

    private func chunk(with message: UIMessage?) -> MessageChunk {
        MessageChunk(
            id: "chunk-\(UUID().uuidString)",
            model: "test-model",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
            usage: nil
        )
    }
}

/// Executes tool_search through a real KMP exposure bridge (local, no
/// network) so the hit becomes visible inside the bridge.
private final class BridgeToolSearchExecutor: IOSToolExecutor {
    private let bridge: IosToolExposureBridge
    init(bridge: IosToolExposureBridge) { self.bridge = bridge }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        .filled(bridge.executeToolSearch(argumentsJson: arguments))
    }
}

/// Executes one `recipe__*` call through the REAL `ChatToolRuntime` recipe
/// route with the round's pinned snapshot (the production path; only the
/// provider is scripted).
@MainActor
private final class RecipeRouteExecutor: IOSToolExecutor {
    private let runtime: ChatToolRuntime
    private let snapshot: IOSDynamicToolCatalogSnapshot
    private let bridge: IosToolExposureBridge
    private let runId: String
    private let providerSetting: ProviderSetting.OpenAI
    private let params: TextGenerationParams

    init(
        runtime: ChatToolRuntime,
        snapshot: IOSDynamicToolCatalogSnapshot,
        bridge: IosToolExposureBridge,
        runId: String
    ) {
        self.runtime = runtime
        self.snapshot = snapshot
        self.bridge = bridge
        self.runId = runId
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        self.providerSetting = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "recipe-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        self.params = TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "tc-\(name)-\(UUID().uuidString)",
            toolName: name,
            input: arguments,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        let baseMessages = [UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolCall],
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )]
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: baseMessages
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: snapshot
        )
        switch result {
        case .completed(let messages):
            let output = messages.flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output.compactMap { ($0 as? UIMessagePart.Text)?.text }
                .joined() ?? ""
            return .filled(output)
        case .waitingForApproval:
            return .needsApproval("Recipe step requires approval.")
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        case .outcomeUnknown(let messages):
            let output = messages.flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output ?? []
            return .outcomeUnknown(output)
        }
    }
}

/// 无网络搜索传输（同 IOSExecNestedNoopSearchTransport 模式）。
private struct RecipeNoopSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (response, Data())
    }
}

private struct RecipeUnusedProvider: IOSAgentTextProvider {
    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        throw NSError(domain: "IOSRecipeIntegrationTests", code: 1)
    }
}

private final class RecipeUncheckedToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor

    init(_ base: any IOSToolExecutor) {
        self.base = base
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await base.execute(
            name: name,
            arguments: arguments,
            isUserInitiated: isUserInitiated
        )
    }
}
