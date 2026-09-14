package app.amber.ai.provider.claude

import app.amber.ai.core.MessageRole
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.core.Tool
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class ClaudeKmpProviderMessageTest {

    private val provider = ClaudeKmpProvider()

    private val claudeSetting = ProviderSetting.Claude(
        id = kotlin.uuid.Uuid.parse("00000000-0000-0000-0000-000000000001"),
        name = "Claude",
        apiKey = "sk-ant-test",
        baseUrl = "https://api.anthropic.com/v1",
        promptCaching = false,
    )

    private fun reasoningModel(): Model = Model(
        modelId = "claude-sonnet-4-5",
        displayName = "Claude Sonnet 4.5",
        abilities = listOf(ModelAbility.REASONING, ModelAbility.TOOL),
    )

    @Test
    fun `message delta preserves stop reason`() {
        val chunk = provider.parseStreamEvent(
            id = "msg_1",
            type = "message_delta",
            data = """{"delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":32}}""",
        )

        assertEquals("max_tokens", chunk!!.choices.single().finishReason)
    }

    @Test
    fun `stream rejects eof without a terminal signal`() {
        val terminal = ClaudeStreamTerminalState()
        terminal.observe(
            type = "content_block_delta",
            data = """{"delta":{"type":"text_delta","text":"partial"}}""",
        )

        assertFailsWith<IllegalStateException> { terminal.requireCompleted() }
    }

    @Test
    fun `buildMessageRequest sets model, max_tokens, stream, and messages`() {
        val params = TextGenerationParams(
            model = Model(modelId = "claude-sonnet-4-5", displayName = "Sonnet"),
            maxTokens = 1024,
        )
        val messages = listOf(
            UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("you are helpful"))),
            UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("follow the user's format"))),
            UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
        )

        val body = provider.callBuildMessageRequest(claudeSetting, messages, params, stream = true)

        assertEquals("claude-sonnet-4-5", body["model"]!!.jsonPrimitive.content)
        assertEquals(1024, body["max_tokens"]!!.jsonPrimitive.intOrNull)
        assertTrue(body["stream"]!!.jsonPrimitive.boolean)
        // system extracted out of messages into top-level "system" array
        assertNotNull(body["system"])
        assertEquals(2, body["system"]!!.jsonArray.size)
        assertEquals("you are helpful", body["system"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("follow the user's format", body["system"]!!.jsonArray[1].jsonObject["text"]!!.jsonPrimitive.content)
        // messages array excludes the SYSTEM role entry
        val msgs = body["messages"]!!.jsonArray
        assertEquals(1, msgs.size)
        assertEquals("user", msgs[0].jsonObject["role"]!!.jsonPrimitive.content)
    }

    @Test
    fun `single system message keeps its original shape`() {
        val params = TextGenerationParams(
            model = Model(modelId = "claude-sonnet-4-5", displayName = "Sonnet"),
            maxTokens = 1024,
        )
        val body = provider.callBuildMessageRequest(
            claudeSetting,
            listOf(
                UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("one system"))),
                UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
            ),
            params,
        )

        assertEquals(1, body["system"]!!.jsonArray.size)
        assertEquals("one system", body["system"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `explicit execution failures become Anthropic is_error results`() {
        val params = TextGenerationParams(model = reasoningModel())
        val assistant = UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                UIMessagePart.Tool(
                    toolCallId = "failed",
                    toolName = "workspace_file_read",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"status":"failed"}""")),
                ),
                UIMessagePart.Tool(
                    toolCallId = "denied",
                    toolName = "workspace_file_write",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"denied":true}""")),
                ),
                UIMessagePart.Tool(
                    toolCallId = "timeout",
                    toolName = "terminal_execute",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"status":"timed_out"}""")),
                ),
            ),
        )

        val body = provider.callBuildMessageRequest(
            claudeSetting,
            listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("run tools"))), assistant),
            params,
        )
        val results = body["messages"]!!.jsonArray[2].jsonObject["content"]!!.jsonArray

        assertEquals(3, results.size)
        results.forEach { result ->
            assertTrue(result.jsonObject["is_error"]!!.jsonPrimitive.boolean)
        }
    }

    @Test
    fun `statusless explicit error fields become Anthropic is_error results`() {
        val params = TextGenerationParams(model = reasoningModel())
        val assistant = UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                UIMessagePart.Tool(
                    toolCallId = "memory-error",
                    toolName = "memory_tool",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"error":"memory not found"}""")),
                ),
                UIMessagePart.Tool(
                    toolCallId = "vision-error",
                    toolName = "wm_visual_read",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"error_code":"vision_unavailable","reason":"no model"}""")),
                ),
                UIMessagePart.Tool(
                    toolCallId = "notification-error",
                    toolName = "notification_schedule",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"reason":"permission unavailable"}""")),
                ),
            ),
        )

        val body = provider.callBuildMessageRequest(
            claudeSetting,
            listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("run tools"))), assistant),
            params,
        )
        val results = body["messages"]!!.jsonArray[2].jsonObject["content"]!!.jsonArray

        results.forEach { result ->
            assertTrue(result.jsonObject["is_error"]!!.jsonPrimitive.boolean)
        }
    }

    @Test
    fun `plain negative business result does not become Anthropic is_error`() {
        val assistant = UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                UIMessagePart.Tool(
                    toolCallId = "no-match",
                    toolName = "search_web",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":false,"status":{"kind":"no_match"},"reason":"no matches"}""")),
                ),
                UIMessagePart.Tool(
                    toolCallId = "job-state",
                    toolName = "terminal_job_read",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("""{"ok":true,"status":"failed","job_id":"job-1"}""")),
                ),
            ),
        )

        val body = provider.callBuildMessageRequest(
            claudeSetting,
            listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("search"))), assistant),
            TextGenerationParams(model = reasoningModel()),
        )
        val results = body["messages"]!!.jsonArray[2].jsonObject["content"]!!.jsonArray
        results.forEach { result -> assertNull(result.jsonObject["is_error"]) }
    }

    @Test
    fun `temperature is omitted when reasoning is enabled, present otherwise`() {
        val msgs = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi"))))

        // Reasoning ON -> temperature suppressed
        val reasoningParams = TextGenerationParams(
            model = reasoningModel(),
            temperature = 0.5f,
            reasoningLevel = ReasoningLevel.MEDIUM,
        )
        val reasoningBody = provider.callBuildMessageRequest(claudeSetting, msgs, reasoningParams)
        assertNull(reasoningBody["temperature"])
        assertNotNull(reasoningBody["thinking"])
        assertEquals("adaptive", reasoningBody["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("medium", reasoningBody["output_config"]!!.jsonObject["effort"]!!.jsonPrimitive.content)

        // Reasoning OFF -> temperature present
        val plainParams = TextGenerationParams(
            model = Model(modelId = "m", displayName = "m", abilities = emptyList()),
            temperature = 0.7f,
        )
        val plainBody = provider.callBuildMessageRequest(claudeSetting, msgs, plainParams)
        assertEquals(0.7f, plainBody["temperature"]!!.jsonPrimitive.content.toFloat())
    }

    @Test
    fun `tools emit name, description, and input_schema`() {
        val tool = Tool(
            name = "get_weather",
            description = "Get the weather",
            parameters = {
                app.amber.ai.core.InputSchema.Obj(
                    properties = buildJsonObject { },
                    required = emptyList(),
                )
            },
            execute = { emptyList() },
        )
        val params = TextGenerationParams(
            model = reasoningModel(),
            tools = listOf(tool),
        )
        val msgs = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("weather?"))))

        val body = provider.callBuildMessageRequest(claudeSetting, msgs, params)
        val tools = body["tools"]!!.jsonArray
        assertEquals(1, tools.size)
        val toolObj = tools[0].jsonObject
        assertEquals("get_weather", toolObj["name"]!!.jsonPrimitive.content)
        assertEquals("Get the weather", toolObj["description"]!!.jsonPrimitive.content)
        assertNotNull(toolObj["input_schema"])
        // cache_control is NOT present when promptCaching=false
        assertNull(toolObj["cache_control"])
    }

    @Test
    fun `tools disable parallel tool use`() {
        val tool = Tool(
            name = "get_weather",
            description = "Get the weather",
            parameters = {
                app.amber.ai.core.InputSchema.Obj(
                    properties = buildJsonObject { },
                    required = emptyList(),
                )
            },
            execute = { emptyList() },
        )
        val params = TextGenerationParams(model = reasoningModel(), tools = listOf(tool))
        val msgs = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("weather?"))))

        val body = provider.callBuildMessageRequest(claudeSetting, msgs, params)
        val toolChoice = body.getValue("tool_choice").jsonObject

        assertTrue(toolChoice.getValue("disable_parallel_tool_use").jsonPrimitive.boolean)
    }

    @Test
    fun `promptCaching on adds cache_control to the last tool`() {
        val cachingSetting = claudeSetting.copy(promptCaching = true)
        val tool = Tool(
            name = "t",
            description = "d",
            parameters = {
                app.amber.ai.core.InputSchema.Obj(
                    properties = buildJsonObject { },
                    required = emptyList(),
                )
            },
            execute = { emptyList() },
        )
        val params = TextGenerationParams(model = reasoningModel(), tools = listOf(tool))
        val msgs = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("x"))))

        val body = provider.callBuildMessageRequest(cachingSetting, msgs, params)
        val toolObj = body["tools"]!!.jsonArray[0].jsonObject
        val cache = toolObj["cache_control"]
        assertNotNull(cache)
        assertEquals("ephemeral", cache.jsonObject.getValue("type").jsonPrimitive.content)
    }
}

// Test-visible trampoline: buildMessageRequest is internal to the module but
// jvmTest is a separate source set that can see internal members (same module).
private fun ClaudeKmpProvider.callBuildMessageRequest(
    setting: ProviderSetting.Claude,
    messages: List<UIMessage>,
    params: TextGenerationParams,
    stream: Boolean = false,
): JsonObject = this.buildMessageRequest(setting, messages, params, stream)
