package app.amber.core.agent.store

import androidx.room.Room
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class AgentRunProjectionTest {
    private class TextReads {
        var characters = 0L
    }

    private class CountingDriver(private val reads: TextReads) : SQLiteDriver {
        private val driver = BundledSQLiteDriver()
        override fun open(fileName: String): SQLiteConnection {
            val connection = driver.open(fileName)
            return object : SQLiteConnection by connection {
                override fun prepare(sql: String): SQLiteStatement {
                    val statement = connection.prepare(sql)
                    return object : SQLiteStatement by statement {
                        override fun getText(index: Int): String = statement.getText(index).also {
                            reads.characters += it.length
                        }
                    }
                }
            }
        }
    }

    @Test
    fun summariesPreserveDisplayDataAndAvoidReadingUnusedPayload() = runTest {
        val path = Files.createTempFile("run-projection", ".db")
        Files.delete(path)
        val reads = TextReads()
        val db = Room.databaseBuilder<AgentRuntimeDatabase>(name = path.toString())
            .setDriver(CountingDriver(reads)).build()
        try {
            val dao = db.agentRuntimeDao()
            for (index in 0 until 12) {
                dao.insertRunIfAbsent(AgentRunEntity(
                    runId = "run-$index", parentRunId = null,
                    agentDescriptorId = if (index % 2 == 0) "chat" else "other",
                    agentVersion = "1", conversationId = if (index == 0) null else "CONVERSATION-$index",
                    messageNodeId = null, producesMessageId = null, assistantId = "assistant",
                    status = listOf("running", "waiting_user", "outcome_unknown", "completed")[index % 4],
                    inputDigest = "digest-$index", inputSnapshotRef = "tool_call:确认-$index",
                    inputSchemaVersion = 1, startedAt = (index / 2).toLong(),
                    finishedAt = if (index % 4 == 3) 9L else null,
                    interruptedReason = "中断-$index", terminalReason = "结束-$index",
                    providerId = "provider", modelId = "model", promptVersion = "prompt",
                    toolCatalogVersion = "tools", capabilitySnapshot = "x".repeat(32 * 1024),
                ))
            }
            reads.characters = 0
            val full = dao.listAllRuns()
            val fullCharacters = reads.characters
            reads.characters = 0
            val summaries = dao.listRunSummaries()
            val summaryCharacters = reads.characters
            reads.characters = 0
            val notices = dao.listRunNoticeSummaries()
            val noticeCharacters = reads.characters
            assertEquals(full.map { AgentRunSummary(it.runId, it.agentDescriptorId, it.conversationId,
                it.status, it.startedAt, it.finishedAt, it.interruptedReason, it.terminalReason) }, summaries)
            assertEquals(full.map { AgentRunNoticeSummary(it.runId, it.agentDescriptorId, it.conversationId,
                it.status, it.startedAt, it.finishedAt, it.inputSnapshotRef) }, notices)
            assertTrue(summaryCharacters < fullCharacters / 10)
            assertTrue(noticeCharacters < fullCharacters / 10)
            println("[RUN-PROJECTION] fullTextChars=$fullCharacters summaryTextChars=$summaryCharacters noticeTextChars=$noticeCharacters")
        } finally {
            db.close()
            Files.deleteIfExists(path)
        }
    }
}
