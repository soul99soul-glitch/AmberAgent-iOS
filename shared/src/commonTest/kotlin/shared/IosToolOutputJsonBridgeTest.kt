package shared

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

class IosToolOutputJsonBridgeTest {
    @Test
    fun mapMetadataProducesSerializableTextPartAndPreservesNestedValues() {
        val metadata = mapOf(
            "amber_task_ui_submission" to JsonPrimitive("{\"draftRevision\":2}"),
            "existing" to Json.parseToJsonElement("""{"records":[7,9],"enabled":true}"""),
        )
        val text = IosToolOutputJsonBridge.textPart("用户选择", metadata)
        val restored = IosToolOutputJsonBridge.decode(IosToolOutputJsonBridge.encode(listOf(text))).single()

        assertEquals(text, restored)
        assertEquals(metadata, restored.metadata?.toMap())
    }

    @Test
    fun absentMetadataRemainsAbsent() {
        val text = IosToolOutputJsonBridge.textPart("普通文字", null)
        assertNull(text.metadata)
        assertEquals(text, IosToolOutputJsonBridge.decode(IosToolOutputJsonBridge.encode(listOf(text))).single())
    }

    @Test
    fun scalarMetadataReadIgnoresNestedJSONAndNull() {
        val part = IosToolOutputJsonBridge.decode(
            """[{"type":"text","text":"card","metadata":{"run":"run-1","nested":{"x":1},"array":[7],"null":null}}]""",
        ).single()
        assertEquals("run-1", IosToolOutputJsonBridge.metadataString(part, "run"))
        for (key in listOf("nested", "array", "null", "missing")) {
            assertNull(IosToolOutputJsonBridge.metadataString(part, key))
        }
    }

    @Test
    fun mergingStringMetadataKeepsNestedJSONAndTextThroughSerialization() {
        val part = IosToolOutputJsonBridge.textPart(
            "card", mapOf("nested" to Json.parseToJsonElement("""{"records":[7,9]}""")),
        )
        val updates = mapOf("run" to "run-2", "terminal" to "completed")
        val merged = IosToolOutputJsonBridge.mergeTextMetadata(part, updates)
        val restored = IosToolOutputJsonBridge.decode(IosToolOutputJsonBridge.encode(listOf(merged))).single()
        assertEquals(part.text, merged.text)
        assertEquals(part.metadata?.get("nested"), restored.metadata?.get("nested"))
        assertEquals("run-2", IosToolOutputJsonBridge.metadataString(restored, "run"))
        assertEquals("completed", IosToolOutputJsonBridge.metadataString(restored, "terminal"))
        assertSame(merged, IosToolOutputJsonBridge.mergeTextMetadata(merged, updates))
        assertSame(part, IosToolOutputJsonBridge.mergeTextMetadata(part, emptyMap()))
    }
}
