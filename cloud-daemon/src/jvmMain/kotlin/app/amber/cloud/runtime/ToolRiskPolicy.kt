package app.amber.cloud.runtime

import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull

/**
 * Static L1/L2/L3 risk tier (deliberately static, never auto-learned):
 * - L1: read-only probes, auto-allowed
 * - L2: reversible writes, executed with post-write notification & undo/artifact summary
 * - L3: irreversible or external side-effect writes, requires explicit confirmation
 */
@Serializable
enum class ToolRiskLevel(val wireName: String) {
    L1("L1"),
    L2("L2"),
    L3("L3"),
}

@Serializable
data class ToolApprovalPreview(
    val riskLevel: String,
    val targetDevice: String,
    val targetSummary: String? = null,
    val diffPreview: String? = null,
    val requiresLocalApproval: Boolean,
)

object ToolRiskPolicy {
    const val DIFF_PREVIEW_LIMIT = 400
    const val TARGET_SUMMARY_LIMIT = 140

    val L1_READ_ONLY_TOOLS = setOf(
        "history_search",
        "history_fetch",
        "workspace_file_list",
        "workspace_file_read",
        "workspace_file_search",
        "host_info",
        "runtime_info",
        "device_context_read",
        "process_wait",
        "task_finish",
        "web_search",
        "http_get",
        "agent_soul_get",
        "plugin_list",
        "tools_list",
        "tool_search",
        "schedule_list",
        "proactive_monitor_list",
        "proactive_webhook_list",
    )

    val L2_REVERSIBLE_WRITE_TOOLS = setOf(
        "workspace_file_write",
        "workspace_file_edit",
        "memory_write",
        "agent_soul_update",
        "process_run",
        "process_stop",
        "proactive_monitor_create",
        "proactive_monitor_update",
        "proactive_monitor_delete",
        "proactive_webhook_create",
        "proactive_webhook_delete",
    )

    val L3_IRREVERSIBLE_OR_EXTERNAL_TOOLS = CloudToolRegistry.BUILTIN_HIGH_RISK_NAMES + setOf(
        "plugin_install",
        "schedule_create",
        "schedule_update",
    )

    fun classify(
        toolName: String,
        definition: CloudToolDefinition? = null,
        args: JsonObject = JsonObject(emptyMap()),
    ): ToolRiskLevel {
        if (definition?.highRisk == true || toolName in L3_IRREVERSIBLE_OR_EXTERNAL_TOOLS) return ToolRiskLevel.L3
        val declaredRead = definition?.effect == ToolEffect.PURE || definition?.effect == ToolEffect.NETWORK_READ
        if (toolName.startsWith("plugin__")) return if (declaredRead) ToolRiskLevel.L1 else ToolRiskLevel.L3
        if (toolName in L1_READ_ONLY_TOOLS || declaredRead) return ToolRiskLevel.L1
        if (toolName in L2_REVERSIBLE_WRITE_TOOLS || definition?.effect == ToolEffect.TASK_LOCAL) return ToolRiskLevel.L2
        // Unknown tools fail closed to L3.
        return ToolRiskLevel.L3
    }

    fun buildPreview(
        toolName: String,
        definition: CloudToolDefinition? = null,
        args: JsonObject = JsonObject(emptyMap()),
        targetDevice: String? = null,
        cloudExecution: Boolean = false,
    ): ToolApprovalPreview {
        val level = classify(toolName, definition, args)
        val resolvedDevice = targetDevice?.trim()?.takeIf { it.isNotEmpty() } ?: "cloud-daemon"
        val requiresLocal = level == ToolRiskLevel.L3 && (!cloudExecution || definition == null)
        return ToolApprovalPreview(
            riskLevel = level.wireName,
            targetDevice = resolvedDevice,
            targetSummary = buildTargetSummary(toolName, args),
            diffPreview = buildDiffPreview(toolName, args),
            requiresLocalApproval = requiresLocal,
        )
    }

    fun reversibleWriteNotification(toolName: String, args: JsonObject): String {
        val path = args.text("path")?.trim().orEmpty()
        return when (toolName) {
            "workspace_file_write" -> "已写入可逆文件 ${CredentialRedactor.redact(path.ifBlank { "(未命名)" })}（L2：可通过覆盖写回或恢复上一版撤回）"
            "workspace_file_edit" -> "已编辑可逆文件 ${CredentialRedactor.redact(path.ifBlank { "(未命名)" })}（L2：可反向替换撤回）"
            "memory_write" -> "已更新长期记忆（L2：可修改或删除该条记忆撤回）"
            "agent_soul_update" -> "已更新形象人设（L2：保留历史快照可一键回退）"
            "proactive_monitor_create", "proactive_monitor_update", "proactive_monitor_delete" -> "已更新 Watchtower 静默巡检规则（L2：可随时启停或删除）"
            "proactive_webhook_create", "proactive_webhook_delete" -> "已更新个人签名入站 Webhook 配置（L2：可随时启停或吊销）"
            else -> "已执行可逆写入 `$toolName`（L2）"
        }
    }

    private fun sanitizeAndTruncate(raw: String?, limit: Int): String? {
        if (raw.isNullOrBlank()) return null
        val safe = CredentialRedactor.redact(raw).trim()
        if (safe.isEmpty()) return null
        return if (safe.length > limit) safe.take(limit - 1) + "…" else safe
    }

    private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun buildTargetSummary(toolName: String, args: JsonObject): String? {
        val path = args.text("path")?.trim()
        val command = args.text("command")?.trim()
        val host = args.text("host")?.trim()
        val raw = when {
            !path.isNullOrEmpty() -> "$toolName: $path"
            !command.isNullOrEmpty() -> "$toolName: ${command.replace(Regex("\\s+"), " ")}"
            !host.isNullOrEmpty() -> "$toolName: $host"
            else -> toolName
        }
        return sanitizeAndTruncate(raw, TARGET_SUMMARY_LIMIT)
    }

    private fun buildDiffPreview(toolName: String, args: JsonObject): String? {
        val oldText = args.text("old")
        val replacement = args.text("replacement")
        val content = args.text("content")
        val command = args.text("command")
        val path = args.text("path")
        val raw = when {
            oldText != null && replacement != null -> "- $oldText\n+ $replacement"
            !content.isNullOrEmpty() -> buildString {
                if (!path.isNullOrBlank()) append("+++ ").append(path).append('\n')
                append(content)
            }
            !command.isNullOrEmpty() -> "$ $command"
            !path.isNullOrEmpty() -> "$toolName $path"
            args.isNotEmpty() -> args.toString()
            else -> null
        }
        return sanitizeAndTruncate(raw, DIFF_PREVIEW_LIMIT)
    }
}
