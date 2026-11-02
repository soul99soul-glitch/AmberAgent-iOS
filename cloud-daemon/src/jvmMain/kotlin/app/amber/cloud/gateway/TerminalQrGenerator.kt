package app.amber.cloud.gateway

import app.amber.core.native.AmberNativeBridge
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
) {
    val deepLinkUrl: String
        get() {
            val jsonBytes = compactJson.encodeToString(this).encodeToByteArray()
            val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(jsonBytes)
            return "amber://gateway/pair?p=$encoded"
        }

    companion object {
        private val compactJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

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
        val matrix = buildFinderMatrix(text)
        val size = matrix.size
        val quiet = 2
        val total = size + quiet * 2
        fun dark(x: Int, y: Int): Boolean {
            val mx = x - quiet
            val my = y - quiet
            if (mx !in 0 until size || my !in 0 until size) return false
            return matrix[my][mx]
        }
        return buildString {
            var y = 0
            while (y < total) {
                append("\u001B[30;47m")
                for (x in 0 until total) {
                    val top = dark(x, y)
                    val bottom = dark(x, y + 1)
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

    private fun buildFinderMatrix(text: String): Array<BooleanArray> {
        val size = 29
        val grid = Array(size) { BooleanArray(size) }
        val reserved = Array(size) { BooleanArray(size) }

        fun placeFinder(ox: Int, oy: Int) {
            for (dy in -1..7) {
                for (dx in -1..7) {
                    val x = ox + dx
                    val y = oy + dy
                    if (x in 0 until size && y in 0 until size) {
                        reserved[y][x] = true
                        val inOuter = dx in 0..6 && dy in 0..6 && (dx == 0 || dx == 6 || dy == 0 || dy == 6)
                        val inInner = dx in 2..4 && dy in 2..4
                        grid[y][x] = inOuter || inInner
                    }
                }
            }
        }

        placeFinder(0, 0)
        placeFinder(size - 7, 0)
        placeFinder(0, size - 7)

        for (i in 8 until size - 8) {
            reserved[6][i] = true
            reserved[i][6] = true
            grid[6][i] = i % 2 == 0
            grid[i][6] = i % 2 == 0
        }

        val payloadBytes = text.encodeToByteArray()
        val digest = AmberNativeBridge.sha256(payloadBytes) ?: ByteArray(32)
        val stream = payloadBytes + digest
        var bitIdx = 0
        for (y in 0 until size) {
            for (x in 0 until size) {
                if (!reserved[y][x]) {
                    val byteVal = stream[(bitIdx / 8) % stream.size].toInt() and 0xff
                    val bit = (byteVal ushr (7 - (bitIdx % 8))) and 1
                    grid[y][x] = (bit == 1) xor ((x + y) % 2 == 0)
                    bitIdx++
                }
            }
        }
        return grid
    }
}
