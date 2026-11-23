package app.amber.cloud.proactive

import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
import java.nio.file.attribute.PosixFileAttributeView

/**
 * Shared atomic 0600/0700 file persistence helper for `dataDir/proactive/`.
 */
object ProactiveFilePersistence {
    fun ensureOwnerOnlyDir(dir: File) {
        Files.createDirectories(dir.toPath())
        setPosix0700(dir)
    }

    fun atomicWrite0600(target: File, content: String) {
        val parent = target.absoluteFile.parentFile
        ensureOwnerOnlyDir(parent)
        val dir = parent.toPath()
        val prefix = ".${target.name}."
        val tmp = if (Files.getFileAttributeView(dir, PosixFileAttributeView::class.java) != null) {
            val ownerOnly = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
            Files.createTempFile(dir, prefix, ".tmp", ownerOnly)
        } else Files.createTempFile(dir, prefix, ".tmp")
        try {
            Files.writeString(tmp, content)
            try {
                Files.move(tmp, target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(tmp, target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            Files.deleteIfExists(tmp)
        }
    }

    fun setPosix0600(file: File?) {
        if (file == null || !file.exists()) return
        runCatching {
            Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------"))
        }
    }

    fun setPosix0700(file: File?) {
        if (file == null || !file.exists()) return
        Files.getFileAttributeView(file.toPath(), PosixFileAttributeView::class.java)
            ?.setPermissions(PosixFilePermissions.fromString("rwx------"))
    }
}
