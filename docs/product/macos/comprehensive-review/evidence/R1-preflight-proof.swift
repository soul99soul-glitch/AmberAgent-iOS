import Foundation
private enum DesktopPublicSearchURL {
    static func validate(_ url: URL) async throws -> URL {
        try await Task.detached {
            let value = try IOSPublicURLPolicy.allowedPublicHTTPURL(from: url.absoluteString)
            guard let host = value.host else { throw IOSPublicURLPolicyError.invalidURL }
            _ = try IOSPublicURLPolicy.resolveIPAddresses(host)
            return value
        }.value
    }
}


@main struct AuditSearchProof {
 static func main() async {
  do {
   let url = URL(string: "http://broadcasthost/")!
   let addresses = try IOSPublicURLPolicy.resolveIPAddresses(url.host!)
   print("DNS addresses:", addresses)
   print("Expected policy:", addresses.allSatisfy(IOSPublicURLPolicy.publicHostAllowed))
   _ = try await DesktopPublicSearchURL.validate(url)
   print("ACTUAL MAC PREFLIGHT: ACCEPTED")
  } catch { print("ERROR:", error) }
 }
}
