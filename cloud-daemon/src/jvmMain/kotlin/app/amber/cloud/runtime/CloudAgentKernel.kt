package app.amber.cloud.runtime

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
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
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.CloudRouter
import app.amber.cloud.orchestration.ConnectorImStatusSink
import app.amber.cloud.orchestration.DefaultCloudOrchestrationKernel
import app.amber.cloud.orchestration.DialogueEvent
import app.amber.cloud.orchestration.DialogueEventKinds
import app.amber.cloud.orchestration.ModelRouterBrain
import app.amber.cloud.orchestration.ModelWorkerTurnRunner
import app.amber.cloud.orchestration.OrchestrationConfig
import app.amber.cloud.orchestration.ProactiveEventMeta
import app.amber.cloud.orchestration.RouterBrain
import app.amber.cloud.orchestration.RouterDecision
import app.amber.cloud.agents.AgentRegistry
import app.amber.cloud.agents.AgentRouting
import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.agents.AgentRouterCoordinator
import app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID
import app.amber.cloud.agents.MAIN_AGENT_ID
import app.amber.cloud.supertags.ConversationTagger
import app.amber.cloud.supertags.HubService
import app.amber.cloud.supertags.SupertagMaintenance
import app.amber.cloud.supertags.SupertagStore
import app.amber.cloud.proactive.CloudProactiveL2Judge
import app.amber.cloud.proactive.CommitmentExtractor
import app.amber.cloud.proactive.DailyPulseTriggerSource
import app.amber.cloud.proactive.DeviceContextPrepTriggerSource
import app.amber.cloud.proactive.InterruptionBudgetConfig
import app.amber.cloud.proactive.L1DeterministicFilter
import app.amber.cloud.proactive.L1Outcome
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveFeedbackAction
import app.amber.cloud.proactive.ProactiveFilePersistence
import app.amber.cloud.proactive.ProactiveMonitorStore
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.proactive.ProactiveRunHistoryStore
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.ProactiveUrgency
import app.amber.cloud.proactive.ProactiveWakeupRecord
import app.amber.cloud.proactive.ProactiveWakeupStore
import app.amber.cloud.proactive.ProactiveWebhookStore
import app.amber.cloud.proactive.QuietHoursConfig
import app.amber.cloud.proactive.SelfWakeupTriggerSource
import app.amber.cloud.proactive.TriggerCategory
import app.amber.cloud.proactive.WatchtowerMonitorTriggerSource
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.agent.runtime.AgentRunStatus
import app.amber.core.model.Conversation
import app.amber.core.model.ConversationMemoryMode
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

data class StreamActivity(
    val kind: String,
    val deltaTextChars: Int = 0,
    val toolName: String? = null,
)

/**
 * Abstraction over KMP model providers (`:ai-provider-claude`, `:ai-provider-openai`)
 * and deterministic test providers.
 */
fun interface CloudModelClient {
    suspend fun generateReply(
        messages: List<UIMessage>,
        tools: List<Tool>,
    ): UIMessage

    suspend fun streamReply(
        messages: List<UIMessage>,
        tools: List<Tool>,
        onActivity: (StreamActivity) -> Unit,
    ): UIMessage {
        val reply = generateReply(messages, tools)
        onActivity(StreamActivity(kind = "complete"))
        return reply
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
    val modelClients: Map<String, CloudModelClient> = emptyMap(),
    val configurationManager: app.amber.cloud.config.CloudConfigurationManager? = null,
    vaultOverride: EnvelopeCredentialVault? = null,
    ownerToolScope: Set<String>? = null,
    searchSources: List<String> = listOf("bing","duckduckgo"),
    searchMode: String = "fallback",
    val ownerBinding: OwnerBindingManager = OwnerBindingManager(
        persistenceFile = File(dataDir, "owner-bindings.json"),
    ),
    val proactiveEngine: ProactiveEngine = ProactiveEngine(
        l1Filter = L1DeterministicFilter(
            persistenceFile = File(File(dataDir, "proactive"), "l1-filter.json"),
        ),
        l2Judge = CloudProactiveL2Judge(modelClient),
        restraintGate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(),
            budgetConfig = InterruptionBudgetConfig(),
            persistenceFile = File(File(dataDir, "proactive"), "restraint-gate.json"),
        ),
    ),
    val workerApprovals: Boolean = false,
    val workerApprovalTtlMs: Long = 30 * 60_000L,
    proactiveHttpClient: io.ktor.client.HttpClient? = null,
    proactiveDnsResolver: (String) -> List<java.net.InetAddress> = { java.net.InetAddress.getAllByName(it).toList() },
) : ChannelIngress {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val conversationsDir = File(dataDir, "conversations").also { it.mkdirs() }
    val memoryDir = File(dataDir, "memory").also { it.mkdirs() }
    val checkpointsDir = File(dataDir, "checkpoints").also { it.mkdirs() }
    val workspaceDir = File(dataDir, "workspace").also { it.mkdirs() }
    val proactiveDir = File(dataDir, "proactive").also { ProactiveFilePersistence.ensureOwnerOnlyDir(it) }

    val conversationStorage = JsonConversationStorage(ConversationFile(conversationsDir.absolutePath))
    val vault = vaultOverride ?: EnvelopeCredentialVault(
        vaultFile = File(dataDir, "secrets.enc.json"),
        masterSecretOverride = masterSecretOverride,
    )
    val proactiveMonitorStore = ProactiveMonitorStore(proactiveDir)
    val proactiveWebhookStore = ProactiveWebhookStore(proactiveDir, vault)
    val proactiveRunHistoryStore = ProactiveRunHistoryStore(proactiveDir)
    val proactiveWakeupStore = ProactiveWakeupStore(
        proactiveDir = proactiveDir,
        zoneIdProvider = { proactiveEngine.restraintGate.budgetConfig.zoneId },
    )
    val memoryStore = CloudMemoryStore(memoryDir)
    val proceduralRuleStore = app.amber.cloud.rules.ProceduralRuleStore(dataDir)
    val soulStore = app.amber.cloud.soul.CloudSoulStore(dataDir = dataDir, memoryDir = memoryDir, workspaceDir = workspaceDir).also { s ->
        memoryStore.onSoulPromptSaved = { md ->
            s.put(app.amber.cloud.soul.SoulPutRequestDto(soulMarkdown = md, isDefault = md.isBlank(), source = "memory_store"))
        }
    }
    val contextManager = CloudContextManager(checkpointsDir)
    val toolRegistry = CloudToolRegistry()
    val taskProcesses = app.amber.cloud.tasks.TaskProcessRunner(File(dataDir, "toolchain").also { it.mkdirs() })
    val taskWorkspace = app.amber.cloud.tasks.TaskWorkspace(File(dataDir, "task-workspaces"), taskProcesses)
    val publicHttp = app.amber.cloud.tasks.PublicHttp()
    val taskToolchain = app.amber.cloud.tasks.TaskToolchain(publicHttp,taskProcesses,taskWorkspace)
    val search = app.amber.cloud.tasks.CloudSearch(publicHttp, vault, searchSources, searchMode, workspace = taskWorkspace)
    val gatewayState = CloudGatewayState(dataDir, soulRevisionProvider = { soulStore.currentRevision() })
    private val approvalHelper = ToolApprovalHelper(vault, gatewayState, conversationStorage)
    val orchestrationStore = CloudOrchestrationStore(dataDir)
    val agentRegistry = AgentRegistry(dataDir, orchestrationStore,
        ownerGrantedTools = {
            val enabled = toolRegistry.availableDefinitions(ExecutionScope.MAIN_AGENT).map { it.name }.toSet()
            ownerToolScope?.intersect(enabled) ?: enabled
        },
        modelPreferences = { modelClients.keys },
    )
    val supertagStore = SupertagStore(dataDir)
    val hubs = HubService(agentRegistry, supertagStore, memoryStore)
    val agentRouting = AgentRouting(agentRegistry, modelClient, supertagStore::focusedHub)
    val conversationTagger = ConversationTagger(supertagStore, modelClient,
        reportFailure = { conversationId, kind ->
            orchestrationStore.appendDiagnosticEvent(sessionId = conversationId, workItemId = null, kind = kind, detail = "后台标签提取未完成", nowMs = System.currentTimeMillis())
        },
        memoryEnabled = { id -> conversationStorage.loadConversation(Uuid.parse(id))?.memoryMode == ConversationMemoryMode.ENABLED },
    )
    val supertagMaintenance = SupertagMaintenance(supertagStore, modelClient) { kind ->
        orchestrationStore.appendDiagnosticEvent(sessionId = "supertags", workItemId = null, kind = kind, detail = "模板同义整理未完成", nowMs = System.currentTimeMillis())
    }
    val orchestrationKernel = DefaultCloudOrchestrationKernel(
        config = OrchestrationConfig(
            workerApprovals = workerApprovals,
            workerApprovalTtlMs = workerApprovalTtlMs,
        ),
        store = orchestrationStore,
        conversationStorage = conversationStorage,
        toolRegistry = toolRegistry,
        proactiveEngine = proactiveEngine,
        autoExecuteWorkersInBackground = true,
        agentRegistry = agentRegistry,
        conversationHub = supertagStore::conversationHub,
        vault = vault,
        gatewayState = gatewayState,
    )
    val workerTurnRunner = ModelWorkerTurnRunner(
        kernel = orchestrationKernel,
        modelClient = modelClient,
        toolRegistry = toolRegistry,
        memoryStore = memoryStore,
        modelClients = modelClients,
        soulStore = soulStore,
        proceduralRuleStore = proceduralRuleStore,
        contextManager = contextManager,
        contextWindowTokens = contextWindowTokens,
    )
    val router: CloudRouter
    private val routerIngress by lazy { CloudRouterIngress(this) }
    val nativeDialogue by lazy { NativeDialogueService(this,{routerIngress.handleInbound(it)}) {id,text->
        routerIngress.recordReply(PRIMARY_CONVERSATION_ID.toString(),text,Uuid.parse(java.util.UUID.nameUUIDFromBytes(id.toByteArray()).toString()))
    } }
    val scheduleRunner by lazy { app.amber.cloud.gateway.CloudScheduleRunner(this) }
    val watchtowerTriggerSource = WatchtowerMonitorTriggerSource(
        monitorStore = proactiveMonitorStore,
        l1Filter = proactiveEngine.l1Filter,
        httpClient = proactiveHttpClient,
        dnsResolver = proactiveDnsResolver,
    )
    val deviceContextPrepTriggerSource: DeviceContextPrepTriggerSource = DeviceContextPrepTriggerSource(
        deviceContextStore = gatewayState.deviceContextStore,
        memoryStore = memoryStore,
        pairedDevicesProvider = gatewayState::loadDevicesStrict,
        zoneIdProvider = { proactiveEngine.restraintGate.budgetConfig.zoneId },
    )
    val selfWakeupTriggerSource: SelfWakeupTriggerSource = SelfWakeupTriggerSource(
        wakeupStore = proactiveWakeupStore,
        onExpired = { record, nowMs ->
            val summary = CredentialRedactor.redact("已过期提醒：${record.title}")
            proactiveEngine.restraintGate.bufferExpiredWakeup(record.id, summary)
            proactiveRunHistoryStore.record(
                signalId = ProactiveWakeupStore.signalIdFor(record),
                category = if (record.kind == ProactiveWakeupRecord.KIND_COMMITMENT) {
                    TriggerCategory.MEMORY_COMMITMENT
                } else {
                    TriggerCategory.CLOCK_CRON
                },
                topicKey = "wakeup:${record.id}",
                title = record.title,
                outcome = "wakeup_expired",
                summary = "唤醒已逾期超过 12 小时，已转入 Pulse 缓冲",
                timestampEpochMs = nowMs,
            )
        },
    )
    val dailyPulseTriggerSource: DailyPulseTriggerSource = DailyPulseTriggerSource(
        restraintGate = proactiveEngine.restraintGate,
        l1Filter = proactiveEngine.l1Filter,
        deviceContextStore = gatewayState.deviceContextStore,
        pairedDevicesProvider = gatewayState::loadDevicesStrict,
    )
    val commitmentExtractor: CommitmentExtractor = CommitmentExtractor(
        wakeupStore = proactiveWakeupStore,
        restraintGate = proactiveEngine.restraintGate,
        modelClientProvider = { configurationManager?.snapshot()?.model ?: modelClient },
        memoryModeProvider = { id ->
            runCatching { Uuid.parse(id) }.getOrNull()?.let { conversationStorage.loadConversation(it)?.memoryMode }
        },
        persistenceFile = File(proactiveDir, "commitment-extractor.json"),
    )

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
        proactiveEngine.registerTriggerSource(watchtowerTriggerSource)
        proactiveEngine.registerTriggerSource(deviceContextPrepTriggerSource)
        proactiveEngine.registerTriggerSource(selfWakeupTriggerSource)
        proactiveEngine.registerTriggerSource(dailyPulseTriggerSource)
        app.amber.cloud.tasks.TaskExecutionTools(taskWorkspace, taskProcesses).register(toolRegistry)
        app.amber.cloud.tasks.TaskNetworkTools(publicHttp, taskWorkspace).register(toolRegistry)
        search.register(toolRegistry) {
            kotlinx.coroutines.currentCoroutineContext()[app.amber.cloud.config.RuntimeConfigurationSnapshot]?.search
                ?: configurationManager?.snapshot()?.search ?: search
        }
        taskToolchain.register(toolRegistry)
        orchestrationKernel.stopTaskProcesses = {taskProcesses.cancelTask(it)}
        orchestrationKernel.stopTaskProcessesNonClosing = {taskProcesses.stopTask(it)}
        orchestrationKernel.hasBackgroundProcesses = taskProcesses::active
        orchestrationKernel.settlementListener = { item, report ->
            nativeDialogue.settlement(item, report)
            scheduleRunner.onWorkItemSettled(item, report)
        }
        orchestrationKernel.workerCommentary = { item, text -> nativeDialogue.commentary(item, text) }
        taskProcesses.inputPending = {orchestrationKernel.workerEvents.pending(it).isNotEmpty()}
        taskProcesses.onBackgroundStarted = {owner,id,pid,started->
            orchestrationStore.dialogue.processStarted(id,owner,pid,started)
            orchestrationKernel.touchWorkItemActivity(owner)
        }
        taskProcesses.onBackgroundFinished = {owner,result->
            val item=orchestrationStore.getWorkItem(owner)
            orchestrationStore.dialogue.processFinished(result.id,owner,item?.let(nativeDialogue::topic)?:owner,kotlinx.serialization.json.Json.encodeToString(result))
            if(item?.state?.isTerminal==true)orchestrationStore.dialogue.abandonPending(owner)
            else orchestrationKernel.touchWorkItemActivity(owner)
            orchestrationKernel.signalWorker(owner)
        }
        orchestrationKernel.workerTurnRunner = { item, principal ->
            val report = try {
                val snapshot = configurationManager?.snapshot()
                if (snapshot == null) workerTurnRunner.run(item, principal)
                else kotlinx.coroutines.withContext(snapshot) { workerTurnRunner.run(item, principal) }
            }
                finally { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { taskProcesses.stopTask(item.workItemId) } }
            val disabledSource = item.sourceProvenance.map { it.sessionId }.distinct().any { id ->
                val uuid = runCatching { Uuid.parse(id) }.getOrNull()
                val mode = uuid?.let { conversationStorage.loadConversation(it)?.memoryMode }
                mode != null && mode != ConversationMemoryMode.ENABLED
            }
            if (report.outcome == "completed" && !disabledSource) item.workerSessionId?.let { id ->
                if (item.agentId != MAIN_AGENT_ID) supertagStore.bindConversation(id, item.agentId)
                conversationStorage.loadConversation(Uuid.parse(id))?.let { conversationTagger.enqueue(it, if (item.agentId == MAIN_AGENT_ID) GLOBAL_MEMORY_AGENT_ID else item.agentId) }
            }
            report
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
        orchestrationKernel.onWorkerApprovalRequested = { item, card ->
            for ((kind, connector) in connectors) {
                val ownerChatId = ownerBinding.getOwnerDirectChatId(kind.wireName) ?: continue
                connector.sendWithReceipt(
                    OutboundMessage(
                        channel = kind,
                        chatId = ownerChatId,
                        text = "任务「${item.title}」正在等待你在原生 App 前台核对批准高危工具 `${card.toolName}`（当前通道仅可拒绝）。",
                        conversationId = PRIMARY_CONVERSATION_ID.toString(),
                        approvalCard = card,
                        idempotencyKey = "wi-approval:${card.sessionKey}:${kind.wireName}",
                    )
                )
            }
        }
        router = CloudRouter(
            kernel = orchestrationKernel,
            sink = ConnectorImStatusSink(
                connectorLookup = { kind -> connectors[kind] },
                onPostFailed = { address, detail ->
                    if (address.channel != ChannelKind.APP) {
                        orchestrationStore.appendDiagnosticEvent(
                            sessionId = PRIMARY_CONVERSATION_ID.toString(),
                            workItemId = null,
                            kind = "im_post_failed",
                            detail = "channel=${address.channel.wireName}, chatId=${address.chatId}, threadId=${address.threadId}, error=$detail",
                            nowMs = System.currentTimeMillis(),
                        )
                    }
                },
            ),
            brain = RouterBrain { RouterDecision() },
            executionToolNames = toolRegistry.availableDefinitions(ExecutionScope.MAIN_AGENT).map { it.name }.toSet(),
            onReply = { conversationId, text -> routerIngress.recordReply(conversationId, text) },
            onEventsHandled = {events,replies->nativeDialogue.handled(events,replies)},
            agentCoordinator = AgentRouterCoordinator(orchestrationKernel, agentRegistry, agentRouting) { text, conversationId, agentId ->
                if (conversationStorage.loadConversation(Uuid.parse(conversationId))?.memoryMode == ConversationMemoryMode.ENABLED) {
                    extractExplicitMemoryIfPresent(text, conversationId, if (agentId == MAIN_AGENT_ID) GLOBAL_MEMORY_AGENT_ID else agentId)
                }
            },
            onTurnCompleted = { input, replies ->
                val conversation = conversationStorage.loadConversation(Uuid.parse(input.events.first().conversationId))
                val userEvents = input.events.filter { it.kind == "user_message" }
                val reply = conversation?.messageNodes?.lastOrNull { it.role == MessageRole.ASSISTANT }
                if (conversation != null && reply != null) {
                    val prompt = userEvents.joinToString("\n") { it.summaryText }
                    conversationTagger.enqueue(conversation.copy(messageNodes = listOf(UIMessage.user(prompt).toMessageNode(), reply)))
                }
                if (conversation?.memoryMode == ConversationMemoryMode.ENABLED && input.ownerAuthorizedMessageIds.isNotEmpty()) {
                    val ownerEvents = userEvents.filter { it.sourceMessageId in input.ownerAuthorizedMessageIds }
                    commitmentExtractor.enqueue(
                        conversationId = conversation.id.toString(),
                        userText = ownerEvents.joinToString("\n") { it.summaryText },
                        // A reply to a mixed batch can describe another sender's commitments.
                        assistantText = if (ownerEvents.size == input.events.size) replies.joinToString("\n") else "",
                    )
                }
            },
            soulStore = soulStore,
        ).also { r ->
            r.brain = ModelRouterBrain(
                modelClient = modelClient,
                modelSnapshot = { configurationManager?.snapshot()?.model ?: modelClient },
                routerTools = { r.routerTools },
                contextMessages = { input -> routerIngress.contextMessages(input) },
            )
        }
        // Wire gateway decision callbacks into the kernel (V2 Worker approvals must precede V1)
        gatewayState.registerDecisionListener { sessionKey, toolCallId, allow ->
            if (sessionKey.startsWith("amber:wi:")) {
                orchestrationKernel.handleV2GatewayDecision(sessionKey, toolCallId, allow)
            } else {
                false
            }
        }
        gatewayState.registerDecisionListener { sessionKey, toolCallId, allow ->
            onGatewayDecision(sessionKey, toolCallId, allow)
        }
        // Defect #2: Cold-start recovery wipes any leftover ephemeral secrets
        vault.wipeAllPendingToolArgs()
    }

    suspend fun recoverColdStartConversations() {
        vault.wipeAllPendingToolArgs()
        conversationStorage.reconcileIndex()
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
        nativeDialogue.recover()
        orchestrationKernel.recoverAfterRestart()
        scheduleRunner.recoverAfterRestart()
        conversationTagger.resumePending()
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
        orchestrationKernel.shutdownForRestart()
        router.shutdown()
        commitmentExtractor.close()
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
        supertagMaintenance.runDue(nowMs)
        scheduleRunner.runDue(nowMs)
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
        return proactiveEngine.pollAllSources(
            targetChatId = "",
            channel = null,
            nowOverrideMs = nowMs,
        ) { signal, result ->
            val delivered = if (result is ProactiveRunResult.PushedAtL3) deliverProactiveCardToOwner(result) else result
            proactiveRunHistoryStore.recordFromResult(delivered, fallbackSignal = signal, timestampEpochMs = nowMs)
            delivered
        }
    }

    /**
     * Evaluates a single [ProactiveTriggerSignal] in the kernel (enforcing L1, L2, quiet hours,
     * and interruption budget) and delivers any produced L3 card to the owner's private chats
     * across registered outbound [ChannelConnector]s and paired APNs devices while recording it on [PRIMARY_CONVERSATION_ID].
     */
    suspend fun triggerProactiveSignal(
        signal: ProactiveTriggerSignal,
        nowOverrideMs: Long? = null,
    ): ProactiveRunResult {
        val evalNowMs = nowOverrideMs ?: signal.timestampEpochMs
        val res = proactiveEngine.processSignal(
            signal = signal,
            targetChatId = "",
            channel = null,
            nowOverrideMs = nowOverrideMs,
        )
        val delivered = if (res is ProactiveRunResult.PushedAtL3) deliverProactiveCardToOwner(res) else res
        proactiveRunHistoryStore.recordFromResult(delivered, fallbackSignal = signal, timestampEpochMs = evalNowMs)
        return delivered
    }

    sealed interface ProactiveFeedbackResult {
        data class Applied(
            val action: ProactiveFeedbackAction,
            val applied: Boolean,
            val wakeupId: String? = null,
            val mutedUntilEpochMs: Long? = null,
        ) : ProactiveFeedbackResult

        data object SignalNotFound : ProactiveFeedbackResult
    }

    /**
     * 统一应用用户对主动卡片的反馈（供 REST `/v2/proactive/signals/{id}/feedback` 与 IM `pa:` 回调共用）。
     */
    fun applyProactiveFeedback(
        signalId: String,
        action: ProactiveFeedbackAction,
        snoozeMinutes: Int = 60,
        muteHours: Int = 168,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): ProactiveFeedbackResult {
        val event = orchestrationStore.dialogue.findEvent("proactive:$signalId")
            ?: return ProactiveFeedbackResult.SignalNotFound
        val meta = event.proactive
        val topicKey = meta?.topicKey?.takeIf { it.isNotBlank() } ?: "proactive:$signalId"
        val title = meta?.title?.takeIf { it.isNotBlank() } ?: "Amber 主动提醒"
        val category = meta?.category
            ?.let { runCatching { TriggerCategory.valueOf(it) }.getOrNull() }
            ?: TriggerCategory.CLOCK_CRON

        val clampedSnooze = snoozeMinutes.coerceIn(15, 1440)
        val clampedMute = muteHours.coerceIn(1, 720)
        val outcome = proactiveEngine.restraintGate.applyFeedback(
            signalId = signalId,
            topicKey = topicKey,
            action = action,
            nowEpochMs = nowEpochMs,
            muteHours = clampedMute,
        ) {
            if (action == ProactiveFeedbackAction.SNOOZE) {
                proactiveWakeupStore.upsertSnooze(
                    originSignalId = signalId,
                    title = title,
                    detail = event.text.take(1_000),
                    checkPrompt = meta?.checkPrompt,
                    triggerAtEpochMs = nowEpochMs + clampedSnooze * 60_000L,
                    nowEpochMs = nowEpochMs,
                )
            }
        }

        if (outcome.applied) {
            val summary = when (action) {
                ProactiveFeedbackAction.OPENED -> "用户已打开卡片"
                ProactiveFeedbackAction.REPLIED -> "用户已交由 Amber 处理"
                ProactiveFeedbackAction.DISMISS -> "用户忽略了该卡片"
                ProactiveFeedbackAction.SNOOZE -> "已延后 $clampedSnooze 分钟再提醒"
                ProactiveFeedbackAction.MUTE_TOPIC -> "已静音该话题 $clampedMute 小时"
            }
            proactiveRunHistoryStore.record(
                signalId = signalId,
                category = category,
                topicKey = topicKey,
                title = title,
                outcome = "feedback_${action.wire}",
                summary = summary,
                timestampEpochMs = nowEpochMs,
            )
        }

        return ProactiveFeedbackResult.Applied(
            action = action,
            applied = outcome.applied,
            wakeupId = if (action == ProactiveFeedbackAction.SNOOZE) {
                proactiveWakeupStore.get(ProactiveWakeupStore.deterministicSnoozeId(signalId))?.id
            } else null,
            mutedUntilEpochMs = outcome.mutedUntilEpochMs,
        )
    }

    internal fun buildProactiveActPrompt(event: DialogueEvent): String {
        val checkPrompt = event.proactive?.checkPrompt?.trim()?.takeIf { it.isNotEmpty() }
        if (checkPrompt != null) return CredentialRedactor.redact(checkPrompt).take(2_000)
        val title = event.proactive?.title?.trim()?.takeIf { it.isNotEmpty() } ?: "主动提醒"
        return CredentialRedactor.redact("关于这条主动提醒「$title」，请帮我处理：\n\n" + event.text.take(600))
    }

    private fun resolveProactiveSourceLabel(delta: L1Outcome.PassedWithDelta): String = when {
        delta.bypassL2ForScheduledBriefing -> "晨报"
        delta.wakeupId != null -> "提醒"
        delta.topicKey.startsWith("watchtower:") -> "网页监控"
        delta.topicKey.startsWith("webhook:") -> "Webhook"
        delta.topicKey.startsWith("calendar:") || delta.topicKey.startsWith("prep:event:") -> "日程"
        delta.topicKey.startsWith("prep:overdue_reminders:") -> "待办"
        delta.category == TriggerCategory.MEMORY_COMMITMENT -> "承诺提醒"
        delta.category == TriggerCategory.TASK_LIFECYCLE -> "任务更新"
        delta.category == TriggerCategory.EDGE_NODE_EVENT -> "设备事件"
        else -> "主动提醒"
    }.take(24)

    internal suspend fun deliverProactiveCardToOwner(pushed: ProactiveRunResult.PushedAtL3): ProactiveRunResult.PushedAtL3 {
        val card = pushed.card.copy(
            title = CredentialRedactor.redact(pushed.card.title).trim().ifBlank { "Amber 主动提醒" }.take(100),
            markdownBody = CredentialRedactor.redact(pushed.card.markdownBody),
        )
        val delta = pushed.l1Delta
        val signalId = delta.signalId
        var firstReceipt: OutboundReceipt? = pushed.receipt

        // 1. Write proactive_message DialogueEvent (idempotent by id="proactive:{signalId}"; failures must not block delivery)
        val safeTopicKey = CredentialRedactor.redact(delta.topicKey).take(160)
        val safeCheckPrompt = delta.checkPrompt?.trim()?.takeIf { it.isNotEmpty() }
            ?.let { CredentialRedactor.redact(it).take(2_000) }
        val urgencyWire = when (pushed.restraintVerdict.urgency) {
            ProactiveUrgency.URGENT -> "urgent"
            ProactiveUrgency.DIGEST -> "digest"
            ProactiveUrgency.NORMAL -> "normal"
        }
        val eventId = "proactive:$signalId"
        val proactiveEvent = DialogueEvent(
            id = eventId,
            kind = DialogueEventKinds.PROACTIVE_MESSAGE,
            role = "assistant",
            text = card.markdownBody.take(4_000),
            topicId = eventId,
            workItemId = null,
            proactive = ProactiveEventMeta(
                signalId = signalId,
                topicKey = safeTopicKey,
                category = delta.category.name,
                title = card.title,
                urgency = urgencyWire,
                silent = pushed.restraintVerdict.silentDelivery,
                sourceLabel = resolveProactiveSourceLabel(delta),
                actions = if (delta.approvalToolCallId != null) emptyList() else listOf("act", "snooze", "mute"),
                checkPrompt = safeCheckPrompt,
                wakeupId = delta.wakeupId,
                originSignalId = delta.originSignalId,
            ),
        )
        try {
            if (!orchestrationStore.dialogue.append(proactiveEvent)) return pushed
        } catch (ce: CancellationException) {
            throw ce
        } catch (e: Exception) {
            runCatching {
                orchestrationStore.appendDiagnosticEvent(
                    sessionId = PRIMARY_CONVERSATION_ID.toString(),
                    workItemId = null,
                    kind = "proactive_event_write_failed",
                    detail = CredentialRedactor.redact("signalId=$signalId, error=${e.message ?: e::class.simpleName}"),
                    nowMs = System.currentTimeMillis(),
                )
            }
        }

        // 2. Record the proactive card in the primary timeline so context is continuous across restarts
        val deterministicMsgId = Uuid.parse(UUID.nameUUIDFromBytes(eventId.toByteArray()).toString())
        routerIngress.recordReply(
            PRIMARY_CONVERSATION_ID.toString(),
            "【主动提醒 · ${card.title}】\n${card.markdownBody}",
            messageId = deterministicMsgId,
            createPrimaryIfMissing = true,
        )

        // 3. Dispatch outbound card to all registered connectors where the owner has a bound private chat
        for ((kind, connector) in connectors) {
            val ownerChatId = ownerBinding.getOwnerDirectChatId(kind.wireName) ?: continue
            val outbound = OutboundMessage(
                channel = kind,
                chatId = ownerChatId,
                text = card.markdownBody,
                conversationId = PRIMARY_CONVERSATION_ID.toString(),
                silent = pushed.restraintVerdict.silentDelivery,
                card = card,
                idempotencyKey = "proactive:$signalId:${kind.wireName}",
            )
            val receipt = try {
                connector.sendWithReceipt(outbound)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                OutboundReceipt(false, kind.wireName, outbound.idempotencyKey.orEmpty(), note = "proactive_delivery_failed")
            }
            if (firstReceipt == null) {
                firstReceipt = receipt
            }
        }

        gatewayState.sendToPairedAppleDevices("proactive-push-failed") { device ->
            gatewayState.buildProactivePushPayload(
                device = device,
                card = card,
                signalId = signalId,
                silentDelivery = pushed.restraintVerdict.silentDelivery,
                urgency = pushed.restraintVerdict.urgency,
            )
        }

        return pushed.copy(card = card, receipt = firstReceipt)
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

        val profile = if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
            agentRegistry.get(agentRouting.select(message.text, convId.toString()).agentId)
        } else null
        val memoryAgentId = profile?.id?.takeUnless { it == MAIN_AGENT_ID } ?: GLOBAL_MEMORY_AGENT_ID

        val ruleConversationId = orchestrationStore.dialogue.ruleConversationId(message.channel.wireName, message.messageId, convId.toString())
        // Auto-extract explicit memory directive & proposed procedural rules in direct owner chat
        if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
            ownerBinding.bindOwnerDirectly(message.channel.wireName, message.senderId, message.chatId)
            if (existing.memoryMode == ConversationMemoryMode.ENABLED) {
                extractExplicitMemoryIfPresent(message.text, convId.toString(), memoryAgentId)
                // Always creates a `proposed` rule card only; never auto-activates on a single correction.
                runCatching {
                    proceduralRuleStore.proposeFromCorrection(
                        userText = message.text,
                        scope = "conversation:$ruleConversationId",
                        sourceEventId = message.messageId,
                    )
                }
            }
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

        val recalledMemories = if (existing.memoryMode != ConversationMemoryMode.ENABLED) emptyList() else if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
            memoryStore.recallForPrompt(message.text, agentId = memoryAgentId, memoryPolicy = profile?.memoryPolicy ?: AgentMemoryPolicy.SHARED_WITH_GLOBAL)
        } else {
            // In group chats, shield CORE personal memories from non-owner prompts
            memoryStore.recallForPrompt(message.text).filter { it.scope != MemoryScope.CORE }
        }

        val activeRules = if ((profile?.memoryPolicy ?: AgentMemoryPolicy.SHARED_WITH_GLOBAL) == AgentMemoryPolicy.HUB_ISOLATED) {
            emptyList()
        } else {
            proceduralRuleStore.selectActiveForInjection(
                conversationId = ruleConversationId,
                recordHit = true,
            )
        }

        // Defect #7: Prepare request messages with pinned SYSTEM message and dynamic memory on tail
        val preparedMessages = contextManager.prepareRequestMessages(
            systemPrompt = soulStore.renderDirectSystemPrompt(
                memoryPolicy = profile?.memoryPolicy ?: AgentMemoryPolicy.SHARED_WITH_GLOBAL,
                extraInstructions = profile?.instructions.orEmpty(),
                activeRules = activeRules,
            ),
            memories = recalledMemories,
            conversationId = convId.toString(),
            historyMessages = currentMessages,
            tokenBudget = contextWindowTokens,
        )

        val executionScope = if (message.senderRole == SenderRole.OWNER && (profile == null || profile.id == MAIN_AGENT_ID)) {
            ExecutionScope.MAIN_AGENT
        } else {
            ExecutionScope.SUBAGENT
        }
        val turnPrincipal: CloudPrincipal = if (message.senderRole == SenderRole.OWNER) {
            CloudPrincipal.OwnerUser(message.senderId, message.channel.wireName)
        } else {
            CloudPrincipal.ExternalCaller(message.channel.wireName, message.senderId)
        }
        val availableTools = toolRegistry.declaredTools(executionScope, turnPrincipal).filter { profile == null || it.name in agentRegistry.effectiveTools(profile) }
        val assistantReply = modelClient.generateReply(preparedMessages, availableTools)

        val toolCalls = assistantReply.getTools()
        if (toolCalls.isEmpty()) {
            val safeAssistant = sanitizeAssistantMessage(assistantReply)
            val completed = conversationStorage.saveConversation(
                afterUserSave.copy(
                    messageNodes = afterUserSave.messageNodes + safeAssistant.toMessageNode(),
                    updateAt = Clock.System.now(),
                )
            )
            conversationTagger.enqueue(completed, memoryAgentId)
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
        require(availableTools.any { it.name == toolCall.toolName }) { "Agent 未获授该工具" }
        val highRisk = toolRegistry.isHighRisk(toolCall.toolName)
        val parsedArgs = runCatching {
            json.parseToJsonElement(toolCall.input.ifBlank { "{}" }).jsonObject
        }.getOrDefault(JsonObject(emptyMap()))

        val requiresApproval = highRisk || (!autoApproveOrdinaryTools && isWriteTool(toolCall.toolName))
        if (requiresApproval) {
            // Defect #2 & #4: Stash raw args in encrypted ephemeral memory, persist only redacted args!
            val redactedArgsJson = approvalHelper.stashPendingToolArgs(toolCall.toolCallId, parsedArgs)
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
            val approvalPreview = toolRegistry.approvalPreview(toolCall.toolName, parsedArgs, targetDevice = "cloud-daemon", cloudExecution = true)
            approvalHelper.upsertPendingApprovalSession(
                sessionKey = sessionKey,
                agent = "amber",
                subject = afterUserSave.title.ifBlank { "主时间线" },
                summary = redactedUserText.take(80),
                origin = "interactive",
                conversationId = convId.toString(),
                toolCallId = toolCall.toolCallId,
                toolName = toolCall.toolName,
                redactedArgsJson = redactedArgsJson,
                highRisk = highRisk,
                nowSec = nowSec,
                riskLevel = approvalPreview.riskLevel,
                targetDevice = approvalPreview.targetDevice,
                targetSummary = approvalPreview.targetSummary,
                diffPreview = approvalPreview.diffPreview,
                requiresLocalApproval = approvalPreview.requiresLocalApproval,
            )
            val card = ChannelApprovalCard(
                sessionKey = sessionKey,
                toolCallId = toolCall.toolCallId,
                toolName = toolCall.toolName,
                redactedDetail = redactedArgsJson,
                highRisk = highRisk,
                allowApproveInChannel = false,
                riskLevel = approvalPreview.riskLevel,
                targetDevice = approvalPreview.targetDevice,
                targetSummary = approvalPreview.targetSummary,
                diffPreview = approvalPreview.diffPreview,
                requiresLocalApproval = approvalPreview.requiresLocalApproval,
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
            toolRegistry.executeGate(toolCall.toolName, parsedArgs, executionScope, principal = turnPrincipal)
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
            pendingRunsBySessionKey.values.firstOrNull { it.toolCallId == toolCallId }?.sessionKey
                ?: orchestrationStore.findPendingApprovalByToolCall(toolCallId)?.let {
                    orchestrationKernel.v2ApprovalSessionKey(it.workItemId, it.id)
                }.orEmpty()
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
        approvalHelper.wipePendingToolArgs(pending.toolCallId)
        approvalHelper.updateStoredToolOutcome(
            conversationId = pending.conversationId,
            toolCallId = pending.toolCallId,
            approvalState = ToolApprovalState.Denied(reason),
            outputJson = buildJsonObject {
                put("ok", false)
                put("status", targetStatus.wireName)
                put("reason", reason)
            }.toString(),
        )
        approvalHelper.clearApprovalSession(
            sessionKey = sessionKey,
            nextState = "stopped",
            abnormal = targetStatus != AgentRunStatus.COMPLETED,
        )
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
            approvalHelper.wipePendingToolArgs(pending.toolCallId)
            return false
        }
        return try {
            if (allow) {
                val rawArgs = approvalHelper.consumePendingToolArgs(toolCallId) ?: JsonObject(emptyMap())
                val outputElement = toolRegistry.executeGate(
                    toolName = pending.toolName,
                    args = rawArgs,
                    scope = ExecutionScope.MAIN_AGENT,
                )
                val redactedOutput = CredentialRedactor.redact(outputElement.toString())
                approvalHelper.updateStoredToolOutcome(
                    conversationId = pending.conversationId,
                    toolCallId = toolCallId,
                    approvalState = ToolApprovalState.Approved,
                    outputJson = redactedOutput,
                )
                approvalHelper.clearApprovalSession(sessionKey = sessionKey, nextState = "completed")
            } else {
                approvalHelper.wipePendingToolArgs(toolCallId)
                approvalHelper.updateStoredToolOutcome(
                    conversationId = pending.conversationId,
                    toolCallId = toolCallId,
                    approvalState = ToolApprovalState.Denied("denied_by_user"),
                    outputJson = buildJsonObject {
                        put("ok", false)
                        put("status", "denied")
                    }.toString(),
                )
                approvalHelper.clearApprovalSession(sessionKey = sessionKey, nextState = "completed")
            }
            true
        } finally {
            // Guarantee credential wipe on both approve and deny paths (Defect #2)
            approvalHelper.wipePendingToolArgs(toolCallId)
        }
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

    internal fun extractExplicitMemoryIfPresent(text: String, conversationId: String, agentId: String = GLOBAL_MEMORY_AGENT_ID) {
        val trimmed = text.trim().replace(Regex("^@[^\\s，,:：]+[\\s，,:：]+"), "")
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
                    agentId = agentId,
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
            deviceContextStore = gatewayState.deviceContextStore,
            pairedIosDevicesProvider = { gatewayState.loadDevicesStrict() },
            proactiveMonitorStore = proactiveMonitorStore,
            proactiveWebhookStore = proactiveWebhookStore,
            proactiveWakeupStore = proactiveWakeupStore,
            proactiveZoneIdProvider = { proactiveEngine.restraintGate.budgetConfig.zoneId },
        )
    }
}
