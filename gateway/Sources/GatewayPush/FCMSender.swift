import Foundation
import Security

/// Firebase Cloud Messaging HTTP v1. Auth is the service-account OAuth flow: an RS256 JWT is exchanged at
/// `token_uri` for a one-hour access token, which is cached.
public actor FCMSender {
    public static let api = URL(string: "https://fcm.googleapis.com")!
    static let scope = "https://www.googleapis.com/auth/firebase.messaging"
    /// Must match the channel the Android app creates.
    static let channelId = "mac_gateway"

    let credentials: FCMCredentials
    let session: URLSession
    let apiBase: URL
    private var accessToken: (value: String, expiresAt: Date)?

    public init(credentials: FCMCredentials, session: URLSession = .shared, apiBase: URL = FCMSender.api) {
        self.credentials = credentials
        self.session = session
        self.apiBase = apiBase
    }

    public func send(_ message: PushMessage, to deviceToken: String) async -> DeliveryResult {
        let bearer: String
        do {
            bearer = try await oauthToken()
        } catch {
            return .failed("FCM 授权失败: \(error)")
        }
        var request = URLRequest(url: apiBase.appendingPathComponent("v1/projects/\(credentials.projectId)/messages:send"))
        request.httpMethod = "POST"
        request.timeoutInterval = pushRequestTimeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.payload(message, token: deviceToken), options: [.sortedKeys])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .delivered }
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let code = (error?["details"] as? [[String: Any]])?.compactMap { $0["errorCode"] as? String }.first
                ?? error?["status"] as? String ?? "HTTP \(status)"
            if code == "UNREGISTERED" { return .invalidToken(code) }
            if status == 401 { accessToken = nil }
            return .failed("FCM \(status) \(code)")
        } catch {
            return .failed("FCM 请求失败: \(error.localizedDescription)")
        }
    }

    /// Notification message (the system shows it even if the app is killed); `tag` makes a newer state of
    /// the same task replace the older one.
    static func payload(_ m: PushMessage, token: String) -> [String: Any] {
        ["message": [
            "token": token,
            "notification": ["title": m.title, "body": m.body],
            "android": [
                "priority": "HIGH",
                "notification": ["channel_id": channelId, "tag": m.threadId],
            ],
        ]]
    }

    func oauthToken(now: Date = Date()) async throws -> String {
        if let cached = accessToken, now < cached.expiresAt { return cached.value }
        let key = try JWT.rsaPrivateKey(pem: credentials.privateKeyPEM)
        let iat = Int(now.timeIntervalSince1970)
        let assertion = try JWT.rsa(
            header: ["alg": "RS256", "typ": "JWT"],
            claims: ["iss": credentials.clientEmail, "scope": Self.scope, "aud": credentials.tokenURI, "iat": iat, "exp": iat + 3600],
            key: key, algorithm: .rsaSignatureMessagePKCS1v15SHA256
        )
        guard let url = URL(string: credentials.tokenURI) else { throw CredentialError.invalid("token_uri 非法: \(credentials.tokenURI)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = pushRequestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, response) = try await session.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = json?["access_token"] as? String else {
            throw CredentialError.invalid("OAuth \((response as? HTTPURLResponse)?.statusCode ?? 0) \(json?["error_description"] ?? json?["error"] ?? "")")
        }
        let lifetime = (json?["expires_in"] as? Double) ?? 3600
        // Refresh a minute early so a push never carries a token that expires in flight.
        accessToken = (token, now.addingTimeInterval(lifetime - 60))
        return token
    }
}
