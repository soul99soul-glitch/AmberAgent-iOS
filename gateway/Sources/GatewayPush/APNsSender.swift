import CryptoKit
import Foundation
import GatewayCore

public struct PushMessage: Sendable, Equatable {
    public var title: String
    public var body: String
    /// Groups notifications per task on the lock screen.
    public var threadId: String
    public var timeSensitive: Bool
    public var isTest: Bool
    /// Notification category that offers in-place actions (Amber approvals), and keys the app needs to act.
    public var category: String?
    public var userInfo: [String: String]

    public static let amberApprovalCategory = "amber.gateway.approval"
    public static let amberDeepLink = "amber://settings/mac-gateway"

    public init(title: String, body: String, threadId: String, timeSensitive: Bool, isTest: Bool = false,
                category: String? = nil, userInfo: [String: String] = [:]) {
        self.title = title
        self.body = body
        self.threadId = threadId
        self.timeSensitive = timeSensitive
        self.isTest = isTest
        self.category = category
        self.userInfo = userInfo
    }

    public init(_ intent: PushIntent, gatewayName: String) {
        let text = PushContent.render(intent, gatewayName: gatewayName)
        var info: [String: String] = [:]
        var category: String?
        if intent.agent == .amber, let key = intent.sessionKey {
            info = ["deepLink": Self.amberDeepLink, "sessionKey": key]
            // High-risk calls are approved on the Mac after reading the full call, never from a lock screen.
            if let call = intent.toolCallId, intent.highRisk == false {
                info["toolCallId"] = call
                category = Self.amberApprovalCategory
            }
        }
        self.init(title: text.title, body: text.body, threadId: intent.sessionKey ?? intent.kind.rawValue,
                  timeSensitive: intent.level == .timeSensitive, isTest: intent.kind == .test, category: category, userInfo: info)
    }
}

/// Per provider request. `/v1/test-push` waits on delivery inside one HTTP connection, so FCM's
/// OAuth exchange + send (2 × this) must finish before `HTTPServer.connectionTimeout`.
let pushRequestTimeout: TimeInterval = 8

public enum DeliveryResult: Sendable, Equatable {
    case delivered
    /// The service says the device token is gone; the caller should forget it.
    case invalidToken(String)
    case failed(String)
}

public actor APNsSender {
    public static let production = URL(string: "https://api.push.apple.com")!
    public static let sandbox = URL(string: "https://api.sandbox.push.apple.com")!
    /// Apple rejects provider tokens older than an hour and throttles refreshes more often than every 20 min.
    static let tokenLifetime: TimeInterval = 50 * 60

    let credentials: APNsCredentials
    let session: URLSession
    let hosts: [PushEnvironment: URL]
    private var cachedToken: (value: String, issuedAt: Date)?

    public init(credentials: APNsCredentials, session: URLSession = .shared,
                hosts: [PushEnvironment: URL] = [.production: APNsSender.production, .sandbox: APNsSender.sandbox]) {
        self.credentials = credentials
        self.session = session
        self.hosts = hosts
    }

    public func send(_ message: PushMessage, to deviceToken: String, environment: PushEnvironment) async -> DeliveryResult {
        let jwt: String
        do {
            jwt = try providerToken()
        } catch {
            return .failed("\(error)")
        }
        var request = URLRequest(url: hosts[environment]!.appendingPathComponent("3/device/\(deviceToken)"))
        request.httpMethod = "POST"
        request.timeoutInterval = pushRequestTimeout
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(credentials.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(Date().timeIntervalSince1970) + 3600), forHTTPHeaderField: "apns-expiration")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.payload(message), options: [.sortedKeys])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .delivered }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
            if status == 410 || ["BadDeviceToken", "Unregistered"].contains(reason) {
                return .invalidToken(reason)
            }
            if reason == "DeviceTokenNotForTopic" {
                return .failed("APNs \(status) \(reason)：topic 与 App 的 Bundle ID 不一致，检查 creds import apns --topic")
            }
            if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" { cachedToken = nil }
            return .failed("APNs \(status) \(reason)")
        } catch {
            return .failed("APNs 请求失败: \(error.localizedDescription)")
        }
    }

    static func payload(_ m: PushMessage) -> [String: Any] {
        var aps: [String: Any] = [
            "alert": ["title": m.title, "body": m.body],
            "sound": "default",
            "thread-id": m.threadId,
            "interruption-level": m.timeSensitive ? "time-sensitive" : "active",
        ]
        if let category = m.category { aps["category"] = category }
        var payload: [String: Any] = ["aps": aps]
        for (key, value) in m.userInfo { payload[key] = value }
        return payload
    }

    func providerToken(now: Date = Date()) throws -> String {
        if let cached = cachedToken, now.timeIntervalSince(cached.issuedAt) < Self.tokenLifetime { return cached.value }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw JWT.Failure.badKey(".p8 不是 P-256 私钥: \(error)")
        }
        let token = try JWT.es256(header: ["alg": "ES256", "kid": credentials.keyId],
                                  claims: ["iss": credentials.teamId, "iat": Int(now.timeIntervalSince1970)], key: key)
        cachedToken = (token, now)
        return token
    }
}
