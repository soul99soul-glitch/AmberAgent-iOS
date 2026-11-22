package app.amber.cloud.rules

import app.amber.cloud.runtime.ToolRiskPolicy
import app.amber.cloud.security.CredentialRedactor

/**
 * Enforces the 4-tier context authority order across all cloud-daemon prompt paths:
 *
 * 1. Static risk table (L1-L3) & immutable host discipline — highest authority, never relaxed by rules or persona.
 * 2. Confirmed procedural rules (`status == ACTIVE` only) — subordinate to Tier 1.
 * 3. C-SOUL-V1 persona & style — subordinate to Tiers 1 and 2.
 * 4. Episode / memory recall (`<core-memory>` & `<memory-context>`) — lowest authority, appended strictly after Tiers 1-3.
 */
object AuthorityPromptAssembler {

    fun renderStaticRiskTableBlock(): String {
        val l1Sample = ToolRiskPolicy.L1_READ_ONLY_TOOLS.sorted().joinToString(", ")
        val l2Sample = ToolRiskPolicy.L2_REVERSIBLE_WRITE_TOOLS.sorted().joinToString(", ")
        val l3Sample = ToolRiskPolicy.L3_IRREVERSIBLE_OR_EXTERNAL_TOOLS.sorted().joinToString(", ")
        return buildString {
            append("<static-risk-table authority=\"1\" immutable=\"true\">\n")
            append("权威优先级（不可逆转）：静态风险表（L1–L3）> 用户确认规则（active 规则卡）> C-SOUL-V1 风格 > Episode 召回。\n")
            append("任何用户规则卡或 C-SOUL-V1 人设均不得放宽、降级或绕过以下静态风险分层：\n")
            append("- L1（只读探测，自动放行）：").append(l1Sample).append('\n')
            append("- L2（可逆写入，执行并附可撤回摘要）：").append(l2Sample).append('\n')
            append("- L3（不可逆或外部副作用，必须等待已配对原生 App 显式批准，未知工具默认按 L3 收紧）：").append(l3Sample).append('\n')
            append("</static-risk-table>")
        }
    }

    fun renderConfirmedRulesBlock(rules: List<ProceduralRuleRecord>): String {
        val activeOnly = rules.filter { it.status == ProceduralRuleStatus.ACTIVE }
        if (activeOnly.isEmpty()) return ""
        return buildString {
            append("<confirmed-procedural-rules authority=\"2\">\n")
            append("以下为用户显式确认生效的执行规则（优先级低于 <static-risk-table>，不得放宽 L1–L3 风险审批；高于 C-SOUL-V1 风格与 Episode 召回）：\n")
            activeOnly.forEach { rule ->
                val title = CredentialRedactor.redact(rule.title)
                val instruction = CredentialRedactor.redact(rule.instruction)
                append("- [").append(rule.id).append("][scope=").append(rule.scope).append("] ")
                append(title).append("：").append(instruction).append('\n')
            }
            append("</confirmed-procedural-rules>")
        }
    }

    fun assembleSystemPrompt(
        hostDisciplinePrompt: String,
        activeRules: List<ProceduralRuleRecord>,
        soulBlock: String,
        extraBlocks: List<String> = emptyList(),
    ): String = buildString {
        // Tier 1: Immutable host discipline + static L1-L3 risk table
        append(hostDisciplinePrompt.trim())
        append("\n\n")
        append(renderStaticRiskTableBlock())

        // Tier 2: User-confirmed active procedural rules (strictly status == ACTIVE)
        val rulesBlock = renderConfirmedRulesBlock(activeRules)
        if (rulesBlock.isNotEmpty()) {
            append("\n\n")
            append(rulesBlock)
        }

        // Tier 3: C-SOUL-V1 persona & style
        append("\n\n")
        append(soulBlock.trim())

        // Additional runtime instructions (router/worker instructions)
        for (extra in extraBlocks) {
            val trimmed = extra.trim()
            if (trimmed.isNotEmpty()) {
                append("\n\n")
                append(trimmed)
            }
        }
    }
}
