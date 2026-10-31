# Amber Cloud Daemon (`:cloud-daemon`)

`cloud-daemon` 是 Amber 云端本体（Amber Cloud Self）的常驻内核与 C3 网关守护进程模块（纯 Kotlin/JVM），产出两个可执行入口：
- **`amberd`**：常驻守护进程（主时间线与多会话持久化、KMP Agent 运行时编排、信封加密凭据库、通道注入路由、C3 v1/v2 Ktor 网关服务）。
- **`amber-cli`**：云主机命令行管理工具（生成终端 ANSI 二维码与 `amber://gateway/pair?p=` 配对深链、查看状态、管理设备与审计日志）。

---

## 1. 通道注入接口（Channel SPI）

Telegram、飞书等外部消息连接器通过 `app.amber.cloud.channel` 包中的标准 SPI 与 `amberd` 交互。

### 1.1 会话路由规则
- **私聊入口（`ConversationScope.DIRECT`）**：飞书私聊、Telegram 私聊、以及原生 App 默认对话**共用同一条持久主时间线**（固定主会话 ID `00000000-0000-4000-8000-000000000001`），跨渠道切换和进程重启后上下文与记忆完全连续。
- **群聊与专项任务（`ConversationScope.GROUP` / `ConversationScope.TASK`）**：按 `(channel, chatId, threadId)` 确定性派生独立会话 UUID，与个人主时间线隔离。

### 1.2 核心数据结构与接口定义（`app.amber.cloud.channel`）

```kotlin
package app.amber.cloud.channel

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ChannelKind(val wireName: String) {
    @SerialName("telegram") TELEGRAM("telegram"),
    @SerialName("feishu") FEISHU("feishu"),
    @SerialName("app") APP("app"),
    @SerialName("cli") CLI("cli"),
    @SerialName("custom") CUSTOM("custom"),
}

@Serializable
enum class ConversationScope {
    /** 所有私聊入口共用同一条主时间线（PRIMARY_CONVERSATION_ID）。 */
    @SerialName("direct") DIRECT,
    /** 群聊或群话题独立开线程。 */
    @SerialName("group") GROUP,
    /** 专项后台任务或定时任务独立开线程。 */
    @SerialName("task") TASK,
}

@Serializable
enum class SenderRole {
    @SerialName("owner") OWNER,
    @SerialName("collaborator") COLLABORATOR,
    @SerialName("guest") GUEST,
}

@Serializable
data class ChannelAttachment(
    val kind: String,
    val url: String,
    val fileName: String? = null,
    val mimeType: String? = null,
)

@Serializable
data class InboundMessage(
    val messageId: String,
    val channel: ChannelKind,
    val chatId: String,
    val threadId: String? = null,
    val senderId: String,
    val senderName: String? = null,
    val senderRole: SenderRole = SenderRole.OWNER,
    val scope: ConversationScope = ConversationScope.DIRECT,
    val text: String,
    val isExplicitMention: Boolean = false,
    val replyToMessageId: String? = null,
    val attachments: List<ChannelAttachment> = emptyList(),
    val receivedAtEpochSeconds: Long = System.currentTimeMillis() / 1000L,
    val metadata: Map<String, String> = emptyMap(),
)

@Serializable
data class ChannelApprovalCard(
    val sessionKey: String,
    val toolCallId: String,
    val toolName: String,
    val redactedDetail: String,
    val highRisk: Boolean,
    /**
     * C3 v2 铁律：IM 渠道对高风险操作只能拒绝（highRisk == true 时恒为 false，
     * 卡片只允许渲染「拒绝」按钮，批准必须去已配对且已解锁的原生 App 前台）。
     */
    val allowApproveInChannel: Boolean = !highRisk,
)

@Serializable
data class OutboundMessage(
    val channel: ChannelKind,
    val chatId: String,
    val threadId: String? = null,
    val replyToMessageId: String? = null,
    val text: String,
    val conversationId: String,
    val markdown: Boolean = true,
    val silent: Boolean = false,
    val approvalCard: ChannelApprovalCard? = null,
    val metadata: Map<String, String> = emptyMap(),
)

@Serializable
data class ChannelDecisionOutcome(
    val httpStatus: Int,
    val outcome: String,
    val error: String? = null,
)

/**
 * 由 `amberd` 内核实现的入站消费接口，供各 ChannelConnector 调用。
 */
interface ChannelIngress {
    /**
     * 注入一条入站消息，推动对应会话（私聊走主时间线，群聊/专项走独立线程）执行一轮推理并持久化。
     */
    suspend fun handleInbound(message: InboundMessage): OutboundMessage

    /**
     * 处理来自 IM 渠道卡片按钮的审批回调。
     * 注意：IM 渠道属于非可信前台来源，当目标工具为 `highRisk == true` 且 `allow == true` 时，
     * 内核强制返回 `httpStatus = 403, outcome = "rejected_high_risk"`。
     */
    suspend fun handleChannelDecision(
        channel: ChannelKind,
        senderId: String,
        sessionKey: String,
        toolCallId: String,
        allow: Boolean,
    ): ChannelDecisionOutcome
}

/**
 * 外部消息通道（Telegram / 飞书等）实现的连接器 SPI。
 */
interface ChannelConnector {
    val kind: ChannelKind
    fun attachIngress(ingress: ChannelIngress)
    suspend fun start()
    suspend fun stop()
    suspend fun send(message: OutboundMessage): Result<String>
}
```

---

## 2. 启动与运行方式

### 2.1 本地 JVM 启动
```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export AMBER_MASTER_KEY="your-32-byte-master-passphrase"
export AMBER_DATA_DIR="/tmp/amberd-data"

# 启动 amberd 守护进程（默认监听 0.0.0.0:47821）
./gradlew :cloud-daemon:run --args="daemon --port 47821"

# 生成终端二维码与 amber://gateway/pair?p= 配对深链（兼容现有 iOS 客户端扫码）
./gradlew :cloud-daemon:runCli --args="pair"
```

### 2.2 Docker 容器启动
```bash
docker build -t amberd:local -f cloud-daemon/Dockerfile .
docker run --rm -it \
  -p 47821:47821 \
  -e AMBER_MASTER_KEY="your-master-key" \
  -v amberd-data:/var/lib/amberd \
  amberd:local
```

### 2.3 systemd 部署
参考 `cloud-daemon/systemd/amberd.service`，支持通过 `LoadCredentialEncrypted=amber_master_key:...`（`CREDENTIALS_DIRECTORY`）或 `AMBER_MASTER_KEY` 派生 AES-256-GCM 主密钥。
