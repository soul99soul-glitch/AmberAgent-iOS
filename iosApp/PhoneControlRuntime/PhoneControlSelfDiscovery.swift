import AmberIPhoneControl
import Foundation
import Network
import UIKit

struct IOSPhoneControlSelfDiscoveryInfo: Decodable {
    let service_identifier: String
    let txt_records: [String: String]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_048 else { throw CocoaError(.coderInvalidValue) }
        let info = try JSONDecoder().decode(Self.self, from: data)
        guard UUID(uuidString: info.service_identifier) != nil,
              Set(info.txt_records.keys) == ["name", "identifier", "authTag", "model", "flags", "ver", "minVer"],
              info.txt_records["identifier"] == info.service_identifier,
              info.txt_records["name"] == "Amber 同机验证",
              info.txt_records["model"] == "Mac17,7",
              info.txt_records["flags"] == "1",
              info.txt_records["ver"] == "26",
              info.txt_records["minVer"] == "17",
              Data(base64Encoded: info.txt_records["authTag"] ?? "")?.count == 6
        else { throw CocoaError(.coderInvalidValue) }
        return info
    }

    static func generate() throws -> Self {
        guard let pointer = amber_iphone_control_self_discovery_info() else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { amber_iphone_control_string_free(pointer) }
        let length = strnlen(pointer, 2_049)
        guard length <= 2_048 else { throw CocoaError(.coderInvalidValue) }
        return try decode(Data(bytes: pointer, count: length))
    }

    static func localMatch(_ endpoint: NWEndpoint, addresses: Set<IOSPhoneControlServiceAddress>) -> Bool? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(remote):
            return addresses.contains { $0.family == "ipv4" && IPv4Address($0.normalizedAddress)?.rawValue == remote.rawValue }
        case let .ipv6(remote):
            return addresses.contains { $0.family == "ipv6" && IPv6Address($0.normalizedAddress)?.rawValue == remote.rawValue }
        default: return nil
        }
    }
}

/// Temporary phone-owned discovery only: close every inbound connection without reading or writing pairing bytes.
@MainActor
final class IOSPhoneControlSelfDiscovery {
    static let shared = IOSPhoneControlSelfDiscovery()
    nonisolated static let diagnosticLaunchArgument = "-amber-phone-self-discovery-once"
    nonisolated static let serviceType = "_remotepairing-pairable-host._tcp"
    private var runID: UUID?
    private var listener: NWListener?
    private var deadline: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    var isRunning: Bool { runID != nil }

    func start() async {
        guard runID == nil, !Task.isCancelled else { return }
        let id = UUID()
        runID = id
        // Let application launch finish before asking UIKit for a bounded background assertion.
        try? await Task.sleep(for: .milliseconds(200))
        guard runID == id, !Task.isCancelled else { finish(id: id, reason: "cancelled"); return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AmberSelfDiscovery") { [weak self] in
            self?.finish(id: id, reason: "system_expired")
        }
        guard backgroundTask != .invalid else { finish(id: id, reason: "background_unavailable"); return }
        do {
            let info = try IOSPhoneControlSelfDiscoveryInfo.generate()
            let listener = try NWListener(using: .tcp)
            self.listener = listener
            listener.newConnectionLimit = 8
            var service = NWListener.Service(
                name: info.service_identifier, type: Self.serviceType, domain: "local.",
                txtRecord: NetService.data(fromTXTRecord: info.txt_records.mapValues { Data($0.utf8) })
            )
            service.noAutoRename = true
            listener.service = service
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.runID == id else { return }
                    switch state {
                    case .ready: IOSBackgroundLifecycleLog.record("phoneControlSelfDiscoveryReady")
                    case .failed: self.finish(id: id, reason: "listener_failed")
                    default: break
                    }
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                MainActor.assumeIsolated {
                    guard self?.runID == id else { return }
                    if case .add = change { IOSBackgroundLifecycleLog.record("phoneControlSelfDiscoveryPublished") }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.cancel()
                MainActor.assumeIsolated {
                    guard let self, self.runID == id else { return }
                    let match = IOSPhoneControlSelfDiscoveryInfo.localMatch(
                        connection.endpoint, addresses: IOSPhoneControlServiceAddressCodec.localAddresses()
                    )
                    IOSBackgroundLifecycleLog.record("phoneControlSelfDiscoveryInbound", detail: "local=\(match.map(String.init) ?? "unknown") bytes_read=0 bytes_written=0")
                    if match == true { self.finish(id: id, reason: "local_candidate_closed") }
                }
            }
            listener.start(queue: .main)
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.finish(id: id, reason: "deadline")
            }
        } catch {
            finish(id: id, reason: "preparation_failed")
        }
    }

    func cancel() { if let runID { finish(id: runID, reason: "cancelled") } }

    private func finish(id: UUID, reason: String) {
        guard runID == id else { return }
        runID = nil
        deadline?.cancel()
        deadline = nil
        listener?.stateUpdateHandler = nil
        listener?.serviceRegistrationUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        IOSBackgroundLifecycleLog.record("phoneControlSelfDiscoveryStopped", detail: "reason=\(reason)")
    }
}
