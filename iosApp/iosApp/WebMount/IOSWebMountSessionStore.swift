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

enum IOSWebMountControlOwner: String, Codable, Equatable {
    case none
    case agent
    case user
}

struct IOSWebMountSessionRecord: Equatable, Identifiable {
    let id: String
    let siteId: String?
    let siteName: String?
    let title: String
    let redactedURL: String
    let status: String
    let canGoBack: Bool
    let canGoForward: Bool
    let lastActivityMillis: Int64
    let isCurrent: Bool
    let ownerConversationId: String?
    let ownerRunId: String?
    let controlOwner: IOSWebMountControlOwner
    let leaseExpiresAtMillis: Int64?
    let persistentOptIn: Bool
    let needsReopen: Bool
    var cardHidden: Bool = false
    let backend: IOSWebMountBackendKind
    let mcpServerName: String?

    func dictionary() -> [String: Any] {
        [
            "session_id": id,
            "site_id": siteId ?? "",
            "site_name": siteName ?? "",
            "title": title,
            "url": redactedURL,
            "status": status,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "last_activity_ms": lastActivityMillis,
            "is_current": isCurrent,
            "control_owner": controlOwner.rawValue,
            "lease_expires_at_ms": leaseExpiresAtMillis ?? 0,
            "persistent": persistentOptIn,
            "needs_reopen": needsReopen,
            "backend": backend.rawValue,
            "mcp_server_name": mcpServerName ?? ""
        ]
    }
}

enum IOSWebMountSessionError: Error, LocalizedError {
    case sessionNotFound(String)
    case cannotCloseOnlySession
    case sessionLimitReached(Int)
    case sessionBindingRequired
    case sessionBindingMismatch(String)
    case siteBindingRequired
    case siteDisabled(String)
    case userControlActive(String)
    case agentLeaseUnavailable(String)

    var errorCode: String {
        switch self {
        case .sessionNotFound: "session_not_found"
        case .cannotCloseOnlySession: "cannot_close_only_session"
        case .sessionLimitReached: "session_limit_reached"
        case .sessionBindingRequired: "session_binding_required"
        case .sessionBindingMismatch: "session_binding_mismatch"
        case .siteBindingRequired: "site_binding_required"
        case .siteDisabled: "site_disabled"
        case .userControlActive: "user_control_active"
        case .agentLeaseUnavailable: "control_lease_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            "WebMount session was not found: \(sessionId)"
        case .cannotCloseOnlySession:
            "Cannot close the only WebMount session."
        case .sessionLimitReached(let limit):
            "WebMount already has \(limit) active or persistent sessions. Close one before creating another."
        case .sessionBindingRequired:
            "Agent WebMount calls require an explicit session_id and host run binding."
        case .sessionBindingMismatch(let sessionId):
            "WebMount session belongs to another conversation: \(sessionId)"
        case .siteBindingRequired:
            "WebMount session is no longer bound to a registered station."
        case .siteDisabled(let siteId):
            "WebMount station is disabled: \(siteId)"
        case .userControlActive(let sessionId):
            "The user currently controls WebMount session \(sessionId). Wait for hand-back before continuing."
        case .agentLeaseUnavailable(let sessionId):
            "WebMount agent control is unavailable for session \(sessionId)."
        }
    }
}

private struct IOSWebMountSessionMetadata: Codable, Equatable {
    var siteId: String?
    var siteName: String?
    var lastTitle: String?
    var redactedURL: String?
    var lastActivityMillis: Int64
    var ownerConversationId: String?
    var ownerRunId: String?
    var controlOwner: IOSWebMountControlOwner
    var leaseExpiresAtMillis: Int64?
    var persistentOptIn: Bool
    var needsReopen: Bool
    var cardHidden: Bool
    /// Optional for backward-compatible decoding of the existing v1 payload.
    var backendRawValue: String?
    var mcpServerName: String?

    private enum CodingKeys: String, CodingKey {
        case siteId
        case siteName
        case lastTitle
        case redactedURL
        case lastActivityMillis
        case ownerConversationId
        case ownerRunId
        case controlOwner
        case leaseExpiresAtMillis
        case persistentOptIn
        case needsReopen
        case cardHidden
        case backendRawValue
        case mcpServerName
    }

    init(
        siteId: String?,
        siteName: String?,
        lastTitle: String?,
        redactedURL: String?,
        lastActivityMillis: Int64,
        ownerConversationId: String?,
        ownerRunId: String?,
        controlOwner: IOSWebMountControlOwner,
        leaseExpiresAtMillis: Int64?,
        persistentOptIn: Bool,
        needsReopen: Bool,
        cardHidden: Bool = false,
        backendRawValue: String?,
        mcpServerName: String?
    ) {
        self.siteId = siteId
        self.siteName = siteName
        self.lastTitle = lastTitle
        self.redactedURL = redactedURL
        self.lastActivityMillis = lastActivityMillis
        self.ownerConversationId = ownerConversationId
        self.ownerRunId = ownerRunId
        self.controlOwner = controlOwner
        self.leaseExpiresAtMillis = leaseExpiresAtMillis
        self.persistentOptIn = persistentOptIn
        self.needsReopen = needsReopen
        self.cardHidden = cardHidden
        self.backendRawValue = backendRawValue
        self.mcpServerName = mcpServerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteId = try container.decodeIfPresent(String.self, forKey: .siteId)
        siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
        lastTitle = try container.decodeIfPresent(String.self, forKey: .lastTitle)
        redactedURL = try container.decodeIfPresent(String.self, forKey: .redactedURL)
        lastActivityMillis = try container.decodeIfPresent(Int64.self, forKey: .lastActivityMillis) ?? 0
        ownerConversationId = try container.decodeIfPresent(String.self, forKey: .ownerConversationId)
        ownerRunId = try container.decodeIfPresent(String.self, forKey: .ownerRunId)
        controlOwner = try container.decodeIfPresent(IOSWebMountControlOwner.self, forKey: .controlOwner) ?? .none
        leaseExpiresAtMillis = try container.decodeIfPresent(Int64.self, forKey: .leaseExpiresAtMillis)
        // Entries in this store were explicitly persisted by the old v1 path;
        // restore still marks them needs_reopen before exposing a runtime.
        persistentOptIn = try container.decodeIfPresent(Bool.self, forKey: .persistentOptIn) ?? true
        needsReopen = try container.decodeIfPresent(Bool.self, forKey: .needsReopen) ?? true
        cardHidden = try container.decodeIfPresent(Bool.self, forKey: .cardHidden) ?? false
        backendRawValue = try container.decodeIfPresent(String.self, forKey: .backendRawValue)
        mcpServerName = try container.decodeIfPresent(String.self, forKey: .mcpServerName)
    }

    var backend: IOSWebMountBackendKind {
        IOSWebMountBackendKind(rawValue: backendRawValue ?? "") ?? .local
    }
}

private struct IOSWebMountPersistedSession: Codable, Equatable {
    let id: String
    let metadata: IOSWebMountSessionMetadata
}

@MainActor
@Observable
final class IOSWebMountSessionStore {
    static let ephemeralTTLMillis: Int64 = 15 * 60 * 1_000
    static let agentLeaseMillis: Int64 = 2 * 60 * 1_000

    let maxSessions: Int

    private(set) var currentSessionId: String
    private(set) var recordsRevision: UInt64 = 0
    @ObservationIgnored private var runtimes: [String: IOSWebMountRuntimeServicing] = [:]
    @ObservationIgnored private var metadata: [String: IOSWebMountSessionMetadata] = [:]
    @ObservationIgnored private let runtimeFactory: () -> IOSWebMountRuntimeServicing
    @ObservationIgnored private let restoredRuntimeFactory: ((String) -> IOSWebMountRuntimeServicing)?
    @ObservationIgnored private let remoteRuntimeFactory: ((String, IOSWebMountBackendKind) -> IOSWebMountRuntimeServicing)?
    @ObservationIgnored private let userDefaults: UserDefaults?
    @ObservationIgnored private let nowMillis: () -> Int64
    @ObservationIgnored private let onSessionRemoved: ((String) -> Void)?

    private static let persistedSessionsKey = "app.amber.ios.webmount.persistent-sessions.v1"
    private static let persistedCurrentSessionKey = "app.amber.ios.webmount.persistent-current-session.v1"

    init(
        initialRuntime: IOSWebMountRuntimeServicing? = nil,
        maxSessions: Int = 3,
        runtimeFactory: @escaping () -> IOSWebMountRuntimeServicing = { IOSWebMountWKRuntime() },
        restoredRuntimeFactory: ((String) -> IOSWebMountRuntimeServicing)? = nil,
        remoteRuntimeFactory: ((String, IOSWebMountBackendKind) -> IOSWebMountRuntimeServicing)? = nil,
        userDefaults: UserDefaults? = nil,
        nowMillis: @escaping () -> Int64 = { IOSWebMountClock.nowMillis() },
        onSessionRemoved: ((String) -> Void)? = nil
    ) {
        self.maxSessions = max(1, maxSessions)
        self.runtimeFactory = runtimeFactory
        self.restoredRuntimeFactory = restoredRuntimeFactory
        self.remoteRuntimeFactory = remoteRuntimeFactory
        self.userDefaults = userDefaults
        self.nowMillis = nowMillis
        self.onSessionRemoved = onSessionRemoved
        self.currentSessionId = ""

        let persisted = Self.loadPersistedSessions(from: userDefaults)
            .filter { $0.metadata.persistentOptIn }
        // Reserve one slot for a local session. A persisted remote session must
        // never crowd the only local WKWebView out of the restored set.
        var restored: [IOSWebMountPersistedSession] = []
        if let local = persisted.first(where: { $0.metadata.backend == .local }) {
            restored.append(local)
        }
        let remainingLimit = max(0, self.maxSessions - max(1, restored.count))
        restored.append(contentsOf: persisted.filter { item in
            !restored.contains(where: { $0.id == item.id })
        }.prefix(remainingLimit))
        for item in restored {
            let backend = item.metadata.backend
            let restoredRuntime: IOSWebMountRuntimeServicing?
            if backend == .local {
                restoredRuntime = restoredRuntimeFactory?(item.id)
            } else {
                restoredRuntime = remoteRuntimeFactory?(item.id, backend)
            }
            guard let restoredRuntime else { continue }
            runtimes[item.id] = restoredRuntime
            var restoredMetadata = item.metadata
            restoredMetadata.ownerRunId = nil
            restoredMetadata.controlOwner = .none
            restoredMetadata.leaseExpiresAtMillis = nil
            restoredMetadata.needsReopen = true
            metadata[item.id] = restoredMetadata
        }

        if !metadata.values.contains(where: { $0.backend == .local }) {
            let runtime = initialRuntime ?? runtimeFactory()
            let sessionId = runtime.snapshot.sessionId
            runtimes[sessionId] = runtime
            metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        }

        let persistedCurrent = userDefaults?.string(forKey: Self.persistedCurrentSessionKey)
        self.currentSessionId = persistedCurrent.flatMap { sessionId in
            guard runtimes[sessionId] != nil, metadata[sessionId]?.backend == .local else { return nil }
            return sessionId
        } ?? metadata.keys.sorted().first(where: { metadata[$0]?.backend == .local }) ?? ""
        ensureCurrentSessionIsLocal()
    }

    var currentRuntime: IOSWebMountRuntimeServicing {
        ensureCurrentSessionIsLocal()
        if let runtime = runtimes[currentSessionId] {
            return runtime
        }
        let runtime = runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        currentSessionId = sessionId
        metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        return runtime
    }

    var records: [IOSWebMountSessionRecord] {
        _ = recordsRevision
        expireInactiveSessions()
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        // A reclaimed Agent session keeps only its bound metadata so the
        // conversation and management page can offer an honest reopen entry.
        // The runtime itself is absent until an explicit reopen action.
        let sessionIds = Set(runtimes.keys).union(
            metadata.compactMap { sessionId, item in
                guard runtimes[sessionId] == nil,
                      item.needsReopen,
                      item.ownerConversationId?.nilIfBlank != nil else { return nil }
                return sessionId
            }
        )
        return sessionIds
            .sorted { lhs, rhs in
                if lhs == currentSessionId { return true }
                if rhs == currentSessionId { return false }
                return (metadata[lhs]?.lastActivityMillis ?? 0) > (metadata[rhs]?.lastActivityMillis ?? 0)
            }
            .compactMap { sessionId -> IOSWebMountSessionRecord? in
                guard let metadata = metadata[sessionId] else { return nil }
                let snapshot = runtimes[sessionId]?.snapshot
                guard snapshot != nil || metadata.needsReopen else { return nil }
                return IOSWebMountSessionRecord(
                    id: sessionId,
                    siteId: metadata.siteId,
                    siteName: metadata.siteName,
                    title: IOSWebMountRedactor.redactedText(snapshot?.title?.nilIfBlank ?? metadata.lastTitle?.nilIfBlank ?? "未命名页面"),
                    redactedURL: snapshot?.currentURL ?? snapshot?.requestedURL ?? metadata.redactedURL ?? "",
                    status: metadata.needsReopen ? "needs_reopen" : snapshot?.status.rawValue ?? "idle",
                    canGoBack: snapshot?.canGoBack ?? false,
                    canGoForward: snapshot?.canGoForward ?? false,
                    lastActivityMillis: metadata.lastActivityMillis,
                    isCurrent: sessionId == currentSessionId,
                    ownerConversationId: metadata.ownerConversationId,
                    ownerRunId: metadata.ownerRunId,
                    controlOwner: effectiveControlOwner(metadata, now: nowMillis()),
                    leaseExpiresAtMillis: metadata.leaseExpiresAtMillis,
                    persistentOptIn: metadata.persistentOptIn,
                    needsReopen: metadata.needsReopen,
                    cardHidden: metadata.cardHidden,
                    backend: metadata.backend,
                    mcpServerName: metadata.mcpServerName
                )
            }
    }

    var activeRecords: [IOSWebMountSessionRecord] {
        records.filter { runtimes[$0.id] != nil }
    }

    func runtime(sessionId requestedSessionId: String?, makeCurrent: Bool = true) throws -> IOSWebMountRuntimeServicing {
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        let sessionId = requestedSessionId?.nilIfBlank ?? currentSessionId
        guard let runtime = runtimes[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        touch(sessionId: sessionId, makeCurrent: makeCurrent)
        return runtime
    }

    func runtimeIfPresent(sessionId requestedSessionId: String?) -> IOSWebMountRuntimeServicing? {
        expireInactiveSessions()
        ensureCurrentSessionIsLocal()
        let sessionId = requestedSessionId?.nilIfBlank ?? currentSessionId
        return runtimes[sessionId]
    }

    /// Rebuild a reclaimed session only for an explicit reopen action. The
    /// restored runtime starts from an idle page; metadata never restores old
    /// page state or actions.
    @discardableResult
    func reopen(sessionId: String) -> IOSWebMountSessionRecord? {
        guard let item = metadata[sessionId], item.needsReopen else {
            return record(sessionId: sessionId)
        }
        if runtimes[sessionId] != nil {
            return record(sessionId: sessionId)
        }
        let runtime: IOSWebMountRuntimeServicing?
        if item.backend == .local {
            runtime = restoredRuntimeFactory?(sessionId)
        } else {
            runtime = remoteRuntimeFactory?(sessionId, item.backend)
        }
        guard let runtime, runtime.snapshot.sessionId == sessionId else { return nil }
        if runtimes.count >= maxSessions,
           !evictLeastRecentlyUsedSession(allowCurrent: false) {
            return nil
        }
        runtimes[sessionId] = runtime
        if var reopenedMetadata = metadata[sessionId] {
            reopenedMetadata.lastActivityMillis = nowMillis()
            metadata[sessionId] = reopenedMetadata
        }
        persistSessions()
        return record(sessionId: sessionId)
    }

    @discardableResult
    func newSession(
        site: IOSWebMountSite? = nil,
        persistent: Bool = false,
        makeCurrent: Bool = true,
        backend: IOSWebMountBackendKind = .local,
        mcpServerName: String? = nil,
        runtime suppliedRuntime: IOSWebMountRuntimeServicing? = nil
    ) throws -> IOSWebMountSessionRecord {
        expireInactiveSessions()
        if runtimes.count >= maxSessions {
            guard evictLeastRecentlyUsedSession(allowCurrent: makeCurrent) else {
                throw IOSWebMountSessionError.sessionLimitReached(maxSessions)
            }
        }
        let runtime = suppliedRuntime ?? runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        if makeCurrent && backend == .local {
            currentSessionId = sessionId
        }
        var newMetadata = Self.freshMetadata(nowMillis: nowMillis())
        newMetadata.persistentOptIn = persistent
        newMetadata.backendRawValue = backend.rawValue
        newMetadata.mcpServerName = mcpServerName?.nilIfBlank
        newMetadata.needsReopen = backend != .local
        metadata[sessionId] = newMetadata
        tag(sessionId: sessionId, site: site)
        ensureCurrentSessionIsLocal()
        persistSessions()
        return records.first { $0.id == sessionId } ?? fallbackRecord(for: runtime, sessionId: sessionId)
    }

    @discardableResult
    func close(sessionId: String) throws -> IOSWebMountSessionRecord? {
        ensureCurrentSessionIsLocal()
        guard runtimes[sessionId] != nil || metadata[sessionId] != nil else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        guard runtimes[sessionId] != nil else {
            metadata.removeValue(forKey: sessionId)
            persistSessions()
            return record(sessionId: currentSessionId)
        }
        if runtimes.count == 1 {
            removeSession(sessionId, preserveReopenEntry: false)
            expireInactiveSessions()
            persistSessions()
            return record(sessionId: currentSessionId)
        }
        removeSession(sessionId, preserveReopenEntry: false)
        if !metadata.values.contains(where: { $0.backend == .local }) {
            _ = try newSession(makeCurrent: true)
        }
        if currentSessionId == sessionId {
            currentSessionId = runtimes.keys.filter { metadata[$0]?.backend == .local }.max {
                (metadata[$0]?.lastActivityMillis ?? 0) < (metadata[$1]?.lastActivityMillis ?? 0)
            } ?? runtimes.keys.first ?? currentSessionId
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return records.first { $0.id == currentSessionId }
    }

    func tag(sessionId: String, site: IOSWebMountSite?) {
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else { return }
        item.siteId = site?.id
        item.siteName = site?.displayName
        metadata[sessionId] = item
        persistSessions()
    }

    func touch(sessionId: String, makeCurrent: Bool = true) {
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        guard let runtime = runtimes[sessionId], var item = metadata[sessionId] else { return }
        if makeCurrent, item.backend == .local {
            currentSessionId = sessionId
        }
        let snapshot = runtime.snapshot
        item.lastActivityMillis = nowMillis()
        item.lastTitle = IOSWebMountRedactor.redactedText(snapshot.title ?? "").nilIfBlank ?? item.lastTitle
        if item.backend == .local {
            item.redactedURL = snapshot.currentURL ?? snapshot.requestedURL ?? item.redactedURL
        }
        metadata[sessionId] = item
        ensureCurrentSessionIsLocal()
        persistSessions()
    }

    @discardableResult
    func acquireAgentControl(
        sessionId: String,
        runId: String,
        conversationId: String
    ) throws -> IOSWebMountSessionRecord {
        try bindAgentSession(
            sessionId: sessionId,
            runId: runId,
            conversationId: conversationId,
            requiresControl: true
        )
    }

    @discardableResult
    func bindAgentSession(
        sessionId: String,
        runId: String,
        conversationId: String,
        requiresControl: Bool
    ) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        guard runId.nilIfBlank != nil, conversationId.nilIfBlank != nil else {
            throw IOSWebMountSessionError.sessionBindingRequired
        }
        if let ownerConversationId = item.ownerConversationId,
           ownerConversationId != conversationId {
            throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
        }
        if let ownerRunId = item.ownerRunId,
           ownerRunId != runId {
            throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
        }
        let now = nowMillis()
        let effectiveOwner = effectiveControlOwner(item, now: now)
        if requiresControl, effectiveOwner == .user {
            throw IOSWebMountSessionError.userControlActive(sessionId)
        }
        item.ownerConversationId = conversationId.nilIfBlank ?? item.ownerConversationId
        item.ownerRunId = runId
        if requiresControl || effectiveOwner == .agent {
            item.controlOwner = .agent
            (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(false)
            item.leaseExpiresAtMillis = now + Self.agentLeaseMillis
        }
        item.lastActivityMillis = now
        metadata[sessionId] = item
        persistSessions()
        return record(sessionId: sessionId)!
    }

    @discardableResult
    func acquireUserControl(sessionId: String) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        let now = nowMillis()
        item.controlOwner = .user
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(true)
        item.leaseExpiresAtMillis = nil
        item.lastActivityMillis = now
        metadata[sessionId] = item
        if item.backend == .local {
            currentSessionId = sessionId
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return record(sessionId: sessionId)!
    }

    @discardableResult
    func handBackToAgent(sessionId: String) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(false)
        guard item.ownerRunId?.nilIfBlank != nil else {
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            metadata[sessionId] = item
            persistSessions()
            return record(sessionId: sessionId)!
        }
        item.controlOwner = .agent
        item.leaseExpiresAtMillis = nowMillis() + Self.agentLeaseMillis
        metadata[sessionId] = item
        persistSessions()
        return record(sessionId: sessionId)!
    }

    func releaseAgentOwnership(runId: String) {
        guard !runId.isEmpty else { return }
        var changed = false
        for sessionId in metadata.keys where metadata[sessionId]?.ownerRunId == runId {
            guard var item = metadata[sessionId] else { continue }
            item.ownerRunId = nil
            if item.controlOwner == .agent {
                item.controlOwner = .none
                item.leaseExpiresAtMillis = nil
                (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
            }
            metadata[sessionId] = item
            changed = true
        }
        if changed {
            persistSessions()
        }
    }

    func hideCard(sessionId: String) {
        guard var item = metadata[sessionId], !item.cardHidden else { return }
        item.cardHidden = true
        metadata[sessionId] = item
        persistSessions()
    }

    func showCard(sessionId: String) {
        guard var item = metadata[sessionId], item.cardHidden else { return }
        item.cardHidden = false
        metadata[sessionId] = item
        persistSessions()
    }

    func expireInactiveSessions(nowMillis explicitNow: Int64? = nil) {
        let now = explicitNow ?? nowMillis()
        normalizeExpiredAgentLeases(now: now)
        let expired = metadata.compactMap { sessionId, item -> String? in
            guard runtimes[sessionId] != nil,
                  !item.persistentOptIn,
                  effectiveControlOwner(item, now: now) != .user,
                  now - item.lastActivityMillis >= Self.ephemeralTTLMillis else { return nil }
            return sessionId
        }
        for sessionId in expired {
            removeSession(sessionId, preserveReopenEntry: true)
        }
        if !metadata.values.contains(where: { $0.backend == .local }) {
            let runtime = runtimeFactory()
            let sessionId = runtime.snapshot.sessionId
            runtimes[sessionId] = runtime
            metadata[sessionId] = Self.freshMetadata(nowMillis: now)
            currentSessionId = sessionId
        }
        ensureCurrentSessionIsLocal()
        if !expired.isEmpty {
            persistSessions()
        }
    }

    func record(sessionId: String) -> IOSWebMountSessionRecord? {
        records.first { $0.id == sessionId }
    }

    private func evictLeastRecentlyUsedSession(allowCurrent: Bool) -> Bool {
        ensureCurrentSessionIsLocal()
        let now = nowMillis()
        let localSessionIds = Set(metadata.compactMap { sessionId, item in
            item.backend == .local && runtimes[sessionId] != nil ? sessionId : nil
        })
        let candidate = runtimes.keys
            .filter { sessionId in
                guard let item = metadata[sessionId],
                      !item.persistentOptIn,
                      effectiveControlOwner(item, now: now) == .none else { return false }
                if item.backend == .local, localSessionIds.count <= 1 { return false }
                return allowCurrent || sessionId != currentSessionId
            }
            .min { lhs, rhs in
                if lhs == currentSessionId { return false }
                if rhs == currentSessionId { return true }
                return (metadata[lhs]?.lastActivityMillis ?? 0) < (metadata[rhs]?.lastActivityMillis ?? 0)
            }
        guard let candidate else { return false }
        removeSession(candidate, preserveReopenEntry: true)
        if currentSessionId == candidate {
            currentSessionId = runtimes.keys.first(where: { metadata[$0]?.backend == .local }) ?? ""
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return true
    }

    private func fallbackRecord(for runtime: IOSWebMountRuntimeServicing, sessionId: String) -> IOSWebMountSessionRecord {
        let snapshot = runtime.snapshot
        return IOSWebMountSessionRecord(
            id: sessionId,
            siteId: metadata[sessionId]?.siteId,
            siteName: metadata[sessionId]?.siteName,
            title: IOSWebMountRedactor.redactedText(snapshot.title?.nilIfBlank ?? "Untitled"),
            redactedURL: snapshot.currentURL ?? snapshot.requestedURL ?? "",
            status: snapshot.status.rawValue,
            canGoBack: snapshot.canGoBack,
            canGoForward: snapshot.canGoForward,
            lastActivityMillis: metadata[sessionId]?.lastActivityMillis ?? snapshot.updatedAtMillis,
            isCurrent: sessionId == currentSessionId,
            ownerConversationId: metadata[sessionId]?.ownerConversationId,
            ownerRunId: metadata[sessionId]?.ownerRunId,
            controlOwner: metadata[sessionId]?.controlOwner ?? .none,
            leaseExpiresAtMillis: metadata[sessionId]?.leaseExpiresAtMillis,
            persistentOptIn: metadata[sessionId]?.persistentOptIn ?? false,
            needsReopen: metadata[sessionId]?.needsReopen ?? false,
            cardHidden: metadata[sessionId]?.cardHidden ?? false,
            backend: metadata[sessionId]?.backend ?? .local,
            mcpServerName: metadata[sessionId]?.mcpServerName
        )
    }

    private func removeSession(_ sessionId: String, preserveReopenEntry: Bool = false) {
        guard let removedRuntime = runtimes.removeValue(forKey: sessionId) else { return }
        if let browser = removedRuntime as? IOSWebMountWKRuntime {
            browser.closeSession()
        }
        if preserveReopenEntry,
           var item = metadata[sessionId],
           item.ownerConversationId?.nilIfBlank != nil {
            item.ownerRunId = nil
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            item.needsReopen = true
            metadata[sessionId] = item
        } else {
            metadata.removeValue(forKey: sessionId)
        }
        onSessionRemoved?(sessionId)
    }

    func markNeedsReopen(sessionId: String) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil else { return }
        guard !item.needsReopen else { return }
        item.needsReopen = true
        metadata[sessionId] = item
        persistSessions()
    }

    func recordValidatedRemoteURL(
        sessionId: String,
        rawURL: String,
        clearNeedsReopen: Bool
    ) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil,
              let redactedURL = IOSWebMountRedactor.redactedURL(rawURL) else { return }
        item.redactedURL = redactedURL
        item.lastActivityMillis = nowMillis()
        if clearNeedsReopen {
            item.needsReopen = false
        }
        metadata[sessionId] = item
        persistSessions()
    }

    func clearNeedsReopen(sessionId: String) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil else { return }
        guard item.needsReopen else { return }
        item.needsReopen = false
        metadata[sessionId] = item
        persistSessions()
    }

    private func normalizeExpiredAgentLease(sessionId: String) {
        guard var item = metadata[sessionId],
              item.controlOwner == .agent || item.ownerRunId?.nilIfBlank != nil else { return }
        guard let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
              leaseExpiresAtMillis <= nowMillis() else { return }
        item.controlOwner = .none
        item.leaseExpiresAtMillis = nil
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
        metadata[sessionId] = item
        persistSessions()
    }

    private func normalizeExpiredAgentLeases(now: Int64? = nil) {
        let now = now ?? nowMillis()
        var changed = false
        for sessionId in metadata.keys {
            guard var item = metadata[sessionId],
                  item.controlOwner == .agent || item.ownerRunId?.nilIfBlank != nil,
                  let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
                  leaseExpiresAtMillis <= now else { continue }
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
            metadata[sessionId] = item
            changed = true
        }
        if changed {
            persistSessions()
        }
    }

    private func ensureCurrentSessionIsLocal() {
        if let item = metadata[currentSessionId],
           item.backend == .local,
           runtimes[currentSessionId] != nil {
            return
        }
        if let localSessionId = runtimes.keys.first(where: { metadata[$0]?.backend == .local }) {
            currentSessionId = localSessionId
            return
        }
        let runtime = runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        currentSessionId = sessionId
    }

    private func effectiveControlOwner(_ item: IOSWebMountSessionMetadata, now: Int64) -> IOSWebMountControlOwner {
        if item.controlOwner == .user {
            return .user
        }
        guard let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
              leaseExpiresAtMillis > now else {
            return .none
        }
        return item.controlOwner
    }

    private func persistSessions() {
        recordsRevision &+= 1
        guard let userDefaults else { return }
        let persisted = metadata
            .filter { $0.value.persistentOptIn }
            .map { IOSWebMountPersistedSession(id: $0.key, metadata: $0.value) }
            .sorted { $0.id < $1.id }
        if persisted.isEmpty {
            userDefaults.removeObject(forKey: Self.persistedSessionsKey)
            userDefaults.removeObject(forKey: Self.persistedCurrentSessionKey)
            return
        }
        if let data = try? JSONEncoder().encode(persisted) {
            userDefaults.set(data, forKey: Self.persistedSessionsKey)
            let persistedCurrent = persisted.first(where: { $0.id == currentSessionId && $0.metadata.backend == .local })?.id
                ?? persisted.first(where: { $0.metadata.backend == .local })?.id
            if let persistedCurrent {
                userDefaults.set(persistedCurrent, forKey: Self.persistedCurrentSessionKey)
            } else {
                userDefaults.removeObject(forKey: Self.persistedCurrentSessionKey)
            }
        }
    }

    private static func loadPersistedSessions(from userDefaults: UserDefaults?) -> [IOSWebMountPersistedSession] {
        guard let data = userDefaults?.data(forKey: persistedSessionsKey),
              let sessions = try? JSONDecoder().decode([IOSWebMountPersistedSession].self, from: data) else {
            return []
        }
        return sessions
    }

    private static func freshMetadata(nowMillis: Int64) -> IOSWebMountSessionMetadata {
        IOSWebMountSessionMetadata(
            siteId: nil,
            siteName: nil,
            lastTitle: nil,
            redactedURL: nil,
            lastActivityMillis: nowMillis,
            ownerConversationId: nil,
            ownerRunId: nil,
            controlOwner: .none,
            leaseExpiresAtMillis: nil,
            persistentOptIn: false,
            needsReopen: false,
            cardHidden: false,
            backendRawValue: IOSWebMountBackendKind.local.rawValue,
            mcpServerName: nil
        )
    }
}

