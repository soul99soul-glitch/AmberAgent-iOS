import Foundation
import Darwin

enum IOSPublicURLPolicyError: Error, Equatable {
    case missingURL
    case invalidURL
    case disallowedURL(String)
}

/// Shared strict-public URL and address policy. Verified-scrape Fake-IP
/// handling stays in its own transport preflight, outside this policy.
enum IOSPublicURLPolicy {
    static func allowedPublicHTTPURL(from rawURL: String) throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSPublicURLPolicyError.missingURL }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw IOSPublicURLPolicyError.invalidURL
        }
        if components.user != nil || components.password != nil {
            throw IOSPublicURLPolicyError.disallowedURL("embedded credentials are blocked")
        }
        guard publicHostAllowed(host) else {
            throw IOSPublicURLPolicyError.disallowedURL("local, loopback, link-local, and private hosts are blocked")
        }
        components.fragment = nil
        guard let url = components.url else { throw IOSPublicURLPolicyError.invalidURL }
        return url
    }

    static func publicHostAllowed(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if lower == "localhost" || lower == "0.0.0.0" || lower.hasSuffix(".local") {
            return false
        }
        var ipv4 = in_addr()
        if inet_aton(lower, &ipv4) == 1 {
            return publicIPv4Allowed(UInt32(bigEndian: ipv4.s_addr))
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, lower, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let mapped = bytes[12...15].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
                return publicIPv4Allowed(mapped)
            }
            // Only globally routable IPv6 unicast addresses are allowed. This
            // rejects unspecified/loopback, link-local, unique-local, multicast,
            // documentation, and transition-space addresses.
            return (bytes[0] & 0xe0) == 0x20 && !(bytes[0...3] == [0x20, 0x01, 0x0d, 0xb8])
        }
        return true
    }

    private static func publicIPv4Allowed(_ address: UInt32) -> Bool {
        let first = Int((address >> 24) & 0xff)
        let second = Int((address >> 16) & 0xff)
        let third = Int((address >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && (third == 0 || third == 2) { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        return first < 224
    }

    static func resolveIPAddresses(_ host: String) throws -> [String] {
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, nil, &result)
        guard status == 0, let first = result else {
            throw IOSPublicURLPolicyError.disallowedURL("host could not be resolved")
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            if info.ai_family == AF_INET || info.ai_family == AF_INET6,
               let address = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    addresses.append(String(cString: buffer))
                }
            }
            cursor = info.ai_next
        }
        return Array(Set(addresses))
    }

}
