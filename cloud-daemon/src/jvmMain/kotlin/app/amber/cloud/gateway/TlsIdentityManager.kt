package app.amber.cloud.gateway

import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.core.native.AmberNativeBridge
import java.io.File
import java.math.BigInteger
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.util.Base64

/**
 * Manages the Gateway's self-signed EC P-256 TLS identity (`tls-identity.p12`)
 * and computes the exact SPKI SHA-256 Base64 fingerprint (`fp`) required by
 * iOS `MacGatewayPinningDelegate`, Android, and HarmonyOS clients (C3 §1.2).
 */
object TlsIdentityManager {

    const val PKCS12_PASSWORD = "amber-gateway"

    private val P256_SPKI_PREFIX = byteArrayOf(
        0x30.toByte(), 0x59.toByte(), 0x30.toByte(), 0x13.toByte(), 0x06.toByte(), 0x07.toByte(),
        0x2A.toByte(), 0x86.toByte(), 0x48.toByte(), 0xCE.toByte(), 0x3D.toByte(), 0x02.toByte(),
        0x01.toByte(), 0x06.toByte(), 0x08.toByte(), 0x2A.toByte(), 0x86.toByte(), 0x48.toByte(),
        0xCE.toByte(), 0x3D.toByte(), 0x03.toByte(), 0x01.toByte(), 0x07.toByte(), 0x03.toByte(),
        0x42.toByte(), 0x00.toByte(),
    )

    data class LoadedTlsIdentity(
        val keyStore: KeyStore,
        val certificate: X509Certificate,
        val spkiFingerprintBase64: String,
    )

    fun loadOrCreate(p12File: File, commonName: String = "amber-gateway"): LoadedTlsIdentity {
        if (!p12File.exists()) {
            generatePkcs12(p12File, commonName)
        }
        val ks = KeyStore.getInstance("PKCS12")
        p12File.inputStream().use { input ->
            ks.load(input, PKCS12_PASSWORD.toCharArray())
        }
        val alias = ks.aliases().toList().firstOrNull()
            ?: error("PKCS#12 证书库为空: ${p12File.absolutePath}")
        val cert = ks.getCertificate(alias) as? X509Certificate
            ?: error("找不到 X.509 证书: ${p12File.absolutePath}")
        val fp = spkiFingerprint(cert)
        return LoadedTlsIdentity(ks, cert, fp)
    }

    fun spkiFingerprint(cert: X509Certificate): String {
        val ecKey = cert.publicKey as? ECPublicKey
            ?: error("证书公钥不是 EC P-256")
        val encoded = ecKey.encoded
        val spkiDer = if (encoded != null && encoded.size == 91 && encoded.copyOfRange(0, 26).contentEquals(P256_SPKI_PREFIX)) {
            encoded
        } else {
            val xBytes = ecKey.w.affineX.toFixed32Bytes()
            val yBytes = ecKey.w.affineY.toFixed32Bytes()
            ByteArray(91).also { out ->
                P256_SPKI_PREFIX.copyInto(out, 0)
                out[26] = 0x04
                xBytes.copyInto(out, 27)
                yBytes.copyInto(out, 59)
            }
        }
        val digest = AmberNativeBridge.sha256(spkiDer)
            ?: error("SHA-256 计算失败")
        return Base64.getEncoder().encodeToString(digest)
    }

    private fun BigInteger.toFixed32Bytes(): ByteArray {
        val raw = toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32).also { raw.copyInto(it, 32 - raw.size) }
        }
    }

    private fun generatePkcs12(p12File: File, commonName: String) {
        p12File.parentFile?.mkdirs()
        val safeCn = commonName.replace(Regex("""[^A-Za-z0-9._\- ]"""), "-")
        val javaHome = System.getProperty("java.home")
        val keytoolBin = File(javaHome, "bin/keytool").takeIf { it.canExecute() }?.absolutePath ?: "keytool"
        val process = ProcessBuilder(
            keytoolBin,
            "-genkeypair",
            "-alias", "amber",
            "-keyalg", "EC",
            "-groupname", "secp256r1",
            "-sigalg", "SHA256withECDSA",
            "-validity", "3650",
            "-dname", "CN=$safeCn",
            "-keystore", p12File.absolutePath,
            "-storetype", "PKCS12",
            "-storepass", PKCS12_PASSWORD,
            "-keypass", PKCS12_PASSWORD,
        ).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        val exitCode = process.waitFor()
        if (exitCode != 0 || !p12File.exists()) {
            error("生成 EC P-256 TLS 证书失败 (exit=$exitCode): $output")
        }
        EnvelopeCredentialVault.setOwnerOnlyPermissions(p12File)
    }
}
