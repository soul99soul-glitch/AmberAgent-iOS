import Foundation
import Observation
import Security

private struct SettingsData: Codable {
    var baseUrl: String
    var apiKey: String  // kept for Codable compatibility; always empty now (real key lives in Keychain)
    var modelId: String
    var terminalDefaultRuntime: IOSTerminalRuntimeKind?
    var terminalExperimentalRuntimesEnabled: Bool?
    var sshProfiles: [IOSSSHProfile]?
    var sshDefaultProfileId: String?
    var sshKeys: [IOSSSHKeyMetadata]?
}

protocol SettingsAPIKeyStore {
    func loadApiKey() -> String?
    @discardableResult
    func saveApiKey(_ key: String) -> Bool
}

private struct KeychainSettingsAPIKeyStore: SettingsAPIKeyStore {
    let account: String

    func loadApiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func saveApiKey(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

@Observable
final class SettingsStore {

    var baseUrl: String {
        didSet { save() }
    }
    var apiKey: String {
        didSet { saveApiKey() }
    }
    var modelId: String {
        didSet { save() }
    }
    var terminalDefaultRuntime: IOSTerminalRuntimeKind {
        didSet { save() }
    }
    var terminalExperimentalRuntimesEnabled: Bool {
        didSet { save() }
    }
    var sshProfiles: [IOSSSHProfile] {
        didSet {
            if let defaultId = sshDefaultProfileId,
               !sshProfiles.contains(where: { $0.id == defaultId }) {
                sshDefaultProfileId = sshProfiles.first?.id
            }
            save()
        }
    }
    var sshDefaultProfileId: String? {
        didSet { save() }
    }
    var sshKeys: [IOSSSHKeyMetadata] {
        didSet { save() }
    }

    /// G7: 前台单轮工具循环上限。UserDefaults 独立 key 直读直写（与
    /// ExecutionSettingsView 的 @AppStorage 共用），不进 SettingsData blob，
    /// 避免两处写同一 blob 互相覆盖。默认 128，可选 128-8192。
    var chatMaxToolResumeCount: Int {
        get {
            guard defaults.object(forKey: Self.chatMaxToolResumeCountKey) != nil else {
                return Self.defaultChatMaxToolResumeCount
            }
            return Self.clampChatMaxToolResumeCount(defaults.integer(forKey: Self.chatMaxToolResumeCountKey))
        }
        set {
            defaults.set(Self.clampChatMaxToolResumeCount(newValue), forKey: Self.chatMaxToolResumeCountKey)
        }
    }

    static let defaultChatMaxToolResumeCount = 128
    static let chatMaxToolResumeCountOptions = [128, 256, 512, 1024, 2048, 4096, 8192]
    static let chatMaxToolResumeCountRange = 128...8192

    static func clampChatMaxToolResumeCount(_ value: Int) -> Int {
        // 旧档位向上归入可选档位，避免升级后缩减已有预算或让面板没有选中项。
        chatMaxToolResumeCountOptions.first { $0 >= value } ?? chatMaxToolResumeCountRange.upperBound
    }

    /// P3-a: exec 纯求值工具总开关（默认关）。UserDefaults 独立 key 直读直写
    /// （与 ExecutionSettingsView 的 @AppStorage 共用），不进 SettingsData blob，
    /// 避免两处写同一 blob 互相覆盖。开时 exec 声明进桥输入 deferred 池
    /// （tool_search 命中后可调用）；关时声明与执行路径零痕迹。
    var execJavaScriptEnabled: Bool {
        get { defaults.bool(forKey: Self.execJavaScriptEnabledKey) }
        set { defaults.set(newValue, forKey: Self.execJavaScriptEnabledKey) }
    }

    private static let storageKey = "app.amber.ios.settings"
    private static let apiKeyKeychainAccount = "app.amber.ios.apiKey"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let apiKeyStore: any SettingsAPIKeyStore
    @ObservationIgnored let keyStore: IOSSSHKeyStore
    private static let chatMaxToolResumeCountKey = IOSExecutionPreferenceKeys.chatMaxToolResumeCount
    private static let execJavaScriptEnabledKey = IOSExecutionPreferenceKeys.execJavaScriptEnabled

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = SettingsStore.storageKey,
        apiKeyStore: (any SettingsAPIKeyStore)? = nil,
        keyStore: IOSSSHKeyStore = IOSSSHKeyStore()
    ) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.apiKeyStore = apiKeyStore ?? KeychainSettingsAPIKeyStore(account: Self.apiKeyKeychainAccount)
        self.keyStore = keyStore

        // Load non-sensitive settings from UserDefaults.
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) {
            baseUrl = decoded.baseUrl
            modelId = decoded.modelId
            terminalDefaultRuntime = IOSTerminalBuildPolicy.normalizedDefaultRuntime(
                decoded.terminalDefaultRuntime ?? .remoteSSH
            )
            terminalExperimentalRuntimesEnabled = IOSTerminalBuildPolicy.experimentalRuntimesLinked &&
                (decoded.terminalExperimentalRuntimesEnabled ?? false)
            let decodedSSHProfiles = decoded.sshProfiles ?? []
            sshProfiles = decodedSSHProfiles
            sshKeys = decoded.sshKeys ?? []
            if let decodedDefault = decoded.sshDefaultProfileId,
               decodedSSHProfiles.contains(where: { $0.id == decodedDefault }) {
                sshDefaultProfileId = decodedDefault
            } else {
                sshDefaultProfileId = decodedSSHProfiles.first?.id
            }
        } else {
            baseUrl = "https://api.openai.com/v1"
            modelId = "gpt-4o"
            terminalDefaultRuntime = .remoteSSH
            terminalExperimentalRuntimesEnabled = false
            sshProfiles = []
            sshDefaultProfileId = nil
            sshKeys = []
        }
        // Load the API key from Keychain (empty string if not found).
        apiKey = self.apiKeyStore.loadApiKey() ?? ""
    }

    private func save() {
        let data = SettingsData(
            baseUrl: baseUrl,
            apiKey: "",  // never persist the key to UserDefaults
            modelId: modelId,
            terminalDefaultRuntime: terminalDefaultRuntime,
            terminalExperimentalRuntimesEnabled: terminalExperimentalRuntimesEnabled,
            sshProfiles: sshProfiles,
            sshDefaultProfileId: sshDefaultProfileId,
            sshKeys: sshKeys
        )
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    private func saveApiKey() {
        apiKeyStore.saveApiKey(apiKey)
    }

    var defaultSSHProfile: IOSSSHProfile? {
        guard let sshDefaultProfileId else { return nil }
        return sshProfiles.first { $0.id == sshDefaultProfileId }
    }

    // MARK: - Local SSH Keys

    func sshKey(id: String) -> IOSSSHKeyMetadata? {
        sshKeys.first { $0.id == id }
    }

    #if canImport(NIOSSH)
    func generateSSHKey(
        name: String,
        type: IOSSSHKeyType = .ed25519,
        requireUserPresence: Bool = false
    ) throws -> IOSSSHKeyMetadata {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IOSSSHError.invalidProfile("密钥名称不能为空。")
        }
        if sshKeys.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw IOSSSHError.invalidProfile("已存在名为「\(trimmed)」的本机 SSH 密钥。")
        }
        let metadata = try keyStore.generateKey(
            name: trimmed,
            type: type,
            requireUserPresence: requireUserPresence
        )
        sshKeys.append(metadata)
        return metadata
    }

    func importSSHKey(
        name: String,
        privateKey: String,
        passphrase: String? = nil,
        requireUserPresence: Bool = false
    ) throws -> IOSSSHKeyMetadata {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IOSSSHError.invalidProfile("密钥名称不能为空。")
        }
        if sshKeys.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw IOSSSHError.invalidProfile("已存在名为「\(trimmed)」的本机 SSH 密钥。")
        }
        let metadata = try keyStore.importKey(
            name: trimmed,
            privateKey: privateKey,
            passphrase: passphrase,
            requireUserPresence: requireUserPresence
        )
        sshKeys.append(metadata)
        return metadata
    }
    #endif

    func deleteSSHKey(id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sshKeys.contains(where: { $0.id == trimmed }) else {
            throw IOSSSHRouteError.keyNotFound(keyId: trimmed)
        }
        try IOSSSHRouteResolver.validateDeleteKey(keyId: trimmed, existingProfiles: sshProfiles)
        try keyStore.deleteKeyMaterial(keyId: trimmed)
        sshKeys.removeAll { $0.id == trimmed }
    }

    /// Migrates a profile's legacy inline `privateKey` credential from `IOSSSHSecretStore`
    /// into `IOSSSHKeyStore` + `sshKeys` and binds `profile.keyId`.
    /// Never deletes the legacy Keychain item unless the new key and profile update
    /// were both persisted cleanly.
    #if canImport(NIOSSH)
    @discardableResult
    func migrateLegacySSHPrivateKeyIfNeeded(profileId: String) -> IOSSSHKeyMetadata? {
        guard let index = sshProfiles.firstIndex(where: { $0.id == profileId }) else { return nil }
        let profile = sshProfiles[index]
        guard profile.authMethod == .privateKey, profile.keyId == nil else { return nil }
        guard let legacyCredential = try? IOSSSHSecretStore.loadCredential(profile: profile),
              case .privateKey(let rawKey) = legacyCredential else {
            return nil
        }
        let baseName = "\(profile.displayName)-migrated"
        let uniqueName = uniqueSSHKeyName(base: baseName)
        guard let metadata = try? keyStore.importKey(name: uniqueName, privateKey: rawKey) else {
            return nil
        }
        sshKeys.append(metadata)
        var updatedProfile = profile
        updatedProfile.keyId = metadata.id
        sshProfiles[index] = updatedProfile
        // Verify the non-secret references are readable before retiring the old item.
        if let persisted = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: persisted),
           decoded.sshKeys?.contains(where: { $0.id == metadata.id }) == true,
           decoded.sshProfiles?.first(where: { $0.id == profile.id })?.keyId == metadata.id {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
        }
        return metadata
    }
    #endif

    func uniqueSSHKeyName(base: String) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ssh-key" : base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sshKeys.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return cleaned
        }
        var suffix = 2
        while sshKeys.contains(where: { $0.name.caseInsensitiveCompare("\(cleaned)-\(suffix)") == .orderedSame }) {
            suffix += 1
        }
        return "\(cleaned)-\(suffix)"
    }

    // MARK: - SSH Profiles & Routes

    func resolveSSHRoute(for targetProfileId: String) throws -> [IOSSSHProfile] {
        try IOSSSHRouteResolver.resolveRoute(targetProfileId: targetProfileId, profiles: sshProfiles)
    }

    func resolveSSHRoute(for target: IOSSSHProfile) throws -> [IOSSSHProfile] {
        try IOSSSHRouteResolver.resolveRoute(target: target, profiles: sshProfiles)
    }

    func isSSHRouteReady(for target: IOSSSHProfile) -> Bool {
        guard let route = try? resolveSSHRoute(for: target), !route.isEmpty else {
            return false
        }
        return route.allSatisfy { hop in
            hop.knownHostSHA256?.isEmpty == false && hasCredentialForSSHProfile(hop)
        }
    }

    func upsertSSHProfile(_ profile: IOSSSHProfile, password: String?) throws {
        try upsertSSHProfile(profile, credential: password.map(IOSSSHCredential.password))
    }

    func upsertSSHProfile(_ profile: IOSSSHProfile, credential: IOSSSHCredential?) throws {
        var validated = try profile.validated()
        if validated.authMethod == .privateKey, let keyId = validated.keyId {
            guard sshKeys.contains(where: { $0.id == keyId }) else {
                throw IOSSSHRouteError.keyNotFound(keyId: keyId)
            }
        }
        _ = try IOSSSHRouteResolver.validateUpsert(candidate: validated, existingProfiles: sshProfiles)

        let previous = sshProfiles.first { $0.id == validated.id }
        if let previous,
           previous.host != validated.host || previous.port != validated.port || previous.jumpProfileId != validated.jumpProfileId,
           validated.knownHostHost != validated.host || validated.knownHostPort != validated.port || validated.knownHostViaJump != validated.jumpProfileId {
            // Keep an explicitly verified new endpoint, but do not carry an
            // old unbound/legacy pin into a different saved connection or jump route.
            validated.knownHostSHA256 = nil
            validated.knownHostHost = nil
            validated.knownHostPort = nil
            validated.knownHostViaJump = nil
        }
        if let credential {
            try IOSSSHSecretStore.saveCredential(credential, profile: validated)
        } else if validated.authMethod == .privateKey, validated.keyId != nil {
            try? IOSSSHSecretStore.deleteCredential(profileId: validated.id)
        } else if let previous,
                  previous.host != validated.host || previous.port != validated.port ||
                  previous.username != validated.username || previous.authMethod != validated.authMethod {
            try IOSSSHSecretStore.deleteCredential(profileId: validated.id)
        }
        if let index = sshProfiles.firstIndex(where: { $0.id == validated.id }) {
            sshProfiles[index] = validated
        } else {
            sshProfiles.append(validated)
        }
        if sshDefaultProfileId == nil { sshDefaultProfileId = validated.id }
    }

    func deleteSSHProfile(id: String) throws {
        try IOSSSHRouteResolver.validateDeleteProfile(id: id, existingProfiles: sshProfiles)
        try IOSSSHSecretStore.deleteCredential(profileId: id)
        sshProfiles.removeAll { $0.id == id }
        if sshDefaultProfileId == id { sshDefaultProfileId = sshProfiles.first?.id }
    }

    func trustHost(profileId: String, fingerprint: String) throws {
        guard let index = sshProfiles.firstIndex(where: { $0.id == profileId }) else {
            throw IOSSSHError.invalidProfile("SSH profile was not found.")
        }
        var profile = sshProfiles[index]
        profile.knownHostSHA256 = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.knownHostHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.knownHostPort = profile.port
        profile.knownHostViaJump = profile.jumpProfileId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        sshProfiles[index] = try profile.validated()
    }

    func credentialForSSHProfile(_ profile: IOSSSHProfile) throws -> IOSSSHCredential? {
        let requested = try profile.validated()
        #if canImport(NIOSSH)
        if requested.authMethod == .privateKey, let keyId = requested.keyId {
            guard let metadata = sshKey(id: keyId) else { throw IOSSSHError.credentialUnavailable }
            let signingKey = try keyStore.loadSigningKey(metadata: metadata)
            if let text = signingKey.extractablePrivateKey { return .privateKey(text) }
            if let token = signingKey.secureEnclaveToken { return .secureEnclaveKey(token) }
            throw IOSSSHError.credentialUnavailable
        }
        #endif
        guard let stored = sshProfiles.first(where: { $0.id == requested.id }) else { return nil }
        let saved = try stored.validated()
        guard saved.host == requested.host, saved.port == requested.port,
              saved.username == requested.username, saved.authMethod == requested.authMethod,
              saved.keyId == requested.keyId else { throw IOSSSHError.credentialUnavailable }
        #if canImport(NIOSSH)
        if saved.authMethod == .privateKey, saved.keyId == nil,
           migrateLegacySSHPrivateKeyIfNeeded(profileId: saved.id) != nil,
           let migrated = sshProfiles.first(where: { $0.id == saved.id }) {
            return try credentialForSSHProfile(migrated)
        }
        #endif
        // Legacy password reads migrate their Keychain item. Only a persisted
        // endpoint may perform that migration, never an unsaved UI candidate.
        return try IOSSSHSecretStore.loadCredential(profile: requested)
    }

    /// Read-only Keychain metadata query used by settings summaries. It never
    /// loads or exposes the password/private-key payload.
    func hasCredentialForSSHProfile(_ profile: IOSSSHProfile) -> Bool {
        if profile.authMethod == .privateKey,
           let keyId = profile.keyId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keyId.isEmpty {
            return sshKeys.contains(where: { $0.id == keyId }) && keyStore.hasKeyMaterial(keyId: keyId)
        }
        return (try? IOSSSHSecretStore.hasCredential(profile: profile)) ?? false
    }

    func clearSSHCredential(profileId: String) throws {
        try IOSSSHSecretStore.deleteCredential(profileId: profileId)
        if let index = sshProfiles.firstIndex(where: { $0.id == profileId }), sshProfiles[index].keyId != nil {
            sshProfiles[index].keyId = nil
        }
    }

    func clearSSHPassword(profileId: String) {
        try? clearSSHCredential(profileId: profileId)
    }

    /// Public read-only access to the Keychain-stored API key.
    var currentApiKey: String { apiKeyStore.loadApiKey() ?? "" }
}
