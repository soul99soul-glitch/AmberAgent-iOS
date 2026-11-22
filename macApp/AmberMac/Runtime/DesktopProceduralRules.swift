import CryptoKit
import Foundation
@preconcurrency import GatewayCore
import Security

// MARK: - Procedural Rule Cards (Stage 3-A)

enum DesktopProceduralRuleStatus: String, Codable, Equatable, Sendable {
    case proposed
    case active
    case archived
    case revoked

    var displayTitle: String {
        switch self {
        case .proposed: "待确认"
        case .active: "生效中"
        case .archived: "已归档"
        case .revoked: "已撤销"
        }
    }
}

struct DesktopProceduralRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var instruction: String
    var scope: String
    var sourceEventId: String
    var status: DesktopProceduralRuleStatus
    var hitCount: Int
    var createdAt: Int64
    var updatedAt: Int64
}

struct DesktopProceduralRuleListResponse: Decodable, Equatable, Sendable {
    var rules: [DesktopProceduralRule]
    var activeCount: Int
    var proposedCount: Int
}

struct DesktopProceduralRuleResponse: Decodable, Equatable, Sendable {
    var rule: DesktopProceduralRule
    var deduplicated: Bool?
}

struct DesktopProceduralRuleRedirectResponse: Decodable, Equatable, Sendable {
    var error: String?
    var redirectToSoul: Bool?
    var target: String?
    var message: String?
}

enum DesktopRuleProposalOutcome: Equatable, Sendable {
    case proposed(DesktopProceduralRule, deduplicated: Bool)
    case redirectToSoul(target: String, message: String)
    case rejected(code: String, message: String)
}

protocol DesktopCloudRulesSync: Sendable {
    func listRules() async throws -> [DesktopProceduralRule]
    func proposeRule(title: String?, instruction: String, scope: String) async throws -> DesktopRuleProposalOutcome
    func confirmRule(id: String) async throws -> DesktopProceduralRule
    func archiveRule(id: String) async throws -> DesktopProceduralRule
    func revokeRule(id: String) async throws -> DesktopProceduralRule
}

struct DesktopCloudClientRulesSync: DesktopCloudRulesSync {
    let client: DesktopCloudClient

    func listRules() async throws -> [DesktopProceduralRule] {
        try await client.fetchRules()
    }

    func proposeRule(title: String?, instruction: String, scope: String) async throws -> DesktopRuleProposalOutcome {
        try await client.proposeRule(title: title, instruction: instruction, scope: scope)
    }

    func confirmRule(id: String) async throws -> DesktopProceduralRule {
        try await client.confirmRule(id: id)
    }

    func archiveRule(id: String) async throws -> DesktopProceduralRule {
        try await client.archiveRule(id: id)
    }

    func revokeRule(id: String) async throws -> DesktopProceduralRule {
        try await client.revokeRule(id: id)
    }
}

// MARK: - Single-Scan Pairing & Encrypted Bootstrap Sync (Stage 3-A)

/// Non-secret metadata carried inside `amber://gateway/pair?p=...`.
/// Plaintext API keys and OAuth tokens are strictly forbidden in QR payloads.
struct DesktopPairingBootstrapHint: Codable, Equatable, Sendable {
    var syncSupported: Bool = true
    var configRevision: Int = 0
    var provider: String = ""
    var authMode: String = "apiKey"
    var siwcConfigured: Bool = false
    var hasEncryptedCredentials: Bool = false
    var soulRevision: Int64 = 0
    var activeRulesCount: Int = 0
}

struct DesktopBootstrapCredentials: Codable, Equatable, Sendable {
    var modelApiKey: String?
    var exaApiKey: String?
    var braveApiKey: String?
}

struct DesktopBootstrapModelSettings: Codable, Equatable, Sendable {
    var provider: String
    var modelId: String
    var baseUrl: String = ""
    var authMode: String = "apiKey"
    var siwcConfigured: Bool = false
}

struct DesktopBootstrapSearchSettings: Codable, Equatable, Sendable {
    var sources: [String]
    var mode: String
}

/// Plaintext payload sealed inside `PairingBootstrapSnapshot.encryptedConfigJwe` (`typ: "amber-bootstrap+jwe"`).
struct DesktopBootstrapEnvelopePayload: Codable, Equatable, Sendable {
    var version: Int
    var gatewayId: String
    var deviceId: String
    var issuedAt: Int64
    var expiresAt: Int64
    var configRevision: Int
    var model: DesktopBootstrapModelSettings
    var search: DesktopBootstrapSearchSettings
    var credentials: DesktopBootstrapCredentials
}

struct DesktopPairingBootstrapSnapshot: Decodable, Sendable {
    var version: Int?
    var configuration: DesktopCloudRemoteConfigResponse?
    var encryptedConfigJwe: String?
    var soul: AmberControl.SoulState?
    var activeRules: [DesktopProceduralRule]?
    var importKey: DesktopCloudImportKeyResponse?
}

struct DesktopIssuedPairingTicket: Decodable, Equatable, Sendable {
    var deepLinkUrl: String
    var fingerprint: String
    var addresses: [String]
    var port: Int
    var expiresAt: Double
    var bootstrap: DesktopPairingBootstrapHint

    // The daemon may be behind a TLS proxy with a different port and certificate.
    func usingPairedEndpoint(_ connection: DesktopCloudConnection) throws -> Self {
        guard var payload = DesktopCloudPairingPayload.parse(deepLinkUrl), payload.id == connection.gatewayId else {
            throw DesktopCloudError.invalidResponse
        }
        payload.fp = connection.fingerprint
        payload.addrs = connection.addrs
        payload.port = connection.port
        var ticket = self
        ticket.deepLinkUrl = "amber://gateway/pair?p=" + DesktopCloudBase64URL.encode(try JSONEncoder().encode(payload))
        ticket.fingerprint = payload.fp
        ticket.addresses = payload.addrs
        ticket.port = payload.port
        return ticket
    }

}

protocol DesktopCloudPairingBootstrapSync: Sendable {
    func issuePairingTicket() async throws -> DesktopIssuedPairingTicket
    func fetchBootstrapSnapshot(clientPublicJwk: [String: String]?) async throws -> DesktopPairingBootstrapSnapshot
}

struct DesktopCloudClientPairingBootstrapSync: DesktopCloudPairingBootstrapSync {
    let client: DesktopCloudClient
    let connection: DesktopCloudConnection

    func issuePairingTicket() async throws -> DesktopIssuedPairingTicket {
        try await client.issuePairingTicket().usingPairedEndpoint(connection)
    }

    func fetchBootstrapSnapshot(clientPublicJwk: [String: String]?) async throws -> DesktopPairingBootstrapSnapshot {
        try await client.fetchBootstrapSnapshot(clientPublicJwk: clientPublicJwk)
    }
}

/// Ephemeral RSA-OAEP-256 + A256GCM JWE helper for decrypting single-scan pairing bootstrap envelopes.
enum DesktopBootstrapJWE {
    /// Generates an ephemeral in-memory RSA keypair (never persisted to Keychain) and returns
    /// strictly the public JWK (`kty`, `n`, `e`, `kid`, `use`, `alg`) with zero private parameters.
    static func generateEphemeralRSAKeyPair(bitSize: Int = 2048) throws -> (privateKey: SecKey, publicJwk: [String: String]) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bitSize,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw DesktopCloudError.invalidResponse
        }
        let (modulus, exponent) = try DesktopCloudRSA.parsePKCS1(pkcs1)
        let n = DesktopCloudBase64URL.encode(modulus)
        let e = DesktopCloudBase64URL.encode(exponent)
        let kid = DesktopCloudRSA.jwkThumbprint(e: e, n: n)
        return (
            privateKey: privateKey,
            publicJwk: [
                "kty": "RSA",
                "use": "enc",
                "alg": "RSA-OAEP-256",
                "kid": kid,
                "n": n,
                "e": e,
            ]
        )
    }

    /// Decrypts a compact JWE sealed with `RSA-OAEP-256` + `A256GCM` and `typ = "amber-bootstrap+jwe"`.
    static func unseal(_ compact: String, privateKey: SecKey) throws -> DesktopBootstrapEnvelopePayload {
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let headerData = DesktopCloudBase64URL.decode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              (header["alg"] as? String) == "RSA-OAEP-256",
              (header["enc"] as? String) == "A256GCM",
              (header["typ"] as? String) == "amber-bootstrap+jwe",
              let encryptedKey = DesktopCloudBase64URL.decode(parts[1]),
              let iv = DesktopCloudBase64URL.decode(parts[2]),
              let ciphertext = DesktopCloudBase64URL.decode(parts[3]),
              let tag = DesktopCloudBase64URL.decode(parts[4])
        else {
            throw DesktopCloudError.invalidResponse
        }
        var decryptError: Unmanaged<CFError>?
        guard let cekData = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            encryptedKey as CFData,
            &decryptError
        ) as Data? else {
            throw DesktopCloudError.invalidResponse
        }
        guard cekData.count == 32, iv.count == 12, tag.count == 16 else { throw DesktopCloudError.invalidResponse }
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: cekData), authenticating: Data(parts[0].utf8))
        return try JSONDecoder().decode(DesktopBootstrapEnvelopePayload.self, from: plaintext)
    }
}
