import Foundation
import Observation
@preconcurrency import Shared

/// The standalone app's model and search configuration. It owns its own
/// UserDefaults suite and Keychain service and publishes the KMP `Settings`
/// snapshot the shared Novel runtime and search executor consume.
@Observable
final class NovelAppSettingsStore: IOSSettingsSnapshotSource {
    private(set) var services: [NovelModelService] = []
    private(set) var defaultModelID: UUID?
    private(set) var searchServices: [NovelSearchService] = [NovelSearchService()]
    private(set) var selectedSearchID: UUID?
    private(set) var resultSize = 8
    private(set) var webSearchEnabled = true
    /// Set when stored settings or keys could not be read at launch.
    private(set) var loadErrorMessage: String?

    @ObservationIgnored private(set) var snapshot: Settings
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any NovelCredentialStorage
    /// A save after a failed read would overwrite the real keys with blanks.
    @ObservationIgnored private var credentialReadFailed = false
    static let persistenceKey = "novel.settings.v1"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: "app.amber.novel.settings") ?? .standard,
        credentials: any NovelCredentialStorage = NovelKeychainStorage()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        snapshot = IosSettingsDefaults.shared.defaultSeededSettings()
        if let data = defaults.data(forKey: Self.persistenceKey) {
            do {
                apply(try JSONDecoder().decode(Persisted.self, from: data))
            } catch {
                loadErrorMessage = "设置读取失败：\(error.localizedDescription)"
            }
        }
        do {
            for index in services.indices {
                services[index].apiKey = try credentials.read(account: Self.modelAccount(services[index].id)) ?? ""
            }
            for index in searchServices.indices {
                searchServices[index].apiKey = try credentials.read(account: Self.searchAccount(searchServices[index].id)) ?? ""
            }
        } catch {
            credentialReadFailed = true
            loadErrorMessage = "密钥读取失败，设置暂不能修改。请重新打开应用后再试：\(error.localizedDescription)"
        }
        if selectedSearchID == nil { selectedSearchID = searchServices.first?.id }
        do {
            snapshot = try Self.buildSettings(
                services: services, defaultModelID: defaultModelID,
                searchServices: searchServices, selectedSearchID: selectedSearchID,
                resultSize: resultSize, webSearchEnabled: webSearchEnabled
            )
        } catch {
            loadErrorMessage = "设置读取失败：\(error.localizedDescription)"
        }
    }

    /// Reads `revision` so observing views refresh after a save.
    var hasUsableModel: Bool {
        _ = revision
        guard let model = snapshot.getCurrentChatModel(),
              let provider = ChatProviderConfiguration.provider(for: model, providers: snapshot.providers)
        else { return false }
        return ChatProviderConfiguration.issue(for: model, provider: provider) == nil
    }

    /// Validates, writes credentials, persists and republishes the snapshot.
    /// Returns the error message when nothing was saved.
    @discardableResult
    func save(
        services newServices: [NovelModelService],
        defaultModelID newDefault: UUID?,
        searchServices newSearch: [NovelSearchService],
        selectedSearchID newSelectedSearch: UUID?,
        resultSize newResultSize: Int,
        webSearchEnabled newWebSearch: Bool
    ) -> String? {
        guard !credentialReadFailed else {
            return loadErrorMessage
        }
        do {
            try Self.validate(services: newServices, resultSize: newResultSize)
            // A default inside a disabled service is unusable; fall back like a missing one.
            let enabledModelIDs = Set(newServices.filter(\.enabled).flatMap { $0.models.map(\.id) })
            let effectiveDefault = newDefault.flatMap { enabledModelIDs.contains($0) ? $0 : nil }
                ?? newServices.first(where: { $0.enabled && !$0.apiKey.isEmpty })?.models.first?.id
                ?? newServices.first(where: \.enabled)?.models.first?.id
            let next = try Self.buildSettings(
                services: newServices, defaultModelID: effectiveDefault,
                searchServices: newSearch, selectedSearchID: newSelectedSearch,
                resultSize: newResultSize, webSearchEnabled: newWebSearch
            )
            for service in newServices {
                try credentials.write(service.apiKey, account: Self.modelAccount(service.id))
            }
            for service in newSearch {
                try credentials.write(service.apiKey, account: Self.searchAccount(service.id))
            }
            let persisted = Persisted(
                services: newServices, defaultModelID: effectiveDefault,
                searchServices: newSearch, selectedSearchID: newSelectedSearch,
                resultSize: newResultSize, webSearchEnabled: newWebSearch
            )
            defaults.set(try JSONEncoder().encode(persisted), forKey: Self.persistenceKey)
            // Credentials of removed entries are no longer reachable; drop them.
            let keptModels = Set(newServices.map(\.id))
            for removed in services where !keptModels.contains(removed.id) {
                try? credentials.write("", account: Self.modelAccount(removed.id))
            }
            let keptSearch = Set(newSearch.map(\.id))
            for removed in searchServices where !keptSearch.contains(removed.id) {
                try? credentials.write("", account: Self.searchAccount(removed.id))
            }
            apply(persisted)
            services = newServices
            searchServices = newSearch
            snapshot = next
            revision += 1
            // A successful save replaces whatever could not be read at launch.
            loadErrorMessage = nil
            return nil
        } catch {
            return "设置未保存：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private static func modelAccount(_ id: UUID) -> String { "model.\(id.uuidString.lowercased())" }
    private static func searchAccount(_ id: UUID) -> String { "search.\(id.uuidString.lowercased())" }

    private static func validate(services: [NovelModelService], resultSize: Int) throws {
        for service in services {
            // Same rule the request path enforces, so a saved service is usable.
            guard IOSProviderEndpointPolicy.isValidBaseURL(service.resolvedBaseURL) else {
                throw ConfigurationError.invalidBaseURL(service.displayName)
            }
            guard !service.models.isEmpty,
                  service.models.allSatisfy({ !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ConfigurationError.missingModel(service.displayName)
            }
        }
        guard (1...20).contains(resultSize) else { throw ConfigurationError.invalidResultSize }
    }

    private static func buildSettings(
        services: [NovelModelService],
        defaultModelID: UUID?,
        searchServices: [NovelSearchService],
        selectedSearchID: UUID?,
        resultSize: Int,
        webSearchEnabled: Bool
    ) throws -> Settings {
        let providers: [[String: Any]] = services.map { service in
            var provider: [String: Any] = [
                "id": service.id.uuidString.lowercased(),
                "enabled": service.enabled,
                "name": service.displayName,
                "apiKey": service.apiKey,
                "baseUrl": service.resolvedBaseURL,
                "models": service.models.map { model -> [String: Any] in
                    let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    var json: [String: Any] = [
                        "id": model.id.uuidString.lowercased(),
                        "modelId": modelID,
                        "displayName": modelID,
                        "type": "CHAT",
                        "abilities": model.supportsReasoning ? ["TOOL", "REASONING"] : ["TOOL"]
                    ]
                    if let tokens = model.contextWindowTokens { json["contextWindowTokens"] = tokens }
                    return json
                }
            ]
            switch service.protocolType {
            case .openAI:
                provider["type"] = "openai"
                provider["authMode"] = "api_key"
                provider["brand"] = "generic"
                provider["chatCompletionsPath"] = "/chat/completions"
                provider["useResponseApi"] = service.useResponsesAPI
            case .claude:
                provider["type"] = "claude"
            case .gemini:
                provider["type"] = "google"
            }
            return provider
        }
        let search: [[String: Any]] = searchServices.map { service in
            var json: [String: Any] = ["type": service.kind.rawValue, "id": service.id.uuidString.lowercased()]
            if service.kind.needsAPIKey { json["apiKey"] = service.apiKey }
            return json
        }
        var json: [String: Any] = [
            "providers": providers,
            "enableWebSearch": webSearchEnabled,
            "searchServices": search,
            "searchCommonOptions": ["resultSize": resultSize],
            "searchServiceSelected": searchServices.firstIndex { $0.id == selectedSearchID } ?? 0,
            "searchEnabledServiceIds": searchServices.map { $0.id.uuidString.lowercased() }
        ]
        if let defaultModelID { json["chatModelId"] = defaultModelID.uuidString.lowercased() }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try IosSettingsJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
    }

    private struct Persisted: Codable {
        var services: [NovelModelService]
        var defaultModelID: UUID?
        var searchServices: [NovelSearchService]
        var selectedSearchID: UUID?
        var resultSize: Int
        var webSearchEnabled: Bool
    }

    private func apply(_ saved: Persisted) {
        services = saved.services
        defaultModelID = saved.defaultModelID
        searchServices = saved.searchServices.isEmpty ? [NovelSearchService()] : saved.searchServices
        selectedSearchID = saved.selectedSearchID
        resultSize = saved.resultSize
        webSearchEnabled = saved.webSearchEnabled
    }

    private enum ConfigurationError: LocalizedError {
        case invalidBaseURL(String), missingModel(String), invalidResultSize
        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let name): "「\(name)」的服务地址需为 https，或以 IP 地址访问的 http。"
            case .missingModel(let name): "「\(name)」至少需要一个模型 ID。"
            case .invalidResultSize: "搜索结果数量需在 1–20 之间。"
            }
        }
    }
}
