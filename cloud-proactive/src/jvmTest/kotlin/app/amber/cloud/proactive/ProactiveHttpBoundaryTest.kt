package app.amber.cloud.proactive

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readByte
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class ProactiveHttpBoundaryTest {
    @Test
    fun `bounded reader accepts exact length and stops at the first excess byte without EOF`() = runTest {
        val body = ByteArray(64 * 1024) { it.toByte() }
        assertContentEquals(body, ByteReadChannel(body).readBoundedBody(body.size))
        val openStream = ByteChannel(autoFlush = true)
        openStream.writeFully(byteArrayOf(1, 2, 3, 4, 5))
        assertNull(withTimeout(1_000) { openStream.readBoundedBody(3) })
        assertEquals(5.toByte(), openStream.readByte())
        openStream.flushAndClose()
    }

    @Test
    fun `watchtower rejects redirect and oversized responses before returning a page`() = runTest {
        val paths = mutableListOf<String>()
        val publicDns = { _: String -> listOf(InetAddress.getByName("93.184.216.34")) }
        HttpClient(MockEngine { request ->
            paths.add(request.url.encodedPath)
            when (request.url.encodedPath) {
                "/redirect" -> respond("", HttpStatusCode.Found, headersOf(HttpHeaders.Location, "http://localhost/unused"))
                "/large" -> respond("12345")
                else -> respond("1234")
            }
        }).use { client ->
            val http = WatchtowerHttp(client, publicDns, maxBytes = 4)
            assertFailsWith<IOException> { http.fetch("https://watch.test/redirect", null) }
            assertFailsWith<IOException> { http.fetch("https://watch.test/large", null) }
            assertEquals("1234", http.fetch("https://watch.test/exact", null).body)
            assertEquals(listOf("/redirect", "/large", "/exact"), paths)
        }
    }

    @Test
    fun `production transport rejects a mixed DNS answer and private literals before connecting`() = runTest {
        val resolved = mutableListOf<String>()
        val http = WatchtowerHttp(dnsResolver = { host ->
            resolved.add(host)
            listOf(InetAddress.getByName("93.184.216.34"), InetAddress.getLoopbackAddress())
        })
        assertFailsWith<NonPublicWatchtowerHost> { http.fetch("https://unit.test", null) }
        for (ip in listOf("[::1]", "[fd00::1]", "[fe80::1]", "[::ffff:127.0.0.1]", "100.64.0.1", "100.127.255.255")) {
            assertFailsWith<IllegalArgumentException> { http.fetch("http://$ip", null) }
        }
        assertEquals(listOf("unit.test"), resolved)
    }
}
