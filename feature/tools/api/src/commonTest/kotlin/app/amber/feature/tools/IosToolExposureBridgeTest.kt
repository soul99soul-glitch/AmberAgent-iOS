package app.amber.feature.tools

import app.amber.ai.core.InputSchema
import app.amber.ai.core.McpDiscoveredToolSpec
import app.amber.ai.core.Tool
import app.amber.ai.core.iosToolDeclarations
import app.amber.ai.core.mcpExpandedToolDeclarations
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * P0-a: iOS tool_search exposure bridge contract. The bridge wraps the shared
 * KMP ToolExposureState with the iOS resident policy and an ObjC-friendly API,
 * so Swift only ever sees String/Boolean/List<Tool>/List<String> shapes.
 */
class IosToolExposureBridgeTest {

    private val json = Json { ignoreUnknownKeys = true }

    /** Pinned iOS product catalog used to verify lazy exposure. */
    private val fullIosToolNames: List<String> = listOf(
        "ask_user", "search_web", "scrape_web", "memory_tool",
        "workspace_file_read", "workspace_file_write", "workspace_file_edit",
        "workspace_file_list", "workspace_file_search", "workspace_file_move",
        "workspace_artifact_read", "workspace_artifact_delete",
        "generate_image",
        "wm_stations", "wm_tab_list", "wm_tab_new", "wm_tab_close", "wm_open",
        "wm_state", "wm_observe", "wm_extract", "wm_get", "wm_visual_snapshot", "wm_visual_read",
        "wm_screenshot", "wm_back", "wm_forward", "wm_clear_session", "wm_site_add",
        "wm_site_remove", "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll",
        "wm_select", "wm_find", "wm_wait",
        "mcp_call", "mcp_list", "mcp_test", "mcp_describe_tool", "mcp_import_from_skill",
        "skills_list", "use_skill", "skill_validate", "skill_import", "soul_import", "skill_enable", "skill_disable",
        "recipes_list", "recipe_validate", "recipe_import", "recipe_enable", "recipe_disable", "recipe_delete",
        "subagent_dispatch", "model_council_run", "file_read_selected",
        "ish_handoff", "ios_ish_execute", "terminal_execute", "ios_shell_execute",
        "terminal_job_start", "terminal_job_read", "terminal_job_wait", "terminal_job_stop",
        "permissions_status", "runtime_status", "tools_list", "subagent_report",
    )

    /** The pinned iOS resident policy set (see IosToolExposureBridge.kt). */
    private val iosResidentNames = setOf(
        "tool_search", "tools_list", "ask_user", "permissions_status", "runtime_status", "memory_tool",
        "search_web", "scrape_web", "generate_image",
        "workspace_file_read", "workspace_file_write", "workspace_file_edit",
        "workspace_file_list", "workspace_file_search", "workspace_file_move",
        "workspace_artifact_read", "workspace_artifact_delete",
        "mcp_list", "mcp_call", "mcp_describe_tool",
        "skills_list", "use_skill",
        "recipes_list",
        "subagent_dispatch", "model_council_run",
        "file_read_selected",
    )

    private val deferredNames = setOf(
        "wm_stations", "wm_click", "wm_type", "wm_screenshot",
        "ish_handoff", "ios_ish_execute", "terminal_execute", "ios_shell_execute",
        "terminal_job_start", "terminal_job_read", "terminal_job_wait", "terminal_job_stop",
        "mcp_test", "mcp_import_from_skill",
        "skill_validate", "skill_import", "soul_import", "skill_enable", "skill_disable",
        "recipe_validate", "recipe_import", "recipe_enable", "recipe_disable", "recipe_delete",
        "subagent_report",
    )

    private fun fullIosTools(): List<Tool> = iosToolDeclarations(fullIosToolNames)

    private fun parseObject(text: String): JsonObject =
        json.parseToJsonElement(text).jsonObject

    @Test
    fun fullCatalogEnablesLazyModeAndExposesOnlyResidentTools() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        assertTrue(bridge.lazyModeEnabled(), "declared tools must exceed the 40-tool lazy threshold")

        val visible = bridge.visibleTools().map { it.name }.toSet()
        assertEquals(iosResidentNames, visible, "first round must expose exactly the resident set (incl. tool_search)")
        deferredNames.forEach { assertFalse(it in visible, "$it must be deferred until tool_search exposes it") }
    }

    @Test
    fun smallCatalogBypassesLazyMode() {
        val lightTools = iosToolDeclarations(
            listOf(
                "search_web", "scrape_web", "memory_tool", "ask_user",
                "workspace_file_read", "workspace_file_list",
                "mcp_call", "mcp_list", "skills_list", "use_skill",
                "subagent_dispatch", "model_council_run",
            )
        )
        val bridge = IosToolExposureBridge(tools = lightTools)

        assertFalse(bridge.lazyModeEnabled())
        val visible = bridge.visibleTools().map { it.name }.toSet()
        assertEquals(
            lightTools.map { it.name }.toSet() + TOOL_SEARCH_TOOL_NAME,
            visible,
            "below threshold every declared tool plus tool_search must be visible",
        )
    }

    @Test
    fun executeToolSearchExpandsDeferredToolForNextStep() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        assertFalse("wm_type" in bridge.visibleTools().map { it.name })

        val payload = parseObject(
            bridge.executeToolSearch("""{"query":"wm_type","limit":1}""")
        )

        assertEquals("ok", payload["status"]?.jsonPrimitive?.contentOrNull)
        val expanded = payload["expanded_tools"]!!.jsonArray.map { it.jsonPrimitive.contentOrNull }
        assertTrue("wm_type" in expanded, "search must return the deferred wm_type tool")
        assertTrue("wm_type" in bridge.visibleTools().map { it.name }, "hit must be exposed for the next model step")
    }

    @Test
    fun webMountSearchCoExposesCoreNavigationWorkflow() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val payload = parseObject(
            bridge.executeToolSearch("""{"query":"wm_type wm_scroll 输入文本 滚动页面","limit":3}""")
        )

        val expanded = payload["expanded_tools"]!!.jsonArray
            .mapNotNull { it.jsonPrimitive.contentOrNull }
            .toSet()
        assertTrue("wm_type" in expanded)
        assertTrue("wm_scroll" in expanded)
        assertTrue("wm_tab_list" in expanded, "browser work must always be able to acquire a session")
        assertTrue("wm_open" in expanded, "a new user turn must not lose the navigation tool")
        assertTrue("wm_observe" in expanded, "navigation must retain the semantic observation step")
        assertTrue("wm_visual_read" in expanded, "browser work must retain visual viewport verification")
        assertTrue("wm_visual_snapshot" in expanded, "browser work should retain the visual-candidate fallback")
        assertTrue("wm_wait" in expanded, "browser work should retain page stabilization")
        assertTrue(
            payload["workflow_hint"]?.jsonPrimitive?.contentOrNull?.contains("wm_open") == true,
            "the result must explicitly prevent type/key tools from being mistaken for navigation",
        )
        val workflowHint = payload["workflow_hint"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue(workflowHint.contains("wm_visual_read"))
        assertTrue(workflowHint.contains("wm_visual_snapshot"))
        assertTrue(workflowHint.contains("not an image"))
        assertTrue(workflowHint.contains("remote"))
        assertTrue(workflowHint.contains("manual approval or high-risk auto-approval"))
        assertTrue(workflowHint.contains("visual verification has not occurred"))
        assertTrue(workflowHint.contains("DOM-verifiable results may still be reported honestly"))
        assertTrue(workflowHint.contains("image was analyzed"))
        assertTrue(expanded.all { it in bridge.visibleTools().map { tool -> tool.name } })
    }

    @Test
    fun amberShellSearchMetadataIsTerminalAndMutating() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        val payload = parseObject(
            bridge.executeToolSearch("""{"query":"ios_shell_execute","category":"terminal","limit":1}""")
        )
        val match = payload["tools"]!!.jsonArray.single().jsonObject

        assertEquals("ios_shell_execute", match["name"]?.jsonPrimitive?.contentOrNull)
        assertEquals("terminal", match["category"]?.jsonPrimitive?.contentOrNull)
        assertEquals("true", match["mutates"]?.jsonPrimitive?.contentOrNull)
    }

    @Test
    fun amberShellIsDiscoverableFromGenericLocalCommandIntent() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        val payload = parseObject(
            bridge.executeToolSearch("""{"query":"本地命令","category":"terminal","limit":3}""")
        )

        val matches = payload["tools"]!!.jsonArray.map { it.jsonObject["name"]!!.jsonPrimitive.content }
        assertTrue("ios_shell_execute" in matches)
    }

    @Test
    fun executeToolSearchReturnsErrorPayloadOnInvalidArguments() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val errorPayload = parseObject(bridge.executeToolSearch("not-json"))

        assertEquals("error", errorPayload["status"]?.jsonPrimitive?.contentOrNull)
        val visibleBefore = bridge.visibleTools().map { it.name }.toSet()
        assertEquals(iosResidentNames, visibleBefore, "failed search must not alter exposure")
    }

    // MARK: - M5: tools_list 本地执行（discovery 引导引用了它，iOS 必须声明+可执行）

    @Test
    fun toolsListDeclarationExistsInCatalog() {
        val declared = iosToolDeclarations(listOf("tools_list"))
        assertEquals(listOf("tools_list"), declared.map { it.name })
    }

    @Test
    fun executeToolsListReturnsFullCatalogNameDescriptionList() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val payload = parseObject(bridge.executeToolsList())

        assertEquals("ok", payload["status"]?.jsonPrimitive?.contentOrNull)
        val tools = payload["tools"]!!.jsonArray
        val fullNames = (fullIosTools().map { it.name } + TOOL_SEARCH_TOOL_NAME).toSet()
        assertEquals(fullNames.size, tools.size, "tools_list 必须返回桥全目录（含 tool_search），不裁剪")
        val names = tools.map { it.jsonObject["name"]!!.jsonPrimitive.contentOrNull }.toSet()
        assertEquals(fullNames, names, "返回清单必须覆盖全目录")
        val sample = tools.first { it.jsonObject["name"]!!.jsonPrimitive.contentOrNull == "wm_type" }.jsonObject
        assertTrue(
            sample["description"]?.jsonPrimitive?.contentOrNull?.isNotBlank() == true,
            "每项必须携带非空 description（模型靠它识别工具）",
        )
        // 目录/调试视图不暴露 schema——与 tool_search 的 callability 契约一致。
        assertTrue(payload["tools"]!!.jsonArray.all { it.jsonObject["schema"] == null })
    }

    @Test
    fun defaultResidentPolicyKeepsAndroidBehavior() {
        // Android-style names with the DEFAULT policy (no residentPolicy passed):
        // file_read / terminal_execute / mcp_call_tool stay resident, synthetic
        // hidden tools stay hidden — identical to the pre-P0-a contract.
        val hiddenTools = (0 until 45).map { tool("hidden_tool_$it", "Hidden capability $it") }
        val registry = ToolRegistry.from(
            hiddenTools + tool("file_read", "Read workspace file.") +
                tool("terminal_execute", "Run a terminal command.") +
                tool("mcp_call_tool", "Call an MCP server tool.")
        )
        val searchTool = createToolSearchTool(registry)
        val exposure = ToolExposureState.from(
            hiddenTools + tool("file_read", "Read workspace file.") +
                tool("terminal_execute", "Run a terminal command.") +
                tool("mcp_call_tool", "Call an MCP server tool.") + searchTool
        )

        assertTrue(exposure.enabled)
        val visible = exposure.toolsForStep().map { it.name }.toSet()
        assertTrue("file_read" in visible)
        assertTrue("terminal_execute" in visible)
        assertTrue("mcp_call_tool" in visible)
        assertFalse("hidden_tool_7" in visible)
    }

    @Test
    fun lazyBridgeDiscoveryGuidanceTellsModelToSearchBeforeHiddenToolsAreCallable() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        assertTrue(bridge.lazyModeEnabled())

        val guidance = bridge.discoveryGuidance()

        assertTrue(
            "not callable until" in guidance,
            "lazy guidance must carry the tool_search discovery contract, got: $guidance",
        )
        assertTrue(TOOL_SEARCH_TOOL_NAME in guidance)
        // 管线闭环：必须含行为规则——声称做不到之前先搜索（真机反馈的断链点）。
        assertTrue(
            "never claim inability" in guidance,
            "guidance must tell the model to search before claiming inability, got: $guidance",
        )
    }

    @Test
    fun bypassBridgeDiscoveryGuidanceIsEmpty() {
        val lightTools = iosToolDeclarations(
            listOf(
                "search_web", "scrape_web", "memory_tool", "ask_user",
                "workspace_file_read", "workspace_file_list",
                "mcp_call", "mcp_list", "skills_list", "use_skill",
                "subagent_dispatch", "model_council_run",
            )
        )
        val bridge = IosToolExposureBridge(tools = lightTools)
        assertFalse(bridge.lazyModeEnabled())

        assertEquals("", bridge.discoveryGuidance(), "non-lazy runs need no discovery guidance")
    }

    @Test
    fun savingsSummaryReportsShapeAndCounts() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val summary = parseObject(bridge.savingsSummary())

        assertTrue(summary["lazy"]!!.jsonPrimitive.contentOrNull == "true")
        assertEquals(fullIosTools().size + 1, summary["total_tools"]?.jsonPrimitive?.intOrNull)
        assertEquals(iosResidentNames.size, summary["visible_tools"]?.jsonPrimitive?.intOrNull)
        assertTrue(summary["estimated_full_schema_chars"]?.jsonPrimitive?.intOrNull!! > 0)
        assertTrue(summary["estimated_visible_schema_chars"]?.jsonPrimitive?.intOrNull!! > 0)
        assertTrue(
            summary["estimated_visible_schema_chars"]!!.jsonPrimitive.intOrNull!! <
                summary["estimated_full_schema_chars"]!!.jsonPrimitive.intOrNull!!,
        )
    }

    @Test
    fun bridgeCanBeRebuiltFromAnotherBridgesVisibleTools() {
        // The run coordinator and the background job both rebuild bridges from
        // already-filtered lists that already contain tool_search. Appending a
        // second tool_search must not throw (ToolRegistry.from rejects
        // duplicates), and the rebuild must keep every visible tool visible.
        val first = IosToolExposureBridge(tools = fullIosTools())
        val visible = first.visibleTools()

        val rebuilt = IosToolExposureBridge(tools = visible)

        assertEquals(visible.map { it.name }.toSet(), rebuilt.visibleTools().map { it.name }.toSet())
    }

    @Test
    fun replacingCatalogPreservesOnlySurvivingExposureAndDefersNewTools() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        bridge.exposeToolNames(listOf("wm_type"))
        assertTrue("wm_type" in bridge.visibleTools().map { it.name })

        val added = Tool(
            name = "recipe__new_tool",
            description = "new dynamic recipe",
            execute = { emptyList() },
        )
        val nextCatalog = fullIosTools().filterNot { it.name == "wm_type" } + added
        bridge.replaceFullCatalog(
            tools = nextCatalog,
            recipeSearchInfo = mapOf("recipe__new_tool" to "new recipe metadata"),
        )

        val fullNames = bridge.fullToolDeclarations().map { it.name }.toSet()
        val visibleNames = bridge.visibleTools().map { it.name }.toSet()
        assertFalse("wm_type" in fullNames, "removed tools must leave the catalog")
        assertFalse("wm_type" in visibleNames, "removed exposure must not survive refresh")
        assertTrue("search_web" in visibleNames, "surviving resident exposure must remain")
        assertTrue("recipe__new_tool" in fullNames, "new dynamic tools must enter the catalog")
        assertFalse("recipe__new_tool" in visibleNames, "new recipes stay deferred until tool_search")

        val payload = parseObject(bridge.executeToolSearch("""{"query":"new_tool","limit":1}"""))
        assertTrue("recipe__new_tool" in payload["expanded_tools"]!!.jsonArray.map { it.jsonPrimitive.contentOrNull })
        assertTrue("recipe__new_tool" in bridge.visibleTools().map { it.name })
    }

    // MARK: - P0-b/P0-c: expanded MCP tools are deferred and cost nothing visible

    /** Two servers x ten tools each, with real per-tool schemas. */
    private fun mcpExpandedToolsFixture(): List<Tool> {
        val schemas = listOf(
            """{"type":"object","properties":{"query":{"type":"string","description":"search query"}},"required":["query"]}""",
            """{"type":"object","properties":{"path":{"type":"string","description":"path to operate on"}},"required":["path"]}""",
        )
        return listOf("alpha", "beta").flatMap { server ->
            mcpExpandedToolDeclarations(
                server,
                (0 until 10).map { index ->
                    McpDiscoveredToolSpec(
                        "tool_$index",
                        "MCP tool $index on server $server operates on ${schemas[index % 2]}",
                        schemas[index % 2],
                    )
                },
            )
        }
    }

    @Test
    fun expandedMcpToolsStayDeferredUntilToolSearchAndDoNotGrowVisibleSchema() {
        val base = IosToolExposureBridge(tools = fullIosTools())
        val withMcp = IosToolExposureBridge(tools = fullIosTools() + mcpExpandedToolsFixture())

        assertTrue(withMcp.lazyModeEnabled(), "20 extra declarations must keep the run in lazy mode")
        assertEquals(
            base.fullToolDeclarations().size + 20,
            withMcp.fullToolDeclarations().size,
            "every expanded MCP tool must reach the bridge's full catalog",
        )

        // First round: no expanded MCP tool is visible.
        val visibleNames = withMcp.visibleTools().map { it.name }.toSet()
        assertTrue(
            visibleNames.none { it.startsWith("mcp__") },
            "expanded MCP tools must be deferred behind tool_search on the first round",
        )
        assertEquals(
            base.visibleTools().map { it.name }.toSet(),
            visibleNames,
            "deferred additions must not change the first-round visible set",
        )

        // Savings metric: adding deferred tools must not grow the visible
        // schema footprint; the full footprint grows by their schemas.
        val baseSummary = parseObject(base.savingsSummary())
        val withMcpSummary = parseObject(withMcp.savingsSummary())
        assertEquals(
            baseSummary["estimated_visible_schema_chars"],
            withMcpSummary["estimated_visible_schema_chars"],
            "deferred expanded tools must not grow the visible schema chars",
        )
        assertTrue(
            withMcpSummary["estimated_full_schema_chars"]!!.jsonPrimitive.intOrNull!! >
                baseSummary["estimated_full_schema_chars"]!!.jsonPrimitive.intOrNull!!,
            "the full catalog footprint must include the expanded MCP schemas",
        )

        // tool_search with an exact expanded name exposes it for the next step.
        val payload = parseObject(withMcp.executeToolSearch("""{"query":"mcp__alpha__tool_3","limit":5}"""))
        val expanded = payload["expanded_tools"]!!.jsonArray.map { it.jsonPrimitive.contentOrNull }
        assertTrue("mcp__alpha__tool_3" in expanded, "exact-name tool_search must hit a deferred MCP tool")
        assertTrue(
            "mcp__alpha__tool_3" in withMcp.visibleTools().map { it.name },
            "the hit must be callable on the next model step",
        )
    }

    @Test
    fun dynamicWorkflowDeclarationPreservesStructuredSchemaProperties() {
        val declaration = createDynamicWorkflowToolDeclaration(
            toolId = "plugin__kit__search",
            version = "1.0.0",
            description = "Structured search",
            inputsJson = """
                {
                  "type":"object",
                  "properties": {
                    "query":{"type":"string","enum":["swift","kotlin"]},
                    "options":{"type":"object","properties":{"limit":{"type":"integer"}}},
                    "tags":{"type":"array","items":{"type":"string"}}
                  },
                  "required":["query"],
                  "description":"Structured search arguments",
                  "additionalProperties":false,
                  "enum":[{"query":"swift"}]
                }
            """.trimIndent(),
            effectClass = "pure",
        )

        val parameters = assertIs<InputSchema.Obj>(declaration.parameters())
        assertEquals(listOf("query"), parameters.required)
        assertEquals("Structured search arguments", parameters.description)
        assertEquals(false, parameters.additionalProperties)
        assertEquals(1, parameters.enumValues?.size)
        val query = assertIs<JsonObject>(parameters.properties["query"])
        assertEquals("string", query["type"]?.jsonPrimitive?.content)
        assertNotNull(query["enum"])
        val options = assertIs<JsonObject>(parameters.properties["options"])
        assertEquals("object", options["type"]?.jsonPrimitive?.content)
        assertTrue(options["properties"] is JsonObject)
        val tags = assertIs<JsonObject>(parameters.properties["tags"])
        assertEquals("array", tags["type"]?.jsonPrimitive?.content)
        assertTrue(tags["items"] is JsonObject)
    }

    @Test
    fun dynamicWorkflowDeclarationKeepsLegacyFlatInputFallback() {
        val declaration = createDynamicWorkflowToolDeclaration(
            toolId = "recipe__legacy",
            version = "1.0.0",
            description = "Legacy recipe",
            inputsJson = """{"query":"string","limit":"number"}""",
            effectClass = "pure",
        )

        val parameters = assertIs<InputSchema.Obj>(declaration.parameters())
        assertEquals(setOf("query", "limit"), parameters.properties.keys)
        assertEquals(setOf("query", "limit"), parameters.required!!.toSet())
        assertEquals("string", parameters.properties["query"]!!.jsonObject["type"]!!.jsonPrimitive.content)
    }

    @Test
    fun pluginDevelopmentAliasFindsSdkAndMarksCandidateTestAsMutating() {
        val declarations = iosToolDeclarations(listOf("plugin_sdk", "plugin_test"))
        val index = ToolSearchIndex(ToolRegistry.from(declarations), null)

        val sdk = index.searchPayload("开发工具", null, 5)
        assertTrue(sdk["expanded_tools"]!!.jsonArray.any { it.jsonPrimitive.content == "plugin_sdk" })

        val test = index.searchPayload("测试插件", null, 5)
            .getValue("tools").jsonArray.single().jsonObject
        assertEquals("plugin_test", test["name"]?.jsonPrimitive?.content)
        assertEquals("true", test["mutates"]?.jsonPrimitive?.content)
        assertEquals("true", test["needs_approval"]?.jsonPrimitive?.content)
        assertEquals("false", test["allows_auto_approval"]?.jsonPrimitive?.content)
    }

    // MARK: Jev Phase 1 — 纯候选快照与排序覆盖

    @Test
    fun candidateSnapshotIsReadOnlyAndCarriesCandidateMetadata() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        val beforeVisible = bridge.visibleTools().map { it.name }.toSet()

        val snapshot = parseObject(bridge.candidateSnapshot("""{"query":"workspace file edit","limit":5}"""))
        assertEquals("ok", snapshot["status"]?.jsonPrimitive?.content)
        assertTrue((snapshot["pool_size"]!!.jsonPrimitive.int) > 0, "semantic pool must include keyword supplements")
        val candidates = snapshot["candidates"]!!.jsonArray
        assertTrue(candidates.isNotEmpty())
        val first = candidates.first().jsonObject
        assertTrue(first.containsKey("name") && first.containsKey("category") && first.containsKey("score"))

        // 快照只读：暴露集合保持不变。
        assertEquals(beforeVisible, bridge.visibleTools().map { it.name }.toSet())
    }

    @Test
    fun candidateSnapshotFlagsExactNameMatchWithoutExposing() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val snapshot = parseObject(bridge.candidateSnapshot("""{"query":"search_web","limit":5}"""))
        assertEquals("search_web", snapshot["exact_match"]?.jsonPrimitive?.content)
    }

    @Test
    fun toolSearchPreviewMatchesExecutionWithoutChangingExposure() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        val beforeVisible = bridge.visibleTools().map { it.name }.toSet()
        val arguments = """{"query":"workspace file edit","limit":5}"""
        val ranking = listOf("wm_click", "workspace_file_edit")

        val keywordPreview = parseObject(bridge.previewToolSearch(arguments))
        val rankedPreview = parseObject(bridge.previewToolSearch(arguments, ranking))

        assertEquals("ok", keywordPreview["status"]?.jsonPrimitive?.content)
        assertEquals("ok", rankedPreview["status"]?.jsonPrimitive?.content)
        assertEquals("wm_click", rankedPreview["expanded_tools"]!!.jsonArray.first().jsonPrimitive.content)
        assertEquals(beforeVisible, bridge.visibleTools().map { it.name }.toSet(), "previews must not mutate exposure")

        val executed = parseObject(bridge.executeToolSearch(arguments, ranking))
        assertEquals(rankedPreview, executed, "preview and execution must share the same search payload")
        assertEquals(
            beforeVisible + rankedPreview["expanded_tools"]!!.jsonArray.map { it.jsonPrimitive.content },
            bridge.visibleTools().map { it.name }.toSet(),
        )
    }

    @Test
    fun approvalTriageFactsExposeRegisteredMutationAndRiskMetadataOnly() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())

        val facts = parseObject(bridge.approvalTriageFactsJson("ios_shell_execute")!!)
        assertEquals(setOf("mutates", "risk"), facts.keys)
        assertEquals(true, facts["mutates"]?.jsonPrimitive?.content?.toBoolean())
        assertEquals("sensitive", facts["risk"]?.jsonPrimitive?.content)
        assertEquals(null, bridge.approvalTriageFactsJson("mcp__remote__unknown"))
    }

    @Test
    fun approvalTriageFactsUseInvocationMutationAndRiskWhenArgumentsAreAvailable() {
        val bridge = IosToolExposureBridge(tools = listOf(tool("http_request")))

        val post = parseObject(
            bridge.approvalTriageFactsJsonForInvocation(
                "http_request",
                """{"method":"POST","url":"https://example.com/items"}""",
            )!!,
        )
        assertEquals("true", post["mutates"]?.jsonPrimitive?.content)
        assertEquals("high", post["risk"]?.jsonPrimitive?.content)

        val get = parseObject(
            bridge.approvalTriageFactsJsonForInvocation(
                "http_request",
                """{"method":"GET","url":"https://example.com/items"}""",
            )!!,
        )
        assertEquals("false", get["mutates"]?.jsonPrimitive?.content)
        assertEquals("normal", get["risk"]?.jsonPrimitive?.content)
    }

    @Test
    fun executeToolSearchRankingOverrideDropsUnknownNamesAndKeepsKeywordScores() {
        val bridge = IosToolExposureBridge(tools = fullIosTools())
        // Jev 排序：把 memory_tool 排到最前；未知名与目录外工具必须被丢弃。
        val payload = parseObject(
            bridge.executeToolSearch(
                """{"query":"remember this note","limit":3}""",
                rankingOverride = listOf("memory_tool", "not_a_real_tool", "tool_search"),
            )
        )
        val expanded = payload["expanded_tools"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals("memory_tool", expanded.first(), "ranking override must lead the result order")
        assertFalse("not_a_real_tool" in expanded, "unknown names must not leak into exposure")
        assertFalse("tool_search" in expanded, "tool_search itself can never be exposed via ranking")
    }

    private fun tool(
        name: String,
        description: String = "test tool",
    ) = Tool(
        name = name,
        description = description,
        parameters = {
            InputSchema.Obj(
                properties = buildJsonObject {
                    put("query", buildJsonObject {
                        put("type", "string")
                        put("description", "query")
                    })
                }
            )
        },
        execute = { listOf(UIMessagePart.Text("ok")) },
    )
}
