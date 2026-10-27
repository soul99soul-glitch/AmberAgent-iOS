@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessagePart
import app.amber.core.storage.conversation.ConversationStorageInterface
import app.amber.core.storage.conversation.ConversationSummary
import kotlinx.serialization.Serializable

@Serializable
internal data class DesktopConversationSummary(
    val id: String,
    val title: String,
    val updatedAt: Double,
    val isPinned: Boolean,
    val messageCount: Int,
)

@Serializable
internal data class DesktopConversationSearchResult(
    val id: String,
    val title: String,
    val updatedAt: Double,
    val isPinned: Boolean,
    val messageCount: Int,
    val kind: String,
    val messageID: String? = null,
    val matchedText: String,
)

internal fun ConversationSummary.desktopSummary() = DesktopConversationSummary(
    id.toString(), title, updateAt.toEpochMilliseconds().toDouble(), isPinned, messageCount,
)

private fun ConversationSummary.searchResult(kind: String, messageID: String? = null, matchedText: String) =
    DesktopConversationSearchResult(id.toString(), title, updateAt.toEpochMilliseconds().toDouble(),
        isPinned, messageCount, kind, messageID, matchedText)

private fun String.searchText(): String = trim().split(Regex("\\s+")).joinToString(" ")

internal suspend fun desktopSearch(storage: ConversationStorageInterface, query: String): List<DesktopConversationSearchResult> {
    val needle = query.searchText()
    if (needle.isEmpty()) return emptyList()
    val summaries = storage.listSummaries()
    val titleMatches = summaries.filter { it.title.searchText().contains(needle, ignoreCase = true) }
    val results = titleMatches.take(200).map { it.searchResult("title", matchedText = it.title) }.toMutableList()
    if (results.size == 200) return results
    val titleIDs = titleMatches.map { it.id }.toSet()
    for (summary in summaries) {
        if (summary.id in titleIDs) continue
        val conversation = storage.loadConversation(summary.id) ?: continue
        val match = conversation.currentMessages.asReversed().firstNotNullOfOrNull { message ->
            if (message.role == MessageRole.SYSTEM) return@firstNotNullOfOrNull null
            val text = message.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text }.searchText()
            if (text.contains(needle, ignoreCase = true)) message.id.toString() to text else null
        } ?: continue
        results += summary.searchResult("message", match.first, match.second)
        if (results.size == 200) break
    }
    return results
}
