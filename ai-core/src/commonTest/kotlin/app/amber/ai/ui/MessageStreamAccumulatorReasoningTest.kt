package app.amber.ai.ui

import app.amber.ai.core.MessageRole
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.JsonNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MessageStreamAccumulatorReasoningTest {
    private fun accumulator() = MessageStreamAccumulator(listOf(UIMessage.user("continue")))

    private fun chunk(vararg parts: UIMessagePart) = MessageChunk(
        id = "msg-1",
        model = "test-model",
        choices = listOf(UIMessageChoice(
            index = 0,
            delta = UIMessage(role = MessageRole.ASSISTANT, parts = parts.toList()),
            message = null,
            finishReason = null,
        )),
    )

    @Test
    fun emptySignedThinkingSurvivesSnapshot() {
        val accumulator = accumulator()
        val metadata = buildJsonObject { put("signature", "sig-empty") }
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "", metadata = metadata)))

        val reasoning = accumulator.snapshot().last().parts.filterIsInstance<UIMessagePart.Reasoning>().single()
        assertEquals("", reasoning.reasoning)
        assertEquals(metadata, reasoning.metadata)
    }

    @Test
    fun emptyEncryptedResponsesReasoningSurvivesSnapshot() {
        val accumulator = accumulator()
        val metadata = buildJsonObject {
            put("reasoning_id", "rs-1")
            put("encrypted_content", "encrypted-first")
        }
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "", metadata = metadata)))

        val reasoning = accumulator.snapshot().last().parts.filterIsInstance<UIMessagePart.Reasoning>().single()
        assertEquals("", reasoning.reasoning)
        assertEquals(metadata, reasoning.metadata)
    }

    @Test
    fun independentEncryptedReasoningBlocksStaySeparate() {
        val accumulator = accumulator()
        val metadata = listOf("first", "second").map { suffix ->
            buildJsonObject {
                put("reasoning_id", "rs-$suffix")
                put("encrypted_content", "encrypted-$suffix")
            }
        }
        metadata.forEach { accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "", metadata = it))) }

        val reasoning = accumulator.snapshot().last().parts.filterIsInstance<UIMessagePart.Reasoning>()
        assertEquals(2, reasoning.size)
        assertEquals(metadata, reasoning.map { it.metadata })
    }

    @Test
    fun ordinaryEmptyReasoningDoesNotCreateSnapshotPart() {
        val accumulator = accumulator()
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "")))
        accumulator.append(chunk(UIMessagePart.Reasoning(
            reasoning = "   ", metadata = buildJsonObject { put("unrelated", "value") },
        )))

        assertTrue(accumulator.snapshot().last().parts.isEmpty())
    }

    @Test
    fun emptyProtocolFieldsDoNotPreserveEmptyReasoning() {
        val accumulator = accumulator()
        accumulator.append(chunk(UIMessagePart.Reasoning(
            reasoning = "", metadata = buildJsonObject {
                put("signature", "")
                put("encrypted_content", JsonNull)
            },
        )))

        assertTrue(accumulator.snapshot().last().parts.isEmpty())
    }

    @Test
    fun encryptedReasoningAddedAndDoneEventsForSameItemMerge() {
        val accumulator = accumulator()
        val metadata = buildJsonObject {
            put("reasoning_id", "rs-1")
            put("encrypted_content", "encrypted")
        }
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "", metadata = metadata)))
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "summary", metadata = null)))
        accumulator.append(chunk(UIMessagePart.Reasoning(reasoning = "", metadata = metadata)))

        val reasoning = accumulator.snapshot().last().parts.filterIsInstance<UIMessagePart.Reasoning>().single()
        assertEquals("summary", reasoning.reasoning)
        assertEquals(metadata, reasoning.metadata)
    }

    @Test
    fun opaqueOnlyMessagesRemainUploadableButOrdinaryEmptyReasoningDoesNot() {
        val opaqueMetadata = listOf(
            buildJsonObject { put("signature", "sig-empty") },
            buildJsonObject { put("encrypted_content", "encrypted") },
            buildJsonObject {
                put("claude_redacted_thinking", buildJsonObject {
                    put("type", "redacted_thinking")
                    put("data", "redacted")
                })
            },
        )
        opaqueMetadata.forEach { metadata ->
            assertTrue(UIMessage(
                role = MessageRole.ASSISTANT,
                parts = listOf(UIMessagePart.Reasoning(reasoning = "", metadata = metadata)),
            ).isValidToUpload())
        }
        assertFalse(UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(UIMessagePart.Reasoning(reasoning = "")),
        ).isValidToUpload())
        assertFalse(UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(UIMessagePart.Reasoning(
                reasoning = "", metadata = buildJsonObject { put("signature", "") },
            )),
        ).isValidToUpload())
    }
}
