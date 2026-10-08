import Foundation
@preconcurrency import Shared

enum IOSHotlistProviders {
    struct Descriptor: Identifiable, Codable, Equatable, Sendable {
        var id: String { providerId }
        var providerId: String
        var displayName: String
    }

    // NewsNow 源(中文热榜,标题本身中文)。直连 36kr.com/feed 常被 UA 拦返回空,故用
    // NewsNow 的 36kr-quick 取代。
    static let newsNow: [IOSHotlistProvider] = IOSNewsNowPreset.all.map {
        IOSNewsNowHotlistProvider(providerId: $0.providerId, displayName: $0.displayName, newsNowId: $0.newsNowId)
    }

    static let all: [IOSHotlistProvider] = [
        IOSHackerNewsHotlistProvider(),
        IOSArxivAIHotlistProvider(),
        IOSInfoqAIHotlistProvider(),
        IOSHuggingFacePapersHotlistProvider(),
        IOSGithubTrendingHotlistProvider()
    ] + newsNow

    static var descriptors: [Descriptor] {
        all.map { Descriptor(providerId: $0.providerId, displayName: $0.displayName) }
    }

    /// 分类 → provider id。内置英文源归「AI · 英文源」,NewsNow 源按各自分类。
    static func category(for providerId: String) -> String {
        if let preset = IOSNewsNowPreset.all.first(where: { $0.providerId == providerId }) {
            return preset.category
        }
        return "AI · 英文源"
    }

    static let categoryOrder: [String] = ["AI · 英文源", "社交热搜", "科技数码", "财经", "体育"]

    /// 描述符按分类分组(供来源设置"分类添加"展示),保持 categoryOrder 顺序。
    static func descriptorsByCategory() -> [(category: String, items: [Descriptor])] {
        let grouped = Dictionary(grouping: descriptors) { category(for: $0.providerId) }
        return categoryOrder.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    // 新装/未自定义用户的默认开启集(英文 + 几个常用中文源)。不开全部,避免一次刷新拉一堆源。
    // 注:NewsNow 的 36kr 上游目前常空,故默认用 IT 之家(稳定),36 氪仍保留为可选源。
    static let iOSDefaultProviderIds: Set<String> = [
        "hacker_news",
        "arxiv_ai",
        "infoq_ai",
        "36kr",
        "huggingface_papers",
        "github_trending_ai",
        "newsnow:zhihu",
        "newsnow:weibo",
        "newsnow:ithome",
        "newsnow:bilibili-hot-search",
    ]
    static let androidDefaultProviderIds: Set<String> = ["bilibili", "hacker_news"]
    static let supportedProviderIds: Set<String> = Set(all.map(\.providerId))

    static func provider(id: String) -> IOSHotlistProvider? {
        all.first { $0.providerId == id }
    }

    static func displayName(for providerId: String) -> String {
        provider(id: providerId)?.displayName ?? providerId
    }

    static func effectiveEnabledProviderIds(setting: TodayBoardSetting) -> Set<String> {
        let raw = Set(setting.hotListEnabledSources.map {
            String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        if raw.isEmpty {
            return []
        }
        if raw == androidDefaultProviderIds {
            return iOSDefaultProviderIds
        }
        return raw.intersection(supportedProviderIds)
    }
}

