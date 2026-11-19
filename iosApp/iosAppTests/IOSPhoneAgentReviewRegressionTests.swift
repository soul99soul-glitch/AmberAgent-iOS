import AmberPhoneControl
import BackgroundTasks
import CryptoKit
import Foundation
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneAgentReviewRegressionTests: XCTestCase {
    // MARK: - Item 1: phone_add_app reachable foreground approval & background gate

    func testPhoneAddAppForegroundRequiresApprovalAndBackgroundDeniesUnapprovedExpansion() async throws {
        let suite = "PhoneAddAppApproval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let installed = [
            PhoneControlInstalledApp(bundleID: "com.example.current", name: "Current App", isSystem: false),
            PhoneControlInstalledApp(bundleID: "com.example.extra", name: "Extra App", isSystem: false),
        ]
        let discovery = AddAppDiscoveryStub(installed)
        let credentials = MemoryPairingStore(data: try Self.makePairingData())
        let controller = IOSPhoneControlController(
            defaults: defaults,
            credentials: credentials,
            applications: discovery,
            localTunnel: PhoneControlTunnelStub()
        )
        controller.enabled = true
        controller.selectedBundleIDs = ["com.example.current"]
        let runID = "run-add-app-\(UUID().uuidString)"
        XCTAssertTrue(controller.claim(runID: runID, onStop: {}))
        _ = try await controller.loadInstalledApplications(runID: runID)

        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults, storageKey: "add-app-settings"),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: UnreachableSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let params = IOSChatForegroundFixtures.makeParams(
            toolNames: [],
            tools: IOSPhoneControlToolCatalog.declarations
        )
        let toolCall = UIMessagePart.Tool(
            toolCallId: "call-add-app",
            toolName: "phone_add_app",
            input: #"{"bundle_id":"com.example.extra"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantMessage = IOSChatForegroundFixtures.assistantMessage(parts: [toolCall])
        let promptBox = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        let executionPolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )

        let foregroundExecutors = runtime.foregroundToolExecutors(
            providerSetting: providerSetting,
            params: params,
            runId: runID,
            startedAt: 1_700_000_000_000,
            inputDigest: "digest-add-app",
            conversationId: nil,
            toolExposureBridge: IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations),
            baseMessagesProvider: { [assistantMessage] },
            approvalPromptBox: promptBox,
            executionPolicy: executionPolicy,
            phoneControl: controller
        )
        let addAppExecutor = try XCTUnwrap(foregroundExecutors["phone_add_app"])
        let outcome = await Self.executeOffMainActor(.init(executor: addAppExecutor, tool: toolCall))
        guard case .needsApproval = outcome else {
            await controller.stop(runID: runID)
            return XCTFail("Expected phone_add_app to pause for foreground approval, got \(outcome)")
        }
        XCTAssertFalse(
            controller.selectedBundleIDs.contains("com.example.extra"),
            "phone_add_app must not mutate persisted selectedBundleIDs before approval"
        )
        XCTAssertFalse(controller.statusText(runID: runID).contains("com.example.extra"))

        let prompt = try XCTUnwrap(promptBox.take(toolCall.toolCallId))
        guard case .mcp(let approvalRequest) = prompt else {
            await controller.stop(runID: runID)
            return XCTFail("Expected iPhone McpToolApprovalRequest, got \(prompt)")
        }
        XCTAssertEqual(approvalRequest.serverName, "iPhone")
        XCTAssertEqual(approvalRequest.toolName, "phone_add_app")
        XCTAssertFalse(approvalRequest.isAppleCapability && !approvalRequest.isHighRiskLocalMutation && !approvalRequest.isDestructiveAppleAction,
                       "phone_add_app must not be remotely approvable on Lock Screen / Watch")
        XCTAssertTrue(approvalRequest.argumentsPreview.contains("com.example.extra"))

        let ledger = IOSAgentToolEngineTests.RecordingLedger()
        let resolver = ChatKernelApprovalResolver(
            runtime: runtime,
            ledger: ledger,
            onRunResumed: { true },
            onDurabilityFailure: {}
        )
        let bindings = Self.makeBindings(messages: [assistantMessage])
        let runRequest = ChatRunRequestFactory(
            bindings: bindings,
            maxToolResumeCount: 8,
            executionPolicy: executionPolicy,
            phoneAutomaticReasoning: false,
            phoneControl: controller,
            prepareUploadMessages: { $0 },
            approvalDecider: { _ in nil }
        ).make(
            adapterProvider: IdleProvider(),
            providerSetting: providerSetting,
            params: params,
            runId: runID,
            startedAt: 1_700_000_000_000,
            inputDigest: "digest-add-app",
            conversationId: nil,
            initialMessages: [assistantMessage],
            toolExposureBridge: IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations),
            recipeCatalogSnapshot: nil,
            citationTracker: IOSMemoryCitationTracker(enforceCitationAllowlist: false)
        )
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: providerSetting,
            params: params,
            runId: runID,
            startedAt: 1_700_000_000_000,
            inputDigest: "digest-add-app",
            conversationId: nil,
            baseMessages: [assistantMessage],
            executionPolicy: executionPolicy
        )

        let deniedResolution = await resolver.resolveApproval(
            prompt: prompt,
            decision: .deny,
            pending: pending,
            candidates: .init(),
            request: runRequest
        )
        guard case .resumed = deniedResolution else {
            await controller.stop(runID: runID)
            return XCTFail("Expected denied approval resolution to resume cleanly")
        }
        XCTAssertFalse(controller.selectedBundleIDs.contains("com.example.extra"))

        let approvedResolution = await resolver.resolveApproval(
            prompt: prompt,
            decision: .approve,
            pending: pending,
            candidates: .init(),
            request: runRequest
        )
        guard case .resumed(let approvedMessages) = approvedResolution else {
            await controller.stop(runID: runID)
            return XCTFail("Expected approved resolution to resume with tool output")
        }
        XCTAssertTrue(controller.selectedBundleIDs.contains("com.example.extra"))
        XCTAssertTrue(controller.statusText(runID: runID).contains("com.example.extra"))
        let outputText = approvedMessages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output
            .compactMap { ($0 as? UIMessagePart.Text)?.text }.joined() ?? ""
        XCTAssertTrue(outputText.contains("\"selected\":true") && outputText.contains("\"outcome\":\"completed\""))
        await controller.stop(runID: runID)

        // Background execution must also fail closed with .denied when an unapproved bundle_id is requested.
        let sharedPhone = IOSPhoneControlController.shared
        let wasEnabled = sharedPhone.enabled
        let oldScope = sharedPhone.selectedBundleIDs
        let bgRunID = "bg-add-app-\(UUID().uuidString)"
        sharedPhone.enabled = true
        sharedPhone.selectedBundleIDs = ["com.example.current"]
        defer {
            sharedPhone.revoke(runID: bgRunID)
            sharedPhone.selectedBundleIDs = oldScope
            sharedPhone.enabled = wasEnabled
        }
        XCTAssertTrue(sharedPhone.claim(runID: bgRunID, onStop: {}))
        let bgExecutors = runtime.backgroundToolExecutors(
            providerSetting: providerSetting,
            params: params,
            runId: bgRunID,
            executionPolicy: executionPolicy
        )
        let bgAddApp = try XCTUnwrap(bgExecutors["phone_add_app"])
        let bgOutcome = await Self.executeOffMainActor(.init(executor: bgAddApp, tool: toolCall))
        guard case .denied = bgOutcome else {
            await sharedPhone.stop(runID: bgRunID)
            return XCTFail("Expected background phone_add_app to fail closed with .denied, got \(bgOutcome)")
        }
        XCTAssertFalse(sharedPhone.selectedBundleIDs.contains("com.example.extra"))
        await sharedPhone.stop(runID: bgRunID)
    }

    // MARK: - Item 2: Phone lease recovery, spawn_agent isolation & occupied foreground exclusion

    func testBackgroundExpirationForegroundRecoveryReclaimsPhoneControlLease() async throws {
        let assertions = BackgroundKeepAliveAssertions()
        let keepAlive = assertions.keepAlive(audioEnabled: false, foreground: false)
        let provider = RecoveryPhoneStatusProvider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)

        let runID = "phone-recover-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bg-phone-recover-\(runID)")
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let phoneTools = IOSPhoneControlToolCatalog.declarations.filter {
            ["phone_status", "phone_observe", "phone_run_flow"].contains($0.name)
        }
        let handoffParams = IOSChatForegroundFixtures.makeParams(toolNames: [], tools: phoneTools)
        let settingsSuite = "bg-phone-settings-\(runID)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuite))
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: settingsDefaults, storageKey: "s"),
            sharedSettings: IOSSharedSettingsStore(userDefaults: settingsDefaults),
            localToolExecutor: nil,
            searchTransport: UnreachableSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let handoff = IOSChatBackgroundHandoff(
            runId: runID,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000),
            inputDigest: runID,
            conversationId: conversationId,
            providerId: providerSetting.id.toHexDashString(),
            providerSetting: providerSetting,
            params: handoffParams,
            uploadMessages: [IOSChatForegroundFixtures.userMessage("检查手机控制状态")],
            displayMessages: [],
            mode: .continueModel,
            generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false,
            fullToolNames: phoneTools.map(\.name),
            subAgentTimeoutSeconds: 60,
            phoneAutomaticReasoning: true
        )
        let recorded = try await IOSDurableRunStore().startChatRun(
            runId: runID,
            startedAt: handoff.startedAt,
            inputDigest: runID,
            conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(recorded)

        let phoneControl = IOSPhoneControlController.shared
        let wasEnabled = phoneControl.enabled
        let oldScope = phoneControl.selectedBundleIDs
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]
        defer {
            coordinator.cancelJobs(conversationId: conversationId)
            phoneControl.revoke(runID: runID)
            phoneControl.selectedBundleIDs = oldScope
            phoneControl.enabled = wasEnabled
            settingsDefaults.removePersistentDomain(forName: settingsSuite)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(phoneControl.claim(runID: runID, conversationID: conversationId.toHexDashString(), onStop: {}))
        XCTAssertTrue(
            coordinator.start(
                handoff: handoff,
                conversationStore: store,
                toolRuntime: runtime,
                liveActivityController: .shared
            )
        )
        try await waitUntil { await provider.callCount == 2 }
        assertions.expirations.first?()
        try await waitUntil { await provider.callCount == 3 }

        XCTAssertEqual(
            phoneControl.ownerRunID,
            runID,
            "Foreground auto-recovery of a phone-capable run must reclaim IOSPhoneControlController for the same runID"
        )
        await provider.release()
        try await waitUntil { coordinator.activeJobCount == 0 }
        await phoneControl.stop(runID: runID)
    }

    func testSpawnAgentStripsPhoneToolsFromDynamicChildAndRejectsExplicitPhoneToolScope() throws {
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let mixedTools = ToolKt.iosToolDeclarations(names: ["tools_list", "workspace_file_read"])
            + IOSPhoneControlToolCatalog.declarations
        let parentParams = IOSChatForegroundFixtures.makeParams(toolNames: [], tools: mixedTools)
        let bridge = IosToolExposureBridge(tools: mixedTools)
        let keepAlive = BackgroundKeepAliveAssertions().keepAlive(audioEnabled: false, foreground: true)
        let bgCoordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: IdleProvider())
        let launchPolicy = IOSOrchestrationLaunchPolicy(
            sharedSettingsProvider: { nil },
            modelPool: IOSSubAgentModelPool(),
            backgroundCoordinator: bgCoordinator
        )

        let dynamicResult = launchPolicy.resolveAgentLaunch(
            arguments: ["message": "后台分析参考文档"],
            providerSetting: providerSetting,
            params: parentParams,
            toolExposureBridge: bridge,
            inherited: nil
        )
        switch dynamicResult {
        case .failure(let error):
            XCTFail("Expected dynamic spawn resolution to succeed, got \(error.reason)")
        case .success(let resolved):
            XCTAssertFalse(
                resolved.params.tools.contains { IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name) },
                "Dynamic child agents must never inherit parent phone_* tools"
            )
            XCTAssertTrue(resolved.params.tools.contains { $0.name == "tools_list" })
        }

        let explicitPhoneScopeResult = launchPolicy.resolveAgentLaunch(
            arguments: ["message": "尝试操控手机", "tool_scope": ["phone_observe"]],
            providerSetting: providerSetting,
            params: parentParams,
            toolExposureBridge: bridge,
            inherited: nil
        )
        if case .success = explicitPhoneScopeResult {
            XCTFail("Explicit tool_scope requesting phone_* must fail closed for orchestrated child runs")
        }
    }

    func testOccupiedOrUnclaimedPhoneControllerExcludesPhoneToolsFromNewForegroundRequest() async throws {
        let suite = "PhoneOccupiedCatalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = IOSPhoneControlController(
            defaults: defaults,
            credentials: MemoryPairingStore(data: try Self.makePairingData()),
            localTunnel: PhoneControlTunnelStub()
        )
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "owner-run", onStop: {}))

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults, storageKey: "occupied-settings"),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            autoGenerateResponses: false,
            phoneControl: controller
        )
        let occupiedParams = viewModel.textGenerationParamsForTesting(includePhoneControlTools: true)
        let occupiedBridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(
            IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(occupiedParams.tools.map(\.name))),
            "A new turn while another run occupies phoneControl must not expose phone_* tools that would fail with run_not_authorized"
        )
        XCTAssertTrue(
            IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(occupiedBridge.fullToolDeclarations().map(\.name)))
        )

        // Even if params/bridge were assembled before another run claimed the controller, ChatRunRequestFactory must strip phone_* when runId is not the owner.
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let mixedTools = ToolKt.iosToolDeclarations(names: ["tools_list"]) + IOSPhoneControlToolCatalog.declarations
        let staleParams = IOSChatForegroundFixtures.makeParams(toolNames: [], tools: mixedTools)
        XCTAssertTrue(
            ChatViewModel.managerDelegationContractPrompt.contains("phone_"),
            "Manager delegation prompt must explicitly exclude foreground-bound phone_* automation from spawn_agent delegation"
        )
        let bindings = Self.makeBindings()
        let unclaimedRequest = ChatRunRequestFactory(
            bindings: bindings,
            maxToolResumeCount: 8,
            executionPolicy: nil,
            phoneAutomaticReasoning: true,
            phoneControl: controller,
            prepareUploadMessages: { $0 },
            approvalDecider: { _ in nil }
        ).make(
            adapterProvider: IdleProvider(),
            providerSetting: providerSetting,
            params: staleParams,
            runId: "unclaimed-second-run",
            startedAt: 1_700_000_000_000,
            inputDigest: "digest",
            conversationId: nil,
            initialMessages: [],
            toolExposureBridge: IosToolExposureBridge(tools: mixedTools),
            recipeCatalogSnapshot: nil,
            citationTracker: IOSMemoryCitationTracker(enforceCitationAllowlist: false)
        )
        XCTAssertTrue(
            IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(unclaimedRequest.params.tools.map(\.name)))
        )
        XCTAssertTrue(
            IOSPhoneControlToolCatalog.toolNames.isDisjoint(
                with: Set(unclaimedRequest.toolExposureBridge.fullToolDeclarations().map(\.name))
            )
        )
        await controller.stop(runID: "owner-run")
    }

    // MARK: - Item 3: Jev .phoneActions planning prompt alignment & phone_run_flow fallback guidance

    func testPhonePlanningPromptUsesFlowGuidanceWhenJevPhoneActionsNotActive() async throws {
        let standardStore = IOSSharedSettingsStore(userDefaults: .standard)
        let savedJev = standardStore.jevSettings
        defer { standardStore.updateJevSettings(savedJev) }

        var offSettings = IOSJevSettings()
        offSettings.modes[.phoneActions] = .off
        standardStore.updateJevSettings(offSettings)

        let suite = "PhonePromptModeOff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = IOSPhoneControlController(
            defaults: defaults,
            credentials: MemoryPairingStore(data: nil),
            localTunnel: PhoneControlTunnelStub()
        )

        let provider = CapturingUploadProvider()
        let engine = IOSAgentToolEngine(provider: provider, executors: [:])
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let params = IOSChatForegroundFixtures.makeParams(
            toolNames: [],
            tools: IOSPhoneControlToolCatalog.declarations
        )
        _ = await engine.run(
            providerSetting: providerSetting,
            messages: [IOSChatForegroundFixtures.userMessage("打开设置并切换开关")],
            params: params
        )
        let uploadedSystem = provider.lastPlanningPrompt
        XCTAssertTrue(uploadedSystem.contains("phone_run_flow"))
        XCTAssertFalse(
            uploadedSystem.contains("prefer one phone_run_goal call"),
            "When Jev .phoneActions is not active, planning prompt must not instruct the model to call phone_run_goal first"
        )
    }

    func testPhoneRunGoalFallbackHintsIncludePhoneRunFlow() async throws {
        let standardStore = IOSSharedSettingsStore(userDefaults: .standard)
        let savedJev = standardStore.jevSettings
        defer { standardStore.updateJevSettings(savedJev) }
        var offSettings = IOSJevSettings()
        offSettings.modes[.phoneActions] = .off
        standardStore.updateJevSettings(offSettings)

        let suite = "PhoneGoalFallbackHints.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(
            defaults: defaults,
            credentials: MemoryPairingStore(data: try Self.makePairingData()),
            localTunnel: PhoneControlTunnelStub()
        )
        controller.enabled = true
        controller.selectedBundleIDs = ["app.test"]
        XCTAssertTrue(controller.claim(runID: "goal-fallback-run", onStop: {}))

        let executor = IOSPhoneControlToolExecutor(runID: "goal-fallback-run", controller: controller)
        let modeOffOutcome = await executor.execute(
            name: "phone_run_goal",
            arguments: #"{"goal":"点击搜索","bundle_id":"app.test","completion":{"kind":"visible","target":{"identifier":"results"}}}"#,
            isUserInitiated: false
        )
        guard case .filled(let modeOffJSON) = modeOffOutcome else {
            await controller.stop(runID: "goal-fallback-run")
            return XCTFail("Expected filled handback JSON for mode_off, got \(modeOffOutcome)")
        }
        XCTAssertTrue(modeOffJSON.contains("phone_run_flow"), "mode_off fallback reason must mention phone_run_flow: \(modeOffJSON)")
        await controller.stop(runID: "goal-fallback-run")

        let helper = IOSPhoneGoalLoopTests()
        let initialScreen = helper.observation("initial", [
            helper.node("ref_a", id: "search_a"),
            helper.node("ref_b", id: "search_b"),
        ])
        let goalRequest = IOSPhoneGoalRequest(
            goal: "点击搜索",
            bundleID: "app.test",
            actions: [
                .init(action: .tap, target: .init(identifier: "search_a")),
                .init(action: .tap, target: .init(identifier: "search_b")),
            ],
            completion: .init(kind: .visible, target: .init(identifier: "results"))
        )

        let shadowFixture = IOSPhoneGoalLoopTests.Fixture([initialScreen])
        shadowFixture.mode = .shadow
        shadowFixture.selections = [.action("a0")]
        let shadowResult = await shadowFixture.loop().run(goalRequest)
        XCTAssertEqual(shadowResult.reasonCode, .shadowMode)
        XCTAssertTrue(shadowResult.reason.contains("phone_run_flow"), "shadow_mode reason must mention phone_run_flow: \(shadowResult.reason)")

        let unavailableFixture = IOSPhoneGoalLoopTests.Fixture([initialScreen])
        unavailableFixture.selections = [.handback("missing_key")]
        let unavailableResult = await unavailableFixture.loop().run(goalRequest)
        XCTAssertEqual(unavailableResult.reasonCode, .jevUnavailable)
        XCTAssertTrue(unavailableResult.reason.contains("phone_run_flow"), "jevUnavailable reason must mention phone_run_flow: \(unavailableResult.reason)")

        let failedFixture = IOSPhoneGoalLoopTests.Fixture([initialScreen])
        failedFixture.selections = [.handback("request_too_large")]
        let failedResult = await failedFixture.loop().run(goalRequest)
        XCTAssertEqual(failedResult.reasonCode, .jevFailed)
        XCTAssertTrue(failedResult.reason.contains("phone_run_flow"), "jevFailed reason must mention phone_run_flow: \(failedResult.reason)")
    }

    // MARK: - Helpers

    private static func makeBindings(messages: [UIMessage] = []) -> ChatGenerationBindings {
        ChatGenerationBindings(
            getMessages: { messages },
            setMessages: { _ in },
            bumpMessageRevision: { _, _ in },
            setIsLoading: { _ in },
            setPendingMemoryApproval: { _ in },
            setPendingSearchApproval: { _ in },
            setPendingWebMountApproval: { _ in },
            setPendingWorkspaceApproval: { _ in },
            setPendingIshHandoffApproval: { _ in },
            setPendingMcpApproval: { _ in },
            setPendingCouncilApproval: { _ in },
            setPendingAskUser: { _ in },
            setContextCompactState: { _ in },
            persistMessages: { _ in true },
            capturePersistMessagesBaseline: { _ in nil },
            persistMessagesSnapshot: { _, _, _ in true },
            recordRun: { _, _, _, _, _, _ in true },
            startLiveActivity: { _, _, _ in },
            saveMiniAppIfPresent: { _, _ in nil },
            messagesByInjectingRuntimeContext: { $0 },
            userFacingGenerationError: { raw, _ in raw }
        )
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try await !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = try await condition()
        XCTAssertTrue(satisfied)
    }

    private static func makePairingData() throws -> Data {
        let key = Curve25519.Signing.PrivateKey()
        let dict: [String: Any] = [
            "public_key": key.publicKey.rawRepresentation,
            "private_key": key.rawRepresentation,
            "identifier": UUID().uuidString,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
    private struct UncheckedExecuteInput: @unchecked Sendable {
        let executor: any IOSToolExecutor
        let tool: UIMessagePart.Tool
    }

    private nonisolated static func executeOffMainActor(
        _ input: UncheckedExecuteInput
    ) async -> IOSAgentToolOutcome {
        await input.executor.execute(tool: input.tool, isUserInitiated: false)
    }
}

private actor AddAppDiscoveryStub: PhoneControlApplicationDiscovering {
    let apps: [PhoneControlInstalledApp]
    init(_ apps: [PhoneControlInstalledApp]) { self.apps = apps }
    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) async throws -> [PhoneControlInstalledApp] {
        apps
    }
}

private struct UnreachableSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        throw URLError(.unsupportedURL)
    }
}

private struct IdleProvider: IOSAgentTextProvider {
    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        throw URLError(.cancelled)
    }
}

@MainActor
private final class CapturingUploadProvider: IOSAgentTextProvider, @unchecked Sendable {
    var lastPlanningPrompt: String = ""
    nonisolated func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        let planning = messages
            .filter(IOSPhoneAutomationRequestPolicy.isPlanningMessage)
            .map { $0.toText() }
            .joined(separator: "\n")
        await MainActor.run { self.lastPlanningPrompt = planning }
        return IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText("ok"))
    }
}

@MainActor
private final class BackgroundKeepAliveAutoAudio: BackgroundAudioKeepAliveControlling {
    var isActive = false
    var isStartingOrActive: Bool { isActive }
    func start() { isActive = true }
    func stop() { isActive = false }
}

@MainActor
private final class BackgroundKeepAliveAssertions {
    let audio = BackgroundKeepAliveAutoAudio()
    var expirations: [() -> Void] = []

    func keepAlive(audioEnabled: Bool, foreground: Bool) -> BackgroundGenerationKeepAlive {
        BackgroundGenerationKeepAlive(
            beginBackgroundTask: { [self] _, expire in
                expirations.append(expire)
                return UIBackgroundTaskIdentifier(rawValue: expirations.count)
            },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true },
            isApplicationForeground: { foreground },
            audioKeepAlive: audio,
            isAudioKeepAliveEnabled: { audioEnabled }
        )
    }
}

private actor RecoveryPhoneStatusProvider: IOSAgentTextProvider {
    var callCount = 0
    private var released = false

    func release() { released = true }

    private func nextRound() -> Int {
        callCount += 1
        return callCount
    }

    private func isReleased() -> Bool { released }

    nonisolated func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        let round = await nextRound()
        if round > 1 {
            while !(await isReleased()) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let parts: [UIMessagePart] = round == 1
            ? [
                UIMessagePart.Tool(
                    toolCallId: "probe-phone-status",
                    toolName: "phone_status",
                    input: "{}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ]
            : [UIMessagePart.Text(text: "done", metadata: nil)]
        return MessageChunk(
            id: UUID().uuidString,
            model: params.model.modelId,
            choices: [
                UIMessageChoice(
                    index: 0,
                    delta: nil,
                    message: UIMessage(
                        id: KotlinUuid.companion.random(),
                        role: .assistant,
                        parts: parts,
                        annotations: [],
                        createdAt: Kotlinx_datetimeLocalDateTime(
                            year: 2026, month: 11, day: 11, hour: 0, minute: 0, second: 0, nanosecond: 0
                        ),
                        finishedAt: nil,
                        modelId: nil,
                        usage: nil,
                        translation: nil
                    ),
                    finishReason: round == 1 ? "tool_calls" : "stop"
                )
            ],
            usage: nil
        )
    }
}
