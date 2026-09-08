import XCTest
@testable import iosApp

final class IOSWebMountPublicDNSTests: XCTestCase {
    func testDecodeAcceptsTypedPublicAnswersAndIgnoresCNAME() throws {
        let a = #"{"Status":0,"TC":false,"Answer":[{"name":"example.com.","type":5,"TTL":60,"data":"alias.example.net."},{"name":"example.com.","type":1,"TTL":60,"data":"93.184.216.34"}]}"#
        let aaaa = #"{"Status":0,"TC":false,"Answer":[{"name":"example.com.","type":5,"TTL":60,"data":"alias.example.net."},{"name":"example.com.","type":28,"TTL":60,"data":"2606:4700:10::6814:179a"}]}"#

        XCTAssertEqual(
            try IOSWebMountPublicDNS.decodeResponse(Data(a.utf8), httpStatus: 200, recordType: 1),
            ["93.184.216.34"]
        )
        XCTAssertEqual(
            try IOSWebMountPublicDNS.decodeResponse(Data(aaaa.utf8), httpStatus: 200, recordType: 28),
            ["2606:4700:10::6814:179a"]
        )
    }

    func testDecodeRejectsMixedPrivateAndPublicAnswers() {
        let response = #"{"Status":0,"TC":false,"Answer":[{"type":1,"TTL":60,"data":"93.184.216.34"},{"type":1,"TTL":60,"data":"192.168.1.10"}]}"#

        XCTAssertThrowsError(
            try IOSWebMountPublicDNS.decodeResponse(Data(response.utf8), httpStatus: 200, recordType: 1)
        ) { error in
            XCTAssertEqual(error as? IOSWebMountPublicDNS.Error, .privateOrReservedAddress("192.168.1.10"))
        }
    }

    func testDecodeRejectsMalformedOrFailedResponses() {
        XCTAssertThrowsError(
            try IOSWebMountPublicDNS.decodeResponse(Data("not-json".utf8), httpStatus: 200, recordType: 1)
        ) { error in
            XCTAssertEqual(error as? IOSWebMountPublicDNS.Error, .malformedResponse)
        }

        let response = #"{"Status":2,"TC":false,"Answer":[]}"#
        XCTAssertThrowsError(
            try IOSWebMountPublicDNS.decodeResponse(Data(response.utf8), httpStatus: 200, recordType: 28)
        ) { error in
            XCTAssertEqual(error as? IOSWebMountPublicDNS.Error, .dnsStatus(2))
        }

        let truncated = #"{"Status":0,"TC":true,"Answer":[{"type":1,"TTL":60,"data":"93.184.216.34"}]}"#
        XCTAssertThrowsError(
            try IOSWebMountPublicDNS.decodeResponse(Data(truncated.utf8), httpStatus: 200, recordType: 1)
        ) { error in
            XCTAssertEqual(error as? IOSWebMountPublicDNS.Error, .malformedResponse)
        }
    }
}
