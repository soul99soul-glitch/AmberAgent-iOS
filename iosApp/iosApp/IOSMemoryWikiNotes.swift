import Foundation

struct IOSMemoryWikiRevision: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let content: String
    let reason: String
    let source: String
    let restoredFrom: String?
    let createdAt: Int64
}

/// Source of truth for the editable layer. Generated Markdown is never used as
/// a write source, so a regeneration cannot promote notes into user facts.
final class IOSMemoryWikiNotes {
    enum Failure: LocalizedError {
        case unreadable, staleRevision, invalidPath, invalidEdit, missingRevision
        var errorDescription: String? {
            switch self {
            case .unreadable: "Wiki notes cannot be read; writes are blocked to preserve the file."
            case .staleRevision: "Page changed; read it again before editing."
            case .invalidPath: "Use a relative .md path inside index.md, topics/, or notes/."
            case .invalidEdit: "A note is limited to 6000 characters and needs a nonempty reason."
            case .missingRevision: "Note revision was not found."
            }
        }
    }

    private let fileURL: URL
    private var revisions: [IOSMemoryWikiRevision] = []
    private var unreadable = false

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("wiki-notes.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { revisions = try JSONDecoder().decode([IOSMemoryWikiRevision].self, from: Data(contentsOf: fileURL)) }
            catch { unreadable = true }
        }
    }

    var signature: String { revisions.last?.id ?? "" }
    var paths: [String] {
        Array(Set(revisions.map(\.path))).filter { !(current(path: $0)?.content.isEmpty ?? true) }.sorted()
    }

    static func resolve(_ path: String, from containingPage: String? = nil) throws -> String {
        let decoded = path.removingPercentEncoding ?? path
        let target = String(decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains(":"), !target.contains("\\") else {
            throw Failure.invalidPath
        }
        let root = URL(fileURLWithPath: "/wiki/", isDirectory: true)
        let parent = try containingPage.map { try resolve($0) }
            .map { root.appendingPathComponent($0).deletingLastPathComponent() } ?? root
        let resolved = parent.appendingPathComponent(target).standardizedFileURL.path
        guard resolved.hasPrefix("/wiki/") else { throw Failure.invalidPath }
        let relative = String(resolved.dropFirst(6))
        let components = relative.split(separator: "/")
        guard relative == "index.md" || (components.count == 2 && ["topics", "notes"].contains(String(components[0])) && relative.hasSuffix(".md")) else {
            throw Failure.invalidPath
        }
        return relative
    }

    // Topic titles can change during daily consolidation; the numeric id owns
    // the note, so renamed slugs continue to show the same revisions.
    private static func key(_ path: String) -> String {
        if path.hasPrefix("topics/"), let name = path.split(separator: "/").last,
           let id = name.split(separator: "-").first, Int(id) != nil {
            return "topic:\(id)"
        }
        return path
    }

    func history(path: String) -> [IOSMemoryWikiRevision] {
        revisions.filter { Self.key($0.path) == Self.key(path) }
    }

    func current(path: String) -> IOSMemoryWikiRevision? { history(path: path).last }

    @discardableResult
    func edit(path: String, content: String, expectedRevision: String, reason: String,
              source: String = "agent:memory_tool", restoreRevision: String? = nil,
              now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> IOSMemoryWikiRevision {
        guard !unreadable else { throw Failure.unreadable }
        let path = try Self.resolve(path)
        guard (current(path: path)?.id ?? "") == expectedRevision else { throw Failure.staleRevision }
        guard content.count <= 6000, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidEdit
        }
        let body: String
        if let restoreRevision {
            if restoreRevision.isEmpty { body = "" }
            else {
                guard let old = history(path: path).first(where: { $0.id == restoreRevision }) else { throw Failure.missingRevision }
                body = old.content
            }
        } else { body = content }
        let revision = IOSMemoryWikiRevision(id: UUID().uuidString, path: path, content: body,
                                             reason: reason, source: source, restoredFrom: restoreRevision, createdAt: now)
        let updated = revisions + [revision]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        revisions = updated
        return revision
    }

    func merging(into generated: [String: String]) -> [String: String] {
        var pages = generated
        for path in paths {
            let matchingPath = pages.keys.first { Self.key($0) == Self.key(path) } ?? path
            guard let note = current(path: path), !note.content.isEmpty else { continue }
            // Only merge once when older revisions used a previous topic slug.
            guard !pages[matchingPath, default: ""].contains("<!-- wiki-note:\(note.id) -->") else { continue }
            pages[matchingPath, default: "# 页面笔记\n"] += "\n## Agent 笔记\n\n> 此部分由 agent 编辑，未经用户确认为事实；置顶与核心记忆仍以用户确认的记录为准。\n\n<!-- wiki-note:\(note.id) -->\n\(note.content)\n"
        }
        let extras = pages.keys.filter { generated[$0] == nil }.sorted()
        if !extras.isEmpty {
            pages["index.md", default: "# Amber 记忆索引\n"] += "\n## 页面笔记\n\n" + extras.map { "- [\(($0 as NSString).lastPathComponent)](\($0))" }.joined(separator: "\n") + "\n"
        }
        return pages
    }
}
