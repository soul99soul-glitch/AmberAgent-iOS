package app.amber.cloud.security

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Unified credential redactor and placeholder guard for `amberd`, `:cloud-channels`, and `:cloud-proactive`.
 *
 * Enforces cross-platform known defect protections:
 * - Defect #2: Pending tool call details persisted to disk are scrubbed of sensitive fields.
 * - Defect #3: Credentials never enter history search/fetch, compaction summaries,
 *   `must_not_lose`, recaps, exports, backups, logs, or auxiliary L2 model prompts.
 * - Defect #4: Placeholder strings (`<redacted>`, `[REDACTED]`, `***`, `••••`, `«已脱敏»`)
 *   are rejected before entering the credential store or overwriting existing secrets.
 */
object CredentialRedactor {

    const val MASK = "«已脱敏»"

    private val SENSITIVE_JSON_KEYS = setOf(
        "password",
        "passphrase",
        "privatekey",
        "private_key",
        "secret",
        "secretkey",
        "secret_key",
        "apikey",
        "api_key",
        "l2_api_key",
        "accesstoken",
        "access_token",
        "tenant_access_token",
        "user_access_token",
        "refreshtoken",
        "refresh_token",
        "bottoken",
        "bot_token",
        "appsecret",
        "app_secret",
        "webhooksecret",
        "webhook_secret",
        "encryptkey",
        "encrypt_key",
        "caldavpassword",
        "caldav_password",
        "authorization",
        "bearer",
        "credential",
        "token",
    )

    private val INLINE_TOKEN_PATTERNS = listOf(
        // Telegram bot token in URL or text: bot123456:ABC-DEF...
        Regex("""(\bbot)\d{5,}:[A-Za-z0-9_\-]{10,}"""),
        // Raw Telegram token shape: 123456789:AAH...
        Regex("""\b\d{6,12}:[A-Za-z0-9_\-]{15,}\b"""),
        // Feishu tenant_access_token / user_access_token (t-xxx / u-xxx)
        Regex("""\b[tu]-[A-Za-z0-9._\-]{12,}\b"""),
        // Anthropic / OpenAI-style keys, including sk-ant-api03-…
        Regex("""\bsk-[A-Za-z0-9_\-]{12,}"""),
        // Bearer / Basic tokens in header dumps
        Regex("""(?i)(\b(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=\-]{8,}"""),
        // GitHub / GitLab / Slack tokens
        Regex("""\b(?:gh[pousr]_[A-Za-z0-9]{12,}|glpat-[A-Za-z0-9_\-]{12,}|xox[abprs]-[A-Za-z0-9\-]{10,})"""),
        // AWS access key IDs and Google API keys
        Regex("""\b(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{24,})"""),
        // JWTs: three base64url segments
        Regex("""\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"""),
    )

    private val ASSIGNMENT_PATTERN = Regex(
        """(?i)\b(api[_\- ]?key|l2[_\- ]?api[_\- ]?key|access[_\- ]?token|tenant[_\- ]?access[_\- ]?token|secret[_\- ]?key|private[_\- ]?key|bot[_\- ]?token|app[_\- ]?secret|webhook[_\- ]?secret|encrypt[_\- ]?key|caldav[_\- ]?password|passphrase|password|pass|secret|token)\b(\s*["']?\s*[:=]\s*["']?)([^"'\s,;)]{4,})"""
    )

    private val lenientJson = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Scrubs inline credentials and structured JSON secret keys from [text].
     */
    fun redact(text: String): String {
        if (text.isEmpty()) return text
        val trimmed = text.trim()
        val afterJsonPass = if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
            runCatching {
                val parsed = lenientJson.parseToJsonElement(trimmed)
                lenientJson.encodeToString(JsonElement.serializer(), redactJsonElement(parsed))
            }.getOrDefault(text)
        } else {
            text
        }
        return redactInlineOnly(afterJsonPass)
    }

    /**
     * Recursively masks values of sensitive JSON keys while preserving structure.
     */
    fun redactJsonElement(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(
            element.mapValues { (key, value) ->
                if (isSensitiveKey(key)) {
                    JsonPrimitive(MASK)
                } else {
                    redactJsonElement(value)
                }
            }
        )
        is JsonArray -> JsonArray(element.map(::redactJsonElement))
        is JsonPrimitive -> if (element.isString) {
            JsonPrimitive(redactInlineOnly(element.content))
        } else {
            element
        }
    }

    private fun redactInlineOnly(text: String): String {
        if (text.isEmpty()) return text
        var result = text
        for (regex in INLINE_TOKEN_PATTERNS) {
            result = regex.replace(result) { match ->
                if (match.groupValues.size > 1 && match.groupValues[1].isNotEmpty()) {
                    match.groupValues[1] + MASK
                } else {
                    MASK
                }
            }
        }
        result = ASSIGNMENT_PATTERN.replace(result) { match ->
            "${match.groupValues[1]}${match.groupValues[2]}$MASK"
        }
        return result
    }

    fun isSensitiveKey(key: String): Boolean {
        val normalized = key.trim().lowercase().replace("-", "_")
        return normalized in SENSITIVE_JSON_KEYS ||
            normalized.endsWith("_password") ||
            normalized.endsWith("_secret") ||
            normalized.endsWith("_api_key") ||
            normalized.endsWith("_private_key") ||
            normalized.endsWith("_encrypt_key") ||
            normalized.endsWith("_token")
    }

    /**
     * Returns true if [value] is a redacted placeholder (`<redacted>`, `[REDACTED]`,
     * `***`, `••••`, `«已脱敏»`, etc.) that must never be written into a credential store.
     */
    fun isPlaceholderCredential(value: String): Boolean {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return false
        val lowered = trimmed.lowercase()
        if (
            lowered == "<redacted>" ||
            lowered == "[redacted]" ||
            lowered == "redacted" ||
            lowered == "null" ||
            trimmed == MASK ||
            trimmed.contains(MASK) ||
            lowered.contains("<redacted>") ||
            lowered.contains("[redacted]")
        ) {
            return true
        }
        if (trimmed.length >= 3 && trimmed.all { it == '*' || it == '•' || it == '·' || it == '.' }) {
            return true
        }
        return false
    }

    /**
     * Checks a JSON object of tool arguments for any sensitive key whose value is a placeholder.
     * Returns the offending key name if found, or null if valid.
     */
    fun findPlaceholderCredentialKey(args: JsonObject): String? {
        for ((key, value) in args) {
            if (isSensitiveKey(key) && value is JsonPrimitive && value.isString) {
                if (isPlaceholderCredential(value.content)) {
                    return key
                }
            } else if (value is JsonObject) {
                findPlaceholderCredentialKey(value)?.let { return "$key.$it" }
            }
        }
        return null
    }
}
