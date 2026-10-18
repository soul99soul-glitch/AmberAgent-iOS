import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum IOSWebMountURLPolicyError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentialsNotAllowed
    case privateHostNotAllowed(String)
    case hostResolutionFailed(String)
    case resolvedHostNotPublic(String)
    case fakeIPPublicDNSFailed(String)
    case navigationTargetNotVerified(String)
    case hostNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .unsupportedScheme(let scheme):
            "Unsupported URL scheme: \(scheme)"
        case .missingHost:
            "URL host is missing"
        case .embeddedCredentialsNotAllowed:
            "Embedded URL credentials are not allowed"
        case .privateHostNotAllowed(let host):
            "Local, loopback, link-local, and private hosts are not allowed: \(host)"
        case .hostResolutionFailed(let host):
            "DNS resolution failed or returned no addresses for: \(host). Check DNS and VPN/proxy settings. Navigation to this host was blocked."
        case .resolvedHostNotPublic(let host):
            "DNS returned a non-public or reserved address for: \(host). Fake-IP compatibility requires HTTPS, standard 198.18.0.0/15 answers without other private addresses, and successful public DNS verification."
        case .fakeIPPublicDNSFailed(let host):
            "VPN Fake-IP was detected, but encrypted public DNS verification failed for: \(host). Navigation was blocked; check network access to the public DNS resolver."
        case .navigationTargetNotVerified(let host):
            "Navigation target was not verified before commit: \(host)"
        case .hostNotAllowed(let host):
            "Host is not in the WebMount allowlist: \(host)"
        }
    }

    var errorCode: String {
        switch self {
        case .invalidURL: "invalid_url"
        case .unsupportedScheme: "unsupported_scheme"
        case .missingHost: "missing_host"
        case .embeddedCredentialsNotAllowed: "embedded_credentials_not_allowed"
        case .privateHostNotAllowed: "private_host_not_allowed"
        case .hostResolutionFailed: "dns_resolution_failed"
        case .resolvedHostNotPublic: "dns_non_public_address"
        case .fakeIPPublicDNSFailed: "fake_ip_public_dns_failed"
        case .navigationTargetNotVerified: "navigation_target_not_verified"
        case .hostNotAllowed: "host_not_allowed"
        }
    }
}

typealias IOSWebMountHostResolver = @Sendable (String) throws -> [String]
typealias IOSWebMountPublicHostResolver = @Sendable (String) async throws -> [String]

struct IOSWebMountURLPolicy {
    let allowedSchemes: Set<String>
    let allowedHosts: Set<String>
    private(set) var allowUnlistedHosts: Bool
    private(set) var allowFakeIPFallback: Bool
    private let resolvePublicHost: IOSWebMountPublicHostResolver

    @MainActor
    init(
        settings: IOSWebMountSettings,
        extraAllowedHosts: [String] = [],
        allowUnlistedHosts: Bool = false,
        allowFakeIPFallback: Bool = false,
        resolvePublicHost: @escaping IOSWebMountPublicHostResolver = IOSWebMountPublicDNS.resolve
    ) {
        self.allowedSchemes = Set(settings.allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = Set(settings.allowedHosts.map { $0.lowercased() })
            .union(extraAllowedHosts.compactMap(Self.normalizedHost))
        self.allowUnlistedHosts = allowUnlistedHosts
        self.allowFakeIPFallback = allowFakeIPFallback
        self.resolvePublicHost = resolvePublicHost
    }

    func allowingPublicUserNavigation() -> Self {
        var policy = self
        policy.allowUnlistedHosts = true
        policy.allowFakeIPFallback = true
        return policy
    }

    func validate(_ rawURL: String, site: IOSWebMountSite? = nil) -> Result<URL, IOSWebMountURLPolicyError> {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let components = URLComponents(string: trimmedURL),
              let scheme = url.scheme?.lowercased() else {
            return .failure(.invalidURL)
        }
        guard allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = Self.normalizedHost(url.host) else {
            return .failure(.missingHost)
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.embeddedCredentialsNotAllowed)
        }
        if allowUnlistedHosts {
            guard IOSPublicURLPolicy.publicHostAllowed(host) else {
                return .failure(.privateHostNotAllowed(host))
            }
            return .success(url)
        }
        let hosts = allowedHosts.union(site?.allowedHosts.compactMap(Self.normalizedHost) ?? [])
        guard Self.host(host, matchesAnyOf: Array(hosts)) else {
            return .failure(.hostNotAllowed(host))
        }
        return .success(url)
    }

    func validateResolvedPublicHost(
        _ rawURL: String,
        site: IOSWebMountSite? = nil,
        resolveHost: @escaping IOSWebMountHostResolver
    ) async -> Result<URL, IOSWebMountURLPolicyError> {
        switch validate(rawURL, site: site) {
        case .failure(let error):
            return .failure(error)
        case .success(let url):
            guard allowUnlistedHosts, let host = Self.normalizedHost(url.host) else {
                return .success(url)
            }
            // Auto-approval expands access to unlisted hosts; it must preserve
            // the existing allowlist path for registered sites behind proxy DNS.
            let registeredHosts = allowedHosts.union(site?.allowedHosts.compactMap(Self.normalizedHost) ?? [])
            if Self.host(host, matchesAnyOf: Array(registeredHosts)) {
                return .success(url)
            }
            do {
                let addresses = try await Task.detached(priority: .userInitiated) {
                    try resolveHost(host)
                }.value
                guard !addresses.isEmpty else {
                    return .failure(.hostResolutionFailed(host))
                }
                if addresses.allSatisfy(Self.isPublicAddress) {
                    return .success(url)
                }
                // Fake-IP is a VPN routing token, not evidence of a public destination.
                // In the existing high-risk preflight model, validate HTTPS hostnames
                // independently and continue trusting the user's VPN hostname routing.
                // This is not socket/IP pinning; never use it for plaintext HTTP.
                guard allowFakeIPFallback, url.scheme?.lowercased() == "https",
                      addresses.contains(where: Self.isStandardFakeIPAddress),
                      addresses.allSatisfy({ Self.isStandardFakeIPAddress($0) || Self.isPublicAddress($0) }) else {
                    return .failure(.resolvedHostNotPublic(host))
                }
                do {
                    let publicAddresses = try await resolvePublicHost(host)
                    guard !publicAddresses.isEmpty, publicAddresses.allSatisfy(Self.isPublicAddress) else {
                        return .failure(.fakeIPPublicDNSFailed(host))
                    }
                    return .success(url)
                } catch {
                    return .failure(.fakeIPPublicDNSFailed(host))
                }
            } catch {
                return .failure(.hostResolutionFailed(host))
            }
        }
    }

    private static func isPublicAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return (inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1)
            && IOSPublicURLPolicy.publicHostAllowed(value)
    }

    private static func isStandardFakeIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, value, &ipv4) == 1 else { return false }
        return UInt32(bigEndian: ipv4.s_addr) & 0xfffe0000 == 0xc6120000
    }

    static func normalizedHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func host(_ rawHost: String?, matchesAnyOf allowedHosts: [String]) -> Bool {
        guard let host = normalizedHost(rawHost) else { return false }
        return allowedHosts.compactMap(normalizedHost).contains { allowed in
            host == allowed ||
                (host.hasPrefix("www.") && String(host.dropFirst(4)) == allowed) ||
                (allowed.hasPrefix("www.") && String(allowed.dropFirst(4)) == host)
        }
    }
}

