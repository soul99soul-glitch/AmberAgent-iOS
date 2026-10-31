package app.amber.core.native

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class AmberNativeBridgeJvmTest {

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun String.hexToBytes(): ByteArray {
        require(length % 2 == 0) { "Hex string must have even length" }
        return ByteArray(length / 2) { i ->
            substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    @Test
    fun sha256_matches_rfc6234_test_vectors() {
        // Empty input
        val emptyDigest = AmberNativeBridge.sha256(ByteArray(0))
        assertNotNull(emptyDigest)
        assertEquals(32, emptyDigest.size)
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            emptyDigest.toHex(),
        )

        // "abc" (RFC 6234 §8.5)
        val abcDigest = AmberNativeBridge.sha256("abc".encodeToByteArray())
        assertNotNull(abcDigest)
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            abcDigest.toHex(),
        )
    }

    @Test
    fun hmacSha256_matches_rfc4231_test_vectors() {
        // RFC 4231 Test Case 1
        val key1 = ByteArray(20) { 0x0b }
        val msg1 = "Hi There".encodeToByteArray()
        val mac1 = AmberNativeBridge.hmacSha256(key1, msg1)
        assertNotNull(mac1)
        assertEquals(32, mac1.size)
        assertEquals(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            mac1.toHex(),
        )

        // RFC 4231 Test Case 2 ("Jefe")
        val key2 = "Jefe".encodeToByteArray()
        val msg2 = "what do ya want for nothing?".encodeToByteArray()
        val mac2 = AmberNativeBridge.hmacSha256(key2, msg2)
        assertNotNull(mac2)
        assertEquals(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            mac2.toHex(),
        )

        // Empty key and empty message should not throw
        val emptyKeyMac = AmberNativeBridge.hmacSha256(ByteArray(0), ByteArray(0))
        assertNotNull(emptyKeyMac)
        assertEquals(32, emptyKeyMac.size)
    }

    @Test
    fun pbkdf2HmacSha256_matches_rust_sync_crypto_golden_vectors() {
        // Golden vector 1: ASCII passphrase ("password", "salt", 4096, 32)
        val asciiKey = AmberNativeBridge.pbkdf2HmacSha256(
            passphrase = "password",
            salt = "salt".encodeToByteArray(),
            iterations = 4096,
            keySizeBytes = 32,
        )
        assertNotNull(asciiKey)
        assertEquals(
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
            asciiKey.toHex(),
        )

        // Golden vector 2: UTF-8 CJK + ASCII passphrase ("口令-passphrase", "salt", 4096, 32)
        val utf8Key = AmberNativeBridge.pbkdf2HmacSha256(
            passphrase = "口令-passphrase",
            salt = "salt".encodeToByteArray(),
            iterations = 4096,
            keySizeBytes = 32,
        )
        assertNotNull(utf8Key)
        assertEquals(
            "4ef032d17c60721419081307ee1e75dd9d99853983f451b3fd33f93d495ad158",
            utf8Key.toHex(),
        )

        // Empty salt fallback parity check
        val emptySaltKey = AmberNativeBridge.pbkdf2HmacSha256(
            passphrase = "password",
            salt = ByteArray(0),
            iterations = 1000,
            keySizeBytes = 32,
        )
        assertNotNull(emptySaltKey)
        assertEquals(32, emptySaltKey.size)

        // Invalid parameters return null
        assertNull(AmberNativeBridge.pbkdf2HmacSha256("password", "salt".encodeToByteArray(), 0, 32))
        assertNull(AmberNativeBridge.pbkdf2HmacSha256("password", "salt".encodeToByteArray(), -1, 32))
        assertNull(AmberNativeBridge.pbkdf2HmacSha256("password", "salt".encodeToByteArray(), 1000, 0))
    }

    @Test
    fun aesGcm_encrypt_decrypt_roundtrip_and_nist_vector() {
        // NIST SP 800-38D Test Case 13 (256-bit key = all 0s, 96-bit IV = all 0s, empty plaintext)
        val zeroKey = ByteArray(32)
        val zeroIv = ByteArray(12)
        val emptyEncrypted = AmberNativeBridge.aesGcmEncrypt(ByteArray(0), zeroKey, zeroIv)
        assertNotNull(emptyEncrypted)
        assertEquals(16, emptyEncrypted.size)
        assertEquals("530f8afbc74536b9a963b4f1c4cb738b", emptyEncrypted.toHex())
        val emptyDecrypted = AmberNativeBridge.aesGcmDecrypt(emptyEncrypted, zeroKey, zeroIv)
        assertNotNull(emptyDecrypted)
        assertEquals(0, emptyDecrypted.size)

        // NIST SP 800-38D Test Case 14 (256-bit key = all 0s, 96-bit IV = all 0s, 16-byte zero plaintext)
        val zeroPt16 = ByteArray(16)
        val ct16 = AmberNativeBridge.aesGcmEncrypt(zeroPt16, zeroKey, zeroIv)
        assertNotNull(ct16)
        assertEquals(
            "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919",
            ct16.toHex(),
        )
        assertContentEquals(zeroPt16, AmberNativeBridge.aesGcmDecrypt(ct16, zeroKey, zeroIv))

        // Arbitrary payload roundtrip
        val key = ByteArray(32) { 42 }
        val iv = ByteArray(12) { 7 }
        val plaintext = "the quick brown fox jumps over the lazy dog".encodeToByteArray()
        val ciphertext = AmberNativeBridge.aesGcmEncrypt(plaintext, key, iv)
        assertNotNull(ciphertext)
        assertEquals(plaintext.size + 16, ciphertext.size)

        val decrypted = AmberNativeBridge.aesGcmDecrypt(ciphertext, key, iv)
        assertNotNull(decrypted)
        assertContentEquals(plaintext, decrypted)
    }

    @Test
    fun aesGcm_rejects_wrong_key_tampered_tag_and_invalid_sizes() {
        val key = ByteArray(32) { 42 }
        val wrongKey = ByteArray(32) { 99 }
        val iv = ByteArray(12) { 7 }
        val wrongIv = ByteArray(12) { 8 }
        val ciphertext = AmberNativeBridge.aesGcmEncrypt("secret".encodeToByteArray(), key, iv)
        assertNotNull(ciphertext)

        // Wrong key or IV must return null
        assertNull(AmberNativeBridge.aesGcmDecrypt(ciphertext, wrongKey, iv))
        assertNull(AmberNativeBridge.aesGcmDecrypt(ciphertext, key, wrongIv))

        // Tampered auth tag must return null
        val tampered = ciphertext.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 0x01).toByte() }
        assertNull(AmberNativeBridge.aesGcmDecrypt(tampered, key, iv))
        assertFalse(tampered.contentEquals(ciphertext))

        // Invalid key/iv/ciphertext lengths must return null
        assertNull(AmberNativeBridge.aesGcmEncrypt("abc".encodeToByteArray(), ByteArray(16), iv))
        assertNull(AmberNativeBridge.aesGcmEncrypt("abc".encodeToByteArray(), key, ByteArray(16)))
        assertNull(AmberNativeBridge.aesGcmDecrypt(ByteArray(15), key, iv))
    }
}
