import Foundation

struct DesktopWorkspaceFile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let byteCount: Int
    let modifiedAt: Date
}

struct DesktopWorkspaceTextRead: Equatable, Sendable {
    let text: String
    let truncated: Bool
}

actor DesktopWorkspaceFiles {
    private let root: URL
    private let manager = FileManager.default
    private var removedOwners: Set<UUID> = []

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("amber-workspaces-" + UUID().uuidString, isDirectory: true)) {
        root = directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
    }

    func list(conversationID: UUID) throws -> [DesktopWorkspaceFile] {
        let directory = try ownerDirectory(conversationID, create: false)
        guard manager.fileExists(atPath: directory.path) else { return [] }
        var entries: [DesktopWorkspaceFile] = []
        func collect(_ folder: URL, prefix: String) throws {
            for child in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                let path = prefix + child.lastPathComponent
                let url = try location(conversationID, path: path, createParents: false)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true { try collect(url, prefix: path + "/") }
                else if values.isRegularFile == true { entries.append(try entry(url, path: path)) }
            }
        }
        try collect(directory, prefix: "")
        return entries.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func read(conversationID: UUID, path: String) throws -> Data {
        let url = try location(conversationID, path: path, createParents: false)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        return try Data(contentsOf: url)
    }

    /// Reads a bounded UTF-8 byte prefix. Extended grapheme clusters can use more than four bytes,
    /// so the returned String may contain fewer than maxCharacters for such text.
    func readUTF8Prefix(conversationID: UUID, path: String, maxCharacters: Int) throws -> DesktopWorkspaceTextRead {
        guard maxCharacters >= 0, maxCharacters <= (Int.max - 4) / 4 else { throw failure("文本读取范围无效。") }
        let url = try location(conversationID, path: path, createParents: false)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let byteLimit = maxCharacters * 4 + 4
        let data = try handle.read(upToCount: byteLimit) ?? Data()
        let endOfFile = data.count < byteLimit
        var hasMore = false
        if !endOfFile {
            hasMore = !(try handle.read(upToCount: 3) ?? Data()).isEmpty
        }
        if let text = String(data: data, encoding: .utf8) {
            return DesktopWorkspaceTextRead(text: String(text.prefix(maxCharacters)),
                truncated: text.count > maxCharacters || hasMore)
        }
        guard hasMore else { throw failure("文件不是 UTF-8 文本。") }
        for count in 1...min(3, data.count) {
            let candidate = data.dropLast(count)
            if let text = String(data: candidate, encoding: .utf8) {
                return DesktopWorkspaceTextRead(text: String(text.prefix(maxCharacters)), truncated: true)
            }
        }
        throw failure("文件不是 UTF-8 文本。")
    }

    @discardableResult
    func write(conversationID: UUID, path: String, data: Data, overwrite: Bool = true) throws -> DesktopWorkspaceFile {
        let url = try location(conversationID, path: path, createParents: true)
        guard overwrite || !manager.fileExists(atPath: url.path) else { throw failure("文件已存在；请使用新文件名，或明确允许覆盖。") }
        try data.write(to: url, options: .atomic)
        return try entry(url, path: path)
    }

    @discardableResult
    func importFile(conversationID: UUID, from source: URL) throws -> DesktopWorkspaceFile {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        let name = try unusedName(conversationID, name: source.lastPathComponent)
        let destination = try location(conversationID, path: name, createParents: true)
        guard !manager.fileExists(atPath: destination.path) else { throw failure("文件已存在；请使用新文件名。") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".amber-import-" + UUID().uuidString)
        do {
            try manager.copyItem(at: source, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
            return try entry(destination, path: name)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    @discardableResult
    func importData(conversationID: UUID, name: String, data: Data) throws -> DesktopWorkspaceFile {
        try write(conversationID: conversationID, path: unusedName(conversationID, name: name), data: data)
    }

    func delete(conversationID: UUID, path: String) throws {
        let url = try location(conversationID, path: path, createParents: false)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        try manager.removeItem(at: url)
    }

    func temporaryURL(conversationID: UUID, path: String) throws -> URL {
        let source = try location(conversationID, path: path, createParents: false)
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        let directory = manager.temporaryDirectory.appendingPathComponent("amber-share-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        do {
            try manager.copyItem(at: source, to: url)
            return url
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func copy(conversationID: UUID, path: String, to destination: URL, overwrite: Bool = true) throws {
        let source = try location(conversationID, path: path, createParents: false)
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure("请选择普通文件。") }
        let granted = destination.startAccessingSecurityScopedResource()
        defer { if granted { destination.stopAccessingSecurityScopedResource() } }
        guard overwrite || !manager.fileExists(atPath: destination.path) else {
            throw failure("目标文件已存在，请选择新文件名。")
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".amber-export-" + UUID().uuidString)
        do {
            try manager.copyItem(at: source, to: temporary)
            if manager.fileExists(atPath: destination.path) {
                guard overwrite else { throw failure("目标文件已存在，请选择新文件名。") }
                _ = try manager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    func commandDirectory(conversationID: UUID) throws -> URL {
        try ownerDirectory(conversationID, create: true)
    }

    func removeConversation(_ owner: UUID) throws {
        let directory = try ownerDirectory(owner, create: false)
        removedOwners.insert(owner)
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
    }

    private func unusedName(_ owner: UUID, name: String) throws -> String {
        _ = try location(owner, path: name, createParents: true)
        let filename = URL(fileURLWithPath: name)
        let stem = filename.deletingPathExtension().lastPathComponent
        let ext = filename.pathExtension.isEmpty ? "" : "." + filename.pathExtension
        var candidate = name
        var suffix = 2
        while manager.fileExists(atPath: try location(owner, path: candidate, createParents: false).path) {
            candidate = "\(stem)-\(suffix)\(ext)"; suffix += 1
        }
        return candidate
    }

    private func ownerDirectory(_ owner: UUID, create: Bool) throws -> URL {
        guard !removedOwners.contains(owner) else { throw failure("会话已删除，无法访问工作区。") }
        let directory = root.appendingPathComponent(owner.uuidString, isDirectory: true)
        for url in [root, directory] {
            if let kind = try? manager.attributesOfItem(atPath: url.path)[.type], kind as? FileAttributeType == .typeSymbolicLink {
                throw failure("工作区路径不能包含符号链接。")
            }
        }
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }

    private func location(_ owner: UUID, path: String, createParents: Bool) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("文件路径必须位于当前会话工作区内。")
        }
        let directory = try ownerDirectory(owner, create: createParents)
        var url = directory
        for component in components {
            url.appendPathComponent(String(component))
            // Check dangling links too: fileExists alone follows links and returns false for them.
            if let kind = try? manager.attributesOfItem(atPath: url.path)[.type], kind as? FileAttributeType == .typeSymbolicLink {
                throw failure("工作区路径不能包含符号链接。")
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(directory.path + "/") else { throw failure("文件路径越出了当前会话工作区。") }
        if createParents { try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return url
    }

    private func entry(_ url: URL, path: String) throws -> DesktopWorkspaceFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return DesktopWorkspaceFile(id: path, name: url.lastPathComponent, byteCount: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    private func failure(_ message: String) -> DesktopRuntimeError { .message(message) }
}
