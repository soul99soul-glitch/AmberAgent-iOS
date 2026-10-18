import Foundation
import SwiftUI
import WebKit

enum IOSDeepReadWebMountAdapter {
    @MainActor
    static func currentPageSource(
        controller: IOSWebMountController = .shared,
        maxChars: Int = 20_000
    ) async -> Result<IOSDeepReadSource, IOSDeepReadSourceNormalizationError> {
        let snapshot = controller.runtime.snapshot
        guard snapshot.status == .ready else {
            let reason = snapshot.error.map(IOSWebMountRedactor.redactedText)?.nilIfBlank
                ?? "站点当前没有已加载完成的页面；请先打开站点并停留在要深读的页面。"
            return .failure(.unsupported(reason))
        }
        do {
            let extracted = try await controller.runtime.extract(mode: "readable", maxChars: maxChars, maxLinks: 20)
            let rawResult = extracted["text"] as? String
                ?? (extracted["result"] as? [String: Any])?["text"] as? String
                ?? ""
            let result = IOSWebMountRedactor.redactedText(rawResult)
            let rawTitle = extracted["title"] as? String
                ?? (extracted["result"] as? [String: Any])?["title"] as? String
                ?? snapshot.title
                ?? "站点页面"
            let title = IOSWebMountRedactor.redactedText(rawTitle)
            let rawURL = extracted["url"] as? String
                ?? (extracted["result"] as? [String: Any])?["url"] as? String
                ?? snapshot.currentURL
            let url = IOSWebMountRedactor.redactedURL(rawURL)
            let source = try IOSDeepReadSourceNormalizer.webMountSource(title: title, url: url, text: result)
            return .success(source)
        } catch let error as IOSDeepReadSourceNormalizationError {
            return .failure(error)
        } catch {
            return .failure(.unsupported("站点页面正文读取失败：\(IOSDeepReadUserFacingText.fromError(error))"))
        }
    }
}

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

    var boardSignal: IOSRawBoardSignal {
        IOSRawBoardSignal(
            sourceType: IOSBoardSignalSourceType.webmount,
            sourceRef: "webmount:\(siteId):\(sourceURL)",
            title: title.nilIfBlank ?? siteName,
            content: String(text.prefix(4_000)),
            signalTime: createdAtMillis,
            metadataJson: IOSWebMountController.json([
                "site_id": siteId,
                "site_name": siteName,
                "source_url": sourceURL,
                "link_count": linkCount,
                "redacted": true
            ])
        )
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
    private var pendingDeepReadHandoff: IOSWebMountContentHandoff?

    private init() {}

    func prepareChat(_ handoff: IOSWebMountContentHandoff) {
        pendingChatHandoff = handoff
    }

    func consumeChatHandoff() -> IOSWebMountContentHandoff? {
        defer { pendingChatHandoff = nil }
        return pendingChatHandoff
    }

    func prepareDeepRead(_ handoff: IOSWebMountContentHandoff) {
        pendingDeepReadHandoff = handoff
    }

    func consumeDeepReadHandoff() -> IOSWebMountContentHandoff? {
        defer { pendingDeepReadHandoff = nil }
        return pendingDeepReadHandoff
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
