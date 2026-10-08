import Foundation

enum IOSDeepReadSourceNormalizationError: LocalizedError, Equatable {
    case emptySource(IOSDeepReadSourceKind)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .emptySource(let kind):
            return IOSAppLocalization.formatted(
                "%@没有可读取内容。",
                defaultValue: "%@没有可读取内容。",
                arguments: [kind.localizedTitle]
            )
        case .unsupported(let reason):
            return IOSDeepReadUserFacingText.sanitize(reason)
        }
    }
}

/// 深度阅读用户可见文案：尽量中文，避免把系统/SDK 英文错误直接抛到界面。
enum IOSDeepReadUserFacingText {
    static func fromError(_ error: Error) -> String {
        if let sourceError = error as? IOSDeepReadSourceNormalizationError {
            return sourceError.errorDescription ?? localized("操作失败，请稍后重试。")
        }
        if let access = error as? DocumentAccessError {
            switch access {
            case .missingGrant:
                return localized("请先选择文件。")
            case .grantMismatch:
                return localized("所选文件授权不匹配，请重新选择文件。")
            case .expiredGrant:
                return localized("文件授权已失效，请重新选择文件。")
            case .fileMissing:
                return localized("文件已不存在，请从文件 App 重新选择。")
            case .fileTooLarge:
                return localized("文件过大，超出导入限制。")
            case .unknownFileSize:
                return localized("无法确认文件大小，请选择普通文件后重试。")
            case .alreadyReading:
                return localized("正在读取该文件，请稍候。")
            case .unsupportedFileType(let message), .noReadableText(let message):
                return sanitize(message)
            case .readFailed(let message):
                return IOSAppLocalization.formatted(
                    "读取文件失败：%@",
                    defaultValue: "读取文件失败：%@",
                    arguments: [sanitize(message)]
                )
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return sanitize(description)
        }
        return sanitize(error.localizedDescription)
    }

    /// 清洗任意原始错误串；已知固定提示按当前语言返回，带详情的中文文案保留，常见英文映射为当前语言，否则给通用句。
    static func sanitize(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return localized("操作失败，请稍后重试。") }

        // 去掉夹杂的 debug 英文尾巴（如 threw=2, unusable=1），再把已知的
        // 固定中文提示重新映射到当前语言；带有任务/来源详情的文案仍原样保留。
        let cleaned = text
            .replacingOccurrences(
                of: #"\s*\(threw=\d+,\s*unusable=\d+\)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch cleaned {
        case "操作失败，请稍后重试。",
             "网络不可用，请检查连接后重试。",
             "请求超时，请稍后重试。",
             "操作已取消。",
             "鉴权失败，请检查 API Key 或登录状态。",
             "没有权限执行此操作。",
             "未找到相关资源。",
             "请求过于频繁，请稍后重试。",
             "服务暂时不可用，请稍后重试。",
             "安全连接失败，请稍后重试。",
             "返回内容无法解析。",
             "文件不存在或无法读取。",
             "Workspace 保存失败，请稍后重试。",
             "文件中没有可读取文本。",
             "当前站点页面没有可读取正文；请先打开站点并确认页面已加载。",
             "深度阅读生成未在单轮内完成。",
             "上次深度阅读生成被中断，可重试。",
             "模型调用全部失败，请检查网络、API Key 或模型配置后重试。",
             "未能生成可用的深度阅读内容，请换个来源或模型后重试。":
            return localized(cleaned)
        default:
            break
        }
        let generationFailurePrefix = "深度阅读生成失败："
        if cleaned.hasPrefix(generationFailurePrefix) {
            return IOSAppLocalization.formatted(
                "深度阅读生成失败：%@",
                defaultValue: "深度阅读生成失败：%@",
                arguments: [String(cleaned.dropFirst(generationFailurePrefix.count))]
            )
        }
        if containsCJK(cleaned) {
            return cleaned
        }

        let lower = cleaned.lowercased()
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet")
            || lower.contains("not connected") || lower.contains("connection") {
            return localized("网络不可用，请检查连接后重试。")
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("time out") {
            return localized("请求超时，请稍后重试。")
        }
        if lower.contains("cancel") {
            return localized("操作已取消。")
        }
        if lower.contains("unauthorized") || lower.contains("api key") || lower.contains("401")
            || lower.contains("invalid api") || lower.contains("authentication") {
            return localized("鉴权失败，请检查 API Key 或登录状态。")
        }
        if lower.contains("forbidden") || lower.contains("403") || lower.contains("permission") {
            return localized("没有权限执行此操作。")
        }
        if lower.contains("not found") || lower.contains("404") {
            return localized("未找到相关资源。")
        }
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many") {
            return localized("请求过于频繁，请稍后重试。")
        }
        if lower.contains("500") || lower.contains("502") || lower.contains("503")
            || lower.contains("server error") || lower.contains("internal error") {
            return localized("服务暂时不可用，请稍后重试。")
        }
        if lower.contains("ssl") || lower.contains("certificate") || lower.contains("secure connection") {
            return localized("安全连接失败，请稍后重试。")
        }
        if lower.contains("json") || lower.contains("decode") || lower.contains("parse") {
            return localized("返回内容无法解析。")
        }
        if lower.contains("no such file") || lower.contains("file") && lower.contains("exist") {
            return localized("文件不存在或无法读取。")
        }
        if lower.contains("workspace") {
            return localized("Workspace 保存失败，请稍后重试。")
        }
        return localized("操作失败，请稍后重试。")
    }

    private static func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            let v = $0.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        }
    }
}

enum IOSDeepReadSourceNormalizer {
    static func manualText(title: String, text: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> IOSDeepReadSource {
        let content = cleanMultiline(text)
        guard !content.isEmpty else { throw IOSDeepReadSourceNormalizationError.emptySource(.manualText) }
        return IOSDeepReadSource(
            kind: .manualText,
            title: clean(title).deepReadIfEmpty(firstLineTitle(content, fallback: "手动深度阅读")),
            content: content,
            createdAt: now
        )
    }

    /// A synthetic source representing a FAILED search — a distinct,
    /// machine-readable source-failure state (`scrape_status="failed"`, matching
    /// the scrape-enrichment convention) so a failed search is not silently
    /// indistinguishable from real manual content. The Deep Read source-collection
    /// catch path and its test both build the failed source via this, so the
    /// marker is exercised end-to-end (closes the deepread search-failure fake-green:
    /// the generator excludes scrape_status=failed sources from the factual block).
    static func searchFailureSource(query: String, error: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> IOSDeepReadSource {
        var source = try manualText(
            title: "搜索不可用：\(query)",
            text: "搜索来源未能读取：\(error)",
            now: now
        )
        source.metadata["scrape_status"] = "failed"
        return source
    }

    static func searchSources(query: String, results: [IOSSearchResult], now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> [IOSDeepReadSource] {
        let cleanQuery = clean(query)
        let sources = results.enumerated().compactMap { index, result -> IOSDeepReadSource? in
            let content = cleanMultiline([
                result.snippet,
                result.url
            ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n"))
            guard !content.isEmpty else { return nil }
            var metadata = [
                "query": cleanQuery,
                "rank": "\(index + 1)"
            ]
            // Carry the first usable provider image (e.g. a Brave thumbnail) so the
            // editorial reader can source a hero. Stored in metadata to avoid a
            // schema change to the persisted IOSDeepReadSource.
            if let image = result.images.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                metadata["hero_image_url"] = image
            }
            return IOSDeepReadSource(
                kind: .searchResult,
                title: result.title.deepReadIfEmpty("搜索结果 \(index + 1)"),
                content: content,
                url: result.url,
                metadata: metadata,
                createdAt: now
            )
        }
        guard !sources.isEmpty else { throw IOSDeepReadSourceNormalizationError.emptySource(.searchResult) }
        return sources
    }

    static func conversationSource(title: String, messages: [String], now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> IOSDeepReadSource {
        let content = cleanMultiline(messages.joined(separator: "\n\n"))
        guard !content.isEmpty else { throw IOSDeepReadSourceNormalizationError.emptySource(.conversation) }
        return IOSDeepReadSource(
            kind: .conversation,
            title: clean(title).deepReadIfEmpty("当前会话"),
            content: content,
            metadata: ["message_count": "\(messages.count)"],
            createdAt: now
        )
    }

    static func fileSource(_ read: SelectedDocumentReadResult, now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> IOSDeepReadSource {
        let content = cleanMultiline(read.preview)
        guard !content.isEmpty else {
            throw IOSDeepReadSourceNormalizationError.unsupported(read.note ?? "文件中没有可读取文本。")
        }
        return IOSDeepReadSource(
            kind: .file,
            title: read.fileName,
            content: content,
            metadata: [
                "file_type": read.fileType,
                "bytes": "\(read.bytesRead)",
                "truncated": "\(read.isTruncated)"
            ],
            createdAt: now
        )
    }

    static func webMountSource(title: String, url: String?, text: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> IOSDeepReadSource {
        let content = cleanMultiline(text)
        guard !content.isEmpty else {
            throw IOSDeepReadSourceNormalizationError.unsupported("当前站点页面没有可读取正文；请先打开站点并确认页面已加载。")
        }
        return IOSDeepReadSource(
            kind: .webMount,
            title: clean(title).deepReadIfEmpty("站点页面"),
            content: content,
            url: url,
            createdAt: now
        )
    }

    static func hotTopicSources(topic: IOSHotTopic, now: Int64 = IOSDeepReadClock.currentEpochMs()) throws -> [IOSDeepReadSource] {
        let sources = topic.sources.compactMap { source -> IOSDeepReadSource? in
            let content = cleanMultiline([
                "综合主题：\(topic.title)",
                "来源：\(source.providerName)",
                "榜单标题：\(source.presentationTitle)",
                "排名：\(source.rank)",
                source.heat.map { "热度：\($0)" },
                source.url.map { "链接：\($0)" }
            ].compactMap { $0 }.joined(separator: "\n"))
            guard !content.isEmpty else { return nil }
            return IOSDeepReadSource(
                kind: .hotTopic,
                title: source.presentationTitle,
                content: content,
                url: source.url,
                metadata: [
                    "topic_id": topic.id,
                    "topic_title": topic.title,
                    "provider_id": source.providerId,
                    "provider_name": source.providerName,
                    "rank": "\(source.rank)",
                    "heat": source.heat ?? ""
                ],
                createdAt: now
            )
        }
        guard !sources.isEmpty else { throw IOSDeepReadSourceNormalizationError.emptySource(.hotTopic) }
        return sources
    }

    static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanMultiline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { clean($0) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstLineTitle(_ text: String, fallback: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).deepReadPrefixString(60) }?
            .deepReadIfEmpty(fallback) ?? fallback
    }
}

