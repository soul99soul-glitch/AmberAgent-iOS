import XCTest
@testable import iosApp

@MainActor
final class IOSWebMountFakeIPTests: XCTestCase {
    func testHTTPSFakeIPRequiresPublicDNSAndPreservesOriginalURL() async throws {
        let policy = makePolicy { host in
            XCTAssertEqual(host, "unlisted.example")
            return ["93.184.216.34", "2606:4700:4700::1111"]
        }
        let url = "https://unlisted.example/search?q=PS5#results"
        for addresses in [["198.18.0.34"], ["198.19.255.254", "2606:4700:4700::1111"]] {
            let result = await policy.validateResolvedPublicHost(url, resolveHost: { _ in addresses })
            XCTAssertEqual(try result.get().absoluteString, url)
        }
    }

    func testFakeIPCompatibilityFailsClosedOutsideItsBoundary() async throws {
        let noFallback = makePolicy { _ in
            XCTFail("This target must be rejected before public DNS is queried")
            return ["93.184.216.34"]
        }
        for (url, addresses) in [
            ("http://unlisted.example/", ["198.18.0.34"]),
            ("https://unlisted.example/", ["10.0.0.8"]),
            ("https://unlisted.example/", ["198.18.0.34", "10.0.0.8"]),
            ("https://198.18.0.34/", ["198.18.0.34"]),
            ("https://127.0.0.1/", ["127.0.0.1"])
        ] {
            let result = await noFallback.validateResolvedPublicHost(url, resolveHost: { _ in addresses })
            if case .success = result { XCTFail("Unsafe target was accepted: \(url), \(addresses)") }
        }

        for publicAnswers in [[], ["10.0.0.8"], ["93.184.216.34", "127.0.0.1"], ["not-an-ip.example"]] as [[String]] {
            let policy = makePolicy { _ in publicAnswers }
            let result = await policy.validateResolvedPublicHost(
                "https://unlisted.example/", resolveHost: { _ in ["198.18.0.34"] }
            )
            guard case .failure(let error) = result else { return XCTFail("Invalid public DNS answers accepted") }
            XCTAssertEqual(error, .fakeIPPublicDNSFailed("unlisted.example"))
        }
        let unavailable = makePolicy { _ in throw URLError(.timedOut) }
        let failed = await unavailable.validateResolvedPublicHost(
            "https://unlisted.example/", resolveHost: { _ in ["198.18.0.34"] }
        )
        guard case .failure(let error) = failed else { return XCTFail("Resolver failure must block navigation") }
        XCTAssertEqual(error.errorCode, "fake_ip_public_dns_failed")

        let strictPolicy = IOSWebMountURLPolicy(
            settings: IOSWebMountSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            allowUnlistedHosts: true,
            resolvePublicHost: { _ in XCTFail("Remote/default policy must not use local VPN compatibility"); return [] }
        )
        let strictResult = await strictPolicy.validateResolvedPublicHost(
            "https://unlisted.example/", resolveHost: { _ in ["198.18.0.34"] }
        )
        guard case .failure(let strictError) = strictResult else { return XCTFail("Strict policy accepted Fake-IP") }
        XCTAssertEqual(strictError, .resolvedHostNotPublic("unlisted.example"))
    }

    private func makePolicy(resolvePublicHost: @escaping IOSWebMountPublicHostResolver) -> IOSWebMountURLPolicy {
        let defaults = UserDefaults(suiteName: "webmount-fakeip-\(UUID().uuidString)")!
        return IOSWebMountURLPolicy(
            settings: IOSWebMountSettings(userDefaults: defaults),
            allowUnlistedHosts: true,
            allowFakeIPFallback: true,
            resolvePublicHost: resolvePublicHost
        )
    }
}
