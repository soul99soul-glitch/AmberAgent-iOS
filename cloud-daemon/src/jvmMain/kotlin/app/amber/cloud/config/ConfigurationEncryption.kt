package app.amber.cloud.config

import app.amber.cloud.security.EnvelopeCredentialVault
import com.nimbusds.jose.*
import com.nimbusds.jose.crypto.RSADecrypter
import com.nimbusds.jose.jwk.KeyUse
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.Base64

/** Standard JWE only; import private material stays in the existing encrypted vault. */
internal class ConfigurationEncryption(private val vault: EnvelopeCredentialVault, private val gatewayId: String) {
    private val key: RSAKey by lazy {
        val stored = vault.getSecret(PRIVATE_KEY)
        if (stored != null) RSAKey.parse(stored) else {
            val generated = RSAKeyGenerator(3072).keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.RSA_OAEP_256).generate()
            val withId = RSAKey.Builder(generated).keyID(generated.computeThumbprint().toString()).build()
            vault.putSecret(PRIVATE_KEY, withId.toJSONString())
            withId
        }
    }

    fun publicKey(deviceId: String, now: Long): ConfigurationImportKey = ConfigurationImportKey(
        gatewayId = gatewayId, deviceId = deviceId, kid = key.keyID,
        publicJwk = Json.parseToJsonElement(key.toPublicJWK().toJSONString()).jsonObject,
        publicKeySpkiDerBase64 = Base64.getEncoder().encodeToString(key.toRSAPublicKey().encoded), serverTime = now,
    )

    fun decrypt(compact: String): ByteArray {
        val privateKey = try { key } catch (_: Exception) { throw ConfigurationApiException(503, "configuration_unavailable") }
        try {
            if (compact.length > 100_000) throw ConfigurationApiException(413, "request_too_large")
            val jwe = JWEObject.parse(compact)
            val header = jwe.header
            require(header.algorithm == JWEAlgorithm.RSA_OAEP_256 && header.encryptionMethod == EncryptionMethod.A256GCM)
            require(header.keyID == privateKey.keyID && header.type?.type == "amber-config+jwe")
            require(header.compressionAlgorithm == null && header.criticalParams.isNullOrEmpty())
            require(header.toJSONObject().keys.all { it in setOf("alg", "enc", "kid", "typ") })
            jwe.decrypt(RSADecrypter(privateKey.toRSAPrivateKey()))
            return jwe.payload.toBytes()
        } catch (e: ConfigurationApiException) { throw e }
        catch (_: Exception) { throw ConfigurationApiException(400, "invalid_envelope") }
    }

    companion object { private const val PRIVATE_KEY = "daemon.configuration.import-key.v1" }
}
