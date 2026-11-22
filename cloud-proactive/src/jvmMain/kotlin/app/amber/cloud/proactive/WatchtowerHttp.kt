package app.amber.cloud.proactive

import app.amber.cloud.security.isPublicNetworkAddress
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.header
import io.ktor.client.request.prepareGet
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import java.net.UnknownHostException

/** Read through the first excess byte. An oversized stream need not reach EOF. */
suspend fun ByteReadChannel.readBoundedBody(maxBytes: Int): ByteArray? {
    require(maxBytes in 1 until Int.MAX_VALUE)
    val buffer = ByteArray(minOf(8192, maxBytes + 1))
    val output = ByteArrayOutputStream()
    while (true) {
        val remaining = maxBytes - output.size()
        val count = readAvailable(buffer, 0, minOf(buffer.size, remaining + 1))
        if (count < 0) return output.toByteArray()
        if (count > remaining) return null
        output.write(buffer, 0, count)
    }
}

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
        val host = uri.host?.lowercase()?.removeSuffix(".")?.removePrefix("[")?.removeSuffix("]")
            ?: throw IllegalArgumentException("监控 URL 缺少主机名")
        require(host.isNotEmpty()) { "监控 URL 缺少主机名" }
        if (host == "localhost" || BLOCKED_HOST_SUFFIXES.any { host.endsWith(it) }) {
            throw IllegalArgumentException("拒绝本机或私网地址: $host")
        }
        // 若主机名是 IP 字面量（IPv4 或 IPv6），立即做公网校验
        if (looksLikeIpLiteral(host)) {
            val addr = runCatching { InetAddress.getByName(host) }.getOrNull()
                ?: throw IllegalArgumentException("非法 IP 地址: $host")
            if (!isPublicNetworkAddress(addr)) {
                throw IllegalArgumentException("拒绝回环、私网或链路本地地址: $host")
            }
        }
        return uri
    }

    /**
     * 校验给定解析器返回的全部地址；生产连接使用同一地址策略校验实际 DNS 结果。
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
            if (!isPublicNetworkAddress(addr)) {
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

class NonPublicWatchtowerHost : UnknownHostException("拒绝解析到非公网地址的目标")

/** Both the scheduled monitor and a direct Watchtower check use this connection policy. */
class WatchtowerHttp(
    httpClient: HttpClient? = null,
    private val dnsResolver: (String) -> List<InetAddress>,
    private val maxBytes: Int = MAX_RESPONSE_BYTES,
) {
    data class Page(val status: Int, val etag: String?, val body: String)

    private val suppliedTransport = httpClient != null
    private val client = httpClient?.config { followRedirects = false } ?: HttpClient(OkHttp) {
        followRedirects = false
        engine {
            config {
                proxy(Proxy.NO_PROXY)
                followRedirects(false)
                followSslRedirects(false)
                dns { host ->
                    val addresses = dnsResolver(host)
                    if (addresses.isEmpty() || !addresses.all(::isPublicNetworkAddress)) throw NonPublicWatchtowerHost()
                    addresses
                }
            }
        }
    }

    suspend fun fetch(url: String, etag: String?): Page {
        if (suppliedTransport) ProactiveUrlGuard.validatePublicUrl(url, dnsResolver)
        else ProactiveUrlGuard.validateSyntaxAndLiteralHost(url)
        return client.prepareGet(url) {
            if (!etag.isNullOrBlank()) header(HttpHeaders.IfNoneMatch, etag)
        }.execute { response ->
            val status = response.status.value
            val responseEtag = response.headers[HttpHeaders.ETag]
            if (status == 304) return@execute Page(status, responseEtag, "")
            if (status !in 200..299) throw IOException("巡检返回 HTTP $status")
            val bytes = response.bodyAsChannel().readBoundedBody(maxBytes) ?: throw IOException("巡检响应超过大小限制")
            Page(status, responseEtag, bytes.decodeToString())
        }
    }

    companion object {
        const val MAX_RESPONSE_BYTES = 512 * 1024
    }
}
