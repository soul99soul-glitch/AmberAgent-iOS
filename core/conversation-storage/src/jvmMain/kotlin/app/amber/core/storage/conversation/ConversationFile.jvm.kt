package app.amber.core.storage.conversation

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.FileTime

actual class ConversationFile actual constructor(actual val path: String) {

    private val file: File = File(path)

    actual fun mkdirs(): Boolean = file.mkdirs() || file.isDirectory

    actual fun exists(): Boolean = file.exists()

    actual fun delete(): Boolean = file.delete()

    actual fun writeText(text: String) {
        val parent = file.parentFile
        if (parent != null && !parent.isDirectory) parent.mkdirs()
        val tmp = File.createTempFile(file.name, ".tmp", parent)
        try {
            tmp.writeText(text)
            runCatching {
                Files.move(
                    tmp.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }.getOrElse {
                Files.move(
                    tmp.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    actual fun readText(): String? =
        if (file.exists()) runCatching { file.readText() }.getOrNull() else null

    actual fun listFilesByExtension(ext: String): List<ConversationFile> =
        file.listFiles { f -> f.extension == ext }.orEmpty().map { ConversationFile(it.absolutePath) }
}

internal actual fun ConversationFile.fileVersion(): ConversationFileVersion? {
    return try {
        // unix:ctime catches an external replacement that restores both size and mtime.
        val attributes = Files.readAttributes(
            File(path).toPath(),
            "unix:dev,ino,size,lastModifiedTime,ctime",
        )
        val device = (attributes["dev"] as? Number)?.toLong() ?: return null
        val inode = (attributes["ino"] as? Number)?.toLong() ?: return null
        val size = (attributes["size"] as? Number)?.toLong() ?: return null
        val modified = (attributes["lastModifiedTime"] as? FileTime)?.toInstant() ?: return null
        val changed = (attributes["ctime"] as? FileTime)?.toInstant() ?: return null
        ConversationFileVersion(
            device = device,
            inode = inode,
            size = size,
            modifiedSeconds = modified.epochSecond,
            modifiedNanoseconds = modified.nano.toLong(),
            changedSeconds = changed.epochSecond,
            changedNanoseconds = changed.nano.toLong(),
        )
    } catch (_: Exception) {
        // A missing/unsupported attribute must never turn into an unsafe cache hit.
        null
    }
}

actual fun separatorChar(): Char = File.separatorChar
