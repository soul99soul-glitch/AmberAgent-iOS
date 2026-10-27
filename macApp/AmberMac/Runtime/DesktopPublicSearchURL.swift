import Foundation

enum DesktopPublicSearchURL {
    static func validate(_ url: URL,
        resolveHost: @escaping @Sendable (String) throws -> [String] = IOSPublicURLPolicy.resolveIPAddresses
    ) async throws -> URL {
        try await Task.detached {
            let value = try IOSPublicURLPolicy.allowedPublicHTTPURL(from: url.absoluteString)
            guard let host = value.host else { throw IOSPublicURLPolicyError.invalidURL }
            let addresses = try resolveHost(host)
            guard !addresses.isEmpty, addresses.allSatisfy(IOSPublicURLPolicy.publicHostAllowed) else {
                throw IOSPublicURLPolicyError.disallowedURL("host resolved to a blocked or empty address set")
            }
            return value
        }.value
    }
}
