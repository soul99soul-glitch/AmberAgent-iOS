import Darwin
import Foundation
import XCTest
@testable import iosApp

final class IOSPhoneControlServiceInspectionTests: XCTestCase {
    func testIPv4AddressDecodesAndMatchesLocalAddress() throws {
        let data = try sockaddrData(family: AF_INET, address: "192.0.2.17")
        let decoded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(data))
        XCTAssertEqual(decoded.family, "ipv4")
        XCTAssertEqual(decoded.normalizedAddress, "192.0.2.17")
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(decoded, localAddresses: [decoded]))
        XCTAssertFalse(IOSPhoneControlServiceAddressCodec.matches(decoded, localAddresses: []))
    }

    func testLocalVPNAddressMatchesActiveInterfaceMetadata() {
        let peerInterface = IOSPhoneControlServiceAddress(family: "ipv4", normalizedAddress: "10.7.1.1")
        let activeInterface = IOSPhoneControlServiceAddress(
            family: "ipv4", normalizedAddress: "10.7.1.1", interfaceIndex: 11
        )
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(peerInterface, localAddresses: [activeInterface]))
    }

    func testIPv6ScopeIsExcludedFromAddressIdentity() throws {
        let data = try sockaddrData(family: AF_INET6, address: "FE80::17", scopeID: 42)
        let decoded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(data))
        XCTAssertEqual(decoded.family, "ipv6")
        XCTAssertEqual(decoded.normalizedAddress, "fe80::17")
        XCTAssertEqual(decoded.scopeID, 42)

        let sameAddressOnAnotherInterface = IOSPhoneControlServiceAddress(
            family: "ipv6",
            normalizedAddress: "fe80::17",
            scopeID: 43,
            interfaceIndex: 43
        )
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(decoded, localAddresses: [sameAddressOnAnotherInterface]))
    }

    func testScopedLocalIPv6EndpointPreservesNumericScope() throws {
        let address = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80::17", scopeID: 42)
        ))
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 42)
        XCTAssertEqual(ipv6Candidates([address, address], local: [local]), ["[fe80::17%42]:49152"])
    }

    func testDarwinEmbeddedScopeIsRetainedFromRealSockaddrBytes() throws {
        let decoded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80:2a::17")
        ))
        XCTAssertEqual(decoded.normalizedAddress, "fe80::17")
        XCTAssertEqual(decoded.scopeID, 0)
        XCTAssertEqual(decoded.embeddedScopeID, 42)
        XCTAssertEqual(decoded.effectiveScopeID, 42)
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 42)
        XCTAssertEqual(ipv6Candidates([decoded], local: [local]), ["[fe80::17%42]:49152"])
        let otherInterface = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 43)
        XCTAssertTrue(ipv6Candidates([decoded], local: [otherInterface]).isEmpty)
    }

    func testExplicitAndEmbeddedScopesMustAgree() throws {
        let matching = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80:2a::17", scopeID: 42)
        ))
        let conflicting = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80:2b::17", scopeID: 42)
        ))
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 42)
        XCTAssertFalse(matching.hasConflictingScope)
        XCTAssertEqual(ipv6Candidates([matching], local: [local]), ["[fe80::17%42]:49152"])
        XCTAssertTrue(conflicting.hasConflictingScope)
        XCTAssertTrue(ipv6Candidates([conflicting], local: [local]).isEmpty)
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(conflicting, localAddresses: [local]))
    }

    func testGlobalIPv6BitsAreNotInterpretedAsEmbeddedScope() throws {
        let decoded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "2001:db8::17")
        ))
        XCTAssertEqual(decoded.normalizedAddress, "2001:db8::17")
        XCTAssertEqual(decoded.embeddedScopeID, 0)
        XCTAssertEqual(decoded.effectiveScopeID, 0)
    }

    func testPreferredWiFiCandidatesRequireObservedLinkLocalAddressAndInterface() {
        let wifi = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", scopeID: 42, interfaceIndex: 42)
        let other = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::18", scopeID: 43, interfaceIndex: 43)
        let global = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "2001:db8::17", interfaceIndex: 42)
        let local: Set<IOSPhoneControlServiceAddress> = [wifi, other, global]
        XCTAssertEqual(IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
            addresses: [wifi, other, global], localAddresses: local,
            serviceType: IOSPhoneControlServiceInspection.serviceType, port: 49152,
            requiredLinkLocalInterfaceIndex: 42
        ), ["[fe80::17%42]:49152"])
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
            addresses: [other, global], localAddresses: local,
            serviceType: IOSPhoneControlServiceInspection.serviceType, port: 49152,
            requiredLinkLocalInterfaceIndex: 42
        ).isEmpty)
    }

    func testUniqueWiFiLinkLocalEndpointTakesPriorityOverOtherRealCandidates() throws {
        let summary = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: [
            record(endpoints: [], ipv6Endpoints: ["[fe80::17%42]:49152", "[2001:db8::17]:49152"],
                   wifiIPv6Endpoints: ["[fe80::17%42]:49152"])
        ])
        XCTAssertEqual(try summary.uniqueLocalIPv6Endpoint, "[fe80::17%42]:49152")

        let ambiguous = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: [
            record(endpoints: [], ipv6Endpoints: ["[fe80::17%42]:49152", "[fe80::18%42]:49152"],
                   wifiIPv6Endpoints: ["[fe80::17%42]:49152", "[fe80::18%42]:49152"])
        ])
        XCTAssertThrowsError(try ambiguous.uniqueLocalIPv6Endpoint)
    }

    func testIPv6DiagnosticContainsCountsWithoutAddresses() throws {
        let embedded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80:2a::17")
        ))
        let conflicting = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(
            sockaddrData(family: AF_INET6, address: "fe80:2b::17", scopeID: 42)
        ))
        let unscoped = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "2001:db8::17")
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 42)
        let detail = IOSPhoneControlServiceAddressCodec.ipv6DiagnosticDetail(
            addresses: [embedded, conflicting, unscoped], localAddresses: [local], candidateCount: 1, wifiCandidateCount: 1
        )
        XCTAssertEqual(detail, "ipv6=3 explicit_scope=1 embedded_scope=2 unscoped=1 conflicting_scope=1 local_match=2 candidates=1 wifi_candidates=1")
    }

    func testLinkLocalIPv6EndpointRejectsMissingOrWrongScopeAndPeerAddress() {
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", interfaceIndex: 42)
        let missingScope = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17")
        let wrongScope = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", scopeID: 43)
        let peer = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::18", scopeID: 42)
        XCTAssertTrue(ipv6Candidates([missingScope, wrongScope, peer], local: [local]).isEmpty)
        // Identity remains possible-self even when the endpoint lacks enough routing information.
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(missingScope, localAddresses: [local]))
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(wrongScope, localAddresses: [local]))
    }

    func testLinkLocalIPv6EndpointRequiresAnActiveKnownLocalInterface() {
        let address = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", scopeID: 42)
        let localWithoutInterface = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", scopeID: 42)
        XCTAssertTrue(ipv6Candidates([address], local: [localWithoutInterface]).isEmpty)
        XCTAssertTrue(ipv6Candidates([address], local: []).isEmpty)
    }

    func testGlobalIPv6EndpointDoesNotInventScope() {
        let address = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "2001:db8::17")
        let local = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "2001:db8::17", interfaceIndex: 42)
        XCTAssertEqual(ipv6Candidates([address], local: [local]), ["[2001:db8::17]:49152"])
    }

    func testIPv6EndpointRejectsOtherServiceOrPort() {
        let address = IOSPhoneControlServiceAddress(family: "ipv6", normalizedAddress: "fe80::17", scopeID: 42, interfaceIndex: 42)
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
            addresses: [address], localAddresses: [address], serviceType: "_other._tcp.", port: 49152
        ).isEmpty)
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
            addresses: [address], localAddresses: [address],
            serviceType: IOSPhoneControlServiceInspection.serviceType, port: 49153
        ).isEmpty)
    }

    func testUniqueLocalIPv6EndpointRejectsNoneAmbiguousAndPeerRecords() {
        for records in [
            [record(endpoints: [])],
            [record(endpoints: [], ipv6Endpoints: ["[fe80::17%42]:49152", "[fe80::17%43]:49152"])],
            [record(endpoints: [], ipv6Endpoints: ["[fe80::18%42]:49152"], identity: .possiblyPeer)]
        ] {
            let summary = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: records)
            XCTAssertThrowsError(try summary.uniqueLocalIPv6Endpoint) { error in
                XCTAssertEqual(error as? IOSPhoneControlServiceInspectionError, .uniqueLocalIPv6EndpointUnavailable)
            }
        }
    }

    func testUniqueLocalIPv6EndpointDeduplicatesTheSameScopedCandidate() throws {
        let summary = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: [
            record(endpoints: [], ipv6Endpoints: ["[fe80::17%42]:49152", "[fe80::17%42]:49152"]),
            record(endpoints: [], ipv6Endpoints: ["[fe80::17%42]:49152"])
        ])
        XCTAssertEqual(try summary.uniqueLocalIPv6Endpoint, "[fe80::17%42]:49152")
    }

    func testTruncatedAndUnknownSocketAddressesAreIgnored() throws {
        let ipv6 = try sockaddrData(family: AF_INET6, address: "2001:db8::17")
        XCTAssertNil(IOSPhoneControlServiceAddressCodec.decode(ipv6.dropLast()))

        var unknown = sockaddr()
        unknown.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        unknown.sa_family = sa_family_t(AF_UNIX)
        let unknownData = Data(bytes: &unknown, count: MemoryLayout<sockaddr>.size)
        XCTAssertNil(IOSPhoneControlServiceAddressCodec.decode(unknownData))
    }

    func testOnlyUniqueSelfIPv4EndpointCandidateIsRetained() throws {
        let selfAddress = IOSPhoneControlServiceAddress(family: "ipv4", normalizedAddress: "192.0.2.17")
        let peerAddress = IOSPhoneControlServiceAddress(family: "ipv4", normalizedAddress: "192.0.2.18")
        let local = Set([selfAddress])

        XCTAssertEqual(
            IOSPhoneControlServiceAddressCodec.localIPv4EndpointCandidates(
                addresses: [selfAddress, selfAddress, peerAddress],
                localAddresses: local,
                serviceType: IOSPhoneControlServiceInspection.serviceType,
                port: IOSPhoneControlServiceInspection.remotePairingPort
            ),
            ["192.0.2.17:49152"]
        )
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.localIPv4EndpointCandidates(
            addresses: [selfAddress],
            localAddresses: local,
            serviceType: "_other._tcp.",
            port: IOSPhoneControlServiceInspection.remotePairingPort
        ).isEmpty)
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.localIPv4EndpointCandidates(
            addresses: [selfAddress],
            localAddresses: local,
            serviceType: IOSPhoneControlServiceInspection.serviceType,
            port: 49153
        ).isEmpty)
    }

    func testUniqueLocalIPv4EndpointRejectsNoneAndAmbiguousCandidates() throws {
        let none = IOSPhoneControlServiceInspectionSummary(
            observation: .resolvedServices,
            services: [record(endpoints: [])]
        )
        XCTAssertThrowsError(try none.uniqueLocalIPv4Endpoint) { error in
            XCTAssertEqual(error as? IOSPhoneControlServiceInspectionError, .uniqueLocalIPv4EndpointUnavailable)
        }

        let ambiguous = IOSPhoneControlServiceInspectionSummary(
            observation: .resolvedServices,
            services: [
                record(endpoints: ["192.0.2.17:49152"]),
                record(endpoints: ["192.0.2.18:49152"])
            ]
        )
        XCTAssertThrowsError(try ambiguous.uniqueLocalIPv4Endpoint) { error in
            XCTAssertEqual(error as? IOSPhoneControlServiceInspectionError, .uniqueLocalIPv4EndpointUnavailable)
        }
    }

    func testUniqueLocalIPv4EndpointReturnsTheOnlyDeduplicatedCandidate() throws {
        let summary = IOSPhoneControlServiceInspectionSummary(
            observation: .resolvedServices,
            services: [
                record(endpoints: ["192.0.2.17:49152", "192.0.2.17:49152"]),
                record(endpoints: ["192.0.2.17:49152"])
            ]
        )
        XCTAssertEqual(try summary.uniqueLocalIPv4Endpoint, "192.0.2.17:49152")
    }

    func testLockdownEndpointRequiresUniqueWiFiAddressMatchingBonjourSelf() throws {
        let summary = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: [
            record(endpoints: ["192.0.2.17:49152"])
        ])
        XCTAssertEqual(
            try summary.uniqueLocalWiFiIPv4LockdownEndpoint(localWiFiIPv4Addresses: ["192.0.2.17"]),
            "192.0.2.17:62078"
        )
        for localAddresses: Set<String> in [[], ["192.0.2.18"], ["192.0.2.17", "192.0.2.18"]] {
            XCTAssertThrowsError(try summary.uniqueLocalWiFiIPv4LockdownEndpoint(localWiFiIPv4Addresses: localAddresses))
        }
    }

    func testLockdownEndpointRejectsMissingOrAmbiguousBonjourSelf() {
        for endpoints in [[], ["192.0.2.17:49152", "192.0.2.18:49152"]] {
            let summary = IOSPhoneControlServiceInspectionSummary(observation: .resolvedServices, services: [
                record(endpoints: endpoints)
            ])
            XCTAssertThrowsError(try summary.uniqueLocalWiFiIPv4LockdownEndpoint(localWiFiIPv4Addresses: ["192.0.2.17"]))
        }
    }

    private func ipv6Candidates(
        _ addresses: [IOSPhoneControlServiceAddress],
        local: Set<IOSPhoneControlServiceAddress>
    ) -> [String] {
        IOSPhoneControlServiceAddressCodec.localIPv6EndpointCandidates(
            addresses: addresses,
            localAddresses: local,
            serviceType: IOSPhoneControlServiceInspection.serviceType,
            port: IOSPhoneControlServiceInspection.remotePairingPort
        )
    }

    private func sockaddrData(
        family: Int32,
        address: String,
        scopeID: UInt32 = 0
    ) throws -> Data {
        if family == Int32(AF_INET) {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            let result = address.withCString { inet_pton(AF_INET, $0, &value.sin_addr) }
            XCTAssertEqual(result, 1)
            return Data(bytes: &value, count: MemoryLayout<sockaddr_in>.size)
        }

        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_scope_id = scopeID
        let result = address.withCString { inet_pton(AF_INET6, $0, &value.sin6_addr) }
        XCTAssertEqual(result, 1)
        return Data(bytes: &value, count: MemoryLayout<sockaddr_in6>.size)
    }

    private func record(
        endpoints: [String],
        ipv6Endpoints: [String] = [],
        wifiIPv6Endpoints: [String] = [],
        identity: IOSPhoneControlServiceIdentity = .possibleSelf
    ) -> IOSPhoneControlServiceRecord {
        IOSPhoneControlServiceRecord(
            type: IOSPhoneControlServiceInspection.serviceType,
            host: "iPhone.local.",
            port: IOSPhoneControlServiceInspection.remotePairingPort,
            addressFamilies: ["ipv4"],
            localAddressMatch: true,
            identity: identity,
            localIPv4Endpoints: endpoints,
            localIPv6Endpoints: ipv6Endpoints,
            localWiFiIPv6Endpoints: wifiIPv6Endpoints
        )
    }
}
