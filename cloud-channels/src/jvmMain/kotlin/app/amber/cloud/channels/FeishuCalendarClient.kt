package app.amber.cloud.channels

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.UUID

@Serializable
data class FeishuCalendarEvent(
    val id: String,
    val summary: String,
    val startTime: String,
    val endTime: String,
    val location: String = "飞书日历 (CalDAV)",
    val attendees: List<String> = emptyList(),
    val notes: String = "",
    val source: String = "feishu",
)

@Serializable
data class FeishuFreeSlot(
    val start: String,
    val end: String,
    val minutes: Int,
)

/**
 * 飞书日历客户端（CalDAV 直连 + OpenAPI 兜底 + 忙闲计算）。
 *
 * 1:1 移植自 `macApp/AmberMac/Runtime/DesktopPlugins.swift`（`:1159-1255`, `:2525-2736`）。
 */
class FeishuCalendarClient(
    private val calDavServerUrl: String = "https://caldav.feishu.cn",
    private val calDavUsername: String = "",
    private val secretLoader: ChannelSecretLoader,
    private val logger: RedactingChannelLogger,
    private val httpClient: HttpClient = HttpClient(OkHttp),
    private val zoneId: ZoneId = ZoneId.of("Asia/Shanghai"),
) {
    companion object {
        const val CONFIG_KEY_CALDAV_PASSWORD = "feishu.caldav_password"
        const val ENV_CALDAV_PASSWORD = "AMBER_FEISHU_CALDAV_PASSWORD"

        private val DATE_FORMATTER: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        private val DATE_TIME_FORMATTER: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

        /**
         * 移植自 `DesktopPlugins.swift:2585` `buildICalendarEvent`。
         */
        fun buildICalendarEvent(
            uid: String,
            summary: String,
            startTime: String,
            endTime: String,
            location: String = "飞书会议",
            notes: String = "",
        ): String {
            fun toIcsDateTime(raw: String): String {
                val digits = raw.filter { it.isDigit() }
                return if (digits.length >= 12) {
                    "${digits.substring(0, 8)}T${digits.substring(8, 12)}00"
                } else {
                    "20261031T090000"
                }
            }
            return listOf(
                "BEGIN:VCALENDAR",
                "VERSION:2.0",
                "PRODID:-//Amber//Feishu CalDAV Client//CN",
                "BEGIN:VEVENT",
                "UID:$uid",
                "DTSTART:${toIcsDateTime(startTime)}",
                "DTEND:${toIcsDateTime(endTime)}",
                "SUMMARY:$summary",
                "LOCATION:$location",
                "DESCRIPTION:$notes",
                "END:VEVENT",
                "END:VCALENDAR",
            ).joinToString("\r\n")
        }

        /**
         * 移植自 `DesktopPlugins.swift:2619` `parseCalDAVEICSData`。
         */
        fun parseCalDavIcsData(
            rawText: String,
            fallbackDate: String = "2026-10-31",
        ): List<FeishuCalendarEvent> {
            if (!rawText.contains("BEGIN:VEVENT")) return emptyList()
            val blocks = rawText.split("BEGIN:VEVENT").drop(1)
            val events = mutableListOf<FeishuCalendarEvent>()

            for (rawBlock in blocks) {
                val endIdx = rawBlock.indexOf("END:VEVENT")
                if (endIdx < 0) continue
                val unfolded = rawBlock.substring(0, endIdx)
                    .replace("\r\n ", "")
                    .replace("\n ", "")
                val lines = unfolded.lines()

                var uid = ""
                var summary = ""
                var dtStart = ""
                var dtEnd = ""
                var location = "飞书日历 (CalDAV)"
                var notes = ""

                for (line in lines) {
                    val trimmed = line.trim()
                    val colonIdx = trimmed.indexOf(':')
                    if (colonIdx <= 0) continue
                    val propPart = trimmed.substring(0, colonIdx).uppercase()
                    val valuePart = trimmed.substring(colonIdx + 1)
                        .replace("\\n", "\n")
                        .replace("\\,", ",")
                    val key = propPart.substringBefore(';')
                    when (key) {
                        "UID" -> uid = valuePart
                        "SUMMARY" -> summary = valuePart
                        "DTSTART" -> dtStart = parseIcsTimestamp(valuePart, fallbackDate)
                        "DTEND" -> dtEnd = parseIcsTimestamp(valuePart, fallbackDate)
                        "LOCATION" -> if (valuePart.isNotBlank()) location = valuePart
                        "DESCRIPTION" -> notes = valuePart
                    }
                }
                if (summary.isBlank()) continue
                val finalId = uid.ifBlank { "caldav_" + UUID.randomUUID().toString().take(8) }
                val startStr = dtStart.ifBlank { "$fallbackDate 09:00" }
                val endStr = dtEnd.ifBlank { "$fallbackDate 10:00" }
                events.add(
                    FeishuCalendarEvent(
                        id = finalId,
                        summary = summary,
                        startTime = startStr,
                        endTime = endStr,
                        location = location,
                        notes = notes,
                        source = "feishu",
                    )
                )
            }
            return events
        }

        private fun parseIcsTimestamp(raw: String, fallbackDate: String): String {
            val clean = raw.trim()
            val digits = clean.filter { it.isDigit() }
            if (digits.length < 8) return "$fallbackDate 09:00"
            val yyyy = digits.substring(0, 4)
            val mm = digits.substring(4, 6)
            val dd = digits.substring(6, 8)
            if (digits.length >= 12) {
                val hh = digits.substring(8, 10)
                val min = digits.substring(10, 12)
                return "$yyyy-$mm-$dd $hh:$min"
            }
            return "$yyyy-$mm-$dd 09:00"
        }

        /**
         * 移植自 `DesktopPlugins.swift:2707` `parseFeishuEventsResponse`。
         */
        fun parseFeishuOpenApiEvents(
            rawJson: String,
            fallbackDate: String = "2026-10-31",
            zoneId: ZoneId = ZoneId.of("Asia/Shanghai"),
        ): List<FeishuCalendarEvent> {
            val json = Json { ignoreUnknownKeys = true }
            val root = runCatching { json.parseToJsonElement(rawJson).jsonObject }.getOrNull() ?: return emptyList()
            val items = root["data"]?.jsonObject?.get("items")?.jsonArray ?: return emptyList()
            return items.mapNotNull { elem ->
                val item: JsonObject = elem.jsonObject
                val id = item["event_id"]?.jsonPrimitive?.content ?: UUID.randomUUID().toString()
                val summary = item["summary"]?.jsonPrimitive?.content?.trim().orEmpty().ifEmpty { "飞书日程" }
                val description = item["description"]?.jsonPrimitive?.content.orEmpty()
                val startSec = item["start_time"]?.jsonObject?.get("timestamp")?.jsonPrimitive?.longOrNull
                val endSec = item["end_time"]?.jsonObject?.get("timestamp")?.jsonPrimitive?.longOrNull
                val startStr = startSec?.let {
                    DATE_TIME_FORMATTER.withZone(zoneId).format(Instant.ofEpochSecond(it))
                } ?: "$fallbackDate 09:00"
                val endStr = endSec?.let {
                    DATE_TIME_FORMATTER.withZone(zoneId).format(Instant.ofEpochSecond(it))
                } ?: "$fallbackDate 10:00"
                val location = item["location"]?.jsonObject?.get("name")?.jsonPrimitive?.content ?: "飞书日历"
                FeishuCalendarEvent(
                    id = id,
                    summary = summary,
                    startTime = startStr,
                    endTime = endStr,
                    location = location,
                    notes = description,
                    source = "feishu",
                )
            }
        }

        /**
         * 移植自 `DesktopPlugins.swift:2525` `computeTodayFreeSlots`。
         */
        fun computeFreeSlots(
            datePrefix: String,
            events: List<FeishuCalendarEvent>,
            workdayStartHour: Int = 9,
            workdayEndHour: Int = 18,
            minDurationMinutes: Int = 30,
        ): List<FeishuFreeSlot> {
            val startHour = workdayStartHour.coerceIn(0, 23)
            val endHour = workdayEndHour.coerceIn(startHour + 1, 24)
            val busyRanges = events
                .filter { it.startTime.startsWith(datePrefix) }
                .mapNotNull { ev ->
                    val s = parseMinutesOfDay(ev.startTime) ?: return@mapNotNull null
                    val e = parseMinutesOfDay(ev.endTime) ?: return@mapNotNull null
                    if (e > s) s to e else null
                }
                .sortedBy { it.first }

            val slots = mutableListOf<FeishuFreeSlot>()
            var cursor = startHour * 60
            val dayEnd = endHour * 60
            for ((bStart, bEnd) in busyRanges) {
                if (bStart - cursor >= minDurationMinutes) {
                    slots.add(
                        FeishuFreeSlot(
                            start = "%02d:%02d".format(cursor / 60, cursor % 60),
                            end = "%02d:%02d".format(bStart / 60, bStart % 60),
                            minutes = bStart - cursor,
                        )
                    )
                }
                if (bEnd > cursor) cursor = bEnd
            }
            if (dayEnd - cursor >= minDurationMinutes) {
                slots.add(
                    FeishuFreeSlot(
                        start = "%02d:%02d".format(cursor / 60, cursor % 60),
                        end = "%02d:%02d".format(dayEnd / 60, dayEnd % 60),
                        minutes = dayEnd - cursor,
                    )
                )
            }
            return slots
        }

        private fun parseMinutesOfDay(dateTimeStr: String): Int? {
            if (dateTimeStr.length < 16) return null
            val hhmm = dateTimeStr.substring(11, 16).split(":")
            if (hhmm.size != 2) return null
            val h = hhmm[0].toIntOrNull() ?: return null
            val m = hhmm[1].toIntOrNull() ?: return null
            return h * 60 + m
        }
    }

    private val calDavPassword: SecretValue? =
        secretLoader.resolveOptionalSecret(CONFIG_KEY_CALDAV_PASSWORD, ENV_CALDAV_PASSWORD)

    /**
     * 通过 CalDAV REPORT 同步日程列表。
     */
    suspend fun syncCalDavEvents(fallbackDate: String = "2026-10-31"): List<FeishuCalendarEvent> {
        val password = calDavPassword
            ?: throw IllegalStateException("未配置飞书 CalDAV 密码 ($CONFIG_KEY_CALDAV_PASSWORD / $ENV_CALDAV_PASSWORD)")
        require(calDavUsername.isNotBlank()) { "未配置飞书 CalDAV 用户名" }

        val basicToken = Base64.getEncoder().encodeToString(
            "${calDavUsername.trim()}:${password.expose()}".toByteArray(StandardCharsets.UTF_8)
        )
        logger.registerLiteral(basicToken)

        val reportXml = """
            <?xml version="1.0" encoding="utf-8" ?>
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop>
                <d:getetag/>
                <c:calendar-data/>
              </d:prop>
              <c:filter>
                <c:comp-filter name="VCALENDAR">
                  <c:comp-filter name="VEVENT"/>
                </c:comp-filter>
              </c:filter>
            </c:calendar-query>
        """.trimIndent()

        val response = httpClient.request(calDavServerUrl) {
            method = HttpMethod.parse("REPORT")
            header(HttpHeaders.Authorization, "Basic $basicToken")
            header("Depth", "1")
            header(HttpHeaders.ContentType, ContentType.Application.Xml.toString())
            setBody(reportXml)
        }
        val rawBody = response.bodyAsText()
        val parsedIcs = parseCalDavIcsData(rawBody, fallbackDate = fallbackDate)
        val events = if (parsedIcs.isNotEmpty()) {
            parsedIcs
        } else {
            parseFeishuOpenApiEvents(rawBody, fallbackDate = fallbackDate, zoneId = zoneId)
        }
        logger.info("已同步飞书 CalDAV 日历: count=${events.size}")
        return events
    }
}
