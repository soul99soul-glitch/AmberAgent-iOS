import Foundation
import Observation
@preconcurrency import Shared

enum IOSMemoryScopeFilter: String, CaseIterable, Identifiable {
    case all
    case core
    case shortTerm
    case longTerm
    /// Archived atomic records (superseded, invalidated, expired or long unused),
    /// shown only here so the user can review or restore them.
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .core: "核心"
        case .shortTerm: "短期"
        case .longTerm: "长期"
        case .archived: "已归档"
        }
    }

    func includes(_ scope: MemoryScope) -> Bool {
        switch self {
        case .all, .archived:
            true
        case .core:
            scope == MemoryScope.core
        case .shortTerm:
            scope == MemoryScope.shortTerm
        case .longTerm:
            scope == MemoryScope.longTerm
        }
    }
}

enum IOSMemoryLibrary {
    static func filteredRecords(
        records: [MemoryRecord],
        query: String,
        scopeFilter: IOSMemoryScopeFilter
    ) -> [MemoryRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records
            // 已归档记录不出现在活跃列表，只在"已归档"筛选下供查看与恢复；
            // 退役主题由整理流程维护，不进归档列表。
            .filter { scopeFilter == .archived ? ($0.archived && $0.kind != .topic) : !$0.archived }
            .filter { scopeFilter.includes($0.scope) }
            .filter { record in
                guard !trimmedQuery.isEmpty else { return true }
                if record.content.localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if record.topicTitle?.localizedCaseInsensitiveContains(trimmedQuery) == true { return true }
                // 界面上显示的标签与来源文案（"短期""用户""来自聊天"）也能搜到。
                if scopeTitle(record.scope).localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if kindTitle(record.kind).localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if sourceSummary(record).localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if record.scope.wireName.localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if record.kind.wireName.localizedCaseInsensitiveContains(trimmedQuery) { return true }
                if record.sourceConversationId?.localizedCaseInsensitiveContains(trimmedQuery) == true { return true }
                return record.sourceMessageIds.contains {
                    $0.localizedCaseInsensitiveContains(trimmedQuery)
                }
            }
            .sorted(by: memorySort)
    }

    static func recallCandidates(
        records: [MemoryRecord],
        runtime: AgentRuntimeSetting,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [MemoryRecord] {
        ChatMemoryContextBuilder.contextPromptResult(
            records: ChatMemoryContextBuilder.recordsForPrompt(records: records, runtime: runtime),
            runtime: runtime,
            queryText: "",
            now: nowMillis
        ).records
    }

    static func recallExplanation(
        records: [MemoryRecord],
        runtime: AgentRuntimeSetting
    ) -> String {
        let candidates = recallCandidates(records: records, runtime: runtime)
        let enabledScopes = [
            runtime.enableCoreMemory ? "核心" : nil,
            runtime.enableShortTermMemory ? "短期" : nil,
            runtime.enableLongTermMemory ? "长期" : nil,
        ].compactMap { $0 }
        guard !candidates.isEmpty else {
            if enabledScopes.isEmpty {
                return "当前没有启用的记忆范围，聊天不会注入记忆。"
            }
            return "已启用 \(enabledScopes.joined(separator: "、"))，但没有可召回的未归档、未过期记忆。"
        }
        let maxItems = min(max(Int(runtime.memoryRecall.maxItems), 1), 40)
        let maxChars = min(max(Int(runtime.memoryRecall.maxPromptChars), 256), 12_000)
        return "聊天会从 \(enabledScopes.joined(separator: "、")) 中按当前问题相关性、置顶和记忆类型选择，单轮最多 \(maxItems) 条、\(maxChars) 字符。"
    }

    static func scopeTitle(_ scope: MemoryScope) -> String {
        if scope == MemoryScope.core { return "核心" }
        if scope == MemoryScope.shortTerm { return "短期" }
        if scope == MemoryScope.longTerm { return "长期" }
        return scope.wireName
    }

    static func kindTitle(_ kind: MemoryKind) -> String {
        kindDisplay(kind.wireName)
    }

    static func scopeDisplay(_ raw: String) -> String {
        switch raw.lowercased() {
        case "core": "核心"
        case "short_term": "短期"
        case "long_term": "长期"
        case "topic": "话题"
        case "experience", "lesson": "经验"
        default: raw
        }
    }

    static func kindDisplay(_ raw: String) -> String {
        switch raw.lowercased() {
        case "user": "用户"
        case "feedback": "反馈"
        case "project": "项目"
        case "reference": "资料"
        case "routine": "习惯"
        case "note": "笔记"
        case "topic": "主题"
        case "experience", "lesson": "经验"
        default: raw
        }
    }

    /// 可扩展的主类型徽章描述（短期 / 长期 / 核心 / 话题 / 经验，兼容未来新增类型）。
    static func primaryTypeTitle(for record: MemoryRecord) -> String {
        let kindWire = record.kind.wireName.lowercased()
        if kindWire == "topic" {
            return "话题"
        }
        if kindWire == "experience" || kindWire == "lesson" {
            return "经验"
        }
        return scopeTitle(record.scope)
    }

    /// 次级细分标签（例如「项目」「习惯」「反馈」；若主类型已是「话题」或「经验」且重复则省略）。
    static func secondaryKindTitle(for record: MemoryRecord) -> String? {
        let kindWire = record.kind.wireName.lowercased()
        if kindWire == "topic" || kindWire == "experience" || kindWire == "lesson" {
            return nil
        }
        return kindTitle(record.kind)
    }

    /// 来源对话展示文案（优先使用已解析的会话标题，不暴露内部 conversation UUID）。
    static func sourceDisplay(
        for record: MemoryRecord,
        conversationTitles: [String: String] = [:]
    ) -> String {
        if record.kind == .topic {
            return "由记忆整理自动聚合"
        }
        var parts: [String] = []
        if let convId = record.sourceConversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !convId.isEmpty {
            if let rawTitle = conversationTitles[convId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawTitle.isEmpty {
                let shortTitle = rawTitle.count > 18 ? String(rawTitle.prefix(17)) + "…" : rawTitle
                parts.append("来自对话「\(shortTitle)」")
            } else {
                parts.append("来自聊天对话")
            }
        } else {
            parts.append("手动或工具记入")
        }
        if !record.sourceMessageIds.isEmpty {
            parts.append("关联 \(record.sourceMessageIds.count) 条消息")
        }
        if !record.supersedesIds.isEmpty {
            parts.append("替代 \(record.supersedesIds.count) 条旧记忆")
        }
        return parts.joined(separator: " · ")
    }

    /// 最近被用到的时间展示文案（无记录时显示「尚未被引用」）。
    static func lastUsedDisplay(
        for record: MemoryRecord,
        now: Date = Date()
    ) -> (text: String, hasBeenUsed: Bool) {
        guard let millis = record.lastUsedAt?.int64Value, millis > 0 else {
            return ("尚未被引用", false)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 {
            return ("最近使用：刚刚", true)
        } else if interval < 3_600 {
            return ("最近使用：\(Int(interval / 60)) 分钟前", true)
        } else if interval < 86_400 {
            return ("最近使用：\(Int(interval / 3_600)) 小时前", true)
        } else if interval < 86_400 * 30 {
            return ("最近使用：\(Int(interval / 86_400)) 天前", true)
        } else {
            let formatter = DateFormatter()
            formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
            formatter.dateFormat = "yyyy-MM-dd"
            return ("最近使用：\(formatter.string(from: date))", true)
        }
    }

    static func actionDisplay(_ raw: String) -> String {
        switch raw {
        case "create", "add", "write": "新增"
        case "edit", "update": "修改"
        case "delete", "remove": "删除"
        case "restore": "恢复"
        case "invalidate": "作废"
        case "extract": "自动提炼"
        case "consolidate": "自动整理"
        case "topic": "主题聚合"
        case "profile": "用户画像"
        default: raw
        }
    }

    /// "N 条记忆" everywhere counts live atomic memories: topics are groupings,
    /// not memories (matches the index.md summary).
    static func liveMemoryCount(_ records: [MemoryRecord]) -> Int {
        records.filter { !$0.archived && $0.kind != .topic }.count
    }

    /// Topic members that still resolve to live records; archived, superseded
    /// or deleted members are not counted (matches the topic detail page).
    static func liveMemberCount(of topic: MemoryRecord, in records: [MemoryRecord]) -> Int {
        let memberIds = Set(topic.memberIds.map { Int(truncating: $0) })
        return records.filter { memberIds.contains(Int($0.id)) && !$0.archived && $0.kind != .topic }.count
    }

    static func sourceSummary(_ record: MemoryRecord) -> String {
        // 用户面不暴露 conversation UUID / 内部 id；只保留可读来源语义。
        var parts: [String] = []
        if let sourceConversationId = record.sourceConversationId, !sourceConversationId.isEmpty {
            parts.append("来自聊天")
        }
        if !record.sourceMessageIds.isEmpty {
            parts.append("关联 \(record.sourceMessageIds.count) 条消息")
        }
        if !record.supersedesIds.isEmpty {
            parts.append("替代 \(record.supersedesIds.count) 条旧记忆")
        }
        return parts.isEmpty ? "手动或工具写入，未记录来源" : parts.joined(separator: " · ")
    }

    static func preview(_ text: String, limit: Int = 180) -> String {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    private static func memorySort(lhs: MemoryRecord, rhs: MemoryRecord) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

struct IOSMemoryWriteAuditRecord: Codable, Identifiable, Equatable {
    var id: String
    var action: String
    var status: String
    var reason: String
    var memoryId: Int?
    var scope: String?
    var kind: String?
    var contentPreview: String?
    var createdAt: Int64
}

@MainActor
@Observable
final class IOSMemoryWriteAuditStore {
    static let shared = IOSMemoryWriteAuditStore()

    private let defaults: UserDefaults
    private let key: String
    private let limit = 80

    private(set) var records: [IOSMemoryWriteAuditRecord]

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "app.amber.ios.memoryWriteAudit.v1"
    ) {
        self.defaults = userDefaults
        self.key = key
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([IOSMemoryWriteAuditRecord].self, from: data) {
            self.records = decoded
        } else {
            self.records = []
        }
    }

    func record(
        action: String,
        status: String,
        reason: String = "",
        memoryId: Int? = nil,
        scope: String? = nil,
        kind: String? = nil,
        contentPreview: String? = nil
    ) {
        records.insert(
            IOSMemoryWriteAuditRecord(
                id: UUID().uuidString,
                action: action,
                status: status,
                reason: reason,
                memoryId: memoryId,
                scope: scope,
                kind: kind,
                contentPreview: contentPreview,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            at: 0
        )
        if records.count > limit {
            records = Array(records.prefix(limit))
        }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Wiki 页面相对路径链接解析器

/// 解析记忆 Wiki 页面内的标准相对路径链接（如 `[习惯](topics/3-习惯.md)`、`[返回](../index.md)`），
/// 并限制在记忆文档根目录下，拒绝越界路径（`..` 逃逸）与外部 URL。
enum MemoryWikiLinkResolver {
    static let scheme = "amber-memory-doc"

    /// 将 Markdown 中的相对路径编码为内部 `amber-memory-doc://open?href=...` URL。
    static func encodeRelativeHref(_ rawHref: String) -> URL? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.contains("://"),
              !trimmed.lowercased().hasPrefix("mailto:"),
              !trimmed.lowercased().hasPrefix("javascript:"),
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let pathPart = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let cleanPath = pathPart.removingPercentEncoding ?? pathPart
        guard cleanPath.lowercased().hasSuffix(".md") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "href", value: cleanPath)]
        return components.url
    }

    /// 从内部 URL 与当前所在文档的 `currentRelativePath` 解析出目标标准相对路径與展示标题。
    static func resolveTarget(from url: URL, currentRelativePath: String) -> (relativePath: String, title: String)? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHref = components.queryItems?.first(where: { $0.name == "href" })?.value else {
            return nil
        }
        return resolveRelativePath(href: rawHref, from: currentRelativePath)
    }

    /// 基于当前文档相对路径（如 `"index.md"` 或 `"topics/3-习惯.md"`）解析相对链接。
    static func resolveRelativePath(href: String, from currentRelativePath: String) -> (relativePath: String, title: String)? {
        let trimmed = (href.removingPercentEncoding ?? href).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("://") else {
            return nil
        }
        let pathOnly = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        guard pathOnly.lowercased().hasSuffix(".md") else { return nil }

        var baseParts = currentRelativePath.split(separator: "/").map(String.init)
        if !baseParts.isEmpty {
            baseParts.removeLast()
        }

        // 若链接本身已是以 `topics/` 开头的仓库内标准相对路径或顶层 `index.md`，直接从根解析；
        // 若以 `./` 或 `../` 开头，则相对于当前文档所在目录解析。
        let startsAtRoot = pathOnly == "index.md" || pathOnly.hasPrefix("topics/")
        var stack: [String] = startsAtRoot ? [] : baseParts

        for segment in pathOnly.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if segment.isEmpty || segment == "." {
                continue
            }
            if segment == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else {
                stack.append(segment)
            }
        }

        guard !stack.isEmpty else { return nil }
        let normalized = stack.joined(separator: "/")
        let fileName = stack.last ?? normalized
        let title = displayTitle(forRelativePath: normalized, fallbackFileName: fileName)
        return (normalized, title)
    }

    static func displayTitle(forRelativePath relativePath: String, fallbackFileName: String? = nil) -> String {
        if relativePath == "index.md" {
            return "Amber 记忆索引"
        }
        let name = fallbackFileName ?? (relativePath as NSString).lastPathComponent
        let withoutExt = name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        // 去掉 `3-习惯` 前面的数字序号前缀，展示为 `习惯`
        if let dashIndex = withoutExt.firstIndex(of: "-"),
           withoutExt[..<dashIndex].allSatisfy(\.isNumber) {
            let slug = String(withoutExt[withoutExt.index(after: dashIndex)...])
            if !slug.isEmpty { return slug }
        }
        return withoutExt.isEmpty ? relativePath : withoutExt
    }
}

// MARK: - 「记忆体检」展示模型（支持空数据与核心线程注入）

struct MemoryHealthCheckSnapshot: Equatable, Sendable {
    /// 被取代比例（0.0 ... 1.0），nil 表示暂无统计数据。
    var supersededRatio: Double?
    /// 被引用比例（0.0 ... 1.0），nil 表示暂无统计数据。
    var citedRatio: Double?
    /// 常驻注入字数，nil 表示暂无统计数据。
    var residentInjectedChars: Int?
    /// 常驻注入预算上限（可选，用于辅助显示对比）。
    var maxPromptCharsBudget: Int?

    static let empty = MemoryHealthCheckSnapshot(
        supersededRatio: nil,
        citedRatio: nil,
        residentInjectedChars: nil,
        maxPromptCharsBudget: nil
    )

    var hasAnyMetric: Bool {
        supersededRatio != nil || citedRatio != nil || residentInjectedChars != nil
    }

    var hasData: Bool {
        hasAnyMetric
    }

    var supersededText: String {
        guard let supersededRatio else { return "—" }
        let clamped = min(max(supersededRatio, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    var supersededRatioText: String {
        supersededText
    }

    var citedText: String {
        guard let citedRatio else { return "—" }
        let clamped = min(max(citedRatio, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    var citedRatioText: String {
        citedText
    }

    var residentCharsText: String {
        guard let residentInjectedChars else { return "—" }
        return "\(max(0, residentInjectedChars)) 字"
    }

    var residentBudgetText: String? {
        guard let maxPromptCharsBudget, maxPromptCharsBudget > 0 else { return nil }
        return "上限 \(maxPromptCharsBudget) 字"
    }
}
