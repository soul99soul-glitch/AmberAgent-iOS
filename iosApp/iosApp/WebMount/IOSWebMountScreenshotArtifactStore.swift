import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum IOSWebMountScreenshotArtifactStore {
    static let retentionMillis: Int64 = 24 * 60 * 60 * 1_000

    static func save(
        _ capture: IOSWebMountScreenshotCapture,
        sessionId: String,
        rootDirectory: URL? = nil,
        nowMillis: Int64 = IOSWebMountClock.nowMillis()
    ) throws -> [String: Any] {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        try prepareDirectory(directory, fileManager: fileManager)
        cleanupExpired(rootDirectory: rootDirectory, nowMillis: nowMillis)
        let safeSessionId = safePathComponent(sessionId)
        let artifactId = "wmshot-\(nowMillis)-\(safeSessionId)"
        let fileName = "\(artifactId).\(capture.format)"
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try capture.data.write(to: destination, options: [.atomic])
        return [
            "artifact_id": artifactId,
            "local_ref": "Workspace/WebMount/screenshots/\(fileName)",
            "format": capture.format,
            "width": capture.width,
            "height": capture.height,
            "size_bytes": capture.data.count,
            "created_at_ms": nowMillis,
            "expires_at_ms": nowMillis + retentionMillis,
            "retention_hours": 24,
            "contains_unredacted_viewport": true
        ]
    }

    static func cleanupExpired(
        rootDirectory: URL? = nil,
        nowMillis: Int64 = IOSWebMountClock.nowMillis()
    ) {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "png" {
            let createdMillis = timestamp(from: file.lastPathComponent)
                ?? Int64(((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)
            if createdMillis > 0, nowMillis - createdMillis >= retentionMillis {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    static func deleteArtifacts(sessionId: String, rootDirectory: URL? = nil) {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        let suffix = "-\(safePathComponent(sessionId)).png"
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func screenshotsDirectory(rootDirectory: URL?) -> URL {
        let root = rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("AmberWorkspace", isDirectory: true)
            .appendingPathComponent("WebMount", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
    }

    private static func timestamp(from fileName: String) -> Int64? {
        guard fileName.hasPrefix("wmshot-") else { return nil }
        let suffix = fileName.dropFirst("wmshot-".count)
        guard let separator = suffix.firstIndex(of: "-") else { return nil }
        return Int64(suffix[..<separator])
    }

    private static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("_") }
        return String(value).nilIfBlank ?? "session"
    }
}

