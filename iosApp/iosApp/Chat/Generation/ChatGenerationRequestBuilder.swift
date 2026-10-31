import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    func generateResponse(inputDigest: String, conversationId: KotlinUuid?,
                                  phoneControlUserInitiated: Bool = false) {
        // generateResponse 本身完全同步（kernelRunHost.start 内部再起 Task），
        // 用 begin/defer-end 包住整个函数体即测到主线程被占用的时长。
        var kickoffInterval = ChatPerfTrace.begin("GenerationKickoff")
        defer { ChatPerfTrace.end(&kickoffInterval) }
        guard conversationStore?.isImportingConversationDocuments != true else {
            configurationError = "正在恢复会话，请等待完成后再生成。"
            return
        }
        if let conversationId {
            guard !isGenerationActive(conversationId: conversationId) else { return }
        } else {
            guard !isGenerationActive else { return }
        }
        isLoading = true

        let providerSetting = makeProviderSetting()
        let params = makeTextGenerationParams(includePhoneControlTools: phoneControlUserInitiated && !currentRun.state.isOrchestratedChild)

        guard let resolvedProvider = providerSetting else {
            isLoading = false
            configurationError = configurationIssue?.message ?? ChatConfigurationIssue.missingProvider.message
            return
        }

        // P0-2:所有前台文本 run 都进入唯一 Kernel。CGC 只保留非 agent 的
        // one-shot 能力与兼容终态入口，不再拥有第二套模型—工具循环。
        currentRun.state.generationConfiguration = (resolvedProvider, params, lastAssembledDynamicToolSnapshot)
        kernelRunHost.start(
            providerSetting: resolvedProvider,
            params: params,
            inputDigest: inputDigest,
            conversationId: conversationId,
            uploadMessages: messages,
            toolExposureBridge: lastAssembledToolExposureBridge,
            recipeCatalogSnapshot: lastAssembledDynamicToolSnapshot,
            phoneControlUserInitiated: phoneControlUserInitiated && !currentRun.state.isOrchestratedChild
        )
    }

    /// P1 管线闭环：参与线程树的会话注入的 mailbox 语义说明（仅在
    /// currentConversationHasOrchestrationLinks 为真时出现在上传上下文）。
    func messagesByInjectingRuntimeContext(
        _ messages: [UIMessage],
        mcpEnabledOverride: Bool? = nil,
        state: ChatConversationRunState? = nil,
        memoryRecallOverride: ChatMemoryContextBuilder.RecallResult? = nil
    ) -> [UIMessage] {
        let state = state ?? currentRun.state
        let uploadableMessages = messages.filter { !Self.isLocalGenerationError($0) }
        // P0-a Fix A: when the current run bridge is in lazy mode, prepend the
        // tool_search discovery guidance as a standalone system fragment (the
        // builder below runs with coalesceSystemMessages: false, so fragments
        // stay separate), so the model knows hidden tools are "not callable
        // until" tool_search exposes them. The bridge is assembled by
        // makeTextGenerationParams() before this runs — messages are only
        // injected inside a started run, after the bridge exists.
        var uploadableWithGuidance = uploadableMessages
        uploadableWithGuidance = [PromptTranscript.shared.sectionMessage(
            name: "scheduledWake", text: Self.scheduledWakeContextPrompt
        )] + uploadableWithGuidance
        uploadableWithGuidance = [PromptTranscript.shared.sectionMessage(
            name: "shortcutAuthoring", text: IOSShortcutAuthoringToolCatalog.runtimeGuidance
        )] + uploadableWithGuidance
        if let guidance = state.toolExposureBridge?.discoveryGuidance(),
           !guidance.isEmpty {
            uploadableWithGuidance = [UIMessage.companion.system(prompt: guidance)] + uploadableWithGuidance
        }
        // 线程编排语境（管线闭环）：只有参与线程树的会话才注入 mailbox 语义——
        // 信封以 user 消息形态折入（`[mailbox TYPE from ...]`），模型需要知道
        // 这不是用户输入、子线程会自动回报，否则会把子线程报告当成用户话语。
        if state.hasOrchestrationLinks {
            uploadableWithGuidance = [UIMessage.companion.system(prompt: Self.orchestrationContextPrompt)] + uploadableWithGuidance
        }
        let withContext = ChatRuntimeContextBuilder(
            sharedSettings: sharedSettings,
            mcpTools: (mcpEnabledOverride ?? isCapabilityPolicyEnabled("ios.mcp.tool_call"))
                ? mcpManager.tools
                : [],
            miniAppRepository: miniAppRepository,
            miniAppRuntimeEnabled: isMiniAppRuntimeEnabled
        ).injectingRuntimeContext(
            into: uploadableWithGuidance,
            coalesceSystemMessages: false,
            memoryRecallOverride: memoryRecallOverride
        )
        return withContext
    }

    func memoryRecordIdsForRuntimeContext(
        _ messages: [UIMessage],
        override: ChatMemoryContextBuilder.RecallResult? = nil
    ) -> [Int32] {
        let uploadableMessages = messages.filter { !Self.isLocalGenerationError($0) }
        return ChatRuntimeContextBuilder(
            sharedSettings: sharedSettings,
            mcpTools: mcpManager.tools,
            miniAppRepository: miniAppRepository,
            miniAppRuntimeEnabled: isMiniAppRuntimeEnabled
        ).memoryRecallResult(for: uploadableMessages, override: override).ids
    }

    /// P3a：Jev 关闭/未提供覆盖时的兜底记忆召回结果，供 `ChatKernelRunHost`
    /// 在一次请求准备内计算一次并复用（见 `memoryRecallResultForRun` 绑定）。
    func memoryRecallResultForRun(_ messages: [UIMessage]) -> ChatMemoryContextBuilder.RecallResult {
        let uploadableMessages = messages.filter { !Self.isLocalGenerationError($0) }
        return ChatRuntimeContextBuilder(
            sharedSettings: sharedSettings,
            mcpTools: mcpManager.tools,
            miniAppRepository: miniAppRepository,
            miniAppRuntimeEnabled: isMiniAppRuntimeEnabled
        ).memoryRecallResult(for: uploadableMessages)
    }

    /// Jev Phase 1（记忆召回）：每轮上传准备时计算统一选中集合。轮次预算与
    /// 并发归属统一用 runId（与其他 Jev 用途共用同一本轮账）；记录内容/范围/
    /// 配置变化由服务端 turnKey 指纹覆盖。
    /// 返回本轮的统一选中集合（nil = off/shadow/失败回退）。
    func prepareJevMemoryRecallSelection(
        _ messages: [UIMessage],
        runId: String?
    ) async -> ChatMemoryContextBuilder.RecallResult? {
        let uploadableMessages = messages.filter { !Self.isLocalGenerationError($0) }
        return await IOSJevMemoryRecallService.shared.prepareTurnSelection(
            messages: uploadableMessages,
            records: IosMemoryFactory.shared.getAllRecords(),
            runtime: sharedSettings.agentRuntime,
            identity: IOSJevMemoryRecallService.RunIdentity(runId: runId)
        )
    }

    func recordMemoryUsage(_ ids: [Int32], force: Bool = false, state: ChatConversationRunState) {
        // P2-b: 注入即使用（injected into upload = used）。去抖与原子写在
        // 原会话的 state 持有本 run 的去抖；切会话后仍绑定该 state 的 host。
        // P2-c 修复 2：模型显式引用（citation flush）传 force: true，绕过
        // 同集去抖——引用是模型信号，与召回标记语义不同，应始终生效。
        let ownerKey = state.conversationId?.toHexDashString() ?? ""
        state.recordMemoryUsage(
            ids: Set(ids), runId: runRegistry.run(forHex: ownerKey)?.host?.currentRunId, force: force
        )
    }

    static func isLocalGenerationError(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.assistant else { return false }
        return message.parts.contains { part in
            guard let text = part as? UIMessagePart.Text else { return false }
            return IosToolOutputJsonBridge.shared.metadataString(part: text, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == MessageKt.LOCAL_GENERATION_ERROR_METADATA_VALUE
        }
    }

    static func isRegeneratedAnswerCandidate(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.assistant,
              !isLocalGenerationError(message),
              !isOutputLimitNotice(message) else { return false }
        return !message.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isOutputLimitNotice(_ message: UIMessage) -> Bool {
        message.parts.contains { part in
            guard let text = part as? UIMessagePart.Text else { return false }
            return IosToolOutputJsonBridge.shared.metadataString(part: text, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == MessageKt.LOCAL_OUTPUT_LIMIT_NOTICE_METADATA_VALUE
        }
    }

    /// Stored messages retain their images. Every upload, including regeneration and
    /// queued input, resolves missing recognition before a text-only model receives it.
    static func imageEditToolInput(
        prompt: String,
        sourceImageURL: String,
        aspectRatio: String
    ) -> String {
        let payload: [String: Any] = [
            "prompt": prompt,
            "aspect_ratio": aspectRatio,
            "count": 1,
            "mode": "edit",
            "source_image_url": sourceImageURL,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let text = String(data: data, encoding: .utf8) else {
            return prompt
        }
        return text
    }

    func prepareImageAttachments(
        _ messages: [UIMessage],
        model: Model,
        settings: Settings,
        conversationId: KotlinUuid?
    ) async throws -> [UIMessage] {
        guard !Self.modelSupportsImageInput(model) else { return messages }
        let imageURLs = messages.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Image)?.url }
        guard !imageURLs.isEmpty else { return messages }
        let texts = try await performVisionRecognition(
            imageURLs: imageURLs,
            settings: settings,
            conversationId: conversationId
        ).get()
        try Task.checkCancellation()
        cacheVisionRecognitionTexts(texts)
        return try messages.map { message in
            guard message.parts.contains(where: { $0 is UIMessagePart.Image }) else { return message }
            let newParts: [UIMessagePart] = try message.parts.map { part in
                guard let image = part as? UIMessagePart.Image else { return part }
                guard let recognized = texts[image.url] else {
                    throw VisionRecognitionError(message: IOSAppLocalization.string(
                        "视觉识别模型没有返回可用内容",
                        defaultValue: "视觉识别模型没有返回可用内容"
                    ))
                }
                return UIMessagePart.Text(text: recognized, metadata: nil)
            }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: newParts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

#if DEBUG
    func preparedUploadMessagesForTesting(_ messages: [UIMessage]) -> [UIMessage] {
        messagesByInjectingRuntimeContext(messages)
    }
#endif

    /// App-level background recovery uses the same transform as foreground completion.
    /// Resolve the configured provider for the current chat model.
    func makeProviderSetting() -> ProviderSetting? {
        guard let currentModel else { return nil }
        guard let provider = ChatProviderConfiguration.provider(
            for: currentModel,
            providers: sharedSettings.snapshot.providers
        ), ChatProviderConfiguration.issue(for: currentModel, provider: provider) == nil else { return nil }
        return provider
    }

    /// Keep discoveries and calls through the next five user turns. Rebuilding
    /// params or retrying the same message does not consume another turn.
    private func recentToolsForExposure(in messages: [UIMessage]) -> [UIMessagePart.Tool] {
        var userTurns = 0
        var tools: [UIMessagePart.Tool] = []
        for message in messages.reversed() {
            if message.role == MessageRole.user {
                userTurns += 1
                if userTurns > 5 { break }
            } else if message.role == MessageRole.assistant {
                tools.append(contentsOf: message.getTools())
            }
        }
        return tools
    }

    func makeTextGenerationParams(
        includePhoneControlTools: Bool = false,
        state: ChatConversationRunState? = nil
    ) -> TextGenerationParams {
        let state = state ?? currentRun.state
        let messages = state.messages
        let includesPhoneTools = includePhoneControlTools && phoneControl.enabled
        let modelId = currentModelId
        let modelAbilities = currentModelAbilities
        let searchEnabled = sharedSettings.snapshot.enableWebSearch
        // 图片生成现在挂载在「指定的生图模型」上(辅助任务 → 生图模型 / imageGenerationModelId),
        // 不再依赖独立的图片生成配置页。模型能解析到且其 provider 有有效 apiKey/baseURL 才挂工具。
        let imageGenerationConfigured: Bool = {
            let snap = sharedSettings.snapshot
            guard let model = snap.findModelById(uuid: snap.imageGenerationModelId),
                  let provider = ChatProviderConfiguration.provider(for: model, providers: snap.providers),
                  provider.enabled else {
                return false
            }
            // Codex image generation uses the OAuth bearer (no apiKey); gate on
            // sign-in instead. Other providers require a real apiKey + baseURL.
            if IOSCodexProviderResolver.isCodexProvider(provider) {
                return IOSCodexProviderResolver.isSignedIn(provider)
            }
            let key = ChatProviderConfiguration.apiKey(of: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = ChatProviderConfiguration.baseURL(of: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && !base.isEmpty
        }()
        var builtInTools: [BuiltInTools] = []
        if searchEnabled { builtInTools.append(BuiltInTools.Search.shared) }

        // Real Android parity: read generation params from the current Assistant
        // + Model instead of hardcoding temperature=0.7/topP=nil/maxTokens=nil.
        // Uses the shared generation defaults contract plus resolveSessionDefaults.
        let snapshot = sharedSettings.snapshot
        let assistant = snapshot.getCurrentAssistant()
        let currentModel = snapshot.getCurrentChatModel()
        let contextWindow = currentModel?.contextWindowTokens
        // resolveSessionDefaults handles: reasoningLevel AUTO→model default,
        // contextMessageSize 0→group default, maxTokens→group default fallback.
        // It is a Settings extension fun; the fallback model avoids a nil model.
        // Model requires its full initializer (Kotlin default args don't bridge).
        let resolvedModel = currentModel ?? Model(
            modelId: modelId,
            displayName: modelId,
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
        let resolved = snapshot.resolveSessionDefaults(assistant: assistant, model: resolvedModel)

        // Merge custom headers/bodies: provider disguise + Assistant + Model.
        let mergedHeaders: [CustomHeader] = {
            guard let currentModel,
                  let provider = ChatProviderConfiguration.provider(
                    for: currentModel,
                    providers: snapshot.providers
                  ) else { return assistant.customHeaders + (currentModel?.customHeaders ?? []) }
            return ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: currentModel.customHeaders,
                conversationId: state.conversationId?.toHexDashString()
            )
        }()
        let mergedBodies: [CustomBody] = assistant.customBodies + (currentModel?.customBodies ?? [])

        let model = Model(
            modelId: modelId,
            displayName: currentModel?.displayName ?? modelId,
            id: currentModel?.id ?? KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: mergedHeaders,
            customBodies: mergedBodies,
            inputModalities: resolvedModel.inputModalities,
            outputModalities: resolvedModel.outputModalities,
            abilities: modelAbilities,
            tools: Set(builtInTools),
            contextWindowTokens: contextWindow,
            providerOverwrite: currentModel?.providerOverwrite
        )
        // Tool declarations: iOS search/scrape, memory, WebMount, MCP,
        // sub-agent dispatch, and model-council run. The model decides which to
        // call; the iOS onComplete dispatch routes each to its executor.
        var toolDeclarations: [Tool] = []
        if searchEnabled {
            toolDeclarations.append(ToolKt.createSearchWebToolDeclaration())
            toolDeclarations.append(ToolKt.createScrapeWebToolDeclaration())
        }
        if IOSMemoryToolExecutor.isEnabled(runtime: sharedSettings.agentRuntime) {
            toolDeclarations.append(ToolKt.createMemoryToolDeclaration())
        }
        if imageGenerationConfigured {
            toolDeclarations.append(ToolKt.createImageGenToolDeclaration())
        }
        if localToolExecutor != nil {
            toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
                names: workspaceToolNamesForCurrentTurn()
            ))
        }
        if localToolExecutor != nil {
            toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
                names: ishToolNamesForCurrentTurn()
            ))
        }
        if localToolExecutor != nil, isWebMountRuntimeEnabled {
            toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
                names: Array(IOSWebMountToolCatalog.supportedToolNames).sorted()
            ))
        }
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSSkillToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(ToolKt.createSoulImportToolDeclaration())
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSRecipeToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSPluginToolCatalog.toolNames).sorted()
        ))
        // Apple device capabilities are default-deferred. They enter the full
        // bridge catalog so tool_search can expose them only when relevant.
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSAppleAgentToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(contentsOf: IOSWakeToolCatalog.declarations)
        toolDeclarations.append(contentsOf: IOSShortcutAuthoringToolCatalog.declarations)
        if includesPhoneTools {
            toolDeclarations.append(contentsOf: IOSPhoneControlToolCatalog.declarations)
        }
        let mcpNetworkEnabled = isCapabilityPolicyEnabled("ios.mcp.tool_call")
        if mcpNetworkEnabled {
            toolDeclarations.append(ToolKt.createMcpCallToolDeclaration())
        }
        var mcpManagementNames = Array(IOSMcpManagementToolCatalog.toolNames)
        if !mcpNetworkEnabled {
            mcpManagementNames.removeAll {
                $0 == "mcp_test" || $0 == "mcp_import_from_skill"
            }
        }
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: mcpManagementNames.sorted()
        ))
        // P0-b: flatten discovered MCP tools into `mcp__{server}__{tool}`
        // declarations. They are appended to the BRIDGE's input (never to the
        // final params — the bridge defers them behind tool_search; mcp_call
        // stays as the always-on passthrough). Disabled network policy omits
        // them so they cannot be searched or called this run.
        if mcpNetworkEnabled {
            toolDeclarations.append(contentsOf: expandedMcpToolDeclarations(mcpManager: mcpManager))
        }
        // P1-c/P1-d: 线程编排六工具声明。非常驻——照 mcp__* 展开先例只进 bridge
        // 全目录（tool_search 命中后才进 params.tools），不加新设置项。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: ["spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent"]
        ))
        // 跨会话读取工具声明（session_search/session_read）。非常驻——照线程编排
        // 先例只进 bridge 全目录（tool_search 命中后才进 params.tools），无设置项。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: ["session_search", "session_read"]
        ))
        // Agent 自配置 provider/model：非常驻 deferred；写密钥仅前台 + 审批。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSProviderConfigToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSThemePackToolCatalog.toolNames).sorted()
        ))
        // SSH profile CRUD：非常驻 deferred；写工具仅前台 + 高风险审批。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSSSHProfileToolCatalog.toolNames).sorted()
        ))
        // M5: discovery 引导（toolSearchDiscoveryGuidance）教模型用 tools_list
        // 识别精确工具名——iOS 主目录声明它（常驻；KMP IOS_RESIDENT_TOOL_NAMES
        // 与 DISCOVERY_UTILITY_TOOLS 已把它列为 resident），执行在桥本地。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(names: ["tools_list"]))
        // runtime_status：agent 运行时自省（Jev 模式/凭据存在性/门控/目录计数）。
        // 常驻首轮可见——模型无需先 tool_search 就能回答"我有什么能力"；
        // 本地只读执行（ChatToolRuntime.dispatchRuntimeStatusToolCall），无设置项。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(names: ["runtime_status"]))
        // P3-a: exec 纯求值工具（JavaScriptCore 沙箱，无 tools 桥）。默认关——
        // 仅在开关开时进桥输入全目录（非常驻 deferred 池，tool_search 命中后才
        // 可见可调）；关时零痕迹（声明与执行路径都不存在，模型调用走未知名
        // 硬失败语义）。
        // P3-c: wait 与 exec 同开关（cell 生命周期续取，无独立设置项）。
        if settingsStore.execJavaScriptEnabled {
            toolDeclarations.append(ToolKt.createExecToolDeclaration())
            toolDeclarations.append(ToolKt.createWaitToolDeclaration())
        }
        if isSlice3ToolEnabled("model_council_run") {
            toolDeclarations.append(ToolKt.createModelCouncilRunToolDeclaration())
        }
        // Standard chat can pause for a focused user decision, same tool surface as novel discussion.
        toolDeclarations.append(ToolKt.createAskUserToolDeclaration())
        // Wave B1 (§13.2.4 run-start seam, §16.1): include recipe declarations
        // from the dynamic registry's CURRENT snapshot. Every recipe is
        // default-deferred — it enters the bridge's full catalog
        // (tool_search-searchable) but never the visible set. Descriptors and
        // search info come from ONE snapshot object, so declaration and
        // execution availability cannot diverge by revision. No snapshot
        // (store unreadable) → no recipe surface at all.
        var recipeSearchInfo: [String: String] = [:]
        let dynamicCatalog = IOSDynamicToolRegistry.shared.currentSnapshot
        lastAssembledDynamicToolSnapshot = dynamicCatalog
        if let dynamicCatalog,
           !dynamicCatalog.recipeTools.isEmpty {
            toolDeclarations.append(contentsOf: dynamicCatalog.recipeDeclarations())
            recipeSearchInfo = dynamicCatalog.searchInfoByName
        }
        // P0-a tool discovery: wrap the full static declarations in the shared
        // KMP exposure bridge and surface only the first-round visible subset
        // (iOS resident tools + tool_search; everything deferred — wm_*, iSH,
        // skill management, … — is exposed on demand via tool_search). The
        // bridge instance is handed to the run coordinator, which owns it for
        // the whole run so hits become callable on the NEXT round.
        let exposureBridge = IosToolExposureBridge(tools: toolDeclarations, recipeSearchInfo: recipeSearchInfo)
        if includesPhoneTools {
            exposureBridge.exposeToolNames(names: Array(IOSPhoneControlToolCatalog.toolNames).sorted())
        }
        exposureBridge.restoreExecutedTools(tools: recentToolsForExposure(in: messages))
        if let provider = makeProviderSetting(),
           PromptTranscriptCapabilities.companion.resolve(setting: provider, model: model).toolAdditions {
            // Native tool additions remain at their historical load point across user turns.
            // Restore names against this run's filtered catalog, never old schemas/executors.
            exposureBridge.exposeToolNames(names: PromptTranscript.shared.currentToolNames(messages: messages))
        }
        state.toolExposureBridge = exposureBridge
        // Real params: temperature/topP from Assistant, maxTokens from
        // resolveSessionDefaults (Assistant → group default), reasoningLevel
        // resolved, custom headers/bodies merged for the iOS generation runtime.
        let resolvedReasoningLevel = modelAbilities.contains(.reasoning) ? resolved.reasoningLevel : ReasoningLevel.off
        return TextGenerationParams(
            model: model,
            temperature: assistant.temperature.map { KotlinFloat(value: Float(truncating: $0)) },
            topP: assistant.topP.map { KotlinFloat(value: Float(truncating: $0)) },
            maxTokens: resolved.maxTokens.map { KotlinInt(value: Int32(truncating: $0)) },
            tools: exposureBridge.visibleTools(),
            reasoningLevel: resolvedReasoningLevel,
            customHeaders: mergedHeaders,
            customBody: mergedBodies
        )
    }

    func currentToolDeclarationNames() -> [String] {
        makeTextGenerationParams().tools.map(\.name)
    }

    private func workspaceToolNamesForCurrentTurn() -> [String] {
        Array(IOSWorkspaceToolCatalog.supportedToolNames).sorted()
    }

    private func ishToolNamesForCurrentTurn() -> [String] {
        enabledModelToolNames(IOSAgentTerminalToolCatalog.supportedToolNames)
    }

    #if DEBUG
    static func auxiliaryTextGenerationParamsForTesting(
        model: Model,
        assistantHeaders: [CustomHeader] = [],
        assistantBodies: [CustomBody] = []
    ) -> TextGenerationParams {
        makeAuxiliaryTextGenerationParams(
            model: model,
            assistantHeaders: assistantHeaders,
            assistantBodies: assistantBodies
        )
    }

    func beginSuggestionRequestForTesting() -> UUID {
        beginSuggestionRequest()
    }

    func applySuggestionsForTesting(
        _ suggestions: [String],
        requestToken: UUID,
        conversationId: KotlinUuid?
    ) {
        applySuggestions(
            suggestions,
            requestToken: requestToken,
            conversationId: conversationId
        )
    }

    /// Test accessor for the resolved generation params (reads real
    /// Assistant/Model values + resolveSessionDefaults).
    func textGenerationParamsForTesting(includePhoneControlTools: Bool = false) -> TextGenerationParams {
        makeTextGenerationParams(includePhoneControlTools: includePhoneControlTools)
    }

    /// P0-a: the run bridge built by the latest assembly (nil until
    /// makeTextGenerationParams ran). Test accessor for the exposure contract.
    func toolExposureBridgeForTesting() -> IosToolExposureBridge? {
        lastAssembledToolExposureBridge
    }

    func persistPendingAssistantRegenerationForTesting(
        conversationId: KotlinUuid,
        targetMessageIndex: Int,
        generatedMessageIndex: Int,
        snapshot: [UIMessage]
    ) async -> Bool {
        guard let store = conversationStore else { return false }
        let pending = PendingAssistantRegeneration(
            conversationId: conversationId,
            targetMessageIndex: targetMessageIndex,
            generatedMessageIndex: generatedMessageIndex
        )
        pendingAssistantRegeneration = pending
        messages = snapshot
        return await persistMessagesSnapshot(
            snapshot,
            targetConversationId: conversationId,
            pendingRegeneration: pending,
            store: store,
            writeBaseline: store.writeBaseline(for: conversationId)
        )
    }
    #endif

    static func userFacingGenerationError(_ rawMessage: String, modelId: String? = nil) -> String {
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = raw.lowercased()
        // NSError diagnostics contain addresses and task IDs whose digits are not HTTP status codes.
        let isURLSessionFailure = lowercased.contains("nsurlerrordomain")
        let prefix: String
        if lowercased.contains("request snapshot ledger write failed") {
            prefix = IOSAppLocalization.string(
                "请求尚未发送，因为本地运行记录写入失败。请重试；若问题持续，请检查设备可用存储空间。",
                defaultValue: "请求尚未发送，因为本地运行记录写入失败。请重试；若问题持续，请检查设备可用存储空间。"
            )
        } else if !isURLSessionFailure && (lowercased.contains("invalid api key") ||
            lowercased.contains("incorrect api key") ||
            lowercased.contains("unauthorized") ||
            lowercased.contains("401")) {
            prefix = IOSAppLocalization.string(
                "API Key 无效或没有权限。请回到「服务商」确认 Key 是否填写正确，并确认它有访问当前服务商的权限。",
                defaultValue: "API Key 无效或没有权限。请回到「服务商」确认 Key 是否填写正确，并确认它有访问当前服务商的权限。"
            )
        } else if !isURLSessionFailure && (lowercased.contains("model_not_found") ||
                    lowercased.contains("model not found") ||
                    lowercased.contains("does not exist") ||
                    lowercased.contains("not found") ||
                    lowercased.contains("404")) {
            let trimmedModelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = trimmedModelId.isEmpty
                ? ""
                : IOSAppLocalization.formatted(
                    "当前 Model ID：%@。",
                    defaultValue: "当前 Model ID：%@。",
                    arguments: [trimmedModelId]
                )
            prefix = IOSAppLocalization.string(
                "模型不可用、模型不存在，或当前 Base URL 不支持这个聊天路径。请在「默认模型」选择当前服务商支持的模型。",
                defaultValue: "模型不可用、模型不存在，或当前 Base URL 不支持这个聊天路径。请在「默认模型」选择当前服务商支持的模型。"
            ) + suffix
        } else if lowercased.contains("network") ||
                    lowercased.contains("internet") ||
                    lowercased.contains("offline") ||
                    lowercased.contains("timed out") ||
                    lowercased.contains("timeout") ||
                    lowercased.contains("cannot connect") ||
                    lowercased.contains("could not connect") ||
                    lowercased.contains("dns") ||
                    lowercased.contains("connection refused") ||
                    lowercased.contains("nsurlerror") {
            prefix = IOSAppLocalization.string(
                "网络连接失败。请检查网络、Base URL 和服务商状态后重试。",
                defaultValue: "网络连接失败。请检查网络、Base URL 和服务商状态后重试。"
            )
        } else {
            prefix = IOSAppLocalization.string(
                "请求失败。请检查服务商配置后重试。",
                defaultValue: "请求失败。请检查服务商配置后重试。"
            )
        }

        guard !raw.isEmpty else { return prefix }
        return prefix + "\n\n" + IOSAppLocalization.formatted(
            "原始错误：%@",
            defaultValue: "原始错误：%@",
            arguments: [truncatedError(raw)]
        )
    }

    private static func truncatedError(_ value: String, maxLength: Int = 700) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    var isMiniAppRuntimeEnabled: Bool {
        sharedSettings.agentRuntime.miniApp.enabled
    }

    private var isWebMountRuntimeEnabled: Bool {
        true
    }

    private func isSlice3ToolEnabled(_ toolName: String) -> Bool {
        switch toolName {
        case "mcp_call", "mcp_test":
            isCapabilityPolicyEnabled("ios.mcp.tool_call")
        case "mcp_list", "mcp_import_from_skill",
             "skills_list", "use_skill", "skill_validate", "skill_import", "soul_import", "skill_enable", "skill_disable":
            true
        case let name where IOSRecipeToolCatalog.toolNames.contains(name):
            true
        case let name where IOSPluginToolCatalog.toolNames.contains(name):
            true
        case "subagent_dispatch":
            isCapabilityPolicyEnabled("ios.agent.subagent_dispatch")
        case "model_council_run":
            isCapabilityPolicyEnabled("ios.agent.model_council_run")
        default:
            false
        }
    }

    // 工具暴露只取决于用户设置的能力策略。不走 permissionsStatus()：它会逐个探测
    // 系统授权（定位、相册、钱包、录屏等），每次发送在主线程上同步阻塞近百毫秒。
    private func isCapabilityPolicyEnabled(_ capabilityId: String) -> Bool {
        guard let localToolExecutor else { return true }
        return localToolExecutor.permissionPolicy(capabilityId: capabilityId) != .disabled
    }

    private func enabledModelToolNames(_ names: Set<String>) -> [String] {
        guard let localToolExecutor else { return Array(names).sorted() }
        return names.filter { toolName in
            guard let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.modelToolNames.contains(toolName) }) else {
                return false
            }
            return localToolExecutor.permissionPolicy(capabilityId: capability.id) != .disabled
        }
        .sorted()
    }
}
