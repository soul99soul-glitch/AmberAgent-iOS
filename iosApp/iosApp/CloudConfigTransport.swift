import CryptoKit
import Foundation
import Security

// MARK: - Contract DTOs (docs/architecture/cloud-configuration-api.md v1)

/// `ConfigurationView` — GET /v2/configuration. Non-secret only.
struct IOSCloudConfigViewDTO: Decodable, Sendable {
    struct Model: Decodable, Sendable { var provider: String; var modelId: String; var baseUrl: String }
    struct Search: Decodable, Sendable { var sources: [String]; var mode: String }
    struct Configured: Decodable, Sendable { var configured: Bool }
    struct Credentials: Decodable, Sendable {
        var modelApiKey: Configured
        var exaApiKey: Configured
        var braveApiKey: Configured
    }
    var gatewayId: String
    var revision: Int
    var model: Model
    var search: Search
    var credentials: Credentials
    var supportedModelProviders: [String] = ["openai", "claude"]
    var supportedSearchSources: [String] = ["bing", "duckduckgo", "exa", "brave"]
}

/// `ConfigurationImportKey` — GET /v2/configuration/import-key. Public key
/// material only; the daemon's private key never leaves its vault.
struct IOSCloudImportKeyDTO: Decodable, Sendable {
    struct Jwk: Decodable, Sendable {
        var kty: String
        var kid: String?
        var alg: String?
        var use: String?
        var n: String
        var e: String
    }
    var version: Int = 1
    var gatewayId: String
    var deviceId: String
    var kid: String
    var alg: String = "RSA-OAEP-256"
    var enc: String = "A256GCM"
    var publicJwk: Jwk
    var publicKeySpkiDerBase64: String
    var serverTime: Int64
    var maxEnvelopeLifetimeSeconds: Int64 = 300
}

/// `ConfigurationReceipt` — POST /v2/configuration success body.
struct IOSCloudConfigReceiptDTO: Decodable, Sendable {
    var requestId: String
    var revision: Int
    var currentRevision: Int
    var replayed: Bool
    var effective: String
}

// MARK: - Typed errors (contract error codes, no user input echoed)

/// The contract's fixed error codes mapped to typed cases, plus the two
/// client-side trust failures. Never carries request bodies or key material.
enum IOSCloudConfigError: LocalizedError, Equatable {
    /// Gateway answers the path as unknown — older gateway, feature unavailable.
    case notFound
    /// 403 untrusted_device — the device isn't a trusted approval surface.
    case untrustedDevice
    /// 503 configuration_unavailable — daemon vault unavailable.
    case unavailable
    /// 400 invalid_envelope — ciphertext/binding/header rejected.
    case invalidEnvelope
    /// 400 invalid_request — body shape or parameter rejected.
    case invalidRequest
    /// 413 request_too_large.
    case tooLarge
    /// 422 invalid_configuration — validation failed; nothing was modified.
    case invalidConfiguration
    /// 422 credential_action_required — model destination changed while the
    /// cloud still holds a key; an explicit replace/delete is required.
    case credentialActionRequired
    /// 410 envelope_expired.
    case envelopeExpired
    /// 409 revision_conflict — carries the server's current revision.
    case revisionConflict(current: Int?)
    /// 409 request_id_conflict — same requestId was used for a different operation.
    case requestIdConflict
    /// The pinned import kid no longer matches what the gateway presents —
    /// re-confirmation of trust is required before any upload continues.
    case importKeyChanged
    /// Response didn't match the contract (shape, kid math, SPKI/JWK mismatch).
    case malformedResponse
    /// SecKey/AES primitive failure while sealing.
    case cryptographyFailed

    var errorDescription: String? {
        switch self {
        case .notFound:
            IOSAppLocalization.string("云端接口待接入，等待服务端更新", defaultValue: "云端接口待接入，等待服务端更新")
        case .untrustedDevice:
            IOSAppLocalization.string("此设备不是云端认可的受信管理端，请检查 Mac 上的设备授权", defaultValue: "此设备不是云端认可的受信管理端，请检查 Mac 上的设备授权")
        case .unavailable:
            IOSAppLocalization.string("云端配置存储暂不可用，请稍后重试", defaultValue: "云端配置存储暂不可用，请稍后重试")
        case .invalidEnvelope, .invalidRequest:
            IOSAppLocalization.string("加密封装被云端拒绝，请重试或更新 App", defaultValue: "加密封装被云端拒绝，请重试或更新 App")
        case .tooLarge:
            IOSAppLocalization.string("导入内容超出云端允许的大小", defaultValue: "导入内容超出云端允许的大小")
        case .invalidConfiguration:
            IOSAppLocalization.string("云端拒绝了该配置（参数不合法），原配置保持不变", defaultValue: "云端拒绝了该配置（参数不合法），原配置保持不变")
        case .credentialActionRequired:
            IOSAppLocalization.string("云端已保存旧模型 Key：切换服务商或地址时需携带本机 Key，或先删除云端旧 Key", defaultValue: "云端已保存旧模型 Key：切换服务商或地址时需携带本机 Key，或先删除云端旧 Key")
        case .envelopeExpired:
            IOSAppLocalization.string("封装已过期，请重试", defaultValue: "封装已过期，请重试")
        case .revisionConflict:
            IOSAppLocalization.string("云端配置刚被其他设备修改，已为你刷新，请核对后重试", defaultValue: "云端配置刚被其他设备修改，已为你刷新，请核对后重试")
        case .requestIdConflict:
            IOSAppLocalization.string("请求标识冲突，请重试", defaultValue: "请求标识冲突，请重试")
        case .importKeyChanged:
            IOSAppLocalization.string("云端导入公钥与已固定的不一致：可能是服务端重装或网络被劫持。确认 Mac 状态后重新信任再继续", defaultValue: "云端导入公钥与已固定的不一致：可能是服务端重装或网络被劫持。确认 Mac 状态后重新信任再继续")
        case .malformedResponse:
            IOSAppLocalization.string("云端返回了无法识别的数据", defaultValue: "云端返回了无法识别的数据")
        case .cryptographyFailed:
            IOSAppLocalization.string("本机加密封装失败", defaultValue: "本机加密封装失败")
        }
    }
}

// MARK: - kid pinning (Keychain)

/// Persists the import public key's RFC7638 kid per gateway. Trust-on-first-use
/// over the already-paired HTTPS/SPKI channel; a later mismatch is a hard stop
/// (never auto-update), cleared only by the user's explicit re-trust action.
struct IOSCloudImportKidStore: Sendable {
    var load: @Sendable (String) -> String?
    var store: @Sendable (String, String) -> Void
    var delete: @Sendable (String) -> Void

    /// In-memory implementation for tests — never touches the real Keychain.
    static func ephemeral() -> IOSCloudImportKidStore {
        final class Box: @unchecked Sendable { var kids: [String: String] = [:]; let lock = NSLock() }
        let box = Box()
        return IOSCloudImportKidStore(
            load: { key in box.lock.lock(); defer { box.lock.unlock() }; return box.kids[key] },
            store: { key, kid in box.lock.lock(); box.kids[key] = kid; box.lock.unlock() },
            delete: { key in box.lock.lock(); box.kids.removeValue(forKey: key); box.lock.unlock() }
        )
    }

    static let live = IOSCloudImportKidStore(
        load: { keychainLoad(account: "config-import-kid.\($0)") },
        store: { keychainStore(account: "config-import-kid.\($0)", value: $1) },
        delete: { keychainDelete(account: "config-import-kid.\($0)") }
    )

    private static let service = "app.amber.ios.gateway-config"

    private static func keychainStore(account: String, value: String) {
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Import key verification + JWE sealing (RFC7516 compact)

/// Import public key after all contract checks pass: RFC7638 recomputed kid,
/// SPKI↔JWK consistency, fixed alg/enc, and kid pinning vs. the store.
struct IOSCloudVerifiedImportKey: @unchecked Sendable {
    var kid: String
    var deviceId: String
    /// Daemon's clock at key response time; `issuedAt` is anchored to it so a
    /// drifting device clock can't produce an out-of-window envelope.
    var serverTime: Int64
    var maxEnvelopeLifetimeSeconds: Int64
    /// RSA-3072 public key usable by `SecKeyCreateEncryptedData` (.rsaEncryptionOAEPSHA256).
    var secKey: SecKey
}

enum IOSCloudConfigEnvelope {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC7638 JWK SHA-256 thumbprint: lexicographic JSON of {e,kty,n} only.
    static func jwkThumbprint(e: String, n: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["e": e, "kty": "RSA", "n": n], options: [.sortedKeys]
        ) else { return nil }
        return base64url(Data(SHA256.hash(data: data)))
    }

    /// Verifies a `ConfigurationImportKey` response: fixed version/alg/enc,
    /// gateway binding, recomputed kid == advertised kid, and the RSA
    /// modulus/exponent inside the SPKI DER == the JWK's n/e.
    static func verify(_ dto: IOSCloudImportKeyDTO, gatewayId: String) throws -> IOSCloudVerifiedImportKey {
        guard dto.version == 1, dto.alg == "RSA-OAEP-256", dto.enc == "A256GCM",
              dto.gatewayId == gatewayId, dto.publicJwk.kty == "RSA",
              dto.maxEnvelopeLifetimeSeconds > 0, dto.maxEnvelopeLifetimeSeconds <= 300
        else { throw IOSCloudConfigError.malformedResponse }
        guard let computed = jwkThumbprint(e: dto.publicJwk.e, n: dto.publicJwk.n), computed == dto.kid
        else { throw IOSCloudConfigError.malformedResponse }
        guard let spki = Data(base64Encoded: dto.publicKeySpkiDerBase64),
              let rsa = rsaPublicNumbers(inSPKI: spki),
              base64url(rsa.modulus) == dto.publicJwk.n, base64url(rsa.exponent) == dto.publicJwk.e
        else { throw IOSCloudConfigError.malformedResponse }
        // SecKeyCreateWithData expects the PKCS#1 RSAPublicKey that sits inside SPKI.
        var failure: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(rsa.pkcs1 as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ] as CFDictionary, &failure) else { throw IOSCloudConfigError.malformedResponse }
        return IOSCloudVerifiedImportKey(
            kid: dto.kid, deviceId: dto.deviceId, serverTime: dto.serverTime,
            maxEnvelopeLifetimeSeconds: dto.maxEnvelopeLifetimeSeconds, secKey: secKey
        )
    }

    /// Compact JWE: RSA-OAEP-256 key wrap + A256GCM with the protected segment's
    /// ASCII bytes as AAD. Header carries exactly alg/enc/kid/typ per contract.
    static func seal(payload: Data, key: IOSCloudVerifiedImportKey) throws -> String {
        let protected = base64url(try JSONSerialization.data(withJSONObject: [
            "alg": "RSA-OAEP-256", "enc": "A256GCM",
            "kid": key.kid, "typ": "amber-config+jwe",
        ], options: [.sortedKeys]))
        let cek = SymmetricKey(size: .bits256)
        let cekData = cek.withUnsafeBytes { Data($0) }
        var failure: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(key.secKey, .rsaEncryptionOAEPSHA256, cekData as CFData, &failure) as Data?
        else { throw IOSCloudConfigError.cryptographyFailed }
        guard let sealed = try? AES.GCM.seal(payload, using: cek, authenticating: Data(protected.utf8))
        else { throw IOSCloudConfigError.cryptographyFailed }
        return [protected, base64url(wrapped), base64url(Data(sealed.nonce)), base64url(sealed.ciphertext), base64url(sealed.tag)]
            .joined(separator: ".")
    }

    /// Extracts the RSA public numbers and the raw PKCS#1 RSAPublicKey from an
    /// X.509 SubjectPublicKeyInfo DER: SEQ{ SEQ{OID,NULL}, BIT STRING{PKCS1} }.
    static func rsaPublicNumbers(inSPKI spki: Data) -> (pkcs1: Data, modulus: Data, exponent: Data)? {
        var topOffset = 0
        guard let topSequence = try? derValue(Array(spki), &topOffset, tag: 0x30) else { return nil }
        var offset = 0
        guard (try? derValue(topSequence, &offset, tag: 0x30)) != nil,
              let bits = try? derValue(topSequence, &offset, tag: 0x03),
              bits.first == 0 else { return nil }
        let pkcs1 = Data(bits.dropFirst())
        var rsaOffset = 0
        guard let rsaSequence = try? derValue(Array(pkcs1), &rsaOffset, tag: 0x30) else { return nil }
        var inner = 0
        func unsigned(_ bytes: [UInt8]) -> Data { Data(bytes.drop(while: { $0 == 0 })) }
        guard let modulus = (try? derValue(rsaSequence, &inner, tag: 0x02)).map(unsigned),
              let exponent = (try? derValue(rsaSequence, &inner, tag: 0x02)).map(unsigned)
        else { return nil }
        return (pkcs1, modulus, exponent)
    }

    /// DER TLV reader shared by the SPKI/PKCS#1 walkers (same shape as the
    /// backend interop fixture's).
    private static func derValue(_ bytes: [UInt8], _ offset: inout Int, tag: UInt8) throws -> [UInt8] {
        struct DerError: Error {}
        guard offset < bytes.count, bytes[offset] == tag else { throw DerError() }
        offset += 1
        guard offset < bytes.count else { throw DerError() }
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
            let count = length & 127; length = 0
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw DerError() }
            for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
        }
        guard offset + length <= bytes.count else { throw DerError() }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }
}

// MARK: - Transport on the paired client

/// Concrete `IOSCloudConfigTransport` from the contract: GET view + import key
/// over the paired HTTPS/SPKI client, pin the kid, seal the payload to JWE,
/// POST `{"jwe": …}` and map the fixed error codes. Secrets never leave memory
/// unsealed; requestId semantics belong to the caller (`applyCloudBundle`).
actor IOSCloudConfigClient: IOSCloudConfigTransport {
    private let client: MacGatewayClient
    private let gatewayId: String
    private let kidStore: IOSCloudImportKidStore
    private let now: @Sendable () -> Int64

    init(
        client: MacGatewayClient,
        gatewayId: String,
        kidStore: IOSCloudImportKidStore = .live,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.client = client
        self.gatewayId = gatewayId
        self.kidStore = kidStore
        self.now = now
    }

    /// Drops the pinned kid so the next fetch re-pins — the explicit user
    /// re-trust action after `importKeyChanged`.
    static func resetImportKeyTrust(gatewayId: String, kidStore: IOSCloudImportKidStore = .live) {
        kidStore.delete(gatewayId)
    }

    func fetchCloudConfiguration() async throws -> IOSCloudConfigSnapshot {
        snapshot(try await fetchViewDTO())
    }

    /// `expectedRevision` is the revision the user reviewed when confirming —
    /// supplied by the caller, never re-fetched here. Refetching just before
    /// POST would bless a stale draft over another device's unseen update.
    func applyCloudConfiguration(_ bundle: IOSCloudConfigBundle, requestId: String, expectedRevision: Int) async throws -> IOSCloudConfigApplyReceipt {
        let key = try await verifiedImportKey()
        let keyFetchedAt = now()
        do {
            return try await post(bundle: bundle, key: key, keyFetchedAt: keyFetchedAt, requestId: requestId, expectedRevision: expectedRevision)
        } catch IOSCloudConfigError.envelopeExpired {
            // Same requestId + same operation re-sealed: if the original was
            // already applied the server answers the stored receipt instead.
            return try await post(bundle: bundle, key: key, keyFetchedAt: keyFetchedAt, requestId: requestId, expectedRevision: expectedRevision)
        }
    }

    // MARK: - Endpoints

    private func fetchViewDTO() async throws -> IOSCloudConfigViewDTO {
        let response = try await client.requestData("GET", "/v2/configuration", slow: true)
        guard (200..<300).contains(response.status), let dto: IOSCloudConfigViewDTO = decode(response.data)
        else { throw mappedError(response) }
        return dto
    }

    /// GETs the import key and enforces the full trust chain: contract fields,
    /// recomputed kid, SPKI↔JWK binding, and the pinned kid for this gateway.
    private func verifiedImportKey() async throws -> IOSCloudVerifiedImportKey {
        let response = try await client.requestData("GET", "/v2/configuration/import-key", slow: true)
        guard (200..<300).contains(response.status), let dto: IOSCloudImportKeyDTO = decode(response.data)
        else { throw mappedError(response) }
        let verified = try IOSCloudConfigEnvelope.verify(dto, gatewayId: gatewayId)
        if let pinned = kidStore.load(gatewayId) {
            guard pinned == verified.kid else { throw IOSCloudConfigError.importKeyChanged }
        } else {
            kidStore.store(gatewayId, verified.kid)
        }
        return verified
    }

    private func post(bundle: IOSCloudConfigBundle, key: IOSCloudVerifiedImportKey, keyFetchedAt: Int64, requestId: String, expectedRevision: Int) async throws -> IOSCloudConfigApplyReceipt {
        // issuedAt follows the daemon's clock (from the key response) advanced
        // by local elapsed time, so a drifting device clock can't produce an
        // out-of-window envelope.
        let issuedAt = key.serverTime + max(0, now() - keyFetchedAt)
        let lifetime = min(120, key.maxEnvelopeLifetimeSeconds)
        let payload = IOSCloudConfigPayload(
            gatewayId: gatewayId,
            deviceId: key.deviceId,
            requestId: requestId,
            expectedRevision: expectedRevision,
            issuedAt: issuedAt,
            expiresAt: issuedAt + lifetime,
            configuration: bundle.configurationPatch,
            credentials: bundle.credentialPatch
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let plaintext = try? encoder.encode(payload) else { throw IOSCloudConfigError.malformedResponse }
        let jwe = try IOSCloudConfigEnvelope.seal(payload: plaintext, key: key)
        let body = try JSONSerialization.data(withJSONObject: ["jwe": jwe])
        let response = try await client.requestData("POST", "/v2/configuration", bodyData: body, slow: true)
        guard (200..<300).contains(response.status), let receipt: IOSCloudConfigReceiptDTO = decode(response.data)
        else { throw mappedError(response) }
        return IOSCloudConfigApplyReceipt(
            requestId: receipt.requestId, revision: receipt.revision,
            currentRevision: receipt.currentRevision, replayed: receipt.replayed,
            effective: receipt.effective
        )
    }

    // MARK: - Mapping

    private func snapshot(_ dto: IOSCloudConfigViewDTO) -> IOSCloudConfigSnapshot {
        func configured(_ key: String) -> Bool {
            switch key {
            case "modelApiKey": dto.credentials.modelApiKey.configured
            case "exaApiKey": dto.credentials.exaApiKey.configured
            case "braveApiKey": dto.credentials.braveApiKey.configured
            default: false
            }
        }
        let model: IOSCloudConfigSnapshot.Model? =
            (dto.model.provider.isEmpty && dto.model.modelId.isEmpty) ? nil : .init(
                provider: dto.model.provider, modelId: dto.model.modelId,
                baseUrl: dto.model.baseUrl, keyConfigured: configured("modelApiKey")
            )
        return IOSCloudConfigSnapshot(
            gatewayId: dto.gatewayId,
            revision: dto.revision,
            model: model,
            search: dto.supportedSearchSources.map { source in
                IOSCloudConfigSnapshot.Search(
                    type: source,
                    name: IOSCloudConfigWire.sourceDisplayName(for: source),
                    enabled: dto.search.sources.contains(source),
                    requiresKey: IOSCloudConfigWire.requiresKey(for: source),
                    keyConfigured: IOSCloudConfigWire.credentialKey(for: source).map(configured) == true
                )
            },
            searchSources: dto.search.sources,
            searchMode: dto.search.mode,
            supportedModelProviders: dto.supportedModelProviders,
            supportedSearchSources: dto.supportedSearchSources
        )
    }

    /// Contract error contract → typed errors; 401 stays `MacGatewayError.unauthorized`
    /// so `forgetIfRevoked` keeps owning the revoked-device flow.
    private func mappedError(_ response: MacGatewayClient.MacGatewayRawResponse) -> Error {
        let code = response.errorCode
        switch (response.status, code) {
        case (401, _): return MacGatewayError.unauthorized
        case (403, _): return IOSCloudConfigError.untrustedDevice
        case (404, _): return IOSCloudConfigError.notFound
        case (409, "request_id_conflict"): return IOSCloudConfigError.requestIdConflict
        case (409, _): return IOSCloudConfigError.revisionConflict(current: response.currentRevision)
        case (410, _): return IOSCloudConfigError.envelopeExpired
        case (413, _): return IOSCloudConfigError.tooLarge
        case (422, "credential_action_required"): return IOSCloudConfigError.credentialActionRequired
        case (422, _): return IOSCloudConfigError.invalidConfiguration
        case (400, "invalid_envelope"): return IOSCloudConfigError.invalidEnvelope
        case (400, _): return IOSCloudConfigError.invalidRequest
        case (503, _): return IOSCloudConfigError.unavailable
        default: return MacGatewayError.server(code ?? "HTTP \(response.status)")
        }
    }

    private func decode<T: Decodable>(_ data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}
