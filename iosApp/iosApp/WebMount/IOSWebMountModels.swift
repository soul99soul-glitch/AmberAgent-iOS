import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum IOSWebMountAuthKind: String, Codable, CaseIterable, Identifiable {
    case anonymous
    case cookie
    case oauth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anonymous: "Anonymous"
        case .cookie: "Cookie"
        case .oauth: "OAuth"
        }
    }
}

enum IOSWebMountRuntimeStatus: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

struct IOSWebMountSite: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var displayName: String
    var homepageURL: String
    var authKind: IOSWebMountAuthKind
    var loginCookieName: String?
    var nativeAdapterId: String?
    var iconKey: String?
    var oauthProviderId: String?
    var allowedHosts: [String]
    var enabled: Bool
    var addedAtMillis: Int64

    var homepageHost: String {
        URL(string: homepageURL)?.host?.lowercased() ?? homepageURL
    }

    static func seeds(nowMillis: Int64 = IOSWebMountClock.nowMillis()) -> [IOSWebMountSite] {
        [
            IOSWebMountSite(
                id: "hackernews",
                displayName: "Hacker News",
                homepageURL: "https://news.ycombinator.com",
                authKind: .anonymous,
                loginCookieName: nil,
                nativeAdapterId: "hackernews",
                iconKey: "hackernews",
                oauthProviderId: nil,
                allowedHosts: ["news.ycombinator.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "reddit",
                displayName: "Reddit",
                homepageURL: "https://www.reddit.com",
                authKind: .anonymous,
                loginCookieName: nil,
                nativeAdapterId: "reddit",
                iconKey: "reddit",
                oauthProviderId: nil,
                allowedHosts: ["www.reddit.com", "reddit.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "github",
                displayName: "GitHub",
                homepageURL: "https://github.com/login",
                authKind: .cookie,
                loginCookieName: "user_session",
                nativeAdapterId: "github",
                iconKey: "github",
                oauthProviderId: nil,
                allowedHosts: ["github.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "bilibili",
                displayName: "Bilibili",
                homepageURL: "https://passport.bilibili.com/login",
                authKind: .cookie,
                loginCookieName: "SESSDATA",
                nativeAdapterId: "bilibili",
                iconKey: "bilibili",
                oauthProviderId: nil,
                allowedHosts: ["passport.bilibili.com", "www.bilibili.com", "bilibili.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "x_com",
                displayName: "X.com",
                homepageURL: "https://x.com/i/flow/login",
                authKind: .cookie,
                loginCookieName: "auth_token",
                nativeAdapterId: nil,
                iconKey: "x_com",
                oauthProviderId: nil,
                allowedHosts: ["x.com", "twitter.com", "www.x.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "weibo",
                displayName: "微博",
                homepageURL: "https://m.weibo.cn",
                authKind: .cookie,
                loginCookieName: "SUB",
                nativeAdapterId: nil,
                iconKey: "weibo",
                oauthProviderId: nil,
                allowedHosts: [
                    "m.weibo.cn", "weibo.cn", "weibo.com", "www.weibo.com",
                    "passport.weibo.cn", "visitor.passport.weibo.cn", "passport.weibo.com",
                    "security.weibo.com", "login.sina.com.cn", "passport.sinaimg.cn"
                ],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "juejin",
                displayName: "掘金",
                homepageURL: "https://juejin.cn/login",
                authKind: .cookie,
                loginCookieName: "sessionid",
                nativeAdapterId: "juejin",
                iconKey: "juejin",
                oauthProviderId: nil,
                allowedHosts: ["juejin.cn", "www.juejin.cn"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "zhihu",
                displayName: "知乎",
                homepageURL: "https://www.zhihu.com/signin",
                authKind: .cookie,
                loginCookieName: "z_c0",
                nativeAdapterId: "zhihu",
                iconKey: "zhihu",
                oauthProviderId: nil,
                allowedHosts: ["www.zhihu.com", "zhihu.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "feishu_docs",
                displayName: "飞书云文档",
                homepageURL: "https://www.feishu.cn/wiki",
                authKind: .oauth,
                loginCookieName: nil,
                nativeAdapterId: "feishu_docs",
                iconKey: "feishu_docs",
                oauthProviderId: "feishu",
                allowedHosts: ["www.feishu.cn", "feishu.cn"],
                enabled: false,
                addedAtMillis: nowMillis
            )
        ]
    }
}

enum IOSWebMountSiteMemoryKind: String, Codable, CaseIterable {
    case pages, actions, pitfalls, cannot_do
}

enum IOSWebMountSiteMemorySource: String, Codable {
    case agent, user
}

struct IOSWebMountSiteMemoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let kind: IOSWebMountSiteMemoryKind
    let name: String
    let detail: String
    let urlPattern: String?
    let locatorJSON: String?
    let updatedAtMillis: Int64
    let source: IOSWebMountSiteMemorySource

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "id": id, "kind": kind.rawValue, "name": name, "detail": detail,
            "updated_at": updatedAtMillis, "source": source.rawValue
        ]
        if let urlPattern { value["url_pattern"] = urlPattern }
        if let locatorJSON, let data = locatorJSON.data(using: .utf8),
           let locator = try? JSONSerialization.jsonObject(with: data) {
            value["locator"] = locator
        }
        return value
    }
}

struct IOSWebMountSiteMemoryChange {
    enum Operation: String { case add, update, delete }
    let operation: Operation
    let id: String?
    let kind: IOSWebMountSiteMemoryKind?
    let name: String?
    let detail: String?
    let urlPattern: String?
    let locatorJSON: String?

    static func parse(_ raw: Any) -> IOSWebMountSiteMemoryChange? {
        guard let object = raw as? [String: Any],
              let operation = (object["operation"] as? String).flatMap(Operation.init(rawValue:)) else { return nil }
        let id = (object["id"] as? String)?.nilIfBlank
        if operation == .delete {
            guard id != nil else { return nil }
            return .init(operation: operation, id: id, kind: nil, name: nil, detail: nil, urlPattern: nil, locatorJSON: nil)
        }
        guard let kind = (object["kind"] as? String).flatMap(IOSWebMountSiteMemoryKind.init(rawValue:)),
              let rawName = (object["name"] as? String)?.nilIfBlank,
              let rawDetail = (object["detail"] as? String)?.nilIfBlank,
              (operation == .add || id != nil) else { return nil }
        let name = sanitize(rawName, limit: 80)
        let detail = sanitize(rawDetail, limit: 500)
        let urlPattern = (object["url_pattern"] as? String)?.nilIfBlank.map {
            String(sanitize($0, limit: 300).prefix { $0 != "?" })
        }
        if kind == .pages && urlPattern == nil { return nil }
        let locatorJSON: String?
        if kind == .actions {
            guard let locator = object["locator"] as? [String: Any],
                  (locator["role"] as? String)?.nilIfBlank != nil,
                  (locator["tag"] as? String)?.nilIfBlank != nil,
                  (locator["url_pattern"] as? String)?.nilIfBlank != nil,
                  JSONSerialization.isValidJSONObject(locator),
                  let data = try? JSONSerialization.data(withJSONObject: sanitizeJSON(locator), options: [.sortedKeys]),
                  data.count <= 2_500,
                  let encoded = String(data: data, encoding: .utf8) else { return nil }
            locatorJSON = encoded
        } else {
            locatorJSON = nil
        }
        return .init(operation: operation, id: id, kind: kind, name: name, detail: detail,
                     urlPattern: urlPattern, locatorJSON: locatorJSON)
    }

    private static func sanitizeJSON(_ value: Any) -> Any {
        if let text = value as? String { return sanitize(text, limit: 300) }
        if let object = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (key, item) in object { clean[sanitize(key, limit: 80)] = sanitizeJSON(item) }
            return clean
        }
        if let array = value as? [Any] { return array.map(sanitizeJSON) }
        return value
    }

    static func sanitize(_ raw: String, limit: Int) -> String {
        var value = IOSWebMountRedactor.redactedText(raw)
        for (pattern, replacement) in [
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[邮箱已隐去]"),
            (#"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d(?:[- ]?\d){8}(?!\d)"#, "[手机号已隐去]"),
            (#"(?i)(?:订单号|订单编号|order[ _-]?(?:id|number|no))[\s:：#=-]*[A-Z0-9-]{6,}"#, "[订单号已隐去]"),
            (#"(?i)(/orders?/)[A-Z0-9_-]{6,}"#, "$1[订单号已隐去]"),
            (#"(?i)(/[A-Z0-9._~/%-]+)\?[A-Z0-9._~-]+=[^\s#]+"#, "$1"),
        ] {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

enum IOSWebMountClock {
    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
