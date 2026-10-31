package app.amber.cloud.runtime

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.provider.claude.ClaudeKmpProvider
import app.amber.ai.provider.openai.OpenAIKmpProvider
import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelApprovalCard
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelDecisionOutcome
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.SessionDto
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.agent.runtime.AgentRunStatus
import app.amber.core.model.Conversation
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import app.amber.core.model.toMessageNode
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Clock
import kotlin.uuid.Uuid

/**
 * Abstraction over KMP model providers (`:ai-provider-claude`, `:ai-provider-openai`)
 * and deterministic test providers.
 */
fun interface CloudModelClient {
    suspend fun generateReply(
        messages: List<UIMessage>,
        tools: List<Tool>,
    ): UIMessage
}

/**
 * Production [CloudModelClient] backed by `:ai-provider-claude` and `:ai-provider-openai`.
 */
class KmpProviderModelClient(
    private val providerSetting: ProviderSetting,
    private val modelId: String,
) : CloudModelClient {
    private val openAIProvider by lazy { OpenAIKmpProvider() }
    private val claudeProvider by lazy { ClaudeKmpProvider() }

    override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage {
        val params = TextGenerationParams(
            model = Model(modelId = modelId),
            tools = tools,
        )
        val chunk = when (providerSetting) {
            is ProviderSetting.OpenAI -> openAIProvider.generateText(providerSetting, messages, params)
            is ProviderSetting.Claude -> claudeProvider.generateText(providerSetting, messages, params)
            else -> error("Unsupported provider setting on cloud daemon: ${providerSetting::class.simpleName}")
        }
        val base = UIMessage(role = MessageRole.ASSISTANT, parts = emptyList())
        return base + chunk
    }
}

/**
 * Core daemon kernel (`amberd`) composing:
 * - `:core:conversation-storage` (`JsonConversationStorage`)
 * - `:ai-core`, `:ai-provider-claude`, `:ai-provider-openai`
 * - `:core:agent-runtime` (`AgentRunStatus`)
 * - [CloudMemoryStore], [CloudContextManager], [EnvelopeCredentialVault], [CloudToolRegistry], [CloudGatewayState]
 */
class CloudAgentKernel(
    val dataDir: File,
    val modelClient: CloudModelClient,
    masterSecretOverride: String? = null,
    val contextWindowTokens: Int = 32_000,
    val autoApproveOrdinaryTools: Boolean = false,
) : ChannelIngress {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val conversationsDir = File(dataDir, "conversations").also { it.mkdirs() }
    val memoryDir = File(dataDir, "memory").also { it.mkdirs() }
    val checkpointsDir = File(dataDir, "checkpoints").also { it.mkdirs() }
    val workspaceDir = File(dataDir, "workspace").also { it.mkdirs() }

    val conversationStorage = JsonConversationStorage(ConversationFile(conversationsDir.absolutePath))
    val vault = EnvelopeCredentialVault(
        vaultFile = File(dataDir, "secrets.enc.json"),
        masterSecretOverride = masterSecretOverride,
    )
    val memoryStore = CloudMemoryStore(memoryDir)
    val contextManager = CloudContextManager(checkpointsDir)
    val toolRegistry = CloudToolRegistry()
    val gatewayState = CloudGatewayState(dataDir)

    private val connectors = ConcurrentHashMap<ChannelKind, ChannelConnector>()
    private val pendingRunsBySessionKey = ConcurrentHashMap<String, PendingRunRecord>()

    data class PendingRunRecord(
        val runId: String,
        val sessionKey: String,
        val conversationId: Uuid,
        val toolCallId: String,
        val toolName: String,
        val highRisk: Boolean,
        val status: AgentRunStatus = AgentRunStatus.AWAITING_PERMISSION,
    )

    init {
        registerBuiltinTools()
        // Wire gateway decision callback into the kernel
        gatewayState.registerDecisionListener { sessionKey, toolCallId, allow ->
            onGatewayDecision(sessionKey, toolCallId, allow)
        }
        // Defect #2: Cold-start recovery wipes any leftover ephemeral secrets
        vault.wipeAllPendingToolArgs()
    }

    suspend fun recoverColdStartConversations() {
        vault.wipeAllPendingToolArgs()
        val summaries = conversationStorage.listSummaries()
        for (summary in summaries) {
            val conv = conversationStorage.loadConversation(summary.id) ?: continue
            var modified = false
            val repairedNodes = conv.messageNodes.map { node ->
                val msg = node.currentMessage
                val updatedParts = msg.parts.map { part ->
                    if (part is UIMessagePart.Tool && (part.isPending || part.output.isEmpty())) {
                        modified = true
                        vault.wipePendingToolArgs(part.toolCallId)
                        part.copy(
                            input = CredentialRedactor.redact(part.input),
                            approvalState = ToolApprovalState.Denied("cold_start_not_resumed"),
                            output = listOf(
                                UIMessagePart.Text(
                                    buildJsonObject {
                                        put("ok", false)
                                        put("status", "not_resumed")
                                        put("tool_call_id", part.toolCallId)
                                        put("reason", "前次调用结果未确认，禁止自动重放，请先核对")
                                    }.toString()
                                )
                            ),
                        )
                    } else {
                        part
                    }
                }
                if (updatedParts != msg.parts) {
                    node.copy(
                        messages = node.messages.toMutableList().also {
                            it[node.selectIndex] = msg.copy(parts = updatedParts)
                        }
                    )
                } else {
                    node
                }
            }
            if (modified) {
                conversationStorage.saveConversation(conv.copy(messageNodes = repairedNodes))
            }
        }
    }

    fun registerConnector(connector: ChannelConnector) {
        connector.attachIngress(this)
        connectors[connector.kind] = connector
    }

    override suspend fun handleInbound(message: InboundMessage): OutboundMessage {
        val convId = resolveConversationId(message)

        // Group chat RBAC: default only responds to OWNER unless explicitly mentioned by collaborator
        if (message.scope == ConversationScope.GROUP && message.senderRole == SenderRole.GUEST) {
            return OutboundMessage(
                channel = message.channel,
                chatId = message.chatId,
                threadId = message.threadId,
                replyToMessageId = message.messageId,
                text = "当前群聊仅响应已绑定的主人或授权协作者。",
                conversationId = convId.toString(),
            )
        }

        // Defect #2: If this conversation had an unfinished waiting tool call, interrupting with a
        // new user message transitions it to INTERRUPTED and wipes its ephemeral secret!
        interruptWaitingRunsForConversation(convId)

        val existing = conversationStorage.loadConversation(convId)
            ?: Conversation(
                id = convId,
                assistantId = DEFAULT_ASSISTANT_ID,
                title = if (convId == PRIMARY_CONVERSATION_ID) "主时间线" else "会话-${message.chatId}",
                messageNodes = emptyList(),
            )

        // Auto-extract explicit memory directive in direct owner chat
        if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
            extractExplicitMemoryIfPresent(message.text, convId.toString())
        }

        val redactedUserText = CredentialRedactor.redact(message.text)
        val userMsg = UIMessage.user(redactedUserText)
        val withUserNodes = existing.messageNodes + userMsg.toMessageNode()
        val afterUserSave = conversationStorage.saveConversation(
            existing.copy(
                messageNodes = withUserNodes,
                updateAt = Clock.System.now(),
            )
        )

        val currentMessages = afterUserSave.messageNodes.map { it.currentMessage }

        // Defect #6: Run compaction check (enforces minDeltaMessages and routine vs forced split)
        contextManager.compactIfNeeded(
            conversationId = convId.toString(),
            messages = currentMessages,
            contextWindowTokens = contextWindowTokens,
        )

        val recalledMemories = if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
            memoryStore.recallForPrompt(message.text)
        } else {
            // In group chats, shield CORE personal memories from non-owner prompts
            memoryStore.recallForPrompt(message.text).filter { it.scope != MemoryScope.CORE }
        }

        // Defect #7: Prepare request messages with pinned SYSTEM message and dynamic memory on tail
        val preparedMessages = contextManager.prepareRequestMessages(
            systemPrompt = memoryStore.loadSoulPrompt(),
            memories = recalledMemories,
            conversationId = convId.toString(),
            historyMessages = currentMessages,
            tokenBudget = contextWindowTokens,
        )

        val executionScope = if (message.senderRole == SenderRole.OWNER) {
            ExecutionScope.MAIN_AGENT
        } else {
            ExecutionScope.SUBAGENT
        }
        val availableTools = toolRegistry.declaredTools(executionScope)
        val assistantReply = modelClient.generateReply(preparedMessages, availableTools)

        val toolCalls = assistantReply.getTools()
        if (toolCalls.isEmpty()) {
            val safeAssistant = sanitizeAssistantMessage(assistantReply)
            conversationStorage.saveConversation(
                afterUserSave.copy(
                    messageNodes = afterUserSave.messageNodes + safeAssistant.toMessageNode(),
                    updateAt = Clock.System.now(),
                )
            )
            return OutboundMessage(
                channel = message.channel,
                chatId = message.chatId,
                threadId = message.threadId,
                replyToMessageId = message.messageId,
                text = safeAssistant.toText(),
                conversationId = convId.toString(),
            )
        }

        // Handle tool calls in the assistant response
        val toolCall = toolCalls.first()
        val highRisk = toolRegistry.isHighRisk(toolCall.toolName)
        val parsedArgs = runCatching {
            json.parseToJsonElement(toolCall.input.ifBlank { "{}" }).jsonObject
        }.getOrDefault(JsonObject(emptyMap()))

        val requiresApproval = highRisk || (!autoApproveOrdinaryTools && isWriteTool(toolCall.toolName))
        if (requiresApproval) {
            // Defect #2 & #4: Stash raw args in encrypted ephemeral memory, persist only redacted args!
            val redactedArgsJson = vault.stashPendingToolArgs(toolCall.toolCallId, parsedArgs)
            val pendingToolPart = toolCall.copy(
                input = redactedArgsJson,
                approvalState = ToolApprovalState.Pending,
                output = emptyList(),
            )
            val pendingAssistantMsg = assistantReply.copy(
                parts = assistantReply.parts.map {
                    if (it is UIMessagePart.Tool && it.toolCallId == toolCall.toolCallId) pendingToolPart else it
                }
            )
            conversationStorage.saveConversation(
                afterUserSave.copy(
                    messageNodes = afterUserSave.messageNodes + pendingAssistantMsg.toMessageNode(),
                    updateAt = Clock.System.now(),
                )
            )

            val runId = UUID.randomUUID().toString().lowercase()
            val sessionKey = "amber:$runId"
            val nowSec = CloudGatewayState.nowEpochSeconds()
            pendingRunsBySessionKey[sessionKey] = PendingRunRecord(
                runId = runId,
                sessionKey = sessionKey,
                conversationId = convId,
                toolCallId = toolCall.toolCallId,
                toolName = toolCall.toolName,
                highRisk = highRisk,
                status = AgentRunStatus.AWAITING_PERMISSION,
            )
            gatewayState.upsertSession(
                SessionDto(
                    key = sessionKey,
                    agent = "amber",
                    subject = afterUserSave.title.ifBlank { "主时间线" },
                    summary = redactedUserText.take(80),
                    origin = "interactive",
                    state = "waiting",
                    waitReason = "permission",
                    updatedAt = nowSec,
                    conversationId = convId.toString(),
                    pendingApproval = PendingApprovalDto(
                        toolCallId = toolCall.toolCallId,
                        tool = toolCall.toolName,
                        detail = redactedArgsJson,
                        highRisk = highRisk,
                    ),
                )
            )
            val card = ChannelApprovalCard(
                sessionKey = sessionKey,
                toolCallId = toolCall.toolCallId,
                toolName = toolCall.toolName,
                redactedDetail = redactedArgsJson,
                highRisk = highRisk,
                allowApproveInChannel = !highRisk,
            )
            val notice = if (highRisk) {
                "正在等待你在已配对且已解锁的原生 App 前台核对批准高风险工具 `${toolCall.toolName}`（当前通道仅可点拒绝）。"
            } else {
                "工具 `${toolCall.toolName}` 等待确认。"
            }
            return OutboundMessage(
                channel = message.channel,
                chatId = message.chatId,
                threadId = message.threadId,
                replyToMessageId = message.messageId,
                text = notice,
                conversationId = convId.toString(),
                approvalCard = card,
            )
        }

        // Auto-executable read-only tool
        val outputElement = try {
            toolRegistry.executeGate(toolCall.toolName, parsedArgs, executionScope)
        } finally {
            vault.wipePendingToolArgs(toolCall.toolCallId)
        }
        val redactedOutput = CredentialRedactor.redact(outputElement.toString())
        val executedToolPart = toolCall.copy(
            input = CredentialRedactor.redact(toolCall.input),
            approvalState = ToolApprovalState.Auto,
            output = listOf(UIMessagePart.Text(redactedOutput)),
        )
        val executedAssistantMsg = assistantReply.copy(
            parts = assistantReply.parts.map {
                if (it is UIMessagePart.Tool && it.toolCallId == toolCall.toolCallId) executedToolPart else it
            }
        )
        conversationStorage.saveConversation(
            afterUserSave.copy(
                messageNodes = afterUserSave.messageNodes + executedAssistantMsg.toMessageNode(),
                updateAt = Clock.System.now(),
            )
        )
        return OutboundMessage(
            channel = message.channel,
            chatId = message.chatId,
            threadId = message.threadId,
            replyToMessageId = message.messageId,
            text = executedAssistantMsg.toText().ifBlank { redactedOutput },
            conversationId = convId.toString(),
        )
    }

    override suspend fun handleChannelDecision(
        channel: ChannelKind,
        senderId: String,
        sessionKey: String,
        toolCallId: String,
        allow: Boolean,
    ): ChannelDecisionOutcome {
        val result = gatewayState.processDecision(
            sessionKey = sessionKey,
            toolCallId = toolCallId,
            allow = allow,
            actorDevice = "${channel.wireName}:$senderId",
            // IM channels are NEVER a trusted native foreground approval surface!
            trustedForegroundSource = false,
        )
        return ChannelDecisionOutcome(
            httpStatus = result.status,
            outcome = result.outcome,
            error = result.error,
        )
    }

    /**
     * Explicit lifecycle termination helpers ensuring all 6 terminal paths wipe stashed credentials.
     */
    suspend fun cancelPendingRun(sessionKey: String): Boolean =
        terminatePendingRun(sessionKey, AgentRunStatus.CANCELLED, "cancelled")

    suspend fun markRunOutcomeUnknown(sessionKey: String): Boolean =
        terminatePendingRun(sessionKey, AgentRunStatus.OUTCOME_UNKNOWN, "outcome_unknown")

    private suspend fun terminatePendingRun(
        sessionKey: String,
        targetStatus: AgentRunStatus,
        reason: String,
    ): Boolean {
        val pending = pendingRunsBySessionKey.remove(sessionKey) ?: return false
        // Always wipe ephemeral secret on terminal/interruption transition (Defect #2)
        vault.wipePendingToolArgs(pending.toolCallId)
        updateStoredToolOutcome(
            conversationId = pending.conversationId,
            toolCallId = pending.toolCallId,
            approvalState = ToolApprovalState.Denied(reason),
            outputJson = buildJsonObject {
                put("ok", false)
                put("status", targetStatus.wireName)
                put("reason", reason)
            }.toString(),
        )
        gatewayState.getSession(sessionKey)?.let { existing ->
            gatewayState.upsertSession(
                existing.copy(
                    state = "stopped",
                    waitReason = null,
                    abnormal = targetStatus != AgentRunStatus.COMPLETED,
                    pendingApproval = null,
                    updatedAt = CloudGatewayState.nowEpochSeconds(),
                )
            )
        }
        return true
    }

    private suspend fun interruptWaitingRunsForConversation(conversationId: Uuid) {
        val matching = pendingRunsBySessionKey.values.filter { it.conversationId == conversationId }
        for (pending in matching) {
            terminatePendingRun(pending.sessionKey, AgentRunStatus.INTERRUPTED, "interrupted_by_new_message")
        }
    }

    private suspend fun onGatewayDecision(
        sessionKey: String,
        toolCallId: String,
        allow: Boolean,
    ): Boolean {
        val pending = pendingRunsBySessionKey.remove(sessionKey) ?: return false
        if (pending.toolCallId != toolCallId) {
            vault.wipePendingToolArgs(pending.toolCallId)
            return false
        }
        return try {
            if (allow) {
                val rawArgs = vault.consumePendingToolArgs(toolCallId) ?: JsonObject(emptyMap())
                val outputElement = toolRegistry.executeGate(
                    toolName = pending.toolName,
                    args = rawArgs,
                    scope = ExecutionScope.MAIN_AGENT,
                )
                val redactedOutput = CredentialRedactor.redact(outputElement.toString())
                updateStoredToolOutcome(
                    conversationId = pending.conversationId,
                    toolCallId = toolCallId,
                    approvalState = ToolApprovalState.Approved,
                    outputJson = redactedOutput,
                )
                gatewayState.getSession(sessionKey)?.let { existing ->
                    gatewayState.upsertSession(
                        existing.copy(
                            state = "completed",
                            waitReason = null,
                            pendingApproval = null,
                            updatedAt = CloudGatewayState.nowEpochSeconds(),
                        )
                    )
                }
            } else {
                vault.wipePendingToolArgs(toolCallId)
                updateStoredToolOutcome(
                    conversationId = pending.conversationId,
                    toolCallId = toolCallId,
                    approvalState = ToolApprovalState.Denied("denied_by_user"),
                    outputJson = buildJsonObject {
                        put("ok", false)
                        put("status", "denied")
                    }.toString(),
                )
                gatewayState.getSession(sessionKey)?.let { existing ->
                    gatewayState.upsertSession(
                        existing.copy(
                            state = "completed",
                            waitReason = null,
                            pendingApproval = null,
                            updatedAt = CloudGatewayState.nowEpochSeconds(),
                        )
                    )
                }
            }
            true
        } finally {
            // Guarantee credential wipe on both approve and deny paths (Defect #2)
            vault.wipePendingToolArgs(toolCallId)
        }
    }

    private suspend fun updateStoredToolOutcome(
        conversationId: Uuid,
        toolCallId: String,
        approvalState: ToolApprovalState,
        outputJson: String,
    ) {
        val conv = conversationStorage.loadConversation(conversationId) ?: return
        val safeOutput = CredentialRedactor.redact(outputJson)
        val updatedNodes = conv.messageNodes.map { node ->
            val msg = node.currentMessage
            val updatedParts = msg.parts.map { part ->
                if (part is UIMessagePart.Tool && part.toolCallId == toolCallId) {
                    part.copy(
                        input = CredentialRedactor.redact(part.input),
                        approvalState = approvalState,
                        output = listOf(UIMessagePart.Text(safeOutput)),
                    )
                } else {
                    part
                }
            }
            if (updatedParts != msg.parts) {
                node.copy(
                    messages = node.messages.toMutableList().also {
                        it[node.selectIndex] = msg.copy(parts = updatedParts)
                    }
                )
            } else {
                node
            }
        }
        conversationStorage.saveConversation(
            conv.copy(messageNodes = updatedNodes, updateAt = Clock.System.now())
        )
    }

    /**
     * Exports a conversation JSON snapshot while scrubbing any credentials (Defect #3 & C4).
     */
    suspend fun exportConversationRedacted(conversationId: Uuid = PRIMARY_CONVERSATION_ID): String? {
        val conv = conversationStorage.loadConversation(conversationId) ?: return null
        val raw = app.amber.core.agent.utils.JsonInstant.encodeToString(Conversation.serializer(), conv)
        return CredentialRedactor.redact(raw)
    }

    private fun isWriteTool(toolName: String): Boolean {
        val def = toolRegistry.get(toolName) ?: return true
        return def.highRisk || def.effect == ToolEffect.SIDE_EFFECT
    }

    private fun sanitizeAssistantMessage(message: UIMessage): UIMessage {
        return message.copy(
            parts = message.parts.map { part ->
                when (part) {
                    is UIMessagePart.Text -> part.copy(text = CredentialRedactor.redact(part.text))
                    is UIMessagePart.Reasoning -> part.copy(reasoning = CredentialRedactor.redact(part.reasoning))
                    else -> part
                }
            }
        )
    }

    private fun extractExplicitMemoryIfPresent(text: String, conversationId: String) {
        val trimmed = text.trim()
        val prefixes = listOf("记住：", "记住:", "请记住：", "请记住:", "remember:", "remember ")
        val matchedPrefix = prefixes.firstOrNull { trimmed.startsWith(it, ignoreCase = true) } ?: return
        val fact = trimmed.substring(matchedPrefix.length).trim()
        if (fact.isNotEmpty() && !CredentialRedactor.isPlaceholderCredential(fact)) {
            runCatching {
                memoryStore.upsertMemory(
                    content = fact,
                    scope = MemoryScope.LONG_TERM,
                    kind = MemoryKind.NOTE,
                    sourceConversationId = conversationId,
                )
            }
        }
    }

    private fun registerBuiltinTools() {
        toolRegistry.register(
            CloudToolDefinition(
                name = "history_search",
                description = "检索历史会话记录（自动脱敏并附带 stale 标记）",
                highRisk = false,
                effect = ToolEffect.PURE,
                requiredCapability = "history_tools",
            ) { args ->
                val query = args["query"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                val convIdStr = args["conversation_id"]?.jsonPrimitive?.contentOrNull
                val targetId = convIdStr?.let { runCatching { Uuid.parse(it) }.getOrNull() } ?: PRIMARY_CONVERSATION_ID
                val conv = conversationStorage.loadConversation(targetId)
                val coveredIds = contextManager.loadLatestCheckpoint(targetId.toString())
                    ?.compact?.sourceMessageIds?.toSet().orEmpty()
                val hits = conv?.messageNodes?.mapIndexedNotNull { idx, node ->
                    val msg = node.currentMessage
                    val combined = msg.toText()
                    if (query.isNotEmpty() && combined.contains(query, ignoreCase = true)) {
                        val safeSnippet = CredentialRedactor.redact(combined.take(240))
                        buildJsonObject {
                            put("message_id", msg.id.toString())
                            put("index", idx)
                            put("role", msg.role.name.lowercase())
                            put("snippet", safeSnippet)
                            put("stale", msg.id.toString() in coveredIds)
                            put("redacted", safeSnippet != combined.take(240))
                        }
                    } else null
                }.orEmpty().take(12)
                buildJsonObject {
                    put("ok", true)
                    put("hits", buildJsonArray { hits.forEach { add(it) } })
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "history_fetch",
                description = "按 message_id 获取单条历史消息原文（强制脱敏）",
                highRisk = false,
                effect = ToolEffect.PURE,
                requiredCapability = "history_tools",
            ) { args ->
                val messageId = args["message_id"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val convIdStr = args["conversation_id"]?.jsonPrimitive?.contentOrNull
                val targetId = convIdStr?.let { runCatching { Uuid.parse(it) }.getOrNull() } ?: PRIMARY_CONVERSATION_ID
                val conv = conversationStorage.loadConversation(targetId)
                val coveredIds = contextManager.loadLatestCheckpoint(targetId.toString())
                    ?.compact?.sourceMessageIds?.toSet().orEmpty()
                val found = conv?.messageNodes?.withIndex()?.firstOrNull { (_, node) ->
                    node.currentMessage.id.toString().equals(messageId, ignoreCase = true)
                }
                if (found == null) {
                    buildJsonObject {
                        put("ok", false)
                        put("error", "这条消息不在当前会话记录中；请用 history_search 重新定位。")
                    }
                } else {
                    val raw = found.value.currentMessage.toText()
                    val safe = CredentialRedactor.redact(raw)
                    buildJsonObject {
                        put("ok", true)
                        put("message_id", found.value.currentMessage.id.toString())
                        put("index", found.index)
                        put("role", found.value.currentMessage.role.name.lowercase())
                        put("stale", found.value.currentMessage.id.toString() in coveredIds)
                        put("text", safe.take(4_000))
                        put("redacted", safe != raw)
                    }
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "memory_write",
                description = "写入或更新长期记忆",
                highRisk = false,
                effect = ToolEffect.SIDE_EFFECT,
                requiredCapability = "memory_tools",
            ) { args ->
                val content = args["content"]?.jsonPrimitive?.contentOrNull.orEmpty()
                if (CredentialRedactor.isPlaceholderCredential(content)) {
                    throw PlaceholderCredentialException("拒绝将占位符写入记忆")
                }
                val record = memoryStore.upsertMemory(content = content)
                buildJsonObject {
                    put("ok", true)
                    put("id", record.id)
                    put("content", record.content)
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "workspace_file_write",
                description = "在云端受管工作区写入文件",
                highRisk = false,
                effect = ToolEffect.SIDE_EFFECT,
                requiredCapability = "workspace_files",
            ) { args ->
                val relPath = args["path"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                val content = args["content"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val target = File(workspaceDir, relPath).canonicalFile
                require(target.path.startsWith(workspaceDir.canonicalPath)) { "禁止越界写入工作区外路径" }
                target.parentFile?.mkdirs()
                target.writeText(content)
                buildJsonObject {
                    put("ok", true)
                    put("path", relPath)
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "terminal_exec",
                description = "执行高风险终端命令（须在授信原生 App 前台批准）",
                highRisk = true,
                effect = ToolEffect.SIDE_EFFECT,
                requiredCapability = "terminal",
            ) { args ->
                val cmd = args["command"]?.jsonPrimitive?.contentOrNull.orEmpty()
                buildJsonObject {
                    put("ok", true)
                    put("executed", CredentialRedactor.redact(cmd))
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "ssh_profile_create",
                description = "创建高风险 SSH 主机凭据配置",
                highRisk = true,
                effect = ToolEffect.SIDE_EFFECT,
                requiredCapability = "ssh_remote",
            ) { args ->
                val host = args["host"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val password = args["password"]?.jsonPrimitive?.contentOrNull.orEmpty()
                if (password.isNotEmpty()) {
                    vault.putSecret("ssh:$host:password", password)
                }
                buildJsonObject {
                    put("ok", true)
                    put("host", host)
                    put("password", CredentialRedactor.MASK)
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "js_sandbox_eval",
                description = "执行受控 JS 沙箱脚本（默认关闭）",
                highRisk = false,
                effect = ToolEffect.PURE,
                requiredCapability = "js_sandbox",
            ) { args ->
                buildJsonObject {
                    put("ok", true)
                    put("result", args["code"]?.jsonPrimitive?.contentOrNull.orEmpty())
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "recipe_run",
                description = "按步骤调用已注册工具（严格经过同一权限与能力开关门禁）",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                val stepTool = args["tool"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val stepArgs = args["args"]?.jsonObject ?: JsonObject(emptyMap())
                // Defect #8: Recipe always delegates through executeGate so disabled capabilities
                // or high-risk rules can NEVER be bypassed!
                toolRegistry.executeGate(stepTool, stepArgs, ExecutionScope.RECIPE)
            }
        )
    }
}
