import CryptoKit
import Foundation
import Security

/// C3 §2.1 pairing payload. `amber-cli pair` on the cloud host prints the same
/// `amber://gateway/pair?p=` deep link the embedded Mac gateway uses; here the Mac is the client.
struct DesktopCloudPairingPayload: Codable, Equatable, Sendable {
    var v: Int
    var id: String
    var name: String
    var addrs: [String]
    var port: Int
    /// base64 SHA-256 of the cloud certificate's SubjectPublicKeyInfo.
    var fp: String
    var s: String

    static let maximumLinkLength = 4_096

    /// Accepts the full link (pasted, surrounding whitespace allowed) or a bare `p` value.
    static func parse(_ text: String) -> DesktopCloudPairingPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLinkLength else { return nil }
        let encoded = URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "p" })?.value ?? trimmed
        guard let data = Data(base64URLEncoded: encoded),
              let payload = try? JSONDecoder().decode(DesktopCloudPairingPayload.self, from: data),
              payload.v == 1, !payload.addrs.isEmpty, (1...65_535).contains(payload.port),
              !payload.fp.isEmpty, !payload.s.isEmpty
        else { return nil }
        return payload
    }
}

/// Non-secret part of a cloud pairing, persisted in UserDefaults. The device token lives in the Keychain.
struct DesktopCloudConnection: Codable, Equatable, Sendable {
    var gatewayId: String
    var name: String
    var addrs: [String]
    var port: Int
    var fingerprint: String
    var deviceId: String
}

/// `/v1/status` fields this client uses; the cloud may send more (sessions, health) which we ignore.
struct DesktopCloudStatus: Decodable, Equatable, Sendable {
    struct Gateway: Decodable, Equatable, Sendable { var id: String; var name: String }
    struct Device: Decodable, Equatable, Sendable { var id: String; var name: String }
    var gateway: Gateway
    var device: Device
    var serverTime: Date?
}

enum DesktopCloudError: LocalizedError, Equatable {
    case unreachable
    /// The cloud answered with a different certificate than the one pinned at pairing.
    case certificateMismatch
    case unauthorized
    /// HTTP 409: a config update raced another writer; the caller keeps its draft and re-reads.
    case conflict(String)
    /// HTTP 410: the signed envelope outlived its window; sealing a fresh one and retrying is safe.
    case envelopeExpired
    /// The import public key changed versus the kid pinned for this gateway; re-pair to re-trust.
    case importKeyChanged
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "无法连接云端主机：确认云端 amberd 已启动且网络可达（Tailscale 或公网地址）"
        case .certificateMismatch:
            "云端的证书与配对时不一致（可能重装过 amberd），请取消配对后重新粘贴链接"
        case .unauthorized:
            "此设备已在云端被吊销，请重新配对"
        case .conflict(let message):
            message
        case .envelopeExpired:
            "配置信封已过期，请重试"
        case .importKeyChanged:
            "云端导入公钥与配对时固定的不一致，请取消配对后重新配对再继续"
        case .server(let message):
            message
        case .invalidResponse:
            "云端返回了无法识别的数据"
        }
    }
}

/// Trust is the SPKI SHA-256 from the pairing link, never the system trust store (the certificate is
/// self-signed). Pinning the key rather than an address keeps working when the host's IP changes.
final class DesktopCloudPinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String

    /// DER prefix of an EC P-256 SubjectPublicKeyInfo; followed by the 65-byte uncompressed point.
    private static let p256SPKIPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              Self.spkiFingerprint(of: leaf) == fingerprint
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func spkiFingerprint(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              raw.count == 65 else { return nil }
        return Data(SHA256.hash(data: Data(p256SPKIPrefix) + raw)).base64EncodedString()
    }
}

/// One HTTPS client per cloud host. Candidate addresses are tried in order; the first that answers
/// is remembered for the next call. Separate from the local DesktopGateway server slot.
actor DesktopCloudClient {
    private let addrs: [String]
    private let port: Int
    private let token: String?
    private let session: URLSession
    private let slowSession: URLSession
    private var preferredAddress: String?

    init(addrs: [String], port: Int, fingerprint: String, token: String?) {
        self.addrs = addrs
        self.port = port
        self.token = token
        func makeSession(timeout: TimeInterval) -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration, delegate: DesktopCloudPinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
        }
        session = makeSession(timeout: 5)
        slowSession = makeSession(timeout: 25)
    }

    deinit {
        session.invalidateAndCancel()
        slowSession.invalidateAndCancel()
    }

    struct PairResponse: Decodable, Sendable {
        var deviceId: String
        var token: String
        var gatewayId: String
        var gatewayName: String
    }

    func pair(secret: String, deviceName: String) async throws -> PairResponse {
        try decode(await send("POST", "/v1/pair", body: ["secret": secret, "platform": "macos", "deviceName": deviceName]))
    }

    func status() async throws -> DesktopCloudStatus {
        try decode(await send("GET", "/v1/status"))
    }

    func unpair() async throws {
        _ = try await send("POST", "/v1/unpair")
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DesktopCloudError.invalidResponse
        }
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: [String: Any]? = nil, slow: Bool = false) async throws -> Data {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let ordered = preferredAddress.map { [$0] + addrs.filter { $0 != preferredAddress } } ?? addrs
        var sawPinMismatch = false
        for address in ordered {
            guard let url = URL(string: "https://\(Self.hostLiteral(address)):\(port)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await (slow ? slowSession : session).data(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // The pinning delegate cancels the challenge on mismatch, which surfaces as `.cancelled`.
                if (error as? URLError)?.code == .cancelled { sawPinMismatch = true }
                continue
            }
            preferredAddress = address
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let mapped = Self.responseError(status: status, data: data) { throw mapped }
            return data
        }
        throw sawPinMismatch ? DesktopCloudError.certificateMismatch : DesktopCloudError.unreachable
    }

    /// Maps a completed HTTP response to an error, or nil on 2xx. Pure so tests can cover every code.
    static func responseError(status: Int, data: Data) -> DesktopCloudError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch status {
        case 401: return .unauthorized
        case 409: return .conflict(message ?? "云端配置已被其它来源更新，请重新读取后再保存")
        case 410: return .envelopeExpired
        default: return .server(message ?? "HTTP \(status)")
        }
    }

    private static func hostLiteral(_ address: String) -> String {
        address.contains(":") ? "[\(address)]" : address
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
