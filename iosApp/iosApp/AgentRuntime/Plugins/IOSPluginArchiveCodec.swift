import CryptoKit
import Foundation

// MARK: - amber.plugin.v1 directory packages

enum IOSPluginTrustTier: String, Codable, Equatable, Sendable {
    case builtIn = "built_in"
    case signed
    case localUnsigned = "local_unsigned"

    var rank: Int {
        switch self {
        case .builtIn: 3
        case .signed: 2
        case .localUnsigned: 1
        }
    }
}

struct IOSPluginTrustRecord: Codable, Equatable, Sendable {
    let tier: IOSPluginTrustTier
    let keyId: String?
    /// Retained so a verified archive can be exported without silently
    /// stripping its provenance. These bytes never affect runtime authority.
    let publicKeyBase64: String?
    let signatureBase64: String?

    static let localUnsigned = IOSPluginTrustRecord(
        tier: .localUnsigned,
        keyId: nil,
        publicKeyBase64: nil,
        signatureBase64: nil
    )
}

private struct IOSPluginArchiveFile: Codable, Equatable {
    let path: String
    let dataBase64: String
}

private struct IOSPluginArchiveSignature: Codable, Equatable {
    let algorithm: String
    let keyId: String
    let publicKeyBase64: String
    let signatureBase64: String
}

private struct IOSPluginArchiveEnvelope: Codable, Equatable {
    let schema: String
    let files: [IOSPluginArchiveFile]
    let signature: IOSPluginArchiveSignature?
}

enum IOSPluginArchiveCodec {
    static let schema = "amber.plugin.archive.v1"
    private static let signatureDomain = Data("amber.plugin.signature.v1\0".utf8)

    static func decode(
        _ data: Data,
        packageHashForFiles: ([String: Data]) throws -> String
    ) throws -> (files: [String: Data], trust: IOSPluginTrustRecord) {
        guard data.count <= IOSPluginLimits.maxPackageBytes * 2 else {
            throw IOSPluginFileStoreError.archiveInvalid("归档超过大小上限。")
        }
        let envelope: IOSPluginArchiveEnvelope
        do { envelope = try JSONDecoder().decode(IOSPluginArchiveEnvelope.self, from: data) }
        catch { throw IOSPluginFileStoreError.archiveInvalid("归档 JSON 无效。") }
        guard envelope.schema == schema, !envelope.files.isEmpty,
              envelope.files.count <= IOSPluginLimits.maxFiles else {
            throw IOSPluginFileStoreError.archiveInvalid("归档 schema 或文件数量无效。")
        }
        var files: [String: Data] = [:]
        for member in envelope.files {
            guard IOSPluginValidator.isCanonicalPackagePath(member.path), files[member.path] == nil,
                  let bytes = Data(base64Encoded: member.dataBase64),
                  bytes.count <= IOSPluginLimits.maxFileBytes else {
                throw IOSPluginFileStoreError.archiveInvalid("归档包含重复、不安全或无效文件。")
            }
            files[member.path] = bytes
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= IOSPluginLimits.maxPackageBytes else {
            throw IOSPluginFileStoreError.fileBudgetExceeded
        }
        guard let signature = envelope.signature else { return (files, .localUnsigned) }
        let packageHash = try packageHashForFiles(files)
        guard signature.algorithm == "ed25519",
              let publicKeyData = Data(base64Encoded: signature.publicKeyBase64),
              let signatureData = Data(base64Encoded: signature.signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        let keyId = String(Self.sha256(publicKeyData).prefix(16))
        guard signature.keyId == keyId,
              publicKey.isValidSignature(signatureData, for: signedMessage(packageHash: packageHash)) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        return (files, IOSPluginTrustRecord(
            tier: .signed,
            keyId: keyId,
            publicKeyBase64: signature.publicKeyBase64,
            signatureBase64: signature.signatureBase64
        ))
    }

    static func encode(
        files: [String: Data],
        packageHash: String,
        signingKey: Curve25519.Signing.PrivateKey? = nil,
        preservedTrust: IOSPluginTrustRecord? = nil
    ) throws -> Data {
        let members = try files.keys.sorted().map { path -> IOSPluginArchiveFile in
            guard IOSPluginValidator.isCanonicalPackagePath(path), let data = files[path] else {
                throw IOSPluginFileStoreError.invalidPath(path)
            }
            return IOSPluginArchiveFile(path: path, dataBase64: data.base64EncodedString())
        }
        let signature: IOSPluginArchiveSignature?
        if let signingKey {
            let publicKey = signingKey.publicKey.rawRepresentation
            signature = IOSPluginArchiveSignature(
                algorithm: "ed25519",
                keyId: String(Self.sha256(publicKey).prefix(16)),
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: try signingKey.signature(for: signedMessage(packageHash: packageHash)).base64EncodedString()
            )
        } else if let trust = preservedTrust,
                  trust.tier == .signed,
                  let keyId = trust.keyId,
                  let publicKey = trust.publicKeyBase64,
                  let signatureBytes = trust.signatureBase64 {
            signature = IOSPluginArchiveSignature(
                algorithm: "ed25519",
                keyId: keyId,
                publicKeyBase64: publicKey,
                signatureBase64: signatureBytes
            )
        } else {
            signature = nil
        }
        let envelope = IOSPluginArchiveEnvelope(schema: schema, files: members, signature: signature)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func isTrustValid(_ trust: IOSPluginTrustRecord, packageHash: String) -> Bool {
        switch trust.tier {
        case .builtIn, .localUnsigned:
            return true
        case .signed:
            guard let keyId = trust.keyId,
                  let publicKeyBase64 = trust.publicKeyBase64,
                  let signatureBase64 = trust.signatureBase64,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64),
                  let signatureData = Data(base64Encoded: signatureBase64),
                  String(Self.sha256(publicKeyData).prefix(16)) == keyId,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
                return false
            }
            return publicKey.isValidSignature(signatureData, for: signedMessage(packageHash: packageHash))
        }
    }

    private static func signedMessage(packageHash: String) -> Data {
        signatureDomain + Data(packageHash.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

