import CryptoKit
import Foundation
import Security

protocol IOSPhoneControlCredentialStoring: Sendable {
    func loadPairing() async throws -> Data?
    func savePairing(_ data: Data) async throws
    func deletePairing() async throws
}

enum IOSPhoneControlCredentialError: LocalizedError {
    case invalidPairing
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPairing:
            "需要有效的 RemotePairing plist，包含对应的 Ed25519 公私钥和 identifier；普通 lockdown 配对文件不能使用。"
        case .keychain(let status):
            "无法读写本机配对钥匙串（\(status)）。"
        }
    }
}

/// Pairing is a device credential. It is never serialized with settings, chat, or backup data.
actor IOSPhoneControlCredentials: IOSPhoneControlCredentialStoring {
    private let service = "app.amber.ios.phone-control"
    private let account = "remote-pairing.v1"

    func loadPairing() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IOSPhoneControlCredentialError.keychain(status)
        }
        return try Self.validatedPairing(data)
    }

    func savePairing(_ data: Data) throws {
        try Task.checkCancellation()
        let validated = try Self.validatedPairing(data)
        let changes: [String: Any] = [
            kSecValueData as String: validated,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw IOSPhoneControlCredentialError.keychain(status) }
        var attributes = baseQuery
        for (key, value) in changes { attributes[key] = value }
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw IOSPhoneControlCredentialError.keychain(added) }
    }

    func deletePairing() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IOSPhoneControlCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// Match idevice's RpPairingFile format, and reject mismatched keys before replacing a valid record.
    nonisolated static func validatedPairing(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 1_048_576,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = value as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              signingKey.publicKey.rawRepresentation == publicKey else {
            throw IOSPhoneControlCredentialError.invalidPairing
        }
        var canonical: [String: Any] = ["public_key": publicKey, "private_key": privateKey,
                                        "identifier": identifier]
        if let alt = plist["alt_irk"] {
            guard let irk = alt as? Data, irk.count == 16 else {
                throw IOSPhoneControlCredentialError.invalidPairing
            }
            canonical["alt_irk"] = irk
        }
        return try PropertyListSerialization.data(fromPropertyList: canonical, format: .xml, options: 0)
    }
}
