import Foundation
import Security
import XCTest
@testable import iosApp

@MainActor
final class IOSSSHCredentialTests: XCTestCase {
    func testPrivateKeySettingsReloadKeepsSecretOutOfUserDefaultsAndUsesDeviceOnlyKeychain() throws {
        let keyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey)
        let suiteName = "IOSSSHCredentialTests.settings.\(UUID().uuidString)"
        let storageKey = "ssh-settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(userDefaults: defaults, storageKey: storageKey)
        try settings.upsertSSHProfile(profile, credential: .privateKey(keyPair.privateKey))

        let persisted = try XCTUnwrap(defaults.data(forKey: storageKey))
        let persistedJSON = try JSONSerialization.jsonObject(with: persisted)
        XCTAssertFalse(
            textValues(in: persistedJSON).contains(keyPair.privateKey),
            "private key must never be serialized into the settings blob, including JSON-escaped text"
        )

        let reloaded = SettingsStore(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(
            try reloaded.credentialForSSHProfile(profile),
            .privateKey(keyPair.privateKey)
        )

        let attributes = try keychainAttributes(account: credentialAccount(profile.id))
        XCTAssertEqual(
            stringAttribute(attributes[kSecAttrAccessible as String]),
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(boolAttribute(attributes[kSecAttrSynchronizable as String]), false)
    }

    func testEmptySameEndpointSavePreservesCredentialButEndpointAndAuthChangesClearIt() throws {
        let keyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey)
        let suiteName = "IOSSSHCredentialTests.retention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(userDefaults: defaults, storageKey: "ssh-retention")
        try settings.upsertSSHProfile(profile, credential: .privateKey(keyPair.privateKey))

        // A blank credential on the same endpoint is an edit that must retain
        // the existing Keychain item.
        try settings.upsertSSHProfile(profile, credential: nil)
        XCTAssertEqual(
            try settings.credentialForSSHProfile(profile),
            .privateKey(keyPair.privateKey)
        )

        // One representative endpoint change must invalidate the bound secret.
        var changedEndpoint = profile
        changedEndpoint.host = "other.example.test"
        changedEndpoint.knownHostHost = changedEndpoint.host
        try settings.upsertSSHProfile(changedEndpoint, credential: nil)
        XCTAssertNil(try settings.credentialForSSHProfile(changedEndpoint))

        // Restore a credential, then exercise the independent auth-method
        // invalidation branch without enumerating every endpoint field.
        try settings.upsertSSHProfile(profile, credential: .privateKey(keyPair.privateKey))
        var changedAuth = profile
        changedAuth.authMethod = .password
        try settings.upsertSSHProfile(changedAuth, credential: nil)
        XCTAssertNil(try settings.credentialForSSHProfile(changedAuth))
    }

    func testInvalidPrivateKeyReplacementLeavesExistingCredentialIntact() throws {
        let keyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey)
        let suiteName = "IOSSSHCredentialTests.replacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(userDefaults: defaults, storageKey: "ssh-replacement")
        try settings.upsertSSHProfile(profile, credential: .privateKey(keyPair.privateKey))

        XCTAssertThrowsError(
            try settings.upsertSSHProfile(
                profile,
                credential: .privateKey("not-an-openSSH-private-key")
            )
        )
        XCTAssertEqual(
            try settings.credentialForSSHProfile(profile),
            .privateKey(keyPair.privateKey)
        )
    }

    func testVerifiedNewEndpointKeepsNewPinAndFailedReplacementKeepsPersistedState() throws {
        let oldKeyPair = try IOSSSHPrivateKey.generate()
        let newKeyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey, host: "old.example.test")
        let suiteName = "IOSSSHCredentialTests.endpoint-pin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(userDefaults: defaults, storageKey: "ssh-endpoint-pin")
        try settings.upsertSSHProfile(profile, credential: .privateKey(oldKeyPair.privateKey))

        var verifiedNewEndpoint = profile
        verifiedNewEndpoint.host = "new.example.test"
        verifiedNewEndpoint.knownHostSHA256 = "SHA256:new-endpoint"
        verifiedNewEndpoint.knownHostHost = verifiedNewEndpoint.host
        verifiedNewEndpoint.knownHostPort = verifiedNewEndpoint.port
        try settings.upsertSSHProfile(verifiedNewEndpoint, credential: .privateKey(newKeyPair.privateKey))

        XCTAssertEqual(
            settings.sshProfiles.first(where: { $0.id == profile.id })?.knownHostSHA256,
            "SHA256:new-endpoint"
        )
        XCTAssertEqual(
            try settings.credentialForSSHProfile(verifiedNewEndpoint),
            .privateKey(newKeyPair.privateKey)
        )

        var failedReplacement = verifiedNewEndpoint
        failedReplacement.host = "failed.example.test"
        XCTAssertThrowsError(
            try settings.upsertSSHProfile(
                failedReplacement,
                credential: .privateKey("not-an-openSSH-private-key")
            )
        )
        XCTAssertEqual(
            settings.sshProfiles.first(where: { $0.id == profile.id }),
            verifiedNewEndpoint
        )
        XCTAssertEqual(
            try settings.credentialForSSHProfile(verifiedNewEndpoint),
            .privateKey(newKeyPair.privateKey)
        )
        var unboundLegacyPin = verifiedNewEndpoint
        unboundLegacyPin.host = "legacy-alias.example.test"
        unboundLegacyPin.knownHostHost = nil
        unboundLegacyPin.knownHostPort = nil
        try settings.upsertSSHProfile(unboundLegacyPin, credential: .privateKey(newKeyPair.privateKey))
        XCTAssertNil(settings.sshProfiles.first?.knownHostSHA256)
    }

    func testCredentialEnvelopeRejectsProfileEndpointMetadataMismatch() throws {
        let keyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey)
        defer { try? IOSSSHSecretStore.deleteCredential(profileId: profile.id) }

        try IOSSSHSecretStore.saveCredential(.privateKey(keyPair.privateKey), profile: profile)

        var changed = profile
        changed.host = "tampered.example.test"
        changed.knownHostHost = changed.host

        XCTAssertThrowsError(try IOSSSHSecretStore.loadCredential(profile: changed)) { error in
            XCTAssertEqual(error as? IOSSSHError, .credentialUnavailable)
        }
    }

    func testLegacyPasswordMigratesToEnvelopeAndDeletesOldKeychainItem() throws {
        let profile = makeProfile(authMethod: .password)
        let password = "legacy-\(UUID().uuidString)"
        let legacyAccount = IOSSSHSecretStore.passwordAccount(profileId: profile.id)
        defer { try? IOSSSHSecretStore.deleteCredential(profileId: profile.id) }

        let fixture: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshService,
            kSecAttrAccount as String: legacyAccount,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        XCTAssertEqual(SecItemAdd(fixture as CFDictionary, nil), errSecSuccess)
        let suiteName = "IOSSSHCredentialTests.legacy-candidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(userDefaults: defaults, storageKey: "ssh-legacy-candidate")
        try settings.upsertSSHProfile(profile, credential: nil)
        var candidate = profile
        candidate.host = "uncommitted.example.test"
        candidate.knownHostHost = candidate.host
        XCTAssertThrowsError(try settings.credentialForSSHProfile(candidate))
        XCTAssertNotNil(try keychainData(account: legacyAccount))
        XCTAssertNil(try keychainData(account: credentialAccount(profile.id)))
        XCTAssertEqual(settings.sshProfiles.first, profile)

        XCTAssertEqual(
            try settings.credentialForSSHProfile(profile),
            .password(password)
        )
        XCTAssertNil(try keychainData(account: legacyAccount))
        XCTAssertEqual(
            try IOSSSHSecretStore.loadCredential(profile: profile),
            .password(password)
        )

        let envelopeAttributes = try keychainAttributes(account: credentialAccount(profile.id))
        XCTAssertEqual(
            stringAttribute(envelopeAttributes[kSecAttrAccessible as String]),
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(boolAttribute(envelopeAttributes[kSecAttrSynchronizable as String]), false)
    }

    func testPrivateKeyReachesOneShotAndBackgroundJobExecutorsThroughSettings() async throws {
        let keyPair = try IOSSSHPrivateKey.generate()
        let profile = makeProfile(authMethod: .privateKey)
        let suiteName = "IOSSSHCredentialTests.executors.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? IOSSSHSecretStore.deleteCredential(profileId: profile.id)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(userDefaults: defaults, storageKey: "ssh-executors")
        try settings.upsertSSHProfile(profile, credential: .privateKey(keyPair.privateKey))
        settings.sshDefaultProfileId = profile.id

        let backend = RecordingSSHBackend()
        let runtime = IOSTerminalRuntime(sshBackend: backend)

        let oneShot = try jsonObject(await IOSRemoteTerminalExecuteExecutor.execute(
            input: #"{"command":"echo one-shot"}"#,
            settingsStore: settings,
            runtime: runtime
        ))
        XCTAssertEqual(oneShot["ok"] as? Bool, true)
        XCTAssertEqual(oneShot["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(backend.observedAuthMethod, .privateKey)
        XCTAssertEqual(backend.observedPublicKey, keyPair.publicKey)

        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "ssh-executor-jobs")
        let started = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            input: #"{"command":"echo background"}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        let jobID = try XCTUnwrap(started["job_id"] as? String)
        XCTAssertEqual(started["status"] as? String, IOSTerminalJobStatus.running.rawValue)

        let finished = try jsonObject(await IOSAgentTerminalJobExecutor.execute(
            toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
            input: #"{"job_id":"\#(jobID)","wait_timeout_seconds":2}"#,
            settingsStore: settings,
            runtime: runtime,
            taskStore: taskStore
        ))
        XCTAssertEqual(finished["status"] as? String, IOSTerminalJobStatus.completed.rawValue)
        XCTAssertEqual(finished["command_ok"] as? Bool, true)
        XCTAssertEqual(backend.executeCallCount, 2)
        XCTAssertEqual(backend.observedAuthMethod, .privateKey)
        XCTAssertEqual(backend.observedPublicKey, keyPair.publicKey)
    }

    private func textValues(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap { textValues(in: $0) } }
        if let object = value as? [String: Any] { return object.values.flatMap { textValues(in: $0) } }
        return []
    }

    private let sshService = "app.amber.agent.ssh"

    private func makeProfile(
        authMethod: IOSSSHAuthMethod,
        id: String = UUID().uuidString,
        host: String = "ssh.example.test",
        port: Int = 22,
        username: String = "amber"
    ) -> IOSSSHProfile {
        IOSSSHProfile(
            id: id,
            name: "Credential test",
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            knownHostSHA256: "SHA256:test",
            knownHostHost: host,
            knownHostPort: port
        )
    }

    private func credentialAccount(_ profileID: String) -> String {
        "ssh-credential:\(profileID)"
    }

    private func keychainAttributes(account: String) throws -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(result as? [String: Any])
    }

    private func keychainData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        XCTAssertEqual(status, errSecSuccess)
        return result as? Data
    }

    private func stringAttribute(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }

    private func boolAttribute(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        return value as? Bool
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private final class RecordingSSHBackend: IOSSSHRuntimeBackendProtocol, @unchecked Sendable {
    private(set) var executeCallCount = 0
    private(set) var observedAuthMethod: IOSSSHAuthMethod?
    private(set) var observedPublicKey: String?

    func testConnection(profile: IOSSSHProfile) async throws -> IOSSSHConnectionProbeResult {
        IOSSSHConnectionProbeResult(fingerprint: "SHA256:test", trustState: .trusted)
    }

    func execute(
        command: String,
        profile: IOSSSHProfile,
        credential: IOSSSHCredential,
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult {
        executeCallCount += 1
        observedAuthMethod = credential.authMethod
        if case .privateKey(let privateKey) = credential {
            observedPublicKey = try? IOSSSHPrivateKey.publicKey(from: privateKey)
        }
        output(IOSSSHOutputChunk(text: "ok\n", isStderr: false))
        return IOSSSHCommandResult(output: "ok\n", exitCode: 0)
    }
}
