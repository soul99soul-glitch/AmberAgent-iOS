package app.amber.cloud

import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.config.CloudConfigLoader
import app.amber.cloud.config.CloudDaemonConfig
import app.amber.cloud.config.CloudConfigurationManager
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.proactive.CloudProactiveL2Judge
import app.amber.cloud.proactive.L1DeterministicFilter
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveFilePersistence
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.security.EnvelopeCredentialVault
import java.io.File

internal data class ConfiguredCloudDaemon(val config: CloudDaemonConfig, val kernel: CloudAgentKernel)

/** Shared by Main and local protocol tests so startup cannot silently bypass model configuration. */
internal fun loadConfiguredDaemon(
    dataDir: File,
    configFile: File = File(dataDir, "amberd.json"),
    env: Map<String, String> = System.getenv(),
    logger: RedactingChannelLogger = RedactingChannelLogger(),
): ConfiguredCloudDaemon {
    val masterSecret = EnvelopeCredentialVault.resolveMasterPassphrase(env = env)
    // Main now ingests provider keys, so the vault's implicit development fallback is insufficient.
    require(masterSecret != EnvelopeCredentialVault.resolveMasterPassphrase(env = emptyMap())) {
        "请配置稳定的 AMBER_MASTER_KEY、AMBER_MASTER_KEY_FILE 或 systemd amber_master_key credential 后启动 daemon"
    }
    val vault = EnvelopeCredentialVault(File(dataDir, "secrets.enc.json"), masterSecretOverride = masterSecret)
    val ownerBinding = OwnerBindingManager(persistenceFile = File(dataDir, "owner-bindings.json"))
    val config = CloudConfigLoader.loadAndIngest(configFile, env, vault, logger, ownerBinding)
    val manager = CloudConfigurationManager(vault, CloudGatewayState(dataDir).identity.id, config)
    val proactiveDir = File(dataDir, "proactive").also { ProactiveFilePersistence.ensureOwnerOnlyDir(it) }
    val l2ModelClient = CloudProactiveL2Judge.resolveModelClient(
        config = config,
        vault = vault,
        fallback = manager.modelClient,
        env = env,
    )
    val proactive = ProactiveEngine(
        l1Filter = L1DeterministicFilter(persistenceFile = File(proactiveDir, "l1-filter.json")),
        l2Judge = CloudProactiveL2Judge(l2ModelClient),
        restraintGate = ProactiveRestraintGate(
            quietHours = config.toQuietHoursConfig(),
            budgetConfig = config.toInterruptionBudgetConfig(),
            persistenceFile = File(proactiveDir, "restraint-gate.json"),
        ),
    )
    val kernel = CloudAgentKernel(
        dataDir = dataDir, modelClient = manager.modelClient, masterSecretOverride = masterSecret,
        configurationManager = manager, vaultOverride = vault,
        ownerBinding = ownerBinding, proactiveEngine = proactive,
        searchSources = config.searchSources.split(',').map { it.trim() }.filter { it.isNotEmpty() }, searchMode = config.searchMode,
        workerApprovals = config.workerApprovals,
    )
    val apnsSender = CloudConfigLoader.createApnsPushSenderOrNull(
        config = config,
        vault = vault,
        logger = logger,
        deviceLookup = kernel.gatewayState::findDeviceById,
        onInvalidToken = { deviceId, pushToken, reason ->
            kernel.gatewayState.clearPushToken(deviceId = deviceId, expectedToken = pushToken, reason = reason)
        },
    )
    if (apnsSender != null) {
        kernel.gatewayState.pushSender = apnsSender
    }
    return ConfiguredCloudDaemon(config, kernel)
}
