import CryptoKit
import Foundation
import Security

/// Self-signed EC P-256 server identity. Generated once with the system openssl and kept as a
/// PKCS#12 file (design doc D12: no Keychain while the binary is ad-hoc signed). Clients pin the
/// SHA-256 of the certificate's SubjectPublicKeyInfo, so the certificate can be reissued with the
/// same key without re-pairing.
public struct TLSIdentity {
    public let identity: SecIdentity
    /// base64 SHA-256 of the leaf certificate's SPKI DER.
    public let fingerprint: String

    static let passphrase = "amber-gateway"
    /// DER prefix of an EC P-256 SubjectPublicKeyInfo; followed by the 65-byte uncompressed point.
    static let p256SPKIPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    public enum Failure: Error, CustomStringConvertible {
        case openssl(String)
        case importFailed(OSStatus)
        case unsupportedKey

        public var description: String {
            switch self {
            case .openssl(let s): "openssl 失败: \(s)"
            case .importFailed(let s): "PKCS#12 导入失败 (OSStatus \(s))"
            case .unsupportedKey: "证书公钥不是 P-256"
            }
        }
    }

    public static func loadOrCreate(at url: URL, commonName: String) throws -> TLSIdentity {
        if !FileManager.default.fileExists(atPath: url.path) {
            try generate(at: url, commonName: commonName)
        }
        return try load(Data(contentsOf: url))
    }

    public static func load(_ p12: Data) throws -> TLSIdentity {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String]
        else { throw Failure.importFailed(status) }
        let identity = value as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw Failure.importFailed(errSecItemNotFound) }
        return TLSIdentity(identity: identity, fingerprint: try spkiFingerprint(of: cert))
    }

    public static func spkiFingerprint(of cert: SecCertificate) throws -> String {
        guard let key = SecCertificateCopyKey(cert),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              raw.count == 65
        else { throw Failure.unsupportedKey }
        return Data(SHA256.hash(data: Data(p256SPKIPrefix) + raw)).base64EncodedString()
    }

    static func generate(at url: URL, commonName: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("amber-gateway-tls-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem").path
        let cert = work.appendingPathComponent("cert.pem").path
        let p12 = work.appendingPathComponent("tls.p12").path
        let name = commonName.replacingOccurrences(of: "/", with: "-")
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        try openssl(["req", "-new", "-x509", "-key", key, "-days", "3650", "-subj", "/CN=\(name)", "-out", cert])
        // 3DES/SHA1 PBE: the combination SecPKCS12Import accepts from LibreSSL.
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:\(passphrase)",
                     "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        chmod(p12, 0o600)
        guard rename(p12, url.path) == 0 else { throw Failure.openssl("无法写入 \(url.path)") }
    }

    private static func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.openssl("\(args[0]): \(message)") }
    }
}
