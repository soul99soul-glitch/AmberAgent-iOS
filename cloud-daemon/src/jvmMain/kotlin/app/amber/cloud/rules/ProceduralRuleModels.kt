package app.amber.cloud.rules

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ProceduralRuleStatus(val wireName: String) {
    @SerialName("proposed")
    PROPOSED("proposed"),

    @SerialName("active")
    ACTIVE("active"),

    @SerialName("archived")
    ARCHIVED("archived"),

    @SerialName("revoked")
    REVOKED("revoked");

    companion object {
        fun parse(raw: String?): ProceduralRuleStatus? = when (raw?.trim()?.lowercase()) {
            "proposed" -> PROPOSED
            "active" -> ACTIVE
            "archived" -> ARCHIVED
            "revoked" -> REVOKED
            else -> null
        }
    }
}

/**
 * Structured procedural rule card generated from user corrections.
 *
 * Lifecycle invariants:
 * - Always created as [ProceduralRuleStatus.PROPOSED]; never auto-activated without explicit user confirmation.
 * - Pure persona/style descriptions belong to C-SOUL-V1 and must never enter this store.
 * - Cannot relax the static L1-L3 risk table.
 */
@Serializable
data class ProceduralRuleRecord(
    val id: String,
    val title: String,
    val instruction: String,
    val scope: String = SCOPE_GLOBAL,
    val sourceEventId: String = "",
    val status: ProceduralRuleStatus = ProceduralRuleStatus.PROPOSED,
    val hitCount: Int = 0,
    val createdAt: Long,
    val updatedAt: Long,
) {
    companion object {
        const val SCOPE_GLOBAL = "global"
    }
}

sealed interface RuleProposalOutcome {
    data class Proposed(
        val rule: ProceduralRuleRecord,
        val deduplicated: Boolean = false,
    ) : RuleProposalOutcome

    data class RedirectToSoul(
        val target: String = "C-SOUL-V1",
        val reason: String,
        val suggestion: String,
    ) : RuleProposalOutcome

    data class Rejected(
        val code: String,
        val reason: String,
    ) : RuleProposalOutcome
}

@Serializable
data class ProposeRuleRequestDto(
    val title: String? = null,
    val instruction: String,
    val scope: String? = null,
    val sourceEventId: String? = null,
)

@Serializable
data class ProceduralRuleListResponseDto(
    val rules: List<ProceduralRuleRecord>,
    val activeCount: Int,
    val proposedCount: Int,
)

@Serializable
data class ProceduralRuleResponseDto(
    val rule: ProceduralRuleRecord,
    val deduplicated: Boolean = false,
)

@Serializable
data class ProceduralRuleRedirectDto(
    val error: String = "persona_belongs_to_soul",
    val redirectToSoul: Boolean = true,
    val target: String = "C-SOUL-V1",
    val message: String,
)
