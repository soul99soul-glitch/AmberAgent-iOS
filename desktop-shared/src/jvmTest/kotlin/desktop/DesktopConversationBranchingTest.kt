@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.MessageNode
import app.amber.core.model.toMessageNode
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class DesktopConversationBranchingTest {
    private fun fixture(): Conversation {
        val original = canonicalConversationFixture()
        val richUser = original.currentMessages.first().copy(parts = listOf(
            original.currentMessages.last().parts[2],
            UIMessagePart.Text("editable", (original.currentMessages.last().parts.first() as UIMessagePart.Text).metadata),
            original.currentMessages.last().parts[4],
            UIMessagePart.Text("second fragment"),
        ))
        return original.copy(messageNodes = listOf(
            original.messageNodes.first().copy(messages = listOf(richUser)),
            original.messageNodes.last(),
            UIMessage.user("follow-up question").toMessageNode(),
            UIMessage.assistant("follow-up reply").toMessageNode(),
        ))
    }

    private fun decode(value: String): DesktopConversation = Json.decodeFromString(value)
    private fun canonical(value: DesktopConversation): Conversation = JsonInstant.decodeFromString(value.canonicalJSON!!)

    @Test
    fun variantProjectionAndSelectionKeepFollowingNodesAndProviderParts(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-select").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val initial = decode(saved)
            assertEquals(original.messageNodes[1].id.toString(), initial.messages[1].nodeID)
            assertEquals(original.messageNodes[1].messages.map { it.id.toString() }, initial.messages[1].variantIDs)
            assertEquals(1, initial.messages.first().editableTextPartIndex)
            assertEquals("editable", initial.messages.first().editableText)
            val selected = decode(repository.selectVariant(saved, original.currentMessages[1].id.toString(),
                original.messageNodes[1].messages.first().id.toString()))
            val actual = canonical(selected)
            assertEquals(original.messageNodes[1].copy(selectIndex = 0), actual.messageNodes[1])
            assertEquals(original.messageNodes.filterIndexed { index, _ -> index != 1 },
                actual.messageNodes.filterIndexed { index, _ -> index != 1 })
            assertEquals(actual.currentMessages, DesktopProviderBridge.messages(Json.encodeToString(selected.messages)))
            val reopened = decode(DesktopConversationRepository(directory.path).load(original.id.toString())!!)
            assertEquals(actual, canonical(reopened))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun deleteRemovesOnlyTargetNodeAndKeepsAllOtherNodes(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-delete-node").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val result = canonical(decode(repository.deleteMessage(saved, original.currentMessages[1].id.toString())))
            assertEquals(original.messageNodes.filterIndexed { index, _ -> index != 1 }, result.messageNodes)
            assertEquals(original.title, result.title)
            assertEquals(original.isPinned, result.isPinned)
            assertEquals(result, canonical(decode(DesktopConversationRepository(directory.path).load(original.id.toString())!!)))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun regenerateAppendsAssistantVariantAndTruncatesOnlyAfterTarget(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-regenerate").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val responseID = "a1000000-0000-4000-8000-000000000001"
            val result = decode(repository.regenerate(saved, original.currentMessages[1].id.toString(), responseID))
            val actual = canonical(result)
            assertEquals(2, actual.messageNodes.size)
            assertEquals(original.messageNodes.first(), actual.messageNodes.first())
            assertEquals(original.messageNodes[1].id, actual.messageNodes[1].id)
            assertEquals(original.messageNodes[1].messages, actual.messageNodes[1].messages.take(2))
            assertEquals(2, actual.messageNodes[1].selectIndex)
            assertEquals(responseID, result.messages.last().id)
            assertEquals("streaming", result.messages.last().state)
            val providerInput = DesktopProviderBridge.messages(Json.encodeToString(result.messages.dropLast(1)))
            assertEquals(listOf(original.currentMessages.first()), providerInput)
            assertEquals(actual, canonical(decode(DesktopConversationRepository(directory.path).load(original.id.toString())!!)))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun editChangesOnlyChosenTextAndRetainsUserSiblingAndMedia(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-edit").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val responseID = "a2000000-0000-4000-8000-000000000002"
            val result = decode(repository.editMessage(saved, original.currentMessages.first().id.toString(), 1,
                "edited body", responseID))
            val actual = canonical(result)
            val node = actual.messageNodes.first()
            assertEquals(2, actual.messageNodes.size)
            assertEquals(original.messageNodes.first().id, node.id)
            assertEquals(original.currentMessages.first(), node.messages.first())
            assertEquals(1, node.selectIndex)
            val edited = node.currentMessage
            val source = original.currentMessages.first()
            assertNotEquals(source.id, edited.id)
            val expectedParts = source.parts.toMutableList().also {
                it[1] = (it[1] as UIMessagePart.Text).copy(text = "edited body")
            }
            assertEquals(source.copy(id = edited.id, parts = expectedParts), edited)
            assertEquals(listOf(edited), DesktopProviderBridge.messages(Json.encodeToString(result.messages.dropLast(1))))
            assertEquals(responseID, result.messages.last().id)
            assertEquals(actual, canonical(decode(DesktopConversationRepository(directory.path).load(original.id.toString())!!)))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun invalidTargetsAndNonTextEditsDoNotChangePersistedConversation(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-invalid-branch").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val file = directory.resolve("${original.id}.json")
            val before = file.readBytes()
            val responseID = "a3000000-0000-4000-8000-000000000003"
            assertFailsWith<IllegalArgumentException> { repository.regenerate(saved, original.currentMessages.first().id.toString(), responseID) }
            assertFailsWith<IllegalArgumentException> { repository.editMessage(saved, original.currentMessages.first().id.toString(), 0, "cannot replace image", responseID) }
            assertFailsWith<IllegalArgumentException> { repository.selectVariant(saved, original.currentMessages.first().id.toString(), original.currentMessages[1].id.toString()) }
            assertFailsWith<IllegalArgumentException> { repository.regenerate(saved, original.currentMessages[1].id.toString(), original.currentMessages.first().id.toString()) }
            kotlin.test.assertContentEquals(before, file.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun deletingFirstUserMakesOrphanAssistantRegenerationFailBeforeWriting(): Unit = runBlocking {
        val directory = Files.createTempDirectory("amber-desktop-orphan-reply").toFile()
        try {
            val original = fixture()
            val repository = DesktopConversationRepository(directory.path)
            val saved = repository.save(repository.normalizeImport(JsonInstant.encodeToString(original)))
            val deleted = repository.deleteMessage(saved, original.currentMessages.first().id.toString())
            val file = directory.resolve("${original.id}.json")
            val before = file.readBytes()
            assertFailsWith<IllegalArgumentException> {
                repository.regenerate(deleted, original.currentMessages[1].id.toString(),
                    "a4000000-0000-4000-8000-000000000004")
            }
            kotlin.test.assertContentEquals(before, file.readBytes())
            assertEquals(original.messageNodes.drop(1), canonical(decode(repository.load(original.id.toString())!!)).messageNodes)
        } finally { directory.deleteRecursively() }
    }

}
