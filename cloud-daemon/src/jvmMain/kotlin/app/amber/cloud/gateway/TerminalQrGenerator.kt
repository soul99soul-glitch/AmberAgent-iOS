package app.amber.cloud.gateway

import app.amber.cloud.config.PairingBootstrapHint
import app.amber.cloud.security.CredentialRedactor
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.URI
import java.util.Base64

/**
 * C3 §2.1 Pairing Payload carried inside `amber://gateway/pair?p=<base64url_no_padding>`.
 *
 * Byte-compatible with iOS `MacGatewayStore` / `PairingPayload` in `Pairing.swift`.
 */
@Serializable
data class PairingPayload(
    val v: Int = 1,
    val id: String,
    val name: String,
    val addrs: List<String>,
    val port: Int,
    val fp: String,
    val s: String,
    val bootstrap: PairingBootstrapHint? = null,
) {
    val deepLinkUrl: String
        get() {
            val rawJson = compactJson.encodeToString(this)
            require(!containsSecretPattern(rawJson)) { "配对二维码载荷严禁包含明文 API Key 或 OAuth Token" }
            val sanitizedBootstrap = bootstrap?.copy(
                provider = CredentialRedactor.redact(bootstrap.provider).take(32),
                authMode = CredentialRedactor.redact(bootstrap.authMode).take(32),
            )
            val safePayload = copy(
                name = CredentialRedactor.redact(name).take(64),
                bootstrap = sanitizedBootstrap,
            )
            val jsonText = compactJson.encodeToString(safePayload)
            require(!containsSecretPattern(jsonText)) { "配对二维码载荷严禁包含明文 API Key 或 OAuth Token" }
            val jsonBytes = jsonText.encodeToByteArray()
            val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(jsonBytes)
            return "amber://gateway/pair?p=$encoded"
        }

    companion object {
        private val compactJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
        private val FORBIDDEN_QR_SECRET_PATTERNS = listOf(
            Regex("""sk-[A-Za-z0-9_-]{12,}"""),
            Regex("""AIza[0-9A-Za-z_-]{20,}"""),
            Regex("""ghp_[A-Za-z0-9]{20,}"""),
            Regex("""eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"""),
            Regex("""(?i)(api[_-]?key|oauth[_-]?token|refresh[_-]?token|access[_-]?token)\s*[:=]"""),
        )

        fun containsSecretPattern(raw: String): Boolean =
            FORBIDDEN_QR_SECRET_PATTERNS.any { it.containsMatchIn(raw) }

        fun parse(urlOrParam: String): PairingPayload? {
            val trimmed = urlOrParam.trim()
            if (trimmed.isEmpty() || trimmed.length > 4096) return null
            val param = if (trimmed.startsWith("amber://")) {
                runCatching {
                    val uri = URI(trimmed)
                    uri.rawQuery
                        ?.split("&")
                        ?.firstOrNull { it.startsWith("p=") }
                        ?.removePrefix("p=")
                }.getOrNull()
            } else {
                trimmed
            } ?: return null

            return runCatching {
                val padded = param + "=".repeat((4 - param.length % 4) % 4)
                val decoded = Base64.getUrlDecoder().decode(padded).decodeToString()
                val payload = compactJson.decodeFromString<PairingPayload>(decoded)
                if (payload.v != 1 || payload.addrs.isEmpty() || payload.port !in 1..65535) null else payload
            }.getOrNull()
        }
    }
}

object CandidateAddressResolver {
    /**
     * Resolves candidate addresses in C3 §1.4 order:
     * 1. `<hostname>.local`
     * 2. Configured public addresses
     * 3. Non-loopback, non-link-local IPv4 addresses
     */
    fun resolve(publicAddresses: List<String> = emptyList()): List<String> {
        val result = mutableListOf<String>()
        runCatching {
            val host = InetAddress.getLocalHost().hostName?.removeSuffix(".local")
            if (!host.isNullOrBlank() && host != "localhost") {
                result.add("$host.local")
            }
        }
        result.addAll(publicAddresses.map { it.trim() }.filter { it.isNotEmpty() })
        runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            for (nif in interfaces) {
                if (!nif.isUp || nif.isLoopback) continue
                for (addr in nif.inetAddresses.toList()) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        val ip = addr.hostAddress
                        if (!ip.startsWith("169.254.") && ip !in result) {
                            result.add(ip)
                        }
                    }
                }
            }
        }
        if (result.isEmpty()) {
            result.add("127.0.0.1")
        }
        return result.distinct()
    }
}

/**
 * Renders an ANSI half-block (`█`, `▀`, `▄`, ` `) terminal representation of the pairing payload
 * for `amber-cli pair`, compatible with both light and dark terminal themes.
 */
object TerminalQrGenerator {

    fun renderAnsi(text: String): String {
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0)
        return buildString {
            var y = 0
            while (y < matrix.height) {
                append("\u001B[30;47m")
                for (x in 0 until matrix.width) {
                    val top = matrix[x, y]
                    val bottom = y + 1 < matrix.height && matrix[x, y + 1]
                    append(
                        when {
                            top && bottom -> "█"
                            top && !bottom -> "▀"
                            !top && bottom -> "▄"
                            else -> " "
                        }
                    )
                }
                append("\u001B[0m\n")
                y += 2
            }
        }
    }
}
