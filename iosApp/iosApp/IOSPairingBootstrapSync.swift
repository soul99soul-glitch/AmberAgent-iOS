import CryptoKit
import Foundation
import Security
@preconcurrency import Shared

// MARK: - Single-Scan Pairing Bootstrap Contract (Stage 3-A / 3-D)

/// Strictly non-secret metadata carried inside `amber://gateway/pair?p=...`.
/// Plaintext API keys, OAuth tokens, or credential fragments are strictly forbidden.
struct MacGatewayPairingBootstrapHint: Codable, Equatable, Sendable {
    var syncSupported: Bool
    var configRevision: Int
    var provider: String
    var authMode: String
    var siwcConfigured: Bool
    var hasEncryptedCredentials: Bool
    var soulRevision: Int64
    var activeRulesCount: Int

    init(
        syncSupported: Bool = true,
        configRevision: Int = 0,
        provider: String = "",
        authMode: String = "apiKey",
        siwcConfigured: Bool = false,
        hasEncryptedCredentials: Bool = false,
        soulRevision: Int64 = 0,
        activeRulesCount: Int = 0
    ) {
        self.syncSupported = syncSupported
        self.configRevision = configRevision
        self.provider = provider
        self.authMode = authMode
        self.siwcConfigured = siwcConfigured
        self.hasEncryptedCredentials = hasEncryptedCredentials
        self.soulRevision = soulRevision
        self.activeRulesCount = activeRulesCount
    }

    private enum CodingKeys: String, CodingKey {
        case syncSupported, configRevision, provider, authMode, siwcConfigured, hasEncryptedCredentials, soulRevision, activeRulesCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncSupported = try container.decodeIfPresent(Bool.self, forKey: .syncSupported) ?? true
        configRevision = try container.decodeIfPresent(Int.self, forKey: .configRevision) ?? 0
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode) ?? "apiKey"
        siwcConfigured = try container.decodeIfPresent(Bool.self, forKey: .siwcConfigured) ?? false
        hasEncryptedCredentials = try container.decodeIfPresent(Bool.self, forKey: .hasEncryptedCredentials) ?? false
        soulRevision = try container.decodeIfPresent(Int64.self, forKey: .soulRevision) ?? 0
        activeRulesCount = try container.decodeIfPresent(Int.self, forKey: .activeRulesCount) ?? 0
    }
}

struct IOSBootstrapCredentials: Codable, Equatable, Sendable {
    var modelApiKey: String?
    var exaApiKey: String?
    var braveApiKey: String?
}

struct IOSBootstrapModelSettings: Codable, Equatable, Sendable {
    var provider: String
    var modelId: String
    var baseUrl: String
    var authMode: String
    var siwcConfigured: Bool

    init(
        provider: String,
        modelId: String,
        baseUrl: String = "",
        authMode: String = "apiKey",
        siwcConfigured: Bool = false
    ) {
        self.provider = provider
        self.modelId = modelId
        self.baseUrl = baseUrl
        self.authMode = authMode
        self.siwcConfigured = siwcConfigured
    }

    private enum CodingKeys: String, CodingKey {
        case provider, modelId, baseUrl, authMode, siwcConfigured
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode) ?? "apiKey"
        siwcConfigured = try container.decodeIfPresent(Bool.self, forKey: .siwcConfigured) ?? false
    }
}

struct IOSBootstrapSearchSettings: Codable, Equatable, Sendable {
    var sources: [String]
    var mode: String

    init(sources: [String] = [], mode: String = "fallback") {
        self.sources = sources
        self.mode = mode
    }
}

/// Plaintext payload sealed inside `IOSPairingBootstrapSnapshot.encryptedConfigJwe` (`typ = "amber-bootstrap+jwe"`).
struct IOSBootstrapEnvelopePayload: Codable, Equatable, Sendable {
    var version: Int
    var gatewayId: String
    var deviceId: String
    var issuedAt: Int64
    var expiresAt: Int64
    var configRevision: Int
    var model: IOSBootstrapModelSettings
    var search: IOSBootstrapSearchSettings
    var credentials: IOSBootstrapCredentials
}

/// Returned by `POST /v1/pair` (optional `bootstrap`) or `POST /v2/pairing/bootstrap-sync`.
struct IOSPairingBootstrapSnapshot: Decodable, Sendable {
    var version: Int?
    var configuration: IOSCloudConfigViewDTO?
    var encryptedConfigJwe: String?
    var soul: CloudSoulSnapshotPayload?
    var activeRules: [IOSProceduralRule]?
    var importKey: IOSCloudImportKeyDTO?
}

/// Non-secret user-facing summary of what single-scan pairing synchronized.
/// NEVER stores or formats plaintext API keys or tokens.
struct IOSPairingBootstrapSyncSummary: Equatable, Sendable {
    var provider: String
    var modelId: String
    var authMode: String
    var siwcConfigured: Bool
    var credentialsImported: Bool
    var soulSynced: Bool
    var soulRevision: Int64
    var activeRulesImported: Int
    var encryptedConfigDecrypted: Bool
    var summaryText: String
}

enum IOSPairingBootstrapError: LocalizedError, Equatable, Sendable {
    case keyGenerationFailed
    case invalidPublicKey
    case invalidEnvelopeHeader
    case invalidEnvelopeStructure
    case decryptionFailed
    case gatewayMismatch
    case deviceMismatch
    case envelopeExpired
    case settingsUnavailable
    case settingsSaveFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return IOSAppLocalization.string("无法生成配对临时加密密钥", defaultValue: "无法生成配对临时加密密钥")
        case .invalidPublicKey:
            return IOSAppLocalization.string("临时加密公钥格式无效", defaultValue: "临时加密公钥格式无效")
        case .invalidEnvelopeHeader, .invalidEnvelopeStructure:
            return IOSAppLocalization.string("加密同步载荷格式不合法", defaultValue: "加密同步载荷格式不合法")
        case .decryptionFailed:
            return IOSAppLocalization.string("加密同步配置解密失败", defaultValue: "加密同步配置解密失败")
        case .gatewayMismatch, .deviceMismatch:
            return IOSAppLocalization.string("同步配置与当前配对网关不匹配", defaultValue: "同步配置与当前配对网关不匹配")
        case .envelopeExpired:
            return IOSAppLocalization.string("加密同步配置已过期，请重新配对或刷新同步", defaultValue: "加密同步配置已过期，请重新配对或刷新同步")
        case .settingsUnavailable:
            return IOSAppLocalization.string("本机模型设置尚未就绪", defaultValue: "本机模型设置尚未就绪")
        case .settingsSaveFailed:
            return IOSAppLocalization.string("本机未能安全保存同步配置", defaultValue: "本机未能安全保存同步配置")
        }
    }
}

// MARK: - Ephemeral RSA-OAEP-256 + A256GCM (`amber-bootstrap+jwe`) Crypto

struct IOSPairingBootstrapKeyPair: @unchecked Sendable {
    let privateKey: SecKey
    let publicJwk: [String: String]
}

enum IOSPairingBootstrapCrypto {
    static let expectedAlg = "RSA-OAEP-256"
    static let expectedEnc = "A256GCM"
    static let expectedTyp = "amber-bootstrap+jwe"

    private static let forbiddenQRSecretPatterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_-]{12,}"#,
        #"AIza[0-9A-Za-z_-]{20,}"#,
        #"ghp_[A-Za-z0-9]{20,}"#,
        #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        #"(api[_-]?key|oauth[_-]?token|refresh[_-]?token|access[_-]?token)\s*[:=]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Rejects QR payloads that illegally carry plaintext secrets.
    static func containsForbiddenSecretPattern(_ raw: String) -> Bool {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return forbiddenQRSecretPatterns.contains { $0.firstMatch(in: raw, options: [], range: range) != nil }
    }

    /// Generates an ephemeral in-memory RSA key pair (default 2048-bit, strictly non-persistent)
    /// and exports a strictly public JWK compatible with `ConfigurationEncryption.validateClientPublicJwk`.
    static func generateEphemeralKeyPair(bitSize: Int = 2_048) throws -> IOSPairingBootstrapKeyPair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: max(bitSize, 2_048),
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw IOSPairingBootstrapError.keyGenerationFailed
        }
        guard let (modulus, exponent) = parsePKCS1RSAPublicKey(pkcs1) else {
            throw IOSPairingBootstrapError.invalidPublicKey
        }
        let n = IOSCloudConfigEnvelope.base64url(modulus)
        let e = IOSCloudConfigEnvelope.base64url(exponent)
        guard let kid = IOSCloudConfigEnvelope.jwkThumbprint(e: e, n: n) else {
            throw IOSPairingBootstrapError.invalidPublicKey
        }
        return IOSPairingBootstrapKeyPair(
            privateKey: privateKey,
            publicJwk: [
                "kty": "RSA",
                "use": "enc",
                "alg": expectedAlg,
                "kid": kid,
                "n": n,
                "e": e,
            ]
        )
    }

    /// Seals an `IOSBootstrapEnvelopePayload` into RFC 7516 compact JWE (`RSA-OAEP-256` + `A256GCM`,
    /// `typ = "amber-bootstrap+jwe"`) for a client public JWK.
    static func seal(_ payload: IOSBootstrapEnvelopePayload, publicJwk: [String: String]) throws -> String {
        guard publicJwk["kty"] == "RSA",
              let nStr = publicJwk["n"], let eStr = publicJwk["e"],
              let modulus = base64urlDecode(nStr), let exponent = base64urlDecode(eStr)
        else {
            throw IOSPairingBootstrapError.invalidPublicKey
        }
        let pkcs1 = encodePKCS1RSAPublicKey(modulus: modulus, exponent: exponent)
        var secError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(
            pkcs1 as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ] as CFDictionary,
            &secError
        ) else {
            throw IOSPairingBootstrapError.invalidPublicKey
        }

        let kid = publicJwk["kid"] ?? IOSCloudConfigEnvelope.jwkThumbprint(e: eStr, n: nStr) ?? ""
        let headerDict: [String: String] = [
            "alg": expectedAlg,
            "enc": expectedEnc,
            "kid": kid,
            "typ": expectedTyp,
        ]
        let protectedData = try JSONSerialization.data(withJSONObject: headerDict, options: [.sortedKeys])
        let protectedSegment = IOSCloudConfigEnvelope.base64url(protectedData)

        let plaintext = try JSONEncoder().encode(payload)
        let cek = SymmetricKey(size: .bits256)
        let cekData = cek.withUnsafeBytes { Data($0) }
        guard let encryptedKey = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            cekData as CFData,
            &secError
        ) as Data? else {
            throw IOSPairingBootstrapError.decryptionFailed
        }
        let sealed = try AES.GCM.seal(plaintext, using: cek, authenticating: Data(protectedSegment.utf8))
        return [
            protectedSegment,
            IOSCloudConfigEnvelope.base64url(encryptedKey),
            IOSCloudConfigEnvelope.base64url(Data(sealed.nonce)),
            IOSCloudConfigEnvelope.base64url(sealed.ciphertext),
            IOSCloudConfigEnvelope.base64url(sealed.tag),
        ].joined(separator: ".")
    }

    /// Decrypts and verifies a compact JWE (`RSA-OAEP-256` + `A256GCM`, `typ = "amber-bootstrap+jwe"`).
    static func unseal(
        _ compact: String,
        privateKey: SecKey,
        expectedGatewayId: String? = nil,
        expectedDeviceId: String? = nil,
        nowSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> IOSBootstrapEnvelopePayload {
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let headerData = base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }
        guard (header["alg"] as? String) == expectedAlg,
              (header["enc"] as? String) == expectedEnc,
              (header["typ"] as? String) == expectedTyp,
              header["zip"] == nil,
              header["crit"] == nil
        else {
            throw IOSPairingBootstrapError.invalidEnvelopeHeader
        }
        guard let encryptedKey = base64urlDecode(parts[1]),
              let iv = base64urlDecode(parts[2]),
              let ciphertext = base64urlDecode(parts[3]),
              let tag = base64urlDecode(parts[4]),
              iv.count == 12, tag.count == 16
        else {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }

        var decryptError: Unmanaged<CFError>?
        guard let cekData = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            encryptedKey as CFData,
            &decryptError
        ) as Data?, cekData.count == 32 else {
            throw IOSPairingBootstrapError.decryptionFailed
        }

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: cekData), authenticating: Data(parts[0].utf8))
        } catch {
            throw IOSPairingBootstrapError.decryptionFailed
        }

        let decoded: IOSBootstrapEnvelopePayload
        do {
            decoded = try JSONDecoder().decode(IOSBootstrapEnvelopePayload.self, from: plaintext)
        } catch {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }

        if let expectedGatewayId, decoded.gatewayId.isEmpty || decoded.gatewayId != expectedGatewayId {
            throw IOSPairingBootstrapError.gatewayMismatch
        }
        if let expectedDeviceId, decoded.deviceId.isEmpty || decoded.deviceId != expectedDeviceId {
            throw IOSPairingBootstrapError.deviceMismatch
        }
        if decoded.expiresAt <= nowSeconds {
            throw IOSPairingBootstrapError.envelopeExpired
        }
        guard decoded.version == 1, decoded.issuedAt > 0, decoded.expiresAt > decoded.issuedAt,
              decoded.expiresAt - decoded.issuedAt <= 300 else {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }
        if decoded.issuedAt - 60 > nowSeconds {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }
        return decoded
    }

    // MARK: - Minimal ASN.1 PKCS#1 RSAPublicKey Helpers

    static func parsePKCS1RSAPublicKey(_ data: Data) -> (modulus: Data, exponent: Data)? {
        let bytes = Array(data)
        var offset = 0
        guard let seq = try? readDER(bytes, &offset, tag: 0x30) else { return nil }
        var inner = 0
        guard let rawN = try? readDER(seq, &inner, tag: 0x02),
              let rawE = try? readDER(seq, &inner, tag: 0x02) else { return nil }
        let modulus = Data(rawN.drop(while: { $0 == 0 }))
        let exponent = Data(rawE.drop(while: { $0 == 0 }))
        guard !modulus.isEmpty, !exponent.isEmpty else { return nil }
        return (modulus, exponent)
    }

    static func encodePKCS1RSAPublicKey(modulus: Data, exponent: Data) -> Data {
        func derInteger(_ unsigned: Data) -> [UInt8] {
            var bytes = Array(unsigned.drop(while: { $0 == 0 }))
            if bytes.isEmpty { bytes = [0] }
            if (bytes[0] & 0x80) != 0 { bytes.insert(0, at: 0) }
            return derWrap(tag: 0x02, body: bytes)
        }
        let body = derInteger(modulus) + derInteger(exponent)
        return Data(derWrap(tag: 0x30, body: body))
    }

    private static func derWrap(tag: UInt8, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let count = body.count
        if count < 128 {
            out.append(UInt8(count))
        } else {
            var lenBytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                lenBytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(lenBytes.count))
            out.append(contentsOf: lenBytes)
        }
        out.append(contentsOf: body)
        return out
    }

    private static func readDER(_ bytes: [UInt8], _ offset: inout Int, tag: UInt8) throws -> [UInt8] {
        struct ParseError: Error {}
        guard offset < bytes.count, bytes[offset] == tag else { throw ParseError() }
        offset += 1
        guard offset < bytes.count else { throw ParseError() }
        var length = Int(bytes[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw ParseError() }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard offset + length <= bytes.count else { throw ParseError() }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    static func base64urlDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Pairing Bootstrap Snapshot Importer

enum IOSPairingBootstrapImporter {
    struct ApplyResult: Equatable, Sendable {
        var summary: IOSPairingBootstrapSyncSummary
        var remoteConfigSnapshot: IOSCloudConfigSnapshot?
    }

    /// Applies a received `IOSPairingBootstrapSnapshot` onto local stores:
    /// - Decrypts `encryptedConfigJwe` (if present) using the ephemeral pairing private key;
    /// - Imports provider configuration, SIWC metadata, and API keys into `IOSSharedSettingsStore`
    ///   without destroying unrelated providers;
    /// - Imports `C-SOUL-V1` snapshot into `AgentSoulStore`;
    /// - Imports confirmed `.active` procedural rule cards into `IOSProceduralRuleStore`.
    @MainActor
    static func apply(
        snapshot: IOSPairingBootstrapSnapshot,
        privateKey: SecKey?,
        gatewayId: String,
        deviceId: String,
        sharedSettings: IOSSharedSettingsStore? = nil,
        soulStore: AgentSoulStore? = nil,
        ruleStore: IOSProceduralRuleStore? = nil,
        nowSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> ApplyResult {
        let resolvedSoulStore = soulStore ?? .shared
        let resolvedRuleStore = ruleStore ?? .shared
        if let version = snapshot.version, version != 1 {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }
        if let config = snapshot.configuration, config.gatewayId != gatewayId {
            throw IOSPairingBootstrapError.gatewayMismatch
        }
        var provider = snapshot.configuration?.model.provider ?? ""
        var modelId = snapshot.configuration?.model.modelId ?? ""
        var authMode = snapshot.configuration?.model.authMode ?? "apiKey"
        var siwcConfigured = snapshot.configuration?.model.siwcConfigured ?? false
        var credentialsImported = false
        var requiresLocalSignIn = false
        var decrypted = false

        if let jwe = snapshot.encryptedConfigJwe {
            guard let privateKey else { throw IOSPairingBootstrapError.decryptionFailed }
            let payload = try IOSPairingBootstrapCrypto.unseal(
                jwe,
                privateKey: privateKey,
                expectedGatewayId: gatewayId,
                expectedDeviceId: deviceId,
                nowSeconds: nowSeconds
            )
            decrypted = true
            provider = payload.model.provider
            modelId = payload.model.modelId
            authMode = payload.model.authMode
            siwcConfigured = payload.model.siwcConfigured

            guard let sharedSettings else { throw IOSPairingBootstrapError.settingsUnavailable }
            let result = try importModelAndCredentials(payload: payload, into: sharedSettings)
            credentialsImported = result.hasCredentials
            requiresLocalSignIn = result.requiresLocalSignIn
        }

        var soulSynced = false
        var soulRevision: Int64 = 0
        if let soul = snapshot.soul {
            soulRevision = soul.revision
            if soul.revision > 0 {
                _ = resolvedSoulStore.applyCloudSoulSnapshot(
                    soul,
                    gatewayId: gatewayId,
                    acceptAuthoritativeRevision: true
                )
                soulSynced = true
            }
        }

        let activeRulesImported = resolvedRuleStore.applyBootstrapActiveRules(snapshot.activeRules ?? [])
        let remoteConfigSnapshot = snapshot.configuration.map(IOSCloudConfigClient.makeSnapshot(from:))

        let summaryText = buildSummaryText(
            provider: provider,
            modelId: modelId,
            authMode: authMode,
            siwcConfigured: siwcConfigured,
            requiresLocalSignIn: requiresLocalSignIn,
            credentialsImported: credentialsImported,
            soulSynced: soulSynced,
            activeRulesImported: activeRulesImported
        )

        let summary = IOSPairingBootstrapSyncSummary(
            provider: provider,
            modelId: modelId,
            authMode: authMode,
            siwcConfigured: siwcConfigured,
            credentialsImported: credentialsImported,
            soulSynced: soulSynced,
            soulRevision: soulRevision,
            activeRulesImported: activeRulesImported,
            encryptedConfigDecrypted: decrypted,
            summaryText: summaryText
        )
        return ApplyResult(summary: summary, remoteConfigSnapshot: remoteConfigSnapshot)
    }

    @MainActor
    private static func importModelAndCredentials(
        payload: IOSBootstrapEnvelopePayload,
        into sharedSettings: IOSSharedSettingsStore
    ) throws -> (hasCredentials: Bool, requiresLocalSignIn: Bool) {
        let mutations = IosSettingsMutations.shared
        var settings = sharedSettings.snapshot
        let key = payload.credentials.modelApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = payload.model.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportsProvider = IOSCloudConfigWire.supportedProviders.contains(kind)
        // The daemon can also run in local echo mode, which has no iOS provider to import.
        let requiresLocalSignIn = supportsProvider
            ? try importChatModel(payload.model, apiKey: key, settings: &settings)
            : false
        var hasCredentials = supportsProvider && !key.isEmpty
        var importedSearchProviders: [[String: String]] = []
        let searchKeys = [("exa", payload.credentials.exaApiKey), ("brave", payload.credentials.braveApiKey)]
        for (type, rawKey) in searchKeys {
            guard let searchKey = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines), !searchKey.isEmpty else { continue }
            hasCredentials = true
            let alreadyImported = settings.searchServices.contains { service in
                type == "exa" ? (service as? SearchServiceOptions.ExaOptions)?.apiKey == searchKey
                    : (service as? SearchServiceOptions.BraveOptions)?.apiKey == searchKey
            }
            if alreadyImported { continue }
            let service = mutations.buildSearchService(serviceType: type, apiKey: searchKey)
            settings = mutations.addSearchServiceAndSelect(settings: settings, service: service)
            importedSearchProviders.append([
                "id": UUID().uuidString, "name": "\(type.capitalized) (Synced)", "apiKey": IOSCredentialRedactor.mask,
                "serviceType": type, "serviceId": service.id.description(),
            ])
        }
        // The settings store commits its redacted configuration only after every credential write succeeds.
        guard sharedSettings.restoreSnapshot(settings) else { throw IOSPairingBootstrapError.settingsSaveFailed }
        if !importedSearchProviders.isEmpty {
            sharedSettings.savedSearchProviders += importedSearchProviders
        }
        return (hasCredentials, requiresLocalSignIn)
    }

    @MainActor
    private static func importChatModel(
        _ model: IOSBootstrapModelSettings, apiKey: String, settings: inout Settings
    ) throws -> Bool {
        let mutations = IosSettingsMutations.shared
        let target = try importProvider(model, apiKey: apiKey, settings: &settings)
        let requiresLocalSignIn = IOSCodexProviderResolver.isChatGptSiwcProvider(target)
            && !IOSCodexProviderResolver.isSignedIn(target)
        let providerId = target.id.description()
        let modelId = model.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        func chatModel(in provider: ProviderSetting?) -> Model? {
            provider?.models.first { $0.type == .chat && $0.modelId == modelId }
        }
        var selectedModel = chatModel(in: target)
        if selectedModel == nil {
            settings = mutations.upsertProviderChatModel(
                settings: settings, providerId: providerId, modelUuid: nil,
                modelId: modelId, displayName: modelId, contextWindowTokens: nil,
                modelType: .chat, inputModalities: [.text], headerPairs: []
            )
            selectedModel = chatModel(in: settings.providers.first { $0.id.description() == providerId })
        }
        if !requiresLocalSignIn, let selectedModel {
            let id = selectedModel.id.description()
            settings = mutations.setCurrentAssistantChatModelId(settings: settings, modelId: id)
            settings = mutations.setChatModelId(settings: settings, modelId: id)
        }
        return requiresLocalSignIn
    }

    private static func importProvider(
        _ model: IOSBootstrapModelSettings, apiKey: String, settings: inout Settings
    ) throws -> ProviderSetting {
        let kind = model.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseUrl = IOSCloudConfigWire.effectiveBaseUrl(provider: kind, baseUrl: model.baseUrl)
        guard !model.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              IOSProviderEndpointPolicy.isValidBaseURL(baseUrl),
              let components = URLComponents(string: baseUrl), components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil else {
            throw IOSPairingBootstrapError.invalidEnvelopeStructure
        }
        // "plan" carries an API key and endpoint on the daemon wire, without a vendor-specific login.
        let authMode: OpenAIAuthMode = model.authMode == "chatgptSiwc" ? .chatgptSiwc : .apiKey
        let mutations = IosSettingsMutations.shared
        let matched = settings.providers.first { provider in
            guard provider.enabled else { return false }
            let localKey: String
            let localUrl: String
            if kind == "openai", let openAI = provider as? ProviderSetting.OpenAI, openAI.authMode == authMode {
                localKey = openAI.apiKey
                localUrl = openAI.baseUrl
            } else if kind == "claude", let claude = provider as? ProviderSetting.Claude {
                localKey = claude.apiKey
                localUrl = claude.baseUrl
            } else {
                return false
            }
            return IOSCloudConfigWire.effectiveBaseUrl(provider: kind, baseUrl: localUrl) == baseUrl
                && (apiKey.isEmpty || localKey.isEmpty || localKey == apiKey)
        }
        if let matched {
            if !apiKey.isEmpty {
                settings = mutations.updateProviderApiKey(settings: settings, providerId: matched.id.description(), apiKey: apiKey)
            }
            return matched
        }

        let id = KotlinUuid.companion.random()
        let balance = BalanceOption(enabled: false, apiPath: "", resultPath: "")
        let created: ProviderSetting
        if kind == "openai" {
            created = ProviderSetting.OpenAI(
                id: id, enabled: true, name: "Synced OpenAI", models: [], balanceOption: balance, builtIn: false,
                descriptionText: nil, shortDescriptionText: nil, apiKey: apiKey, baseUrl: baseUrl,
                chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: authMode,
                brand: baseUrl == IOSChatGptSiwcConstants.apiBaseUrl ? .openai : .generic
            )
        } else {
            created = ProviderSetting.Claude(
                id: id, enabled: true, name: "Synced Claude", models: [], balanceOption: balance, builtIn: false,
                descriptionText: nil, shortDescriptionText: nil, apiKey: apiKey, baseUrl: baseUrl, promptCaching: true
            )
        }
        settings = mutations.addProvider(settings: settings, provider: created)
        return created
    }

    private static func buildSummaryText(
        provider: String,
        modelId: String,
        authMode: String,
        siwcConfigured: Bool,
        requiresLocalSignIn: Bool,
        credentialsImported: Bool,
        soulSynced: Bool,
        activeRulesImported: Int
    ) -> String {
        var parts: [String] = []
        if !provider.isEmpty || !modelId.isEmpty {
            let label = [provider, modelId].filter { !$0.isEmpty }.joined(separator: " · ")
            if requiresLocalSignIn {
                parts.append("模型 \(label)（需在本机登录 SIWC）")
            } else if authMode == "chatgptSiwc" || siwcConfigured {
                parts.append("模型 \(label)（SIWC）")
            } else {
                parts.append("模型 \(label)")
            }
        }
        if credentialsImported {
            parts.append("已加密导入凭据")
        }
        if soulSynced {
            parts.append("形象人设已同步")
        }
        if activeRulesImported > 0 {
            parts.append("\(activeRulesImported) 条生效规则卡")
        }
        if parts.isEmpty {
            return IOSAppLocalization.string("配对完成", defaultValue: "配对完成")
        }
        return IOSAppLocalization.string("配对并同步完成：", defaultValue: "配对并同步完成：") + parts.joined(separator: " · ")
    }
}
