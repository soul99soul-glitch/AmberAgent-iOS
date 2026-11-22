package app.amber.cloud.runtime

import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.OrchestrationHash
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.cloud.tasks.TaskCallContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

@Serializable
enum class ExecutionScope {
    MAIN_AGENT,
    SUBAGENT,
    MODEL_COUNCIL,
    JS_SANDBOX,
    RECIPE,
}

@Serializable
enum class ToolEffect {
    PURE,
    NETWORK_READ,
    TASK_LOCAL,
    SIDE_EFFECT,
}

data class CloudToolDefinition(
    val name: String,
    val description: String,
    val highRisk: Boolean,
    val effect: ToolEffect,
    val requiredCapability: String? = null,
    val parameters: InputSchema? = null,
    val taskHandler: (suspend (JsonObject, TaskCallContext) -> JsonElement)? = null,
    val ownerOnly: Boolean = false,
    val handler: suspend (JsonObject) -> JsonElement = { error("工具需要任务调用上下文") },
)

/**
 * Runtime capability switches.
 *
 * Enforces Defect #8: default-disabled capabilities (e.g. `js_sandbox`) are checked at the
 * innermost execution gate so recipes, scheduled runs, or nested tool calls cannot bypass them.
 */
class CapabilityConfig(
    initialEnabled: Map<String, Boolean> = emptyMap(),
) {
    private val switches = ConcurrentHashMap<String, Boolean>().apply {
        put("history_tools", true)
        put("network_tools", true)
        put("memory_tools", true)
        put("workspace_files", true)
        put("terminal", true)
        put("ssh_remote", true)
        // Default-disabled capability (Defect #8)
        put("js_sandbox", false)
        putAll(initialEnabled)
    }

    fun isEnabled(capability: String?): Boolean {
        if (capability.isNullOrBlank()) return true
        return switches[capability] == true
    }

    fun setEnabled(capability: String, enabled: Boolean) {
        switches[capability] = enabled
    }

    fun snapshot(): Map<String, Boolean> = switches.toMap()
}

/**
 * Tool Registry and Execution Gate for `amberd`.
 *
 * Enforces:
 * - Defect #4: Rejects placeholder credentials (`<redacted>`, `***`, `••••`, `«已脱敏»`) in tool inputs.
 * - Defect #5: Subagents receive only authorized task-local writes; high-risk and host side effects remain excluded.
 * - Defect #8: Default-disabled capabilities cannot be bypassed via `recipe_run` or nested invocation.
 * - Defect #9: Declared tools strictly match registered, capability-enabled executors.
 */
class CloudToolRegistry(
    val capabilities: CapabilityConfig = CapabilityConfig(),
) {
    private val tools = LinkedHashMap<String, CloudToolDefinition>()

    @Synchronized
    fun register(tool: CloudToolDefinition) {
        tools[tool.name] = tool
    }

    @Synchronized
    fun get(name: String): CloudToolDefinition? = tools[name]

    @Synchronized
    fun registeredToolNames(): Set<String> = tools.keys.toSet()

    @Synchronized
    fun isHighRisk(toolName: String): Boolean = riskLevel(toolName) == ToolRiskLevel.L3

    @Synchronized
    fun riskLevel(toolName: String, args: JsonObject = JsonObject(emptyMap())): ToolRiskLevel =
        ToolRiskPolicy.classify(toolName, tools[toolName], args)

    @Synchronized
    fun approvalPreview(
        toolName: String,
        args: JsonObject = JsonObject(emptyMap()),
        targetDevice: String? = null,
        cloudExecution: Boolean = false,
    ): ToolApprovalPreview = ToolRiskPolicy.buildPreview(toolName, tools[toolName], args, targetDevice, cloudExecution)

    @Synchronized
    fun isWorkerApprovalTool(toolName: String): Boolean {
        val def = tools[toolName] ?: return false
        if (def.ownerOnly || def.name in EXCLUDED_WORKER_APPROVAL_TOOLS) return false
        return def.highRisk || def.effect == ToolEffect.SIDE_EFFECT
    }

    /**
     * Returns the tools visible to the given [scope].
     *
     * - Defect #5: `SUBAGENT`, `MODEL_COUNCIL`, and `JS_SANDBOX` are physically stripped of all
     *   high-risk and side-effect write tools unless [includeWorkerApprovalTools] is explicitly enabled
     *   for managed Worker approval gating (never including `terminal_exec` or `ownerOnly`).
     * - Defect #9: Only tools that are actually wired in [tools] AND whose [CloudToolDefinition.requiredCapability]
     *   is enabled in [capabilities] are advertised.
     */
    @Synchronized
    fun declaredTools(
        scope: ExecutionScope = ExecutionScope.MAIN_AGENT,
        principal: CloudPrincipal? = null,
        includeWorkerApprovalTools: Boolean = false,
    ): List<Tool> {
        return availableDefinitions(scope, principal, includeWorkerApprovalTools).map { def ->
            val gatedForWorker = scope == ExecutionScope.SUBAGENT && (def.highRisk || def.effect == ToolEffect.SIDE_EFFECT)
            val requiresApproval = def.highRisk || gatedForWorker
            Tool(
                name = def.name,
                description = def.description,
                parameters = { def.parameters },
                needsApproval = requiresApproval,
                allowsAutoApproval = !requiresApproval,
                mandatoryApproval = requiresApproval,
                execute = { args ->
                    val obj = runCatching { args.jsonObject }.getOrDefault(JsonObject(emptyMap()))
                    listOf(UIMessagePart.Text(executeGate(def.name, obj, scope, principal = principal).toString()))
                },
            )
        }
    }

    @Synchronized
    fun availableDefinitions(
        scope: ExecutionScope = ExecutionScope.MAIN_AGENT,
        principal: CloudPrincipal? = null,
        includeWorkerApprovalTools: Boolean = false,
    ): List<CloudToolDefinition> {
        return tools.values.filter { def ->
            if (!capabilities.isEnabled(def.requiredCapability)) return@filter false
            if (def.ownerOnly && !isOwnerAuthorized(scope, principal)) return@filter false
            when (scope) {
                ExecutionScope.SUBAGENT -> {
                    (!def.highRisk && def.effect != ToolEffect.SIDE_EFFECT) ||
                        (includeWorkerApprovalTools && def.name !in EXCLUDED_WORKER_APPROVAL_TOOLS)
                }
                ExecutionScope.MODEL_COUNCIL,
                ExecutionScope.JS_SANDBOX,
                -> !def.highRisk && def.effect != ToolEffect.SIDE_EFFECT
                ExecutionScope.MAIN_AGENT,
                ExecutionScope.RECIPE,
                -> true
            }
        }.sortedBy { it.name }
    }

    private fun isOwnerAuthorized(scope: ExecutionScope, principal: CloudPrincipal?, recipeDepth: Int = 0): Boolean {
        return recipeDepth == 0 && scope == ExecutionScope.MAIN_AGENT && principal is CloudPrincipal.OwnerUser
    }

    data class ApprovalGrant(
        val workItemId: String,
        val toolCallId: String,
        val toolName: String,
        val argsDigest: String,
        val consumeOnce: () -> Boolean,
    )

    /**
     * Innermost execution gate used by direct tool calls, subagents, and `recipe_run`.
     */
    suspend fun executeGate(
        toolName: String,
        args: JsonObject,
        scope: ExecutionScope = ExecutionScope.MAIN_AGENT,
        context: TaskCallContext? = null,
        recipeDepth: Int = 0,
        principal: CloudPrincipal? = null,
        approvalGrant: ApprovalGrant? = null,
    ): JsonElement {
        if (context != null && toolName !in context.allowedTools) return buildJsonObject {
            put("ok", false); put("error", "Agent 未获授该工具")
        }
        val def = get(toolName)
            ?: return buildJsonObject {
                put("ok", false)
                put("error", "未注册的工具: $toolName")
            }

        // Defect #8: Check capability switch at the innermost execution point
        if (!capabilities.isEnabled(def.requiredCapability)) {
            return buildJsonObject {
                put("ok", false)
                put("error", "能力未启用: ${def.requiredCapability}")
            }
        }

        if (def.ownerOnly && !isOwnerAuthorized(scope, principal, recipeDepth)) {
            return buildJsonObject {
                put("ok", false)
                put("error", "工具 $toolName 仅限主人 OwnerUser 上下文执行 ($scope)")
            }
        }

        // Defect #4: Reject placeholder credentials before computing approval digest or executing
        val placeholderKey = CredentialRedactor.findPlaceholderCredentialKey(args)
        if (placeholderKey != null) {
            throw PlaceholderCredentialException("工具参数 $placeholderKey 包含占位符凭据，已拒绝执行")
        }

        val scopedArgs = if (context != null && toolName in setOf("history_search", "history_fetch")) {
            val requested = args["conversation_id"]?.jsonPrimitive?.contentOrNull
            require(requested == null || requested == context.sessionId) { "禁止跨会话读取" }
            JsonObject(args + ("conversation_id" to JsonPrimitive(context.sessionId)))
        } else args

        // Defect #5: Enforce scope boundary even if a subagent/sandbox fabricates a tool call.
        // The only exception is a one-time foreground-approved grant for authorized SUBAGENT write tools.
        if (
            scope in setOf(ExecutionScope.SUBAGENT, ExecutionScope.MODEL_COUNCIL, ExecutionScope.JS_SANDBOX) &&
            (def.highRisk || def.effect == ToolEffect.SIDE_EFFECT)
        ) {
            val grantValid = scope == ExecutionScope.SUBAGENT &&
                recipeDepth == 0 &&
                def.name !in EXCLUDED_WORKER_APPROVAL_TOOLS &&
                !def.ownerOnly &&
                approvalGrant != null &&
                context != null &&
                approvalGrant.workItemId == context.workItemId &&
                approvalGrant.toolName == toolName &&
                approvalGrant.argsDigest == OrchestrationHash.sha256Hex(scopedArgs.toString()) &&
                approvalGrant.consumeOnce()
            if (!grantValid) {
                return buildJsonObject {
                    put("ok", false)
                    put("error", "当前执行域 ($scope) 禁止调用高风险或宿主写工具: $toolName")
                }
            }
        }

        if (toolName == "recipe_run") {
            require(recipeDepth < 4) { "recipe 嵌套超过限额" }
            val nested = args["tool"]?.jsonPrimitive?.contentOrNull.orEmpty()
            require(nested.isNotBlank()) { "recipe_run 需要 tool 和 args，不接受配方名或 steps" }
            return executeGate(nested, args["args"]?.jsonObject ?: JsonObject(emptyMap()), scope, context, recipeDepth + 1, principal)
        }
        return def.taskHandler?.invoke(scopedArgs, requireNotNull(context) { "工具需要已认证任务身份" }) ?: def.handler(scopedArgs)
    }

    companion object {
        val BUILTIN_HIGH_RISK_NAMES = setOf(
            "terminal_exec",
            "workspace_artifact_delete",
            "mcp_call_tool",
            "interrupt_agent",
            "ssh_profile_create",
            "ssh_profile_update",
            "ssh_profile_delete",
        )
        val EXCLUDED_WORKER_APPROVAL_TOOLS = setOf(
            "terminal_exec",
            "mcp_call_tool",
            "interrupt_agent",
            "ssh_profile_create",
            "ssh_profile_update",
            "ssh_profile_delete",
        )
    }
}
