package app.amber.cloud.runtime

import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

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
    )

    val L2_REVERSIBLE_WRITE_TOOLS = setOf(
        "workspace_file_write",
        "workspace_file_edit",
        "memory_write",
        "agent_soul_update",
        "process_run",
        "process_stop",
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
        if (toolName in L3_IRREVERSIBLE_OR_EXTERNAL_TOOLS) return ToolRiskLevel.L3
        if (toolName.startsWith("plugin__")) {
            return if (definition != null && !definition.highRisk && (definition.effect == ToolEffect.PURE || definition.effect == ToolEffect.NETWORK_READ)) {
                ToolRiskLevel.L1
            } else {
                ToolRiskLevel.L3
            }
        }
        if (definition != null) {
            if (definition.highRisk) return ToolRiskLevel.L3
            if (toolName in L1_READ_ONLY_TOOLS || definition.effect == ToolEffect.PURE || definition.effect == ToolEffect.NETWORK_READ) {
                return ToolRiskLevel.L1
            }
            if (toolName in L2_REVERSIBLE_WRITE_TOOLS || definition.effect == ToolEffect.TASK_LOCAL || definition.effect == ToolEffect.SIDE_EFFECT) {
                return ToolRiskLevel.L2
            }
        }
        if (toolName in L1_READ_ONLY_TOOLS) return ToolRiskLevel.L1
        if (toolName in L2_REVERSIBLE_WRITE_TOOLS) return ToolRiskLevel.L2
        // Unknown tools fail closed to L3.
        return ToolRiskLevel.L3
    }

    fun buildPreview(
        toolName: String,
        definition: CloudToolDefinition? = null,
        args: JsonObject = JsonObject(emptyMap()),
        targetDevice: String? = null,
    ): ToolApprovalPreview {
        val level = classify(toolName, definition, args)
        val resolvedDevice = targetDevice?.trim()?.takeIf { it.isNotEmpty() } ?: "cloud-daemon"
        val requiresLocal = level == ToolRiskLevel.L3 || definition?.highRisk == true || toolName in CloudToolRegistry.BUILTIN_HIGH_RISK_NAMES
        return ToolApprovalPreview(
            riskLevel = level.wireName,
            targetDevice = resolvedDevice,
            targetSummary = buildTargetSummary(toolName, args),
            diffPreview = buildDiffPreview(toolName, args),
            requiresLocalApproval = requiresLocal,
        )
    }

    fun reversibleWriteNotification(toolName: String, args: JsonObject): String {
        val path = args["path"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
        return when (toolName) {
            "workspace_file_write" -> "已写入可逆文件 ${CredentialRedactor.redact(path.ifBlank { "(未命名)" })}（L2：可通过覆盖写回或恢复上一版撤回）"
            "workspace_file_edit" -> "已编辑可逆文件 ${CredentialRedactor.redact(path.ifBlank { "(未命名)" })}（L2：可反向替换撤回）"
            "memory_write" -> "已更新长期记忆（L2：可修改或删除该条记忆撤回）"
            "agent_soul_update" -> "已更新形象人设（L2：保留历史快照可一键回退）"
            else -> "已执行可逆写入 `$toolName`（L2）"
        }
    }

    private fun sanitizeAndTruncate(raw: String?, limit: Int): String? {
        if (raw.isNullOrBlank()) return null
        val safe = CredentialRedactor.redact(raw).trim()
        if (safe.isEmpty()) return null
        return if (safe.length > limit) safe.take(limit - 1) + "…" else safe
    }

    private fun buildTargetSummary(toolName: String, args: JsonObject): String? {
        val path = args["path"]?.jsonPrimitive?.contentOrNull?.trim()
        val command = args["command"]?.jsonPrimitive?.contentOrNull?.trim()
        val host = args["host"]?.jsonPrimitive?.contentOrNull?.trim()
        val raw = when {
            !path.isNullOrEmpty() -> "$toolName: $path"
            !command.isNullOrEmpty() -> "$toolName: ${command.replace(Regex("\\s+"), " ")}"
            !host.isNullOrEmpty() -> "$toolName: $host"
            else -> toolName
        }
        return sanitizeAndTruncate(raw, TARGET_SUMMARY_LIMIT)
    }

    private fun buildDiffPreview(toolName: String, args: JsonObject): String? {
        val oldText = args["old"]?.jsonPrimitive?.contentOrNull
        val replacement = args["replacement"]?.jsonPrimitive?.contentOrNull
        val content = args["content"]?.jsonPrimitive?.contentOrNull
        val command = args["command"]?.jsonPrimitive?.contentOrNull
        val path = args["path"]?.jsonPrimitive?.contentOrNull
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
