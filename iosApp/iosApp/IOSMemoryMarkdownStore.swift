import Foundation
@preconcurrency import Shared

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
            ?? "app.amber.ios.memoryMarkdown.signature.v1.\(directory.standardizedFileURL.path)"
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

    // MARK: - Rendering

    private func write(records: [MemoryRecord]) throws {
        let topicsDir = directory.appendingPathComponent("topics", isDirectory: true)
        try FileManager.default.createDirectory(at: topicsDir, withIntermediateDirectories: true)

        let live = records.filter { !$0.archived }
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
            var body = "# \(topic.topicTitle ?? "主题")\n\n"
            if !topic.content.isEmpty {
                body += "> \(topic.content)\n\n"
            }
            for member in members {
                body += "- (memory:\(member.id), \(member.scope.wireName)/\(member.kind.wireName), \(Self.day(member.updatedAt))) \(member.content)\n"
            }
            try body.write(to: topicsDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }

        // Stale topic documents are removed so the folder always mirrors the
        // current topic set.
        for file in try FileManager.default.contentsOfDirectory(atPath: topicsDir.path)
        where file.hasSuffix(".md") && !expectedFiles.contains(file) {
            try? FileManager.default.removeItem(at: topicsDir.appendingPathComponent(file))
        }

        let groupedIds = Set(topics.flatMap { $0.memberIds.map { Int(truncating: $0) } })
        let ungrouped = live.filter { $0.kind != .topic && !groupedIds.contains(Int($0.id)) }
        var index = "# Amber 记忆索引\n\n<!-- generated \(ISO8601DateFormatter().string(from: now())); do not edit -->\n\n"
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
        index += "未归档 \(live.count) 条 · 主题 \(topics.count) 个覆盖 \(groupedIds.count) 条 · 未归类 \(ungrouped.count) 条\n"
        try index.write(to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
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
