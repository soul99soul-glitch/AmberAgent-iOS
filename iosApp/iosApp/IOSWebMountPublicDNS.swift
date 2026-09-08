import Foundation
import Darwin

/// Resolves a WebMount hostname with a fixed, encrypted public DNS service.
/// The hostname is disclosed to Google Public DNS; no URL credentials, cookies,
/// or page content are sent.
struct IOSWebMountPublicDNS {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidHost
        case transport
        case httpStatus(Int)
        case dnsStatus(Int)
        case malformedResponse
        case responseTooLarge
        case privateOrReservedAddress(String)
        case noPublicAddress

        var errorDescription: String? {
            switch self {
            case .invalidHost: "DNS host is invalid."
            case .transport: "The public DNS request failed."
            case .httpStatus(let status): "The public DNS service returned HTTP \(status)."
            case .dnsStatus(let status): "The public DNS service returned DNS status \(status)."
            case .malformedResponse: "The public DNS response is malformed."
            case .responseTooLarge: "The public DNS response is too large."
            case .privateOrReservedAddress(let address):
                "The public DNS response contains a private or reserved address: \(address)."
            case .noPublicAddress: "The public DNS response contains no public address."
            }
        }
    }

    private static let endpoint = URL(string: "https://dns.google/resolve")!
    private static let maxResponseBytes = 64 * 1024

    private struct Response: Decodable {
        let status: Int
        let truncated: Bool?
        let answers: [Answer]?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case truncated = "TC"
            case answers = "Answer"
        }
    }

    private struct Answer: Decodable {
        let type: Int
        let data: String

        enum CodingKeys: String, CodingKey {
            case type
            case data
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static func resolve(_ rawHost: String) async throws -> [String] {
        let host = try normalizedHost(rawHost)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8

        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        async let a = query(host: host, recordType: 1, session: session)
        async let aaaa = query(host: host, recordType: 28, session: session)
        let addresses = try await a + aaaa

        var unique: [String] = []
        for address in addresses where !unique.contains(address) {
            unique.append(address)
        }
        guard !unique.isEmpty else { throw Error.noPublicAddress }
        return unique
    }

    private static func query(
        host: String,
        recordType: Int,
        session: URLSession
    ) async throws -> [String] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: String(recordType)),
            URLQueryItem(name: "edns_client_subnet", value: "0.0.0.0/0")
        ]
        guard let url = components.url else { throw Error.invalidHost }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= maxResponseBytes else { throw Error.responseTooLarge }
            return try decodeResponse(
                data,
                httpStatus: (response as? HTTPURLResponse)?.statusCode ?? -1,
                recordType: recordType
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport
        }
    }

    static func decodeResponse(
        _ data: Data,
        httpStatus: Int,
        recordType: Int
    ) throws -> [String] {
        guard httpStatus == 200 else { throw Error.httpStatus(httpStatus) }
        guard recordType == 1 || recordType == 28 else { throw Error.malformedResponse }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Error.malformedResponse
        }
        guard response.status == 0 else { throw Error.dnsStatus(response.status) }
        guard response.truncated == false else { throw Error.malformedResponse }

        var addresses: [String] = []
        for answer in response.answers ?? [] {
            switch answer.type {
            case 1, 28:
                guard isAddress(answer.data, recordType: answer.type) else {
                    throw Error.malformedResponse
                }
                guard IOSSearchExecutor.publicHostAllowed(answer.data) else {
                    throw Error.privateOrReservedAddress(answer.data)
                }
                if answer.type == recordType, !addresses.contains(answer.data) {
                    addresses.append(answer.data)
                }
            default:
                // CNAME and future DNSSEC/metadata records are not addresses.
                continue
            }
        }
        return addresses
    }

    private static func normalizedHost(_ rawHost: String) throws -> String {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              !host.contains("/"), !host.contains("?"), !host.contains("#"),
              !host.contains("@"), !host.contains(":") else {
            throw Error.invalidHost
        }
        return host
    }

    private static func isAddress(_ value: String, recordType: Int) -> Bool {
        if recordType == 1 {
            var address = in_addr()
            return inet_pton(AF_INET, value, &address) == 1
        }
        var address = in6_addr()
        return inet_pton(AF_INET6, value, &address) == 1
    }
}
