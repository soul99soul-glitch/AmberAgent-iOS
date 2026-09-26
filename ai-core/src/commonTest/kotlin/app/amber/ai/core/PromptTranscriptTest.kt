package app.amber.ai.core

import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.ai.util.json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PromptTranscriptTest {
    private fun tool(name: String, description: String = name) = Tool(name, description, execute = { emptyList() })
    private fun user(text: String) = UIMessage.user(text)
    private fun assistant(text: String) = UIMessage(role = MessageRole.ASSISTANT, parts = listOf(UIMessagePart.Text(text)))
    private fun prompt(text: String) = PromptTranscript.sectionMessage("rules", text)
    private fun wireText(messages: List<UIMessage>) = messages.map { it.toText() }

    @Test
    fun unchangedRoundKeepsPrefixAndAddsNoEventAfterJsonRestore() {
        val firstUser = user("hello")
        val first = PromptTranscript.prepare(listOf(firstUser), listOf(prompt("A"), firstUser), listOf(tool("read")))
        val reply = PromptTranscript.recordResponse(assistant("hi"), first)
        val restored = json.decodeFromString<List<UIMessage>>(json.encodeToString(listOf(firstUser, reply)))
        val history = restored + user("continue")
        val next = PromptTranscript.prepare(history, listOf(prompt("A")) + history, listOf(tool("read")))
        assertNull(next.pendingEvent)
        assertEquals(first.messages.first().toText(), next.messages.first().toText())
        assertEquals(1, next.messages.count { it.role == MessageRole.SYSTEM })
        assertEquals("hi", reply.toText())
    }

    @Test
    fun changedSectionsAndToolsAreAppendedAndReplayAtOriginalPosition() {
        val user = user("hello")
        val first = PromptTranscript.prepare(listOf(user), listOf(prompt("A"), user), listOf(tool("read")))
        val reply = PromptTranscript.recordResponse(assistant("hi"), first)
        val history = listOf(user, reply, user("change"))
        val second = PromptTranscript.prepare(history, listOf(prompt("B")) + history, listOf(tool("read"), tool("write")))
        assertEquals(wireText(first.messages), wireText(second.messages.take(first.messages.size)))
        assertEquals(mapOf("rules" to "B"), second.pendingEvent?.sections)
        assertEquals(listOf("write"), second.pendingEvent?.toolsAdded?.map { it.name })
        val secondReply = PromptTranscript.recordResponse(assistant("changed"), second)
        val nextHistory = history + secondReply + user("again")
        val third = PromptTranscript.prepare(nextHistory, listOf(prompt("B")) + nextHistory, listOf(tool("read"), tool("write")))
        assertEquals(wireText(second.messages), wireText(third.messages.take(second.messages.size)))
        assertNull(third.pendingEvent)
    }

    @Test
    fun deletionAndSchemaReplacementResolveToCurrentStateOnUnsupportedProvider() {
        val user = user("hello")
        val first = PromptTranscript.prepare(listOf(user), listOf(prompt("old"), user), listOf(tool("read"), tool("write")))
        val history = listOf(user, PromptTranscript.recordResponse(assistant("hi"), first), user("change"))
        val currentTools = listOf(tool("read", "new schema description"))
        val next = PromptTranscript.prepare(history, history, currentTools)
        assertEquals(mapOf("rules" to null), next.pendingEvent?.sections)
        val view = PromptTranscript.resolve(next.messages, currentTools, false)
        assertTrue(view.hasNonAdditiveToolChanges)
        assertTrue(view.hasToolRedefinitions)
        assertEquals(currentTools.map { it.name }, view.currentTools.map { it.name })
        assertFalse(view.messages.any { it.toText().contains("old") })
    }

    @Test
    fun compactedPrefixBecomesCheckpointWithoutReplayingCoveredChanges() {
        val u1 = user("one")
        val r1 = PromptTranscript.prepare(listOf(u1), listOf(prompt("A"), u1), listOf(tool("read")))
        val a1 = PromptTranscript.recordResponse(assistant("one"), r1)
        val u2 = user("two")
        val h2 = listOf(u1, a1, u2)
        val r2 = PromptTranscript.prepare(h2, listOf(prompt("B")) + h2, listOf(tool("read"), tool("write")))
        val a2 = PromptTranscript.recordResponse(assistant("two"), r2)
        val u3 = user("three")
        val canonical = h2 + a2 + u3
        val compacted = PromptTranscript.prepare(canonical, listOf(prompt("B"), u3), listOf(tool("read"), tool("write")))
        assertNull(compacted.pendingEvent)
        assertEquals(2, compacted.messages.size)
        assertTrue(compacted.messages.first().toText().contains("B"))
        assertEquals(listOf("read", "write"), PromptTranscript.event(compacted.messages.first())?.toolsAdded?.map { it.name })
    }

    @Test
    fun selectedBranchDoesNotInheritOtherBranchPromptOrTools() {
        val user = user("start")
        val first = PromptTranscript.prepare(listOf(user), listOf(prompt("A"), user), listOf(tool("read")))
        val a1 = PromptTranscript.recordResponse(assistant("first"), first)
        val changed = PromptTranscript.prepare(listOf(user, a1), listOf(prompt("B"), user, a1), listOf(tool("write")))
        val alternate = PromptTranscript.recordResponse(assistant("alternate"), changed)
        assertNotNull(PromptTranscript.event(alternate))
        val branch = listOf(user, a1, user("different branch"))
        val request = PromptTranscript.prepare(branch, listOf(prompt("A")) + branch, listOf(tool("read")))
        assertNull(request.pendingEvent)
        assertFalse(request.messages.any { it.toText().contains("B") })
        assertEquals(listOf("read"), PromptTranscript.currentToolNames(branch))
        assertEquals(listOf("write"), PromptTranscript.currentToolNames(listOf(user, a1, alternate)))
    }

    @Test
    fun pureToolResponsesKeepMetadataWithoutMutatingOriginal() {
        val call = UIMessagePart.Tool("call1", "read", "{}")
        val raw = UIMessage(role = MessageRole.ASSISTANT, parts = listOf(call))
        val request = PromptTranscript.prepare(emptyList(), listOf(prompt("A")), listOf(tool("read")))
        val recorded = PromptTranscript.recordResponse(raw, request)
        assertNull(call.metadata)
        assertEquals("call1", (recorded.parts.first() as UIMessagePart.Tool).toolCallId)
        assertNotNull(PromptTranscript.event(recorded))
    }

    @Test
    fun liveToolCatalogOverridesStaleBackgroundTranscript() {
        val first = PromptTranscript.prepare(emptyList(), listOf(prompt("A")), listOf(tool("read"), tool("write")))
        val view = PromptTranscript.resolve(first.messages, listOf(tool("read")), true)
        assertTrue(view.hasNonAdditiveToolChanges)
        assertEquals(listOf("write"), PromptTranscript.event(view.messages.last())?.toolsRemoved)
    }

    @Test
    fun preparedBackgroundHandoffDoesNotNestSystemUpdateText() {
        val u1 = user("one")
        val first = PromptTranscript.prepare(listOf(u1), listOf(prompt("A"), u1), listOf(tool("read")))
        val a1 = PromptTranscript.recordResponse(assistant("reply"), first)
        val history = listOf(u1, a1, user("two"))
        val second = PromptTranscript.prepare(history, listOf(prompt("B")) + history, listOf(tool("read"), tool("write")))
        val restored = json.decodeFromString<List<UIMessage>>(json.encodeToString(second.messages))
        val resumed = PromptTranscript.prepare(history, restored, listOf(tool("read"), tool("write")))
        assertEquals(wireText(second.messages), wireText(resumed.messages))
        assertEquals(second.pendingEvent, resumed.pendingEvent)
    }

    @Test
    fun truncatedImportWithoutInitialSnapshotStartsNewEpoch() {
        val delta = PromptTranscriptEvent(sections = mapOf("rules" to "old"))
        val partial = PromptTranscript.recordResponse(assistant("old"), PromptTranscriptRequest(emptyList(), delta))
        val history = listOf(partial, user("now"))
        val request = PromptTranscript.prepare(history, listOf(prompt("current")) + history, listOf(tool("read")))
        assertEquals(true, request.pendingEvent?.initial)
        assertEquals(mapOf("rules" to "current"), request.pendingEvent?.sections)
    }

    @Test
    fun controlledMemoryMetadataSurvivesReplayButUnrelatedMetadataDoesNotPersist() {
        val memory = UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("memory", JsonObject(mapOf(
            PROMPT_SECTION_METADATA to JsonPrimitive("memory"),
            "amber_memory_record_ids" to JsonArray(listOf(JsonPrimitive(42))),
            SYSTEM_PROMPT_CACHE_CONTROL_METADATA to JsonPrimitive(SYSTEM_PROMPT_CACHE_DISABLED),
            "unrelated_header" to JsonPrimitive("not persisted"),
        )))))
        val u1 = user("start")
        val first = PromptTranscript.prepare(listOf(u1), listOf(memory, u1), emptyList())
        val a1 = PromptTranscript.recordResponse(assistant("done"), first)
        val next = PromptTranscript.prepare(listOf(u1, a1), listOf(memory, u1, a1), emptyList())
        val metadata = next.messages.first().parts.first().metadata!!
        assertEquals(JsonArray(listOf(JsonPrimitive(42))), metadata["amber_memory_record_ids"])
        assertEquals(JsonPrimitive(SYSTEM_PROMPT_CACHE_DISABLED), metadata[SYSTEM_PROMPT_CACHE_CONTROL_METADATA])
        assertFalse(json.encodeToString(next.pendingEvent).contains("not persisted"))
        assertFalse(json.encodeToString(PromptTranscript.event(a1)).contains("not persisted"))
    }

    @Test
    fun instructionBeforeHandoffCheckpointIsNotDiscarded() {
        val u1 = user("one")
        val first = PromptTranscript.prepare(listOf(u1), listOf(prompt("A"), u1), emptyList())
        val resumed = PromptTranscript.prepare(listOf(u1), listOf(PromptTranscript.sectionMessage("guard", "stop tools")) + first.messages, emptyList())
        assertTrue(resumed.messages.first().toText().contains("stop tools"))
        assertTrue(resumed.messages.first().toText().contains("A"))
    }

    @Test
    fun endpointAndModelAreBothRequiredForNativeCapabilities() {
        val model = Model(modelId = "gpt-5.4")
        assertTrue(PromptTranscriptCapabilities.resolve(ProviderSetting.OpenAI(useResponseApi = true), model).toolAdditions)
        assertFalse(PromptTranscriptCapabilities.resolve(ProviderSetting.OpenAI(baseUrl = "https://proxy.test/v1", useResponseApi = true), model).systemUpdates)
        assertFalse(PromptTranscriptCapabilities.resolve(ProviderSetting.OpenAI(), model).systemUpdates)
        assertFalse(PromptTranscriptCapabilities.resolve(ProviderSetting.OpenAI(useResponseApi = true), Model(modelId = "gpt-future")).systemUpdates)
        val moonshot = ProviderSetting.OpenAI(baseUrl = "https://api.moonshot.ai/v1")
        assertTrue(PromptTranscriptCapabilities.resolve(moonshot, Model(modelId = "kimi-k3")).toolAdditions)
        assertFalse(PromptTranscriptCapabilities.resolve(moonshot, Model(modelId = "kimi-k2.6")).toolAdditions)
        val codex = ProviderSetting.OpenAI(baseUrl = "https://chatgpt.com/backend-api/codex", authMode = OpenAIAuthMode.CODEX_OAUTH)
        assertTrue(PromptTranscriptCapabilities.resolve(codex, model).responsesToolSearch)
        assertTrue(PromptTranscriptCapabilities.resolve(codex, Model(modelId = "gpt-5.5")).responsesToolSearch)
        assertFalse(PromptTranscriptCapabilities.resolve(codex, Model(modelId = "gpt-6-astra")).responsesToolSearch)
    }
}
