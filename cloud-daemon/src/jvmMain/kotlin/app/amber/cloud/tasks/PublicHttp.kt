package app.amber.cloud.tasks

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.*
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** DNS validation is part of the actual connection, including redirects; no ambient proxy/credentials. */
class PublicHttp internal constructor(
    private val fixtureOrigin: String? = null,
    private val resolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() },
) {
    private val client = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false)
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS)
        .dns { host -> resolver(host).also { addresses ->
            if (addresses.isEmpty() || (fixtureOrigin?.toHttpUrl()?.host != host && !addresses.all(::publicAddress))) {
                throw IOException("拒绝非公网DNS地址")
            }
        } }.build()

    data class Result(
        val status: Int, val url: String, val contentType: String, val bytes: ByteArray,
        internal val redirectLocation: String? = null,
    ) {
        fun text() = bytes.toString(Charsets.UTF_8)
    }

    fun validate(url: String): HttpUrl = url.toHttpUrl().also {
        require(it.scheme in setOf("http", "https") && it.username.isEmpty() && it.password.isEmpty()) { "仅允许无内嵌凭据的HTTP(S)" }
        require(it.port in setOf(80, 443) || origin(it) == fixtureOrigin) { "仅允许公网80/443端口" }
        if (fixtureOrigin != null && it.host == fixtureOrigin.toHttpUrl().host) require(origin(it) == fixtureOrigin)
    }

    suspend fun request(
        url: String, method: String = "GET", body: String? = null,
        headers: Map<String, String> = emptyMap(), maxBytes: Int = 2_000_000,
    ): Result {
        require(method in setOf("GET", "HEAD", "POST"))
        require(body == null || body.length <= 100_000)
        var target = validate(url)
        var currentMethod = method
        var currentBody = body
        var currentHeaders = headers
        repeat(4) { redirect ->
            val request = Request.Builder().url(target).apply {
                currentHeaders.forEach { (key, value) -> header(key, value) }
                method(currentMethod, if (currentMethod == "POST") (currentBody ?: "").toRequestBody("application/json".toMediaType()) else null)
            }.build()
            val result = execute(client.newCall(request), target, maxBytes)
            val location = result.redirectLocation ?: return result
            require(redirect < 3) { "重定向超过3次" }
            val next = validate(location)
            if (origin(next) != origin(target)) currentHeaders = emptyMap()
            if (result.status in setOf(301, 302, 303)) {
                currentMethod = "GET"
                currentBody = null
            }
            target = next
        }
        error("重定向失败")
    }

    private suspend fun execute(call: Call, target: HttpUrl, maxBytes: Int): Result = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    response.use {
                        val redirect = if (response.code in setOf(301, 302, 303, 307, 308)) {
                            val location = response.header("Location") ?: throw IOException("重定向缺少Location")
                            target.resolve(location)?.toString() ?: throw IOException("无效重定向")
                        } else null
                        val output = ByteArrayOutputStream()
                        if (redirect == null) response.body.byteStream().use { input ->
                            val buffer = ByteArray(8192)
                            while (true) {
                                val size = input.read(buffer)
                                if (size < 0) break
                                if (output.size() + size > maxBytes) throw IOException("响应超过大小限制")
                                output.write(buffer, 0, size)
                            }
                        }
                        if (continuation.isActive) continuation.resume(Result(response.code, target.toString(), response.header("Content-Type").orEmpty(), output.toByteArray(), redirect))
                    }
                } catch (e: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(e)
                }
            }
        })
    }

    companion object {
        private fun origin(url: HttpUrl) = "${url.scheme}://${url.host}:${url.port}"
        fun publicAddress(ip: InetAddress): Boolean {
            if (ip.isAnyLocalAddress || ip.isLoopbackAddress || ip.isLinkLocalAddress || ip.isSiteLocalAddress || ip.isMulticastAddress) return false
            val bytes = ip.address.map { it.toInt() and 255 }
            return if (bytes.size == 4) !(bytes[0] in setOf(0, 10, 127, 169) || bytes[0] >= 224 ||
                bytes[0] == 100 && bytes[1] in 64..127 || bytes[0] == 192 && bytes[1] in setOf(0, 168) || bytes[0] == 198 && bytes[1] in 18..19)
            else bytes[0] in 0x20..0x3f
        }
    }
}
