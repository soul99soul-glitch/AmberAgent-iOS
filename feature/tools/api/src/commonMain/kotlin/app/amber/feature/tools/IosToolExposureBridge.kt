package app.amber.feature.tools

import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

private val bridgeJson = Json { ignoreUnknownKeys = true }

/**
 * P0-a: ObjC/Swift-facing facade over [ToolExposureState] for the iOS chat run.
 *
 * Kotlin/Native export constraints (reserved words, default arguments, sealed
 * classes) mean this surface only uses String / Boolean / List<Tool> /
 * List<String>. The registry is built internally from the passed declarations;
 * [tool_search] is appended by the bridge itself so iOS never declares it
 * twice. One bridge instance is owned per chat run (see
 * ChatGenerationCoordinator) — the same instance is reused across all tool
 * rounds of that run so a `tool_search` hit becomes callable on the NEXT round.
 */
class IosToolExposureBridge private constructor(
    private var allTools: List<Tool>,
    private var registry: ToolRegistry,
    private var exposureState: ToolExposureState,
    private var recipeSearchInfo: Map<String, String>,
) {
    constructor(tools: List<Tool>) : this(
        withSearchTool(tools, ToolRegistry.from(tools)),
        ToolRegistry.from(tools),
        ToolExposureState.from(
            withSearchTool(tools, ToolRegistry.from(tools)),
            residentPolicy = ::iosResidentToolPolicy,
        ),
        recipeSearchInfo = emptyMap(),
    )

    constructor(tools: List<Tool>, registry: ToolRegistry) : this(
        withSearchTool(tools, registry),
        registry,
        ToolExposureState.from(
            withSearchTool(tools, registry),
            residentPolicy = ::iosResidentToolPolicy,
        ),
        recipeSearchInfo = emptyMap(),
    )

    /**
     * Wave B1 (§13.2.3): rebuild-with-recipe-search-info constructor. The
     * Swift round-boundary seam rebuilds the bridge over a new catalog
     * revision and seeds the previously exposed names back via
     * [exposeToolNames]; this map (toolId → `{"version":…,
     * "permission_summary":…, "source":"custom.recipe"}`) lets `tool_search`
     * results carry the recipe version/permission/source fields (§16.3).
     */
    constructor(tools: List<Tool>, recipeSearchInfo: Map<String, String>) : this(
        withSearchTool(tools, ToolRegistry.from(tools)),
        ToolRegistry.from(tools),
        ToolExposureState.from(
            withSearchTool(tools, ToolRegistry.from(tools)),
            residentPolicy = ::iosResidentToolPolicy,
        ),
        recipeSearchInfo = recipeSearchInfo,
    )

    /** Appends the discovery tool unless the caller already declared it (a
     *  bridge rebuilt from a previous bridge's `visibleTools()` already has it —
     *  appending again would make ToolRegistry.from throw on duplicates). */
    private companion object {
        /**
         * WebMount is a workflow, not a bag of independent commands. A fresh
         * user turn gets a fresh bridge, so exposing only the literal search
         * hits can leave the model with `wm_type`/`wm_scroll` but no way to
         * navigate or re-observe. Keep this small read/navigation spine
         * together whenever any WebMount tool is discovered.
         */
        val WEB_MOUNT_CORE_TOOL_NAMES = listOf(
            "wm_tab_list",
            "wm_open",
            "wm_observe",
            "wm_visual_snapshot",
            "wm_wait",
        )

        fun withSearchTool(tools: List<Tool>, registry: ToolRegistry): List<Tool> =
            if (tools.any { it.name == TOOL_SEARCH_TOOL_NAME }) tools
            else tools + createToolSearchTool(registry)
    }

    /** Full declaration list including the appended tool_search tool. */
    fun fullToolDeclarations(): List<Tool> = allTools

    fun lazyModeEnabled(): Boolean = exposureState.enabled

    /**
     * Fix A: system-level discovery guidance for the iOS run. In lazy mode this
     * is the internal tool_search tool's systemPrompt text — it tells the model
     * that hidden tools are "not callable until" `tool_search` exposes them.
     * Non-lazy runs return an empty string (no discovery contract needed).
     */
    fun discoveryGuidance(): String =
        if (exposureState.enabled) toolSearchDiscoveryGuidance(registry) else ""

    fun visibleTools(): List<Tool> = exposureState.toolsForStep()

    fun exposeToolNames(names: List<String>) {
        exposureState.exposeToolNames(names)
    }

    /**
     * Replaces the full catalog at a model-round boundary while preserving
     * exposure for tools that still exist. This keeps one bridge identity for
     * the whole run, so the engine, tool_search and nested execution all see
     * the same recipe revision after an import/enable/disable/delete.
     */
    fun replaceFullCatalog(tools: List<Tool>, recipeSearchInfo: Map<String, String>) {
        val previouslyVisible = exposureState.toolsForStep().map { it.name }
        val nextRegistry = ToolRegistry.from(tools)
        val nextAllTools = withSearchTool(tools, nextRegistry)
        allTools = nextAllTools
        registry = nextRegistry
        exposureState = ToolExposureState.from(
            nextAllTools,
            residentPolicy = ::iosResidentToolPolicy,
        )
        this.recipeSearchInfo = recipeSearchInfo
        exposureState.exposeToolNames(previouslyVisible)
    }

    /**
     * Executes a `tool_search` call locally: parses query/category/limit, runs
     * the shared search index, feeds the `expanded_tools` names back into the
     * exposure state (so hits are visible on the next model step), and returns
     * the payload JSON. Never throws — malformed arguments yield an error
     * payload instead.
     */
    fun executeToolSearch(argumentsJson: String): String {
        return runCatching {
            val input = bridgeJson.parseToJsonElement(argumentsJson.ifBlank { "{}" }).jsonObject
            val query = input["query"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val category = input["category"]?.jsonPrimitive?.contentOrNull?.ifBlank { null }
            val limit = input["limit"]?.jsonPrimitive?.intOrNull ?: TOOL_SEARCH_DEFAULT_LIMIT
            val payload = ToolSearchIndex(registry).searchPayload(query, category, limit)
            // Wave B1 (§16.3): recipe hits additionally carry version,
            // permission summary and source=custom.recipe. The manifest body is
            // never included — the model only gets the schema at call time.
            val enriched = enrichRecipeSearchResults(payload)
            val searchHits = enriched["expanded_tools"]?.jsonArray
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                .orEmpty()
            val expanded = relatedExpandedToolNames(searchHits)
            exposureState.exposeToolNames(expanded)
            payloadWithRelatedExposure(enriched, searchHits, expanded).toString()
        }.getOrElse { toolSearchErrorPayload(it.message) }
    }

    private fun relatedExpandedToolNames(searchHits: List<String>): List<String> {
        if (searchHits.none { it.startsWith("wm_") }) return searchHits
        return (searchHits + WEB_MOUNT_CORE_TOOL_NAMES)
            .filter { registry.metadataFor(it) != null }
            .distinct()
    }

    private fun payloadWithRelatedExposure(
        payload: JsonObject,
        searchHits: List<String>,
        expanded: List<String>,
    ): JsonObject {
        if (expanded == searchHits) return payload
        return JsonObject(payload.toMutableMap().apply {
            put("expanded_tools", buildJsonArray { expanded.forEach { add(it) } })
            put(
                "workflow_hint",
                JsonPrimitive(
                    "WebMount core workflow is also callable on the next step: get a session with " +
                        "wm_tab_list, navigate URLs only with wm_open, then use wm_observe or " +
                        "wm_visual_snapshot. wm_type and wm_keys never navigate.",
                ),
            )
        })
    }

    /** Merges per-tool recipe search info into the `tools` entries of a
     *  search payload. Never throws and never changes non-recipe entries. */
    private fun enrichRecipeSearchResults(payload: JsonObject): JsonObject {
        if (recipeSearchInfo.isEmpty()) return payload
        val tools = payload["tools"] as? JsonArray ?: return payload
        val enrichedTools = buildJsonArray {
            tools.forEach { element ->
                val entry = element as? JsonObject
                val info = entry?.get("name")?.jsonPrimitive?.contentOrNull
                    ?.let { recipeSearchInfo[it] }
                    ?.let { raw -> runCatching { bridgeJson.parseToJsonElement(raw) as? JsonObject }.getOrNull() }
                if (entry == null || info == null) {
                    add(element)
                    return@forEach
                }
                add(buildJsonObject {
                    entry.forEach { (key, value) -> put(key, value) }
                    info.forEach { (key, value) -> put(key, value) }
                })
            }
        }
        return JsonObject(payload.toMutableMap().apply { put("tools", enrichedTools) })
    }

    /** JSON summary of lazy mode + schema savings (same footprint algorithm as the search payload). */
    fun savingsSummary(): String = buildJsonObject {
        put("lazy", exposureState.enabled)
        put("total_tools", allTools.size)
        put("visible_tools", exposureState.toolsForStep().size)
        put("estimated_full_schema_chars", allTools.sumOf { it.schemaFootprintChars() })
        put("estimated_visible_schema_chars", exposureState.toolsForStep().sumOf { it.schemaFootprintChars() })
    }.toString()

    /**
     * M5: executes the `tools_list` catalog call locally — the model-facing
     * guidance (`toolSearchDiscoveryGuidance`) tells the model to use
     * `tools_list` to identify exact tool names before `tool_search`, so iOS
     * must both DECLARE it (resident) and EXECUTE it. Returns the full catalog
     * as a `{status, total, tools:[{name, description}]}` JSON list (no
     * schemas, catalog/debug only). Never throws — malformed state yields an
     * error payload instead, mirroring `executeToolSearch`.
     */
    fun executeToolsList(): String {
        return runCatching {
            buildJsonObject {
                put("status", "ok")
                put("total", allTools.size)
                put("tools", buildJsonArray {
                    allTools.forEach { tool ->
                        add(buildJsonObject {
                            put("name", tool.name)
                            put("description", tool.description)
                        })
                    }
                })
            }.toString()
        }.getOrElse { toolSearchErrorPayload(it.message) }
    }

    private fun toolSearchErrorPayload(reason: String?): String = buildJsonObject {
        put("status", "error")
        put("error", "tool_search failed: ${reason ?: "invalid arguments"}")
    }.toString()
}

/**
 * Wave B1 (§13.2.4 / §16.3): one declaration for an active recipe. The Swift
 * registry derives this from the SAME snapshot that carries the manifest
 * (declaration and execution availability can never diverge, §16.1).
 *
 * Recipes are default-deferred: `recipe__*` is not in `IOS_RESIDENT_TOOL_NAMES`,
 * so in lazy mode (production catalog) they stay hidden until `tool_search`
 * exposes them — they never occupy the main prompt.
 *
 * `inputsJson` is `{"<name>":"string|number|boolean", ...}` generated by the
 * registry from the manifest's typed inputs; `effectClass` is the recipe's
 * conservative permission envelope (I-10) and drives the approval flags — a
 * mutation-capable envelope is never advertised as auto-approvable
 * (§10.3.5; per-step approval still applies at execution, next wave).
 */
fun createRecipeToolDeclaration(
    recipeName: String,
    version: String,
    description: String,
    inputsJson: String,
    effectClass: String,
): Tool {
    return createDynamicWorkflowToolDeclaration(
        toolId = "recipe__$recipeName",
        version = version,
        description = description,
        inputsJson = inputsJson,
        effectClass = effectClass,
    )
}

/** Shared declaration seam for Recipe v1 and amber.plugin.v1 workflow tools. */
fun createDynamicWorkflowToolDeclaration(
    toolId: String,
    version: String,
    description: String,
    inputsJson: String,
    effectClass: String,
): Tool {
    val inputs = runCatching {
        (bridgeJson.parseToJsonElement(inputsJson.ifBlank { "{}" }) as? JsonObject)
            ?: JsonObject(emptyMap())
    }.getOrDefault(JsonObject(emptyMap()))
    val properties = buildJsonObject {
        inputs.forEach { (name, typeElement) ->
            val type = (typeElement as? JsonPrimitive)?.contentOrNull ?: "string"
            put(name, buildJsonObject {
                put("type", type)
                put("description", "Workflow input `$name` for `$toolId` (v$version).")
            })
        }
    }
    val (needsApproval, allowsAutoApproval) = recipeApprovalFlags(effectClass)
    return Tool(
        name = toolId,
        description = description,
        parameters = { InputSchema.Obj(properties = properties, required = inputs.keys.toList()) },
        needsApproval = needsApproval,
        allowsAutoApproval = allowsAutoApproval,
        execute = { emptyList() },
    )
}

/** §10.3.5: read-only envelopes auto-approve at the declaration level;
 *  anything that can mutate goes through the existing approval policy. */
private fun recipeApprovalFlags(effectClass: String): Pair<Boolean, Boolean> = when (effectClass) {
    "pure", "networkRead" -> false to true
    "idempotent" -> true to false
    "sideEffect" -> true to false
    // Fail closed: an unknown envelope is never advertised as auto-approvable.
    else -> true to false
}

/**
 * Pinned iOS resident tool policy. Exact-name allowlist (no prefix rules) —
 * mirrors the real iOS declaration names from `iosToolDeclaration` in
 * ai-core/Tool.kt. Everything NOT in this set (wm_*, terminal_execute,
 * ios_shell_execute, ish_handoff, ios_ish_execute, mcp_test, mcp_import_from_skill, skill_validate,
 * skill_import, soul_import, skill_enable, skill_disable, recipe lifecycle,
 * subagent_report) is deferred
 * until `tool_search` exposes it.
 */
internal val IOS_RESIDENT_TOOL_NAMES: Set<String> = setOf(
    TOOL_SEARCH_TOOL_NAME,
    "tools_list",
    "ask_user",
    "permissions_status",
    "memory_tool",
    "search_web",
    "scrape_web",
    "generate_image",
    "workspace_file_read",
    "workspace_file_write",
    "workspace_file_edit",
    "workspace_file_list",
    "workspace_file_search",
    "workspace_file_move",
    "workspace_artifact_read",
    "workspace_artifact_delete",
    "mcp_list",
    "mcp_call",
    "mcp_describe_tool",
    "skills_list",
    "use_skill",
    "recipes_list",
    "plugins_list",
    "subagent_dispatch",
    "model_council_run",
    "file_read_selected",
)

internal fun iosResidentToolPolicy(name: String, category: String?): Boolean =
    name in IOS_RESIDENT_TOOL_NAMES
