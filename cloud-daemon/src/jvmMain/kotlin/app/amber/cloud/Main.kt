package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.config.CloudConfigLoader
import app.amber.cloud.gateway.TlsIdentityManager
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.proactive.L2NoteworthyScore
import app.amber.cloud.proactive.NoteworthyJudgeProvider
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.security.EnvelopeCredentialVault
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * Entry point for `amberd` (Amber Cloud Self Daemon).
 */
fun main(args: Array<String>) {
    if (args.firstOrNull() == "pair") {
        app.amber.cloud.runCli(args)
        return
    }
    if (args.firstOrNull() == "cli") {
        app.amber.cloud.runCli(args.drop(1).toTypedArray())
        return
    }

    val port = parseOption(args, "--port")?.toIntOrNull()
        ?: System.getenv("AMBER_PORT")?.toIntOrNull()
        ?: 47821
    val host = parseOption(args, "--host")
        ?: System.getenv("AMBER_HOST")
        ?: "0.0.0.0"
    val dataDirPath = parseOption(args, "--data-dir")
        ?: System.getenv("AMBER_DATA_DIR")
        ?: "/var/lib/amberd"
    val dataDir = File(dataDirPath).also { it.mkdirs() }
    val configFilePath = parseOption(args, "--config")
        ?: System.getenv("AMBER_CONFIG_FILE")
    val configFile = configFilePath?.let(::File) ?: File(dataDir, "amberd.json")

    // Ensure TLS identity exists so `amber-cli pair` can read SPKI fingerprint immediately
    TlsIdentityManager.loadOrCreate(File(dataDir, "tls-identity.p12"))

    val logger = RedactingChannelLogger { println(it) }
    val vault = EnvelopeCredentialVault(vaultFile = File(dataDir, "secrets.enc.json"))
    val ownerBinding = OwnerBindingManager(persistenceFile = File(dataDir, "owner-bindings.json"))
    val daemonConfig = CloudConfigLoader.loadAndIngest(
        configFile = configFile,
        vault = vault,
        logger = logger,
        ownerBinding = ownerBinding,
    )

    val defaultEchoModelClient = CloudModelClient { messages, _ ->
        val lastUser = messages.lastOrNull()?.toText().orEmpty()
        UIMessage.assistant("Amber Cloud Self 已收到: ${lastUser.lines().firstOrNull().orEmpty()}")
    }

    val proactiveEngine = ProactiveEngine(
        l2Judge = NoteworthyJudgeProvider { req ->
            L2NoteworthyScore(
                noteworthy = true,
                urgency = 4,
                importance = 4,
                summary = req.deltaSummary.lines().firstOrNull()?.take(80) ?: req.topicKey,
            )
        },
        restraintGate = ProactiveRestraintGate(
            quietHours = daemonConfig.toQuietHoursConfig(),
            budgetConfig = daemonConfig.toInterruptionBudgetConfig(),
        ),
    )

    val kernel = CloudAgentKernel(
        dataDir = dataDir,
        modelClient = defaultEchoModelClient,
        ownerBinding = ownerBinding,
        proactiveEngine = proactiveEngine,
    )

    val telegramChannel = CloudConfigLoader.createTelegramChannelOrNull(
        config = daemonConfig,
        vault = kernel.vault,
        ownerBinding = kernel.ownerBinding,
        logger = logger,
    )
    val feishuChannel = CloudConfigLoader.createFeishuChannelOrNull(
        config = daemonConfig,
        vault = kernel.vault,
        ownerBinding = kernel.ownerBinding,
        logger = logger,
    )

    runBlocking {
        kernel.recoverColdStartConversations()
        telegramChannel?.let {
            kernel.registerConnector(it)
            it.start()
        }
        feishuChannel?.let {
            kernel.registerConnector(it)
            it.start()
        }
        kernel.startProactiveLoop()
    }

    Runtime.getRuntime().addShutdownHook(
        Thread {
            runBlocking {
                kernel.stopProactiveLoop()
                telegramChannel?.stop()
                feishuChannel?.stop()
            }
        }
    )

    logger.info("amberd starting on $host:$port (dataDir=${dataDir.absolutePath}, gatewayId=${kernel.gatewayState.identity.id})")
    embeddedServer(CIO, port = port, host = host) {
        configureCloudGateway(kernel.gatewayState, feishuChannel)
    }.start(wait = true)
}

internal fun parseOption(args: Array<String>, flag: String): String? {
    val idx = args.indexOf(flag)
    if (idx >= 0 && idx + 1 < args.size) {
        return args[idx + 1]
    }
    return args.firstOrNull { it.startsWith("$flag=") }?.substringAfter("=")
}
