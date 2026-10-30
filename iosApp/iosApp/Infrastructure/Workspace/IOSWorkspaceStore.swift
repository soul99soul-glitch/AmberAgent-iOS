import Foundation
import Observation

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
    @ObservationIgnored private let previewParser: (@MainActor (URL, String) async -> Result<SelectedDocumentReadResult, Error>)?

    init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        previewParser: (@MainActor (URL, String) async -> Result<SelectedDocumentReadResult, Error>)? = nil
    ) {
        self.previewParser = previewParser
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
        var nextFiles = files
        nextFiles.insert(record, at: 0)
        do {
            try persist(files: nextFiles)
        } catch {
            try rollbackPayload(after: error) {
                try fileManager.removeItem(at: destination)
            }
        }
        publish()
        return record
    }

    @discardableResult
    func reparseFile(id: String, now: Date = Date()) async throws -> IOSWorkspaceFileRecord {
        guard let original = files.first(where: { $0.id == id }) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        let next = await parsedRecord(original, now: now)
        guard let index = files.firstIndex(where: { $0.id == id }) else {
            throw IOSWorkspaceStoreError.missingFile
        }
        guard files[index] == original else {
            throw IOSWorkspaceStoreError.storage("Workspace file changed while it was being parsed. Retry with the current file.")
        }
        var nextFiles = files
        nextFiles[index] = next
        try persist(files: nextFiles)
        publish()
        return next
    }

    func removeFile(id: String) throws {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let record = files[index]
        let url = fileURL(forWorkspacePath: record.workspacePath)
        let data = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let modificationDate = data != nil
            ? try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        if data != nil {
            try fileManager.removeItem(at: url)
        }
        var nextFiles = files
        nextFiles.remove(at: index)
        do {
            try persist(files: nextFiles)
        } catch {
            try rollbackPayload(after: error) {
                try restorePayload(at: url, data: data, modificationDate: modificationDate)
            }
        }
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
        var nextArtifacts = artifacts
        nextArtifacts.insert(record, at: 0)
        do {
            try persist(artifacts: nextArtifacts)
        } catch {
            try rollbackPayload(after: error) {
                try fileManager.removeItem(at: destination)
            }
        }
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
        let record = artifacts[index]
        let url = artifactsDirectory.appendingPathComponent(record.contentPath, isDirectory: false)
        let data = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let modificationDate = data != nil
            ? try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        if data != nil {
            try fileManager.removeItem(at: url)
        }
        var nextArtifacts = artifacts
        nextArtifacts.remove(at: index)
        do {
            try persist(artifacts: nextArtifacts)
        } catch {
            try rollbackPayload(after: error) {
                try restorePayload(at: url, data: data, modificationDate: modificationDate)
            }
        }
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
        let original = files.first(where: { $0.workspacePath == relativePath })
        let existed = fileManager.fileExists(atPath: file.path)
        if existed { try amberShellRequireRegularFile(at: file) }
        let previousData = existed ? try Data(contentsOf: file) : nil
        let modificationDate = existed
            ? try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        let record = try await amberShellPreparedRecord(
            path: relativePath, file: file, data: data, source: "amber_shell_write", original: original
        )
        try amberShellRequireUnchanged(path: relativePath, record: original, data: previousData)
        try data.write(to: file, options: [.atomic])
        do {
            try commitFileRecord(record)
        } catch {
            try rollbackPayload(after: error) {
                try restorePayload(at: file, data: previousData, modificationDate: modificationDate)
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
        let original = files.first(where: { $0.workspacePath == relativePath })
        let existed = fileManager.fileExists(atPath: file.path)
        if existed { try amberShellRequireRegularFile(at: file) }
        let previousData = existed ? try Data(contentsOf: file) : nil
        let modificationDate = existed
            ? try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        let record = try await amberShellPreparedRecord(
            path: relativePath, file: file, data: previousData ?? Data(), source: "amber_shell_touch", original: original
        )
        try amberShellRequireUnchanged(path: relativePath, record: original, data: previousData)
        if existed {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            try Data().write(to: file, options: [.atomic])
        }
        do {
            try commitFileRecord(record)
        } catch {
            try rollbackPayload(after: error) {
                if existed, let modificationDate {
                    try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)
                } else if !existed {
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
        let originalSource = files.first(where: { $0.workspacePath == sourcePath })
        let originalDestination = files.first(where: { $0.workspacePath == destinationPath })
        let record = try await amberShellPreparedRecord(
            path: destinationPath, file: destinationURL, data: data,
            source: "amber_shell_copy", original: originalDestination
        )
        try amberShellRequireUnchanged(path: sourcePath, record: originalSource, data: data)
        try amberShellRequireUnchanged(path: destinationPath, record: originalDestination, data: nil)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        do {
            try commitFileRecord(record)
        } catch {
            try rollbackPayload(after: error) {
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
        let data = try Data(contentsOf: sourceURL)
        let originalSource = files.first(where: { $0.workspacePath == sourcePath })
        let originalDestination = files.first(where: { $0.workspacePath == destinationPath })
        let record = try await amberShellPreparedRecord(
            path: destinationPath, file: destinationURL, data: data,
            source: "amber_shell_move", original: originalSource
        )
        try amberShellRequireUnchanged(path: sourcePath, record: originalSource, data: data)
        try amberShellRequireUnchanged(path: destinationPath, record: originalDestination, data: nil)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        do {
            try commitFileRecord(record)
        } catch {
            try rollbackPayload(after: error) {
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
        var nextFiles = files
        nextFiles.removeAll { $0.workspacePath == relativePath }
        try fileManager.removeItem(at: file)
        do {
            try persist(files: nextFiles)
            publish()
        } catch {
            try rollbackPayload(after: error) {
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

    private func amberShellPreparedRecord(
        path: String, file: URL, data: Data, source: String, original: IOSWorkspaceFileRecord?
    ) async throws -> IOSWorkspaceFileRecord {
        let now = Date()
        var record = original ?? IOSWorkspaceFileRecord(
            id: UUID().uuidString,
            displayName: file.lastPathComponent,
            originalFileName: file.lastPathComponent,
            workspacePath: path,
            mimeType: path.hasSuffix(".md") ? "text/markdown" : "text/plain",
            sizeBytes: Int64(data.count),
            importedAtMillis: Self.millis(now),
            updatedAtMillis: Self.millis(now),
            status: .ready,
            statusMessage: "",
            preview: "",
            isTruncated: false,
            characterCount: 0,
            source: source
        )
        record.workspacePath = path
        record.displayName = file.lastPathComponent
        record.sizeBytes = Int64(data.count)
        record.source = source
        return try await parsedProposedRecord(record, data: data, now: now)
    }

    private func amberShellRequireUnchanged(
        path: String, record: IOSWorkspaceFileRecord?, data: Data?
    ) throws {
        // Resolve again after parsing: a parent can have moved or become a symlink.
        let file = try amberShellURL(for: path, finalMayBeMissing: true)
        let existed = fileManager.fileExists(atPath: file.path)
        if existed { try amberShellRequireRegularFile(at: file) }
        let currentData = existed ? try Data(contentsOf: file) : nil
        guard files.first(where: { $0.workspacePath == path }) == record, currentData == data else {
            throw IOSWorkspaceStoreError.storage("Workspace file changed while the command was being prepared. Retry with the current file.")
        }
    }

    private func commitFileRecord(_ record: IOSWorkspaceFileRecord) throws {
        var nextFiles = files
        nextFiles.removeAll { $0.id == record.id || $0.workspacePath == record.workspacePath }
        nextFiles.insert(record, at: 0)
        try persist(files: nextFiles)
        publish()
    }

    private func rollbackPayload(after originalError: Error, _ rollback: () throws -> Void) throws -> Never {
        do {
            try rollback()
        } catch {
            throw IOSWorkspaceStoreError.storage(
                "Workspace update failed: \(originalError.localizedDescription). Its file rollback also failed: \(error.localizedDescription)"
            )
        }
        throw originalError
    }

    private func restorePayload(at url: URL, data: Data?, modificationDate: Date?) throws {
        if let data {
            try data.write(to: url, options: [.atomic])
            if let modificationDate {
                try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
            }
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
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
        guard let content = args["content"] as? String else {
            return Self.json(["ok": false, "tool": "workspace_file_write", "error": "content must be a string."])
        }
        let overwrite = (args["overwrite"] as? Bool) ?? false
        let url = fileURL(forWorkspacePath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path), !overwrite {
            throw IOSWorkspaceStoreError.writeWouldOverwrite("/workspace/\(path)")
        }
        let originalRecord = files.first(where: { $0.workspacePath == path })
        let previousData = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let modificationDate = previousData != nil
            ? try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            : nil
        let contentData = Data(content.utf8)
        let now = Date()
        let mime = path.hasSuffix(".md") ? "text/markdown" : "text/plain"
        var record = originalRecord ?? IOSWorkspaceFileRecord(
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
        record = try await parsedProposedRecord(record, data: contentData, now: now)
        let currentData = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard files.first(where: { $0.workspacePath == path }) == originalRecord,
              currentData == previousData else {
            throw IOSWorkspaceStoreError.storage("Workspace file changed while the write was being prepared. Retry with the current file.")
        }
        try contentData.write(to: url, options: [.atomic])
        var nextFiles = files
        nextFiles.removeAll { $0.id == record.id || $0.workspacePath == record.workspacePath }
        nextFiles.insert(record, at: 0)
        do {
            try persist(files: nextFiles)
        } catch {
            try rollbackPayload(after: error) {
                try restorePayload(at: url, data: previousData, modificationDate: modificationDate)
            }
        }
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
        let modificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let editedData = Data(edited.utf8)
        let now = Date()
        var updated = record
        updated.sizeBytes = Int64(edited.utf8.count)
        updated.updatedAtMillis = Self.millis(now)
        updated = try await parsedProposedRecord(updated, data: editedData, now: now)
        guard files.first(where: { $0.id == record.id }) == record,
              fileManager.fileExists(atPath: url.path),
              try Data(contentsOf: url) == originalBytes else {
            throw IOSWorkspaceStoreError.storage("Workspace file changed while the edit was being prepared. Retry with the current file.")
        }
        try editedData.write(to: url, options: [.atomic])
        var nextFiles = files
        nextFiles.removeAll { $0.id == updated.id }
        nextFiles.insert(updated, at: 0)
        do {
            try persist(files: nextFiles)
        } catch {
            try rollbackPayload(after: error) {
                try restorePayload(at: url, data: originalBytes, modificationDate: modificationDate)
            }
        }
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
        var nextFiles = files
        nextFiles.removeAll { $0.id == record.id }
        nextFiles.insert(record, at: 0)
        do {
            try persist(files: nextFiles)
        } catch {
            try rollbackPayload(after: error) {
                try fileManager.moveItem(at: destURL, to: sourceURL)
            }
        }
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

    private func parsedProposedRecord(
        _ record: IOSWorkspaceFileRecord, data: Data, now: Date
    ) async throws -> IOSWorkspaceFileRecord {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        // Keep the extension and MIME type so preview parsing matches the eventual target.
        let stagedFile = directory.appendingPathComponent(fileURL(for: record).lastPathComponent)
        try data.write(to: stagedFile, options: [.atomic])
        return await parsedRecord(record, now: now, sourceURL: stagedFile)
    }

    private func parsedRecord(
        _ record: IOSWorkspaceFileRecord, now: Date, sourceURL: URL? = nil
    ) async -> IOSWorkspaceFileRecord {
        var next = record
        let url = sourceURL ?? fileURL(forWorkspacePath: record.workspacePath)
        guard fileManager.fileExists(atPath: url.path) else {
            next.status = .missing
            next.statusMessage = "The copied Workspace file is missing. Import it again."
            next.updatedAtMillis = Self.millis(now)
            return next
        }
        let parseResult: Result<SelectedDocumentReadResult, Error>
        if let previewParser {
            parseResult = await previewParser(url, record.mimeType)
        } else {
            parseResult = await DocumentAccessStore.previewFileForWorkspace(
                url: url,
                fileType: record.mimeType,
                maxReadableBytes: maxImportBytes,
                maxPreviewBytes: 64 * 1024,
                maxPreviewCharacters: maxPreviewCharacters
            )
        }
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

    private func persist(
        files nextFiles: [IOSWorkspaceFileRecord]? = nil,
        artifacts nextArtifacts: [IOSWorkspaceArtifactRecord]? = nil
    ) throws {
        try ensureDirectories()
        let state = IOSWorkspaceState(files: nextFiles ?? files, artifacts: nextArtifacts ?? artifacts)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
        if let nextFiles, files != nextFiles { files = nextFiles }
        if let nextArtifacts, artifacts != nextArtifacts { artifacts = nextArtifacts }
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
