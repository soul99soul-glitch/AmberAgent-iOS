import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct SelectedDocumentGrant: Identifiable, Hashable {
    let id: String
    let capabilityId: String
    let toolName: String
    let operation: String
    let fileName: String
    let fileType: String
    let fileSize: Int64
    let scopeDigest: String
    let payloadDigest: String
    let createdAt: Date
    let expiresAt: Date
    let maxUses: Int
    var usedCount: Int
    fileprivate let url: URL

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt || usedCount >= maxUses
    }
}

struct SelectedDocumentGrantSummary: Identifiable, Hashable {
    let id: String
    let capabilityId: String
    let toolName: String
    let operation: String
    let fileName: String
    let fileType: String
    let fileSize: Int64
    let scopeDigest: String
    let payloadDigest: String
    let createdAt: Date
    let expiresAt: Date
    let maxUses: Int
    let usedCount: Int

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt || usedCount >= maxUses
    }
}

struct SelectedDocumentReadResult: Hashable {
    let fileName: String
    let fileType: String
    let totalBytes: Int64
    let bytesRead: Int
    let characterCount: Int
    let preview: String
    let isTruncated: Bool
    let note: String?

    var byteSummary: String {
        let read = DocumentAccessStore.formatBytes(Int64(bytesRead))
        guard totalBytes > 0 else { return read }
        return "\(read)/\(DocumentAccessStore.formatBytes(totalBytes))"
    }

    var statusSummary: String {
        if let note, !note.isEmpty { return note }
        return isTruncated ? "内容已截断" : "完整读取"
    }
}

enum IOSWorkspaceFileStatus: String, Codable, Hashable {
    case ready
    case missing
    case parseFailed
    case unsupported
    case tooLarge
    case needsReauthorization

    var title: String {
        let key: String
        switch self {
        case .ready: key = "Ready"
        case .missing: key = "Missing"
        case .parseFailed: key = "Parse failed"
        case .unsupported: key = "Unsupported"
        case .tooLarge: key = "Too large"
        case .needsReauthorization: key = "Needs reauthorization"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

enum IOSWorkspaceArtifactType: String, Codable, CaseIterable, Identifiable {
    case chat
    case deepRead
    case webMount
    case miniApp
    case image
    case note
    case file

    var id: String { rawValue }

    var title: String {
        let key: String
        switch self {
        case .chat: key = "Chat"
        case .deepRead: key = "Deep Read"
        case .webMount: key = "WebMount"
        case .miniApp: key = "Mini App"
        case .image: key = "Image"
        case .note: key = "Note"
        case .file: key = "File"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

struct IOSWorkspaceFileRecord: Identifiable, Codable, Hashable {
    let id: String
    var displayName: String
    var originalFileName: String
    var workspacePath: String
    var mimeType: String
    var sizeBytes: Int64
    var importedAtMillis: Int64
    var updatedAtMillis: Int64
    var status: IOSWorkspaceFileStatus
    var statusMessage: String
    var preview: String
    var isTruncated: Bool
    var characterCount: Int
    var source: String

    var byteSummary: String {
        DocumentAccessStore.formatBytes(sizeBytes)
    }
}

struct IOSWorkspaceArtifactRecord: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var type: IOSWorkspaceArtifactType
    var contentPath: String
    var contentBytes: Int64
    var summary: String
    var createdAtMillis: Int64
    var updatedAtMillis: Int64
    var sourceKind: String
    var sourceId: String?
}

private struct IOSWorkspaceState: Codable {
    var files: [IOSWorkspaceFileRecord] = []
    var artifacts: [IOSWorkspaceArtifactRecord] = []
}

enum IOSWorkspaceStoreError: Error, LocalizedError, Equatable {
    case missingFile
    case missingArtifact
    case invalidPath(String)
    case fileTooLarge(String)
    case accessDenied(String)
    case directorySelected
    case writeWouldOverwrite(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .missingFile:
            "Workspace file was not found."
        case .missingArtifact:
            "Workspace artifact was not found."
        case .invalidPath(let message):
            message
        case .fileTooLarge(let message):
            message
        case .accessDenied(let message):
            message
        case .directorySelected:
            "Choose a regular file, not a folder."
        case .writeWouldOverwrite(let path):
            "Workspace file already exists: \(path)"
        case .storage(let message):
            message
        }
    }
}

enum IOSWorkspaceToolCatalog {
    static let readToolNames: Set<String> = ["workspace_file_read", "workspace_artifact_read", "workspace_file_list", "workspace_file_search"]
    static let writeToolNames: Set<String> = ["workspace_file_write", "workspace_artifact_delete", "workspace_file_edit", "workspace_file_move"]
    static let supportedToolNames: Set<String> = readToolNames.union(writeToolNames)
}

@MainActor
@Observable
final class IOSWorkspaceStore {
    static let shared = IOSWorkspaceStore()

    private(set) var files: [IOSWorkspaceFileRecord] = []
    private(set) var artifacts: [IOSWorkspaceArtifactRecord] = []
    private(set) var errorMessage: String?
    private(set) var revision: Int = 0

    let maxImportBytes: Int64 = 20 * 1024 * 1024
    let maxPreviewCharacters = 60_000

    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let filesDirectory: URL
    @ObservationIgnored private let artifactsDirectory: URL
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.rootDirectory = root.appendingPathComponent("AmberWorkspace", isDirectory: true)
        self.filesDirectory = rootDirectory.appendingPathComponent("files", isDirectory: true)
        self.artifactsDirectory = rootDirectory.appendingPathComponent("artifacts", isDirectory: true)
        self.stateURL = rootDirectory.appendingPathComponent("workspace.json", isDirectory: false)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        reload()
    }

    var recentFiles: [IOSWorkspaceFileRecord] {
        files.sorted { $0.updatedAtMillis > $1.updatedAtMillis }
    }

    var recentArtifacts: [IOSWorkspaceArtifactRecord] {
        artifacts.sorted { $0.updatedAtMillis > $1.updatedAtMillis }
    }

    func reload() {
        do {
            try ensureDirectories()
            guard fileManager.fileExists(atPath: stateURL.path) else {
                files = []
                artifacts = []
                errorMessage = nil
                return
            }
            let data = try Data(contentsOf: stateURL)
            let state = try decoder.decode(IOSWorkspaceState.self, from: data)
            files = state.files
            artifacts = state.artifacts
            errorMessage = nil
        } catch {
            files = []
            artifacts = []
            errorMessage = error.localizedDescription
        }
        revision &+= 1
    }

    @discardableResult
    func importFile(url: URL, source: String = "document_picker", now: Date = Date()) async throws -> IOSWorkspaceFileRecord {
        try ensureDirectories()
        let shouldStopAccessing = try startScopedAccessIfNeeded(url)
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .localizedTypeDescriptionKey])
        guard values.isRegularFile != false else {
            throw IOSWorkspaceStoreError.directorySelected
        }
        let size = Int64(values.fileSize ?? Self.fileSize(for: url) ?? 0)
        guard size <= maxImportBytes else {
            throw IOSWorkspaceStoreError.fileTooLarge("File is larger than the Workspace import limit of \(DocumentAccessStore.formatBytes(maxImportBytes)).")
        }

        let id = UUID().uuidString
        let fileName = Self.safeFileName(url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent)
        let workspacePath = "uploads/\(id)-\(fileName)"
        let destination = fileURL(forWorkspacePath: workspacePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)

        let mimeType = values.contentType?.preferredMIMEType
            ?? values.contentType?.identifier
            ?? values.localizedTypeDescription
            ?? "application/octet-stream"
        var record = IOSWorkspaceFileRecord(
            id: id,
            displayName: url.lastPathComponent,
            originalFileName: url.lastPathComponent,
            workspacePath: workspacePath,
            mimeType: mimeType,
            sizeBytes: size,
            importedAtMillis: Self.millis(now),
            updatedAtMillis: Self.millis(now),
            status: .ready,
            statusMessage: "",
            preview: "",
            isTruncated: false,
            characterCount: 0,
            source: source
        )
        record = await parsedRecord(record, now: now)
        files.insert(record, at: 0)
        try persist()
        publish()
        return record
    }

    @discardableResult
    func reparseFile(id: String, now: Date = Date()) async throws -> IOSWorkspaceFileRecord {
        guard let index = files.firstIndex(where: { $0.id == id }) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        let next = await parsedRecord(files[index], now: now)
        files[index] = next
        try persist()
        publish()
        return next
    }

    func removeFile(id: String) throws {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let record = files.remove(at: index)
        let url = fileURL(forWorkspacePath: record.workspacePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try persist()
        publish()
    }

    @discardableResult
    func saveArtifact(
        title rawTitle: String,
        content: String,
        type: IOSWorkspaceArtifactType,
        sourceKind: String,
        sourceId: String? = nil,
        now: Date = Date()
    ) throws -> IOSWorkspaceArtifactRecord {
        try ensureDirectories()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).workspaceNilIfBlank ?? "Untitled Artifact"
        let id = UUID().uuidString
        let safeTitle = Self.safeFileName(title).prefix(42)
        let contentPath = "\(id)-\(safeTitle).md"
        let destination = artifactsDirectory.appendingPathComponent(contentPath, isDirectory: false)
        try Data(content.utf8).write(to: destination, options: [.atomic])
        let nowMillis = Self.millis(now)
        let record = IOSWorkspaceArtifactRecord(
            id: id,
            title: title,
            type: type,
            contentPath: contentPath,
            contentBytes: Int64(content.utf8.count),
            summary: Self.summary(content),
            createdAtMillis: nowMillis,
            updatedAtMillis: nowMillis,
            sourceKind: sourceKind,
            sourceId: sourceId
        )
        artifacts.insert(record, at: 0)
        try persist()
        publish()
        return record
    }

    func artifactContent(id: String) throws -> String {
        guard let record = artifacts.first(where: { $0.id == id }) else {
            throw IOSWorkspaceStoreError.missingArtifact
        }
        return try String(contentsOf: artifactsDirectory.appendingPathComponent(record.contentPath), encoding: .utf8)
    }

    func deleteArtifact(id: String) throws {
        guard let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        let record = artifacts.remove(at: index)
        let url = artifactsDirectory.appendingPathComponent(record.contentPath, isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try persist()
        publish()
    }

    func executeTool(toolName: String, input: String) async -> String {
        do {
            let args = Self.jsonObject(input)
            switch toolName {
            case "workspace_file_read":
                return try await workspaceFileReadJSON(args)
            case "workspace_file_write":
                return try await workspaceFileWriteJSON(args)
            case "workspace_file_edit":
                return try await workspaceFileEditJSON(args)
            case "workspace_file_list":
                return try workspaceFileListJSON(args)
            case "workspace_file_search":
                return try await workspaceFileSearchJSON(args)
            case "workspace_file_move":
                return try await workspaceFileMoveJSON(args)
            case "workspace_artifact_read":
                return try workspaceArtifactReadJSON(args)
            case "workspace_artifact_delete":
                return try workspaceArtifactDeleteJSON(args)
            default:
                return Self.json(["ok": false, "tool": toolName, "error": "Unsupported Workspace tool."])
            }
        } catch {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
        }
    }

    func fileRecord(idOrPath raw: String) -> IOSWorkspaceFileRecord? {
        let normalized = try? normalizeWorkspacePath(raw)
        return files.first { record in
            if record.id == raw || "/workspace/\(record.workspacePath)" == raw {
                return true
            }
            guard let normalized else { return false }
            return record.workspacePath == normalized
        }
    }

    func fileURL(for record: IOSWorkspaceFileRecord) -> URL {
        fileURL(forWorkspacePath: record.workspacePath)
    }

    func amberShellRootEntries() throws -> [String] {
        try amberShellList(path: "/workspace")
    }

    func amberShellList(path: String) throws -> [String] {
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: true)
        let directory = try amberShellURL(for: relativePath, finalMayBeMissing: false)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot traverse symbolic links.")
        }
        guard values.isDirectory == true else {
            throw IOSWorkspaceStoreError.directorySelected
        }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .map(\.lastPathComponent)
        .sorted()
    }

    func amberShellReadText(path: String, maxBytes: Int) throws -> String {
        guard maxBytes >= 0 else {
            throw IOSWorkspaceStoreError.invalidPath("maxBytes must be non-negative.")
        }
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let file = try amberShellURL(for: relativePath, finalMayBeMissing: false)
        try amberShellRequireRegularFile(at: file)
        let data = try Data(contentsOf: file)
        guard String(data: data, encoding: .utf8) != nil else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace file is not valid UTF-8 text.")
        }
        guard data.count <= maxBytes else {
            throw IOSWorkspaceStoreError.fileTooLarge("File exceeds the AmberShell output limit of \(DocumentAccessStore.formatBytes(Int64(maxBytes))).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func amberShellWriteText(path: String, text: String) async throws {
        let data = Data(text.utf8)
        let maxBytes = 128 * 1024
        guard data.count <= maxBytes else {
            throw IOSWorkspaceStoreError.fileTooLarge(
                "File exceeds the AmberShell write limit of \(DocumentAccessStore.formatBytes(Int64(maxBytes)))."
            )
        }

        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let file = try amberShellURL(for: relativePath, finalMayBeMissing: true)
        let existed = fileManager.fileExists(atPath: file.path)
        let previousData: Data?
        let previousModificationDate: Date?
        if existed {
            try amberShellRequireRegularFile(at: file)
            previousData = try Data(contentsOf: file)
            previousModificationDate = try file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        } else {
            previousData = nil
            previousModificationDate = nil
        }
        let previousFiles = files

        try data.write(to: file, options: [.atomic])
        do {
            try await amberShellSyncFileRecord(
                path: relativePath,
                file: file,
                source: "amber_shell_write"
            )
        } catch {
            try amberShellRollback(after: error, restoring: previousFiles) {
                if let previousData {
                    try previousData.write(to: file, options: [.atomic])
                    if let previousModificationDate {
                        try fileManager.setAttributes(
                            [.modificationDate: previousModificationDate],
                            ofItemAtPath: file.path
                        )
                    }
                } else if fileManager.fileExists(atPath: file.path) {
                    try fileManager.removeItem(at: file)
                }
            }
        }
    }

    func amberShellValidateWriteTarget(path: String) throws {
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let file = try amberShellURL(for: relativePath, finalMayBeMissing: true)
        if fileManager.fileExists(atPath: file.path) {
            try amberShellRequireRegularFile(at: file)
        }
    }

    func amberShellPathIdentity(_ path: String) throws -> String {
        try amberShellRelativePath(path, allowingRoot: false)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    func amberShellCreateDirectory(path: String) throws {
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let directory = try amberShellURL(for: relativePath, finalMayBeMissing: true)
        if fileManager.fileExists(atPath: directory.path) {
            throw IOSWorkspaceStoreError.writeWouldOverwrite("/workspace/\(relativePath)")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func amberShellTouch(path: String) async throws {
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let file = try amberShellURL(for: relativePath, finalMayBeMissing: true)
        let existed = fileManager.fileExists(atPath: file.path)
        let previousModificationDate = existed
            ? try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        let previousFiles = files
        if existed {
            try amberShellRequireRegularFile(at: file)
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            guard fileManager.createFile(atPath: file.path, contents: Data()) else {
                throw IOSWorkspaceStoreError.storage("Unable to create Workspace file.")
            }
        }
        do {
            try await amberShellSyncFileRecord(path: relativePath, file: file, source: "amber_shell_touch")
        } catch {
            try amberShellRollback(after: error, restoring: previousFiles) {
                if existed, let previousModificationDate {
                    try fileManager.setAttributes([.modificationDate: previousModificationDate], ofItemAtPath: file.path)
                } else if !existed, fileManager.fileExists(atPath: file.path) {
                    try fileManager.removeItem(at: file)
                }
            }
        }
    }

    func amberShellCopy(from source: String, to destination: String) async throws {
        try ensureDirectories()
        let sourcePath = try amberShellRelativePath(source, allowingRoot: false)
        let destinationPath = try amberShellRelativePath(destination, allowingRoot: false)
        let sourceURL = try amberShellURL(for: sourcePath, finalMayBeMissing: false)
        let destinationURL = try amberShellURL(for: destinationPath, finalMayBeMissing: true)
        try amberShellRequireRegularFile(at: sourceURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw IOSWorkspaceStoreError.writeWouldOverwrite("/workspace/\(destinationPath)")
        }
        let data = try Data(contentsOf: sourceURL)
        guard String(data: data, encoding: .utf8) != nil else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace file is not valid UTF-8 text.")
        }
        let previousFiles = files
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        do {
            try await amberShellSyncFileRecord(
                path: destinationPath,
                file: destinationURL,
                source: "amber_shell_copy"
            )
        } catch {
            try amberShellRollback(after: error, restoring: previousFiles) {
                try fileManager.removeItem(at: destinationURL)
            }
        }
    }

    func amberShellMove(from source: String, to destination: String) async throws {
        try ensureDirectories()
        let sourcePath = try amberShellRelativePath(source, allowingRoot: false)
        let destinationPath = try amberShellRelativePath(destination, allowingRoot: false)
        let sourceURL = try amberShellURL(for: sourcePath, finalMayBeMissing: false)
        let destinationURL = try amberShellURL(for: destinationPath, finalMayBeMissing: true)
        try amberShellRequireRegularFile(at: sourceURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw IOSWorkspaceStoreError.writeWouldOverwrite("/workspace/\(destinationPath)")
        }
        let previousFiles = files
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        do {
            if let index = files.firstIndex(where: { $0.workspacePath == sourcePath }) {
                var record = files[index]
                record.workspacePath = destinationPath
                record.displayName = destinationURL.lastPathComponent
                files.remove(at: index)
                files.removeAll { $0.workspacePath == destinationPath }
                files.insert(record, at: 0)
            }
            try await amberShellSyncFileRecord(
                path: destinationPath,
                file: destinationURL,
                source: "amber_shell_move"
            )
        } catch {
            try amberShellRollback(after: error, restoring: previousFiles) {
                try fileManager.moveItem(at: destinationURL, to: sourceURL)
            }
        }
    }

    func amberShellRemove(path: String) throws {
        try ensureDirectories()
        let relativePath = try amberShellRelativePath(path, allowingRoot: false)
        let file = try amberShellURL(for: relativePath, finalMayBeMissing: false)
        try amberShellRequireRegularFile(at: file)
        let data = try Data(contentsOf: file)
        let previousModificationDate = try file.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let previousFiles = files
        try fileManager.removeItem(at: file)
        files.removeAll { $0.workspacePath == relativePath }
        do {
            try persist()
            publish()
        } catch {
            try amberShellRollback(after: error, restoring: previousFiles) {
                try data.write(to: file, options: [.atomic])
                if let previousModificationDate {
                    try fileManager.setAttributes([.modificationDate: previousModificationDate], ofItemAtPath: file.path)
                }
            }
        }
    }

    private func amberShellRelativePath(_ raw: String, allowingRoot: Bool) throws -> String {
        guard !raw.isEmpty,
              !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths must be canonical UTF-8 POSIX paths.")
        }

        let relative: String
        if raw == "/workspace" || raw == "/workspace/" {
            relative = ""
        } else if raw.hasPrefix("/workspace/") {
            relative = String(raw.dropFirst("/workspace/".count))
        } else if raw.hasPrefix("/") {
            throw IOSWorkspaceStoreError.invalidPath("Use a path under /workspace, not a host absolute path.")
        } else {
            relative = raw
        }

        var value = relative
        let hadPathComponent = !value.isEmpty
        if value.hasSuffix("/") {
            value.removeLast()
        }
        guard !hadPathComponent || !value.isEmpty else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot contain empty components.")
        }
        guard allowingRoot || !value.isEmpty else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace path is required.")
        }
        guard !value.hasSuffix("/") else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot contain empty components.")
        }
        if !value.isEmpty {
            let components = value.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot contain empty, . or .. components.")
            }
        }
        return value
    }

    private func amberShellURL(for relativePath: String, finalMayBeMissing: Bool) throws -> URL {
        let root = filesDirectory.standardizedFileURL
        let candidate = relativePath.isEmpty
            ? root
            : root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace path escapes /workspace.")
        }

        guard !amberShellIsSymbolicLink(root) else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot traverse symbolic links.")
        }
        let components = relativePath.split(separator: "/").map(String.init)
        var current = root
        for (index, component) in components.enumerated() {
            let next = current.appendingPathComponent(component, isDirectory: index < components.count - 1)
            guard next.standardizedFileURL.path == root.path || next.standardizedFileURL.path.hasPrefix(root.path + "/") else {
                throw IOSWorkspaceStoreError.invalidPath("Workspace path escapes /workspace.")
            }
            if amberShellIsSymbolicLink(next) {
                throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot traverse symbolic links.")
            }
            let exists = fileManager.fileExists(atPath: next.path)
            if !exists {
                guard finalMayBeMissing && index == components.count - 1 else {
                    throw IOSWorkspaceStoreError.missingFile
                }
                return candidate
            }
            if index < components.count - 1 {
                let values = try next.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw IOSWorkspaceStoreError.directorySelected
                }
            }
            current = next
        }
        return candidate
    }

    private func amberShellRequireRegularFile(at file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace paths cannot traverse symbolic links.")
        }
        guard values.isRegularFile == true else {
            if values.isDirectory == true {
                throw IOSWorkspaceStoreError.directorySelected
            }
            throw IOSWorkspaceStoreError.missingFile
        }
    }

    private func amberShellIsSymbolicLink(_ url: URL) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return true
        }
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }

    private func amberShellSyncFileRecord(path: String, file: URL, source: String) async throws {
        let now = Date()
        var record = files.first(where: { $0.workspacePath == path }) ?? IOSWorkspaceFileRecord(
            id: UUID().uuidString,
            displayName: file.lastPathComponent,
            originalFileName: file.lastPathComponent,
            workspacePath: path,
            mimeType: path.hasSuffix(".md") ? "text/markdown" : "text/plain",
            sizeBytes: Int64(Self.fileSize(for: file) ?? 0),
            importedAtMillis: Self.millis(now),
            updatedAtMillis: Self.millis(now),
            status: .ready,
            statusMessage: "",
            preview: "",
            isTruncated: false,
            characterCount: 0,
            source: source
        )
        record.displayName = file.lastPathComponent
        record.sizeBytes = Int64(Self.fileSize(for: file) ?? 0)
        record.updatedAtMillis = Self.millis(now)
        record.source = source
        record = await parsedRecord(record, now: now)
        files.removeAll { $0.id == record.id || $0.workspacePath == path }
        files.insert(record, at: 0)
        try persist()
        publish()
    }

    private func amberShellRollback(
        after originalError: Error,
        restoring previousFiles: [IOSWorkspaceFileRecord],
        _ rollback: () throws -> Void
    ) throws -> Never {
        files = previousFiles
        do {
            try rollback()
        } catch {
            throw IOSWorkspaceStoreError.storage(
                "Workspace update failed and its file rollback also failed: \(error.localizedDescription)"
            )
        }
        throw originalError
    }

    private func workspaceFileReadJSON(_ args: [String: Any]) async throws -> String {
        let raw = (args["file_id"] as? String)?.workspaceNilIfBlank
            ?? (args["path"] as? String)?.workspaceNilIfBlank
            ?? ""
        guard var record = fileRecord(idOrPath: raw) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        let hasLineRange = args["start_line"] != nil || args["end_line"] != nil
        let maxChars = ((args["max_chars"] as? Int) ?? 20_000).workspaceClamped(to: 1...80_000)
        if hasLineRange {
            let fileURL = fileURL(for: record)
            let source = try Self.readWorkspaceFileLines(
                from: fileURL,
                startLine: args["start_line"],
                endLine: args["end_line"],
                maxChars: maxChars
            )
            return Self.json([
                "ok": true,
                "id": record.id,
                "path": "/workspace/\(record.workspacePath)",
                "name": record.displayName,
                "mime_type": record.mimeType,
                "size_bytes": record.sizeBytes,
                "status": record.status.rawValue,
                "message": record.statusMessage,
                "text": source.text,
                "text_chars": source.selectedCharacterCount,
                "truncated": source.truncated,
                "start_line": source.startLine,
                "end_line": source.endLine,
                "total_lines": source.totalLines
            ])
        }
        if record.status != .ready || record.preview.isEmpty {
            record = try await reparseFile(id: record.id)
        }
        return Self.json([
            "ok": record.status == .ready,
            "id": record.id,
            "path": "/workspace/\(record.workspacePath)",
            "name": record.displayName,
            "mime_type": record.mimeType,
            "size_bytes": record.sizeBytes,
            "status": record.status.rawValue,
            "message": record.statusMessage,
            "text": String(record.preview.prefix(maxChars)),
            "text_chars": record.characterCount,
            "truncated": record.isTruncated || record.preview.count > maxChars
        ])
    }

    private struct WorkspaceFileLineRead {
        let text: String
        let selectedCharacterCount: Int
        let truncated: Bool
        let startLine: Int
        let endLine: Int
        let totalLines: Int
    }

    private static func readWorkspaceFileLines(
        from url: URL,
        startLine rawStartLine: Any?,
        endLine rawEndLine: Any?,
        maxChars: Int
    ) throws -> WorkspaceFileLineRead {
        let source = try String(contentsOf: url, encoding: .utf8)
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x0A: // LF
                lineStarts.append(index + 1)
            case 0x0D: // CR or CRLF
                lineStarts.append(index + (index + 1 < bytes.count && bytes[index + 1] == 0x0A ? 2 : 1))
                if index + 1 < bytes.count && bytes[index + 1] == 0x0A {
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        let totalLines = bytes.isEmpty
            ? 0
            : (lineStarts.last == bytes.count ? lineStarts.count - 1 : lineStarts.count)
        let startLine = try Self.workspaceLineNumber(rawStartLine, name: "start_line", defaultValue: 1)
        let endLine = try Self.workspaceLineNumber(rawEndLine, name: "end_line", defaultValue: totalLines)
        guard totalLines > 0, startLine <= totalLines, endLine <= totalLines, startLine <= endLine else {
            throw IOSWorkspaceStoreError.invalidPath(
                "start_line/end_line must select an existing 1-based inclusive line range (total_lines=\(totalLines))."
            )
        }

        let startByte = lineStarts[startLine - 1]
        let endByte = endLine < lineStarts.count ? lineStarts[endLine] : bytes.count
        let selected = String(decoding: bytes[startByte..<endByte], as: UTF8.self)
        let returned = String(selected.prefix(maxChars))
        let selectedCharacterCount = selected.count
        let returnedEndByte = startByte + returned.utf8.count
        var returnedEndLine = startLine
        while returnedEndLine < endLine,
              lineStarts[returnedEndLine] < returnedEndByte {
            returnedEndLine += 1
        }
        return WorkspaceFileLineRead(
            text: returned,
            selectedCharacterCount: selectedCharacterCount,
            truncated: selectedCharacterCount > maxChars,
            startLine: startLine,
            endLine: returnedEndLine,
            totalLines: totalLines
        )
    }

    private static func workspaceLineNumber(
        _ rawValue: Any?,
        name: String,
        defaultValue: Int
    ) throws -> Int {
        guard let rawValue else { return defaultValue }
        guard let value = rawValue as? Int, value >= 1 else {
            throw IOSWorkspaceStoreError.invalidPath("\(name) must be a positive integer.")
        }
        return value
    }

    private func workspaceFileWriteJSON(_ args: [String: Any]) async throws -> String {
        let path = try normalizeWorkspacePath((args["path"] as? String) ?? "")
        let content = (args["content"] as? String) ?? ""
        let overwrite = (args["overwrite"] as? Bool) ?? false
        let url = fileURL(forWorkspacePath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path), !overwrite {
            throw IOSWorkspaceStoreError.writeWouldOverwrite("/workspace/\(path)")
        }
        try Data(content.utf8).write(to: url, options: [.atomic])
        let now = Date()
        let mime = path.hasSuffix(".md") ? "text/markdown" : "text/plain"
        var record = files.first(where: { $0.workspacePath == path }) ?? IOSWorkspaceFileRecord(
            id: UUID().uuidString,
            displayName: path.components(separatedBy: "/").last ?? path,
            originalFileName: path.components(separatedBy: "/").last ?? path,
            workspacePath: path,
            mimeType: mime,
            sizeBytes: Int64(content.utf8.count),
            importedAtMillis: Self.millis(now),
            updatedAtMillis: Self.millis(now),
            status: .ready,
            statusMessage: "",
            preview: "",
            isTruncated: false,
            characterCount: 0,
            source: "tool_write"
        )
        record.sizeBytes = Int64(content.utf8.count)
        record.updatedAtMillis = Self.millis(now)
        record = await parsedRecord(record, now: now)
        files.removeAll { $0.id == record.id || $0.workspacePath == record.workspacePath }
        files.insert(record, at: 0)
        try persist()
        publish()
        return Self.json([
            "ok": true,
            "id": record.id,
            "path": "/workspace/\(record.workspacePath)",
            "size_bytes": record.sizeBytes
        ])
    }

    /// Exact replacement follows the unique-match contract of Claude's text editor;
    /// a global replacement must be explicitly requested by the caller.
    private func workspaceFileEditJSON(_ args: [String: Any]) async throws -> String {
        let raw = (args["file_id"] as? String)?.workspaceNilIfBlank
            ?? (args["path"] as? String)?.workspaceNilIfBlank
            ?? ""
        guard let record = fileRecord(idOrPath: raw) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        guard let find = args["find"] as? String, !find.isEmpty,
              let replace = args["replace"] as? String else {
            return Self.json(["ok": false, "changed": false, "error": "file_edit requires non-empty 'find' and a 'replace' string (which may be empty)."])
        }
        let replaceAll = (args["replace_all"] as? Bool) ?? false
        let url = fileURL(for: record)
        // Extracted/truncated previews are never a valid source for overwriting a file.
        let original = try String(contentsOf: url, encoding: .utf8)
        let originalBytes = Data(original.utf8)
        let findBytes = Data(find.utf8)
        var cursor = originalBytes.startIndex
        var occurrences = 0
        var matchedLines: [Int] = []
        var line = 1
        while let match = originalBytes.range(of: findBytes, in: cursor..<originalBytes.endIndex) {
            line += originalBytes[cursor..<match.lowerBound].filter { $0 == 10 }.count
            occurrences += 1
            if matchedLines.count < 20, matchedLines.last != line { matchedLines.append(line) }
            line += originalBytes[match].filter { $0 == 10 }.count
            cursor = match.upperBound
        }
        if occurrences == 0 {
            return Self.json([
                "ok": false, "changed": false, "replacements": 0, "match_count": 0,
                "error": "No exact match found. Read the current file and copy the original text, including whitespace and newlines, before retrying."
            ])
        }
        if occurrences > 1, !replaceAll {
            return Self.json([
                "ok": false, "changed": false, "replacements": 0, "match_count": occurrences,
                "matched_lines": matchedLines,
                "error": "Found \(occurrences) exact matches; file unchanged. Include more surrounding context in 'find' to identify one location, or set replace_all=true for an intentional global replacement."
            ])
        }
        let edited = original.replacingOccurrences(of: find, with: replace, options: .literal)
        guard !original.utf8.elementsEqual(edited.utf8) else {
            return Self.json([
                "ok": true, "changed": false, "id": record.id,
                "path": "/workspace/\(record.workspacePath)", "replacements": 0,
                "match_count": occurrences, "message": "Replacement is identical to the original text; file unchanged."
            ])
        }
        let diff = Self.workspaceEditDiffPreview(original: original, edited: edited, path: record.workspacePath)
        try Data(edited.utf8).write(to: url, options: [.atomic])
        let now = Date()
        var updated = record
        updated.sizeBytes = Int64(edited.utf8.count)
        updated.updatedAtMillis = Self.millis(now)
        updated = await parsedRecord(updated, now: now)
        files.removeAll { $0.id == updated.id }
        files.insert(updated, at: 0)
        try persist()
        publish()
        return Self.json([
            "ok": true,
            "id": updated.id,
            "path": "/workspace/\(updated.workspacePath)",
            "changed": true,
            "replacements": occurrences,
            "size_bytes": updated.sizeBytes,
            "matched_lines": matchedLines,
            "diff_preview": diff.text,
            "diff_truncated": diff.truncated
        ])
    }

    /// Use the standard library's line diff on a bounded window around the changes.
    /// This is review output, not a patch protocol; large edits report truncation.
    private static func workspaceEditDiffPreview(
        original: String, edited: String, path: String
    ) -> (text: String, truncated: Bool) {
        let before = original.components(separatedBy: "\n")
        let after = edited.components(separatedBy: "\n")
        var first = 0
        while first < min(before.count, after.count), before[first].utf8.elementsEqual(after[first].utf8) {
            first += 1
        }
        var oldEnd = before.count
        var newEnd = after.count
        while oldEnd > first, newEnd > first,
              before[oldEnd - 1].utf8.elementsEqual(after[newEnd - 1].utf8) {
            oldEnd -= 1
            newEnd -= 1
        }
        let start = max(0, first - 2)
        let oldLimit = min(before.count, oldEnd + 2)
        let newLimit = min(after.count, newEnd + 2)
        guard oldLimit - start <= 120, newLimit - start <= 120 else {
            return ("Diff preview omitted: changes span more than 120 lines. Read the edited file by line range to verify the result.", true)
        }
        let oldLines = Array(before[start..<oldLimit])
        let newLines = Array(after[start..<newLimit])
        var truncated = false
        // Data equality preserves exact UTF-8 differences, including Unicode normalization.
        let difference = newLines.map { Data($0.utf8) }.difference(from: oldLines.map { Data($0.utf8) })
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var text = "--- /workspace/\(path)\n+++ /workspace/\(path)\n@@ -\(start + 1),\(oldLines.count) +\(start + 1),\(newLines.count) @@\n"
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            let row: String
            if removed.contains(oldIndex), oldIndex < oldLines.count {
                row = "-" + oldLines[oldIndex]
                oldIndex += 1
            } else if inserted.contains(newIndex), newIndex < newLines.count {
                row = "+" + newLines[newIndex]
                newIndex += 1
            } else {
                row = " " + oldLines[oldIndex]
                oldIndex += 1
                newIndex += 1
            }
            let remaining = 8_000 - text.count
            guard remaining > row.count else {
                text += String(row.prefix(max(0, remaining)))
                truncated = true
                break
            }
            text += row + "\n"
        }
        return (text, truncated)
    }

    /// file_list: lists workspace files (optionally under a sub-path) with
    /// metadata. Android WorkspaceTools.file_list parity.
    private func workspaceFileListJSON(_ args: [String: Any]) throws -> String {
        let prefix = (args["path"] as? String)?.workspaceNilIfBlank
        let matching = files.filter { record in
            guard let prefix else { return true }
            return record.workspacePath.hasPrefix(prefix) || "/workspace/\(record.workspacePath)".hasPrefix(prefix)
        }
        let items = matching.map { record -> [String: Any] in
            [
                "id": record.id,
                "path": "/workspace/\(record.workspacePath)",
                "name": record.displayName,
                "size_bytes": record.sizeBytes,
                "mime_type": record.mimeType,
                "status": record.status.rawValue,
                "updated_at": record.updatedAtMillis
            ]
        }
        return Self.json(["ok": true, "count": items.count, "files": items])
    }

    /// file_search: content search across workspace files; returns matching
    /// files + snippet. Android WorkspaceTools.file_search parity.
    private func workspaceFileSearchJSON(_ args: [String: Any]) async throws -> String {
        let query = (args["query"] as? String) ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(["ok": false, "error": "file_search requires a non-empty 'query'."])
        }
        var hits: [[String: Any]] = []
        for record in files where record.status == .ready {
            let content = record.preview
            guard let range = content.range(of: query, options: .caseInsensitive) else { continue }
            let lower = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
            let upper = content.index(range.upperBound, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
            let snippet = String(content[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
            hits.append([
                "id": record.id,
                "path": "/workspace/\(record.workspacePath)",
                "name": record.displayName,
                "snippet": snippet
            ])
        }
        return Self.json(["ok": true, "query": query, "matches": hits.count, "results": hits])
    }

    /// file_move: rename/move a workspace file to a new path. Android
    /// WorkspaceTools.file_move parity.
    private func workspaceFileMoveJSON(_ args: [String: Any]) async throws -> String {
        let raw = (args["file_id"] as? String)?.workspaceNilIfBlank
            ?? (args["path"] as? String)?.workspaceNilIfBlank
            ?? ""
        guard var record = fileRecord(idOrPath: raw) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        let destPath = try normalizeWorkspacePath((args["destination_path"] as? String) ?? "")
        guard !destPath.isEmpty, destPath != record.workspacePath else {
            return Self.json(["ok": false, "error": "file_move requires a non-empty, different 'destination_path'."])
        }
        let sourceURL = fileURL(for: record)
        let destURL = fileURL(forWorkspacePath: destPath)
        if fileManager.fileExists(atPath: destURL.path) {
            return Self.json(["ok": false, "error": "A file already exists at \(destPath)."])
        }
        try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: destURL)
        record.workspacePath = destPath
        record.displayName = destPath.components(separatedBy: "/").last ?? destPath
        record.updatedAtMillis = Self.millis(Date())
        files.removeAll { $0.id == record.id }
        files.insert(record, at: 0)
        try persist()
        publish()
        return Self.json([
            "ok": true,
            "id": record.id,
            "path": "/workspace/\(record.workspacePath)"
        ])
    }

    private func workspaceArtifactReadJSON(_ args: [String: Any]) throws -> String {
        guard let id = (args["artifact_id"] as? String)?.workspaceNilIfBlank ?? (args["id"] as? String)?.workspaceNilIfBlank,
              let record = artifacts.first(where: { $0.id == id }) else {
            throw IOSWorkspaceStoreError.missingArtifact
        }
        let content = try artifactContent(id: record.id)
        return Self.json([
            "ok": true,
            "id": record.id,
            "title": record.title,
            "type": record.type.rawValue,
            "source_kind": record.sourceKind,
            "content": content,
            "content_bytes": record.contentBytes
        ])
    }

    private func workspaceArtifactDeleteJSON(_ args: [String: Any]) throws -> String {
        guard let id = (args["artifact_id"] as? String)?.workspaceNilIfBlank ?? (args["id"] as? String)?.workspaceNilIfBlank else {
            throw IOSWorkspaceStoreError.missingArtifact
        }
        try deleteArtifact(id: id)
        return Self.json(["ok": true, "id": id, "deleted": true])
    }

    private func parsedRecord(_ record: IOSWorkspaceFileRecord, now: Date) async -> IOSWorkspaceFileRecord {
        var next = record
        let url = fileURL(forWorkspacePath: record.workspacePath)
        guard fileManager.fileExists(atPath: url.path) else {
            next.status = .missing
            next.statusMessage = "The copied Workspace file is missing. Import it again."
            next.updatedAtMillis = Self.millis(now)
            return next
        }
        let parseResult = await DocumentAccessStore.previewFileForWorkspace(
            url: url,
            fileType: record.mimeType,
            maxReadableBytes: maxImportBytes,
            maxPreviewBytes: 64 * 1024,
            maxPreviewCharacters: maxPreviewCharacters
        )
        switch parseResult {
        case .success(let preview):
            next.status = .ready
            next.statusMessage = preview.statusSummary
            next.preview = preview.preview
            next.isTruncated = preview.isTruncated
            next.characterCount = preview.characterCount
            next.sizeBytes = preview.totalBytes
        case .failure(let error):
            let accessError = (error as? DocumentAccessError) ?? .readFailed(error.localizedDescription)
            next.status = Self.workspaceStatus(for: accessError)
            next.statusMessage = accessError.userMessage
            next.preview = ""
            next.isTruncated = false
            next.characterCount = 0
        }
        next.updatedAtMillis = Self.millis(now)
        return next
    }

    private func normalizeWorkspacePath(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/workspace/") {
            value.removeFirst("/workspace/".count)
        } else if value == "/workspace" {
            value = ""
        }
        value = value.replacingOccurrences(of: "\\", with: "/")
        guard !value.isEmpty else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace path is required.")
        }
        guard !value.hasPrefix("/") && !value.contains(":") else {
            throw IOSWorkspaceStoreError.invalidPath("Use a path under /workspace, not an absolute system path.")
        }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IOSWorkspaceStoreError.invalidPath("Workspace path cannot contain traversal segments.")
        }
        return parts.joined(separator: "/")
    }

    private func fileURL(forWorkspacePath path: String) -> URL {
        filesDirectory.appendingPathComponent(path, isDirectory: false)
    }

    private func startScopedAccessIfNeeded(_ url: URL) throws -> Bool {
        guard !Self.isInsideAppContainer(url) else { return false }
        let started = url.startAccessingSecurityScopedResource()
        guard started else {
            throw IOSWorkspaceStoreError.accessDenied("iOS did not grant access to this file. Reopen it from Files and try again.")
        }
        return true
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
    }

    private func persist() throws {
        try ensureDirectories()
        let state = IOSWorkspaceState(files: files, artifacts: artifacts)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private func publish() {
        errorMessage = nil
        revision &+= 1
    }

    private static func workspaceStatus(for error: DocumentAccessError) -> IOSWorkspaceFileStatus {
        switch error {
        case .fileTooLarge:
            .tooLarge
        case .missingGrant, .expiredGrant:
            .needsReauthorization
        case .unsupportedFileType, .noReadableText:
            .unsupported
        case .readFailed(let message) where message.localizedCaseInsensitiveContains("exist") || message.localizedCaseInsensitiveContains("missing"):
            .missing
        default:
            .parseFailed
        }
    }

    private static func isInsideAppContainer(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(NSHomeDirectory()) || path.hasPrefix(NSTemporaryDirectory())
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).workspaceNilIfBlank ?? "file"
    }

    private static func summary(_ text: String, maxLength: Int = 240) -> String {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count > maxLength ? String(compact.prefix(maxLength)) + "..." : compact
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func fileSize(for url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"Unable to encode Workspace JSON."}"#
        }
        return text
    }
}

private extension String {
    var workspaceNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Comparable {
    func workspaceClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
@Observable
final class DocumentAccessStore {
    fileprivate var grant: SelectedDocumentGrant?
    private(set) var lastRead: SelectedDocumentReadResult?
    private(set) var errorMessage: String?
    private(set) var isReading: Bool = false

    let ttlSeconds: TimeInterval = 10 * 60
    let maxUses = 1
    let maxReadableBytes: Int64 = 20 * 1024 * 1024
    let maxPreviewBytes = 64 * 1024
    let maxPreviewCharacters = 60_000

    var grantSummary: SelectedDocumentGrantSummary? {
        grant.map { current in
            SelectedDocumentGrantSummary(
                id: current.id,
                capabilityId: current.capabilityId,
                toolName: current.toolName,
                operation: current.operation,
                fileName: current.fileName,
                fileType: current.fileType,
                fileSize: current.fileSize,
                scopeDigest: current.scopeDigest,
                payloadDigest: current.payloadDigest,
                createdAt: current.createdAt,
                expiresAt: current.expiresAt,
                maxUses: current.maxUses,
                usedCount: current.usedCount
            )
        }
    }

    @discardableResult
    func registerPickedFile(_ url: URL, now: Date = Date()) -> SelectedDocumentGrant {
        errorMessage = nil
        lastRead = nil

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedTypeDescriptionKey])
        let fileSize = Int64(values?.fileSize ?? Self.fileSize(for: url) ?? 0)
        let contentType = values?.contentType?.preferredMIMEType
            ?? values?.contentType?.identifier
            ?? values?.localizedTypeDescription
            ?? "unknown"
        let scopeDigest = Self.scopeDigest(for: url)
        let payloadDigest = Self.payloadDigest(
            toolName: "file_read_selected",
            operation: "read_preview",
            scopeDigest: scopeDigest
        )

        let newGrant = SelectedDocumentGrant(
            id: UUID().uuidString,
            capabilityId: "ios.files.selected_read",
            toolName: "file_read_selected",
            operation: "read_preview",
            fileName: url.lastPathComponent,
            fileType: contentType,
            fileSize: fileSize,
            scopeDigest: scopeDigest,
            payloadDigest: payloadDigest,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds),
            maxUses: maxUses,
            usedCount: 0,
            url: url
        )
        grant = newGrant
        return newGrant
    }

    func readSelectedDocumentForDeepRead(now: Date = Date()) async -> Result<IOSDeepReadSource, DocumentAccessError> {
        let request = requestForCurrentGrant(isUserInitiated: true)
        let result = await consumeSelectedFileRead(request: request, now: now)
        switch result {
        case .success(let read):
            do {
                return .success(try IOSDeepReadSourceNormalizer.fileSource(
                    read,
                    now: Int64(now.timeIntervalSince1970 * 1_000)
                ))
            } catch let error as IOSDeepReadSourceNormalizationError {
                return .failure(.unsupportedFileType(error.localizedDescription))
            } catch {
                return .failure(.readFailed(error.localizedDescription))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    func recordSelectionError(_ message: String) {
        grant = nil
        lastRead = nil
        errorMessage = message
    }

    func requestForCurrentGrant(isUserInitiated: Bool) -> IOSToolInvocationRequest {
        guard let current = grant else {
            return IOSToolInvocationRequest(
                toolName: "file_read_selected",
                operation: "read_preview",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: isUserInitiated
            )
        }

        return IOSToolInvocationRequest(
            toolName: current.toolName,
            operation: current.operation,
            scopeDigest: current.scopeDigest,
            payloadDigest: current.payloadDigest,
            isUserInitiated: isUserInitiated
        )
    }

    fileprivate func consumeSelectedFileRead(request: IOSToolInvocationRequest, now: Date = Date()) async -> Result<SelectedDocumentReadResult, DocumentAccessError> {
        guard let current = grant else {
            errorMessage = "Choose a file before reading."
            return .failure(.missingGrant)
        }
        guard current.toolName == request.toolName,
              current.operation == request.operation,
              current.scopeDigest == request.scopeDigest,
              current.payloadDigest == request.payloadDigest else {
            errorMessage = "The selected-file grant does not match this request."
            return .failure(.grantMismatch)
        }
        guard !current.isExpired(now: now) else {
            grant = nil
            lastRead = nil
            errorMessage = "The in-memory file grant expired. Choose the file again."
            return .failure(.expiredGrant)
        }
        guard current.fileSize <= maxReadableBytes else {
            errorMessage = "Selected file is larger than the file-context import limit of \(Self.formatBytes(maxReadableBytes))."
            return .failure(.fileTooLarge)
        }
        guard !isReading else {
            return .failure(.alreadyReading)
        }

        isReading = true
        errorMessage = nil
        let grantId = current.id
        let url = current.url
        let fileType = current.fileType
        let maxReadableBytes = maxReadableBytes
        let maxPreviewBytes = maxPreviewBytes
        let maxPreviewCharacters = maxPreviewCharacters

        let result = await Self.readPreview(
            url: url,
            fileType: fileType,
            maxReadableBytes: maxReadableBytes,
            maxPreviewBytes: maxPreviewBytes,
            maxPreviewCharacters: maxPreviewCharacters
        )
        guard var latest = grant, latest.id == grantId else {
            isReading = false
            return .failure(.grantMismatch)
        }
        switch result {
        case .success(let readResult):
            latest.usedCount += 1
            grant = latest
            lastRead = readResult
            errorMessage = nil
            isReading = false
            return .success(readResult)
        case .failure(let error):
            let accessError = (error as? DocumentAccessError) ?? .readFailed(error.localizedDescription)
            if accessError.clearsSelectedGrant {
                grant = nil
                lastRead = nil
            }
            errorMessage = accessError.userMessage
            isReading = false
            return .failure(accessError)
        }
    }

    static func previewFileForWorkspace(
        url: URL,
        fileType: String,
        maxReadableBytes: Int64,
        maxPreviewBytes: Int,
        maxPreviewCharacters: Int
    ) async -> Result<SelectedDocumentReadResult, Error> {
        await readPreview(
            url: url,
            fileType: fileType,
            maxReadableBytes: maxReadableBytes,
            maxPreviewBytes: maxPreviewBytes,
            maxPreviewCharacters: maxPreviewCharacters
        )
    }

    private static func readPreview(
        url: URL,
        fileType: String,
        maxReadableBytes: Int64,
        maxPreviewBytes: Int,
        maxPreviewCharacters: Int
    ) async -> Result<SelectedDocumentReadResult, Error> {
        await Task.detached(priority: .utility) {
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return Result<SelectedDocumentReadResult, Error>.failure(DocumentAccessError.fileMissing)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
                    return Result<SelectedDocumentReadResult, Error>.failure(DocumentAccessError.unknownFileSize)
                }
                guard fileSize <= maxReadableBytes else {
                    return Result<SelectedDocumentReadResult, Error>.failure(DocumentAccessError.fileTooLarge)
                }
                let kind = selectedDocumentKind(url: url, fileType: fileType)
                switch kind {
                case .text:
                    let result = try readTextPreview(
                        url: url,
                        fileType: fileType,
                        fileSize: fileSize,
                        maxPreviewBytes: maxPreviewBytes,
                        maxPreviewCharacters: maxPreviewCharacters
                    )
                    return .success(result)
                case .pdf:
                    let result = try readPDFPreview(
                        url: url,
                        fileType: fileType,
                        fileSize: fileSize,
                        maxPreviewCharacters: maxPreviewCharacters
                    )
                    return .success(result)
                case .docx:
                    let result = try readDocxPreview(
                        url: url,
                        fileType: fileType,
                        fileSize: fileSize,
                        maxPreviewCharacters: maxPreviewCharacters
                    )
                    return .success(result)
                case .pptx:
                    let result = try readPptxPreview(
                        url: url,
                        fileType: fileType,
                        fileSize: fileSize,
                        maxPreviewCharacters: maxPreviewCharacters
                    )
                    return .success(result)
                case .image:
                    return .failure(DocumentAccessError.unsupportedFileType("图片文件暂不能作为文本上下文读取；iOS 端不会假装 OCR。"))
                case .unsupported:
                    return .failure(DocumentAccessError.unsupportedFileType("暂不支持此文件类型的文本上下文。支持 txt、md、json、csv、pdf、docx、pptx。"))
                }
            } catch {
                return Result<SelectedDocumentReadResult, Error>.failure(error)
            }
        }.value
    }

    private enum SelectedDocumentKind {
        case text
        case pdf
        case docx
        case pptx
        case image
        case unsupported
    }

    nonisolated private static func selectedDocumentKind(url: URL, fileType: String) -> SelectedDocumentKind {
        let ext = url.pathExtension.lowercased()
        if ["txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "html", "htm", "yaml", "yml"].contains(ext) {
            return .text
        }
        if ext == "pdf" { return .pdf }
        if ext == "docx" { return .docx }
        if ext == "pptx" { return .pptx }

        let lowerType = fileType.lowercased()
        if lowerType.contains("pdf") { return .pdf }
        if lowerType.contains("wordprocessingml.document") || lowerType.contains("officedocument.wordprocessingml") {
            return .docx
        }
        if lowerType.contains("presentationml.presentation") || lowerType.contains("officedocument.presentationml") {
            return .pptx
        }
        if lowerType.hasPrefix("text/") ||
            lowerType.contains("json") ||
            lowerType.contains("csv") ||
            lowerType.contains("markdown") {
            return .text
        }
        if lowerType.hasPrefix("image/") {
            return .image
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) {
                return .text
            }
            if type.conforms(to: .image) { return .image }
        }
        return .unsupported
    }

    nonisolated private static func readTextPreview(
        url: URL,
        fileType: String,
        fileSize: Int64,
        maxPreviewBytes: Int,
        maxPreviewCharacters: Int
    ) throws -> SelectedDocumentReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxPreviewBytes + 1) ?? Data()
        let truncatedByBytes = data.count > maxPreviewBytes || fileSize > Int64(maxPreviewBytes)
        let previewData = data.prefix(maxPreviewBytes)
        guard let decoded = decodeText(previewData) else {
            throw DocumentAccessError.unsupportedFileType("此文件不是可解码的文本，无法作为文件上下文读取。")
        }
        return buildReadResult(
            fileName: url.lastPathComponent,
            fileType: fileType,
            fileSize: fileSize,
            bytesRead: previewData.count,
            text: decoded,
            truncatedBySource: truncatedByBytes,
            maxPreviewBytes: maxPreviewBytes,
            maxPreviewCharacters: maxPreviewCharacters
        )
    }

    nonisolated private static func readPDFPreview(
        url: URL,
        fileType: String,
        fileSize: Int64,
        maxPreviewCharacters: Int
    ) throws -> SelectedDocumentReadResult {
        guard let document = PDFDocument(url: url) else {
            throw DocumentAccessError.unsupportedFileType("无法打开此 PDF 文件。")
        }
        var chunks: [String] = []
        var truncated = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            chunks.append(text)
            if chunks.joined(separator: "\n\n").count > maxPreviewCharacters {
                truncated = true
                break
            }
        }
        let text = chunks.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAccessError.noReadableText("PDF 中没有可提取文本；扫描版 PDF 需要 OCR，iOS 文件上下文暂不假装 OCR。")
        }
        return buildReadResult(
            fileName: url.lastPathComponent,
            fileType: fileType,
            fileSize: fileSize,
            bytesRead: Int(fileSize),
            text: text,
            truncatedBySource: truncated,
            maxPreviewBytes: Int(fileSize),
            maxPreviewCharacters: maxPreviewCharacters
        )
    }

    nonisolated private static func readDocxPreview(
        url: URL,
        fileType: String,
        fileSize: Int64,
        maxPreviewCharacters: Int
    ) throws -> SelectedDocumentReadResult {
        let data = try Data(contentsOf: url)
        let entryNames = ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"]
        let xmlTexts = try entryNames.compactMap { name -> String? in
            guard let entryData = try IOSDocumentZipReader.entry(named: name, in: data) else { return nil }
            return String(data: entryData, encoding: .utf8)
        }
        guard !xmlTexts.isEmpty else {
            throw DocumentAccessError.noReadableText("DOCX 中没有找到 word/document.xml，无法提取正文。")
        }
        let text = xmlTexts
            .map(extractDocxText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAccessError.noReadableText("DOCX 正文为空，或当前文档结构暂不支持文本提取。")
        }
        return buildReadResult(
            fileName: url.lastPathComponent,
            fileType: fileType,
            fileSize: fileSize,
            bytesRead: Int(fileSize),
            text: text,
            truncatedBySource: text.count > maxPreviewCharacters,
            maxPreviewBytes: Int(fileSize),
            maxPreviewCharacters: maxPreviewCharacters
        )
    }

    /// Extracts text from a PPTX. Slides live at `ppt/slides/slide{N}.xml`;
    /// the visible text is in `<a:t>` elements (the DrawingML text-run tag),
    /// analogous to DOCX's `<w:t>`. Android parity for `PptxParser`.
    nonisolated private static func readPptxPreview(
        url: URL,
        fileType: String,
        fileSize: Int64,
        maxPreviewCharacters: Int
    ) throws -> SelectedDocumentReadResult {
        let data = try Data(contentsOf: url)
        // Discover slide entries (variable count) in presentation order.
        let slideNames = try IOSDocumentZipReader.entryNames(matchingPrefix: "ppt/slides/slide", in: data)
            .filter { $0.hasSuffix(".xml") }
        guard !slideNames.isEmpty else {
            throw DocumentAccessError.noReadableText("PPTX 中没有找到 ppt/slides/slideN.xml，无法提取幻灯片文本。")
        }
        var slideTexts: [String] = []
        for (index, name) in slideNames.enumerated() {
            guard let entryData = try IOSDocumentZipReader.entry(named: name, in: data),
                  let xml = String(data: entryData, encoding: .utf8) else { continue }
            let slideText = extractPptxText(xml)
            if !slideText.isEmpty {
                slideTexts.append("[Slide \(index + 1)]\n\(slideText)")
            }
        }
        let text = slideTexts.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAccessError.noReadableText("PPTX 幻灯片正文为空，或当前文档结构暂不支持文本提取。")
        }
        return buildReadResult(
            fileName: url.lastPathComponent,
            fileType: fileType,
            fileSize: fileSize,
            bytesRead: Int(fileSize),
            text: text,
            truncatedBySource: text.count > maxPreviewCharacters,
            maxPreviewBytes: Int(fileSize),
            maxPreviewCharacters: maxPreviewCharacters
        )
    }

    nonisolated private static func buildReadResult(
        fileName: String,
        fileType: String,
        fileSize: Int64,
        bytesRead: Int,
        text: String,
        truncatedBySource: Bool,
        maxPreviewBytes: Int,
        maxPreviewCharacters: Int
    ) -> SelectedDocumentReadResult {
        let normalized = normalizeExtractedText(text)
        guard !normalized.isEmpty else {
            return SelectedDocumentReadResult(
                fileName: fileName,
                fileType: fileType,
                totalBytes: fileSize,
                bytesRead: bytesRead,
                characterCount: 0,
                preview: "",
                isTruncated: false,
                note: "文件中没有可读取文本。"
            )
        }
        let truncatedByCharacters = normalized.count > maxPreviewCharacters
        let preview = truncatedByCharacters ? String(normalized.prefix(maxPreviewCharacters)) : normalized
        let isTruncated = truncatedBySource || truncatedByCharacters
        let note = isTruncated
            ? "内容已截断：最多读取 \(formatBytes(Int64(maxPreviewBytes))) / \(maxPreviewCharacters) 字符。"
            : nil
        return SelectedDocumentReadResult(
            fileName: fileName,
            fileType: fileType,
            totalBytes: fileSize,
            bytesRead: bytesRead,
            characterCount: preview.count,
            preview: preview,
            isTruncated: isTruncated,
            note: note
        )
    }

    nonisolated private static func decodeText(_ data: Data.SubSequence) -> String? {
        let value = Data(data)
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .ascii]
        for encoding in encodings {
            if let text = String(data: value, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    nonisolated private static func normalizeExtractedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func extractDocxText(_ xml: String) -> String {
        var prepared = xml
            .replacingOccurrences(of: "<w:tab/>", with: "<w:t>\t</w:t>")
            .replacingOccurrences(of: "<w:tab />", with: "<w:t>\t</w:t>")
            .replacingOccurrences(of: "<w:br/>", with: "<w:t>\n</w:t>")
            .replacingOccurrences(of: "<w:br />", with: "<w:t>\n</w:t>")
            .replacingOccurrences(of: "</w:p>", with: "<w:t>\n</w:t>")
        prepared = prepared.replacingOccurrences(of: "</w:tr>", with: "<w:t>\n</w:t>")

        let pattern = #"<w:t(?:\s[^>]*)?>(.*?)</w:t>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return ""
        }
        let matches = regex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared))
        let pieces = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: prepared) else {
                return nil
            }
            return decodeXMLEntities(String(prepared[range]))
        }
        return normalizeExtractedText(pieces.joined())
    }

    /// Extracts visible text from a PPTX slide XML. DrawingML text runs are in
    /// `<a:t>` elements; `</a:p>` marks paragraph breaks (analogous to DOCX
    /// `<w:t>` / `</w:p>`). Mirrors `extractDocxText`.
    nonisolated private static func extractPptxText(_ xml: String) -> String {
        // Paragraph-end → newline so each text block sits on its own line.
        let prepared = xml.replacingOccurrences(of: "</a:p>", with: "<a:t>\n</a:t>")
        let pattern = #"<a:t(?:\s[^>]*)?>(.*?)</a:t>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return ""
        }
        let matches = regex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared))
        let pieces = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: prepared) else {
                return nil
            }
            return decodeXMLEntities(String(prepared[range]))
        }
        return normalizeExtractedText(pieces.joined())
    }

    nonisolated private static func decodeXMLEntities(_ text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return decoded }
        for match in regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded) else {
                continue
            }
            let value = String(decoded[valueRange])
            let radix = value.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(value.dropFirst()) : value
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return decoded
    }

    nonisolated private static func fileSize(for url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let units: ByteCountFormatStyle.Units = bytes >= 1024 * 1024 ? [.mb] : [.kb, .bytes]
        return bytes.formatted(
            .byteCount(style: .file, allowedUnits: units)
                .locale(IOSAppLanguagePreference.selected().resolvedLocale())
        )
    }

    static func scopeDigest(for url: URL) -> String {
        let canonical = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func payloadDigest(toolName: String, operation: String, scopeDigest: String) -> String {
        let payload = "\(toolName)\n\(operation)\n\(scopeDigest)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct IOSDocumentZipReader {
    static func entry(named expectedName: String, in data: Data) throws -> Data? {
        guard let eocd = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else {
            throw DocumentAccessError.unsupportedFileType("DOCX 不是有效的 ZIP 文档。")
        }
        let entryCount = Int(try data.doc_uint16LE(at: eocd + 10))
        let centralOffset = Int(try data.doc_uint32LE(at: eocd + 16))
        var cursor = centralOffset

        for _ in 0..<entryCount {
            guard try data.doc_uint32LE(at: cursor) == 0x02014b50 else {
                throw DocumentAccessError.unsupportedFileType("DOCX ZIP 中央目录损坏。")
            }
            let method = try data.doc_uint16LE(at: cursor + 10)
            let compressedSize = Int(try data.doc_uint32LE(at: cursor + 20))
            let uncompressedSize = Int(try data.doc_uint32LE(at: cursor + 24))
            let nameLength = Int(try data.doc_uint16LE(at: cursor + 28))
            let extraLength = Int(try data.doc_uint16LE(at: cursor + 30))
            let commentLength = Int(try data.doc_uint16LE(at: cursor + 32))
            let localOffset = Int(try data.doc_uint32LE(at: cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw DocumentAccessError.unsupportedFileType("DOCX ZIP 条目名损坏。")
            }

            defer {
                cursor = nameEnd + extraLength + commentLength
            }
            guard name == expectedName else { continue }
            guard try data.doc_uint32LE(at: localOffset) == 0x04034b50 else {
                throw DocumentAccessError.unsupportedFileType("DOCX ZIP 本地条目损坏。")
            }
            let localNameLength = Int(try data.doc_uint16LE(at: localOffset + 26))
            let localExtraLength = Int(try data.doc_uint16LE(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else {
                throw DocumentAccessError.unsupportedFileType("DOCX ZIP 条目大小损坏。")
            }
            let payload = Data(data[dataStart..<dataEnd])
            switch method {
            case 0:
                return payload
            case 8:
                let decompressed: Data
                do {
                    decompressed = try (payload as NSData).decompressed(using: .zlib) as Data
                } catch {
                    throw DocumentAccessError.unsupportedFileType("DOCX ZIP 解压失败，暂不能提取此文档文本。")
                }
                if uncompressedSize > 0, decompressed.count > max(uncompressedSize * 2, uncompressedSize + 1024) {
                    throw DocumentAccessError.unsupportedFileType("DOCX ZIP 解压结果异常。")
                }
                return decompressed
            default:
                throw DocumentAccessError.unsupportedFileType("DOCX 使用了暂不支持的 ZIP 压缩方式：\(method)。")
            }
        }
        return nil
    }

    /// Lists the entry names in a ZIP archive that start with the given prefix
    /// (e.g. "ppt/slides/slide" for PPTX slides). Used to discover a variable
    /// number of slide entries before extracting them. Returns names sorted by
    /// their trailing integer so slide1..slideN come out in order.
    static func entryNames(matchingPrefix prefix: String, in data: Data) throws -> [String] {
        guard let eocd = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else {
            throw DocumentAccessError.unsupportedFileType("文档不是有效的 ZIP。")
        }
        let entryCount = Int(try data.doc_uint16LE(at: eocd + 10))
        let centralOffset = Int(try data.doc_uint32LE(at: eocd + 16))
        var cursor = centralOffset
        var matches: [String] = []

        for _ in 0..<entryCount {
            guard try data.doc_uint32LE(at: cursor) == 0x02014b50 else {
                throw DocumentAccessError.unsupportedFileType("ZIP 中央目录损坏。")
            }
            let nameLength = Int(try data.doc_uint16LE(at: cursor + 28))
            let extraLength = Int(try data.doc_uint16LE(at: cursor + 30))
            let commentLength = Int(try data.doc_uint16LE(at: cursor + 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw DocumentAccessError.unsupportedFileType("ZIP 条目名损坏。")
            }
            cursor = nameEnd + extraLength + commentLength
            if name.hasPrefix(prefix) { matches.append(name) }
        }
        // Sort by trailing integer (slide1, slide2, ..., slide10) so slides stay
        // in presentation order rather than lexicographic order.
        return matches.sorted { lhs, rhs in
            trailingInt(lhs) < trailingInt(rhs)
        }
    }

    /// Extracts the trailing integer from a name like "ppt/slides/slide12.xml".
    private static func trailingInt(_ name: String) -> Int {
        let digits = name.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }
}

private extension Data {
    func doc_uint16LE(at offset: Int) throws -> UInt16 {
        guard offset + 2 <= count else {
            throw DocumentAccessError.unsupportedFileType("DOCX ZIP 读取越界。")
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func doc_uint32LE(at offset: Int) throws -> UInt32 {
        guard offset + 4 <= count else {
            throw DocumentAccessError.unsupportedFileType("DOCX ZIP 读取越界。")
        }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

enum DocumentAccessError: Error, Equatable {
    case missingGrant
    case grantMismatch
    case expiredGrant
    case fileMissing
    case fileTooLarge
    case unknownFileSize
    case alreadyReading
    case unsupportedFileType(String)
    case noReadableText(String)
    case readFailed(String)
}

extension DocumentAccessError {
    /// 深度阅读专用中文提示（不复用通用英文 `userMessage`）。
    var userMessageForDeepRead: String {
        switch self {
        case .missingGrant:
            "请先选择文件。"
        case .grantMismatch:
            "所选文件授权不匹配，请重新选择文件。"
        case .expiredGrant:
            "文件授权已失效，请重新选择文件。"
        case .fileMissing:
            "文件已不存在，请从文件 App 重新选择。"
        case .fileTooLarge:
            "文件过大，超出导入限制。"
        case .unknownFileSize:
            "无法确认文件大小，请选择普通文件后重试。"
        case .alreadyReading:
            "正在读取该文件，请稍候。"
        case .unsupportedFileType(let message):
            IOSDeepReadUserFacingText.sanitize(message)
        case .noReadableText(let message):
            IOSDeepReadUserFacingText.sanitize(message)
        case .readFailed(let message):
            "读取文件失败：\(IOSDeepReadUserFacingText.sanitize(message))"
        }
    }
}

struct IOSToolInvocationRequest: Equatable {
    let toolName: String
    let operation: String
    let scopeDigest: String
    let payloadDigest: String
    let isUserInitiated: Bool
    let executionPolicy: IOSExecutionPolicySnapshot?

    init(
        toolName: String,
        operation: String,
        scopeDigest: String,
        payloadDigest: String,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) {
        self.toolName = toolName
        self.operation = operation
        self.scopeDigest = scopeDigest
        self.payloadDigest = payloadDigest
        self.isUserInitiated = isUserInitiated
        self.executionPolicy = executionPolicy
    }
}

enum IOSPlatformGateDecision: Equatable {
    case allow(capabilityId: String)
    case needsUserAction(reason: String)
    case deny(reason: String)

    var summary: String {
        switch self {
        case .allow:
            "Allowed"
        case .needsUserAction(let reason):
            "Needs user action: \(reason)"
        case .deny(let reason):
            "Denied: \(reason)"
        }
    }
}

enum IOSToolExecutionResult: Equatable {
    case success(SelectedDocumentReadResult)
    case needsUserAction(String)
    case denied(String)
    case failed(String)
}

@MainActor
final class IOSToolRuntime {
    private let permissionStore: IOSPermissionStore
    private let documentStore: DocumentAccessStore

    init(permissionStore: IOSPermissionStore, documentStore: DocumentAccessStore) {
        self.permissionStore = permissionStore
        self.documentStore = documentStore
    }

    func resolve(request: IOSToolInvocationRequest, now: Date = Date()) -> IOSPlatformGateDecision {
        guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
            return .deny(reason: "Unknown iOS tool: \(request.toolName)")
        }

        if capability.status == .unsupported {
            return .deny(reason: "Unsupported on iOS")
        }
        if capability.blockedToolNames.contains(request.toolName) {
            return .deny(reason: "Tool is blocked on iOS")
        }

        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent policy")
        }
        if policy == .askEveryTime && !request.isUserInitiated {
            return .needsUserAction(reason: "Ask every time requires a foreground user action")
        }
        if capability.gate.requiresFreshUserPresence && !request.isUserInitiated {
            return .needsUserAction(reason: "Fresh user presence required")
        }

        if request.toolName == "file_read_selected" {
            return resolveSelectedFileRead(request: request, capability: capability, now: now)
        }

        return .needsUserAction(reason: "No iOS runtime implementation for \(request.toolName)")
    }

    func executeFileReadSelected(
        request: IOSToolInvocationRequest,
        now: Date = Date()
    ) async -> IOSToolExecutionResult {
        let decision = resolve(request: request, now: now)
        switch decision {
        case .allow:
            let result = await documentStore.consumeSelectedFileRead(request: request, now: now)
            switch result {
            case .success(let readResult):
                return .success(readResult)
            case .failure(let error):
                return .failed(error.userMessage)
            }
        case .needsUserAction(let reason):
            return .needsUserAction(reason)
        case .deny(let reason):
            return .denied(reason)
        }
    }

    private func resolveSelectedFileRead(
        request: IOSToolInvocationRequest,
        capability: IOSPlatformCapability,
        now: Date
    ) -> IOSPlatformGateDecision {
        guard let grant = documentStore.grant else {
            return .needsUserAction(reason: "Choose a file in the foreground picker")
        }
        guard grant.capabilityId == capability.id,
              grant.toolName == request.toolName,
              grant.operation == request.operation,
              grant.scopeDigest == request.scopeDigest,
              grant.payloadDigest == request.payloadDigest else {
            return .deny(reason: "Grant does not match tool, operation, scope, and payload")
        }
        guard !grant.isExpired(now: now) else {
            return .deny(reason: "Grant expired or was already used")
        }
        guard grant.fileSize <= documentStore.maxReadableBytes else {
            return .deny(reason: "Selected file is larger than the file-context import limit of \(DocumentAccessStore.formatBytes(documentStore.maxReadableBytes))")
        }
        guard capability.gate.allowRunScopedReuse else {
            return .needsUserAction(reason: "Run-scoped reuse is not allowed")
        }
        return .allow(capabilityId: capability.id)
    }
}

fileprivate extension DocumentAccessError {
    var userMessage: String {
        switch self {
        case .missingGrant:
            "Choose a file before reading."
        case .grantMismatch:
            "The selected-file grant does not match this request."
        case .expiredGrant:
            "The in-memory file grant expired. Choose the file again."
        case .fileMissing:
            "The selected file is missing. Choose it again from Files."
        case .fileTooLarge:
            "Selected file is larger than the file-context import limit."
        case .unknownFileSize:
            "Selected file size is unavailable. Choose a regular file and try again."
        case .alreadyReading:
            "The selected file is already being read."
        case .unsupportedFileType(let message):
            message
        case .noReadableText(let message):
            message
        case .readFailed(let message):
            "Failed to read selected file: \(message)"
        }
    }

    var clearsSelectedGrant: Bool {
        switch self {
        case .expiredGrant, .fileMissing:
            true
        default:
            false
        }
    }
}
