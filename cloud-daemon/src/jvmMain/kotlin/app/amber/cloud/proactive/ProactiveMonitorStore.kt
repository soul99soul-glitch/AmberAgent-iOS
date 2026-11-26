package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import io.ktor.client.HttpClient
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.net.InetAddress
import java.util.UUID

/**
 * Watchtower 静默巡检规则持久化记录（存于 `dataDir/proactive/monitors.json`，权限 `0600`）。
 */
@Serializable
data class ProactiveMonitorRecord(
    val id: String,
    val title: String,
    val url: String,
    val conditionPrompt: String = "",
    val intervalMinutes: Int = 15,
    val enabled: Boolean = true,
    val createdAtMs: Long,
    val lastCheckedAtMs: Long? = null,
    val lastOutcome: String? = null,
    val lastSummary: String? = null,
    val consecutiveUnchanged: Int = 0,
    val nextRunAtMs: Long,
    val deliveryMode: String = DELIVERY_MODE_IMMEDIATE,
) {
    companion object {
        const val DELIVERY_MODE_IMMEDIATE = "immediate"
        const val DELIVERY_MODE_DIGEST = "digest"

        fun normalizeDeliveryMode(raw: String): String {
            val normalized = raw.trim().lowercase()
            require(normalized == DELIVERY_MODE_IMMEDIATE || normalized == DELIVERY_MODE_DIGEST) {
                "deliveryMode 仅支持 immediate 或 digest"
            }
            return normalized
        }
    }
}

/**
 * Watchtower 静默巡检规则持久化存储（`dataDir/proactive/monitors.json`，权限 `0600`）。
 */
class ProactiveMonitorStore(
    proactiveDir: File,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    private val file = File(proactiveDir, "monitors.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val records = LinkedHashMap<String, ProactiveMonitorRecord>()

    init {
        ProactiveFilePersistence.ensureOwnerOnlyDir(proactiveDir)
        loadFromDisk()
    }

    @Synchronized
    fun list(includeDisabled: Boolean = true): List<ProactiveMonitorRecord> {
        val all = records.values.sortedBy { it.createdAtMs }
        return if (includeDisabled) all else all.filter { it.enabled }
    }

    @Synchronized
    fun get(id: String): ProactiveMonitorRecord? = records[id]

    @Synchronized
    fun create(
        title: String,
        url: String,
        conditionPrompt: String = "",
        intervalMinutes: Int = 15,
        enabled: Boolean = true,
        deliveryMode: String = ProactiveMonitorRecord.DELIVERY_MODE_IMMEDIATE,
        nowMs: Long = clockMs(),
    ): ProactiveMonitorRecord {
        val cleanUrl = url.trim()
        ProactiveUrlGuard.validateSyntaxAndLiteralHost(cleanUrl)
        val normalizedDeliveryMode = ProactiveMonitorRecord.normalizeDeliveryMode(deliveryMode)
        val cleanTitle = CredentialRedactor.redact(title.trim()).ifBlank { cleanUrl }.take(120)
        val cleanCondition = CredentialRedactor.redact(conditionPrompt.trim()).take(500)
        val clampedInterval = intervalMinutes.coerceIn(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)
        val id = "mon_" + UUID.randomUUID().toString().replace("-", "").take(12)
        val record = ProactiveMonitorRecord(
            id = id,
            title = cleanTitle,
            url = cleanUrl,
            conditionPrompt = cleanCondition,
            intervalMinutes = clampedInterval,
            enabled = enabled,
            createdAtMs = nowMs,
            nextRunAtMs = nowMs,
            deliveryMode = normalizedDeliveryMode,
        )
        records[id] = record
        persistToDisk()
        return record
    }

    @Synchronized
    fun update(
        id: String,
        title: String? = null,
        url: String? = null,
        conditionPrompt: String? = null,
        intervalMinutes: Int? = null,
        enabled: Boolean? = null,
        deliveryMode: String? = null,
        nowMs: Long = clockMs(),
    ): ProactiveMonitorRecord? {
        val existing = records[id] ?: return null
        val nextUrl = if (url != null) {
            val trimmed = url.trim()
            ProactiveUrlGuard.validateSyntaxAndLiteralHost(trimmed)
            trimmed
        } else existing.url
        val nextDeliveryMode = if (deliveryMode != null) {
            ProactiveMonitorRecord.normalizeDeliveryMode(deliveryMode)
        } else {
            existing.deliveryMode
        }
        val nextTitle = title?.trim()?.takeIf { it.isNotEmpty() }
            ?.let { CredentialRedactor.redact(it).take(120) } ?: existing.title
        val nextCondition = conditionPrompt?.trim()
            ?.let { CredentialRedactor.redact(it).take(500) } ?: existing.conditionPrompt
        val nextInterval = intervalMinutes?.coerceIn(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)
            ?: existing.intervalMinutes
        val nextEnabled = enabled ?: existing.enabled
        val nextRun = when {
            !existing.enabled && nextEnabled -> nowMs
            intervalMinutes != null && existing.lastCheckedAtMs != null ->
                existing.lastCheckedAtMs + nextInterval * 60_000L
            else -> existing.nextRunAtMs
        }
        val updated = existing.copy(
            title = nextTitle,
            url = nextUrl,
            conditionPrompt = nextCondition,
            intervalMinutes = nextInterval,
            enabled = nextEnabled,
            nextRunAtMs = nextRun,
            deliveryMode = nextDeliveryMode,
        )
        records[id] = updated
        persistToDisk()
        return updated
    }

    @Synchronized
    fun delete(id: String): Boolean {
        val removed = records.remove(id) != null
        if (removed) persistToDisk()
        return removed
    }

    @Synchronized
    fun dueMonitors(nowMs: Long = clockMs()): List<ProactiveMonitorRecord> =
        records.values.filter { it.enabled && it.nextRunAtMs <= nowMs }.sortedBy { it.nextRunAtMs }

    @Synchronized
    fun recordCheckResult(
        id: String,
        checkedAtMs: Long,
        outcome: String,
        summary: String?,
        consecutiveUnchanged: Int,
        effectiveIntervalMinutes: Int,
    ): ProactiveMonitorRecord? {
        val existing = records[id] ?: return null
        val clampedNext = effectiveIntervalMinutes.coerceIn(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)
        val updated = existing.copy(
            lastCheckedAtMs = checkedAtMs,
            lastOutcome = outcome,
            lastSummary = summary?.let { CredentialRedactor.redact(it).take(240) },
            consecutiveUnchanged = consecutiveUnchanged.coerceAtLeast(0),
            nextRunAtMs = checkedAtMs + clampedNext * 60_000L,
        )
        records[id] = updated
        persistToDisk()
        return updated
    }

    private fun loadFromDisk() {
        if (!file.isFile) return
        val list = runCatching {
            json.decodeFromString<List<ProactiveMonitorRecord>>(file.readText())
        }.getOrNull() ?: return
        records.clear()
        list.forEach { records[it.id] = it }
    }

    private fun persistToDisk() {
        ProactiveFilePersistence.atomicWrite0600(file, json.encodeToString(records.values.toList()))
    }

    companion object {
        const val MIN_INTERVAL_MINUTES = 5
        const val MAX_INTERVAL_MINUTES = 1_440
    }
}

/**
 * Watchtower 静默巡检触发源：
 * - 按 `nextRunAtMs` 轮询到期且启用的监控规则；
 * - 每次抓取前强制执行 [ProactiveUrlGuard.validatePublicUrl] SSRF 防护；
 * - 携带上次 ETag 走现有 [L1DeterministicFilter] 零成本预筛与指数退避（无变化 0 次模型调用）。
 */
class WatchtowerMonitorTriggerSource(
    private val monitorStore: ProactiveMonitorStore,
    private val l1Filter: L1DeterministicFilter,
    httpClient: HttpClient? = null,
    dnsResolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() },
    maxResponseBytes: Int = WatchtowerHttp.MAX_RESPONSE_BYTES,
) : TriggerSource {
    private val fetcher = WatchtowerHttp(httpClient, dnsResolver, maxResponseBytes)


    override val id: String = "watchtower_monitors"
    override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR

    override suspend fun pollAll(nowEpochMs: Long): List<ProactiveTriggerSignal> {
        val due = monitorStore.dueMonitors(nowEpochMs)
        if (due.isEmpty()) return emptyList()
        val signals = mutableListOf<ProactiveTriggerSignal>()

        for (monitor in due) {
            val prevEtag = l1Filter.getWatchtowerSnapshot(monitor.url)?.etag
            val page = try {
                fetcher.fetch(monitor.url, prevEtag)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val blocked = e is IllegalArgumentException || e is NonPublicWatchtowerHost
                monitorStore.recordCheckResult(
                    id = monitor.id,
                    checkedAtMs = nowEpochMs,
                    outcome = if (blocked) "blocked_ssrf" else "error",
                    summary = e.message ?: "抓取失败",
                    consecutiveUnchanged = monitor.consecutiveUnchanged,
                    effectiveIntervalMinutes = maxOf(monitor.intervalMinutes, if (blocked) 60 else 15),
                )
                continue
            }
            signals.add(
                ProactiveTriggerSignal.WatchtowerPageSignal(
                    signalId = "wt_${monitor.id}_$nowEpochMs",
                    url = monitor.url,
                    title = monitor.title,
                    httpStatusCode = page.status,
                    etag = page.etag,
                    rawBody = page.body,
                    conditionPrompt = monitor.conditionPrompt,
                    monitorId = monitor.id,
                    topicKey = "watchtower:${monitor.id}",
                    timestampEpochMs = nowEpochMs,
                    digest = monitor.deliveryMode == ProactiveMonitorRecord.DELIVERY_MODE_DIGEST,
                )
            )
        }
        return signals
    }

    override suspend fun onResult(
        signal: ProactiveTriggerSignal,
        result: ProactiveRunResult,
        nowEpochMs: Long,
    ) {
        val wt = signal as? ProactiveTriggerSignal.WatchtowerPageSignal ?: return
        val monitorId = wt.monitorId ?: return
        val monitor = monitorStore.get(monitorId) ?: return
        when (result) {
            is ProactiveRunResult.DroppedAtL1 -> {
                val nextInterval = maxOf(monitor.intervalMinutes, result.outcome.recommendedPollIntervalMinutes)
                monitorStore.recordCheckResult(
                    id = monitorId,
                    checkedAtMs = nowEpochMs,
                    outcome = "unchanged",
                    summary = result.outcome.reason,
                    consecutiveUnchanged = result.outcome.consecutiveUnchanged,
                    effectiveIntervalMinutes = nextInterval,
                )
            }
            is ProactiveRunResult.PushedAtL3 -> {
                monitorStore.recordCheckResult(
                    id = monitorId,
                    checkedAtMs = nowEpochMs,
                    outcome = "pushed",
                    summary = result.l2Score?.summary ?: result.card.title,
                    consecutiveUnchanged = 0,
                    effectiveIntervalMinutes = monitor.intervalMinutes,
                )
            }
            is ProactiveRunResult.SuppressedAtGate -> {
                val verdict = result.restraintVerdict
                val reason = when (verdict) {
                    is RestraintVerdict.SuppressedQuietHours -> verdict.reason
                    is RestraintVerdict.DeferredByBudget -> verdict.reason
                    is RestraintVerdict.DroppedLowScore -> verdict.reason
                    is RestraintVerdict.AllowedToPush -> "allowed"
                }
                val outcome = if (
                    result.l1Delta.urgency == ProactiveUrgency.DIGEST &&
                    verdict is RestraintVerdict.DeferredByBudget &&
                    verdict.bufferedForMorningBriefing
                ) {
                    "digest"
                } else {
                    "suppressed"
                }
                monitorStore.recordCheckResult(
                    id = monitorId,
                    checkedAtMs = nowEpochMs,
                    outcome = outcome,
                    summary = reason,
                    consecutiveUnchanged = 0,
                    effectiveIntervalMinutes = monitor.intervalMinutes,
                )
            }
        }
    }
}
