import Darwin
import Foundation
import GatewayCore

public struct APNsCredentials: Codable, Sendable, Equatable {
    public var keyId: String
    public var teamId: String
    /// App bundle id, sent as `apns-topic`.
    public var topic: String
    public var privateKeyPEM: String

    public init(keyId: String, teamId: String, topic: String, privateKeyPEM: String) {
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
        self.privateKeyPEM = privateKeyPEM
    }
}

public struct FCMCredentials: Codable, Sendable, Equatable {
    public var projectId: String
    public var clientEmail: String
    public var privateKeyPEM: String
    public var tokenURI: String

    /// Parses a Firebase service-account JSON file.
    public init(serviceAccount data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = json["project_id"] as? String, let email = json["client_email"] as? String,
              let key = json["private_key"] as? String
        else { throw CredentialError.invalid("不是 Firebase 服务账号 JSON（缺 project_id / client_email / private_key）") }
        projectId = project
        clientEmail = email
        privateKeyPEM = key
        tokenURI = json["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
    }
}

public struct HuaweiCredentials: Codable, Sendable, Equatable {
    public var projectId: String
    public var keyId: String
    public var subAccount: String
    public var privateKeyPEM: String
    /// Notification category; `MARKETING` works without a self-classification grant.
    public var category: String

    /// Parses an AGC service-account key file (`key_id`, `sub_account`, `private_key`, `project_id`).
    public init(serviceAccount data: Data, projectId: String?, category: String) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyId = json["key_id"] as? String, let sub = json["sub_account"] as? String,
              let key = json["private_key"] as? String
        else { throw CredentialError.invalid("不是 AGC 服务账号密钥 JSON（缺 key_id / sub_account / private_key）") }
        guard let project = projectId ?? json["project_id"] as? String else {
            throw CredentialError.invalid("缺少 projectId（文件中没有 project_id，请用 --project-id 指定）")
        }
        self.projectId = project
        self.keyId = keyId
        self.subAccount = sub
        self.privateKeyPEM = key
        self.category = category
    }
}

public enum CredentialError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let s): s
        }
    }
}

public enum CredentialKind: String, CaseIterable, Sendable {
    case apns, fcm, huawei

    public var displayName: String {
        switch self {
        case .apns: "APNs (iOS)"
        case .fcm: "FCM (Android)"
        case .huawei: "华为 Push Kit (鸿蒙)"
        }
    }
}

/// One JSON file per channel under `secrets/` (dir 700, files 600). Design doc D12.
public struct CredentialStore: Sendable {
    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
    }

    func url(_ kind: CredentialKind) -> URL { dir.appendingPathComponent("\(kind.rawValue).json") }

    public func load<T: Decodable>(_ kind: CredentialKind, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(kind)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func exists(_ kind: CredentialKind) -> Bool {
        FileManager.default.fileExists(atPath: url(kind).path)
    }

    public func save<T: Encodable>(_ value: T, as kind: CredentialKind) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url(kind).appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(value), attributes: [.posixPermissions: 0o600])
        guard rename(tmp.path, url(kind).path) == 0 else { throw CredentialError.invalid("无法写入 \(url(kind).path)") }
    }

    public func delete(_ kind: CredentialKind) throws {
        try FileManager.default.removeItem(at: url(kind))
    }
}
