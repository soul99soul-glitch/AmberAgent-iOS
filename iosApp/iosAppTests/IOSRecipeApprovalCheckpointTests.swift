import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Recipe approval, checkpoint durability, ledger attribution, and handoff.
@MainActor
final class IOSRecipeApprovalCheckpointTests: IOSRecipeIntegrationTestCase {
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

    func testAutoHighRiskWebMountRecipeExecutesSnapshotBoundPayAndSubmit() async throws {
        let fixture = try await makeWebMountCheckoutFixture(highRiskAutoApproveEnabled: true)
        let result = await fixture.runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: fixture.call),
            context: fixture.pending,
            toolExposureBridge: fixture.bridge,
            recipeCatalogSnapshot: fixture.snapshot
        )
        guard case .completed(let messages) = result else {
            return XCTFail("high-risk auto approval should execute the snapshot-bound recipe: \(result)")
        }
        let output = try XCTUnwrap(toolOutputText(in: messages, toolCallId: fixture.call.toolCallId))
        let parsed = try XCTUnwrap(parse(output))
        XCTAssertEqual(parsed["ok"] as? Bool, true, output)
        XCTAssertEqual(parsed["status"] as? String, "completed", output)
        XCTAssertEqual(parsed["steps"] as? [String], ["pay_and_submit"])
        let outputs = try XCTUnwrap(parsed["outputs"] as? [String: Any])
        XCTAssertEqual(outputs["status"] as? String, "verified")
        XCTAssertEqual(fixture.webMountRuntime.preflightCount, 0)
        XCTAssertEqual(fixture.webMountRuntime.dispatchCount, 1)
        XCTAssertTrue(fixture.webMountRuntime.lastActionAllowedHighConsequence)
    }

    func testWebMountRecipeRequiresPayAndSubmitApprovalUnderAskEveryTimePolicy() async throws {
        let fixture = try await makeWebMountCheckoutFixture(highRiskAutoApproveEnabled: false)
        let result = await fixture.runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: fixture.call),
            context: fixture.pending,
            toolExposureBridge: fixture.bridge,
            recipeCatalogSnapshot: fixture.snapshot
        )
        guard case .waitingForApproval(.recipe(let request)) = result,
              case .step(let payload) = request.payload else {
            return XCTFail("payment/submit recipe must pause before dispatch: \(result)")
        }
        XCTAssertEqual(payload.stepId, "pay_and_submit")
        XCTAssertEqual(payload.tool, "wm_click")
        XCTAssertTrue(request.reason.localizedCaseInsensitiveContains("pay or submit"))
        XCTAssertEqual(fixture.webMountRuntime.preflightCount, 1)
        XCTAssertEqual(fixture.webMountRuntime.dispatchCount, 0)
    }

    private func makeWebMountCheckoutFixture(
        highRiskAutoApproveEnabled: Bool
    ) async throws -> (
        runtime: ChatToolRuntime,
        webMountRuntime: BackgroundFeatureRecipeWebMountRuntime,
        snapshot: IOSDynamicToolCatalogSnapshot,
        bridge: IosToolExposureBridge,
        call: UIMessagePart.Tool,
        pending: ChatPendingToolApproval
    ) {
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
        let policy: IOSAgentPermissionPolicy = highRiskAutoApproveEnabled
            ? .autoApproveHighRisk : .askEveryTime
        permissionStore.setPolicy(policy, for: webMountCapability)
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            webMountController: controller
        )
        let executionPolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [webMountCapability.id: policy.rawValue],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: highRiskAutoApproveEnabled,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )
        try apply(
            store: store,
            json: try webMountCheckoutRecipeJSON(
                version: "1.0.0",
                sessionId: webMountRuntime.snapshot.sessionId,
                snapshotId: "recipe-snapshot",
                targetRef: webMountRuntime.targetRef
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
        return (runtime, webMountRuntime, snapshot, bridge, call, pending)
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

        // The direct runtime call needs one seeded outer pause, then each
        // approval starts another attempt. Three steps have their own pairs.
        let rows = await ledgerRows(runId: runId, dao: dao)
        let started = rows.filter { $0.type == IOSToolCallLedgerClassifier.startedType }
        let finished = rows.filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
        XCTAssertEqual(started.count, 6, "3 steps + seeded pause + 2 approval attempts")
        XCTAssertEqual(finished.count, 7, "3 steps + recipe-level + seeded pause + 2 approval attempts")
        let startedPayloads = started.compactMap { parsedPayload($0.payload) }
        XCTAssertEqual(startedPayloads.filter {
            ($0["toolCallId"] as? String) == call.toolCallId
        }.count, 3)
        XCTAssertEqual(startedPayloads.filter {
            ($0["toolCallId"] as? String)?.hasPrefix("recipe-recipe-") == true
        }.count, 3)
        let finishedPayloads = rows
            .filter { $0.type == IOSToolCallLedgerClassifier.finishedType }
            .compactMap { parsedPayload($0.payload) }
        let outerOutcomes = finished
            .sorted { $0.seq < $1.seq }
            .compactMap { parsedPayload($0.payload) }
            .filter { ($0["toolCallId"] as? String) == call.toolCallId }
            .compactMap { $0["outcome"] as? String }
        XCTAssertEqual(outerOutcomes, ["paused_for_approval", "paused_for_approval", "completed"])
        let stepAttributions = finishedPayloads.filter {
            ($0["toolCallId"] as? String)?.hasPrefix("recipe-recipe-") == true
        }
        XCTAssertEqual(stepAttributions.count, 3)
        for payload in stepAttributions {
            XCTAssertEqual(payload["artifactId"] as? String, "recipe__double_save")
            XCTAssertEqual(payload["artifactVersion"] as? String, "1.0.0")
            XCTAssertEqual(payload["outcomeKind"] as? String, "success")
        }
        let recipeLevelFinishes = finishedPayloads.filter {
            ($0["toolCallId"] as? String)?.hasPrefix("recipe-level-") == true
        }
        XCTAssertEqual(recipeLevelFinishes.count, 1)
        let recipeLevel = try XCTUnwrap(recipeLevelFinishes.first)
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
        let disabledExecutionPolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [capability.id: IOSAgentPermissionPolicy.disabled.rawValue],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: true,
            mcpEnabled: true
        )
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
            runtime: runtime, toolCall: call, snapshot: snapshot, bridge: bridge, runId: runId,
            executionPolicy: disabledExecutionPolicy
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
            toolExposureBridge: bridge,
            executionPolicy: disabledExecutionPolicy
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
        XCTAssertEqual(parsed["status"] as? String, "failed", output)
        XCTAssertTrue((parsed["reason"] as? String)?.contains("不在当前目录中") == true, output)

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

}
