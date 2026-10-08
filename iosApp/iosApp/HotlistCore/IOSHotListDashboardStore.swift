import Foundation
import Observation
@preconcurrency import Shared

@MainActor
@Observable
final class IOSHotListDashboardStore {
    static let shared = IOSHotListDashboardStore()

    private(set) var dashboard: IOSHotListDashboard
    /// Unfiltered provider data used as the cache source. The dashboard above
    /// is the current presentation projection and may remove rows for focus_only.
    private var rawDashboard: IOSHotListDashboard
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private let directory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = root.appendingPathComponent("deep_read", isDirectory: true)
        fileURL = directory.appendingPathComponent("hotlist_dashboard.json", isDirectory: false)
        let cachedDashboard = Self.load(from: fileURL, decoder: decoder, fileManager: fileManager) ?? .empty
        rawDashboard = cachedDashboard
        dashboard = cachedDashboard
    }

    func refresh(
        setting: TodayBoardSetting,
        force: Bool = true,
        limit: Int = 20,
        translate: IOSHotListTitleTranslate? = nil
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let enabledIds = IOSHotlistProviders.effectiveEnabledProviderIds(setting: setting)
        guard !enabledIds.isEmpty else {
            rawDashboard = .empty
            dashboard = rawDashboard
            lastError = nil
            persist()
            return
        }
        if !force, !shouldRefresh(setting: setting) {
            // Fresh enough to skip a re-fetch, but still fill in any untranslated titles
            // (the model may have become available after the last fetch, or a prior
            // translation was skipped — an enabled translator also runs on cached refresh).
            // applyTitleTranslations no-ops when nothing pends, so this spends an LLM call
            // only the first time new non-Chinese titles appear.
            let cached = rawDashboard.providers
            let prev = Dictionary(uniqueKeysWithValues: cached.map { ($0.providerId, $0) })
            let translated = await Self.applyTitleTranslations(to: cached, previous: prev, translate: translate)
            let topics = IOSHotListAggregator.aggregate(providerSnapshots: translated, limit: limit)
            rawDashboard = IOSHotListDashboard(
                topics: topics,
                providers: translated,
                lastUpdatedAt: rawDashboard.lastUpdatedAt,
                enabledSourceCount: rawDashboard.enabledSourceCount
            )
            dashboard = filteredDashboard(rawDashboard, setting: setting, limit: limit)
            persist()
            return
        }

        lastError = nil

        let previous = Dictionary(uniqueKeysWithValues: rawDashboard.providers.map { ($0.providerId, $0) })
        let now = IOSHotListClock.currentEpochMs()
        let enabledProviders = IOSHotlistProviders.all.filter { enabledIds.contains($0.providerId) }

        // 并发抓取所有启用的来源。此前是顺序抓取,且某个源被取消/超时就 `return` 整批中断,
        // 导致后面的源(尤其新加的 NewsNow)永远抓不到、首页不显示。改成 TaskGroup 后单个源
        // 失败/为空只影响自己,互不拖累。
        var snapshots = await withTaskGroup(of: IOSHotListProviderSnapshot.self) { group in
            for provider in enabledProviders {
                group.addTask {
                    do {
                        let items = try await provider.fetch(limit: limit)
                        return IOSHotListProviderSnapshot(
                            providerId: provider.providerId,
                            providerName: provider.displayName,
                            items: items,
                            fetchedAt: now
                        )
                    } catch {
                        let cached = previous[provider.providerId]?.items ?? []
                        return IOSHotListProviderSnapshot(
                            providerId: provider.providerId,
                            providerName: provider.displayName,
                            items: cached,
                            fetchedAt: previous[provider.providerId]?.fetchedAt ?? now,
                            stale: !cached.isEmpty,
                            // 有缓存就不显示为错误(标 stale 即可);彻底拿不到才报错。
                            error: cached.isEmpty ? error.localizedDescription : nil
                        )
                    }
                }
            }
            var collected: [IOSHotListProviderSnapshot] = []
            for await snapshot in group { collected.append(snapshot) }
            return collected
        }
        // TaskGroup 完成顺序不定,还原成启用列表的稳定顺序。
        let orderIndex = Dictionary(uniqueKeysWithValues: enabledProviders.enumerated().map { ($1.providerId, $0) })
        snapshots.sort { (orderIndex[$0.providerId] ?? 0) < (orderIndex[$1.providerId] ?? 0) }

        // 整批已被取消(用户离开页面)→ 不用部分数据覆盖既有 dashboard。
        if Task.isCancelled { return }

        // The caller supplies a translator only when translation is enabled.
        // Reuse cached translations so only new titles need a model request.
        snapshots = await Self.applyTitleTranslations(to: snapshots, previous: previous, translate: translate)

        let topics = IOSHotListAggregator.aggregate(providerSnapshots: snapshots, limit: limit)
        self.rawDashboard = IOSHotListDashboard(
            topics: topics,
            providers: snapshots,
            lastUpdatedAt: snapshots.map(\.fetchedAt).max() ?? now,
            enabledSourceCount: enabledIds.count
        )
        dashboard = filteredDashboard(self.rawDashboard, setting: setting, limit: limit)
        if dashboard.hasErrors {
            lastError = dashboard.providers.compactMap(\.error).first
        }
        persist()
    }

    /// Re-applies local source and interest filters without starting a network
    /// fetch or title translation. Used when Wi-Fi-only mode keeps the cache
    /// visible while the current network is unavailable.
    func applyCached(setting: TodayBoardSetting, limit: Int = 20) {
        dashboard = filteredDashboard(rawDashboard, setting: setting, limit: limit)
    }

    /// Fills `displayTitle` with a Chinese translation for non-Chinese titles.
    /// First reuses any cached translation from the previous dashboard (keyed by
    /// raw title), then issues one batched LLM call for the remaining untranslated
    /// titles. No translator or no pending titles → snapshots returned unchanged.
    private static func applyTitleTranslations(
        to snapshots: [IOSHotListProviderSnapshot],
        previous: [String: IOSHotListProviderSnapshot],
        translate: IOSHotListTitleTranslate?
    ) async -> [IOSHotListProviderSnapshot] {
        // 1. Cache prior translations (raw title -> Chinese displayTitle).
        var cache: [String: String] = [:]
        for snap in previous.values {
            for item in snap.items {
                let dt = (item.displayTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !dt.isEmpty, dt != item.title { cache[item.title] = dt }
            }
        }
        func applyCache(_ snaps: [IOSHotListProviderSnapshot]) -> [IOSHotListProviderSnapshot] {
            snaps.map { snap in
                var s = snap
                s.items = s.items.map { item in
                    var it = item
                    if (it.displayTitle ?? "").isEmpty, let cached = cache[it.title] { it.displayTitle = cached }
                    return it
                }
                return s
            }
        }
        var working = applyCache(snapshots)

        // 2. Translate the titles that are still untranslated and non-Chinese.
        let pending = working.flatMap(\.items)
            .filter { ($0.displayTitle ?? "").isEmpty && IOSHotListTitleTranslator.needsTranslation($0.title) }
            .map(\.title)
#if DEBUG
        NSLog("[AmberTranslate] apply pending=\(pending.count) translatorNil=\(translate == nil) cached=\(cache.count)")
#endif
        guard !pending.isEmpty, let translate else { return working }
        let translations = await translate(Array(Set(pending)))
        guard !translations.isEmpty else { return working }

        working = working.map { snap in
            var s = snap
            s.items = s.items.map { item in
                var it = item
                if (it.displayTitle ?? "").isEmpty, let zh = translations[it.title] { it.displayTitle = zh }
                return it
            }
            return s
        }
        return working
    }

    static func topic(from provider: IOSHotListProviderSnapshot, item: IOSHotlistItem) -> IOSHotTopic {
        let source = IOSHotTopicSource(
            providerId: provider.providerId,
            providerName: provider.providerName,
            rank: item.rank,
            title: item.title,
            displayTitle: item.displayTitle,
            url: item.url,
            heat: item.heat ?? item.score.map(String.init),
            fetchedAt: item.fetchedAt
        )
        return IOSHotListAggregator.aggregate(
            providerSnapshots: [
                IOSHotListProviderSnapshot(
                    providerId: provider.providerId,
                    providerName: provider.providerName,
                    items: [item],
                    fetchedAt: provider.fetchedAt,
                    stale: provider.stale,
                    error: provider.error
                )
            ],
            limit: 1
        ).first ?? IOSHotTopic(
            id: UUID().uuidString,
            title: source.presentationTitle,
            sources: [source],
            sourceCount: 1,
            bestRank: source.rank,
            latestFetchedAt: source.fetchedAt
        )
    }

    private func shouldRefresh(setting: TodayBoardSetting) -> Bool {
        guard rawDashboard.hasContent, rawDashboard.lastUpdatedAt > 0 else { return true }
        // 启用来源集合变了(新开/关了源,比如刚加的 NewsNow)→ 立刻刷新,否则缓存里没有
        // 这些源,首页就一直不显示它们,直到刷新间隔过去。
        let enabledIds = IOSHotlistProviders.effectiveEnabledProviderIds(setting: setting)
        let fetchedIds = Set(rawDashboard.providers.map(\.providerId))
        if enabledIds != fetchedIds { return true }
        let minutes = max(Int(setting.hotListRefreshIntervalMinutes), 30)
        let gapMs = Int64(minutes) * 60_000
        return IOSHotListClock.currentEpochMs() - rawDashboard.lastUpdatedAt >= gapMs
    }

    private func filteredDashboard(
        _ rawDashboard: IOSHotListDashboard,
        setting: TodayBoardSetting,
        limit: Int = 20
    ) -> IOSHotListDashboard {
        let enabledIds = IOSHotlistProviders.effectiveEnabledProviderIds(setting: setting)
        let providers = rawDashboard.providers
            .filter { enabledIds.contains($0.providerId) }
            .map { provider in
                guard !setting.hotListTranslateToChinese else { return provider }
                var projected = provider
                projected.items = projected.items.map { item in
                    var item = item
                    item.displayTitle = nil
                    return item
                }
                return projected
            }
        let visible = IOSHotListDashboard(
            topics: IOSHotListAggregator.aggregate(providerSnapshots: providers, limit: limit),
            providers: providers,
            lastUpdatedAt: rawDashboard.lastUpdatedAt,
            enabledSourceCount: enabledIds.count
        )
        return IOSHotListAggregator.applyInterestFilter(
            dashboard: visible,
            keywords: setting.hotListFocusKeywords,
            modeWireName: setting.hotListFilterMode.wireName
        )
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(rawDashboard)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[IOSHotListDashboardStore] persist failed: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder, fileManager: FileManager) -> IOSHotListDashboard? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(IOSHotListDashboard.self, from: data)
    }
}

