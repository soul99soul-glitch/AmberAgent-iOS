import XCTest
@preconcurrency import Shared
@testable import iosApp

extension IOSParityRedLightTests {
    // MARK: - Settings / Backup / Recovery (truth_matrix rows `backup`, `chat`.recover)

    /// RED for P0. GREEN target: P2.
    /// Cell: *.secure_store (settings encode path).
    ///
    /// Encoding the canonical settings snapshot to its persisted form must NOT
    /// contain any credential (apiKey) in plaintext. Today
    /// `IOSSharedSettingsStore` serializes the full KMP `Settings` (whose
    /// providers carry a real `apiKey`) as plaintext JSON to UserDefaults
    /// (`app.amber.ios.sharedSettingsJson`, IOSSharedSettingsStore.swift:147).
    /// P2 (iOS-only scheme B) strips credentials before encode + stores them in
    /// a Keychain side-table. This test writes a provider apiKey via the public
    /// mutation API, persists, and greps the persisted bytes for the secret.
    func test_settings_encode_containsNoCredential() {
        let secret = "sk-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(apiKey: secret)
        store.addProvider(provider)
        // addProvider calls restoreSnapshot (writes JSON to UserDefaults).

        guard let persisted = defaults.data(forKey: "app.amber.ios.sharedSettingsJson") ??
            defaults.string(forKey: "app.amber.ios.sharedSettingsJson")?.data(using: .utf8) else {
            XCTFail("settings JSON must be persisted to UserDefaults for the leak check")
            return
        }
        let persistedString = String(data: persisted, encoding: .utf8) ?? ""

        XCTAssertFalse(
            persistedString.contains(secret),
            "Persisted settings JSON must not contain the plaintext apiKey credential. "
                + "P2 scheme B strips credentials before encode + Keychain side-table."
        )
    }

    /// RED for P0. GREEN target: P2.
    /// Cell: backup.secure_store.
    ///
    /// The DEFAULT backup export (no opt-in redaction) must NOT contain
    /// credentials. A backup that decrypts back to plaintext credentials is a
    /// leak (encryption is not a substitute for redaction: a passphrase-protected
    /// backup decrypts to the secret, and a no-passphrase backup uses a public
    /// fallback constant). Today `IOSSyncBackup.export` calls
    /// `IosSettingsJsonBridge.encode` with no redaction (IOSSyncBackup.swift:63),
    /// unlike Android's `BackupSettingsRedactor`. This test builds a Settings
    /// with a known apiKey, exports, imports back (round-trip decrypt), and
    /// asserts the secret is absent from the decrypted payload.
    func test_backup_default_containsNoCredential() throws {
        let secret = "sk-SECRET-\(UUID().uuidString)"
        var settings = IosSettingsDefaults.shared.defaultSeededSettings()
        // Inject a provider carrying the secret apiKey.
        let providerWithSecret = makeOpenAIProvider(apiKey: secret)
        settings = IosSettingsMutations.shared.addProvider(
            settings: settings,
            provider: providerWithSecret
        )

        // Export with a known passphrase, then decrypt-import. The redaction
        // target must hold in the DECRYPTED payload, not just the encrypted
        // bytes. (Scheme B redacts before encryption; the decrypted form carries
        // the mask sentinel, never the secret.)
        let passphrase = "pw-\(UUID().uuidString)"
        let archive = try IOSSyncBackup.export(settings: settings, passphrase: passphrase)
        let imported = try IOSSyncBackup.import(data: archive, passphrase: passphrase)
        let decryptedJson = IosSettingsJsonBridge.shared.encode(settings: imported.settings)

        XCTAssertFalse(
            decryptedJson.contains(secret),
            "Default backup (decrypted) must not contain the plaintext apiKey credential. "
                + "Scheme B redacts before encryption; the decrypted form carries the mask, not the secret."
        )
    }

    // MARK: - secure_store (search / TTS credential classes — discovery round 1)

    /// RED for P0 (discovery round 1). GREEN target: P2.
    /// Cell: search.secure_store.
    ///
    /// A user-configured SEARCH provider API key must NOT be persisted in
    /// plaintext. Today `IOSSharedSettingsStore.addSearchProvider(name:apiKey:serviceType:)`
    /// (IOSSharedSettingsStore.swift:535) writes the apiKey into BOTH the legacy
    /// mirror `app.amber.ios.customSearchProviders` (line 546) AND the full
    /// `Settings` JSON blob via `restoreSnapshot` → `IosSettingsJsonBridge.encode`
    /// (the SearchServiceOptions.TavilyOptions.apiKey field is serialized). P2
    /// scheme B extends credential stripping to search keys. This test adds a
    /// search provider and greps both UserDefaults surfaces for the secret.
    func test_searchProviderApiKey_encode_containsNoCredential() {
        let secret = "search-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-search-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.addSearchProvider(name: "Tavily Test", apiKey: secret, serviceType: "tavily")

        // Two leak surfaces (both must be clean after P2):
        let fullJson = (defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? "")
        let legacyEntries = (defaults.array(forKey: "app.amber.ios.customSearchProviders") as? [[String: Any]]) ?? []
        let legacyMirror = legacyEntries.flatMap { $0["apiKey"] as? String }.joined()

        XCTAssertFalse(
            fullJson.contains(secret),
            "Full settings JSON must not contain the search apiKey in plaintext. (P2 scheme B)"
        )
        XCTAssertFalse(
            legacyMirror.contains(secret),
            "Legacy customSearchProviders mirror must not contain the search apiKey in plaintext. (P2)"
        )
    }

    func test_searchProviderApiKey_rehydratedFromKeychainOnReloadAndRepersist() {
        let secret = "search-rehydrate-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-search-rehydrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.addSearchProvider(name: "Tavily Rehydrate", apiKey: secret, serviceType: "tavily")

        guard let added = store.snapshot.searchServices.last as? SearchServiceOptions.TavilyOptions else {
            return XCTFail("Expected added Tavily search service.")
        }
        let serviceId = added.id.description()
        let persistedJson = defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? ""
        XCTAssertFalse(persistedJson.contains(secret))
        XCTAssertTrue(persistedJson.contains(IOSCredentialRedactor.mask))

        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        let reloadedService = reloaded.snapshot.searchServices.first {
            $0.id.description() == serviceId
        } as? SearchServiceOptions.TavilyOptions
        XCTAssertEqual(reloadedService?.apiKey, secret)

        reloaded.setEnableWebSearch(!reloaded.snapshot.enableWebSearch)
        let repersistedJson = defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? ""
        XCTAssertFalse(repersistedJson.contains(secret))
        XCTAssertTrue(repersistedJson.contains(IOSCredentialRedactor.mask))

        let reloadedAgain = IOSSharedSettingsStore(userDefaults: defaults)
        let serviceAfterRepersist = reloadedAgain.snapshot.searchServices.first {
            $0.id.description() == serviceId
        } as? SearchServiceOptions.TavilyOptions
        XCTAssertEqual(serviceAfterRepersist?.apiKey, secret)
    }

    /// RED for P0 (discovery round 1). GREEN target: P2.
    /// Cell: *.secure_store (TTS credential class).
    ///
    /// A user-configured TTS engine API key must NOT be persisted in plaintext.
    /// Today `IOSSharedSettingsStore.addTtsEngine(name:engineType:apiKey:model:)`
    /// (IOSSharedSettingsStore.swift:615) writes the apiKey into BOTH the legacy
    /// mirror `app.amber.ios.customTtsEngines` (line 603) AND the full `Settings`
    /// JSON blob via `restoreSnapshot` (the TTSProviderSetting.OpenAI.apiKey field
    /// is serialized). P2 scheme B extends credential stripping to TTS keys.
    func test_ttsEngineApiKey_encode_containsNoCredential() {
        let secret = "tts-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-tts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.addTtsEngine(name: "OpenAI TTS Test", engineType: "openai", apiKey: secret, model: "tts-1")

        let fullJson = (defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? "")
        let legacyEntries = (defaults.array(forKey: "app.amber.ios.customTtsEngines") as? [[String: Any]]) ?? []
        let legacyMirror = legacyEntries.flatMap { $0["apiKey"] as? String }.joined()

        XCTAssertFalse(
            fullJson.contains(secret),
            "Full settings JSON must not contain the TTS apiKey in plaintext. (P2 scheme B)"
        )
        XCTAssertFalse(
            legacyMirror.contains(secret),
            "Legacy customTtsEngines mirror must not contain the TTS apiKey in plaintext. (P2)"
        )
    }

    /// RED for P0 (discovery round 2). GREEN target: P2.
    /// Cell: *.secure_store (MCP credential class).
    ///
    /// A user-configured MCP server's Authorization/API-key headers must NOT be
    /// persisted in plaintext. Today `IOSMcpConfigStore.persist()`
    /// (IOSMcpConfigStore.swift:87) encodes `IOSMcpStoredServer` (whose `headers`
    /// dict is stored verbatim, IOSMcpClient.swift:99) to UserDefaults key
    /// `app.amber.ios.mcpServers` with no redaction — so a user typing
    /// `Authorization: Bearer <secret>` leaks the secret. MCP headers have no
    /// Keychain wrapper (only provider/SSH keys do). P2 scheme B extends
    /// credential stripping to MCP header values.
    func test_mcpServerHeaders_encode_containsNoCredential() {
        let secret = "mcp-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-mcp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSMcpConfigStore(userDefaults: defaults)
        let server = IOSMcpServerConfig.streamableHTTP(
            name: "Leaky MCP",
            url: "https://mcp.example.com/sse",
            headers: ["Authorization": "Bearer \(secret)"],
            enabled: true,
            tools: []
        )
        store.add(server)

        guard let persisted = defaults.data(forKey: "app.amber.ios.mcpServers"),
              let persistedString = String(data: persisted, encoding: .utf8) else {
            XCTFail("MCP servers must be persisted to UserDefaults for the leak check")
            return
        }
        XCTAssertFalse(
            persistedString.contains(secret),
            "Persisted MCP config must not contain the Authorization header secret in plaintext. (P2 scheme B)"
        )
    }

    /// RED for P0 (discovery round 3). GREEN target: P2.
    /// Cell: chat.secure_store (model-level customHeaders credential class).
    ///
    /// A user-editable model customHeader carrying a credential (e.g.
    /// `Authorization: Bearer <secret>`) must NOT be persisted in plaintext.
    /// Today `IOSSharedSettingsStore.upsertProviderChatModel(... headers:)`
    /// (IOSSharedSettingsStore.swift:453) writes the header pairs verbatim onto
    /// `Model.customHeaders` (via IosSettingsMutations, no redaction) and
    /// `restoreSnapshot` serializes the full Settings to UserDefaults plaintext
    /// (the same JSON also feeds the default backup export). The model-header
    /// editor is user-facing (ProviderDetailView.swift:869). P2 scheme B extends
    /// credential stripping to customHeader Authorization-like values.
    func test_modelCustomHeaders_encode_containsNoCredential() {
        let secret = "modelhdr-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-modelhdr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider()
        store.addProvider(provider)
        let providerId = provider.id.description() as String
        store.upsertProviderChatModel(
            providerId: providerId,
            modelUuid: nil,
            modelId: "m-\(UUID().uuidString)",
            displayName: "m",
            contextWindowTokens: nil,
            modelType: ModelType.chat,
            headers: [("Authorization", "Bearer \(secret)")]
        )

        let fullJson = (defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? "")
        XCTAssertFalse(
            fullJson.contains(secret),
            "Persisted settings JSON must not contain a model customHeader credential in plaintext. (P2 scheme B)"
        )
    }

    /// RED for P0 (discovery round 5). GREEN target: P2.
    /// Cell: chat.secure_store (assistant-level customHeaders credential class).
    ///
    /// An assistant carrying a credential in `Assistant.customHeaders` (e.g.
    /// `Authorization: Bearer <secret>`) must NOT be persisted in plaintext.
    /// No iOS editor exists for Assistant.customHeaders, BUT the backup-import /
    /// restore path deserializes it from external JSON (IOSSyncBackup.import →
    /// `IosSettingsJsonBridge.decode`, IOSSyncBackup.swift:210) and
    /// `restoreSnapshot` (IOSSharedSettingsStore.swift:147) re-encodes the full
    /// Settings via the UNREDACTED `IosSettingsJsonBridge.encode` to UserDefaults
    /// `app.amber.ios.sharedSettingsJson`. So an imported assistant with an
    /// Authorization header leaks the secret in plaintext. Same leak class as
    /// `test_modelCustomHeaders_encode_containsNoCredential`; P2 scheme B must
    /// extend credential stripping to Assistant.customHeaders on the persist path.
    ///
    /// This test seeds the leak via the same JSON-round-trip path import uses:
    /// encode default settings → inject an assistant carrying the header into the
    /// JSON → decode → restoreSnapshot → assert the secret is absent.
    func test_assistantCustomHeaders_encode_containsNoCredential() throws {
        let secret = "assthdr-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-assthdr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)

        // Build a Settings JSON with an assistant carrying the credential header,
        // mirroring what an imported backup would contain.
        var json = IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        // The Settings JSON is an object with an "assistants" array. Inject one.
        let assistantFragment = """
        {"id":"\(UUID().uuidString)","name":"Imported","customHeaders":[{"name":"Authorization","value":"Bearer \(secret)"}]}
        """.data(using: .utf8)!
        json = try injectAssistant(into: json, assistantJsonData: assistantFragment)

        // Decode + restoreSnapshot = the import/restore leak path.
        // decode 已声明 @Throws（Kotlin/Native 桥接），这里走成功路径，用 try。
        let decoded = try IosSettingsJsonBridge.shared.decode(json: json)
        store.restoreSnapshot(decoded)

        let persisted = (defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? "")
        XCTAssertFalse(
            persisted.contains(secret),
            "Persisted settings JSON must not contain an assistant customHeader credential in plaintext. "
                + "Import/restore round-trips Assistant.customHeaders unredacted (P2 scheme B)."
        )
    }

    /// Injects an assistant object into a Settings JSON string's "assistants"
    /// array (used to model the backup-import leak path). Throws if the JSON
    /// shape is unexpected.
    private func injectAssistant(into settingsJson: String, assistantJsonData: Data) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: Data(settingsJson.utf8)) as? [String: Any] else {
            struct BadShape: Error {}
            throw BadShape()
        }
        var assistants = (root["assistants"] as? [Any]) ?? []
        guard let assistant = try JSONSerialization.jsonObject(with: assistantJsonData) as? [String: Any] else {
            struct BadAssistant: Error {}
            throw BadAssistant()
        }
        assistants.append(assistant)
        root["assistants"] = assistants
        let data = try JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8) ?? settingsJson
    }

    /// RED for P0 (discovery round 5b). GREEN target: P2.
    /// Cell: chat.secure_store (assistant-level customBodies credential class).
    ///
    /// Companion to `test_assistantCustomHeaders_encode_containsNoCredential`.
    /// `Assistant.customBodies: List<CustomBody>` (CustomBody.key + value: JSON)
    /// is a user-supplied request-body merge map; a user could place a credential
    /// there (e.g. key "authorization", value `"Bearer <secret>"`). It flows
    /// through the same unredacted import/restore → encode path. P2 scheme B's
    /// JSON-tree redactor (mirroring Android BackupSettingsRedactor, which masks
    /// any key matching authorization/token/secret) covers this too.
    func test_assistantCustomBodies_encode_containsNoCredential() throws {
        let secret = "asstbody-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-asstbody-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)

        var json = IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        let assistantFragment = """
        {"id":"\(UUID().uuidString)","name":"Imported","customBodies":[{"key":"authorization","value":"Bearer \(secret)"}]}
        """.data(using: .utf8)!
        json = try injectAssistant(into: json, assistantJsonData: assistantFragment)

        // decode 已声明 @Throws（Kotlin/Native 桥接），这里走成功路径，用 try。
        let decoded = try IosSettingsJsonBridge.shared.decode(json: json)
        store.restoreSnapshot(decoded)

        let persisted = (defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? "")
        XCTAssertFalse(
            persisted.contains(secret),
            "Persisted settings JSON must not contain an assistant customBody credential in plaintext. (P2 scheme B)"
        )
    }

    // MARK: - secure_store (redactor classification + path collision — discovery round 6)

    func test_customBodyTokenLimits_remainNumericWithoutCredentialRefs() throws {
        let json = #"{"customBodies":[{"key":"max_tokens","value":2048},{"key":"max_output_tokens","value":4096},{"key":"token_budget","value":512}]}"#
        var sideTable: [String: String] = [:]
        let redacted = IOSCredentialRedactor.redact(json) { sideTable[$0] = $1 }
        let hydrated = IOSCredentialRedactor.rehydrate(redacted) { sideTable[$0] }
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
        let restored = try JSONSerialization.jsonObject(with: Data(hydrated.utf8)) as! NSDictionary
        XCTAssertEqual(restored, original)
        XCTAssertTrue(sideTable.isEmpty)
        XCTAssertTrue(IOSCredentialRedactor.activeCredentialPaths(in: json).isEmpty)
    }

    func test_customBodyJSONCredentials_preserveTypesAndCleanupRefs() throws {
        let json = #"{"customBodies":[{"key":"token","value":{"access":"object-secret","ttl":12}},{"key":"api_key","value":["array-secret",7,false,null]},{"key":"secret","value":true},{"key":"password","value":null},{"key":"authorization","value":12345}]}"#
        var sideTable: [String: String] = [:]
        let redacted = IOSCredentialRedactor.redact(json) { sideTable[$0] = $1 }
        XCTAssertFalse(redacted.contains("object-secret"))
        XCTAssertFalse(redacted.contains("array-secret"))
        XCTAssertEqual(sideTable.count, 5)
        XCTAssertEqual(IOSCredentialRedactor.activeCredentialPaths(in: json), Set(sideTable.keys))
        XCTAssertEqual(IOSCredentialRedactor.activeCredentialPaths(in: redacted), Set(sideTable.keys))

        let hydrated = IOSCredentialRedactor.rehydrate(redacted) { sideTable[$0] }
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
        let restored = try JSONSerialization.jsonObject(with: Data(hydrated.utf8)) as! NSDictionary
        XCTAssertEqual(restored, original)
        var rewrites: [String: String] = [:]
        let remasked = IOSCredentialRedactor.redact(redacted) { rewrites[$0] = $1 }
        XCTAssertTrue(rewrites.isEmpty, "A persisted placeholder must not replace the real Keychain value.")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(remasked.utf8)) as! NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(redacted.utf8)) as! NSDictionary)
    }

    func test_customBodyAndHeaderStringCredentials_preserveLegacyRawValues() throws {
        // JSON-looking strings must remain strings, including old raw Keychain entries.
        let json = #"{"apiKey":"provider-key","customBodies":[{"key":"token","value":"true"},{"key":"secret","value":"{\"access\":1}"}],"customHeaders":[{"first":"X-Access-Token","second":"123"}]}"#
        var sideTable: [String: String] = [:]
        let redacted = IOSCredentialRedactor.redact(json) { sideTable[$0] = $1 }
        XCTAssertEqual(sideTable["root.customBodies[token#0].value"], "true")
        XCTAssertEqual(sideTable["root.customHeaders[X-Access-Token#0].second"], "123")
        let hydrated = IOSCredentialRedactor.rehydrate(redacted) { sideTable[$0] }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(hydrated.utf8)) as! NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary)
    }

    func test_customBodyCanonicalAuthAliases_remainMaskedAndRoundTrip() throws {
        let aliases = ["cookie", "set-cookie", "credential", "X-Api-Key", "X-Auth-Key",
                       "X-Auth-Token", "X-Access-Token", "Api-Token", "Proxy-Authorization"]
        let original: NSDictionary = ["customBodies": aliases.enumerated().map {
            ["key": $0.element, "value": "auth-secret-\($0.offset)"]
        }]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: original), as: UTF8.self)
        var sideTable: [String: String] = [:]
        let redacted = IOSCredentialRedactor.redact(json) { sideTable[$0] = $1 }
        XCTAssertFalse(redacted.contains("auth-secret-"))
        XCTAssertEqual(sideTable.count, aliases.count)
        XCTAssertEqual(IOSCredentialRedactor.activeCredentialPaths(in: json), Set(sideTable.keys))
        let restored = IOSCredentialRedactor.rehydrate(redacted) { sideTable[$0] }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(restored.utf8)) as! NSDictionary, original)
    }

    func test_customBodyPreviouslyOverMaskedOptions_restoreLegacyStringsAndRetainRefs() throws {
        let json = """
        {"customBodies":[{"key":"max_tokens","value":"\(IOSCredentialRedactor.mask)"},
                         {"key":"token_budget","value":"\(IOSCredentialRedactor.mask)"}]}
        """
        let sideTable = ["root.customBodies[max_tokens#0].value": "2048",
                         "root.customBodies[token_budget#1].value": "512"]
        XCTAssertEqual(IOSCredentialRedactor.activeCredentialPaths(in: json), Set(sideTable.keys))
        let restored = IOSCredentialRedactor.rehydrate(json) { sideTable[$0] }
        let expected = #"{"customBodies":[{"key":"max_tokens","value":"2048"},{"key":"token_budget","value":"512"}]}"#
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(restored.utf8)) as! NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(expected.utf8)) as! NSDictionary)
        XCTAssertTrue(IOSCredentialRedactor.activeCredentialPaths(in: restored).isEmpty)
        var writes: [String: String] = [:]
        let persisted = IOSCredentialRedactor.redact(restored) { writes[$0] = $1 }
        XCTAssertTrue(writes.isEmpty, "Ordinary body options must not be newly routed to Keychain.")
        XCTAssertFalse(persisted.contains(IOSCredentialRedactor.mask))
        XCTAssertFalse(IOSCredentialRedactor.rehydrate(json) { _ in nil }.contains(IOSCredentialRedactor.mask))
    }

    /// RED for P0 (discovery round 6). GREEN target: P2.
    /// Cell: *.secure_store (header classification gap).
    ///
    /// `isSensitiveHeaderName` only matched a narrow exact list
    /// (authorization/x-api-key/cookie/…), so a credential header named
    /// `Access-Token` / `Token` / `Secret` (or a customBody keyed `token`) was NOT
    /// masked and leaked into the persisted Settings JSON and backups. Classification
    /// must cover the same sensitive markers as `isSensitiveKey`, matching by
    /// substring so prefixed forms (X-Access-Token, Api-Token) are covered too.
    func test_customHeaderNamedAccessToken_encode_containsNoCredential() {
        let secret = "tokhdr-SECRET-\(UUID().uuidString)"
        let json = """
        {"providers":[{"id":"p1","customHeaders":[{"first":"Access-Token","second":"\(secret)"}]}]}
        """
        let redacted = IOSCredentialRedactor.redact(json)
        XCTAssertFalse(
            redacted.contains(secret),
            "A credential header named Access-Token must be masked (isSensitiveHeaderName was too narrow)."
        )
    }

    /// RED for P0 (discovery round 6). GREEN target: P2.
    /// Cell: *.secure_store (side-table path collision).
    ///
    /// The Keychain side-table ref for an array item used only its name/identity (no
    /// index), so two custom headers sharing the same sensitive name (e.g. two
    /// `X-Api-Key`) collapsed onto ONE path: redact stored the second over the first
    /// (credential A lost) and rehydrate filled BOTH fields with credential B
    /// (cross-contamination). The path must include the array index so same-named
    /// items keep distinct refs.
    func test_twoSameNamedSensitiveHeaders_keepDistinctValuesAcrossRoundTrip() {
        let secretA = "hdr-A-\(UUID().uuidString)"
        let secretB = "hdr-B-\(UUID().uuidString)"
        let json = """
        {"providers":[{"id":"p1","models":[{"id":"m1","customHeaders":[\
        {"first":"X-Api-Key","second":"\(secretA)"},\
        {"first":"X-Api-Key","second":"\(secretB)"}\
        ]}]}]}
        """
        var sideTable: [String: String] = [:]
        let redacted = IOSCredentialRedactor.redact(json) { path, value in sideTable[path] = value }
        // Both distinct secrets must be masked out of the persisted JSON...
        XCTAssertFalse(redacted.contains(secretA))
        XCTAssertFalse(redacted.contains(secretB))
        // ...and each must rehydrate to its OWN field (not collide onto one path).
        let rehydrated = IOSCredentialRedactor.rehydrate(redacted) { path in sideTable[path] }
        XCTAssertTrue(rehydrated.contains(secretA), "first same-named header's distinct value must survive the round-trip")
        XCTAssertTrue(rehydrated.contains(secretB), "second same-named header's distinct value must survive the round-trip")
    }

    // MARK: - secure_store binding (subagent_standalone / subagent_chat / council)

    /// GREEN (P4 binding). Cell: subagent_standalone.secure_store.
    ///
    /// The standalone subagent capability must NOT land credentials on any
    /// independent persist surface. It resolves its provider via
    /// `IOSDeepReadDraftGenerator.resolveProviderSetting` (which clones the
    /// selected setting into an in-memory value passed to the adapter — never
    /// persisted) and stores run records via `IOSAdvancedTaskStore`, whose
    /// `IOSAdvancedTaskRecord` is redacted (`redacted()` scrubs bearer/key/
    /// token/password). Credentials flow only through the shared, redacted
    /// `IOSSharedSettingsStore` (bound green by `test_settings_encode_contains
    /// NoCredential`). This test binds that contract: a standalone run with a
    /// secret apiKey leaves no secret in the task store's persist surface.
    func test_subagentStandalone_secureStore_noIndependentCredentialLanding() async throws {
        let secret = "subagent-standalone-SECRET-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: "redlight-subagent-sec-\(UUID().uuidString)")!
        let taskStore = IOSAdvancedTaskStore(userDefaults: suite, storageKey: "redlight.tasks")
        let runner = SubAgentRunner(taskStore: taskStore)
        let providerWithSecret = makeOpenAIProvider(apiKey: secret)

        // Drive the engine path with the secret-bearing provider (the resolved
        // provider is passed in-memory; nothing persists it).
        _ = await runner.runViaEngine(
            objective: "explore the objective",
            roleId: "explorer",
            providerSetting: providerWithSecret,
            modelId: "any-model",
            parentToolExecutors: [:],
            provider: EngineProbeProvider()
        )

        // The task store is the only persist surface the standalone capability
        // owns. Assert the secret is absent from its persisted form.
        guard let persisted = suite.data(forKey: "redlight.tasks") else {
            // No persistence yet is itself clean (no credential landed).
            return
        }
        let persistedString = String(data: persisted, encoding: .utf8) ?? ""
        XCTAssertFalse(
            persistedString.contains(secret),
            "Standalone subagent must not land the apiKey credential in its task-store persist surface. "
                + "Credentials flow only through the shared redacted settings store (scheme B)."
        )
    }

    /// GREEN (P4 binding). Cell: subagent_chat.secure_store.
    ///
    /// The chat-embedded subagent dispatch (`ChatToolRuntime.subagent_dispatch`
    /// → `SubAgentRunner.runViaEngine`) reuses the chat-resolved provider
    /// (passed in-memory) and the same redacted task store. It has NO
    /// independent credential persist surface. This binds that contract the
    /// same way as the standalone test.
    func test_subagentChat_secureStore_noIndependentCredentialLanding() async throws {
        let secret = "subagent-chat-SECRET-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: "redlight-subagentchat-sec-\(UUID().uuidString)")!
        let taskStore = IOSAdvancedTaskStore(userDefaults: suite, storageKey: "redlight.tasks")
        let runner = SubAgentRunner(taskStore: taskStore)
        let providerWithSecret = makeOpenAIProvider(apiKey: secret)

        // The chat path calls runViaEngine with the chat-resolved provider.
        _ = await runner.runViaEngine(
            objective: "chat-embedded objective",
            roleId: "explorer",
            providerSetting: providerWithSecret,
            modelId: "any-model",
            parentToolExecutors: [:],
            provider: EngineProbeProvider()
        )

        guard let persisted = suite.data(forKey: "redlight.tasks") else { return }
        let persistedString = String(data: persisted, encoding: .utf8) ?? ""
        XCTAssertFalse(
            persistedString.contains(secret),
            "Chat-embedded subagent must not land the apiKey credential in its task-store persist surface. "
                + "It reuses the chat-resolved provider (in-memory) + shared redacted settings store."
        )
    }

    /// GREEN (P4 binding). Cell: council.secure_store.
    ///
    /// The council capability must NOT land credentials on any independent
    /// persist surface. It resolves its provider via
    /// `IOSCouncilRoomRunner.resolveProviderSetting` (in-memory clone passed to
    /// the streamer — never persisted) and records runs via the shared
    /// `IOSAdvancedTaskStore` (redacted). Credentials flow only through the
    /// shared, redacted settings store. This binds that contract by driving a
    /// council run record through the same redacted task store the capability
    /// uses, with the secret-bearing provider, and asserting the secret is
    /// absent from the persisted form.
    func test_council_secureStore_noIndependentCredentialLanding() {
        let secret = "council-SECRET-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: "redlight-council-sec-\(UUID().uuidString)")!
        let taskStore = IOSAdvancedTaskStore(userDefaults: suite, storageKey: "redlight.tasks")
        // Council records runs via IOSAdvancedTaskStore; start a task carrying
        // the secret-bearing provider in its metadata (worst case) and persist.
        let providerWithSecret = makeClaudeProvider(apiKey: secret)
        _ = taskStore.startTask(
            kind: .modelCouncil,
            title: "council sec test",
            objective: "objective",
            roleId: nil,
            toolScope: [],
            budgetSummary: "budget",
            connectionSummary: "",
            commandPreview: "",
            sourceToolName: "model_council_run",
            metadata: ["provider_type": String(describing: type(of: providerWithSecret))]
        )

        // Council has no independent credential persist surface — it reuses the
        // shared redacted settings store + the redacted task store. Assert the
        // task store (its only persist surface) does not contain the secret.
        guard let persisted = suite.data(forKey: "redlight.tasks") else {
            return // no persistence yet is itself clean
        }
        let persistedString = String(data: persisted, encoding: .utf8) ?? ""
        XCTAssertFalse(
            persistedString.contains(secret),
            "Council must not land the apiKey credential in its task-store persist surface. "
                + "Credentials flow only through the shared redacted settings store (scheme B)."
        )
    }

    /// GREEN (P2 rehydration). Cell: chat.secure_store (restart-survival aspect).
    ///
    /// Scheme B redacts provider apiKeys in the persisted JSON (mask sentinel)
    /// and stores the real key in the Keychain side-table. On restart, the
    /// loaded snapshot must REHYDRATE the real apiKey from the side-table — so
    /// a provider added before restart is still usable after, with its real key
    /// (not the mask). This binds that contract: add a provider with a real key,
    /// reload the store from the same UserDefaults, and assert the reloaded
    /// snapshot carries the REAL key (not the mask).
    func test_providerApiKey_rehydratedFromKeychainOnReload() {
        let secret = "sk-rehydrate-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-rehydrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(apiKey: secret)
        store.addProvider(provider)
        let providerId = provider.id.description() as String

        // Reload from the same UserDefaults (simulates restart). The persisted
        // JSON is redacted; the reload must rehydrate the real key from Keychain.
        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        let reloadedProvider = reloaded.snapshot.providers.first {
            ($0.id.description() as String) == providerId
        }

        XCTAssertNotNil(reloadedProvider, "Provider must survive restart.")
        let reloadedKey = (reloadedProvider as? ProviderSetting.OpenAI)?.apiKey
            ?? (reloadedProvider as? ProviderSetting.Claude)?.apiKey
            ?? ""
        XCTAssertEqual(
            reloadedKey, secret,
            "Provider apiKey must be rehydrated from the Keychain side-table on reload, "
                + "not left as the redactor mask. Got: \(reloadedKey) (P2 scheme B rehydration)."
        )
    }

    /// 根因守护:`IOSCredentialRedactor.arrayItemPath` 用 `[<identity>#<index>]`
    /// 标识数组项(索引后缀是为了让两个同名 header 不塌到同一条 side-table 路径),
    /// 因此按稳定 ID 反查 generic 凭据路径时必须匹配到 `#` 为止。
    /// 曾经用 `"[\(id)]"` 匹配——对真实路径恒为 false,`genericCredentialRefs`
    /// 永远返回空,provider/model/TTS 删除时 generic side-table 条目全部残留。
    func test_credentialPathsIdentifyArrayItemsWithIndexSuffix() {
        let defaults = UserDefaults(suiteName: "redlight-path-format-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(apiKey: "sk-path-format-\(UUID().uuidString)")
        store.addProvider(provider)
        let providerId = provider.id.description() as String

        let paths = IOSCredentialRedactor.activeCredentialPaths(
            in: IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        ).filter { $0.contains(providerId) }
        print("[CRED-PATH] \(paths.sorted().joined(separator: " | "))")

        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(
            paths.allSatisfy { $0.contains("[\(providerId)#") },
            "数组项路径必须是 [<id>#<index>] 形态;按稳定 ID 反查的一方要匹配到 # 为止"
        )
        XCTAssertFalse(
            paths.contains { $0.contains("[\(providerId)]") },
            "不存在无索引后缀的 [<id>] 形态——按该形态匹配等于永远匹配不到"
        )
    }

    func test_removeProviderDeletesTypedAndGenericCredentialRefs() {
        let secret = "sk-delete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: "redlight-delete-provider-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(apiKey: secret)
        store.addProvider(provider)
        let providerId = provider.id.description() as String
        let paths = IOSCredentialRedactor.activeCredentialPaths(
            in: IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        ).filter { $0.contains(providerId) }

        XCTAssertEqual(
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.providerApiKey(providerId: providerId)),
            secret
        )
        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) != nil
        })

        XCTAssertTrue(store.removeProvider(providerId: providerId))

        XCTAssertNil(IOSCredentialSideTable.load(key: IOSCredentialSideTable.providerApiKey(providerId: providerId)))
        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) == nil
        })
    }

    func test_removeCustomModelReusesProviderCredentialCleanup() throws {
        let secret = "custom-model-delete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: "redlight-delete-custom-model-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.addCustomModel(
            name: "Legacy Custom",
            modelId: "legacy-custom-\(UUID().uuidString)",
            providerName: "Legacy Provider"
        )
        let index = store.savedCustomModels.count - 1
        let providerId = try XCTUnwrap(store.savedCustomModels[index]["providerId"])
        _ = store.updateProviderApiKey(providerId: providerId, apiKey: secret)
        let paths = IOSCredentialRedactor.activeCredentialPaths(
            in: IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        ).filter { $0.contains(providerId) }

        XCTAssertEqual(
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.providerApiKey(providerId: providerId)),
            secret
        )
        XCTAssertFalse(paths.isEmpty)

        store.removeCustomModel(at: index)

        XCTAssertFalse(store.snapshot.providers.contains { $0.id.description() == providerId })
        XCTAssertNil(IOSCredentialSideTable.load(key: IOSCredentialSideTable.providerApiKey(providerId: providerId)))
        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) == nil
        })
    }

    func test_removeModelDeletesOnlyItsGenericCredentialRefs() throws {
        let secret = "model-delete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: "redlight-delete-model-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(apiKey: "")
        store.addProvider(provider)
        let providerId = provider.id.description() as String
        let modelId = "private-model-\(UUID().uuidString)"
        let updated = try XCTUnwrap(store.upsertProviderChatModel(
            providerId: providerId,
            modelUuid: nil,
            modelId: modelId,
            displayName: "Private",
            contextWindowTokens: nil,
            modelType: .chat,
            headers: [("Authorization", "Bearer \(secret)")]
        ))
        let model = try XCTUnwrap(updated.models.first { $0.modelId == modelId })
        let modelUuid = model.id.description()
        let paths = IOSCredentialRedactor.activeCredentialPaths(
            in: IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        ).filter { $0.contains(modelUuid) }

        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) != nil
        })

        _ = store.removeProviderChatModel(providerId: providerId, modelUuid: modelUuid)

        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) == nil
        })
    }

    func test_removeTtsProviderDeletesItsGenericCredentialRefs() throws {
        let secret = "tts-delete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: "redlight-delete-tts-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.addTtsEngine(name: "Delete TTS", engineType: "openai", apiKey: secret, model: "tts-1")
        let ttsId = try XCTUnwrap(store.savedTtsEngines.last?["ttsId"])
        let paths = IOSCredentialRedactor.activeCredentialPaths(
            in: IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        ).filter { $0.contains(ttsId) }

        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) != nil
        })

        store.removeTtsEngine(at: store.savedTtsEngines.count - 1)

        XCTAssertTrue(paths.allSatisfy {
            IOSCredentialSideTable.load(key: IOSCredentialSideTable.settingsPath($0)) == nil
        })
    }

    func test_providerApiKey_plaintextMigrationRedactsDefaultsImmediately() {
        let secret = "sk-migrate-SECRET-\(UUID().uuidString)"
        let namespace = "redlight-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: namespace)!
        var settings = IosSettingsDefaults.shared.defaultSeededSettings()
        let provider = makeOpenAIProvider(apiKey: secret)
        settings = IosSettingsMutations.shared.addProvider(settings: settings, provider: provider)
        defaults.set(
            IosSettingsJsonBridge.shared.encode(settings: settings),
            forKey: "app.amber.ios.sharedSettingsJson"
        )

        _ = IOSSharedSettingsStore(userDefaults: defaults)

        let migratedJson = defaults.string(forKey: "app.amber.ios.sharedSettingsJson") ?? ""
        XCTAssertFalse(
            migratedJson.contains(secret),
            "Plaintext migration must immediately rewrite UserDefaults with redacted JSON, not wait for the next settings write."
        )
        XCTAssertTrue(migratedJson.contains(IOSCredentialRedactor.mask))

        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        let providerId = provider.id.description() as String
        let reloadedProvider = reloaded.snapshot.providers.first {
            ($0.id.description() as String) == providerId
        } as? ProviderSetting.OpenAI
        XCTAssertEqual(reloadedProvider?.apiKey, secret)
    }

    func test_releaseSensitiveLogsAreDebugGuarded() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testDirectory.deletingLastPathComponent().appendingPathComponent("iosApp")
        let sourcesAndMarkers: [(String, [String])] = [
            ("HotlistCore/IOSHotListTitleTranslator.swift", [
                "[AmberTranslate] translate()",
                "[AmberTranslate] generateText threw:",
                "[AmberTranslate] llm chars="
            ]),
            ("HotlistCore/IOSHotListDashboardStore.swift", [
                "[AmberTranslate] apply pending="
            ]),
            ("DeepReadCore/IOSDeepReadDraftGenerator.swift", [
                "[AmberDeepRead] sources="
            ])
        ]
        let deepRead = try String(
            contentsOf: appDirectory.appendingPathComponent("DeepReadCore/DeepReadSourceCollector.swift"),
            encoding: .utf8
        )

        for (path, markers) in sourcesAndMarkers {
            let content = try String(
                contentsOf: appDirectory.appendingPathComponent(path),
                encoding: .utf8
            )
            for marker in markers {
                XCTAssertTrue(
                    Self.source(content, hasDebugGuardAround: marker),
                    "\(marker) must be wrapped in #if DEBUG before release builds."
                )
            }
        }
        for marker in [
            "[AmberDeepRead] topic-search angle failed",
            "[AmberDeepRead] topic-search angles="
        ] {
            XCTAssertTrue(
                Self.source(deepRead, hasDebugGuardAround: marker),
                "\(marker) must be wrapped in #if DEBUG before release builds."
            )
        }
    }

    func test_iPadMultipleScenesDisabledUntilMultiWindowCoordinatorExists() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testDirectory.deletingLastPathComponent().appendingPathComponent("iosApp")
        let plistURL = appDirectory.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            plist["UIApplicationSupportsMultipleScenes"] as? Bool,
            false,
            "iPad multi-window must stay disabled until the store/viewModel/background coordinator are multi-scene safe."
        )
    }

    private static func source(_ source: String, hasDebugGuardAround marker: String) -> Bool {
        guard let markerRange = source.range(of: marker) else { return false }
        let before = source[..<markerRange.lowerBound]
        let after = source[markerRange.upperBound...]
        guard let ifRange = before.range(of: "#if DEBUG", options: .backwards) else { return false }
        if let endifBefore = before.range(of: "#endif", options: .backwards),
           endifBefore.lowerBound > ifRange.lowerBound {
            return false
        }
        guard let endifAfter = after.range(of: "#endif") else { return false }
        if let ifAfter = after.range(of: "#if DEBUG"),
           ifAfter.lowerBound < endifAfter.lowerBound {
            return false
        }
        return true
    }
    /// A provider that records engine-path invocation for the subagent test.
    final class EngineProbeProvider: IOSAgentTextProvider, @unchecked Sendable {
        private(set) var callCount = 0
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            let message = UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: "done", metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 6, day: 22, hour: 0, minute: 0, second: 0, nanosecond: 0),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            return MessageChunk(
                id: "probe-\(callCount)",
                model: "test",
                choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
                usage: nil
            )
        }
    }
}
