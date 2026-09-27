import CryptoKit
import Foundation
import Security

/// Contents of the `amber-gateway pair` QR code / `amber://gateway/pair?p=` link.
struct MacGatewayPairingPayload: Codable, Equatable, Sendable {
    var v: Int
    var id: String
    var name: String
    var addrs: [String]
    var port: Int
    /// base64 SHA-256 of the gateway certificate's SubjectPublicKeyInfo.
    var fp: String
    var s: String

    static let maximumLinkLength = 4_096

    /// Accepts the full link (scanned or pasted, surrounding whitespace allowed) or a bare `p` value.
    static func parse(_ text: String) -> MacGatewayPairingPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLinkLength else { return nil }
        let encoded = URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "p" })?.value ?? trimmed
        guard let data = Data(base64URLEncoded: encoded),
              let payload = try? JSONDecoder().decode(MacGatewayPairingPayload.self, from: data),
              payload.v == 1, !payload.addrs.isEmpty, (1...65_535).contains(payload.port),
              !payload.fp.isEmpty, !payload.s.isEmpty
        else { return nil }
        return payload
    }
}

/// Non-secret part of a pairing, persisted in UserDefaults. The device token lives in the Keychain.
struct MacGatewayConnection: Codable, Equatable, Sendable {
    var gatewayId: String
    var name: String
    var addrs: [String]
    var port: Int
    var fingerprint: String
    var deviceId: String
}

struct MacGatewayStatus: Decodable, Equatable, Sendable {
    struct Gateway: Decodable, Equatable, Sendable { var id: String; var name: String }
    struct Device: Decodable, Equatable, Sendable { var id: String; var name: String; var pushRegistered: Bool }
    struct Health: Decodable, Equatable, Sendable {
        var sampledAt: Date
        var diskFreeBytes: Int64?
        var batteryPercent: Int?
        var onBattery: Bool?
        var memoryPressure: String
        var thermal: String
    }
    struct Session: Decodable, Equatable, Sendable, Identifiable {
        var key: String
        var agent: String
        var subject: String
        var origin: String
        var state: String
        var waitReason: String?
        var abnormal: Bool
        var monitored: Bool
        var updatedAt: Date
        var id: String { key }
    }

    var gateway: Gateway
    var device: Device
    var serverTime: Date
    var health: Health?
    var sessions: [Session]
}

enum MacGatewayError: LocalizedError, Equatable {
    case unreachable
    /// The Mac answered with a different certificate than the one pinned at pairing.
    case certificateMismatch
    case unauthorized
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            IOSAppLocalization.string("无法连接 Mac：确认手机与 Mac 在同一局域网或 Tailscale 网络，且 Mac 未睡眠", defaultValue: "无法连接 Mac：确认手机与 Mac 在同一局域网或 Tailscale 网络，且 Mac 未睡眠")
        case .certificateMismatch:
            IOSAppLocalization.string("Mac 的证书与配对时不一致（可能重装过 amber-gateway），请取消配对后重新扫码", defaultValue: "Mac 的证书与配对时不一致（可能重装过 amber-gateway），请取消配对后重新扫码")
        case .unauthorized:
            IOSAppLocalization.string("此设备已在 Mac 上被吊销，请重新配对", defaultValue: "此设备已在 Mac 上被吊销，请重新配对")
        case .server(let message):
            message
        case .invalidResponse:
            IOSAppLocalization.string("Mac Gateway 返回了无法识别的数据", defaultValue: "Mac Gateway 返回了无法识别的数据")
        }
    }
}

/// Trust is the SPKI SHA-256 from the QR code, never the system trust store (the certificate is
/// self-signed). Pinning the key rather than an address keeps working when the Mac's IP changes.
final class MacGatewayPinningDelegate: NSObject, URLSessionDelegate, Sendable {
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

/// One HTTPS client per gateway. Candidate addresses are tried in order; the first that answers is
/// remembered for the next call.
actor MacGatewayClient {
    private let addrs: [String]
    private let port: Int
    private let token: String?
    private let session: URLSession
    /// test-push waits on APNs inside the request; the Mac answers within 20 s, so a short timeout would
    /// retry the next address and send the push twice.
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
            return URLSession(configuration: configuration, delegate: MacGatewayPinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
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
        try decode(await send("POST", "/v1/pair", body: ["secret": secret, "platform": "ios", "deviceName": deviceName]))
    }

    func status() async throws -> MacGatewayStatus {
        try decode(await send("GET", "/v1/status"))
    }

    func setMonitored(taskKey: String, monitored: Bool) async throws {
        let encoded = taskKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? taskKey
        _ = try await send("POST", "/v1/tasks/\(encoded)/monitor", body: ["monitored": monitored])
    }

    func registerPushToken(_ token: String, environment: String) async throws {
        _ = try await send("POST", "/v1/push-token", body: ["token": token, "platform": "ios", "environment": environment])
    }

    func testPush() async throws {
        _ = try await send("POST", "/v1/test-push", slow: true)
    }

    func unpair() async throws {
        _ = try await send("POST", "/v1/unpair")
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MacGatewayError.invalidResponse
        }
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, slow: Bool = false) async throws -> Data {
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
            switch status {
            case 200..<300:
                return data
            case 401:
                throw MacGatewayError.unauthorized
            default:
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw MacGatewayError.server(message ?? "HTTP \(status)")
            }
        }
        throw sawPinMismatch ? MacGatewayError.certificateMismatch : MacGatewayError.unreachable
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
