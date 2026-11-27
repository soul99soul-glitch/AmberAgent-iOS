package app.amber.cloud

import app.amber.cloud.gateway.ApnsConfig
import app.amber.cloud.gateway.ApnsPushSender
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.PushMessagePayload
import app.amber.cloud.gateway.PushSender
import app.amber.cloud.gateway.SessionDto
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ApnsPushSenderTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun generateTestEcKeyPair(curve: String = "secp256r1"): Pair<KeyPair, String> {
        val kp = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec(curve))
        }.generateKeyPair()
        val pem = buildString {
            appendLine("-----BEGIN PRIVATE KEY-----")
            appendLine(Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(kp.private.encoded))
            appendLine("-----END PRIVATE KEY-----")
        }
        return kp to pem
    }

    private fun verifyEs256Jwt(jwt: String, keyPair: KeyPair, expectedKeyId: String, expectedTeamId: String): Long {
        val parts = jwt.split('.')
        assertEquals(3, parts.size, "JWT 必须包含三段")
        val header = json.parseToJsonElement(String(Base64.getUrlDecoder().decode(parts[0]), StandardCharsets.UTF_8)).jsonObject
        val claims = json.parseToJsonElement(String(Base64.getUrlDecoder().decode(parts[1]), StandardCharsets.UTF_8)).jsonObject
        val signatureBytes = Base64.getUrlDecoder().decode(parts[2])

        assertEquals("ES256", header["alg"]!!.jsonPrimitive.content)
        assertEquals(expectedKeyId, header["kid"]!!.jsonPrimitive.content)
        assertEquals(expectedTeamId, claims["iss"]!!.jsonPrimitive.content)
        assertEquals(64, signatureBytes.size, "ES256 P1363 签名必须为 64 字节 R||S")

        val verifier = Signature.getInstance("SHA256withECDSAinP1363Format")
        verifier.initVerify(keyPair.public)
        verifier.update("${parts[0]}.${parts[1]}".toByteArray(StandardCharsets.US_ASCII))
        assertTrue(verifier.verify(signatureBytes), "ES256 JWT 公钥验签必须通过")
        return claims["iat"]!!.jsonPrimitive.long
    }

    @Test
    fun `rejects non ES256 EC key at configuration time`() {
        val (_, pem) = generateTestEcKeyPair("secp384r1")
        assertFailsWith<IllegalArgumentException> { ApnsPushSender.parseEcPrivateKey(pem) }
    }

    @Test
    fun `timeout in APNs returns a failure without cancelling the caller`() = runTest {
        val state = CloudGatewayState(Files.createTempDirectory("apns-request-timeout").toFile())
        val paired = state.pairDevice(state.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
        state.registerPushToken(state.findDeviceById(paired.deviceId)!!, "original", "sandbox")
        val client = HttpClient(MockEngine { awaitCancellation() })
        try {
            val sender = ApnsPushSender(
                config = ApnsConfig("KID", "TEAM", "app.amber.ios", generateTestEcKeyPair().second),
                deviceLookup = state::findDeviceById, httpClient = client,
            )
            val result = sender.send(PushMessagePayload(paired.deviceId, "ios", "original", "标题", "正文"))
            assertTrue(result.isFailure)
            assertEquals(ApnsPushSender.REQUEST_TIMEOUT_MS, testScheduler.currentTime)
        } finally {
            client.close()
        }
    }

    @Test
    fun `token rotation before a provider retry skips the stale destination and delayed invalidation preserves replacement`() = runBlocking {
        val state = CloudGatewayState(Files.createTempDirectory("apns-rotate").toFile())
        val paired = state.pairDevice(state.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
        val device = state.findDeviceById(paired.deviceId)!!
        val stale = PushMessagePayload(device.id, "ios", "old_token", "标题", "正文")
        val requests = AtomicInteger(0)
        var providerExpired = true
        val client = HttpClient(MockEngine {
            requests.incrementAndGet()
            state.registerPushToken(device, "new_token", "production")
            if (providerExpired) respond("""{"reason":"ExpiredProviderToken"}""", HttpStatusCode.Forbidden)
            else respond("""{"reason":"Unregistered"}""", HttpStatusCode.Gone)
        })
        try {
            val sender = ApnsPushSender(
                config = ApnsConfig("KID", "TEAM", "app.amber.ios", generateTestEcKeyPair().second),
                deviceLookup = state::findDeviceById,
                onInvalidToken = { id, token, reason -> state.clearPushToken(id, token, reason) },
                httpClient = client,
            )
            state.registerPushToken(device, stale.pushToken, "sandbox")
            assertTrue(sender.send(stale).isFailure)
            assertTrue(sender.send(stale).isFailure)
            assertEquals(1, requests.get())
            providerExpired = false
            state.registerPushToken(device, stale.pushToken, "sandbox")
            assertTrue(sender.send(stale).isFailure)
            assertEquals("new_token", state.findDeviceById(device.id)?.pushToken)
            assertEquals(2, requests.get())
        } finally {
            client.close()
        }
    }

    @Test
    fun `paired device fanout bounds concurrent requests and total waiting time`() = runTest {
        val state = CloudGatewayState(Files.createTempDirectory("apns-fanout").toFile())
        repeat(6) { i ->
            val paired = state.pairDevice(state.issuePairingTicket(), "ios", "Phone $i") as CloudGatewayState.PairResult.Success
            state.registerPushToken(state.findDeviceById(paired.deviceId)!!, "device_$i", "sandbox")
        }
        var active = 0
        var peak = 0
        val attempted = mutableSetOf<String>()
        state.pushSender = PushSender { payload ->
            attempted.add(payload.pushToken)
            active++
            peak = maxOf(active, peak)
            try { delay(7_000) } finally { active-- }
            Result.success(Unit)
        }
        val payloadFor = { device: PairedDevice ->
            PushMessagePayload(device.id, device.platform, device.pushToken!!, "标题", "正文")
        }
        state.sendToPairedAppleDevices("push-failed", payloadFor)
        assertEquals(4, peak)
        assertEquals(6, attempted.size)
        assertEquals(14_000L, testScheduler.currentTime)
        state.pushSender = PushSender { awaitCancellation() }
        state.sendToPairedAppleDevices("push-failed", payloadFor)
        assertEquals(34_000L, testScheduler.currentTime)
        assertTrue(state.auditFile.readText().contains("batch_timeout"))
    }

    @Test
    fun `signs verifiable ES256 JWT sets APNs headers and payload fields and honors sandbox vs production`(): Unit = runBlocking {
        val dir = Files.createTempDirectory("apns-sender-ok").toFile()
        val state = CloudGatewayState(dir)
        val (keyPair, pem) = generateTestEcKeyPair()
        val clock = AtomicLong(1_764_000_000_000L)
        val requests = CopyOnWriteArrayList<HttpRequestData>()

        val ticket1 = state.issuePairingTicket()
        val prodPaired = state.pairDevice(ticket1, "ios", "Prod iPhone") as CloudGatewayState.PairResult.Success
        state.registerPushToken(state.findDeviceById(prodPaired.deviceId)!!, "token-prod-01", "production")

        val ticket2 = state.issuePairingTicket()
        val sandPaired = state.pairDevice(ticket2, "ios", "Sand iPhone") as CloudGatewayState.PairResult.Success
        state.registerPushToken(state.findDeviceById(sandPaired.deviceId)!!, "token-sand-01", "sandbox")

        val mockClient = HttpClient(
            MockEngine { req ->
                requests.add(req)
                respond(
                    content = "",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
        )

        val sender = ApnsPushSender(
            config = ApnsConfig(
                keyId = "KEY1234567",
                teamId = "TEAM765432",
                topic = "app.amber.ios",
                privateKeyPem = pem,
            ),
            deviceLookup = state::findDeviceById,
            httpClient = mockClient,
            clockMs = { clock.get() },
        )

        // 1. Time-sensitive proactive card to production device (with long multi-byte collapse id > 64 bytes)
        val longSignalId = "sig_" + "中".repeat(30)
        val res1 = sender.send(
            PushMessagePayload(
                deviceId = prodPaired.deviceId,
                platform = "ios",
                pushToken = "token-prod-01",
                title = "会议提醒",
                body = "15 分钟后开始预算评审",
                category = "amber.proactive.card",
                deepLink = "amber://proactive/sig_01",
                signalId = longSignalId,
                interruptionLevel = "time-sensitive",
                silent = false,
                sessionKey = "amber:sess-1",
                toolCallId = "tc-1",
                workItemId = "wi-1",
                highRisk = true,
            )
        )
        assertTrue(res1.isSuccess)

        val req1 = requests[0]
        assertEquals("https://api.push.apple.com/3/device/token-prod-01", req1.url.toString())
        val auth1 = req1.headers["authorization"]!!
        assertTrue(auth1.startsWith("bearer "))
        val jwt1 = auth1.removePrefix("bearer ")
        assertEquals(1_764_000_000L, verifyEs256Jwt(jwt1, keyPair, "KEY1234567", "TEAM765432"))

        assertEquals("alert", req1.headers["apns-push-type"])
        assertEquals("app.amber.ios", req1.headers["apns-topic"])
        assertEquals("10", req1.headers["apns-priority"])
        assertEquals((1_764_000_000L + 3600L).toString(), req1.headers["apns-expiration"])
        val collapseId = assertNotNull(req1.headers["apns-collapse-id"])
        assertTrue(collapseId.toByteArray(StandardCharsets.UTF_8).size <= 64, "apns-collapse-id UTF-8 字节数不得超过 64")

        val body1 = json.parseToJsonElement((req1.body as TextContent).text).jsonObject
        val aps1 = body1["aps"]!!.jsonObject
        assertEquals("会议提醒", aps1["alert"]!!.jsonObject["title"]!!.jsonPrimitive.content)
        assertEquals("15 分钟后开始预算评审", aps1["alert"]!!.jsonObject["body"]!!.jsonPrimitive.content)
        assertEquals("amber.proactive.card", aps1["category"]!!.jsonPrimitive.content)
        assertEquals("amber.proactive", aps1["thread-id"]!!.jsonPrimitive.content)
        assertEquals("time-sensitive", aps1["interruption-level"]!!.jsonPrimitive.content)
        assertEquals("default", aps1["sound"]!!.jsonPrimitive.content)
        assertNull(aps1["content-available"])
        assertEquals("amber://proactive/sig_01", body1["deepLink"]!!.jsonPrimitive.content)
        assertEquals(longSignalId, body1["signalId"]!!.jsonPrimitive.content)
        assertEquals("amber:sess-1", body1["sessionKey"]!!.jsonPrimitive.content)
        assertEquals("tc-1", body1["toolCallId"]!!.jsonPrimitive.content)
        assertEquals("wi-1", body1["workItemId"]!!.jsonPrimitive.content)
        assertEquals(true, body1["highRisk"]!!.jsonPrimitive.boolean)

        // 2. Passive / silent proactive card to sandbox device (within 50m -> cached JWT reused!)
        clock.addAndGet(10 * 60_000L)
        val res2 = sender.send(
            PushMessagePayload(
                deviceId = sandPaired.deviceId,
                platform = "ios",
                pushToken = "token-sand-01",
                title = "轻提醒",
                body = "网页轻微变动",
                category = "amber.proactive.card",
                deepLink = "amber://proactive/sig_02",
                signalId = "sig_02",
                interruptionLevel = "passive",
                silent = true,
            )
        )
        assertTrue(res2.isSuccess)
        val req2 = requests[1]
        assertEquals("https://api.sandbox.push.apple.com/3/device/token-sand-01", req2.url.toString())
        assertEquals(jwt1, req2.headers["authorization"]!!.removePrefix("bearer "), "50 分钟内应复用缓存 JWT")
        assertEquals("5", req2.headers["apns-priority"])
        val aps2 = json.parseToJsonElement((req2.body as TextContent).text).jsonObject["aps"]!!.jsonObject
        assertEquals("passive", aps2["interruption-level"]!!.jsonPrimitive.content)
        assertNull(aps2["sound"], "passive 推送绝不能包含 sound")
        assertNull(aps2["content-available"], "silent 推送绝不能发送 content-available")

        // 3. Past 50 minutes -> fresh JWT is signed
        clock.addAndGet(45 * 60_000L)
        val jwt3 = sender.getOrSignJwt(clock.get())
        assertNotEquals(jwt1, jwt3)
        verifyEs256Jwt(jwt3, keyPair, "KEY1234567", "TEAM765432")

        val device = state.findDeviceById(prodPaired.deviceId)!!
        val session = SessionDto(key = "amber:session", subject = "云端审批", state = "waiting", updatedAt = 1.0)
        for (highRisk in listOf(false, true)) {
            val approval = PendingApprovalDto("approval_1", "tool", highRisk = highRisk)
            val payload = state.buildApprovalPushPayload(device, session, approval)!!
            assertTrue(sender.send(payload).isSuccess)
            val body = json.parseToJsonElement((requests.last().body as TextContent).text).jsonObject
            assertEquals("amber://tasks/cloud", body["deepLink"]!!.jsonPrimitive.content)
            assertEquals(session.key, body["sessionKey"]!!.jsonPrimitive.content)
            assertEquals(if (highRisk) null else "approval_1", body["toolCallId"]?.jsonPrimitive?.content)
            assertEquals(if (highRisk) null else "amber.cloud.approval", body["aps"]!!.jsonObject["category"]?.jsonPrimitive?.content)
        }
        Unit
    }

    @Test
    fun `refreshes token once on 403 ExpiredProviderToken and clears device push token on 410 or Unregistered`() = runBlocking {
        val dir = Files.createTempDirectory("apns-sender-errors").toFile()
        val state = CloudGatewayState(dir)
        val (keyPair, pem) = generateTestEcKeyPair()
        val clock = AtomicLong(1_764_100_000_000L)

        val ticket = state.issuePairingTicket()
        val paired = state.pairDevice(ticket, "ios", "Owner iPhone") as CloudGatewayState.PairResult.Success
        state.registerPushToken(state.findDeviceById(paired.deviceId)!!, "token-live-01", "production")

        // Part A: 403 ExpiredProviderToken triggers one token refresh and retry
        val attempts = AtomicInteger(0)
        val seenJwts = CopyOnWriteArrayList<String>()
        val retryClient = HttpClient(
            MockEngine { req ->
                val jwt = req.headers["authorization"]!!.removePrefix("bearer ")
                seenJwts.add(jwt)
                if (attempts.incrementAndGet() == 1) {
                    clock.addAndGet(5_000L)
                    respond(
                        content = """{"reason":"ExpiredProviderToken"}""",
                        status = HttpStatusCode.Forbidden,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(content = "", status = HttpStatusCode.OK)
                }
            }
        )
        val retrySender = ApnsPushSender(
            config = ApnsConfig("KID1", "TID1", "app.amber.ios", pem),
            deviceLookup = state::findDeviceById,
            httpClient = retryClient,
            clockMs = { clock.get() },
        )
        val retryRes = retrySender.send(
            PushMessagePayload(
                deviceId = paired.deviceId,
                platform = "ios",
                pushToken = "token-live-01",
                title = "Test",
                body = "Retry body",
            )
        )
        assertTrue(retryRes.isSuccess)
        assertEquals(2, attempts.get())
        assertNotEquals(seenJwts[0], seenJwts[1])
        verifyEs256Jwt(seenJwts[1], keyPair, "KID1", "TID1")

        // Part B: 410 Unregistered invokes callback and clears device token from CloudGatewayState
        val clearedEvents = CopyOnWriteArrayList<Triple<String, String, String>>()
        val goneClient = HttpClient(
            MockEngine {
                respond(
                    content = """{"reason":"Unregistered","timestamp":1764100000}""",
                    status = HttpStatusCode.Gone,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
        )
        val goneSender = ApnsPushSender(
            config = ApnsConfig("KID1", "TID1", "app.amber.ios", pem),
            deviceLookup = state::findDeviceById,
            onInvalidToken = { devId, tok, reason ->
                clearedEvents.add(Triple(devId, tok, reason))
                state.clearPushToken(devId, expectedToken = tok, reason = reason)
            },
            httpClient = goneClient,
            clockMs = { clock.get() },
        )
        val goneRes = goneSender.send(
            PushMessagePayload(
                deviceId = paired.deviceId,
                platform = "ios",
                pushToken = "token-live-01",
                title = "Test",
                body = "Gone body",
            )
        )
        assertTrue(goneRes.isFailure)
        val errMsg = goneRes.exceptionOrNull()?.message.orEmpty()
        assertFalse(errMsg.contains("BEGIN PRIVATE KEY"))
        assertFalse(errMsg.contains("token-live-01"))
        assertEquals(1, clearedEvents.size)
        assertEquals(Triple(paired.deviceId, "token-live-01", "Unregistered"), clearedEvents.single())
        assertNull(state.findDeviceById(paired.deviceId)?.pushToken, "收到 410/Unregistered 后必须清理设备 pushToken")
    }
}
