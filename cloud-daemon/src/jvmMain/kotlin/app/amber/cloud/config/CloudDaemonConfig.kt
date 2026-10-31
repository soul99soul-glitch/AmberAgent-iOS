package app.amber.cloud.config

import app.amber.cloud.channels.ChannelSecretLoader
import app.amber.cloud.channels.FeishuCalendarClient
import app.amber.cloud.channels.FeishuChannel
import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.channels.SecretValue
import app.amber.cloud.channels.TelegramChannel
import app.amber.cloud.proactive.InterruptionBudgetConfig
import app.amber.cloud.proactive.QuietHoursConfig
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.time.LocalTime
import java.time.ZoneId

/**
 * Unified configuration snapshot for `amberd` (non-secret values only; all secrets live in [EnvelopeCredentialVault]).
 */
@Serializable
data class CloudDaemonConfig(
    val telegramBaseUrl: String = "https://api.telegram.org",
    val telegramOwnerId: String = "",
    val feishuOpenApiBaseUrl: String = "https://open.feishu.cn",
    val feishuAppId: String = "",
    val feishuWebhookUrl: String = "",
    val feishuOwnerOpenId: String = "",
    val feishuCalDavServerUrl: String = "https://caldav.feishu.cn",
    val feishuCalDavUsername: String = "",
    val proactiveL2Provider: String = "deepseek",
    val proactiveL2Model: String = "deepseek-chat",
    val proactiveL2BaseUrl: String = "https://api.deepseek.com/v1",
    val quietHoursEnabled: Boolean = true,
    val quietHoursStart: String = "23:00",
    val quietHoursEnd: String = "08:00",
    val dailyMaxPushes: Int = 5,
    val modelProvider: String = "claude",
    val modelId: String = "claude-sonnet-4-5-20250929",
    val modelBaseUrl: String = "",
) {
    fun toQuietHoursConfig(zoneId: ZoneId = ZoneId.of("Asia/Shanghai")): QuietHoursConfig {
        val start = runCatching { LocalTime.parse(quietHoursStart.trim()) }.getOrDefault(LocalTime.of(23, 0))
        val end = runCatching { LocalTime.parse(quietHoursEnd.trim()) }.getOrDefault(LocalTime.of(8, 0))
        return QuietHoursConfig(
            enabled = quietHoursEnabled,
            start = start,
            end = end,
            zoneId = zoneId,
        )
    }

    fun toInterruptionBudgetConfig(zoneId: ZoneId = ZoneId.of("Asia/Shanghai")): InterruptionBudgetConfig {
        return InterruptionBudgetConfig(
            dailyMaxPushes = dailyMaxPushes.coerceAtLeast(1),
            zoneId = zoneId,
        )
    }
}

/**
 * Unified configuration & credential loader for `amberd`.
 *
 * Reads configuration from a single unified config file (`amberd.json` or `.env`/`.properties`)
 * plus environment variables, validates that no placeholder credentials are provided, and persists
 * all secret items into the unified [EnvelopeCredentialVault] (`secrets.enc.json`).
 */
object CloudConfigLoader {

    const val KEY_TELEGRAM_BOT_TOKEN = TelegramChannel.CONFIG_KEY_BOT_TOKEN
    const val ENV_TELEGRAM_BOT_TOKEN = TelegramChannel.ENV_BOT_TOKEN
    const val KEY_TELEGRAM_BASE_URL = "telegram.base_url"
    const val ENV_TELEGRAM_BASE_URL = "AMBER_TELEGRAM_BASE_URL"
    const val KEY_TELEGRAM_OWNER_ID = "telegram.owner_id"
    const val ENV_TELEGRAM_OWNER_ID = "AMBER_TELEGRAM_OWNER_ID"

    const val KEY_FEISHU_APP_ID = FeishuChannel.CONFIG_KEY_APP_ID
    const val ENV_FEISHU_APP_ID = FeishuChannel.ENV_APP_ID
    const val KEY_FEISHU_APP_SECRET = FeishuChannel.CONFIG_KEY_APP_SECRET
    const val ENV_FEISHU_APP_SECRET = FeishuChannel.ENV_APP_SECRET
    const val KEY_FEISHU_ENCRYPT_KEY = FeishuChannel.CONFIG_KEY_ENCRYPT_KEY
    const val ENV_FEISHU_ENCRYPT_KEY = FeishuChannel.ENV_ENCRYPT_KEY
    const val KEY_FEISHU_WEBHOOK_URL = "feishu.webhook_url"
    const val ENV_FEISHU_WEBHOOK_URL = "AMBER_FEISHU_WEBHOOK_URL"
    const val KEY_FEISHU_WEBHOOK_SECRET = FeishuChannel.CONFIG_KEY_WEBHOOK_SECRET
    const val ENV_FEISHU_WEBHOOK_SECRET = FeishuChannel.ENV_WEBHOOK_SECRET
    const val KEY_FEISHU_BASE_URL = "feishu.open_api_base_url"
    const val ENV_FEISHU_BASE_URL = "AMBER_FEISHU_BASE_URL"
    const val KEY_FEISHU_OWNER_OPEN_ID = "feishu.owner_open_id"
    const val ENV_FEISHU_OWNER_OPEN_ID = "AMBER_FEISHU_OWNER_OPEN_ID"

    const val KEY_FEISHU_CALDAV_URL = "feishu.caldav_server_url"
    const val ENV_FEISHU_CALDAV_URL = "AMBER_FEISHU_CALDAV_URL"
    const val KEY_FEISHU_CALDAV_USERNAME = "feishu.caldav_username"
    const val ENV_FEISHU_CALDAV_USERNAME = "AMBER_FEISHU_CALDAV_USERNAME"
    const val KEY_FEISHU_CALDAV_PASSWORD = FeishuCalendarClient.CONFIG_KEY_CALDAV_PASSWORD
    const val ENV_FEISHU_CALDAV_PASSWORD = FeishuCalendarClient.ENV_CALDAV_PASSWORD

    const val KEY_PROACTIVE_L2_PROVIDER = "proactive.l2_provider"
    const val ENV_PROACTIVE_L2_PROVIDER = "AMBER_PROACTIVE_L2_PROVIDER"
    const val KEY_PROACTIVE_L2_MODEL = "proactive.l2_model"
    const val ENV_PROACTIVE_L2_MODEL = "AMBER_PROACTIVE_L2_MODEL"
    const val KEY_PROACTIVE_L2_BASE_URL = "proactive.l2_base_url"
    const val ENV_PROACTIVE_L2_BASE_URL = "AMBER_PROACTIVE_L2_BASE_URL"
    const val KEY_PROACTIVE_L2_API_KEY = "proactive.l2_api_key"
    const val ENV_PROACTIVE_L2_API_KEY = "AMBER_PROACTIVE_L2_API_KEY"

    const val KEY_PROACTIVE_QUIET_ENABLED = "proactive.quiet_hours_enabled"
    const val ENV_PROACTIVE_QUIET_ENABLED = "AMBER_PROACTIVE_QUIET_HOURS_ENABLED"
    const val KEY_PROACTIVE_QUIET_START = "proactive.quiet_hours_start"
    const val ENV_PROACTIVE_QUIET_START = "AMBER_PROACTIVE_QUIET_HOURS_START"
    const val KEY_PROACTIVE_QUIET_END = "proactive.quiet_hours_end"
    const val ENV_PROACTIVE_QUIET_END = "AMBER_PROACTIVE_QUIET_HOURS_END"
    const val KEY_PROACTIVE_DAILY_MAX_PUSHES = "proactive.daily_max_pushes"
    const val ENV_PROACTIVE_DAILY_MAX_PUSHES = "AMBER_PROACTIVE_DAILY_MAX_PUSHES"

    const val KEY_MODEL_PROVIDER = "model.provider"
    const val ENV_MODEL_PROVIDER = "AMBER_MODEL_PROVIDER"
    const val KEY_MODEL_ID = "model.id"
    const val ENV_MODEL_ID = "AMBER_MODEL_ID"
    const val KEY_MODEL_BASE_URL = "model.base_url"
    const val ENV_MODEL_BASE_URL = "AMBER_MODEL_BASE_URL"
    const val KEY_MODEL_API_KEY = "model.api_key"
    const val ENV_MODEL_API_KEY = "AMBER_MODEL_API_KEY"

    private val SECRET_MAPPINGS = listOf(
        KEY_TELEGRAM_BOT_TOKEN to ENV_TELEGRAM_BOT_TOKEN,
        KEY_FEISHU_APP_SECRET to ENV_FEISHU_APP_SECRET,
        KEY_FEISHU_ENCRYPT_KEY to ENV_FEISHU_ENCRYPT_KEY,
        KEY_FEISHU_WEBHOOK_SECRET to ENV_FEISHU_WEBHOOK_SECRET,
        KEY_FEISHU_CALDAV_PASSWORD to ENV_FEISHU_CALDAV_PASSWORD,
        KEY_PROACTIVE_L2_API_KEY to ENV_PROACTIVE_L2_API_KEY,
        KEY_MODEL_API_KEY to ENV_MODEL_API_KEY,
    )

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Loads configuration from [configFile] (optional) + [env], ingests all secrets into [vault],
     * registers secret literals on [logger], and optionally pre-binds owners in [ownerBinding].
     */
    fun loadAndIngest(
        configFile: File? = null,
        env: Map<String, String> = System.getenv(),
        vault: EnvelopeCredentialVault,
        logger: RedactingChannelLogger = RedactingChannelLogger(),
        ownerBinding: OwnerBindingManager? = null,
    ): CloudDaemonConfig {
        val fileMap = parseConfigFile(configFile)

        fun resolveValue(configKey: String, envName: String): String? {
            val fromEnv = env[envName]?.trim()?.takeIf { it.isNotEmpty() }
            if (fromEnv != null) return fromEnv
            val fromFileByKey = fileMap[configKey]?.trim()?.takeIf { it.isNotEmpty() }
            if (fromFileByKey != null) return fromFileByKey
            val fromFileByEnv = fileMap[envName]?.trim()?.takeIf { it.isNotEmpty() }
            return fromFileByEnv
        }

        // 1. Ingest all secret values into unified EnvelopeCredentialVault
        for ((configKey, envName) in SECRET_MAPPINGS) {
            val rawSecret = resolveValue(configKey, envName)
            if (rawSecret != null) {
                if (CredentialRedactor.isPlaceholderCredential(rawSecret)) {
                    throw PlaceholderCredentialException("配置项 $configKey / $envName 包含脱敏占位符，已拒绝写入凭据库")
                }
                vault.putSecret(configKey, rawSecret)
                logger.registerLiteral(rawSecret)
            } else {
                // If already stored in vault from previous run, register with logger for redaction
                vault.getSecret(configKey)?.let { logger.registerLiteral(it) }
            }
        }

        // 2. Build non-secret config snapshot
        val cfg = CloudDaemonConfig(
            telegramBaseUrl = resolveValue(KEY_TELEGRAM_BASE_URL, ENV_TELEGRAM_BASE_URL) ?: "https://api.telegram.org",
            telegramOwnerId = resolveValue(KEY_TELEGRAM_OWNER_ID, ENV_TELEGRAM_OWNER_ID).orEmpty(),
            feishuOpenApiBaseUrl = resolveValue(KEY_FEISHU_BASE_URL, ENV_FEISHU_BASE_URL) ?: "https://open.feishu.cn",
            feishuAppId = resolveValue(KEY_FEISHU_APP_ID, ENV_FEISHU_APP_ID).orEmpty(),
            feishuWebhookUrl = resolveValue(KEY_FEISHU_WEBHOOK_URL, ENV_FEISHU_WEBHOOK_URL).orEmpty(),
            feishuOwnerOpenId = resolveValue(KEY_FEISHU_OWNER_OPEN_ID, ENV_FEISHU_OWNER_OPEN_ID).orEmpty(),
            feishuCalDavServerUrl = resolveValue(KEY_FEISHU_CALDAV_URL, ENV_FEISHU_CALDAV_URL) ?: "https://caldav.feishu.cn",
            feishuCalDavUsername = resolveValue(KEY_FEISHU_CALDAV_USERNAME, ENV_FEISHU_CALDAV_USERNAME).orEmpty(),
            proactiveL2Provider = resolveValue(KEY_PROACTIVE_L2_PROVIDER, ENV_PROACTIVE_L2_PROVIDER) ?: "deepseek",
            proactiveL2Model = resolveValue(KEY_PROACTIVE_L2_MODEL, ENV_PROACTIVE_L2_MODEL) ?: "deepseek-chat",
            proactiveL2BaseUrl = resolveValue(KEY_PROACTIVE_L2_BASE_URL, ENV_PROACTIVE_L2_BASE_URL) ?: "https://api.deepseek.com/v1",
            quietHoursEnabled = resolveValue(KEY_PROACTIVE_QUIET_ENABLED, ENV_PROACTIVE_QUIET_ENABLED)?.toBooleanStrictOrNull() ?: true,
            quietHoursStart = resolveValue(KEY_PROACTIVE_QUIET_START, ENV_PROACTIVE_QUIET_START) ?: "23:00",
            quietHoursEnd = resolveValue(KEY_PROACTIVE_QUIET_END, ENV_PROACTIVE_QUIET_END) ?: "08:00",
            dailyMaxPushes = resolveValue(KEY_PROACTIVE_DAILY_MAX_PUSHES, ENV_PROACTIVE_DAILY_MAX_PUSHES)?.toIntOrNull() ?: 5,
            modelProvider = resolveValue(KEY_MODEL_PROVIDER, ENV_MODEL_PROVIDER) ?: "claude",
            modelId = resolveValue(KEY_MODEL_ID, ENV_MODEL_ID) ?: "claude-sonnet-4-5-20250929",
            modelBaseUrl = resolveValue(KEY_MODEL_BASE_URL, ENV_MODEL_BASE_URL).orEmpty(),
        )

        if (ownerBinding != null) {
            if (cfg.telegramOwnerId.isNotBlank()) {
                ownerBinding.bindOwnerDirectly(TelegramChannel.CHANNEL_ID, cfg.telegramOwnerId)
            }
            if (cfg.feishuOwnerOpenId.isNotBlank()) {
                ownerBinding.bindOwnerDirectly(FeishuChannel.CHANNEL_ID, cfg.feishuOwnerOpenId)
            }
        }

        return cfg
    }

    fun resolveL2ApiKey(
        vault: EnvelopeCredentialVault,
        env: Map<String, String> = System.getenv(),
        logger: RedactingChannelLogger = RedactingChannelLogger(),
    ): SecretValue? {
        val loader = ChannelSecretLoader(vault = vault, envProvider = { env[it] }, logger = logger)
        return loader.resolveOptionalSecret(KEY_PROACTIVE_L2_API_KEY, ENV_PROACTIVE_L2_API_KEY)
    }

    fun createTelegramChannelOrNull(
        config: CloudDaemonConfig,
        vault: EnvelopeCredentialVault,
        ownerBinding: OwnerBindingManager,
        logger: RedactingChannelLogger,
        httpClient: HttpClient = HttpClient(OkHttp),
        env: Map<String, String> = System.getenv(),
    ): TelegramChannel? {
        val loader = ChannelSecretLoader(vault = vault, envProvider = { env[it] }, logger = logger)
        loader.resolveOptionalSecret(KEY_TELEGRAM_BOT_TOKEN, ENV_TELEGRAM_BOT_TOKEN) ?: return null
        return TelegramChannel(
            baseUrl = config.telegramBaseUrl,
            secretLoader = loader,
            ownerBinding = ownerBinding,
            logger = logger,
            httpClient = httpClient,
        )
    }

    fun createFeishuChannelOrNull(
        config: CloudDaemonConfig,
        vault: EnvelopeCredentialVault,
        ownerBinding: OwnerBindingManager,
        logger: RedactingChannelLogger,
        httpClient: HttpClient = HttpClient(OkHttp),
        env: Map<String, String> = System.getenv(),
    ): FeishuChannel? {
        val loader = ChannelSecretLoader(vault = vault, envProvider = { env[it] }, logger = logger)
        val hasSecret = loader.resolveOptionalSecret(KEY_FEISHU_APP_SECRET, ENV_FEISHU_APP_SECRET) != null ||
            loader.resolveOptionalSecret(KEY_FEISHU_WEBHOOK_SECRET, ENV_FEISHU_WEBHOOK_SECRET) != null ||
            config.feishuWebhookUrl.isNotBlank()
        if (!hasSecret) return null
        return FeishuChannel(
            openApiBaseUrl = config.feishuOpenApiBaseUrl,
            appId = config.feishuAppId,
            webhookUrl = config.feishuWebhookUrl,
            secretLoader = loader,
            ownerBinding = ownerBinding,
            logger = logger,
            httpClient = httpClient,
        )
    }

    fun createFeishuCalendarClientOrNull(
        config: CloudDaemonConfig,
        vault: EnvelopeCredentialVault,
        logger: RedactingChannelLogger,
        httpClient: HttpClient = HttpClient(OkHttp),
        env: Map<String, String> = System.getenv(),
    ): FeishuCalendarClient? {
        val loader = ChannelSecretLoader(vault = vault, envProvider = { env[it] }, logger = logger)
        loader.resolveOptionalSecret(KEY_FEISHU_CALDAV_PASSWORD, ENV_FEISHU_CALDAV_PASSWORD) ?: return null
        if (config.feishuCalDavUsername.isBlank()) return null
        return FeishuCalendarClient(
            calDavServerUrl = config.feishuCalDavServerUrl,
            calDavUsername = config.feishuCalDavUsername,
            secretLoader = loader,
            logger = logger,
            httpClient = httpClient,
        )
    }

    private fun parseConfigFile(configFile: File?): Map<String, String> {
        if (configFile == null || !configFile.isFile) return emptyMap()
        val raw = configFile.readText().trim()
        if (raw.isEmpty()) return emptyMap()
        if (raw.startsWith("{")) {
            val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return emptyMap()
            val out = LinkedHashMap<String, String>()
            flattenJson("", root, out)
            return out
        }
        val out = LinkedHashMap<String, String>()
        for (line in raw.lines()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("//")) continue
            val normalized = trimmed.removePrefix("export ").trim()
            val eqIdx = normalized.indexOf('=')
            if (eqIdx <= 0) continue
            val k = normalized.substring(0, eqIdx).trim()
            val v = normalized.substring(eqIdx + 1).trim().removeSurrounding("\"").removeSurrounding("'")
            out[k] = v
        }
        return out
    }

    private fun flattenJson(prefix: String, obj: JsonObject, dest: MutableMap<String, String>) {
        for ((k, v) in obj) {
            val fullKey = if (prefix.isEmpty()) k else "$prefix.$k"
            when (v) {
                is JsonPrimitive -> dest[fullKey] = v.content
                is JsonObject -> flattenJson(fullKey, v, dest)
                else -> Unit
            }
        }
    }
}
