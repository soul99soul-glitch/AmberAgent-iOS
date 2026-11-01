package app.amber.cloud.supertags

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.net.URI
import java.text.Normalizer
import java.time.LocalDate

internal const val DAY_MS = 86_400_000L

@Serializable
enum class TagFieldType { TEXT, DATE, STATUS, PERSON, LINK, NUMBER }

@Serializable
data class TagValue(val type: TagFieldType, val value: JsonPrimitive)

@Serializable
data class TemplateField(val name: String, val type: TagFieldType)

@Serializable
data class TagCandidate(
    val name: String,
    val templateId: String? = null,
    val attributes: Map<String, TagValue> = emptyMap(),
)

@Serializable
data class ConversationTag(
    val conversationId: String,
    val scopeId: String,
    val name: String,
    val templateId: String? = null,
    val attributes: Map<String, TagValue> = emptyMap(),
    val userModified: Boolean = false,
    val updatedAtMs: Long,
)

@Serializable
data class TagTemplate(
    val id: String,
    val scopeId: String,
    val name: String,
    val fields: List<TemplateField>,
    val aliases: List<String> = emptyList(),
    val aiSuggested: Boolean = false,
    val userModified: Boolean = false,
    val archived: Boolean = false,
    val deleted: Boolean = false,
    val mergedInto: String? = null,
    val revision: Int = 1,
    val createdAtMs: Long,
    val lastUsedAtMs: Long = createdAtMs,
)

@Serializable
data class TagObservation(
    val turnId: String,
    val tag: ConversationTag,
    val observedAtMs: Long,
)

@Serializable
data class TagCollection(
    val id: String,
    val scopeId: String,
    val tag: String,
    val conversationIds: List<String>,
    val promotionId: String? = null,
    val promotedHubId: String? = null,
)

@Serializable
data class HubPromotion(
    val id: String,
    val collectionId: String,
    val scopeId: String,
    val tag: String,
    val conversationIds: List<String>,
    val createdAtMs: Long,
    val hubId: String? = null,
)

@Serializable
data class SupertagEvent(val sequence: Long, val kind: String, val subjectId: String, val createdAtMs: Long)

class SupertagConflict(message: String) : IllegalStateException(message)
class SupertagNotFound(message: String) : IllegalArgumentException(message)

internal fun normalizeTag(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFKC)
    .trim().removePrefix("#").lowercase().replace(Regex("\\s+"), "-")

internal fun TagValue.isValid(): Boolean = when (type) {
    TagFieldType.NUMBER -> !value.isString && value.doubleOrNull?.isFinite() == true
    TagFieldType.DATE -> value.isString && runCatching { LocalDate.parse(value.content) }.isSuccess
    TagFieldType.LINK -> value.isString && runCatching { URI(value.content).let { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() && it.userInfo == null } }.getOrDefault(false)
    else -> value.isString && value.content.isNotBlank()
}
