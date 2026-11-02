package app.amber.cloud.channels

import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelDecisionOutcome
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundButton
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.OutboundReceipt
import app.amber.cloud.channel.SenderRole
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Telegram Bot API 通道连接器实现（实现统一 SPI [ChannelConnector]）。
 *
 * 严格遵循安全边界：
 * 1. Bot Token 仅从 [ChannelSecretLoader]（统一加密凭据库或环境变量 `AMBER_TELEGRAM_BOT_TOKEN`）读取，且绝不进入日志；
 * 2. 主人绑定基于不可变 64 位整数 `from.id`，支持 `/bind <一次性码>`，非主人消息直接拦截；
 * 3. 入站内容默认标记 `tainted = true` 并包裹 `<untrusted_input>` 沙箱；
 * 4. IM 内审批按钮只渲染「拒绝」，且任何伪造批准回调均被拦截并交由内核按 C3 v2 拒绝（403）。
 */
class TelegramChannel(
    private val baseUrl: String = "https://api.telegram.org",
    private val secretLoader: ChannelSecretLoader,
    private val ownerBinding: OwnerBindingManager,
    private val deduplicator: InboundMessageDeduplicator = InboundMessageDeduplicator(),
    private val idempotencyStore: OutboundIdempotencyStore = OutboundIdempotencyStore(),
    private val logger: RedactingChannelLogger,
    private val httpClient: HttpClient = HttpClient(OkHttp),
    private val pollIntervalMs: Long = 200L,
    private val pollTimeoutSeconds: Int = 5,
    private val streamEditMinIntervalMs: Long = 0L,
) : ChannelConnector {
    override val kind: ChannelKind = ChannelKind.TELEGRAM
    val id: String = CHANNEL_ID

    companion object {
        const val CHANNEL_ID = "telegram"
        const val CONFIG_KEY_BOT_TOKEN = "telegram.bot_token"
        const val ENV_BOT_TOKEN = "AMBER_TELEGRAM_BOT_TOKEN"
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val botToken: SecretValue = secretLoader.requireSecret(CONFIG_KEY_BOT_TOKEN, ENV_BOT_TOKEN)
    private var ingress: ChannelIngress? = null
    private var inboundCallback: (suspend (InboundMessage) -> Unit)? = null
    private var nextUpdateOffset: Long = 0L
    private var pollingJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lastEditAtByMessage = mutableMapOf<String, Long>()
    private val rejectedMessages = mutableListOf<InboundGateVerdict.RejectedNonOwner>()
    private val decisionOutcomes = mutableListOf<ChannelDecisionOutcome>()

    fun rejectedHistory(): List<InboundGateVerdict.RejectedNonOwner> =
        synchronized(rejectedMessages) { rejectedMessages.toList() }

    fun decisionHistory(): List<ChannelDecisionOutcome> =
        synchronized(decisionOutcomes) { decisionOutcomes.toList() }

    override fun attachIngress(ingress: ChannelIngress) {
        this.ingress = ingress
    }

    override suspend fun start() {
        start(onInbound = {})
    }

    suspend fun start(onInbound: suspend (InboundMessage) -> Unit) {
        this.inboundCallback = onInbound
        if (pollingJob?.isActive == true) return
        logger.info("启动 Telegram Long Polling 通道 (endpoint=${logger.redact(baseUrl)})")
        pollingJob = scope.launch {
            while (isActive) {
                try {
                    pollOnce(inboundCallback)
                } catch (ce: CancellationException) {
                    throw ce
                } catch (t: Throwable) {
                    logger.error("Telegram Long Polling 轮询异常", t)
                }
                delay(pollIntervalMs)
            }
        }
    }

    override suspend fun stop() {
        pollingJob?.cancel()
        pollingJob = null
        logger.info("已停止 Telegram Long Polling 通道")
    }

    /**
     * 执行单次 `getUpdates` 拉取并处理所有新增更新（支持连接到 [ChannelIngress] 内核或测试回调）。
     */
    suspend fun pollOnce(onInbound: (suspend (InboundMessage) -> Unit)? = null): Int {
        val requestBody = buildJsonObject {
            put("offset", nextUpdateOffset)
            put("timeout", pollTimeoutSeconds)
            put(
                "allowed_updates",
                buildJsonArray {
                    add(JsonPrimitive("message"))
                    add(JsonPrimitive("callback_query"))
                }
            )
        }
        val responseObj = callTelegramApi("getUpdates", requestBody)
        val ok = responseObj["ok"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false
        if (!ok) {
            logger.warn("Telegram getUpdates 返回非 ok 响应: ${responseObj["description"]}")
            return 0
        }

        val updates = responseObj["result"]?.jsonArray ?: JsonArray(emptyList())
        var acceptedCount = 0
        for (element in updates) {
            val update = element.jsonObject
            val updateId = update["update_id"]?.jsonPrimitive?.longOrNull ?: continue
            if (updateId >= nextUpdateOffset) {
                nextUpdateOffset = updateId + 1
            }
            if (!deduplicator.markIfFirstSeen(id, "update:$updateId")) {
                continue
            }
            val parsed = parseUpdate(update) ?: continue
            if (!deduplicator.markIfFirstSeen(id, "msg:${parsed.id}")) {
                continue
            }

            when (val verdict = ownerBinding.evaluate(parsed)) {
                is InboundGateVerdict.Allowed -> {
                    acceptedCount++
                    val verified = verdict.message
                    onInbound?.invoke(verified)
                    val attachedIngress = ingress
                    if (attachedIngress != null) {
                        val decision = verified.approvalDecision
                        if (decision != null) {
                            val outcome = attachedIngress.handleChannelDecision(
                                channel = kind,
                                senderId = verified.senderId,
                                sessionKey = decision.sessionKey.orEmpty(),
                                toolCallId = decision.toolCallId,
                                allow = decision.coercedFromApproveAttempt,
                            )
                            synchronized(decisionOutcomes) {
                                decisionOutcomes.add(outcome)
                            }
                        } else {
                            val outbound = attachedIngress.handleInbound(verified)
                            sendWithReceipt(outbound)
                        }
                    }
                }
                is InboundGateVerdict.BoundSuccess -> {
                    logger.info("Telegram 主人绑定成功: senderId=${verdict.ownerSenderId}")
                    sendWithReceipt(
                        OutboundMessage(
                            channel = kind,
                            chatId = parsed.chatId,
                            text = verdict.replyMessage,
                        )
                    )
                }
                is InboundGateVerdict.RejectedNonOwner -> {
                    synchronized(rejectedMessages) {
                        rejectedMessages.add(verdict)
                    }
                    logger.warn("拦截非主人 Telegram 消息: senderId=${verdict.senderId}, reason=${verdict.reason}")
                }
                is InboundGateVerdict.DuplicateIgnored -> Unit
            }
        }
        return acceptedCount
    }

    override suspend fun send(message: OutboundMessage): Result<String> {
        val receipt = sendWithReceipt(message)
        return if (receipt.ok) {
            Result.success(receipt.messageId)
        } else {
            Result.failure(IllegalStateException(receipt.note ?: "Telegram sendMessage failed"))
        }
    }

    override suspend fun sendWithReceipt(message: OutboundMessage): OutboundReceipt {
        return idempotencyStore.executeIdempotent(message.idempotencyKey, id) {
            val card = message.effectiveCard()
            val displayText = if (card != null) {
                buildString {
                    if (card.title.isNotBlank()) {
                        append("【").append(card.title.trim()).append("】\n")
                    }
                    append(card.markdownBody.trim())
                }
            } else {
                message.text
            }

            val payload = buildJsonObject {
                put("chat_id", message.chatId)
                put("text", displayText)
                if (message.silent) {
                    put("disable_notification", true)
                }
                if (!message.replyToMessageId.isNullOrBlank()) {
                    put("reply_to_message_id", message.replyToMessageId)
                }
                if (card != null) {
                    val safeButtons = ImApprovalGate.sanitizeOutboundButtons(card)
                    if (safeButtons.isNotEmpty()) {
                        put("reply_markup", buildInlineKeyboardMarkup(safeButtons))
                    }
                }
            }

            val resp = callTelegramApi("sendMessage", payload)
            val ok = resp["ok"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false
            val msgId = resp["result"]?.jsonObject?.get("message_id")?.jsonPrimitive?.content ?: ""
            logger.info("Telegram 发送消息完成: chatId=${message.chatId}, ok=$ok, messageId=$msgId")
            OutboundReceipt(
                ok = ok,
                channelId = id,
                messageId = msgId,
            )
        }
    }

    suspend fun editStreamMessage(
        chatId: String,
        messageId: String,
        newText: String,
        card: OutboundCard? = null,
    ): OutboundReceipt {
        val key = "$chatId:$messageId"
        val now = System.currentTimeMillis()
        val lastEdit = synchronized(lastEditAtByMessage) { lastEditAtByMessage[key] ?: 0L }
        val waitMs = (lastEdit + streamEditMinIntervalMs) - now
        if (waitMs > 0) {
            delay(waitMs)
        }
        synchronized(lastEditAtByMessage) {
            lastEditAtByMessage[key] = System.currentTimeMillis()
        }

        val displayText = if (card != null) {
            buildString {
                if (card.title.isNotBlank()) {
                    append("【").append(card.title.trim()).append("】\n")
                }
                append(card.markdownBody.trim())
            }
        } else {
            newText
        }

        val payload = buildJsonObject {
            put("chat_id", chatId)
            put("message_id", messageId.toLongOrNull() ?: 0L)
            put("text", displayText)
            if (card != null) {
                val safeButtons = ImApprovalGate.sanitizeOutboundButtons(card)
                if (safeButtons.isNotEmpty()) {
                    put("reply_markup", buildInlineKeyboardMarkup(safeButtons))
                }
            }
        }

        val resp = callTelegramApi("editMessageText", payload)
        val ok = resp["ok"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false
        val editedId = resp["result"]?.jsonObject?.get("message_id")?.jsonPrimitive?.content ?: messageId
        logger.info("Telegram 流式编辑消息完成: chatId=$chatId, messageId=$editedId, ok=$ok")
        return OutboundReceipt(
            ok = ok,
            channelId = id,
            messageId = editedId,
        )
    }

    private fun buildInlineKeyboardMarkup(buttons: List<OutboundButton>): JsonObject =
        buildJsonObject {
            put(
                "inline_keyboard",
                buildJsonArray {
                    add(
                        buildJsonArray {
                            for (btn in buttons) {
                                add(
                                    buildJsonObject {
                                        put("text", btn.text)
                                        put("callback_data", btn.actionData)
                                    }
                                )
                            }
                        }
                    )
                }
            )
        }

    private suspend fun parseUpdate(update: JsonObject): InboundMessage? {
        val messageObj = update["message"]?.jsonObject
        if (messageObj != null) {
            val msgId = messageObj["message_id"]?.jsonPrimitive?.content ?: return null
            val fromObj = messageObj["from"]?.jsonObject ?: return null
            // 强制使用不可伪造的 numeric from.id，严禁使用 @username
            val senderNumericId = fromObj["id"]?.jsonPrimitive?.longOrNull?.toString() ?: return null
            val chatObj = messageObj["chat"]?.jsonObject ?: return null
            val chatId = chatObj["id"]?.jsonPrimitive?.content ?: return null
            val rawChatType = chatObj["type"]?.jsonPrimitive?.content ?: "private"
            val scope = if (rawChatType == "private") ConversationScope.DIRECT else ConversationScope.GROUP
            val text = messageObj["text"]?.jsonPrimitive?.content
                ?: messageObj["caption"]?.jsonPrimitive?.content
                ?: ""
            val dateSec = messageObj["date"]?.jsonPrimitive?.longOrNull ?: (System.currentTimeMillis() / 1000L)
            val threadId = messageObj["message_thread_id"]?.jsonPrimitive?.intOrNull?.toString()

            return InboundMessage(
                messageId = msgId,
                channel = kind,
                chatId = chatId,
                threadId = threadId,
                senderId = senderNumericId,
                senderRole = SenderRole.GUEST,
                scope = scope,
                text = text,
                receivedAtEpochSeconds = dateSec,
                tainted = true,
            )
        }

        val callbackObj = update["callback_query"]?.jsonObject
        if (callbackObj != null) {
            val callbackId = callbackObj["id"]?.jsonPrimitive?.content ?: return null
            val fromObj = callbackObj["from"]?.jsonObject ?: return null
            val senderNumericId = fromObj["id"]?.jsonPrimitive?.longOrNull?.toString() ?: return null
            val msgObj = callbackObj["message"]?.jsonObject
            val chatObj = msgObj?.get("chat")?.jsonObject
            val chatId = chatObj?.get("id")?.jsonPrimitive?.content ?: senderNumericId
            val rawChatType = chatObj?.get("type")?.jsonPrimitive?.content ?: "private"
            val scope = if (rawChatType == "private") ConversationScope.DIRECT else ConversationScope.GROUP
            val callbackData = callbackObj["data"]?.jsonPrimitive?.content ?: ""

            // 强制通过 ImApprovalGate 解析审批动作：任何批准请求在 IM 中一律转为 DENIED (allow = false)
            val approvalDecision = ImApprovalGate.resolveCallbackDecision(callbackData)

            // 应答 Telegram callbackQuery
            runCatching {
                callTelegramApi(
                    "answerCallbackQuery",
                    buildJsonObject {
                        put("callback_query_id", callbackId)
                        put("text", approvalDecision?.reason ?: "已收到操作")
                    }
                )
            }

            return InboundMessage(
                messageId = "cb_$callbackId",
                channel = kind,
                chatId = chatId,
                senderId = senderNumericId,
                senderRole = SenderRole.GUEST,
                scope = scope,
                text = callbackData,
                tainted = true,
                callbackData = callbackData,
                approvalDecision = approvalDecision,
            )
        }

        return null
    }

    private suspend fun callTelegramApi(method: String, payload: JsonObject): JsonObject {
        val cleanBase = baseUrl.trimEnd('/')
        val fullUrl = "$cleanBase/bot${botToken.expose()}/$method"
        logger.info("调用 Telegram API: method=$method, url=${logger.redact(fullUrl)}")
        val response = httpClient.post(fullUrl) {
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(payload.toString())
        }
        val rawText = response.bodyAsText()
        if (!response.status.isSuccess()) {
            logger.warn("Telegram API HTTP 非 2xx: method=$method, status=${response.status.value}")
        }
        return runCatching { json.parseToJsonElement(rawText).jsonObject }
            .getOrElse {
                buildJsonObject {
                    put("ok", false)
                    put("description", "Invalid JSON response")
                }
            }
    }
}
