package app.amber.cloud.config

import app.amber.ai.provider.ProviderSetting
import app.amber.ai.ui.UIMessage
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.KmpProviderModelClient
import app.amber.cloud.security.EnvelopeCredentialVault
import java.net.URI

/** Startup configuration selects the existing provider adapters; credentials stay in the existing vault. */
internal fun configuredModelClient(config: CloudDaemonConfig, vault: EnvelopeCredentialVault): CloudModelClient {
    val provider = config.modelProvider.trim().lowercase()
    if (provider == "echo") return CloudModelClient { messages, _ ->
        UIMessage.assistant("Amber Cloud Self 已收到: ${messages.lastOrNull()?.toText().orEmpty().lineSequence().firstOrNull().orEmpty()}")
    }
    require(provider in setOf("openai", "claude")) {
        "请设置 AMBER_MODEL_PROVIDER / model.provider 为 openai 或 claude；开发回显须显式选择 echo"
    }
    val modelId = config.modelId.trim()
    require(modelId.isNotEmpty()) { "请设置 AMBER_MODEL_ID / model.id" }
    val baseUrl = config.modelBaseUrl.trim().ifEmpty {
        if (provider == "openai") "https://api.openai.com/v1" else "https://api.anthropic.com/v1"
    }.trimEnd('/')
    val uri = runCatching { URI(baseUrl) }.getOrNull()
    require(uri != null && uri.scheme in setOf("https", "http") && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
        "AMBER_MODEL_BASE_URL / model.base_url 必须是无凭据、查询参数或 fragment 的 HTTP(S) API 根地址"
    }
    val key = vault.getSecret(CloudConfigLoader.KEY_MODEL_API_KEY)?.trim()
    require(!key.isNullOrEmpty()) {
        "未配置模型 Key：请设置 AMBER_MODEL_API_KEY / model.api_key（自动加密入库），并核对 AMBER_MODEL_PROVIDER、AMBER_MODEL_ID"
    }
    val setting = if (provider == "openai") ProviderSetting.OpenAI(apiKey = key, baseUrl = baseUrl)
        else ProviderSetting.Claude(apiKey = key, baseUrl = baseUrl)
    return KmpProviderModelClient(setting, modelId)
}
