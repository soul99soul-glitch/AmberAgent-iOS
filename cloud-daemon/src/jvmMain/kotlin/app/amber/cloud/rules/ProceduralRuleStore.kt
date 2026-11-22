package app.amber.cloud.rules

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * Durable store for "correction -> procedural rule card" memory.
 *
 * Security & product invariants:
 * - Corrections ONLY create [ProceduralRuleStatus.PROPOSED] cards; explicit [confirm] is required for [ProceduralRuleStatus.ACTIVE].
 * - Pure persona/tone/character requests are redirected to C-SOUL-V1 and never persisted as rules.
 * - Rules attempting to relax or bypass the static L1-L3 risk table are rejected.
 * - Revoking or archiving a rule removes it from injection immediately on the next turn (100% excluded).
 * - Every prompt injection increments [ProceduralRuleRecord.hitCount] and persists atomically.
 */
class ProceduralRuleStore(
    dataDir: File,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        encodeDefaults = true
    }
    private val storeFile = File(dataDir, "procedural-rules.json")

    @Volatile
    private var cached: List<ProceduralRuleRecord>

    init {
        dataDir.mkdirs()
        cached = loadFromDisk()
    }

    fun list(
        status: ProceduralRuleStatus? = null,
        scope: String? = null,
    ): List<ProceduralRuleRecord> {
        val normalizedScope = scope?.takeUnless { it.isBlank() }?.let(::normalizeScope)
        return cached
            .asSequence()
            .filter { status == null || it.status == status }
            .filter { normalizedScope == null || it.scope == normalizedScope }
            .sortedWith(
                compareBy<ProceduralRuleRecord> { statusSortOrder(it.status) }
                    .thenByDescending { it.updatedAt }
            )
            .toList()
    }

    fun get(id: String): ProceduralRuleRecord? = cached.firstOrNull { it.id == id }

    fun activeSnapshot(): List<ProceduralRuleRecord> =
        cached.filter { it.status == ProceduralRuleStatus.ACTIVE }

    fun counts(current: List<ProceduralRuleRecord> = cached): Pair<Int, Int> {
        return current.count { it.status == ProceduralRuleStatus.ACTIVE } to
            current.count { it.status == ProceduralRuleStatus.PROPOSED }
    }

    /**
     * Proposes a new procedural rule card. Always starts as [ProceduralRuleStatus.PROPOSED].
     */
    @Synchronized
    fun propose(
        instruction: String,
        title: String? = null,
        scope: String? = null,
        sourceEventId: String = "",
        nowMs: Long = clockMs(),
    ): RuleProposalOutcome {
        if (CredentialRedactor.isPlaceholderCredential(instruction) ||
            (title != null && CredentialRedactor.isPlaceholderCredential(title))
        ) {
            throw PlaceholderCredentialException("拒绝将占位符凭据写入规则卡")
        }

        val cleanInstruction = sanitizeMultiline(instruction, MAX_INSTRUCTION_CHARS)
        if (cleanInstruction.isEmpty()) {
            return RuleProposalOutcome.Rejected("empty_instruction", "规则内容不能为空")
        }

        val fields = listOfNotNull(title?.trim(), cleanInstruction)
        if (fields.any(::attemptsRiskTableRelaxation)) {
            return RuleProposalOutcome.Rejected(
                code = "risk_table_immutable",
                reason = "静态风险表（L1–L3）由系统强制保留，规则卡不得放宽审批或绕过高风险确认。",
            )
        }

        if (isPurePersonaDescription(cleanInstruction)) {
            return RuleProposalOutcome.RedirectToSoul(
                target = "C-SOUL-V1",
                reason = "该内容属于形象人设、称呼或说话口吻设定，而非任务执行规矩。",
                suggestion = "请前往「形象人设 (C-SOUL-V1)」编辑器调整性格与语气，不混入执行规则卡。",
            )
        }

        if (scope != null && (scope.trim().length > MAX_SCOPE_CHARS || scope.trim().any(Char::isISOControl))) {
            return RuleProposalOutcome.Rejected("invalid_scope", "作用域不可包含控制字符或超过 ${MAX_SCOPE_CHARS} 个字符")
        }
        val resolvedScope = normalizeScope(scope)
        val cleanTitle = sanitizeSingleLine(title, MAX_TITLE_CHARS).ifEmpty { deriveTitle(cleanInstruction) }
        val cleanSourceEventId = sanitizeSingleLine(sourceEventId, MAX_EVENT_ID_CHARS)

        val current = cached.toMutableList()
        val existing = current.firstOrNull {
            (it.status == ProceduralRuleStatus.PROPOSED || it.status == ProceduralRuleStatus.ACTIVE) &&
                it.scope == resolvedScope &&
                it.instruction.equals(cleanInstruction, ignoreCase = true)
        }
        if (existing != null) {
            return RuleProposalOutcome.Proposed(existing, deduplicated = true)
        }

        val record = ProceduralRuleRecord(
            id = "rule_${UUID.randomUUID().toString().lowercase().take(12)}",
            title = cleanTitle,
            instruction = cleanInstruction,
            scope = resolvedScope,
            sourceEventId = cleanSourceEventId,
            status = ProceduralRuleStatus.PROPOSED,
            hitCount = 0,
            createdAt = nowMs,
            updatedAt = nowMs,
        )
        current.add(record)
        persist(current)
        return RuleProposalOutcome.Proposed(record, deduplicated = false)
    }

    /**
     * Detects explicit user correction phrasing from chat input and creates a [ProceduralRuleStatus.PROPOSED] card.
     * Never silently activates a rule. Returns null when the input is not a correction directive.
     */
    @Synchronized
    fun proposeFromCorrection(
        userText: String,
        scope: String = ProceduralRuleRecord.SCOPE_GLOBAL,
        sourceEventId: String = "",
        nowMs: Long = clockMs(),
    ): RuleProposalOutcome? {
        val extracted = extractCorrectionInstruction(userText) ?: return null
        return propose(
            instruction = extracted,
            title = deriveTitle(extracted),
            scope = scope,
            sourceEventId = sourceEventId,
            nowMs = nowMs,
        )
    }

    @Synchronized
    fun confirm(id: String, nowMs: Long = clockMs()): ProceduralRuleRecord {
        val current = cached.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx < 0) throw NoSuchElementException("规则卡不存在: $id")
        val target = current[idx]
        if (target.status == ProceduralRuleStatus.REVOKED || target.status == ProceduralRuleStatus.ARCHIVED) {
            throw IllegalStateException("已归档或已撤销的规则卡不可直接重新生效，请重新提议。")
        }
        if (listOf(target.title, target.instruction).any(::attemptsRiskTableRelaxation)) {
            throw IllegalStateException("静态风险表（L1–L3）不可被规则卡放宽")
        }
        if (target.status == ProceduralRuleStatus.ACTIVE) return target
        val updated = target.copy(
            status = ProceduralRuleStatus.ACTIVE,
            updatedAt = maxOf(nowMs, target.updatedAt + 1L),
        )
        current[idx] = updated
        persist(current)
        return updated
    }

    @Synchronized
    fun archive(id: String, nowMs: Long = clockMs()): ProceduralRuleRecord {
        val current = cached.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx < 0) throw NoSuchElementException("规则卡不存在: $id")
        val target = current[idx]
        if (target.status == ProceduralRuleStatus.ARCHIVED) return target
        val updated = target.copy(
            status = ProceduralRuleStatus.ARCHIVED,
            updatedAt = maxOf(nowMs, target.updatedAt + 1L),
        )
        current[idx] = updated
        persist(current)
        return updated
    }

    @Synchronized
    fun revoke(id: String, nowMs: Long = clockMs()): ProceduralRuleRecord {
        val current = cached.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx < 0) throw NoSuchElementException("规则卡不存在: $id")
        val target = current[idx]
        if (target.status == ProceduralRuleStatus.REVOKED) return target
        val updated = target.copy(
            status = ProceduralRuleStatus.REVOKED,
            updatedAt = maxOf(nowMs, target.updatedAt + 1L),
        )
        current[idx] = updated
        persist(current)
        return updated
    }

    /**
     * Selects ONLY [ProceduralRuleStatus.ACTIVE] rules matching global or the specified conversation/project scope.
     * Revoked, archived, and unconfirmed proposed rules are strictly excluded.
     * Increments [ProceduralRuleRecord.hitCount] when [recordHit] is true.
     */
    @Synchronized
    fun selectActiveForInjection(
        conversationId: String? = null,
        projectId: String? = null,
        recordHit: Boolean = true,
        nowMs: Long = clockMs(),
    ): List<ProceduralRuleRecord> {
        val matchedIds = cached
            .asSequence()
            .filter { it.status == ProceduralRuleStatus.ACTIVE }
            .filter { matchesScope(it.scope, conversationId, projectId) }
            .sortedWith(
                compareBy<ProceduralRuleRecord> { if (it.scope == ProceduralRuleRecord.SCOPE_GLOBAL) 0 else 1 }
                    .thenBy { it.createdAt }
                    .thenBy { it.id }
            )
            .map { it.id }
            .toList()

        if (matchedIds.isEmpty()) return emptyList()
        if (!recordHit) {
            val idOrder = matchedIds.withIndex().associate { it.value to it.index }
            return cached.filter { it.id in idOrder }.sortedBy { idOrder.getValue(it.id) }
        }

        val idSet = matchedIds.toSet()
        val current = cached.map { record ->
            if (record.id in idSet) {
                record.copy(
                    hitCount = record.hitCount + 1,
                    updatedAt = maxOf(nowMs, record.updatedAt),
                )
            } else {
                record
            }
        }
        persist(current)
        val idOrder = matchedIds.withIndex().associate { it.value to it.index }
        return current.filter { it.id in idOrder }.sortedBy { idOrder.getValue(it.id) }
    }

    private fun loadFromDisk(): List<ProceduralRuleRecord> {
        if (!storeFile.exists()) return emptyList()
        return json.decodeFromString<List<ProceduralRuleRecord>>(storeFile.readText())
    }

    private fun persist(records: List<ProceduralRuleRecord>) {
        atomicWrite(storeFile, json.encodeToString(records))
        cached = records
    }

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val MAX_TITLE_CHARS = 80
        const val MAX_INSTRUCTION_CHARS = 1_000
        const val MAX_SCOPE_CHARS = 141 // "conversation:" plus a 128-character native conversation ID
        const val MAX_EVENT_ID_CHARS = 128

        private val CORRECTION_PREFIXES = listOf(
            "规则：", "规则:",
            "纠正：", "纠正:",
            "以后不要", "以后请", "以后每次", "以后一律", "以后都", "以后",
            "下次不要", "下次请", "下次一定", "下次别再", "下次",
            "记住以后", "别再", "不要再",
            "rule:", "correction:", "from now on,", "from now on ",
        )

        private val RISK_RELAXATION_PATTERNS = listOf(
            Regex("""(?i)(跳过|忽略|取消|关闭|绕过|无需|不用|不需要).{0,10}(审批|确认|高风险|风险表|L3)"""),
            Regex("""(?i)(自动批准|自动同意|直接放行|静默执行).{0,12}(L3|高风险|不可逆|删除|命令|外部发送)"""),
            Regex("""(?i)(放宽|降低|覆盖|忽略).{0,8}(静态)?风险表"""),
            Regex("""(?i)(skip|bypass|disable|ignore|relax|override).{0,16}(approval|confirm|risk\s*table|l3|high[\s-]*risk)"""),
            Regex("""(?i)auto[\s-]*approve.{0,12}(l3|high[\s-]*risk|destructive|irreversible)"""),
        )

        private val PERSONA_SIGNALS = listOf(
            Regex("""(?i)(人设|性格|口吻|语气|声线|画风|角色扮演|扮演|自称|称呼|叫我|喊我)"""),
            Regex("""(?i)(温柔|傲娇|幽默|毒舌|高冷|活泼|俏皮|可爱|搞笑|热情|冷淡|二次元|霸总|管家|猫娘|兄弟口吻)"""),
            Regex("""(?i)\b(persona|personality|tone\s+of\s+voice|roleplay|act\s+like|call\s+me|speak\s+like|sound\s+more)\b"""),
        )

        private val EXECUTION_ACTION_SIGNALS = listOf(
            Regex("""(?i)(提交|推送|git|commit|push|merge|分支|代码|单测|测试|构建|编译|部署|发布|文件|路径|目录|命令|脚本|格式|markdown|json|表格|语言|中文|英文|日志|备份|删除|修改|创建|发送|邮件|日历|日程|报告|总结|输出|附带|先.*再)"""),
            Regex("""(?i)\b(git|commit|push|test|build|deploy|file|directory|command|script|json|markdown|table|format|output|include|avoid|never\s+run|always\s+run|before\s+editing)\b"""),
        )

        fun normalizeScope(raw: String?): String {
            val clean = raw?.trim().orEmpty()
            if (clean.isEmpty() || clean.equals("global", ignoreCase = true)) {
                return ProceduralRuleRecord.SCOPE_GLOBAL
            }
            return clean
        }

        fun matchesScope(ruleScope: String, conversationId: String?, projectId: String?): Boolean {
            if (ruleScope.equals(ProceduralRuleRecord.SCOPE_GLOBAL, ignoreCase = true)) return true
            val conv = conversationId?.trim()?.takeIf { it.isNotEmpty() }
            val proj = projectId?.trim()?.takeIf { it.isNotEmpty() }
            return when {
                ruleScope.startsWith("conversation:") -> conv != null && ruleScope.removePrefix("conversation:") == conv
                ruleScope.startsWith("project:") -> proj != null && ruleScope.removePrefix("project:") == proj
                else -> ruleScope == conv || ruleScope == proj
            }
        }

        fun extractCorrectionInstruction(userText: String): String? {
            val trimmed = userText.trim().replace(Regex("""^@[^\s，,:：]+[\s，,:：]+"""), "").trim()
            if (trimmed.length < 4 || trimmed.endsWith("?") || trimmed.endsWith("？")) return null
            val matched = CORRECTION_PREFIXES.firstOrNull { trimmed.startsWith(it, ignoreCase = true) } ?: return null
            val stripped = when {
                matched.endsWith("：") || matched.endsWith(":") || matched.startsWith("from now on", ignoreCase = true) ->
                    trimmed.substring(matched.length).trim()
                else -> trimmed
            }
            return stripped.takeIf { it.length >= 3 }
        }

        private val AUTO_APPROVAL = Regex("""(?i)自动批准|自动同意|直接放行|auto[ -]?approve""")
        private val PRECEDING_HIGH_RISK = Regex("""(?i)(L3|高风险|不可逆|high[ -]risk)[^。！？.!?；;，,\n]{0,18}$""")
        private val PROHIBITS_ACTION = Regex("""(?i)(不要|不准|禁止|不得|不能|不可|切勿|严禁|不允许|never|do not|must not|don't)(?:再|擅自|\s+ever)?\s*$""")

        fun attemptsRiskTableRelaxation(text: String): Boolean {
            fun prohibited(match: MatchResult) = PROHIBITS_ACTION.containsMatchIn(text.substring(0, match.range.first))
            return RISK_RELAXATION_PATTERNS.any { pattern -> pattern.findAll(text).any { !prohibited(it) } } ||
                AUTO_APPROVAL.findAll(text).any { match ->
                    !prohibited(match) && PRECEDING_HIGH_RISK.containsMatchIn(text.substring(0, match.range.first))
                }
        }

        fun isPurePersonaDescription(text: String): Boolean {
            val hasPersona = PERSONA_SIGNALS.any { it.containsMatchIn(text) }
            if (!hasPersona) return false
            val hasExecutionRule = EXECUTION_ACTION_SIGNALS.any { it.containsMatchIn(text) }
            return !hasExecutionRule
        }

        private fun statusSortOrder(status: ProceduralRuleStatus): Int = when (status) {
            ProceduralRuleStatus.PROPOSED -> 0
            ProceduralRuleStatus.ACTIVE -> 1
            ProceduralRuleStatus.ARCHIVED -> 2
            ProceduralRuleStatus.REVOKED -> 3
        }

        private fun deriveTitle(instruction: String): String {
            val firstLine = instruction.lineSequence().firstOrNull()?.trim().orEmpty()
            val cleaned = firstLine.trimEnd('。', '.', '!', '！', '；', ';')
            return if (cleaned.length <= 28) cleaned else cleaned.take(27) + "…"
        }

        private fun sanitizeSingleLine(raw: String?, maxChars: Int): String {
            if (raw == null) return ""
            return CredentialRedactor.redact(raw.replace(Regex("""[\r\n]+"""), " ").trim())
                .take(maxChars)
                .trim()
        }

        private fun sanitizeMultiline(raw: String, maxChars: Int): String =
            CredentialRedactor.redact(raw.trim()).take(maxChars).trim()
    }
}
