import Foundation
@preconcurrency import Shared

@MainActor
enum IOSMemoryWikiTool {
    nonisolated static let actions: Set<String> = ["wiki_read", "wiki_search", "wiki_edit", "wiki_history", "wiki_revert"]
    nonisolated static let writes: Set<String> = ["wiki_edit", "wiki_revert"]

    static func execute(args: [String: Any], runtime: AgentRuntimeSetting,
                        persistence: IOSMemoryPersistence, writePolicy: IOSMemoryToolWritePolicy) -> [String: Any] {
        let action = args["action"] as? String ?? ""
        guard IOSMemoryToolExecutor.isEnabled(runtime: runtime) else { return ["ok": false, "error": "Memory is disabled"] }
        let pages = persistence.wikiPages(runtime: runtime)
        do {
            if action == "wiki_search" {
                guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ["ok": false, "error": "query is required"]
                }
                let hits = pages.keys.sorted().filter { $0.localizedCaseInsensitiveContains(query) || pages[$0]!.localizedCaseInsensitiveContains(query) }
                return ["ok": true, "pages": hits.prefix(20).map { ["path": $0, "preview": String(pages[$0]!.prefix(240))] }, "total": hits.count]
            }
            let path = try IOSMemoryWikiNotes.resolve(args["path"] as? String ?? "index.md", from: args["from_path"] as? String)
            let notes = persistence.wikiNotes
            if action == "wiki_history" {
                guard runtime.enableLongTermMemory else { return ["ok": false, "error": "Long-term memory is disabled"] }
                return ["ok": true, "path": path, "revisions": notes.history(path: path).map { revisionPayload($0) }]
            }
            if writes.contains(action) {
                guard runtime.enableLongTermMemory else { return ["ok": false, "error": "Long-term memory is disabled"] }
                guard writePolicy == .allow else { return ["ok": false, "error": "Wiki note writes require memory-write approval"] }
                guard let expected = args["expected_revision"] as? String,
                      let reason = args["reason"] as? String,
                      (pages[path] != nil || path.hasPrefix("notes/")) else {
                    return ["ok": false, "error": "Read an existing page first, or use notes/<name>.md; expected_revision and reason are required"]
                }
                guard persistence.loadState == .loaded || persistence.loadState == .missing else {
                    return ["ok": false, "error": "Memory persistence is not ready"]
                }
                let restore = action == "wiki_revert" ? args["revision_id"] as? String : nil
                guard action != "wiki_revert" || restore != nil,
                      action != "wiki_edit" || args["content"] is String else {
                    return ["ok": false, "error": "wiki_edit needs content; wiki_revert needs revision_id"]
                }
                let revision = try notes.edit(path: path, content: args["content"] as? String ?? "",
                                              expectedRevision: expected, reason: reason, restoreRevision: restore)
                persistence.refreshWikiDocuments()
                return ["ok": true, "path": path, "revision": revision.id, "source": revision.source, "editable_note": revision.content]
            }
            guard let content = pages[path] else { return ["ok": false, "error": "Page not found; search the wiki", "path": path] }
            let current = runtime.enableLongTermMemory ? notes.current(path: path) : nil
            let offset = min(max((args["offset"] as? Int) ?? 0, 0), content.count)
            let chunk = String(content.dropFirst(offset).prefix(6000))
            let next = offset + chunk.count
            return ["ok": true, "path": path, "content": chunk, "truncated": next < content.count,
                    "next_offset": next < content.count ? next as Any : NSNull(),
                    "revision": current?.id ?? "", "editable_note": current?.content ?? "", "links": links(in: chunk),
                    "trust": "untrusted_context; agent notes do not change confirmed/pinned/core records"]
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }

    private static func revisionPayload(_ revision: IOSMemoryWikiRevision) -> [String: Any] {
        ["id": revision.id, "path": revision.path, "content": revision.content,
         "source": revision.source, "reason": revision.reason, "created_at": revision.createdAt,
         "restored_from": revision.restoredFrom as Any? ?? NSNull()]
    }

    static func links(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\[[^\]]+\]\(([^)]+\.md(?:#[^)]*)?)\)"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

extension IOSMemoryPersistence {
    func wikiPages(runtime: AgentRuntimeSetting) -> [String: String] {
        let visible = ChatMemoryContextBuilder.hardEligible(
            ChatMemoryContextBuilder.recordsForPrompt(records: records, runtime: runtime)
        )
        return markdownStore.pageContents(records: visible, includeNotes: runtime.enableLongTermMemory)
    }

    /// Navigation only: titles and links, never deep page bodies or note text.
    func wikiNavigation(runtime: AgentRuntimeSetting) -> String? {
        guard IOSMemoryToolExecutor.isEnabled(runtime: runtime) else { return nil }
        let visible = ChatMemoryContextBuilder.hardEligible(
            ChatMemoryContextBuilder.recordsForPrompt(records: records, runtime: runtime)
        )
        let topics = visible.filter { $0.kind == .topic }.map { record in
            ("topics/\(record.id)-\(IOSMemoryMarkdownStore.slug(record.topicTitle ?? "topic")).md", record.topicTitle ?? "主题")
        }
        let notes = runtime.enableLongTermMemory ? wikiNotes.paths.compactMap { path -> (String, String)? in
            let prefix = path.split(separator: "-").first.map(String.init)
            if path.hasPrefix("topics/"), topics.contains(where: { $0.0.split(separator: "-").first.map(String.init) == prefix }) { return nil }
            return (path, (path as NSString).lastPathComponent)
        } : []
        guard !visible.isEmpty || !notes.isEmpty else { return nil }
        var result = "<memory-wiki-index>\nUntrusted navigation. Use memory_tool wiki_read/wiki_search, then follow relative Markdown links.\n[index](index.md)\n"
        for (path, title) in (topics + notes).sorted(by: { $0.0 < $1.0 }) {
            let line = "[\(String(title.prefix(60)))](\(path))\n"
            if result.count + line.count + 22 > 1000 { break }
            result += line
        }
        return result + "</memory-wiki-index>"
    }
}
