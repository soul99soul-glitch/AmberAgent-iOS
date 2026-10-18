import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Shared Host harness and lifecycle cleanup for the concrete suites.
///
/// 这里钉「Host 把适配器回调接到真实副作用的序列」——暂停(markRunAwaitingPermission
/// 先于发卡、等待期 isLoading=false、脱敏快照先持久化)、恢复(resume 认领 +
/// 续跑)、三种终态(completed/failed/cancelled)各自的 CGC 对齐序列。
///
/// 复用前台 harness 的录制 bindings/依赖(同一装配);provider 是剧本化
/// generateText(引擎对非流式 provider 有回退,IOSAgentToolEngine :670)。
@MainActor
class IOSChatKernelRunHostTestCase: XCTestCase {

    typealias F = IOSChatForegroundFixtures

    override func setUp() async throws {
        try await super.setUp()
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()
        IOSBackgroundLifecycleLog.resetForTesting()
    }

    override func tearDown() async throws {
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()
        IOSBackgroundLifecycleLog.resetForTesting()
        try await super.tearDown()
    }

    final class YieldEventRecorder {
        var events: [String] = []
        var runId: String?
    }

    /// Minimal scheduler used only to make the real orchestration service
    /// executable in the Host test. `wait_agent` does not start a background
    /// job, but the service still requires its scheduling dependency.
    final class YieldBackgroundScheduler: IOSThreadOrchestrationToolService.BackgroundScheduling {
        var activeJobCount = 0

        func start(
            handoff: IOSChatBackgroundHandoff,
            conversationStore: IOSConversationStore,
            toolRuntime: ChatToolRuntime,
            liveActivityController: AgentLiveActivityController,
            saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
        ) -> Bool {
            true
        }

        func activeRunId(conversationHex: String) -> String? { nil }

        @discardableResult
        func cancelJob(runId: String) -> Bool { true }
    }

    // MARK: - 剧本化 provider

    /// generateText 轮次剧本。
    final class HostScriptedProvider: IOSAgentTextProvider, @unchecked Sendable {
        struct Round {
            let message: UIMessage
            let finishReason: String
        }

        private let lock = NSLock()
        private var rounds: [Round]
        private var uploads: [[UIMessage]] = []

        init(rounds: [Round]) {
            self.rounds = rounds
        }

        var callCount: Int { lock.withLock { uploads.count } }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let round = lock.withLock { () -> Round in
                uploads.append(messages)
                return rounds.isEmpty
                    ? Round(message: F.assistantText("stop"), finishReason: "stop")
                    : rounds.removeFirst()
            }
            return F.chunk(with: round.message, finishReason: round.finishReason)
        }
    }

    final class HostBlockingProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int { lock.withLock { calls } }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            lock.withLock { calls += 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return F.chunk(with: F.assistantText("unreachable"))
        }
    }

    final class HostBlockingSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int { lock.withLock { calls } }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { calls += 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return (
                IOSForegroundNoopSearchTransport.okResponse(for: request),
                Data(IOSForegroundNoopSearchTransport.resultHTML.utf8)
            )
        }
    }

    final class NonCooperativeSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var entered = false
        var isExecuting: Bool { lock.withLock { entered } }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            // Deliberately ignores Task cancellation until the external result arrives.
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    entered = true
                    if released { return true }
                    continuations.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
            return (IOSForegroundNoopSearchTransport.okResponse(for: request),
                    Data(IOSForegroundNoopSearchTransport.resultHTML.utf8))
        }

        func release() {
            let pending = lock.withLock {
                released = true
                defer { continuations.removeAll() }
                return continuations
            }
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    final class ImageExecutionGate {
        var started = false
        var released = false
    }

    // MARK: - 具装

    func makeHarness(
        exposedToolNames: [String] = [],
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport(),
        chatMaxToolResumeCount: Int? = nil,
        seedMessages: [UIMessage]? = nil,
        localToolExecutor: IOSLocalToolExecutor? = nil,
        persistMessages: @escaping @MainActor (KotlinUuid?) async -> Bool = { _ in true }
    ) -> IOSChatForegroundHarness {
        // Host 不驱动 CGC;harness 的 rounds 剧本留空(dispatch 不启动)。
        IOSChatForegroundHarness(
            exposedToolNames: exposedToolNames,
            seedMessages: seedMessages,
            searchTransport: searchTransport,
            chatMaxToolResumeCount: chatMaxToolResumeCount,
            localToolExecutor: localToolExecutor,
            persistMessages: persistMessages
        )
    }

    func makeHost(
        harness: IOSChatForegroundHarness,
        provider: IOSAgentTextProvider,
        phoneControl: IOSPhoneControlController = .shared
    ) -> ChatKernelRunHost {
        ChatKernelRunHost(
            dependencies: harness.dependencies,
            bindings: harness.bindings,
            backgroundExecution: harness.keepAlive,
            toolLedger: harness.ledger,
            textProvider: provider,
            phoneControl: phoneControl
        )
    }

    /// Assemble just enough production wiring to exercise the complete
    /// `wait_agent` → Engine result.yielded → Adapter callback → Host teardown
    /// path. The shared harness intentionally has no orchestration service,
    /// so this fixture keeps that dependency isolated to this regression.
    func makeForegroundYieldHost() async throws -> (
        host: ChatKernelRunHost,
        provider: HostScriptedProvider,
        recorder: YieldEventRecorder,
        conversationId: KotlinUuid,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostForegroundYield-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = IOSConversationStore(baseDirectory: directory)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let database = IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("yield.db").path
        )
        try await database.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: KotlinUuid.companion.random().toHexDashString(),
            parentThreadId: conversationId.toHexDashString(),
            agentPath: "/root/worker", nickname: nil, roleAssistantId: nil,
            forkTurns: "all", status: "Open", createdAt: 0
        ))
        let center = IOSMailboxActivityCenter()
        let scheduler = YieldBackgroundScheduler()
        let service = IOSThreadOrchestrationToolService(
            conversationStoreProvider: { store },
            mailboxDaoProvider: { database.mailboxDao() },
            threadEdgeDaoProvider: { database.threadEdgeDao() },
            agentRuntimeDaoProvider: { database.agentRuntimeDao() },
            backgroundCoordinator: scheduler,
            makeBackgroundToolRuntime: {
                ChatToolRuntime(
                    settingsStore: SettingsStore(),
                    sharedSettings: IOSSharedSettingsStore(),
                    localToolExecutor: nil,
                    searchTransport: IOSURLSessionSearchHTTPTransport(),
                    mcpManager: IOSMcpManager(serverProvider: { [] })
                )
            },
            currentConversationId: { conversationId },
            foregroundActiveRunId: { _ in "foreground-yield-run" },
            cancelForegroundRun: { _ in false },
            activityCenter: center
        )

        let defaultsSuite = "KernelHostForegroundYield-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        let settingsStore = SettingsStore(
            userDefaults: defaults,
            storageKey: "foreground-yield-settings"
        )
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let dependencies = ChatGenerationDependencies(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: IOSForegroundNoopSearchTransport(),
            liveActivityController: .shared,
            autoGenerateResponses: true,
            mcpManager: IOSMcpManager(serverProvider: { [] }),
            orchestrationToolService: service,
            memoryPollutionMarker: nil,
            conversationStoreProvider: { store }
        )

        var messages = [F.userMessage("等待子代理")]
        let recorder = YieldEventRecorder()
        let keepAlive = BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 902) },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true },
            audioKeepAlive: NoOpBackgroundAudioKeepAlive(),
            isAudioKeepAliveEnabled: { false }
        )
        var bindings = ChatGenerationBindings(
            getMessages: { messages },
            setMessages: { messages = $0 },
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
            recordRun: { runId, _, status, _, _, _ in
                if status == .running { recorder.runId = runId }
                return true
            },
            startLiveActivity: { _, _, _ in },
            saveMiniAppIfPresent: { _, _ in nil },
            messagesByInjectingRuntimeContext: { $0 },
            userFacingGenerationError: { rawMessage, _ in rawMessage }
        )
        bindings.onForegroundYield = { runId in
            recorder.events.append("yield:\(runId)")
        }
        bindings.handleSteerQueueAtTerminal = { _, autoContinue in
            recorder.events.append("steer:\(autoContinue)")
        }

        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: ["wait_agent"])
        )
        let provider = HostScriptedProvider(rounds: [
            toolRound("wait-1", "wait_agent", #"{"timeout_ms":60000}"#)
        ])
        let host = ChatKernelRunHost(
            dependencies: dependencies,
            bindings: bindings,
            backgroundExecution: keepAlive,
            // Keep the provider-before-tool request snapshot deterministic;
            // the Room-backed production ledger uses the shared default DB,
            // which is intentionally not part of this isolated fixture.
            toolLedger: IOSRunEventLogLedger(log: IOSRunEventLog()),
            textProvider: provider
        )
        host.start(
            providerSetting: F.makeProviderSetting(),
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            inputDigest: "foreground-yield-test",
            conversationId: conversationId,
            uploadMessages: messages,
            toolExposureBridge: bridge
        )
        return (host, provider, recorder, conversationId, directory)
    }

    func makeIshLocalExecutor() -> IOSLocalToolExecutor {
        let defaults = UserDefaults(suiteName: "terminal-approval-\(UUID().uuidString)")!
        return IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: defaults),
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
    }

    func start(_ host: ChatKernelRunHost, harness: IOSChatForegroundHarness) {
        host.start(
            providerSetting: harness.providerSetting,
            params: harness.params,
            inputDigest: "kernel-host-test",
            conversationId: harness.conversationId,
            uploadMessages: harness.messages,
            toolExposureBridge: harness.toolExposureBridge
        )
    }

    func toolRound(_ toolCallId: String, _ toolName: String, _ input: String) -> HostScriptedProvider.Round {
        HostScriptedProvider.Round(
            message: F.assistantMessage(parts: [
                UIMessagePart.Tool(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    input: input,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
            ]),
            finishReason: "stop"
        )
    }

    func textRound(_ text: String) -> HostScriptedProvider.Round {
        HostScriptedProvider.Round(message: F.assistantText(text), finishReason: "stop")
    }

    // MARK: - 等待器

    func waitForHostIdle(_ host: ChatKernelRunHost, timeoutSeconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !host.isRunning { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForCondition(
        timeoutSeconds: Double = 10,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func startPhoneProgressRun(exposedToolNames: [String] = ["session_search"]) async throws -> (
        host: ChatKernelRunHost, harness: IOSChatForegroundHarness, provider: IOSChatProgressStreamingProvider,
        phoneControl: IOSPhoneControlController, defaults: UserDefaults, suite: String
    ) {
        let suite = "KernelHostPhoneProgress-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let phoneControl = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
        await phoneControl.refreshPreparation()
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]
        let harness = makeHarness(exposedToolNames: exposedToolNames)
        let provider = IOSChatProgressStreamingProvider()
        let host = makeHost(harness: harness, provider: provider, phoneControl: phoneControl)
        let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations
            + ToolKt.iosToolDeclarations(names: exposedToolNames))
        bridge.exposeToolNames(names: exposedToolNames)
        host.start(providerSetting: harness.providerSetting,
                   params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
                   inputDigest: "phone-progress", conversationId: harness.conversationId,
                   uploadMessages: harness.messages, toolExposureBridge: bridge, phoneControlUserInitiated: true)
        return (host, harness, provider, phoneControl, defaults, suite)
    }

    func phoneReasoningParams(
        harness: IOSChatForegroundHarness,
        storedLevel: String,
        resolvedLevel: ReasoningLevel,
        tools: [Tool]
    ) throws -> (ProviderSetting.OpenAI, TextGenerationParams) {
        let model = Model(
            modelId: "deepseek-flash", displayName: "DeepSeek Flash",
            id: KotlinUuid.companion.random(), type: .chat,
            customHeaders: [], customBodies: [], inputModalities: [.text], outputModalities: [.text],
            abilities: [.tool, .reasoning], tools: Set<BuiltInTools>(),
            contextWindowTokens: nil, providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Phone reasoning fixture",
            models: [model], balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil,
            apiKey: "", baseUrl: "https://api.deepseek.com/v1", chatCompletionsPath: "/chat/completions",
            useResponseApi: false, authMode: .apiKey, brand: .deepseek
        )
        let settings = harness.dependencies.sharedSettings
        _ = settings.addProvider(provider)
        settings.setCurrentChatModelId(model.id.description())
        settings.setCurrentAssistantChatModelId(model.id.description())
        // Restore the raw stored choice: the public picker intentionally coerces AUTO to HIGH.
        let encoded = IosSettingsJsonBridge.shared.encode(settings: settings.snapshot)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        var assistants = try XCTUnwrap(fields["assistants"] as? [[String: Any]])
        let activeID = settings.snapshot.getCurrentAssistant().id.description()
        let index = try XCTUnwrap(assistants.firstIndex { $0["id"] as? String == activeID })
        assistants[index]["reasoningLevel"] = storedLevel
        assistants[index]["rememberedReasoningLevelsByModelId"] = [model.id.description(): storedLevel]
        fields["assistants"] = assistants
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        XCTAssertTrue(settings.restoreSnapshot(try IosSettingsJsonBridge.shared.decode(json: json)))
        return (provider, TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: tools,
            reasoningLevel: resolvedLevel, customHeaders: [], customBody: []
        ))
    }
}
