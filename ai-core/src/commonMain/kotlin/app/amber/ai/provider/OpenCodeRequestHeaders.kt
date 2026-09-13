package app.amber.ai.provider

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import kotlin.uuid.Uuid

/**
 * Request headers required by the OpenCode hosted endpoints.
 *
 * The session header is deliberately derived from the request messages rather
 * than from provider configuration. A provider can serve multiple concurrent
 * conversations, so a provider-wide value would route those conversations to
 * the same OpenCode session.
 */
object OpenCodeRequestHeaders {
    const val SESSION_HEADER = "x-opencode-session"
    const val DEFAULT_USER_AGENT = "AmberAgent/1.0"

    /** Returns true only when the URL authority host is exactly `opencode.ai`. */
    fun isOpenCodeEndpoint(baseUrl: String): Boolean {
        val value = baseUrl.trim()
        val schemeEnd = value.indexOf("://")
        if (schemeEnd <= 0) return false

        val authorityStart = schemeEnd + 3
        val authorityEnd = value.indexOfFirstFrom(
            startIndex = authorityStart,
            delimiters = charArrayOf('/', '?', '#'),
        )
        val authority = value.substring(
            startIndex = authorityStart,
            endIndex = authorityEnd.takeIf { it >= 0 } ?: value.length,
        )
        val hostPort = authority.substringAfterLast('@')
        // OpenCode is a DNS host, not an IPv6 literal. Treat a bracketed host
        // as non-matching rather than accidentally accepting its prefix.
        if (hostPort.startsWith('[')) return false
        val host = hostPort.substringBefore(':')
        return host.equals("opencode.ai", ignoreCase = true)
    }

    /**
     * Adds OpenCode generation headers while preserving user-supplied values.
     * Header names are compared case-insensitively. Blank values for the two
     * generated headers are discarded so they cannot create duplicate headers
     * alongside the generated value.
     */
    fun forGeneration(
        baseUrl: String,
        messages: List<UIMessage>,
        customHeaders: List<CustomHeader> = emptyList(),
    ): List<CustomHeader> {
        val headers = customHeaders.filter { it.name.isNotBlank() }
        if (!isOpenCodeEndpoint(baseUrl)) return headers

        val explicitSession = headers.lastOrNull {
            it.name.equals(SESSION_HEADER, ignoreCase = true) && it.value.isNotBlank()
        }
        val explicitUserAgent = headers.lastOrNull {
            it.name.equals("User-Agent", ignoreCase = true) && it.value.isNotBlank()
        }
        val preserved = headers.filterNot { header ->
            header.name.equals(SESSION_HEADER, ignoreCase = true) ||
                header.name.equals("User-Agent", ignoreCase = true)
        }

        val sessionValue = explicitSession?.value ?: messages
            .firstOrNull { it.role == MessageRole.USER }
            ?.id
            ?.toString()
            ?: messages.firstOrNull()?.id?.toString()
            ?: Uuid.random().toString()

        return preserved + CustomHeader(
            name = SESSION_HEADER,
            value = sessionValue,
        ) + CustomHeader(
            name = "User-Agent",
            value = explicitUserAgent?.value ?: DEFAULT_USER_AGENT,
        )
    }

    private fun String.indexOfFirstFrom(startIndex: Int, delimiters: CharArray): Int {
        for (index in startIndex until length) {
            if (this[index] in delimiters) return index
        }
        return -1
    }
}
