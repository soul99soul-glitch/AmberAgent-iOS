import AppKit
import Foundation
import Observation

/// String-keyed secret slot for the cloud device token. `IOSCredentialSideTable` in production,
/// a memory fake in tests/previews.
protocol DesktopCloudTokenStore: Sendable {
    func load(key: String) -> String?
    @discardableResult func store(key: String, value: String) -> Bool
    @discardableResult func delete(key: String) -> Bool
}

struct DesktopCloudKeychainTokens: DesktopCloudTokenStore {
    func load(key: String) -> String? { IOSCredentialSideTable.load(key: key) }
    @discardableResult func store(key: String, value: String) -> Bool {
        IOSCredentialSideTable.store(key: key, value: value)
    }
    @discardableResult func delete(key: String) -> Bool { IOSCredentialSideTable.delete(key: key) }
}

// MARK: - Remote config view model (never carries secret values)

/// The cloud's non-secret configuration status (`GET /v2/configuration`). `*Configured` flags
/// only say a secret exists; secret values are never read back.
struct DesktopCloudRemoteConfig: Equatable, Sendable {
    struct Model: Equatable, Sendable {
        var provider: String = ""
        var modelId: String = ""
        var baseURL: String = ""
        var keyConfigured = false
    }
    struct Search: Equatable, Sendable {
        var sources: [String] = []
        var mode: String = "fallback"
        var exaKeyConfigured = false
        var braveKeyConfigured = false
    }
    var model = Model()
    var search = Search()
    /// Remote secret slot names the daemon reports as set (contract keys, e.g. "modelApiKey").
    var configuredSecrets: Set<String> = []
    var supportedModelProviders: [String] = []
    var supportedSearchSources: [String] = []
    /// Optimistic-lock counter (`expectedRevision` on the next write).
    var revision = 0
}

/// What the user may edit manually. Empty key fields mean "keep the stored value";
/// removing a secret is a separate explicit `deletes` action.
struct DesktopCloudConfigDraft: Equatable, Sendable {
    var modelProvider = "openai"
    var modelId = ""
    var modelBaseURL = ""
    var modelApiKey = ""
    var searchSources: [String] = []
    var searchMode = "fallback"
    var exaKey = ""
    var braveKey = ""
    var deletes: Set<String> = []
    var baseRevision = 0
}

/// One apply call: non-secret fields plus the plaintext secrets the user chose to upload.
/// `includes*` decide whether the whole `configuration.model`/`configuration.search` objects go
/// in the envelope — the contract treats omitted objects as "keep current" (contract key names:
/// modelApiKey/exaApiKey/braveApiKey). Secrets exist only in memory and are sealed into the JWE.
struct DesktopCloudConfigApply: Equatable, Sendable {
    var config: DesktopCloudConfigDraft
    var includesModel = false
    var includesSearch = false
    var secrets: [String: String] = [:]
}

/// The cloud configuration transport (`/v2/configuration`, JWE-sealed applies).
/// `DesktopCloudClientConfigSync` in production, a fake in tests. Secrets never appear in fetch results.
protocol DesktopCloudConfigSync: Sendable {
    func fetchConfig() async throws -> DesktopCloudRemoteConfig
    func applyConfig(_ request: DesktopCloudConfigApply, requestId: String) async throws -> DesktopCloudRemoteConfig
}

// MARK: - Local import catalog

/// What the Mac can offer the cloud, built from the real settings stores. No secret values are
/// loaded here — `hasAPIKey` only checks presence; values are read at confirm time.
struct DesktopCloudImportCatalog: Equatable, Sendable {
    struct ProviderItem: Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var kindTitle: String
        var baseURL: String
        var modelDisplay: String
        var hasAPIKey: Bool
        /// apiKey / plan providers can export a key; OAuth login state is device-bound and is not offered.
        var exportable: Bool
        /// True for the provider this Mac currently runs on — the import sheet preselects it.
        var selectedLocally: Bool
        var note: String?
    }
    struct SearchItem: Equatable, Identifiable, Sendable {
        var id: DesktopSearchService
        var title: String
        /// Cloud source names this local service maps to (free aggregates bing + duckduckgo).
        var cloudSources: [String]
        /// Remote secret slot fed by this service's key (contract credential names), if any.
        var secretKey: String?
        var hasAPIKey: Bool
        var supported: Bool
        var enabledLocally: Bool
    }
    var providers: [ProviderItem]
    var search: [SearchItem]
    var executionMode: DesktopSearchExecutionMode
    var resultCount: Int

    static let freeCloudSources = ["bing", "duckduckgo"]

    /// Local service → cloud sources; nil when the cloud has no such source.
    static func cloudSources(for service: DesktopSearchService) -> [String]? {
        switch service {
        case .free: freeCloudSources
        case .exa: ["exa"]
        case .brave: ["brave"]
        default: nil
        }
    }
}

/// The user's choices in the import sheet: one provider for the single cloud model slot,
/// plus any subset of cloud-supported search sources.
struct DesktopCloudImportPlan: Equatable, Sendable {
    var providerID: UUID?
    var searchServices: Set<DesktopSearchService> = []
    var searchMode: DesktopSearchExecutionMode = .sequentialFallback
    var deletes: Set<String> = []
}

// MARK: - Store

/// Owns the outbound cloud pairing (Mac → cloud host), connection state, and the
/// configuration import pipeline. Independent of the local `DesktopGateway` server slot:
/// different state, different Keychain item, different client.
@MainActor @Observable final class DesktopCloudSelfStore {
    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private static let connectionKey = "desktop.cloudSelf.connection.v1"
    private static let tokenKey = "cloudSelf.deviceToken"
    static let deviceName = Host.current().localizedName ?? "Mac"

    private(set) var connection: DesktopCloudConnection?
    private(set) var status: DesktopCloudStatus?
    /// nil until the first refresh after launch or pairing.
    private(set) var isReachable: Bool?
    private(set) var isBusy = false
    /// Remote config snapshot; nil until fetched. Never contains secret values.
    private(set) var remoteConfig: DesktopCloudRemoteConfig?
    private(set) var remoteConfigError: String?
    private(set) var isImporting = false
    /// Names of secret slots the cloud confirmed after the last upload.
    private(set) var lastConfiguredSecrets: Set<String>?
    var pendingPairing: DesktopCloudPairingPayload?
    var notice: Notice?

    @ObservationIgnored private var client: DesktopCloudClient?
    @ObservationIgnored private var sync: (any DesktopCloudConfigSync)?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: any DesktopCloudTokenStore
    @ObservationIgnored private let settings: DesktopSettings
    @ObservationIgnored private let searchSettings: DesktopSearchSettings
    /// Builds the config sync from the paired client; injectable so tests never touch TLS/JWE.
    @ObservationIgnored private let makeSync: @Sendable (DesktopCloudClient, DesktopCloudConnection) -> (any DesktopCloudConfigSync)?

    init(
        settings: DesktopSettings,
        searchSettings: DesktopSearchSettings,
        defaults: UserDefaults = .standard,
        tokens: any DesktopCloudTokenStore = DesktopCloudKeychainTokens(),
        makeSync: (@Sendable (DesktopCloudClient, DesktopCloudConnection) -> (any DesktopCloudConfigSync)?)? = nil
    ) {
        self.settings = settings
        self.searchSettings = searchSettings
        self.defaults = defaults
        self.tokens = tokens
        let kidStore = DesktopCloudPinnedKidStore(defaults: defaults)
        self.makeSync = makeSync ?? { client, connection in
            DesktopCloudClientConfigSync(client: client, connection: connection, kidStore: kidStore)
        }
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(DesktopCloudConnection.self, from: data),
           let token = tokens.load(key: Self.tokenKey) {
            connection = saved
            install(saved, token: token)
        }
    }

    private func install(_ connection: DesktopCloudConnection, token: String) {
        let client = DesktopCloudClient(addrs: connection.addrs, port: connection.port,
                                        fingerprint: connection.fingerprint, token: token)
        self.client = client
        self.sync = makeSync(client, connection)
    }

    // MARK: - Pairing

    /// Deep link or paste entry. Pairing still needs an explicit fingerprint confirmation.
    func receivePairingLink(_ link: String) {
        guard let payload = DesktopCloudPairingPayload.parse(link) else {
            notice = Notice(text: "配对链接无效，请在云端重新运行 amber-cli pair", isError: true)
            return
        }
        pendingPairing = payload
        notice = nil
    }

    func pasteLinkFromClipboard() {
        receivePairingLink(NSPasteboard.general.string(forType: .string) ?? "")
    }

    func confirmPairing() async {
        guard let payload = pendingPairing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let pairingClient = DesktopCloudClient(addrs: payload.addrs, port: payload.port, fingerprint: payload.fp, token: nil)
        do {
            let response = try await pairingClient.pair(secret: payload.s, deviceName: Self.deviceName)
            guard tokens.store(key: Self.tokenKey, value: response.token) else {
                notice = Notice(text: "无法把配对凭据写入钥匙串", isError: true)
                return
            }
            let saved = DesktopCloudConnection(gatewayId: response.gatewayId, name: response.gatewayName,
                addrs: payload.addrs, port: payload.port, fingerprint: payload.fp, deviceId: response.deviceId)
            defaults.set(try? JSONEncoder().encode(saved), forKey: Self.connectionKey)
            connection = saved
            install(saved, token: response.token)
            pendingPairing = nil
            notice = nil
            await refresh()
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    func unpair() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Best effort: if the cloud is unreachable the device stays listed there until revoked server-side.
        // 401 means the cloud already dropped this device, which is the outcome we wanted.
        var reached = true
        do {
            try await client?.unpair()
        } catch DesktopCloudError.unauthorized {
        } catch {
            reached = false
        }
        forget()
        notice = reached ? nil : Notice(text: "已在本机取消配对。云端当前不可达，可在云端用 amber-cli devices 核对后再吊销此设备", isError: false)
    }

    // MARK: - Status & remote config

    func refresh() async {
        guard let client else { return }
        statusGeneration += 1
        let generation = statusGeneration
        do {
            let latest = try await client.status()
            guard self.client === client, generation == statusGeneration else { return }
            status = latest
            isReachable = true
            await refreshRemoteConfig()
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == statusGeneration else { return }
            if !forgetIfRevoked(error) { isReachable = false }
        }
    }

    func refreshRemoteConfig() async {
        guard let sync else { return }
        do {
            remoteConfig = try await sync.fetchConfig()
            remoteConfigError = nil
        } catch is CancellationError {
        } catch {
            if forgetIfRevoked(error) { return }
            remoteConfigError = error.localizedDescription
        }
    }

    /// Polls while the settings tab is visible, like DesktopGateway.startPolling but gentler:
    /// a remote host is not a local socket.
    func startPolling() {
        guard poll == nil, connection != nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() { poll?.cancel(); poll = nil }

    // MARK: - Remote config apply (manual update)

    /// The cloud config transport exists once pairing lands a contract-backed sync.
    var canSyncConfig: Bool { sync != nil }

    /// Saves the manual-edit draft. Empty key fields keep stored values; `deletes` are explicit.
    /// Retries keep the same requestId; on conflict the caller keeps the draft and re-reads.
    @discardableResult
    func applyRemoteConfig(_ draft: DesktopCloudConfigDraft, requestId: String) async -> DesktopCloudError? {
        guard let sync else { return .server("云端配置接口尚未接入，等待后端契约") }
        do {
            var secrets: [String: String] = [:]
            // Placeholder/masked text ("••••", "sk-****") means keep, never upload.
            if let key = Self.realSecret(draft.modelApiKey) { secrets["modelApiKey"] = key }
            if let key = Self.realSecret(draft.exaKey) { secrets["exaApiKey"] = key }
            if let key = Self.realSecret(draft.braveKey) { secrets["braveApiKey"] = key }
            // Contract guard: with a stored model key, switching provider or effective baseURL
            // requires an explicit credential action in the same request (else 422
            // credential_action_required and nothing applies). Fail early with a clearer message.
            if credentialActionMissing(for: draft, secrets: secrets) {
                return .server("云端已存有模型 Key：更换服务商或接口地址需同时粘贴新 Key，或在下方勾选删除后切换")
            }
            remoteConfig = try await sync.applyConfig(
                DesktopCloudConfigApply(config: draft, includesModel: true, includesSearch: true,
                                        secrets: secrets), requestId: requestId)
            remoteConfigError = nil
            lastConfiguredSecrets = remoteConfig?.configuredSecrets
            return nil
        } catch let error as DesktopCloudError {
            if error == .unauthorized { forgetIfRevoked(error) }
            return error
        } catch {
            return .server(error.localizedDescription)
        }
    }

    // MARK: - Import from this Mac

    /// Snapshot of what this Mac can offer; reads key *presence* only.
    func importCatalog() -> DesktopCloudImportCatalog {
        let providers = settings.providers.map { provider in
            let exportable = provider.authMode == .apiKey || provider.authMode.isPlan
            let model = provider.selectedModel
            return DesktopCloudImportCatalog.ProviderItem(
                id: provider.id,
                name: provider.name,
                kindTitle: provider.kind.title,
                baseURL: provider.baseURL,
                modelDisplay: model?.displayName ?? "",
                hasAPIKey: exportable && (try? settings.apiKey(for: provider.id))?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                exportable: exportable,
                selectedLocally: provider.id == settings.selectedProviderID,
                note: exportable ? nil : "OAuth 登录态只在本机有效，不上传"
            )
        }
        let search = searchSettings.serviceOrder.compactMap { service -> DesktopCloudImportCatalog.SearchItem? in
            let sources = DesktopCloudImportCatalog.cloudSources(for: service)
            return DesktopCloudImportCatalog.SearchItem(
                id: service,
                title: service.title,
                cloudSources: sources ?? [],
                secretKey: service == .exa ? "exaApiKey" : service == .brave ? "braveApiKey" : nil,
                hasAPIKey: searchSettings.hasAPIKey(for: service),
                supported: sources != nil,
                enabledLocally: searchSettings.enabledServices.contains(service)
            )
        }
        return DesktopCloudImportCatalog(providers: providers, search: search,
            executionMode: searchSettings.executionMode, resultCount: searchSettings.resultCount)
    }

    /// Display name for a contract credential slot in notices/previews (never the value).
    nonisolated static func secretDisplayName(_ key: String) -> String {
        switch key {
        case "modelApiKey": "模型 Key"
        case "exaApiKey": "Exa Key"
        case "braveApiKey": "Brave Key"
        default: key
        }
    }

    /// Ordered cloud search sources for a selected local service set.
    nonisolated static func cloudSearchSources(for selection: Set<DesktopSearchService>,
                                   order: [DesktopSearchService]) -> [String] {
        order.filter { selection.contains($0) }
            .flatMap { DesktopCloudImportCatalog.cloudSources(for: $0) ?? [] }
    }

    /// Executes the confirmed import: reads the selected keys from Keychain into memory, seals and
    /// uploads through the paired channel. Empty/unselected items keep existing cloud values.
    /// `requestId` stays stable across retries of the same user action.
    @discardableResult
    func `import`(_ plan: DesktopCloudImportPlan, catalog: DesktopCloudImportCatalog,
                  requestId: String) async -> DesktopCloudError? {
        guard let sync else { return .server("云端配置接口尚未接入，等待后端契约") }
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        // The revision carried in the draft drives conflict detection; refresh when we never fetched.
        if remoteConfig == nil { await refreshRemoteConfig() }
        do {
            var secrets: [String: String] = [:]
            var draft = remoteConfig.map {
                DesktopCloudConfigDraft(modelProvider: $0.model.provider, modelId: $0.model.modelId,
                    modelBaseURL: $0.model.baseURL, searchSources: $0.search.sources, searchMode: $0.search.mode,
                    baseRevision: $0.revision)
            } ?? DesktopCloudConfigDraft()

            if let providerID = plan.providerID,
               let provider = settings.providers.first(where: { $0.id == providerID }) {
                guard provider.authMode == .apiKey || provider.authMode.isPlan else {
                    return .server("OAuth 登录态只在本机有效，无法上传到云端；请改用 API Key 服务商")
                }
                let key = try settings.apiKey(for: provider.id).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty || DesktopHistoryRedaction.isPlaceholderCredential(key) {
                    return .server("\(provider.name) 在本机没有已保存的 API Key")
                }
                secrets["modelApiKey"] = key
                draft.modelProvider = Self.cloudProviderName(for: provider.kind)
                draft.modelId = provider.selectedModel?.modelID ?? ""
                draft.modelBaseURL = provider.baseURL
            }
            if !plan.searchServices.isEmpty {
                for service in plan.searchServices {
                    guard let secretKey = (service == .exa ? "exaApiKey" : service == .brave ? "braveApiKey" : nil)
                    else { continue }
                    let key = try searchSettings.apiKey(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty || DesktopHistoryRedaction.isPlaceholderCredential(key) {
                        return .server("\(service.title) 在本机没有已保存的 API Key")
                    }
                    secrets[secretKey] = key
                }
                draft.searchSources = Self.cloudSearchSources(for: plan.searchServices,
                    order: catalog.search.map(\.id))
                draft.searchMode = plan.searchMode == .parallel ? "aggregate" : "fallback"
            }
            draft.deletes = plan.deletes
            remoteConfig = try await sync.applyConfig(
                DesktopCloudConfigApply(config: draft, includesModel: plan.providerID != nil,
                    includesSearch: !plan.searchServices.isEmpty, secrets: secrets), requestId: requestId)
            remoteConfigError = nil
            lastConfiguredSecrets = remoteConfig?.configuredSecrets
            return nil
        } catch let error as DesktopCloudError {
            if error == .unauthorized { forgetIfRevoked(error) }
            return error
        } catch {
            return .server(error.localizedDescription)
        }
    }

    /// Trims manual key input; nil when empty or a redaction placeholder (both mean "keep").
    nonisolated static func realSecret(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !DesktopHistoryRedaction.isPlaceholderCredential(trimmed) else { return nil }
        return trimmed
    }

    /// Local provider protocol → cloud `model.provider` value (openai covers OpenAI-compatible
    /// endpoints incl. DeepSeek; gemini has no cloud adapter yet).
    nonisolated static func cloudProviderName(for kind: DesktopProviderKind) -> String {
        switch kind {
        case .openAI, .responses: "openai"
        case .claude: "claude"
        case .gemini: "gemini"
        }
    }

    // MARK: - Private

    /// True when the draft redirects the model endpoint while the cloud still holds a key for the
    /// old one and no `replace`/`delete` rides along — the request the backend must reject.
    private func credentialActionMissing(for draft: DesktopCloudConfigDraft,
                                         secrets: [String: String]) -> Bool {
        guard let remote = remoteConfig, remote.model.keyConfigured,
              secrets["modelApiKey"] == nil, !draft.deletes.contains("modelApiKey")
        else { return false }
        return draft.modelProvider.trimmingCharacters(in: .whitespacesAndNewlines) != remote.model.provider
            || draft.modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) != remote.model.baseURL
    }

    /// 401 means the cloud revoked this device: drop the pairing everywhere, with the same explanation.
    @discardableResult
    private func forgetIfRevoked(_ error: Error) -> Bool {
        guard case DesktopCloudError.unauthorized = error else { return false }
        forget()
        notice = Notice(text: DesktopCloudError.unauthorized.localizedDescription, isError: true)
        return true
    }

    private func forget() {
        tokens.delete(key: Self.tokenKey)
        if let gatewayId = connection?.gatewayId {
            DesktopCloudPinnedKidStore(defaults: defaults).unpin(forGateway: gatewayId)
        }
        defaults.removeObject(forKey: Self.connectionKey)
        connection = nil
        client = nil
        sync = nil
        status = nil
        remoteConfig = nil
        remoteConfigError = nil
        lastConfiguredSecrets = nil
        isReachable = nil
        poll?.cancel(); poll = nil
    }
}
