import Foundation

/// Where each conversation's workspace lives. Three cases, resolved in this order:
/// 1. A folder bound to the conversation: one the user opened (`external`), or one Amber created under the
///    default workspace (kept by absolute path, so changing the default later never moves it).
/// 2. The legacy per-conversation directory under Application Support, if it already exists.
/// 3. With a default workspace set, a new folder there named after the conversation, created on first use;
///    otherwise the legacy directory.
/// Lock-based rather than an actor so the main actor can read it synchronously for display and request context.
final class DesktopWorkspaceLocations: @unchecked Sendable {
    struct Binding: Codable, Equatable, Sendable {
        var path: String
        /// Opened by the user: Amber never deletes, trashes or backs it up.
        var external: Bool
    }

    enum Kind: Equatable, Sendable {
        case legacy
        /// Created by Amber under the default workspace.
        case managed
        case external
    }

    private struct Record: Codable {
        var defaultRoot: String?
        var bindings: [UUID: Binding] = [:]
    }

    let legacyRoot: URL
    private let fileURL: URL?
    private let lock = NSLock()
    private var record: Record
    private var titles: [UUID: String] = [:]
    private let manager = FileManager.default

    /// `fileURL` nil keeps everything in memory (tests and previews).
    init(legacyRoot: URL, fileURL: URL? = nil) {
        self.legacyRoot = legacyRoot
        self.fileURL = fileURL
        record = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    var defaultRoot: URL? {
        lock.withLock { record.defaultRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    func setDefaultRoot(_ url: URL?) throws {
        let path = try url.map { try Self.validatedFolder($0).path }
        try lock.withLock {
            record.defaultRoot = path
            try save()
        }
    }

    /// Titles name new folders under the default workspace; not persisted (summaries re-supply them at launch).
    func noteTitle(_ title: String, for owner: UUID) {
        lock.withLock { titles[owner] = title }
    }

    func bindExternal(_ url: URL, to owner: UUID) throws {
        let folder = try Self.validatedFolder(url)
        try lock.withLock {
            record.bindings[owner] = Binding(path: folder.path, external: true)
            try save()
        }
    }

    /// Back to the default location. Only an opened folder can be released; Amber's own folders stay bound.
    func releaseExternal(_ owner: UUID) throws {
        try lock.withLock {
            guard record.bindings[owner]?.external == true else { return }
            record.bindings[owner] = nil
            try save()
        }
    }

    func forget(_ owner: UUID) {
        lock.withLock {
            titles[owner] = nil
            guard record.bindings.removeValue(forKey: owner) != nil else { return }
            try? save()
        }
    }

    func kind(of owner: UUID) -> Kind {
        lock.withLock {
            if let binding = record.bindings[owner] { return binding.external ? .external : .managed }
            return .legacy
        }
    }

    /// The folder in use, or nil when it would only be created on first use.
    func existingDirectory(for owner: UUID) -> URL? {
        lock.withLock {
            if let binding = record.bindings[owner] { return URL(fileURLWithPath: binding.path, isDirectory: true) }
            let legacy = legacyDirectory(owner)
            if manager.fileExists(atPath: legacy.path) || record.defaultRoot == nil { return legacy }
            return nil
        }
    }

    /// `create` false never touches the disk: a not-yet-created folder resolves to a path that does not exist.
    func directory(for owner: UUID, create: Bool) throws -> (url: URL, kind: Kind) {
        try lock.withLock {
            if let binding = record.bindings[owner] {
                let url = URL(fileURLWithPath: binding.path, isDirectory: true)
                if binding.external {
                    var isDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw DesktopRuntimeError.message("工作区文件夹不存在：\(url.path)。请在会话文件中重新选择。")
                    }
                    return (url, .external)
                }
                if create { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
                return (url, .managed)
            }
            let legacy = legacyDirectory(owner)
            guard let rootPath = record.defaultRoot, !manager.fileExists(atPath: legacy.path) else {
                if create { try manager.createDirectory(at: legacy, withIntermediateDirectories: true) }
                return (legacy, .legacy)
            }
            guard create else { return (legacy, .legacy) }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DesktopRuntimeError.message("默认工作区文件夹不存在：\(root.path)。请在设置中重新选择。")
            }
            let url = unusedFolder(in: root, name: Self.folderName(titles[owner]))
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            record.bindings[owner] = Binding(path: url.path, external: false)
            do { try save() } catch {
                record.bindings[owner] = nil
                try? manager.removeItem(at: url)
                throw error
            }
            return (url, .managed)
        }
    }

    // MARK: private (lock held)

    private func legacyDirectory(_ owner: UUID) -> URL {
        legacyRoot.appendingPathComponent(owner.uuidString, isDirectory: true)
    }

    private func unusedFolder(in root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) \(suffix)", isDirectory: true); suffix += 1
        }
        return candidate
    }

    private func save() throws {
        guard let fileURL else { return }
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
    }

    // MARK: helpers

    static func folderName(_ title: String?, now: Date = Date()) -> String {
        let cleaned = (title ?? "").components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !trimmed.isEmpty, trimmed != "新对话" { return String(trimmed.prefix(40)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "对话 " + formatter.string(from: now)
    }

    /// A real directory, links resolved, and not so broad that listing it means walking the whole disk.
    static func validatedFolder(_ url: URL) throws -> URL {
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopRuntimeError.message("请选择一个文件夹。")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.path != "/", folder.path != home, folder.path != "/Users" else {
            throw DesktopRuntimeError.message("请选择具体的项目或资料文件夹，不能是根目录或整个用户目录。")
        }
        return folder
    }
}
