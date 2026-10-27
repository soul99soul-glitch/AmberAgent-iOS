package app.amber.core.storage.conversation

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.MessageNode
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import kotlin.io.encoding.Base64
import kotlin.random.Random
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class ConversationBlobStorageTest {

    private lateinit var root: File
    private lateinit var dir: ConversationFile
    private lateinit var storage: JsonConversationStorage

    @BeforeTest
    fun setup() {
        root = kotlin.io.path.createTempDirectory(prefix = "conv-blob-test").toFile()
        dir = ConversationFile(root.absolutePath)
        storage = JsonConversationStorage(dir)
    }

    @AfterTest
    fun teardown() {
        root.deleteRecursively()
    }

    // ---- D: cache reuse after write ----

    @Test
    fun consecutiveSavesReuseJustWrittenSnapshotWithoutDecoding() = runTest {
        val id = Uuid.random()
        var conversation = conversation(id, listOf(screenshotTool("t0", pngDataUrl(1))))
        storage.saveConversation(conversation)

        var decodes = 0
        storage.beforeConversationDecodeForTesting = { decodes += 1 }
        repeat(4) { step ->
            conversation = conversation.appendTool(screenshotTool("t${step + 1}", pngDataUrl(step + 2)))
            storage.saveConversation(conversation)
        }
        storage.updateMetadata(id, title = "renamed")
        val loaded = storage.loadConversation(id)

        assertEquals(0, decodes, "saves, metadata updates and loads after own writes must hit the cache")
        assertNotNull(loaded)
        assertEquals("renamed", loaded.title)
        assertEquals(conversation.messageNodes.size, loaded.messageNodes.size)
        assertEquals(allImageUrls(conversation), allImageUrls(loaded))
    }

    @Test
    fun externalChangeAfterOwnWriteInvalidatesCache() = runTest {
        val id = Uuid.random()
        val conversation = conversation(id, listOf(UIMessagePart.Text("hi")), title = "mine")
        storage.saveConversation(conversation)

        var decodes = 0
        storage.beforeConversationDecodeForTesting = { decodes += 1 }
        // Another writer (same byte length on purpose) replaces the file.
        File(root, "$id.json").writeText(JsonInstant.encodeToString(conversation.copy(title = "them")))

        val loaded = storage.loadConversation(id)
        assertEquals(1, decodes, "a file changed by someone else must be re-read")
        assertEquals("them", loaded?.title)

        // The save merge must also see the external title, not the stale cached one.
        val merged = storage.saveConversation(conversation.copy(title = "mine"))
        assertEquals("them", merged.title)
    }

    // ---- E: blob externalization ----

    @Test
    fun largeDataUrlsAreStoredAsBlobsAndLoadBackIdentically() = runTest {
        val id = Uuid.random()
        val png = pngDataUrl(7)
        val jpeg = jpegDataUrl(8)
        val conversation = conversation(
            id,
            listOf(
                UIMessagePart.Image(url = png),
                screenshotTool("tool-1", jpeg),
                UIMessagePart.Text("after"),
            ),
        )
        storage.saveConversation(conversation)

        val json = File(root, "$id.json").readText()
        assertFalse(json.contains(png.substringAfter("base64,")), "base64 payload must not stay in the JSON")
        assertFalse(json.contains(jpeg.substringAfter("base64,")))
        assertEquals(2, Regex(Regex.escape(BLOB_URL_SCHEME)).findAll(json).count())
        assertTrue(json.length < 8 * 1024, "JSON should be small, was ${json.length}")

        val blobs = File(root, "$id.blobs").listFiles().orEmpty().map { it.name }.sorted()
        assertEquals(2, blobs.size)
        assertTrue(blobs.all(::isValidBlobName))
        val pngBlob = File(root, "$id.blobs").listFiles()!!.single { it.name.endsWith(".png") }
        assertContentEquals(Base64.decode(png.substringAfter("base64,")), pngBlob.readBytes())

        val reloaded = JsonConversationStorage(dir).loadConversation(id)
        assertNotNull(reloaded)
        assertEquals(listOf(png, jpeg), allImageUrls(reloaded))
        assertEquals(conversation.messageNodes, reloaded.messageNodes)
    }

    @Test
    fun identicalImagesShareOneBlobAcrossPartsAndSaves() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(3)
        var conversation = conversation(id, listOf(screenshotTool("a", shot), screenshotTool("b", shot)))
        storage.saveConversation(conversation)
        conversation = conversation.appendTool(screenshotTool("c", shot))
        storage.saveConversation(conversation)

        assertEquals(1, File(root, "$id.blobs").listFiles()!!.size)
        val reloaded = JsonConversationStorage(dir).loadConversation(id)!!
        assertEquals(listOf(shot, shot, shot), allImageUrls(reloaded))
    }

    @Test
    fun oldInlineConversationLoadsUnchangedAndMigratesOnNextSave() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(4)
        val legacy = conversation(id, listOf(screenshotTool("legacy", shot)))
        val file = File(root, "$id.json")
        file.writeText(JsonInstant.encodeToString(legacy))
        val legacySize = file.length()

        val loaded = storage.loadConversation(id)!!
        assertEquals(listOf(shot), allImageUrls(loaded))
        assertEquals(legacySize, file.length(), "loading must not rewrite the file")
        assertFalse(File(root, "$id.blobs").exists())

        storage.saveConversation(loaded)
        assertTrue(file.length() < legacySize / 4, "migrated file should be much smaller")
        assertTrue(file.readText().contains(BLOB_URL_SCHEME))
        assertEquals(listOf(shot), allImageUrls(JsonConversationStorage(dir).loadConversation(id)!!))
    }

    @Test
    fun missingBlobLoadsPlaceholderAndKeepsReferenceOnResave() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(5)
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", shot))))
        val blob = File(root, "$id.blobs").listFiles()!!.single()
        val ref = BLOB_URL_SCHEME + blob.name
        val bytes = blob.readBytes()
        assertTrue(blob.delete())

        val fresh = JsonConversationStorage(dir)
        val loaded = fresh.loadConversation(id)!!
        val image = allImages(loaded).single()
        assertEquals(MISSING_BLOB_PLACEHOLDER_URL, image.url)
        assertEquals(JsonPrimitive(ref), image.metadata?.get(MISSING_BLOB_METADATA_KEY))

        // Saving the untouched placeholder must write the original reference back.
        fresh.saveConversation(loaded)
        val json = File(root, "$id.json").readText()
        assertTrue(json.contains(ref))
        assertFalse(json.contains(MISSING_BLOB_METADATA_KEY))
        assertFalse(json.contains(MISSING_BLOB_PLACEHOLDER_URL.substringAfter("base64,")))

        // If the blob comes back (e.g. restore), the original image is fully recovered.
        File(root, "$id.blobs").mkdirs()
        File(root, "$id.blobs/${blob.name}").writeBytes(bytes)
        val recovered = JsonConversationStorage(dir).loadConversation(id)!!
        assertEquals(listOf(shot), allImageUrls(recovered))
        assertNull(allImages(recovered).single().metadata)
    }

    @Test
    fun corruptBlobKeepsReferenceAndRecoversWhenRestored() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(25)
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", shot))))
        val file = File(root, "$id.json")
        val blob = File(root, "$id.blobs").listFiles()!!.single()
        val ref = BLOB_URL_SCHEME + blob.name
        val original = blob.readBytes()
        val corruptions = listOf(
            original.copyOf().apply { this[lastIndex] = (last().toInt() xor 1).toByte() },
            byteArrayOf(),
        )
        for (corrupt in corruptions) {
            blob.writeBytes(corrupt)

            assertFailsWith<ConversationStorageException> {
                inlineConversationBlobsForExport(file.absolutePath, file.readText())
            }

            val fresh = JsonConversationStorage(dir)
            val loaded = fresh.loadConversation(id)!!
            val image = allImages(loaded).single()
            assertTrue(image.isMissingBlobPlaceholder())
            assertEquals(JsonPrimitive(ref), image.metadata?.get(MISSING_BLOB_METADATA_KEY))

            fresh.saveConversation(loaded)
            assertTrue(file.readText().contains(ref))
            assertContentEquals(corrupt, blob.readBytes(), "saving a placeholder must preserve the unresolved blob")

            blob.writeBytes(original)
            assertEquals(listOf(shot), allImageUrls(fresh.loadConversation(id)!!))
        }
    }

    @Test
    fun replacedPlaceholderDropsMarker() = runTest {
        val id = Uuid.random()
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", pngDataUrl(6)))))
        File(root, "$id.blobs").deleteRecursively()
        val fresh = JsonConversationStorage(dir)
        val loaded = fresh.loadConversation(id)!!
        val replacement = pngDataUrl(60)
        fresh.saveConversation(loaded.mapImages { it.copy(url = replacement) })

        val reloaded = JsonConversationStorage(dir).loadConversation(id)!!
        assertEquals(listOf(replacement), allImageUrls(reloaded))
        assertNull(allImages(reloaded).single().metadata)
    }

    @Test
    fun deleteRemovesBlobDirectory() = runTest {
        val id = Uuid.random()
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", pngDataUrl(9)))))
        assertTrue(File(root, "$id.blobs").isDirectory)

        storage.deleteConversation(id)
        assertFalse(File(root, "$id.json").exists())
        assertFalse(File(root, "$id.blobs").exists())
    }

    @Test
    fun saveDropsOnlyBlobsNoLongerReferenced() = runTest {
        val id = Uuid.random()
        val kept = pngDataUrl(10)
        val dropped = pngDataUrl(11)
        val base = conversation(id, listOf(screenshotTool("kept", kept)))
        storage.saveConversation(base.appendTool(screenshotTool("dropped", dropped)))
        assertEquals(2, File(root, "$id.blobs").listFiles()!!.size)

        // e.g. branch truncation removes the second screenshot.
        storage.saveConversation(base)
        val remaining = File(root, "$id.blobs").listFiles()!!.map { it.name }
        assertEquals(1, remaining.size)
        assertTrue(File(root, "$id.json").readText().contains(remaining.single()))
        assertEquals(listOf(kept), allImageUrls(JsonConversationStorage(dir).loadConversation(id)!!))

        storage.saveConversation(conversation(id, listOf(UIMessagePart.Text("no images"))))
        assertFalse(File(root, "$id.blobs").exists(), "empty blob directory is removed")
    }

    @Test
    fun smallUnknownOrNonCanonicalDataUrlsStayInline() = runTest {
        val id = Uuid.random()
        val small = "data:image/png;base64," + Base64.encode(Random(1).nextBytes(64))
        val svg = "data:image/svg+xml;base64," + Base64.encode(Random(2).nextBytes(20_000))
        val withParams = "data:image/png;name=a.png;base64," + Base64.encode(Random(3).nextBytes(20_000))
        val wrapped = "data:image/png;base64," + Base64.Mime.encode(Random(4).nextBytes(20_000))
        val remote = "https://example.com/" + "x".repeat(20_000)
        val urls = listOf(small, svg, withParams, wrapped, remote)
        storage.saveConversation(conversation(id, urls.map { UIMessagePart.Image(url = it) }))

        assertFalse(File(root, "$id.json").readText().contains(BLOB_URL_SCHEME))
        assertFalse(File(root, "$id.blobs").exists())
        assertEquals(urls, allImageUrls(JsonConversationStorage(dir).loadConversation(id)!!))
    }

    @Test
    fun importExternalizesInlineImagesAndExportInlinesThemBack() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(12)
        val document = JsonInstant.encodeToString(conversation(id, listOf(screenshotTool("t", shot))))
        storage.importConversations(listOf(document))

        val file = File(root, "$id.json")
        val stored = file.readText()
        assertTrue(stored.contains(BLOB_URL_SCHEME))
        assertEquals(listOf(shot), allImageUrls(JsonConversationStorage(dir).loadConversation(id)!!))

        // Backup export path: self-contained JSON identical to the pre-blob encoding.
        val exported = inlineConversationBlobsForExport(file.absolutePath, stored)
        assertEquals(document, exported)
        assertEquals("plain", inlineConversationBlobsForExport(file.absolutePath, "plain"))
    }

    @Test
    fun saveRewritesMemoizedBlobThatVanished() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(13)
        val conversation = conversation(id, listOf(screenshotTool("t", shot)))
        storage.saveConversation(conversation)
        File(root, "$id.blobs").deleteRecursively()

        storage.saveConversation(conversation.copy(title = "again"))
        assertEquals(1, File(root, "$id.blobs").listFiles()!!.size, "a referenced blob must exist after save")
        assertEquals(listOf(shot), allImageUrls(JsonConversationStorage(dir).loadConversation(id)!!))
    }

    @Test
    fun saveRepairsSameSizeCorruptMemoizedBlobFromInMemoryDataUrl() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(26)
        val conversation = conversation(id, listOf(screenshotTool("t", shot)))
        storage.saveConversation(conversation)
        val loaded = storage.loadConversation(id)!!
        val blob = File(root, "$id.blobs").listFiles()!!.single()
        val original = blob.readBytes()
        val corrupt = original.copyOf().apply {
            this[0] = (this[0].toInt() xor 1).toByte()
        }
        assertEquals(original.size, corrupt.size)
        blob.writeBytes(corrupt)

        storage.saveConversation(loaded.copy(title = "repair"))

        assertContentEquals(original, blob.readBytes(), "a same-size corrupt blob must be rewritten")
        assertEquals(listOf(shot), allImageUrls(storage.loadConversation(id)!!))
    }

    @Test
    fun saveRepairsSameSizeCorruptHashNamedBlobWithoutMemo() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(27)
        val bytes = Base64.decode(shot.substringAfter("base64,"))
        val blobDirectory = File(root, "$id.blobs").apply { mkdirs() }
        val blob = File(blobDirectory, blobNameOf(shot))
        blob.writeBytes(bytes.copyOf().apply { this[0] = (this[0].toInt() xor 1).toByte() })

        storage.saveConversation(conversation(id, listOf(screenshotTool("t", shot))))

        assertContentEquals(bytes, blob.readBytes(), "an existing hash-named blob must be hash-checked")
        assertEquals(listOf(shot), allImageUrls(storage.loadConversation(id)!!))
    }

    // ---- review fixes ----

    @Test
    fun unreadableBlobIsNeverDeletedAndReferenceSurvivesMetadataLoss() = runTest {
        val id = Uuid.random()
        val shot = pngDataUrl(20)
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", shot))))
        val blob = File(root, "$id.blobs").listFiles()!!.single()
        val ref = BLOB_URL_SCHEME + blob.name
        val bytes = blob.readBytes()
        // Simulate a transient read failure: the path exists but cannot be read as a file.
        assertTrue(blob.delete())
        assertTrue(blob.mkdir())

        val fresh = JsonConversationStorage(dir)
        val loaded = fresh.loadConversation(id)!!
        val placeholder = allImages(loaded).single()
        assertTrue(placeholder.isMissingBlobPlaceholder(), "nested tool output placeholder must be detectable")
        assertEquals(JsonPrimitive(ref), placeholder.metadata?.get(MISSING_BLOB_METADATA_KEY))

        // An upper layer rebuilds the part without metadata (marker lost).
        fresh.saveConversation(loaded.mapImages { UIMessagePart.Image(url = it.url, metadata = null) })
        assertTrue(File(root, "$id.json").readText().contains(ref), "reference recovered by position")

        // Even when the conversation stops referencing it, a blob that failed to resolve stays.
        fresh.saveConversation(conversation(id, listOf(UIMessagePart.Text("dropped"))))
        assertTrue(File(root, "$id.blobs/${blob.name}").exists())

        // The read failure was transient: once readable, a reload is exact (not cached as placeholder).
        fresh.saveConversation(loaded)
        File(root, "$id.blobs/${blob.name}").delete()
        File(root, "$id.blobs/${blob.name}").writeBytes(bytes)
        assertEquals(listOf(shot), allImageUrls(fresh.loadConversation(id)!!))
    }

    @Test
    fun unrecoverablePlaceholderSkipsPruning() = runTest {
        val id = Uuid.random()
        val kept = pngDataUrl(21)
        val lost = pngDataUrl(22)
        storage.saveConversation(conversation(id, listOf(screenshotTool("a", kept), screenshotTool("b", lost))))
        val lostName = File(root, "$id.json").readText().let { json ->
            File(root, "$id.blobs").listFiles()!!.map { it.name }.single { json.contains(it) && it != blobNameOf(kept) }
        }
        val lostBytes = File(root, "$id.blobs/$lostName").readBytes()
        File(root, "$id.blobs/$lostName").delete()

        val fresh = JsonConversationStorage(dir)
        val loaded = fresh.loadConversation(id)!!
        // Upper layer moves the placeholder into a brand-new message and drops metadata:
        // position recovery cannot apply, so the placeholder is saved inline.
        val moved = loaded.copy(
            messageNodes = loaded.messageNodes.take(1) + MessageNode.of(
                UIMessage(
                    role = MessageRole.ASSISTANT,
                    parts = listOf(UIMessagePart.Image(url = MISSING_BLOB_PLACEHOLDER_URL), screenshotTool("a", kept)),
                ),
            ),
        )
        fresh.saveConversation(moved)
        File(root, "$id.blobs/$lostName").writeBytes(lostBytes)
        fresh.saveConversation(moved.copy(title = "again"))
        assertTrue(File(root, "$id.blobs/$lostName").exists(), "no pruning while placeholders are present")
        assertEquals(2, File(root, "$id.blobs").listFiles()!!.size)
    }

    @Test
    fun orphanBlobDirectoriesAreSweptOnlyWhenOldAndUnowned() = runTest {
        val owned = Uuid.random()
        storage.saveConversation(conversation(owned, listOf(screenshotTool("t", pngDataUrl(23)))))
        val old = System.currentTimeMillis() - 2 * 60 * 60 * 1000L
        File(root, "$owned.blobs").setLastModified(old)

        val orphanOld = File(root, "${Uuid.random()}.blobs").apply { mkdirs(); File(this, "x.png").writeBytes(byteArrayOf(1)) }
        orphanOld.setLastModified(old)
        val orphanYoung = File(root, "${Uuid.random()}.blobs").apply { mkdirs(); File(this, "y.png").writeBytes(byteArrayOf(1)) }
        val stagedId = Uuid.random()
        val orphanStaged = File(root, "$stagedId.blobs").apply { mkdirs(); setLastModified(old) }
        File(root, "$stagedId.batch.backup").writeText("{}")

        JsonConversationStorage(dir).listSummaries()

        assertFalse(orphanOld.exists(), "old directory without a conversation is reclaimed")
        assertTrue(orphanYoung.exists(), "recent directory may belong to an in-flight write")
        assertTrue(orphanStaged.exists(), "import staging/backup files keep their blobs")
        assertTrue(File(root, "$owned.blobs").exists(), "owned directory is never swept")
    }

    @Test
    fun exportFailsLoudlyInsteadOfDroppingScreenshots() = runTest {
        val id = Uuid.random()
        storage.saveConversation(conversation(id, listOf(screenshotTool("t", pngDataUrl(24)))))
        val file = File(root, "$id.json")
        val stored = file.readText()
        val blob = File(root, "$id.blobs").listFiles()!!.single()
        blob.delete()
        blob.mkdir()

        assertFailsWith<ConversationStorageException> {
            inlineConversationBlobsForExport(file.absolutePath, stored)
        }
        assertFailsWith<ConversationStorageException> {
            inlineConversationBlobsForExport(file.absolutePath, "{\"broken\": \"$BLOB_URL_SCHEME\"")
        }
        // A genuinely absent blob exports as a placeholder that keeps its reference.
        blob.delete()
        val exported = inlineConversationBlobsForExport(file.absolutePath, stored)
        assertTrue(exported.contains(MISSING_BLOB_METADATA_KEY))
        assertTrue(exported.contains(MISSING_BLOB_PLACEHOLDER_URL))
    }

    private fun blobNameOf(dataUrl: String): String =
        java.security.MessageDigest.getInstance("SHA-256")
            .digest(Base64.decode(dataUrl.substringAfter("base64,")))
            .joinToString("") { "%02x".format(it) } + ".png"

    // ---- helpers ----

    private fun pngDataUrl(seed: Int) = "data:image/png;base64," + Base64.encode(Random(seed).nextBytes(30_000))
    private fun jpegDataUrl(seed: Int) = "data:image/jpeg;base64," + Base64.encode(Random(seed).nextBytes(25_000))

    private fun screenshotTool(callId: String, url: String) = UIMessagePart.Tool(
        toolCallId = callId,
        toolName = "phone_screenshot",
        input = "{}",
        output = listOf(UIMessagePart.Text("screen"), UIMessagePart.Image(url = url)),
    )

    private fun conversation(id: Uuid, assistantParts: List<UIMessagePart>, title: String = "t") = Conversation(
        id = id,
        assistantId = Uuid.random(),
        title = title,
        messageNodes = listOf(
            MessageNode.of(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("go")))),
            MessageNode.of(UIMessage(role = MessageRole.ASSISTANT, parts = assistantParts)),
        ),
    )

    private fun Conversation.appendTool(tool: UIMessagePart.Tool) = copy(
        messageNodes = messageNodes + MessageNode.of(UIMessage(role = MessageRole.ASSISTANT, parts = listOf(tool))),
    )

    private fun allImages(conversation: Conversation): List<UIMessagePart.Image> {
        fun walk(part: UIMessagePart): List<UIMessagePart.Image> = when (part) {
            is UIMessagePart.Image -> listOf(part)
            is UIMessagePart.Tool -> part.output.flatMap(::walk)
            else -> emptyList()
        }
        return conversation.messageNodes.flatMap { node -> node.messages.flatMap { it.parts.flatMap(::walk) } }
    }

    private fun allImageUrls(conversation: Conversation) = allImages(conversation).map { it.url }

    private fun Conversation.mapImages(transform: (UIMessagePart.Image) -> UIMessagePart.Image): Conversation {
        fun map(part: UIMessagePart): UIMessagePart = when (part) {
            is UIMessagePart.Image -> transform(part)
            is UIMessagePart.Tool -> part.copy(output = part.output.map(::map))
            else -> part
        }
        return copy(messageNodes = messageNodes.map { node ->
            node.copy(messages = node.messages.map { it.copy(parts = it.parts.map(::map)) })
        })
    }
}
