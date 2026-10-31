package app.amber.core.native

import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.min

/**
 * JVM actual for [AmberNativeBridge].
 *
 * Implements the cryptographic primitives (SHA-256, HMAC-SHA256, AES-256-GCM,
 * PBKDF2-HMAC-SHA256) using the JDK standard library (`java.security` /
 * `javax.crypto`) with byte-identical semantics to `native/sync-crypto`.
 */
actual object AmberNativeBridge {

    private const val AES_KEY_SIZE_BYTES = 32
    private const val GCM_IV_SIZE_BYTES = 12
    private const val GCM_TAG_SIZE_BITS = 128
    private const val GCM_TAG_SIZE_BYTES = 16
    private const val SHA256_BLOCK_SIZE_BYTES = 64

    actual fun jsonExprEvaluate(rootJson: String, expr: String): String? = null

    actual fun jsonExprIsValid(expr: String): Boolean = false

    actual fun regexApply(
        input: String,
        findPatterns: Array<String>,
        replacements: Array<String>,
    ): String? = null

    actual fun pbkdf2HmacSha256(
        passphrase: String,
        salt: ByteArray,
        iterations: Int,
        keySizeBytes: Int,
    ): ByteArray? {
        if (iterations <= 0 || keySizeBytes <= 0) return null
        return runCatching {
            if (salt.isNotEmpty()) {
                val spec = PBEKeySpec(
                    passphrase.toCharArray(),
                    salt,
                    iterations,
                    keySizeBytes * 8,
                )
                try {
                    SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                        .generateSecret(spec)
                        .encoded
                } finally {
                    spec.clearPassword()
                }
            } else {
                pbkdf2HmacSha256Fallback(
                    passphraseBytes = passphrase.encodeToByteArray(),
                    salt = salt,
                    iterations = iterations,
                    keySizeBytes = keySizeBytes,
                )
            }
        }.getOrNull()
    }

    actual fun aesGcmEncrypt(plaintext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray? {
        if (key.size != AES_KEY_SIZE_BYTES || iv.size != GCM_IV_SIZE_BYTES) return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(GCM_TAG_SIZE_BITS, iv),
            )
            cipher.doFinal(plaintext)
        }.getOrNull()
    }

    actual fun aesGcmDecrypt(ciphertext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray? {
        if (
            key.size != AES_KEY_SIZE_BYTES ||
            iv.size != GCM_IV_SIZE_BYTES ||
            ciphertext.size < GCM_TAG_SIZE_BYTES
        ) {
            return null
        }
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(GCM_TAG_SIZE_BITS, iv),
            )
            cipher.doFinal(ciphertext)
        }.getOrNull()
    }

    actual fun sha256(data: ByteArray): ByteArray? = runCatching {
        MessageDigest.getInstance("SHA-256").digest(data)
    }.getOrNull()

    actual fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray? = runCatching {
        val mac = Mac.getInstance("HmacSHA256")
        val effectiveKey = if (key.isEmpty()) ByteArray(SHA256_BLOCK_SIZE_BYTES) else key
        mac.init(SecretKeySpec(effectiveKey, "HmacSHA256"))
        mac.doFinal(message)
    }.getOrNull()

    actual fun tokenizerCount(tokenizerId: String, text: String): Int = -1

    actual fun markdownToHtml(text: String): String? = null

    actual fun markdownPreprocess(input: String): String? = null

    actual fun highlightSupportedLanguages(): String? = null

    actual fun htmlDiffNormalize(html: String): String? = null

    actual fun readerExtract(html: String, baseUrl: String): String? = null

    actual fun parseDocx(path: String): String? = null

    actual fun parsePptx(path: String): String? = null

    actual fun parseEpub(path: String): String? = null

    actual fun parseXlsx(path: String): String? = null

    /**
     * RFC 2898 PBKDF2-HMAC-SHA256 fallback used when [salt] is empty (since
     * `javax.crypto.spec.PBEKeySpec` rejects zero-length salt arrays).
     */
    private fun pbkdf2HmacSha256Fallback(
        passphraseBytes: ByteArray,
        salt: ByteArray,
        iterations: Int,
        keySizeBytes: Int,
    ): ByteArray? {
        val hLen = 32
        val blocks = (keySizeBytes + hLen - 1) / hLen
        val out = ByteArray(keySizeBytes)
        var offset = 0
        for (blockIndex in 1..blocks) {
            val blockSalt = ByteBuffer.allocate(salt.size + 4)
                .put(salt)
                .putInt(blockIndex)
                .array()
            var u = hmacSha256(passphraseBytes, blockSalt) ?: return null
            val t = u.copyOf()
            for (iter in 2..iterations) {
                u = hmacSha256(passphraseBytes, u) ?: return null
                for (i in t.indices) {
                    t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
                }
            }
            val copyLen = min(hLen, keySizeBytes - offset)
            t.copyInto(out, destinationOffset = offset, startIndex = 0, endIndex = copyLen)
            offset += copyLen
        }
        return out
    }
}
