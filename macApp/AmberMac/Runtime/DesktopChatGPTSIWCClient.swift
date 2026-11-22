import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import Security

/// Official OpenAI Sign in with ChatGPT (SIWC) constants for open-source / local token sharing.
/// Spec: developers.openai.com/siwc/token-sharing-open-source
enum DesktopChatGPTSIWCConstants {
    static let issuer = "https://auth.openai.com"
    static let authorizationEndpoint = "https://auth.openai.com/api/accounts/authorize"
    static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    static let jwksEndpoint = "https://auth.openai.com/.well-known/jwks.json"
    static let resource = "https://api.openai.com/v1"
    static let apiBaseURL = "https://api.openai.com/v1"
    static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!

    static let dynamicClientID = "dynamic_agent_client"
    static let agentNameHint = "Amber"
    static let requiredPlanScope = "chatgpt.tokens.use.direct"
    static let scopes: [String] = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "resource.invoke",
        requiredPlanScope,
    ]
    static let scopeString = scopes.joined(separator: " ")

    static let loopbackHost = "127.0.0.1"
    static let callbackPath = "/auth/callback"

    static let refreshSkewMillis: Int64 = 2 * 60 * 1000
    static let fallbackTokenLifetimeMillis: Int64 = 45 * 60 * 1000
    static let loginTimeoutSeconds: TimeInterval = 5 * 60
    static let clockSkewSeconds: TimeInterval = 60

    static let planConfirmedDefaultsKey = "amber.mac.siwc.plan_confirmed.v1"
}

enum DesktopSIWCError: LocalizedError, Equatable, Sendable {
    case notSignedIn
    case planScopeUnavailable
    case dynamicRegistrationMissingClientID
    case invalidState
    case authorizationDenied(String)
    case loopbackListenerFailed(String)
    case browserLaunchFailed
    case timedOut
    case tokenExchangeFailed(String)
    case idTokenVerificationFailed(String)
    case credentialStoreFailed
    case usageLimitExceeded
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "尚未登录 ChatGPT 套餐，请先点击「Continue with ChatGPT」完成授权。"
        case .planScopeUnavailable:
            "当前账号未授予 chatgpt.tokens.use.direct 权限，暂不可使用 ChatGPT 套餐额度。请重新授权或切换为 OpenAI API Key。"
        case .dynamicRegistrationMissingClientID:
            "OpenAI 授权回调未返回有效的客户端标识（client_id），无法完成动态注册。"
        case .invalidState:
            "授权回调的 state 校验失败，已拒绝本次登录。请重试。"
        case .authorizationDenied(let detail):
            detail.isEmpty ? "授权已取消或被拒绝。" : "ChatGPT 授权未完成：\(detail)"
        case .loopbackListenerFailed(let detail):
            "无法在 127.0.0.1 启动本地登录回调监听：\(detail)"
        case .browserLaunchFailed:
            "无法打开系统浏览器进行 ChatGPT 登录。"
        case .timedOut:
            "等待浏览器登录回调超时，请重新点击「Continue with ChatGPT」。"
        case .tokenExchangeFailed(let detail):
            "交换或刷新 ChatGPT 凭证失败：\(detail)"
        case .idTokenVerificationFailed(let detail):
            "ID Token 安全校验失败：\(detail)"
        case .credentialStoreFailed:
            "无法将 ChatGPT 登录凭证保存到系统钥匙串，请解锁钥匙串后重试。"
        case .usageLimitExceeded:
            "ChatGPT 套餐共享额度已用尽（subscription_sharing_usage_limit_exceeded）。请前往 https://chatgpt.com/settings/usage 查看或管理用量，或切换为 OpenAI API Key。"
        case .usageUnavailable:
            "当前账号的 ChatGPT 套餐共享暂不可用（subscription_sharing_usage_unavailable）。请前往 https://chatgpt.com/settings/usage 检查订阅状态与套餐共享设置，或切换为 OpenAI API Key。"
        }
    }
}

struct DesktopSIWCCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let clientId: String
    let extAgentHostId: String
    let expiresAtMillis: Int64
    let earliestRefreshAtMillis: Int64
    let scopes: [String]
    let subject: String?
    let email: String?
    let name: String?
    let planType: String?

    var hasDirectTokenSharingScope: Bool {
        scopes.contains(DesktopChatGPTSIWCConstants.requiredPlanScope)
    }

    var account: DesktopSIWCAccount {
        DesktopSIWCAccount(
            email: email,
            name: name,
            subject: subject,
            plan: planType,
            planAvailable: hasDirectTokenSharingScope
        )
    }
}

struct DesktopSIWCAccount: Equatable, Sendable {
    let email: String?
    let name: String?
    let subject: String?
    let plan: String?
    let planAvailable: Bool

    var displayName: String {
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "ChatGPT 账号"
    }
}

protocol DesktopSIWCSecretStore: Sendable {
    func load(key: String) -> String?
    @discardableResult func store(key: String, value: String) -> Bool
    @discardableResult func delete(key: String) -> Bool
}

struct DesktopSIWCKeychainSecretStore: DesktopSIWCSecretStore {
    func load(key: String) -> String? { IOSCredentialSideTable.load(key: key) }
    @discardableResult func store(key: String, value: String) -> Bool { IOSCredentialSideTable.store(key: key, value: value) }
    @discardableResult func delete(key: String) -> Bool { IOSCredentialSideTable.delete(key: key) }
}

enum DesktopSIWCAuthStore {
    enum RefreshCommitResult: Equatable, Sendable {
        case saved
        case storeFailed
        case credentialsChanged
    }

    private static let lock = NSLock()
    static let deviceHostIDKey = "siwc.device.ext_agent_host_id"

    static func credentialsKey(providerId: String) -> String { "siwc.\(providerId).credentials" }
    static func clientIDKey(providerId: String) -> String { "siwc.\(providerId).client_id" }

    static func getOrCreateExtAgentHostID(store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = store.load(key: deviceHostIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           existing.hasPrefix("urn:uuid:") || existing.hasPrefix("urn:ietf:params:oauth:jwk-thumbprint:") {
            return existing
        }
        let generated = "urn:uuid:\(UUID().uuidString.lowercased())"
        guard store.store(key: deviceHostIDKey, value: generated) else {
            throw DesktopSIWCError.credentialStoreFailed
        }
        return generated
    }

    static func loadClientID(
        providerId: String,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadClientIDLocked(providerId: providerId, store: store)
    }

    static func load(
        providerId: String,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> DesktopSIWCCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(providerId: providerId, store: store)
    }

    @discardableResult
    static func save(
        providerId: String,
        credentials: DesktopSIWCCredentials,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> Bool {
        guard isValidIssuedClientID(credentials.clientId),
              let encoded = encode(credentials) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let savedCreds = store.store(key: credentialsKey(providerId: providerId), value: encoded)
        let savedClient = store.store(key: clientIDKey(providerId: providerId), value: credentials.clientId)
        return savedCreds && savedClient
    }

    static func saveRefreshedCredentials(
        providerId: String,
        expected: DesktopSIWCCredentials,
        refreshed: DesktopSIWCCredentials,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> RefreshCommitResult {
        guard isValidIssuedClientID(refreshed.clientId),
              let encoded = encode(refreshed) else { return .storeFailed }
        lock.lock()
        defer { lock.unlock() }
        guard loadLocked(providerId: providerId, store: store) == expected else {
            return .credentialsChanged
        }
        let savedCreds = store.store(key: credentialsKey(providerId: providerId), value: encoded)
        let savedClient = store.store(key: clientIDKey(providerId: providerId), value: refreshed.clientId)
        return (savedCreds && savedClient) ? .saved : .storeFailed
    }

    /// Signs out the provider session while keeping the device `ext_agent_host_id` and issued `client_id`
    /// so a subsequent sign-in on this device reuses the registered client.
    @discardableResult
    static func logout(
        providerId: String,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.delete(key: credentialsKey(providerId: providerId))
    }

    /// Removes all provider-scoped SIWC credentials when a provider entry is deleted.
    @discardableResult
    static func deleteProvider(
        providerId: String,
        store: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let credsDeleted = store.delete(key: credentialsKey(providerId: providerId))
        let clientDeleted = store.delete(key: clientIDKey(providerId: providerId))
        return credsDeleted && clientDeleted
    }

    static func isValidIssuedClientID(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != DesktopChatGPTSIWCConstants.dynamicClientID else {
            return false
        }
        return true
    }

    private static func loadClientIDLocked(providerId: String, store: any DesktopSIWCSecretStore) -> String? {
        if let direct = store.load(key: clientIDKey(providerId: providerId)), isValidIssuedClientID(direct) {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let creds = loadLocked(providerId: providerId, store: store), isValidIssuedClientID(creds.clientId) {
            return creds.clientId
        }
        return nil
    }

    private static func loadLocked(providerId: String, store: any DesktopSIWCSecretStore) -> DesktopSIWCCredentials? {
        guard let raw = store.load(key: credentialsKey(providerId: providerId)),
              let data = raw.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(DesktopSIWCCredentials.self, from: data),
              isValidIssuedClientID(credentials.clientId) else {
            return nil
        }
        return credentials
    }

    private static func encode(_ credentials: DesktopSIWCCredentials) -> String? {
        guard let data = try? JSONEncoder().encode(credentials) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - JWT & JWKS Verification

struct DesktopSIWCVerifiedIDToken: Equatable, Sendable {
    let subject: String
    let email: String?
    let name: String?
    let planType: String?
}

struct DesktopSIWCJWK: Codable, Equatable, Sendable {
    let kty: String
    let kid: String?
    let alg: String?
    let use: String?
    let n: String?
    let e: String?
    let crv: String?
    let x: String?
    let y: String?
}

struct DesktopSIWCJWKS: Codable, Equatable, Sendable {
    let keys: [DesktopSIWCJWK]
}

enum DesktopSIWCJWTVerifier {
    static func verify(
        idToken: String,
        expectedIssuer: String = DesktopChatGPTSIWCConstants.issuer,
        expectedClientID: String,
        expectedNonce: String?,
        jwks: DesktopSIWCJWKS,
        nowSeconds: TimeInterval = Date().timeIntervalSince1970
    ) throws -> DesktopSIWCVerifiedIDToken {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw DesktopSIWCError.idTokenVerificationFailed("JWT 格式无效。")
        }
        guard let headerData = base64URLDecode(String(segments[0])),
              let payloadData = base64URLDecode(String(segments[1])),
              let signatureData = base64URLDecode(String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw DesktopSIWCError.idTokenVerificationFailed("无法解码 JWT 头或载荷。")
        }

        guard let alg = header["alg"] as? String, !alg.isEmpty, alg.lowercased() != "none" else {
            throw DesktopSIWCError.idTokenVerificationFailed("不支持或缺失的签名算法（alg）。")
        }
        let kid = header["kid"] as? String
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        try verifySignature(signingInput: signingInput, signature: signatureData, alg: alg, kid: kid, jwks: jwks)

        // Standard OIDC claim verification
        guard let iss = payload["iss"] as? String, iss == expectedIssuer else {
            throw DesktopSIWCError.idTokenVerificationFailed("iss 发行方不匹配。")
        }
        guard audienceMatches(payload["aud"], expectedClientID: expectedClientID) else {
            throw DesktopSIWCError.idTokenVerificationFailed("aud 未包含颁布的 client_id。")
        }
        guard let exp = numericTimestamp(payload["exp"]),
              exp > nowSeconds - DesktopChatGPTSIWCConstants.clockSkewSeconds else {
            throw DesktopSIWCError.idTokenVerificationFailed("ID Token 已过期（exp）。")
        }
        if let nbf = numericTimestamp(payload["nbf"]),
           nbf > nowSeconds + DesktopChatGPTSIWCConstants.clockSkewSeconds {
            throw DesktopSIWCError.idTokenVerificationFailed("ID Token 尚未生效（nbf）。")
        }
        if let expectedNonce {
            guard let actualNonce = payload["nonce"] as? String, actualNonce == expectedNonce else {
                throw DesktopSIWCError.idTokenVerificationFailed("nonce 不匹配。")
            }
        }
        guard let sub = (payload["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sub.isEmpty else {
            throw DesktopSIWCError.idTokenVerificationFailed("缺少有效的 sub 主体标识。")
        }

        let authClaims = payload["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = (payload["email"] as? String) ?? (profileClaims?["email"] as? String)
        let name = (payload["name"] as? String) ?? (profileClaims?["name"] as? String)
        let planType = authClaims?["chatgpt_plan_type"] as? String

        return DesktopSIWCVerifiedIDToken(subject: sub, email: email, name: name, planType: planType)
    }

    private static func audienceMatches(_ rawAudience: Any?, expectedClientID: String) -> Bool {
        if let single = rawAudience as? String {
            return single == expectedClientID
        }
        if let list = rawAudience as? [String] {
            return list.contains(expectedClientID)
        }
        if let list = rawAudience as? [Any] {
            return list.compactMap { $0 as? String }.contains(expectedClientID)
        }
        return false
    }

    private static func numericTimestamp(_ raw: Any?) -> TimeInterval? {
        if let value = raw as? TimeInterval { return value }
        if let value = raw as? Int { return TimeInterval(value) }
        if let value = raw as? Int64 { return TimeInterval(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func verifySignature(
        signingInput: Data,
        signature: Data,
        alg: String,
        kid: String?,
        jwks: DesktopSIWCJWKS
    ) throws {
        let matchingKeys: [DesktopSIWCJWK]
        if let kid, !kid.isEmpty {
            matchingKeys = jwks.keys.filter { $0.kid == kid && ($0.use == nil || $0.use == "sig") }
        } else {
            matchingKeys = jwks.keys.filter { $0.use == nil || $0.use == "sig" }
        }
        guard !matchingKeys.isEmpty else {
            throw DesktopSIWCError.idTokenVerificationFailed("JWKS 中未找到匹配的签名公钥（kid=\(kid ?? "none")）。")
        }

        var verified = false
        for key in matchingKeys {
            if try verifyWithKey(signingInput: signingInput, signature: signature, alg: alg, jwk: key) {
                verified = true
                break
            }
        }
        guard verified else {
            throw DesktopSIWCError.idTokenVerificationFailed("ID Token 签名校验未通过。")
        }
    }

    private static func verifyWithKey(
        signingInput: Data,
        signature: Data,
        alg: String,
        jwk: DesktopSIWCJWK
    ) throws -> Bool {
        switch alg {
        case "RS256", "RS384", "RS512":
            guard jwk.kty == "RSA",
                  let nStr = jwk.n, let eStr = jwk.e,
                  let modulus = base64URLDecode(nStr),
                  let exponent = base64URLDecode(eStr) else {
                return false
            }
            let derKey = rsaPublicKeyDER(modulus: modulus, exponent: exponent)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            var cfError: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(derKey as CFData, attributes as CFDictionary, &cfError) else {
                return false
            }
            let secAlg: SecKeyAlgorithm = switch alg {
            case "RS384": .rsaSignatureMessagePKCS1v15SHA384
            case "RS512": .rsaSignatureMessagePKCS1v15SHA512
            default: .rsaSignatureMessagePKCS1v15SHA256
            }
            return SecKeyVerifySignature(secKey, secAlg, signingInput as CFData, signature as CFData, &cfError)

        case "ES256":
            guard jwk.kty == "EC", jwk.crv == "P-256",
                  let xStr = jwk.x, let yStr = jwk.y,
                  let x = base64URLDecode(xStr), let y = base64URLDecode(yStr),
                  let rawPoint = paddedECPoint(x: x, y: y, coordinateSize: 32),
                  let publicKey = try? P256.Signing.PublicKey(rawRepresentation: rawPoint),
                  let ecdsaSig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
                return false
            }
            return publicKey.isValidSignature(ecdsaSig, for: signingInput)

        case "ES384":
            guard jwk.kty == "EC", jwk.crv == "P-384",
                  let xStr = jwk.x, let yStr = jwk.y,
                  let x = base64URLDecode(xStr), let y = base64URLDecode(yStr),
                  let rawPoint = paddedECPoint(x: x, y: y, coordinateSize: 48),
                  let publicKey = try? P384.Signing.PublicKey(rawRepresentation: rawPoint),
                  let ecdsaSig = try? P384.Signing.ECDSASignature(rawRepresentation: signature) else {
                return false
            }
            return publicKey.isValidSignature(ecdsaSig, for: signingInput)

        case "ES512":
            guard jwk.kty == "EC", jwk.crv == "P-521",
                  let xStr = jwk.x, let yStr = jwk.y,
                  let x = base64URLDecode(xStr), let y = base64URLDecode(yStr),
                  let rawPoint = paddedECPoint(x: x, y: y, coordinateSize: 66),
                  let publicKey = try? P521.Signing.PublicKey(rawRepresentation: rawPoint),
                  let ecdsaSig = try? P521.Signing.ECDSASignature(rawRepresentation: signature) else {
                return false
            }
            return publicKey.isValidSignature(ecdsaSig, for: signingInput)

        default:
            throw DesktopSIWCError.idTokenVerificationFailed("不支持的 JWS 算法：\(alg)。")
        }
    }

    private static func paddedECPoint(x: Data, y: Data, coordinateSize: Int) -> Data? {
        guard x.count <= coordinateSize, y.count <= coordinateSize else { return nil }
        var result = Data(capacity: coordinateSize * 2)
        if x.count < coordinateSize { result.append(Data(repeating: 0, count: coordinateSize - x.count)) }
        result.append(x)
        if y.count < coordinateSize { result.append(Data(repeating: 0, count: coordinateSize - y.count)) }
        result.append(y)
        return result
    }

    /// Encodes PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    private static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let modBytes = derInteger(modulus)
        let expBytes = derInteger(exponent)
        return derSequence(modBytes + expBytes)
    }

    private static func derInteger(_ raw: Data) -> Data {
        var bytes = raw
        while bytes.count > 1, bytes.first == 0x00 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return Data([0x02]) + derLength(bytes.count) + bytes
    }

    private static func derSequence(_ body: Data) -> Data {
        Data([0x30]) + derLength(body.count) + body
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback HTTP Callback Server (127.0.0.1 only)

struct DesktopSIWCCallbackPayload: Equatable, Sendable {
    let code: String?
    let state: String?
    let clientID: String?
    let error: String?
    let errorDescription: String?
}

final class DesktopSIWCLoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var closed = false

    var redirectURI: String {
        "http://\(DesktopChatGPTSIWCConstants.loopbackHost):\(port)\(DesktopChatGPTSIWCConstants.callbackPath)"
    }

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DesktopSIWCError.loopbackListenerFailed("socket() 失败（errno=\(errno)）")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-assigned ephemeral loopback port
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DesktopSIWCError.loopbackListenerFailed("bind(127.0.0.1) 失败（errno=\(code)）")
        }

        guard listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DesktopSIWCError.loopbackListenerFailed("listen() 失败（errno=\(code)）")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DesktopSIWCError.loopbackListenerFailed("getsockname() 失败（errno=\(code)）")
        }

        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)
        lock.lock()
        listenFD = fd
        port = assignedPort
        closed = false
        lock.unlock()
        return assignedPort
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        closed = true
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    deinit {
        stop()
    }

    func waitForCallback(timeout: TimeInterval = DesktopChatGPTSIWCConstants.loginTimeoutSeconds) async throws -> DesktopSIWCCallbackPayload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let deadline = Date().addingTimeInterval(timeout)
                    do {
                        let payload = try self.acceptLoop(deadline: deadline)
                        self.stop()
                        continuation.resume(returning: payload)
                    } catch {
                        self.stop()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.stop()
        }
    }

    private func acceptLoop(deadline: Date) throws -> DesktopSIWCCallbackPayload {
        while true {
            let fd = currentFD()
            guard fd >= 0 else { throw CancellationError() }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw DesktopSIWCError.timedOut }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMillis = Int32(min(remaining * 1000.0, 500.0))
            let ready = poll(&pfd, 1, max(waitMillis, 50))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                if currentFD() < 0 { throw CancellationError() }
                throw DesktopSIWCError.loopbackListenerFailed("poll() 失败（errno=\(errno)）")
            }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fd, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if currentFD() < 0 { throw CancellationError() }
                if errno == EINTR { continue }
                continue
            }

            let payload = handleClient(clientFD)
            Darwin.close(clientFD)
            if let payload { return payload }
        }
    }

    private func currentFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return closed ? -1 : listenFD
    }

    private func handleClient(_ clientFD: Int32) -> DesktopSIWCCallbackPayload? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 16_384)
        let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return nil }

        let requestText = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        guard let firstLine = requestText.components(separatedBy: "\r\n").first else {
            writeResponse(clientFD, status: "400 Bad Request", html: Self.errorHTML("无效的回调请求。"))
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            writeResponse(clientFD, status: "405 Method Not Allowed", html: Self.errorHTML("不支持的请求方法。"))
            return nil
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://\(DesktopChatGPTSIWCConstants.loopbackHost)\(target)"),
              components.path == DesktopChatGPTSIWCConstants.callbackPath else {
            writeResponse(clientFD, status: "404 Not Found", html: Self.errorHTML("Not Found"))
            return nil
        }

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        let payload = DesktopSIWCCallbackPayload(
            code: query["code"]?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty,
            state: query["state"]?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty,
            clientID: query["client_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty,
            error: query["error"]?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty,
            errorDescription: query["error_description"]?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty
        )

        if let error = payload.error {
            writeResponse(clientFD, status: "200 OK", html: Self.errorHTML("授权未完成（\(Self.escapeHTML(error))），你可以关闭此标签页并返回 Amber。"))
        } else {
            writeResponse(clientFD, status: "200 OK", html: Self.successHTML)
        }
        return payload
    }

    private func writeResponse(_ clientFD: Int32, status: String, html: String) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < response.count {
                let sent = send(clientFD, base.advanced(by: totalSent), response.count - totalSent, 0)
                if sent <= 0 { break }
                totalSent += sent
            }
        }
    }

    private static let successHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8" />
      <title>Amber · Sign in with ChatGPT</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #faf8f5; color: #1f1b16; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .card { background: #ffffff; border: 1px solid #e6dfd5; border-radius: 14px; padding: 28px 32px; max-width: 420px; box-shadow: 0 8px 24px rgba(0,0,0,0.05); }
        h1 { font-size: 18px; margin: 0 0 8px; }
        p { font-size: 14px; color: #5c5346; margin: 0; line-height: 1.5; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>已完成 ChatGPT 授权</h1>
        <p>请返回 Amber，此页面现在可以关闭。</p>
      </div>
    </body>
    </html>
    """

    private static func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head><meta charset="utf-8" /><title>Amber · Sign in with ChatGPT</title></head>
        <body style="font-family:-apple-system,sans-serif;padding:32px;color:#1f1b16;background:#faf8f5;">
          <p>\(message)</p>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension String {
    var siwcNonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - SIWC OAuth Client

actor DesktopChatGPTSIWCClient {
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias BrowserOpener = @Sendable (URL) async -> Bool
    typealias Clock = @Sendable () -> Int64

    private static let refreshLock = NSLock()
    nonisolated(unsafe) private static var inFlightRefreshes: [String: Task<DesktopSIWCCredentials, Error>] = [:]
    nonisolated(unsafe) private static var cachedJWKS: DesktopSIWCJWKS?

    let providerId: String
    private let secretStore: any DesktopSIWCSecretStore
    private let transport: HTTPTransport
    private let openBrowser: BrowserOpener
    private let nowMillis: Clock

    init(
        providerId: String,
        secretStore: any DesktopSIWCSecretStore = DesktopSIWCKeychainSecretStore(),
        transport: @escaping HTTPTransport = DesktopChatGPTSIWCClient.defaultTransport,
        openBrowser: @escaping BrowserOpener = DesktopChatGPTSIWCClient.defaultOpenBrowser,
        nowMillis: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.providerId = providerId.lowercased()
        self.secretStore = secretStore
        self.transport = transport
        self.openBrowser = openBrowser
        self.nowMillis = nowMillis
    }

    static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopSIWCError.tokenExchangeFailed("收到非 HTTP 响应。")
        }
        return (data, http)
    }

    static func defaultOpenBrowser(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    /// Builds the official SIWC authorization URL.
    /// - First registration: `client_id=dynamic_agent_client` + `agent_name_hint=Amber` + `ext_agent_host_id`.
    /// - Subsequent re-login: reuses issued `client_id`, omits `agent_name_hint`, and attaches `id_token_hint` / `login_hint` when available.
    static func buildAuthorizationURL(
        redirectURI: String,
        codeChallenge: String,
        state: String,
        nonce: String,
        extAgentHostID: String,
        savedClientID: String?,
        idTokenHint: String? = nil,
        loginHint: String? = nil
    ) -> URL {
        let isDynamicRegistration = !DesktopSIWCAuthStore.isValidIssuedClientID(savedClientID)
        let clientID = isDynamicRegistration
            ? DesktopChatGPTSIWCConstants.dynamicClientID
            : savedClientID!.trimmingCharacters(in: .whitespacesAndNewlines)

        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: DesktopChatGPTSIWCConstants.scopeString),
            URLQueryItem(name: "resource", value: DesktopChatGPTSIWCConstants.resource),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "ext_agent_host_id", value: extAgentHostID),
        ]
        if isDynamicRegistration {
            items.append(URLQueryItem(name: "agent_name_hint", value: DesktopChatGPTSIWCConstants.agentNameHint))
        } else {
            if let idTokenHint = idTokenHint?.trimmingCharacters(in: .whitespacesAndNewlines), !idTokenHint.isEmpty {
                items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
            }
            if let loginHint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !loginHint.isEmpty {
                items.append(URLQueryItem(name: "login_hint", value: loginHint))
            }
        }
        var components = URLComponents(string: DesktopChatGPTSIWCConstants.authorizationEndpoint)!
        components.queryItems = items
        return components.url!
    }

    static func generatePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = DesktopSIWCJWTVerifier.base64URLEncode(Data(digest))
        return (verifier, challenge)
    }

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return DesktopSIWCJWTVerifier.base64URLEncode(Data(bytes))
    }

    func signIn(
        timeout: TimeInterval = DesktopChatGPTSIWCConstants.loginTimeoutSeconds
    ) async throws -> DesktopSIWCAccount {
        let extAgentHostID = try DesktopSIWCAuthStore.getOrCreateExtAgentHostID(store: secretStore)
        let existingCredentials = DesktopSIWCAuthStore.load(providerId: providerId, store: secretStore)
        let savedClientID = DesktopSIWCAuthStore.loadClientID(providerId: providerId, store: secretStore)
        let isDynamicRegistration = !DesktopSIWCAuthStore.isValidIssuedClientID(savedClientID)

        let pkce = Self.generatePKCE()
        let state = Self.randomBase64URL(byteCount: 32)
        let nonce = Self.randomBase64URL(byteCount: 32)

        // Start 127.0.0.1 loopback listener BEFORE opening system browser.
        let server = DesktopSIWCLoopbackServer()
        _ = try server.start()
        defer { server.stop() }
        let redirectURI = server.redirectURI

        let authURL = Self.buildAuthorizationURL(
            redirectURI: redirectURI,
            codeChallenge: pkce.challenge,
            state: state,
            nonce: nonce,
            extAgentHostID: extAgentHostID,
            savedClientID: savedClientID,
            idTokenHint: existingCredentials?.idToken,
            loginHint: existingCredentials?.email
        )

        let opened = await openBrowser(authURL)
        guard opened else { throw DesktopSIWCError.browserLaunchFailed }

        let callback = try await server.waitForCallback(timeout: timeout)
        if let error = callback.error {
            let detail = [error, callback.errorDescription].compactMap { $0 }.joined(separator: "：")
            throw DesktopSIWCError.authorizationDenied(detail)
        }
        guard callback.state == state else {
            throw DesktopSIWCError.invalidState
        }
        guard let code = callback.code, !code.isEmpty else {
            throw DesktopSIWCError.authorizationDenied("回调缺少授权码（code）。")
        }

        let issuedClientID: String
        if isDynamicRegistration {
            guard DesktopSIWCAuthStore.isValidIssuedClientID(callback.clientID),
                  let returned = callback.clientID else {
                throw DesktopSIWCError.dynamicRegistrationMissingClientID
            }
            issuedClientID = returned
        } else if DesktopSIWCAuthStore.isValidIssuedClientID(callback.clientID), let returned = callback.clientID {
            issuedClientID = returned
        } else if let savedClientID, DesktopSIWCAuthStore.isValidIssuedClientID(savedClientID) {
            issuedClientID = savedClientID
        } else {
            throw DesktopSIWCError.dynamicRegistrationMissingClientID
        }

        let credentials = try await exchangeAuthorizationCode(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier,
            issuedClientID: issuedClientID,
            extAgentHostID: extAgentHostID,
            expectedNonce: nonce
        )

        guard DesktopSIWCAuthStore.save(providerId: providerId, credentials: credentials, store: secretStore) else {
            throw DesktopSIWCError.credentialStoreFailed
        }
        return credentials.account
    }

    func getValidAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = DesktopSIWCAuthStore.load(providerId: providerId, store: secretStore) else {
            throw DesktopSIWCError.notSignedIn
        }
        guard current.hasDirectTokenSharingScope else {
            throw DesktopSIWCError.planScopeUnavailable
        }
        let now = nowMillis()
        let needsRefresh = forceRefresh ||
            now >= current.expiresAtMillis - DesktopChatGPTSIWCConstants.refreshSkewMillis ||
            now >= current.earliestRefreshAtMillis
        if !needsRefresh && now < current.expiresAtMillis - DesktopChatGPTSIWCConstants.refreshSkewMillis {
            return current.accessToken
        }

        let refreshed = try await coalescedRefresh(current: current)
        guard refreshed.hasDirectTokenSharingScope else {
            throw DesktopSIWCError.planScopeUnavailable
        }
        return refreshed.accessToken
    }

    func logout() -> Bool {
        Self.cancelInFlightRefresh(providerId: providerId)
        return DesktopSIWCAuthStore.logout(providerId: providerId, store: secretStore)
    }

    func deleteProvider() -> Bool {
        Self.cancelInFlightRefresh(providerId: providerId)
        return DesktopSIWCAuthStore.deleteProvider(providerId: providerId, store: secretStore)
    }

    private func coalescedRefresh(current: DesktopSIWCCredentials) async throws -> DesktopSIWCCredentials {
        let key = providerId
        let task: Task<DesktopSIWCCredentials, Error> = Self.refreshLock.withLock {
            if let existing = Self.inFlightRefreshes[key] { return existing }
            let created = Task { [self] in
                defer {
                    _ = Self.refreshLock.withLock { Self.inFlightRefreshes.removeValue(forKey: key) }
                }
                return try await self.performRefresh(current: current)
            }
            Self.inFlightRefreshes[key] = created
            return created
        }
        return try await task.value
    }

    private static func cancelInFlightRefresh(providerId: String) {
        let task = refreshLock.withLock { inFlightRefreshes.removeValue(forKey: providerId) }
        task?.cancel()
    }

    private func performRefresh(current: DesktopSIWCCredentials) async throws -> DesktopSIWCCredentials {
        let form = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": current.clientId,
            "resource": DesktopChatGPTSIWCConstants.resource,
        ])
        let tokenJSON = try await postTokenRequest(formBody: form)
        let refreshed = try await parseTokenResponse(
            tokenJSON,
            issuedClientID: current.clientId,
            extAgentHostID: current.extAgentHostId,
            expectedNonce: nil,
            fallback: current
        )
        switch DesktopSIWCAuthStore.saveRefreshedCredentials(
            providerId: providerId,
            expected: current,
            refreshed: refreshed,
            store: secretStore
        ) {
        case .saved:
            return refreshed
        case .credentialsChanged:
            guard let latest = DesktopSIWCAuthStore.load(providerId: providerId, store: secretStore) else {
                throw DesktopSIWCError.notSignedIn
            }
            return latest
        case .storeFailed:
            throw DesktopSIWCError.credentialStoreFailed
        }
    }

    private func exchangeAuthorizationCode(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        issuedClientID: String,
        extAgentHostID: String,
        expectedNonce: String
    ) async throws -> DesktopSIWCCredentials {
        let form = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": issuedClientID,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "resource": DesktopChatGPTSIWCConstants.resource,
        ])
        let tokenJSON = try await postTokenRequest(formBody: form)
        return try await parseTokenResponse(
            tokenJSON,
            issuedClientID: issuedClientID,
            extAgentHostID: extAgentHostID,
            expectedNonce: expectedNonce,
            fallback: nil
        )
    }

    private func postTokenRequest(formBody: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: DesktopChatGPTSIWCConstants.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formBody.utf8)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DesktopSIWCError.tokenExchangeFailed("网络请求失败：\(error.localizedDescription)")
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DesktopSIWCError.tokenExchangeFailed("HTTP \(response.statusCode) \(Self.safeErrorDetail(data))")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DesktopSIWCError.tokenExchangeFailed("Token 响应不是有效的 JSON。")
        }
        return object
    }

    private func parseTokenResponse(
        _ json: [String: Any],
        issuedClientID: String,
        extAgentHostID: String,
        expectedNonce: String?,
        fallback: DesktopSIWCCredentials?
    ) async throws -> DesktopSIWCCredentials {
        guard let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw DesktopSIWCError.tokenExchangeFailed("Token 响应缺少 access_token。")
        }
        let refreshToken = ((json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty)
            ?? fallback?.refreshToken
            ?? ""
        guard !refreshToken.isEmpty else {
            throw DesktopSIWCError.tokenExchangeFailed("Token 响应缺少 refresh_token。")
        }

        let idToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty
            ?? fallback?.idToken

        var verified: DesktopSIWCVerifiedIDToken?
        if let rawIDToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).siwcNonEmpty {
            verified = try await verifyIDTokenWithJWKS(
                rawIDToken,
                expectedClientID: issuedClientID,
                expectedNonce: expectedNonce
            )
        } else if expectedNonce != nil {
            throw DesktopSIWCError.idTokenVerificationFailed("登录响应缺少 id_token。")
        }

        let returnedScopes: [String]
        if let scopeString = json["scope"] as? String {
            returnedScopes = scopeString
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        } else if let fallback {
            returnedScopes = fallback.scopes
        } else {
            returnedScopes = []
        }

        let now = nowMillis()
        let expiresInSeconds = Self.parseNumeric(json["expires_in"])
        let lifetimeMillis = expiresInSeconds.map { max(Int64($0 * 1000.0), 60_000) }
            ?? DesktopChatGPTSIWCConstants.fallbackTokenLifetimeMillis
        let expiresAtMillis = now + lifetimeMillis

        let earliestRefreshAtMillis: Int64
        if let serverEarliest = Self.parseEpochMillis(json["earliest_refresh_at"]) {
            earliestRefreshAtMillis = serverEarliest
        } else {
            earliestRefreshAtMillis = max(
                now + Int64(Double(lifetimeMillis) * 0.75),
                expiresAtMillis - DesktopChatGPTSIWCConstants.refreshSkewMillis
            )
        }

        return DesktopSIWCCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            clientId: issuedClientID,
            extAgentHostId: extAgentHostID,
            expiresAtMillis: expiresAtMillis,
            earliestRefreshAtMillis: min(earliestRefreshAtMillis, expiresAtMillis),
            scopes: returnedScopes,
            subject: verified?.subject ?? fallback?.subject,
            email: verified?.email ?? fallback?.email,
            name: verified?.name ?? fallback?.name,
            planType: verified?.planType ?? fallback?.planType
        )
    }

    private func verifyIDTokenWithJWKS(
        _ idToken: String,
        expectedClientID: String,
        expectedNonce: String?
    ) async throws -> DesktopSIWCVerifiedIDToken {
        let nowSeconds = TimeInterval(nowMillis()) / 1000.0
        let initialJWKS = try await fetchJWKS(forceRefresh: false)
        do {
            return try DesktopSIWCJWTVerifier.verify(
                idToken: idToken,
                expectedClientID: expectedClientID,
                expectedNonce: expectedNonce,
                jwks: initialJWKS,
                nowSeconds: nowSeconds
            )
        } catch DesktopSIWCError.idTokenVerificationFailed(let message) where message.contains("kid=") {
            // Key rotation: retry once with fresh JWKS before failing.
            let refreshedJWKS = try await fetchJWKS(forceRefresh: true)
            return try DesktopSIWCJWTVerifier.verify(
                idToken: idToken,
                expectedClientID: expectedClientID,
                expectedNonce: expectedNonce,
                jwks: refreshedJWKS,
                nowSeconds: nowSeconds
            )
        }
    }

    private func fetchJWKS(forceRefresh: Bool) async throws -> DesktopSIWCJWKS {
        if !forceRefresh, let cached = Self.refreshLock.withLock({ Self.cachedJWKS }) {
            return cached
        }
        var request = URLRequest(url: URL(string: DesktopChatGPTSIWCConstants.jwksEndpoint)!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DesktopSIWCError.idTokenVerificationFailed("无法获取 OpenAI JWKS 公钥（离线或网络受限）：\(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode),
              let jwks = try? JSONDecoder().decode(DesktopSIWCJWKS.self, from: data),
              !jwks.keys.isEmpty else {
            throw DesktopSIWCError.idTokenVerificationFailed("JWKS 公钥响应无效（HTTP \(response.statusCode)）。")
        }
        Self.refreshLock.withLock { Self.cachedJWKS = jwks }
        return jwks
    }

    static func clearCachedJWKSForTesting() {
        refreshLock.withLock { cachedJWKS = nil }
    }

    private static func parseNumeric(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Int64 { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func parseEpochMillis(_ raw: Any?) -> Int64? {
        guard let numeric = parseNumeric(raw), numeric > 0 else { return nil }
        // Accept both Unix seconds (~1.7e9) and Unix milliseconds (~1.7e12).
        return numeric < 10_000_000_000 ? Int64(numeric * 1000.0) : Int64(numeric)
    }

    private static func safeErrorDetail(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let desc = object["error_description"] as? String, !desc.isEmpty { return desc }
            if let err = object["error"] as? String, !err.isEmpty { return err }
            if let msg = object["message"] as? String, !msg.isEmpty { return msg }
        }
        return String(decoding: data.prefix(240), as: UTF8.self)
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.keys.sorted().compactMap { key -> String? in
            guard let value = params[key],
                  let k = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let v = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

// MARK: - Observable UI Controller

@MainActor protocol DesktopSIWCAuthorizer {
    func account(providerID: UUID) -> DesktopSIWCAccount?
    func signIn(providerID: UUID) async throws -> DesktopSIWCAccount
    func logout(providerID: UUID) async throws
    func deleteProvider(providerID: UUID) async throws
}

@MainActor final class DesktopMacSIWCAuthorizer: DesktopSIWCAuthorizer {
    func account(providerID: UUID) -> DesktopSIWCAccount? {
        DesktopSIWCAuthStore.load(providerId: providerID.uuidString.lowercased())?.account
    }

    func signIn(providerID: UUID) async throws -> DesktopSIWCAccount {
        try await DesktopChatGPTSIWCClient(providerId: providerID.uuidString.lowercased()).signIn()
    }

    func logout(providerID: UUID) async throws {
        let ok = await DesktopChatGPTSIWCClient(providerId: providerID.uuidString.lowercased()).logout()
        guard ok else { throw DesktopSIWCError.credentialStoreFailed }
    }

    func deleteProvider(providerID: UUID) async throws {
        let ok = await DesktopChatGPTSIWCClient(providerId: providerID.uuidString.lowercased()).deleteProvider()
        guard ok else { throw DesktopSIWCError.credentialStoreFailed }
    }
}

@MainActor @Observable final class DesktopSIWCLogin {
    private(set) var providerID: UUID?
    private(set) var account: DesktopSIWCAccount?
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var failed = false
    var showFirstTimePlanConfirmation = false

    @ObservationIgnored private let authorizer: any DesktopSIWCAuthorizer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var pending: [UUID: (providerID: UUID, task: Task<Void, Never>)] = [:]

    init(authorizer: any DesktopSIWCAuthorizer, defaults: UserDefaults = .standard) {
        self.authorizer = authorizer
        self.defaults = defaults
    }

    func selectProvider(_ id: UUID?) {
        cancel()
        providerID = id
        account = id.flatMap { authorizer.account(providerID: $0) }
        status = nil
        failed = false
    }

    func cancel() {
        token = nil
        task?.cancel()
        task = nil
        isBusy = false
    }

    func login(_ id: UUID, onSignedIn: (@MainActor (DesktopSIWCAccount) -> Void)? = nil) {
        cancel()
        providerID = id
        let request = UUID()
        token = request
        isBusy = true
        failed = false
        status = "正在打开系统浏览器，完成授权后此处将自动更新。"
        let launched = Task {
            defer {
                pending[request] = nil
                if token == request { task = nil; isBusy = false }
            }
            do {
                let signedIn = try await authorizer.signIn(providerID: id)
                guard token == request else { return }
                account = signedIn
                if signedIn.planAvailable {
                    failed = false
                    status = "已登录 ChatGPT 套餐，凭证已保存到系统钥匙串。"
                    if !defaults.bool(forKey: DesktopChatGPTSIWCConstants.planConfirmedDefaultsKey) {
                        showFirstTimePlanConfirmation = true
                    }
                } else {
                    failed = true
                    status = DesktopSIWCError.planScopeUnavailable.localizedDescription
                }
                onSignedIn?(signedIn)
            } catch is CancellationError {
                guard token == request else { return }
                status = nil
                failed = false
            } catch {
                guard token == request else { return }
                failed = true
                status = error.localizedDescription
            }
        }
        task = launched
        pending[request] = (id, launched)
    }

    func acknowledgePlanConfirmation() {
        defaults.set(true, forKey: DesktopChatGPTSIWCConstants.planConfirmedDefaultsKey)
        showFirstTimePlanConfirmation = false
    }

    func logout(_ id: UUID) {
        let previous = pending.values.filter { $0.providerID == id }.map(\.task)
        for item in previous { item.cancel() }
        cancel()
        providerID = id
        let request = UUID()
        token = request
        isBusy = true
        status = nil
        failed = false
        let launched = Task {
            defer {
                pending[request] = nil
                if token == request { task = nil; isBusy = false }
            }
            for item in previous { await item.value }
            do {
                try await authorizer.logout(providerID: id)
                guard token == request else { return }
                account = nil
                status = "已退出 ChatGPT 登录，服务商和模型配置已保留。"
            } catch {
                guard token == request else { return }
                failed = true
                status = error.localizedDescription
            }
        }
        task = launched
        pending[request] = (id, launched)
    }

    func waitUntilIdle() async { await task?.value }

    func removeCredentials(_ id: UUID) async throws {
        let previous = pending.values.filter { $0.providerID == id }.map(\.task)
        for item in previous { item.cancel() }
        cancel()
        for item in previous { await item.value }
        try await authorizer.deleteProvider(providerID: id)
    }
}
