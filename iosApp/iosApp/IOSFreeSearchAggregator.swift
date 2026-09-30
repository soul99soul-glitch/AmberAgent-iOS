import Foundation

/// 无需 API Key 的免费搜索引擎。解析方式参考 deedy5/ddgs 与 searxng 的公开引擎实现，
/// 2026-09 实测可用；百度、搜狗、Mojeek、Startpage、Yandex、DuckDuckGo Lite 等
/// 在同期实测中直接返回验证码/403，未接入。
enum IOSFreeSearchEngine: String, CaseIterable {
    case wikipedia
    case bing
    case brave
    case duckDuckGo
    case quark
    case so360
    case hackerNews

    var displayName: String {
        switch self {
        case .wikipedia: "Wikipedia"
        case .bing: "Bing"
        case .brave: "Brave"
        case .duckDuckGo: "DuckDuckGo"
        case .quark: "夸克"
        case .so360: "360 搜索"
        case .hackerNews: "Hacker News"
        }
    }
}

enum IOSFreeSearchEngineError: Error, Equatable {
    /// 验证码 / 反爬页 / 限流：进入冷却，冷却期内不再请求该引擎。
    case blocked
}

/// IOSSearchHTTPTransport 是 @MainActor 协议，所有调用都在主线程执行；
/// 包装只为把它交给同样在主线程运行的子任务。
private struct TransportBox: @unchecked Sendable {
    let transport: any IOSSearchHTTPTransport
}

/// 多引擎并发查询、单引擎失败跳过、按引擎轮流合并去重。
@MainActor
enum IOSFreeSearchAggregator {
    nonisolated static let providerName = "免费聚合搜索"
    nonisolated static let providerType = "free_aggregate"
    nonisolated static let blockedCooldown: TimeInterval = 10 * 60
    /// 聚合结果少于该条数时才启用 Google WebView 兜底。
    nonisolated static let weakResultThreshold = 3

    nonisolated static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    nonisolated private static let apiUserAgent = "AmberAgent-iOS/1.0 (free search aggregator)"

    private static var cooldownUntil: [IOSFreeSearchEngine: Date] = [:]

    static func resetCooldowns() {
        cooldownUntil.removeAll()
    }

    static func search(
        query: String,
        maxResults: Int,
        googleFallbackEnabled: Bool,
        transport: any IOSSearchHTTPTransport,
        googleFallback: (String, Int) async throws -> [IOSSearchResult] = { query, maxResults in
            try await IOSGoogleWebViewSearch.search(query: query, maxResults: maxResults)
        },
        now: () -> Date = Date.init
    ) async throws -> [IOSSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSSearchExecutorError.missingQuery }
        let limit = min(max(maxResults, 1), 10)
        let engines = engines(for: trimmed, now: now())

        var perEngine: [IOSFreeSearchEngine: [IOSSearchResult]] = [:]
        var failures: [String] = []
        let box = TransportBox(transport: transport)
        // 各引擎并发执行（都在主线程上挂起等待网络），逐个收集；外层取消时一并取消。
        let tasks = engines.map { engine in
            Task { @MainActor in try await search(engine: engine, query: trimmed, transport: box.transport) }
        }
        await withTaskCancellationHandler {
            for (engine, task) in zip(engines, tasks) {
                switch await task.result {
                case .success(let results):
                    cooldownUntil[engine] = nil
                    perEngine[engine] = results
                case .failure(let error):
                    if isBlocking(error) {
                        cooldownUntil[engine] = now().addingTimeInterval(blockedCooldown)
                    }
                    failures.append("\(engine.displayName)：\(describe(error))")
                }
            }
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
        try Task.checkCancellation()

        var merged = roundRobinMerge(perEngine, order: engines, limit: limit)
        if merged.count < weakResultThreshold, googleFallbackEnabled {
            do {
                let google = try await googleFallback(trimmed, limit)
                merged = dedupe(merged + google, limit: limit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("Google WebView：\(describe(error))")
            }
        }
#if DEBUG
        NSLog("[AmberSearch] free-aggregate engines=\(engines.map(\.rawValue)) hits=\(perEngine.mapValues(\.count)) merged=\(merged.count) failures=\(failures)")
#endif
        guard !merged.isEmpty else {
            throw IOSSearchExecutorError.freeSearchExhausted(failures.isEmpty ? "所有免费源都没有返回结果" : failures.joined(separator: "；"))
        }
        return merged
    }

    static func engines(for query: String, now: Date) -> [IOSFreeSearchEngine] {
        IOSFreeSearchEngine.allCases.filter { engine in
            if let until = cooldownUntil[engine], until > now { return false }
            // HN 只有英文技术讨论，中文查询只会带来噪声。
            if engine == .hackerNews { return !containsCJK(query) }
            return true
        }
    }

    /// 按引擎顺序轮流取结果：保证最终列表里各引擎都有代表，而不是被第一个引擎占满。
    static func roundRobinMerge(
        _ perEngine: [IOSFreeSearchEngine: [IOSSearchResult]],
        order: [IOSFreeSearchEngine],
        limit: Int
    ) -> [IOSSearchResult] {
        var interleaved: [IOSSearchResult] = []
        let lists = order.compactMap { perEngine[$0] }
        let depth = lists.map(\.count).max() ?? 0
        for index in 0..<depth {
            for list in lists where index < list.count {
                interleaved.append(list[index])
            }
        }
        return dedupe(interleaved, limit: limit)
    }

    private static func dedupe(_ results: [IOSSearchResult], limit: Int) -> [IOSSearchResult] {
        var seen = Set<String>()
        var output: [IOSSearchResult] = []
        for result in results {
            let key = dedupeKey(result.url)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(result)
            if output.count >= limit { break }
        }
        return output
    }

    static func dedupeKey(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        for prefix in ["www.", "m."] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    // MARK: - Engines

    private static func search(
        engine: IOSFreeSearchEngine,
        query: String,
        transport: any IOSSearchHTTPTransport
    ) async throws -> [IOSSearchResult] {
        switch engine {
        case .bing:
            let html = try await fetchHTML(
                "https://www.bing.com/search", query: [("q", query)], engine: engine, transport: transport
            )
            let results = IOSSearchExecutor.parseBingHTML(html: html, maxResults: 10)
            if results.isEmpty, looksBlocked(html) { throw IOSFreeSearchEngineError.blocked }
            return results
        case .duckDuckGo:
            var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "b", value: "")]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            let html = try await send(request, engine: engine, transport: transport)
            let results = parseDuckDuckGoHTML(html)
            if results.isEmpty, looksBlocked(html) { throw IOSFreeSearchEngineError.blocked }
            return results
        case .brave:
            let html = try await fetchHTML(
                "https://search.brave.com/search", query: [("q", query), ("source", "web")], engine: engine, transport: transport
            )
            let results = parseBraveHTML(html)
            if results.isEmpty, looksBlocked(html) { throw IOSFreeSearchEngineError.blocked }
            return results
        case .so360:
            let html = try await fetchHTML(
                "https://www.so.com/s", query: [("q", query)], engine: engine, transport: transport
            )
            let results = parse360HTML(html)
            if results.isEmpty, looksBlocked(html) { throw IOSFreeSearchEngineError.blocked }
            return results
        case .quark:
            let html = try await fetchHTML(
                "https://quark.sm.cn/s", query: [("q", query), ("layout", "html"), ("page", "1")], engine: engine, transport: transport
            )
            // 夸克短时间约 9 次请求后返回阿里 X5SEC 验证页（见 searxng quark.py）。
            if html.range(of: #""action"\s*:\s*"captcha""#, options: .regularExpression) != nil {
                throw IOSFreeSearchEngineError.blocked
            }
            return parseQuarkHTML(html)
        case .wikipedia:
            let lang = containsCJK(query) ? "zh" : "en"
            var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
            components.queryItems = [
                .init(name: "action", value: "query"),
                .init(name: "generator", value: "search"),
                .init(name: "gsrsearch", value: query),
                .init(name: "gsrlimit", value: "2"),
                .init(name: "prop", value: "extracts|info"),
                .init(name: "exintro", value: "1"),
                .init(name: "explaintext", value: "1"),
                .init(name: "exchars", value: "600"),
                .init(name: "inprop", value: "url"),
                .init(name: "format", value: "json"),
                .init(name: "formatversion", value: "2"),
            ]
            let body = try await send(apiRequest(components.url!), engine: engine, transport: transport)
            return parseWikipediaJSON(body)
        case .hackerNews:
            var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
            components.queryItems = [
                .init(name: "query", value: query),
                .init(name: "tags", value: "story"),
                .init(name: "hitsPerPage", value: "5"),
            ]
            let body = try await send(apiRequest(components.url!), engine: engine, transport: transport)
            return parseHackerNewsJSON(body)
        }
    }

    static func searchSingleEngineForTesting(
        _ engine: IOSFreeSearchEngine,
        query: String,
        transport: any IOSSearchHTTPTransport = IOSURLSessionSearchHTTPTransport()
    ) async throws -> [IOSSearchResult] {
        try await search(engine: engine, query: query, transport: transport)
    }

    private static func fetchHTML(
        _ base: String,
        query: [(String, String)],
        engine: IOSFreeSearchEngine,
        transport: any IOSSearchHTTPTransport
    ) async throws -> String {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw IOSSearchExecutorError.invalidURL }
        return try await send(URLRequest(url: url), engine: engine, transport: transport)
    }

    private static func apiRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Wikimedia 的 UA 政策要求可识别的客户端标识。
        request.setValue(apiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func send(
        _ request: URLRequest,
        engine: IOSFreeSearchEngine,
        transport: any IOSSearchHTTPTransport
    ) async throws -> String {
        var request = request
        request.timeoutInterval = 8
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            // 桌面 Safari UA：移动 UA 会让搜狗/360/Bing 跳转到结构不同的移动页。
            request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        }
        let (response, data) = try await transport.send(request)
        if response.statusCode == 202 { throw IOSFreeSearchEngineError.blocked }
        guard (200...299).contains(response.statusCode) else {
            throw IOSSearchExecutorError.httpStatus(engine.displayName, response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func looksBlocked(_ html: String) -> Bool {
        let lower = html.lowercased()
        return ["captcha", "anomaly", "unusual traffic", "are you a robot", "antispider", "verifying your browser"]
            .contains { lower.contains($0) }
    }

    private static func isBlocking(_ error: Error) -> Bool {
        if error as? IOSFreeSearchEngineError == .blocked { return true }
        if case .httpStatus(_, let code) = error as? IOSSearchExecutorError { return code == 403 || code == 429 }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if error as? IOSFreeSearchEngineError == .blocked { return "遇到验证页，已暂停 10 分钟" }
        if let error = error as? LocalizedError, let message = error.errorDescription { return message }
        return error.localizedDescription
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    // MARK: - Parsers

    static func parseDuckDuckGoHTML(_ html: String) -> [IOSSearchResult] {
        html.components(separatedBy: "class=\"result__a\"").dropFirst().compactMap { block in
            guard let href = capture(#"^[^>]*href="([^"]+)""#, in: block),
                  let title = capture(#"^[^>]*>(.*?)</a>"#, in: block) else { return nil }
            let url = IOSSearchExecutor.cleanResultURL(href)
            guard url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js") else { return nil }
            let snippet = capture(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block).map(text) ?? ""
            return result(title: text(title), url: url, snippet: snippet)
        }
    }

    static func parseBraveHTML(_ html: String) -> [IOSSearchResult] {
        html.components(separatedBy: "data-type=\"web\"").dropFirst().compactMap { block in
            guard let url = capture(#"<a href="(https?://[^"]+)""#, in: block),
                  !(URL(string: url)?.host?.hasSuffix("brave.com") ?? true) else { return nil }
            let title = capture(#"class="title[^"]*"[^>]*title="([^"]+)""#, in: block)
                ?? capture(#"class="title[^"]*"[^>]*>(.*?)</div>"#, in: block)
                ?? ""
            let snippet = capture(#"<div class="content[^"]*"[^>]*>(.*?)</div>"#, in: block).map(text) ?? ""
            return result(title: text(title), url: url, snippet: snippet)
        }
    }

    static func parse360HTML(_ html: String) -> [IOSSearchResult] {
        IOSSearchExecutor.regexCaptures(#"<li[^>]*class="[^"]*res-list[^"]*"[^>]*>(.*?)</li>"#, in: html).compactMap { block in
            guard let anchor = capture(#"<h3[^>]*res-title[^>]*>.*?<a([^>]*)>(.*?)</a>"#, in: block, group: 1),
                  let titleHTML = capture(#"<h3[^>]*res-title[^>]*>.*?<a[^>]*>(.*?)</a>"#, in: block) else { return nil }
            let rawURL = capture(#"data-mdurl="([^"]+)""#, in: anchor) ?? capture(#"href="([^"]+)""#, in: anchor) ?? ""
            let url = IOSSearchExecutor.decodeEntities(rawURL)
            // 360 自家 AI 聚合页 / 文库不是原始来源。
            guard let host = URL(string: url)?.host, host != "so.com", !host.hasSuffix(".so.com") else { return nil }
            let snippet = (capture(#"<p[^>]*class="res-desc"[^>]*>(.*?)</p>"#, in: block)
                ?? capture(#"<span[^>]*class="res-list-summary"[^>]*>(.*?)</span>"#, in: block)).map(text) ?? ""
            return result(title: text(titleHTML), url: url, snippet: snippet)
        }
    }

    static func parseQuarkHTML(_ html: String) -> [IOSSearchResult] {
        let pattern = #"<script\s+type="application/json"\s+id="s-data-[^"]+"\s+data-used-by="hydrate">(.*?)</script>"#
        return IOSSearchExecutor.regexCaptures(pattern, in: html).compactMap { json in
            guard let object = jsonObject(json),
                  let sc = (object["extraData"] as? [String: Any])?["sc"] as? String,
                  ["ss_doc", "ss_text", "ss_pic", "ss_kv", "baike"].contains(sc),
                  let data = ((object["data"] as? [String: Any])?["initialData"]) as? [String: Any] else { return nil }
            let title = ((data["titleProps"] as? [String: Any])?["content"] as? String) ?? (data["title"] as? String) ?? ""
            let url = ((data["sourceProps"] as? [String: Any])?["dest_url"] as? String)
                ?? (data["normal_url"] as? String) ?? (data["url"] as? String) ?? ""
            let summary = ((data["summaryProps"] as? [String: Any])?["content"] as? String)
                ?? (data["show_body"] as? String) ?? (data["desc"] as? String) ?? ""
            return result(title: text(title), url: url, snippet: text(summary))
        }
    }

    static func parseWikipediaJSON(_ body: String) -> [IOSSearchResult] {
        guard let pages = ((jsonObject(body)?["query"] as? [String: Any])?["pages"]) as? [[String: Any]] else { return [] }
        return pages
            .sorted { ($0["index"] as? Int ?? .max) < ($1["index"] as? Int ?? .max) }
            .compactMap { page in
                let extract = (page["extract"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // 消歧义页没有实质内容。
                guard !extract.isEmpty, !extract.contains("may refer to"), !extract.contains("可以指") else { return nil }
                return result(title: page["title"] as? String ?? "", url: page["fullurl"] as? String ?? "", snippet: extract)
            }
    }

    static func parseHackerNewsJSON(_ body: String) -> [IOSSearchResult] {
        guard let hits = jsonObject(body)?["hits"] as? [[String: Any]] else { return [] }
        return hits.compactMap { hit in
            let objectID = hit["objectID"] as? String ?? ""
            let url = (hit["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "https://news.ycombinator.com/item?id=\(objectID)"
            let points = hit["points"] as? Int ?? 0
            let comments = hit["num_comments"] as? Int ?? 0
            return result(
                title: hit["title"] as? String ?? "",
                url: url,
                snippet: "Hacker News 讨论：\(points) 分，\(comments) 条评论。https://news.ycombinator.com/item?id=\(objectID)"
            )
        }
    }

    // MARK: - Helpers

    private static func result(title: String, url: String, snippet: String) -> IOSSearchResult? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, url.hasPrefix("http") else { return nil }
        return IOSSearchResult(title: title, url: url, snippet: snippet)
    }

    private static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func text(_ html: String) -> String {
        // 行内高亮标签（<em> 等）直接去掉，不能替换成空格，否则中文会被断开。
        let inline = html.replacingOccurrences(
            of: #"</?(em|b|strong|i|span|mark)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        return IOSSearchExecutor.plainText(fromHTML: inline)
    }

    private static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
