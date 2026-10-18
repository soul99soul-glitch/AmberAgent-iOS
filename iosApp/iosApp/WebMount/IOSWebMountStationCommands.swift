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

@MainActor
final class IOSWebMountStationCommands {
    private unowned let controller: IOSWebMountController
    private var sessionStore: IOSWebMountSessionStore { controller.sessionStore }
    private var registry: IOSWebMountRegistry { controller.registry }
    private var settings: IOSWebMountSettings { controller.settings }
    private var cookieStore: IOSWebMountCookieStoreProtocol { controller.cookieStore }
    private var memoryObservedHostsBySession: [String: Set<String>] = [:]

    init(controller: IOSWebMountController) {
        self.controller = controller
    }

    func stationsResult(args: [String: Any]) async -> String {
        let authFilter = (args["auth_kind_filter"] as? String)?.lowercased().nilIfBlank
        var stations: [[String: Any]] = []
        for site in registry.sites {
            if let authFilter, site.authKind.rawValue != authFilter { continue }
            let summary = await cookieStore.summary(for: site)
            let loginStatus: String
            switch site.authKind {
            case .anonymous:
                loginStatus = "not_required"
            case .cookie:
                if summary.hasLoginCookie == false {
                    loginStatus = "logged_out"
                } else {
                    loginStatus = "unknown"
                }
            case .oauth:
                loginStatus = "unknown"
            }
            var payload: [String: Any] = [
                "id": site.id,
                "display_name": site.displayName,
                "url": IOSWebMountRedactor.redactedURL(site.homepageURL) ?? "",
                "auth_kind": site.authKind.rawValue,
                "enabled": site.enabled,
                "user_added": site.nativeAdapterId == nil,
                "login_status": loginStatus,
                "login_verified": false,
                "authentication_required": site.authKind != .anonymous,
                "authentication_evidence": site.authKind == .anonymous ? "not_required"
                    : (summary.hasLoginCookie == true ? "cookie_present_unverified" : "none"),
                "cookie_count": summary.cookieCount,
                "cookie_names": summary.cookieNames,
                "native_adapter_id": site.nativeAdapterId ?? "",
                "adapter_status": site.nativeAdapterId == nil ? "not_configured" : "unsupported_on_ios",
                "oauth_token_present": false,
                "redacted": true
            ]
            if site.authKind == .oauth {
                payload["oauth_status"] = "unsupported_on_ios"
            }
            stations.append(payload)
        }
        return IOSWebMountController.json([
            "ok": true,
            "global_enabled": settings.globalEnabled,
            "eval_supported": false,
            "count": stations.count,
            "stations": stations
        ])
    }

    private func siteMemoryHost(_ args: [String: Any]) -> String? {
        guard let host = IOSWebMountURLPolicy.normalizedHost((args["host"] as? String)?.nilIfBlank),
              registry.sites.contains(where: { IOSWebMountURLPolicy.host(host, matchesAnyOf: $0.allowedHosts) }) else { return nil }
        return IOSWebMountRegistry.memoryHostKey(host)
    }

    private func preparedSiteMemoryChanges(_ args: [String: Any]) -> (host: String, entries: [IOSWebMountSiteMemoryEntry], lines: [String])? {
        guard let host = siteMemoryHost(args),
              let rawChanges = args["changes"] as? [Any],
              !rawChanges.isEmpty, rawChanges.count <= 8 else { return nil }
        var entries = registry.siteMemory(host: host)
        var lines: [String] = []
        for raw in rawChanges {
            guard let change = IOSWebMountSiteMemoryChange.parse(raw) else { return nil }
            switch change.operation {
            case .add:
                guard entries.count < IOSWebMountRegistry.maximumMemoryEntriesPerHost,
                      let kind = change.kind, let name = change.name, let detail = change.detail else { return nil }
                let entry = IOSWebMountSiteMemoryEntry(id: UUID().uuidString, kind: kind, name: name, detail: detail,
                                     urlPattern: change.urlPattern, locatorJSON: change.locatorJSON,
                                     updatedAtMillis: IOSWebMountClock.nowMillis(), source: .agent)
                entries.append(entry)
                lines.append("新增 \(Self.siteMemoryApprovalDescription(entry))")
            case .update:
                guard let id = change.id, let index = entries.firstIndex(where: { $0.id == id }),
                      let kind = change.kind, let name = change.name, let detail = change.detail else { return nil }
                let old = entries[index]
                entries[index] = .init(id: id, kind: kind, name: name, detail: detail,
                                       urlPattern: change.urlPattern, locatorJSON: change.locatorJSON,
                                       updatedAtMillis: IOSWebMountClock.nowMillis(), source: .agent)
                lines.append("修改 \(Self.siteMemoryApprovalDescription(old)) → \(Self.siteMemoryApprovalDescription(entries[index]))")
            case .delete:
                guard let id = change.id, let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
                let old = entries.remove(at: index)
                lines.append("删除 \(Self.siteMemoryApprovalDescription(old))")
            }
        }
        return (host, entries, lines)
    }

    func siteMemoryApprovalLines(input: String) -> [String]? {
        let args = IOSWebMountController.parseObject(input)
        guard args["action"] as? String == "propose" else { return nil }
        return preparedSiteMemoryChanges(args)?.lines
    }

    func siteMemoryApprovalBaseline(input: String) -> String? {
        let args = IOSWebMountController.parseObject(input)
        // Hash content, not JSONEncoder's unspecified object key order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard args["action"] as? String == "propose", let host = siteMemoryHost(args),
              let entries = try? encoder.encode(registry.siteMemory(host: host)) else { return nil }
        let sites = registry.sites
            .filter { IOSWebMountURLPolicy.host(host, matchesAnyOf: $0.allowedHosts) }
            .map { "\($0.id):\($0.addedAtMillis)" }
            .sorted()
        var data = Data(sites.joined(separator: "\n").utf8)
        data.append(entries)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func siteMemoryApprovalDescription(_ entry: IOSWebMountSiteMemoryEntry) -> String {
        var text = "[\(entry.kind.rawValue)] \(entry.name)：\(entry.detail)"
        if let urlPattern = entry.urlPattern { text += " · URL: \(urlPattern)" }
        if let locatorJSON = entry.locatorJSON { text += " · locator: \(locatorJSON)" }
        return text
    }

    func siteMemoryResult(args: [String: Any], isUserInitiated: Bool) -> String {
        guard let host = siteMemoryHost(args) else {
            return IOSWebMountController.json(["ok": false, "error_code": "unknown_site_host", "reason": "Use an exact registered WebMount host."])
        }
        switch args["action"] as? String {
        case "read":
            let entries = registry.siteMemory(host: host)
            let offset = ((args["offset"] as? Int) ?? 0).clamped(to: 0...entries.count)
            let limit = ((args["limit"] as? Int) ?? 3).clamped(to: 1...3)
            let page = Array(entries.dropFirst(offset).prefix(limit))
            return IOSWebMountController.json([
                "ok": true, "host": host, "entries": page.map(\.dictionary),
                "total": entries.count, "next_offset": offset + page.count < entries.count ? offset + page.count : NSNull() as Any,
                "untrusted_site_memory": true, "note": "与页面实际不符时以页面为准。"
            ])
        case "propose":
            guard let prepared = preparedSiteMemoryChanges(args) else {
                return IOSWebMountController.json(["ok": false, "error_code": "invalid_site_memory_proposal", "reason": "Provide 1–8 changes, each with operation: add, update, or delete. add/update require kind, name, detail; update/delete require an existing id; pages require url_pattern; actions require a locator with role, tag, url_pattern. Host memory limit: 40 entries."])
            }
            guard isUserInitiated else {
                return IOSWebMountController.json(["ok": false, "needs_user_action": true, "reason": "确认这批站点记忆变更后将保存到本机。"])
            }
            registry.replaceSiteMemory(host: host, entries: prepared.entries)
            return IOSWebMountController.json(["ok": true, "host": host, "applied": prepared.lines, "total": prepared.entries.count])
        default:
            return IOSWebMountController.json(["ok": false, "error_code": "invalid_action", "reason": "Use read or propose."])
        }
    }

    func siteMemorySummary(host: String, sessionId: String) -> [String: Any]? {
        guard let registeredHost = siteMemoryHost(["host": host]) else { return nil }
        let entries = registry.siteMemory(host: registeredHost)
        guard !entries.isEmpty else { return nil }
        memoryObservedHostsBySession[sessionId, default: []].insert(registeredHost)
        let budget = 1_600
        var selected: [[String: Any]] = []
        var summary: [String: Any] = [
            "host": registeredHost, "entries": selected, "total": entries.count,
            "truncated": true, "summary_budget_chars": budget,
            "untrusted_site_memory": true, "note": "与页面实际不符时以页面为准。"
        ]
        for entry in entries.sorted(by: { $0.updatedAtMillis > $1.updatedAtMillis }) {
            guard selected.count < 5 else { break }
            var item = entry.dictionary
            item["detail"] = String(entry.detail.prefix(140))
            if let locator = item["locator"], IOSWebMountController.json(["locator": locator]).count > 700 {
                item.removeValue(forKey: "locator")
            }
            let candidate = selected + [item]
            summary["entries"] = candidate
            summary["truncated"] = entries.count > candidate.count
            guard IOSWebMountController.json(summary).count <= budget else { break }
            selected = candidate
        }
        summary["entries"] = selected
        summary["truncated"] = entries.count > selected.count
        return summary
    }

    func firstObservationSiteMemory(sessionId: String, currentURL: String?) -> [String: Any]? {
        guard let currentURL,
              let rawHost = URL(string: currentURL)?.host,
              let host = siteMemoryHost(["host": rawHost]),
              !memoryObservedHostsBySession[sessionId, default: []].contains(host) else { return nil }
        return siteMemorySummary(host: host, sessionId: sessionId)
    }

    func siteAddResult(args: [String: Any]) throws -> String {
        let displayName = ((args["display_name"] as? String)?.nilIfBlank
            ?? (args["name"] as? String)?.nilIfBlank
            ?? "WebMount Site")
        guard let homepageURL = (args["homepage_url"] as? String)?.nilIfBlank
            ?? (args["url"] as? String)?.nilIfBlank else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": "wm_site_add",
                "error": "wm_site_add requires homepage_url or url"
            ])
        }
        let needsLogin = args["needs_login"] as? Bool ?? true
        let cookieName = (args["login_cookie_name"] as? String)?.nilIfBlank
            ?? (args["cookie_name"] as? String)?.nilIfBlank
        let site = try registry.addCustomSite(
            displayName: displayName,
            homepageURL: homepageURL,
            needsLogin: needsLogin,
            loginCookieName: cookieName
        )
        let enabled = args["enabled"] as? Bool ?? true
        registry.setEnabled(id: site.id, enabled: enabled)
        let savedSite = registry.site(id: site.id) ?? site
        settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
        return IOSWebMountController.json([
            "ok": true,
            "tool": "wm_site_add",
            "site_id": savedSite.id,
            "display_name": savedSite.displayName,
            "url": IOSWebMountRedactor.redactedURL(savedSite.homepageURL) ?? "",
            "enabled": savedSite.enabled,
            "allowed_hosts": savedSite.allowedHosts,
            "allowlist_count": settings.allowedHosts.count,
            "redacted": true
        ])
    }

    func siteRemoveResult(args: [String: Any]) throws -> String {
        guard let siteId = (args["site_id"] as? String)?.nilIfBlank else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": "wm_site_remove",
                "error": "wm_site_remove requires site_id"
            ])
        }
        guard let site = registry.site(id: siteId) else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": "wm_site_remove",
                "error": "WebMount station was not found",
                "site_id": siteId
            ])
        }
        let removed = registry.remove(id: siteId)
        settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
        return IOSWebMountController.json([
            "ok": removed,
            "tool": "wm_site_remove",
            "site_id": siteId,
            "display_name": site.displayName,
            "removed": removed,
            "cookies_cleared": false,
            "allowlist_count": settings.allowedHosts.count,
            "redacted": true
        ])
    }

}
