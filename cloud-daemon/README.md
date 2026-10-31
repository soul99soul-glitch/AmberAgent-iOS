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

---

## 3. 接入真实服务（配置项清单与获取步骤）

`amberd` 通过 `CloudConfigLoader` 统一从配置文件（默认 `$AMBER_DATA_DIR/amberd.json`，或通过 `--config` / `AMBER_CONFIG_FILE` 指定）与环境变量加载配置。所有敏感密钥在启动加载时自动校验占位符并采用信封加密（PBKDF2-HMAC-SHA256 + AES-256-GCM）写入 `$AMBER_DATA_DIR/secrets.enc.json`（权限 `0600`）。

> **安全约束**：请勿在代码仓库、日志或配置文件中提交任何真实密钥或脱敏占位符（如 `<redacted>`、`***`、`«已脱敏»`）。

### 3.1 配置项名称对照表

| 模块 | 配置文件键名（`amberd.json`） | 环境变量名 | 是否加密入库 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| **主密钥** | — | `AMBER_MASTER_KEY` / `AMBER_MASTER_KEY_FILE` | 根密钥（KEK） | 用于派生信封加密主密钥（生产环境建议配合 systemd `CREDENTIALS_DIRECTORY`） |
| **Telegram** | `telegram.bot_token` | `AMBER_TELEGRAM_BOT_TOKEN` | 是（`secrets.enc.json`） | Telegram 机器人 Bot Token |
| **Telegram** | `telegram.base_url` | `AMBER_TELEGRAM_BASE_URL` | 否 | Telegram API 地址（默认 `https://api.telegram.org`） |
| **Telegram** | `telegram.owner_id` | `AMBER_TELEGRAM_OWNER_ID` | 否 | 可选预置主人数字 ID（未设置时在私聊发送 `/bind <一次性码>` 绑定） |
| **飞书机器人** | `feishu.app_id` | `AMBER_FEISHU_APP_ID` | 否 | 飞书企业自建应用 App ID |
| **飞书机器人** | `feishu.app_secret` | `AMBER_FEISHU_APP_SECRET` | 是（`secrets.enc.json`） | 飞书企业自建应用 App Secret（用于换取 `tenant_access_token`） |
| **飞书机器人** | `feishu.encrypt_key` | `AMBER_FEISHU_ENCRYPT_KEY` | 是（`secrets.enc.json`） | 飞书事件订阅 Encrypt Key（用于校验 `X-Lark-Signature`） |
| **飞书机器人** | `feishu.webhook_url` | `AMBER_FEISHU_WEBHOOK_URL` | 否 | 可选自定义群机器人 Webhook 地址 |
| **飞书机器人** | `feishu.webhook_secret` | `AMBER_FEISHU_WEBHOOK_SECRET` | 是（`secrets.enc.json`） | 可选自定义群机器人签名校验密钥（HMAC-SHA256） |
| **飞书机器人** | `feishu.owner_open_id` | `AMBER_FEISHU_OWNER_OPEN_ID` | 否 | 可选预置主人飞书 `open_id`（未设置时在私聊发送 `/bind <一次性码>` 绑定） |
| **飞书日历** | `feishu.caldav_server_url` | `AMBER_FEISHU_CALDAV_URL` | 否 | 飞书 CalDAV 服务地址（默认 `https://caldav.feishu.cn`） |
| **飞书日历** | `feishu.caldav_username` | `AMBER_FEISHU_CALDAV_USERNAME` | 否 | 飞书 CalDAV 专用用户名 |
| **飞书日历** | `feishu.caldav_password` | `AMBER_FEISHU_CALDAV_PASSWORD` | 是（`secrets.enc.json`） | 飞书 CalDAV 专用密码 |
| **主动引擎 L2** | `proactive.l2_provider` | `AMBER_PROACTIVE_L2_PROVIDER` | 否 | 主动引擎 L2 快判模型提供方（如 `deepseek`、`openai`、`claude`） |
| **主动引擎 L2** | `proactive.l2_model` | `AMBER_PROACTIVE_L2_MODEL` | 否 | 主动引擎 L2 快判模型 ID |
| **主动引擎 L2** | `proactive.l2_base_url` | `AMBER_PROACTIVE_L2_BASE_URL` | 否 | 主动引擎 L2 模型 API 地址 |
| **主动引擎 L2** | `proactive.l2_api_key` | `AMBER_PROACTIVE_L2_API_KEY` | 是（`secrets.enc.json`） | 主动引擎 L2 快判模型 API Key |
| **主动引擎节制** | `proactive.quiet_hours_start` / `proactive.quiet_hours_end` | `AMBER_PROACTIVE_QUIET_HOURS_START` / `AMBER_PROACTIVE_QUIET_HOURS_END` | 否 | 静默时段起止时间（默认 `23:00` 至 `08:00`） |
| **主动引擎节制** | `proactive.daily_max_pushes` | `AMBER_PROACTIVE_DAILY_MAX_PUSHES` | 否 | 每日主动强触达预算上限（默认 `5`） |
| **主模型** | `model.provider` / `model.id` / `model.base_url` | `AMBER_MODEL_PROVIDER` / `AMBER_MODEL_ID` / `AMBER_MODEL_BASE_URL` | 否 | 主智能体推理模型提供方、模型 ID 与 API 地址 |
| **主模型** | `model.api_key` | `AMBER_MODEL_API_KEY` | 是（`secrets.enc.json`） | 主智能体推理模型 API Key |

### 3.2 各服务凭据获取步骤

1. **Telegram Bot Token（`AMBER_TELEGRAM_BOT_TOKEN`）**
   - 在 Telegram 中打开官方 `@BotFather`，发送 `/newbot` 并按提示设置名称与用户名。
   - 复制生成的 Bot Token 并通过环境变量 `AMBER_TELEGRAM_BOT_TOKEN` 或配置文件 `telegram.bot_token` 注入。
   - 启动 `amberd` 后，使用生成的 3 分钟一次性绑定码在机器人私聊发送 `/bind <一次性码>` 完成主人数字 ID（`from.id`）绑定。

2. **飞书企业自建应用（`AMBER_FEISHU_APP_ID` / `AMBER_FEISHU_APP_SECRET` / `AMBER_FEISHU_ENCRYPT_KEY`）**
   - 登录飞书开放平台（开发者后台），创建「企业自建应用」，在「凭证与基础信息」页获取 `App ID` 与 `App Secret`。
   - 在「应用能力」中启用「机器人」，并在「权限管理」中开通消息收发（`im:message`）与日历只读/读写相关权限。
   - 在「事件与回调」中配置请求网址为 `https://<你的网关域名>/v1/channels/feishu/webhook`，开启加密策略并获取 `Encrypt Key`，订阅 `im.message.receive_v1` 与卡片交互回调 `card.action.trigger`。
   - 发布应用版本后，在飞书与机器人私聊发送 `/bind <一次性码>` 绑定主人 `open_id`。

3. **飞书 CalDAV 日历凭据（`AMBER_FEISHU_CALDAV_USERNAME` / `AMBER_FEISHU_CALDAV_PASSWORD`）**
   - 打开飞书客户端「设置 → 日历 → 第三方日历管理 → CalDAV 同步设置」。
   - 生成一台新设备的 CalDAV 用户名与专用密码，分别填入 `feishu.caldav_username` 与 `AMBER_FEISHU_CALDAV_PASSWORD`。

4. **主动引擎 L2 模型与主模型 API Key（`AMBER_PROACTIVE_L2_API_KEY` / `AMBER_MODEL_API_KEY`）**
   - 在对应模型服务商控制台创建 API Key，分别配置到 `AMBER_PROACTIVE_L2_API_KEY`（用于 L1 通过后的低成本 `noteworthy` 快判）与 `AMBER_MODEL_API_KEY`（用于主对话推理）。
