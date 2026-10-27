import CryptoKit
import Foundation
import GatewayCore
import Security

public enum JWT {
    public enum Failure: Error, CustomStringConvertible {
        case badKey(String)
        case signing(String)

        public var description: String {
            switch self {
            case .badKey(let s): "私钥无法解析: \(s)"
            case .signing(let s): "签名失败: \(s)"
            }
        }
    }

    public static func es256(header: [String: Any], claims: [String: Any], key: P256.Signing.PrivateKey) throws -> String {
        let input = try signingInput(header: header, claims: claims)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + signature.rawRepresentation.base64URLEncoded()
    }

    /// RS256 (`.rsaSignatureMessagePKCS1v15SHA256`) or PS256 (`.rsaSignatureMessagePSSSHA256`, salt = 32).
    public static func rsa(header: [String: Any], claims: [String: Any], key: SecKey, algorithm: SecKeyAlgorithm) throws -> String {
        let input = try signingInput(header: header, claims: claims)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, Data(input.utf8) as CFData, &error) as Data? else {
            throw Failure.signing(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return input + "." + signature.base64URLEncoded()
    }

    static func signingInput(header: [String: Any], claims: [String: Any]) throws -> String {
        let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let c = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return h.base64URLEncoded() + "." + c.base64URLEncoded()
    }

    /// Google and Huawei service-account keys are PKCS#8 PEM; SecKey wants the inner PKCS#1 blob.
    public static func rsaPrivateKey(pem: String) throws -> SecKey {
        let isPKCS1 = pem.contains("BEGIN RSA PRIVATE KEY")
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw Failure.badKey("PEM 不是合法 base64") }
        let pkcs1 = isPKCS1 ? der : try unwrapPKCS8(der)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw Failure.badKey(error.map { "\($0.takeRetainedValue())" } ?? "SecKeyCreateWithData")
        }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING privateKey, ... }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(Array(der))
        var info = try reader.enter(0x30)
        _ = try info.read(0x02)
        _ = try info.read(0x30)
        return Data(try info.read(0x04))
    }

    struct DERReader {
        var bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ tag: UInt8) throws -> [UInt8] {
            guard index < bytes.count, bytes[index] == tag else { throw Failure.badKey("DER 结构不符（期望 tag \(tag)）") }
            index += 1
            guard index < bytes.count else { throw Failure.badKey("DER 截断") }
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, index + count <= bytes.count else { throw Failure.badKey("DER 长度非法") }
                length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard index + length <= bytes.count else { throw Failure.badKey("DER 截断") }
            defer { index += length }
            return Array(bytes[index..<index + length])
        }

        mutating func enter(_ tag: UInt8) throws -> DERReader {
            DERReader(try read(tag))
        }
    }
}
