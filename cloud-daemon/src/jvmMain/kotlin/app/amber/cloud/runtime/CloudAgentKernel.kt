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
import app.amber.cloud.channel.OutboundReceipt
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.SessionDto
import app.amber.cloud.orchestration.AutomationTurnOutput
import app.amber.cloud.orchestration.CloudOrchestrationStore
import app.amber.cloud.orchestration.CloudRouter
import app.amber.cloud.orchestration.ConnectorImStatusSink
import app.amber.cloud.orchestration.DefaultCloudOrchestrationKernel
import app.amber.cloud.orchestration.ModelRouterBrain
import app.amber.cloud.orchestration.ModelWorkerTurnRunner
import app.amber.cloud.orchestration.OrchestrationConfig
import app.amber.cloud.orchestration.RouterBrain
import app.amber.cloud.orchestration.RouterDecision
import app.amber.cloud.proactive.InterruptionBudgetConfig
import app.amber.cloud.proactive.L2NoteworthyScore
import app.amber.cloud.proactive.NoteworthyJudgeProvider
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.QuietHoursConfig
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
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
    val ownerBinding: OwnerBindingManager = OwnerBindingManager(
        persistenceFile = File(dataDir, "owner-bindings.json"),
    ),
    val proactiveEngine: ProactiveEngine = ProactiveEngine(
        l2Judge = NoteworthyJudgeProvider { req ->
            L2NoteworthyScore(
                noteworthy = true,
                urgency = 4,
                importance = 4,
                summary = req.deltaSummary.lines().firstOrNull()?.take(80) ?: req.topicKey,
            )
        },
        restraintGate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(),
            budgetConfig = InterruptionBudgetConfig(),
        ),
    ),
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
    val orchestrationStore = CloudOrchestrationStore(dataDir)
    val orchestrationKernel = DefaultCloudOrchestrationKernel(
        config = OrchestrationConfig(),
        store = orchestrationStore,
        conversationStorage = conversationStorage,
        toolRegistry = toolRegistry,
        proactiveEngine = proactiveEngine,
        autoExecuteWorkersInBackground = true,
    )
    val workerTurnRunner = ModelWorkerTurnRunner(
        kernel = orchestrationKernel,
        modelClient = modelClient,
        toolRegistry = toolRegistry,
    )
    val router: CloudRouter
    private val routerIngress by lazy { CloudRouterIngress(this) }

    private val connectors = ConcurrentHashMap<ChannelKind, ChannelConnector>()
    private val pendingRunsBySessionKey = ConcurrentHashMap<String, PendingRunRecord>()
    private val proactiveScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var proactiveJob: Job? = null

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
        orchestrationKernel.workerTurnRunner = { item, principal ->
            workerTurnRunner.run(item, principal)
        }
        orchestrationKernel.onOwnerNotificationCard = { card, key ->
            for ((kind, connector) in connectors) {
                val ownerChatId = ownerBinding.getOwnerDirectChatId(kind.wireName) ?: continue
                connector.sendWithReceipt(
                    OutboundMessage(
                        channel = kind,
                        chatId = ownerChatId,
                        text = card.markdownBody,
                        conversationId = PRIMARY_CONVERSATION_ID.toString(),
                        card = card,
                        idempotencyKey = "orch:$key:${kind.wireName}:${System.nanoTime()}",
                    )
                )
            }
        }
        router = CloudRouter(
            kernel = orchestrationKernel,
            sink = ConnectorImStatusSink { kind -> connectors[kind] },
            brain = RouterBrain { RouterDecision() },
            executionToolNames = toolRegistry.availableDefinitions(ExecutionScope.MAIN_AGENT).map { it.name }.toSet(),
            onReply = { conversationId, text -> routerIngress.recordReply(conversationId, text) },
        ).also { r ->
            r.brain = ModelRouterBrain(
                modelClient = modelClient,
                routerTools = { r.routerTools },
                contextMessages = { input -> routerIngress.contextMessages(input) },
            )
        }
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
        orchestrationKernel.recoverAfterRestart()
    }

    fun registerConnector(connector: ChannelConnector) {
        connector.attachIngress(routerIngress)
        connectors[connector.kind] = connector
    }

    /**
     * Starts the resident proactive intelligence engine background loop inside `amberd`.
     */
    fun startProactiveLoop(pollIntervalMs: Long = 60_000L) {
        orchestrationKernel.startHealthLoop(pollIntervalMs)
        if (proactiveJob?.isActive == true) return
        proactiveJob = proactiveScope.launch {
            while (isActive) {
                try {
                    runProactiveCycle()
                } catch (ce: CancellationException) {
                    throw ce
                } catch (_: Throwable) {
                    // Keep resident loop alive on transient sensor errors
                }
                delay(pollIntervalMs)
            }
        }
    }

    fun stopProactiveLoop() {
        orchestrationKernel.stopHealthLoop()
        proactiveJob?.cancel()
        proactiveJob = null
    }

    val isProactiveLoopRunning: Boolean
        get() = proactiveJob?.isActive == true

    /**
     * Polls all registered proactive trigger sources and routes produced L3 cards through
     * the kernel's restraint gate (quiet hours + interruption budget) to the owner's private chats.
     */
    suspend fun runProactiveCycle(nowOverrideMs: Long? = null): List<ProactiveRunResult> {
        val nowMs = nowOverrideMs ?: System.currentTimeMillis()
        if (orchestrationStore.listAutomations().isNotEmpty()) {
            orchestrationKernel.runDueAutomations(nowMs) { envelope, _, sessionId ->
                val convUuid = runCatching { Uuid.parse(sessionId) }.getOrNull()
                val msgs = convUuid?.let { conversationStorage.loadConversation(it) }?.messageNodes?.map { it.currentMessage }.orEmpty()
                val reply = modelClient.generateReply(msgs, toolRegistry.declaredTools(ExecutionScope.SUBAGENT))
                AutomationTurnOutput(
                    summary = CredentialRedactor.redact(reply.toText().ifBlank { "已完成巡检 #${envelope.iteration}" }),
                    decision = "silent",
                )
            }
        }
        val rawResults = proactiveEngine.pollAllSources(targetChatId = "", channel = null)
        return rawResults.map { res ->
            if (res is ProactiveRunResult.PushedAtL3) {
                deliverProactiveCardToOwner(res)
            } else {
                res
            }
        }
    }

    /**
     * Evaluates a single [ProactiveTriggerSignal] in the kernel (enforcing L1, L2, quiet hours,
     * and interruption budget) and delivers any produced L3 card to the owner's private chats
     * across registered outbound [ChannelConnector]s while recording it on [PRIMARY_CONVERSATION_ID].
     */
    suspend fun triggerProactiveSignal(
        signal: ProactiveTriggerSignal,
        nowOverrideMs: Long? = null,
    ): ProactiveRunResult {
        val res = proactiveEngine.processSignal(
            signal = signal,
            targetChatId = "",
            channel = null,
            nowOverrideMs = nowOverrideMs,
        )
        return if (res is ProactiveRunResult.PushedAtL3) {
            deliverProactiveCardToOwner(res)
        } else {
            res
        }
    }

    private suspend fun deliverProactiveCardToOwner(pushed: ProactiveRunResult.PushedAtL3): ProactiveRunResult.PushedAtL3 {
        val card = pushed.card
        var firstReceipt: OutboundReceipt? = pushed.receipt

        // Record the proactive card in the primary timeline so context is continuous across restarts
        val existing = conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)
            ?: Conversation(
                id = PRIMARY_CONVERSATION_ID,
                assistantId = DEFAULT_ASSISTANT_ID,
                title = "主时间线",
                messageNodes = emptyList(),
            )
        val proactiveMsg = sanitizeAssistantMessage(
            UIMessage.assistant("【主动提醒 · ${card.title}】\n${card.markdownBody}")
        )
        conversationStorage.saveConversation(
            existing.copy(
                messageNodes = existing.messageNodes + proactiveMsg.toMessageNode(),
                updateAt = Clock.System.now(),
            )
        )

        // Dispatch outbound card to all registered connectors where the owner has a bound private chat
        for ((kind, connector) in connectors) {
            val ownerChatId = ownerBinding.getOwnerDirectChatId(kind.wireName) ?: continue
            val outbound = OutboundMessage(
                channel = kind,
                chatId = ownerChatId,
                text = card.markdownBody,
                conversationId = PRIMARY_CONVERSATION_ID.toString(),
                silent = pushed.restraintVerdict.silentDelivery,
                card = card,
                idempotencyKey = "proactive:${pushed.l1Delta.signalId}:${kind.wireName}",
            )
            val receipt = connector.sendWithReceipt(outbound)
            if (firstReceipt == null) {
                firstReceipt = receipt
            }
        }
        return pushed.copy(receipt = firstReceipt)
    }

    // Retained synchronous entry for existing direct callers and the P1 approval lifecycle.
    // Registered IM connectors use CloudRouterIngress and never run this model/tool loop.
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
            ownerBinding.bindOwnerDirectly(message.channel.wireName, message.senderId, message.chatId)
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
                allowApproveInChannel = false,
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
        val resolvedSessionKey = sessionKey.trim().ifEmpty {
            pendingRunsBySessionKey.values.firstOrNull { it.toolCallId == toolCallId }?.sessionKey.orEmpty()
        }
        val result = gatewayState.processDecision(
            sessionKey = resolvedSessionKey,
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

    internal suspend fun interruptWaitingRunsForConversation(conversationId: Uuid) {
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

    internal fun extractExplicitMemoryIfPresent(text: String, conversationId: String) {
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
        CloudBuiltinTools.registerAll(
            toolRegistry = toolRegistry,
            conversationStorage = conversationStorage,
            contextManager = contextManager,
            memoryStore = memoryStore,
            vault = vault,
            workspaceDir = workspaceDir,
        )
    }
}
