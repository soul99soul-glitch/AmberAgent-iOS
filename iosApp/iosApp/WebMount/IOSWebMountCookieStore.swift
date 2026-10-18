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

struct IOSWebMountCookieSummary: Codable, Equatable {
    let siteId: String
    let cookieCount: Int
    let cookieNames: [String]
    let domains: [String]
    let hasLoginCookie: Bool?
    let redacted: Bool
}

struct IOSWebMountCookieClearResult: Codable, Equatable {
    let siteId: String
    let deletedCookieCount: Int
    let clearedWebsiteDataRecords: Int
}

@MainActor
protocol IOSWebMountCookieStoreProtocol: AnyObject {
    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary
    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult
}

@MainActor
final class IOSWebMountCookieStore: IOSWebMountCookieStoreProtocol {
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? WKWebsiteDataStore.default()
    }

    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        let allCookies = await allCookies()
        let cookies = allCookies.filter { cookie in
            IOSWebMountURLPolicy.host(cookie.domain, matchesAnyOf: site.allowedHosts)
        }
        let names = cookies.map(\.name).uniqued().sorted()
        let domains = cookies.map(\.domain).uniqued().sorted()
        let hasLoginCookie = site.loginCookieName.map { names.contains($0) }
        return IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: cookies.count,
            cookieNames: names,
            domains: domains,
            hasLoginCookie: hasLoginCookie,
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        let allCookies = await allCookies()
        let cookies = allCookies.filter { cookie in
            IOSWebMountURLPolicy.host(cookie.domain, matchesAnyOf: site.allowedHosts)
        }
        for cookie in cookies {
            await delete(cookie)
        }
        let dataRecords = await dataRecords()
        let records = dataRecords.filter { record in
            IOSWebMountURLPolicy.host(record.displayName, matchesAnyOf: site.allowedHosts)
        }
        if !records.isEmpty {
            await remove(records: records)
        }
        return IOSWebMountCookieClearResult(
            siteId: site.id,
            deletedCookieCount: cookies.count,
            clearedWebsiteDataRecords: records.count
        )
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private func dataRecords() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                continuation.resume(returning: records)
            }
        }
    }

    private func remove(records: [WKWebsiteDataRecord]) async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records
            ) {
                continuation.resume()
            }
        }
    }
}

