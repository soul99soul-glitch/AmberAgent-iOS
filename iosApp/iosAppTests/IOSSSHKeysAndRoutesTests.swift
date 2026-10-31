import CryptoKit
import NIOSSH
import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSSSHKeysAndRoutesTests: XCTestCase {
    // OpenBSD regress/lib/libutil/bcrypt_pbkdf/bcrypt_pbkdf_test.c (basic and multi-block vectors).
    func testBcryptPBKDFMatchesOpenBSDVectors() throws {
        let basic = try IOSSSHBcryptPBKDF.deriveKey(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 4, keyLength: 32)
        XCTAssertEqual(hex(basic), "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
        let wide = try IOSSSHBcryptPBKDF.deriveKey(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 8, keyLength: 64)
        XCTAssertEqual(hex(wide), "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246e74bba51723fefa9f9474d6508845e8d")
    }

    func testEncryptedOpenSSHImportDiscardsPassphraseAndRoundTripsPublicKey() throws {
        let backend = IOSSSHInMemoryKeyBackend()
        let store = IOSSSHKeyStore(backend: backend)
        let metadata = try store.importKey(name: "fixture", privateKey: encryptedFixture, passphrase: "amber-fixture-pass")
        XCTAssertEqual(metadata.fingerprintSHA256, "SHA256:VnBF304pCwisjxfe5LApbbxqbye5yH9wjtOHWh6zduw")
        let stored = try XCTUnwrap(backend.load(account: IOSSSHKeyStore.account(keyId: metadata.id)))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("amber-fixture-pass"))
        let signing = try store.loadSigningKey(metadata: metadata)
        let privateKey = try XCTUnwrap(signing.extractablePrivateKey)
        let parsed = try IOSSSHPrivateKey.parseDetailed(privateKey)
        XCTAssertFalse(parsed.wasEncrypted)
        XCTAssertFalse(metadata.hasPassphrase)
        XCTAssertEqual(String(openSSHPublicKey: signing.nioKey.publicKey), parsed.publicKeyOpenSSH)
        XCTAssertTrue(signing.description.contains("[redacted]"))
        XCTAssertThrowsError(try store.importKey(name: "wrong", privateKey: encryptedFixture, passphrase: "incorrect")) {
            XCTAssertEqual($0 as? IOSSSHPrivateKeyError, .incorrectPassphrase)
        }
    }

    func testGeneratedKeyOnlyReturnsPublicMaterialAndUsesInjectedStorage() throws {
        let backend = IOSSSHInMemoryKeyBackend()
        let store = IOSSSHKeyStore(backend: backend)
        let key = try store.generateKey(name: "test")
        XCTAssertEqual(key.algorithm, "ssh-ed25519")
        XCTAssertTrue(key.publicKeyOpenSSH.hasSuffix(" amber-test"))
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: key.publicKeyOpenSSH)
        XCTAssertEqual(try IOSSSHPrivateKey.fingerprintSHA256(publicKey: publicKey), key.fingerprintSHA256)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(key), as: UTF8.self).contains("PRIVATE KEY"))
        XCTAssertEqual(try store.loadSigningKey(metadata: key).nioKey.publicKey, publicKey)
    }

    func testRouteLimitCyclesAndReverseDependentWritesAreRejected() throws {
        let direct = profile("a")
        let one = profile("b", jump: "a")
        let two = profile("c", jump: "b")
        let three = profile("d", jump: "c")
        let profiles = [direct, one, two, three]
        for (index, target) in profiles.enumerated() {
            XCTAssertEqual(try IOSSSHRouteResolver.resolveRoute(targetProfileId: target.id, profiles: profiles).map(\.id), Array(profiles.prefix(index + 1)).map(\.id))
        }
        XCTAssertThrowsError(try IOSSSHRouteResolver.resolveRoute(target: profile("e", jump: "d"), profiles: profiles)) {
            XCTAssertEqual(($0 as? IOSSSHRouteError)?.status, "jump_chain_too_long")
        }
        var cyclic = direct; cyclic.jumpProfileId = "c"
        XCTAssertThrowsError(try IOSSSHRouteResolver.validateUpsert(candidate: cyclic, existingProfiles: profiles)) {
            XCTAssertEqual(($0 as? IOSSSHRouteError)?.status, "jump_cycle")
        }
        let deeper = profile("z")
        var changed = direct; changed.jumpProfileId = "z"
        XCTAssertThrowsError(try IOSSSHRouteResolver.validateUpsert(candidate: changed, existingProfiles: profiles + [deeper])) {
            XCTAssertEqual(($0 as? IOSSSHRouteError)?.status, "jump_chain_too_long")
        }
        XCTAssertNil(direct.jumpProfileId)
    }

    func testReferencedKeyAndJumpCannotBeDeletedAndPinBindsToRoute() throws {
        let jump = profile("jump")
        var target = profile("target", jump: jump.id); target.keyId = "key"
        XCTAssertThrowsError(try IOSSSHRouteResolver.validateDeleteKey(keyId: "key", existingProfiles: [jump, target])) {
            XCTAssertEqual(($0 as? IOSSSHRouteError)?.status, "key_in_use")
        }
        XCTAssertThrowsError(try IOSSSHRouteResolver.validateDeleteProfile(id: jump.id, existingProfiles: [jump, target])) {
            XCTAssertEqual(($0 as? IOSSSHRouteError)?.status, "in_use_as_jump")
        }
        target.knownHostSHA256 = "SHA256:test"; target.knownHostHost = target.host; target.knownHostPort = 22
        XCTAssertNil(try target.validated().knownHostSHA256, "A direct pin is not trusted via a new jump")
        target.knownHostViaJump = jump.id
        XCTAssertEqual(try target.validated().knownHostSHA256, "SHA256:test")
        let digest = remoteSSHTargetDigest(route: [jump, target])
        var changed = jump; changed.username = "different"
        XCTAssertNotEqual(digest, remoteSSHTargetDigest(route: [changed, target]))
    }

    @MainActor
    func testKeyToolsUseSamePersistedSettingsAndEnforceDeleteAndPlaceholderGuards() throws {
        let defaults = UserDefaults(suiteName: "SSHKeys-\(UUID().uuidString)")!
        let keyStore = IOSSSHKeyStore(backend: IOSSSHInMemoryKeyBackend())
        let settings = SettingsStore(userDefaults: defaults, apiKeyStore: NoAPIKey(), keyStore: keyStore)
        let generated = IOSSSHKeyToolExecutor.execute(toolName: "ssh_key_generate", argumentsJSON: #"{"name":"agent"}"#, settingsStore: settings)
        XCTAssertTrue(generated.contains("authorized_keys")); XCTAssertFalse(generated.contains("PRIVATE KEY"))
        let key = try XCTUnwrap(settings.sshKeys.first)
        var target = profile("target"); target.keyId = key.id; target.authMethod = .privateKey
        settings.sshProfiles = [target]
        let output = IOSSSHKeyToolExecutor.execute(toolName: "ssh_key_delete", argumentsJSON: "{\"key_id\":\"\(key.id)\"}", settingsStore: settings)
        XCTAssertTrue(output.contains("key_in_use")); XCTAssertTrue(keyStore.hasKeyMaterial(keyId: key.id))
        let reloaded = SettingsStore(userDefaults: defaults, apiKeyStore: NoAPIKey(), keyStore: keyStore)
        XCTAssertEqual(reloaded.sshKeys, settings.sshKeys)
        XCTAssertNotNil(try reloaded.credentialForSSHProfile(target))
        for marker in ["[redacted]", "<redacted>", "***", "••••", "(empty)"] {
            let args = IOSWorkspaceStore.json(["name": "invalid", "private_key": marker])
            let result = IOSSSHKeyToolExecutor.execute(toolName: "ssh_key_import", argumentsJSON: args, settingsStore: settings)
            XCTAssertTrue(result.contains("invalid_arguments"))
        }
        XCTAssertEqual(settings.sshKeys.count, 1)
    }

    func testImportRedactionAndAllHopOutputSecrets() {
        let input = #"{"name":"a","private_key":"fixture-private","passphrase":"fixture-pass"}"#
        XCTAssertEqual(IOSSecretArgumentRedaction.redactedArgumentsJSON(#"{"private_key":"unfinished"#), "{}")
        let redacted = IOSSecretArgumentRedaction.redactedArgumentsJSON(input)
        XCTAssertFalse(redacted.contains("fixture-private")); XCTAssertFalse(redacted.contains("fixture-pass"))
        let output = IOSSSHOutputRedactor.redact("a jump-secret b target-secret c", credentials: [.password("jump-secret"), .password("target-secret")])
        XCTAssertEqual(output, "a [redacted] b [redacted] c")
        let streaming = IOSSSHOutputRedactor(credentials: [.password("short"), .password("short-long")])
        let first = streaming.redact(.init(text: "pre short", isStderr: false))?.text ?? ""
        let second = streaming.redact(.init(text: "-long post", isStderr: false))?.text ?? ""
        XCTAssertEqual(first + second + streaming.finish().map(\.text).joined(), "pre [redacted] post")
        XCTAssertEqual(IOSSSHKeyToolCatalog.highRiskToolNames, ["ssh_key_generate", "ssh_key_import", "ssh_key_delete"])
        XCTAssertEqual(IOSSSHKeyToolCatalog.backgroundAllowedToolNames, ["ssh_key_list"])
    }

    private func profile(_ id: String, jump: String? = nil) -> IOSSSHProfile {
        IOSSSHProfile(id: id, host: "\(id).test", username: "test", jumpProfileId: jump)
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private struct NoAPIKey: SettingsAPIKeyStore {
        func loadApiKey() -> String? { nil }
        func saveApiKey(_ key: String) -> Bool { true }
    }

    // Synthetic ssh-keygen -t ed25519 -a 4 fixture, never used outside these tests.
    private var encryptedFixture: String {
        """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAhdJmYVE
        e21acMn1BSBD5nAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPmjbItZqQGzooi9
        vtJDwsmI3SlLZciJBOUfo/L2Q9F4AAAAoLK5Ig/sMIIA+xWySxp8Oc9+hDjlDNILhIRtfT
        QD/hjuYeC7Imd3HT3Zkgx8JJnV3tp7sBkunFnVcgbvNWlUTh8qeXntkDFOB9c8lHov5hUc
        EmEBfYgcWRJTrNPi/U4wgfRhov3NpHJvi+Fq1BdlCs+u0/QfHzELoRXsG47aqXufpywLMe
        E4wiQl7WrkaC1AmACghk03T10md6ePDpoWdjU=
        -----END OPENSSH PRIVATE KEY-----
        """
    }
}
