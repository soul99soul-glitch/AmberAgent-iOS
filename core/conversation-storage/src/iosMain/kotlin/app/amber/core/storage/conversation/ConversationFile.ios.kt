package app.amber.core.storage.conversation

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.UByteVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreCrypto.CC_SHA256
import platform.CoreCrypto.CC_SHA256_DIGEST_LENGTH
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.dataWithContentsOfFile
import platform.posix.EINTR
import platform.posix.O_CREAT
import platform.posix.O_TRUNC
import platform.posix.O_WRONLY
import platform.posix.close
import platform.posix.errno
import platform.posix.fsync
import platform.posix.memcpy
import platform.posix.unlink
import platform.Foundation.NSFileManager
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.stringByDeletingLastPathComponent
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile
import platform.posix.stat
import platform.posix.rename

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
actual class ConversationFile actual constructor(actual val path: String) {

    private val fm: NSFileManager = NSFileManager.defaultManager

    actual fun mkdirs(): Boolean {
        if (fm.fileExistsAtPath(path)) return true
        // 复刻 TaskFile.ios.kt 的递归创建，保证 withIntermediateDirectories 行为一致。
        val parentPath = NSString.create(string = path).stringByDeletingLastPathComponent()
        if (parentPath.isNotEmpty() && parentPath != path &&
            !fm.fileExistsAtPath(parentPath)
        ) {
            ConversationFile(parentPath).mkdirs()
        }
        return runCatching {
            fm.createDirectoryAtPath(path, withIntermediateDirectories = true, attributes = null, error = null)
        }.getOrDefault(false)
    }

    actual fun exists(): Boolean = fm.fileExistsAtPath(path)

    actual fun delete(): Boolean {
        if (!exists()) return false
        return memScoped {
            val error = alloc<ObjCObjectVar<NSError?>>()
            val didDelete = fm.removeItemAtPath(path, error = error.ptr)
            if (!didDelete) {
                throw IllegalStateException("Failed to delete conversation file at $path: ${error.value.message()}")
            }
            true
        }
    }

    actual fun writeText(text: String) {
        // writeToFile(atomically: true) 走 tmp 文件 + rename，Foundation 原子写。
        val nsString = NSString.create(string = text)
        memScoped {
            val error = alloc<ObjCObjectVar<NSError?>>()
            val didWrite = nsString.writeToFile(
                path,
                atomically = true,
                encoding = NSUTF8StringEncoding,
                error = error.ptr,
            )
            if (!didWrite) {
                throw IllegalStateException("Failed to write conversation file at $path: ${error.value.message()}")
            }
        }
    }

    actual fun readText(): String? {
        if (!exists()) return null
        return runCatching {
            NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null) as String
        }.getOrNull()
    }

    actual fun listFilesByExtension(ext: String): List<ConversationFile> {
        if (!exists()) return emptyList()
        val names: List<String> = runCatching {
            (fm.contentsOfDirectoryAtPath(path, error = null) as? List<String>).orEmpty()
        }.getOrDefault(emptyList())
        return names.filter { name ->
            val dotIndex = name.lastIndexOf('.')
            dotIndex >= 0 && name.substring(dotIndex + 1) == ext
        }.map { name -> ConversationFile(path + "/" + name) }
    }
}

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun ConversationFile.fileVersion(): ConversationFileVersion? = memScoped {
    val fileStat = alloc<stat>()
    if (stat(path, fileStat.ptr) != 0) return@memScoped null
    ConversationFileVersion(
        device = fileStat.st_dev.toLong(),
        inode = fileStat.st_ino.toLong(),
        size = fileStat.st_size,
        modifiedSeconds = fileStat.st_mtimespec.tv_sec,
        modifiedNanoseconds = fileStat.st_mtimespec.tv_nsec,
        changedSeconds = fileStat.st_ctimespec.tv_sec,
        changedNanoseconds = fileStat.st_ctimespec.tv_nsec,
    )
}

actual fun separatorChar(): Char = '/'

@OptIn(ExperimentalForeignApi::class)
internal actual fun ConversationFile.moveTo(destination: ConversationFile) {
    if (rename(path, destination.path) != 0) {
        throw IllegalStateException("Failed to move conversation file from $path to ${destination.path}")
    }
}

private fun NSError?.message(): String =
    this?.localizedDescription ?: "unknown Foundation error"

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun ConversationFile.writeBytesDurably(bytes: ByteArray) {
    val parentPath = NSString.create(string = path).stringByDeletingLastPathComponent()
    if (parentPath.isNotEmpty()) ConversationFile(parentPath).mkdirs()
    val tmpPath = "$path.${kotlin.uuid.Uuid.random()}.tmp"
    // 0644; the file inherits the container's default data-protection class.
    val fd = platform.posix.open(tmpPath, O_WRONLY or O_CREAT or O_TRUNC, 0x1A4)
    if (fd < 0) throw IllegalStateException("Failed to create blob temp file $tmpPath errno=$errno")
    var committed = false
    try {
        var failure: String? = null
        if (bytes.isNotEmpty()) {
            bytes.usePinned { pinned ->
                var offset = 0
                while (offset < bytes.size) {
                    val written = platform.posix.write(
                        fd,
                        pinned.addressOf(offset),
                        (bytes.size - offset).convert(),
                    )
                    if (written < 0) {
                        if (errno == EINTR) continue
                        failure = "write errno=$errno"
                        break
                    }
                    offset += written.toInt()
                }
            }
        }
        if (failure == null && fsync(fd) != 0) failure = "fsync errno=$errno"
        if (close(fd) != 0 && failure == null) failure = "close errno=$errno"
        failure?.let { throw IllegalStateException("Failed to write blob $path: $it") }
        if (rename(tmpPath, path) != 0) {
            throw IllegalStateException("Failed to move blob into place $path errno=$errno")
        }
        committed = true
    } finally {
        if (!committed) unlink(tmpPath)
    }
}

@OptIn(ExperimentalForeignApi::class)
internal actual fun ConversationFile.readBytesOrNull(): ByteArray? {
    val data = NSData.dataWithContentsOfFile(path) ?: return null
    val length = data.length.toInt()
    if (length == 0) return ByteArray(0)
    val source = data.bytes ?: return null
    val result = ByteArray(length)
    result.usePinned { pinned -> memcpy(pinned.addressOf(0), source, data.length) }
    return result
}

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun ConversationFile.deleteRecursively(): Boolean {
    // NSFileManager.removeItemAtPath removes directory trees as well as files.
    return delete()
}

@OptIn(ExperimentalForeignApi::class)
internal actual fun ConversationFile.listChildNames(): List<String> {
    if (!exists()) return emptyList()
    return runCatching {
        @Suppress("UNCHECKED_CAST")
        (NSFileManager.defaultManager.contentsOfDirectoryAtPath(path, error = null) as? List<String>).orEmpty()
    }.getOrDefault(emptyList())
}

@OptIn(ExperimentalForeignApi::class)
internal actual fun sha256Hex(bytes: ByteArray): String = memScoped {
    val digest = allocArray<UByteVar>(CC_SHA256_DIGEST_LENGTH)
    if (bytes.isEmpty()) {
        CC_SHA256(null, 0u, digest)
    } else {
        bytes.usePinned { pinned -> CC_SHA256(pinned.addressOf(0), bytes.size.convert(), digest) }
    }
    buildString(CC_SHA256_DIGEST_LENGTH * 2) {
        for (i in 0 until CC_SHA256_DIGEST_LENGTH) {
            append(digest[i].toInt().toString(16).padStart(2, '0'))
        }
    }
}
