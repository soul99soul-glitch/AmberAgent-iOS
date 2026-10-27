import Foundation

enum DesktopPublicSearchURL {
    /// Proxies in Fake-IP mode (Clash, Surge, sing-box…) answer every name with 198.18.0.0/15, which the strict
    /// policy would reject as reserved. When the system answer is Fake-IP, the host is re-checked against public
    /// DNS (same DoH resolver as iOS) and the request then goes out through the proxy as usual. Genuinely private
    /// answers (loopback, RFC1918, link-local…) are still refused.
    static func validate(_ url: URL,
        resolveHost: @escaping @Sendable (String) throws -> [String] = IOSPublicURLPolicy.resolveIPAddresses,
        resolvePublicHost: @escaping @Sendable (String) async throws -> [String] = { try await IOSWebMountPublicDNS.resolve($0) }
    ) async throws -> URL {
        let (value, host, addresses) = try await Task.detached {
            let value = try IOSPublicURLPolicy.allowedPublicHTTPURL(from: url.absoluteString)
            guard let host = value.host else { throw IOSPublicURLPolicyError.invalidURL }
            return (value, host, try resolveHost(host))
        }.value
        guard !addresses.isEmpty else { throw IOSPublicURLPolicyError.disallowedURL("host could not be resolved") }
        if addresses.allSatisfy(IOSPublicURLPolicy.publicHostAllowed) { return value }
        guard addresses.allSatisfy({ IOSPublicURLPolicy.publicHostAllowed($0) || isFakeIP($0) }) else {
            throw IOSPublicURLPolicyError.disallowedURL("host resolved to a private address")
        }
        let verified = try await resolvePublicHost(host)
        guard !verified.isEmpty, verified.allSatisfy(IOSPublicURLPolicy.publicHostAllowed) else {
            throw IOSPublicURLPolicyError.disallowedURL("fake-IP host is not public")
        }
        return value
    }

    static func isFakeIP(_ value: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return false }
        let bits = UInt32(bigEndian: address.s_addr)
        return bits >> 24 == 198 && ((bits >> 16) & 0xff == 18 || (bits >> 16) & 0xff == 19)
    }
}
