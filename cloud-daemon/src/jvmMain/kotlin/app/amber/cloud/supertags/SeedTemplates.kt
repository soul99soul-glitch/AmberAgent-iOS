package app.amber.cloud.supertags

import app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID

internal fun seedTemplates(nowMs: Long): List<TagTemplate> {
    fun seed(name: String, vararg fields: Pair<String, TagFieldType>) = TagTemplate(
        name, GLOBAL_MEMORY_AGENT_ID, name, fields.map { TemplateField(it.first, it.second) }, createdAtMs = nowMs,
    )
    return listOf(
        seed("task", "title" to TagFieldType.TEXT, "status" to TagFieldType.STATUS, "due" to TagFieldType.DATE, "owner" to TagFieldType.PERSON),
        seed("bug", "repo" to TagFieldType.TEXT, "status" to TagFieldType.STATUS, "link" to TagFieldType.LINK),
        seed("decision", "topic" to TagFieldType.TEXT, "outcome" to TagFieldType.TEXT, "date" to TagFieldType.DATE),
        seed("trip", "destination" to TagFieldType.TEXT, "date" to TagFieldType.DATE, "budget" to TagFieldType.NUMBER),
        seed("reading", "title" to TagFieldType.TEXT, "source" to TagFieldType.LINK, "author" to TagFieldType.PERSON),
        seed("watch", "target" to TagFieldType.TEXT, "condition" to TagFieldType.TEXT, "status" to TagFieldType.STATUS),
    )
}
