import CommonCrypto
import CryptoKit
import Foundation

/// Read-only reader for iOS `.amberbackup` archives (format written by iosApp IOSSyncBackup.export).
/// Only conversations are imported; iOS settings, providers and credentials are skipped.
enum DesktopIOSBackup {
    static let fileExtension = "amberbackup"
    private static let archiveVersion = 1
    private static let iterations = 210_000
    private static let tagBytes = 16
    private static let noPassphrase = "AmberAgent-NoPassphrase-v1"
    private static let metadataEntries: Set<String> = ["index.json", "list-previews.json", "list-icons.json",
        "artifact-shelf.json", "task-ui-drafts.json", "conversation-recaps.json", "thread-edges.json"]

    private struct Manifest: Decodable {
        struct Kdf: Decodable { var name: String?; let iterations: Int; let saltBase64: String; var keySizeBits: Int? }
        struct Cipher: Decodable { var name: String?; let ivBase64: String; var tagSizeBits: Int? }
        var archiveVersion: Int?
        let kdf: Kdf
        let cipher: Cipher
        let payloadSha256: String
        var passphraseProtected: Bool?
    }

    /// Decrypts the archive and returns a Mac restore payload containing only the conversations.
    static func payload(_ data: Data, passphrase: String?) throws -> DesktopBackupPayload {
        var value = DesktopBackupPayload()
        for document in try conversationDocuments(data, passphrase: passphrase) {
            try Task.checkCancellation()
            guard let object = try? JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any],
                  let raw = object["id"] as? String, let id = UUID(uuidString: raw) else { throw corrupt() }
            value.conversations.append(.init(id: id, document: document))
        }
        try DesktopBackup.validate(value)
        return value
    }

    static func conversationDocuments(_ data: Data, passphrase: String?) throws -> [String] {
        let outer = try StoredZip.read(data)
        guard let manifestData = outer["manifest.json"], let encrypted = outer["payload.enc"],
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else { throw corrupt() }
        let version = manifest.archiveVersion ?? 1
        guard version == archiveVersion else { throw failure("不支持的 iOS 备份版本：\(version)。请更新 Amber 后再导入。") }
        guard (manifest.kdf.name ?? "PBKDF2WithHmacSHA256") == "PBKDF2WithHmacSHA256", manifest.kdf.iterations == iterations,
              (manifest.kdf.keySizeBits ?? 256) == 256, (manifest.cipher.name ?? "AES/GCM/NoPadding") == "AES/GCM/NoPadding",
              (manifest.cipher.tagSizeBits ?? 128) == 128 else { throw failure("iOS 备份使用了不支持的加密参数。") }
        guard encrypted.count > tagBytes, hash(encrypted) == manifest.payloadSha256.lowercased(),
              let salt = Data(base64Encoded: manifest.kdf.saltBase64),
              let iv = Data(base64Encoded: manifest.cipher.ivBase64), iv.count == 12 else { throw corrupt() }
        // Same normalisation as iOS: trimmed passphrase, empty means the constant fallback.
        // An unprotected archive was always sealed with the fallback, whatever the user typed.
        let protected = manifest.passphraseProtected ?? true
        let trimmed = protected ? passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if trimmed.isEmpty, protected { throw failure("此 iOS 备份已设置口令，请先填写备份密码。") }
        try Task.checkCancellation()
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                ciphertext: encrypted.prefix(encrypted.count - tagBytes), tag: encrypted.suffix(tagBytes))
            plain = try AES.GCM.open(box, using: key(protected ? trimmed : noPassphrase, salt: salt))
        } catch { throw failure("iOS 备份密码错误或文件已损坏。") }
        try Task.checkCancellation()
        let inner = try StoredZip.read(plain)
        guard inner["settings.json"] != nil else { throw corrupt() }
        guard let conversations = inner["conversations.zip"] else { return [] }
        return try StoredZip.read(conversations)
            .filter { name, _ in
                let component = (name as NSString).lastPathComponent.lowercased()
                return (component as NSString).pathExtension == "json" && !metadataEntries.contains(component)
            }
            .sorted { $0.key < $1.key }
            .map { _, data in
                guard let text = String(data: data, encoding: .utf8) else { throw corrupt() }
                return text
            }
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var output = Data(repeating: 0, count: 32)
        let status = output.withUnsafeMutableBytes { bytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        bytes.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw failure("无法派生 iOS 备份密钥。") }
        return SymmetricKey(data: output)
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ message: String) -> DesktopRuntimeError { .message(message) }
    private static func corrupt() -> DesktopRuntimeError { failure("不是有效的 iOS 备份文件，或文件已损坏。") }

    /// Minimal reader for the uncompressed (stored) zips written by iOS.
    private enum StoredZip {
        static func read(_ data: Data) throws -> [String: Data] {
            let bytes = [UInt8](data)
            func u16(_ at: Int) throws -> Int {
                guard at >= 0, at + 2 <= bytes.count else { throw corrupt() }
                return Int(bytes[at]) | Int(bytes[at + 1]) << 8
            }
            func u32(_ at: Int) throws -> Int { try u16(at) | (try u16(at + 2)) << 16 }
            guard let eocd = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else { throw corrupt() }
            let start = eocd - data.startIndex
            var cursor = try u32(start + 16)
            var result: [String: Data] = [:]
            for _ in 0..<(try u16(start + 10)) {
                guard try u32(cursor) == 0x02014b50, try u16(cursor + 10) == 0 else { throw corrupt() }
                let size = try u32(cursor + 20), nameLength = try u16(cursor + 28)
                let skip = try u16(cursor + 30) + (try u16(cursor + 32)), local = try u32(cursor + 42)
                guard cursor + 46 + nameLength <= bytes.count,
                      let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                      !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                      !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                      try u32(local) == 0x04034b50 else { throw corrupt() }
                let begin = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
                guard begin + size <= bytes.count, result[name] == nil else { throw corrupt() }
                result[name] = Data(bytes[begin..<(begin + size)])
                cursor += 46 + nameLength + skip
            }
            return result
        }
    }
}
