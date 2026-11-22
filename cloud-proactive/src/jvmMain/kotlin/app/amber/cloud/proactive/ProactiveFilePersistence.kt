package app.amber.cloud.proactive

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions

/**
 * Shared atomic 0600/0700 file persistence helper for `dataDir/proactive/`.
 */
object ProactiveFilePersistence {
    fun ensureOwnerOnlyDir(dir: File) {
        if (!dir.exists()) {
            dir.mkdirs()
        }
        setPosix0700(dir)
    }

    fun atomicWrite0600(target: File, content: String) {
        val parent = target.parentFile
        if (parent != null) {
            ensureOwnerOnlyDir(parent)
        }
        val tmp = File(parent, "${target.name}.${System.nanoTime()}.tmp")
        tmp.writeText(content)
        setPosix0600(tmp)
        try {
            Files.move(
                tmp.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: Exception) {
            Files.move(
                tmp.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
        setPosix0600(target)
    }

    fun setPosix0600(file: File?) {
        if (file == null || !file.exists()) return
        runCatching {
            Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------"))
        }
    }

    fun setPosix0700(file: File?) {
        if (file == null || !file.exists()) return
        runCatching {
            Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }
}
