import Foundation

struct IOSHackerNewsHotlistProvider: IOSHotlistProvider {
    let providerId = "hacker_news"
    let displayName = "Hacker News"

    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            return configuration
        }())
        let decoder = JSONDecoder()
        let (topData, _) = try await session.data(from: URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!)
        let ids = try decoder.decode([Int].self, from: topData)
        let now = IOSHotListClock.currentEpochMs()
        var items: [IOSHotlistItem] = []

        for (index, id) in ids.prefix(max(limit, 0)).enumerated() {
            let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!
            let (data, _) = try await session.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["deleted"] as? Bool) != true,
                  (object["dead"] as? Bool) != true,
                  let title = object["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            items.append(IOSHotlistItem(
                providerId: providerId,
                title: String(title.prefix(160)),
                url: object["url"] as? String,
                rank: index + 1,
                score: object["score"] as? Int,
                fetchedAt: now
            ))
        }
        return items
    }
}

// MARK: - Additional hotlist providers (Android BuiltInHotListProviders parity)
//
// Android ships 9 built-in hotlist providers; iOS only had HackerNews. These
// add the providers with stable public endpoints (RSS/JSON/HTML). Providers
// that need login or have aggressive anti-scraping (Weibo, Bilibili) are
// omitted honestly rather than faked.

/// Parses RSS/Atom <item><title>/<link> entries into hotlist items. Shared by
/// the ArxivAI / InfoqAI / 36Kr RSS providers.
struct IOSRSSHotlistProvider: IOSHotlistProvider {
    let providerId: String
    let displayName: String
    let feedURL: String

    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        let session = Self.ephemeralSession
        let (data, _) = try await session.data(from: URL(string: feedURL)!)
        let xml = String(data: data, encoding: .utf8) ?? ""
        let now = IOSHotListClock.currentEpochMs()
        // Naive RSS <item> extraction (sufficient for feed titles/links).
        let itemPattern = #"<item[^>]*>([\s\S]*?)</item>"#
        guard let regex = try? NSRegularExpression(pattern: itemPattern, options: []) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        var items: [IOSHotlistItem] = []
        for (index, match) in matches.prefix(max(limit, 0)).enumerated() {
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[range])
            let title = Self.firstTag(in: block, tag: "title").trimmingCharacters(in: .whitespacesAndNewlines)
            let link = Self.firstTag(in: block, tag: "link").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            items.append(IOSHotlistItem(
                providerId: providerId,
                title: String(title.prefix(160)),
                url: link.isEmpty ? nil : link,
                rank: index + 1,
                score: nil,
                fetchedAt: now
            ))
        }
        return items
    }

    private static func firstTag(in block: String, tag: String) -> String {
        let pattern = "<\(tag)[^>]*><!\\[CDATA\\[([\\s\\S]*?)\\]\\]></\(tag)>|<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        guard let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              match.numberOfRanges >= 4 else { return "" }
        // Group 2 = CDATA content, group 3 = plain content.
        if let r = Range(match.range(at: 2), in: block), !r.isEmpty {
            return String(block[r])
        }
        if let r = Range(match.range(at: 3), in: block) {
            return String(block[r])
        }
        return ""
    }

    static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()
}

/// Arxiv AI/CL/LG/RO RSS feed.
struct IOSArxivAIHotlistProvider: IOSHotlistProvider {
    let providerId = "arxiv_ai"
    let displayName = "Arxiv AI"
    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        // Merge the AI-related arxiv RSS feeds Android uses.
        let urls = ["https://rss.arxiv.org/rss/cs.AI", "https://rss.arxiv.org/rss/cs.CL"]
        var all: [IOSHotlistItem] = []
        for url in urls {
            let provider = IOSRSSHotlistProvider(providerId: providerId, displayName: displayName, feedURL: url)
            all.append(contentsOf: try await provider.fetch(limit: limit))
        }
        return Array(all.prefix(limit))
    }
}

/// InfoqAI RSS feed.
struct IOSInfoqAIHotlistProvider: IOSHotlistProvider {
    let providerId = "infoq_ai"
    let displayName = "InfoQ AI"
    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        try await IOSRSSHotlistProvider(
            providerId: providerId,
            displayName: displayName,
            feedURL: "https://www.infoq.com/artificial_intelligence/rss/"
        ).fetch(limit: limit)
    }
}

/// HuggingFace daily papers (JSON API).
struct IOSHuggingFacePapersHotlistProvider: IOSHotlistProvider {
    let providerId = "huggingface_papers"
    let displayName = "HuggingFace Papers"
    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        let session = IOSRSSHotlistProvider.ephemeralSession
        let (data, _) = try await session.data(from: URL(string: "https://huggingface.co/api/daily_papers")!)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let now = IOSHotListClock.currentEpochMs()
        return array.prefix(max(limit, 0)).enumerated().map { index, entry in
            let paper = entry["paper"] as? [String: Any]
            let title = (paper?["title"] as? String) ?? ""
            let paperId = (paper?["id"] as? String) ?? ""
            return IOSHotlistItem(
                providerId: providerId,
                title: String(title.prefix(160)),
                url: paperId.isEmpty ? nil : "https://huggingface.co/papers/\(paperId)",
                rank: index + 1,
                score: (entry["upvotes"] as? Int),
                fetchedAt: now
            )
        }
    }
}

/// Github trending (HTML scrape — GitHub provides no JSON API for trending).
struct IOSGithubTrendingHotlistProvider: IOSHotlistProvider {
    let providerId = "github_trending_ai"
    let displayName = "GitHub AI"
    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        let session = IOSRSSHotlistProvider.ephemeralSession
        let (data, _) = try await session.data(from: URL(string: "https://github.com/trending")!)
        let html = String(data: data, encoding: .utf8) ?? ""
        let now = IOSHotListClock.currentEpochMs()
        // Extract repo paths from <h2 class="..."><a href="/owner/repo">.
        let pattern = #"<h2[^>]*>\s*<a[^>]*href="(/[^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var items: [IOSHotlistItem] = []
        for (index, match) in matches.prefix(max(limit, 0)).enumerated() {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let path = String(html[r])
            let name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { continue }
            items.append(IOSHotlistItem(
                providerId: providerId,
                title: String(name.prefix(160)),
                url: "https://github.com\(path)",
                rank: index + 1,
                score: nil,
                fetchedAt: now
            ))
        }
        return items
    }
}

/// NewsNow 聚合器预设源(Android NewsNowPresets 对齐)。NewsNow 代理了一批中文热榜,
/// 标题本身就是中文、且比直连源(如 36kr.com/feed 常被 UA 拦)更稳。按分类组织,便于在
/// 来源设置里"分类添加"。
struct IOSNewsNowPreset: Identifiable, Equatable {
    let newsNowId: String   // e.g. "zhihu"
    let displayName: String // e.g. "知乎热榜"
    let category: String    // e.g. "社交热搜"

    var id: String { providerId }
    var providerId: String { "newsnow:\(newsNowId)" }

    static let all: [IOSNewsNowPreset] = [
        .init(newsNowId: "zhihu", displayName: "知乎热榜", category: "社交热搜"),
        .init(newsNowId: "weibo", displayName: "微博热搜", category: "社交热搜"),
        .init(newsNowId: "douyin", displayName: "抖音热搜", category: "社交热搜"),
        .init(newsNowId: "bilibili-hot-search", displayName: "B 站热搜", category: "科技数码"),
        .init(newsNowId: "ithome", displayName: "IT 之家", category: "科技数码"),
        .init(newsNowId: "sspai", displayName: "少数派", category: "科技数码"),
        .init(newsNowId: "juejin", displayName: "掘金", category: "科技数码"),
        .init(newsNowId: "36kr-quick", displayName: "36 氪快讯", category: "科技数码"),
        .init(newsNowId: "coolapk", displayName: "酷安", category: "科技数码"),
        .init(newsNowId: "v2ex-share", displayName: "V2EX 分享", category: "科技数码"),
        .init(newsNowId: "github-trending-today", displayName: "GitHub 趋势", category: "科技数码"),
        .init(newsNowId: "xueqiu-hotstock", displayName: "雪球热股", category: "财经"),
        .init(newsNowId: "wallstreetcn-hot", displayName: "华尔街见闻", category: "财经"),
        .init(newsNowId: "cls-telegraph", displayName: "财联社电报", category: "财经"),
        .init(newsNowId: "hupu-zhugandaoretie", displayName: "虎扑步行街", category: "体育"),
    ]
}

/// 单个 NewsNow 源 provider。命中 `https://newsnow.busiyi.world/api/s?id=<id>&latest`,
/// 解析 `{items:[{title,url,extra:{info:热度}}]}`(Android FIELD_MAPPING_JSON 对齐)。
struct IOSNewsNowHotlistProvider: IOSHotlistProvider {
    let providerId: String
    let displayName: String
    let newsNowId: String

    func fetch(limit: Int) async throws -> [IOSHotlistItem] {
        let session = IOSRSSHotlistProvider.ephemeralSession
        var request = URLRequest(url: URL(string: "https://newsnow.busiyi.world/api/s?id=\(newsNowId)")!)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }
        let now = IOSHotListClock.currentEpochMs()
        return items.prefix(max(limit, 0)).enumerated().compactMap { index, item in
            guard let rawTitle = item["title"] as? String else { return nil }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let heat = (item["extra"] as? [String: Any])?["info"] as? String
            return IOSHotlistItem(
                providerId: providerId,
                title: String(title.prefix(160)),
                url: (url?.isEmpty == false) ? url : nil,
                rank: index + 1,
                score: nil,
                fetchedAt: now,
                heat: heat
            )
        }
    }
}

/// All built-in iOS hotlist providers (Android BuiltInHotListProviders parity
/// for the providers with stable public endpoints).
