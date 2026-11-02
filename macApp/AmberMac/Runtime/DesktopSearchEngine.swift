import Foundation

/// URL identity and deduplication helper preserving path case, query parameters, query case, and port semantics.
enum DesktopSearchURLIdentity {
    static func dedupeKey(for rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https",
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return trimmed
        }

        let normalizedHost = stripMobileOrWWWPrefix(rawHost)
        let portPart: String
        if let port = components.port,
           !((rawScheme == "http" && port == 80) || (rawScheme == "https" && port == 443)) {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }

        let rawPath = components.percentEncodedPath
        let query = components.percentEncodedQuery
        let normalizedPath: String
        if rawPath.isEmpty || rawPath == "/" {
            normalizedPath = ""
        } else if query == nil && rawPath.count > 1 && rawPath.hasSuffix("/") {
            var copy = rawPath
            while copy.count > 1 && copy.hasSuffix("/") {
                copy.removeLast()
            }
            normalizedPath = copy
        } else {
            normalizedPath = rawPath
        }

        if let query, !query.isEmpty {
            return "\(normalizedHost)\(portPart)\(normalizedPath)?\(query)"
        }
        return "\(normalizedHost)\(portPart)\(normalizedPath)"
    }

    private static func stripMobileOrWWWPrefix(_ host: String) -> String {
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        if host.hasPrefix("m."), host.count > 2 {
            return String(host.dropFirst(2))
        }
        return host
    }
}

enum DesktopSearchImageDeduplicator {
    static func deduplicate(_ images: [DesktopSearchImage], maxCount: Int = 20) -> [DesktopSearchImage] {
        var indexByKey: [String: Int] = [:]
        var output: [DesktopSearchImage] = []
        for image in images {
            guard DesktopExaClient.isValidHTTPURL(image.url) else { continue }
            let key = DesktopSearchURLIdentity.dedupeKey(for: image.url)
            if let existingIndex = indexByKey[key] {
                var existing = output[existingIndex]
                if (existing.alt == nil || existing.alt == existing.title), let newAlt = image.alt, !newAlt.isEmpty {
                    existing.alt = newAlt
                }
                if existing.title == nil, let newTitle = image.title, !newTitle.isEmpty {
                    existing.title = newTitle
                }
                if existing.sourceURL == nil, let newSource = image.sourceURL, !newSource.isEmpty {
                    existing.sourceURL = newSource
                }
                if existing.snippet == nil, let newSnippet = image.snippet, !newSnippet.isEmpty {
                    existing.snippet = newSnippet
                }
                output[existingIndex] = existing
            } else {
                indexByKey[key] = output.count
                output.append(image)
                if output.count >= maxCount { break }
            }
        }
        return output
    }
}

enum DesktopSearchHitDeduplicator {
    static func merge(_ hits: [DesktopSearchHit], limit: Int) -> [DesktopSearchHit] {
        var indexByKey: [String: Int] = [:]
        var output: [DesktopSearchHit] = []
        for hit in hits {
            let key = DesktopSearchURLIdentity.dedupeKey(for: hit.url)
            guard !key.isEmpty else { continue }
            if let idx = indexByKey[key] {
                var current = output[idx]
                if current.title.isEmpty || current.title == current.url, !hit.title.isEmpty {
                    current.title = hit.title
                }
                if hit.snippet.count > current.snippet.count {
                    current.snippet = hit.snippet
                }
                if current.publishedDate == nil { current.publishedDate = hit.publishedDate }
                if current.author == nil { current.author = hit.author }
                if current.summary == nil { current.summary = hit.summary }
                if current.text == nil { current.text = hit.text }
                if !hit.highlights.isEmpty {
                    var seenHL = Set(current.highlights)
                    for hl in hit.highlights where !seenHL.contains(hl) {
                        seenHL.insert(hl)
                        current.highlights.append(hl)
                    }
                }
                if !hit.subpages.isEmpty {
                    var seenSub = Set(current.subpages.map { DesktopSearchURLIdentity.dedupeKey(for: $0.url) })
                    for sub in hit.subpages {
                        let subKey = DesktopSearchURLIdentity.dedupeKey(for: sub.url)
                        if !seenSub.contains(subKey) {
                            seenSub.insert(subKey)
                            current.subpages.append(sub)
                        }
                    }
                }
                current.images = DesktopSearchImageDeduplicator.deduplicate(current.images + hit.images)
                if let newSvc = hit.sourceService, !newSvc.isEmpty {
                    if let curSvc = current.sourceService, !curSvc.isEmpty {
                        let parts = curSvc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if !parts.contains(newSvc) {
                            current.sourceService = "\(curSvc), \(newSvc)"
                        }
                    } else {
                        current.sourceService = newSvc
                    }
                }
                output[idx] = current
            } else {
                indexByKey[key] = output.count
                output.append(hit)
            }
        }
        return Array(output.prefix(max(1, limit)))
    }
}

struct DesktopSearchSourceReport: Codable, Equatable, Sendable {
    var service: DesktopSearchService
    var succeeded: Bool
    var hitCount: Int
    var error: String?
}

struct DesktopSearchExecutionOutput: Equatable, Sendable {
    static let mediaOriginKey = "app.amber.media.origin"
    static let mediaImagesKey = "app.amber.media.images"
    static let maxOutputChars = 24_000
    static let maxSnippetChars = 1_600

    var text: String
    var results: [DesktopSearchHit]
    var images: [DesktopSearchImage]
    var sources: [DesktopSearchSourceReport]
    var executionMode: DesktopSearchExecutionMode
    var fallbackReason: String?

    var mediaMetadataEntries: [String: String]? {
        guard !images.isEmpty else { return nil }
        let items: [[String: String]] = images.map { image in
            var dict: [String: String] = [
                "id": image.id,
                "url": image.url
            ]
            if let title = image.title, !title.isEmpty { dict["title"] = title }
            if let alt = image.alt, !alt.isEmpty { dict["alt"] = alt }
            if let sourceURL = image.sourceURL, !sourceURL.isEmpty { dict["sourceURL"] = sourceURL }
            if let snippet = image.snippet, !snippet.isEmpty { dict["snippet"] = snippet }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else {
            return nil
        }
        return [
            Self.mediaOriginKey: "search",
            Self.mediaImagesKey: String(decoding: data, as: UTF8.self)
        ]
    }
}

typealias DesktopSearchHTTPHandler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
typealias DesktopFreeSearchHandler = @Sendable (_ query: String, _ maxResults: Int, _ transport: DesktopSearchHTTPHandler?) async throws -> [DesktopSearchHit]

enum DesktopSearchEngine {
    /// Snapshot of settings values captured on MainActor for concurrent execution.
    struct ConfigurationSnapshot: Sendable {
        var enabledServices: [DesktopSearchService]
        var executionMode: DesktopSearchExecutionMode
        var resultCount: Int
        var exaOptions: DesktopExaOptions
        var apiKeys: [DesktopSearchService: String]
        var explicitlyConfigured: Bool
    }

    @MainActor static func snapshot(from settings: DesktopSearchSettings) -> ConfigurationSnapshot {
        var keys: [DesktopSearchService: String] = [:]
        for svc in DesktopSearchService.allCases where svc.requiresAPIKey {
            if let key = try? settings.apiKey(for: svc).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                keys[svc] = key
            }
        }
        return ConfigurationSnapshot(
            enabledServices: settings.enabledServices,
            executionMode: settings.executionMode,
            resultCount: settings.resultCount,
            exaOptions: settings.exaOptions,
            apiKeys: keys,
            explicitlyConfigured: settings.explicitlyConfigured
        )
    }

    @MainActor static func execute(
        name: String,
        input: String,
        settings: DesktopSearchSettings,
        transport: DesktopSearchHTTPHandler? = nil,
        freeSearch: DesktopFreeSearchHandler? = nil
    ) async throws -> DesktopSearchExecutionOutput {
        let config = snapshot(from: settings)
        let http = transport ?? defaultHTTPTransport
        let args = parseJSONObject(input)

        switch name {
        case "exa_contents":
            return try await executeExaContents(args: args, rawInput: input, config: config, transport: http)
        case "exa_answer":
            return try await executeExaAnswer(args: args, rawInput: input, config: config, transport: http)
        case "exa_find_similar":
            return try await executeExaFindSimilar(args: args, rawInput: input, config: config, transport: http)
        case "scrape_web":
            return try await executeScrapeWeb(args: args, rawInput: input, config: config, transport: http)
        case "search_web", "exa_search":
            if let exaEndpoint = (args?["exa_endpoint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                switch exaEndpoint {
                case "contents", "/contents":
                    return try await executeExaContents(args: args, rawInput: input, config: config, transport: http)
                case "answer", "/answer":
                    return try await executeExaAnswer(args: args, rawInput: input, config: config, transport: http)
                case "find_similar", "findsimilar", "/findsimilar":
                    return try await executeExaFindSimilar(args: args, rawInput: input, config: config, transport: http)
                default:
                    break
                }
            }
            return try await executeSearchWeb(
                name: name,
                args: args,
                rawInput: input,
                config: config,
                transport: http,
                freeSearch: freeSearch ?? defaultFreeSearch
            )
        default:
            throw DesktopRuntimeError.message("未知的搜索工具：\(name)")
        }
    }

    // MARK: - Search Web (Multi-Source Sequential Fallback & Parallel)

    private static func executeSearchWeb(
        name: String,
        args: [String: Any]?,
        rawInput: String,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler,
        freeSearch: @escaping DesktopFreeSearchHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        let query: String
        if let args {
            query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            query = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !query.isEmpty else {
            throw DesktopRuntimeError.message("搜索参数 query 不能为空。")
        }

        let requestedMax = intValue(args?["max_results"] ?? args?["num_results"] ?? args?["numResults"]) ?? config.resultCount
        let maxResults = min(DesktopSearchSettings.resultLimit, max(1, requestedMax))
        let exaParams = DesktopExaParameters.parse(from: args ?? [:])

        let mode: DesktopSearchExecutionMode
        if let rawMode = (args?["execution_mode"] as? String ?? args?["executionMode"] as? String)?.lowercased() {
            mode = (rawMode == "parallel" || rawMode == "concurrent") ? .parallel : .sequentialFallback
        } else {
            mode = config.executionMode
        }

        let servicesToRun = try resolveServicesToRun(name: name, args: args, config: config)
        guard !servicesToRun.isEmpty else {
            throw DesktopRuntimeError.message("未启用任何搜索服务，请在搜索设置中开启至少一个搜索源。")
        }

        switch mode {
        case .sequentialFallback:
            return try await runSequentialFallback(
                query: query,
                maxResults: maxResults,
                services: servicesToRun,
                exaParams: exaParams,
                config: config,
                transport: transport,
                freeSearch: freeSearch
            )
        case .parallel:
            return try await runParallel(
                query: query,
                maxResults: maxResults,
                services: servicesToRun,
                exaParams: exaParams,
                config: config,
                transport: transport,
                freeSearch: freeSearch
            )
        }
    }

    private static func resolveServicesToRun(
        name: String,
        args: [String: Any]?,
        config: ConfigurationSnapshot
    ) throws -> [DesktopSearchService] {
        if name == "exa_search" {
            guard config.enabledServices.contains(.exa) || (config.apiKeys[.exa]?.isEmpty == false && !config.explicitlyConfigured) else {
                if config.enabledServices.isEmpty {
                    throw DesktopRuntimeError.message("未启用任何搜索服务，请在搜索设置中开启 Exa。")
                }
                throw DesktopRuntimeError.message("Exa 搜索源当前未启用，请在搜索设置中开启 Exa。")
            }
            return [.exa]
        }

        if let rawSources = args?["sources"] ?? args?["providers"] {
            let requestedNames: [String]
            if let arr = rawSources as? [Any] {
                requestedNames = arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            } else if let str = rawSources as? String {
                requestedNames = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            } else {
                requestedNames = []
            }
            let mapped = requestedNames.compactMap(mapServiceName)
            if !mapped.isEmpty {
                guard !config.enabledServices.isEmpty else {
                    throw DesktopRuntimeError.message("未启用任何搜索服务，请在搜索设置中开启至少一个搜索源。")
                }
                let allowed = mapped.filter { config.enabledServices.contains($0) }
                guard !allowed.isEmpty else {
                    throw DesktopRuntimeError.message("请求的搜索源未在设置中启用。")
                }
                return allowed
            }
        }

        return config.enabledServices
    }

    private static func mapServiceName(_ raw: String) -> DesktopSearchService? {
        switch raw {
        case "free", "bing_local", "bing", "ddg", "duckduckgo", "aggregate": return .free
        case "exa": return .exa
        case "tavily": return .tavily
        case "brave": return .brave
        case "serper": return .serper
        case "serpapi", "serp_api": return .serpapi
        case "zhipu", "glm": return .zhipu
        case "jina": return .jina
        default: return DesktopSearchService(rawValue: raw)
        }
    }

    private static func runSequentialFallback(
        query: String,
        maxResults: Int,
        services: [DesktopSearchService],
        exaParams: DesktopExaParameters,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler,
        freeSearch: @escaping DesktopFreeSearchHandler
    ) async throws -> DesktopSearchExecutionOutput {
        var reports: [DesktopSearchSourceReport] = []
        var failureReasons: [String] = []

        for service in services {
            try Task.checkCancellation()
            do {
                let result = try await runSingleService(
                    service: service,
                    query: query,
                    maxResults: maxResults,
                    exaParams: exaParams,
                    config: config,
                    transport: transport,
                    freeSearch: freeSearch
                )
                try Task.checkCancellation()
                guard !result.hits.isEmpty || (result.synthesizedAnswer?.isEmpty == false) else {
                    let reason = "\(service.title) 未返回结果"
                    reports.append(DesktopSearchSourceReport(service: service, succeeded: false, hitCount: 0, error: reason))
                    failureReasons.append(reason)
                    continue
                }
                let deduplicated = DesktopSearchHitDeduplicator.merge(result.hits, limit: maxResults)
                reports.append(DesktopSearchSourceReport(service: service, succeeded: true, hitCount: deduplicated.count, error: nil))
                let fallback = failureReasons.isEmpty ? nil : "\(failureReasons.joined(separator: "；"))，已自动回退至 \(service.title)"
                return buildExecutionOutput(
                    headerTitle: "搜索结果：\(query)",
                    results: deduplicated,
                    synthesizedAnswer: result.synthesizedAnswer,
                    searchType: result.searchType,
                    sources: reports,
                    executionMode: .sequentialFallback,
                    fallbackReason: fallback
                )
            } catch {
                if isCancellation(error) { throw CancellationError() }
                let redacted = redactCredentials(in: error.localizedDescription, apiKeys: config.apiKeys)
                let reason = "\(service.title) 失败（\(redacted)）"
                reports.append(DesktopSearchSourceReport(service: service, succeeded: false, hitCount: 0, error: redacted))
                failureReasons.append(reason)
            }
        }

        let summary = failureReasons.isEmpty ? "没有可用的搜索源。" : failureReasons.joined(separator: "；")
        throw DesktopRuntimeError.message("所有已启用搜索源均未能完成检索：\(summary)")
    }

    private static func runParallel(
        query: String,
        maxResults: Int,
        services: [DesktopSearchService],
        exaParams: DesktopExaParameters,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler,
        freeSearch: @escaping DesktopFreeSearchHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        struct IndexedOutcome: Sendable {
            let index: Int
            let service: DesktopSearchService
            let hits: [DesktopSearchHit]
            let synthesizedAnswer: String?
            let searchType: String?
            let error: String?
        }

        let outcomes: [IndexedOutcome] = try await withThrowingTaskGroup(of: IndexedOutcome.self) { group in
            for (index, service) in services.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let res = try await runSingleService(
                            service: service,
                            query: query,
                            maxResults: maxResults,
                            exaParams: exaParams,
                            config: config,
                            transport: transport,
                            freeSearch: freeSearch
                        )
                        try Task.checkCancellation()
                        if res.hits.isEmpty && (res.synthesizedAnswer?.isEmpty ?? true) {
                            return IndexedOutcome(
                                index: index,
                                service: service,
                                hits: [],
                                synthesizedAnswer: nil,
                                searchType: res.searchType,
                                error: "\(service.title) 未返回结果"
                            )
                        }
                        return IndexedOutcome(
                            index: index,
                            service: service,
                            hits: res.hits,
                            synthesizedAnswer: res.synthesizedAnswer,
                            searchType: res.searchType,
                            error: nil
                        )
                    } catch {
                        if isCancellation(error) { throw CancellationError() }
                        let redacted = redactCredentials(in: error.localizedDescription, apiKeys: config.apiKeys)
                        return IndexedOutcome(
                            index: index,
                            service: service,
                            hits: [],
                            synthesizedAnswer: nil,
                            searchType: nil,
                            error: redacted
                        )
                    }
                }
            }

            var collected: [IndexedOutcome] = []
            for try await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.index < $1.index }
        }

        try Task.checkCancellation()
        var allHits: [DesktopSearchHit] = []
        var answers: [String] = []
        var searchType: String?
        var reports: [DesktopSearchSourceReport] = []
        var partialFailures: [String] = []

        for outcome in outcomes {
            if let error = outcome.error {
                reports.append(DesktopSearchSourceReport(service: outcome.service, succeeded: false, hitCount: 0, error: error))
                partialFailures.append("\(outcome.service.title)（\(error)）")
            } else {
                allHits.append(contentsOf: outcome.hits)
                if let ans = outcome.synthesizedAnswer, !ans.isEmpty { answers.append(ans) }
                if searchType == nil { searchType = outcome.searchType }
                reports.append(DesktopSearchSourceReport(service: outcome.service, succeeded: true, hitCount: outcome.hits.count, error: nil))
            }
        }

        let merged = DesktopSearchHitDeduplicator.merge(allHits, limit: maxResults)
        guard !merged.isEmpty || !answers.isEmpty else {
            let reason = partialFailures.joined(separator: "；")
            throw DesktopRuntimeError.message("并发检索的所有搜索源均失败：\(reason)")
        }

        let fallbackNote = partialFailures.isEmpty ? nil : "部分搜索源未成功：\(partialFailures.joined(separator: "；"))"
        return buildExecutionOutput(
            headerTitle: "搜索结果：\(query)",
            results: merged,
            synthesizedAnswer: answers.isEmpty ? nil : answers.joined(separator: "\n\n"),
            searchType: searchType,
            sources: reports,
            executionMode: .parallel,
            fallbackReason: fallbackNote
        )
    }

    // MARK: - Exa Dedicated Endpoints (`/contents`, `/answer`, `/findSimilar`)

    private static func executeExaContents(
        args: [String: Any]?,
        rawInput: String,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        let apiKey = try requireExaKey(config: config)
        let params = DesktopExaParameters.parse(from: args ?? [:])
        var rawURLs = params.urls
        if rawURLs.isEmpty, let single = params.url { rawURLs = [single] }
        if rawURLs.isEmpty, args == nil {
            let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { rawURLs = [trimmed] }
        }
        guard !rawURLs.isEmpty else {
            throw DesktopRuntimeError.message("Exa contents 需要至少一个有效网页 URL（urls 或 url 参数）。")
        }

        var validatedURLs: [String] = []
        for raw in rawURLs {
            let valid = try await validatePublicURL(raw)
            validatedURLs.append(valid.absoluteString)
        }

        let body = DesktopExaClient.buildContentsBody(urls: validatedURLs, parameters: params, defaults: config.exaOptions)
        let req = try buildJSONRequest(
            url: DesktopExaClient.baseURL.appendingPathComponent("contents"),
            body: body,
            headers: ["x-api-key": apiKey, "Authorization": "Bearer \(apiKey)"]
        )
        let object = try await sendJSON(req, providerName: "Exa", transport: transport)
        let parsed = DesktopExaClient.parseResponse(
            object: object,
            endpoint: "contents",
            queryOrTarget: validatedURLs.joined(separator: ", "),
            maxResults: validatedURLs.count
        )
        guard !parsed.results.isEmpty else {
            let statusErrors = parsed.statuses
                .filter { $0.status != "success" }
                .map { "\($0.id): \($0.errorTag ?? $0.status)" }
                .joined(separator: "; ")
            throw DesktopRuntimeError.message("Exa contents 未返回正文\(statusErrors.isEmpty ? "。" : "（\(statusErrors)）。")")
        }

        let statusNote: String? = {
            let failed = parsed.statuses.filter { $0.status != "success" }
            guard !failed.isEmpty else { return nil }
            return "部分 URL 抓取异常：" + failed.map { "\($0.id) (\($0.errorTag ?? $0.status))" }.joined(separator: ", ")
        }()

        return buildExecutionOutput(
            headerTitle: "Exa 网页内容提取（\(validatedURLs.count) 个网址）",
            results: parsed.results,
            synthesizedAnswer: parsed.synthesizedAnswer,
            searchType: "contents",
            sources: [DesktopSearchSourceReport(service: .exa, succeeded: true, hitCount: parsed.results.count, error: nil)],
            executionMode: .sequentialFallback,
            fallbackReason: statusNote
        )
    }

    private static func executeExaAnswer(
        args: [String: Any]?,
        rawInput: String,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        let apiKey = try requireExaKey(config: config)
        let query = ((args?["query"] as? String) ?? (args == nil ? rawInput : ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw DesktopRuntimeError.message("Exa answer 需要非空的 query 参数。")
        }
        let params = DesktopExaParameters.parse(from: args ?? [:])
        let body = DesktopExaClient.buildAnswerBody(query: query, parameters: params)
        let req = try buildJSONRequest(
            url: DesktopExaClient.baseURL.appendingPathComponent("answer"),
            body: body,
            headers: ["x-api-key": apiKey, "Authorization": "Bearer \(apiKey)"]
        )
        let object = try await sendJSON(req, providerName: "Exa", transport: transport)
        let parsed = DesktopExaClient.parseResponse(
            object: object,
            endpoint: "answer",
            queryOrTarget: query,
            requestedType: "answer",
            maxResults: config.resultCount
        )
        guard (parsed.synthesizedAnswer?.isEmpty == false) || !parsed.results.isEmpty else {
            throw DesktopRuntimeError.message("Exa answer 未返回有效回答。")
        }
        return buildExecutionOutput(
            headerTitle: "Exa 检索问答：\(query)",
            results: parsed.results,
            synthesizedAnswer: parsed.synthesizedAnswer,
            searchType: "answer",
            sources: [DesktopSearchSourceReport(service: .exa, succeeded: true, hitCount: parsed.results.count, error: nil)],
            executionMode: .sequentialFallback,
            fallbackReason: nil
        )
    }

    private static func executeExaFindSimilar(
        args: [String: Any]?,
        rawInput: String,
        config: ConfigurationSnapshot,
        transport: @escaping DesktopSearchHTTPHandler
    ) async throws -> DesktopSearchExecutionOutput {
        try Task.checkCancellation()
        let apiKey = try requireExaKey(config: config)
        let params = DesktopExaParameters.parse(from: args ?? [:])
        let rawURL = (params.url ?? (args == nil ? rawInput : "")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            throw DesktopRuntimeError.message("Exa find_similar 需要非空的 url 参数。")
        }
        let validURL = try await validatePublicURL(rawURL)
        let requestedMax = intValue(args?["max_results"] ?? args?["num_results"] ?? args?["numResults"]) ?? config.resultCount
        let maxResults = min(DesktopSearchSettings.resultLimit, max(1, requestedMax))
        let body = DesktopExaClient.buildFindSimilarBody(
            url: validURL.absoluteString,
            maxResults: maxResults,
            parameters: params,
            defaults: config.exaOptions
        )
        let req = try buildJSONRequest(
            url: DesktopExaClient.baseURL.appendingPathComponent("findSimilar"),
            body: body,
            headers: ["x-api-key": apiKey, "Authorization": "Bearer \(apiKey)"]
        )
        let object = try await sendJSON(req, providerName: "Exa", transport: transport)
        let parsed = DesktopExaClient.parseResponse(
            object: object,
            endpoint: "findSimilar",
            queryOrTarget: validURL.absoluteString,
            requestedType: "findSimilar",
            maxResults: maxResults
        )
        guard !parsed.results.isEmpty else {
            throw DesktopRuntimeError.message("Exa find_similar 未找到相似网页。")
        }
        return buildExecutionOutput(
            headerTitle: "Exa 相似网页检索：\(validURL.absoluteString)",
            results: parsed.results,
            synthesizedAnswer: nil,
            searchType: "findSimilar",
            sources: [DesktopSearchSourceReport(service: .exa, succeeded: true, hitCount: parsed.results.count, error: nil)],
            executionMode: .sequentialFallback,
            fallbackReason: nil
        )
    }
}
