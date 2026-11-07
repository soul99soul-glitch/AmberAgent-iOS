import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    func generateResponse(
        inputDigest: String,
        conversationId: KotlinUuid?,
        phoneControlUserInitiated: Bool = false,
        anchorUserMessageId: String? = nil
    ) {
        // generateResponse 本身完全同步（kernelRunHost.start 内部再起 Task），
        // 用 begin/defer-end 包住整个函数体即测到主线程被占用的时长。
        var kickoffInterval = ChatPerfTrace.begin("GenerationKickoff")
        defer { ChatPerfTrace.end(&kickoffInterval) }
        guard conversationStore?.isImportingConversationDocuments != true else {
            configurationError = "正在恢复会话，请等待完成后再生成。"
            return
        }
        let targetConversationId = conversationId ?? currentConversationId
#if DEBUG
        if generationActiveOverrideForTesting?(targetConversationId) == true {
            return
        }
#endif
        if let targetConversationId,
           IOSChatBackgroundGenerationCoordinator.shared.hasActiveJob(conversationId: targetConversationId) {
            return
        }
        let targetRun = runRegistry.current(for: targetConversationId)
        targetRun.state.isLoading = true

        let providerSetting = makeProviderSetting()
        let allowPhoneControl = phoneControlUserInitiated && !targetRun.state.isOrchestratedChild
        let params = makeTextGenerationParams(includePhoneControlTools: allowPhoneControl)

        guard let resolvedProvider = providerSetting else {
            targetRun.state.isLoading = targetRun.hasActiveOrQueuedTask
            configurationError = configurationIssue?.message ?? ChatConfigurationIssue.missingProvider.message
            return
        }

        // P0-2:所有前台文本 run 都进入唯一 Kernel。每个用户问题分配独立 ChatAsyncTaskSlot，
        // 复用现有 ChatConversationRunState / ChatKernelRunHost，按任务锚点隔离消息与追问。
        targetRun.state.generationConfiguration = (resolvedProvider, params, lastAssembledDynamicToolSnapshot)
        let resolvedAnchorId: String?
        if targetRun.state.pendingAssistantRegeneration != nil {
            resolvedAnchorId = anchorUserMessageId
        } else {
            resolvedAnchorId = anchorUserMessageId ?? targetRun.state.messages
                .last(where: { $0.role == MessageRole.user })
                .map { ChatMessageProjector.messageId(for: $0) }
        }
        let baselineMessages = buildTaskBaselineMessages(
            in: targetRun,
            anchorUserMessageId: resolvedAnchorId
        )
        let slot = ChatAsyncTaskSlot(
            conversationId: targetConversationId,
            inputDigest: inputDigest,
            anchorUserMessageId: resolvedAnchorId,
            phoneControlUserInitiated: allowPhoneControl,
            providerSetting: resolvedProvider,
            params: params,
            toolExposureBridge: lastAssembledToolExposureBridge,
            recipeCatalogSnapshot: lastAssembledDynamicToolSnapshot,
            baselineMessages: baselineMessages
        )
        _ = startOrEnqueueTaskSlot(slot, in: targetRun)
    }

    static let managerDelegationContractPrompt = """
    【AI 经理并发派工契约（秘书班子领班）】
    你在前台主对话中扮演“AI 经理（秘书班子领班）”角色：前台只负责与用户自然对话、理清意图、拆解任务，并将重度执行交由后台子代理（spawn_agent）并发完成，使对话与执行彻底解耦，绝不在主会话里同步死磕长耗时任务打断聊天节奏。
    - 任务分流准则：
      1. 随手单步查询（如简短问答、查改单条日程/设置、切换形象人设、一次轻量检索即可作答）：在主对话当轮直接轻量完成。
      2. 多维调研 / 潜在客户摸排 / 赛道对比 / 批量分析 / 复杂多步任务：前台仅用 1 句自然利落的口语接单回应，同轮直接拆解并调用 `spawn_agent` 派发给后台子代理并发干活，不要在主会话里自己连续多轮搜索或长篇憋字。
    - 多事项并发拆单：当用户在一段话里同时交办多件独立事项（例如同时让找潜在客户、做赛道调研、对比竞品方案）时，在同一轮或连续轮次拆成多个独立的 `spawn_agent` 任务并发执行（后台支持最高 4 路子代理同时并行）；派发后立即结束当前前台轮次释放输入框，供用户继续闲聊或随时补充新意图，不要在主会话同步轮询死等。
    - 结构化交办参数：调用 `spawn_agent` 时，除清晰的 `task_name`（短小写英文名）与 `message` 外，可按需指定 `deliverable_hint`（期望交付物格式，如“潜在客户清单与联系方式”、“赛道对比结论与核心依据”）与 `checkpoint_policy`（`"none"` 表示全程执行到底；`"pause_for_decision"` 表示完成前序摸排/初筛后先暂停并回传结构化候选供用户拍板下一步），复杂任务可指定 `reasoning_level: "high"`。若其余编排工具（如 `followup_task`、`send_message`、`interrupt_agent`、`list_agents`）未暴露，先通过 `tool_search` 检索精确名称后直接调用，严禁使用 `mcp_call` 包装。
    """

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
        if !state.isOrchestratedChild {
            if let latestUserIndex = uploadableMessages.lastIndex(where: { $0.role == MessageRole.user }) {
                let latestUserMessage = uploadableMessages[latestUserIndex]
                let rawUserText = latestUserMessage.toText().trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawUserText.isEmpty, !rawUserText.hasPrefix("[mailbox ") {
                    let currentTurnToolNames = Set(
                        uploadableMessages[(latestUserIndex + 1)...]
                            .filter { $0.role == MessageRole.assistant }
                            .flatMap { $0.getTools().map(\.toolName) }
                    )
                    AmberIntentInboxStore.shared.captureFromUserMessage(
                        rawUserText,
                        conversationId: state.conversationId?.toHexDashString(),
                        sourceMessageId: ChatMessageProjector.messageId(for: latestUserMessage),
                        triggeredToolNames: currentTurnToolNames
                    )
                }
            }
        uploadableWithGuidance = [PromptTranscript.shared.sectionMessage(
            name: "conversationalProgress",
            text: """
            无需调用工具的闲聊、寒暄或可直接回答的问题，在同一轮直接自然作答，不要拆成“先应一声、再答一遍”的两段。凡是需要调用工具或多步处理的请求（如修改角色设定、查日程、搜索、读写数据、执行操作等），要调用工具时在同轮调用，绝不能静默只发 tool_calls：首轮发出 tool_calls 的同时，必须先输出简短自然的一句口语回应（严格控制在 1 句以内），按你当前的形象人设（Soul）性格与称呼（默认则以亲切利落的朋友口吻）顺手把事应下来；严禁复读用户原话，严禁“收到您的请求”“正在为您处理”“好的，我将为您……”等客服腔或汇报体。工具执行完毕给出最终答复时，在新一轮直接自然交付结果与正文，不要重复开场寒暄或再来一遍客套汇报；若刚通过 agent_soul_update 切换了角色设定，立即以新身份和口吻说话。若纯文本问题确实需要分步深入展开，可在首轮简短给出核心判断并在末尾附上 <amber-continue>阶段1|阶段2|阶段3</amber-continue>（写出 3 个与具体话题相关、各 6～14 字的思考方向，例如“梳理二人的交往|比较彼此的经历|分析他们的情谊”；不要声称尚未发生的搜索或工具操作，无工具时随后结束本轮，有工具时仍须同轮调用）。编排复杂后台子线程时，如目标模型支持，可为 spawn_agent 指定 reasoning_level: "high"。只陈述真实进展，不要声称尚未完成的操作已完成。仅在用户明确要求记住、修改或忘掉时使用 memory_tool 写入用户事实；日常对话流露的信息由后台按原话证据规则提炼。需要历史上下文时可主动使用 wiki_read/wiki_search 并沿相对链接读取；wiki_edit/wiki_revert 只修改带版本来源的 Agent 笔记，不能替代用户确认置顶或核心记忆。

            \(Self.managerDelegationContractPrompt)
            """
        )] + uploadableWithGuidance
        }
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
            miniAppRuntimeEnabled: isMiniAppRuntimeEnabled,
            soulStore: agentSoulStore,
            conversationId: state.conversationId?.toHexDashString(),
            isOrchestratedChild: state.isOrchestratedChild
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
            toolDeclarations.append(MemoryWikiToolKt.createMemoryWikiEnabledToolDeclaration())
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
        // Agent 形象人设（Soul）：读免审批；写按产品决定直通，旧版自动进快照栈可回退。
        toolDeclarations.append(contentsOf: AgentSoulToolDeclarationsKt.createAgentSoulToolDeclarations())
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
        // 当前会话原始历史检索（history_search/history_fetch）与归档话题召回（episode_recall）。
        // 常驻：分段归档或压缩后模型必须能立刻回查原文，不能先依赖 tool_search 的额外一轮。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: ["history_search", "history_fetch"]
        ))
        if !state.isOrchestratedChild {
            toolDeclarations.append(ChatEpisodeRecallTool.declaration)
        }
        // Agent 自配置 provider/model：非常驻 deferred；写密钥仅前台 + 审批。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSProviderConfigToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSThemePackToolCatalog.toolNames).sorted()
        ))
        // SSH profile & key CRUD：非常驻 deferred；写工具仅前台 + 高风险审批。
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSSSHProfileToolCatalog.toolNames).sorted()
        ))
        toolDeclarations.append(contentsOf: ToolKt.iosToolDeclarations(
            names: Array(IOSSSHKeyToolCatalog.toolNames).sorted()
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
        exposureBridge.exposeToolNames(names: Array(AgentSoulToolCatalog.toolNames).sorted())
        if !state.isOrchestratedChild {
            exposureBridge.exposeToolNames(names: [ChatEpisodeRecallTool.name, "spawn_agent"])
        }
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
        case let name where AgentSoulToolCatalog.toolNames.contains(name):
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
