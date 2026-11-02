import CryptoKit
import Foundation
import Security

// MARK: - Contract DTOs (docs/architecture/cloud-configuration-api.md v1)

/// `GET /v2/configuration` response: non-secret state only, never key material.
struct DesktopCloudRemoteConfigResponse: Decodable {
    var gatewayId: String
    var revision: Int
    var model: Model?
    var search: Search?
    var credentials: [String: Credential]?
    var supportedModelProviders: [String]?
    var supportedSearchSources: [String]?

    struct Model: Decodable { var provider: String?; var modelId: String?; var baseUrl: String? }
    struct Search: Decodable { var sources: [String]?; var mode: String? }
    struct Credential: Decodable { var configured: Bool? }
}

/// `GET /v2/configuration/import-key` response. The JWK holds the RSA-3072 public key used to wrap
/// the JWE CEK; `kid` must equal the JWK's RFC7638 thumbprint recomputed client-side.
struct DesktopCloudImportKeyResponse: Decodable {
    var version: Int
    var gatewayId: String
    var deviceId: String
    var kid: String
    var publicJwk: JWK
    var publicKeySpkiDerBase64: String
    var serverTime: Int
    var maxEnvelopeLifetimeSeconds: Int?

    struct JWK: Decodable { var kty: String; var e: String; var n: String }
}

struct DesktopCloudApplyResponse: Decodable {
    var requestId: String
    var revision: Int
    var currentRevision: Int?
    var replayed: Bool?
    var effective: String?
}

/// The plaintext sealed inside the JWE. Omitted `configuration`/`credentials` members mean
/// "keep current" per contract; credential `replace` with an absent/blank value also keeps.
struct DesktopCloudConfigPayload: Encodable {
    var version = 1
    var gatewayId: String
    var deviceId: String
    var requestId: String
    var expectedRevision: Int
    var issuedAt: Int
    var expiresAt: Int
    var configuration: Configuration?
    var credentials: [String: CredentialAction]?

    struct Configuration: Encodable {
        var model: Model?
        var search: Search?
        struct Model: Encodable { var provider: String; var modelId: String; var baseUrl: String }
        struct Search: Encodable { var sources: [String]; var mode: String }
    }

    enum CredentialAction: Encodable {
        case replace(String)
        case delete
        private enum Keys: String, CodingKey { case action, value }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .replace(let value):
                try container.encode("replace", forKey: .action)
                try container.encode(value, forKey: .value)
            case .delete:
                try container.encode("delete", forKey: .action)
            }
        }
    }
}

// MARK: - base64url (no padding)

enum DesktopCloudBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

// MARK: - RSA / DER helpers

/// Minimal DER for RSA public keys: RSAPublicKey (PKCS#1) inside X.509 SubjectPublicKeyInfo.
enum DesktopCloudRSA {

    /// Parses `SEQUENCE { INTEGER modulus, INTEGER exponent }` (PKCS#1 RSAPublicKey), stripping
    /// the sign-padding zero of each INTEGER.
    static func parsePKCS1(_ der: Data) throws -> (modulus: Data, exponent: Data) {
        var reader = DERReader(der)
        var inner = try reader.sequence()
        let modulus = stripSignZero(try inner.integer())
        let exponent = stripSignZero(try inner.integer())
        return (modulus, exponent)
    }

    /// Parses `SEQUENCE { algorithmIdentifier, BIT STRING RSAPublicKey }` (X.509 SPKI).
    static func parseSPKI(_ der: Data) throws -> (modulus: Data, exponent: Data) {
        var reader = DERReader(der)
        var inner = try reader.sequence()
        _ = try inner.tlv() // algorithm identifier SEQUENCE (rsaEncryption, NULL)
        let bits = try inner.tlv()
        guard bits.tag == 0x03, bits.content.first == 0x00 else {
            throw DesktopCloudError.invalidResponse
        }
        return try parsePKCS1(bits.content.dropFirst())
    }

    /// Rebuilds a PKCS#1 RSAPublicKey DER from unsigned big-endian components.
    static func encodePKCS1(modulus: Data, exponent: Data) -> Data {
        func integer(_ raw: Data) -> Data {
            var bytes = stripSignZero(raw)
            if (bytes.first ?? 0) & 0x80 != 0 { bytes.insert(0x00, at: 0) }
            return tlv(0x02, bytes)
        }
        return tlv(0x30, integer(modulus) + integer(exponent))
    }

    /// Wraps a PKCS#1 RSAPublicKey into an X.509 SPKI (rsaEncryption algorithm identifier).
    static func spkiWrappingPKCS1(_ pkcs1: Data) -> Data {
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        return tlv(0x30, algorithm + tlv(0x03, Data([0x00]) + pkcs1))
    }

    /// RFC7638 JWK SHA-256 thumbprint: SHA-256 of `{"e":"..","kty":"RSA","n":".."}` (keys sorted,
    /// only members present), base64url without padding.
    static func jwkThumbprint(e: String, n: String) -> String {
        let canonical = #"{"e":""# + e + #"","kty":"RSA","n":""# + n + #""}"#
        return DesktopCloudBase64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
    }

    /// Imports the import-key JWK as a SecKey, requiring the response's SPKI DER to carry the same
    /// modulus/exponent (contract: DER must not be trusted without matching the JWK).
    static func importKey(jwkE: String, jwkN: String, spkiDERBase64: String) throws -> SecKey {
        guard let jwkModulus = DesktopCloudBase64URL.decode(jwkN),
              let jwkExponent = DesktopCloudBase64URL.decode(jwkE),
              let der = Data(base64Encoded: spkiDERBase64),
              let derComponents = try? parseSPKI(der),
              derComponents.modulus == stripSignZero(jwkModulus),
              derComponents.exponent == stripSignZero(jwkExponent)
        else { throw DesktopCloudError.invalidResponse }
        let pkcs1 = encodePKCS1(modulus: jwkModulus, exponent: jwkExponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: jwkModulus.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw DesktopCloudError.invalidResponse
        }
        return key
    }

    /// RSA-OAEP with SHA-256 for both the hash and MGF1, per the JWE `alg` value `RSA-OAEP-256`.
    static func encryptOAEP256(_ data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionOAEPSHA256, data as CFData, &error) as Data?
        else { throw error?.takeRetainedValue() ?? DesktopCloudError.invalidResponse }
        return encrypted
    }

    private static func stripSignZero(_ data: Data) -> Data {
        var bytes = data
        while bytes.count > 1, bytes.first == 0x00 { bytes.removeFirst() }
        return bytes
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    /// Byte-array backed so indices are always 0-based (Data slices keep their parent indices).
    struct DERReader {
        private let data: [UInt8]
        private var index = 0
        init(_ data: Data) { self.data = Array(data) }
        mutating func sequence() throws -> DERReader {
            let node = try tlv()
            guard node.tag == 0x30 else { throw DesktopCloudError.invalidResponse }
            return DERReader(node.content)
        }
        mutating func integer() throws -> Data {
            let node = try tlv()
            guard node.tag == 0x02 else { throw DesktopCloudError.invalidResponse }
            return node.content
        }
        mutating func tlv() throws -> (tag: UInt8, content: Data) {
            guard index + 2 <= data.count else { throw DesktopCloudError.invalidResponse }
            let tag = data[index]; index += 1
            var length = Int(data[index]); index += 1
            if length & 0x80 != 0 {
                let octets = length & 0x7F
                guard octets > 0, octets <= 4, index + octets <= data.count else { throw DesktopCloudError.invalidResponse }
                length = 0
                for _ in 0..<octets { length = length << 8 | Int(data[index]); index += 1 }
            }
            guard index + length <= data.count else { throw DesktopCloudError.invalidResponse }
            let content = Data(data[index..<index + length])
            index += length
            return (tag, content)
        }
    }
}

// MARK: - JWE compact (RFC7516: RSA-OAEP-256 + A256GCM)

enum DesktopCloudJWE {
    /// Five-part compact serialization; AAD is the protected segment's own ASCII bytes.
    /// Header is fixed by contract: alg/enc/kid/typ only.
    static func seal(payload: Data, publicKey: SecKey, kid: String) throws -> String {
        let header = #"{"alg":"RSA-OAEP-256","enc":"A256GCM","kid":""# + kid + #"","typ":"amber-config+jwe"}"#
        let protected = DesktopCloudBase64URL.encode(Data(header.utf8))
        let cek = SymmetricKey(size: .bits256)
        let encryptedKey = try DesktopCloudRSA.encryptOAEP256(cek.withUnsafeBytes { Data($0) }, key: publicKey)
        var iv = Data(count: 12)
        try iv.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  SecRandomCopyBytes(kSecRandomDefault, 12, base) == errSecSuccess
            else { throw DesktopCloudError.invalidResponse }
        }
        let sealed = try AES.GCM.seal(payload,
            using: cek, nonce: AES.GCM.Nonce(data: iv), authenticating: Data(protected.utf8))
        return [protected,
                DesktopCloudBase64URL.encode(encryptedKey),
                DesktopCloudBase64URL.encode(iv),
                DesktopCloudBase64URL.encode(sealed.ciphertext),
                DesktopCloudBase64URL.encode(sealed.tag)].joined(separator: ".")
    }
}

// MARK: - kid pinning

/// Per-gateway pinned import-key kid. UserDefaults is documented thread-safe; the wrapper marks
/// it so actor state can hold it. Kid pinning ends with the pairing (unpair unpins).
struct DesktopCloudPinnedKidStore: @unchecked Sendable {
    private let defaults: UserDefaults
    static let keyPrefix = "desktop.cloudSelf.importKid"
    init(defaults: UserDefaults) { self.defaults = defaults }
    func kid(forGateway id: String) -> String? { defaults.string(forKey: "\(Self.keyPrefix).\(id)") }
    func pin(_ kid: String, forGateway id: String) { defaults.set(kid, forKey: "\(Self.keyPrefix).\(id)") }
    func unpin(forGateway id: String) { defaults.removeObject(forKey: "\(Self.keyPrefix).\(id)") }
}

// MARK: - Contract-backed sync

/// Implements `/v2/configuration` per cloud-configuration-api.md v1: GET state, fetch the RSA
/// import key (RFC7638-verified, DER cross-checked, kid pinned per gateway), seal the payload
/// JWE, POST, then GET the fresh state. Secrets live only inside the sealed envelope.
actor DesktopCloudClientConfigSync: DesktopCloudConfigSync {
    /// Credential slot names the contract accepts; anything else is rejected before upload.
    static let knownSecrets: Set<String> = ["modelApiKey", "exaApiKey", "braveApiKey"]

    private let client: DesktopCloudClient
    private let gatewayId: String
    private let deviceId: String
    private let kidStore: DesktopCloudPinnedKidStore

    init(client: DesktopCloudClient, connection: DesktopCloudConnection,
         kidStore: DesktopCloudPinnedKidStore) {
        self.client = client
        self.gatewayId = connection.gatewayId
        self.deviceId = connection.deviceId
        self.kidStore = kidStore
    }

    // MARK: fetch

    func fetchConfig() async throws -> DesktopCloudRemoteConfig {
        let response: DesktopCloudRemoteConfigResponse =
            try await client.decode(client.send("GET", "/v2/configuration"))
        guard response.gatewayId == gatewayId else { throw DesktopCloudError.invalidResponse }
        let credentials = response.credentials ?? [:]
        return DesktopCloudRemoteConfig(
            model: .init(provider: response.model?.provider ?? "",
                         modelId: response.model?.modelId ?? "",
                         baseURL: response.model?.baseUrl ?? "",
                         keyConfigured: credentials["modelApiKey"]?.configured == true),
            search: .init(sources: response.search?.sources ?? [],
                          mode: response.search?.mode ?? "fallback",
                          exaKeyConfigured: credentials["exaApiKey"]?.configured == true,
                          braveKeyConfigured: credentials["braveApiKey"]?.configured == true),
            configuredSecrets: Set(credentials.filter { $0.value.configured == true }.keys),
            supportedModelProviders: response.supportedModelProviders ?? [],
            supportedSearchSources: response.supportedSearchSources ?? [],
            revision: response.revision)
    }

    // MARK: apply

    func applyConfig(_ request: DesktopCloudConfigApply, requestId: String) async throws -> DesktopCloudApplyOutcome {
        try await apply(request, requestId: requestId, retriedAfterExpiry: false)
    }

    /// One internal retry on 410: the envelope window elapsed, so resealing with fresh
    /// issuedAt/expiresAt under the same requestId is the intended retry path.
    /// A confirmed POST receipt ends the operation — a failed read-back afterwards is reported
    /// as `refreshed: false`, never as an apply failure.
    private func apply(_ request: DesktopCloudConfigApply, requestId: String,
                       retriedAfterExpiry: Bool) async throws -> DesktopCloudApplyOutcome {
        let key = try await fetchImportKey()
        let payload = try buildPayload(request, requestId: requestId,
            serverTime: key.serverTime, lifetime: key.maxLifetime)
        let jwe = try DesktopCloudJWE.seal(payload: payload, publicKey: key.secKey, kid: key.kid)
        let receipt: DesktopCloudApplyResponse
        do {
            receipt = try await client.decode(
                client.send("POST", "/v2/configuration", body: ["jwe": jwe]))
            guard receipt.requestId == requestId else { throw DesktopCloudError.invalidResponse }
        } catch DesktopCloudError.envelopeExpired where !retriedAfterExpiry {
            return try await apply(request, requestId: requestId, retriedAfterExpiry: true)
        }
        // Receipt confirmed: the write took effect. Best-effort refresh; revocation still wins.
        do {
            return DesktopCloudApplyOutcome(config: try await fetchConfig(),
                                            revision: receipt.revision, refreshed: true)
        } catch DesktopCloudError.unauthorized {
            throw DesktopCloudError.unauthorized
        } catch {
            return DesktopCloudApplyOutcome(config: nil, revision: receipt.revision, refreshed: false)
        }
    }

    /// GET the daemon's import key, recompute the RFC7638 thumbprint, cross-check the SPKI DER
    /// against the JWK, and enforce the per-gateway pinned kid (first fetch pins it; a changed
    /// kid requires re-pairing instead of silently updating trust).
    private func fetchImportKey() async throws -> (secKey: SecKey, kid: String, serverTime: Int, maxLifetime: Int) {
        let response: DesktopCloudImportKeyResponse =
            try await client.decode(client.send("GET", "/v2/configuration/import-key"))
        guard response.version == 1,
              response.gatewayId == gatewayId,
              response.deviceId == deviceId,
              response.publicJwk.kty == "RSA",
              DesktopCloudRSA.jwkThumbprint(e: response.publicJwk.e, n: response.publicJwk.n) == response.kid
        else { throw DesktopCloudError.invalidResponse }
        let secKey = try DesktopCloudRSA.importKey(
            jwkE: response.publicJwk.e, jwkN: response.publicJwk.n,
            spkiDERBase64: response.publicKeySpkiDerBase64)
        try checkPinnedKid(response.kid)
        let lifetime = min(max(response.maxEnvelopeLifetimeSeconds ?? 300, 60), 300)
        return (secKey, response.kid, response.serverTime, lifetime)
    }

    func checkPinnedKid(_ kid: String) throws {
        if let pinned = kidStore.kid(forGateway: gatewayId) {
            guard pinned == kid else { throw DesktopCloudError.importKeyChanged }
        } else {
            kidStore.pin(kid, forGateway: gatewayId)
        }
    }

    /// Builds the plaintext that gets sealed. Contract: omitted objects keep current values;
    /// replace-with-empty keeps the stored key; delete is explicit and value-less.
    func buildPayload(_ request: DesktopCloudConfigApply, requestId: String,
                      serverTime: Int, lifetime: Int) throws -> Data {
        var configuration: DesktopCloudConfigPayload.Configuration?
        if request.includesModel || request.includesSearch {
            var model: DesktopCloudConfigPayload.Configuration.Model?
            if request.includesModel {
                let baseURL = request.config.modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.config.modelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !request.config.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw DesktopCloudError.server("请填写云端服务商与模型标识") }
                // Contract: only HTTPS API roots, no userinfo/query/fragment.
                if !baseURL.isEmpty {
                    guard let url = URL(string: baseURL), url.scheme == "https",
                          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
                    else { throw DesktopCloudError.server("云端接口地址须为不带参数或凭据的 HTTPS API 根地址") }
                }
                model = .init(provider: request.config.modelProvider.trimmingCharacters(in: .whitespacesAndNewlines),
                              modelId: request.config.modelId.trimmingCharacters(in: .whitespacesAndNewlines),
                              baseUrl: baseURL)
            }
            configuration = .init(model: model,
                search: request.includesSearch ? .init(sources: request.config.searchSources,
                                                       mode: request.config.searchMode) : nil)
        }
        var credentials: [String: DesktopCloudConfigPayload.CredentialAction] = [:]
        for (key, value) in request.secrets {
            guard Self.knownSecrets.contains(key) else { throw DesktopCloudError.server("不支持的凭据项：\(key)") }
            credentials[key] = .replace(value)
        }
        // An explicit delete wins only when no replacement key is being uploaded for the slot.
        for key in request.config.deletes where credentials[key] == nil {
            guard Self.knownSecrets.contains(key) else { throw DesktopCloudError.server("不支持的凭据项：\(key)") }
            credentials[key] = .delete
        }
        let payload = DesktopCloudConfigPayload(
            gatewayId: gatewayId, deviceId: deviceId, requestId: requestId,
            expectedRevision: request.config.baseRevision,
            issuedAt: serverTime, expiresAt: serverTime + min(lifetime, 300),
            configuration: configuration,
            credentials: credentials.isEmpty ? nil : credentials)
        let encoder = JSONEncoder()
        return try encoder.encode(payload)
    }
}
