package app.amber.ai.provider.claude

import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptToolDeclaration
import app.amber.ai.core.PromptTranscript
import app.amber.ai.core.PromptTranscriptEvent
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.core.Tool
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.ai.ui.MessageStreamAccumulator
import kotlinx.serialization.json.Json
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
import kotlinx.serialization.json.put
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

    private fun nativeModel(): Model = Model(
        modelId = "claude-opus-5",
        displayName = "Claude Opus 5",
        abilities = listOf(ModelAbility.REASONING, ModelAbility.TOOL),
    )

    private fun promptTool(name: String, description: String): PromptToolDeclaration = PromptToolDeclaration(
        name = name,
        description = description,
        parameters = app.amber.ai.core.InputSchema.Obj(
            properties = buildJsonObject {},
            required = emptyList(),
        ),
    )

    private fun executableTool(declaration: PromptToolDeclaration): Tool = Tool(
        name = declaration.name,
        description = declaration.description,
        parameters = { declaration.parameters },
        execute = { emptyList() },
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
    fun `redacted thinking survives stream accumulation and tool result replay`() {
        val accumulator = MessageStreamAccumulator(listOf(UIMessage.user("look up the answer")))
        val blocks = listOf(
            """{"type":"thinking","thinking":"Check the source","signature":"sig-visible"}""",
            """{"type":"redacted_thinking","data":"encrypted-redacted"}""",
            """{"type":"tool_use","id":"tool-1","name":"lookup","input":{"query":"answer"}}""",
        )
        blocks.forEachIndexed { index, block ->
            provider.parseStreamEvent(
                id = "msg-1",
                type = "content_block_start",
                data = """{"index":$index,"content_block":$block}""",
            )?.let(accumulator::append)
        }
        val snapshot = accumulator.snapshot()
        val assistant = snapshot.last()
        assertEquals(3, assistant.parts.size)
        assertEquals("Check the source", (assistant.parts.first() as UIMessagePart.Reasoning).reasoning)
        val replay = assistant.copy(parts = assistant.parts.map {
            if (it is UIMessagePart.Tool) it.copy(output = listOf(UIMessagePart.Text("found"))) else it
        })
        val request = provider.callBuildMessageRequest(
            claudeSetting, snapshot.dropLast(1) + replay, TextGenerationParams(model = reasoningModel()),
        )
        val messages = request["messages"]!!.jsonArray
        val assistantBlocks = messages[1].jsonObject["content"]!!.jsonArray
        assertEquals(blocks.map { Json.parseToJsonElement(it) }, assistantBlocks.toList())
        val result = messages[2].jsonObject["content"]!!.jsonArray.single().jsonObject
        assertEquals("tool-1", result["tool_use_id"]!!.jsonPrimitive.content)
    }

    @Test
    fun `two redacted thinking blocks retain their order and encrypted data`() {
        val accumulator = MessageStreamAccumulator(listOf(UIMessage.user("continue")))
        val blocks = listOf(
            """{"type":"redacted_thinking","data":"encrypted-first"}""",
            """{"type":"redacted_thinking","data":"encrypted-second"}""",
        )
        blocks.forEachIndexed { index, block ->
            provider.parseStreamEvent(
                id = "msg-1", type = "content_block_start",
                data = """{"index":$index,"content_block":$block}""",
            )?.let(accumulator::append)
        }
        val messages = accumulator.snapshot()
        assertEquals(2, messages.last().parts.size)
        val request = provider.callBuildMessageRequest(
            claudeSetting, messages, TextGenerationParams(model = reasoningModel()),
        )
        val replayed = request["messages"]!!.jsonArray[1].jsonObject["content"]!!.jsonArray
        assertEquals(blocks.map { Json.parseToJsonElement(it) }, replayed.toList())
    }

    @Test
    fun `empty thinking with signature survives snapshot and request replay`() {
        val accumulator = MessageStreamAccumulator(listOf(UIMessage.user("continue")))
        val chunk = provider.parseStreamEvent(
            id = "msg-1", type = "content_block_delta",
            data = """{"index":0,"delta":{"type":"signature_delta","signature":"sig-empty"}}""",
        )
        accumulator.append(assertNotNull(chunk))
        val messages = accumulator.snapshot()
        val reasoning = messages.last().parts.filterIsInstance<UIMessagePart.Reasoning>().single()
        assertEquals("", reasoning.reasoning)
        val request = provider.callBuildMessageRequest(
            claudeSetting, messages, TextGenerationParams(model = reasoningModel()),
        )
        val replayed = request["messages"]!!.jsonArray[1].jsonObject["content"]!!.jsonArray.single()
        assertEquals(
            Json.parseToJsonElement("""{"type":"thinking","thinking":"","signature":"sig-empty"}"""),
            replayed,
        )
    }

    @Test
    fun `thinking and signature deltas merge within their original block only`() {
        val accumulator = MessageStreamAccumulator(listOf(UIMessage.user("continue")))
        val events = listOf(
            "content_block_start" to """{"index":0,"content_block":{"type":"thinking","thinking":""}}""",
            "content_block_delta" to """{"index":0,"delta":{"type":"thinking_delta","thinking":"first"}}""",
            "content_block_delta" to """{"index":0,"delta":{"type":"signature_delta","signature":"sig-first"}}""",
            "content_block_start" to """{"index":1,"content_block":{"type":"thinking","thinking":""}}""",
            "content_block_delta" to """{"index":1,"delta":{"type":"thinking_delta","thinking":"second"}}""",
            "content_block_delta" to """{"index":1,"delta":{"type":"signature_delta","signature":"sig-second"}}""",
        )
        events.forEach { (type, data) ->
            provider.parseStreamEvent(id = "msg-1", type = type, data = data)?.let(accumulator::append)
        }
        val messages = accumulator.snapshot()
        val reasoning = messages.last().parts.filterIsInstance<UIMessagePart.Reasoning>()
        assertEquals(listOf("first", "second"), reasoning.map { it.reasoning })
        val request = provider.callBuildMessageRequest(
            claudeSetting, messages, TextGenerationParams(model = reasoningModel()),
        )
        val replayed = request["messages"]!!.jsonArray[1].jsonObject["content"]!!.jsonArray
        assertEquals(listOf(
            Json.parseToJsonElement("""{"type":"thinking","thinking":"first","signature":"sig-first"}"""),
            Json.parseToJsonElement("""{"type":"thinking","thinking":"second","signature":"sig-second"}"""),
        ), replayed.toList())
    }

    @Test
    fun `foreign empty encrypted reasoning is omitted without changing transcript tool replay`() {
        val foreign = UIMessagePart.Reasoning(reasoning = "", metadata = buildJsonObject {
            put("reasoning_id", "rs-foreign")
            put("encrypted_content", "openai-encrypted")
        })
        val tool = executableTool(promptTool("lookup", "Look up the answer"))
        val history = listOf(UIMessage.user("look up"), UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                foreign,
                UIMessagePart.Text("before"),
                UIMessagePart.Tool(
                    toolCallId = "call-original", toolName = "lookup", input = "{}",
                    output = listOf(UIMessagePart.Text("found")),
                ),
                UIMessagePart.Text("after"),
            ),
        ))
        val originalParts = history.last().parts.toList()
        val originalMetadata = foreign.metadata
        val prepared = PromptTranscript.prepare(history, history, listOf(tool))
        val resolved = PromptTranscript.resolve(prepared.messages, listOf(tool), nativeSystem = true)
        assertTrue(resolved.hasTranscript)
        val body = provider.callBuildMessageRequest(
            claudeSetting, resolved.messages, TextGenerationParams(model = nativeModel(), tools = listOf(tool)),
        )

        assertEquals(Json.parseToJsonElement("""[
            {"role":"user","content":[{"type":"text","text":"look up"}]},
            {"role":"assistant","content":[{"type":"text","text":"before"},{"type":"tool_use","id":"call-original","name":"lookup","input":{}}]},
            {"role":"user","content":[{"type":"tool_result","tool_use_id":"call-original","content":[{"type":"text","text":"found"}]}]},
            {"role":"assistant","content":[{"type":"text","text":"after"}]}
        ]"""), body["messages"])
        assertEquals(originalParts, history.last().parts)
        assertEquals(originalMetadata, foreign.metadata)
        assertTrue(history.last().parts.first() === foreign)
    }

    @Test
    fun `foreign encrypted only assistant does not create an empty Claude turn`() {
        val foreign = UIMessagePart.Reasoning(reasoning = "", metadata = buildJsonObject {
            put("reasoning_id", "rs-foreign")
            put("encrypted_content", "openai-encrypted")
        })
        val history = listOf(UIMessage.user("continue"), UIMessage(
            role = MessageRole.ASSISTANT, parts = listOf(foreign),
        ))
        val prepared = PromptTranscript.prepare(history, history, emptyList())
        val resolved = PromptTranscript.resolve(prepared.messages, emptyList(), nativeSystem = true)
        val body = provider.callBuildMessageRequest(
            claudeSetting, resolved.messages, TextGenerationParams(model = nativeModel()),
        )

        assertEquals(1, body["messages"]!!.jsonArray.size)
        assertEquals("user", body["messages"]!!.jsonArray.single().jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals(listOf(foreign), history.last().parts)
        assertEquals("openai-encrypted", foreign.metadata!!["encrypted_content"]!!.jsonPrimitive.content)
    }

    @Test
    fun `transcript keeps native opaque blocks and signed nonempty reasoning replay`() {
        val signed = UIMessagePart.Reasoning(reasoning = "", metadata = buildJsonObject {
            put("signature", "claude-signature")
        })
        val redactedBlock = Json.parseToJsonElement(
            """{"type":"redacted_thinking","data":"claude-redacted"}""",
        ).jsonObject
        val redacted = UIMessagePart.Reasoning(reasoning = "", metadata = buildJsonObject {
            put("claude_redacted_thinking", redactedBlock)
        })
        val readable = UIMessagePart.Reasoning(reasoning = "existing readable thought", metadata = buildJsonObject {
            put("signature", "claude-readable-signature")
        })
        val history = listOf(UIMessage.user("continue"), UIMessage(
            role = MessageRole.ASSISTANT, parts = listOf(signed, redacted, readable),
        ))
        val prepared = PromptTranscript.prepare(history, history, emptyList())
        val resolved = PromptTranscript.resolve(prepared.messages, emptyList(), nativeSystem = true)
        val body = provider.callBuildMessageRequest(
            claudeSetting, resolved.messages, TextGenerationParams(model = nativeModel()),
        )

        assertEquals(Json.parseToJsonElement("""[
            {"type":"thinking","thinking":"","signature":"claude-signature"},
            {"type":"redacted_thinking","data":"claude-redacted"},
            {"type":"thinking","thinking":"existing readable thought","signature":"claude-readable-signature"}
        ]"""), body["messages"]!!.jsonArray[1].jsonObject["content"])
        assertEquals(listOf(signed, redacted, readable), history.last().parts)
    }

    @Test
    fun `plain unsigned reasoning is omitted from Claude transcript without changing canonical history`() {
        assertUnsignedReasoningOmitted(UIMessagePart.Reasoning(reasoning = "plain unsigned thought"))
    }

    @Test
    fun `foreign nonempty encrypted reasoning is omitted from Claude transcript without changing canonical history`() {
        assertUnsignedReasoningOmitted(UIMessagePart.Reasoning(
            reasoning = "foreign visible reasoning", metadata = buildJsonObject {
                put("reasoning_id", "rs-foreign")
                put("encrypted_content", "openai-encrypted")
            },
        ))
    }

    private fun assertUnsignedReasoningOmitted(reasoning: UIMessagePart.Reasoning) {
        val tool = executableTool(promptTool("lookup", "Look up the answer"))
        val history = listOf(UIMessage.user("look up"), UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                UIMessagePart.Text("before"), reasoning,
                UIMessagePart.Tool(
                    toolCallId = "call-original", toolName = "lookup", input = "{}",
                    output = listOf(UIMessagePart.Text("found")),
                ),
                UIMessagePart.Text("after"),
            ),
        ))
        val originalParts = history.last().parts.toList()
        val originalMetadata = reasoning.metadata
        val prepared = PromptTranscript.prepare(history, history, listOf(tool))
        val resolved = PromptTranscript.resolve(prepared.messages, listOf(tool), nativeSystem = true)
        val body = provider.callBuildMessageRequest(
            claudeSetting, resolved.messages, TextGenerationParams(model = nativeModel(), tools = listOf(tool)),
        )
        assertEquals(Json.parseToJsonElement("""[
            {"role":"user","content":[{"type":"text","text":"look up"}]},
            {"role":"assistant","content":[{"type":"text","text":"before"},{"type":"tool_use","id":"call-original","name":"lookup","input":{}}]},
            {"role":"user","content":[{"type":"tool_result","tool_use_id":"call-original","content":[{"type":"text","text":"found"}]}]},
            {"role":"assistant","content":[{"type":"text","text":"after"}]}
        ]"""), body["messages"])
        assertEquals(originalParts, history.last().parts)
        assertEquals(originalMetadata, reasoning.metadata)
        assertTrue(history.last().parts[1] === reasoning)
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

    @Test
    fun `native transcript keeps prefix and emits deferred tool changes in place`() {
        val initialTool = promptTool("read_file", "Read a file")
        val lateTool = promptTool("write_file", "Write a file")
        val initial = PromptTranscript.message(
            PromptTranscriptEvent(
                initial = true,
                sections = mapOf("rules" to "base rules"),
                toolsAdded = listOf(initialTool),
            ),
        )
        val update = PromptTranscript.message(
            PromptTranscriptEvent(
                sections = mapOf("mode" to "strict mode"),
                toolsAdded = listOf(lateTool),
                toolsRemoved = listOf(initialTool.name),
            ),
        )
        val body = provider.callBuildMessageRequest(
            claudeSetting.copy(promptCaching = true),
            listOf(
                initial,
                UIMessage.user("start"),
                UIMessage.assistant("first answer"),
                UIMessage.user("continue"),
                update,
                UIMessage.assistant("second answer"),
            ),
            TextGenerationParams(
                model = nativeModel(),
                tools = listOf(executableTool(lateTool)),
            ),
        )

        val system = body["system"]!!.jsonArray
        assertEquals(1, system.size)
        assertTrue(system.single().jsonObject["text"]!!.jsonPrimitive.content.contains("base rules"))
        assertEquals(
            "ephemeral",
            system.single().jsonObject["cache_control"]!!.jsonObject["type"]!!.jsonPrimitive.content,
        )

        val tools = body["tools"]!!.jsonArray
        assertEquals(listOf("read_file", "__amber_deferred_placeholder__", "write_file"), tools.map {
            it.jsonObject["name"]!!.jsonPrimitive.content
        })
        assertEquals("ephemeral", tools[0].jsonObject["cache_control"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertTrue(tools[1].jsonObject["defer_loading"]!!.jsonPrimitive.boolean)
        assertTrue(tools[2].jsonObject["defer_loading"]!!.jsonPrimitive.boolean)
        assertNull(tools[2].jsonObject["cache_control"])

        val messages = body["messages"]!!.jsonArray
        assertEquals(listOf("user", "assistant", "user", "system", "assistant"), messages.map {
            it.jsonObject["role"]!!.jsonPrimitive.content
        })
        val updateContent = messages[3].jsonObject["content"]!!.jsonArray
        assertEquals("tool_removal", updateContent[1].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("tool_addition", updateContent[2].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("read_file", updateContent[1].jsonObject["tool"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals("write_file", updateContent[2].jsonObject["tool"]!!.jsonObject["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `native transcript falls back to current tools for schema redefinition`() {
        val oldTool = promptTool("lookup", "Old lookup")
        val newTool = promptTool("lookup", "New lookup")
        val body = provider.callBuildMessageRequest(
            claudeSetting,
            listOf(
                PromptTranscript.message(
                    PromptTranscriptEvent(
                        initial = true,
                        sections = mapOf("rules" to "base rules"),
                        toolsAdded = listOf(oldTool),
                    ),
                ),
                UIMessage.user("start"),
                PromptTranscript.message(
                    PromptTranscriptEvent(
                        sections = mapOf("mode" to "strict mode"),
                        toolsAdded = listOf(newTool),
                    ),
                ),
                UIMessage.assistant("answer"),
            ),
            TextGenerationParams(model = nativeModel(), tools = listOf(executableTool(newTool))),
        )

        val tools = body["tools"]!!.jsonArray
        assertEquals(1, tools.size)
        assertEquals("lookup", tools.single().jsonObject["name"]!!.jsonPrimitive.content)
        assertNull(tools.single().jsonObject["defer_loading"])
        assertNull(tools.single().jsonObject["cache_control"])
        val update = body["messages"]!!.jsonArray.first { it.jsonObject["role"]!!.jsonPrimitive.content == "system" }
        assertEquals(1, update.jsonObject["content"]!!.jsonArray.size)
        assertEquals("text", update.jsonObject["content"]!!.jsonArray.single().jsonObject["type"]!!.jsonPrimitive.content)
    }

    @Test
    fun `non Anthropic endpoint collapses transcript and sends current tools`() {
        val oldTool = promptTool("lookup", "Old lookup")
        val newTool = promptTool("write", "Write")
        val body = provider.callBuildMessageRequest(
            claudeSetting.copy(baseUrl = "https://proxy.example/v1"),
            listOf(
                PromptTranscript.message(
                    PromptTranscriptEvent(
                        initial = true,
                        sections = mapOf("rules" to "base rules"),
                        toolsAdded = listOf(oldTool),
                    ),
                ),
                UIMessage.user("start"),
                PromptTranscript.message(PromptTranscriptEvent(sections = mapOf("mode" to "strict mode"))),
                UIMessage.assistant("answer"),
            ),
            TextGenerationParams(model = nativeModel(), tools = listOf(executableTool(newTool))),
        )

        assertEquals(1, body["system"]!!.jsonArray.size)
        assertTrue(body["system"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content.contains("strict mode"))
        assertTrue(body["messages"]!!.jsonArray.none {
            it.jsonObject["role"]?.jsonPrimitive?.content == "system"
        })
        assertEquals("write", body["tools"]!!.jsonArray.single().jsonObject["name"]!!.jsonPrimitive.content)
        assertNull(body["tools"]!!.jsonArray.single().jsonObject["defer_loading"])
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
