import CryptoKit
import Foundation
@preconcurrency import Shared

// MARK: - Remote snapshot (non-secret view of GET /v2/configuration)

/// What the settings page shows about the cloud's current configuration.
/// Built from the contract's `ConfigurationView`; never contains secret values.
struct IOSCloudConfigSnapshot: Equatable, Sendable {
    struct Model: Equatable, Sendable {
        /// Contract provider kind: "openai" / "claude". Empty when nothing is configured.
        var provider: String
        var modelId: String
        /// Empty means the provider protocol's default address.
        var baseUrl: String
        /// `credentials.modelApiKey.configured` — status flag only, never the key.
        var keyConfigured: Bool
    }

    /// One supported search source row: the contract's fixed whitelist.
    struct Search: Equatable, Sendable, Identifiable {
        /// Cloud source id: "bing" / "duckduckgo" / "exa" / "brave".
        var type: String
        var name: String
        /// Present in `search.sources` — the source participates in cloud search.
        var enabled: Bool
        /// Free sources (bing/duckduckgo) don't need a key.
        var requiresKey: Bool
        /// `credentials.<source>ApiKey.configured` for key-carrying sources.
        var keyConfigured: Bool
        var id: String { type }
    }

    var gatewayId: String
    /// Optimistic-concurrency token for apply (`expectedRevision`).
    var revision: Int
    var model: Model?
    /// All supported sources, each marked enabled/configured.
    var search: [Search]
    /// Ordered search sources exactly as the cloud stores them.
    var searchSources: [String]
    /// "fallback" / "aggregate".
    var searchMode: String
    var supportedModelProviders: [String]
    var supportedSearchSources: [String]

    /// Free aggregate sources currently participating (subset of `searchSources`).
    var freeSources: [String] { searchSources.filter { IOSCloudConfigWire.requiresKey(for: $0) == false } }

    func keyConfigured(forCredentialKey credentialKey: String) -> Bool {
        search.first { IOSCloudConfigWire.credentialKey(for: $0.type) == credentialKey }?.keyConfigured == true
            || (credentialKey == IOSCloudConfigWire.modelCredentialKey && model?.keyConfigured == true)
    }
}

/// Server-side outcome of one apply call (`ConfigurationReceipt`). Only
/// names/status come back — the contract never echoes secret values.
struct IOSCloudConfigApplyReceipt: Equatable, Sendable {
    var requestId: String
    var revision: Int
    var currentRevision: Int
    /// True when the server already applied this requestId and only returned
    /// the stored receipt — the payload was not re-applied.
    var replayed: Bool
    /// Contract value "next_task": running workers keep their pinned snapshot.
    var effective: String
}

// MARK: - Contract wire mapping (docs/architecture/cloud-configuration-api.md)

/// Pure functions mapping local settings semantics onto the contract's fixed
/// whitelist: providers are openai/claude only; sources are
/// bing/duckduckgo/exa/brave; credential keys are modelApiKey/exaApiKey/braveApiKey.
enum IOSCloudConfigWire {
    static let modelCredentialKey = "modelApiKey"
    static let supportedProviders: Set<String> = ["openai", "claude"]

    /// Local serial service type → ordered cloud sources. The local free
    /// aggregate ("bing_local"/"free") expands to ordered bing, duckduckgo per
    /// the contract; unsupported types map to nothing.
    static func cloudSources(forLocalType typeLabel: String) -> [String] {
        switch typeLabel {
        case "bing_local", "free": ["bing", "duckduckgo"]
        case "bing": ["bing"]
        case "duckduckgo": ["duckduckgo"]
        case "exa": ["exa"]
        case "brave": ["brave"]
        default: []
        }
    }

    /// Cloud source → credential key name in the payload's `credentials` object.
    static func credentialKey(for cloudSource: String) -> String? {
        switch cloudSource {
        case "exa": "exaApiKey"
        case "brave": "braveApiKey"
        default: nil
        }
    }

    /// Free sources run without a key; exa/brave need their own.
    static func requiresKey(for cloudSource: String) -> Bool {
        credentialKey(for: cloudSource) != nil
    }

    static func sourceDisplayName(for cloudSource: String) -> String {
        switch cloudSource {
        case "bing": "Bing"
        case "duckduckgo": "DuckDuckGo"
        case "exa": "Exa"
        case "brave": "Brave"
        default: cloudSource
        }
    }
}

// MARK: - Local export items (what this device can offer)

/// Provider kinds the cloud can consume; maps the local sealed type.
enum IOSCloudProviderKind: String, Sendable {
    case openAI = "openai"
    case claude = "claude"
    case google = "google"

    /// The contract accepts openai/claude protocols only (OpenAI-compatible
    /// services ride "openai" with their HTTPS baseUrl).
    var isCloudSupported: Bool { IOSCloudConfigWire.supportedProviders.contains(rawValue) }
}

/// One local provider in the import picker. Built from the shared settings
/// snapshot; secrets are never stored on the item — `hasApiKey` is a flag only.
struct IOSCloudProviderExportItem: Identifiable, Equatable {
    struct ChatModel: Identifiable, Equatable {
        /// `Model.id` UUID string; selects the model inside this provider.
        let uuid: String
        /// Wire model id, e.g. "deepseek-flash".
        let modelId: String
        let displayName: String
        var id: String { uuid }
    }

    /// `ProviderSetting.id` — identifies the Keychain credential ref at upload time.
    let providerId: String
    var id: String { providerId }
    let name: String
    let kind: IOSCloudProviderKind
    let baseUrl: String
    let chatModels: [ChatModel]
    /// The current chat model when it lives in this provider, else the first chat model.
    let defaultModelUuid: String?
    let hasApiKey: Bool
    /// Managed account sessions ("Codex OAuth", "Antigravity OAuth", "Grok") whose
    /// credential cannot leave the device; nil means the apiKey is the credential.
    let managedAuthLabel: String?
    let enabled: Bool

    /// Only a real API key on a cloud-supported protocol can be imported;
    /// account sign-in sessions and disabled providers stay local.
    var isExportable: Bool {
        enabled && managedAuthLabel == nil && hasApiKey && !chatModels.isEmpty && kind.isCloudSupported
    }

    var blockedReason: String? {
        if !kind.isCloudSupported { return macGatewayL("云端不支持该服务商协议") }
        if !enabled { return macGatewayL("已停用") }
        if let managedAuthLabel { return managedAuthLabel + macGatewayL(" 登录态不能导出") }
        if !hasApiKey { return macGatewayL("没有 API Key") }
        if chatModels.isEmpty { return macGatewayL("没有聊天模型") }
        return nil
    }
}

/// One local search service in the import picker. Secrets never stored; the
/// Keychain side-table ref is resolved only at upload time.
struct IOSCloudSearchExportItem: Identifiable, Equatable {
    /// `SearchServiceOptions.id` — identifies the Keychain credential ref.
    let serviceId: String
    var id: String { serviceId }
    let name: String
    /// Local wire service type, e.g. "exa" / "brave" / "bing_local".
    let typeLabel: String
    let requiresKey: Bool
    let hasApiKey: Bool
    /// In `Settings.searchEnabledServiceIds` — the device actually uses it.
    let enabled: Bool
    /// The device's currently-selected search service.
    let isSelected: Bool

    /// Ordered cloud sources this service maps to; empty when the contract
    /// can't consume the type (tavily, zhipu, … stay local-only).
    var cloudSources: [String] { IOSCloudConfigWire.cloudSources(forLocalType: typeLabel) }
    var isCloudSupported: Bool { !cloudSources.isEmpty }
    var isExportable: Bool { isCloudSupported && (!requiresKey || hasApiKey) }
    var blockedReason: String? {
        if !isCloudSupported { return macGatewayL("云端暂不支持该搜索服务") }
        if requiresKey && !hasApiKey { return macGatewayL("没有 API Key") }
        return nil
    }
}

// MARK: - Import draft & preview

/// Selection state for "从本机导入". Defaults are deliberately narrow — the
/// current chat provider/model and the selected search service only — never
/// every configured account.
struct IOSCloudImportDraft: Equatable {
    var providers: [IOSCloudProviderExportItem]
    var searches: [IOSCloudSearchExportItem]
    var providerId: String?
    var modelUuid: String?
    var selectedSearchIds: Set<String>
    /// Whether the device's web-search master switch is on (UI hint only).
    let enableWebSearch: Bool
    /// Enabled built-in free sources, e.g. "duckduckgo", "bing", "jina".
    let freeSources: [String]

    /// Selection is UI-gated by `isExportable`; the draft itself resolves
    /// whatever id it holds so preview and bundle never silently diverge.
    var selectedProvider: IOSCloudProviderExportItem? {
        providers.first { $0.providerId == providerId }
    }

    var selectedModel: IOSCloudProviderExportItem.ChatModel? {
        guard let provider = selectedProvider else { return nil }
        return provider.chatModels.first { $0.uuid == modelUuid } ?? provider.chatModels.first
    }

    var selectedSearches: [IOSCloudSearchExportItem] {
        searches.filter { selectedSearchIds.contains($0.serviceId) && $0.isExportable }
    }

    var hasSelection: Bool {
        selectedProvider != nil || !selectedSearches.isEmpty
    }

    /// Builds the draft from the shared settings snapshot. Secret values are
    /// read only as flags here; `bundle()` resolves them at confirm time.
    static func make(from sharedSettings: IOSSharedSettingsStore) -> IOSCloudImportDraft {
        _ = sharedSettings.revision // observation dependency for callers reading in body
        let snapshot = sharedSettings.snapshot
        let currentModel = snapshot.getCurrentChatModel()
        let currentProvider = currentModel.flatMap {
            ChatProviderConfiguration.provider(for: $0, providers: snapshot.providers)
        }

        let providerItems = snapshot.providers.map { provider in
            item(for: provider, currentModelUuid: currentModel?.id.description())
        }
        let enabledIds = Set(snapshot.searchEnabledServiceIds.map { $0.description() })
        let selectedIndex = Int(snapshot.searchServiceSelected)
        let searchItems = snapshot.searchServices.enumerated().map { index, service in
            searchItem(
                for: service,
                index: index,
                selectedIndex: selectedIndex,
                sharedSettings: sharedSettings,
                enabledIds: enabledIds
            )
        }

        var draft = IOSCloudImportDraft(
            providers: providerItems,
            searches: searchItems,
            providerId: nil,
            modelUuid: nil,
            selectedSearchIds: [],
            enableWebSearch: snapshot.enableWebSearch,
            freeSources: freeSources(of: snapshot)
        )
        // Default selection: the active chat provider+model, and the currently
        // selected search service — deliberately not every configured account.
        if let currentProvider {
            let id = currentProvider.id.description()
            if let item = providerItems.first(where: { $0.providerId == id }), item.isExportable {
                draft.providerId = id
                draft.modelUuid = currentModel?.id.description() ?? item.defaultModelUuid
            }
        }
        if let selected = searchItems.first(where: { $0.isSelected && $0.isExportable }) {
            draft.selectedSearchIds = [selected.serviceId]
        }
        return draft
    }

    /// A stable refresh path: rebuild items while keeping the user's selections.
    /// An explicit "no model" deselection (`providerId == nil`) survives too —
    /// the rebuilt draft must not resurrect the default provider.
    func rebuilt(from sharedSettings: IOSSharedSettingsStore) -> IOSCloudImportDraft {
        var next = IOSCloudImportDraft.make(from: sharedSettings)
        if providerId == nil {
            next.providerId = nil
            next.modelUuid = nil
        } else if let providerId, next.providers.contains(where: { $0.providerId == providerId && $0.isExportable }) {
            next.providerId = providerId
            next.modelUuid = modelUuid ?? next.providers.first { $0.providerId == providerId }?.defaultModelUuid
        }
        next.selectedSearchIds = selectedSearchIds.intersection(
            Set(next.searches.filter(\.isExportable).map(\.serviceId))
        )
        return next
    }

    private static func item(
        for provider: ProviderSetting,
        currentModelUuid: String?
    ) -> IOSCloudProviderExportItem {
        let chatModels = provider.models
            .filter { $0.type == ModelType.chat && !$0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { model in
                IOSCloudProviderExportItem.ChatModel(
                    uuid: model.id.description(),
                    modelId: model.modelId,
                    displayName: model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? model.modelId : model.displayName
                )
            }
        let defaultModelUuid = chatModels.contains { $0.uuid == currentModelUuid }
            ? currentModelUuid
            : chatModels.first?.uuid
        return IOSCloudProviderExportItem(
            providerId: provider.id.description(),
            name: provider.name,
            kind: kind(of: provider),
            baseUrl: ChatProviderConfiguration.baseURL(of: provider),
            chatModels: chatModels,
            defaultModelUuid: defaultModelUuid,
            hasApiKey: !ChatProviderConfiguration.apiKey(of: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            managedAuthLabel: managedAuthLabel(of: provider),
            enabled: provider.enabled
        )
    }

    private static func kind(of provider: ProviderSetting) -> IOSCloudProviderKind {
        if provider is ProviderSetting.OpenAI { return .openAI }
        if provider is ProviderSetting.Claude { return .claude }
        return .google
    }

    /// Account-bound credentials stay on the device: OAuth sign-ins, web cookie
    /// sessions and managed coding-plan sign-ins can't be imported to the cloud.
    private static func managedAuthLabel(of provider: ProviderSetting) -> String? {
        if IOSCodexProviderResolver.isCodexProvider(provider) { return "Codex OAuth" }
        if IOSGrokWebProviderResolver.isGrokWebProvider(provider) { return "Grok" }
        if let google = provider as? ProviderSetting.Google {
            switch google.authMode {
            case GoogleAuthMode.antigravityOauth: return "Antigravity OAuth"
            case GoogleAuthMode.geminiCodeAssistOauth: return "Gemini OAuth"
            default: return nil
            }
        }
        return nil
    }

    private static func searchItem(
        for service: SearchServiceOptions,
        index: Int,
        selectedIndex: Int,
        sharedSettings: IOSSharedSettingsStore,
        enabledIds: Set<String>
    ) -> IOSCloudSearchExportItem {
        let serviceId = service.id.description()
        let providerType = SearchProviderType(service: service)
        let configured = sharedSettings.configuredSearchProviders.first { $0.id == serviceId }
        return IOSCloudSearchExportItem(
            serviceId: serviceId,
            name: configured?.name ?? providerType?.title ?? macGatewayL("搜索服务"),
            typeLabel: providerType?.serialName ?? String(describing: type(of: service)),
            requiresKey: providerType?.requiresAPIKey ?? true,
            hasApiKey: !searchApiKey(of: service).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            enabled: enabledIds.contains(serviceId),
            isSelected: index == selectedIndex
        )
    }

    private static func freeSources(of snapshot: Settings) -> [String] {
        var sources: [String] = []
        if snapshot.searchBuiltinDuckDuckGoEnabled { sources.append("duckduckgo") }
        if snapshot.searchBuiltinBingEnabled { sources.append("bing") }
        if snapshot.searchBuiltinJinaEnabled { sources.append("jina") }
        if snapshot.searchBuiltinWikipediaEnabled { sources.append("wikipedia") }
        if snapshot.searchBuiltinHackerNewsEnabled { sources.append("hackernews") }
        return sources
    }
}

// MARK: - Preview entries (no secrets, ever)

/// One row in the import confirmation sheet: what the selection will change on
/// the cloud. `replaces` says whether the remote currently has that slot.
struct IOSCloudImportPreviewEntry: Identifiable, Equatable {
    enum Section: Equatable {
        case model
        case search
    }

    let section: Section
    /// Display name, e.g. "DeepSeek" or "Exa".
    let title: String
    /// Detail line, e.g. model wire id, base URL host, or "免费聚合".
    let detail: String
    /// What changes on the cloud: "替换" when the slot exists remotely, "新增" otherwise.
    let replacesRemote: Bool
    /// A credential travels with this entry (Key/secret) — badges only, never the value.
    let includesSecret: Bool
    /// Local identifier used to build the bundle (providerId / serviceId).
    let sourceId: String
    /// Non-blocking warning, e.g. the contract's credential-destination guard.
    let warning: String?

    var id: String { "\(section)-\(sourceId)" }
}

extension IOSCloudImportDraft {
    /// Preview rows for the confirmation sheet. `remote` may be nil while the
    /// cloud's config endpoint is unavailable — entries then describe adds.
    func previewEntries(remote: IOSCloudConfigSnapshot?) -> [IOSCloudImportPreviewEntry] {
        var entries: [IOSCloudImportPreviewEntry] = []
        if let provider = selectedProvider, let model = selectedModel {
            let host = URLComponents(string: provider.baseUrl)?.host ?? provider.baseUrl
            // Contract guard: when the remote holds a model key and the destination
            // (provider|baseUrl) changes, the request must carry an explicit key
            // action or the server rejects it with credential_action_required.
            let remoteModel = remote?.model
            let destinationChanged = remoteModel.map {
                $0.provider.lowercased() != provider.kind.rawValue
                    || effectiveBaseUrl($0.provider, $0.baseUrl) != effectiveBaseUrl(provider.kind.rawValue, provider.baseUrl)
            } ?? false
            let needsKeyAction = remoteModel?.keyConfigured == true && destinationChanged && !provider.hasApiKey
            entries.append(IOSCloudImportPreviewEntry(
                section: .model,
                title: provider.name,
                detail: "\(model.modelId) · \(host)",
                replacesRemote: remoteModel != nil,
                includesSecret: provider.hasApiKey,
                sourceId: provider.providerId,
                warning: needsKeyAction
                    ? macGatewayL("云端已保存旧模型 Key：切换地址需携带本机 Key，否则云端会拒绝该更新")
                    : nil
            ))
        }
        for search in selectedSearches {
            let remoteConfigured = search.cloudSources.contains { source in
                remote?.search.first { $0.type == source }?.keyConfigured == true
            }
            let remoteEnabled = search.cloudSources.contains { remote?.searchSources.contains($0) == true }
            entries.append(IOSCloudImportPreviewEntry(
                section: .search,
                title: search.name,
                detail: search.cloudSources.map(IOSCloudConfigWire.sourceDisplayName(for:)).joined(separator: "、"),
                replacesRemote: remoteConfigured || remoteEnabled,
                includesSecret: search.requiresKey && search.hasApiKey,
                sourceId: search.serviceId,
                warning: nil
            ))
        }
        return entries
    }

    /// The contract's default-address normalization: an empty baseUrl resolves
    /// to the protocol default before comparing destinations.
    private func effectiveBaseUrl(_ provider: String, _ baseUrl: String) -> String {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return provider.lowercased() == "claude" ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1"
    }
}

// MARK: - Bundle (plaintext payload assembled at confirm time; sealed before upload)

/// The semantic content the user approved to send. Secrets live only here, in
/// memory, between the confirm action and the transport's seal step — they are
/// never persisted, logged, or sent to chat/agent inputs.
struct IOSCloudConfigBundle: Equatable, Sendable {
    /// Credential mutation matching the contract's `CredentialMutation`:
    /// replace carries a non-empty value; delete is explicit and value-less;
    /// absent keeps the cloud's current key.
    enum CredentialAction: Equatable, Sendable {
        case keep
        case replace(String)
        case delete
    }

    struct ModelSection: Equatable, Sendable {
        /// Contract provider kind: "openai" / "claude".
        var providerKind: String
        var modelId: String
        /// Empty baseUrl uses the provider protocol's default address.
        var baseUrl: String
        var credential: CredentialAction
    }

    struct SearchEntry: Equatable, Sendable {
        /// Local serial type ("exa" / "brave" / "bing_local") or a cloud source
        /// name — `cloudSources` normalizes both onto the contract whitelist.
        var type: String
        var name: String
        var enabled: Bool
        var credential: CredentialAction
        /// Import selections join `search.sources`; a manual key-only update
        /// leaves the cloud's source list untouched (credential action only).
        var includeInConfiguration: Bool = true

        var cloudSources: [String] { IOSCloudConfigWire.cloudSources(forLocalType: type) }
    }

    var model: ModelSection?
    var search: [SearchEntry]
    /// Ordered sources appended after the selected services' mapped sources
    /// (the contract's free whitelist only: bing/duckduckgo).
    var freeSources: [String]
    /// Standalone credential actions keyed by contract credential name
    /// ("modelApiKey"/"exaApiKey"/"braveApiKey") — e.g. the explicit delete
    /// button; not tied to any configuration patch.
    var extraCredentials: [String: CredentialAction] = [:]

    /// True when nothing would change on the cloud — the UI keeps the confirm
    /// button disabled rather than sending an empty apply.
    var isEmpty: Bool { model == nil && search.isEmpty && extraCredentials.isEmpty }
}

// MARK: - Payload encoding (ConfigurationEnvelopePayload on the wire)

extension IOSCloudConfigBundle {
    /// Ordered cloud search sources: selected services' mapped sources first,
    /// then enabled built-in free sources; duplicates removed, order kept.
    var cloudSearchSources: [String] {
        var ordered: [String] = []
        for entry in search where entry.enabled && entry.includeInConfiguration {
            for source in entry.cloudSources where !ordered.contains(source) {
                ordered.append(source)
            }
        }
        for source in freeSources where ["bing", "duckduckgo"].contains(source) && !ordered.contains(source) {
            ordered.append(source)
        }
        return ordered
    }

    /// Strategy sent with the sources list. The contract requires "fallback" or
    /// "aggregate"; order is already the policy, so a multi-source list fails
    /// over in order while a single source has nothing to aggregate.
    var cloudSearchMode: String { "fallback" }

    /// Contract `ConfigurationPatch`: nil sections stay unchanged server-side.
    /// An empty source list can't be expressed (422), so "no search selected"
    /// means "leave the cloud's search config alone" rather than "clear it".
    var configurationPatch: IOSCloudConfigPayload.Configuration? {
        let modelSection = model.map {
            IOSCloudConfigPayload.Model(provider: $0.providerKind, modelId: $0.modelId, baseUrl: $0.baseUrl)
        }
        let sources = cloudSearchSources
        let searchSection = (search.isEmpty || sources.isEmpty)
            ? nil
            : IOSCloudConfigPayload.Search(sources: sources, mode: cloudSearchMode)
        guard modelSection != nil || searchSection != nil else { return nil }
        return IOSCloudConfigPayload.Configuration(model: modelSection, search: searchSection)
    }

    /// Contract `CredentialPatch`: only explicit replace/delete actions appear;
    /// keep sends nothing so the cloud retains its current key. Standalone
    /// `extraCredentials` take precedence over the entry-driven ones.
    var credentialPatch: IOSCloudConfigPayload.Credentials? {
        var credentials = IOSCloudConfigPayload.Credentials()
        if let model {
            credentials.modelApiKey = mutation(model.credential)
        }
        for entry in search {
            for source in entry.cloudSources {
                guard let key = IOSCloudConfigWire.credentialKey(for: source),
                      let action = mutation(entry.credential) else { continue }
                switch key {
                case "exaApiKey": credentials.exaApiKey = action
                case "braveApiKey": credentials.braveApiKey = action
                default: break
                }
            }
        }
        for (key, action) in extraCredentials {
            guard let mutation = mutation(action) else { continue }
            switch key {
            case "modelApiKey": credentials.modelApiKey = mutation
            case "exaApiKey": credentials.exaApiKey = mutation
            case "braveApiKey": credentials.braveApiKey = mutation
            default: break // contract whitelist — unknown keys are never sent
            }
        }
        return credentials.isEmpty ? nil : credentials
    }

    private func mutation(_ action: CredentialAction) -> IOSCloudConfigPayload.Mutation? {
        switch action {
        case .keep: return nil
        case .replace(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : IOSCloudConfigPayload.Mutation(action: "replace", value: trimmed)
        case .delete: return IOSCloudConfigPayload.Mutation(action: "delete", value: nil)
        }
    }

    /// Stable hash of the wire-level operation (configuration + credentials),
    /// mirroring the server's idempotency key. Retries of the same semantic
    /// operation reuse the same requestId; a changed selection gets a fresh one.
    var operationKey: String {
        struct Operation: Encodable {
            var configuration: IOSCloudConfigPayload.Configuration?
            var credentials: IOSCloudConfigPayload.Credentials?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Operation(configuration: configurationPatch, credentials: credentialPatch))
        else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// `ConfigurationEnvelopePayload` — the plaintext encrypted inside the JWE.
/// Secrets appear only inside `credentials` values and only exist in memory.
struct IOSCloudConfigPayload: Encodable {
    struct Model: Encodable { var provider: String; var modelId: String; var baseUrl: String }
    struct Search: Encodable { var sources: [String]; var mode: String }
    struct Configuration: Encodable { var model: Model?; var search: Search? }
    struct Mutation: Encodable {
        var action: String
        /// Omitted entirely on keep/delete — delete must not carry a value.
        var value: String?
    }
    struct Credentials: Encodable {
        var modelApiKey: Mutation?
        var exaApiKey: Mutation?
        var braveApiKey: Mutation?
        var isEmpty: Bool { modelApiKey == nil && exaApiKey == nil && braveApiKey == nil }
    }

    var version = 1
    var gatewayId: String
    var deviceId: String
    var requestId: String
    var expectedRevision: Int
    var issuedAt: Int64
    var expiresAt: Int64
    var configuration: Configuration?
    var credentials: Credentials?
}

extension IOSCloudImportDraft {
    /// Materializes the selected configuration, resolving credentials at the
    /// explicit user action. `apiKey` values come from the already-rehydrated
    /// in-memory snapshot (loaded from the Keychain side-table); callers must
    /// not persist or log the returned bundle.
    func bundle(using sharedSettings: IOSSharedSettingsStore) -> IOSCloudConfigBundle {
        var modelSection: IOSCloudConfigBundle.ModelSection?
        if let provider = selectedProvider, let model = selectedModel,
           let setting = sharedSettings.snapshot.providers.first(where: { $0.id.description() == provider.providerId }) {
            let apiKey = ChatProviderConfiguration.apiKey(of: setting)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            modelSection = IOSCloudConfigBundle.ModelSection(
                providerKind: provider.kind.rawValue,
                modelId: model.modelId,
                baseUrl: provider.baseUrl,
                credential: apiKey.isEmpty ? .keep : .replace(apiKey)
            )
        }
        let searchEntries = selectedSearches.map { item -> IOSCloudConfigBundle.SearchEntry in
            let service = sharedSettings.snapshot.searchServices.first { $0.id.description() == item.serviceId }
            let apiKey = service.map(Self.searchApiKey(of:))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return IOSCloudConfigBundle.SearchEntry(
                type: item.typeLabel,
                name: item.name,
                enabled: true,
                credential: apiKey.isEmpty ? .keep : .replace(apiKey)
            )
        }
        return IOSCloudConfigBundle(
            model: modelSection,
            search: searchEntries,
            freeSources: freeSources
        )
    }

    private static func searchApiKey(of service: SearchServiceOptions) -> String {
        if let service = service as? SearchServiceOptions.ZhipuOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.TavilyOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.ExaOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.LinkUpOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.BraveOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.SerperOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.SerpApiOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.MetasoOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.OllamaOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.PerplexityOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.FirecrawlOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.JinaOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.BochaOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.AmberAgentSearchOptions { return service.apiKey }
        if let service = service as? SearchServiceOptions.GrokOptions { return service.apiKey }
        return ""
    }
}

// MARK: - Pending operation (requestId lifecycle)

/// Idempotency state for one in-flight cloud-config operation, owned by
/// `MacGatewayStore`. A successful receipt *finishes* the operation — the next
/// submit, even with identical content, is a new operation with a fresh id so
/// the server applies it instead of replaying the old receipt. A retry whose
/// result is unknown (network drop, timeout, unreadable response) keeps the
/// pending id: the server merges the same semantic operation or answers its
/// stored receipt rather than applying twice.
struct IOSCloudPendingOperation: Equatable, Sendable {
    private(set) var operationKey: String?
    private(set) var requestId: String?

    /// The id to send for this operation: the pending id while the same
    /// operation retries, otherwise a fresh UUID for a new operation.
    mutating func requestId(forOperationKey key: String) -> String {
        if operationKey == key, let requestId { return requestId }
        let id = UUID().uuidString
        operationKey = key
        requestId = id
        return id
    }

    /// Terminal receipt received (applied or replayed) — the operation is over.
    mutating func finish() {
        operationKey = nil
        requestId = nil
    }
}

// MARK: - Wire seam (contract: docs/architecture/cloud-configuration-api.md)

/// Transport for the cloud configuration API over the paired HTTPS/SPKI
/// channel. Implemented by `IOSCloudConfigClient` on the paired
/// `MacGatewayClient`; secrets are sealed into the contract's JWE before any
/// network send, and requestId/idempotency semantics live in
/// `MacGatewayStore.applyCloudBundle`.
protocol IOSCloudConfigTransport: Sendable {
    /// Current cloud configuration (non-secret view; `keyConfigured` flags only).
    func fetchCloudConfiguration() async throws -> IOSCloudConfigSnapshot
    /// Seals the bundle's secrets in memory and uploads over the pinned pairing.
    /// The caller supplies both idempotency anchors: `requestId` (same semantic
    /// operation reuses it, a changed selection uses a fresh one) and
    /// `expectedRevision` — the revision the user actually reviewed, never a
    /// POST-time refetch that would silently authorize a stale draft. Revision
    /// conflicts surface as `IOSCloudConfigError.revisionConflict` so drafts
    /// survive and the store can refresh.
    func applyCloudConfiguration(_ bundle: IOSCloudConfigBundle, requestId: String, expectedRevision: Int) async throws -> IOSCloudConfigApplyReceipt
}
