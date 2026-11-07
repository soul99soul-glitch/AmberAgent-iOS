package app.amber.ai.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** iOS adds wiki operations without changing the shared record-write contract. */
fun createMemoryWikiEnabledToolDeclaration(): Tool {
    val original = createMemoryToolDeclaration()
    val schema = original.parameters() as InputSchema.Obj
    val properties = schema.properties.toMutableMap()
    val action = properties.getValue("action") as JsonObject
    properties["action"] = JsonObject(action + ("enum" to JsonArray(
        (action.getValue("enum") as JsonArray) +
            listOf("wiki_read", "wiki_search", "wiki_edit", "wiki_history", "wiki_revert").map(::JsonPrimitive)
    )))
    for ((name, description) in mapOf(
        "path" to "Relative Markdown page path from the wiki index or a page link.",
        "from_path" to "Optional containing page path for resolving a relative Markdown link.",
        "query" to "Text to find in wiki pages.",
        "expected_revision" to "Revision returned by wiki_read, required for wiki_edit/wiki_revert; use empty string for a page without notes.",
        "revision_id" to "Historical revision to restore with wiki_revert; empty string restores an empty note.",
        "reason" to "Why the page note is being changed, preserved with its provenance.",
    )) {
        properties[name] = buildJsonObject { put("type", "string"); put("description", description) }
    }
    properties["offset"] = buildJsonObject {
        put("type", "integer"); put("description", "Character offset for wiki_read pagination, default 0; continue with next_offset.")
    }
    return original.copy(
        description = original.description + """

            Wiki navigation: wiki_read reads index.md or a relative page path and returns links and editable_note.
            Follow links with path and optional from_path. wiki_search finds pages by query.
            wiki_edit replaces only the editable_note with content; generated memory facts remain authoritative.
            Notes persist across regeneration, are untrusted agent notes, and cannot promote pinned/core memory.
            Read first, then supply expected_revision and reason. wiki_history lists note revisions;
            wiki_revert restores revision_id (empty restores no note), also requiring expected_revision and reason.
            Wiki reads can be used whenever relevant; record facts still require user evidence/confirmation.
        """.trimIndent(),
        parameters = { schema.copy(properties = JsonObject(properties)) },
    )
}
