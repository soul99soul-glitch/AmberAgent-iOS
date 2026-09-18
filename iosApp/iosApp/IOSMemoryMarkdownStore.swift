import Foundation
@preconcurrency import Shared

/// One generated Markdown file as shown in the memory documents list.
struct IOSMemoryMarkdownDocument: Equatable, Identifiable {
    /// Path relative to the memories directory ("index.md", "topics/3-习惯.md").
    let relativePath: String
    let fileName: String
    /// First `# ` heading text; falls back to the file name.
    let title: String
    /// First meaningful line after the title (blockquote summary, stats line…).
    let preview: String
    let sizeBytes: Int
    let modifiedAt: Date

    var id: String { relativePath }
}

/// Derives human-readable Markdown documents from the memory store:
/// `index.md` (small, recall-friendly) plus one `topics/<id>-<slug>.md` per
/// non-archived topic record. Regeneration is signature-gated — nothing is
/// rewritten when the store content did not change. This is a derived view;
/// `memories.json` remains the source of truth and failures here never roll
/// back a successful persist.
final class IOSMemoryMarkdownStore {
    private let directory: URL
    private let defaults: UserDefaults
    private let signatureKey: String
    private let now: () -> Date

    init(
        directory: URL,
        defaults: UserDefaults = .standard,
        signatureKey: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.defaults = defaults
        // Keyed per directory so sibling stores (fixtures, restored backups)
        // never share a signature and silently skip regeneration.
        self.signatureKey = signatureKey
            ?? "app.amber.ios.memoryMarkdown.signature.v2.\(directory.standardizedFileURL.path)"
        self.now = now
    }

    /// Rewrite the documents only when the projected state changed.
    func syncIfChanged(records: [MemoryRecord]) {
        let signature = Self.signature(of: records)
        guard signature != defaults.string(forKey: signatureKey) else { return }
        do {
            try write(records: records)
            defaults.set(signature, forKey: signatureKey)
        } catch {
            print("[IOSMemoryMarkdownStore] sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Listing

    /// Snapshot of the generated documents: index.md first, then topic files
    /// sorted by their numeric id prefix. Missing directories simply yield [].
    func listDocuments() -> [IOSMemoryMarkdownDocument] {
        let topicsDir = directory.appendingPathComponent("topics", isDirectory: true)
        var docs: [IOSMemoryMarkdownDocument] = []
        if let doc = describe(at: directory.appendingPathComponent("index.md"), relativePath: "index.md") {
            docs.append(doc)
        }
        let topicFiles = (try? FileManager.default.contentsOfDirectory(atPath: topicsDir.path)) ?? []
        let topicDocs = topicFiles
            .filter { $0.hasSuffix(".md") }
            .compactMap { describe(at: topicsDir.appendingPathComponent($0), relativePath: "topics/\($0)") }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        docs.append(contentsOf: topicDocs)
        return docs
    }

    /// Full text of one generated document. `relativePath` is validated to
    /// stay inside the memories directory so callers can't escape it.
    func readDocument(relativePath: String) -> String? {
        let url = directory.appendingPathComponent(relativePath)
        let root = directory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    private func describe(at url: URL, relativePath: String) -> IOSMemoryMarkdownDocument? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var title = url.lastPathComponent
        var preview = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2))
                continue
            }
            if line.hasPrefix("#") { continue }
            preview = Self.previewText(for: line)
            break
        }
        return IOSMemoryMarkdownDocument(
            relativePath: relativePath,
            fileName: url.lastPathComponent,
            title: title,
            preview: preview,
            sizeBytes: values.fileSize ?? data.count,
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    // MARK: - Rendering

    /// Strip list/quote/link decorations so the row preview reads as prose.
    private static func previewText(for line: String) -> String {
        var text = line
        if text.hasPrefix("> ") { text = String(text.dropFirst(2)) }
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        if text.hasPrefix("["),
           let close = text.firstIndex(of: "]"),
           let parenClose = text[close...].firstIndex(of: ")") {
            text = "\(text[text.index(after: text.startIndex)..<close])\(text[text.index(after: parenClose)...])"
        }
        return text
    }

    /// `- 内容` followed by a quiet italic metadata line — the memory itself
    /// stays primary while scope/kind/date drop to a subordinate second line
    /// instead of being jammed into the same bullet.
    private static func memberLine(_ record: MemoryRecord) -> String {
        var meta: [String] = []
        if record.pinned { meta.append("置顶") }
        meta.append(IOSMemoryLibrary.scopeTitle(record.scope))
        meta.append(IOSMemoryLibrary.kindTitle(record.kind))
        meta.append(day(record.updatedAt))
        // 行尾双空格 = CommonMark 硬换行；缩进两格让元信息留在同一列表项内。
        return "- \(record.content)  \n  *\(meta.joined(separator: " · "))*\n"
    }

    /// Rewrite only when the bytes differ so each document's mtime stays the
    /// moment its content last changed, not the last sync.
    private func writeIfChanged(_ body: String, to url: URL) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) != body {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func write(records: [MemoryRecord]) throws {
        let topicsDir = directory.appendingPathComponent("topics", isDirectory: true)
        try FileManager.default.createDirectory(at: topicsDir, withIntermediateDirectories: true)

        let live = records.filter { !$0.archived }
        if live.isEmpty {
            // An empty store gets no documents at all so the UI can show its
            // empty state instead of a stub index.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("index.md"))
            for file in (try? FileManager.default.contentsOfDirectory(atPath: topicsDir.path)) ?? []
            where file.hasSuffix(".md") {
                try? FileManager.default.removeItem(at: topicsDir.appendingPathComponent(file))
            }
            return
        }
        let topics = live
            .filter { $0.kind == .topic }
            .sorted { $0.id < $1.id }
        let byId = Dictionary(uniqueKeysWithValues: records.map { (Int($0.id), $0) })

        var expectedFiles = Set<String>()
        for topic in topics {
            let fileName = "\(topic.id)-\(Self.slug(topic.topicTitle ?? "topic")).md"
            expectedFiles.insert(fileName)
            let members = topic.memberIds
                .map { Int(truncating: $0) }
                .compactMap { byId[$0] }
                .filter { !$0.archived && $0.kind != .topic }
                .sorted { $0.updatedAt > $1.updatedAt }
            var body = "# \(topic.topicTitle ?? "主题")\n\n"
            if !topic.content.isEmpty {
                body += "> \(topic.content)\n\n"
            }
            if members.isEmpty {
                body += "暂无条目。\n"
            } else {
                for member in members {
                    body += Self.memberLine(member)
                }
            }
            try writeIfChanged(body, to: topicsDir.appendingPathComponent(fileName))
        }

        // Stale topic documents are removed so the folder always mirrors the
        // current topic set.
        for file in try FileManager.default.contentsOfDirectory(atPath: topicsDir.path)
        where file.hasSuffix(".md") && !expectedFiles.contains(file) {
            try? FileManager.default.removeItem(at: topicsDir.appendingPathComponent(file))
        }

        // Coverage counts resolved members only — dangling or archived
        // memberIds must not inflate the index summary.
        let groupedIds = Set(topics.flatMap { topic in
            topic.memberIds.map { Int(truncating: $0) }.filter { id in
                guard let member = byId[id] else { return false }
                return !member.archived && member.kind != .topic
            }
        })
        let ungrouped = live
            .filter { $0.kind != .topic && !groupedIds.contains(Int($0.id)) }
            .sorted { $0.updatedAt > $1.updatedAt }
        var index = "# Amber 记忆索引\n\n<!-- generated \(ISO8601DateFormatter().string(from: now())); do not edit -->\n\n"
        // 概览行放最前——打开索引先看到总量，而不是先翻主题列表。
        index += "共 \(groupedIds.count + ungrouped.count) 条记忆 · \(topics.count) 个主题 · \(ungrouped.count) 条未归类\n\n"
        index += "## 主题\n\n"
        if topics.isEmpty {
            index += "暂无主题。\n\n"
        } else {
            for topic in topics {
                let fileName = "\(topic.id)-\(Self.slug(topic.topicTitle ?? "topic")).md"
                index += "- [\(topic.topicTitle ?? "主题")](topics/\(fileName)) — \(topic.memberIds.count) 条\n"
            }
            index += "\n"
        }
        index += "## 未归类\n\n"
        if ungrouped.isEmpty {
            index += "暂无。\n"
        } else {
            for record in ungrouped {
                index += Self.memberLine(record)
            }
        }
        try writeIfChanged(index, to: directory.appendingPathComponent("index.md"))
    }

    private static func signature(of records: [MemoryRecord]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in records
            .sorted(by: { $0.id < $1.id })
            .map({ record in
                "\(record.id)|\(record.updatedAt)|\(record.archived)|\(record.kind.wireName)|\(record.scope.wireName)|\(record.topicTitle ?? "")|\(record.memberIds.map { "\(Int(truncating: $0))" }.joined(separator: ","))|\(record.content)"
            })
            .joined(separator: "\n")
            .utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Keep CJK and alphanumerics, collapse everything else to '-'.
    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var slug = ""
        var lastWasDash = false
        for char in lowered {
            if char.isLetter || char.isNumber {
                slug.append(char)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 24 { slug = String(slug.prefix(24)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "topic" : slug
    }

    private static func day(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1_000))
    }
}
