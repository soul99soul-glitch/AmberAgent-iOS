package app.amber.cloud.gateway

import app.amber.cloud.security.CredentialRedactor
import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions

@Serializable
data class CalendarUpcomingItem(
    val title: String,
    val startMs: Long,
    val endMs: Long,
    val allDay: Boolean,
)

@Serializable
data class CalendarUpcomingDomain(
    val items: List<CalendarUpcomingItem> = emptyList(),
)

@Serializable
data class RemindersDueItem(
    val title: String,
    val dueMs: Long? = null,
    val priority: Int? = null,
)

@Serializable
data class RemindersDueDomain(
    val items: List<RemindersDueItem> = emptyList(),
)

@Serializable
data class WorkspaceArtifactSummaryItem(
    val id: String,
    val title: String,
    val type: String,
    val updatedAtMs: Long,
    val summary: String,
)

@Serializable
data class WorkspaceArtifactsDomain(
    val items: List<WorkspaceArtifactSummaryItem> = emptyList(),
)

@Serializable
data class DeviceContextDomains(
    val calendarUpcoming: CalendarUpcomingDomain? = null,
    val remindersDue: RemindersDueDomain? = null,
    val workspaceArtifacts: WorkspaceArtifactsDomain? = null,
) {
    fun presentDomainNames(): List<String> = buildList {
        if (calendarUpcoming != null) add("calendarUpcoming")
        if (remindersDue != null) add("remindersDue")
        if (workspaceArtifacts != null) add("workspaceArtifacts")
    }
}

@Serializable
data class StoredDeviceContextSnapshot(
    val deviceId: String,
    val deviceName: String = "",
    val capturedAtEpochMs: Long,
    val ttlSeconds: Long,
    val expiresAtEpochMs: Long,
    val domains: DeviceContextDomains,
)

/**
 * Per-device `0600` snapshot store for iOS foreground context sharing (§3.3 B1 / X3).
 */
class DeviceContextSnapshotStore(
    val dir: File,
) {
    private val strictJson = Json { ignoreUnknownKeys = false; prettyPrint = false; encodeDefaults = false }
    private val tolerantJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    init {
        dir.mkdirs()
        setPosix0700(dir)
    }

    sealed interface PutResult {
        data class Stored(val snapshot: StoredDeviceContextSnapshot) : PutResult
        data class Error(val status: Int, val message: String) : PutResult
    }

    sealed interface ReadResult {
        data class Active(val snapshot: StoredDeviceContextSnapshot) : ReadResult
        data class Expired(val capturedAtEpochMs: Long) : ReadResult
        data object Missing : ReadResult
    }

    @Synchronized
    fun putRawJson(
        device: PairedDevice,
        rawBytes: ByteArray,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): PutResult {
        if (device.platform != "ios") {
            return PutResult.Error(403, "仅限已配对 iOS 设备写入设备上下文快照")
        }
        if (rawBytes.size > MAX_BODY_BYTES) {
            return PutResult.Error(413, "设备上下文快照不能超过 32 KiB")
        }
        val bodyText = runCatching { rawBytes.toString(Charsets.UTF_8) }.getOrElse {
            return PutResult.Error(400, "无效 UTF-8 请求体")
        }
        val obj = runCatching { Json.parseToJsonElement(bodyText).jsonObject }.getOrElse {
            return PutResult.Error(400, "需要合法 JSON 对象")
        }
        val unknownRoot = obj.keys - ALLOWED_ROOT_KEYS
        if (unknownRoot.isNotEmpty()) {
            return PutResult.Error(400, "不允许未声明字段: ${unknownRoot.sorted().joinToString(",")}")
        }
        val bodyDeviceId = obj["deviceId"]?.let {
            val value = it as? JsonPrimitive ?: return PutResult.Error(400, "deviceId 必须为字符串")
            if (!value.isString) return PutResult.Error(400, "deviceId 必须为字符串")
            value.content.trim()
        }
        if (!bodyDeviceId.isNullOrEmpty() && bodyDeviceId != device.id) {
            return PutResult.Error(403, "deviceId 与当前认证设备不一致")
        }
        val capturedAt = (obj["capturedAtEpochMs"] as? JsonPrimitive)?.longOrNull
            ?: return PutResult.Error(400, "缺少合法 capturedAtEpochMs")
        if (capturedAt < 0L) {
            return PutResult.Error(400, "capturedAtEpochMs 不能为负数")
        }
        val rawTtl = if ("ttlSeconds" in obj) {
            (obj["ttlSeconds"] as? JsonPrimitive)?.longOrNull ?: return PutResult.Error(400, "ttlSeconds 必须为整数")
        } else DEFAULT_TTL_SECONDS
        val ttlSeconds = rawTtl.coerceIn(MIN_TTL_SECONDS, MAX_TTL_SECONDS)
        // Client clocks may run ahead; retention can never exceed the server's hard TTL.
        val expiresAt = minOf(capturedAt, nowEpochMs) + ttlSeconds * 1000L

        val domainsEl = obj["domains"]
            ?: return PutResult.Error(400, "缺少 domains 对象")
        val domainsObj = domainsEl as? JsonObject
            ?: return PutResult.Error(400, "domains 必须为 JSON 对象")
        val unknownDomains = domainsObj.keys - ALLOWED_DOMAIN_KEYS
        if (unknownDomains.isNotEmpty()) {
            return PutResult.Error(400, "不支持的上下文域: ${unknownDomains.sorted().joinToString(",")}")
        }

        val calendarDomain = if ("calendarUpcoming" in domainsObj) {
            parseCalendarDomain(domainsObj["calendarUpcoming"]).let { res ->
                if (res.isFailure) return PutResult.Error(400, res.exceptionOrNull()?.message ?: "calendarUpcoming 格式错误")
                res.getOrNull()
            }
        } else null

        val remindersDomain = if ("remindersDue" in domainsObj) {
            parseRemindersDomain(domainsObj["remindersDue"]).let { res ->
                if (res.isFailure) return PutResult.Error(400, res.exceptionOrNull()?.message ?: "remindersDue 格式错误")
                res.getOrNull()
            }
        } else null

        val artifactsDomain = if ("workspaceArtifacts" in domainsObj) {
            parseArtifactsDomain(domainsObj["workspaceArtifacts"]).let { res ->
                if (res.isFailure) return PutResult.Error(400, res.exceptionOrNull()?.message ?: "workspaceArtifacts 格式错误")
                res.getOrNull()
            }
        } else null

        val snapshot = StoredDeviceContextSnapshot(
            deviceId = device.id,
            deviceName = CredentialRedactor.redact(device.name).take(120),
            capturedAtEpochMs = capturedAt,
            ttlSeconds = ttlSeconds,
            expiresAtEpochMs = expiresAt,
            domains = DeviceContextDomains(
                calendarUpcoming = calendarDomain,
                remindersDue = remindersDomain,
                workspaceArtifacts = artifactsDomain,
            ),
        )
        val target = fileForDevice(device.id)
        atomicWrite0600(target, tolerantJson.encodeToString(snapshot))
        return PutResult.Stored(snapshot)
    }

    @Synchronized
    fun read(deviceId: String, nowEpochMs: Long = System.currentTimeMillis()): ReadResult {
        val file = fileForDevice(deviceId)
        if (!file.exists()) return ReadResult.Missing
        val snapshot = runCatching {
            strictJson.decodeFromString<StoredDeviceContextSnapshot>(file.readText())
        }.getOrElse {
            file.delete()
            return ReadResult.Missing
        }
        if (nowEpochMs >= snapshot.expiresAtEpochMs) {
            file.delete()
            return ReadResult.Expired(snapshot.capturedAtEpochMs)
        }
        return ReadResult.Active(snapshot)
    }

    @Synchronized
    fun delete(deviceId: String): Boolean {
        val file = fileForDevice(deviceId)
        return file.exists() && file.delete()
    }

    /**
     * 读取所有未过期的设备上下文快照（自动清理已过期或损坏文件）。
     */
    @Synchronized
    fun listActiveSnapshots(
        nowEpochMs: Long = System.currentTimeMillis(),
        allowedDeviceIds: Set<String>? = null,
    ): List<StoredDeviceContextSnapshot> {
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".json") } ?: return emptyList()
        val active = mutableListOf<StoredDeviceContextSnapshot>()
        for (file in files) {
            val snapshot = runCatching {
                strictJson.decodeFromString<StoredDeviceContextSnapshot>(file.readText())
            }.getOrNull()
            if (snapshot == null || nowEpochMs >= snapshot.expiresAtEpochMs) {
                file.delete()
                continue
            }
            if (allowedDeviceIds != null && snapshot.deviceId !in allowedDeviceIds) {
                continue
            }
            active.add(snapshot)
        }
        return active.sortedByDescending { it.capturedAtEpochMs }
    }

    @Synchronized
    fun purgeExpired(nowEpochMs: Long = System.currentTimeMillis()): Int {
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".json") } ?: return 0
        var removed = 0
        for (file in files) {
            val snapshot = runCatching {
                strictJson.decodeFromString<StoredDeviceContextSnapshot>(file.readText())
            }.getOrNull()
            if (snapshot == null || nowEpochMs >= snapshot.expiresAtEpochMs) {
                if (file.delete()) removed++
            }
        }
        return removed
    }

    @Synchronized
    fun readForOwnerDevices(
        pairedIosDevices: List<PairedDevice>,
        domainFilter: String = "all",
        requestedDeviceId: String? = null,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): JsonObject {
        val normalizedDomain = domainFilter.trim().ifEmpty { "all" }
        val candidates = if (!requestedDeviceId.isNullOrBlank()) {
            pairedIosDevices.filter { it.id == requestedDeviceId && it.platform == "ios" }
        } else {
            pairedIosDevices.filter { it.platform == "ios" }
        }

        val active = mutableListOf<StoredDeviceContextSnapshot>()
        var latestExpiredCapturedAt: Long? = null
        for (dev in candidates) {
            when (val res = read(dev.id, nowEpochMs)) {
                is ReadResult.Active -> active += res.snapshot
                is ReadResult.Expired -> {
                    if (latestExpiredCapturedAt == null || res.capturedAtEpochMs > latestExpiredCapturedAt) {
                        latestExpiredCapturedAt = res.capturedAtEpochMs
                    }
                }
                ReadResult.Missing -> Unit
            }
        }

        if (active.isEmpty()) {
            return if (latestExpiredCapturedAt != null) {
                buildJsonObject {
                    put("status", "expired")
                    put("capturedAtEpochMs", latestExpiredCapturedAt)
                }
            } else {
                buildJsonObject {
                    put("status", "not_shared")
                    put("hint", "主人尚未在 iOS 网关设置开启对应本机只读摘要共享")
                }
            }
        }

        val filteredDevices = active.mapNotNull { snap ->
            val dataObj = buildFilteredUntrustedJson(snap, normalizedDomain)
            if (dataObj.isEmpty()) null else snap to dataObj
        }
        if (filteredDevices.isEmpty()) {
            return buildJsonObject {
                put("status", "not_shared")
                put("hint", "主人尚未开启该域只读摘要共享")
            }
        }

        return buildJsonObject {
            put("status", "ok")
            put(
                "devices",
                buildJsonArray {
                    for ((snap, dataObj) in filteredDevices) {
                        add(
                            buildJsonObject {
                                put("deviceName", escapeUntrustedTag(snap.deviceName.ifBlank { snap.deviceId }))
                                put("capturedAtEpochMs", snap.capturedAtEpochMs)
                                put("expiresAtEpochMs", snap.expiresAtEpochMs)
                                put("untrusted_device_data", dataObj)
                                put("wrapped", formatUntrustedDeviceData(snap, dataObj))
                            }
                        )
                    }
                }
            )
        }
    }

    private fun parseCalendarDomain(el: kotlinx.serialization.json.JsonElement?): Result<CalendarUpcomingDomain> = runCatching {
        val obj = el as? JsonObject ?: error("calendarUpcoming 必须为对象")
        val extra = obj.keys - setOf("items")
        require(extra.isEmpty()) { "calendarUpcoming 不允许额外字段: ${extra.joinToString(",")}" }
        val itemsArr = obj["items"] as? JsonArray ?: error("calendarUpcoming.items 必须为数组")
        require(itemsArr.size <= MAX_CALENDAR_ITEMS) { "calendarUpcoming.items 最多 $MAX_CALENDAR_ITEMS 条" }
        val items = itemsArr.map { itemEl ->
            val itemObj = itemEl as? JsonObject ?: error("calendar item 必须为对象")
            val itemExtra = itemObj.keys - ALLOWED_CALENDAR_ITEM_KEYS
            require(itemExtra.isEmpty()) { "calendar item 不允许字段: ${itemExtra.joinToString(",")}" }
            val rawTitle = requireString(itemObj, "title", MAX_TITLE_CHARS)
            val startMs = itemObj["startMs"]?.jsonPrimitive?.longOrNull ?: error("calendar item 缺少 startMs")
            val endMs = itemObj["endMs"]?.jsonPrimitive?.longOrNull ?: error("calendar item 缺少 endMs")
            val allDay = itemObj["allDay"]?.jsonPrimitive?.booleanOrNull ?: error("calendar item 缺少 allDay")
            CalendarUpcomingItem(
                title = CredentialRedactor.redact(rawTitle).take(MAX_TITLE_CHARS),
                startMs = startMs,
                endMs = endMs,
                allDay = allDay,
            )
        }
        CalendarUpcomingDomain(items)
    }

    private fun parseRemindersDomain(el: kotlinx.serialization.json.JsonElement?): Result<RemindersDueDomain> = runCatching {
        val obj = el as? JsonObject ?: error("remindersDue 必须为对象")
        val extra = obj.keys - setOf("items")
        require(extra.isEmpty()) { "remindersDue 不允许额外字段: ${extra.joinToString(",")}" }
        val itemsArr = obj["items"] as? JsonArray ?: error("remindersDue.items 必须为数组")
        require(itemsArr.size <= MAX_REMINDER_ITEMS) { "remindersDue.items 最多 $MAX_REMINDER_ITEMS 条" }
        val items = itemsArr.map { itemEl ->
            val itemObj = itemEl as? JsonObject ?: error("reminder item 必须为对象")
            val itemExtra = itemObj.keys - ALLOWED_REMINDER_ITEM_KEYS
            require(itemExtra.isEmpty()) { "reminder item 不允许字段: ${itemExtra.joinToString(",")}" }
            val rawTitle = requireString(itemObj, "title", MAX_TITLE_CHARS)
            val dueMs = itemObj["dueMs"]?.jsonPrimitive?.longOrNull
            val priority = itemObj["priority"]?.jsonPrimitive?.intOrNull
            RemindersDueItem(
                title = CredentialRedactor.redact(rawTitle).take(MAX_TITLE_CHARS),
                dueMs = dueMs,
                priority = priority,
            )
        }
        RemindersDueDomain(items)
    }

    private fun parseArtifactsDomain(el: kotlinx.serialization.json.JsonElement?): Result<WorkspaceArtifactsDomain> = runCatching {
        val obj = el as? JsonObject ?: error("workspaceArtifacts 必须为对象")
        val extra = obj.keys - setOf("items")
        require(extra.isEmpty()) { "workspaceArtifacts 不允许额外字段: ${extra.joinToString(",")}" }
        val itemsArr = obj["items"] as? JsonArray ?: error("workspaceArtifacts.items 必须为数组")
        require(itemsArr.size <= MAX_ARTIFACT_ITEMS) { "workspaceArtifacts.items 最多 $MAX_ARTIFACT_ITEMS 条" }
        val items = itemsArr.map { itemEl ->
            val itemObj = itemEl as? JsonObject ?: error("artifact item 必须为对象")
            val itemExtra = itemObj.keys - ALLOWED_ARTIFACT_ITEM_KEYS
            require(itemExtra.isEmpty()) { "artifact item 不允许字段: ${itemExtra.joinToString(",")}" }
            val id = requireString(itemObj, "id", 128)
            val title = requireString(itemObj, "title", MAX_TITLE_CHARS)
            val type = requireString(itemObj, "type", 40)
            val updatedAtMs = itemObj["updatedAtMs"]?.jsonPrimitive?.longOrNull ?: error("artifact 缺少 updatedAtMs")
            val summary = requireString(itemObj, "summary", MAX_ARTIFACT_SUMMARY_CHARS)
            WorkspaceArtifactSummaryItem(
                id = CredentialRedactor.redact(id).take(128),
                title = CredentialRedactor.redact(title).take(MAX_TITLE_CHARS),
                type = CredentialRedactor.redact(type).take(40),
                updatedAtMs = updatedAtMs,
                summary = CredentialRedactor.redact(summary).take(MAX_ARTIFACT_SUMMARY_CHARS),
            )
        }
        WorkspaceArtifactsDomain(items)
    }

    private fun requireString(obj: JsonObject, key: String, maxLen: Int): String {
        val primitive = obj[key] as? JsonPrimitive ?: error("缺少字符串字段 $key")
        require(primitive.isString) { "$key 必须为字符串" }
        val text = primitive.content.trim()
        require(text.length <= maxLen) { "$key 超过最大长度 $maxLen" }
        return text
    }

    private fun buildFilteredUntrustedJson(snapshot: StoredDeviceContextSnapshot, domainFilter: String): JsonObject =
        buildJsonObject {
            val includeAll = domainFilter == "all"
            if ((includeAll || domainFilter == "calendar" || domainFilter == "calendarUpcoming") && snapshot.domains.calendarUpcoming != null) {
                put(
                    "calendarUpcoming",
                    buildJsonObject {
                        put(
                            "items",
                            buildJsonArray {
                                snapshot.domains.calendarUpcoming.items.forEach { item ->
                                    add(
                                        buildJsonObject {
                                            put("title", escapeUntrustedTag(item.title))
                                            put("startMs", item.startMs)
                                            put("endMs", item.endMs)
                                            put("allDay", item.allDay)
                                        }
                                    )
                                }
                            }
                        )
                    }
                )
            }
            if ((includeAll || domainFilter == "reminders" || domainFilter == "remindersDue") && snapshot.domains.remindersDue != null) {
                put(
                    "remindersDue",
                    buildJsonObject {
                        put(
                            "items",
                            buildJsonArray {
                                snapshot.domains.remindersDue.items.forEach { item ->
                                    add(
                                        buildJsonObject {
                                            put("title", escapeUntrustedTag(item.title))
                                            item.dueMs?.let { put("dueMs", it) }
                                            item.priority?.let { put("priority", it) }
                                        }
                                    )
                                }
                            }
                        )
                    }
                )
            }
            if ((includeAll || domainFilter == "artifacts" || domainFilter == "workspaceArtifacts") && snapshot.domains.workspaceArtifacts != null) {
                put(
                    "workspaceArtifacts",
                    buildJsonObject {
                        put(
                            "items",
                            buildJsonArray {
                                snapshot.domains.workspaceArtifacts.items.forEach { item ->
                                    add(
                                        buildJsonObject {
                                            put("id", escapeUntrustedTag(item.id))
                                            put("title", escapeUntrustedTag(item.title))
                                            put("type", escapeUntrustedTag(item.type))
                                            put("updatedAtMs", item.updatedAtMs)
                                            put("summary", escapeUntrustedTag(item.summary))
                                        }
                                    )
                                }
                            }
                        )
                    }
                )
            }
        }

    private fun fileForDevice(deviceId: String): File = File(dir, "${sha256Hex(deviceId)}.json")

    private fun atomicWrite0600(target: File, content: String) {
        target.parentFile?.mkdirs()
        setPosix0700(target.parentFile)
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        setPosix0600(tmp)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        setPosix0600(target)
    }

    private fun setPosix0600(file: File?) {
        if (file == null || !file.exists()) return
        runCatching { Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------")) }
    }

    private fun setPosix0700(file: File?) {
        if (file == null || !file.exists()) return
        runCatching { Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rwx------")) }
    }

    companion object {
        const val MAX_BODY_BYTES = 32 * 1024
        const val MIN_TTL_SECONDS = 900L
        const val MAX_TTL_SECONDS = 86_400L
        const val DEFAULT_TTL_SECONDS = 43_200L
        const val MAX_TITLE_CHARS = 120
        const val MAX_ARTIFACT_SUMMARY_CHARS = 60
        const val MAX_CALENDAR_ITEMS = 20
        const val MAX_REMINDER_ITEMS = 20
        const val MAX_ARTIFACT_ITEMS = 10

        val ALLOWED_ROOT_KEYS = setOf("deviceId", "capturedAtEpochMs", "ttlSeconds", "domains")
        val ALLOWED_DOMAIN_KEYS = setOf("calendarUpcoming", "remindersDue", "workspaceArtifacts")
        val ALLOWED_CALENDAR_ITEM_KEYS = setOf("title", "startMs", "endMs", "allDay")
        val ALLOWED_REMINDER_ITEM_KEYS = setOf("title", "dueMs", "priority")
        val ALLOWED_ARTIFACT_ITEM_KEYS = setOf("id", "title", "type", "updatedAtMs", "summary")

        fun escapeUntrustedTag(raw: String): String =
            raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

        fun formatUntrustedDeviceData(snapshot: StoredDeviceContextSnapshot, filteredData: JsonObject): String {
            return "<untrusted_device_data device_id=\"${escapeUntrustedTag(snapshot.deviceId)}\" captured_at_ms=\"${snapshot.capturedAtEpochMs}\">\n" +
                filteredData.toString() +
                "\n</untrusted_device_data>"
        }

        fun sha256Hex(input: String): String {
            val digest = AmberNativeBridge.sha256(input.encodeToByteArray())
                ?: error("SHA-256 unavailable")
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}
