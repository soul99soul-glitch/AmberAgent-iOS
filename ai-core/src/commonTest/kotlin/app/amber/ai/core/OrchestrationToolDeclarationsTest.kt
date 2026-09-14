package app.amber.ai.core

import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** 线程编排工具的 schema、审批与关键语义契约。 */
class OrchestrationToolDeclarationsTest {

    // MARK: - spawn_agent

    @Test
    fun spawnAgentDeclarationPinsParametersAndFlags() {
        val tool = createSpawnAgentToolDeclaration()
        assertEquals("spawn_agent", tool.name)
        assertFalse(tool.needsApproval, "编排工具不设审批门（harness 拥有时机）")

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("task_name", "message"), params.required)

        val taskName = params.properties["task_name"]!!.jsonObject
        assertEquals("string", taskName["type"]?.jsonPrimitive?.contentOrNull)
        assertEquals("^[a-z0-9_]+$", taskName["pattern"]?.jsonPrimitive?.contentOrNull)

        val forkTurns = params.properties["fork_turns"]!!.jsonObject
        // L6: 实现接受任意正整数（"none" | "all" | 正整数字符串），schema 不再
        // 钉死 enum ["none","all","3"]——描述写明取值域。
        assertEquals("string", forkTurns["type"]?.jsonPrimitive?.contentOrNull)
        assertTrue(forkTurns["enum"] == null, "fork_turns 不得再钉死 enum——实现接受任意正整数")
        val forkDescription = forkTurns["description"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue("\"none\"" in forkDescription, "描述必须写明 \"none\" 取值")
        assertTrue("\"all\"" in forkDescription, "描述必须写明 \"all\" 取值")
        assertTrue("positive-integer" in forkDescription, "描述必须写明正整数字符串取值")
        assertTrue("Defaults to \"all\"" in forkDescription, "fork_turns 必须写明默认 all")

        assertTrue("role_assistant_id" in params.properties)
        listOf("role_id", "system_prompt", "context", "tool_scope", "skill_names", "model_id", "reasoning_level").forEach { name ->
            assertTrue(name in params.properties, "spawn_agent 缺少动态角色字段: $name")
        }
        assertEquals(
            "array",
            params.properties["tool_scope"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull
        )
        assertEquals(
            "array",
            params.properties["skill_names"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull
        )

        val description = tool.description
        listOf("tool catalog", "can spawn its own subagents", "allowed scope", "background", "/root/", "FINAL_ANSWER").forEach { semantic ->
            assertTrue(semantic in description, "spawn_agent 描述缺少关键语义: $semantic")
        }
    }

    // MARK: - list_agents / interrupt_agent

    @Test
    fun listAgentsDeclarationPinsOptionalPathPrefix() {
        val tool = createListAgentsToolDeclaration()
        assertEquals("list_agents", tool.name)
        assertFalse(tool.needsApproval)

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertTrue("path_prefix" in params.properties, "path_prefix 可选")
        assertTrue(params.required.isNullOrEmpty(), "list_agents 无必填参数")
    }

    @Test
    fun interruptAgentDeclarationPinsRequiredTarget() {
        val tool = createInterruptAgentToolDeclaration()
        assertEquals("interrupt_agent", tool.name)
        assertFalse(tool.needsApproval)

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("target"), params.required)
        val target = params.properties["target"]!!.jsonObject
        assertTrue(
            "child_thread_id" in (target["description"]?.jsonPrimitive?.contentOrNull ?: ""),
            "target 描述必须同时接受 child_thread_id 与 agent path",
        )
        assertTrue("agent path" in (target["description"]?.jsonPrimitive?.contentOrNull ?: ""))

        val description = tool.description
        assertTrue("thread is preserved" in description, "interrupt 不销毁线程")
        assertTrue("stays Open" in description, "interrupt 后线程保持可寻址")
        assertTrue("idle thread returns" in description, "idle 返回语义必须在描述里")
    }

    // MARK: - send_message / followup_task / wait_agent（P1-d）

    @Test
    fun sendMessageDeclarationPinsRequiredTargetAndMessage() {
        val tool = createSendMessageToolDeclaration()
        assertEquals("send_message", tool.name)
        assertFalse(tool.needsApproval, "编排工具不设审批门（harness 拥有时机）")

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("target", "message"), params.required)

        // 描述必须明示「投递不唤醒」：idle 目标的邮件留在 mailbox 直到其下次 run。
        val description = tool.description
        assertTrue("does not trigger a new turn" in description, "必须明示不触发新 turn")
        assertTrue("mailbox" in description, "必须说明 mailbox 语义")
        assertTrue("idle" in description, "必须说明 idle 目标的行为")
    }

    @Test
    fun followupTaskDeclarationPinsRequiredTargetAndWakeSemantics() {
        val tool = createFollowupTaskToolDeclaration()
        assertEquals("followup_task", tool.name)
        assertFalse(tool.needsApproval)

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("target", "message"), params.required)

        val description = tool.description
        assertTrue("idle" in description, "必须说明 idle 唤醒语义")
        assertTrue("running" in description || "queued" in description, "必须说明运行中目标的排队语义")
    }

    @Test
    fun waitAgentDeclarationPinsOptionalTimeoutAndInterruptSemantics() {
        val tool = createWaitAgentToolDeclaration()
        assertEquals("wait_agent", tool.name)
        assertFalse(tool.needsApproval)

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertTrue("timeout_ms" in params.properties, "timeout_ms 可选")
        assertTrue(params.required.isNullOrEmpty(), "wait_agent 无必填参数")

        val timeout = params.properties["timeout_ms"]!!.jsonObject
        assertEquals("integer", timeout["type"]?.jsonPrimitive?.contentOrNull)
        val timeoutDescription = timeout["description"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue("[5000, 300000]" in timeoutDescription)
        assertTrue("defaults to 30000" in timeoutDescription)

        val description = tool.description
        assertTrue("interrupted" in description, "必须说明被新输入打断的语义")
    }

    // MARK: - catalog discoverability（非常驻，deferred 池）

    @Test
    fun deferredNamesResolveThroughIosToolDeclarationCatalog() {
        val names = listOf(
            "exec", "wait", "spawn_agent", "list_agents", "interrupt_agent",
            "send_message", "followup_task", "wait_agent", "session_search", "session_read",
            "provider_config_status", "provider_config_apply", "provider_config_create",
            "provider_refresh_models", "settings_set_model_slot",
            "theme_pack_status", "theme_pack_import",
        )
        assertEquals(names, iosToolDeclarations(names).map { it.name })
    }

    @Test
    fun themePackStatusIsReadOnlyAndImportNeedsApproval() {
        val status = createThemePackStatusToolDeclaration()
        assertEquals("theme_pack_status", status.name)
        assertFalse(status.needsApproval)
        assertTrue(status.description.contains("theme_pack_import"))

        val import = createThemePackImportToolDeclaration()
        assertEquals("theme_pack_import", import.name)
        assertTrue(import.needsApproval, "试穿主题必须需要审批")
        val params = import.parameters()
        assertIs<InputSchema.Obj>(params)
        val required = params.required.orEmpty()
        assertTrue("id" in required)
        assertTrue("accent_hex" in required)
        val paper = params.properties["paper"]!!.jsonObject
        val paperEnum = paper["enum"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(listOf("paper", "neutral", "white", "pi", "notion"), paperEnum)
        assertFalse("garnet" in paperEnum)
        val shortcutIconStyle = params.properties["shortcut_icon_style"]!!.jsonObject
        assertEquals(
            listOf("phosphorFill", "pixelSit", "systemOutline"),
            shortcutIconStyle["enum"]!!.jsonArray.map { it.jsonPrimitive.content },
        )

        assertTrue(import.description.contains("design"), "主题说明必须引导模型使用完整设计对象")
        assertTrue(import.description.contains("appWide"), "主题说明必须保留 appWide 范围能力")
        val design = params.properties["design"]!!.jsonObject
        assertEquals("object", design["type"]?.jsonPrimitive?.contentOrNull)
        assertEquals(
            listOf("light", "dark", "patterns"),
            design["required"]!!.jsonArray.map { it.jsonPrimitive.content },
        )

        val palette = design["properties"]!!.jsonObject["light"]!!.jsonObject
        assertEquals(
            setOf("background", "surface", "foreground", "mutedForeground", "border"),
            palette["properties"]!!.jsonObject.keys,
        )
        assertEquals(
            setOf("background", "surface", "foreground", "mutedForeground", "border"),
            palette["required"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet(),
        )

        val gradient = design["properties"]!!.jsonObject["gradient"]!!.jsonObject
        val gradientProperties = gradient["properties"]!!.jsonObject
        assertEquals("array", gradientProperties["colors"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull)
        assertEquals(2, gradientProperties["colors"]!!.jsonObject["minItems"]?.jsonPrimitive?.int)
        assertEquals(4, gradientProperties["colors"]!!.jsonObject["maxItems"]?.jsonPrimitive?.int)
        assertEquals("array", gradientProperties["darkColors"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull)
        assertEquals(2, gradientProperties["darkColors"]!!.jsonObject["minItems"]?.jsonPrimitive?.int)
        assertEquals(4, gradientProperties["darkColors"]!!.jsonObject["maxItems"]?.jsonPrimitive?.int)
        assertEquals("number", gradientProperties["angle"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull)

        val patterns = design["properties"]!!.jsonObject["patterns"]!!.jsonObject
        assertEquals(3, patterns["maxItems"]?.jsonPrimitive?.int)
        val pattern = patterns["items"]!!.jsonObject
        val patternProperties = pattern["properties"]!!.jsonObject
        val kinds = patternProperties["kind"]!!.jsonObject["enum"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(listOf("dots", "grid", "diagonal", "crosses", "waves", "rings"), kinds)
        assertEquals(0.3, patternProperties["opacity"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(12.0, patternProperties["spacing"]!!.jsonObject["minimum"]?.jsonPrimitive?.double)
        assertEquals(120.0, patternProperties["spacing"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(0.5, patternProperties["size"]!!.jsonObject["minimum"]?.jsonPrimitive?.double)
        assertEquals(8.0, patternProperties["size"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)

        val components = design["properties"]!!.jsonObject["components"]!!.jsonObject
        assertEquals(
            setOf(
                "cardRadius", "bubbleRadius", "controlRadius", "borderWidth", "shadowOpacity", "shadowRadius",
                "brandText", "brandSize", "brandTracking",
            ),
            components["properties"]!!.jsonObject.keys,
        )
        assertEquals(32.0, components["properties"]!!.jsonObject["cardRadius"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(28.0, components["properties"]!!.jsonObject["bubbleRadius"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(28.0, components["properties"]!!.jsonObject["controlRadius"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(3.0, components["properties"]!!.jsonObject["borderWidth"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(0.35, components["properties"]!!.jsonObject["shadowOpacity"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(24.0, components["properties"]!!.jsonObject["shadowRadius"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(1, components["properties"]!!.jsonObject["brandText"]!!.jsonObject["minLength"]?.jsonPrimitive?.int)
        assertEquals(16, components["properties"]!!.jsonObject["brandText"]!!.jsonObject["maxLength"]?.jsonPrimitive?.int)
        assertEquals(40.0, components["properties"]!!.jsonObject["brandSize"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
        assertEquals(-2.0, components["properties"]!!.jsonObject["brandTracking"]!!.jsonObject["minimum"]?.jsonPrimitive?.double)
        assertEquals(6.0, components["properties"]!!.jsonObject["brandTracking"]!!.jsonObject["maximum"]?.jsonPrimitive?.double)
    }

    @Test
    fun providerConfigStatusIsReadOnlyAndApplyNeedsApproval() {
        val status = createProviderConfigStatusToolDeclaration()
        assertEquals("provider_config_status", status.name)
        assertFalse(status.needsApproval)
        assertTrue(status.description.contains("Never returns API keys") || status.description.contains("API key"))

        val apply = createProviderConfigApplyToolDeclaration()
        assertEquals("provider_config_apply", apply.name)
        assertTrue(apply.needsApproval, "写入 provider 配置必须需要审批")
        assertTrue(apply.description.contains("never echoed") || apply.description.contains("never"))

        val create = createProviderConfigCreateToolDeclaration()
        assertEquals("provider_config_create", create.name)
        assertTrue(create.needsApproval, "新建 provider 必须需要审批")
    }

    // MARK: - session_search / session_read（跨会话读取，与 Android 当前会话
    // conversation_search/conversation_expand 语义错开）

    @Test
    fun sessionSearchDeclarationPinsRequiredQueryAndLimitBounds() {
        val tool = createSessionSearchToolDeclaration()
        assertEquals("session_search", tool.name)
        assertFalse(tool.needsApproval, "跨会话读取不设审批门（只读 pure）")

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("query"), params.required)

        val query = params.properties["query"]!!.jsonObject
        assertEquals("string", query["type"]?.jsonPrimitive?.contentOrNull)

        val limit = params.properties["limit"]!!.jsonObject
        assertEquals("integer", limit["type"]?.jsonPrimitive?.contentOrNull)
        val limitDescription = limit["description"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue("[1, 20]" in limitDescription, "limit 描述必须写明范围 [1, 20]")
        assertTrue("8" in limitDescription, "limit 描述必须写明默认 8")

        val description = tool.description
        assertTrue("ALL conversations" in description, "必须声明跨全部会话搜索")
        assertTrue("session_read" in description, "描述必须引导 follow-up session_read")
    }

    @Test
    fun sessionReadDeclarationPinsRequiredConversationIdAndMessageBounds() {
        val tool = createSessionReadToolDeclaration()
        assertEquals("session_read", tool.name)
        assertFalse(tool.needsApproval, "跨会话读取不设审批门（只读 pure）")

        val params = tool.parameters()
        assertIs<InputSchema.Obj>(params)
        assertEquals(listOf("conversation_id"), params.required)

        val conversationId = params.properties["conversation_id"]!!.jsonObject
        assertEquals("string", conversationId["type"]?.jsonPrimitive?.contentOrNull)
        val idDescription = conversationId["description"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue("session_search" in idDescription, "conversation_id 必须说明取自 session_search 结果")

        val maxMessages = params.properties["max_messages"]!!.jsonObject
        assertEquals("integer", maxMessages["type"]?.jsonPrimitive?.contentOrNull)
        val maxDescription = maxMessages["description"]?.jsonPrimitive?.contentOrNull.orEmpty()
        assertTrue("[1, 50]" in maxDescription, "max_messages 描述必须写明范围 [1, 50]")
        assertTrue("20" in maxDescription, "max_messages 描述必须写明默认 20")

        val description = tool.description
        assertTrue("Read-only" in description, "必须声明只读")
        assertTrue("session_search" in description, "描述必须说明 id 来自 session_search 结果")
    }

}
