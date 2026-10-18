import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Foreground recipe publication, version pinning, stale imports, and rollback.
@MainActor
final class IOSRecipeHotReloadTests: IOSRecipeIntegrationTestCase {
    func testHotReloadCanarySearchPromoteCallResultRoundByRound() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let (_, dao) = makeDatabase(root: root)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "canary-run-\(UUID().uuidString)"
        try await seedDurableRun(runId, dao: dao)
        let runtime = makeRuntime(root: root, ledger: ledger)

        // Round 1: the recipe is NOT published. Static recipe management tools
        // may match this query because their descriptions contain the sample name.
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
        XCTAssertFalse(
            toolSearchHitNames(search1).contains("recipe__catalog_probe"),
            "round 1 must not discover the unpublished recipe: \(search1)"
        )
        XCTAssertFalse(Set(bridge.visibleTools().map(\.name)).contains("recipe__catalog_probe"))

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

}
