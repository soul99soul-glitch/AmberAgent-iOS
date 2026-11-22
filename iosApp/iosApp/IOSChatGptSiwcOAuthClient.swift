import CryptoKit
import Foundation
import Network
import Security
@preconcurrency import Shared

enum IOSChatGptSiwcConstants {
    static let issuer = "https://auth.openai.com"
    static let authorizeEndpoint = "https://auth.openai.com/api/accounts/authorize"
    static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    static let revocationEndpoint = "https://auth.openai.com/api/accounts/oauth/revoke"
    static let jwksEndpoint = "https://auth.openai.com/.well-known/jwks.json"
    static let apiBaseUrl = "https://api.openai.com/v1"
    static let modelsEndpoint = "https://api.openai.com/v1/models"
    static let usageSettingsUrl = "https://chatgpt.com/settings/usage"
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let requiredDirectTokenScope = "chatgpt.tokens.use.direct"
    static let dynamicClientId = "dynamic_agent_client"
    static let agentNameHint = "Amber"
    static let callbackPath = "/auth/callback"
    static let refreshSkewMillis: Int64 = 120_000
    static let fallbackTokenLifetimeMillis: Int64 = 3_600_000
    static let jwtClockSkewSeconds: TimeInterval = 60
}

struct IOSChatGptSiwcOAuthError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct IOSChatGptSiwcCredentials: Codable, Equatable, Sendable {
    let clientId: String
    let accessToken: String
    let refreshToken: String
    let expiresAtMillis: Int64
    let scope: String
    let idToken: String?
    let subject: String?
    let email: String?
    let name: String?

    func belongsToSameAccount(as other: Self) -> Bool {
        clientId == other.clientId && subject == other.subject
    }

    func canReuse(rejectedAccessToken: String?) -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return expiresAtMillis > now + IOSChatGptSiwcConstants.refreshSkewMillis && accessToken != rejectedAccessToken
    }
}

struct IOSChatGptSiwcRegistrationRecord: Codable, Equatable, Sendable {
    let clientId: String
    let lastIdToken: String?
    let lastEmail: String?
    let subject: String?
}

struct IOSChatGptSiwcAuthRequest: Equatable, Sendable {
    let authorizeURL: URL
    let redirectUri: String
    let clientId: String
    let state: String
    let nonce: String
    let codeVerifier: String
    let codeChallenge: String
    let hostId: String
    let isDynamicRegistration: Bool
    let expectedSubject: String?
}

struct IOSChatGptSiwcCallbackResult: Equatable, Sendable {
    let code: String
    let state: String
    let issuedClientId: String
}

struct IOSChatGptSiwcModelItem: Equatable, Sendable {
    let slug: String
    let displayName: String
}

struct IOSChatGptSiwcIdTokenClaims: Equatable, Sendable {
    let issuer: String
    let audiences: [String]
    let subject: String
    let nonce: String?
    let expiresAt: TimeInterval
    let email: String?
    let name: String?
}

// MARK: - Persistent per-device host id (`ext_agent_host_id`)

/// Persists one stable `urn:uuid:<uuidv4>` per device in the Keychain side-table.
/// Never rotated or cleared across sign-outs or re-authentications.
enum IOSChatGptSiwcHostIdStore {
    private static let lock = NSLock()
    private static let keychainKey = "chatgpt_siwc.device.ext_agent_host_id"
    nonisolated(unsafe) private static var cachedHostId: String?

    static func hostId() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedHostId, isValidHostId(cachedHostId) {
            return cachedHostId
        }
        if let stored = IOSCredentialSideTable.load(key: keychainKey),
           isValidHostId(stored) {
            cachedHostId = stored
            return stored
        }
        let generated = "urn:uuid:\(UUID().uuidString.lowercased())"
        guard let persisted = IOSCredentialSideTable.insertDeviceValueIfAbsent(key: keychainKey, value: generated),
              isValidHostId(persisted) else {
            throw IOSChatGptSiwcOAuthError(message: "无法从 Keychain 读取或保存 ChatGPT 设备标识，请解锁后重试。")
        }
        cachedHostId = persisted
        return persisted
    }

    static func isValidHostId(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("urn:uuid:") else { return false }
        let uuidPart = String(lower.dropFirst("urn:uuid:".count))
        return UUID(uuidString: uuidPart) != nil
    }
}

// MARK: - Keychain credential & registration store

enum IOSChatGptSiwcAuthStore {
    enum RefreshCommitResult: Equatable, Sendable {
        case saved
        case storeFailed
        case credentialsChanged
    }

    private static let mutationLock = NSLock()
    private static let firstSignInDefaultsPrefix = "app.amber.ios.chatgpt_siwc.first_confirmed."
    nonisolated(unsafe) private static var decodedCredentialsCache: [String: (raw: String, value: IOSChatGptSiwcCredentials)] = [:]
    nonisolated(unsafe) private static var decodedRegistrationCache: [String: (raw: String, value: IOSChatGptSiwcRegistrationRecord)] = [:]

    static func credentialKey(providerId: String) -> String { "chatgpt_siwc.\(providerId).tokens" }
    static func registrationKey(providerId: String) -> String { "chatgpt_siwc.\(providerId).registration" }

    static func load(providerId: String) -> IOSChatGptSiwcCredentials? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return loadLocked(providerId: providerId)
    }

    @discardableResult
    static func save(providerId: String, credentials: IOSChatGptSiwcCredentials) -> Bool {
        guard credentials.clientId != IOSChatGptSiwcConstants.dynamicClientId,
              let raw = encoded(credentials) else { return false }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let saved = IOSCredentialSideTable.store(key: credentialKey(providerId: providerId), value: raw)
        if saved {
            decodedCredentialsCache[providerId] = (raw, credentials)
        } else {
            decodedCredentialsCache.removeValue(forKey: providerId)
        }
        return saved
    }

    static func loadRegistration(providerId: String) -> IOSChatGptSiwcRegistrationRecord? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if let active = loadLocked(providerId: providerId) {
            return IOSChatGptSiwcRegistrationRecord(
                clientId: active.clientId, lastIdToken: active.idToken, lastEmail: active.email, subject: active.subject
            )
        }
        let stored = loadRegistrationLocked(providerId: providerId)
        guard let registration = stored, let hint = registration.lastIdToken else { return stored }
        // Older signed-out records retained the previously verified ID token.
        let signedOut = IOSChatGptSiwcRegistrationRecord(
            clientId: registration.clientId, lastIdToken: nil, lastEmail: registration.lastEmail,
            subject: registration.subject ?? (IOSChatGptSiwcJwtVerifier.decodePayload(hint)?["sub"] as? String)
        )
        _ = saveRegistrationLocked(providerId: providerId, registration: signedOut)
        return signedOut
    }

    @discardableResult
    static func saveRegistration(providerId: String, registration: IOSChatGptSiwcRegistrationRecord) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return saveRegistrationLocked(providerId: providerId, registration: registration)
    }

    /// Atomically commits refreshed tokens only while the previous session is still current.
    static func saveRefreshedTokens(
        providerId: String,
        expected: IOSChatGptSiwcCredentials,
        refreshed: IOSChatGptSiwcCredentials
    ) -> RefreshCommitResult {
        guard let raw = encoded(refreshed) else { return .storeFailed }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard loadLocked(providerId: providerId) == expected else {
            return .credentialsChanged
        }
        let saved = IOSCredentialSideTable.store(key: credentialKey(providerId: providerId), value: raw)
        if saved {
            decodedCredentialsCache[providerId] = (raw, refreshed)
            return .saved
        }
        decodedCredentialsCache.removeValue(forKey: providerId)
        return .storeFailed
    }

    /// Keep the verified account mapping before dropping its active tokens.
    @discardableResult
    static func clearSession(providerId: String, matching expected: IOSChatGptSiwcCredentials? = nil) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let current = loadLocked(providerId: providerId)
        if let expected, expected != current { return false }
        if let active = current {
            let registration = IOSChatGptSiwcRegistrationRecord(
                clientId: active.clientId, lastIdToken: nil, lastEmail: active.email, subject: active.subject
            )
            guard saveRegistrationLocked(providerId: providerId, registration: registration) else { return false }
        }
        guard IOSCredentialSideTable.delete(key: credentialKey(providerId: providerId)) else { return false }
        decodedCredentialsCache.removeValue(forKey: providerId)
        return true
    }

    /// Clears all provider-scoped SIWC state (used when deleting a provider).
    /// The device-scoped `ext_agent_host_id` is never deleted.
    static func clearAll(providerId: String) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        decodedCredentialsCache.removeValue(forKey: providerId)
        decodedRegistrationCache.removeValue(forKey: providerId)
        IOSCredentialSideTable.delete(key: credentialKey(providerId: providerId))
        IOSCredentialSideTable.delete(key: registrationKey(providerId: providerId))
        UserDefaults.standard.removeObject(forKey: firstSignInDefaultsPrefix + providerId)
    }

    static func hasShownFirstSignInConfirmation(providerId: String) -> Bool {
        UserDefaults.standard.bool(forKey: firstSignInDefaultsPrefix + providerId)
    }

    static func markFirstSignInConfirmationShown(providerId: String) {
        UserDefaults.standard.set(true, forKey: firstSignInDefaultsPrefix + providerId)
    }

    private static func loadLocked(providerId: String) -> IOSChatGptSiwcCredentials? {
        guard let raw = IOSCredentialSideTable.load(key: credentialKey(providerId: providerId)) else {
            decodedCredentialsCache.removeValue(forKey: providerId)
            return nil
        }
        if let cached = decodedCredentialsCache[providerId], cached.raw == raw {
            return cached.value
        }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(IOSChatGptSiwcCredentials.self, from: data) else {
            decodedCredentialsCache.removeValue(forKey: providerId)
            return nil
        }
        decodedCredentialsCache[providerId] = (raw, value)
        return value
    }

    private static func loadRegistrationLocked(providerId: String) -> IOSChatGptSiwcRegistrationRecord? {
        guard let raw = IOSCredentialSideTable.load(key: registrationKey(providerId: providerId)) else {
            decodedRegistrationCache.removeValue(forKey: providerId)
            return nil
        }
        if let cached = decodedRegistrationCache[providerId], cached.raw == raw {
            return cached.value
        }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(IOSChatGptSiwcRegistrationRecord.self, from: data) else {
            decodedRegistrationCache.removeValue(forKey: providerId)
            return nil
        }
        decodedRegistrationCache[providerId] = (raw, value)
        return value
    }

    @discardableResult
    private static func saveRegistrationLocked(
        providerId: String,
        registration: IOSChatGptSiwcRegistrationRecord
    ) -> Bool {
        guard registration.clientId != IOSChatGptSiwcConstants.dynamicClientId,
              let raw = encoded(registration) else { return false }
        let saved = IOSCredentialSideTable.store(key: registrationKey(providerId: providerId), value: raw)
        if saved {
            decodedRegistrationCache[providerId] = (raw, registration)
        } else {
            decodedRegistrationCache.removeValue(forKey: providerId)
        }
        return saved
    }

    private static func encoded<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return raw
    }
}

// MARK: - JWKS cache & ID Token cryptographic verification

struct IOSChatGptSiwcJwk: Codable, Sendable {
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

struct IOSChatGptSiwcJwksDocument: Codable, Sendable {
    let keys: [IOSChatGptSiwcJwk]
}

actor IOSChatGptSiwcJwksCache {
    static let shared = IOSChatGptSiwcJwksCache()

    private var cachedKeys: [IOSChatGptSiwcJwk] = []
    private var fetchedAt: Date = .distantPast
    private let ttl: TimeInterval = 300

    func keys(session: URLSession, forceRefresh: Bool = false) async throws -> [IOSChatGptSiwcJwk] {
        if !forceRefresh, !cachedKeys.isEmpty, Date().timeIntervalSince(fetchedAt) < ttl {
            return cachedKeys
        }
        guard let url = URL(string: IOSChatGptSiwcConstants.jwksEndpoint) else {
            throw IOSChatGptSiwcOAuthError(message: "无效的 OpenAI JWKS 地址。")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IOSChatGptSiwcOAuthError(message: "获取 OpenAI JWKS 公钥失败（HTTP \(status)）。")
        }
        let doc = try JSONDecoder().decode(IOSChatGptSiwcJwksDocument.self, from: data)
        guard !doc.keys.isEmpty else {
            throw IOSChatGptSiwcOAuthError(message: "OpenAI JWKS 未返回可用公钥。")
        }
        cachedKeys = doc.keys
        fetchedAt = Date()
        return doc.keys
    }
}

enum IOSChatGptSiwcJwtVerifier {
    static func verifyIdToken(
        _ idToken: String,
        expectedClientId: String,
        expectedNonce: String?,
        jwks: [IOSChatGptSiwcJwk],
        now: Date = Date()
    ) throws -> IOSChatGptSiwcIdTokenClaims {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 格式无效。")
        }
        let headerB64 = String(segments[0])
        let payloadB64 = String(segments[1])
        let signatureB64 = String(segments[2])

        guard let headerData = base64URLDecode(headerB64),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let alg = header["alg"] as? String, !alg.isEmpty,
              let payloadData = base64URLDecode(payloadB64),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let signatureData = base64URLDecode(signatureB64) else {
            throw IOSChatGptSiwcOAuthError(message: "无法解析 ID Token 头部或载荷。")
        }

        let kid = header["kid"] as? String
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)

        let candidateKeys = matchingKeys(in: jwks, kid: kid, alg: alg)
        guard !candidateKeys.isEmpty else {
            throw IOSChatGptSiwcOAuthError(message: "JWKS 中未找到与 ID Token 匹配的签名公钥。")
        }

        var signatureVerified = false
        for jwk in candidateKeys {
            if verifySignature(signingInput: signingInput, signature: signatureData, alg: alg, jwk: jwk) {
                signatureVerified = true
                break
            }
        }
        guard signatureVerified else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token JWKS 签名验证失败。")
        }

        return try validateClaims(
            payload,
            expectedClientId: expectedClientId,
            expectedNonce: expectedNonce,
            now: now
        )
    }

    static func validateClaims(
        _ payload: [String: Any],
        expectedClientId: String,
        expectedNonce: String?,
        now: Date = Date()
    ) throws -> IOSChatGptSiwcIdTokenClaims {
        guard let issuer = payload["iss"] as? String, issuer == IOSChatGptSiwcConstants.issuer else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 签发方（iss）不匹配。")
        }

        let audiences: [String]
        if let audString = payload["aud"] as? String {
            audiences = [audString]
        } else if let audArray = payload["aud"] as? [String] {
            audiences = audArray
        } else {
            audiences = []
        }
        guard audiences.contains(expectedClientId) else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 受众（aud）与颁布的 client_id 不匹配。")
        }

        guard let expNumber = payload["exp"] as? NSNumber else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 缺少过期时间（exp）。")
        }
        let exp = expNumber.doubleValue
        let nowSeconds = now.timeIntervalSince1970
        guard exp > nowSeconds - IOSChatGptSiwcConstants.jwtClockSkewSeconds else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 已过期。")
        }
        if let nbf = (payload["nbf"] as? NSNumber)?.doubleValue,
           nbf > nowSeconds + IOSChatGptSiwcConstants.jwtClockSkewSeconds {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 尚未生效（nbf）。")
        }

        let tokenNonce = payload["nonce"] as? String
        if let expectedNonce {
            guard tokenNonce == expectedNonce else {
                throw IOSChatGptSiwcOAuthError(message: "ID Token nonce 校验失败。")
            }
        }

        guard let subject = (payload["sub"] as? String).nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 缺少用户标识（sub）。")
        }

        let profileClaims = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = (payload["email"] as? String).nonBlank ?? (profileClaims?["email"] as? String).nonBlank
        let name = (payload["name"] as? String).nonBlank ?? (profileClaims?["name"] as? String).nonBlank

        return IOSChatGptSiwcIdTokenClaims(
            issuer: issuer,
            audiences: audiences,
            subject: subject,
            nonce: tokenNonce,
            expiresAt: exp,
            email: email,
            name: name
        )
    }

    static func decodePayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let data = base64URLDecode(String(segments[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func decodeHeaderKid(_ jwt: String) -> String? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let data = base64URLDecode(String(segments[0])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["kid"] as? String
    }

    private static func matchingKeys(in jwks: [IOSChatGptSiwcJwk], kid: String?, alg: String) -> [IOSChatGptSiwcJwk] {
        let expectedKty: String?
        if alg.hasPrefix("RS") || alg.hasPrefix("PS") {
            expectedKty = "RSA"
        } else if alg.hasPrefix("ES") {
            expectedKty = "EC"
        } else {
            expectedKty = nil
        }
        return jwks.filter { key in
            if let expectedKty, key.kty.uppercased() != expectedKty { return false }
            if let keyAlgorithm = key.alg, keyAlgorithm != alg { return false }
            if let use = key.use, use != "sig" { return false }
            if let kid, !kid.isEmpty {
                return key.kid == kid
            }
            return true
        }
    }

    private static func verifySignature(
        signingInput: Data,
        signature: Data,
        alg: String,
        jwk: IOSChatGptSiwcJwk
    ) -> Bool {
        switch alg {
        case "RS256", "RS384", "RS512", "PS256", "PS384", "PS512":
            guard let secKey = makeRSAPublicKey(from: jwk),
                  let secAlg = rsaAlgorithm(for: alg) else { return false }
            return SecKeyVerifySignature(secKey, secAlg, signingInput as CFData, signature as CFData, nil)

        case "ES256", "ES384", "ES512":
            guard let secAlg = ecAlgorithm(for: alg, curve: jwk.crv),
                  let (secKey, coordinateBytes) = makeECPublicKey(from: jwk),
                  let derSignature = rawECDSASignatureToDER(signature, coordinateBytes: coordinateBytes) else {
                return false
            }
            return SecKeyVerifySignature(secKey, secAlg, signingInput as CFData, derSignature as CFData, nil)

        default:
            return false
        }
    }

    private static func rsaAlgorithm(for alg: String) -> SecKeyAlgorithm? {
        switch alg {
        case "RS256": .rsaSignatureMessagePKCS1v15SHA256
        case "RS384": .rsaSignatureMessagePKCS1v15SHA384
        case "RS512": .rsaSignatureMessagePKCS1v15SHA512
        case "PS256": .rsaSignatureMessagePSSSHA256
        case "PS384": .rsaSignatureMessagePSSSHA384
        case "PS512": .rsaSignatureMessagePSSSHA512
        default: nil
        }
    }

    private static func ecAlgorithm(for alg: String, curve: String?) -> SecKeyAlgorithm? {
        switch (alg, curve) {
        case ("ES256", "P-256"): .ecdsaSignatureMessageX962SHA256
        case ("ES384", "P-384"): .ecdsaSignatureMessageX962SHA384
        case ("ES512", "P-521"): .ecdsaSignatureMessageX962SHA512
        default: nil
        }
    }

    private static func makeRSAPublicKey(from jwk: IOSChatGptSiwcJwk) -> SecKey? {
        guard jwk.kty.uppercased() == "RSA",
              let nStr = jwk.n, let eStr = jwk.e,
              let modulus = base64URLDecode(nStr),
              let exponent = base64URLDecode(eStr),
              !modulus.isEmpty, !exponent.isEmpty else {
            return nil
        }
        let pkcs1 = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil)
    }

    private static func makeECPublicKey(from jwk: IOSChatGptSiwcJwk) -> (SecKey, Int)? {
        guard jwk.kty.uppercased() == "EC",
              let crv = jwk.crv,
              let xStr = jwk.x, let yStr = jwk.y,
              let xRaw = base64URLDecode(xStr),
              let yRaw = base64URLDecode(yStr) else {
            return nil
        }
        let coordinateBytes: Int
        switch crv {
        case "P-256": coordinateBytes = 32
        case "P-384": coordinateBytes = 48
        case "P-521": coordinateBytes = 66
        default: return nil
        }
        guard let x = leftPadded(xRaw, to: coordinateBytes),
              let y = leftPadded(yRaw, to: coordinateBytes) else {
            return nil
        }
        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil) else {
            return nil
        }
        return (key, coordinateBytes)
    }

    private static func rawECDSASignatureToDER(_ raw: Data, coordinateBytes: Int) -> Data? {
        guard raw.count == coordinateBytes * 2 else { return nil }
        let r = raw.prefix(coordinateBytes)
        let s = raw.suffix(coordinateBytes)
        return derSequence(derInteger(Data(r)) + derInteger(Data(s)))
    }

    private static func leftPadded(_ data: Data, to length: Int) -> Data? {
        if data.count == length { return data }
        if data.count < length {
            return Data(repeating: 0, count: length - data.count) + data
        }
        // Strip leading zero padding if any.
        let trimmed = data.drop(while: { $0 == 0 })
        guard trimmed.count <= length else { return nil }
        return Data(repeating: 0, count: length - trimmed.count) + trimmed
    }

    private static func derInteger(_ unsignedBigEndian: Data) -> Data {
        var bytes = [UInt8](unsignedBigEndian.drop(while: { $0 == 0 }))
        if bytes.isEmpty {
            bytes = [0x00]
        } else if (bytes[0] & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return Data([0x02]) + derLength(bytes.count) + Data(bytes)
    }

    private static func derSequence(_ body: Data) -> Data {
        Data([0x30]) + derLength(body.count) + body
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var remaining = length
        var octets: [UInt8] = []
        while remaining > 0 {
            octets.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(octets.count)]) + Data(octets)
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Loopback HTTP callback server (`127.0.0.1:<ephemeral>/auth/callback`)

final class IOSChatGptSiwcLoopbackServer: @unchecked Sendable {
    private final class PortContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?

        init(_ continuation: CheckedContinuation<UInt16, Error>) {
            self.continuation = continuation
        }

        func resumeOnce(_ result: Result<UInt16, Error>) {
            let cont: CheckedContinuation<UInt16, Error>? = lock.withLock {
                let current = continuation
                continuation = nil
                return current
            }
            cont?.resume(with: result)
        }
    }

    private let queue = DispatchQueue(label: "app.amber.ios.chatgpt-siwc.loopback")
    private let lock = NSLock()
    let state = UUID().uuidString
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var boundPort: UInt16 = 0
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var deliveredCallback: URL?
    private var terminalError: Error?
    private var stopped = false

    func start() async throws -> String {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = PortContinuationBox(continuation)

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue, port > 0 {
                        self?.setBoundPort(port)
                        box.resumeOnce(.success(port))
                    } else {
                        box.resumeOnce(.failure(IOSChatGptSiwcOAuthError(message: "本地回环监听未能分配可用端口。")))
                    }
                case let .failed(error):
                    let err = IOSChatGptSiwcOAuthError(message: "本地回环监听启动失败：\(error.localizedDescription)")
                    box.resumeOnce(.failure(err))
                    self?.failWaiting(with: err)
                case .cancelled:
                    box.resumeOnce(.failure(CancellationError()))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            lock.withLock {
                guard !stopped else {
                    box.resumeOnce(.failure(CancellationError()))
                    return
                }
                self.listener = listener
                listener.start(queue: queue)
            }
        }

        return "http://127.0.0.1:\(port)\(IOSChatGptSiwcConstants.callbackPath)"
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerCallbackContinuation(continuation)
            }
        } onCancel: {
            self.stop()
        }
    }

    private func registerCallbackContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        enum ImmediateOutcome {
            case delivered(URL)
            case failed(Error)
            case cancelled
            case pending
        }
        let outcome: ImmediateOutcome = lock.withLock {
            if let deliveredCallback { return .delivered(deliveredCallback) }
            if let terminalError { return .failed(terminalError) }
            if stopped { return .cancelled }
            callbackContinuation = continuation
            return .pending
        }
        switch outcome {
        case let .delivered(url):
            continuation.resume(returning: url)
        case let .failed(error):
            continuation.resume(throwing: error)
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        case .pending:
            break
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        let activeListener = listener
        listener = nil
        let openConnections = connections.values
        connections.removeAll()
        lock.unlock()

        activeListener?.cancel()
        openConnections.forEach { $0.cancel() }
        continuation?.resume(throwing: CancellationError())
    }

    private func setBoundPort(_ port: UInt16) {
        lock.lock()
        boundPort = port
        lock.unlock()
    }

    private func failWaiting(with error: Error) {
        lock.lock()
        guard !stopped, deliveredCallback == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func deliver(_ callbackURL: URL) {
        lock.lock()
        guard !stopped, terminalError == nil, deliveredCallback == nil else {
            lock.unlock()
            return
        }
        deliveredCallback = callbackURL
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()

        stop()
        continuation?.resume(returning: callbackURL)
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = lock.withLock {
            guard !stopped else { return false }
            connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state {
                    self?.lock.withLock { self?.connections[id] = nil }
                }
            }
            connection.start(queue: queue)
            return true
        }
        guard accepted else { connection.cancel(); return }
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        let limit = 16_384
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - buffer.count) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            let headerDelimiter = Data("\r\n\r\n".utf8)
            if let end = accumulated.range(of: headerDelimiter) {
                self.processRawRequest(accumulated[..<end.lowerBound], on: connection)
            } else if isComplete || error != nil || accumulated.count >= limit {
                self.sendHTTPResponse(status: "400 Bad Request", html: Self.errorHTML, on: connection) {}
            } else {
                self.receiveRequest(on: connection, buffer: accumulated)
            }
        }
    }

    private func processRawRequest(_ raw: Data, on connection: NWConnection) {
        guard let text = String(data: raw, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            sendHTTPResponse(status: "400 Bad Request", html: Self.errorHTML, on: connection) {}
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else {
            sendHTTPResponse(status: "400 Bad Request", html: Self.errorHTML, on: connection) {}
            return
        }
        let target = String(parts[1])
        lock.lock()
        let port = boundPort
        lock.unlock()

        guard let callbackURL = URL(string: "http://127.0.0.1:\(port)\(target)"),
              target.hasPrefix("/"),
              callbackURL.path == IOSChatGptSiwcConstants.callbackPath else {
            sendHTTPResponse(status: "404 Not Found", html: Self.notFoundHTML, on: connection) {}
            return
        }

        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state else {
            sendHTTPResponse(status: "400 Bad Request", html: Self.errorHTML, on: connection) {}
            return
        }
        let hasError = query.contains { $0.name == "error" && !($0.value ?? "").isEmpty }
        let html = hasError ? Self.errorHTML : Self.successHTML
        sendHTTPResponse(status: "200 OK", html: html, on: connection) { [weak self] in
            self?.deliver(callbackURL)
        }
    }

    private func sendHTTPResponse(
        status: String,
        html: String,
        on connection: NWConnection,
        completion: @escaping @Sendable () -> Void
    ) {
        let body = Data(html.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private static let successHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <title>Amber — Sign in with ChatGPT</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 24px; text-align: center; }
        .card { max-width: 360px; padding: 24px; border-radius: 16px; border: 1px solid rgba(128,128,128,.22); }
        h1 { font-size: 18px; margin: 0 0 8px; }
        p { font-size: 14px; opacity: .75; margin: 0; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Sign-in complete</h1>
        <p>Returning to Amber…</p>
      </div>
    </body>
    </html>
    """

    private static let errorHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <title>Amber — Sign in with ChatGPT</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 24px; text-align: center; }
        .card { max-width: 360px; padding: 24px; border-radius: 16px; border: 1px solid rgba(128,128,128,.22); }
        h1 { font-size: 18px; margin: 0 0 8px; }
        p { font-size: 14px; opacity: .75; margin: 0; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Authorization did not complete</h1>
        <p>You can close this page and return to Amber.</p>
      </div>
    </body>
    </html>
    """

    private static let notFoundHTML = "<!doctype html><html><body>Not Found</body></html>"
}

// MARK: - Main SIWC OAuth client

actor IOSChatGptSiwcOAuthClient {
    private let providerId: String
    private let session: URLSession
    private let jwksCache: IOSChatGptSiwcJwksCache

    init(
        providerId: String,
        session: URLSession = .shared,
        jwksCache: IOSChatGptSiwcJwksCache = .shared
    ) {
        self.providerId = providerId
        self.session = session
        self.jwksCache = jwksCache
    }

    nonisolated static func cached(providerId: String) -> IOSChatGptSiwcCredentials? {
        IOSChatGptSiwcAuthStore.load(providerId: providerId)
    }

    @MainActor
    func logout(onLocalSignOut: () -> Void = {}) async throws {
        let current = IOSChatGptSiwcAuthStore.load(providerId: providerId)
        guard IOSChatGptSiwcAuthStore.clearSession(providerId: providerId, matching: current) else {
            throw IOSChatGptSiwcOAuthError(message: "无法从 Keychain 清除当前凭据，请重试退出。")
        }
        onLocalSignOut()
        guard let current else { return }
        var request = URLRequest(url: URL(string: IOSChatGptSiwcConstants.revocationEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode([
            "token": current.refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientId,
        ]).utf8)
        let response = try? await dataWithRetry(for: request, retryServerError: true).1 as? HTTPURLResponse
        guard response?.statusCode == 200 else {
            throw IOSChatGptSiwcOAuthError(message: "已在本机退出，尚未确认服务端撤销。可在 ChatGPT 设置中断开连接。")
        }
    }

    // MARK: - Authorization URL & callback parsing

    nonisolated static func buildAuthorizationRequest(
        redirectUri: String,
        registration: IOSChatGptSiwcRegistrationRecord?,
        hostId: String? = nil,
        state: String? = nil,
        nonce: String? = nil,
        codeVerifier: String? = nil
    ) throws -> IOSChatGptSiwcAuthRequest {
        guard let redirectComponents = URLComponents(string: redirectUri),
              redirectComponents.scheme?.lowercased() == "http",
              redirectComponents.host == "127.0.0.1",
              redirectComponents.path == IOSChatGptSiwcConstants.callbackPath,
              let port = redirectComponents.port, port > 0 else {
            throw IOSChatGptSiwcOAuthError(message: "SIWC redirect_uri 必须为 http://127.0.0.1:<port>/auth/callback。")
        }

        let hostId = try hostId ?? IOSChatGptSiwcHostIdStore.hostId()
        let resolvedState = try state ?? randomBase64URL(byteCount: 24)
        let resolvedNonce = try nonce ?? randomBase64URL(byteCount: 24)
        let resolvedVerifier = try codeVerifier ?? randomBase64URL(byteCount: 32)
        let challenge = pkceS256Challenge(for: resolvedVerifier)

        let existingClientId = registration?.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDynamic = existingClientId == nil || existingClientId!.isEmpty || existingClientId == IOSChatGptSiwcConstants.dynamicClientId
        let clientId = isDynamic ? IOSChatGptSiwcConstants.dynamicClientId : existingClientId!

        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: IOSChatGptSiwcConstants.scope),
            URLQueryItem(name: "resource", value: IOSChatGptSiwcConstants.resource),
            URLQueryItem(name: "state", value: resolvedState),
            URLQueryItem(name: "nonce", value: resolvedNonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "ext_agent_host_id", value: hostId),
        ]

        if isDynamic {
            items.append(URLQueryItem(name: "agent_name_hint", value: IOSChatGptSiwcConstants.agentNameHint))
        } else {
            if let idTokenHint = registration?.lastIdToken.nonBlank {
                items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
            }
            if let loginHint = registration?.lastEmail.nonBlank {
                items.append(URLQueryItem(name: "login_hint", value: loginHint))
            }
        }

        var components = URLComponents(string: IOSChatGptSiwcConstants.authorizeEndpoint)!
        components.queryItems = items
        guard let url = components.url else {
            throw IOSChatGptSiwcOAuthError(message: "无法构造 Sign in with ChatGPT 授权地址。")
        }

        return IOSChatGptSiwcAuthRequest(
            authorizeURL: url,
            redirectUri: redirectUri,
            clientId: clientId,
            state: resolvedState,
            nonce: resolvedNonce,
            codeVerifier: resolvedVerifier,
            codeChallenge: challenge,
            hostId: hostId,
            isDynamicRegistration: isDynamic,
            expectedSubject: isDynamic ? nil : registration?.subject
        )
    }

    nonisolated static func parseAndValidateCallback(
        url: URL,
        expectedState: String,
        requestedClientId: String,
        isDynamicRegistration: Bool
    ) throws -> IOSChatGptSiwcCallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == IOSChatGptSiwcConstants.callbackPath else {
            throw IOSChatGptSiwcOAuthError(message: "回调路径无效，期望 \(IOSChatGptSiwcConstants.callbackPath)。")
        }

        let queryMap = (components.queryItems ?? []).reduce(into: [String: String]()) { map, item in
            if map[item.name] == nil, let value = item.value {
                map[item.name] = value
            }
        }

        guard let returnedState = queryMap["state"].nonBlank, returnedState == expectedState else {
            throw IOSChatGptSiwcOAuthError(message: "授权回调 state 校验失败，请重新登录。")
        }
        if let error = queryMap["error"].nonBlank {
            let description = queryMap["error_description"].nonBlank
            throw IOSChatGptSiwcOAuthError(message: description ?? "ChatGPT 授权被拒绝或失败（\(error)）。")
        }

        guard let code = queryMap["code"].nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "授权回调缺少 code 参数。")
        }

        let callbackClientId = queryMap["client_id"].nonBlank
        let issuedClientId: String
        if isDynamicRegistration {
            guard let callbackClientId,
                  callbackClientId != IOSChatGptSiwcConstants.dynamicClientId else {
                throw IOSChatGptSiwcOAuthError(message: "首次动态注册回调未返回颁布的 client_id。")
            }
            issuedClientId = callbackClientId
        } else {
            guard !requestedClientId.isEmpty, requestedClientId != IOSChatGptSiwcConstants.dynamicClientId,
                  callbackClientId == nil || callbackClientId == requestedClientId else {
                throw IOSChatGptSiwcOAuthError(message: "授权回调的 client_id 与所选账号不匹配。")
            }
            issuedClientId = requestedClientId
        }

        return IOSChatGptSiwcCallbackResult(
            code: code,
            state: returnedState,
            issuedClientId: issuedClientId
        )
    }

    // MARK: - Token exchange & refresh

    @MainActor
    func exchangeAuthorizationCode(
        request authRequest: IOSChatGptSiwcAuthRequest,
        callback: IOSChatGptSiwcCallbackResult
    ) async throws -> IOSChatGptSiwcCredentials {
        let form = Self.formEncode([
            "grant_type": "authorization_code",
            "code": callback.code,
            "redirect_uri": authRequest.redirectUri,
            "client_id": callback.issuedClientId,
            "code_verifier": authRequest.codeVerifier,
            "resource": IOSChatGptSiwcConstants.resource,
            "ext_agent_host_id": authRequest.hostId,
        ])
        var request = URLRequest(url: URL(string: IOSChatGptSiwcConstants.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.oauthError("ChatGPT SIWC 令牌交换失败", status: status, body: data)
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let accessToken = (obj["access_token"] as? String).nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT SIWC 响应缺少 access_token。")
        }
        guard let refreshToken = (obj["refresh_token"] as? String).nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT SIWC 响应缺少 refresh_token。")
        }
        guard let idToken = (obj["id_token"] as? String).nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT SIWC 响应缺少 id_token。")
        }

        let grantedScope = Self.resolveGrantedScope(tokenResponse: obj, accessToken: accessToken)
        guard Self.hasRequiredDirectTokenScope(grantedScope) else {
            throw IOSChatGptSiwcOAuthError(
                message: "ChatGPT 授权未包含所需权限（\(IOSChatGptSiwcConstants.requiredDirectTokenScope)），无法使用套餐共享推理。"
            )
        }

        let claims = try await verifyIdTokenWithJwks(
            idToken: idToken,
            expectedClientId: callback.issuedClientId,
            expectedNonce: authRequest.nonce,
            expectedSubject: authRequest.expectedSubject
        )

        let expiresAtMillis = Self.resolveExpiresAtMillis(tokenResponse: obj, accessToken: accessToken)
        let credentials = IOSChatGptSiwcCredentials(
            clientId: callback.issuedClientId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMillis: expiresAtMillis,
            scope: grantedScope,
            idToken: idToken,
            subject: claims.subject,
            email: claims.email,
            name: claims.name
        )

        try Task.checkCancellation()
        guard IOSChatGptSiwcAuthStore.save(providerId: providerId, credentials: credentials) else {
            throw IOSChatGptSiwcOAuthError(message: "无法将 ChatGPT SIWC 凭据安全保存到 Keychain。")
        }
        return credentials
    }

    func getValidAccessToken() async throws -> String {
        try await validCredentials().accessToken
    }

    private func validCredentials(afterRejection rejected: IOSChatGptSiwcCredentials? = nil) async throws -> IOSChatGptSiwcCredentials {
        guard let current = IOSChatGptSiwcAuthStore.load(providerId: providerId) else {
            throw IOSChatGptSiwcOAuthError(message: "尚未登录 ChatGPT 套餐，请先点击 Continue with ChatGPT 完成授权。")
        }
        if let rejected, !current.belongsToSameAccount(as: rejected) {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT 登录账号已变更，请重新获取模型。")
        }
        if current.canReuse(rejectedAccessToken: rejected?.accessToken) {
            return current
        }
        let key = IOSChatGptSiwcResolveCoordinator.Key(providerId: providerId, clientId: current.clientId, subject: current.subject)
        return try await IOSChatGptSiwcResolveCoordinator.shared.resolve(key: key) { [self] in
            guard let latest = IOSChatGptSiwcAuthStore.load(providerId: providerId), latest.belongsToSameAccount(as: current) else {
                throw IOSChatGptSiwcOAuthError(message: "ChatGPT 登录账号已变更，已取消令牌刷新。")
            }
            if latest.canReuse(rejectedAccessToken: rejected?.accessToken) { return latest }
            return try await refresh(latest)
        }
    }

    private func refresh(_ current: IOSChatGptSiwcCredentials) async throws -> IOSChatGptSiwcCredentials {
        let form = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": current.clientId,
            "resource": IOSChatGptSiwcConstants.resource,
            "ext_agent_host_id": try IOSChatGptSiwcHostIdStore.hostId(),
        ])
        var request = URLRequest(url: URL(string: IOSChatGptSiwcConstants.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.utf8)

        // A lost response may already have rotated the refresh token. Do not replay this grant.
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if (400..<500).contains(status), Self.isUnusableRefreshTokenResponse(data) {
                _ = IOSChatGptSiwcAuthStore.clearSession(providerId: providerId, matching: current)
                throw Self.oauthError("ChatGPT 会话已失效，请重新登录", status: status, body: data)
            }
            throw Self.oauthError("ChatGPT SIWC 令牌刷新失败", status: status, body: data)
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let accessToken = (obj["access_token"] as? String).nonBlank else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT SIWC 令牌刷新响应缺少 access_token。")
        }
        let rotatedRefresh = (obj["refresh_token"] as? String).nonBlank ?? current.refreshToken
        let refreshedScope = Self.resolveGrantedScope(
            tokenResponse: obj,
            accessToken: accessToken,
            fallback: current.scope
        )
        guard Self.hasRequiredDirectTokenScope(refreshedScope) else {
            _ = IOSChatGptSiwcAuthStore.clearSession(providerId: providerId, matching: current)
            throw IOSChatGptSiwcOAuthError(
                message: "刷新后的 ChatGPT 授权缺少 \(IOSChatGptSiwcConstants.requiredDirectTokenScope) 权限，请重新登录。"
            )
        }

        let refreshedIdToken = (obj["id_token"] as? String).nonBlank
        var subject = current.subject
        var email = current.email
        var name = current.name
        if let refreshedIdToken {
            let claims = try await verifyIdTokenWithJwks(
                idToken: refreshedIdToken,
                expectedClientId: current.clientId,
                expectedNonce: nil,
                expectedSubject: current.subject
            )
            subject = claims.subject
            email = claims.email ?? email
            name = claims.name ?? name
        }

        let merged = IOSChatGptSiwcCredentials(
            clientId: current.clientId,
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            expiresAtMillis: Self.resolveExpiresAtMillis(tokenResponse: obj, accessToken: accessToken),
            scope: refreshedScope,
            idToken: refreshedIdToken ?? current.idToken,
            subject: subject,
            email: email,
            name: name
        )

        switch IOSChatGptSiwcAuthStore.saveRefreshedTokens(
            providerId: providerId,
            expected: current,
            refreshed: merged
        ) {
        case .saved:
            return merged
        case .storeFailed:
            throw IOSChatGptSiwcOAuthError(message: "无法保存刷新后的 ChatGPT SIWC 凭据，请重试。")
        case .credentialsChanged:
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT 登录状态已变更，已取消过期的令牌刷新。")
        }
    }

    // MARK: - Model discovery (`GET https://api.openai.com/v1/models`)

    func fetchModelsOrThrow() async throws -> [IOSChatGptSiwcModelItem] {
        var credentials = try await validCredentials()
        var (data, response) = try await dataWithRetry(for: modelsRequest(bearer: credentials.accessToken))
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            credentials = try await validCredentials(afterRejection: credentials)
            (data, response) = try await dataWithRetry(for: modelsRequest(bearer: credentials.accessToken))
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard (200..<300).contains(status) else {
            throw Self.oauthError("获取 ChatGPT 模型列表失败", status: status, body: data)
        }
        guard IOSChatGptSiwcAuthStore.load(providerId: providerId)?.belongsToSameAccount(as: credentials) == true else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT 登录账号已变更，请重新获取模型。")
        }
        return try Self.parseModels(data)
    }

    nonisolated static func parseModels(_ data: Data) throws -> [IOSChatGptSiwcModelItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else {
            throw IOSChatGptSiwcOAuthError(message: "ChatGPT 模型列表响应缺少有效的 models 数组。")
        }
        var result: [IOSChatGptSiwcModelItem] = []
        var seen = Set<String>()
        for entry in entries {
            guard let visibility = (entry["visibility"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  visibility == "list" else {
                continue
            }
            guard let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty,
                  seen.insert(slug).inserted else {
                continue
            }
            let displayName = (entry["display_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDisplay = (displayName?.isEmpty == false) ? displayName! : slug
            result.append(IOSChatGptSiwcModelItem(slug: slug, displayName: resolvedDisplay))
        }
        return result
    }

    nonisolated static func kmpModels(from discovered: [IOSChatGptSiwcModelItem]) -> [Model] {
        discovered.map { item in
            Model(
                modelId: item.slug,
                displayName: item.displayName,
                id: KotlinUuid.companion.random(),
                type: ModelType.chat,
                customHeaders: [],
                customBodies: [],
                inputModalities: [Modality.text, Modality.image],
                outputModalities: [Modality.text],
                abilities: [ModelAbility.tool, ModelAbility.reasoning],
                tools: Set<BuiltInTools>(),
                contextWindowTokens: nil,
                providerOverwrite: nil
            )
        }
    }

    // MARK: - Helpers

    private func verifyIdTokenWithJwks(
        idToken: String,
        expectedClientId: String,
        expectedNonce: String?,
        expectedSubject: String?
    ) async throws -> IOSChatGptSiwcIdTokenClaims {
        let kid = IOSChatGptSiwcJwtVerifier.decodeHeaderKid(idToken)
        var keys = try await jwksCache.keys(session: session, forceRefresh: false)
        if let kid, !keys.contains(where: { $0.kid == kid }) {
            keys = try await jwksCache.keys(session: session, forceRefresh: true)
        }
        let claims = try IOSChatGptSiwcJwtVerifier.verifyIdToken(
            idToken,
            expectedClientId: expectedClientId,
            expectedNonce: expectedNonce,
            jwks: keys
        )
        guard expectedSubject == nil || expectedSubject == claims.subject else {
            throw IOSChatGptSiwcOAuthError(message: "ID Token 的账号标识（sub）与所选账号不匹配。")
        }
        return claims
    }

    private func modelsRequest(bearer: String) -> URLRequest {
        var request = URLRequest(url: URL(string: IOSChatGptSiwcConstants.modelsEndpoint)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func dataWithRetry(for request: URLRequest, retryServerError: Bool = false) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        do {
            let result = try await session.data(for: request)
            guard retryServerError, let http = result.1 as? HTTPURLResponse,
                  (500..<600).contains(http.statusCode) else {
                return result
            }
        } catch {
            guard Self.isTransientTransport(error) else { throw error }
        }
        try await Task.sleep(for: .milliseconds(350))
        return try await session.data(for: request)
    }

    nonisolated static func pkceS256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    nonisolated static func hasRequiredDirectTokenScope(_ scopeString: String) -> Bool {
        scopeString
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0 == Substring(IOSChatGptSiwcConstants.requiredDirectTokenScope) }
    }

    nonisolated static func resolveGrantedScope(
        tokenResponse: [String: Any],
        accessToken: String,
        fallback: String = ""
    ) -> String {
        if let explicit = tokenResponse["scope"] as? String {
            return explicit
        }
        if let claims = IOSChatGptSiwcJwtVerifier.decodePayload(accessToken) {
            if let claimScope = claims["scope"] as? String {
                return claimScope
            }
            if let scpArray = claims["scp"] as? [String] {
                return scpArray.joined(separator: " ")
            }
            if let scpString = claims["scp"] as? String {
                return scpString
            }
        }
        return fallback
    }

    private nonisolated static func resolveExpiresAtMillis(
        tokenResponse: [String: Any],
        accessToken: String
    ) -> Int64 {
        let now = nowMillis()
        if let expiresIn = (tokenResponse["expires_in"] as? NSNumber)?.int64Value, expiresIn > 0 {
            return max(now + expiresIn * 1000, now + IOSChatGptSiwcConstants.refreshSkewMillis)
        }
        if let claims = IOSChatGptSiwcJwtVerifier.decodePayload(accessToken),
           let exp = (claims["exp"] as? NSNumber)?.int64Value {
            return max(exp * 1000, now + IOSChatGptSiwcConstants.refreshSkewMillis)
        }
        return now + IOSChatGptSiwcConstants.fallbackTokenLifetimeMillis
    }

    private nonisolated static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw IOSChatGptSiwcOAuthError(message: "无法生成 ChatGPT 授权所需的随机值。")
        }
        return base64URLEncode(Data(bytes))
    }

    private nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func isTransientTransport(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return ns.code == NSURLErrorNetworkConnectionLost
            || ns.code == NSURLErrorTimedOut
            || ns.code == NSURLErrorCannotConnectToHost
            || ns.code == NSURLErrorNotConnectedToInternet
    }

    private nonisolated static func oauthError(_ prefix: String, status: Int, body: Data) -> IOSChatGptSiwcOAuthError {
        let detail = Self.safeOAuthError(body)
        return IOSChatGptSiwcOAuthError(
            message: detail.isEmpty ? "\(prefix)：HTTP \(status)" : "\(prefix)：\(detail)"
        )
    }

    private nonisolated static func safeOAuthError(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let v = (obj["error_description"] as? String).nonBlank { return v }
            if let errObj = obj["error"] as? [String: Any],
               let msg = (errObj["message"] as? String).nonBlank { return msg }
            if let v = (obj["error"] as? String).nonBlank { return v }
            if let v = (obj["message"] as? String).nonBlank { return v }
        }
        return String((String(data: body, encoding: .utf8) ?? "").prefix(240))
    }

    private nonisolated static func isUnusableRefreshTokenResponse(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = object["error"] as? String ?? (object["error"] as? [String: Any])?["code"] as? String else {
            return false
        }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }

    private nonisolated static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private nonisolated static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.sorted(by: { $0.key < $1.key }).map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

actor IOSChatGptSiwcResolveCoordinator {
    static let shared = IOSChatGptSiwcResolveCoordinator()

    struct Key: Hashable {
        let providerId: String
        let clientId: String
        let subject: String?
    }

    private var inFlight: [Key: Task<IOSChatGptSiwcCredentials, Error>] = [:]

    func resolve(
        key: Key,
        _ operation: @escaping @Sendable () async throws -> IOSChatGptSiwcCredentials
    ) async throws -> IOSChatGptSiwcCredentials {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
