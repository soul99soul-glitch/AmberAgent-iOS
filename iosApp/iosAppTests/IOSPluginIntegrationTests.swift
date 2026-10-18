import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Plugin installation, capability boundaries, health, runtime, signature, and archive.
@MainActor
final class IOSPluginIntegrationTests: IOSRecipeIntegrationTestCase {
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

}
