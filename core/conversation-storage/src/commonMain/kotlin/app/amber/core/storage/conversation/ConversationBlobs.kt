package app.amber.core.storage.conversation

import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.io.encoding.Base64
import kotlin.uuid.Uuid

/**
 * Large inline image data URLs (automation screenshots are ~1 MB of base64 each and made
 * conversation files 20+ MB) are stored outside the conversation JSON:
 *
 *   {baseDir}/{conversationId}.blobs/{sha256}.{ext}   # decoded bytes, content-addressed, write-once
 *
 * and the JSON stores `amber-blob://{sha256}.{ext}` in the image part's `url`.
 *
 * Scope is deliberately confined to the storage layer: [ConversationBlobCodec.resolve] turns
 * references back into the exact original `data:` URL on load, so every upper layer keeps
 * seeing inline data URLs. Only [UIMessagePart.Image] parts are externalized (top-level
 * message parts and tool outputs, recursively), and only when the URL is exactly
 * `data:<known image mime>;base64,<canonical base64>` above [INLINE_DATA_URL_THRESHOLD_CHARS];
 * anything else stays inline untouched, so the round trip is byte-identical by construction.
 *
 * A reference that cannot be resolved (blob absent, unreadable or corrupt) loads as
 * [MISSING_BLOB_PLACEHOLDER_URL] (a valid 1x1 PNG, safe to render or send to a provider) with
 * the original reference kept in the part metadata under [MISSING_BLOB_METADATA_KEY]. Saving an
 * untouched placeholder writes the original reference back (also when an upper layer rebuilt
 * the part without metadata, matched by message id + part position), and a blob that failed to
 * resolve in this process is never deleted, so a transient read failure cannot become data loss.
 */
internal const val BLOB_URL_SCHEME = "amber-blob://"
internal const val BLOB_DIRECTORY_SUFFIX = ".blobs"
internal const val INLINE_DATA_URL_THRESHOLD_CHARS = 16 * 1024

/**
 * Stable public contract: metadata key present on every placeholder image part produced by
 * storage for an unresolvable blob, at any nesting depth (message parts and tool outputs).
 * The value is the original `amber-blob://` reference string.
 */
const val MISSING_BLOB_METADATA_KEY = "amberMissingBlobRef"

/** Stable public contract: the url every missing-blob placeholder image part carries. */
const val MISSING_BLOB_PLACEHOLDER_URL =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

/** Bijective mime <-> extension map; the extension must reproduce the exact data URL header. */
private val EXTENSION_BY_MIME = mapOf(
    "image/png" to "png",
    "image/jpeg" to "jpeg",
    "image/gif" to "gif",
    "image/webp" to "webp",
    "image/heic" to "heic",
)
private val MIME_BY_EXTENSION = EXTENSION_BY_MIME.entries.associate { (mime, ext) -> ext to mime }
private val BLOB_NAME_PATTERN = Regex("^[0-9a-f]{64}\\.(png|jpeg|gif|webp|heic)$")
private const val BASE64_MARKER = ";base64,"

internal fun isValidBlobName(name: String): Boolean = BLOB_NAME_PATTERN.matches(name)

/**
 * data URL -> blob reference for one conversation, so consecutive saves do not re-decode and
 * re-hash every screenshot. Keyed by a sampled fingerprint and confirmed with full string
 * equality (identity short-circuits it), so a fingerprint collision can never map an image
 * to the wrong blob. Holds the same String instances as the cached conversation, so it adds
 * no meaningful memory.
 */
internal class BlobRefMemo {
    private val buckets = HashMap<Long, MutableList<Pair<String, String>>>()

    fun get(url: String): String? =
        buckets[fingerprint(url)]?.firstOrNull { it.first == url }?.second

    fun put(url: String, ref: String) {
        val bucket = buckets.getOrPut(fingerprint(url)) { ArrayList(1) }
        if (bucket.none { it.first == url }) bucket += url to ref
    }

    private fun fingerprint(value: String): Long {
        var hash = value.length.toLong()
        if (value.isEmpty()) return hash
        val step = maxOf(1, value.length / 64)
        var index = 0
        while (index < value.length) {
            hash = hash * 31 + value[index].code
            index += step
        }
        return hash * 31 + value[value.length - 1].code
    }
}

/**
 * True when this image part is a storage placeholder for a blob that could not be loaded.
 * Checks the url as well as the marker, so it still works after an upper layer dropped metadata.
 */
fun UIMessagePart.Image.isMissingBlobPlaceholder(): Boolean =
    url == MISSING_BLOB_PLACEHOLDER_URL || metadata?.containsKey(MISSING_BLOB_METADATA_KEY) == true

internal class ConversationBlobCodec(private val baseDir: ConversationFile) {

    class Prepared(
        /** What gets encoded to JSON: large data URLs replaced with blob references. */
        val forDisk: Conversation,
        /** Blob file names the JSON for [forDisk] references. */
        val referenced: Set<String>,
        val memo: BlobRefMemo,
        /** Some part is still a missing-blob placeholder: do not cache or prune. */
        val containsPlaceholder: Boolean,
    )

    class Resolved(
        val conversation: Conversation,
        val memo: BlobRefMemo,
        /** Blob names the decoded JSON referenced (resolved or not). */
        val diskRefs: Set<String>,
        /** At least one reference could not be resolved; the result must not be cached. */
        val hadFailures: Boolean,
    )

    /** conversation -> (message id + part path) -> original reference, for placeholders handed out. */
    private val placeholderRefs = HashMap<Uuid, HashMap<String, String>>()

    /** conversation -> blob names that failed to resolve in this process; never deleted by pruning. */
    private val unresolvedBlobs = HashMap<Uuid, HashSet<String>>()

    fun blobDirectory(id: Uuid): ConversationFile = baseDir.child("$id$BLOB_DIRECTORY_SUFFIX")

    /**
     * Writes every needed blob durably *before* returning, so the caller can only ever write
     * a JSON that references blobs already on disk. A blob that cannot be written keeps its
     * data URL inline instead of failing the save.
     */
    fun externalize(conversation: Conversation, previousMemo: BlobRefMemo?): Prepared {
        val directory = blobDirectory(conversation.id)
        val referenced = mutableSetOf<String>()
        val memo = BlobRefMemo()
        var containsPlaceholder = false
        val knownPlaceholders = placeholderRefs[conversation.id]

        fun keepReference(part: UIMessagePart.Image, ref: String, metadata: JsonObject?): UIMessagePart.Image {
            ref.removePrefix(BLOB_URL_SCHEME).takeIf(::isValidBlobName)?.let { referenced += it }
            return part.copy(url = ref, metadata = metadata)
        }

        fun externalizeImage(part: UIMessagePart.Image, position: String): UIMessagePart.Image {
            val url = part.url
            val missingRef = part.metadata?.get(MISSING_BLOB_METADATA_KEY)
                ?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
            if (missingRef != null) {
                val metadataWithoutMarker = part.metadata
                    ?.let { JsonObject(it - MISSING_BLOB_METADATA_KEY) }
                    ?.takeIf { it.isNotEmpty() }
                if (url == MISSING_BLOB_PLACEHOLDER_URL) {
                    // Untouched placeholder: keep the original reference on disk.
                    containsPlaceholder = true
                    return keepReference(part, missingRef, metadataWithoutMarker)
                }
                // An upper layer replaced the image; the marker no longer applies.
                return externalizeImage(part.copy(metadata = metadataWithoutMarker), position)
            }
            if (url == MISSING_BLOB_PLACEHOLDER_URL) {
                // Placeholder rebuilt without metadata: recover the reference by position.
                containsPlaceholder = true
                val ref = knownPlaceholders?.get(position) ?: return part
                return keepReference(part, ref, part.metadata)
            }
            if (url.startsWith(BLOB_URL_SCHEME)) {
                // Already a reference (e.g. imported from a backup made from raw files).
                url.removePrefix(BLOB_URL_SCHEME).takeIf(::isValidBlobName)?.let { referenced += it }
                return part
            }
            if (url.length < INLINE_DATA_URL_THRESHOLD_CHARS || !url.startsWith("data:")) return part

            val knownRef = previousMemo?.get(url) ?: memo.get(url)
            if (knownRef != null) {
                val name = knownRef.removePrefix(BLOB_URL_SCHEME)
                val file = directory.child(name)
                val present = (file.fileVersion()?.size ?: 0L) > 0L
                if (present || writeBlob(file, url) != null) {
                    memo.put(url, knownRef)
                    referenced += name
                    return part.copy(url = knownRef)
                }
                return part
            }

            val markerIndex = url.indexOf(BASE64_MARKER)
            if (markerIndex < 0) return part
            val ext = EXTENSION_BY_MIME[url.substring("data:".length, markerIndex)] ?: return part
            val payload = url.substring(markerIndex + BASE64_MARKER.length)
            val bytes = runCatching { Base64.decode(payload) }.getOrNull() ?: return part
            // Only canonical base64 is externalized, so resolve() reproduces the exact string.
            if (bytes.isEmpty() || Base64.encode(bytes) != payload) return part
            val name = "${sha256Hex(bytes)}.$ext"
            val file = directory.child(name)
            val ok = runCatching {
                if (file.fileVersion()?.size != bytes.size.toLong()) {
                    directory.mkdirs()
                    file.writeBytesDurably(bytes)
                }
            }.isSuccess
            if (!ok) return part
            val ref = BLOB_URL_SCHEME + name
            memo.put(url, ref)
            referenced += name
            return part.copy(url = ref)
        }

        fun externalizePart(part: UIMessagePart, position: String): UIMessagePart = when (part) {
            is UIMessagePart.Image -> externalizeImage(part, position)
            is UIMessagePart.Tool -> {
                val output = part.output.mapIndexedPreservingIdentity { index, child ->
                    externalizePart(child, "$position/o$index")
                }
                if (output === part.output) part else part.copy(output = output)
            }
            else -> part
        }

        val forDisk = conversation.mapParts(::externalizePart)
        return Prepared(forDisk, referenced, memo, containsPlaceholder)
    }

    /** Re-writes a blob from a data URL whose reference was memoized but whose file vanished. */
    private fun writeBlob(file: ConversationFile, url: String): Unit? {
        val markerIndex = url.indexOf(BASE64_MARKER)
        if (markerIndex < 0) return null
        val bytes = runCatching { Base64.decode(url.substring(markerIndex + BASE64_MARKER.length)) }.getOrNull()
            ?: return null
        if (bytes.isEmpty()) return null
        return runCatching {
            ConversationFile(file.path.substringBeforeLast(separatorChar())).mkdirs()
            file.writeBytesDurably(bytes)
        }.getOrNull()
    }

    /**
     * Turns blob references back into the exact data URLs the conversation was saved with.
     * With [failOnUnreadable], a blob that exists but cannot be read throws instead of becoming
     * a placeholder (used by export, so a backup never silently drops a readable screenshot).
     */
    fun resolve(conversation: Conversation, failOnUnreadable: Boolean = false): Resolved {
        val memo = BlobRefMemo()
        val directory = blobDirectory(conversation.id)
        val diskRefs = mutableSetOf<String>()
        val failures = HashMap<String, String>()

        fun resolveImage(part: UIMessagePart.Image, position: String): UIMessagePart.Image {
            val url = part.url
            if (!url.startsWith(BLOB_URL_SCHEME)) return part
            val name = url.removePrefix(BLOB_URL_SCHEME)
            val valid = isValidBlobName(name)
            if (valid) diskRefs += name
            val mime = if (valid) MIME_BY_EXTENSION[name.substringAfterLast('.')] else null
            val file = directory.child(name)
            val bytes = mime?.let { file.readBytesOrNull() }
            if (mime != null && bytes != null && bytes.isNotEmpty()) {
                val dataUrl = "data:$mime$BASE64_MARKER${Base64.encode(bytes)}"
                memo.put(dataUrl, url)
                return part.copy(url = dataUrl)
            }
            if (failOnUnreadable && mime != null && bytes == null && file.exists()) {
                throw ConversationStorageException("Blob exists but could not be read: ${file.path}")
            }
            failures[position] = url
            val metadata = JsonObject((part.metadata ?: emptyMap()) + (MISSING_BLOB_METADATA_KEY to JsonPrimitive(url)))
            return part.copy(url = MISSING_BLOB_PLACEHOLDER_URL, metadata = metadata)
        }

        fun resolvePart(part: UIMessagePart, position: String): UIMessagePart = when (part) {
            is UIMessagePart.Image -> resolveImage(part, position)
            is UIMessagePart.Tool -> {
                val output = part.output.mapIndexedPreservingIdentity { index, child ->
                    resolvePart(child, "$position/o$index")
                }
                if (output === part.output) part else part.copy(output = output)
            }
            else -> part
        }

        val resolved = conversation.mapParts(::resolvePart)
        if (failures.isNotEmpty()) {
            placeholderRefs.getOrPut(conversation.id) { HashMap() }.putAll(failures)
            val names = failures.values.map { it.removePrefix(BLOB_URL_SCHEME) }.filter(::isValidBlobName)
            unresolvedBlobs.getOrPut(conversation.id) { HashSet() }.addAll(names)
        }
        return Resolved(resolved, memo, diskRefs, hadFailures = failures.isNotEmpty())
    }

    /**
     * Deletes blobs the previous on-disk JSON referenced ([previousDiskRefs]) that the JSON just
     * committed no longer references. Blobs this instance never saw referenced (crash orphans,
     * blobs of another writer) and blobs that failed to resolve in this process are never
     * touched; they are reclaimed when the conversation is deleted. Call only after the new
     * JSON is committed, under the storage mutex.
     */
    fun prune(id: Uuid, previousDiskRefs: Set<String>, referenced: Set<String>) {
        val protected = unresolvedBlobs[id].orEmpty()
        val removable = previousDiskRefs - referenced - protected
        if (removable.isEmpty()) return
        val directory = blobDirectory(id)
        removable.forEach { name -> runCatching { directory.child(name).delete() } }
        if (referenced.isEmpty() && directory.listChildNames().isEmpty()) {
            runCatching { directory.delete() }
        }
    }

    fun deleteAll(id: Uuid) {
        placeholderRefs.remove(id)
        unresolvedBlobs.remove(id)
        blobDirectory(id).deleteRecursively()
    }

    /**
     * Removes `{id}.blobs` directories whose conversation is gone: no `{id}.json` and no other
     * `{id}.*` file (import staging/backup), not seen by this process, and untouched for at
     * least [minAgeSeconds] (directory mtime moves on every blob write or delete).
     */
    fun sweepOrphanDirectories(nowEpochSeconds: Long, minAgeSeconds: Long) {
        val names = baseDir.listChildNames()
        val ids = names.filter { it.endsWith(BLOB_DIRECTORY_SUFFIX) }.mapNotNull { name ->
            runCatching { Uuid.parse(name.removeSuffix(BLOB_DIRECTORY_SUFFIX)) }.getOrNull()?.let { name to it }
        }
        ids.forEach { (dirName, id) ->
            val prefix = "$id."
            if (names.any { it != dirName && it.startsWith(prefix) }) return@forEach
            if (id in placeholderRefs || id in unresolvedBlobs) return@forEach
            val directory = baseDir.child(dirName)
            val version = directory.fileVersion() ?: return@forEach
            if (nowEpochSeconds - version.modifiedSeconds < minAgeSeconds) return@forEach
            runCatching { directory.deleteRecursively() }
        }
    }
}

private fun Conversation.mapParts(transform: (UIMessagePart, String) -> UIMessagePart): Conversation {
    val nodes = messageNodes.mapPreservingIdentity { node ->
        val messages = node.messages.mapPreservingIdentity { message ->
            val parts = message.parts.mapIndexedPreservingIdentity { index, part ->
                transform(part, "${message.id}/p$index")
            }
            if (parts === message.parts) message else message.copy(parts = parts)
        }
        if (messages === node.messages) node else node.copy(messages = messages)
    }
    return if (nodes === messageNodes) this else copy(messageNodes = nodes)
}

private inline fun <T> List<T>.mapPreservingIdentity(transform: (T) -> T): List<T> =
    mapIndexedPreservingIdentity { _, item -> transform(item) }

/** Maps a list, returning the same instance when no element changed (by identity). */
private inline fun <T> List<T>.mapIndexedPreservingIdentity(transform: (Int, T) -> T): List<T> {
    var result: ArrayList<T>? = null
    for (index in indices) {
        val original = this[index]
        val mapped = transform(index, original)
        if (result == null && mapped !== original) {
            result = ArrayList(size)
            for (previous in 0 until index) result.add(this[previous])
        }
        result?.add(mapped)
    }
    return result ?: this
}

/**
 * For backup/export paths that read conversation files directly: returns [documentText]
 * with every blob reference inlined back to its data URL, so the exported document is
 * self-contained and readable by app versions that predate blob storage. Text without
 * references is returned unchanged.
 *
 * Never silently drops a screenshot: a document that contains references but cannot be
 * decoded or re-encoded, or a blob that exists but cannot be read, throws (the backup fails
 * visibly and can be retried). A blob that is genuinely absent is already lost locally; it
 * exports as the placeholder with its reference kept under [MISSING_BLOB_METADATA_KEY].
 *
 * Reads blobs without the storage mutex; a blob pruned by a concurrent save is one the
 * current conversation no longer references.
 */
@Throws(Throwable::class)
fun inlineConversationBlobsForExport(conversationFilePath: String, documentText: String): String {
    if (!documentText.contains(BLOB_URL_SCHEME)) return documentText
    val conversation = try {
        JsonInstant.decodeFromString<Conversation>(documentText)
    } catch (error: Throwable) {
        throw ConversationStorageException("Cannot decode conversation for export: $conversationFilePath", error)
    }
    val directory = ConversationFile(conversationFilePath.substringBeforeLast(separatorChar()))
    val resolved = ConversationBlobCodec(directory).resolve(conversation, failOnUnreadable = true)
    if (resolved.hadFailures) {
        println("[AA-STORE] export: missing blobs kept as placeholders in $conversationFilePath")
    }
    if (resolved.conversation === conversation) return documentText
    return try {
        JsonInstant.encodeToString(resolved.conversation)
    } catch (error: Throwable) {
        throw ConversationStorageException("Cannot encode conversation for export: $conversationFilePath", error)
    }
}
