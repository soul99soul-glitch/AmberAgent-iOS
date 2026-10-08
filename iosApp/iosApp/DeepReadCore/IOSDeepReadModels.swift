import Foundation

enum IOSDeepReadTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case unsupported

    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .unsupported
    }

    var title: String {
        switch self {
        case .queued: "待生成"
        case .running: "生成中"
        case .succeeded: "已完成"
        case .failed: "失败"
        case .unsupported: "不可用"
        }
    }

    /// `title` is also used by persisted/generated content and therefore stays
    /// in its canonical form. This variant is for display-only surfaces.
    var localizedTitle: String {
        IOSAppLocalization.string(title, defaultValue: title)
    }
}

enum IOSDeepReadSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case manualText = "manual_text"
    case searchResult = "search_result"
    case conversation
    case file
    case webMount = "web_mount"
    case hotTopic = "hot_topic"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manualText: "手动文本"
        case .searchResult: "搜索结果"
        case .conversation: "会话内容"
        case .file: "文件"
        case .webMount: IOSAppLocalization.string("WebMount", defaultValue: "WebMount")
        case .hotTopic: "热榜主题"
        }
    }

    /// `title` remains the canonical source label used by storage and prompts;
    /// callers rendering a source label should use this display-only variant.
    var localizedTitle: String {
        IOSAppLocalization.string(title, defaultValue: title)
    }
}

struct IOSDeepReadSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: IOSDeepReadSourceKind
    var title: String
    var content: String
    var url: String?
    var metadata: [String: String]
    var createdAt: Int64

    var hasUsableGenerationContent: Bool {
        guard metadata["scrape_status"] != "failed", !content.isEmpty else { return false }
        // Hot-list records contain only titles/ranks until their page has been read.
        if kind == .hotTopic { return metadata["scrape_status"] == "ok" }
        if kind == .searchResult { return content != url }
        return true
    }

    init(
        id: String = UUID().uuidString,
        kind: IOSDeepReadSourceKind,
        title: String,
        content: String,
        url: String? = nil,
        metadata: [String: String] = [:],
        createdAt: Int64 = IOSDeepReadClock.currentEpochMs()
    ) {
        self.id = id
        self.kind = kind
        self.title = IOSDeepReadSourceNormalizer.clean(title).deepReadPrefixString(160).deepReadIfEmpty(kind.title)
        self.content = IOSDeepReadSourceNormalizer.cleanMultiline(content).deepReadPrefixString(40_000)
        self.url = IOSDeepReadSourceNormalizer.clean(url ?? "").deepReadIfBlankNil
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

struct IOSDeepReadTask: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: IOSDeepReadTaskStatus
    var templateId: String
    var sources: [IOSDeepReadSource]
    var resultMarkdown: String
    var failureMessage: String?
    var createdAt: Int64
    var updatedAt: Int64
    var completedAt: Int64?
    var retryCount: Int
    /// Serialized `IOSDeepReadOutput` JSON when the LLM produced structured output;
    /// the reader renders the rich editorial cards from it. nil → flat-markdown reader.
    /// Optional so old persisted tasks decode unchanged.
    var structuredJSON: String? = nil
    /// Non-nil when the reading itself succeeded but the best-effort Workspace
    /// artifact sync failed. Persisted because true background execution has no
    /// live status closure to surface this problem.
    var workspaceSyncFailed: String? = nil
    /// Stage labels that produced no usable content when the run completed
    /// (partial completion — Android's per-section FAILED analogue). Optional so
    /// old persisted tasks decode unchanged; nil/empty = every stage contributed.
    var missingSections: [String]? = nil

    var sourceSummary: String {
        let counts = Dictionary(grouping: sources, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.title) \($0.value)" }
        return counts.joined(separator: " · ")
    }

    /// Display-only counterpart of `sourceSummary`; the canonical summary is
    /// retained for generated/persisted content.
    var localizedSourceSummary: String {
        let counts = Dictionary(grouping: sources, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map {
                "\(IOSAppLocalization.string($0.key.title, defaultValue: $0.key.title)) \($0.value)"
            }
        return counts.joined(separator: " · ")
    }

    var template: IOSDeepReadTemplate {
        IOSDeepReadTemplate.template(id: templateId)
    }
}

