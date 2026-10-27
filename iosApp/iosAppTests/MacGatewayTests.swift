import Foundation
import Security
import Testing
@testable import iosApp

@Suite("Mac Gateway")
struct MacGatewayTests {
    private static let payloadJSON = #"{"v":1,"id":"gw-1","name":"Studio Mac","addrs":["studio.local","192.168.1.20"],"port":47821,"fp":"E1koSGeJkiwpjjeThRw6ApEq2SvdvsQLpfEav0yC6Iw=","s":"secret_-1"}"#

    private static var encodedPayload: String {
        Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func parsesPairingLinkAndBareValue() throws {
        let link = "  amber://gateway/pair?p=\(Self.encodedPayload)\n"
        let payload = try #require(MacGatewayPairingPayload.parse(link))
        #expect(payload.name == "Studio Mac")
        #expect(payload.addrs == ["studio.local", "192.168.1.20"])
        #expect(payload.port == 47821)
        #expect(payload.s == "secret_-1")
        #expect(MacGatewayPairingPayload.parse(Self.encodedPayload) == payload)
    }

    @Test func rejectsMalformedPayloads() {
        #expect(MacGatewayPairingPayload.parse("") == nil)
        #expect(MacGatewayPairingPayload.parse("amber://gateway/pair?p=not-json") == nil)
        let wrongVersion = Data(Self.payloadJSON.replacingOccurrences(of: #""v":1"#, with: #""v":2"#).utf8).base64EncodedString()
        #expect(MacGatewayPairingPayload.parse(wrongVersion) == nil)
        let noAddress = Data(Self.payloadJSON.replacingOccurrences(of: #"["studio.local","192.168.1.20"]"#, with: "[]").utf8).base64EncodedString()
        #expect(MacGatewayPairingPayload.parse(noAddress) == nil)
    }

    /// Expected value from `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`,
    /// the same computation `amber-gateway` prints next to the QR code.
    @Test func spkiFingerprintMatchesOpenSSL() throws {
        let der = try #require(Data(base64Encoded: "MIIBDDCBtAIJAMN/Mwv8flerMAoGCCqGSM49BAMCMA8xDTALBgNVBAMMBHRlc3QwHhcNMjYwOTI3MDgxNTQyWhcNMzYwOTI0MDgxNTQyWjAPMQ0wCwYDVQQDDAR0ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtTyzbJf2Lqbe6fzit0tZ0xqhGOURe8QYdiII4wJoCeGsc8IoQlZmHNwODZnE794HYpLN7JYkX3LI6cTzsqwewzAKBggqhkjOPQQDAgNHADBEAiA/beSwfzzuB7jNcmn8goG4gV0HW5GxSHluQ81VTdrRqgIgWx8s9aOv82hBH0+QqudgrUnE89gAGA/lm4bsOaFQ9EE="))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(MacGatewayPinningDelegate.spkiFingerprint(of: certificate) == "E1koSGeJkiwpjjeThRw6ApEq2SvdvsQLpfEav0yC6Iw=")
    }

    @Test func statusDecodesAmberPendingApproval() throws {
        let json = #"{"gateway":{"id":"g","name":"Mac"},"device":{"id":"d","name":"iPhone","pushRegistered":true},"serverTime":1800000000,"sessions":[{"key":"amber:r1","agent":"amber","subject":"每日汇总","origin":"headless","state":"waiting","waitReason":"permission","abnormal":false,"monitored":true,"updatedAt":1800000000,"pendingApproval":{"toolCallId":"c1","tool":"workspace_file_write","detail":"path a.txt","highRisk":false}},{"key":"claude:s","agent":"claude","subject":"p","origin":"interactive","state":"running","abnormal":false,"monitored":true,"updatedAt":1800000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let status = try decoder.decode(MacGatewayStatus.self, from: Data(json.utf8))
        #expect(status.sessions[0].pendingApproval?.toolCallId == "c1")
        #expect(status.sessions[0].pendingApproval?.highRisk == false)
        #expect(status.sessions[1].pendingApproval == nil, "older gateways and agent sessions omit the field")
    }

    @Test func gatewayPairDeepLinkRoundTrips() throws {
        let url = try #require(URL(string: "amber-test://gateway/pair?p=\(Self.encodedPayload)"))
        let destination = try #require(IOSAppDeepLink.parse(url, expectedScheme: "amber-test"))
        #expect(destination == .gatewayPair(payload: Self.encodedPayload))
        let rebuilt = try #require(IOSAppDeepLink.url(for: destination, scheme: "amber-test"))
        #expect(IOSAppDeepLink.parse(rebuilt, expectedScheme: "amber-test") == destination)
    }

    @Test func gatewayPairDeepLinkRejectsExtraOrUnsafeQuery() throws {
        for text in [
            "amber-test://gateway/pair",
            "amber-test://gateway/pair?p=abc&x=1",
            "amber-test://gateway/pair?q=abc",
            "amber-test://gateway/pair?p=a%2Fb",
            "amber-test://gateway/other?p=abc",
        ] {
            #expect(IOSAppDeepLink.parse(try #require(URL(string: text)), expectedScheme: "amber-test") == nil, "\(text)")
        }
    }
}
