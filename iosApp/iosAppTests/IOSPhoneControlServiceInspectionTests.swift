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

    func testIPv6ScopeIsExcludedFromAddressIdentity() throws {
        let data = try sockaddrData(family: AF_INET6, address: "FE80::17", scopeID: 42)
        let decoded = try XCTUnwrap(IOSPhoneControlServiceAddressCodec.decode(data))
        XCTAssertEqual(decoded.family, "ipv6")
        XCTAssertEqual(decoded.normalizedAddress, "fe80::17")

        let sameAddressOnAnotherInterface = IOSPhoneControlServiceAddress(
            family: "ipv6",
            normalizedAddress: "fe80::17"
        )
        XCTAssertTrue(IOSPhoneControlServiceAddressCodec.matches(decoded, localAddresses: [sameAddressOnAnotherInterface]))
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

    private func record(endpoints: [String]) -> IOSPhoneControlServiceRecord {
        IOSPhoneControlServiceRecord(
            type: IOSPhoneControlServiceInspection.serviceType,
            host: "iPhone.local.",
            port: IOSPhoneControlServiceInspection.remotePairingPort,
            addressFamilies: ["ipv4"],
            localAddressMatch: true,
            identity: .possibleSelf,
            localIPv4Endpoints: endpoints
        )
    }
}
