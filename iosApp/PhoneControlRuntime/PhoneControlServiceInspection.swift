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
    var scopeID: UInt32 = 0
    /// Set only for an address observed on an active local interface.
    var interfaceIndex: UInt32 = 0
    var embeddedScopeID: UInt32 = 0

    var effectiveScopeID: UInt32 { scopeID == 0 ? embeddedScopeID : scopeID }
    var hasConflictingScope: Bool {
        scopeID != 0 && embeddedScopeID != 0 && scopeID != embeddedScopeID
    }
}

struct IOSPhoneControlServiceRecord: Equatable, Sendable {
    let type: String
    let host: String
    let port: Int
    let addressFamilies: [String]
    let localAddressMatch: Bool?
    let identity: IOSPhoneControlServiceIdentity
    let localIPv4Endpoints: [String]
    var localIPv6Endpoints: [String] = []
    var localWiFiIPv6Endpoints: [String] = []
    var ipv6DiagnosticDetail: String = ""
}

enum IOSPhoneControlServiceInspectionError: LocalizedError, Equatable, Sendable {
    case uniqueLocalIPv4EndpointUnavailable
    case uniqueLocalIPv6EndpointUnavailable
    case uniqueLocalWiFiIPv4EndpointUnavailable

    var errorDescription: String? {
        switch self {
        case .uniqueLocalIPv4EndpointUnavailable:
            "未取得唯一的本机IPv4开发服务地址，身份未知"
        case .uniqueLocalIPv6EndpointUnavailable:
            "未取得唯一且接口明确的本机IPv6开发服务地址"
        case .uniqueLocalWiFiIPv4EndpointUnavailable:
            "本机开发服务地址与唯一的Wi-Fi地址不匹配"
        }
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

    var uniqueLocalIPv6Endpoint: String {
        get throws {
            let localServices = services.filter {
                $0.type == IOSPhoneControlServiceInspection.serviceType
                    && $0.identity == .possibleSelf
                    && $0.port == IOSPhoneControlServiceInspection.remotePairingPort
            }
            let wifiCandidates = Set(localServices.flatMap(\.localWiFiIPv6Endpoints))
            if wifiCandidates.count == 1, let endpoint = wifiCandidates.first { return endpoint }
            let candidates = Set(localServices.flatMap(\.localIPv6Endpoints))
            guard candidates.count == 1, let endpoint = candidates.first else {
                throw IOSPhoneControlServiceInspectionError.uniqueLocalIPv6EndpointUnavailable
            }
            return endpoint
        }
    }

    func uniqueLocalWiFiIPv4LockdownEndpoint(
        localWiFiIPv4Addresses: Set<String> = IOSPhoneControlServiceAddressCodec.localWiFiIPv4Addresses()
    ) throws -> String {
        guard localWiFiIPv4Addresses.count == 1,
              let address = localWiFiIPv4Addresses.first,
              try uniqueLocalIPv4Endpoint == "\(address):\(IOSPhoneControlServiceInspection.remotePairingPort)"
        else { throw IOSPhoneControlServiceInspectionError.uniqueLocalWiFiIPv4EndpointUnavailable }
        return "\(address):62078"
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

        var scopeID: UInt32 = 0
        var embeddedScopeID: UInt32 = 0
        if family == sa_family_t(AF_INET6) {
            // Address identity excludes the interface; numeric decoding must not require that interface to exist.
            withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    scopeID = $0.pointee.sin6_scope_id
                    // Darwin can encode the link-local zone in the address itself.
                    // Preserve it before getnameinfo moves it into the textual suffix.
                    embeddedScopeID = withUnsafeMutableBytes(of: &$0.pointee.sin6_addr) { bytes in
                        guard bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 else { return 0 }
                        let embedded = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                        bytes[2] = 0
                        bytes[3] = 0
                        return embedded
                    }
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
            normalizedAddress: normalize(host),
            scopeID: scopeID,
            embeddedScopeID: embeddedScopeID
        )
    }

    static func matches(
        _ address: IOSPhoneControlServiceAddress,
        localAddresses: Set<IOSPhoneControlServiceAddress>
    ) -> Bool {
        localAddresses.contains {
            $0.family == address.family && $0.normalizedAddress == address.normalizedAddress
        }
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

    static func localIPv6EndpointCandidates(
        addresses: [IOSPhoneControlServiceAddress],
        localAddresses: Set<IOSPhoneControlServiceAddress>,
        serviceType: String,
        port: Int,
        requiredLinkLocalInterfaceIndex: UInt32? = nil
    ) -> [String] {
        guard serviceType == IOSPhoneControlServiceInspection.serviceType,
              port == IOSPhoneControlServiceInspection.remotePairingPort
        else { return [] }

        return Set(addresses.compactMap { address -> String? in
            guard address.family == "ipv6", !address.hasConflictingScope else { return nil }
            var binaryAddress = in6_addr()
            guard address.normalizedAddress.withCString({ inet_pton(AF_INET6, $0, &binaryAddress) }) == 1 else {
                return nil
            }
            let isLinkLocal = withUnsafeBytes(of: binaryAddress) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
            let scopeID = address.effectiveScopeID
            if let requiredLinkLocalInterfaceIndex {
                guard isLinkLocal, requiredLinkLocalInterfaceIndex != 0,
                      scopeID == requiredLinkLocalInterfaceIndex else { return nil }
            }
            guard !isLinkLocal || scopeID != 0,
                  localAddresses.contains(where: {
                      $0.family == "ipv6" && $0.normalizedAddress == address.normalizedAddress
                          && $0.interfaceIndex != 0
                          && (scopeID == 0 || scopeID == $0.interfaceIndex)
                  })
            else { return nil }
            let scope = scopeID == 0 ? "" : "%\(scopeID)"
            return "[\(address.normalizedAddress)\(scope)]:\(port)"
        }).sorted()
    }

    static func ipv6DiagnosticDetail(
        addresses: [IOSPhoneControlServiceAddress],
        localAddresses: Set<IOSPhoneControlServiceAddress>,
        candidateCount: Int,
        wifiCandidateCount: Int
    ) -> String {
        let ipv6 = addresses.filter { $0.family == "ipv6" }
        let explicit = ipv6.filter { $0.scopeID != 0 }.count
        let embedded = ipv6.filter { $0.embeddedScopeID != 0 }.count
        let unscoped = ipv6.filter { $0.effectiveScopeID == 0 }.count
        let conflicting = ipv6.filter(\.hasConflictingScope).count
        let local = ipv6.filter { matches($0, localAddresses: localAddresses) }.count
        return "ipv6=\(ipv6.count) explicit_scope=\(explicit) embedded_scope=\(embedded) unscoped=\(unscoped) conflicting_scope=\(conflicting) local_match=\(local) candidates=\(candidateCount) wifi_candidates=\(wifiCandidateCount)"
    }

    static func localWiFiIPv4Addresses() -> Set<String> {
        Set(localAddresses(interfaceName: "en0")
            .filter { $0.family == "ipv4" && $0.interfaceIndex != 0 }
            .map(\.normalizedAddress))
    }

    static func localAddresses(interfaceName: String? = nil) -> Set<IOSPhoneControlServiceAddress> {
        var result = Set<IOSPhoneControlServiceAddress>()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            if let interfaceName, String(cString: item.pointee.ifa_name) != interfaceName { continue }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == Int32(AF_INET) || family == Int32(AF_INET6) else { continue }
            let length = family == Int32(AF_INET)
                ? MemoryLayout<sockaddr_in>.size
                : MemoryLayout<sockaddr_in6>.size
            let data = Data(bytes: address, count: length)
            if var decoded = decode(data) {
                if item.pointee.ifa_flags & UInt32(IFF_UP) != 0 {
                    decoded.interfaceIndex = if_nametoindex(item.pointee.ifa_name)
                }
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
            IOSBackgroundLifecycleLog.record("phoneControlIPv6Candidates", detail: service.ipv6DiagnosticDetail)
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
    private let wifiInterfaceIndex: UInt32
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolvedByService: [String: IOSPhoneControlServiceRecord] = [:]
    private var finished = false
    private var timeoutTimer: Timer?

    init(completion: @escaping (IOSPhoneControlServiceInspectionSummary) -> Void) {
        self.completion = completion
        localAddresses = IOSPhoneControlServiceAddressCodec.localAddresses()
        wifiInterfaceIndex = if_nametoindex("en0")
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
        let localIPv6Endpoints = identity == .possibleSelf
            ? IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
                addresses: addresses,
                localAddresses: localAddresses,
                serviceType: sender.type,
                port: sender.port
            )
            : []
        let localWiFiIPv6Endpoints = identity == .possibleSelf
            ? IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
                addresses: addresses,
                localAddresses: localAddresses,
                serviceType: sender.type,
                port: sender.port,
                requiredLinkLocalInterfaceIndex: wifiInterfaceIndex
            )
            : []

        let record = IOSPhoneControlServiceRecord(
            type: IOSPhoneControlServiceInspection.serviceType,
            host: host,
            port: sender.port,
            addressFamilies: families,
            localAddressMatch: hasLocalAddresses ? localMatch : nil,
            identity: identity,
            localIPv4Endpoints: localIPv4Endpoints,
            localIPv6Endpoints: localIPv6Endpoints,
            localWiFiIPv6Endpoints: localWiFiIPv6Endpoints,
            ipv6DiagnosticDetail: IOSPhoneControlServiceAddressCodec.ipv6DiagnosticDetail(
                addresses: addresses,
                localAddresses: localAddresses,
                candidateCount: localIPv6Endpoints.count,
                wifiCandidateCount: localWiFiIPv6Endpoints.count
            )
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
