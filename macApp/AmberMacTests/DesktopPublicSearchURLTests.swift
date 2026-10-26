import Foundation
import XCTest
@testable import AmberMac

@MainActor final class DesktopPublicSearchURLTests: XCTestCase {
    func testPublicResolvedAddressesAllowTheURLAndRemoveItsFragment() async throws {
        let url = URL(string: "https://public.example.test/article#section")!
        for addresses in [["93.184.216.34"], ["2606:4700:4700::1111"], ["93.184.216.34", "2606:4700:4700::1111"]] {
            let validated = try await DesktopPublicSearchURL.validate(url, resolveHost: { _ in addresses })
            XCTAssertEqual(validated.absoluteString, "https://public.example.test/article")
        }
    }

    func testEmptyPrivateLoopbackFakeIPAndMixedDNSAnswersAreRejected() async {
        let answers = [
            [], ["127.0.0.1"], ["10.1.2.3"], ["192.168.1.2"], ["172.16.0.1"],
            ["169.254.169.254"], ["255.255.255.255"], ["198.18.0.2", "10.1.2.3"],
            ["::1"], ["fc00::1"], ["::ffff:127.0.0.1"],
            ["93.184.216.34", "10.1.2.3"], ["2606:4700:4700::1111", "::1"]
        ]
        for addresses in answers {
            do {
                _ = try await DesktopPublicSearchURL.validate(URL(string: "https://public.example.test/")!,
                    resolveHost: { _ in addresses }, resolvePublicHost: { _ in ["93.184.216.34"] })
                XCTFail("Blocked DNS answer was accepted: \(addresses)")
            } catch {
                guard case .disallowedURL = error as? IOSPublicURLPolicyError else {
                    XCTFail("Expected a URL policy rejection for \(addresses), got \(error)"); continue
                }
            }
        }
    }

    func testFakeIPAnswerIsAcceptedOnlyWhenPublicDNSConfirmsAPublicHost() async throws {
        let url = URL(string: "https://example.com/")!
        let ok = try await DesktopPublicSearchURL.validate(url, resolveHost: { _ in ["198.18.0.78"] },
            resolvePublicHost: { _ in ["93.184.216.34"] })
        XCTAssertEqual(ok.host, "example.com")
        for publicAnswer in [["10.0.0.5"], ["127.0.0.1"], []] {
            do {
                _ = try await DesktopPublicSearchURL.validate(url, resolveHost: { _ in ["198.18.0.78"] },
                    resolvePublicHost: { _ in publicAnswer })
                XCTFail("fake-IP accepted with public answer \(publicAnswer)")
            } catch {}
        }
    }

    func testNonHTTPEmbeddedCredentialsAndLiteralPrivateHostsAreRejectedBeforeDNS() async {
        for raw in ["file:///tmp/article", "https://user:password@public.example.test/", "http://127.0.0.1/"] {
            do {
                _ = try await DesktopPublicSearchURL.validate(URL(string: raw)!, resolveHost: { _ in
                    XCTFail("Invalid URL must not reach DNS resolution")
                    return ["93.184.216.34"]
                })
                XCTFail("Invalid URL was accepted: \(raw)")
            } catch {
                XCTAssertTrue(error is IOSPublicURLPolicyError)
            }
        }
    }

    func testDNSResolutionFailureIsPropagated() async {
        enum ResolutionError: Error { case unavailable }
        do {
            _ = try await DesktopPublicSearchURL.validate(URL(string: "https://public.example.test/")!,
                resolveHost: { _ in throw ResolutionError.unavailable })
            XCTFail("Failed DNS resolution must not allow the request")
        } catch {
            XCTAssertTrue(error is ResolutionError)
        }
    }
}
