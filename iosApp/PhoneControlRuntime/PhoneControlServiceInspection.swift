import Darwin
import Foundation
import Observation

enum IOSPhoneControlServiceInspectionObservation: String, Equatable, Sendable {
    case resolvedServices
    /// No record is treated as an unknown observation because browsing can be
    /// filtered by local-network permission or the current network.
    case unknown
}

enum IOSPhoneControlServiceIdentity: String, Equatable, Sendable {
    case possibleSelf
    case possiblyPeer
    case unknown
}

struct IOSPhoneControlServiceAddress: Hashable, Sendable {
    let family: String
    let normalizedAddress: String
}

struct IOSPhoneControlServiceRecord: Equatable, Sendable {
    let type: String
    let host: String
    let port: Int
    let addressFamilies: [String]
    let localAddressMatch: Bool?
    let identity: IOSPhoneControlServiceIdentity
    let localIPv4Endpoints: [String]
}

enum IOSPhoneControlServiceInspectionError: LocalizedError, Equatable, Sendable {
    case uniqueLocalIPv4EndpointUnavailable

    var errorDescription: String? {
        "未取得唯一的本机IPv4开发服务地址，身份未知"
    }
}

struct IOSPhoneControlServiceInspectionSummary: Equatable, Sendable {
    let observation: IOSPhoneControlServiceInspectionObservation
    let services: [IOSPhoneControlServiceRecord]

    static let unknown = Self(observation: .unknown, services: [])

    var uniqueLocalIPv4Endpoint: String {
        get throws {
            let candidates = Set(services
                .filter {
                    $0.type == IOSPhoneControlServiceInspection.serviceType
                        && $0.identity == .possibleSelf
                        && $0.port == IOSPhoneControlServiceInspection.remotePairingPort
                }
                .flatMap(\.localIPv4Endpoints))
            guard candidates.count == 1, let endpoint = candidates.first else {
                throw IOSPhoneControlServiceInspectionError.uniqueLocalIPv4EndpointUnavailable
            }
            return endpoint
        }
    }
}

/// Address parsing is kept separate so the service browser never needs to
/// expose raw sockaddr bytes or TXT records to the rest of the app.
enum IOSPhoneControlServiceAddressCodec {
    static func decode(_ data: Data) -> IOSPhoneControlServiceAddress? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }

        var header = sockaddr()
        withUnsafeMutableBytes(of: &header) { destination in
            data.copyBytes(to: destination, count: MemoryLayout<sockaddr>.size)
        }
        let family = header.sa_family
        let familyName: String
        let addressLength: Int
        switch family {
        case sa_family_t(AF_INET):
            guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            familyName = "ipv4"
            addressLength = MemoryLayout<sockaddr_in>.size
        case sa_family_t(AF_INET6):
            guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
            familyName = "ipv6"
            addressLength = MemoryLayout<sockaddr_in6>.size
        default: return nil
        }

        var storage = sockaddr_storage()
        let copyCount = min(addressLength, MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutableBytes(of: &storage) { destination in
            data.copyBytes(to: destination, count: copyCount)
        }

        if family == sa_family_t(AF_INET6) {
            // Address identity excludes the interface; numeric decoding must not require that interface to exist.
            withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_scope_id = 0
                }
            }
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = host.withUnsafeMutableBufferPointer { hostBuffer in
            withUnsafePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    getnameinfo(
                        addressPointer,
                        socklen_t(copyCount),
                        hostBuffer.baseAddress,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
        }
        guard result == 0, let first = host.first, first != 0 else { return nil }

        return IOSPhoneControlServiceAddress(
            family: familyName,
            normalizedAddress: normalize(host)
        )
    }

    static func matches(
        _ address: IOSPhoneControlServiceAddress,
        localAddresses: Set<IOSPhoneControlServiceAddress>
    ) -> Bool {
        localAddresses.contains(address)
    }

    static func localIPv4EndpointCandidates(
        addresses: [IOSPhoneControlServiceAddress],
        localAddresses: Set<IOSPhoneControlServiceAddress>,
        serviceType: String,
        port: Int
    ) -> [String] {
        guard serviceType == IOSPhoneControlServiceInspection.serviceType,
              port == IOSPhoneControlServiceInspection.remotePairingPort
        else { return [] }

        return Set(
            addresses
                .filter { $0.family == "ipv4" && matches($0, localAddresses: localAddresses) }
                .map { "\($0.normalizedAddress):\(port)" }
        ).sorted()
    }

    static func localAddresses() -> Set<IOSPhoneControlServiceAddress> {
        var result = Set<IOSPhoneControlServiceAddress>()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == Int32(AF_INET) || family == Int32(AF_INET6) else { continue }
            let length = family == Int32(AF_INET)
                ? MemoryLayout<sockaddr_in>.size
                : MemoryLayout<sockaddr_in6>.size
            let data = Data(bytes: address, count: length)
            if let decoded = decode(data) {
                result.insert(decoded)
            }
        }
        return result
    }

    private static func normalize(_ host: [CChar]) -> String {
        let value = String(cString: host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // getnameinfo may append an interface scope to an IPv6 literal. The
        // scope identifies the local interface, not the address identity.
        return value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? value
    }
}

/// Main-actor owner for a bounded, read-only Bonjour identity observation.
/// It never opens a socket, sends pairing bytes, reads TXT data, or stores
/// service credentials.
@MainActor
@Observable
final class IOSPhoneControlServiceInspection {
    nonisolated static let serviceType = "_remotepairing._tcp."
    nonisolated static let remotePairingPort = 49_152
    nonisolated static let diagnosticLaunchArgument = "-amber-phone-service-inspection-once"

    private(set) var summary: IOSPhoneControlServiceInspectionSummary?
    private(set) var isInspecting = false

    @ObservationIgnored private var run: IOSPhoneControlServiceInspectionRun?
    @ObservationIgnored private var inspectionID: UUID?

    @discardableResult
    func inspectAndRecord(source: String) async -> IOSPhoneControlServiceInspectionSummary {
        IOSBackgroundLifecycleLog.record("phoneControlServiceInspectionStarted", detail: "source=\(source)")
        let result = await inspect()
        IOSBackgroundLifecycleLog.record("phoneControlServiceInspection", detail: "resolved=\(result.services.count)")
        for service in result.services {
            IOSBackgroundLifecycleLog.record("phoneControlServiceRecord",
                detail: "port=\(service.port) families=\(service.addressFamilies.joined(separator: ",")) local=\(service.localAddressMatch.map(String.init) ?? "unknown")")
        }
        return result
    }

    @discardableResult
    func inspect() async -> IOSPhoneControlServiceInspectionSummary {
        guard !Task.isCancelled else { return summary ?? .unknown }
        cancel()
        let id = UUID()
        inspectionID = id
        isInspecting = true

        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<IOSPhoneControlServiceInspectionSummary, Never>) in
                let run = IOSPhoneControlServiceInspectionRun { [weak self] result in
                    Task { @MainActor [weak self] in
                        continuation.resume(returning: result)
                        guard let self, self.inspectionID == id else { return }
                        self.run = nil
                        self.inspectionID = nil
                        self.isInspecting = false
                        self.summary = result
                    }
                }
                self.run = run
                run.start()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        })
        return result
    }

    func cancel() {
        cancel(id: inspectionID)
    }

    private func cancel(id: UUID?) {
        guard inspectionID == id else { return }
        run?.cancel()
        run = nil
        inspectionID = nil
        isInspecting = false
    }
}

// The delegate object is created and controlled by the MainActor owner. Both
// browser and resolver callbacks are explicitly scheduled on RunLoop.main.
@MainActor
private final class IOSPhoneControlServiceInspectionRun: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let completion: (IOSPhoneControlServiceInspectionSummary) -> Void
    private let localAddresses: Set<IOSPhoneControlServiceAddress>
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolvedByService: [String: IOSPhoneControlServiceRecord] = [:]
    private var finished = false
    private var timeoutTimer: Timer?

    init(completion: @escaping (IOSPhoneControlServiceInspectionSummary) -> Void) {
        self.completion = completion
        localAddresses = IOSPhoneControlServiceAddressCodec.localAddresses()
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !finished else { return }
        browser.schedule(in: RunLoop.main, forMode: .common)
        browser.searchForServices(ofType: IOSPhoneControlServiceInspection.serviceType, inDomain: "")
        timeoutTimer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        if let timeoutTimer {
            RunLoop.main.add(timeoutTimer, forMode: .common)
        }
    }

    func cancel() {
        finish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !finished, services.count < 4 else { return }
        let key = "\(service.name)\u{0000}\(service.domain)"
        guard !services.contains(where: { "\($0.name)\u{0000}\($0.domain)" == key }) else { return }
        services.append(service)
        service.delegate = self
        service.schedule(in: RunLoop.main, forMode: .common)
        service.resolve(withTimeout: 1.25)
        if services.count == 4 {
            browser.stop()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // The final summary only reports successfully resolved endpoint
        // metadata; resolver errors are deliberately not surfaced or logged.
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !finished,
              let host = sender.hostName,
              !host.isEmpty,
              sender.port > 0
        else { return }

        let addresses = (sender.addresses ?? []).compactMap(IOSPhoneControlServiceAddressCodec.decode)
        guard !addresses.isEmpty else { return }
        let families = Array(Set(addresses.map(\.family))).sorted()
        let hasLocalAddresses = !localAddresses.isEmpty
        let localMatch = addresses.contains { IOSPhoneControlServiceAddressCodec.matches($0, localAddresses: localAddresses) }
        let identity: IOSPhoneControlServiceIdentity
        if localMatch {
            identity = .possibleSelf
        } else if hasLocalAddresses {
            identity = .possiblyPeer
        } else {
            identity = .unknown
        }
        let localIPv4Endpoints = identity == .possibleSelf
            ? IOSPhoneControlServiceAddressCodec.localIPv4EndpointCandidates(
                addresses: addresses,
                localAddresses: localAddresses,
                serviceType: sender.type,
                port: sender.port
            )
            : []

        let record = IOSPhoneControlServiceRecord(
            type: IOSPhoneControlServiceInspection.serviceType,
            host: host,
            port: sender.port,
            addressFamilies: families,
            localAddressMatch: hasLocalAddresses ? localMatch : nil,
            identity: identity,
            localIPv4Endpoints: localIPv4Endpoints
        )
        let key = "\(sender.name)\u{0000}\(sender.domain)"
        resolvedByService[key] = record
    }

    func netServiceDidStop(_ sender: NetService) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {}

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        browser.stop()
        browser.remove(from: RunLoop.main, forMode: .common)
        browser.delegate = nil
        for service in services {
            service.stop()
            service.remove(from: RunLoop.main, forMode: .common)
            service.delegate = nil
        }
        let result = IOSPhoneControlServiceInspectionSummary(
            observation: resolvedByService.isEmpty ? .unknown : .resolvedServices,
            services: resolvedByService.values.sorted {
                ($0.host, $0.port, $0.addressFamilies.joined(separator: ",")) < ($1.host, $1.port, $1.addressFamilies.joined(separator: ","))
            }
        )
        completion(result)
    }
}
