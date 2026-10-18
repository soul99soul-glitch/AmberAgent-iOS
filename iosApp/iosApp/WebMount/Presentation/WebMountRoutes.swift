import Foundation
import SwiftUI
import WebKit

enum WebMountSitePresentationMode: String, Hashable {
    case browse
    case watch
}

struct WebMountSiteRoute: Hashable, Identifiable {
    let siteId: String
    let name: String
    let host: String
    let sessionId: String?
    let mode: WebMountSitePresentationMode

    var id: String { "\(siteId):\(sessionId ?? "current"):\(mode.rawValue)" }

    init(
        siteId: String,
        name: String,
        host: String,
        sessionId: String? = nil
    ) {
        self.siteId = siteId
        self.name = name
        self.host = host
        self.sessionId = sessionId?.nilIfBlank
        self.mode = .browse
    }

    init(
        site: IOSWebMountSite,
        sessionId: String? = nil
    ) {
        self.siteId = site.id
        self.name = site.displayName
        self.host = site.homepageHost
        self.sessionId = sessionId?.nilIfBlank
        self.mode = .browse
    }

    @MainActor
    init?(watching record: IOSWebMountSessionRecord, registry: IOSWebMountRegistry) {
        guard record.backend == .local,
              let sessionId = record.id.nilIfBlank else {
            return nil
        }
        if let siteId = record.siteId?.nilIfBlank,
           let site = registry.site(id: siteId) {
            self.siteId = site.id
            self.name = site.displayName
            self.host = site.homepageHost
        } else {
            guard let components = URLComponents(string: record.redactedURL),
                  let host = components.host?.nilIfBlank else {
                return nil
            }
            self.siteId = "unlisted:\(sessionId)"
            self.name = record.title.nilIfBlank ?? host
            self.host = host
        }
        self.sessionId = sessionId
        self.mode = .watch
    }
}
