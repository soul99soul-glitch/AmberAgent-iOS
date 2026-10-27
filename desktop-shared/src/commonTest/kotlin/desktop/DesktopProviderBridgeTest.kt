package desktop

import app.amber.ai.provider.ProviderSetting
import app.amber.ai.core.MessageRole
import app.amber.ai.core.InputSchema
import kotlinx.coroutines.runBlocking
import app.amber.core.agent.utils.JsonInstant
import kotlinx.serialization.encodeToString
import kotlin.uuid.Uuid
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.provider.GoogleAuthMode
import app.amber.ai.provider.OpenAIAuthMode

class DesktopProviderBridgeTest {
    @Test
    fun modelOverridesPreserveTypedBodyHeadersAndExplicitImageCapability() {
        val params = DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"private-model","supportsVision":true,"customHeaders":{"X-Project":"amber"},"customBody":"{\"seed\":7,\"enabled\":true,\"options\":{\"mode\":\"fast\"}}"}""")
        assertEquals(listOf(CustomHeader("X-Project", "amber")), params.customHeaders)
        assertEquals("7", params.customBody.single { it.key == "seed" }.value.toString())
        assertEquals("true", params.customBody.single { it.key == "enabled" }.value.toString())
        assertEquals("fast", params.customBody.single { it.key == "options" }.value.jsonObject.getValue("mode").jsonPrimitive.content)
        assertTrue(app.amber.ai.provider.Modality.IMAGE in params.model.inputModalities)
        val textOnly = DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"gpt-4o","supportsVision":false}""")
        assertTrue(app.amber.ai.provider.Modality.IMAGE !in textOnly.model.inputModalities)
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"x","customHeaders":{"X-Test":"a\r\nAuthorization: x"}}""")
        }
        assertFailsWith<IllegalStateException> {
            DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"x","customBody":"[]"}""")
        }
    }

    @Test
    fun nativeSearchConfigurationUsesOriginalSettingsAndServiceSerializers() {
        val settings = DesktopProviderBridge.searchSettings("""{"searchServices":[{"type":"tavily","id":"$id","apiKey":"fixture-key"}],"searchEnabledServiceIds":["$id"],"searchServiceSelected":0,"searchCommonOptions":{"resultSize":4},"searchGoogleWebViewFallbackEnabled":false}""")
        assertEquals(4, settings.searchCommonOptions.resultSize)
        val service = settings.searchServices.single() as app.amber.search.SearchServiceOptions.TavilyOptions
        assertEquals("fixture-key", service.apiKey)
        assertEquals(listOf(Uuid.parse(id)), settings.searchEnabledServiceIds)
        assertTrue(!settings.searchGoogleWebViewFallbackEnabled)
    }

    @Test
    fun newAgentRequestCannotReplayAnUnconfirmedHistoricalToolOrMutateCanonicalHistory() {
        val pending = app.amber.ai.ui.UIMessagePart.Tool("unknown-from-old-run", "mcp_call_tool", """{"name":"mutate"}""",
            metadata = kotlinx.serialization.json.JsonObject(mapOf("kept" to kotlinx.serialization.json.JsonPrimitive(true))))
        val completed = pending.copy(toolCallId = "completed", output = listOf(app.amber.ai.ui.UIMessagePart.Text("actual confirmed output")))
        val message = canonicalConversationFixture().currentMessages.last().copy(parts = listOf(pending, completed))
        val canonicalBefore = DesktopProviderBridge.projectMessages(listOf(message))
        val request = DesktopProviderBridge.agentRequestHistory(listOf(message))
        val tools = request.single().parts.filterIsInstance<app.amber.ai.ui.UIMessagePart.Tool>()
        assertTrue(tools.all { it.isExecuted })
        assertTrue(tools.first().output.single() is app.amber.ai.ui.UIMessagePart.Text)
        val marker = Json.parseToJsonElement((tools.first().output.single() as app.amber.ai.ui.UIMessagePart.Text).text).jsonObject
        assertEquals("not_resumed", marker.getValue("status").jsonPrimitive.content)
        assertEquals(pending.toolCallId, marker.getValue("tool_call_id").jsonPrimitive.content)
        assertEquals(pending.copy(output = tools.first().output), tools.first())
        assertEquals(completed, tools.last())
        assertEquals(message.id, request.single().id)
        assertEquals(message.usage, request.single().usage)
        assertTrue(pending.output.isEmpty())
        assertEquals(canonicalBefore, DesktopProviderBridge.projectMessages(listOf(message)))
        assertEquals(request, DesktopProviderBridge.agentRequestHistory(request))
    }

    @Test
    fun recipeInvocationIsARealTypedToolCallWithoutInventedResult() {
        val message = DesktopProviderBridge.toolInvocation("recipe-stable-call", "workspace_write", """{"path":"note.txt","text":"content"}""")
        assertEquals(MessageRole.ASSISTANT, message.role)
        val tool = message.parts.single() as app.amber.ai.ui.UIMessagePart.Tool
        assertEquals("recipe-stable-call", tool.toolCallId)
        assertEquals("workspace_write", tool.toolName)
        assertTrue(tool.output.isEmpty())
        assertEquals(message, DesktopProviderBridge.messages(DesktopProviderBridge.projectMessages(listOf(message))).single())
        assertFailsWith<IllegalArgumentException> { DesktopProviderBridge.toolInvocation("", "tool", "{}") }
        assertFailsWith<IllegalArgumentException> { DesktopProviderBridge.toolInvocation("call", "tool", "[]") }
    }

    @Test
    fun nativeToolDeclarationsPreserveSchemaAndApprovalAndCannotFakeExecution(): Unit = runBlocking {
        val declaration = DesktopProviderBridge.declarations("""[{"name":"read_file","description":"Read an allowed file","needsApproval":true,"parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}]""").single()
        assertEquals("read_file", declaration.name)
        assertEquals("Read an allowed file", declaration.description)
        val schema = declaration.parameters() as InputSchema.Obj
        assertEquals(listOf("path"), schema.required)
        assertEquals(false, schema.additionalProperties)
        assertEquals("string", schema.properties.getValue("path").jsonObject.getValue("type").jsonPrimitive.content)
        assertTrue(declaration.needsApproval)
        assertTrue(!declaration.allowsAutoApproval)
        assertFailsWith<IllegalStateException> { declaration.execute(kotlinx.serialization.json.JsonObject(emptyMap())) }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.declarations("""[{"name":"same","description":"a","parameters":{"type":"object","properties":{}}},{"name":"same","description":"b","parameters":{"type":"object","properties":{}}}]""")
        }
    }

    @Test
    fun completeAgentProjectionKeepsEveryOriginalMessageIdentityAndCanonicalParts() {
        val messages = canonicalConversationFixture().currentMessages
        val projection = DesktopProviderBridge.projectMessages(messages)
        assertEquals(messages, DesktopProviderBridge.messages(projection))
        assertEquals(messages.map { it.id.toString() }, Json.decodeFromString<List<DesktopMessage>>(projection).map { it.id })
    }

    @Test
    fun attachmentsBuildOrderedOriginalMessagePartsAndSurviveProviderAndStorageProjection() {
        val image = "data:image/png;base64,aGVsbG8="
        val attachmentJSON = """[{"name":"photo.png","mimeType":"image/png","kind":"image","dataURL":"$image"},{"name":"notes.txt","mimeType":"text/plain","kind":"text","text":"reference text"}]"""
        val envelope = Json.decodeFromString<DesktopMessage>(DesktopProviderBridge.userMessage(id, "question", attachmentJSON))
        val original = envelope.toMessage()
        assertEquals(MessageRole.USER, original.role)
        assertEquals(listOf(app.amber.ai.ui.UIMessagePart.Text::class, app.amber.ai.ui.UIMessagePart.Image::class,
            app.amber.ai.ui.UIMessagePart.Text::class), original.parts.map { it::class })
        assertEquals(image, (original.parts[1] as app.amber.ai.ui.UIMessagePart.Image).url)
        assertEquals("photo.png", original.parts[1].metadata!!.getValue("fileName").jsonPrimitive.content)
        assertTrue((original.parts.last() as app.amber.ai.ui.UIMessagePart.Text).text.contains("notes.txt"))
        assertEquals(original, DesktopProviderBridge.messages(Json.encodeToString(listOf(envelope))).single())
        assertEquals(0, envelope.unsupportedPartCount)
        assertEquals(listOf(DesktopMessageImage(image, "photo.png")), envelope.images)
        assertTrue(envelope.estimatedTokens!! > 0)
    }

    @Test
    fun attachmentBoundaryRejectsEmptyUnsupportedAndNonInlineImages() {
        assertFailsWith<IllegalArgumentException> { DesktopProviderBridge.userMessage(id, " ", "[]") }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.userMessage(id, "", """[{"name":"x","mimeType":"image/png","kind":"image","dataURL":"file:///tmp/x.png"}]""")
        }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.userMessage(id, "", """[{"name":"x","mimeType":"text/plain","kind":"text","text":""}]""")
        }
        assertFailsWith<IllegalStateException> {
            DesktopProviderBridge.userMessage(id, "", """[{"name":"x","mimeType":"application/octet-stream","kind":"binary"}]""")
        }
    }

    private val id = "12345678-1234-1234-1234-123456789abc"

    @Test
    fun modelOptionsReachStableIdentityCapabilitiesAndWireParameters() {
        val params = DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"claude-test","name":"Private model","contextWindowTokens":12345,"temperature":0.4,"maxOutputTokens":2048,"reasoning":"high"}""")
        assertEquals(Uuid.parse(id), params.model.id)
        assertEquals("claude-test", params.model.modelId)
        assertEquals("Private model", params.model.displayName)
        assertEquals(12345, params.model.contextWindowTokens)
        assertEquals(0.4f, params.temperature)
        assertEquals(2048, params.maxTokens)
        assertEquals(ReasoningLevel.HIGH, params.reasoningLevel)
        assertTrue(ModelAbility.REASONING in params.model.abilities)
        assertTrue(ModelAbility.TOOL in params.model.abilities)
        val known = DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"gpt-4o","reasoning":"off"}""")
        assertTrue(ModelAbility.TOOL in known.model.abilities)
        assertTrue(known.model.contextWindowTokens!! > 0)
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"test","enabled":false}""")
        }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"test","temperature":3}""")
        }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.paramsFromJSON("""{"id":"$id","modelID":"test","maxOutputTokens":0}""")
        }
    }

    @Test
    fun catalogProjectionPreservesWireNamesAndRemovesDuplicateIds() {
        val result = Json.parseToJsonElement(DesktopProviderBridge.catalogJSON(listOf(
            Model(modelId = "test", displayName = "Named", contextWindowTokens = 8000),
            Model(modelId = "test", displayName = "Duplicate"),
        ))).jsonArray.single().jsonObject
        assertEquals("test", result.getValue("modelID").jsonPrimitive.content)
        assertEquals("Named", result.getValue("name").jsonPrimitive.content)
        assertEquals("8000", result.getValue("contextWindowTokens").jsonPrimitive.content)
    }

    @Test
    fun googleAndCodexUseExplicitAuthAndRequiredHeadersWithoutDiscardingOverrides() {
        val google = DesktopProviderBridge.configurationWithAuth("gemini", id, "Gemini", "https://example.com/v1beta", "key", "antigravityOAuth")
        assertTrue(google is ProviderSetting.Google)
        assertEquals(GoogleAuthMode.ANTIGRAVITY_OAUTH, google.authMode)
        val codex = DesktopProviderBridge.configurationWithAuth("responses", id, "Codex", "https://example.com", "token", "codexOAuth")
        assertTrue(codex is ProviderSetting.OpenAI)
        assertEquals(OpenAIAuthMode.CODEX_OAUTH, codex.authMode)
        assertTrue(codex.useResponseApi)
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.configurationWithAuth("claude", id, "Claude", "https://example.com", "key", "codexOAuth")
        }
        val original = TextGenerationParams(Model(modelId = "test"), customHeaders = listOf(
            CustomHeader("openai-beta", "old"), CustomHeader("X-Custom", "keep")))
        val updated = DesktopProviderBridge.withCodexHeaders(original, "account", "same-as-native-client")
        assertEquals(4, updated.customHeaders.size)
        assertEquals("keep", updated.customHeaders.first { it.name == "X-Custom" }.value)
        assertEquals("responses=experimental", updated.customHeaders.first { it.name == "OpenAI-Beta" }.value)
        assertEquals("same-as-native-client", updated.customHeaders.first { it.name == "originator" }.value)
        assertEquals("account", updated.customHeaders.first { it.name == "ChatGPT-Account-Id" }.value)
    }

    @Test
    fun providerProtocolAndModelReachRealKmpConfiguration() {
        val openAI = DesktopProviderBridge.configuration("responses", id, "Compatible", " https://example.com/v1/ ", "private")
        assertTrue(openAI is ProviderSetting.OpenAI)
        assertTrue(openAI.useResponseApi)
        assertEquals("https://example.com/v1", openAI.baseUrl)
        assertEquals("private", openAI.apiKey)
        assertTrue(DesktopProviderBridge.configuration("claude", id, "Claude", "https://example.com/v1", "key") is ProviderSetting.Claude)
        assertEquals("my-model", DesktopProviderBridge.params("my-model").model.modelId)
        assertFailsWith<IllegalStateException> { DesktopProviderBridge.configuration("invalid", id, "", "", "") }
    }

    @Test
    fun messageProjectionRetainsIdentityReasoningAndPartialTerminal() {
        val json = """[{"id":"$id","role":"assistant","text":"partial text","reasoning":"thought","state":"cancelled"}]"""
        val messages = DesktopProviderBridge.messages(json)
        val projected = Json.parseToJsonElement(DesktopProviderBridge.snapshot(messages)).jsonArray.single().jsonObject
        assertEquals(id, projected.getValue("id").jsonPrimitive.content)
        assertEquals("partial text", projected.getValue("text").jsonPrimitive.content)
        assertEquals("thought", projected.getValue("reasoning").jsonPrimitive.content)
        assertEquals("cancelled", projected.getValue("state").jsonPrimitive.content)
    }

    @Test
    fun invalidRolesAndMalformedIDsAreCatchableAtJsonBoundary() {
        assertFailsWith<IllegalStateException> {
            DesktopProviderBridge.messages("""[{"id":"$id","role":"unknown"}]""")
        }
        assertFailsWith<IllegalArgumentException> {
            DesktopProviderBridge.messages("""[{"id":"not-a-uuid","role":"user"}]""")
        }
    }

    @Test
    fun canonicalMessageSnapshotPreservesOrderedPartsAndCompleteMessageFields() {
        val original = canonicalConversationFixture().currentMessages.last()
        val snapshot = DesktopProviderBridge.snapshot(listOf(original))
        val returned = DesktopProviderBridge.messages(snapshot).single()
        assertEquals(original, returned)
        assertEquals(2, Json.parseToJsonElement(snapshot).jsonArray.single().jsonObject.getValue("unsupportedPartCount").jsonPrimitive.content.toInt())
        assertEquals(original.parts.map { it::class }, returned.parts.map { it::class })
        val projection = Json.parseToJsonElement(snapshot).jsonArray.single().jsonObject
        assertEquals(original, JsonInstant.decodeFromString(projection.getValue("canonicalJSON").jsonPrimitive.content))
    }

    @Test
    fun stableAssistantIdentityChangesBothProjectionAndCanonicalPayload() {
        val original = canonicalConversationFixture().currentMessages.last()
        val stableID = "90000000-0000-4000-8000-000000000009"
        val snapshot = DesktopProviderBridge.snapshot(listOf(original), stableID)
        val returned = DesktopProviderBridge.messages(snapshot).single()
        assertEquals(original.copy(id = Uuid.parse(stableID)), returned)
        val projection = Json.parseToJsonElement(snapshot).jsonArray.single().jsonObject
        assertEquals(stableID, projection.getValue("id").jsonPrimitive.content)
        assertFailsWith<IllegalArgumentException> { DesktopProviderBridge.snapshot(listOf(original), "invalid") }
    }

    @Test
    fun terminalStateMergesMetadataWithoutFlatteningMixedParts() {
        val original = canonicalConversationFixture().currentMessages.last()
        val projection = DesktopMessage.from(original).copy(state = "cancelled")
        val returned = DesktopProviderBridge.messages(Json.encodeToString(listOf(projection))).single()
        assertEquals(original.id, returned.id)
        assertEquals(original.parts.drop(1), returned.parts.drop(1))
        val originalText = original.parts.first() as app.amber.ai.ui.UIMessagePart.Text
        val returnedText = returned.parts.first() as app.amber.ai.ui.UIMessagePart.Text
        assertEquals(originalText.text, returnedText.text)
        assertEquals(originalText.metadata, kotlinx.serialization.json.JsonObject(returnedText.metadata!!.filterKeys { it != "desktopState" }))
        assertEquals("cancelled", returnedText.metadata!!.getValue("desktopState").jsonPrimitive.content)
        assertEquals(original.annotations, returned.annotations)
        assertEquals(original.usage, returned.usage)
    }

    @Test
    fun canonicalToolRoleReturnsToProviderWithoutTextReconstruction() {
        val original = canonicalConversationFixture().currentMessages.last().copy(role = MessageRole.TOOL)
        assertEquals(original, DesktopProviderBridge.messages(DesktopProviderBridge.snapshot(listOf(original))).single())
    }

}

class DesktopCodingPlanBridgeTest {
    @kotlin.test.Test
    fun codingPlanModesPinVendorEndpointAndPlanMode() {
        val plan = desktopAuthenticatedConfiguration("openai", "00000000-0000-0000-0000-000000000001", "GLM",
            "https://example.com/v1", "key", "zhipuCodingPlan") as app.amber.ai.provider.ProviderSetting.OpenAI
        kotlin.test.assertEquals(app.amber.ai.provider.OpenAIAuthMode.ZHIPU_CODING_PLAN, plan.authMode)
        kotlin.test.assertEquals("https://open.bigmodel.cn/api/coding/paas/v4", plan.baseUrl)
        kotlin.test.assertFailsWith<IllegalArgumentException> {
            desktopAuthenticatedConfiguration("claude", "00000000-0000-0000-0000-000000000002", "x", "https://a.b/v1", "k", "kimiCodingPlan")
        }
    }
}
