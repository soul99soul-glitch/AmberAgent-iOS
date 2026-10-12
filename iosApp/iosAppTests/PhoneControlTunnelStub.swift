import Foundation
@testable import iosApp

/// Controller and tool tests exercise ownership without reading system VPN preferences.
@MainActor
final class PhoneControlTunnelStub: IOSPhoneControlLocalTunneling {
    var state: IOSPhoneControlLocalTunnel.State = .ready
    var isPrepared = true
    var prepareOperation: (() async throws -> Void)?
    var startOperation: ((UUID) async throws -> Void)?
    var stopOperation: ((UUID) async -> Bool)?
    private(set) var prepareCount = 0
    private(set) var startOwners: [UUID] = []
    private(set) var stopOwners: [UUID] = []

    func refresh() async { }

    func prepare() async throws {
        prepareCount += 1
        try await prepareOperation?()
        isPrepared = true
        state = .ready
    }

    func start(owner: UUID) async throws {
        startOwners.append(owner)
        guard isPrepared else { throw IOSPhoneControlLocalTunnelError.notPrepared }
        state = .connecting
        try await startOperation?(owner)
        try Task.checkCancellation()
        state = .connected
    }

    func stop(owner: UUID) async -> Bool {
        stopOwners.append(owner)
        state = .disconnecting
        let disconnected = await stopOperation?(owner) ?? true
        state = disconnected ? .ready : .failed(IOSPhoneControlLocalTunnelError.disconnectionTimedOut.localizedDescription)
        return disconnected
    }
}
