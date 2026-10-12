package app.amber.core.storage.conversation

import app.amber.ai.ui.UIMessage
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.MessageNode
import kotlinx.coroutines.test.runTest
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.measureTimedValue
import kotlin.uuid.Uuid

class ConversationSummaryStartupTest {
    @Test
    fun coldListingReusesPersistedSummariesWithoutDecodingHistory() = runTest {
        val directory = Files.createTempDirectory("conversation-startup-").toFile()
        try {
            val baseDir = ConversationFile(directory.path)
            val nodes = List(80) {
                MessageNode(messages = listOf(UIMessage.user("history $it " + "x".repeat(1024))))
            }
            val expected = List(500) {
                val conversation = Conversation(
                    id = Uuid.random(), title = "session $it", messageNodes = nodes,
                    assistantId = app.amber.core.model.DEFAULT_ASSISTANT_ID,
                )
                baseDir.child("${conversation.id}.json")
                    .writeText(JsonInstant.encodeToString(conversation))
                conversation.toSummary()
            }
            // The legacy index is valid, as on an existing installation.
            baseDir.child("index.json").writeText(JsonInstant.encodeToString(expected))
            val migration = measureTimedValue { JsonConversationStorage(baseDir).listSummaries() }
            assertEquals(expected.toSet(), migration.value.toSet())
            println("SUMMARY_STARTUP sessions=500 messages=40000 bytes=${directory.listFiles()!!.sumOf { it.length() }} migrationMs=${migration.duration.inWholeMilliseconds}")

            val decodeCounts = List(3) { iteration ->
                // A new owner models a new app process; no in-memory cache can survive.
                val reopened = JsonConversationStorage(baseDir)
                var decoded = 0
                reopened.beforeSummaryDecodeForTesting = { decoded++ }
                val result = measureTimedValue { reopened.listSummaries() }
                assertEquals(expected.toSet(), result.value.toSet())
                println("SUMMARY_STARTUP cold=$iteration elapsedMs=${result.duration.inWholeMilliseconds} decoded=$decoded")
                decoded
            }
            assertEquals(listOf(0, 0, 0), decodeCounts, "冷启动读取摘要不应反复解码全部历史正文")
        } finally {
            directory.deleteRecursively()
        }
    }
}
