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
        /// Opening words of the session's first prompt (newer gateways); a better name than the directory.
        var summary: String?
        var origin: String
        /// App hosting the session on the Mac, e.g. "Synara".
        var host: String?
        var state: String
        var waitReason: String?
        var abnormal: Bool
        var monitored: Bool
        var updatedAt: Date
        var displayTitle: String { summary ?? subject }
        /// Running or waiting; only these can still push, so only these get a push switch.
        var isOpen: Bool { state == "running" || state == "waiting" || state == "stalled" }
        /// Amber scheduled runs waiting on a tool call (answered with `decide`).
        var pendingApproval: PendingApproval?
        var id: String { key }
    }

    struct PendingApproval: Decodable, Equatable, Sendable {
        var toolCallId: String
        var tool: String
        var detail: String?
        /// High-risk calls are only approved on the Mac; the phone can still deny.
        var highRisk: Bool

        private enum CodingKeys: String, CodingKey {
            case toolCallId, tool, detail, highRisk
        }
    }

    var gateway: Gateway
    var device: Device
    var serverTime: Date
    var health: Health?
    /// Where Synara-hosted tasks are answered from outside the LAN; opened in the browser.
    var synaraURL: String?
    var sessions: [Session]
}

extension MacGatewayStatus.PendingApproval {
    /// Older gateways omit `highRisk`. Unknown risk fails closed: only the Mac may approve it then.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        tool = try container.decode(String.self, forKey: .tool)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        highRisk = try container.decodeIfPresent(Bool.self, forKey: .highRisk) ?? true
    }
}

/// An Amber scheduled task as the Mac reports it (`/v1/amber/schedules`).
struct MacGatewaySchedule: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var rule: String
    var enabled: Bool
    var running: Bool
    var paused: Bool?
    var nextRunAt: Date?
    var lastStatus: String?
    var lastRunAt: Date?
    var autoApprovesHighRisk: Bool
}

/// One card on the Mac's task board (`/v1/amber/board`). Grouped and ordered on the Mac; the phone renders it as is.
struct MacGatewayBoardItem: Decodable, Equatable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable { case schedule, run, agentSession }
    enum Column: String, Decodable, Sendable, CaseIterable { case needsYou, running, scheduled, done }
    struct Approval: Decodable, Equatable, Sendable {
        var sessionKey: String
        var toolCallId: String
        var tool: String
        var detail: String?
        /// High-risk calls are only approved on the Mac; the phone can still deny.
        var highRisk: Bool

        private enum CodingKeys: String, CodingKey {
            case sessionKey, toolCallId, tool, detail, highRisk
        }
    }

    var id: String
    var kind: Kind
    var column: Column
    var title: String
    var detail: String
    var updatedAt: Date
    var scheduleId: String?
    var nextRunAt: Date?
    var waitingForReply: Bool
    var failed: Bool
    var approval: Approval?

    /// Gateway session key of an agent session card (`session:<key>`).
    var sessionKey: String? {
        guard kind == .agentSession, id.hasPrefix("session:") else { return nil }
        return String(id.dropFirst("session:".count))
    }
}

extension MacGatewayBoardItem.Approval {
    /// Same rule as the status payload: a missing `highRisk` must not unlock remote approval.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        tool = try container.decode(String.self, forKey: .tool)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        highRisk = try container.decodeIfPresent(Bool.self, forKey: .highRisk) ?? true
    }
}

/// What the phone can set on a new task. Approval rules are Mac-only: remote tasks start with nothing auto-approved.
struct MacGatewayScheduleDraft: Equatable, Sendable {
    enum Rule: String, CaseIterable, Sendable { case daily, weekdays, weekly, interval }
    var name = ""
    var prompt = ""
    var rule = Rule.daily
    var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    /// Calendar weekdays, 1 = Sunday.
    var weekdays: Set<Int> = [2]
    var intervalMinutes = 60

    var body: [String: Any] {
        let calendar = Calendar.current
        var value: [String: Any] = ["name": name, "prompt": prompt, "rule": rule.rawValue]
        switch rule {
        case .daily, .weekdays, .weekly:
            value["hour"] = calendar.component(.hour, from: time)
            value["minute"] = calendar.component(.minute, from: time)
            if rule == .weekly { value["weekdays"] = weekdays.sorted() }
        case .interval:
            value["intervalMinutes"] = intervalMinutes
        }
        return value
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (rule != .weekly || !weekdays.isEmpty)
    }
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
            IOSAppLocalization.string("无法连接 Mac：确认 Mac 未睡眠，且网络可达（同一局域网、Tailscale 或公网地址）", defaultValue: "无法连接 Mac：确认 Mac 未睡眠，且网络可达（同一局域网、Tailscale 或公网地址）")
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

    /// Approve or deny the tool call an Amber scheduled run is waiting on. The Mac answers within ~5 s (it reports
    /// "busy" rather than going silent), so the long timeout keeps a slow answer from being re-sent to another address.
    func decide(sessionKey: String, toolCallId: String, allow: Bool) async throws {
        _ = try await send("POST", "/v1/amber/decision", body: ["sessionKey": sessionKey, "toolCallId": toolCallId, "allow": allow], slow: true)
    }

    func schedules() async throws -> [MacGatewaySchedule] {
        struct Response: Decodable { var schedules: [MacGatewaySchedule] }
        let response: Response = try decode(await send("GET", "/v1/amber/schedules", slow: true))
        return response.schedules
    }

    func board() async throws -> [MacGatewayBoardItem] {
        struct Response: Decodable { var board: [MacGatewayBoardItem] }
        let response: Response = try decode(await send("GET", "/v1/amber/board", slow: true))
        return response.board
    }

    func createSchedule(_ draft: MacGatewayScheduleDraft) async throws {
        _ = try await send("POST", "/v1/amber/schedules", body: draft.body, slow: true)
    }

    func setScheduleEnabled(id: String, enabled: Bool) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        _ = try await send("POST", "/v1/amber/schedules/\(encoded)/enabled", body: ["enabled": enabled], slow: true)
    }

    func runSchedule(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        _ = try await send("POST", "/v1/amber/schedules/\(encoded)/run", slow: true)
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
