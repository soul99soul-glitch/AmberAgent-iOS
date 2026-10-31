package app.amber.cloud.runtime

import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
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
    SIDE_EFFECT,
}

data class CloudToolDefinition(
    val name: String,
    val description: String,
    val highRisk: Boolean,
    val effect: ToolEffect,
    val requiredCapability: String? = null,
    val parameters: InputSchema? = null,
    val handler: suspend (JsonObject) -> JsonElement,
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
 * - Defect #5: Subagents, ModelCouncil, and JS Sandbox never receive high-risk or side-effect write tools.
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
    fun isHighRisk(toolName: String): Boolean {
        val registered = tools[toolName]
        if (registered != null) {
            return registered.highRisk ||
                (toolName.startsWith("plugin__") && registered.effect == ToolEffect.SIDE_EFFECT)
        }
        return toolName in BUILTIN_HIGH_RISK_NAMES || toolName.startsWith("plugin__")
    }

    /**
     * Returns the tools visible to the given [scope].
     *
     * - Defect #5: `SUBAGENT`, `MODEL_COUNCIL`, and `JS_SANDBOX` are physically stripped of all
     *   high-risk and side-effect write tools.
     * - Defect #9: Only tools that are actually wired in [tools] AND whose [CloudToolDefinition.requiredCapability]
     *   is enabled in [capabilities] are advertised.
     */
    @Synchronized
    fun declaredTools(scope: ExecutionScope = ExecutionScope.MAIN_AGENT): List<Tool> {
        return availableDefinitions(scope).map { def ->
            Tool(
                name = def.name,
                description = def.description,
                parameters = { def.parameters },
                needsApproval = def.highRisk,
                allowsAutoApproval = !def.highRisk,
                mandatoryApproval = def.highRisk,
                execute = { args ->
                    val obj = runCatching { args.jsonObject }.getOrDefault(JsonObject(emptyMap()))
                    listOf(UIMessagePart.Text(def.handler(obj).toString()))
                },
            )
        }
    }

    @Synchronized
    fun availableDefinitions(scope: ExecutionScope = ExecutionScope.MAIN_AGENT): List<CloudToolDefinition> {
        return tools.values.filter { def ->
            if (!capabilities.isEnabled(def.requiredCapability)) return@filter false
            when (scope) {
                ExecutionScope.SUBAGENT,
                ExecutionScope.MODEL_COUNCIL,
                ExecutionScope.JS_SANDBOX,
                -> !def.highRisk && def.effect != ToolEffect.SIDE_EFFECT
                ExecutionScope.MAIN_AGENT,
                ExecutionScope.RECIPE,
                -> true
            }
        }.sortedBy { it.name }
    }

    /**
     * Innermost execution gate used by direct tool calls, subagents, and `recipe_run`.
     */
    suspend fun executeGate(
        toolName: String,
        args: JsonObject,
        scope: ExecutionScope = ExecutionScope.MAIN_AGENT,
    ): JsonElement {
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

        // Defect #5: Enforce scope boundary even if a subagent/sandbox fabricates a tool call
        if (
            scope in setOf(ExecutionScope.SUBAGENT, ExecutionScope.MODEL_COUNCIL, ExecutionScope.JS_SANDBOX) &&
            (def.highRisk || def.effect == ToolEffect.SIDE_EFFECT)
        ) {
            return buildJsonObject {
                put("ok", false)
                put("error", "当前执行域 ($scope) 禁止调用高风险或写工具: $toolName")
            }
        }

        // Defect #4: Reject placeholder credentials before executing
        val placeholderKey = CredentialRedactor.findPlaceholderCredentialKey(args)
        if (placeholderKey != null) {
            throw PlaceholderCredentialException("工具参数 $placeholderKey 包含占位符凭据，已拒绝执行")
        }

        return def.handler(args)
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
    }
}
