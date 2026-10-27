package desktop

import java.nio.file.Files
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.ai.core.MessageRole
import kotlin.io.encoding.Base64
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import kotlinx.serialization.encodeToString
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.uuid.Uuid
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DesktopConversationRepositoryTest {
    @Test
    fun backupMemoryRemappingCoversHiddenVariantsAndNestedPartsWithoutChangingIdentity(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-memory-remap").toFile()
        try {
            val metadata = JsonObject(mapOf("kept" to JsonPrimitive("nested value"),
                "amber_memory_record_ids" to JsonArray(listOf(1, 2, 3).map(::JsonPrimitive))))
            val cited = UIMessagePart.Text("literal number 3 <amber-mem-cite>{\"ids\":[1,3],\"note\":\"keep 3\"}</amber-mem-cite>", metadata)
            val original = canonicalConversationFixture().let { base -> base.copy(messageNodes = base.messageNodes.map { node ->
                node.copy(messages = node.messages.map { message -> message.copy(parts = message.parts.map { part ->
                    if (part is UIMessagePart.Tool) part.copy(output = part.output + cited) else part
                } + cited) })
            }) }
            val repository = DesktopConversationRepository(directory.path)
            val incoming = Json.encodeToString(DesktopConversation.from(original))
            val result = Json.decodeFromString<DesktopConversation>(repository.remapMemoryCitations(incoming, """{"1":101,"2":202}"""))
            val remapped = JsonInstant.decodeFromString<Conversation>(result.canonicalJSON!!)
            assertEquals(original.messageNodes.map { it.id }, remapped.messageNodes.map { it.id })
            assertEquals(original.messageNodes.map { it.selectIndex }, remapped.messageNodes.map { it.selectIndex })
            for ((oldNode, newNode) in original.messageNodes.zip(remapped.messageNodes)) {
                assertEquals(oldNode.messages.map { it.id }, newNode.messages.map { it.id })
                for ((oldMessage, message) in oldNode.messages.zip(newNode.messages)) {
                    assertEquals(oldMessage.parts.filter { it !is UIMessagePart.Text && it !is UIMessagePart.Tool },
                        message.parts.filter { it !is UIMessagePart.Text && it !is UIMessagePart.Tool })
                    val text = message.parts.last() as UIMessagePart.Text
                    assertEquals(JsonArray(listOf(101, 202).map(::JsonPrimitive)), text.metadata!!.getValue("amber_memory_record_ids"))
                    assertEquals(JsonPrimitive("nested value"), text.metadata!!.getValue("kept"))
                    assertTrue(text.text.startsWith("literal number 3 "))
                    assertTrue(text.text.contains("\"ids\":[101]"))
                    assertTrue(text.text.contains("\"note\":\"keep 3\""))
                    val nested = message.parts.filterIsInstance<UIMessagePart.Tool>().firstOrNull()?.output?.last() as? UIMessagePart.Text
                    if (nested != null) assertEquals(text, nested)
                }
            }
            val dropped = Json.decodeFromString<DesktopConversation>(repository.remapMemoryCitations(incoming, "{}"))
            val text = JsonInstant.decodeFromString<Conversation>(dropped.canonicalJSON!!).currentMessages.last().parts.last() as UIMessagePart.Text
            assertEquals(JsonArray(emptyList()), text.metadata!!.getValue("amber_memory_record_ids"))
            assertTrue(text.text.contains("\"ids\":[]"))
            assertTrue(directory.listFiles().isNullOrEmpty(), "Remapping an imported snapshot must not write a conversation")
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun backupMemoryRemappingRejectsUnknownCitationStructuresInsteadOfGuessing(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-memory-invalid").toFile()
        try {
            val repository = DesktopConversationRepository(directory.path)
            val original = DesktopConversation.from(canonicalConversationFixture())
            assertFailsWith<IllegalArgumentException> { repository.remapMemoryCitations(Json.encodeToString(original), """{"1":-1}""") }
            val message = original.messages.first().toMessage().copy(parts = listOf(UIMessagePart.Text("text",
                JsonObject(mapOf("amber_memory_record_ids" to JsonPrimitive("not an array"))))))
            val malformed = original.copy(messages = listOf(DesktopMessage.from(message)) + original.messages.drop(1))
            assertFailsWith<IllegalArgumentException> { repository.remapMemoryCitations(Json.encodeToString(malformed), "{}") }
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun summariesExposeOnlyMetadataAndSelectedNodeCount(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-summaries").toFile()
        try {
            val original = canonicalConversationFixture()
            val repository = DesktopConversationRepository(directory.path)
            repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val summary = Json.parseToJsonElement(repository.listSummaries()).jsonArray.single().jsonObject
            assertEquals(original.id.toString(), summary.getValue("id").jsonPrimitive.content)
            assertEquals("2", summary.getValue("messageCount").jsonPrimitive.content)
            assertEquals(original.updateAt.toEpochMilliseconds().toDouble().toString(), summary.getValue("updatedAt").jsonPrimitive.content)
            assertEquals(setOf("id", "title", "updatedAt", "isPinned", "messageCount"), summary.keys)
            assertFalse(summary.toString().contains("data:image"))
            assertFalse(summary.toString().contains("canonicalJSON"))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun searchUsesAllPersistedSelectedMessagesAndPrioritizesTitles(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-search").toFile()
        try {
            val original = canonicalConversationFixture()
            val selected = original.messageNodes.last().currentMessage
            val body = original.copy(title = "body conversation", isPinned = true, messageNodes = listOf(
                original.messageNodes.first().copy(messages = listOf(original.currentMessages.first().copy(
                    parts = listOf(UIMessagePart.Text("early needle result"))))),
                original.messageNodes.last().copy(messages = listOf(
                    selected.copy(id = Uuid.random(), parts = listOf(UIMessagePart.Text("hidden phrase"))),
                    selected.copy(parts = listOf(UIMessagePart.Text("last NEEDLE\n  result"))),
                )),
            ))
            val title = original.copy(id = Uuid.random(), title = "Needle result title", isPinned = false)
            val system = original.copy(id = Uuid.random(), title = "system conversation", isPinned = false,
                messageNodes = listOf(original.messageNodes.first().copy(messages = listOf(UIMessage(
                    role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("needle result")))))))
            val writer = DesktopConversationRepository(directory.path)
            for (conversation in listOf(body, title, system)) {
                writer.save(writer.normalizeImport(JsonInstant.encodeToString(conversation)))
            }
            // A new repository has no Swift/body cache; both persisted paths must still be found.
            val repository = DesktopConversationRepository(directory.path)
            val results = Json.parseToJsonElement(repository.search("  needle  result  ")).jsonArray.map { it.jsonObject }
            assertEquals(listOf(title.id.toString(), body.id.toString()), results.map { it.getValue("id").jsonPrimitive.content })
            assertEquals("title", results.first().getValue("kind").jsonPrimitive.content)
            assertEquals("message", results.last().getValue("kind").jsonPrimitive.content)
            assertEquals(selected.id.toString(), results.last().getValue("messageID").jsonPrimitive.content)
            assertEquals("last NEEDLE result", results.last().getValue("matchedText").jsonPrimitive.content)
            assertFalse(results.toString().contains("canonicalJSON"))
            assertFalse(results.toString().contains("data:image"))
            assertEquals("[]", repository.search("hidden phrase"))
            assertEquals("[]", repository.search("  \n "))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun cancelledContentSurvivesRestartAndStaleSavePreservesMetadata(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-store").toFile()
        val id = "12345678-1234-1234-1234-123456789abc"
        val messageId = "22345678-1234-1234-1234-123456789abc"
        val document = """{"id":"$id","title":"original","updatedAt":1234.0,"isPinned":false,"messages":[{"id":"$messageId","role":"assistant","text":"partial","state":"cancelled"}]}"""
        try {
            val first = DesktopConversationRepository(directory.path)
            first.save(document)
            first.updateMetadata(id, "renamed", true)
            first.save(document)
            val restarted = DesktopConversationRepository(directory.path)
            val loaded = Json.parseToJsonElement(restarted.loadAll()).jsonArray.single().jsonObject
            assertEquals("renamed", loaded.getValue("title").jsonPrimitive.content)
            assertEquals("true", loaded.getValue("isPinned").jsonPrimitive.content)
            assertEquals("cancelled", loaded.getValue("messages").jsonArray.single().jsonObject.getValue("state").jsonPrimitive.content)
            assertTrue(directory.resolve("$id.json").readText().contains("messageNodes"))
            restarted.delete(id)
            assertEquals("[]", restarted.loadAll())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun canonicalConversationRoundTripPreservesPartsVariantsAndMetadata(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-canonical").toFile()
        try {
            val original = canonicalConversationFixture()
            val repository = DesktopConversationRepository(directory.path)
            val normalized = repository.normalizeImport(JsonInstant.encodeToString(original))
            repository.save(normalized)
            val loaded = DesktopConversationRepository(directory.path).load(original.id.toString())!!
            val envelope = Json.decodeFromString<DesktopConversation>(loaded)
            assertEquals(original, JsonInstant.decodeFromString<Conversation>(envelope.canonicalJSON!!))
            // Also preserve a rich persisted document when an older UI sends only its display fields.
            val legacyProjection = envelope.copy(canonicalJSON = null,
                messages = envelope.messages.map { it.copy(canonicalJSON = null) })
            repository.save(Json.encodeToString(legacyProjection))
            val diskJSON = directory.resolve("${original.id}.json").readText()
            assertTrue(diskJSON.contains("amber-blob://"))
            assertFalse(diskJSON.contains(canonicalInlineImageFixture()))
            assertFalse(diskJSON.contains("canonicalJSON"))
            val blob = directory.resolve("${original.id}.blobs").listFiles()!!.single()
            kotlin.test.assertContentEquals(Base64.decode(canonicalInlineImageFixture().substringAfter(";base64,")), blob.readBytes())
            val reopened = DesktopConversationRepository(directory.path).load(original.id.toString())!!
            assertEquals(original, JsonInstant.decodeFromString<Conversation>(Json.decodeFromString<DesktopConversation>(reopened).canonicalJSON!!))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun retryPreservesNodeAndEarlierVariantsThenUpdatesOnlyNewAssistant(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-variants").toFile()
        try {
            val original = canonicalConversationFixture()
            val repository = DesktopConversationRepository(directory.path)
            val initial = Json.decodeFromString<DesktopConversation>(repository.normalizeImport(JsonInstant.encodeToString(original)))
            repository.save(Json.encodeToString(initial))
            val replyID = "90000000-0000-4000-8000-000000000009"
            val retry = initial.copy(messages = initial.messages.dropLast(1) +
                DesktopMessage(replyID, "assistant", "", state = "streaming"))
            val saved = Json.decodeFromString<DesktopConversation>(repository.save(Json.encodeToString(retry)))
            val canonical = JsonInstant.decodeFromString<Conversation>(saved.canonicalJSON!!)
            val node = canonical.messageNodes.last()
            assertEquals(original.messageNodes.last().id, node.id)
            assertEquals(original.messageNodes.last().messages, node.messages.take(2))
            assertEquals(2, node.selectIndex)
            assertEquals(3, node.messages.size)
            val fullReply = original.currentMessages.last().copy(id = Uuid.parse(replyID))
            val streamed = DesktopMessage.from(fullReply).copy(state = "cancelled")
            val later = saved.copy(messages = saved.messages.dropLast(1) + streamed)
            val finished = Json.decodeFromString<DesktopConversation>(repository.save(Json.encodeToString(later)))
            val finishedCanonical = JsonInstant.decodeFromString<Conversation>(finished.canonicalJSON!!)
            assertEquals(3, finishedCanonical.messageNodes.last().messages.size)
            assertEquals(fullReply.parts.drop(1), finishedCanonical.currentMessages.last().parts.drop(1))
            assertEquals(original.messageNodes.last().messages, finishedCanonical.messageNodes.last().messages.take(2))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun importSupportsLegacyEnvelopeAndCanonicalCopyWithoutChangingHiddenIDs(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-import").toFile()
        try {
            val repository = DesktopConversationRepository(directory.path)
            val legacy = """{"format":"amber.mac.conversation.v1","conversation":{"id":"12345678-1234-1234-1234-123456789abc","title":"old","updatedAt":1234,"messages":[{"id":"22345678-1234-1234-1234-123456789abc","role":"assistant","text":"partial","reasoning":"thought","state":"failed"}]}}"""
            val imported = Json.decodeFromString<DesktopConversation>(repository.normalizeImport(legacy))
            assertEquals("failed", imported.messages.single().state)
            assertEquals("thought", imported.messages.single().reasoning)
            assertTrue(imported.canonicalJSON != null)
            val original = canonicalConversationFixture()
            val normalized = Json.decodeFromString<DesktopConversation>(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val newID = "91000000-0000-4000-8000-000000000009"
            val saved = Json.decodeFromString<DesktopConversation>(repository.save(Json.encodeToString(normalized.copy(id = newID))))
            assertEquals(original.copy(id = Uuid.parse(newID)), JsonInstant.decodeFromString<Conversation>(saved.canonicalJSON!!))
            assertFailsWith<IllegalArgumentException> { repository.normalizeImport(legacy.replace("conversation.v1", "conversation.v2")) }
            assertFailsWith<IllegalArgumentException> {
                repository.normalizeImport(JsonInstant.encodeToString(original.copy(messageNodes = listOf(original.messageNodes.last().copy(selectIndex = 99)))))
            }
        } finally { directory.deleteRecursively() }
    }


    @Test
    fun exportAfterFailedSaveKeepsUnsavedContentAndHiddenVariants() : Unit = runBlocking {
        val blockedDirectory = Files.createTempFile("amber-desktop-blocked", ".file").toFile()
        blockedDirectory.writeText("not a directory")
        try {
            val original = canonicalConversationFixture()
            val envelope = DesktopConversation.from(original).copy(title = "unsaved title", isPinned = false,
                messages = DesktopConversation.from(original).messages + listOf(
                    DesktopMessage("a0000000-0000-4000-8000-000000000001", "user", "new unsaved question"),
                    DesktopMessage("a0000000-0000-4000-8000-000000000002", "assistant", "unsaved partial", state = "cancelled"),
                ))
            val repository = DesktopConversationRepository(blockedDirectory.path)
            assertFailsWith<Exception> { repository.save(Json.encodeToString(envelope)) }
            val exported = JsonInstant.decodeFromString<Conversation>(repository.exportDocument(Json.encodeToString(envelope)))
            assertEquals("unsaved title", exported.title)
            assertFalse(exported.isPinned)
            assertEquals(original.messageNodes, exported.messageNodes.take(2))
            assertEquals("unsaved partial", (exported.currentMessages.last().parts.first() as app.amber.ai.ui.UIMessagePart.Text).text)
            assertEquals("cancelled", DesktopMessage.from(exported.currentMessages.last()).state)
            assertEquals("not a directory", blockedDirectory.readText())
        } finally { blockedDirectory.delete() }
    }


    @Test
    fun legacyEnvelopeImportUsesVisibleMetadataWithoutChangingExistingSaveOwner(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-legacy-metadata").toFile()
        try {
            val original = canonicalConversationFixture()
            val envelope = DesktopConversation.from(original).copy(title = "renamed in preview", isPinned = false)
            val legacy = """{"format":"amber.mac.conversation.v1","conversation":${Json.encodeToString(envelope)}}"""
            val repository = DesktopConversationRepository(directory.path)
            val normalized = repository.normalizeImport(legacy)
            val imported = Json.decodeFromString<DesktopConversation>(normalized)
            assertEquals("renamed in preview", imported.title)
            assertFalse(imported.isPinned)
            assertEquals(original.copy(title = envelope.title, isPinned = false),
                JsonInstant.decodeFromString<Conversation>(imported.canonicalJSON!!))
            repository.save(normalized)
            repository.updateMetadata(original.id.toString(), "new disk title", true)
            repository.save(normalized)
            val latest = Json.decodeFromString<DesktopConversation>(repository.load(original.id.toString())!!)
            assertEquals("new disk title", latest.title)
            assertTrue(latest.isPinned)
        } finally { directory.deleteRecursively() }
    }

}
