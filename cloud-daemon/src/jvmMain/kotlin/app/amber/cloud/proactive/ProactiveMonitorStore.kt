package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.tasks.PublicHttp
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.HttpHeaders
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.net.InetAddress
import java.net.URI
import java.nio.charset.StandardCharsets
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
)

/**
 * 面向主动巡检的 URL 安全校验（仅允许无内嵌凭据的公网 `http`/`https`，拦截回环、私网与链路本地地址）。
 */
object ProactiveUrlGuard {
    private val BLOCKED_HOST_SUFFIXES = listOf(".localhost", ".local", ".internal", ".localdomain")

    /**
     * 静态校验（创建/更新监控规则时立即执行，不依赖外部网络 DNS）：
     * - 必须是 `http` 或 `https`
     * - 禁止内嵌 `userInfo`
     * - 禁止 `localhost`、内网后缀、IPv4/IPv6 回环/私网/链路本地/多播字面量
     */
    fun validateSyntaxAndLiteralHost(rawUrl: String): URI {
        val clean = rawUrl.trim()
        require(clean.isNotEmpty()) { "监控 URL 不能为空" }
        require(clean.length <= 2_048) { "监控 URL 过长" }
        val uri = runCatching { URI(clean) }.getOrNull()
            ?: throw IllegalArgumentException("监控 URL 格式非法")
        val scheme = uri.scheme?.lowercase()
        require(scheme in setOf("http", "https")) { "仅允许 http/https 公开地址" }
        require(uri.userInfo == null) { "监控 URL 不允许内嵌凭据" }
        val host = uri.host?.trim()?.lowercase()?.removePrefix("[")?.removeSuffix("]")
            ?: throw IllegalArgumentException("监控 URL 缺少主机名")
        require(host.isNotEmpty()) { "监控 URL 缺少主机名" }
        if (host == "localhost" || BLOCKED_HOST_SUFFIXES.any { host.endsWith(it) }) {
            throw IllegalArgumentException("拒绝本机或私网地址: $host")
        }
        // 若主机名是 IP 字面量（IPv4 或 IPv6），立即做公网校验
        if (looksLikeIpLiteral(host)) {
            val addr = runCatching { InetAddress.getByName(host) }.getOrNull()
                ?: throw IllegalArgumentException("非法 IP 地址: $host")
            if (!PublicHttp.publicAddress(addr)) {
                throw IllegalArgumentException("拒绝回环、私网或链路本地地址: $host")
            }
        }
        return uri
    }

    /**
     * 请求前完整校验（含 DNS 解析校验，防 DNS 重绑定至私网/回环/链路本地地址）。
     */
    fun validatePublicUrl(
        rawUrl: String,
        dnsResolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() },
    ): URI {
        val uri = validateSyntaxAndLiteralHost(rawUrl)
        val host = uri.host.trim().lowercase().removePrefix("[").removeSuffix("]")
        val resolved = runCatching { dnsResolver(host) }.getOrElse {
            throw IllegalArgumentException("无法解析主机名: $host")
        }
        require(resolved.isNotEmpty()) { "无法解析主机名: $host" }
        for (addr in resolved) {
            if (!PublicHttp.publicAddress(addr)) {
                throw IllegalArgumentException("拒绝解析到非公网地址的目标: $host")
            }
        }
        return uri
    }

    private fun looksLikeIpLiteral(host: String): Boolean {
        if (host.contains(':')) return true // IPv6
        if (host.all { it.isDigit() || it == '.' }) return true // dotted IPv4 or decimal IP
        if (host.startsWith("0x") && host.drop(2).all { it.isDigit() || it in 'a'..'f' }) return true
        return false
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
        nowMs: Long = clockMs(),
    ): ProactiveMonitorRecord {
        val cleanUrl = url.trim()
        ProactiveUrlGuard.validateSyntaxAndLiteralHost(cleanUrl)
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
        nowMs: Long = clockMs(),
    ): ProactiveMonitorRecord? {
        val existing = records[id] ?: return null
        val nextUrl = if (url != null) {
            val trimmed = url.trim()
            ProactiveUrlGuard.validateSyntaxAndLiteralHost(trimmed)
            trimmed
        } else existing.url
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
    private val httpClient: HttpClient = HttpClient(OkHttp) {
        followRedirects = false
    },
    private val dnsResolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() },
    private val maxResponseBytes: Int = 512 * 1024,
) : TriggerSource {

    override val id: String = "watchtower_monitors"
    override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR

    override suspend fun pollAll(nowEpochMs: Long): List<ProactiveTriggerSignal> {
        val due = monitorStore.dueMonitors(nowEpochMs)
        if (due.isEmpty()) return emptyList()
        val signals = mutableListOf<ProactiveTriggerSignal>()

        for (monitor in due) {
            val validation = runCatching {
                ProactiveUrlGuard.validatePublicUrl(monitor.url, dnsResolver)
            }
            if (validation.isFailure) {
                monitorStore.recordCheckResult(
                    id = monitor.id,
                    checkedAtMs = nowEpochMs,
                    outcome = "blocked_ssrf",
                    summary = validation.exceptionOrNull()?.message ?: "SSRF 校验拦截",
                    consecutiveUnchanged = monitor.consecutiveUnchanged,
                    effectiveIntervalMinutes = maxOf(monitor.intervalMinutes, 60),
                )
                continue
            }

            val prevEtag = l1Filter.getWatchtowerSnapshot(monitor.url)?.etag
            val fetchResult = runCatching {
                val response = httpClient.get(monitor.url) {
                    if (!prevEtag.isNullOrBlank()) {
                        header(HttpHeaders.IfNoneMatch, prevEtag)
                    }
                }
                val status = response.status.value
                val etag = response.headers[HttpHeaders.ETag]
                val body = if (status == 304) {
                    ""
                } else {
                    val bytes = response.bodyAsBytes()
                    val capped = if (bytes.size > maxResponseBytes) bytes.copyOf(maxResponseBytes) else bytes
                    String(capped, StandardCharsets.UTF_8)
                }
                Triple(status, etag, body)
            }

            if (fetchResult.isFailure) {
                monitorStore.recordCheckResult(
                    id = monitor.id,
                    checkedAtMs = nowEpochMs,
                    outcome = "error",
                    summary = fetchResult.exceptionOrNull()?.message ?: "抓取失败",
                    consecutiveUnchanged = monitor.consecutiveUnchanged,
                    effectiveIntervalMinutes = maxOf(monitor.intervalMinutes, 15),
                )
                continue
            }

            val (status, etag, bodyText) = fetchResult.getOrThrow()
            signals.add(
                ProactiveTriggerSignal.WatchtowerPageSignal(
                    signalId = "wt_${monitor.id}_$nowEpochMs",
                    url = monitor.url,
                    title = monitor.title,
                    httpStatusCode = status,
                    etag = etag,
                    rawBody = bodyText,
                    conditionPrompt = monitor.conditionPrompt,
                    monitorId = monitor.id,
                    topicKey = "watchtower:${monitor.id}",
                    timestampEpochMs = nowEpochMs,
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
                val reason = when (val v = result.restraintVerdict) {
                    is RestraintVerdict.SuppressedQuietHours -> v.reason
                    is RestraintVerdict.DeferredByBudget -> v.reason
                    is RestraintVerdict.DroppedLowScore -> v.reason
                    is RestraintVerdict.AllowedToPush -> "allowed"
                }
                monitorStore.recordCheckResult(
                    id = monitorId,
                    checkedAtMs = nowEpochMs,
                    outcome = "suppressed",
                    summary = reason,
                    consecutiveUnchanged = 0,
                    effectiveIntervalMinutes = monitor.intervalMinutes,
                )
            }
        }
    }
}
