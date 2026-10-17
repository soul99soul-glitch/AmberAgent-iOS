package app.amber.core.storage.conversation

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import platform.Foundation.NSTemporaryDirectory

class ConversationFileIosTest {

    @Test
    fun deleteNonExistentFileReturnsFalsePerContract() {
        val ghost = ConversationFile(tempPath("missing"))

        assertFalse(ghost.exists())
        assertFalse(ghost.delete())
    }

    @Test
    fun deleteExistingFileReturnsTrueAndRemovesIt() {
        val file = ConversationFile(tempPath("deletable"))

        file.writeText("payload")

        assertTrue(file.exists())
        assertTrue(file.delete())
        assertFalse(file.exists())
    }

    @Test
    fun writeTextToDirectoryThrows() {
        val directory = ConversationFile(tempPath("write-target-dir"))

        assertTrue(directory.mkdirs())

        assertFailsWith<IllegalStateException> {
            directory.writeText("payload")
        }
        assertTrue(directory.delete())
    }

    @Test
    fun fileVersionChangesAfterAtomicReplacement() {
        val file = ConversationFile(tempPath("versioned"))

        file.writeText("first")
        val before = assertNotNull(file.fileVersion())
        file.writeText("other")
        val after = assertNotNull(file.fileVersion())

        assertTrue(before != after, "原子替换后文件指纹必须变化")
        assertTrue(file.delete())
    }

    @Test
    fun durableBytesRoundTripAndDirectoryHelpers() {
        val directory = ConversationFile(tempPath("blobs"))
        assertTrue(directory.mkdirs())
        val bytes = Random(42).nextBytes(70_000)
        val file = directory.child("a.png")

        file.writeBytesDurably(bytes)
        assertContentEquals(bytes, file.readBytesOrNull())
        file.writeBytesDurably(byteArrayOf(1, 2, 3))
        assertContentEquals(byteArrayOf(1, 2, 3), file.readBytesOrNull())
        // No temp files are left behind after a successful write.
        assertEquals(listOf("a.png"), directory.listChildNames())
        assertNull(directory.child("missing.png").readBytesOrNull())

        assertTrue(directory.deleteRecursively())
        assertFalse(directory.exists())
        assertFalse(directory.deleteRecursively())
    }

    @Test
    fun sha256MatchesKnownVectors() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            sha256Hex(ByteArray(0)),
        )
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            sha256Hex("abc".encodeToByteArray()),
        )
    }

    private fun tempPath(prefix: String): String {
        val base = NSTemporaryDirectory().trimEnd('/')
        return "$base/$prefix-${Random.nextLong()}.json"
    }
}
