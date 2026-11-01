import Foundation

extension DesktopSearchEngine {
    // MARK: - Scrape Web (with Hero Image & Optional Exa Contents Support)

    static func executeScrapeWeb(
        args: [String: Any]?,
        rawInput: String,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        let rawURL = ((args?["url"] as? String) ?? (args?["link"] as? String) ?? (args?["uri"] as? String) ?? (args == nil ? rawInput : ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            throw DesktopRuntimeError.message("scrape_web 参数 url 不能为空。")
        }
        let validURL = try await validatePublicURL(rawURL)
        let maxChars = min(40_000, max(1_000, intValue(args?["max_chars"]) ?? 12_000))

        var request = URLRequest(url: validURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 AmberAgent-macOS Scrape", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain,application/xhtml+xml,application/json;q=0.8,*/*;q=0.3", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        guard (200...299).contains(response.statusCode) else {
            throw DesktopRuntimeError.message("scrape_web 请求失败（HTTP \(response.statusCode)）。")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let title = extractHTMLTitle(from: html)
        let content = extractReadableText(from: html, maxChars: maxChars)
        guard !content.isEmpty else {
            throw DesktopRuntimeError.message("scrape_web 未能从页面提取出可读正文。")
        }
        let heroImageURLs = extractHeroImageURLs(from: html)
        let snippet = String(content.prefix(240))
        let structuredImages = heroImageURLs.map { imgURL in
            DesktopSearchImage(
                url: imgURL,
                title: title.nonEmpty ?? validURL.host ?? "网页图片",
                alt: title.nonEmpty,
                sourceURL: validURL.absoluteString,
                snippet: snippet
            )
        }

        var jsonDict: [String: Any] = [
            "status": "ok",
            "url": validURL.absoluteString,
            "title": title,
            "content": content,
            "chars": content.count
        ]
        if !heroImageURLs.isEmpty {
            jsonDict["images"] = heroImageURLs
            jsonDict["image_items"] = structuredImages.map { img in
                var item: [String: String] = ["url": img.url]
                if let t = img.title { item["title"] = t }
                if let a = img.alt { item["alt"] = a }
                if let s = img.sourceURL { item["sourceURL"] = s }
                return item
            }
        }
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys])
        let text = String(decoding: jsonData, as: UTF8.self)
        let hit = DesktopSearchHit(
            title: title.nonEmpty ?? validURL.absoluteString,
            url: validURL.absoluteString,
            snippet: snippet,
            text: content,
            images: structuredImages,
            sourceService: "scrape_web"
        )
        return DesktopSearchExecutionOutput(
            text: text,
            results: [hit],
            images: structuredImages,
            sources: [],
            executionMode: .sequentialFallback,
            fallbackReason: nil
        )
    }

    // MARK: - Individual Provider Adapters

    struct SingleServiceOutcome: Sendable {
        var hits: [DesktopSearchHit]
        var synthesizedAnswer: String?
        var searchType: String?
    }

    static func runSingleService(
        service: DesktopSearchService,
        query: String,
        maxResults: Int,
        exaParams: DesktopExaParameters,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler,
        freeSearch: @escaping DesktopFreeSearchHandler
    ) async throws -> SingleServiceOutcome {
        switch service {
        case .free:
            let hits = try await freeSearch(query, maxResults, transport)
            return SingleServiceOutcome(hits: hits, synthesizedAnswer: nil, searchType: nil)

        case .exa:
            let apiKey = try requireAPIKey(for: .exa, config: config)
            let body = DesktopExaClient.buildSearchBody(
                query: query,
                maxResults: maxResults,
                parameters: exaParams,
                defaults: config.exaOptions
            )
            let req = try buildJSONRequest(
                url: DesktopExaClient.baseURL.appendingPathComponent("search"),
                body: body,
                headers: ["x-api-key": apiKey, "Authorization": "Bearer \(apiKey)"]
            )
            let object = try await sendJSON(req, providerName: "Exa", transport: transport)
            let parsed = DesktopExaClient.parseResponse(
                object: object,
                endpoint: "search",
                queryOrTarget: query,
                requestedType: body["type"] as? String,
                maxResults: maxResults
            )
            return SingleServiceOutcome(
                hits: parsed.results,
                synthesizedAnswer: parsed.synthesizedAnswer,
                searchType: parsed.searchType
            )

        case .tavily:
            let apiKey = try requireAPIKey(for: .tavily, config: config)
            var body: [String: Any] = [
                "query": query,
                "max_results": maxResults,
                "search_depth": "advanced",
                "include_answer": false,
                "include_raw_content": exaParams.includeFullText == true,
                "include_images": exaParams.includeImages ?? true,
                "include_image_descriptions": true
            ]
            if exaParams.category == "news" {
                body["topic"] = "news"
            }
            if !exaParams.includeDomains.isEmpty {
                body["include_domains"] = exaParams.includeDomains
            }
            if !exaParams.excludeDomains.isEmpty {
                body["exclude_domains"] = exaParams.excludeDomains
            }
            let req = try buildJSONRequest(
                url: URL(string: "https://api.tavily.com/search")!,
                body: body,
                headers: ["Authorization": "Bearer \(apiKey)"]
            )
            let object = try await sendJSON(req, providerName: "Tavily", transport: transport)
            let topImages = parseTavilyImages(object["images"], defaultTitle: query, sourceURL: nil, snippet: nil)
            let rawResults = (object["results"] as? [[String: Any]]) ?? []
            var hits: [DesktopSearchHit] = []
            for (idx, item) in rawResults.prefix(maxResults).enumerated() {
                let url = ((item["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let content = ((item["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawContent = ((item["raw_content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var itemImages = parseTavilyImages(item["images"], defaultTitle: title, sourceURL: url, snippet: content)
                if idx == 0 && !topImages.isEmpty {
                    let attachedTop = topImages.map { img -> DesktopSearchImage in
                        var copy = img
                        if copy.sourceURL == nil { copy.sourceURL = url }
                        if copy.snippet == nil { copy.snippet = content }
                        return copy
                    }
                    itemImages.append(contentsOf: attachedTop)
                }
                hits.append(DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: content,
                    publishedDate: item["published_date"] as? String,
                    text: rawContent.nonEmpty,
                    images: itemImages,
                    sourceService: "Tavily"
                ))
            }
            return SingleServiceOutcome(hits: hits, synthesizedAnswer: nil, searchType: nil)

        case .brave:
            let apiKey = try requireAPIKey(for: .brave, config: config)
            var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: "\(min(maxResults, 20))")
            ]
            var req = URLRequest(url: components.url!)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
            let object = try await sendJSON(req, providerName: "Brave", transport: transport)
            let web = (object["web"] as? [String: Any]) ?? [:]
            let rawResults = (web["results"] as? [[String: Any]]) ?? []
            let hits = rawResults.prefix(maxResults).compactMap { item -> DesktopSearchHit? in
                let url = ((item["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let description = ((item["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var images: [DesktopSearchImage] = []
                if let thumb = (item["thumbnail"] as? [String: Any])?["src"] as? String,
                   DesktopExaClient.isValidHTTPURL(thumb) {
                    let alt = (item["thumbnail"] as? [String: Any])?["alt"] as? String
                    images.append(DesktopSearchImage(url: thumb, title: title, alt: alt ?? title, sourceURL: url, snippet: description))
                }
                return DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: description,
                    publishedDate: item["age"] as? String,
                    images: images,
                    sourceService: "Brave"
                )
            }
            return SingleServiceOutcome(hits: Array(hits), synthesizedAnswer: nil, searchType: nil)

        case .serper:
            let apiKey = try requireAPIKey(for: .serper, config: config)
            let endpoint = exaParams.category == "news" ? "news" : "search"
            let req = try buildJSONRequest(
                url: URL(string: "https://google.serper.dev/\(endpoint)")!,
                body: ["q": query, "num": min(maxResults, 20)],
                headers: ["X-API-KEY": apiKey]
            )
            let object = try await sendJSON(req, providerName: "Serper", transport: transport)
            let news = (object["news"] as? [[String: Any]]) ?? []
            let organic = (object["organic"] as? [[String: Any]]) ?? []
            let rawItems = news.isEmpty ? organic : news
            let hits = rawItems.prefix(maxResults).compactMap { item -> DesktopSearchHit? in
                let url = ((item["link"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = ((item["snippet"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var images: [DesktopSearchImage] = []
                if let imgURL = (item["imageUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   DesktopExaClient.isValidHTTPURL(imgURL) {
                    images.append(DesktopSearchImage(url: imgURL, title: title, alt: title, sourceURL: url, snippet: snippet))
                }
                return DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: snippet,
                    publishedDate: item["date"] as? String,
                    images: images,
                    sourceService: "Serper"
                )
            }
            return SingleServiceOutcome(hits: Array(hits), synthesizedAnswer: nil, searchType: nil)

        case .serpapi:
            let apiKey = try requireAPIKey(for: .serpapi, config: config)
            var components = URLComponents(string: "https://serpapi.com/search.json")!
            var items = [
                URLQueryItem(name: "engine", value: "google"),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "num", value: "\(min(maxResults, 20))")
            ]
            if exaParams.category == "news" {
                items.append(URLQueryItem(name: "tbm", value: "nws"))
            }
            components.queryItems = items
            var req = URLRequest(url: components.url!)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let object = try await sendJSON(req, providerName: "SerpAPI", transport: transport)
            let news = (object["news_results"] as? [[String: Any]]) ?? []
            let organic = (object["organic_results"] as? [[String: Any]]) ?? []
            let rawItems = news.isEmpty ? organic : news
            let hits = rawItems.prefix(maxResults).compactMap { item -> DesktopSearchHit? in
                let url = ((item["link"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = ((item["snippet"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var images: [DesktopSearchImage] = []
                if let thumb = (item["thumbnail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   DesktopExaClient.isValidHTTPURL(thumb) {
                    images.append(DesktopSearchImage(url: thumb, title: title, alt: title, sourceURL: url, snippet: snippet))
                }
                return DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: snippet,
                    publishedDate: item["date"] as? String,
                    images: images,
                    sourceService: "SerpAPI"
                )
            }
            return SingleServiceOutcome(hits: Array(hits), synthesizedAnswer: nil, searchType: nil)

        case .zhipu:
            let apiKey = try requireAPIKey(for: .zhipu, config: config)
            let req = try buildJSONRequest(
                url: URL(string: "https://open.bigmodel.cn/api/paas/v4/web_search")!,
                body: [
                    "search_query": query,
                    "search_engine": "search_pro",
                    "count": maxResults
                ],
                headers: ["Authorization": "Bearer \(apiKey)"]
            )
            let object = try await sendJSON(req, providerName: "智谱", transport: transport)
            let rawItems = (object["search_result"] as? [[String: Any]]) ?? []
            let hits = rawItems.prefix(maxResults).compactMap { item -> DesktopSearchHit? in
                let url = ((item["link"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = ((item["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: snippet,
                    publishedDate: item["publish_date"] as? String,
                    sourceService: "智谱"
                )
            }
            return SingleServiceOutcome(hits: Array(hits), synthesizedAnswer: nil, searchType: nil)

        case .jina:
            let apiKey = try requireAPIKey(for: .jina, config: config)
            let req = try buildJSONRequest(
                url: URL(string: "https://s.jina.ai/")!,
                body: ["q": query],
                headers: ["Authorization": "Bearer \(apiKey)"]
            )
            let object = try await sendJSON(req, providerName: "Jina", transport: transport)
            let rawItems = (object["data"] as? [[String: Any]]) ?? []
            let hits = rawItems.prefix(maxResults).compactMap { item -> DesktopSearchHit? in
                let url = ((item["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = ((item["title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = ((item["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let content = ((item["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return DesktopSearchHit(
                    title: title,
                    url: url,
                    snippet: desc.isEmpty ? content : desc,
                    text: content.nonEmpty,
                    sourceService: "Jina"
                )
            }
            return SingleServiceOutcome(hits: Array(hits), synthesizedAnswer: nil, searchType: nil)
        }
    }

    private static func parseTavilyImages(
        _ raw: Any?,
        defaultTitle: String,
        sourceURL: String?,
        snippet: String?
    ) -> [DesktopSearchImage] {
        guard let array = raw as? [Any] else { return [] }
        var output: [DesktopSearchImage] = []
        for entry in array {
            if let url = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               DesktopExaClient.isValidHTTPURL(url) {
                output.append(DesktopSearchImage(
                    url: url,
                    title: defaultTitle,
                    alt: defaultTitle,
                    sourceURL: sourceURL,
                    snippet: snippet
                ))
            } else if let obj = entry as? [String: Any],
                      let url = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      DesktopExaClient.isValidHTTPURL(url) {
                let desc = ((obj["description"] as? String) ?? (obj["alt"] as? String) ?? (obj["title"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                output.append(DesktopSearchImage(
                    url: url,
                    title: desc?.nonEmpty ?? defaultTitle,
                    alt: desc?.nonEmpty ?? defaultTitle,
                    sourceURL: sourceURL,
                    snippet: snippet
                ))
            }
        }
        return DesktopSearchImageDeduplicator.deduplicate(output)
    }

    // MARK: - Formatting & Output Construction

    static func buildExecutionOutput(
        headerTitle: String,
        results: [DesktopSearchHit],
        synthesizedAnswer: String?,
        searchType: String?,
        sources: [DesktopSearchSourceReport],
        executionMode: DesktopSearchExecutionMode,
        fallbackReason: String?
    ) -> DesktopSearchExecutionOutput {
        let succeededNames = sources.filter(\.succeeded).map(\.service.title)
        let providerLabel = succeededNames.isEmpty ? "搜索服务" : succeededNames.joined(separator: " + ")
        let serviceTypes = sources.filter(\.succeeded).map(\.service.rawValue).joined(separator: ",")

        var lines: [String] = [
            headerTitle,
            "来源：\(providerLabel)",
            "服务类型：\(serviceTypes.isEmpty ? "search" : serviceTypes)",
            "执行策略：\(executionMode.title)"
        ]
        if let searchType, !searchType.isEmpty {
            lines.append("检索模式：\(searchType)")
        }
        if let fallbackReason, !fallbackReason.isEmpty {
            lines.append("已自动改用：\(fallbackReason)")
        }
        if let synthesizedAnswer, !synthesizedAnswer.isEmpty {
            lines.append("\n【综合回答】\n\(synthesizedAnswer)")
        }

        var collectedImages: [DesktopSearchImage] = []
        for (index, result) in results.enumerated() {
            let sourceBadge = result.sourceService.map { " [\($0)]" } ?? ""
            lines.append("\n[\(index + 1)] \(result.title)\(sourceBadge)")
            lines.append(result.url)
            var metaParts: [String] = []
            if let date = result.publishedDate, !date.isEmpty { metaParts.append("发布时间：\(date)") }
            if let author = result.author, !author.isEmpty { metaParts.append("作者：\(author)") }
            if !metaParts.isEmpty {
                lines.append(metaParts.joined(separator: " | "))
            }
            if !result.snippet.isEmpty {
                lines.append(String(result.snippet.prefix(DesktopSearchExecutionOutput.maxSnippetChars)))
            }
            if !result.subpages.isEmpty {
                for sub in result.subpages.prefix(3) {
                    let subDesc = sub.snippet.isEmpty ? "" : " — \(String(sub.snippet.prefix(160)))"
                    lines.append("  • 子页面：\(sub.title) (\(sub.url))\(subDesc)")
                }
            }
            if !result.images.isEmpty {
                for img in result.images.prefix(4) {
                    let label = img.displayLabel
                    let srcSuffix = img.sourceURL.map { " (来源: \($0))" } ?? ""
                    lines.append("图片：![\(label)](\(img.url))\(srcSuffix)")
                }
                collectedImages.append(contentsOf: result.images)
            }
        }

        let deduplicatedImages = DesktopSearchImageDeduplicator.deduplicate(collectedImages, maxCount: 20)
        var text = lines.joined(separator: "\n")
        if text.count > DesktopSearchExecutionOutput.maxOutputChars {
            let dropped = text.count - DesktopSearchExecutionOutput.maxOutputChars
            text = String(text.prefix(DesktopSearchExecutionOutput.maxOutputChars))
                + "\n…[已截断 \(dropped) 字符]"
        }

        return DesktopSearchExecutionOutput(
            text: text,
            results: results,
            images: deduplicatedImages,
            sources: sources,
            executionMode: executionMode,
            fallbackReason: fallbackReason
        )
    }

    // MARK: - Networking & Helpers

    static let defaultHTTPTransport: DesktopSearchHTTPHandler = { request in
        if let url = request.url {
            _ = try await DesktopPublicSearchURL.validate(url)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DesktopRuntimeError.message("搜索请求未返回有效的 HTTP 响应。")
        }
        return (data, httpResponse)
    }

    static let defaultFreeSearch: DesktopFreeSearchHandler = { query, maxResults, transport in
        let http = transport ?? defaultHTTPTransport
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "\(min(maxResults, 20))")
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await http(req)
        guard (200...299).contains(response.statusCode) else {
            throw DesktopRuntimeError.message("免费聚合搜索返回 HTTP \(response.statusCode)。")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let hits = parseBingHTML(html: html, maxResults: maxResults)
        guard !hits.isEmpty else {
            throw DesktopRuntimeError.message("免费聚合搜索未返回结果。")
        }
        return hits
    }

    static func requireExaKey(config: ConfigurationSnapshot) throws -> String {
        try requireAPIKey(for: .exa, config: config)
    }

    static func requireAPIKey(for service: DesktopSearchService, config: ConfigurationSnapshot) throws -> String {
        guard let key = config.apiKeys[service]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DesktopRuntimeError.message("\(service.title) 未配置 API Key，请在搜索设置中填写。")
        }
        return key
    }

    static func validatePublicURL(_ rawURL: String) async throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw DesktopRuntimeError.message("无效的网页地址：\(rawURL)")
        }
        return try await DesktopPublicSearchURL.validate(url)
    }

    static func buildJSONRequest(
        url: URL,
        body: [String: Any],
        headers: [String: String],
        timeout: TimeInterval = 15
    ) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    static func sendJSON(
        _ request: URLRequest,
        providerName: String,
        transport: DesktopSearchHTTPHandler
    ) async throws -> [String: Any] {
        let (data, response) = try await transport(request)
        guard (200...299).contains(response.statusCode) else {
            var detail = ""
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let msg = (obj["error"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? (obj["message"] as? String) {
                detail = "：\(String(msg.prefix(160)))"
            }
            throw DesktopRuntimeError.message("\(providerName) 请求失败（HTTP \(response.statusCode)\(detail)）")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DesktopRuntimeError.message("\(providerName) 返回的响应不是有效 JSON。")
        }
        return object
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func redactCredentials(in message: String, apiKeys: [DesktopSearchService: String]) -> String {
        var output = message
        for key in apiKeys.values where key.count >= 4 {
            output = output.replacingOccurrences(of: key, with: "[REDACTED]")
        }
        return output
    }

    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let numVal = value as? NSNumber { return numVal.intValue }
        if let strVal = value as? String { return Int(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    // MARK: - Lightweight HTML Extraction for Scrape & Fallback

    static func extractHeroImageURLs(from raw: String) -> [String] {
        let patterns = [
            #"<meta[^>]+?(?:property|name)\s*=\s*["'](?:og:image(?::secure_url|:url)?|twitter:image(?::src)?)["'][^>]+?content\s*=\s*["']([^"'>]+)["']"#,
            #"<meta[^>]+?content\s*=\s*["']([^"'>]+)["'][^>]+?(?:property|name)\s*=\s*["'](?:og:image(?::secure_url|:url)?|twitter:image(?::src)?)["']"#
        ]
        var urls: [String] = []
        var seen = Set<String>()
        let ns = raw as NSString
        let range = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            for match in re.matches(in: raw, options: [], range: range) where match.numberOfRanges > 1 {
                let r = match.range(at: 1)
                guard r.location != NSNotFound else { continue }
                let url = ns.substring(with: r)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&amp;", with: "&")
                let key = DesktopSearchURLIdentity.dedupeKey(for: url)
                guard DesktopExaClient.isValidHTTPURL(url), !seen.contains(key) else { continue }
                seen.insert(key)
                urls.append(url)
            }
        }
        return Array(urls.prefix(5))
    }

    private static func extractHTMLTitle(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return ""
        }
        return cleanHTML(String(html[range]))
    }

    private static func extractReadableText(from raw: String, maxChars: Int) -> String {
        var text = raw
        for tag in ["script", "style", "noscript", "svg"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: "</?(p|div|section|article|header|footer|main|li|h[1-6]|br)\\b[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let cleaned = cleanHTML(text)
        return cleaned.count > maxChars ? String(cleaned.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private static func cleanHTML(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return stripped
            .replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBingHTML(html: String, maxResults: Int) -> [DesktopSearchHit] {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"<li[^>]*class=["'][^"']*\bb_algo\b[^"']*["'][^>]*>(.*?)</li>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let anchorRegex = try? NSRegularExpression(
            pattern: #"<h2[^>]*>.*?<a[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>.*?</h2>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let ns = html as NSString
        let matches = blockRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var hits: [DesktopSearchHit] = []
        for match in matches where match.numberOfRanges > 1 {
            let block = ns.substring(with: match.range(at: 1))
            let blockNS = block as NSString
            guard let anchor = anchorRegex.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length)),
                  anchor.numberOfRanges > 2 else { continue }
            let rawHref = blockNS.substring(with: anchor.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            let title = cleanHTML(blockNS.substring(with: anchor.range(at: 2)))
            guard !title.isEmpty, DesktopExaClient.isValidHTTPURL(rawHref) else { continue }
            var snippet = ""
            if let pRegex = try? NSRegularExpression(pattern: #"<p[^>]*>(.*?)</p>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let pMatch = pRegex.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length)),
               pMatch.numberOfRanges > 1 {
                snippet = cleanHTML(blockNS.substring(with: pMatch.range(at: 1)))
            }
            hits.append(DesktopSearchHit(title: title, url: rawHref, snippet: snippet, sourceService: "免费聚合搜索"))
            if hits.count >= maxResults { break }
        }
        return DesktopSearchHitDeduplicator.merge(hits, limit: maxResults)
    }
}
