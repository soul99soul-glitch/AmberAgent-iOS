package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.TlsIdentityManager
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
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

    // Ensure TLS identity exists so `amber-cli pair` can read SPKI fingerprint immediately
    TlsIdentityManager.loadOrCreate(File(dataDir, "tls-identity.p12"))

    val defaultEchoModelClient = CloudModelClient { messages, _ ->
        val lastUser = messages.lastOrNull()?.toText().orEmpty()
        UIMessage.assistant("Amber Cloud Self 已收到: ${lastUser.lines().firstOrNull().orEmpty()}")
    }

    val kernel = CloudAgentKernel(
        dataDir = dataDir,
        modelClient = defaultEchoModelClient,
    )

    println("amberd starting on $host:$port (dataDir=${dataDir.absolutePath}, gatewayId=${kernel.gatewayState.identity.id})")
    embeddedServer(CIO, port = port, host = host) {
        configureCloudGateway(kernel.gatewayState)
    }.start(wait = true)
}

internal fun parseOption(args: Array<String>, flag: String): String? {
    val idx = args.indexOf(flag)
    if (idx >= 0 && idx + 1 < args.size) {
        return args[idx + 1]
    }
    return args.firstOrNull { it.startsWith("$flag=") }?.substringAfter("=")
}
