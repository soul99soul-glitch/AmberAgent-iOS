import CryptoKit
import Darwin
import Foundation

public enum DevicePlatform: String, Codable, Sendable { case ios, android, harmony }
public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }

public struct PairedDevice: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    /// SHA-256 of the bearer token; the token itself is only ever held by the device.
    public var tokenHash: String
    public var pushToken: String?
    public var pushEnvironment: PushEnvironment?
    public var pairedAt: Date
    public var lastSeenAt: Date

    public init(id: String, name: String, platform: DevicePlatform, tokenHash: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.platform = platform
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeenAt = pairedAt
    }
}

public enum Secrets {
    public static func random(bytes: Int = 16) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded()
    }

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    public func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}

/// devices.json is written by both the daemon (pairing, push tokens) and the CLI (revoke), so every
/// read-modify-write holds an flock.
public struct DeviceStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [PairedDevice] {
        (try? loadStrict()) ?? []
    }

    /// Throws when the file exists but can't be decoded, so callers never overwrite it with an empty list.
    public func loadStrict() throws -> [PairedDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try GatewayJSON.decoder().decode([PairedDevice].self, from: data)
    }

    @discardableResult
    public func update<T>(_ body: (inout [PairedDevice]) throws -> T) throws -> T {
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        var devices = try loadStrict()
        let before = devices
        let result = try body(&devices)
        if devices != before {
            try GatewayJSON.encoder(pretty: true).encode(devices).write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
        return result
    }

    public func device(forToken token: String) throws -> PairedDevice? {
        let hash = Secrets.sha256(token)
        return try loadStrict().first { $0.tokenHash == hash }
    }
}

public struct PairingTicket: Codable, Sendable {
    public var secretHash: String
    public var expiresAt: Date

    public init(secretHash: String, expiresAt: Date) {
        self.secretHash = secretHash
        self.expiresAt = expiresAt
    }
}

public struct GatewayIdentity: Codable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static func loadOrCreate(at url: URL) -> GatewayIdentity {
        if let data = try? Data(contentsOf: url), let id = try? GatewayJSON.decoder().decode(GatewayIdentity.self, from: data) {
            return id
        }
        let id = GatewayIdentity(id: UUID().uuidString.lowercased(), name: Host.current().localizedName ?? "Mac")
        try? GatewayJSON.encoder(pretty: true).encode(id).write(to: url, options: .atomic)
        return id
    }
}

public struct AuditLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func record(_ action: String, _ detail: [String: String] = [:]) {
        var entry = detail
        entry["action"] = action
        entry["at"] = Date().formatted(.iso8601)
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
