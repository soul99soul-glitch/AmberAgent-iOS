package app.amber.cloud

import app.amber.cloud.gateway.CandidateAddressResolver
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PairingPayload
import app.amber.cloud.gateway.TerminalQrGenerator
import app.amber.cloud.gateway.TlsIdentityManager
import java.io.File

/**
 * Entry point for `amber-cli` (Amber Cloud Self CLI management tool).
 *
 * Supports:
 * - `amber-cli pair [--data-dir <dir>] [--port <port>] [--addr <public-ip-or-domain>]`
 * - `amber-cli status [--data-dir <dir>]`
 * - `amber-cli devices [--data-dir <dir>]`
 */
fun main(args: Array<String>) = runCli(args)

internal fun runCli(args: Array<String>) {
    val command = args.firstOrNull { !it.startsWith("-") } ?: "pair"
    val dataDirPath = parseOption(args, "--data-dir")
        ?: System.getenv("AMBER_DATA_DIR")
        ?: "/var/lib/amberd"
    val port = parseOption(args, "--port")?.toIntOrNull()
        ?: System.getenv("AMBER_PORT")?.toIntOrNull()
        ?: 47821
    val publicAddr = parseOption(args, "--addr")
        ?: System.getenv("AMBER_PUBLIC_ADDR")
    val dataDir = File(dataDirPath).also { it.mkdirs() }

    val state = CloudGatewayState(dataDir)
    when (command) {
        "pair" -> {
            val tls = TlsIdentityManager.loadOrCreate(state.tlsIdentityFile, state.identity.name)
            val secret = state.issuePairingTicket()
            val addrs = CandidateAddressResolver.resolve(
                publicAddresses = listOfNotNull(publicAddr),
            )
            val payload = PairingPayload(
                v = 1,
                id = state.identity.id,
                name = state.identity.name,
                addrs = addrs,
                port = port,
                fp = tls.spkiFingerprintBase64,
                s = secret,
            )
            val qr = TerminalQrGenerator.renderAnsi(payload.deepLinkUrl)
            println(qr)
            println("配对深链 (5 分钟内单次有效):")
            println(payload.deepLinkUrl)
            println("SPKI 指纹 (fp): ${payload.fp}")
        }
        "status" -> {
            println("Gateway ID:   ${state.identity.id}")
            println("Gateway Name: ${state.identity.name}")
            println("Data Dir:     ${dataDir.absolutePath}")
            println("Devices:      ${state.loadDevicesStrict().size}")
            println("Sessions:     ${state.listSessions().size}")
        }
        "devices" -> {
            val devices = state.loadDevicesStrict()
            if (devices.isEmpty()) {
                println("尚无已配对设备。")
            } else {
                devices.forEach { d ->
                    println("${d.id}\t${d.platform}\t${d.name}\tpush=${d.pushToken != null}")
                }
            }
        }
        else -> {
            System.err.println("用法: amber-cli [pair|status|devices] [--data-dir <dir>] [--port <port>] [--addr <host>]")
        }
    }
}
