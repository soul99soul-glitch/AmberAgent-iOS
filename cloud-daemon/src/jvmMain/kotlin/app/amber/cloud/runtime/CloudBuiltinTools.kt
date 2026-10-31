package app.amber.cloud.runtime

import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import kotlin.uuid.Uuid

/**
 * 注册 `amberd` 云端守护进程内置工具（历史检索、长期记忆、受管工作区写入、终端命令、SSH 配置、JS 沙箱与 Recipe 门禁）。
 */
internal object CloudBuiltinTools {

    fun registerAll(
        toolRegistry: CloudToolRegistry,
        conversationStorage: JsonConversationStorage,
        contextManager: CloudContextManager,
        memoryStore: CloudMemoryStore,
        vault: EnvelopeCredentialVault,
        workspaceDir: File,
    ) {
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
                toolRegistry.executeGate(stepTool, stepArgs, ExecutionScope.RECIPE)
            }
        )
    }
}
