import Foundation
import SwiftUI
import WebKit

struct IOSWebMountContentHandoff: Equatable, Identifiable {
    let id: String
    let siteId: String
    let siteName: String
    let title: String
    let sourceURL: String
    let text: String
    let linkCount: Int
    let createdAtMillis: Int64

    var chatPrompt: String {
        """
        请基于以下站点网页内容继续帮我处理。

        来源：\(siteName)
        标题：\(title.nilIfBlank ?? siteName)
        URL：\(sourceURL)
        链接数：\(linkCount)

        正文：
        \(String(text.prefix(12_000)))
        """
    }

    static func from(
        site: IOSWebMountSite,
        snapshot: IOSWebMountRuntimeSnapshot,
        extraction: [String: Any]
    ) -> IOSWebMountContentHandoff? {
        let rawText = (extraction["text"] as? String)?.nilIfBlank
        guard let rawText else { return nil }
        let redactedText = IOSWebMountRedactor.redactedText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redactedText.isEmpty else { return nil }
        let sourceURL = IOSWebMountRedactor.redactedURL(extraction["url"] as? String)
            ?? snapshot.currentURL
            ?? IOSWebMountRedactor.redactedURL(site.homepageURL)
            ?? site.homepageHost
        let links = extraction["links"] as? [[String: Any]] ?? []
        return IOSWebMountContentHandoff(
            id: UUID().uuidString,
            siteId: site.id,
            siteName: site.displayName,
            title: IOSWebMountRedactor.redactedText((extraction["title"] as? String)?.nilIfBlank ?? snapshot.title ?? site.displayName),
            sourceURL: sourceURL,
            text: redactedText,
            linkCount: links.count,
            createdAtMillis: IOSWebMountClock.nowMillis()
        )
    }
}

@MainActor
final class IOSWebMountContentHandoffStore {
    static let shared = IOSWebMountContentHandoffStore()

    private var pendingChatHandoff: IOSWebMountContentHandoff?

    private init() {}

    func prepareChat(_ handoff: IOSWebMountContentHandoff) {
        pendingChatHandoff = handoff
    }

    func consumeChatHandoff() -> IOSWebMountContentHandoff? {
        defer { pendingChatHandoff = nil }
        return pendingChatHandoff
    }
}

@MainActor
@Observable
final class IOSWebMountActivityStore {
    static let shared = IOSWebMountActivityStore()

    var recentExtractionTitle = "—"
    var recentExtractionDetail = "暂无"
    var recentExtractionAtMillis: Int64 = 0

    private init() {}

    func recordExtraction(siteName: String, title: String?, characterCount: Int, linkCount: Int) {
        recentExtractionTitle = title?.nilIfBlank ?? siteName
        recentExtractionDetail = "\(siteName) · \(characterCount) 字符 · \(linkCount) 链接"
        recentExtractionAtMillis = IOSWebMountClock.nowMillis()
    }
}
