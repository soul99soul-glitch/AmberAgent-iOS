import Foundation
import CryptoKit

enum IOSHotListAggregator {
    static func aggregate(providerSnapshots: [IOSHotListProviderSnapshot], limit: Int = 20) -> [IOSHotTopic] {
        var clusters: [[(source: IOSHotTopicSource, key: MatchKey)]] = []
        for snapshot in providerSnapshots {
            for item in snapshot.items {
                let source = IOSHotTopicSource(
                    providerId: snapshot.providerId,
                    providerName: snapshot.providerName,
                    rank: item.rank,
                    title: item.title,
                    displayTitle: item.displayTitle,
                    url: item.url,
                    heat: item.heat ?? item.score.map(String.init),
                    fetchedAt: item.fetchedAt
                )
                // Normalize each title once; pairwise matching would otherwise rerun the regexes O(n²) times.
                let key = MatchKey(normalizedTitle(source.presentationTitle))
                if let index = clusters.firstIndex(where: { cluster in
                    cluster.contains { matches(key, $0.key) }
                }) {
                    clusters[index].append((source, key))
                } else {
                    clusters.append([(source, key)])
                }
            }
        }

        return clusters
            .map { makeTopic(sources: $0.map(\.source)) }
            .sorted {
                if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
                if $0.bestRank != $1.bestRank { return $0.bestRank < $1.bestRank }
                return $0.latestFetchedAt > $1.latestFetchedAt
            }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    static func applyInterestFilter(
        dashboard: IOSHotListDashboard,
        keywords rawKeywords: [String],
        modeWireName: String
    ) -> IOSHotListDashboard {
        let keywords = normalizeKeywords(rawKeywords)
        guard !keywords.isEmpty, modeWireName != "all" else { return dashboard }

        let topicPairs = dashboard.topics.map { topic in (topic, hotTopicMatches(topic, keywords: keywords)) }
        let providerSnapshots = dashboard.providers.map { provider in
            let indexedItems = provider.items.map { item in (item, hotItemMatches(item, keywords: keywords)) }
            let items: [IOSHotlistItem]
            if modeWireName == "focus_only" {
                items = indexedItems.filter(\.1).map(\.0)
            } else {
                items = indexedItems.sorted { left, right in
                    if left.1 != right.1 { return left.1 && !right.1 }
                    return left.0.rank < right.0.rank
                }.map(\.0)
            }
            return IOSHotListProviderSnapshot(
                providerId: provider.providerId,
                providerName: provider.providerName,
                items: items,
                fetchedAt: provider.fetchedAt,
                stale: provider.stale,
                error: modeWireName == "focus_only" && items.isEmpty && (provider.error ?? "").isEmpty ? "没有匹配关注关键词的内容。" : provider.error
            )
        }

        let topics: [IOSHotTopic]
        if modeWireName == "focus_only" {
            topics = topicPairs.filter(\.1).map(\.0)
        } else {
            topics = topicPairs.sorted { left, right in
                if left.1 != right.1 { return left.1 && !right.1 }
                if left.0.sourceCount != right.0.sourceCount { return left.0.sourceCount > right.0.sourceCount }
                if left.0.bestRank != right.0.bestRank { return left.0.bestRank < right.0.bestRank }
                return left.0.latestFetchedAt > right.0.latestFetchedAt
            }.map(\.0)
        }
        return IOSHotListDashboard(
            topics: topics,
            providers: providerSnapshots,
            lastUpdatedAt: dashboard.lastUpdatedAt,
            enabledSourceCount: dashboard.enabledSourceCount
        )
    }

    static func normalizeKeywords(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\t")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(80)
            .map { $0 }
    }

    private static func makeTopic(sources: [IOSHotTopicSource]) -> IOSHotTopic {
        let sortedSources = sources.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.fetchedAt > $1.fetchedAt
        }
        let title = sortedSources.first?.presentationTitle ?? "热点"
        let sourceCount = Set(sortedSources.map(\.providerId)).count
        let bestRank = sortedSources.map(\.rank).min() ?? Int.max
        let latest = sortedSources.map(\.fetchedAt).max() ?? 0
        return IOSHotTopic(
            id: topicId(title: title, sources: sortedSources),
            title: title,
            sources: sortedSources,
            sourceCount: sourceCount,
            bestRank: bestRank,
            latestFetchedAt: latest
        )
    }

    /// Per-title matching features, computed once per source.
    private struct MatchKey {
        let title: String
        let entities: Set<String>
        let cjk: Bool
        let length: Int
        let bigrams: Set<String>

        init(_ normalized: String) {
            title = normalized
            entities = extractEntities(normalized)
            cjk = containsCJK(normalized)
            length = normalized.count
            bigrams = IOSHotListAggregator.bigrams(normalized)
        }
    }

    private static func matches(_ left: MatchKey, _ right: MatchKey) -> Bool {
        guard !left.title.isEmpty, !right.title.isEmpty else { return false }
        if left.title == right.title { return true }

        let sharedEntities = left.entities.intersection(right.entities)
        if sharedEntities.count >= 2 { return true }
        // DEAD-CODE(marked, not removed): equal titles already returned true above.
        if sharedEntities.count == 1 && left.title == right.title { return true }
        guard left.cjk == right.cjk else { return false }
        let minLength = min(left.length, right.length)
        return minLength >= 6 && bigramJaccard(left.bigrams, right.bigrams) >= 0.4
    }

    private static func hotTopicMatches(_ topic: IOSHotTopic, keywords: [String]) -> Bool {
        let haystack = ([topic.title] + topic.sources.flatMap { [$0.presentationTitle, $0.providerName, $0.heat ?? ""] })
            .joined(separator: " ")
        return keywords.contains { containsKeyword($0, in: haystack) }
    }

    private static func hotItemMatches(_ item: IOSHotlistItem, keywords: [String]) -> Bool {
        let haystack = [item.presentationTitle, item.category ?? "", item.heat ?? "", item.url ?? ""]
            .joined(separator: " ")
        return keywords.contains { containsKeyword($0, in: haystack) }
    }

    private static func containsKeyword(_ keyword: String, in text: String) -> Bool {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let lowerText = text.lowercased()
        let lowerKey = key.lowercased()
        if lowerKey.count <= 3,
           lowerKey.range(of: #"^[a-z0-9+\-]+$"#, options: .regularExpression) != nil {
            let pattern = #"(?<![a-z0-9+\-])\#(NSRegularExpression.escapedPattern(for: lowerKey))(?![a-z0-9+\-])"#
            return lowerText.range(of: pattern, options: .regularExpression) != nil
        }
        return lowerText.contains(lowerKey)
    }

    private static func normalizedTitle(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\+]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractEntities(_ normalized: String) -> Set<String> {
        let aliases: [String: [String]] = [
            "openai": ["openai", "chatgpt", "gpt"],
            "anthropic": ["anthropic", "claude"],
            "deepseek": ["deepseek", "深度求索"],
            "gemini": ["gemini", "google ai"],
            "ai": ["ai", "人工智能", "大模型", "llm", "agent"],
            "robotics": ["机器人", "具身智能", "robot"],
            "chip": ["芯片", "半导体", "gpu", "nvidia"],
            "apple": ["apple", "苹果"],
            "microsoft": ["microsoft", "微软"],
            "google": ["google", "谷歌"],
            "tesla": ["tesla", "特斯拉"],
            "xiaomi": ["xiaomi", "小米"],
            "huawei": ["huawei", "华为"],
            "github": ["github", "git hub"]
        ]
        var found = Set<String>()
        for (key, values) in aliases where values.contains(where: { normalized.contains($0) }) {
            found.insert(key)
        }
        let words = normalized.split(separator: " ").map(String.init)
        for word in words where word.count >= 4 && word.range(of: #"^[a-z][a-z0-9+\-]+$"#, options: .regularExpression) != nil {
            found.insert(word)
        }
        return found
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private static func bigramJaccard(_ leftSet: Set<String>, _ rightSet: Set<String>) -> Double {
        guard !leftSet.isEmpty, !rightSet.isEmpty else { return 0 }
        let intersection = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func bigrams(_ value: String) -> Set<String> {
        let chars = Array(value)
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) })
    }

    private static func topicId(title: String, sources: [IOSHotTopicSource]) -> String {
        let material = ([normalizedTitle(title)] + sources.map { "\($0.providerId):\($0.rank):\(normalizedTitle($0.presentationTitle))" })
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().hotListPrefixString(24)
    }
}

