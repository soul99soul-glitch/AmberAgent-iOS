package app.amber.cloud.gateway

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.nio.charset.StandardCharsets
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.interfaces.ECPrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Duration
import java.util.Base64

data class ApnsConfig(
    val keyId: String,
    val teamId: String,
    val topic: String,
    val privateKeyPem: String,
) {
    override fun toString(): String =
        "ApnsConfig(keyId=$keyId, teamId=$teamId, topic=$topic, privateKeyPem=<redacted>)"
}

/**
 * 真实 JVM APNs HTTP/2 发送器（复用 Ktor OkHttp ALPN，ES256 P1363 JWT 缓存 50 分钟）。
 *
 * 严格安全红线：
 * - `.p8` 私钥与签发 JWT 永不写入日志、异常消息或审计；
 * - 收到 `410` / `BadDeviceToken` / `Unregistered` 时回调 [onInvalidToken] 清理设备 token；
 * - 收到 `403 ExpiredProviderToken` 时立即重签 Provider token 并重试一次；
 * - `passive` / `silent` 推送绝不携带 `sound` 与 `content-available`，`apns-priority` 为 `5`。
 */
class ApnsPushSender(
    private val config: ApnsConfig,
    private val deviceLookup: (deviceId: String) -> PairedDevice?,
    private val onInvalidToken: (deviceId: String, pushToken: String, reason: String) -> Unit = { _, _, _ -> },
    httpClient: HttpClient? = null,
    private val baseUrlOverride: String? = null,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) : PushSender {

    private val client by lazy { httpClient ?: defaultHttpClient() }
    private val privateKey: ECPrivateKey
    private val tokenLock = Any()
    private var cachedToken: String? = null
    private var cachedAtMs: Long = Long.MIN_VALUE

    init {
        require(config.keyId.isNotBlank()) { "apns_key_id_blank" }
        require(config.teamId.isNotBlank()) { "apns_team_id_blank" }
        require(config.topic.isNotBlank()) { "apns_topic_blank" }
        privateKey = parseEcPrivateKey(config.privateKeyPem)
    }

    override suspend fun send(payload: PushMessagePayload): Result<Unit> {
        val token = payload.pushToken.trim()
        if (token.isEmpty()) {
            return Result.failure(IllegalArgumentException("missing_push_token"))
        }
        val baseUrl = resolveBaseUrl(payload.deviceId, token)
            ?: return Result.failure(IllegalStateException("invalid_push_registration"))

        val nowMs = clockMs()
        val nowSec = nowMs / 1000L
        val interruptionLevel = resolveInterruptionLevel(payload)
        val isPassive = interruptionLevel == "passive"
        val collapseId = resolveCollapseId(payload)
        val bodyJson = buildApnsPayloadJson(payload, interruptionLevel)

        val firstJwt = getOrSignJwt(nowMs)
        val firstAttempt = sendOnce(
            baseUrl = baseUrl,
            deviceToken = token,
            jwt = firstJwt,
            bodyJson = bodyJson,
            isPassive = isPassive,
            expirationEpochSec = nowSec + DEFAULT_EXPIRATION_SECONDS,
            collapseId = collapseId,
        )

        if (firstAttempt.isSuccess) return Result.success(Unit)
        val firstResponse = firstAttempt.exceptionOrNull() as? ApnsHttpRejectedException
        if (firstResponse != null && firstResponse.status == 403 && firstResponse.reason == "ExpiredProviderToken") {
            if (resolveBaseUrl(payload.deviceId, token) != baseUrl) {
                return Result.failure(IllegalStateException("push_registration_changed"))
            }
            val retryNowMs = clockMs()
            val retryAttempt = sendOnce(
                baseUrl = baseUrl,
                deviceToken = token,
                jwt = synchronized(tokenLock) { getOrSignJwt(retryNowMs, forceRefresh = cachedToken == firstJwt) },
                bodyJson = bodyJson,
                isPassive = isPassive,
                expirationEpochSec = (retryNowMs / 1000L) + DEFAULT_EXPIRATION_SECONDS,
                collapseId = collapseId,
            )
            return handleFinalResult(payload, token, retryAttempt)
        }
        return handleFinalResult(payload, token, firstAttempt)
    }

    private fun handleFinalResult(
        payload: PushMessagePayload,
        token: String,
        attempt: Result<Unit>,
    ): Result<Unit> {
        if (attempt.isSuccess) return Result.success(Unit)
        val err = attempt.exceptionOrNull()
        if (err is ApnsHttpRejectedException) {
            if (err.status == 410 || err.reason in INVALID_TOKEN_REASONS) {
                runCatching { onInvalidToken(payload.deviceId, token, err.reason.ifBlank { "http_${err.status}" }) }
            }
            return Result.failure(IllegalStateException("apns_rejected:${err.status}:${err.reason.ifBlank { "unknown" }}"))
        }
        return attempt
    }

    private suspend fun sendOnce(
        baseUrl: String,
        deviceToken: String,
        jwt: String,
        bodyJson: String,
        isPassive: Boolean,
        expirationEpochSec: Long,
        collapseId: String?,
    ): Result<Unit> {
        return try {
            withTimeoutOrNull(REQUEST_TIMEOUT_MS) {
                val response = client.post("$baseUrl/3/device/$deviceToken") {
                    contentType(ContentType.Application.Json)
                    header("authorization", "bearer $jwt")
                    header("apns-push-type", "alert")
                    header("apns-topic", config.topic)
                    header("apns-priority", if (isPassive) "5" else "10")
                    header("apns-expiration", expirationEpochSec.toString())
                    if (!collapseId.isNullOrEmpty()) {
                        header("apns-collapse-id", collapseId)
                    }
                    setBody(bodyJson)
                }
                val code = response.status.value
                if (code in 200..299) {
                    Result.success(Unit)
                } else {
                    val reason = parseApnsErrorReason(response.bodyAsText())
                    Result.failure(ApnsHttpRejectedException(code, reason))
                }
            } ?: Result.failure(IllegalStateException("apns_transport_timeout"))
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Exception) {
            Result.failure(IllegalStateException("apns_transport_failed"))
        }
    }

    internal fun getOrSignJwt(nowMs: Long = clockMs(), forceRefresh: Boolean = false): String = synchronized(tokenLock) {
        val current = cachedToken
        if (!forceRefresh && current != null && nowMs >= cachedAtMs && (nowMs - cachedAtMs) < TOKEN_CACHE_TTL_MS) {
            return@synchronized current
        }
        val signed = signJwt(nowMs / 1000L)
        cachedToken = signed
        cachedAtMs = nowMs
        signed
    }

    private fun signJwt(issuedAtEpochSec: Long): String {
        val headerJson = compactJson.encodeToString(
            JsonObject.serializer(),
            buildJsonObject {
                put("alg", "ES256")
                put("kid", config.keyId)
            },
        )
        val claimsJson = compactJson.encodeToString(
            JsonObject.serializer(),
            buildJsonObject {
                put("iss", config.teamId)
                put("iat", issuedAtEpochSec)
            },
        )
        val headerB64 = base64Url(headerJson.toByteArray(StandardCharsets.UTF_8))
        val claimsB64 = base64Url(claimsJson.toByteArray(StandardCharsets.UTF_8))
        val signingInput = "$headerB64.$claimsB64"
        val signer = Signature.getInstance(ES256_P1363_ALGORITHM)
        signer.initSign(privateKey)
        signer.update(signingInput.toByteArray(StandardCharsets.US_ASCII))
        val sigBytes = signer.sign()
        return "$signingInput.${base64Url(sigBytes)}"
    }

    private fun resolveBaseUrl(deviceId: String, token: String): String? {
        val device = deviceLookup(deviceId) ?: return null
        if (device.pushToken != token) return null
        val host = when (device.pushEnvironment) {
            "sandbox" -> SANDBOX_BASE_URL
            "production" -> PRODUCTION_BASE_URL
            else -> return null
        }
        return baseUrlOverride?.trim()?.trimEnd('/')?.takeIf { it.isNotEmpty() } ?: host
    }

    private fun resolveInterruptionLevel(payload: PushMessagePayload): String {
        val explicit = payload.interruptionLevel?.trim()?.lowercase()
        if (explicit in VALID_INTERRUPTION_LEVELS) return explicit!!
        return if (payload.silent) "passive" else "active"
    }

    private fun resolveCollapseId(payload: PushMessagePayload): String? {
        val raw = payload.signalId?.trim()?.takeIf { it.isNotEmpty() }
            ?: payload.toolCallId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return null
        return truncateUtf8Bytes(raw, MAX_COLLAPSE_ID_BYTES).takeIf { it.isNotEmpty() }
    }

    private fun buildApnsPayloadJson(payload: PushMessagePayload, interruptionLevel: String): String {
        val isPassive = interruptionLevel == "passive"
        val root = buildJsonObject {
            putJsonObject("aps") {
                putJsonObject("alert") {
                    put("title", payload.title)
                    put("body", payload.body)
                }
                payload.category?.takeIf { it.isNotBlank() }?.let { cat ->
                    put("category", cat)
                    if (cat == PROACTIVE_CATEGORY) {
                        put("thread-id", PROACTIVE_THREAD_ID)
                    }
                }
                put("interruption-level", interruptionLevel)
                if (!isPassive) {
                    put("sound", "default")
                }
            }
            payload.deepLink?.takeIf { it.isNotBlank() }?.let { put("deepLink", it) }
            payload.signalId?.takeIf { it.isNotBlank() }?.let { put("signalId", it) }
            payload.sessionKey?.takeIf { it.isNotBlank() }?.let { put("sessionKey", it) }
            payload.toolCallId?.takeIf { it.isNotBlank() }?.let { put("toolCallId", it) }
            payload.workItemId?.takeIf { it.isNotBlank() }?.let { put("workItemId", it) }
            if (payload.highRisk) {
                put("highRisk", true)
            }
        }
        return compactJson.encodeToString(JsonObject.serializer(), root)
    }

    private class ApnsHttpRejectedException(val status: Int, val reason: String) :
        RuntimeException("apns_rejected:$status:$reason")

    companion object {
        const val SANDBOX_BASE_URL = "https://api.sandbox.push.apple.com"
        const val PRODUCTION_BASE_URL = "https://api.push.apple.com"
        const val PROACTIVE_CATEGORY = "amber.proactive.card"
        const val PROACTIVE_THREAD_ID = "amber.proactive"
        const val TOKEN_CACHE_TTL_MS = 50 * 60_000L
        const val REQUEST_TIMEOUT_MS = 8_000L
        const val DEFAULT_EXPIRATION_SECONDS = 3600L
        const val MAX_COLLAPSE_ID_BYTES = 64

        private const val ES256_P1363_ALGORITHM = "SHA256withECDSAinP1363Format"
        private val VALID_INTERRUPTION_LEVELS = setOf("passive", "active", "time-sensitive")
        private val INVALID_TOKEN_REASONS = setOf("BadDeviceToken", "Unregistered")
        private val compactJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun defaultHttpClient(): HttpClient = HttpClient(OkHttp) {
            engine {
                config {
                    connectTimeout(Duration.ofMillis(REQUEST_TIMEOUT_MS))
                    readTimeout(Duration.ofMillis(REQUEST_TIMEOUT_MS))
                    writeTimeout(Duration.ofMillis(REQUEST_TIMEOUT_MS))
                    callTimeout(Duration.ofMillis(REQUEST_TIMEOUT_MS))
                }
            }
        }

        internal fun parseEcPrivateKey(pem: String): ECPrivateKey {
            val normalized = pem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replace(Regex("\\s+"), "")
            require(normalized.isNotEmpty()) { "invalid_apns_p8_key" }
            return try {
                val der = Base64.getDecoder().decode(normalized)
                val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(der))
                require(key is ECPrivateKey)
                val p256 = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
                require(key.params.order == p256.getParameterSpec(ECParameterSpec::class.java).order)
                key
            } catch (_: Exception) {
                throw IllegalArgumentException("invalid_apns_p8_key")
            }
        }

        internal fun truncateUtf8Bytes(raw: String, maxBytes: Int): String {
            if (maxBytes <= 0) return ""
            val bytes = raw.toByteArray(StandardCharsets.UTF_8)
            if (bytes.size <= maxBytes) return raw
            val sb = StringBuilder(raw.length)
            var used = 0
            var i = 0
            while (i < raw.length) {
                val cp = raw.codePointAt(i)
                val charCount = Character.charCount(cp)
                val chunk = raw.substring(i, i + charCount)
                val chunkBytes = chunk.toByteArray(StandardCharsets.UTF_8).size
                if (used + chunkBytes > maxBytes) break
                sb.append(chunk)
                used += chunkBytes
                i += charCount
            }
            return sb.toString()
        }

        private fun parseApnsErrorReason(body: String): String {
            if (body.isBlank()) return ""
            return runCatching {
                compactJson.parseToJsonElement(body).jsonObject["reason"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            }.getOrDefault("")
        }

        private fun base64Url(bytes: ByteArray): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
}
