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
    var subtitle: String {
        switch self {
        case .free: "DuckDuckGo / Brave HTML / Bing / 百度 多引擎免费聚合，免 API Key"
        case .exa: "AI 原生神经检索：支持 auto/lite/deep、分类过滤、时间范围、正文高光与图片提取"
        case .tavily: "面向 Agent 的实时检索与摘要，支持图片结果"
        case .brave: "独立索引网页搜索，支持缩略图与高相关度网页结果"
        case .serper: "Google 搜索与新闻结果 API，支持图片链接"
        case .serpapi: "Google 搜索结果与新闻抓取 API"
        case .zhipu: "智谱 Web Search Pro 中文增强搜索"
        case .jina: "Jina Search 网页正文与摘要检索"
        }
    }
    var requiresAPIKey: Bool { self != .free }
    var credentialID: UUID {
        UUID(uuidString: "313cb8ac-0286-4ff1-9000-" + String(format: "%012d", Self.allCases.firstIndex(of: self)! + 1))!
    }
}

enum DesktopSearchExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sequentialFallback = "sequential"
    case parallel = "parallel"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sequentialFallback: "顺序兜底（推荐）"
        case .parallel: "多源并发"
        }
    }
    var subtitle: String {
        switch self {
        case .sequentialFallback: "按优先级依次尝试已启用搜索源，主源失败、超时或空结果时自动回退下一源"
        case .parallel: "同时请求所有已启用搜索源，合并去重结果并保留部分成功结果"
        }
    }
}

enum DesktopExaSearchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case lite = "lite"
    case deepLite = "deep-lite"
    case deep = "deep"
    case fast = "fast"
    case instant = "instant"
    case deepReasoning = "deep-reasoning"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto（智能默认）"
        case .lite: "Lite（极速缓存）"
        case .deepLite: "Deep Lite（轻量深度）"
        case .deep: "Deep（多步深度研究）"
        case .fast: "Fast（兼容快速）"
        case .instant: "Instant（兼容即时）"
        case .deepReasoning: "Deep Reasoning（兼容深度推理）"
        }
    }

    static var primaryCases: [DesktopExaSearchType] { [.auto, .lite, .deepLite, .deep] }
}

enum DesktopExaContentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case highlights = "highlights"
    case text = "text"
    case summary = "summary"
    case highlightsAndText = "highlights_and_text"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .highlights: "高光摘录（Highlights）"
        case .text: "网页全文（Text）"
        case .summary: "智能摘要（Summary）"
        case .highlightsAndText: "高光 + 全文"
        }
    }
}

struct DesktopExaOptions: Codable, Equatable, Sendable {
    var searchType: DesktopExaSearchType = .auto
    var contentMode: DesktopExaContentMode = .highlights
    var includeImages: Bool = true
    var imageLinksCount: Int = 3
    var maxAgeHours: Int? = nil

    init(
        searchType: DesktopExaSearchType = .auto,
        contentMode: DesktopExaContentMode = .highlights,
        includeImages: Bool = true,
        imageLinksCount: Int = 3,
        maxAgeHours: Int? = nil
    ) {
        self.searchType = searchType
        self.contentMode = contentMode
        self.includeImages = includeImages
        self.imageLinksCount = min(10, max(0, imageLinksCount))
        self.maxAgeHours = maxAgeHours
    }
}

@MainActor @Observable final class DesktopSearchSettings {
    private(set) var service: DesktopSearchService
    private(set) var resultCount: Int
    private(set) var enabledServices: [DesktopSearchService]
    private(set) var serviceOrder: [DesktopSearchService]
    private(set) var executionMode: DesktopSearchExecutionMode
    private(set) var exaOptions: DesktopExaOptions
    /// True once the user has explicitly saved a multi-source configuration (allowing `enabledServices` to be intentionally empty).
    private(set) var explicitlyConfigured: Bool

    /// Same 1...50 range as iOS/Android settings.
    nonisolated static let resultLimit = 50
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore

    private struct Record: Codable {
        var service: DesktopSearchService
        var resultCount: Int
        var enabledServices: [DesktopSearchService]?
        var serviceOrder: [DesktopSearchService]?
        var executionMode: DesktopSearchExecutionMode?
        var exaOptions: DesktopExaOptions?
        var explicitlyConfigured: Bool?
    }

    init(
        defaults: UserDefaults = .standard,
        credentials: any DesktopCredentialStore = DesktopKeychain(service: "app.amber.mac.search")
    ) {
        self.defaults = defaults
        self.credentials = credentials
        let record = defaults.data(forKey: "desktop.search.v1").flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let primary = record?.service ?? .free
        let order = Self.normalizedOrder(record?.serviceOrder ?? [primary])
        let explicit = record?.explicitlyConfigured ?? false
        let enabled: [DesktopSearchService]
        if let savedEnabled = record?.enabledServices {
            enabled = Self.orderedEnabled(savedEnabled, within: order)
        } else {
            enabled = [primary]
        }
        let resolvedEnabled = explicit ? enabled : (enabled.isEmpty ? [primary] : enabled)
        self.serviceOrder = order
        self.enabledServices = resolvedEnabled
        self.service = resolvedEnabled.first ?? primary
        self.resultCount = min(Self.resultLimit, max(1, record?.resultCount ?? 5))
        self.executionMode = record?.executionMode ?? .sequentialFallback
        self.exaOptions = record?.exaOptions ?? DesktopExaOptions()
        self.explicitlyConfigured = explicit
    }

    func apiKey(for service: DesktopSearchService) throws -> String {
        service == .free ? "" : try credentials.load(id: service.credentialID)
    }

    func hasAPIKey(for service: DesktopSearchService) -> Bool {
        guard service.requiresAPIKey else { return true }
        let key = (try? apiKey(for: service))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    /// Legacy single-service save entrypoint (preserved for existing callers and unit tests).
    func save(service: DesktopSearchService, resultCount: Int, apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service == .free || !key.isEmpty else {
            throw DesktopRuntimeError.message("请填写搜索服务的 API Key。")
        }
        guard (1...Self.resultLimit).contains(resultCount) else {
            throw DesktopRuntimeError.message("搜索结果数量须为 1–\(Self.resultLimit)。")
        }
        if service != .free {
            try credentials.save(key, id: service.credentialID)
        }
        let order = Self.normalizedOrder([service] + serviceOrder)
        let enabled = [service]
        try persist(
            service: service,
            resultCount: resultCount,
            enabledServices: enabled,
            serviceOrder: order,
            executionMode: executionMode,
            exaOptions: exaOptions,
            explicitlyConfigured: true
        )
    }

    /// Multi-source save entrypoint supporting simultaneous sources, priority order, execution mode, and Exa options.
    func saveConfiguration(
        enabledServices: [DesktopSearchService],
        serviceOrder: [DesktopSearchService]? = nil,
        executionMode: DesktopSearchExecutionMode? = nil,
        resultCount: Int? = nil,
        exaOptions: DesktopExaOptions? = nil,
        apiKeys: [DesktopSearchService: String] = [:]
    ) throws {
        let count = resultCount ?? self.resultCount
        guard (1...Self.resultLimit).contains(count) else {
            throw DesktopRuntimeError.message("搜索结果数量须为 1–\(Self.resultLimit)。")
        }
        let order = Self.normalizedOrder(serviceOrder ?? (enabledServices + self.serviceOrder))
        let orderedEnabled = Self.orderedEnabled(enabledServices, within: order)

        // First validate that every enabled API-backed service will have a non-empty key before mutating state.
        var keysToSave: [(DesktopSearchService, String)] = []
        for (svc, rawKey) in apiKeys where svc.requiresAPIKey {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                keysToSave.append((svc, trimmed))
            }
        }
        let pendingMap = Dictionary(uniqueKeysWithValues: keysToSave)
        for svc in orderedEnabled where svc.requiresAPIKey {
            if let pending = pendingMap[svc], !pending.isEmpty { continue }
            let existing = (try? apiKey(for: svc))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !existing.isEmpty else {
                throw DesktopRuntimeError.message("请填写 \(svc.title) 的 API Key。")
            }
        }

        for (svc, key) in keysToSave {
            try credentials.save(key, id: svc.credentialID)
        }

        let primary = orderedEnabled.first ?? order.first ?? .free
        try persist(
            service: primary,
            resultCount: count,
            enabledServices: orderedEnabled,
            serviceOrder: order,
            executionMode: executionMode ?? self.executionMode,
            exaOptions: exaOptions ?? self.exaOptions,
            explicitlyConfigured: true
        )
    }

    /// Removes a stored API key for a specific service from Keychain.
    func removeAPIKey(for service: DesktopSearchService) throws {
        guard service.requiresAPIKey else { return }
        try credentials.delete(id: service.credentialID)
    }

    // Credentials exist only in this request snapshot; persisted preferences and backups contain no key.
    func requestJSON() throws -> String {
        guard !enabledServices.isEmpty else {
            throw DesktopRuntimeError.message("未启用任何搜索服务，请在搜索设置中开启至少一个搜索源。")
        }
        var providers: [[String: Any]] = []
        var enabledIDs: [String] = []
        for svc in enabledServices {
            let id = svc.credentialID.uuidString.lowercased()
            var provider: [String: Any] = ["type": svc.rawValue, "id": id]
            if svc != .free {
                let key = try apiKey(for: svc).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    throw DesktopRuntimeError.message("搜索服务凭证不可用，请在搜索设置中重新保存。")
                }
                provider["apiKey"] = key
            }
            providers.append(provider)
            enabledIDs.append(id)
        }
        let object: [String: Any] = [
            "searchServices": providers,
            "searchEnabledServiceIds": enabledIDs,
            "searchServiceSelected": 0,
            "searchCommonOptions": ["resultSize": resultCount],
            "searchGoogleWebViewFallbackEnabled": false,
            "searchExecutionMode": executionMode.rawValue
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func persist(
        service: DesktopSearchService,
        resultCount: Int,
        enabledServices: [DesktopSearchService],
        serviceOrder: [DesktopSearchService],
        executionMode: DesktopSearchExecutionMode,
        exaOptions: DesktopExaOptions,
        explicitlyConfigured: Bool
    ) throws {
        let record = Record(
            service: service,
            resultCount: resultCount,
            enabledServices: enabledServices,
            serviceOrder: serviceOrder,
            executionMode: executionMode,
            exaOptions: exaOptions,
            explicitlyConfigured: explicitlyConfigured
        )
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: "desktop.search.v1")
        self.service = service
        self.resultCount = resultCount
        self.enabledServices = enabledServices
        self.serviceOrder = serviceOrder
        self.executionMode = executionMode
        self.exaOptions = exaOptions
        self.explicitlyConfigured = explicitlyConfigured
    }

    private static func normalizedOrder(_ candidate: [DesktopSearchService]) -> [DesktopSearchService] {
        var seen = Set<DesktopSearchService>()
        var output: [DesktopSearchService] = []
        for item in candidate where !seen.contains(item) {
            seen.insert(item)
            output.append(item)
        }
        let defaultPriority: [DesktopSearchService] = [.free, .exa, .tavily, .brave, .serper, .serpapi, .zhipu, .jina]
        for item in defaultPriority where !seen.contains(item) {
            seen.insert(item)
            output.append(item)
        }
        for item in DesktopSearchService.allCases where !seen.contains(item) {
            seen.insert(item)
            output.append(item)
        }
        return output
    }

    private static func orderedEnabled(_ enabled: [DesktopSearchService], within order: [DesktopSearchService]) -> [DesktopSearchService] {
        let enabledSet = Set(enabled)
        var seen = Set<DesktopSearchService>()
        var output: [DesktopSearchService] = []
        for item in order where enabledSet.contains(item) && !seen.contains(item) {
            seen.insert(item)
            output.append(item)
        }
        for item in enabled where !seen.contains(item) {
            seen.insert(item)
            output.append(item)
        }
        return output
    }
}
