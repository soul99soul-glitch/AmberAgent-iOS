import Foundation
@preconcurrency import GatewayCore

/// Transport contract for `/v2/soul` (`C-SOUL-V1`).
/// `DesktopCloudClientSoulSync` in production; memory fake in unit tests.
protocol DesktopCloudSoulSync: Sendable {
    func fetchSoul() async throws -> AmberControl.SoulState
    func putSoul(_ request: AmberControl.SoulPutRequest) async throws -> AmberControl.SoulState
}

struct DesktopCloudClientSoulSync: DesktopCloudSoulSync {
    let client: DesktopCloudClient

    func fetchSoul() async throws -> AmberControl.SoulState {
        try await client.fetchSoul()
    }

    func putSoul(_ request: AmberControl.SoulPutRequest) async throws -> AmberControl.SoulState {
        try await client.putSoul(request)
    }
}

/// Loop-free two-way synchronizer between macOS `DesktopAgentSoulStore` and cloud `amberd` `/v2/soul`.
///
/// Anti-loop invariants:
/// 1. Remote pulls (`GET /v2/soul`) apply via `soulStore.applyRemote(_:)`, which never emits `onLocalMutation`
///    and therefore never triggers `PUT /v2/soul`.
/// 2. `/v1/status` carries `soulRevision`; when `remoteRevisionHint == soulStore.revision` and there is no
///    pending local push (nor an initial local-custom vs cloud-default migration), reconcile performs zero HTTP calls.
/// 3. Local mutations (`onLocalMutation`) set a durable `hasPendingLocalPush` flag for the active `gatewayId`
///    and push once via `PUT /v2/soul`, adopting the server's returned `SoulState` via `applyRemote`.
@MainActor
final class DesktopCloudSoulCoordinator {
    private let soulStore: DesktopAgentSoulStore
    private let defaults: UserDefaults
    private var gatewayId: String?
    private var sync: (any DesktopCloudSoulSync)?
    private var isReconciling = false
    private var inFlightPushTask: Task<Void, Never>?
    private(set) var lastSyncError: String?

    init(soulStore: DesktopAgentSoulStore, defaults: UserDefaults = .standard) {
        self.soulStore = soulStore
        self.defaults = defaults
        soulStore.onLocalMutation = { [weak self] _ in
            guard let self else { return }
            self.markPendingLocalPush(true)
            self.scheduleImmediatePush()
        }
    }

    var hasPendingLocalPush: Bool {
        guard let key = pendingKey else { return false }
        return defaults.bool(forKey: key)
    }

    func attach(gatewayId: String, sync: (any DesktopCloudSoulSync)?) {
        inFlightPushTask?.cancel()
        inFlightPushTask = nil
        self.gatewayId = gatewayId
        self.sync = sync
        lastSyncError = nil
    }

    func detach(clearPendingForGateway gatewayId: String? = nil) {
        inFlightPushTask?.cancel()
        inFlightPushTask = nil
        if let id = gatewayId ?? self.gatewayId {
            defaults.removeObject(forKey: Self.pendingDefaultsKey(for: id))
        }
        self.gatewayId = nil
        self.sync = nil
        lastSyncError = nil
    }

    func reconcile(remoteRevisionHint: Int64?) async {
        guard let sync else { return }
        if let pushTask = inFlightPushTask {
            await pushTask.value
        }
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        do {
            if hasPendingLocalPush {
                let snapshotBeforeFetch = soulStore.state
                let remote = try await sync.fetchSoul()
                if remote.revision > snapshotBeforeFetch.revision,
                   !remote.isDefault,
                   remote.updatedAtMs > snapshotBeforeFetch.updatedAtMs {
                    soulStore.applyRemote(remote)
                    if soulStore.state == remote {
                        markPendingLocalPush(false)
                    }
                    lastSyncError = nil
                    return
                }
                try await pushLocalState(using: sync)
                lastSyncError = nil
                return
            }

            if let hint = remoteRevisionHint,
               hint == soulStore.revision,
               !(hint == 0 && !soulStore.isDefault) {
                lastSyncError = nil
                return
            }

            let remote = try await sync.fetchSoul()
            if remote.revision == 0, remote.isDefault, !soulStore.isDefault {
                try await pushLocalState(using: sync)
            } else if remote != soulStore.state {
                soulStore.applyRemote(remote)
            }
            lastSyncError = nil
        } catch is CancellationError {
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func syncNow() async {
        await reconcile(remoteRevisionHint: nil)
    }

    // MARK: - Private

    private var pendingKey: String? {
        gatewayId.map(Self.pendingDefaultsKey(for:))
    }

    private static func pendingDefaultsKey(for gatewayId: String) -> String {
        "desktop.cloudSelf.soulPendingPush.\(gatewayId)"
    }

    private func markPendingLocalPush(_ pending: Bool) {
        guard let key = pendingKey else { return }
        if pending {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func scheduleImmediatePush() {
        guard let sync else { return }
        inFlightPushTask?.cancel()
        inFlightPushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightPushTask = nil }
            do {
                try await self.pushLocalState(using: sync)
                self.lastSyncError = nil
            } catch is CancellationError {
            } catch {
                self.lastSyncError = error.localizedDescription
            }
        }
    }

    private func pushLocalState(using sync: any DesktopCloudSoulSync) async throws {
        let local = soulStore.state
        let request = AmberControl.SoulPutRequest(
            displayName: local.displayName,
            tagline: local.tagline,
            soulMarkdown: local.soulMarkdown,
            isDefault: local.isDefault,
            updatedAtMs: local.updatedAtMs,
            source: local.source
        )
        let confirmed = try await sync.putSoul(request)
        // Only adopt if no newer local mutation raced while the network call was in flight.
        if soulStore.state == local {
            soulStore.applyRemote(confirmed)
            markPendingLocalPush(false)
        } else {
            markPendingLocalPush(true)
        }
    }
}
