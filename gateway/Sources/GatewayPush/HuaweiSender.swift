import CryptoKit
import Foundation

/// HarmonyOS Push Kit REST v3. Auth is a service-account PS256 JWT sent directly as the bearer token
/// (HarmonyOS 5+ no longer accepts OAuth access tokens here).
public struct HuaweiSender: Sendable {
    public static let api = URL(string: "https://push-api.cloud.huawei.com")!
    static let audience = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
    static let success = "80000000"
    static let allTokensInvalid = "80300007"

    let credentials: HuaweiCredentials
    let session: URLSession
    let apiBase: URL

    public init(credentials: HuaweiCredentials, session: URLSession = .shared, apiBase: URL = HuaweiSender.api) {
        self.credentials = credentials
        self.session = session
        self.apiBase = apiBase
    }

    public func send(_ message: PushMessage, to deviceToken: String) async -> DeliveryResult {
        let bearer: String
        do {
            bearer = try jwt()
        } catch {
            return .failed("华为推送 JWT 生成失败: \(error)")
        }
        var request = URLRequest(url: apiBase.appendingPathComponent("v3/\(credentials.projectId)/messages:send"))
        request.httpMethod = "POST"
        request.timeoutInterval = pushRequestTimeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "push-type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: Self.payload(message, token: deviceToken, category: credentials.category), options: [.sortedKeys])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = json?["code"] as? String ?? "HTTP \(status)"
            if status == 200, code == Self.success { return .delivered }
            if code == Self.allTokensInvalid { return .invalidToken(code) }
            return .failed("华为推送 \(status) \(code) \(json?["msg"] as? String ?? "")")
        } catch {
            return .failed("华为推送请求失败: \(error.localizedDescription)")
        }
    }

    /// `notifyId` derived from the thread makes a newer state of the same task replace the older one.
    static func payload(_ m: PushMessage, token: String, category: String) -> [String: Any] {
        var body: [String: Any] = [
            "payload": ["notification": [
                "category": category,
                "title": m.title,
                "body": m.body,
                "clickAction": ["actionType": 0],
                "foregroundShow": true,
                "notifyId": notifyId(m.threadId),
            ]],
            "target": ["token": [token]],
        ]
        // MARKETING allows only a few messages per device per day and throttled sends still return
        // 80000000; test messages use a separate project-wide quota so a test never eats a real alert.
        if m.isTest { body["pushOptions"] = ["testMessage": true] }
        return body
    }

    static func notifyId(_ threadId: String) -> Int {
        let digest = SHA256.hash(data: Data(threadId.utf8))
        return Int(digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF)
    }

    func jwt(now: Date = Date()) throws -> String {
        let iat = Int(now.timeIntervalSince1970)
        return try JWT.rsa(
            header: ["alg": "PS256", "typ": "JWT", "kid": credentials.keyId],
            claims: ["iss": credentials.subAccount, "aud": Self.audience, "iat": iat, "exp": iat + 3600],
            key: try JWT.rsaPrivateKey(pem: credentials.privateKeyPEM),
            algorithm: .rsaSignatureMessagePSSSHA256
        )
    }
}
