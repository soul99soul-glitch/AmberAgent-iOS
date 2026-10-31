import Foundation
import Security

enum IOSSSHAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    static let key: IOSSSHAuthMethod = .privateKey

    var id: String { rawValue }

    /// Canonical wire value for agent tools (`"password"` or `"key"`).
    var wireName: String {
        switch self {
        case .password: "password"
        case .privateKey: "key"
        }
    }

    var displayName: String {
        switch self {
        case .password: "密码"
        case .privateKey: "密钥"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "password":
            self = .password
        case "privateKey", "private_key", "key":
            self = .privateKey
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown IOSSSHAuthMethod: \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct IOSSSHProfile: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: IOSSSHAuthMethod
    var keyId: String?
    var jumpProfileId: String?
    var knownHostSHA256: String?
    var knownHostHost: String?
    var knownHostPort: Int?
    var knownHostViaJump: String?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: IOSSSHAuthMethod = .password,
        keyId: String? = nil,
        jumpProfileId: String? = nil,
        knownHostSHA256: String? = nil,
        knownHostHost: String? = nil,
        knownHostPort: Int? = nil,
        knownHostViaJump: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyId = keyId
        self.jumpProfileId = jumpProfileId
        self.knownHostSHA256 = knownHostSHA256
        self.knownHostHost = knownHostHost
        self.knownHostPort = knownHostPort
        self.knownHostViaJump = knownHostViaJump
    }

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if !host.isEmpty {
            return "\(username)@\(host)"
        }
        return "New SSH Profile"
    }

    func validated() throws -> IOSSSHProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.keyId = keyId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        copy.jumpProfileId = jumpProfileId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        copy.knownHostSHA256 = knownHostSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        copy.knownHostHost = knownHostHost?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        copy.knownHostViaJump = knownHostViaJump?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        if copy.authMethod == .password {
            copy.keyId = nil
        }

        guard !copy.host.isEmpty else { throw IOSSSHError.invalidProfile("Host is required.") }
        guard !copy.username.isEmpty else { throw IOSSSHError.invalidProfile("Username is required.") }
        guard (1...65535).contains(copy.port) else { throw IOSSSHError.invalidProfile("Port must be between 1 and 65535.") }
        let hasBoundKnownHostEndpoint = copy.knownHostHost != nil || copy.knownHostPort != nil || copy.jumpProfileId != nil
        let viaJumpMismatch = copy.knownHostViaJump != copy.jumpProfileId
        if copy.knownHostSHA256 != nil,
            hasBoundKnownHostEndpoint,
            (copy.knownHostHost != copy.host || copy.knownHostPort != copy.port || viaJumpMismatch) {
            copy.knownHostSHA256 = nil
            copy.knownHostHost = nil
            copy.knownHostPort = nil
            copy.knownHostViaJump = nil
        }
        return copy
    }
}

enum IOSSSHTrustState: Equatable, Sendable {
    case trusted
    case needsTrust(fingerprint: String)
    case mismatch(expected: String, actual: String)
}

struct IOSSSHConnectionProbeResult: Equatable, Sendable {
    let fingerprint: String
    let trustState: IOSSSHTrustState
}

struct IOSSSHHopProbeResult: Equatable, Sendable {
    let hopIndex: Int
    let hopCount: Int
    let profileId: String
    let host: String
    let port: Int
    let fingerprint: String
    let trustState: IOSSSHTrustState
}

struct IOSSSHHopFailure: Error, Equatable, Sendable {
    let status: String
    let hopIndex: Int
    let hopCount: Int
    let profileId: String
    let display: String
    let expectedFingerprint: String?
    let presentedFingerprint: String?
    let message: String

    init(
        status: String,
        hopIndex: Int,
        hopCount: Int,
        profileId: String,
        display: String = "",
        expectedFingerprint: String? = nil,
        presentedFingerprint: String? = nil,
        message: String
    ) {
        self.status = status
        self.hopIndex = hopIndex
        self.hopCount = hopCount
        self.profileId = profileId
        self.display = display
        self.expectedFingerprint = expectedFingerprint
        self.presentedFingerprint = presentedFingerprint
        self.message = message
    }

    func toToolFields() -> [String: Any] {
        var fields: [String: Any] = [
            "status": status,
            "error_code": status,
            "hop_index": hopIndex,
            "hop_count": hopCount,
            "profile_id": profileId,
            "reason": message,
            "message": message,
            "error": message,
        ]
        if !display.isEmpty {
            fields["display"] = display
        }
        if let expectedFingerprint {
            fields["expected_fingerprint"] = expectedFingerprint
        }
        if let presentedFingerprint {
            fields["presented_fingerprint"] = presentedFingerprint
        }
        return fields
    }
}

struct IOSSSHCommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int?

    init(output: String, exitCode: Int?) {
        self.stdout = output
        self.stderr = ""
        self.exitCode = exitCode
    }

    init(stdout: String, stderr: String, exitCode: Int?) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    var output: String {
        guard !stderr.isEmpty else { return stdout }
        guard !stdout.isEmpty else { return "[stderr]\n\(stderr)" }
        return stdout + (stdout.hasSuffix("\n") ? "" : "\n") + "[stderr]\n" + stderr
    }
}

struct IOSSSHOutputChunk: Equatable, Sendable {
    let text: String
    let isStderr: Bool
}

enum IOSSSHError: Error, LocalizedError, Equatable, Sendable {
    case invalidProfile(String)
    case missingPassword
    case missingPrivateKey
    case invalidPrivateKey
    case unsupportedPrivateKey
    case encryptedPrivateKey
    case authenticationFailed
    case credentialUnavailable
    case noDefaultProfile
    case hostKeyNotTrusted(String)
    case hostKeyMismatch(expected: String, actual: String)
    case hopFailure(IOSSSHHopFailure)
    case backendUnavailable
    case commandTimedOut
    case commandCancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): message
        case .missingPassword: "SSH password is required for this profile."
        case .missingPrivateKey: "请导入或生成 SSH 私钥。"
        case .invalidPrivateKey: "私钥格式无效或公私钥不匹配。"
        case .unsupportedPrivateKey: "此私钥类型暂不支持，请使用 Ed25519 OpenSSH 或 ECDSA 私钥。"
        case .encryptedPrivateKey: "私钥已加密，请提供口令（passphrase）后再导入。"
        case .authenticationFailed: "SSH 认证失败，请检查账户、密码或服务器上的公钥配置。"
        case .credentialUnavailable: "SSH 凭证不可用，请解锁设备后重试，或重新保存凭证。"
        case .noDefaultProfile: "Create and select a default SSH profile before running remote SSH commands."
        case .hostKeyNotTrusted(let fingerprint): "Host fingerprint must be trusted first: \(fingerprint)"
        case .hostKeyMismatch(let expected, let actual): "Host fingerprint mismatch. Expected \(expected), got \(actual)."
        case .hopFailure(let failure): failure.message
        case .backendUnavailable: "SwiftNIO SSH is not linked in this build."
        case .commandTimedOut: "SSH command timed out."
        case .commandCancelled: "SSH command was cancelled."
        case .commandFailed(let message): message
        }
    }
}

/// Kept out of profile Codable, settings exports, tool arguments and job snapshots.
enum IOSSSHCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(String)
    case privateKey(String)
    case secureEnclaveKey(Data)

    var authMethod: IOSSSHAuthMethod {
        switch self {
        case .password: .password
        case .privateKey, .secureEnclaveKey: .privateKey
        }
    }

    var secret: String {
        switch self {
        case .password(let value), .privateKey(let value):
            return value
        case .secureEnclaveKey:
            return ""
        }
    }

    var description: String { "SSH credential [redacted]" }
    var debugDescription: String { description }

    func validated(for profile: IOSSSHProfile) throws -> IOSSSHCredential {
        guard authMethod == profile.authMethod else { throw IOSSSHError.credentialUnavailable }
        switch self {
        case .password(let value):
            guard !value.isEmpty else { throw IOSSSHError.missingPassword }
            guard value.utf8.count <= 64 * 1024 else {
                throw IOSSSHError.invalidProfile("SSH 凭证不能超过 64 KB。")
            }
        case .privateKey(let value):
            guard !value.isEmpty else { throw IOSSSHError.missingPrivateKey }
            guard value.utf8.count <= 64 * 1024 else {
                throw IOSSSHError.invalidProfile("SSH 凭证不能超过 64 KB。")
            }
        case .secureEnclaveKey(let token):
            guard !token.isEmpty else { throw IOSSSHError.missingPrivateKey }
        }
        return self
    }
}

enum IOSSSHSecretStore {
    private static let service = "app.amber.agent.ssh"

    private struct StoredCredential: Codable {
        let host: String
        let port: Int
        let username: String
        let authMethod: IOSSSHAuthMethod
        let secret: String
    }

    static func passwordAccount(profileId: String) -> String { "ssh-password:\(profileId)" }
    private static func credentialAccount(_ id: String) -> String { "ssh-credential:\(id)" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    private static func save(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let base = query(account)
        // Update in place: a failed write must not erase a working credential.
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw IOSSSHError.credentialUnavailable }
    }

    private static func load(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IOSSSHError.credentialUnavailable }
        return data
    }

    private static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IOSSSHError.credentialUnavailable }
    }

    static func saveCredential(_ credential: IOSSSHCredential, profile: IOSSSHProfile) throws {
        let profile = try profile.validated()
        _ = try credential.validated(for: profile)
        if case .privateKey(let key) = credential { _ = try IOSSSHPrivateKey.publicKey(from: key) }
        let payload = StoredCredential(host: profile.host, port: profile.port, username: profile.username,
                                       authMethod: profile.authMethod, secret: credential.secret)
        try save(JSONEncoder().encode(payload), account: credentialAccount(profile.id))
        try delete(passwordAccount(profileId: profile.id))
    }

    static func loadCredential(profile: IOSSSHProfile) throws -> IOSSSHCredential? {
        let profile = try profile.validated()
        if let data = try load(credentialAccount(profile.id)) {
            guard let stored = try? JSONDecoder().decode(StoredCredential.self, from: data),
                  stored.host == profile.host, stored.port == profile.port,
                  stored.username == profile.username, stored.authMethod == profile.authMethod else {
                throw IOSSSHError.credentialUnavailable
            }
            return stored.authMethod == .password ? .password(stored.secret) : .privateKey(stored.secret)
        }
        // Upgrade existing passwords only while unlocked. Never return a legacy secret
        // unless the stricter protection and endpoint binding were saved successfully.
        guard profile.authMethod == .password else { return nil }
        let legacyAccount = passwordAccount(profileId: profile.id)
        let protection = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(legacyAccount) as CFDictionary, protection as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IOSSSHError.credentialUnavailable }
        guard let data = try load(legacyAccount),
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        let credential = IOSSSHCredential.password(password)
        try saveCredential(credential, profile: profile)
        return credential
    }

    /// Returns only whether a Keychain item exists. The credential payload is
    /// intentionally never loaded for settings summaries or UI status.
    static func hasCredential(profile: IOSSSHProfile) throws -> Bool {
        let profile = try profile.validated()
        let accounts: [String] = [
            credentialAccount(profile.id),
            profile.authMethod == .password ? passwordAccount(profileId: profile.id) : ""
        ].filter { !$0.isEmpty }

        for account in accounts {
            var request = query(account)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecSuccess { return true }
            if status != errSecItemNotFound {
                throw IOSSSHError.credentialUnavailable
            }
        }
        return false
    }

    static func deleteCredential(profileId: String) throws {
        try delete(passwordAccount(profileId: profileId))
        try delete(credentialAccount(profileId))
    }
}
