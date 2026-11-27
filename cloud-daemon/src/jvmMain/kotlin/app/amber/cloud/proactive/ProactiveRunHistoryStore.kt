package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/**
 * 主动引擎最近运行历史条目（供 `GET /v2/proactive/summary` 展示，存于 `dataDir/proactive/run-history.json`，权限 `0600`）。
 */
@Serializable
data class ProactiveRunHistoryEntry(
    val id: String,
    val signalId: String,
    val category: String,
    val topicKey: String,
    val title: String,
    val outcome: String,
    val summary: String,
    val timestampEpochMs: Long,
)

class ProactiveRunHistoryStore(
    proactiveDir: File,
    private val maxEntries: Int = 50,
) {
    private val file = File(proactiveDir, "run-history.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private var entries = emptyList<ProactiveRunHistoryEntry>()

    init {
        ProactiveFilePersistence.ensureOwnerOnlyDir(proactiveDir)
        loadFromDisk()
    }

    @Synchronized
    fun recent(limit: Int = 20): List<ProactiveRunHistoryEntry> =
        entries.takeLast(limit.coerceIn(1, maxEntries)).reversed()

    @Synchronized
    fun record(
        signalId: String,
        category: TriggerCategory,
        topicKey: String,
        title: String,
        outcome: String,
        summary: String,
        timestampEpochMs: Long,
    ): ProactiveRunHistoryEntry {
        if (outcome == "wakeup_expired") {
            entries.lastOrNull { it.signalId == signalId && it.outcome == outcome }?.let { return it }
        }
        val entry = ProactiveRunHistoryEntry(
            id = "prun_" + UUID.randomUUID().toString().replace("-", "").take(10),
            signalId = signalId,
            category = category.name,
            topicKey = CredentialRedactor.redact(topicKey).take(160),
            title = CredentialRedactor.redact(title).take(160),
            outcome = outcome,
            summary = CredentialRedactor.redact(summary).take(300),
            timestampEpochMs = timestampEpochMs,
        )
        val nextEntries = (entries + entry).takeLast(maxEntries)
        ProactiveFilePersistence.atomicWrite0600(file, json.encodeToString(nextEntries))
        entries = nextEntries
        return entry
    }

    @Synchronized
    fun recordFromResult(
        result: ProactiveRunResult,
        fallbackSignal: ProactiveTriggerSignal? = null,
        timestampEpochMs: Long = System.currentTimeMillis(),
    ) {
        when (result) {
            is ProactiveRunResult.DroppedAtL1 -> {
                val sig = fallbackSignal ?: return
                record(
                    signalId = sig.signalId,
                    category = sig.category,
                    topicKey = sig.topicKey,
                    title = sig.topicKey,
                    outcome = "dropped_l1",
                    summary = result.outcome.reason,
                    timestampEpochMs = timestampEpochMs,
                )
            }
            is ProactiveRunResult.SuppressedAtGate -> {
                val (outcome, reason) = when (val v = result.restraintVerdict) {
                    is RestraintVerdict.SuppressedQuietHours -> "suppressed_quiet_hours" to v.reason
                    is RestraintVerdict.DeferredByBudget -> {
                        val outcome = if (result.l1Delta.urgency == ProactiveUrgency.DIGEST && v.bufferedForMorningBriefing) {
                            "digest"
                        } else {
                            "deferred_budget"
                        }
                        outcome to v.reason
                    }
                    is RestraintVerdict.DroppedLowScore -> "dropped_low_score" to v.reason
                    is RestraintVerdict.AllowedToPush -> "allowed" to ""
                }
                record(
                    signalId = result.l1Delta.signalId,
                    category = result.l1Delta.category,
                    topicKey = result.l1Delta.topicKey,
                    title = result.l1Delta.title,
                    outcome = outcome,
                    summary = reason,
                    timestampEpochMs = timestampEpochMs,
                )
            }
            is ProactiveRunResult.PushedAtL3 -> {
                record(
                    signalId = result.l1Delta.signalId,
                    category = result.l1Delta.category,
                    topicKey = result.l1Delta.topicKey,
                    title = result.card.title,
                    outcome = "pushed",
                    summary = result.l2Score?.summary ?: result.card.title,
                    timestampEpochMs = timestampEpochMs,
                )
            }
        }
    }

    private fun loadFromDisk() {
        if (!file.isFile) return
        val loaded = runCatching {
            json.decodeFromString<List<ProactiveRunHistoryEntry>>(file.readText())
        }.getOrNull() ?: return
        entries = loaded.takeLast(maxEntries)
    }
}
