import CommonCrypto
import CryptoKit
import Foundation
import Security

#if canImport(NIOSSH)
import NIOSSH
#endif

enum IOSSSHPrivateKeyError: Error, Equatable {
    case missingPrivateKey
    case invalidFormat
    case keyTooLarge
    case unsupportedAlgorithm
    case passphraseRequired
    case incorrectPassphrase
    case secureEnclaveUnavailable

    var asSSHError: IOSSSHError {
        switch self {
        case .missingPrivateKey:
            return .missingPrivateKey
        case .invalidFormat, .keyTooLarge:
            return .invalidPrivateKey
        case .unsupportedAlgorithm, .secureEnclaveUnavailable:
            return .unsupportedPrivateKey
        case .passphraseRequired, .incorrectPassphrase:
            return .encryptedPrivateKey
        }
    }
}

#if canImport(NIOSSH)

/// Bounded SSH private-key generator and importer used by the iOS Remote SSH runtime.
///
/// Supports:
/// - Ed25519 and ECDSA (P-256 / P-384 / P-521) OpenSSH (`openssh-key-v1`) private keys,
///   both unencrypted (`cipher=none`) and passphrase-encrypted (`cipher=aes256-ctr|aes192-ctr|aes128-ctr`, `kdf=bcrypt`).
/// - Unencrypted ECDSA PEM private keys (P-256 / P-384 / P-521).
/// - Hardware-backed Secure Enclave P-256 keys (`ecdsa-sha2-nistp256`).
enum IOSSSHPrivateKey {
    struct ParsedKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        var description: String { "SSH parsed key [redacted]" }
        var debugDescription: String { description }
        let nioKey: NIOSSHPrivateKey
        let unencryptedPrivateKey: String
        let algorithm: String
        let publicKeyOpenSSH: String
        let fingerprintSHA256: String
        let wasEncrypted: Bool
    }

    private static let openSSHHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let openSSHFooter = "-----END OPENSSH PRIVATE KEY-----"
    static let maxArmoredBytes = 64 * 1024
    private static let maxFieldBytes = 64 * 1024
    private static let maxCommentBytes = 4 * 1024
    private static let openSSHBlockSize = 8
    private static let aesBlockSize = 16

    static func generate(comment: String = "") throws -> (privateKey: String, publicKey: String) {
        var generator = SystemRandomNumberGenerator()
        let seed = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })

        let key: NIOSSHPrivateKey
        do {
            key = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: seed))
        } catch {
            throw IOSSSHError.invalidPrivateKey
        }

        let rawPublicKey = String(openSSHPublicKey: key.publicKey)
        guard let publicBlob = publicBlob(from: rawPublicKey),
              let parsedPublicBlob = try? parseEd25519PublicBlob(publicBlob),
              parsedPublicBlob.algorithm == "ssh-ed25519",
              parsedPublicBlob.publicBytes.count == 32 else {
            throw IOSSSHError.invalidPrivateKey
        }

        let privateMaterial = seed + parsedPublicBlob.publicBytes
        let checkInt = UInt32.random(in: UInt32.min...UInt32.max, using: &generator)
        var privateSection = Data()
        privateSection.appendUInt32(checkInt)
        privateSection.appendUInt32(checkInt)
        privateSection.appendSSHString(Data("ssh-ed25519".utf8))
        privateSection.appendSSHString(parsedPublicBlob.publicBytes)
        privateSection.appendSSHString(privateMaterial)
        privateSection.appendSSHString(Data(comment.utf8))

        appendOpenSSHPadding(to: &privateSection, blockSize: openSSHBlockSize)

        let outer = buildUnencryptedOpenSSHOuter(publicBlob: publicBlob, privateSection: privateSection)
        let publicKeyWithComment = comment.isEmpty ? rawPublicKey : "\(rawPublicKey) \(comment)"
        return (armor(outer), publicKeyWithComment)
    }

    static func generateSecureEnclaveP256(
        requireUserPresence: Bool = false,
        comment: String = ""
    ) throws -> (dataRepresentation: Data, nioKey: NIOSSHPrivateKey, publicKeyOpenSSH: String, fingerprintSHA256: String) {
        guard SecureEnclave.isAvailable else {
            throw IOSSSHPrivateKeyError.secureEnclaveUnavailable
        }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requireUserPresence {
            flags.insert(.userPresence)
        }
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            throw IOSSSHPrivateKeyError.secureEnclaveUnavailable
        }
        let seKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            seKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        } catch {
            throw IOSSSHPrivateKeyError.secureEnclaveUnavailable
        }
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: seKey)
        let basePublicKey = String(openSSHPublicKey: nioKey.publicKey)
        let fingerprint = try fingerprintSHA256(publicKeyOpenSSH: basePublicKey)
        let fullPublicKey = comment.isEmpty ? basePublicKey : "\(basePublicKey) \(comment)"
        return (seKey.dataRepresentation, nioKey, fullPublicKey, fingerprint)
    }

    static func loadSecureEnclaveP256(dataRepresentation: Data) throws -> NIOSSHPrivateKey {
        do {
            let seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
            return NIOSSHPrivateKey(secureEnclaveP256Key: seKey)
        } catch {
            throw IOSSSHError.invalidPrivateKey
        }
    }

    static func publicKey(from privateKey: String, passphrase: String? = nil) throws -> String {
        let parsed = try parse(privateKey, passphrase: passphrase)
        return String(openSSHPublicKey: parsed.publicKey)
    }

    static func fingerprintSHA256(publicKey: NIOSSHPublicKey) throws -> String {
        try fingerprintSHA256(publicKeyOpenSSH: String(openSSHPublicKey: publicKey))
    }

    static func fingerprintSHA256(publicKeyOpenSSH: String) throws -> String {
        let parts = publicKeyOpenSSH.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let keyData = Data(base64Encoded: String(parts[1])) else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
        let digest = SHA256.hash(data: keyData)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    /// Parse one supported private-key representation into `NIOSSHPrivateKey`
    /// while preserving existing `IOSSSHError` semantics.
    static func parse(_ privateKey: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        do {
            return try parseDetailed(privateKey, passphrase: passphrase).nioKey
        } catch let keyError as IOSSSHPrivateKeyError {
            throw keyError.asSSHError
        }
    }

    /// Parse and normalize a private key (decrypting with `passphrase` if needed)
    /// into an unencrypted representation suitable for Keychain storage.
    static func parseDetailed(_ privateKey: String, passphrase: String? = nil) throws -> ParsedKey {
        guard privateKey.utf8.count <= maxArmoredBytes else {
            throw IOSSSHPrivateKeyError.keyTooLarge
        }
        let normalized = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw IOSSSHPrivateKeyError.missingPrivateKey
        }

        if normalized.contains("ENCRYPTED PRIVATE KEY")
            || normalized.contains("Proc-Type: 4,ENCRYPTED")
            || normalized.contains("DEK-Info:") {
            throw IOSSSHPrivateKeyError.passphraseRequired
        }

        if normalized.hasPrefix(openSSHHeader) {
            return try parseOpenSSHDetailed(normalized, passphrase: passphrase)
        }

        if normalized.hasPrefix("-----BEGIN RSA PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN DSA PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN OPENSSH CERTIFICATE-----") {
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm
        }

        if normalized.hasPrefix("-----BEGIN EC PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            let nioKey = try parseECDSAPEM(normalized)
            let pub = String(openSSHPublicKey: nioKey.publicKey)
            let alg = String(pub.split(separator: " ").first ?? "ecdsa-sha2-nistp256")
            let fp = try fingerprintSHA256(publicKeyOpenSSH: pub)
            return ParsedKey(
                nioKey: nioKey,
                unencryptedPrivateKey: normalized + "\n",
                algorithm: alg,
                publicKeyOpenSSH: pub,
                fingerprintSHA256: fp,
                wasEncrypted: false
            )
        }

        throw IOSSSHPrivateKeyError.invalidFormat
    }

    // MARK: - OpenSSH v1 Parser & Decryptor

    private static func parseOpenSSHDetailed(_ input: String, passphrase: String?) throws -> ParsedKey {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count >= 3,
              lines.first.map(String.init) == openSSHHeader,
              lines.last.map(String.init) == openSSHFooter else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        let bodyLines = lines.dropFirst().dropLast()
        guard !bodyLines.isEmpty,
              bodyLines.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        let body = bodyLines.map(String.init).joined()
        guard body.utf8.count <= maxArmoredBytes,
              body.utf8.allSatisfy(Self.isBase64Byte),
              body.utf8.count % 4 == 0,
              let decoded = Data(base64Encoded: body),
              decoded.count <= maxArmoredBytes else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        var reader = IOSSSHBinaryReader(data: decoded)
        let magic = Data("openssh-key-v1\0".utf8)
        guard try reader.readRawData(count: magic.count) == magic else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        let cipherName = try reader.readUTF8String(maxLength: 64)
        let kdfName = try reader.readUTF8String(maxLength: 64)
        let kdfOptions = try reader.readData(maxLength: 4 * 1024)

        guard try reader.readUInt32() == 1 else {
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm
        }

        let publicBlob = try reader.readData(maxLength: maxFieldBytes)
        let rawPrivateBlob = try reader.readData(maxLength: maxFieldBytes)
        guard reader.isAtEnd else { throw IOSSSHPrivateKeyError.invalidFormat }

        let decryptedPrivateBlob: Data
        let blockSize: Int
        let wasEncrypted: Bool

        if cipherName == "none" && kdfName == "none" && kdfOptions.isEmpty {
            decryptedPrivateBlob = rawPrivateBlob
            blockSize = openSSHBlockSize
            wasEncrypted = false
        } else if let aesKeyLength = aesCTRKeyLength(for: cipherName), kdfName == "bcrypt" {
            guard let passphrase, !passphrase.isEmpty else {
                throw IOSSSHPrivateKeyError.passphraseRequired
            }
            var kdfReader = IOSSSHBinaryReader(data: kdfOptions)
            let salt = try kdfReader.readData(maxLength: 256)
            let rounds = try kdfReader.readUInt32()
            guard kdfReader.isAtEnd, !salt.isEmpty, rounds >= 1, rounds <= 1_000 else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            guard rawPrivateBlob.count >= aesBlockSize,
                  rawPrivateBlob.count % aesBlockSize == 0 else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            let derived = try IOSSSHBcryptPBKDF.deriveKey(
                password: Data(passphrase.utf8),
                salt: salt,
                rounds: rounds,
                keyLength: aesKeyLength + aesBlockSize
            )
            let keyBytes = derived.prefix(aesKeyLength)
            let ivBytes = derived.suffix(aesBlockSize)
            decryptedPrivateBlob = try IOSSSHBcryptPBKDF.decryptAESCTR(
                ciphertext: rawPrivateBlob,
                key: Data(keyBytes),
                iv: Data(ivBytes)
            )
            blockSize = aesBlockSize
            wasEncrypted = true
        } else if cipherName != "none" || kdfName != "none" {
            // Encrypted with an unsupported cipher/KDF or malformed header
            if passphrase == nil || passphrase?.isEmpty == true {
                throw IOSSSHPrivateKeyError.passphraseRequired
            }
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm
        } else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        guard decryptedPrivateBlob.count % blockSize == 0 else {
            throw wasEncrypted ? IOSSSHPrivateKeyError.incorrectPassphrase : IOSSSHPrivateKeyError.invalidFormat
        }

        var privateReader = IOSSSHBinaryReader(data: decryptedPrivateBlob)
        let checkInt1 = try privateReader.readUInt32()
        let checkInt2 = try privateReader.readUInt32()
        guard checkInt1 == checkInt2 else {
            throw wasEncrypted ? IOSSSHPrivateKeyError.incorrectPassphrase : IOSSSHPrivateKeyError.invalidFormat
        }

        let privateAlgorithm = try privateReader.readUTF8String(maxLength: 64)
        let nioKey: NIOSSHPrivateKey
        let unencryptedSectionBody: Data

        switch privateAlgorithm {
        case "ssh-ed25519":
            let (pubAlg, publicBytes) = try parseEd25519PublicBlob(publicBlob)
            guard pubAlg == "ssh-ed25519", publicBytes.count == 32 else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            let privatePublicBytes = try privateReader.readData(maxLength: 64)
            let privateMaterial = try privateReader.readData(maxLength: 128)
            let comment = try privateReader.readUTF8String(maxLength: maxCommentBytes)
            try verifyOpenSSHPadding(&privateReader, blockSize: blockSize, wasEncrypted: wasEncrypted)

            guard privatePublicBytes == publicBytes,
                  privateMaterial.count == 64,
                  Data(privateMaterial.suffix(32)) == publicBytes else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            let seed = Data(privateMaterial.prefix(32))
            do {
                nioKey = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: seed))
            } catch {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            var body = Data()
            body.appendUInt32(checkInt1)
            body.appendUInt32(checkInt2)
            body.appendSSHString(Data("ssh-ed25519".utf8))
            body.appendSSHString(publicBytes)
            body.appendSSHString(privateMaterial)
            body.appendSSHString(Data(comment.utf8))
            unencryptedSectionBody = body

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let (pubAlg, pubCurve, pubQ) = try parseECDSAPublicBlob(publicBlob)
            guard pubAlg == privateAlgorithm else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            let privCurve = try privateReader.readUTF8String(maxLength: 64)
            let privQ = try privateReader.readData(maxLength: 256)
            let privScalarMPInt = try privateReader.readData(maxLength: 256)
            let comment = try privateReader.readUTF8String(maxLength: maxCommentBytes)
            try verifyOpenSSHPadding(&privateReader, blockSize: blockSize, wasEncrypted: wasEncrypted)

            guard privCurve == pubCurve, privQ == pubQ else {
                throw IOSSSHPrivateKeyError.invalidFormat
            }
            nioKey = try buildECDSAPrivateKey(
                algorithm: privateAlgorithm,
                curve: privCurve,
                publicPoint: pubQ,
                mpintScalar: privScalarMPInt
            )
            var body = Data()
            body.appendUInt32(checkInt1)
            body.appendUInt32(checkInt2)
            body.appendSSHString(Data(privateAlgorithm.utf8))
            body.appendSSHString(Data(privCurve.utf8))
            body.appendSSHString(privQ)
            body.appendSSHString(privScalarMPInt)
            body.appendSSHString(Data(comment.utf8))
            unencryptedSectionBody = body

        case "ssh-rsa", "ssh-dss", "ecdsa-sha2-nistp256-cert-v01@openssh.com", "ssh-ed25519-cert-v01@openssh.com":
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm

        default:
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm
        }

        let canonicalPub = String(openSSHPublicKey: nioKey.publicKey)
        guard let canonicalPublicBlob = Self.publicBlob(from: canonicalPub),
              canonicalPublicBlob == publicBlob else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }

        let normalizedPrivateKey: String
        if wasEncrypted {
            var rePadded = unencryptedSectionBody
            appendOpenSSHPadding(to: &rePadded, blockSize: openSSHBlockSize)
            let outer = buildUnencryptedOpenSSHOuter(publicBlob: publicBlob, privateSection: rePadded)
            normalizedPrivateKey = armor(outer)
        } else {
            normalizedPrivateKey = input.hasSuffix("\n") ? input : (input + "\n")
        }

        let fingerprint = try fingerprintSHA256(publicKeyOpenSSH: canonicalPub)
        return ParsedKey(
            nioKey: nioKey,
            unencryptedPrivateKey: normalizedPrivateKey,
            algorithm: privateAlgorithm,
            publicKeyOpenSSH: canonicalPub,
            fingerprintSHA256: fingerprint,
            wasEncrypted: wasEncrypted
        )
    }

    private static func aesCTRKeyLength(for cipherName: String) -> Int? {
        switch cipherName {
        case "aes256-ctr": return kCCKeySizeAES256
        case "aes192-ctr": return kCCKeySizeAES192
        case "aes128-ctr": return kCCKeySizeAES128
        default: return nil
        }
    }

    private static func verifyOpenSSHPadding(
        _ reader: inout IOSSSHBinaryReader,
        blockSize: Int,
        wasEncrypted: Bool
    ) throws {
        let paddingCount = reader.remaining
        guard paddingCount <= blockSize else {
            throw wasEncrypted ? IOSSSHPrivateKeyError.incorrectPassphrase : IOSSSHPrivateKeyError.invalidFormat
        }
        for index in 0..<paddingCount {
            guard reader.readByte() == UInt8(index + 1) else {
                throw wasEncrypted ? IOSSSHPrivateKeyError.incorrectPassphrase : IOSSSHPrivateKeyError.invalidFormat
            }
        }
        guard reader.isAtEnd else {
            throw wasEncrypted ? IOSSSHPrivateKeyError.incorrectPassphrase : IOSSSHPrivateKeyError.invalidFormat
        }
    }

    private static func buildECDSAPrivateKey(
        algorithm: String,
        curve: String,
        publicPoint: Data,
        mpintScalar: Data
    ) throws -> NIOSSHPrivateKey {
        let expectedScalarSize: Int
        switch (algorithm, curve) {
        case ("ecdsa-sha2-nistp256", "nistp256"):
            expectedScalarSize = 32
        case ("ecdsa-sha2-nistp384", "nistp384"):
            expectedScalarSize = 48
        case ("ecdsa-sha2-nistp521", "nistp521"):
            expectedScalarSize = 66
        default:
            throw IOSSSHPrivateKeyError.unsupportedAlgorithm
        }

        let rawScalar = try normalizeMPIntScalar(mpintScalar, targetSize: expectedScalarSize)
        do {
            switch expectedScalarSize {
            case 32:
                let key = try P256.Signing.PrivateKey(rawRepresentation: rawScalar)
                guard key.publicKey.x963Representation == publicPoint else {
                    throw IOSSSHPrivateKeyError.invalidFormat
                }
                return NIOSSHPrivateKey(p256Key: key)
            case 48:
                let key = try P384.Signing.PrivateKey(rawRepresentation: rawScalar)
                guard key.publicKey.x963Representation == publicPoint else {
                    throw IOSSSHPrivateKeyError.invalidFormat
                }
                return NIOSSHPrivateKey(p384Key: key)
            case 66:
                let key = try P521.Signing.PrivateKey(rawRepresentation: rawScalar)
                guard key.publicKey.x963Representation == publicPoint else {
                    throw IOSSSHPrivateKeyError.invalidFormat
                }
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw IOSSSHPrivateKeyError.unsupportedAlgorithm
            }
        } catch let error as IOSSSHPrivateKeyError {
            throw error
        } catch {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
    }

    private static func normalizeMPIntScalar(_ mpint: Data, targetSize: Int) throws -> Data {
        var bytes = [UInt8](mpint)
        while bytes.count > targetSize && bytes.first == 0 {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count <= targetSize else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
        if bytes.count < targetSize {
            bytes = [UInt8](repeating: 0, count: targetSize - bytes.count) + bytes
        }
        return Data(bytes)
    }

    private static func parseECDSAPEM(_ input: String) throws -> NIOSSHPrivateKey {
        if let key = try? NIOSSHPrivateKey(p256Key: .init(pemRepresentation: input)) {
            return key
        }
        if let key = try? NIOSSHPrivateKey(p384Key: .init(pemRepresentation: input)) {
            return key
        }
        if let key = try? NIOSSHPrivateKey(p521Key: .init(pemRepresentation: input)) {
            return key
        }
        throw IOSSSHPrivateKeyError.invalidFormat
    }

    private static func parseEd25519PublicBlob(_ blob: Data) throws -> (algorithm: String, publicBytes: Data) {
        var reader = IOSSSHBinaryReader(data: blob)
        let algorithm = try reader.readUTF8String(maxLength: 64)
        let publicBytes = try reader.readData(maxLength: 256)
        guard reader.isAtEnd else { throw IOSSSHPrivateKeyError.invalidFormat }
        return (algorithm, publicBytes)
    }

    private static func parseECDSAPublicBlob(_ blob: Data) throws -> (algorithm: String, curve: String, publicPoint: Data) {
        var reader = IOSSSHBinaryReader(data: blob)
        let algorithm = try reader.readUTF8String(maxLength: 64)
        let curve = try reader.readUTF8String(maxLength: 64)
        let publicPoint = try reader.readData(maxLength: 256)
        guard reader.isAtEnd else { throw IOSSSHPrivateKeyError.invalidFormat }
        return (algorithm, curve, publicPoint)
    }

    private static func publicBlob(from publicKey: String) -> Data? {
        let components = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        return blob
    }

    private static func appendOpenSSHPadding(to privateSection: inout Data, blockSize: Int) {
        let paddingLength = blockSize - (privateSection.count % blockSize)
        privateSection.append(contentsOf: (1...paddingLength).map(UInt8.init))
    }

    private static func buildUnencryptedOpenSSHOuter(publicBlob: Data, privateSection: Data) -> Data {
        var outer = Data("openssh-key-v1\0".utf8)
        outer.appendSSHString(Data("none".utf8))
        outer.appendSSHString(Data("none".utf8))
        outer.appendSSHString(Data())
        outer.appendUInt32(1)
        outer.appendSSHString(publicBlob)
        outer.appendSSHString(privateSection)
        return outer
    }

    private static func armor(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        lines.reserveCapacity((encoded.count / 70) + 1)
        var start = encoded.startIndex
        while start < encoded.endIndex {
            let end = encoded.index(start, offsetBy: min(70, encoded.distance(from: start, to: encoded.endIndex)))
            lines.append(String(encoded[start..<end]))
            start = end
        }
        return ([openSSHHeader] + lines + [openSSHFooter]).joined(separator: "\n") + "\n"
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        byte == 61 // '='
            || (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 43 // '+'
            || byte == 47 // '/'
    }
}

private struct IOSSSHBinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func readRawData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw IOSSSHPrivateKeyError.invalidFormat }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func readData(maxLength: Int) throws -> Data {
        let length = Int(try readUInt32())
        guard length <= maxLength, length <= remaining else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
        let result = data.subdata(in: offset..<(offset + length))
        offset += length
        return result
    }

    mutating func readUTF8String(maxLength: Int) throws -> String {
        guard let string = String(data: try readData(maxLength: maxLength), encoding: .utf8) else {
            throw IOSSSHPrivateKeyError.invalidFormat
        }
        return string
    }

    mutating func readByte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendSSHString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }
}

#endif
