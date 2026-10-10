import Foundation
import Network
import XCTest
@testable import iosApp

final class IOSPhoneControlSelfDiscoveryTests: XCTestCase {
    func testNativeAdvertisementMatchesContractAndHasFreshIdentity() throws {
        let first = try IOSPhoneControlSelfDiscoveryInfo.generate()
        let second = try IOSPhoneControlSelfDiscoveryInfo.generate()
        XCTAssertNotEqual(first.service_identifier, second.service_identifier)
        XCTAssertEqual(first.txt_records["identifier"], first.service_identifier)
        XCTAssertEqual(Data(base64Encoded: first.txt_records["authTag"] ?? "")?.count, 6)
    }

    func testInvalidAdvertisementCannotBePublished() throws {
        let valid = try IOSPhoneControlSelfDiscoveryInfo.generate()
        for replacement in ["identifier": "mismatch", "ver": "19", "authTag": "bad", "model": "iPhone"] {
            var fields = valid.txt_records
            fields[replacement.key] = replacement.value
            let data = try JSONSerialization.data(withJSONObject: ["service_identifier": valid.service_identifier, "txt_records": fields])
            XCTAssertThrowsError(try IOSPhoneControlSelfDiscoveryInfo.decode(data))
        }
        XCTAssertThrowsError(try IOSPhoneControlSelfDiscoveryInfo.decode(Data(repeating: 0, count: 2_049)))
    }

    func testInboundPeerIsNeverReportedAsLocalAndNamesAreUnknown() throws {
        let local: Set<IOSPhoneControlServiceAddress> = [.init(family: "ipv4", normalizedAddress: "192.0.2.17")]
        XCTAssertEqual(IOSPhoneControlSelfDiscoveryInfo.localMatch(.hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.0.2.17"))), port: 123), addresses: local), true)
        XCTAssertEqual(IOSPhoneControlSelfDiscoveryInfo.localMatch(.hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.0.2.18"))), port: 123), addresses: local), false)
        XCTAssertNil(IOSPhoneControlSelfDiscoveryInfo.localMatch(.hostPort(host: .name("phone.local", nil), port: 123), addresses: local))
    }

    @MainActor
    func testCancelledOldStartCannotFinishNewDiscovery() async throws {
        let owner = IOSPhoneControlSelfDiscovery()
        defer { owner.cancel() }
        let old = Task { await owner.start() }
        await Task.yield()
        owner.cancel()
        await owner.start()
        await old.value
        XCTAssertTrue(owner.isRunning)
        owner.cancel()
        owner.cancel()
        XCTAssertFalse(owner.isRunning)
    }
}
