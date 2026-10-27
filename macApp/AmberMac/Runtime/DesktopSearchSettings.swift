import Foundation
import Observation

enum DesktopSearchService: String, Codable, CaseIterable, Identifiable, Sendable {
    case free = "bing_local", tavily, exa, zhipu, brave, serper, serpapi, jina
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: "免费聚合搜索"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .zhipu: "智谱"
        case .brave: "Brave"
        case .serper: "Serper"
        case .serpapi: "SerpAPI"
        case .jina: "Jina"
        }
    }
    var credentialID: UUID {
        UUID(uuidString: "313cb8ac-0286-4ff1-9000-" + String(format: "%012d", Self.allCases.firstIndex(of: self)! + 1))!
    }
}

@MainActor @Observable final class DesktopSearchSettings {
    private(set) var service: DesktopSearchService
    private(set) var resultCount: Int
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore
    private struct Record: Codable { var service: DesktopSearchService; var resultCount: Int }

    init(defaults: UserDefaults = .standard,
        credentials: any DesktopCredentialStore = DesktopKeychain(service: "app.amber.mac.search")) {
        self.defaults = defaults; self.credentials = credentials
        let record = defaults.data(forKey: "desktop.search.v1").flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        service = record?.service ?? .free
        resultCount = min(10, max(1, record?.resultCount ?? 5))
    }

    func apiKey(for service: DesktopSearchService) throws -> String {
        service == .free ? "" : try credentials.load(id: service.credentialID)
    }

    func save(service: DesktopSearchService, resultCount: Int, apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service == .free || !key.isEmpty else { throw DesktopRuntimeError.message("请填写搜索服务的 API Key。") }
        guard (1...10).contains(resultCount) else { throw DesktopRuntimeError.message("搜索结果数量须为 1–10。") }
        if service != .free { try credentials.save(key, id: service.credentialID) }
        let record = Record(service: service, resultCount: resultCount)
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: "desktop.search.v1")
        self.service = service; self.resultCount = resultCount
    }

    // Credentials exist only in this request snapshot; persisted preferences and backups contain no key.
    func requestJSON() throws -> String {
        let id = service.credentialID.uuidString.lowercased()
        var provider: [String: Any] = ["type": service.rawValue, "id": id]
        if service != .free {
            let key = try apiKey(for: service)
            guard !key.isEmpty else { throw DesktopRuntimeError.message("搜索服务凭证不可用，请在搜索设置中重新保存。") }
            provider["apiKey"] = key
        }
        let object: [String: Any] = ["searchServices": [provider], "searchEnabledServiceIds": [id],
            "searchServiceSelected": 0, "searchCommonOptions": ["resultSize": resultCount],
            "searchGoogleWebViewFallbackEnabled": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
