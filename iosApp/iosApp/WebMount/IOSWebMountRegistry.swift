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

private let webMountRegistryLogger = Logger(subsystem: "app.amber.ios", category: "webmount")

@MainActor
@Observable
final class IOSWebMountRegistry {
    private let defaults: UserDefaults
    private let storageKey: String
    private let seededKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var sites: [IOSWebMountSite]
    private(set) var siteMemories: [String: [IOSWebMountSiteMemoryEntry]] = [:]

    static let maximumMemoryEntriesPerHost = 40

    static func memoryHostKey(_ host: String) -> String {
        let normalized = IOSWebMountURLPolicy.normalizedHost(host) ?? host.lowercased()
        return normalized.hasPrefix("www.") ? String(normalized.dropFirst(4)) : normalized
    }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "app.amber.ios.webmount.sites.v1",
        seededKey: String = "app.amber.ios.webmount.seeded.v1"
    ) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.seededKey = seededKey
        self.siteMemories = userDefaults.data(forKey: storageKey + ".memory.v1")
            .flatMap { try? JSONDecoder().decode([String: [IOSWebMountSiteMemoryEntry]].self, from: $0) } ?? [:]

        if let data = userDefaults.data(forKey: storageKey) {
            if let decoded = try? decoder.decode([IOSWebMountSite].self, from: data) {
                self.sites = decoded
                let migrationKey = storageKey + ".weiboLoginHosts.v1"
                if !userDefaults.bool(forKey: migrationKey) {
                    if let index = sites.firstIndex(where: {
                        $0.id == "weibo" && ["m.weibo.cn", "weibo.cn", "weibo.com", "www.weibo.com"].contains($0.homepageHost)
                    }), let seed = IOSWebMountSite.seeds().first(where: { $0.id == "weibo" }) {
                        sites[index].allowedHosts = (sites[index].allowedHosts + seed.allowedHosts).uniqued()
                        if let data = try? encoder.encode(sites) { userDefaults.set(data, forKey: storageKey) }
                    }
                    userDefaults.set(true, forKey: migrationKey)
                }
            } else {
                // 已有用户数据但解码失败（如 schema 演进）：只在内存里回退到
                // seeds，绝不把 seeds 编码写回磁盘，避免把用户配置冲掉。
                webMountRegistryLogger.error("webMount sites 解码失败，使用内存 seeds 回退（不写回存储）")
                self.sites = IOSWebMountSite.seeds()
            }
        } else {
            self.sites = IOSWebMountSite.seeds()
            if let data = try? encoder.encode(self.sites) {
                userDefaults.set(data, forKey: storageKey)
                userDefaults.set(true, forKey: seededKey)
            }
        }
    }

    func site(id: String) -> IOSWebMountSite? {
        sites.first { $0.id == id }
    }

    func site(for url: URL) -> IOSWebMountSite? {
        sites.first { site in
            IOSWebMountURLPolicy.host(url.host, matchesAnyOf: site.allowedHosts)
        }
    }

    func siteMemory(host: String) -> [IOSWebMountSiteMemoryEntry] {
        siteMemories[Self.memoryHostKey(host)] ?? []
    }

    @discardableResult
    func deleteSiteMemoryEntry(host: String, id: String) -> Bool {
        let host = Self.memoryHostKey(host)
        guard var entries = siteMemories[host], entries.contains(where: { $0.id == id }) else { return false }
        entries.removeAll { $0.id == id }
        siteMemories[host] = entries
        persistSiteMemory()
        return true
    }

    func clearSiteMemory(host: String) {
        siteMemories.removeValue(forKey: Self.memoryHostKey(host))
        persistSiteMemory()
    }

    func replaceSiteMemory(host: String, entries: [IOSWebMountSiteMemoryEntry]) {
        siteMemories[Self.memoryHostKey(host)] = entries
        persistSiteMemory()
    }

    private func persistSiteMemory() {
        guard let data = try? encoder.encode(siteMemories) else { return }
        defaults.set(data, forKey: storageKey + ".memory.v1")
    }

    @discardableResult
    func add(_ site: IOSWebMountSite) -> Bool {
        guard !sites.contains(where: { $0.id == site.id }) else { return false }
        sites.insert(site, at: 0)
        persist()
        return true
    }

    @discardableResult
    func addCustomSite(
        displayName: String,
        homepageURL: String,
        needsLogin: Bool = true,
        loginCookieName: String? = nil
    ) throws -> IOSWebMountSite {
        guard let url = URL(string: homepageURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSWebMountRegistryError.invalidSite
        }
        let baseId = "user_" + IOSWebMountRegistry.slug(displayName)
        var candidate = baseId
        var suffix = 2
        while sites.contains(where: { $0.id == candidate }) {
            candidate = "\(baseId)_\(suffix)"
            suffix += 1
        }
        let site = IOSWebMountSite(
            id: candidate,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            homepageURL: url.absoluteString,
            authKind: needsLogin ? .cookie : .anonymous,
            loginCookieName: needsLogin ? loginCookieName?.nilIfBlank : nil,
            nativeAdapterId: nil,
            iconKey: nil,
            oauthProviderId: nil,
            allowedHosts: [host],
            enabled: false,
            addedAtMillis: IOSWebMountClock.nowMillis()
        )
        add(site)
        return site
    }

    @discardableResult
    func remove(id: String) -> Bool {
        guard let removedSite = site(id: id) else { return false }
        sites.removeAll { $0.id == id }
        let remainingHosts = Set(sites.flatMap(\.allowedHosts).map(Self.memoryHostKey))
        let removedHosts = Set(removedSite.allowedHosts.map(Self.memoryHostKey))
        if !removedHosts.isSubset(of: remainingHosts) {
            for host in removedHosts.subtracting(remainingHosts) {
                siteMemories.removeValue(forKey: host)
            }
            persistSiteMemory()
        }
        persist()
        return true
    }

    @discardableResult
    func restoreMissingSeeds() -> Int {
        let existing = Set(sites.map(\.id))
        let missing = IOSWebMountSite.seeds().filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        sites.append(contentsOf: missing)
        persist()
        return missing.count
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].enabled = enabled
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(sites) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.set(true, forKey: seededKey)
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let collapsed = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "site" : String(collapsed.prefix(40))
    }
}

enum IOSWebMountRegistryError: Error {
    case invalidSite
}

@MainActor
@Observable
final class IOSWebMountSettings {
    var globalEnabled: Bool {
        didSet { persist() }
    }
    var allowedHosts: Set<String> {
        didSet { persist() }
    }
    var allowedSchemes: Set<String> {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let globalKey: String
    private let hostsKey: String
    private let schemesKey: String
    private var isLoading = true

    init(
        userDefaults: UserDefaults = .standard,
        globalKey: String = "app.amber.ios.webmount.globalEnabled.v1",
        hostsKey: String = "app.amber.ios.webmount.allowedHosts.v1",
        schemesKey: String = "app.amber.ios.webmount.allowedSchemes.v1"
    ) {
        self.defaults = userDefaults
        self.globalKey = globalKey
        self.hostsKey = hostsKey
        self.schemesKey = schemesKey
        self.globalEnabled = userDefaults.object(forKey: globalKey) as? Bool ?? true
        let seedHosts = IOSWebMountSite.seeds().flatMap(\.allowedHosts)
        self.allowedHosts = Set((userDefaults.array(forKey: hostsKey) as? [String]) ?? seedHosts)
        self.allowedSchemes = Set((userDefaults.array(forKey: schemesKey) as? [String]) ?? ["http", "https"])
        self.isLoading = false
        persist()
    }

    func syncAllowedHosts(_ hosts: [String]) {
        let normalized = hosts.compactMap { IOSWebMountURLPolicy.normalizedHost($0) }
        allowedHosts = Set(normalized)
    }

    private func persist() {
        guard !isLoading else { return }
        defaults.set(globalEnabled, forKey: globalKey)
        defaults.set(Array(allowedHosts).sorted(), forKey: hostsKey)
        defaults.set(Array(allowedSchemes).sorted(), forKey: schemesKey)
    }
}

