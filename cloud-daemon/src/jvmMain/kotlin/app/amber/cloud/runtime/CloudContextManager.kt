package app.amber.cloud.runtime

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.security.CredentialRedactor
import app.amber.core.context.CompactPlan
import app.amber.core.context.CompactPolicy
import app.amber.core.context.CompactResult
import app.amber.core.context.ConversationCompact
import app.amber.core.memory.model.MemoryRecord
import app.amber.core.model.MemoryScope
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.math.max
import kotlin.uuid.Uuid

@Serializable
data class CloudCompactCheckpoint(
    val compact: ConversationCompact,
    val mustNotLose: List<String> = emptyList(),
    val mode: String = "routine",
)

/**
 * Context Compaction, Budget Fitting, and History Search/Fetch manager for `amberd`.
 *
 * Enforces cross-platform known defect protections:
 * - Defect #3: All compaction summaries, `must_not_lose` needles, and `history_search` /
 *   `history_fetch` outputs pass through [CredentialRedactor.redact].
 * - Defect #6: Auto-compaction requires a minimum delta (`minDeltaMessages`, default 4 new turns)
 *   since the previous compaction and separates routine pre-compaction (`0.70`) from forced
 *   compaction (`0.85`), preventing every-turn compaction loops.
 * - Defect #7: Budget fitting (`prepareRequestMessages`) pins `MessageRole.SYSTEM` messages as
 *   non-evictable; trimming only evicts older non-system messages.
 */
class CloudContextManager(
    private val checkpointsDir: File,
    private val policy: CompactPolicy = CompactPolicy(
        enabled = true,
        precompactRatio = 0.70f,
        forceRatio = 0.85f,
        keepRecentTurns = 4,
        maxSummaryTokens = 2_000,
    ),
    private val minDeltaMessages: Int = 4,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }

    init {
        checkpointsDir.mkdirs()
    }

    fun estimateTokens(message: UIMessage): Int {
        val textChars = message.parts.sumOf { part ->
            when (part) {
                is UIMessagePart.Text -> part.text.length
                is UIMessagePart.Reasoning -> part.reasoning.length
                is UIMessagePart.Tool -> part.toolName.length + part.input.length +
                    part.output.sumOf { (it as? UIMessagePart.Text)?.text?.length ?: 32 }
                else -> 64
            }
        }
        return max(4, (textChars + 3) / 4)
    }

    fun estimateTokens(messages: List<UIMessage>): Int = messages.sumOf(::estimateTokens)

    @Synchronized
    fun loadLatestCheckpoint(conversationId: String): CloudCompactCheckpoint? {
        val file = checkpointFile(conversationId)
        if (!file.exists()) return null
        return runCatching {
            json.decodeFromString<List<CloudCompactCheckpoint>>(file.readText()).lastOrNull()
        }.getOrNull()
    }

    @Synchronized
    fun loadAllCheckpoints(conversationId: String): List<CloudCompactCheckpoint> {
        val file = checkpointFile(conversationId)
        if (!file.exists()) return emptyList()
        return runCatching {
            json.decodeFromString<List<CloudCompactCheckpoint>>(file.readText())
        }.getOrDefault(emptyList())
    }

    /**
     * Plans whether compaction should run on [messages].
     *
     * Separates `"routine_precompact"` (`>= precompactRatio`) and `"forced_compact"` (`>= forceRatio`),
     * and enforces [minDeltaMessages] since the last checkpoint so compaction never fires on every turn.
     */
    @Synchronized
    fun planCompaction(
        conversationId: String,
        messages: List<UIMessage>,
        contextWindowTokens: Int,
    ): CompactPlan {
        val nonSystem = messages.filter { it.role != MessageRole.SYSTEM }
        val totalTokens = estimateTokens(messages)
        if (!policy.enabled || contextWindowTokens <= 0) {
            return CompactPlan(false, "disabled", totalTokens, contextWindowTokens, -1, -1, emptyList())
        }
        val latest = loadLatestCheckpoint(conversationId)
        val lastCompactedEndIndex = latest?.compact?.sourceEndIndex ?: -1
        val candidateEndIndex = nonSystem.size - policy.keepRecentTurns - 1
        val deltaMessages = if (lastCompactedEndIndex < 0) {
            nonSystem.size
        } else {
            candidateEndIndex - lastCompactedEndIndex
        }

        val forceThreshold = (contextWindowTokens * policy.forceRatio).toInt()
        val precompactThreshold = (contextWindowTokens * policy.precompactRatio).toInt()

        // Defect #6: Require at least minDeltaMessages new compressible messages since the last compaction!
        if (deltaMessages < minDeltaMessages) {
            return CompactPlan(
                shouldCompact = false,
                reason = "insufficient_delta",
                estimatedTokens = totalTokens,
                contextWindowTokens = contextWindowTokens,
                sourceStartIndex = -1,
                sourceEndIndex = -1,
                sourceMessageIds = emptyList(),
            )
        }

        val mode = when {
            totalTokens >= forceThreshold -> "forced_compact"
            totalTokens >= precompactThreshold -> "routine_precompact"
            else -> return CompactPlan(
                shouldCompact = false,
                reason = "below_threshold",
                estimatedTokens = totalTokens,
                contextWindowTokens = contextWindowTokens,
                sourceStartIndex = -1,
                sourceEndIndex = -1,
                sourceMessageIds = emptyList(),
            )
        }

        val endIndex = nonSystem.size - policy.keepRecentTurns - 1
        if (endIndex <= lastCompactedEndIndex || endIndex < 0) {
            return CompactPlan(
                shouldCompact = false,
                reason = "no_compressible_prefix",
                estimatedTokens = totalTokens,
                contextWindowTokens = contextWindowTokens,
                sourceStartIndex = -1,
                sourceEndIndex = -1,
                sourceMessageIds = emptyList(),
            )
        }
        val startIndex = 0
        val coveredIds = nonSystem.subList(startIndex, endIndex + 1).map { it.id.toString() }
        return CompactPlan(
            shouldCompact = true,
            reason = mode,
            estimatedTokens = totalTokens,
            contextWindowTokens = contextWindowTokens,
            sourceStartIndex = startIndex,
            sourceEndIndex = endIndex,
            sourceMessageIds = coveredIds,
        )
    }

    /**
     * Executes compaction if planned, redacting all summaries and `must_not_lose` needles.
     */
    @Synchronized
    fun compactIfNeeded(
        conversationId: String,
        messages: List<UIMessage>,
        contextWindowTokens: Int,
    ): CompactResult {
        val plan = planCompaction(conversationId, messages, contextWindowTokens)
        if (!plan.shouldCompact) {
            return CompactResult(
                status = "skipped:${plan.reason}",
                estimatedTokensBefore = plan.estimatedTokens,
                estimatedTokensAfter = plan.estimatedTokens,
            )
        }
        val nonSystem = messages.filter { it.role != MessageRole.SYSTEM }
        val slice = nonSystem.subList(plan.sourceStartIndex, plan.sourceEndIndex + 1)
        val mustNotLose = extractMustNotLose(slice).map(CredentialRedactor::redact)
        val rawSummary = slice.joinToString("\n") { msg ->
            val snippet = msg.toText().trim().replace("\n", " ").take(160)
            "- [${msg.role.name.lowercase()}] $snippet"
        }
        val redactedSummary = CredentialRedactor.redact(rawSummary)
        val now = System.currentTimeMillis()
        val previous = loadAllCheckpoints(conversationId)
        val compact = ConversationCompact(
            id = Uuid.random().toString(),
            conversationId = conversationId,
            summary = redactedSummary,
            level = previous.size + 1,
            sourceStartIndex = plan.sourceStartIndex,
            sourceEndIndex = plan.sourceEndIndex,
            sourceMessageIds = plan.sourceMessageIds,
            tokenEstimate = max(4, redactedSummary.length / 4),
            createdAt = now,
            updatedAt = now,
            status = "completed",
        )
        val checkpoint = CloudCompactCheckpoint(
            compact = compact,
            mustNotLose = mustNotLose,
            mode = plan.reason,
        )
        persistCheckpoints(conversationId, previous + checkpoint)
        val afterMessages = prepareRequestMessages(
            systemPrompt = "system",
            memories = emptyList(),
            conversationId = conversationId,
            historyMessages = messages,
            tokenBudget = contextWindowTokens,
        )
        return CompactResult(
            status = plan.reason,
            summaryId = compact.id,
            sourceMessageCount = slice.size,
            estimatedTokensBefore = plan.estimatedTokens,
            estimatedTokensAfter = estimateTokens(afterMessages),
        )
    }

    /**
     * Assembles model request messages while enforcing:
     * 1. Stable L0 System Prompt prefix (`MessageRole.SYSTEM` is ALWAYS first and NEVER evicted by budget fitting - Defect #7).
     * 2. Schema v2 `<context-handoff>` injected as a user message when a checkpoint covers earlier turns.
     * 3. Dynamic `<memory-context>` appended only to the final user turn (preserving L0 prefix cache hits).
     */
    fun prepareRequestMessages(
        systemPrompt: String,
        memories: List<MemoryRecord>,
        conversationId: String,
        historyMessages: List<UIMessage>,
        tokenBudget: Int = 32_000,
    ): List<UIMessage> {
        val coreMemories = memories.filter { it.scope == MemoryScope.CORE || it.pinned }
        val dynamicMemories = memories.filterNot { it.scope == MemoryScope.CORE || it.pinned }

        val stableSystemText = buildString {
            append(CredentialRedactor.redact(systemPrompt.trim()))
            if (coreMemories.isNotEmpty()) {
                append("\n\n<core-memory>\n")
                coreMemories.forEach { append("- ").append(CredentialRedactor.redact(it.content)).append('\n') }
                append("</core-memory>")
            }
        }
        val explicitSystemMessages = historyMessages.filter { it.role == MessageRole.SYSTEM }
        val pinnedSystemMessages = if (explicitSystemMessages.isNotEmpty()) {
            explicitSystemMessages.map { msg ->
                msg.copy(
                    parts = msg.parts.map { part ->
                        if (part is UIMessagePart.Text) part.copy(text = CredentialRedactor.redact(part.text)) else part
                    }
                )
            }
        } else {
            listOf(UIMessage.system(stableSystemText))
        }

        val checkpoint = loadLatestCheckpoint(conversationId)
        val coveredIds = checkpoint?.compact?.sourceMessageIds?.toSet().orEmpty()
        val nonSystemHistory = historyMessages.filter { it.role != MessageRole.SYSTEM }
        val uncoveredHistory = nonSystemHistory.filterNot { it.id.toString() in coveredIds }

        val handoffMessage = checkpoint?.let { cp ->
            val handoffText = buildString {
                append("<context-handoff version=\"2\" mode=\"${cp.mode}\">\n")
                append(CredentialRedactor.redact(cp.compact.summary))
                if (cp.mustNotLose.isNotEmpty()) {
                    append("\n<must-not-lose>\n")
                    cp.mustNotLose.forEach { needle ->
                        append("- ").append(CredentialRedactor.redact(needle)).append('\n')
                    }
                    append("</must-not-lose>")
                }
                append("\n</context-handoff>")
            }
            UIMessage.user(handoffText)
        }

        // Defect #7: System messages are pinned and non-evictable!
        val systemTokens = estimateTokens(pinnedSystemMessages)
        val handoffTokens = handoffMessage?.let(::estimateTokens) ?: 0
        val remainingBudget = max(64, tokenBudget - systemTokens - handoffTokens)

        val keptTail = mutableListOf<UIMessage>()
        var usedTokens = 0
        for (msg in uncoveredHistory.asReversed()) {
            val msgTokens = estimateTokens(msg)
            if (keptTail.isNotEmpty() && usedTokens + msgTokens > remainingBudget) {
                break
            }
            keptTail.add(0, msg)
            usedTokens += msgTokens
        }

        // Attach dynamic memories only to the last user message so L0 system prefix stays cache-hot
        if (dynamicMemories.isNotEmpty() && keptTail.isNotEmpty()) {
            val lastUserIdx = keptTail.indexOfLast { it.role == MessageRole.USER }
            if (lastUserIdx >= 0) {
                val target = keptTail[lastUserIdx]
                val memoryBlock = buildString {
                    append("\n\n<memory-context>\n")
                    dynamicMemories.forEach { append("- ").append(CredentialRedactor.redact(it.content)).append('\n') }
                    append("</memory-context>")
                }
                keptTail[lastUserIdx] = target.copy(
                    parts = target.parts + UIMessagePart.Text(memoryBlock)
                )
            }
        }

        return buildList {
            addAll(pinnedSystemMessages)
            if (handoffMessage != null) add(handoffMessage)
            addAll(keptTail)
        }
    }

    private fun extractMustNotLose(messages: List<UIMessage>): List<String> {
        val needles = mutableListOf<String>()
        val needleRegex = Regex("""(?i)(error|exception|exit\s*code|/[A-Za-z0-9._\-/]+|[0-9a-f]{7,40})""")
        for (msg in messages) {
            val text = msg.toText()
            for (line in text.lines()) {
                val trimmed = line.trim()
                if (trimmed.isNotEmpty() && needleRegex.containsMatchIn(trimmed)) {
                    needles.add(CredentialRedactor.redact(trimmed.take(200)))
                }
            }
        }
        return needles.distinct().take(12)
    }

    private fun checkpointFile(conversationId: String): File =
        File(checkpointsDir, "$conversationId.json")

    private fun persistCheckpoints(conversationId: String, checkpoints: List<CloudCompactCheckpoint>) {
        checkpointsDir.mkdirs()
        val target = checkpointFile(conversationId)
        val tmp = File(checkpointsDir, "$conversationId.json.tmp")
        tmp.writeText(json.encodeToString(checkpoints))
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }
}
