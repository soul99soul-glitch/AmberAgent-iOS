import Foundation
import Observation
@preconcurrency import Shared

@Observable @MainActor
final class DeepReadSettingsStore {
    var models: [DeepReadModelConfiguration] = []
    var selectedModelID: UUID?
    var searchServices: [DeepReadSearchConfiguration] = [DeepReadSearchConfiguration()]
    var selectedSearchID: UUID?
    var resultSize = 10
    var searchBuiltinDuckDuckGoEnabled = true
    var searchBuiltinBingEnabled = true
    var searchBuiltinJinaEnabled = true
    var searchBuiltinWikipediaEnabled = true
    var searchBuiltinHackerNewsEnabled = true
    var searchGoogleWebViewFallbackEnabled = true
    var fontScale = 1.0
    var fontMode = "serif"
    var templateId = DeepReadSynthesisTemplate.auto.id
    private(set) var errorMessage: String?
    private(set) var searchSettings: Settings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DeepReadCredentialStorage
    @ObservationIgnored private var credentialLoadFailed = false
    @ObservationIgnored private var credentialRevision = UUID().uuidString
    static let persistenceKey = "deepread.settings.v1"

    init(defaults: UserDefaults = UserDefaults(suiteName: "app.amber.deepread.settings")!,
         credentials: any DeepReadCredentialStorage = DeepReadKeychainStorage()) {
        self.defaults = defaults
        self.credentials = credentials
        searchSettings = IosSettingsDefaults.shared.defaultSeededSettings()
        if let data = defaults.data(forKey: Self.persistenceKey) {
            do { apply(try JSONDecoder().decode(Persisted.self, from: data)) }
            catch { errorMessage = "设置读取失败：\(error.localizedDescription)" }
        }
        if selectedSearchID == nil { selectedSearchID = searchServices.first?.id }
        reloadCredentials()
        do { searchSettings = try buildSharedSettings() }
        catch { errorMessage = "搜索配置读取失败：\(error.localizedDescription)" }
    }

    var resolvedModel: (model: Model, provider: ProviderSetting)? {
        guard let selectedModelID else { return nil }
        let provider = searchSettings.providers.first {
            $0.id.description().lowercased() == selectedModelID.uuidString.lowercased()
        }
        guard let provider, provider.enabled, let model = provider.models.first else { return nil }
        if let openAI = provider as? ProviderSetting.OpenAI, openAI.apiKey.isEmpty { return nil }
        if let claude = provider as? ProviderSetting.Claude, claude.apiKey.isEmpty { return nil }
        return (model, provider)
    }

    func reloadCredentials() {
        let retrying = credentialLoadFailed
        credentialLoadFailed = false
        do {
            var loadedModels = models
            var loadedSearch = searchServices
            for index in loadedModels.indices {
                loadedModels[index].apiKey = try credentials.read(account: "\(credentialRevision).model.\(loadedModels[index].id)") ?? ""
            }
            for index in loadedSearch.indices {
                let id = loadedSearch[index].id
                loadedSearch[index].apiKey = try credentials.read(account: "\(credentialRevision).search.\(id)") ?? ""
                loadedSearch[index].password = try credentials.read(account: "\(credentialRevision).search.password.\(id)") ?? ""
            }
            if loadedModels != models { models = loadedModels }
            if loadedSearch != searchServices { searchServices = loadedSearch }
            // A successful retry must also refresh what generation reads, not just hide the error.
            if retrying, let rebuilt = try? buildSharedSettings() {
                searchSettings = rebuilt
                errorMessage = nil
            }
        } catch {
            credentialLoadFailed = true
            errorMessage = "凭据读取失败，请重试读取后再保存：\(error.localizedDescription)"
        }
    }

    @discardableResult func save() -> Bool {
        guard !credentialLoadFailed else { return false }
        let nextRevision = UUID().uuidString
        var stagedAccounts: [String] = []
        do {
            for model in models {
                guard let url = URL(string: model.baseURL), url.scheme == "https" || url.scheme == "http",
                      url.host != nil, !model.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationError.invalidModel(model.name)
                }
            }
            guard (1...50).contains(resultSize), (0.7...1.8).contains(fontScale) else {
                throw ConfigurationError.invalidRange
            }
            let snapshot = try buildSharedSettings()
            var saved = Persisted(store: self)
            saved.credentialRevision = nextRevision
            let persisted = try JSONEncoder().encode(saved)
            let previous = defaults.data(forKey: Self.persistenceKey).flatMap {
                try? JSONDecoder().decode(Persisted.self, from: $0)
            }
            // Stage credentials under a new revision. A failed multi-key write must
            // not change the credentials used by the previously saved configuration.
            for model in models {
                let account = "\(nextRevision).model.\(model.id)"
                try credentials.write(model.apiKey, account: account)
                stagedAccounts.append(account)
            }
            for service in searchServices {
                for (name, value) in [("search", service.apiKey), ("search.password", service.password)] {
                    let account = "\(nextRevision).\(name).\(service.id)"
                    try credentials.write(value, account: account)
                    stagedAccounts.append(account)
                }
            }
            defaults.set(persisted, forKey: Self.persistenceKey)
            credentialRevision = nextRevision
            searchSettings = snapshot
            errorMessage = nil
            if let previous {
                for account in previous.credentialAccounts {
                    do { try credentials.write("", account: account) }
                    catch { errorMessage = "设置已保存，但清理旧凭据失败：\(error.localizedDescription)" }
                }
            }
            return true
        } catch {
            errorMessage = "设置未保存：\(error.localizedDescription)"
            for account in stagedAccounts {
                do { try credentials.write("", account: account) }
                catch { errorMessage = "设置未保存，且清理临时凭据失败：\(error.localizedDescription)" }
            }
            return false
        }
    }

    private func buildSharedSettings() throws -> Settings {
        let providers: [[String: Any]] = models.map { model in
            var provider: [String: Any] = [
                "type": model.protocolType == .openAI ? "openai" : "claude",
                "id": model.id.uuidString.lowercased(), "enabled": model.enabled, "name": model.name,
                "apiKey": model.apiKey, "baseUrl": model.baseURL,
                "models": [["id": model.id.uuidString.lowercased(), "modelId": model.modelID,
                            "displayName": model.modelID, "type": "CHAT"]]
            ]
            if model.protocolType == .openAI {
                provider["authMode"] = "api_key"
                provider["brand"] = "generic"
                provider["chatCompletionsPath"] = model.chatCompletionsPath
                provider["useResponseApi"] = model.useResponsesAPI
            } else { provider["promptCaching"] = model.promptCaching }
            return provider
        }
        let services: [[String: Any]] = searchServices.map { service in
            var json: [String: Any] = ["type": service.kind.rawValue,
                                      "id": service.id.uuidString.lowercased()]
            if service.kind != .bingLocal { json["apiKey"] = service.apiKey }
            for (key, value) in service.fields where !value.isEmpty {
                if ["maxTokens", "maxTokensPerPage"].contains(key) {
                    if let integer = Int(value) { json[key] = integer }
                } else if key == "summary" { json[key] = value == "true" }
                else { json[key] = value }
            }
            if service.kind == .searxng { json["password"] = service.password }
            return json
        }
        let json: [String: Any] = [
            "providers": providers, "assistants": [], "searchServices": services,
            "searchCommonOptions": ["resultSize": resultSize],
            "searchServiceSelected": searchServices.firstIndex { $0.id == selectedSearchID } ?? 0,
            "searchEnabledServiceIds": searchServices.filter(\.enabled).map { $0.id.uuidString.lowercased() },
            "searchBuiltinDuckDuckGoEnabled": searchBuiltinDuckDuckGoEnabled,
            "searchBuiltinBingEnabled": searchBuiltinBingEnabled,
            "searchBuiltinJinaEnabled": searchBuiltinJinaEnabled,
            "searchBuiltinWikipediaEnabled": searchBuiltinWikipediaEnabled,
            "searchBuiltinHackerNewsEnabled": searchBuiltinHackerNewsEnabled,
            "searchGoogleWebViewFallbackEnabled": searchGoogleWebViewFallbackEnabled
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try IosSettingsJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
    }

    private struct Persisted: Codable {
        var models: [DeepReadModelConfiguration]
        var selectedModelID: UUID?
        var searchServices: [DeepReadSearchConfiguration]
        var selectedSearchID: UUID?
        var resultSize: Int
        var duckDuckGo: Bool, bing: Bool, jina: Bool, wikipedia: Bool, hackerNews: Bool, google: Bool
        var fontScale: Double, fontMode: String, templateId: String
        var credentialRevision: String
        var credentialAccounts: [String] {
            models.map { "\(credentialRevision).model.\($0.id)" } + searchServices.flatMap {
                ["\(credentialRevision).search.\($0.id)", "\(credentialRevision).search.password.\($0.id)"]
            }
        }
        @MainActor init(store: DeepReadSettingsStore) {
            models = store.models; selectedModelID = store.selectedModelID
            searchServices = store.searchServices; selectedSearchID = store.selectedSearchID
            resultSize = store.resultSize
            duckDuckGo = store.searchBuiltinDuckDuckGoEnabled; bing = store.searchBuiltinBingEnabled
            jina = store.searchBuiltinJinaEnabled; wikipedia = store.searchBuiltinWikipediaEnabled
            hackerNews = store.searchBuiltinHackerNewsEnabled; google = store.searchGoogleWebViewFallbackEnabled
            fontScale = store.fontScale; fontMode = store.fontMode; templateId = store.templateId
            credentialRevision = store.credentialRevision
        }
    }

    private func apply(_ saved: Persisted) {
        models = saved.models; selectedModelID = saved.selectedModelID
        searchServices = saved.searchServices; selectedSearchID = saved.selectedSearchID
        resultSize = saved.resultSize
        searchBuiltinDuckDuckGoEnabled = saved.duckDuckGo; searchBuiltinBingEnabled = saved.bing
        searchBuiltinJinaEnabled = saved.jina; searchBuiltinWikipediaEnabled = saved.wikipedia
        searchBuiltinHackerNewsEnabled = saved.hackerNews; searchGoogleWebViewFallbackEnabled = saved.google
        fontScale = saved.fontScale; fontMode = saved.fontMode; templateId = saved.templateId
        credentialRevision = saved.credentialRevision
    }

    private enum ConfigurationError: LocalizedError {
        case invalidModel(String), invalidRange
        var errorDescription: String? {
            switch self {
            case .invalidModel(let name): "请检查 \(name) 的服务地址和模型 ID。"
            case .invalidRange: "搜索结果数量或字号超出允许范围。"
            }
        }
    }
}
