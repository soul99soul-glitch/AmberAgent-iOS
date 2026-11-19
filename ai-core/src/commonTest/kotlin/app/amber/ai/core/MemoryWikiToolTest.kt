package app.amber.ai.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MemoryWikiToolTest {
    @Test fun preservesRecordOperationsAndAddsVersionedWikiContract() {
        val tool = createMemoryWikiEnabledToolDeclaration()
        val schema = tool.parameters() as InputSchema.Obj
        val action = schema.properties.getValue("action") as JsonObject
        val actions = (action.getValue("enum") as JsonArray).map { it.jsonPrimitive.content }
        assertEquals("memory_tool", tool.name)
        assertTrue(actions.containsAll(listOf("create", "edit", "delete", "wiki_read", "wiki_search", "wiki_edit", "wiki_history", "wiki_revert")))
        assertTrue(schema.properties.keys.containsAll(listOf("content", "sourceMessageIds", "expected_revision", "revision_id", "from_path", "offset")))
        assertEquals(listOf("action"), schema.required)
    }
}
