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
