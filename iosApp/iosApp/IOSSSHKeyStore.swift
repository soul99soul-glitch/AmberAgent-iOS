import Foundation
import Security

#if canImport(NIOSSH)
import NIOSSH
#endif

enum IOSSSHKeyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case ed25519 = "ed25519"
    case ecdsaP256SE = "ecdsa-p256-se"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ed25519:
            return "Ed25519（通用推荐）"
        case .ecdsaP256SE:
            return "ECDSA P-256（Secure Enclave 硬件保护）"
        }
    }
}

enum IOSSSHKeyOrigin: String, Codable, Equatable, Sendable {
    case generated = "generated"
    case imported = "imported"
}

enum IOSSSHKeyProtection: String, Codable, Equatable, Sendable {
    case keychain = "keychain"
    case secureEnclave = "secure_enclave"
}

struct IOSSSHKeyMetadata: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var algorithm: String
    var publicKeyOpenSSH: String
    var fingerprintSHA256: String
    var origin: IOSSSHKeyOrigin
    var protection: IOSSSHKeyProtection
    var hasPassphrase: Bool
    var requireUserPresence: Bool
    var createdAt: Int64

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        algorithm: String,
        publicKeyOpenSSH: String,
        fingerprintSHA256: String,
        origin: IOSSSHKeyOrigin,
        protection: IOSSSHKeyProtection,
        hasPassphrase: Bool = false,
        requireUserPresence: Bool = false,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.origin = origin
        self.protection = protection
        self.hasPassphrase = hasPassphrase
        self.requireUserPresence = requireUserPresence
        self.createdAt = createdAt
    }

    var createdAtISO8601: String {
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0)
        return ISO8601DateFormatter().string(from: date)
    }

    func toToolDictionary() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "algorithm": algorithm,
            "fingerprint_sha256": fingerprintSHA256,
            "public_key_openssh": publicKeyOpenSSH,
            "origin": origin.rawValue,
            "protection": protection.rawValue,
            "has_passphrase": hasPassphrase,
            "require_user_presence": requireUserPresence,
            "created_at": createdAtISO8601,
        ]
    }
}

#if canImport(NIOSSH)
struct IOSSSHSigningKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let metadata: IOSSSHKeyMetadata
    let nioKey: NIOSSHPrivateKey
    /// Only available for software keys stored in Keychain; nil for Secure Enclave keys.
    let extractablePrivateKey: String?
    /// Only available for Secure Enclave keys; nil for software keys.
    let secureEnclaveToken: Data?

    var description: String { "IOSSSHSigningKey [redacted]" }
    var debugDescription: String { description }
}
#endif

protocol IOSSSHKeyStoreBackend: Sendable {
    func save(_ data: Data, account: String, requireUserPresence: Bool) throws
    func load(account: String) throws -> Data?
    func hasItem(account: String) throws -> Bool
    func delete(account: String) throws
}

struct IOSSSHKeychainBackend: IOSSSHKeyStoreBackend {
    static let service = "app.amber.agent.ssh.key"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func save(_ data: Data, account: String, requireUserPresence: Bool) throws {
        var attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        if requireUserPresence {
            guard let accessControl = SecAccessControlCreateWithFlags(
               kCFAllocatorDefault,
               kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
               .userPresence,
               nil
            ) else { throw IOSSSHError.credentialUnavailable }
            attributes[kSecAttrAccessControl as String] = accessControl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let base = query(account)
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw IOSSSHError.credentialUnavailable
        }
    }

    func load(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IOSSSHError.credentialUnavailable
        }
        return data
    }

    func hasItem(account: String) throws -> Bool {
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw IOSSSHError.credentialUnavailable
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IOSSSHError.credentialUnavailable
        }
    }
}

final class IOSSSHInMemoryKeyBackend: IOSSSHKeyStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    init() {}

    func save(_ data: Data, account: String, requireUserPresence: Bool) throws {
        lock.withLock {
            storage[account] = data
        }
    }

    func load(account: String) throws -> Data? {
        lock.withLock {
            storage[account]
        }
    }

    func hasItem(account: String) throws -> Bool {
        lock.withLock {
            storage[account] != nil
        }
    }

    func delete(account: String) throws {
        _ = lock.withLock {
            storage.removeValue(forKey: account)
        }
    }
}

struct IOSSSHKeyStore: Sendable {
    private struct StoredKeyPayload: Codable {
        let keyId: String
        let algorithm: String
        let protection: IOSSSHKeyProtection
        let fingerprintSHA256: String
        let privateKeyText: String?
        let secureEnclaveToken: Data?
    }

    let backend: any IOSSSHKeyStoreBackend

    init(backend: any IOSSSHKeyStoreBackend = IOSSSHKeychainBackend()) {
        self.backend = backend
    }

    static func account(keyId: String) -> String {
        "ssh-key:\(keyId)"
    }

    #if canImport(NIOSSH)
    func generateKey(
        name: String,
        type: IOSSSHKeyType = .ed25519,
        requireUserPresence: Bool = false
    ) throws -> IOSSSHKeyMetadata {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64, !trimmedName.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw IOSSSHError.invalidProfile("密钥名称须为 1–64 个字符，且不能包含换行或 NUL。")
        }
        let keyId = UUID().uuidString.lowercased()
        let comment = "amber-\(trimmedName)"

        switch type {
        case .ed25519:
            let generated = try IOSSSHPrivateKey.generate(comment: comment)
            let parsed = try IOSSSHPrivateKey.parseDetailed(generated.privateKey)
            let metadata = IOSSSHKeyMetadata(
                id: keyId,
                name: trimmedName,
                algorithm: "ssh-ed25519",
                publicKeyOpenSSH: generated.publicKey,
                fingerprintSHA256: parsed.fingerprintSHA256,
                origin: .generated,
                protection: .keychain,
                hasPassphrase: false,
                requireUserPresence: requireUserPresence
            )
            let payload = StoredKeyPayload(
                keyId: keyId,
                algorithm: metadata.algorithm,
                protection: .keychain,
                fingerprintSHA256: metadata.fingerprintSHA256,
                privateKeyText: generated.privateKey,
                secureEnclaveToken: nil
            )
            let encoded = try JSONEncoder().encode(payload)
            try backend.save(encoded, account: Self.account(keyId: keyId), requireUserPresence: requireUserPresence)
            return metadata

        case .ecdsaP256SE:
            let generated = try IOSSSHPrivateKey.generateSecureEnclaveP256(
                requireUserPresence: requireUserPresence,
                comment: comment
            )
            let metadata = IOSSSHKeyMetadata(
                id: keyId,
                name: trimmedName,
                algorithm: "ecdsa-sha2-nistp256",
                publicKeyOpenSSH: generated.publicKeyOpenSSH,
                fingerprintSHA256: generated.fingerprintSHA256,
                origin: .generated,
                protection: .secureEnclave,
                hasPassphrase: false,
                requireUserPresence: requireUserPresence
            )
            let payload = StoredKeyPayload(
                keyId: keyId,
                algorithm: metadata.algorithm,
                protection: .secureEnclave,
                fingerprintSHA256: metadata.fingerprintSHA256,
                privateKeyText: nil,
                secureEnclaveToken: generated.dataRepresentation
            )
            let encoded = try JSONEncoder().encode(payload)
            try backend.save(encoded, account: Self.account(keyId: keyId), requireUserPresence: requireUserPresence)
            return metadata
        }
    }

    func importKey(
        name: String,
        privateKey: String,
        passphrase: String? = nil,
        requireUserPresence: Bool = false
    ) throws -> IOSSSHKeyMetadata {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64, !trimmedName.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw IOSSSHError.invalidProfile("密钥名称须为 1–64 个字符，且不能包含换行或 NUL。")
        }
        let parsed = try IOSSSHPrivateKey.parseDetailed(privateKey, passphrase: passphrase)
        let keyId = UUID().uuidString.lowercased()
        let comment = "amber-\(trimmedName)"
        let publicKeyWithComment = "\(parsed.publicKeyOpenSSH) \(comment)"
        let metadata = IOSSSHKeyMetadata(
            id: keyId,
            name: trimmedName,
            algorithm: parsed.algorithm,
            publicKeyOpenSSH: publicKeyWithComment,
            fingerprintSHA256: parsed.fingerprintSHA256,
            origin: .imported,
            protection: .keychain,
            hasPassphrase: false,
            requireUserPresence: requireUserPresence
        )
        let payload = StoredKeyPayload(
            keyId: keyId,
            algorithm: metadata.algorithm,
            protection: .keychain,
            fingerprintSHA256: metadata.fingerprintSHA256,
            privateKeyText: parsed.unencryptedPrivateKey,
            secureEnclaveToken: nil
        )
        let encoded = try JSONEncoder().encode(payload)
        try backend.save(encoded, account: Self.account(keyId: keyId), requireUserPresence: requireUserPresence)
        return metadata
    }

    func loadSigningKey(metadata: IOSSSHKeyMetadata) throws -> IOSSSHSigningKey {
        guard let data = try backend.load(account: Self.account(keyId: metadata.id)),
              let payload = try? JSONDecoder().decode(StoredKeyPayload.self, from: data),
              payload.keyId == metadata.id,
              payload.fingerprintSHA256 == metadata.fingerprintSHA256 else {
            throw IOSSSHError.credentialUnavailable
        }
        switch payload.protection {
        case .keychain:
            guard let text = payload.privateKeyText else {
                throw IOSSSHError.credentialUnavailable
            }
            let nioKey = try IOSSSHPrivateKey.parse(text)
            return IOSSSHSigningKey(
                metadata: metadata,
                nioKey: nioKey,
                extractablePrivateKey: text,
                secureEnclaveToken: nil
            )
        case .secureEnclave:
            guard let token = payload.secureEnclaveToken else {
                throw IOSSSHError.credentialUnavailable
            }
            let nioKey = try IOSSSHPrivateKey.loadSecureEnclaveP256(dataRepresentation: token)
            return IOSSSHSigningKey(
                metadata: metadata,
                nioKey: nioKey,
                extractablePrivateKey: nil,
                secureEnclaveToken: token
            )
        }
    }
    #endif

    func hasKeyMaterial(keyId: String) -> Bool {
        (try? backend.hasItem(account: Self.account(keyId: keyId))) ?? false
    }

    func deleteKeyMaterial(keyId: String) throws {
        try backend.delete(account: Self.account(keyId: keyId))
    }
}
