import CryptoKit
import Foundation

struct IOSWorkspaceUndoSnapshot: Codable, Equatable {
    let id: String
    let workspacePath: String
    let previousPath: String?
    let operation: String
    let existedBefore: Bool
    let previousSHA256: String?
    let afterSHA256: String
    let payloadFileName: String?
    let payloadBytes: Int
    let previousRecord: IOSWorkspaceFileRecord?
    let createdAtMillis: Int64
}

struct IOSWorkspaceUndoAuditEntry: Codable, Equatable {
    let id: String
    let action: String
    let workspacePath: String
    let operation: String
    let detail: String
    let createdAtMillis: Int64
}

struct IOSWorkspaceUndoPreState {
    let operation: String
    let targetPath: String
    let previousPath: String?
    let existedBefore: Bool
    let previousData: Data?
    let previousRecord: IOSWorkspaceFileRecord?
}

extension IOSWorkspaceStore {
    nonisolated static let maxUndoSnapshotBytes = 5 * 1024 * 1024
    nonisolated static let maxUndoSnapshotsPerPath = 3
    nonisolated static let maxUndoAgeMillis: Int64 = 24 * 60 * 60 * 1000
    nonisolated private static let maxUndoAuditEntries = 100

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var undoIndexURL: URL {
        undoDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    private var undoAuditURL: URL {
        undoDirectory.appendingPathComponent("audit.json", isDirectory: false)
    }

    func approvalDiffPreview(toolName: String, args: [String: Any]) -> String? {
        switch toolName {
        case "workspace_file_write":
            guard let rawPath = args["path"] as? String,
                  let path = try? normalizedPathForUndo(rawPath),
                  let content = args["content"] as? String else {
                return nil
            }
            let targetURL = undoFilesDirectory().appendingPathComponent(path, isDirectory: false)
            if let existingData = fileDataIfRegular(at: targetURL),
               existingData.count <= 512_000,
               content.utf8.count <= 512_000,
               let existingText = String(data: existingData, encoding: .utf8) {
                return Self.workspaceEditDiffPreview(original: existingText, edited: content, path: path).text
            }
            return Self.newFileDiffPreview(content: content, path: path)

        case "workspace_file_edit":
            let raw = (args["file_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? ""
            guard !raw.isEmpty,
                  let record = fileRecord(idOrPath: raw),
                  let find = args["find"] as? String, !find.isEmpty,
                  let replace = args["replace"] as? String else {
                return nil
            }
            let targetURL = fileURL(for: record)
            let replaceAll = (args["replace_all"] as? Bool) ?? false
            if let existingData = fileDataIfRegular(at: targetURL),
               existingData.count <= 512_000,
               let original = String(data: existingData, encoding: .utf8),
               let proposed = Self.applyingProposedEdit(
                   original: original,
                   find: find,
                   replace: replace,
                   replaceAll: replaceAll
               ) {
                return Self.workspaceEditDiffPreview(
                    original: original,
                    edited: proposed,
                    path: record.workspacePath
                ).text
            }
            let findSnippet = find.components(separatedBy: "\n").prefix(12).map { "-" + $0 }.joined(separator: "\n")
            let replaceSnippet = replace.components(separatedBy: "\n").prefix(12).map { "+" + $0 }.joined(separator: "\n")
            return "--- /workspace/\(record.workspacePath)\n+++ /workspace/\(record.workspacePath)\n\(findSnippet)\n\(replaceSnippet)"

        case "workspace_file_move":
            let raw = (args["file_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? ""
            guard let record = fileRecord(idOrPath: raw),
                  let rawDest = args["destination_path"] as? String,
                  let dest = try? normalizedPathForUndo(rawDest) else {
                return nil
            }
            return "--- /workspace/\(record.workspacePath)\n+++ /workspace/\(dest)"

        case "workspace_artifact_delete":
            let id = (args["artifact_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            guard let id,
                  let artifact = artifacts.first(where: { $0.id == id }) else {
                return nil
            }
            return "- Artifact: \(artifact.title) (\(artifact.contentBytes) bytes)"

        default:
            return nil
        }
    }

    func captureUndoPreState(toolName: String, args: [String: Any]) -> IOSWorkspaceUndoPreState? {
        switch toolName {
        case "workspace_file_write":
            guard let rawPath = args["path"] as? String,
                  let path = try? normalizedPathForUndo(rawPath) else {
                return nil
            }
            let targetURL = undoFilesDirectory().appendingPathComponent(path, isDirectory: false)
            let previousData = fileDataIfRegular(at: targetURL)
            let previousRecord = files.first(where: { $0.workspacePath == path })
            return IOSWorkspaceUndoPreState(
                operation: "write",
                targetPath: path,
                previousPath: nil,
                existedBefore: previousData != nil,
                previousData: previousData,
                previousRecord: previousRecord
            )

        case "workspace_file_edit":
            let raw = (args["file_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? ""
            guard let record = fileRecord(idOrPath: raw) else {
                return nil
            }
            let targetURL = fileURL(for: record)
            let previousData = fileDataIfRegular(at: targetURL)
            return IOSWorkspaceUndoPreState(
                operation: "edit",
                targetPath: record.workspacePath,
                previousPath: nil,
                existedBefore: previousData != nil,
                previousData: previousData,
                previousRecord: record
            )

        case "workspace_file_move":
            let raw = (args["file_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? ""
            guard let sourceRecord = fileRecord(idOrPath: raw),
                  let rawDest = args["destination_path"] as? String,
                  let destPath = try? normalizedPathForUndo(rawDest) else {
                return nil
            }
            let sourceData = fileDataIfRegular(at: fileURL(for: sourceRecord))
            return IOSWorkspaceUndoPreState(
                operation: "move",
                targetPath: destPath,
                previousPath: sourceRecord.workspacePath,
                existedBefore: false,
                previousData: sourceData,
                previousRecord: sourceRecord
            )

        default:
            return nil
        }
    }

    func finalizeUndoSnapshot(pre: IOSWorkspaceUndoPreState?, toolResultJSON: String, now: Date = Date()) {
        guard let pre else { return }
        let resultObject = undoJSONObject(toolResultJSON)
        guard (resultObject["ok"] as? Bool) == true else { return }

        do {
            try undoEnsureDirectories()
        } catch {
            return
        }

        let nowMillis = undoMillis(now)
        var snapshots = loadUndoSnapshots()
        var audit = loadUndoAuditEntries()
        pruneExpired(&snapshots, audit: &audit, nowMillis: nowMillis)

        let targetURL = undoFilesDirectory().appendingPathComponent(pre.targetPath, isDirectory: false)
        guard let afterData = fileDataIfRegular(at: targetURL) else { return }

        let beforeBytes = pre.previousData?.count ?? 0
        if beforeBytes > Self.maxUndoSnapshotBytes || afterData.count > Self.maxUndoSnapshotBytes {
            audit.append(IOSWorkspaceUndoAuditEntry(
                id: UUID().uuidString,
                action: "snapshot_skipped",
                workspacePath: pre.targetPath,
                operation: pre.operation,
                detail: "Snapshot skipped: file size exceeds 5 MB limit (before=\(beforeBytes), after=\(afterData.count)).",
                createdAtMillis: nowMillis
            ))
            saveUndoAuditEntries(audit)
            saveUndoSnapshots(snapshots)
            return
        }

        let snapshotID = UUID().uuidString
        var payloadFileName: String? = nil
        var previousSHA: String? = nil
        if pre.existedBefore, let previousData = pre.previousData {
            previousSHA = Self.sha256Hex(previousData)
            let fileName = "\(snapshotID).bin"
            let payloadURL = undoDirectory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try previousData.write(to: payloadURL, options: [.atomic])
                payloadFileName = fileName
            } catch {
                return
            }
        }

        let snapshot = IOSWorkspaceUndoSnapshot(
            id: snapshotID,
            workspacePath: pre.targetPath,
            previousPath: pre.previousPath,
            operation: pre.operation,
            existedBefore: pre.existedBefore,
            previousSHA256: previousSHA,
            afterSHA256: Self.sha256Hex(afterData),
            payloadFileName: payloadFileName,
            payloadBytes: pre.existedBefore ? beforeBytes : 0,
            previousRecord: pre.previousRecord,
            createdAtMillis: nowMillis
        )
        snapshots.append(snapshot)
        audit.append(IOSWorkspaceUndoAuditEntry(
            id: UUID().uuidString,
            action: "snapshot_saved",
            workspacePath: pre.targetPath,
            operation: pre.operation,
            detail: "Saved .undo snapshot \(snapshotID) (afterSHA256=\(snapshot.afterSHA256.prefix(12))).",
            createdAtMillis: nowMillis
        ))

        enforcePerPathLimit(for: pre.targetPath, snapshots: &snapshots, audit: &audit, nowMillis: nowMillis)
        saveUndoSnapshots(snapshots)
        saveUndoAuditEntries(audit)
    }

    func pruneExpiredUndoSnapshots(now: Date = Date()) {
        let nowMillis = undoMillis(now)
        var snapshots = loadUndoSnapshots()
        guard !snapshots.isEmpty else { return }
        var audit = loadUndoAuditEntries()
        let beforeCount = snapshots.count
        pruneExpired(&snapshots, audit: &audit, nowMillis: nowMillis)
        if snapshots.count != beforeCount {
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
        }
    }

    func undoSnapshots(forPath rawPath: String? = nil) -> [IOSWorkspaceUndoSnapshot] {
        let all = loadUndoSnapshots()
        guard let rawPath, let normalized = try? normalizedPathForUndo(rawPath) else {
            return all
        }
        return all.filter { $0.workspacePath == normalized }
    }

    func undoAuditEntries() -> [IOSWorkspaceUndoAuditEntry] {
        loadUndoAuditEntries()
    }

    func resultWithUndoReceipt(_ result: String, previousSnapshotIDs: Set<String>) -> String {
        guard let snapshot = undoSnapshots().last(where: { !previousSnapshotIDs.contains($0.id) }) else { return result }
        var object = undoJSONObject(result)
        object["undo_snapshot_id"] = snapshot.id
        return Self.json(object)
    }

    @discardableResult
    func undoLastChange(forPath rawPath: String, expectedSnapshotID: String? = nil, now: Date = Date()) -> [String: Any] {
        let nowMillis = undoMillis(now)
        var snapshots = loadUndoSnapshots()
        var audit = loadUndoAuditEntries()
        pruneExpired(&snapshots, audit: &audit, nowMillis: nowMillis)

        guard let targetPath = try? normalizedPathForUndo(rawPath) else {
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
            return ["ok": false, "error": "Invalid workspace path."]
        }

        guard let index = snapshots.lastIndex(where: { $0.workspacePath == targetPath }) else {
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
            return [
                "ok": false,
                "path": "/workspace/\(targetPath)",
                "error": "No undo snapshot available for /workspace/\(targetPath)."
            ]
        }

        let snapshot = snapshots[index]
        guard expectedSnapshotID == nil || snapshot.id == expectedSnapshotID else {
            audit.append(IOSWorkspaceUndoAuditEntry(id: UUID().uuidString, action: "undo_conflict",
                workspacePath: snapshot.workspacePath, operation: snapshot.operation,
                detail: "Undo refused: a newer snapshot owns this path.", createdAtMillis: nowMillis))
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
            return ["ok": false, "conflict": true, "error": "A newer workspace change exists; undo refused."]
        }
        let targetURL = undoFilesDirectory().appendingPathComponent(snapshot.workspacePath, isDirectory: false)
        guard let currentData = fileDataIfRegular(at: targetURL) else {
            audit.append(IOSWorkspaceUndoAuditEntry(
                id: UUID().uuidString,
                action: "undo_conflict",
                workspacePath: snapshot.workspacePath,
                operation: snapshot.operation,
                detail: "Undo refused: target file is missing.",
                createdAtMillis: nowMillis
            ))
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
            return [
                "ok": false,
                "conflict": true,
                "path": "/workspace/\(snapshot.workspacePath)",
                "error": "Target file no longer exists on disk; undo refused."
            ]
        }

        let currentSHA256 = Self.sha256Hex(currentData)
        guard currentSHA256 == snapshot.afterSHA256 else {
            audit.append(IOSWorkspaceUndoAuditEntry(
                id: UUID().uuidString,
                action: "undo_conflict",
                workspacePath: snapshot.workspacePath,
                operation: snapshot.operation,
                detail: "Undo refused: SHA-256 mismatch (expected \(snapshot.afterSHA256.prefix(12)), got \(currentSHA256.prefix(12))).",
                createdAtMillis: nowMillis
            ))
            saveUndoSnapshots(snapshots)
            saveUndoAuditEntries(audit)
            return [
                "ok": false,
                "conflict": true,
                "path": "/workspace/\(snapshot.workspacePath)",
                "expected_sha256": snapshot.afterSHA256,
                "actual_sha256": currentSHA256,
                "error": "File changed externally after agent write; undo refused."
            ]
        }

        let fm = undoFileManager()
        do {
            if snapshot.operation == "move", let previousPath = snapshot.previousPath {
                let sourceURL = undoFilesDirectory().appendingPathComponent(previousPath, isDirectory: false)
                guard !fm.fileExists(atPath: sourceURL.path) else {
                    audit.append(IOSWorkspaceUndoAuditEntry(
                        id: UUID().uuidString,
                        action: "undo_conflict",
                        workspacePath: snapshot.workspacePath,
                        operation: snapshot.operation,
                        detail: "Undo move refused: original path already exists.",
                        createdAtMillis: nowMillis
                    ))
                    saveUndoSnapshots(snapshots)
                    saveUndoAuditEntries(audit)
                    return [
                        "ok": false,
                        "conflict": true,
                        "path": "/workspace/\(snapshot.workspacePath)",
                        "error": "Original path /workspace/\(previousPath) already exists; undo refused."
                    ]
                }
                try fm.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: targetURL, to: sourceURL)
                try applyUndoMutation(
                    removingRecordIDs: Set([snapshot.previousRecord?.id].compactMap { $0 }),
                    removingPaths: Set([snapshot.workspacePath, previousPath]),
                    insertingRecord: snapshot.previousRecord
                )
            } else if snapshot.existedBefore {
                guard let payloadFileName = snapshot.payloadFileName,
                      let previousData = try? Data(contentsOf: undoDirectory.appendingPathComponent(payloadFileName)),
                      snapshot.previousSHA256 == nil || Self.sha256Hex(previousData) == snapshot.previousSHA256 else {
                    return [
                        "ok": false,
                        "conflict": true,
                        "path": "/workspace/\(snapshot.workspacePath)",
                        "error": "Stored .undo payload failed integrity verification."
                    ]
                }
                try previousData.write(to: targetURL, options: [.atomic])
                try applyUndoMutation(
                    removingRecordIDs: Set([snapshot.previousRecord?.id].compactMap { $0 }),
                    removingPaths: Set([snapshot.workspacePath]),
                    insertingRecord: snapshot.previousRecord
                )
            } else {
                try fm.removeItem(at: targetURL)
                try applyUndoMutation(
                    removingRecordIDs: Set([snapshot.previousRecord?.id].compactMap { $0 }),
                    removingPaths: Set([snapshot.workspacePath]),
                    insertingRecord: nil
                )
            }
        } catch {
            return [
                "ok": false,
                "path": "/workspace/\(snapshot.workspacePath)",
                "error": error.localizedDescription
            ]
        }

        if let payloadFileName = snapshot.payloadFileName {
            try? fm.removeItem(at: undoDirectory.appendingPathComponent(payloadFileName))
        }
        snapshots.remove(at: index)
        audit.append(IOSWorkspaceUndoAuditEntry(
            id: UUID().uuidString,
            action: "undone",
            workspacePath: snapshot.workspacePath,
            operation: snapshot.operation,
            detail: "Restored /workspace/\(snapshot.workspacePath) from snapshot \(snapshot.id).",
            createdAtMillis: nowMillis
        ))
        saveUndoSnapshots(snapshots)
        saveUndoAuditEntries(audit)

        return [
            "ok": true,
            "undone": true,
            "operation": snapshot.operation,
            "path": "/workspace/\(snapshot.workspacePath)",
            "restored_previous_path": snapshot.previousPath.map { "/workspace/\($0)" } as Any
        ]
    }

    // MARK: - Private Undo Helpers

    private func pruneExpired(
        _ snapshots: inout [IOSWorkspaceUndoSnapshot],
        audit: inout [IOSWorkspaceUndoAuditEntry],
        nowMillis: Int64
    ) {
        let fm = undoFileManager()
        var kept: [IOSWorkspaceUndoSnapshot] = []
        for snapshot in snapshots {
            if nowMillis - snapshot.createdAtMillis > Self.maxUndoAgeMillis {
                if let fileName = snapshot.payloadFileName {
                    try? fm.removeItem(at: undoDirectory.appendingPathComponent(fileName))
                }
                audit.append(IOSWorkspaceUndoAuditEntry(
                    id: UUID().uuidString,
                    action: "snapshot_expired",
                    workspacePath: snapshot.workspacePath,
                    operation: snapshot.operation,
                    detail: "Auto-cleaned .undo snapshot older than 24h (\(snapshot.id)).",
                    createdAtMillis: nowMillis
                ))
            } else {
                kept.append(snapshot)
            }
        }
        snapshots = kept
    }

    private func enforcePerPathLimit(
        for path: String,
        snapshots: inout [IOSWorkspaceUndoSnapshot],
        audit: inout [IOSWorkspaceUndoAuditEntry],
        nowMillis: Int64
    ) {
        let fm = undoFileManager()
        var matchingIndices = snapshots.indices.filter { snapshots[$0].workspacePath == path }
        while matchingIndices.count > Self.maxUndoSnapshotsPerPath {
            let removeIndex = matchingIndices.removeFirst()
            let evicted = snapshots.remove(at: removeIndex)
            if let fileName = evicted.payloadFileName {
                try? fm.removeItem(at: undoDirectory.appendingPathComponent(fileName))
            }
            audit.append(IOSWorkspaceUndoAuditEntry(
                id: UUID().uuidString,
                action: "snapshot_evicted",
                workspacePath: evicted.workspacePath,
                operation: evicted.operation,
                detail: "Evicted oldest .undo snapshot beyond limit \(Self.maxUndoSnapshotsPerPath).",
                createdAtMillis: nowMillis
            ))
            matchingIndices = snapshots.indices.filter { snapshots[$0].workspacePath == path }
        }
    }

    private func loadUndoSnapshots() -> [IOSWorkspaceUndoSnapshot] {
        guard let data = try? Data(contentsOf: undoIndexURL),
              let decoded = try? JSONDecoder().decode([IOSWorkspaceUndoSnapshot].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveUndoSnapshots(_ snapshots: [IOSWorkspaceUndoSnapshot]) {
        do {
            try undoEnsureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshots)
            try data.write(to: undoIndexURL, options: [.atomic])
        } catch {
            // Keep store mutations resilient even if auxiliary undo persistence fails.
        }
    }

    private func loadUndoAuditEntries() -> [IOSWorkspaceUndoAuditEntry] {
        guard let data = try? Data(contentsOf: undoAuditURL),
              let decoded = try? JSONDecoder().decode([IOSWorkspaceUndoAuditEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveUndoAuditEntries(_ entries: [IOSWorkspaceUndoAuditEntry]) {
        do {
            try undoEnsureDirectories()
            let trimmed = Array(entries.suffix(Self.maxUndoAuditEntries))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(trimmed)
            try data.write(to: undoAuditURL, options: [.atomic])
        } catch {
            // Non-fatal
        }
    }

    private static func applyingProposedEdit(
        original: String,
        find: String,
        replace: String,
        replaceAll: Bool
    ) -> String? {
        if replaceAll {
            guard original.contains(find) else { return nil }
            return original.replacingOccurrences(of: find, with: replace)
        }
        guard let range = original.range(of: find) else { return nil }
        if original[range.upperBound...].contains(find) {
            return nil
        }
        var copy = original
        copy.replaceSubrange(range, with: replace)
        return copy
    }

    private static func newFileDiffPreview(content: String, path: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var text = "--- /dev/null\n+++ /workspace/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines.prefix(40) {
            let row = "+" + line + "\n"
            if text.count + row.count > 4_000 {
                text += "...\n"
                break
            }
            text += row
        }
        if lines.count > 40 {
            text += "... (\(lines.count - 40) more lines)\n"
        }
        return text
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
