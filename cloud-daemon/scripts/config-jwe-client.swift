// Interop fixture: Apple Security + CryptoKit -> standard compact JWE. Reads stdin, emits ciphertext only.
// No Keychain, user settings, network or plaintext temporary file access.
import Foundation
import Security
import CryptoKit

func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
// SecKey expects PKCS#1 RSA public bytes; extract the BIT STRING from the supplied X.509 SPKI DER.
func value(_ bytes: [UInt8], _ offset: inout Int, tag: UInt8) throws -> [UInt8] {
    guard offset < bytes.count, bytes[offset] == tag else { throw NSError(domain: "der-tag", code: 1) }
    offset += 1
    guard offset < bytes.count else { throw NSError(domain: "der-length", code: 1) }
    var length = Int(bytes[offset]); offset += 1
    if length & 128 != 0 {
        let count = length & 127; length = 0
        guard count > 0, count <= 4, offset + count <= bytes.count else { throw NSError(domain: "der-length", code: 2) }
        for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
    }
    guard offset + length <= bytes.count else { throw NSError(domain: "der-bounds", code: 1) }
    let result = Array(bytes[offset..<offset+length]); offset += length
    return result
}
let input = FileHandle.standardInput.readDataToEndOfFile()
let root = try JSONSerialization.jsonObject(with: input) as! [String: Any]
let keyInfo = root["importKey"] as! [String: Any]
let jwk = keyInfo["publicJwk"] as! [String: Any]
let thumbprintFields = ["e": jwk["e"] as! String, "kty": "RSA", "n": jwk["n"] as! String]
let thumbprintBytes = try JSONSerialization.data(withJSONObject: thumbprintFields, options: [.sortedKeys])
guard b64url(Data(SHA256.hash(data: thumbprintBytes))) == keyInfo["kid"] as! String else { fatalError("JWK thumbprint mismatch") }
let spki = Data(base64Encoded: keyInfo["publicKeySpkiDerBase64"] as! String)!
var offset = 0
let sequence = try value(Array(spki), &offset, tag: 0x30)
offset = 0
_ = try value(sequence, &offset, tag: 0x30)
let bits = try value(sequence, &offset, tag: 0x03)
guard bits.first == 0 else { fatalError("Invalid SPKI BIT STRING") }
var rsaOffset = 0
let rsaSequence = try value(Array(bits.dropFirst()), &rsaOffset, tag: 0x30)
rsaOffset = 0
func unsigned(_ bytes: [UInt8]) -> Data { Data(bytes.drop(while: { $0 == 0 })) }
let modulus = unsigned(try value(rsaSequence, &rsaOffset, tag: 0x02))
let exponent = unsigned(try value(rsaSequence, &rsaOffset, tag: 0x02))
guard b64url(modulus) == jwk["n"] as! String, b64url(exponent) == jwk["e"] as! String else { fatalError("SPKI/JWK mismatch") }
var failure: Unmanaged<CFError>?
let key = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData,
    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &failure)!
let header: [String: Any] = ["alg": "RSA-OAEP-256", "enc": "A256GCM", "typ": "amber-config+jwe", "kid": keyInfo["kid"]!]
let protected = b64url(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
let cek = SymmetricKey(size: .bits256)
let cekData = cek.withUnsafeBytes { Data($0) }
let wrapped = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, cekData as CFData, &failure)! as Data
let payload = try JSONSerialization.data(withJSONObject: root["payload"]!, options: [.sortedKeys])
let sealed = try AES.GCM.seal(payload, using: cek, authenticating: Data(protected.utf8))
print([protected, b64url(wrapped), b64url(Data(sealed.nonce)), b64url(sealed.ciphertext), b64url(sealed.tag)].joined(separator: "."))
