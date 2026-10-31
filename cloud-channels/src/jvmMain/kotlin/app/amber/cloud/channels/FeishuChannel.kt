package app.amber.cloud.channels

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.header
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * 飞书入站 Webhook 处理响应。
 */
@Serializable
data class FeishuWebhookResponse(
    val statusCode: Int,
    val bodyJson: String,
)

/**
 * 飞书通道实现（HTTPS Webhook 入站事件与卡片回调 + 签名校验 + OpenAPI/自定义机器人 Webhook 出站）。
 *
 * 复用并对齐 `macApp/AmberMac/Runtime/DesktopPlugins.swift`：
 * 1. `inferReceiveIdType`（`oc_` -> `chat_id`、`ou_` -> `open_id`、`on_` -> `union_id`、`@` -> `email`）；
 * 2. `buildFeishuInteractiveCard`（`wide_screen_mode`、`header.template`、`markdown` 与安全按钮区）；
 * 3. `computeFeishuWebhookSign`（`timestamp + "\n" + secret` HMAC-SHA256 Base64 签名）及事件回调 `X-Lark-Signature` SHA-256 验签；
 * 4. `tenant_access_token` 自动换取与内存缓存；
 * 5. 主人绑定（`/bind`）、入站幂等去重、出站幂等键防重发、入站 `tainted = true` 沙箱、IM 审批按钮仅能产生「拒绝」。
 */
class FeishuChannel(
    private val openApiBaseUrl: String = "https://open.feishu.cn",
    private val appId: String = "",
    private val webhookUrl: String = "",
    private val secretLoader: ChannelSecretLoader,
    private val ownerBinding: OwnerBindingManager,
    private val deduplicator: InboundMessageDeduplicator = InboundMessageDeduplicator(),
    private val idempotencyStore: OutboundIdempotencyStore = OutboundIdempotencyStore(),
    private val logger: RedactingChannelLogger,
    private val httpClient: HttpClient = HttpClient(OkHttp),
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) : Channel {
    override val id: String = CHANNEL_ID

    companion object {
        const val CHANNEL_ID = "feishu"
        const val CONFIG_KEY_APP_SECRET = "feishu.app_secret"
        const val ENV_APP_SECRET = "AMBER_FEISHU_APP_SECRET"
        const val CONFIG_KEY_ENCRYPT_KEY = "feishu.encrypt_key"
        const val ENV_ENCRYPT_KEY = "AMBER_FEISHU_ENCRYPT_KEY"
        const val CONFIG_KEY_WEBHOOK_SECRET = "feishu.webhook_secret"
        const val ENV_WEBHOOK_SECRET = "AMBER_FEISHU_WEBHOOK_SECRET"

        /**
         * 移植自 `DesktopPlugins.swift:2746` `inferFeishuReceiveIDType(_:)`。
         */
        fun inferReceiveIdType(receiveId: String): String {
            val clean = receiveId.trim()
            return when {
                clean.startsWith("oc_") -> "chat_id"
                clean.startsWith("ou_") -> "open_id"
                clean.startsWith("on_") -> "union_id"
                clean.contains("@") -> "email"
                else -> "chat_id"
            }
        }

        /**
         * 移植并扩展自 `DesktopPlugins.swift:2754` `buildFeishuInteractiveCard(title:markdown:)`。
         * 当包含按钮或关联审批时，强制经 [ImApprovalGate.sanitizeOutboundButtons] 剥离任何批准按钮。
         */
        fun buildInteractiveCardJson(card: OutboundCard): JsonObject {
            val safeButtons = ImApprovalGate.sanitizeOutboundButtons(card)
            return buildJsonObject {
                put("config", buildJsonObject { put("wide_screen_mode", true) })
                put(
                    "header",
                    buildJsonObject {
                        put("template", card.headerTemplate.ifBlank { "wathet" })
                        put(
                            "title",
                            buildJsonObject {
                                put("tag", "plain_text")
                                put("content", card.title.ifBlank { "Amber 智能体通知" })
                            }
                        )
                    }
                )
                put(
                    "elements",
                    buildJsonArray {
                        add(
                            buildJsonObject {
                                put("tag", "markdown")
                                put("content", card.markdownBody)
                            }
                        )
                        if (safeButtons.isNotEmpty()) {
                            add(
                                buildJsonObject {
                                    put("tag", "action")
                                    put(
                                        "actions",
                                        buildJsonArray {
                                            for (btn in safeButtons) {
                                                add(
                                                    buildJsonObject {
                                                        put("tag", "button")
                                                        put(
                                                            "text",
                                                            buildJsonObject {
                                                                put("tag", "plain_text")
                                                                put("content", btn.text)
                                                            }
                                                        )
                                                        put(
                                                            "type",
                                                            when (btn.style) {
                                                                ButtonStyle.DANGER -> "danger"
                                                                ButtonStyle.PRIMARY -> "primary"
                                                                ButtonStyle.DEFAULT -> "default"
                                                            }
                                                        )
                                                        put(
                                                            "value",
                                                            buildJsonObject {
                                                                put("action", btn.actionData)
                                                            }
                                                        )
                                                    }
                                                )
                                            }
                                        }
                                    )
                                }
                            )
                        }
                    }
                )
            }
        }
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val appSecret: SecretValue? = secretLoader.resolveOptionalSecret(CONFIG_KEY_APP_SECRET, ENV_APP_SECRET)
    private val encryptKey: SecretValue? = secretLoader.resolveOptionalSecret(CONFIG_KEY_ENCRYPT_KEY, ENV_ENCRYPT_KEY)
    private val webhookSecret: SecretValue? = secretLoader.resolveOptionalSecret(CONFIG_KEY_WEBHOOK_SECRET, ENV_WEBHOOK_SECRET)

    private val tokenMutex = Mutex()
    private var cachedTenantToken: SecretValue? = null
    private var cachedTenantTokenExpiresAtMs: Long = 0L

    private var inboundHandler: (suspend (InboundMessage) -> Unit)? = null
    private val rejectedMessages = mutableListOf<InboundGateVerdict.RejectedNonOwner>()

    fun rejectedHistory(): List<InboundGateVerdict.RejectedNonOwner> =
        synchronized(rejectedMessages) { rejectedMessages.toList() }

    override suspend fun start(onInbound: suspend (InboundMessage) -> Unit) {
        inboundHandler = onInbound
        logger.info("飞书通道已就绪 (mode=HTTPS_WEBHOOK_AND_OPENAPI, baseUrl=${logger.redact(openApiBaseUrl)})")
    }

    override suspend fun stop() {
        inboundHandler = null
        cachedTenantToken?.wipe()
        cachedTenantToken = null
        logger.info("飞书通道已停止")
    }

    /**
     * 处理飞书开放平台推送的 HTTPS Webhook 事件（含 `url_verification`、`im.message.receive_v1`、`card.action.trigger`）。
     *
     * 签名校验规则：
     * - 若配置了 [encryptKey]，强制校验 `X-Lark-Request-Timestamp` + `X-Lark-Request-Nonce` + `X-Lark-Signature`；
     * - 若请求体包含 `timestamp` 与 `sign` 且配置了 [webhookSecret]，校验 HMAC-SHA256 签名。
     */
    suspend fun handleWebhookEvent(
        headers: Map<String, String>,
        rawBody: String,
        onInboundOverride: (suspend (InboundMessage) -> Unit)? = null,
    ): FeishuWebhookResponse {
        val normalizedHeaders = headers.entries.associate { it.key.lowercase() to it.value }
        val bodyObj = runCatching { json.parseToJsonElement(rawBody).jsonObject }.getOrElse {
            return FeishuWebhookResponse(400, """{"ok":false,"error":"invalid_json"}""")
        }

        // 1. 签名校验
        val configuredEncryptKey = encryptKey
        if (configuredEncryptKey != null && !configuredEncryptKey.isWiped) {
            val timestamp = normalizedHeaders["x-lark-request-timestamp"] ?: ""
            val nonce = normalizedHeaders["x-lark-request-nonce"] ?: ""
            val signature = normalizedHeaders["x-lark-signature"] ?: ""
            val valid = ChannelCrypto.verifyFeishuEventSignature(
                timestamp = timestamp,
                nonce = nonce,
                encryptKey = configuredEncryptKey.expose(),
                rawBody = rawBody,
                expectedSignatureHex = signature,
            )
            if (!valid) {
                logger.warn("飞书 Webhook 事件签名校验失败: signature=$signature")
                return FeishuWebhookResponse(401, """{"ok":false,"error":"invalid_signature"}""")
            }
        }

        val configuredWebhookSecret = webhookSecret
        if (configuredWebhookSecret != null && !configuredWebhookSecret.isWiped && bodyObj.containsKey("sign")) {
            val ts = bodyObj["timestamp"]?.jsonPrimitive?.content ?: ""
            val sign = bodyObj["sign"]?.jsonPrimitive?.content ?: ""
            val expectedSign = ChannelCrypto.computeFeishuWebhookSign(ts, configuredWebhookSecret.expose())
            if (sign.isBlank() || sign != expectedSign) {
                logger.warn("飞书自定义 Webhook HMAC 签名校验失败")
                return FeishuWebhookResponse(401, """{"ok":false,"error":"invalid_hmac_signature"}""")
            }
        }

        // 2. 处理 url_verification 握手
        val reqType = bodyObj["type"]?.jsonPrimitive?.content
        if (reqType == "url_verification") {
            val challenge = bodyObj["challenge"]?.jsonPrimitive?.content ?: ""
            return FeishuWebhookResponse(
                statusCode = 200,
                bodyJson = buildJsonObject { put("challenge", challenge) }.toString(),
            )
        }

        // 3. 解析 v2 事件头与去重
        val headerObj = bodyObj["header"]?.jsonObject
        val eventType = headerObj?.get("event_type")?.jsonPrimitive?.content
            ?: bodyObj["event_type"]?.jsonPrimitive?.content
            ?: ""
        val eventId = headerObj?.get("event_id")?.jsonPrimitive?.content
            ?: bodyObj["uuid"]?.jsonPrimitive?.content
            ?: ""

        if (eventId.isNotBlank() && !deduplicator.markIfFirstSeen(id, "event:$eventId")) {
            return FeishuWebhookResponse(200, """{"ok":true,"duplicate":true}""")
        }

        val parsedMessage = when (eventType) {
            "im.message.receive_v1" -> parseImMessageEvent(bodyObj, eventId)
            "card.action.trigger" -> parseCardActionEvent(bodyObj, eventId)
            else -> null
        } ?: return FeishuWebhookResponse(200, """{"ok":true,"ignored":true}""")

        if (!deduplicator.markIfFirstSeen(id, "msg:${parsedMessage.id}")) {
            return FeishuWebhookResponse(200, """{"ok":true,"duplicate":true}""")
        }

        // 4. 主人绑定与权限门禁校验
        val handler = onInboundOverride ?: inboundHandler
        return when (val verdict = ownerBinding.evaluate(parsedMessage)) {
            is InboundGateVerdict.Allowed -> {
                handler?.invoke(verdict.message)
                FeishuWebhookResponse(200, """{"ok":true}""")
            }
            is InboundGateVerdict.BoundSuccess -> {
                logger.info("飞书主人绑定成功: senderId=${verdict.ownerSenderId}")
                send(
                    OutboundMessage(
                        chatId = parsedMessage.chatId,
                        text = verdict.replyMessage,
                    )
                )
                FeishuWebhookResponse(200, """{"ok":true,"bound":true}""")
            }
            is InboundGateVerdict.RejectedNonOwner -> {
                synchronized(rejectedMessages) {
                    rejectedMessages.add(verdict)
                }
                logger.warn("拦截非主人飞书消息: senderId=${verdict.senderId}, reason=${verdict.reason}")
                FeishuWebhookResponse(403, """{"ok":false,"error":"forbidden_non_owner"}""")
            }
            is InboundGateVerdict.DuplicateIgnored -> {
                FeishuWebhookResponse(200, """{"ok":true,"duplicate":true}""")
            }
        }
    }

    override suspend fun send(message: OutboundMessage): OutboundReceipt {
        return idempotencyStore.executeIdempotent(message.idempotencyKey, id) {
            val targetId = message.chatId.trim()
            val useCustomWebhook = webhookUrl.isNotBlank() && targetId.isEmpty()
            if (useCustomWebhook) {
                sendViaCustomWebhook(message)
            } else {
                sendViaOpenApi(message)
            }
        }
    }

    override suspend fun editStreamMessage(
        chatId: String,
        messageId: String,
        newText: String,
        card: OutboundCard?,
    ): OutboundReceipt {
        val token = resolveTenantAccessToken()
        val effectiveCard = card ?: OutboundCard(
            title = "Amber",
            markdownBody = newText,
        )
        val cardJsonString = buildInteractiveCardJson(effectiveCard).toString()
        val payload = buildJsonObject {
            put("content", cardJsonString)
        }
        val cleanBase = openApiBaseUrl.trimEnd('/')
        val url = "$cleanBase/open-apis/im/v1/messages/$messageId"
        val response = httpClient.patch(url) {
            header(HttpHeaders.Authorization, "Bearer ${token.expose()}")
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(payload.toString())
        }
        val bodyText = response.bodyAsText()
        val respObj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
        val code = respObj?.get("code")?.jsonPrimitive?.intOrNull ?: (if (response.status.isSuccess()) 0 else -1)
        val ok = response.status.isSuccess() && code == 0
        logger.info("飞书流式更新卡片完成: messageId=$messageId, ok=$ok")
        return OutboundReceipt(
            ok = ok,
            channelId = id,
            messageId = messageId,
        )
    }

    private suspend fun sendViaCustomWebhook(message: OutboundMessage): OutboundReceipt {
        val card = message.card
        val timestampSec = (clockMs() / 1000L).toString()
        val bodyObj = buildJsonObject {
            if (card != null) {
                put("msg_type", "interactive")
                put("card", buildInteractiveCardJson(card))
            } else {
                put("msg_type", "text")
                put("content", buildJsonObject { put("text", message.text) })
            }
            val secret = webhookSecret
            if (secret != null && !secret.isWiped) {
                put("timestamp", timestampSec)
                put("sign", ChannelCrypto.computeFeishuWebhookSign(timestampSec, secret.expose()))
            }
        }
        val response = httpClient.post(webhookUrl) {
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(bodyObj.toString())
        }
        val bodyText = response.bodyAsText()
        val respObj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
        val code = respObj?.get("code")?.jsonPrimitive?.intOrNull ?: 0
        val ok = response.status.isSuccess() && code == 0
        return OutboundReceipt(
            ok = ok,
            channelId = id,
            messageId = "webhook_$timestampSec",
        )
    }

    private suspend fun sendViaOpenApi(message: OutboundMessage): OutboundReceipt {
        val token = resolveTenantAccessToken()
        val receiveId = message.chatId.trim()
        require(receiveId.isNotEmpty()) { "飞书 OpenAPI 发送消息需要非空 chatId / receiveId" }
        val receiveIdType = inferReceiveIdType(receiveId)
        val card = message.card
        val msgType: String
        val contentJsonString: String
        if (card != null) {
            msgType = "interactive"
            contentJsonString = buildInteractiveCardJson(card).toString()
        } else {
            msgType = "text"
            contentJsonString = buildJsonObject { put("text", message.text) }.toString()
        }

        val payload = buildJsonObject {
            put("receive_id", receiveId)
            put("msg_type", msgType)
            put("content", contentJsonString)
        }

        val cleanBase = openApiBaseUrl.trimEnd('/')
        val url = "$cleanBase/open-apis/im/v1/messages?receive_id_type=$receiveIdType"
        val response = httpClient.post(url) {
            header(HttpHeaders.Authorization, "Bearer ${token.expose()}")
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(payload.toString())
        }
        val bodyText = response.bodyAsText()
        val respObj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
        val code = respObj?.get("code")?.jsonPrimitive?.intOrNull ?: -1
        val dataObj = respObj?.get("data")?.jsonObject
        val msgId = dataObj?.get("message_id")?.jsonPrimitive?.content ?: ""
        val ok = response.status.isSuccess() && code == 0
        logger.info("飞书 OpenAPI 发送消息完成: receiveId=$receiveId, msgType=$msgType, ok=$ok, messageId=$msgId")
        return OutboundReceipt(
            ok = ok,
            channelId = id,
            messageId = msgId,
        )
    }

    internal suspend fun resolveTenantAccessToken(): SecretValue {
        tokenMutex.withLock {
            val existing = cachedTenantToken
            if (existing != null && !existing.isWiped && clockMs() + 60_000L < cachedTenantTokenExpiresAtMs) {
                return existing
            }
            val secret = appSecret
                ?: throw IllegalStateException("未配置飞书 App Secret ($CONFIG_KEY_APP_SECRET / $ENV_APP_SECRET)")
            val cleanBase = openApiBaseUrl.trimEnd('/')
            val url = "$cleanBase/open-apis/auth/v3/tenant_access_token/internal"
            val reqBody = buildJsonObject {
                put("app_id", appId)
                put("app_secret", secret.expose())
            }
            val response = httpClient.post(url) {
                header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
                setBody(reqBody.toString())
            }
            val rawText = response.bodyAsText()
            val obj = json.parseToJsonElement(rawText).jsonObject
            val tokenStr = obj["tenant_access_token"]?.jsonPrimitive?.content
                ?: obj["app_access_token"]?.jsonPrimitive?.content
                ?: throw IllegalStateException("飞书鉴权响应未包含有效的 tenant_access_token")
            val expireSec = obj["expire"]?.jsonPrimitive?.longOrNull ?: 7200L
            val tokenSecret = SecretValue.of(tokenStr, "tenant_access_token")
            logger.registerSecret(tokenSecret)
            cachedTenantToken?.wipe()
            cachedTenantToken = tokenSecret
            cachedTenantTokenExpiresAtMs = clockMs() + (expireSec * 1000L)
            logger.info("已刷新飞书 tenant_access_token: token=$tokenSecret")
            return tokenSecret
        }
    }

    private fun parseImMessageEvent(root: JsonObject, fallbackEventId: String): InboundMessage? {
        val eventObj = root["event"]?.jsonObject ?: return null
        val senderObj = eventObj["sender"]?.jsonObject
        val senderIdObj = senderObj?.get("sender_id")?.jsonObject
        val openId = senderIdObj?.get("open_id")?.jsonPrimitive?.content
            ?: senderIdObj?.get("user_id")?.jsonPrimitive?.content
            ?: return null

        val messageObj = eventObj["message"]?.jsonObject ?: return null
        val messageId = messageObj["message_id"]?.jsonPrimitive?.content ?: fallbackEventId.ifBlank { return null }
        val chatId = messageObj["chat_id"]?.jsonPrimitive?.content ?: openId
        val chatTypeStr = messageObj["chat_type"]?.jsonPrimitive?.content ?: "p2p"
        val chatType = if (chatTypeStr == "p2p") ChatType.DIRECT else ChatType.GROUP
        val createTimeMs = messageObj["create_time"]?.jsonPrimitive?.longOrNull ?: clockMs()
        val rootId = messageObj["root_id"]?.jsonPrimitive?.content

        val rawContent = messageObj["content"]?.jsonPrimitive?.content ?: ""
        val parsedText = runCatching {
            json.parseToJsonElement(rawContent).jsonObject["text"]?.jsonPrimitive?.content
        }.getOrNull() ?: rawContent

        return InboundMessage(
            id = messageId,
            channelId = id,
            chatId = chatId,
            chatType = chatType,
            senderId = openId,
            text = parsedText.trim(),
            tainted = true,
            timestampEpochMs = createTimeMs,
            threadId = rootId,
        )
    }

    private fun parseCardActionEvent(root: JsonObject, fallbackEventId: String): InboundMessage? {
        val eventObj = root["event"]?.jsonObject ?: root
        val operatorObj = eventObj["operator"]?.jsonObject
        val openId = operatorObj?.get("open_id")?.jsonPrimitive?.content
            ?: eventObj["open_id"]?.jsonPrimitive?.content
            ?: return null
        val contextObj = eventObj["context"]?.jsonObject
        val chatId = contextObj?.get("open_chat_id")?.jsonPrimitive?.content
            ?: eventObj["open_chat_id"]?.jsonPrimitive?.content
            ?: openId
        val actionObj = eventObj["action"]?.jsonObject ?: return null
        val valueObj = actionObj["value"]?.jsonObject
        val actionString = valueObj?.get("action")?.jsonPrimitive?.content
            ?: actionObj["value"]?.jsonPrimitive?.content
            ?: ""

        // 强制通过 ImApprovalGate 解析审批动作：任何批准请求在 IM 中一律转为 DENIED (allow = false)
        val approvalDecision = ImApprovalGate.resolveCallbackDecision(actionString)
        val msgId = fallbackEventId.ifBlank { "card_cb_${clockMs()}" }

        return InboundMessage(
            id = msgId,
            channelId = id,
            chatId = chatId,
            chatType = ChatType.DIRECT,
            senderId = openId,
            text = actionString,
            tainted = true,
            timestampEpochMs = clockMs(),
            callbackData = actionString,
            approvalDecision = approvalDecision,
        )
    }
}
