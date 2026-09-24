import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Generation-parameter + system-prompt parity tests (Android GenerationHandler
/// parity). Verifies makeTextGenerationParams reads real Assistant/Model
/// values instead of hardcoding temperature=0.7/topP=nil/maxTokens=nil, and
/// that the assistant system prompt is injected into the upload context.
@MainActor
final class ChatViewModelGenerationParamsTests: XCTestCase {
    func testOpenCodeSessionFollowsConversationAcrossTurnsAndBackgroundRestore() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let provider = sharedSettings.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Go", apiKey: "test", baseUrl: "https://opencode.ai/zen/go/v1",
            modelName: "Test", modelId: "test"
        ))
        let model = try XCTUnwrap(provider.models.first)
        sharedSettings.setCurrentChatModelId(model.id.description())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationA = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: isolatedDefaults()),
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        viewModel.conversationStore = store
        viewModel.messages = [.companion.user(prompt: "first turn")]
        let first = viewModel.textGenerationParamsForTesting()
        XCTAssertEqual(first.customHeaders.first { $0.name == "x-opencode-session" }?.value,
                       conversationA.toHexDashString())
        viewModel.messages = [.companion.user(prompt: "compacted later turn")]
        XCTAssertEqual(viewModel.textGenerationParamsForTesting().customHeaders.map(\.value),
                       first.customHeaders.map(\.value))

        let strippedParams = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
            reasoningLevel: .off, customHeaders: [], customBody: []
        )
        let restored = try XCTUnwrap(IOSChatBackgroundGenerationCoordinator.rehydratedParamsForTesting(
            persistedParams: strippedParams, providerSetting: provider,
            assistantHeaders: [], assistantBodies: [], conversationId: conversationA.toHexDashString()
        ))
        XCTAssertEqual(restored.customHeaders.first { $0.name == "x-opencode-session" }?.value,
                       conversationA.toHexDashString())

        await store.newConversation()
        let conversationB = try XCTUnwrap(store.currentConversation?.id)
        XCTAssertNotEqual(conversationA, conversationB)
        XCTAssertEqual(viewModel.textGenerationParamsForTesting().customHeaders.first {
            $0.name == "x-opencode-session"
        }?.value, conversationB.toHexDashString())
    }

    func testMimoV26ModelDefaultsSurvivePersistenceAndEnableImages() throws {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = store.addProvider(IosSettingsMutations.shared.buildBlankOpenAIProvider(
            name: "MiMo", apiKey: "mimo-capability-test", baseUrl: "https://api.xiaomimimo.com/v1"
        ))
        let modelIds = ["mimo-v2.6-pro", "mimo-v2.6-flash", "mimo-v2.6-pro-ultraspeed"]
        _ = store.mergeProviderChatModels(
            providerId: provider.id.description(),
            models: modelIds.map { (modelId: $0, displayName: $0) }
        )
        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        let savedProvider = try XCTUnwrap(reloaded.snapshot.providers.first { $0.id == provider.id })
        for model in savedProvider.models {
            XCTAssertEqual(model.inputModalities.map(\.name), ["TEXT", "IMAGE", "AUDIO", "VIDEO"])
            XCTAssertEqual(model.abilities.map(\.name), ["TOOL", "REASONING"])
            XCTAssertNil(model.contextWindowTokens, "使用注册表默认窗口，不写入伪装成手动覆盖的值")
            XCTAssertEqual(ChatContextSnapshot.resolvedContextWindowTokens(modelWindow: nil, modelId: model.modelId), 1_000_000)
            XCTAssertEqual(ChatContextSnapshot.resolvedContextWindowTokens(modelWindow: 128_000, modelId: model.modelId), 128_000)
            reloaded.setCurrentChatModelId(model.id.description())
            reloaded.setCurrentAssistantChatModelId(model.id.description())
            let viewModel = ChatViewModel(
                settingsStore: SettingsStore(userDefaults: isolatedDefaults()),
                sharedSettings: reloaded, autoGenerateResponses: false
            )
            viewModel.addPendingImage(dataUrl: "data:image/png;base64,AAAA", previewData: Data())
            XCTAssertEqual(viewModel.imageAttachmentState, .ready, model.modelId)
        }
        XCTAssertEqual(savedProvider.models.count, modelIds.count)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ChatViewModelGenerationParamsTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func localToolExecutor(
        permissionStore: IOSPermissionStore? = nil
    ) -> IOSLocalToolExecutor {
        IOSLocalToolExecutor(
            permissionStore: permissionStore ?? IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
    }

    private func exposureViewModel(permissionStore: IOSPermissionStore? = nil) -> ChatViewModel {
        ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(permissionStore: permissionStore),
            autoGenerateResponses: false
        )
    }

    private func executedToolMessage(_ name: String, output: String) -> UIMessage {
        let base = UIMessage.companion.assistant(prompt: "")
        return UIMessage(
            id: base.id, role: .assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: UUID().uuidString, toolName: name, input: "{}",
                output: [UIMessagePart.Text(text: output, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )],
            annotations: [], createdAt: base.createdAt, finishedAt: nil,
            modelId: nil, usage: nil, translation: nil
        )
    }

    func testDiscoveredToolSurvivesFiveUserTurnsAndExpiresOnSixth() throws {
        let viewModel = exposureViewModel()
        viewModel.messages = [.companion.user(prompt: "浏览网页")]
        _ = viewModel.textGenerationParamsForTesting()
        let bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        let search = bridge.executeToolSearch(argumentsJson: #"{"query":"wm_click","limit":1}"#)
        viewModel.messages.append(executedToolMessage("tool_search", output: search))

        for turn in 1...5 {
            viewModel.messages.append(.companion.user(prompt: "第 \(turn) 轮"))
            XCTAssertTrue(viewModel.currentToolDeclarationNames().contains("wm_click"), "turn \(turn)")
            viewModel.messages.append(.companion.assistant(prompt: "完成"))
        }
        XCTAssertTrue(viewModel.currentToolDeclarationNames().contains("wm_click"), "rebuilding the same turn must not age tools")
        viewModel.messages.append(.companion.user(prompt: "第 6 轮"))
        XCTAssertFalse(viewModel.currentToolDeclarationNames().contains("wm_click"))
    }

    func testActualToolUseRenewsFiveTurnsAndBrowserCore() {
        let viewModel = exposureViewModel()
        viewModel.messages = [.companion.user(prompt: "点击网页")]
        viewModel.messages.append(executedToolMessage("wm_click", output: #"{"ok":true}"#))
        for _ in 1...5 {
            viewModel.messages.append(.companion.user(prompt: "继续"))
        }
        XCTAssertTrue(viewModel.currentToolDeclarationNames().contains("wm_click"))
        viewModel.messages.append(executedToolMessage("wm_click", output: #"{"ok":true}"#))
        for _ in 1...5 {
            viewModel.messages.append(.companion.user(prompt: "继续"))
        }
        let renewed = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(renewed.isSuperset(of: ["wm_click", "wm_tab_list", "wm_open", "wm_observe", "wm_wait"]))
        viewModel.messages.append(.companion.user(prompt: "换话题"))
        XCTAssertFalse(viewModel.currentToolDeclarationNames().contains("wm_click"))
    }

    func testRestoredToolsStayInCurrentConversationAndRespectDisabledCapability() throws {
        let permissions = IOSPermissionStore(userDefaults: isolatedDefaults())
        let viewModel = exposureViewModel(permissionStore: permissions)
        let history = [
            UIMessage.companion.user(prompt: "运行命令"),
            executedToolMessage("ish_handoff", output: #"{"ok":true}"#),
            UIMessage.companion.user(prompt: "继续")
        ]
        viewModel.messages = history
        XCTAssertTrue(viewModel.currentToolDeclarationNames().contains("ish_handoff"))
        viewModel.messages = [.companion.user(prompt: "新会话")]
        XCTAssertFalse(viewModel.currentToolDeclarationNames().contains("ish_handoff"))
        viewModel.messages = history
        let capability = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first {
            $0.id == "ios.external.ish_handoff"
        })
        permissions.setPolicy(.disabled, for: capability)
        XCTAssertFalse(viewModel.currentToolDeclarationNames().contains("ish_handoff"))
    }

    /// The default seeded Amber Assistant carries a non-empty systemPrompt.
    /// The upload context must include it as a leading system message so the
    /// model receives the assistant's persona/instructions (Android parity).
    func testAssistantSystemPromptIsInjectedIntoUploadContext() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        viewModel.inputText = "hello"
        viewModel.sendMessage()

        let uploadMessages = viewModel.preparedUploadMessagesForTesting(viewModel.messages)
        let assistantSystemPrompt = sharedSettings.snapshot.getCurrentAssistant().systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The first upload message must be the assistant system prompt (it is
        // injected before memory/MCP/mini-app/user).
        XCTAssertFalse(assistantSystemPrompt.isEmpty, "default assistant should have a system prompt")
        let first = uploadMessages.first
        XCTAssertEqual(first?.role, MessageRole.system)
        XCTAssertTrue((first?.toText() ?? "").contains(String(assistantSystemPrompt.prefix(40))))
    }

    /// System prompt must be upload-only — never persisted into the visible
    /// chat history (it would pollute the message list).
    func testSystemPromptInjectionDoesNotPersistToChatHistory() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "hello"
        viewModel.sendMessage()

        // Persisted messages must contain only the user message — no system
        // message from the injection.
        XCTAssertFalse(viewModel.messages.contains { $0.role == MessageRole.system })
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.role, MessageRole.user)
    }

    func testSoulIsInjectedOnceInForegroundAndChildAssemblers() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setAgentSoulMarkdown("SOUL_CANARY_UNIQUE")
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        let upload = viewModel.preparedUploadMessagesForTesting([
            UIMessage.companion.user(prompt: "hello")
        ])
        let soulTexts = upload
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .filter { $0.contains("SOUL_CANARY_UNIQUE") }
        XCTAssertEqual(soulTexts.count, 1)
        XCTAssertTrue(soulTexts[0].contains("<agents_md>"))
        XCTAssertFalse(viewModel.messages.contains { $0.toText().contains("SOUL_CANARY_UNIQUE") })

        let child = IOSThreadOrchestrationToolService.childUploadMessages(
            targetMessages: [UIMessage.companion.user(prompt: "child")],
            soulMarkdown: "SOUL_CANARY_UNIQUE"
        )
        XCTAssertEqual(
            child.filter { $0.toText().contains("SOUL_CANARY_UNIQUE") }.count,
            1
        )
        XCTAssertTrue(child.contains { $0.toText().contains("child agent thread") })
    }

    /// makeTextGenerationParams must succeed and produce a non-empty tool list
    /// (the tool declarations are independent of the params fix, but this guards
    /// against the real-params refactor throwing on snapshot access).
    func testMakeTextGenerationParamsProducesValidParams() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        let params = viewModel.textGenerationParamsForTesting()
        // The default assistant has temperature == null, so the resolved
        // temperature must be nil (NOT the old hardcoded 0.7).
        XCTAssertNil(params.temperature, "temperature should come from Assistant (null by default), not hardcoded 0.7")
        XCTAssertNil(params.topP)
        XCTAssertNotNil(params.model)
        XCTAssertFalse(params.tools.isEmpty, "tool declarations must be populated")
    }

    func testRuntimeGenerationPreservesCustomImageModalityAndUploadsImage() async throws {
        let defaults = isolatedDefaults()
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let model = Model(
            modelId: "amber-custom-vision-unknown-\(UUID().uuidString)",
            displayName: "Custom Vision",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [.text, .image],
            outputModalities: [.text],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Custom Vision Provider",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        _ = sharedSettings.addProvider(provider)
        sharedSettings.setCurrentChatModelId(model.id.description())
        sharedSettings.setCurrentAssistantChatModelId(model.id.description())

        let registryModalities = ModelRegistry.shared.MODEL_INPUT_MODALITIES
            .getData(modelId: model.modelId) as? [Modality] ?? []
        XCTAssertFalse(registryModalities.contains(.image), "fixture must be unknown to the model registry")

        let recordingProvider = RuntimeImageRecordingProvider()
        let auxiliaryProvider = RuntimeImageRecordingProvider()
        let databaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelGenerationParamsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let database = IosDatabaseFactory.shared.createDatabase(
            atFilePath: databaseDirectory.appendingPathComponent("agent-runtime.sqlite").path
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: sharedSettings,
            autoGenerateResponses: true,
            auxiliaryTextProvider: auxiliaryProvider,
            agentRuntimeDao: database.agentRuntimeDao()
        )
        viewModel.kernelTextProviderOverrideForTesting = recordingProvider
        let dataUrl = "data:image/jpeg;base64,AAAA"
        viewModel.addPendingImage(dataUrl: dataUrl, previewData: Data("thumb".utf8))
        viewModel.inputText = "请描述这张图片"

        XCTAssertTrue(viewModel.sendMessage())
        let uploadDeadline = Date().addingTimeInterval(5)
        while recordingProvider.lastUpload == nil, Date() < uploadDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let upload = try XCTUnwrap(recordingProvider.lastUpload)
        XCTAssertTrue(upload.contains { message in
            message.parts.contains { part in
                (part as? UIMessagePart.Image)?.url == dataUrl
            }
        }, "the real ChatKernelRunHost upload must retain the image part")

        let terminalDeadline = Date().addingTimeInterval(5)
        while viewModel.isLoading, Date() < terminalDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading, "the real ChatKernelRunHost run must reach a terminal state")
    }

    func testAuxiliaryGenerationParamsPreserveProviderMergedModelOverrides() {
        let json = Kotlinx_serialization_jsonJson.companion
        let model = Model(
            modelId: "aux-model",
            displayName: "Aux Model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [CustomHeader(name: "X-Aux", value: "enabled")],
            customBodies: [
                CustomBody(
                    key: "service_tier",
                    value: json.parseToJsonElement(string: "\"priority\"")
                )
            ],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )

        let params = ChatViewModel.auxiliaryTextGenerationParamsForTesting(
            model: model,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: IosSettingsMutations.shared.buildOpenAIProvider(
                    name: "Aux", apiKey: "test", baseUrl: "https://example.test/v1",
                    modelName: "Aux", modelId: "aux-model"
                ),
                assistant: [CustomHeader(name: "X-Assistant", value: "assistant")],
                model: model.customHeaders
            ),
            assistantBodies: [
                CustomBody(
                    key: "assistant_flag",
                    value: json.parseToJsonElement(string: "true")
                )
            ]
        )

        XCTAssertEqual(params.customHeaders.map(\.name), ["X-Assistant", "X-Aux"])
        XCTAssertEqual(params.customHeaders.map(\.value), ["assistant", "enabled"])
        XCTAssertEqual(params.customBody.map(\.key), ["assistant_flag", "service_tier"])
        XCTAssertEqual(params.customBody.map { $0.value.description }, ["true", "\"priority\""])
    }

    /// The visible resident declarations and full catalog must stay aligned
    /// after the params refactor. P0-a: the default config declares >40 tools,
    /// so the new orchestration tools are discoverable in the full catalog and
    /// exposed through tool_search instead of being first-round declarations.
    func testToolDeclarationsStillIncludeCoreTools() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(names.contains("model_council_run"))
        XCTAssertTrue(names.contains("ask_user"))
        // P0-a: the discovery tool itself is always resident.
        XCTAssertTrue(names.contains("tool_search"))
        // Workspace read AND write tools are always declared; the approval gate
        // and the injected workspace policy prompt (not keyword detection) stop
        // unsanctioned writes.
        XCTAssertTrue(names.contains("workspace_file_list"))
        XCTAssertTrue(names.contains("workspace_file_search"))
        XCTAssertTrue(names.contains("workspace_file_write"))
        XCTAssertTrue(names.contains("workspace_file_edit"))
        XCTAssertTrue(names.contains("workspace_file_move"))
        XCTAssertTrue(names.contains("workspace_artifact_delete"))
        // P0-a: iSH execution/handoff and the WebMount catalog are deferred in
        // the default (>40 tools) config — the model reaches them by calling
        // tool_search with a concrete query, not on the first round.
        XCTAssertFalse(names.contains("ish_handoff"))
        XCTAssertTrue(names.isDisjoint(with: IOSEmbeddedIshToolCatalog.supportedToolNames))
        XCTAssertTrue(names.isDisjoint(with: IOSWebMountToolCatalog.supportedToolNames))

        let fullNames = Set(viewModel.toolExposureBridgeForTesting()?.fullToolDeclarations().map(\.name) ?? [])
        XCTAssertTrue(fullNames.contains("spawn_agent"), "orchestration uses spawn_agent in the full catalog")
        XCTAssertTrue(fullNames.contains("session_search"), "session tools belong to the full catalog")
        XCTAssertFalse(fullNames.contains("subagent_dispatch"), "the retired dispatch tool must not be reintroduced")
    }

    /// P0-a: iSH tools are no longer first-round declarations in the default
    /// heavy config — they are discovered via tool_search (which returns them
    /// as expanded_tools for the next step).
    func testIshToolsDeferredBehindToolSearchForPlainIshRequest() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "用内置 iSH 执行 uname -a，并返回 stdout stderr exit code"
        viewModel.sendMessage()

        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(names.contains("tool_search"))
        XCTAssertFalse(names.contains("ish_handoff"))
        XCTAssertTrue(names.isDisjoint(with: IOSEmbeddedIshToolCatalog.supportedToolNames))

        let bridge = viewModel.toolExposureBridgeForTesting()
        let payload = bridge?.executeToolSearch(argumentsJson: #"{"query":"ish_handoff","limit":1}"#) ?? ""
        XCTAssertTrue(payload.contains("ish_handoff"))
    }

    func testWeatherToolIsDiscoverableThroughProductionExposureBridge() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        _ = viewModel.textGenerationParamsForTesting()

        let bridge = viewModel.toolExposureBridgeForTesting()
        XCTAssertTrue(bridge?.fullToolDeclarations().map(\.name).contains("weather_read") == true)
        let payload = bridge?.executeToolSearch(
            argumentsJson: #"{"query":"weather_read","limit":1}"#
        ) ?? ""
        XCTAssertTrue(payload.contains("weather_read"), payload)
    }

    func testExternalIshHandoffDiscoverableViaToolSearch() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "交接到外部 iSH App，复制脚本到剪贴板，我手动粘贴执行"
        viewModel.sendMessage()

        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(names.contains("tool_search"))
        XCTAssertFalse(names.contains("ish_handoff"))

        let bridge = viewModel.toolExposureBridgeForTesting()
        let payload = bridge?.executeToolSearch(argumentsJson: #"{"query":"ish_handoff","limit":1}"#) ?? ""
        XCTAssertTrue(payload.contains("ish_handoff"))
    }

    /// Workspace write tools are always declared regardless of the latest user
    /// message wording — including a message with no write keyword at all. The
    /// approval gate and the injected workspace policy prompt (not keyword
    /// detection) are what stop unsanctioned writes.
    func testWorkspaceWriteToolsAlwaysDeclaredEvenWithoutWriteRequest() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )

        viewModel.inputText = "试试 Markdown，写几个格式示例"
        viewModel.sendMessage()

        let markdownDemoNames = Set(viewModel.currentToolDeclarationNames())
        XCTAssertEqual(
            markdownDemoNames.intersection(IOSWorkspaceToolCatalog.supportedToolNames),
            IOSWorkspaceToolCatalog.supportedToolNames
        )

        let explicitWriteViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        explicitWriteViewModel.inputText = "把上面的 Markdown 保存到 Workspace 文件 /workspace/notes/demo.md"
        explicitWriteViewModel.sendMessage()

        let explicitWriteNames = Set(explicitWriteViewModel.currentToolDeclarationNames())
        XCTAssertEqual(
            explicitWriteNames.intersection(IOSWorkspaceToolCatalog.supportedToolNames),
            IOSWorkspaceToolCatalog.supportedToolNames
        )
    }

    func testDisabledAdvancedCapabilityIsNotDeclaredToModel() throws {
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults())
        let subAgent = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.agent.subagent_dispatch" }
        )
        let council = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.agent.model_council_run" }
        )
        let ish = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.external.ish_handoff" }
        )
        let embeddedIsh = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.embedded.ish_runtime" }
        )
        permissionStore.setPolicy(.disabled, for: subAgent)
        permissionStore.setPolicy(.disabled, for: council)
        permissionStore.setPolicy(.disabled, for: ish)
        permissionStore.setPolicy(.disabled, for: embeddedIsh)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(permissionStore: permissionStore),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())

        XCTAssertFalse(names.contains("subagent_dispatch"))
        XCTAssertFalse(names.contains("model_council_run"))
        XCTAssertFalse(names.contains("ish_handoff"))
        XCTAssertFalse(names.contains("ios_ish_execute"))
    }

    /// G7: 前台工具循环上限参数化——默认 24，clamp 24-384，UserDefaults 持久化。
    func testChatMaxToolResumeCountDefaultsToTwentyFourAndClamps() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.chatMaxToolResumeCount, 24)

        store.chatMaxToolResumeCount = 23
        XCTAssertEqual(store.chatMaxToolResumeCount, 24)

        store.chatMaxToolResumeCount = 256
        XCTAssertEqual(SettingsStore(userDefaults: defaults).chatMaxToolResumeCount, 256)

        store.chatMaxToolResumeCount = 384
        XCTAssertEqual(SettingsStore(userDefaults: defaults).chatMaxToolResumeCount, 384)

        store.chatMaxToolResumeCount = 385
        XCTAssertEqual(store.chatMaxToolResumeCount, 384)

        store.chatMaxToolResumeCount = 9
        XCTAssertEqual(SettingsStore(userDefaults: defaults).chatMaxToolResumeCount, 24)
    }

    // MARK: - P3-a: exec 工具开关（默认关，开时进 deferred 池）

    func testExecSwitchDefaultsToOffAndPersists() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.execJavaScriptEnabled, "exec 开关默认关")

        store.execJavaScriptEnabled = true
        XCTAssertTrue(SettingsStore(userDefaults: defaults).execJavaScriptEnabled, "开关必须持久化")
    }

    func testExecZeroTraceInFullCatalogWhenSwitchOff() {
        let defaults = isolatedDefaults()
        let settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.execJavaScriptEnabled = false
        let viewModel = ChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertFalse(names.contains("exec"), "开关关时首轮声明不得含 exec")

        // 零痕迹也覆盖桥输入全目录——tool_search 也搜不到 exec。
        let bridge = viewModel.toolExposureBridgeForTesting()
        let fullNames = bridge?.fullToolDeclarations().map(\.name) ?? []
        XCTAssertFalse(fullNames.contains("exec"), "开关关时全目录也不得含 exec")
    }

    func testExecEntersDeferredPoolWhenSwitchOn() {
        let defaults = isolatedDefaults()
        let settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.execJavaScriptEnabled = true
        let viewModel = ChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertFalse(names.contains("exec"), "exec 非常驻：首轮声明不含（deferred 池）")

        let bridge = viewModel.toolExposureBridgeForTesting()
        let fullNames = bridge?.fullToolDeclarations().map(\.name) ?? []
        XCTAssertTrue(fullNames.contains("exec"), "开关开时 exec 必须进桥输入全目录")

        // tool_search 精确命中后，exec 进入下轮声明。
        let payload = bridge?.executeToolSearch(argumentsJson: #"{"query":"exec","limit":1}"#) ?? ""
        XCTAssertTrue(payload.contains("exec"), "tool_search 必须能命中 exec")
        let visible = bridge?.visibleTools().map(\.name) ?? []
        XCTAssertTrue(visible.contains("exec"), "命中后 exec 必须出现在下轮可见声明")
    }

    func testLocalToolDeclarationsMatchCatalogAndCapabilityRegistry() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        let paramsNames = Set(viewModel.currentToolDeclarationNames())
        let executableNames = IOSCapabilityRegistry.executableToolNames
        let workspaceNames = IOSWorkspaceToolCatalog.supportedToolNames
        let ishNames = IOSIshToolCatalog.supportedToolNames
        let embeddedIshNames = IOSEmbeddedIshToolCatalog.supportedToolNames
        let webMountNames = IOSWebMountToolCatalog.supportedToolNames

        // Workspace tools are resident and always declared; iSH + WebMount are
        // deferred behind tool_search in the default (>40 tools) config.
        XCTAssertEqual(paramsNames.intersection(workspaceNames), workspaceNames)
        XCTAssertTrue(paramsNames.isDisjoint(with: ishNames))
        XCTAssertTrue(paramsNames.isDisjoint(with: embeddedIshNames))
        XCTAssertTrue(paramsNames.isDisjoint(with: webMountNames))
        XCTAssertEqual(executableNames.intersection(workspaceNames), workspaceNames)
        XCTAssertEqual(executableNames.intersection(ishNames), ishNames)
        XCTAssertEqual(executableNames.intersection(embeddedIshNames), embeddedIshNames)
        XCTAssertEqual(executableNames.intersection(webMountNames), webMountNames)

        // tool_search is the discovery path for the deferred catalogs.
        XCTAssertTrue(paramsNames.contains("tool_search"))
        let bridge = viewModel.toolExposureBridgeForTesting()
        let payload = bridge?.executeToolSearch(argumentsJson: #"{"query":"wm_tab_list","limit":1}"#) ?? ""
        XCTAssertTrue(payload.contains("wm_tab_list"))
        XCTAssertTrue(bridge?.visibleTools().map(\.name).contains("wm_tab_list") ?? false)

        viewModel.inputText = "创建 Workspace 文件 /workspace/check.md"
        viewModel.sendMessage()
        let explicitWriteNames = Set(viewModel.currentToolDeclarationNames())
        XCTAssertEqual(explicitWriteNames.intersection(workspaceNames), workspaceNames)

        let skillViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        skillViewModel.inputText = "生成一份技能说明"
        skillViewModel.sendMessage()
        let skillWriteNames = Set(skillViewModel.currentToolDeclarationNames())
        XCTAssertEqual(skillWriteNames.intersection(workspaceNames), workspaceNames)
    }
}

private final class RuntimeImageRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var uploads: [[UIMessage]] = []

    var lastUpload: [UIMessage]? {
        lock.withLock { uploads.last }
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        lock.withLock { uploads.append(messages) }
        return MessageChunk(
            id: "custom-vision-upload-test",
            model: params.model.modelId,
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: UIMessage.companion.assistant(prompt: "收到图片"),
                finishReason: "stop"
            )],
            usage: nil
        )
    }
}
