import CoreImage
import CryptoKit
import Foundation
import Testing
@testable import GatewayCore
@testable import GatewayPush
@testable import GatewayTransport

/// Plain-HTTP stand-in for a push service: records requests and replies with a canned response.
final class MockPushService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mock-push")
    private var server: HTTPServer!
    private(set) var requests: [HTTPRequest] = []
    var reply: (HTTPRequest) -> HTTPResponse = { _ in HTTPResponse(status: 200) }

    init() throws {
        server = try HTTPServer(port: 0, identity: nil, queue: queue) { [unowned self] request, respond in
            requests.append(request)
            respond(reply(request))
        }
        try server.start()
    }

    deinit { server.stop() }

    var base: URL { URL(string: "http://127.0.0.1:\(server.port!)")! }
    var recorded: [HTTPRequest] { queue.sync { requests } }
}

func decodeJWT(_ jwt: String) throws -> (header: [String: Any], claims: [String: Any], signingInput: Data, signature: Data) {
    let parts = jwt.split(separator: ".").map(String.init)
    try #require(parts.count == 3)
    let header = try JSONSerialization.jsonObject(with: try #require(Data(base64URLEncoded: parts[0]))) as! [String: Any]
    let claims = try JSONSerialization.jsonObject(with: try #require(Data(base64URLEncoded: parts[1]))) as! [String: Any]
    return (header, claims, Data((parts[0] + "." + parts[1]).utf8), try #require(Data(base64URLEncoded: parts[2])))
}

/// Fresh RSA key as PKCS#1 PEM (what `JWT.rsaPrivateKey` accepts besides PKCS#8).
func makeRSAKey() throws -> (pem: String, publicKey: SecKey) {
    var error: Unmanaged<CFError>?
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    let der = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return ("-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----\n", try #require(SecKeyCopyPublicKey(key)))
}

func verifyRSA(_ jwt: (header: [String: Any], claims: [String: Any], signingInput: Data, signature: Data),
               _ publicKey: SecKey, _ algorithm: SecKeyAlgorithm) -> Bool {
    SecKeyVerifySignature(publicKey, algorithm, jwt.signingInput as CFData, jwt.signature as CFData, nil)
}

@Suite("push senders")
struct PushSenderTests {
    func fcmCredentials(tokenURI: URL) throws -> (FCMCredentials, SecKey) {
        let (pem, publicKey) = try makeRSAKey()
        let json: [String: Any] = ["type": "service_account", "project_id": "amber-test", "client_email": "gw@amber-test.iam.gserviceaccount.com",
                                   "private_key": pem, "token_uri": tokenURI.absoluteString]
        return (try FCMCredentials(serviceAccount: JSONSerialization.data(withJSONObject: json)), publicKey)
    }

    @Test func fcmExchangesAJWTForAnAccessTokenAndSendsV1Message() async throws {
        let mock = try MockPushService()
        mock.reply = { request in
            request.path == "/token" ? .json(200, ["access_token": "ya29.test", "expires_in": 3599, "token_type": "Bearer"]) : .json(200, ["name": "projects/amber-test/messages/1"])
        }
        let (creds, publicKey) = try fcmCredentials(tokenURI: mock.base.appendingPathComponent("token"))
        let sender = FCMSender(credentials: creds, apiBase: mock.base)

        #expect(await sender.send(message, to: "fcm-token-1") == .delivered)
        let (tokenRequest, sendRequest) = (mock.recorded[0], mock.recorded[1])
        #expect(tokenRequest.method == "POST" && tokenRequest.path == "/token")
        let form = String(decoding: tokenRequest.body, as: UTF8.self)
        #expect(form.hasPrefix("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="))
        let jwt = try decodeJWT(String(form.split(separator: "=").last!))
        #expect(jwt.header["alg"] as? String == "RS256")
        #expect(jwt.claims["iss"] as? String == "gw@amber-test.iam.gserviceaccount.com")
        #expect(jwt.claims["scope"] as? String == "https://www.googleapis.com/auth/firebase.messaging")
        #expect(jwt.claims["aud"] as? String == mock.base.appendingPathComponent("token").absoluteString)
        #expect(verifyRSA(jwt, publicKey, .rsaSignatureMessagePKCS1v15SHA256))

        #expect(sendRequest.path == "/v1/projects/amber-test/messages:send")
        #expect(sendRequest.headers["authorization"] == "Bearer ya29.test")
        let body = try #require(try JSONSerialization.jsonObject(with: sendRequest.body) as? [String: Any])
        let msg = try #require(body["message"] as? [String: Any])
        #expect(msg["token"] as? String == "fcm-token-1")
        #expect((msg["notification"] as? [String: String]) == ["title": "Claude Code · amber", "body": "等待你处理"])
        let android = try #require(msg["android"] as? [String: Any])
        #expect(android["priority"] as? String == "HIGH")
        #expect((android["notification"] as? [String: String]) == ["channel_id": "mac_gateway", "tag": "claude:s1"])

        // The access token is reused: the second push makes no OAuth call.
        _ = await sender.send(message, to: "fcm-token-1")
        #expect(mock.recorded.count == 3 && mock.recorded[2].path.hasSuffix("messages:send"))
    }

    @Test func fcmUnregisteredTokenIsReportedInvalid() async throws {
        let mock = try MockPushService()
        mock.reply = { request in
            request.path == "/token" ? .json(200, ["access_token": "t", "expires_in": 3600])
                : .json(404, ["error": ["code": 404, "status": "NOT_FOUND", "message": "Requested entity was not found.",
                                        "details": [["@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": "UNREGISTERED"]]]])
        }
        let (creds, _) = try fcmCredentials(tokenURI: mock.base.appendingPathComponent("token"))
        #expect(await FCMSender(credentials: creds, apiBase: mock.base).send(message, to: "gone") == .invalidToken("UNREGISTERED"))
    }

    @Test func fcmRejectedServiceAccountIsAFailureNotAnInvalidToken() async throws {
        let mock = try MockPushService()
        mock.reply = { _ in .json(400, ["error": "invalid_grant", "error_description": "Invalid JWT Signature."]) }
        let (creds, _) = try fcmCredentials(tokenURI: mock.base.appendingPathComponent("token"))
        guard case .failed(let reason) = await FCMSender(credentials: creds, apiBase: mock.base).send(message, to: "t") else {
            Issue.record("expected failure"); return
        }
        #expect(reason.contains("Invalid JWT Signature"))
    }

    let message = PushMessage(title: "Claude Code · amber", body: "等待你处理", threadId: "claude:s1", timeSensitive: true)

    @Test func apnsRequestIsWellFormedAndSigned() async throws {
        let mock = try MockPushService()
        let key = P256.Signing.PrivateKey()
        let creds = APNsCredentials(keyId: "KEY123", teamId: "TEAM45", topic: "app.amber.ios", privateKeyPEM: key.pemRepresentation)
        let sender = APNsSender(credentials: creds, hosts: [.sandbox: mock.base, .production: URL(string: "http://127.0.0.1:1")!])

        #expect(await sender.send(message, to: "deadbeef", environment: .sandbox) == .delivered)
        let request = try #require(mock.recorded.first)
        #expect(request.method == "POST" && request.path == "/3/device/deadbeef")
        #expect(request.headers["apns-topic"] == "app.amber.ios")
        #expect(request.headers["apns-push-type"] == "alert")
        #expect(request.headers["apns-priority"] == "10")

        let auth = try #require(request.headers["authorization"])
        #expect(auth.hasPrefix("bearer "))
        let jwt = try decodeJWT(String(auth.dropFirst(7)))
        #expect(jwt.header["alg"] as? String == "ES256" && jwt.header["kid"] as? String == "KEY123")
        #expect(jwt.claims["iss"] as? String == "TEAM45")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: jwt.signature)
        #expect(key.publicKey.isValidSignature(signature, for: jwt.signingInput))

        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        #expect(aps["thread-id"] as? String == "claude:s1")
        #expect((aps["alert"] as? [String: String])?["body"] == "等待你处理")

        // The provider token is reused rather than re-signed per push.
        _ = await sender.send(message, to: "deadbeef", environment: .sandbox)
        #expect(mock.recorded.count == 2 && mock.recorded[1].headers["authorization"] == auth)
    }

    @Test func apnsGoneTokenIsReportedInvalid() async throws {
        let mock = try MockPushService()
        mock.reply = { _ in .json(410, ["reason": "Unregistered"]) }
        let creds = APNsCredentials(keyId: "K", teamId: "T", topic: "app.amber.ios", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let sender = APNsSender(credentials: creds, hosts: [.production: mock.base, .sandbox: mock.base])
        #expect(await sender.send(message, to: "t", environment: .production) == .invalidToken("Unregistered"))

        // A wrong --topic is a setup error: dropping the token would hide it behind "no token reported".
        mock.reply = { _ in .json(400, ["reason": "DeviceTokenNotForTopic"]) }
        guard case .failed(let reason) = await sender.send(message, to: "t", environment: .production) else {
            Issue.record("DeviceTokenNotForTopic must not invalidate the token")
            return
        }
        #expect(reason.contains("topic"))
    }

    @Test func dispatcherRoutesByPlatformAndExplainsMissingSetup() async throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = try MockPushService()
        var endpoints = PushDispatcher.Endpoints()
        endpoints.apns = [.production: mock.base, .sandbox: mock.base]
        let store = CredentialStore(dir: dir)
        let dispatcher = PushDispatcher(store: store, endpoints: endpoints)

        var phone = PairedDevice(id: "d1", name: "iPhone", platform: .ios, tokenHash: "h", pairedAt: Date())
        if case .failed(let reason) = await dispatcher.deliver(message, to: phone) {
            #expect(reason.contains("token"))
        } else { Issue.record("device without push token must fail") }

        phone.pushToken = "abc"
        phone.pushEnvironment = .production
        if case .failed(let reason) = await dispatcher.deliver(message, to: phone) {
            #expect(reason.contains("creds import apns"))
        } else { Issue.record("missing credentials must fail with a hint") }

        try store.save(APNsCredentials(keyId: "K", teamId: "T", topic: "app.amber.ios", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), as: .apns)
        #expect(await dispatcher.deliver(message, to: phone) == .delivered)
        #expect(mock.recorded.first?.path == "/3/device/abc")
    }

    @Test func dispatcherRoutesAndroidToFCM() async throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = try MockPushService()
        mock.reply = { $0.path == "/token" ? .json(200, ["access_token": "t", "expires_in": 3600]) : HTTPResponse(status: 200) }
        var endpoints = PushDispatcher.Endpoints()
        endpoints.fcm = mock.base
        let store = CredentialStore(dir: dir)
        let dispatcher = PushDispatcher(store: store, endpoints: endpoints)
        var pixel = PairedDevice(id: "d2", name: "Pixel", platform: .android, tokenHash: "h", pairedAt: Date())
        pixel.pushToken = "fcm-abc"

        if case .failed(let reason) = await dispatcher.deliver(message, to: pixel) {
            #expect(reason.contains("creds import fcm"))
        } else { Issue.record("missing FCM credentials must fail with a hint") }

        try store.save(try fcmCredentials(tokenURI: mock.base.appendingPathComponent("token")).0, as: .fcm)
        #expect(await dispatcher.deliver(message, to: pixel) == .delivered)
        #expect(mock.recorded.last?.path == "/v1/projects/amber-test/messages:send")
    }

    func huaweiCredentials() throws -> (HuaweiCredentials, SecKey) {
        let (pem, publicKey) = try makeRSAKey()
        let json: [String: Any] = ["project_id": "101234", "key_id": "kid-1", "sub_account": "1100001", "private_key": pem]
        return (try HuaweiCredentials(serviceAccount: JSONSerialization.data(withJSONObject: json), projectId: nil, category: "MARKETING"), publicKey)
    }

    @Test func huaweiSendsAV3NotificationWithAPS256ServiceAccountJWT() async throws {
        let mock = try MockPushService()
        mock.reply = { _ in .json(200, ["code": "80000000", "msg": "Success", "requestId": "r1"]) }
        let (creds, publicKey) = try huaweiCredentials()

        #expect(await HuaweiSender(credentials: creds, apiBase: mock.base).send(message, to: "hms-token/1=") == .delivered)
        let request = try #require(mock.recorded.first)
        #expect(request.method == "POST" && request.path == "/v3/101234/messages:send")
        #expect(request.headers["push-type"] == "0")
        let auth = try #require(request.headers["authorization"])
        let jwt = try decodeJWT(String(auth.dropFirst("Bearer ".count)))
        #expect(jwt.header["alg"] as? String == "PS256" && jwt.header["kid"] as? String == "kid-1")
        #expect(jwt.claims["iss"] as? String == "1100001")
        #expect(jwt.claims["aud"] as? String == "https://oauth-login.cloud.huawei.com/oauth2/v3/token")
        #expect(verifyRSA(jwt, publicKey, .rsaSignatureMessagePSSSHA256))

        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect((body["target"] as? [String: [String]]) == ["token": ["hms-token/1="]])
        let notification = try #require((body["payload"] as? [String: Any])?["notification"] as? [String: Any])
        #expect(notification["category"] as? String == "MARKETING")
        #expect(notification["title"] as? String == "Claude Code · amber" && notification["body"] as? String == "等待你处理")
        #expect(notification["notifyId"] as? Int == HuaweiSender.notifyId("claude:s1"))
        #expect(HuaweiSender.notifyId("claude:s1") != HuaweiSender.notifyId("claude:s2"))
        #expect(body["pushOptions"] == nil, "real alerts must not be marked as test messages")

        let test = PushMessage(PushIntent(kind: .test, subject: "test", createdAt: Date()), gatewayName: "Mac")
        let testBody = HuaweiSender.payload(test, token: "t", category: "MARKETING")
        #expect((testBody["pushOptions"] as? [String: Bool]) == ["testMessage": true], "tests must not consume the MARKETING daily quota")
    }

    @Test func huaweiInvalidTokenAndAuthFailureAreDistinguished() async throws {
        let mock = try MockPushService()
        let (creds, _) = try huaweiCredentials()
        let sender = HuaweiSender(credentials: creds, apiBase: mock.base)
        mock.reply = { _ in .json(400, ["code": "80300007", "msg": "All the tokens are invalid"]) }
        #expect(await sender.send(message, to: "gone") == .invalidToken("80300007"))
        mock.reply = { _ in .json(401, ["code": "80200001", "msg": "Authentication Error"]) }
        guard case .failed(let reason) = await sender.send(message, to: "t") else { Issue.record("expected failure"); return }
        #expect(reason.contains("80200001"))
    }

    @Test func dispatcherRoutesHarmonyToHuawei() async throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = try MockPushService()
        mock.reply = { _ in .json(200, ["code": "80000000"]) }
        var endpoints = PushDispatcher.Endpoints()
        endpoints.huawei = mock.base
        let store = CredentialStore(dir: dir)
        let dispatcher = PushDispatcher(store: store, endpoints: endpoints)
        var mate = PairedDevice(id: "d3", name: "Mate", platform: .harmony, tokenHash: "h", pairedAt: Date())
        mate.pushToken = "hms-abc"

        if case .failed(let reason) = await dispatcher.deliver(message, to: mate) {
            #expect(reason.contains("creds import huawei"))
        } else { Issue.record("missing Huawei credentials must fail with a hint") }

        try store.save(try huaweiCredentials().0, as: .huawei)
        #expect(await dispatcher.deliver(message, to: mate) == .delivered)
        #expect(mock.recorded.last?.path == "/v3/101234/messages:send")
    }

    @Test func terminalQRDecodesBackToThePairingURL() throws {
        let payload = PairingPayload(id: UUID().uuidString.lowercased(), name: "渡光的MacBook Pro",
                                     addrs: ["duguangdeMacBook-Pro.local", "192.168.100.107", "mac.tail1234.ts.net"],
                                     port: 47821, fp: Data(SHA256.hash(data: Data())).base64EncodedString(), s: Secrets.random())
        let text = try #require(TerminalQR.render(payload.url))
        let rows = text.split(separator: "\n").map {
            $0.replacingOccurrences(of: "\u{1B}[30;47m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "")
        }
        let width = rows[0].count
        #expect(width <= 80, "fits a standard terminal")

        let scale = 8
        let (w, h) = (width * scale, rows.count * 2 * scale)
        var pixels = [UInt8](repeating: 255, count: w * h)
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                let dark = [ch == "█" || ch == "▀", ch == "█" || ch == "▄"]
                for half in 0..<2 where dark[half] {
                    for y in 0..<scale { for x in 0..<scale { pixels[((r * 2 + half) * scale + y) * w + c * scale + x] = 0 } }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let decoded = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(decoded == [payload.url])
        #expect(PairingPayload.parse(url: decoded.first ?? "") == payload)
    }

    @Test func pushTextIsMetadataOnly() {
        let intent = PushIntent(kind: .task, sessionKey: "codex:x", agent: .codex, subject: "amber-gateway",
                                state: .stopped, abnormal: true, createdAt: Date())
        let m = PushMessage(intent, gatewayName: "MacBook")
        #expect(m.title == "Codex · amber-gateway")
        #expect(m.body == "意外中断")
        #expect(TaskState.waiting.label(.permission) == "等你确认" && TaskState.waiting.label(.turnEnd) == "等你回复")
        #expect(TaskState.stalled.label() == "可能卡住了" && TaskState.stopped.label() == "已停止")
        #expect(!m.timeSensitive)
        let health = PushMessage(PushIntent(kind: .health, subject: "disk", detail: "磁盘剩余 12 GB", createdAt: Date()), gatewayName: "MacBook")
        #expect(health.title == "MacBook 健康提醒" && health.body == "磁盘剩余 12 GB")
    }
}
