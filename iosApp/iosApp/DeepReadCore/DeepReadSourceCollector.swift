import Foundation
@preconcurrency import Shared

/// Original deep-read multi-angle search, scrape enrichment and source deduplication.
@MainActor
enum DeepReadSourceCollector {
    static func enrich(
        _ sources: [IOSDeepReadSource],
        settings: Settings?,
        scrape: @MainActor (_ input: String, _ settings: Settings?) async throws -> String = executeScrape,
        onSourceProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async -> [IOSDeepReadSource] {
        var enriched: [IOSDeepReadSource] = []
        for (index, var source) in sources.enumerated() {
            guard !Task.isCancelled else { break }
            defer { onSourceProgress?(index + 1, sources.count) }
            // A retry reuses verified article text instead of appending it again or
            // losing it when the source website is temporarily unavailable.
            if source.metadata["scrape_status"] == "ok", source.hasUsableGenerationContent {
                enriched.append(source)
                continue
            }
            if source.metadata["scrape_status"] == "failed" {
                enriched.append(source)
                continue
            }
            guard let url = source.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                source.metadata["scrape_status"] = "no_url"
                enriched.append(source)
                continue
            }
            do {
                let input = jsonString(["url": url, "max_chars": 12_000])
                let output = try await scrape(input, settings)
                if let content = scrapeContent(from: output), !content.isEmpty {
                    source.content = IOSDeepReadSourceNormalizer.cleanMultiline(source.content + "\n\n网页正文：\n" + content)
                    source.metadata["scrape_status"] = "ok"
                } else {
                    source.metadata["scrape_status"] = "empty"
                }
                if source.metadata["hero_image_url"] == nil,
                   let hero = scrapeFirstImage(from: output) {
                    source.metadata["hero_image_url"] = hero
                }
            } catch {
                let hasExistingContent = !IOSDeepReadSourceNormalizer.cleanMultiline(source.content).isEmpty
                source.metadata["scrape_status"] = hasExistingContent ? "scrape_failed_keep_content" : "failed"
                source.metadata["scrape_error"] = String(IOSDeepReadUserFacingText.fromError(error).prefix(180))
            }
            enriched.append(source)
        }
        return enriched
    }

    private static func executeScrape(_ input: String, _ settings: Settings?) async throws -> String {
        try await IOSSearchExecutor.execute(toolName: "scrape_web", toolInput: input, settings: settings)
    }

    /// `queries` overrides the news-angle expansion, e.g. a plain title search for other reports.
    static func search(title: String, settings: Settings?, queries custom: [String]? = nil,
                       execute: @MainActor (_ input: String, _ settings: Settings?) async throws -> [IOSSearchResult] = executeSearch) async -> [IOSDeepReadSource] {
        let queries = custom ?? searchQueries(from: title)
        guard !queries.isEmpty else { return [] }
        var byURL: [String: IOSSearchResult] = [:]
        var perQuery: [[String]] = []
        var failures: [IOSDeepReadSource] = []
        let maxResults = Int(settings?.searchCommonOptions.resultSize ?? 4)
        for query in queries {
            guard !Task.isCancelled else { break }
            do {
                let results = try await execute(searchToolInput(query: query, maxResults: maxResults), settings)
                var keys: [String] = []
                for result in results {
                    let key = normalizedURL(result.url)
                    guard !key.isEmpty, byURL[key] == nil else { continue }
                    byURL[key] = result
                    keys.append(key)
                }
                perQuery.append(keys)
            } catch {
                let message = IOSDeepReadUserFacingText.fromError(error)
                if var source = try? IOSDeepReadSourceNormalizer.searchFailureSource(query: query, error: message) {
                    source.metadata["search_query"] = query
                    source.metadata["scrape_error"] = message
                    failures.append(source)
                }
#if DEBUG
                NSLog("[AmberDeepRead] topic-search angle failed (\(query.prefix(20))…): \(message)")
#endif
            }
        }
        // Take results round-robin across angles so the 12-source cap does not keep only the first query's hits.
        var order: [String] = []
        for rank in 0..<(perQuery.map(\.count).max() ?? 0) {
            for keys in perQuery where rank < keys.count { order.append(keys[rank]) }
        }
        let merged = Array(order.prefix(12).compactMap { byURL[$0] })
#if DEBUG
        NSLog("[AmberDeepRead] topic-search angles=\(queries.count) distinct=\(byURL.count) used=\(merged.count)")
#endif
        let sources = (try? IOSDeepReadSourceNormalizer.searchSources(query: title, results: merged)) ?? []
        return sources + failures
    }

    private static func executeSearch(_ input: String, _ settings: Settings?) async throws -> [IOSSearchResult] {
        try await IOSSearchExecutor.searchResults(toolInput: input, settings: settings).results
    }

    static func searchQueries(from title: String) -> [String] {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return [] }
        let year = Calendar.current.component(.year, from: Date())
        let lower = t.lowercased()
        var queries = [
            t,
            "\(t) 前因后果 时间线 背景 最新进展",
            "\(t) 官方 声明 通报",
            "\(t) 核心矛盾 争议 影响 各方反应",
            "\(t) 专家解读 分析",
            "\(t) background timeline latest news \(year)",
            "\(t) 图片 现场图 截图",
        ]
        if ["gemini", "google", "openai", "claude", "deepseek", "gpt", "llm", "大模型", "模型", "发布会", "ppt", "截图"].contains(where: { lower.contains($0) || t.contains($0) }) {
            queries.append("\(t) 发布 价格 跑分 性能 评价")
            queries.append("\(t) 发布会 PPT 演示 文稿 图片")
        }
        return queries
    }

    static func dedupe(_ sources: [IOSDeepReadSource]) -> [IOSDeepReadSource] {
        var seen = Set<[String]>()
        var result: [IOSDeepReadSource] = []
        for source in sources {
            let url = normalizedURL(source.url ?? "")
            let key = url.isEmpty ? ["input", source.kind.rawValue, source.title, source.content] : ["url", url]
            if seen.insert(key).inserted { result.append(source) }
        }
        return result
    }

    private static func normalizedURL(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value) else { return value }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? value
    }

    private static func scrapeContent(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["content"] as? String
    }

    private static func scrapeFirstImage(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["images"] as? [String] else {
            return nil
        }
        return images.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private static func jsonString(_ values: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func searchToolInput(query: String, maxResults: Int) -> String {
        let object: [String: Any] = ["query": query, "max_results": maxResults]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return query
        }
        return string
    }
}
