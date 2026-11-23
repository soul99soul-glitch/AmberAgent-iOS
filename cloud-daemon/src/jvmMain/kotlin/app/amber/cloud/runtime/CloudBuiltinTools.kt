package app.amber.cloud.runtime

import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.gateway.DeviceContextSnapshotStore
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.proactive.ProactiveMonitorRecord
import app.amber.cloud.proactive.ProactiveMonitorStore
import app.amber.cloud.proactive.ProactiveWebhookRecord
import app.amber.cloud.proactive.ProactiveWebhookStore
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import kotlin.uuid.Uuid

/**
 * 注册 `amberd` 云端守护进程内置工具（历史检索、长期记忆、受管工作区写入、终端命令、SSH 配置、JS 沙箱与 Recipe 门禁）。
 */
internal object CloudBuiltinTools {

    private val toolJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun registerAll(
        toolRegistry: CloudToolRegistry,
        conversationStorage: JsonConversationStorage,
        contextManager: CloudContextManager,
        memoryStore: CloudMemoryStore,
        vault: EnvelopeCredentialVault,
        workspaceDir: File,
        deviceContextStore: DeviceContextSnapshotStore? = null,
        pairedIosDevicesProvider: () -> List<PairedDevice> = { emptyList() },
        proactiveMonitorStore: ProactiveMonitorStore? = null,
        proactiveWebhookStore: ProactiveWebhookStore? = null,
    ) {
        toolRegistry.register(
            CloudToolDefinition(
                name = "history_search",
                description = "检索历史会话记录（自动脱敏并附带 stale 标记）",
                highRisk = false,
                effect = ToolEffect.PURE,
                requiredCapability = "history_tools",
                parameters = app.amber.cloud.tasks.schema("{\"query\":{\"type\":\"string\"},\"message_id\":{\"type\":\"string\"},\"conversation_id\":{\"type\":\"string\"}}"),
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
                parameters = app.amber.cloud.tasks.schema("{\"query\":{\"type\":\"string\"},\"message_id\":{\"type\":\"string\"},\"conversation_id\":{\"type\":\"string\"}}"),
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
                    put("ok", false)
                    put("error", "宿主终端执行未接入；任务脚本请用 process_run（需要任务身份与OS隔离）")
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
                    put("ok", false)
                    put("error", "JS运行时未接入，请使用已隔离的 process_run")
                }
            }
        )

        toolRegistry.register(
            CloudToolDefinition(
                name = "recipe_run",
                description = "调用一个已注册工具，继承真实调用者权限和任务作用域；参数为tool/args，不支持命名配方或steps",
                parameters = app.amber.cloud.tasks.schema("{\"tool\":{\"type\":\"string\"},\"args\":{\"type\":\"object\"}}", "tool", "args"),
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                val stepTool = args["tool"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val stepArgs = args["args"]?.jsonObject ?: JsonObject(emptyMap())
                toolRegistry.executeGate(stepTool, stepArgs, ExecutionScope.RECIPE)
            }
        )

        if (deviceContextStore != null) {
            toolRegistry.register(
                CloudToolDefinition(
                    name = "device_context_read",
                    description = "只读读取主人已配对 iOS 设备主动共享的近期上下文摘要（日历/提醒/Artifact），返回不可信数据包裹结果",
                    parameters = app.amber.cloud.tasks.schema("{\"domain\":{\"type\":\"string\",\"enum\":[\"all\",\"calendar\",\"reminders\",\"artifacts\"]},\"deviceId\":{\"type\":\"string\"}}"),
                    highRisk = false,
                    effect = ToolEffect.PURE,
                    ownerOnly = true,
                ) { args ->
                    val domain = args["domain"]?.jsonPrimitive?.contentOrNull ?: "all"
                    val deviceId = args["deviceId"]?.jsonPrimitive?.contentOrNull
                    deviceContextStore.readForOwnerDevices(
                        pairedIosDevices = pairedIosDevicesProvider(),
                        domainFilter = domain,
                        requestedDeviceId = deviceId,
                    )
                }
            )
        }

        if (proactiveMonitorStore != null) {
            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_monitor_create",
                    description = "创建一条 Watchtower 静默网页巡检规则（仅允许公开 http/https URL，有变化才提醒）",
                    parameters = app.amber.cloud.tasks.schema(
                        "{\"title\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"},\"conditionPrompt\":{\"type\":\"string\"},\"intervalMinutes\":{\"type\":\"integer\"},\"enabled\":{\"type\":\"boolean\"}}",
                        "url",
                    ),
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                    ownerOnly = true,
                ) { args ->
                    val url = args["url"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val title = args["title"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val condition = args["conditionPrompt"]?.jsonPrimitive?.contentOrNull
                        ?: args["condition_prompt"]?.jsonPrimitive?.contentOrNull
                        ?: ""
                    val interval = args["intervalMinutes"]?.jsonPrimitive?.intOrNull
                        ?: args["interval_minutes"]?.jsonPrimitive?.intOrNull
                        ?: 15
                    val enabled = args["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
                    runCatching {
                        val created = proactiveMonitorStore.create(
                            title = title,
                            url = url,
                            conditionPrompt = condition,
                            intervalMinutes = interval,
                            enabled = enabled,
                        )
                        buildJsonObject {
                            put("ok", true)
                            put("monitor", toolJson.encodeToJsonElement(ProactiveMonitorRecord.serializer(), created))
                        }
                    }.getOrElse { err ->
                        buildJsonObject {
                            put("ok", false)
                            put("error", err.message ?: "创建巡检规则失败")
                        }
                    }
                }
            )

            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_monitor_list",
                    description = "列出当前所有 Watchtower 静默巡检规则及最近检查状态",
                    parameters = app.amber.cloud.tasks.schema("{\"includeDisabled\":{\"type\":\"boolean\"}}"),
                    highRisk = false,
                    effect = ToolEffect.PURE,
                    ownerOnly = true,
                ) { args ->
                    val includeDisabled = args["includeDisabled"]?.jsonPrimitive?.booleanOrNull ?: true
                    val list = proactiveMonitorStore.list(includeDisabled = includeDisabled)
                    buildJsonObject {
                        put("ok", true)
                        put(
                            "monitors",
                            buildJsonArray {
                                list.forEach { add(toolJson.encodeToJsonElement(ProactiveMonitorRecord.serializer(), it)) }
                            }
                        )
                    }
                }
            )

            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_monitor_update",
                    description = "更新指定 Watchtower 巡检规则（启停、调整轮询频率、修改关注条件或标题/URL）",
                    parameters = app.amber.cloud.tasks.schema(
                        "{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"},\"conditionPrompt\":{\"type\":\"string\"},\"intervalMinutes\":{\"type\":\"integer\"},\"enabled\":{\"type\":\"boolean\"}}",
                        "id",
                    ),
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                    ownerOnly = true,
                ) { args ->
                    val id = args["id"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    runCatching {
                        val updated = proactiveMonitorStore.update(
                            id = id,
                            title = args["title"]?.jsonPrimitive?.contentOrNull,
                            url = args["url"]?.jsonPrimitive?.contentOrNull,
                            conditionPrompt = args["conditionPrompt"]?.jsonPrimitive?.contentOrNull
                                ?: args["condition_prompt"]?.jsonPrimitive?.contentOrNull,
                            intervalMinutes = args["intervalMinutes"]?.jsonPrimitive?.intOrNull
                                ?: args["interval_minutes"]?.jsonPrimitive?.intOrNull,
                            enabled = args["enabled"]?.jsonPrimitive?.booleanOrNull,
                        )
                        if (updated == null) {
                            buildJsonObject {
                                put("ok", false)
                                put("error", "未找到巡检规则: $id")
                            }
                        } else {
                            buildJsonObject {
                                put("ok", true)
                                put("monitor", toolJson.encodeToJsonElement(ProactiveMonitorRecord.serializer(), updated))
                            }
                        }
                    }.getOrElse { err ->
                        buildJsonObject {
                            put("ok", false)
                            put("error", err.message ?: "更新巡检规则失败")
                        }
                    }
                }
            )

            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_monitor_delete",
                    description = "删除指定 Watchtower 静默巡检规则",
                    parameters = app.amber.cloud.tasks.schema("{\"id\":{\"type\":\"string\"}}", "id"),
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                    ownerOnly = true,
                ) { args ->
                    val id = args["id"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val deleted = proactiveMonitorStore.delete(id)
                    buildJsonObject {
                        put("ok", deleted)
                        put("id", id)
                        if (!deleted) put("error", "未找到巡检规则: $id")
                    }
                }
            )
        }

        if (proactiveWebhookStore != null) {
            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_webhook_create",
                    description = "创建一个个人签名入站 Webhook（密钥密文入库，仅此次创建返回一次 secret 与入站路径）",
                    parameters = app.amber.cloud.tasks.schema(
                        "{\"name\":{\"type\":\"string\"},\"instruction\":{\"type\":\"string\"},\"enabled\":{\"type\":\"boolean\"}}",
                        "name",
                    ),
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                    ownerOnly = true,
                ) { args ->
                    val name = args["name"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val instruction = args["instruction"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val enabled = args["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
                    runCatching {
                        val created = proactiveWebhookStore.create(
                            name = name,
                            instruction = instruction,
                            enabled = enabled,
                        )
                        buildJsonObject {
                            put("ok", true)
                            put("webhook", toolJson.encodeToJsonElement(ProactiveWebhookRecord.serializer(), created.webhook))
                            put("secret", created.secret)
                            put("inboundPath", created.inboundPath)
                        }
                    }.getOrElse { err ->
                        buildJsonObject {
                            put("ok", false)
                            put("error", err.message ?: "创建 Webhook 失败")
                        }
                    }
                }
            )

            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_webhook_list",
                    description = "列出已配置的个人入站 Webhook（永不回显明文 secret）",
                    parameters = app.amber.cloud.tasks.schema("{}"),
                    highRisk = false,
                    effect = ToolEffect.PURE,
                    ownerOnly = true,
                ) {
                    val list = proactiveWebhookStore.list()
                    buildJsonObject {
                        put("ok", true)
                        put(
                            "webhooks",
                            buildJsonArray {
                                list.forEach { add(toolJson.encodeToJsonElement(ProactiveWebhookRecord.serializer(), it)) }
                            }
                        )
                    }
                }
            )

            toolRegistry.register(
                CloudToolDefinition(
                    name = "proactive_webhook_delete",
                    description = "删除指定个人入站 Webhook 并同步吊销其密文密钥",
                    parameters = app.amber.cloud.tasks.schema("{\"id\":{\"type\":\"string\"}}", "id"),
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                    ownerOnly = true,
                ) { args ->
                    val id = args["id"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                    val deleted = proactiveWebhookStore.delete(id)
                    buildJsonObject {
                        put("ok", deleted)
                        put("id", id)
                        if (!deleted) put("error", "未找到 Webhook: $id")
                    }
                }
            )
        }
    }
}
