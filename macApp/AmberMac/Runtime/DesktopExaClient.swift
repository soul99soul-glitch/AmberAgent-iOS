import Foundation

/// Structured image item preserved across search providers, tool output formatting, and UIMessage media metadata.
struct DesktopSearchImage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var url: String
    var title: String?
    var alt: String?
    var sourceURL: String?
    var snippet: String?

    init(
        id: String? = nil,
        url: String,
        title: String? = nil,
        alt: String? = nil,
        sourceURL: String? = nil,
        snippet: String? = nil
    ) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? DesktopSearchURLIdentity.dedupeKey(for: trimmedURL)
        self.url = trimmedURL
        self.title = Self.clean(title)
        self.alt = Self.clean(alt)
        self.sourceURL = Self.clean(sourceURL)
        self.snippet = Self.clean(snippet, maxLength: 240)
    }

    var displayLabel: String {
        if let alt, !alt.isEmpty { return alt }
        if let title, !title.isEmpty { return title }
        return "搜索图片"
    }

    private static func clean(_ value: String?, maxLength: Int = 200) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
    }
}

/// Normalized search hit shared across Exa and all other macOS search providers.
struct DesktopSearchHit: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
    var publishedDate: String?
    var author: String?
    var summary: String?
    var highlights: [String]
    var text: String?
    var subpages: [DesktopExaSubpageHit]
    var images: [DesktopSearchImage]
    var sourceService: String?

    init(
        title: String,
        url: String,
        snippet: String,
        publishedDate: String? = nil,
        author: String? = nil,
        summary: String? = nil,
        highlights: [String] = [],
        text: String? = nil,
        subpages: [DesktopExaSubpageHit] = [],
        images: [DesktopSearchImage] = [],
        sourceService: String? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publishedDate = publishedDate?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.author = author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.highlights = highlights.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.subpages = subpages
        self.images = DesktopSearchImageDeduplicator.deduplicate(images)
        self.sourceService = sourceService
    }
}

struct DesktopExaSubpageHit: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
}

struct DesktopExaContentStatus: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var errorTag: String?
    var httpStatusCode: Int?
}

struct DesktopExaResponse: Equatable, Sendable {
    var endpoint: String
    var queryOrTarget: String
    var searchType: String?
    var synthesizedAnswer: String?
    var results: [DesktopSearchHit]
    var statuses: [DesktopExaContentStatus]
}

/// Parsed native parameters for Exa endpoints (`/search`, `/contents`, `/answer`, `/findSimilar`).
struct DesktopExaParameters: Equatable, Sendable {
    var type: String?
    var category: String?
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    var startPublishedDate: String?
    var endPublishedDate: String?
    var includeText: [String] = []
    var excludeText: [String] = []
    var additionalQueries: [String] = []
    var userLocation: String?
    var moderation: Bool?
    var systemPrompt: String?
    var outputSchemaJSON: String?

    // Content retrieval controls
    var includeHighlights: Bool?
    var highlightsQuery: String?
    var highlightsMaxCharacters: Int?
    var numSentences: Int?
    var highlightsPerURL: Int?

    var includeFullText: Bool?
    var textMaxCharacters: Int?

    var includeSummary: Bool?
    var summaryQuery: String?

    var maxAgeHours: Int?
    var livecrawlTimeout: Int?
    var subpages: Int?
    var subpageTarget: [String] = []

    var includeImages: Bool?
    var imageLinksCount: Int?
    var linksCount: Int?

    // `/contents` & `/findSimilar` & `/answer` specific fields
    var urls: [String] = []
    var url: String?
    var excludeSourceDomain: Bool?
    var answerModel: String?

    static func == (lhs: DesktopExaParameters, rhs: DesktopExaParameters) -> Bool {
        lhs.type == rhs.type
            && lhs.category == rhs.category
            && lhs.includeDomains == rhs.includeDomains
            && lhs.excludeDomains == rhs.excludeDomains
            && lhs.startPublishedDate == rhs.startPublishedDate
            && lhs.endPublishedDate == rhs.endPublishedDate
            && lhs.includeText == lhs.includeText
            && lhs.excludeText == rhs.excludeText
            && lhs.additionalQueries == rhs.additionalQueries
            && lhs.userLocation == rhs.userLocation
            && lhs.moderation == rhs.moderation
            && lhs.systemPrompt == rhs.systemPrompt
            && lhs.includeHighlights == rhs.includeHighlights
            && lhs.highlightsQuery == rhs.highlightsQuery
            && lhs.highlightsMaxCharacters == rhs.highlightsMaxCharacters
            && lhs.numSentences == rhs.numSentences
            && lhs.highlightsPerURL == rhs.highlightsPerURL
            && lhs.includeFullText == rhs.includeFullText
            && lhs.textMaxCharacters == rhs.textMaxCharacters
            && lhs.includeSummary == rhs.includeSummary
            && lhs.summaryQuery == rhs.summaryQuery
            && lhs.maxAgeHours == rhs.maxAgeHours
            && lhs.livecrawlTimeout == rhs.livecrawlTimeout
            && lhs.subpages == rhs.subpages
            && lhs.subpageTarget == rhs.subpageTarget
            && lhs.includeImages == rhs.includeImages
            && lhs.imageLinksCount == rhs.imageLinksCount
            && lhs.linksCount == rhs.linksCount
            && lhs.urls == rhs.urls
            && lhs.url == rhs.url
            && lhs.excludeSourceDomain == rhs.excludeSourceDomain
            && lhs.answerModel == rhs.answerModel
    }

    static func parse(from object: [String: Any]) -> DesktopExaParameters {
        var params = DesktopExaParameters()
        params.type = Self.normalizeType(
            Self.string(object["type"]) ?? Self.string(object["search_type"]) ?? Self.string(object["searchType"])
        )
        params.category = Self.normalizeCategory(Self.string(object["category"]))
        params.includeDomains = Self.stringArray(object["include_domains"] ?? object["includeDomains"])
        params.excludeDomains = Self.stringArray(object["exclude_domains"] ?? object["excludeDomains"])
        params.startPublishedDate = Self.string(object["start_published_date"] ?? object["startPublishedDate"])
        params.endPublishedDate = Self.string(object["end_published_date"] ?? object["endPublishedDate"])
        params.includeText = Self.stringArray(object["include_text"] ?? object["includeText"])
        params.excludeText = Self.stringArray(object["exclude_text"] ?? object["excludeText"])
        params.additionalQueries = Self.stringArray(object["additional_queries"] ?? object["additionalQueries"])
        params.userLocation = Self.string(object["user_location"] ?? object["userLocation"])
        params.moderation = Self.bool(object["moderation"])
        params.systemPrompt = Self.string(object["system_prompt"] ?? object["systemPrompt"])
        if let schema = (object["output_schema"] ?? object["outputSchema"]) as? [String: Any],
           JSONSerialization.isValidJSONObject(schema),
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            params.outputSchemaJSON = String(decoding: data, as: UTF8.self)
        }

        // Top-level or nested `contents`
        let contentsObj = object["contents"] as? [String: Any]

        // Highlights
        let rawHighlights = contentsObj?["highlights"] ?? object["highlights"] ?? object["include_highlights"]
        if let flag = Self.bool(rawHighlights) {
            params.includeHighlights = flag
        } else if let hlObj = rawHighlights as? [String: Any] {
            params.includeHighlights = true
            params.highlightsQuery = Self.string(hlObj["query"])
            params.highlightsMaxCharacters = Self.int(hlObj["max_characters"] ?? hlObj["maxCharacters"])
            params.numSentences = Self.int(hlObj["num_sentences"] ?? hlObj["numSentences"])
            params.highlightsPerURL = Self.int(hlObj["highlights_per_url"] ?? hlObj["highlightsPerUrl"])
        }
        if let hlQuery = Self.string(object["highlights_query"] ?? object["highlightsQuery"]) {
            params.includeHighlights = true
            params.highlightsQuery = hlQuery
        }
        if let hlMax = Self.int(object["highlights_max_characters"] ?? object["highlightsMaxCharacters"]) {
            params.highlightsMaxCharacters = hlMax
        }

        // Full text
        let rawText = contentsObj?["text"] ?? object["text"] ?? object["include_full_text"] ?? object["includeFullText"]
        if let flag = Self.bool(rawText) {
            params.includeFullText = flag
        } else if let textObj = rawText as? [String: Any] {
            params.includeFullText = true
            params.textMaxCharacters = Self.int(textObj["max_characters"] ?? textObj["maxCharacters"])
        }
        if let maxChars = Self.int(object["text_max_characters"] ?? object["textMaxCharacters"] ?? object["max_characters"] ?? object["maxCharacters"]) {
            params.textMaxCharacters = maxChars
        }

        // Summary
        let rawSummary = contentsObj?["summary"] ?? object["summary"] ?? object["include_summary"] ?? object["includeSummary"]
        if let flag = Self.bool(rawSummary) {
            params.includeSummary = flag
        } else if let sumQuery = Self.string(rawSummary) {
            params.includeSummary = true
            params.summaryQuery = sumQuery
        } else if let sumObj = rawSummary as? [String: Any] {
            params.includeSummary = true
            params.summaryQuery = Self.string(sumObj["query"])
        }
        if let sumQuery = Self.string(object["summary_query"] ?? object["summaryQuery"]) {
            params.includeSummary = true
            params.summaryQuery = sumQuery
        }

        params.maxAgeHours = Self.int(contentsObj?["max_age_hours"] ?? contentsObj?["maxAgeHours"] ?? object["max_age_hours"] ?? object["maxAgeHours"])
        params.livecrawlTimeout = Self.int(contentsObj?["livecrawl_timeout"] ?? contentsObj?["livecrawlTimeout"] ?? object["livecrawl_timeout"] ?? object["livecrawlTimeout"])
        params.subpages = Self.int(contentsObj?["subpages"] ?? object["subpages"])
        params.subpageTarget = Self.stringArray(contentsObj?["subpage_target"] ?? contentsObj?["subpageTarget"] ?? object["subpage_target"] ?? object["subpageTarget"])

        let extrasObj = (contentsObj?["extras"] ?? object["extras"]) as? [String: Any]
        if let includeImages = Self.bool(object["include_images"] ?? object["includeImages"]) {
            params.includeImages = includeImages
        }
        if let imgLinks = Self.int(extrasObj?["imageLinks"] ?? extrasObj?["image_links"] ?? object["image_links"] ?? object["imageLinks"]) {
            params.imageLinksCount = min(10, max(0, imgLinks))
            if imgLinks > 0 { params.includeImages = true }
            else if params.includeImages == nil { params.includeImages = false }
        }
        if let richLinks = Self.int(extrasObj?["richImageLinks"] ?? extrasObj?["rich_image_links"]) {
            params.imageLinksCount = max(params.imageLinksCount ?? 0, min(10, max(0, richLinks)))
            if richLinks > 0 { params.includeImages = true }
        }
        if let linksCount = Self.int(extrasObj?["links"] ?? object["links_count"] ?? object["linksCount"]) {
            params.linksCount = min(10, max(0, linksCount))
        }

        params.urls = Self.stringArray(object["urls"] ?? object["ids"])
        params.url = Self.string(object["url"] ?? object["link"] ?? object["uri"])
        params.excludeSourceDomain = Self.bool(object["exclude_source_domain"] ?? object["excludeSourceDomain"])
        params.answerModel = Self.string(object["model"] ?? object["answer_model"])
        return params
    }

    static func normalizeType(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed {
        case "auto", "lite", "deep-lite", "deep", "fast", "instant", "deep-reasoning", "neural", "keyword":
            return trimmed
        case "deeplite", "deep_lite":
            return "deep-lite"
        case "deepreasoning", "deep_reasoning":
            return "deep-reasoning"
        default:
            return trimmed
        }
    }

    static func normalizeCategory(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed {
        case "company", "companies":
            return "company"
        case "publication", "publications", "paper", "papers", "research paper", "research_paper", "pdf":
            return "publication"
        case "news":
            return "news"
        case "personal site", "personal_site", "personalsite", "blog":
            return "personal site"
        case "financial report", "financial_report", "financial":
            return "financial report"
        case "people", "person", "profile":
            return "people"
        default:
            return trimmed
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let numVal = value as? NSNumber { return numVal.intValue }
        if let strVal = value as? String { return Int(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let boolVal = value as? Bool { return boolVal }
        if let strVal = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["true", "1", "yes"].contains(strVal) { return true }
            if ["false", "0", "no"].contains(strVal) { return false }
        }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { item -> String? in
                guard let str = item as? String else { return nil }
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let single = value as? String {
            return single
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

/// Official Exa API v2 client supporting `/search`, `/contents`, `/answer`, and `/findSimilar`.
enum DesktopExaClient {
    static let baseURL = URL(string: "https://api.exa.ai")!

    static func buildSearchBody(
        query: String,
        maxResults: Int,
        parameters: DesktopExaParameters,
        defaults: DesktopExaOptions
    ) -> [String: Any] {
        let resolvedType = parameters.type ?? defaults.searchType.rawValue
        let isLite = resolvedType == "lite"
        let isDeep = resolvedType == "deep" || resolvedType == "deep-lite" || resolvedType == "deep-reasoning"
        let category = parameters.category

        var body: [String: Any] = [
            "query": query,
            "numResults": min(100, max(1, maxResults)),
            "type": resolvedType
        ]

        if let category, !category.isEmpty {
            body["category"] = category
        }
        if !parameters.includeDomains.isEmpty {
            body["includeDomains"] = parameters.includeDomains
        }
        // Per Exa spec: `people` category does not support `excludeDomains` (returns 400).
        if !parameters.excludeDomains.isEmpty, category != "people" {
            body["excludeDomains"] = parameters.excludeDomains
        }
        // Per Exa spec: `company` and `people` categories do not support publishedDate filters (returns 400).
        if category != "company" && category != "people" {
            if let start = parameters.startPublishedDate {
                body["startPublishedDate"] = start
            }
            if let end = parameters.endPublishedDate {
                body["endPublishedDate"] = end
            }
        }
        if !parameters.includeText.isEmpty {
            body["includeText"] = Array(parameters.includeText.prefix(1))
        }
        if !parameters.excludeText.isEmpty {
            body["excludeText"] = Array(parameters.excludeText.prefix(1))
        }
        if isDeep, !parameters.additionalQueries.isEmpty {
            body["additionalQueries"] = Array(parameters.additionalQueries.prefix(5))
        }
        if let userLocation = parameters.userLocation {
            body["userLocation"] = userLocation
        }
        if let moderation = parameters.moderation {
            body["moderation"] = moderation
        }
        if !isLite {
            if let systemPrompt = parameters.systemPrompt {
                body["systemPrompt"] = systemPrompt
            }
            if let outputSchemaJSON = parameters.outputSchemaJSON,
               let data = outputSchemaJSON.data(using: .utf8),
               let schemaObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                body["outputSchema"] = schemaObj
            }
        }

        let contents = buildContentsOptions(
            parameters: parameters,
            defaults: defaults,
            isLite: isLite,
            defaultFullText: false
        )
        if !contents.isEmpty {
            body["contents"] = contents
        }
        return body
    }

    static func buildContentsBody(
        urls: [String],
        parameters: DesktopExaParameters,
        defaults: DesktopExaOptions
    ) -> [String: Any] {
        // Per Exa OpenAPI spec: `/contents` takes `urls` and content options at the top level.
        var body = buildContentsOptions(
            parameters: parameters,
            defaults: defaults,
            isLite: false,
            defaultFullText: true
        )
        body["urls"] = urls
        return body
    }

    static func buildFindSimilarBody(
        url: String,
        maxResults: Int,
        parameters: DesktopExaParameters,
        defaults: DesktopExaOptions
    ) -> [String: Any] {
        var body: [String: Any] = [
            "url": url,
            "numResults": min(100, max(1, maxResults))
        ]
        if let category = parameters.category {
            body["category"] = category
        }
        if !parameters.includeDomains.isEmpty {
            body["includeDomains"] = parameters.includeDomains
        }
        if !parameters.excludeDomains.isEmpty, parameters.category != "people" {
            body["excludeDomains"] = parameters.excludeDomains
        }
        if parameters.category != "company" && parameters.category != "people" {
            if let start = parameters.startPublishedDate {
                body["startPublishedDate"] = start
            }
            if let end = parameters.endPublishedDate {
                body["endPublishedDate"] = end
            }
        }
        if let excludeSourceDomain = parameters.excludeSourceDomain {
            body["excludeSourceDomain"] = excludeSourceDomain
        }
        let contents = buildContentsOptions(
            parameters: parameters,
            defaults: defaults,
            isLite: false,
            defaultFullText: false
        )
        if !contents.isEmpty {
            body["contents"] = contents
        }
        return body
    }

    static func buildAnswerBody(
        query: String,
        parameters: DesktopExaParameters
    ) -> [String: Any] {
        var body: [String: Any] = [
            "query": query,
            "text": parameters.includeFullText ?? true
        ]
        if let model = parameters.answerModel {
            body["model"] = model
        }
        if let systemPrompt = parameters.systemPrompt {
            body["systemPrompt"] = systemPrompt
        }
        if let outputSchemaJSON = parameters.outputSchemaJSON,
           let data = outputSchemaJSON.data(using: .utf8),
           let schemaObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            body["outputSchema"] = schemaObj
        }
        if let userLocation = parameters.userLocation {
            body["userLocation"] = userLocation
        }
        return body
    }

    private static func buildContentsOptions(
        parameters: DesktopExaParameters,
        defaults: DesktopExaOptions,
        isLite: Bool,
        defaultFullText: Bool
    ) -> [String: Any] {
        var contents: [String: Any] = [:]

        let defaultHighlights = defaults.contentMode == .highlights || defaults.contentMode == .highlightsAndText
        let defaultText = defaultFullText || defaults.contentMode == .text || defaults.contentMode == .highlightsAndText
        let defaultSummary = defaults.contentMode == .summary

        let wantHighlights = parameters.includeHighlights ?? defaultHighlights
        let wantText = parameters.includeFullText ?? defaultText
        let wantSummary = !isLite && (parameters.includeSummary ?? defaultSummary)

        if wantHighlights {
            var hl: [String: Any] = [:]
            if let query = parameters.highlightsQuery { hl["query"] = query }
            if let maxChars = parameters.highlightsMaxCharacters { hl["maxCharacters"] = max(100, maxChars) }
            if let sentences = parameters.numSentences { hl["numSentences"] = max(1, sentences) }
            if let perURL = parameters.highlightsPerURL { hl["highlightsPerUrl"] = max(1, perURL) }
            contents["highlights"] = hl.isEmpty ? true : hl
        }

        if wantText {
            if let maxChars = parameters.textMaxCharacters {
                contents["text"] = ["maxCharacters": max(200, maxChars)]
            } else {
                contents["text"] = true
            }
        }

        if wantSummary {
            if let sumQuery = parameters.summaryQuery {
                contents["summary"] = ["query": sumQuery]
            } else {
                contents["summary"] = true
            }
        }

        // Per Exa spec: `lite` rejects `maxAgeHours`, `subpages`, `subpageTarget`, `livecrawlTimeout`, and `extras`.
        if !isLite {
            if let maxAge = parameters.maxAgeHours ?? defaults.maxAgeHours {
                contents["maxAgeHours"] = maxAge
            }
            if let livecrawlTimeout = parameters.livecrawlTimeout {
                contents["livecrawlTimeout"] = max(1000, livecrawlTimeout)
            }
            if let subpages = parameters.subpages, subpages > 0 {
                contents["subpages"] = min(20, subpages)
            }
            if !parameters.subpageTarget.isEmpty {
                contents["subpageTarget"] = parameters.subpageTarget.count == 1
                    ? parameters.subpageTarget[0]
                    : parameters.subpageTarget
            }

            let wantImages = parameters.includeImages ?? defaults.includeImages
            let imageCount = parameters.imageLinksCount ?? (wantImages ? max(1, defaults.imageLinksCount) : 0)
            var extras: [String: Any] = [:]
            if wantImages && imageCount > 0 {
                extras["imageLinks"] = imageCount
                extras["richImageLinks"] = imageCount
            }
            if let linksCount = parameters.linksCount, linksCount > 0 {
                extras["links"] = linksCount
            }
            if !extras.isEmpty {
                contents["extras"] = extras
            }
        }

        return contents
    }

    static func parseResponse(
        object: [String: Any],
        endpoint: String,
        queryOrTarget: String,
        requestedType: String? = nil,
        maxResults: Int = 50
    ) -> DesktopExaResponse {
        var synthesizedAnswer: String?
        if let answer = (object["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            synthesizedAnswer = answer
        } else if let output = object["output"] as? [String: Any] {
            if let content = (output["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                synthesizedAnswer = content
            } else if let contentObj = output["content"],
                      JSONSerialization.isValidJSONObject(contentObj),
                      let data = try? JSONSerialization.data(withJSONObject: contentObj, options: [.sortedKeys]) {
                synthesizedAnswer = String(decoding: data, as: UTF8.self)
            }
        }

        let rawResults = (object["results"] as? [[String: Any]])
            ?? (object["citations"] as? [[String: Any]])
            ?? []

        let hits = rawResults.prefix(max(1, maxResults)).compactMap { item -> DesktopSearchHit? in
            parseResultItem(item)
        }

        let rawStatuses = (object["statuses"] as? [[String: Any]]) ?? []
        let statuses = rawStatuses.compactMap { item -> DesktopExaContentStatus? in
            guard let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            let status = (item["status"] as? String) ?? "unknown"
            let errorObj = item["error"] as? [String: Any]
            let errorTag = errorObj?["tag"] as? String
            let httpStatusCode = (errorObj?["httpStatusCode"] as? Int) ?? (errorObj?["httpStatusCode"] as? NSNumber)?.intValue
            return DesktopExaContentStatus(id: id, status: status, errorTag: errorTag, httpStatusCode: httpStatusCode)
        }

        let resolvedType = (object["resolvedSearchType"] as? String) ?? requestedType
        return DesktopExaResponse(
            endpoint: endpoint,
            queryOrTarget: queryOrTarget,
            searchType: resolvedType,
            synthesizedAnswer: synthesizedAnswer,
            results: Array(hits),
            statuses: statuses
        )
    }

    static func parseResultItem(_ item: [String: Any]) -> DesktopSearchHit? {
        let url = ((item["url"] as? String) ?? (item["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? url : rawTitle
        let publishedDate = (item["publishedDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (item["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlights = ((item["highlights"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawSubpages = (item["subpages"] as? [[String: Any]]) ?? []
        var subpages: [DesktopExaSubpageHit] = []
        var subpageImages: [DesktopSearchImage] = []
        for sub in rawSubpages {
            let subURL = ((sub["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subURL.isEmpty else { continue }
            let subTitle = ((sub["title"] as? String) ?? subURL).trimmingCharacters(in: .whitespacesAndNewlines)
            let subSummary = (sub["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subHighlights = ((sub["highlights"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let subText = (sub["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subSnippet = [subSummary, subHighlights, String(subText.prefix(400))]
                .first { !$0.isEmpty } ?? ""
            subpages.append(DesktopExaSubpageHit(title: subTitle, url: subURL, snippet: subSnippet))
            subpageImages.append(contentsOf: extractImages(from: sub, defaultTitle: subTitle, sourceURL: subURL, snippet: subSnippet))
        }

        // Compose best snippet for LLM and media context
        var snippetParts: [String] = []
        if let summary, !summary.isEmpty {
            snippetParts.append("摘要：\(summary)")
        }
        if !highlights.isEmpty {
            snippetParts.append(highlights.joined(separator: " … "))
        }
        if let text, !text.isEmpty {
            if snippetParts.isEmpty {
                snippetParts.append(String(text.prefix(1_600)))
            } else if text.count > 120 {
                snippetParts.append("正文摘录：\(String(text.prefix(1_200)))")
            }
        }
        let snippet = snippetParts.joined(separator: "\n")
        let contextSnippet = highlights.first ?? summary ?? text.map { String($0.prefix(240)) } ?? title
        let images = extractImages(from: item, defaultTitle: title, sourceURL: url, snippet: contextSnippet) + subpageImages

        return DesktopSearchHit(
            title: title,
            url: url,
            snippet: snippet,
            publishedDate: publishedDate,
            author: author,
            summary: summary,
            highlights: highlights,
            text: text,
            subpages: subpages,
            images: images,
            sourceService: "Exa"
        )
    }

    static func extractImages(
        from item: [String: Any],
        defaultTitle: String,
        sourceURL: String,
        snippet: String?
    ) -> [DesktopSearchImage] {
        var collected: [DesktopSearchImage] = []

        if let hero = (item["image"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isValidHTTPURL(hero) {
            collected.append(DesktopSearchImage(
                url: hero,
                title: defaultTitle,
                alt: defaultTitle,
                sourceURL: sourceURL,
                snippet: snippet
            ))
        }

        if let extras = item["extras"] as? [String: Any] {
            if let richLinks = extras["richImageLinks"] as? [[String: Any]] {
                for rich in richLinks {
                    let rawURL = ((rich["url"] as? String) ?? (rich["image"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard Self.isValidHTTPURL(rawURL) else { continue }
                    let alt = ((rich["alt"] as? String) ?? (rich["title"] as? String) ?? (rich["description"] as? String))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    collected.append(DesktopSearchImage(
                        url: rawURL,
                        title: defaultTitle,
                        alt: alt?.nonEmpty ?? defaultTitle,
                        sourceURL: sourceURL,
                        snippet: snippet
                    ))
                }
            }
            if let imageLinks = extras["imageLinks"] as? [Any] {
                for entry in imageLinks {
                    if let rawURL = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       Self.isValidHTTPURL(rawURL) {
                        collected.append(DesktopSearchImage(
                            url: rawURL,
                            title: defaultTitle,
                            alt: nil,
                            sourceURL: sourceURL,
                            snippet: snippet
                        ))
                    } else if let obj = entry as? [String: Any],
                              let rawURL = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              Self.isValidHTTPURL(rawURL) {
                        let alt = (obj["alt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        collected.append(DesktopSearchImage(
                            url: rawURL,
                            title: defaultTitle,
                            alt: alt,
                            sourceURL: sourceURL,
                            snippet: snippet
                        ))
                    }
                }
            }
        }

        return DesktopSearchImageDeduplicator.deduplicate(collected)
    }

    static func isValidHTTPURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return false
        }
        return true
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
