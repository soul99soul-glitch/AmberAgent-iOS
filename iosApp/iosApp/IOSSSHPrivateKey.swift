import Foundation

#if canImport(NIOSSH)
import NIOSSH
#endif

#if canImport(NIOSSH)

/// The small, deliberately bounded SSH private-key importer used by the iOS
/// Remote SSH runtime.
///
/// NIOSSH exposes the key object and signing implementation, but it does not
/// expose an OpenSSH private-key file parser. Amber therefore accepts the
/// unencrypted OpenSSH Ed25519 format itself and delegates ECDSA PEM decoding
/// to the Crypto implementation already used by NIOSSH. No private-key
/// encryption or RSA implementation is included here.
enum IOSSSHPrivateKey {
    private static let openSSHHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let openSSHFooter = "-----END OPENSSH PRIVATE KEY-----"
    private static let maxArmoredBytes = 64 * 1024
    private static let maxFieldBytes = 64 * 1024
    private static let maxCommentBytes = 4 * 1024
    private static let openSSHBlockSize = 8

    static func generate() throws -> (privateKey: String, publicKey: String) {
        var generator = SystemRandomNumberGenerator()
        let seed = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })

        let key: NIOSSHPrivateKey
        do {
            // The argument type is inferred from NIOSSHPrivateKey's public
            // initializer. This keeps the app coupled to NIOSSH's Crypto
            // implementation without adding a second crypto dependency.
            key = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: seed))
        } catch {
            throw IOSSSHError.invalidPrivateKey
        }

        let publicKey = String(openSSHPublicKey: key.publicKey)
        guard let publicBlob = publicBlob(from: publicKey),
              let parsedPublicBlob = try? parsePublicBlob(publicBlob),
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
        privateSection.appendSSHString(Data())

        let paddingLength = openSSHBlockSize - (privateSection.count % openSSHBlockSize)
        privateSection.append(contentsOf: (1...paddingLength).map(UInt8.init))

        var outer = Data("openssh-key-v1\0".utf8)
        outer.appendSSHString(Data("none".utf8))
        outer.appendSSHString(Data("none".utf8))
        outer.appendSSHString(Data())
        outer.appendUInt32(1)
        outer.appendSSHString(publicBlob)
        outer.appendSSHString(privateSection)

        return (armor(outer), publicKey)
    }

    static func publicKey(from privateKey: String) throws -> String {
        let key = try parse(privateKey)
        return String(openSSHPublicKey: key.publicKey)
    }

    /// Parse one supported private-key representation into the NIOSSH key
    /// object used by the authentication delegate.
    static func parse(_ privateKey: String) throws -> NIOSSHPrivateKey {
        guard privateKey.utf8.count <= maxArmoredBytes else {
            throw IOSSSHError.invalidPrivateKey
        }
        let normalized = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw IOSSSHError.missingPrivateKey }

        if normalized.contains("ENCRYPTED PRIVATE KEY")
            || normalized.contains("Proc-Type: 4,ENCRYPTED")
            || normalized.contains("DEK-Info:") {
            throw IOSSSHError.encryptedPrivateKey
        }

        if normalized.hasPrefix(openSSHHeader) {
            return try parseOpenSSH(normalized)
        }

        if normalized.hasPrefix("-----BEGIN RSA PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN DSA PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN OPENSSH CERTIFICATE-----") {
            throw IOSSSHError.unsupportedPrivateKey
        }

        if normalized.hasPrefix("-----BEGIN EC PRIVATE KEY-----")
            || normalized.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            return try parseECDSAPEM(normalized)
        }

        throw IOSSSHError.invalidPrivateKey
    }

    private static func parseOpenSSH(_ input: String) throws -> NIOSSHPrivateKey {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count >= 3,
              lines.first.map(String.init) == openSSHHeader,
              lines.last.map(String.init) == openSSHFooter else {
            throw IOSSSHError.invalidPrivateKey
        }

        let bodyLines = lines.dropFirst().dropLast()
        guard !bodyLines.isEmpty,
              bodyLines.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else {
            throw IOSSSHError.invalidPrivateKey
        }

        let body = bodyLines.map(String.init).joined()
        guard body.utf8.count <= maxArmoredBytes,
              body.utf8.allSatisfy(Self.isBase64Byte),
              body.utf8.count % 4 == 0,
              let decoded = Data(base64Encoded: body),
              decoded.count <= maxArmoredBytes else {
            throw IOSSSHError.invalidPrivateKey
        }

        var reader = IOSSSHBinaryReader(data: decoded)
        let magic = Data("openssh-key-v1\0".utf8)
        guard try reader.readRawData(count: magic.count) == magic else {
            throw IOSSSHError.invalidPrivateKey
        }

        let cipherName = try reader.readUTF8String(maxLength: 64)
        let kdfName = try reader.readUTF8String(maxLength: 64)
        let kdfOptions = try reader.readData(maxLength: 4 * 1024)
        if cipherName != "none" || kdfName != "none" || !kdfOptions.isEmpty {
            throw IOSSSHError.encryptedPrivateKey
        }

        guard try reader.readUInt32() == 1 else {
            throw IOSSSHError.unsupportedPrivateKey
        }

        let publicBlob = try reader.readData(maxLength: maxFieldBytes)
        let privateBlob = try reader.readData(maxLength: maxFieldBytes)
        guard reader.isAtEnd else { throw IOSSSHError.invalidPrivateKey }

        let (algorithm, publicBytes) = try parsePublicBlob(publicBlob)
        guard algorithm == "ssh-ed25519", publicBytes.count == 32 else {
            throw IOSSSHError.unsupportedPrivateKey
        }

        var privateReader = IOSSSHBinaryReader(data: privateBlob)
        let checkInt1 = try privateReader.readUInt32()
        let checkInt2 = try privateReader.readUInt32()
        guard checkInt1 == checkInt2 else { throw IOSSSHError.invalidPrivateKey }

        let privateAlgorithm = try privateReader.readUTF8String(maxLength: 64)
        let privatePublicBytes = try privateReader.readData(maxLength: 64)
        let privateMaterial = try privateReader.readData(maxLength: 128)
        _ = try privateReader.readUTF8String(maxLength: maxCommentBytes)

        guard privateAlgorithm == "ssh-ed25519",
              privatePublicBytes == publicBytes,
              privateMaterial.count == 64,
              Data(privateMaterial.suffix(32)) == publicBytes else {
            throw IOSSSHError.invalidPrivateKey
        }

        guard privateBlob.count % openSSHBlockSize == 0 else {
            throw IOSSSHError.invalidPrivateKey
        }
        let paddingCount = privateReader.remaining
        guard paddingCount <= openSSHBlockSize else {
            throw IOSSSHError.invalidPrivateKey
        }
        for index in 0..<paddingCount {
            guard privateReader.readByte() == UInt8(index + 1) else {
                throw IOSSSHError.invalidPrivateKey
            }
        }
        guard privateReader.isAtEnd else { throw IOSSSHError.invalidPrivateKey }

        let seed = Data(privateMaterial.prefix(32))
        let key: NIOSSHPrivateKey
        do {
            key = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: seed))
        } catch {
            throw IOSSSHError.invalidPrivateKey
        }

        guard let canonicalPublicBlob = Self.publicBlob(from: String(openSSHPublicKey: key.publicKey)),
              canonicalPublicBlob == publicBlob else {
            throw IOSSSHError.invalidPrivateKey
        }
        return key
    }

    private static func parseECDSAPEM(_ input: String) throws -> NIOSSHPrivateKey {
        // CryptoKit/Swift Crypto owns the ASN.1 and PEM implementation. Do
        // not duplicate that parser here. RSA and encrypted PEM are filtered
        // before this method is reached.
        if let key = try? NIOSSHPrivateKey(p256Key: .init(pemRepresentation: input)) {
            return key
        }
        if let key = try? NIOSSHPrivateKey(p384Key: .init(pemRepresentation: input)) {
            return key
        }
        if let key = try? NIOSSHPrivateKey(p521Key: .init(pemRepresentation: input)) {
            return key
        }
        throw IOSSSHError.invalidPrivateKey
    }

    private static func parsePublicBlob(_ blob: Data) throws -> (algorithm: String, publicBytes: Data) {
        var reader = IOSSSHBinaryReader(data: blob)
        let algorithm = try reader.readUTF8String(maxLength: 64)
        let publicBytes = try reader.readData(maxLength: 256)
        guard reader.isAtEnd else { throw IOSSSHError.invalidPrivateKey }
        return (algorithm, publicBytes)
    }

    private static func publicBlob(from publicKey: String) -> Data? {
        let components = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2,
              components[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        return blob
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
            throw IOSSSHError.invalidPrivateKey
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw IOSSSHError.invalidPrivateKey }
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
            throw IOSSSHError.invalidPrivateKey
        }
        let result = data.subdata(in: offset..<(offset + length))
        offset += length
        return result
    }

    mutating func readUTF8String(maxLength: Int) throws -> String {
        guard let string = String(data: try readData(maxLength: maxLength), encoding: .utf8) else {
            throw IOSSSHError.invalidPrivateKey
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
