import Foundation

// MARK: - Jev Phase 1 settings
//
// 独立版本化 Codable 设置。非凭据配置进 UserDefaults（经 IOSSharedSettingsStore
// 持久化）；API Key 走 IOSCredentialSideTable（Keychain），绝不写进这里。
// 旧配置（无该 key）默认全用途 off。Jev 不进入普通聊天 provider/模型列表。

/// Jev 用途。五个用途均已接线（工具发现/记忆召回 = Phase 1，上下文筛选 =
/// Phase 2，模型调度/网页操作 = Phase 3）；设置页展示全部五个开关，
/// webActions 的调用入口是 wm_run_goal 工具。
enum IOSJevUseCase: String, Codable, CaseIterable, Identifiable {
    case toolDiscovery
    case memoryRecall
    case contextSelection
    case modelRouting
    case webActions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toolDiscovery: "工具发现"
        case .memoryRecall: "记忆召回"
        case .contextSelection: "上下文筛选"
        case .modelRouting: "模型调度"
        case .webActions: "网页操作"
        }
    }

    /// 该用途需要外发的数据范围（Phase 1 实际使用的只有前两类）。
    var defaultDataScopes: Set<IOSJevDataScope> {
        switch self {
        case .toolDiscovery: [.toolMetadata, .selectedTaskText]
        case .memoryRecall: [.selectedTaskText, .personalMemory]
        case .contextSelection: [.selectedTaskText, .toolOutput]
        case .modelRouting: [.selectedTaskText]
        case .webActions: [.webContent, .selectedTaskText]
        }
    }
}

/// 每用途三模式。shadow 同样把允许外发的数据发给 TypeSafe，只是不应用结果。
enum IOSJevMode: String, Codable, CaseIterable, Identifiable {
    case off
    case shadow
    case active

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "关闭"
        case .shadow: "Shadow"
        case .active: "启用"
        }
    }

    var detail: String {
        switch self {
        case .off: "不联网，走本地流程。"
        case .shadow: "发送数据只观测，不应用。"
        case .active: "应用判断，失败即回退。"
        }
    }
}

/// 数据外发范围。请求需要的范围全部允许才发送。
enum IOSJevDataScope: String, Codable, CaseIterable, Identifiable {
    case toolMetadata
    case selectedTaskText
    case personalMemory
    case toolOutput
    case webContent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toolMetadata: "工具目录元数据"
        case .selectedTaskText: "当前任务文本"
        case .personalMemory: "个人记忆内容"
        case .toolOutput: "文件 / 工具输出"
        case .webContent: "网页内容"
        }
    }
}

/// Jev 出站的 API 调用形态。默认 TypeSafe 原生 systemone 契约；
/// vercelGateway 走 Vercel AI Gateway 的 evaluation-model 契约（模型为
/// provider/model slug，默认 typesafe-ai/jev；同一个 Key 字段承载
/// AI_GATEWAY_API_KEY）。注意 Gateway 的 evaluation 不经 OpenAI 兼容端点。
enum IOSJevAPIStyle: String, Codable, CaseIterable, Identifiable {
    case systemone
    case vercelGateway

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemone: "TypeSafe 原生"
        case .vercelGateway: "Vercel AI Gateway"
        }
    }

    /// runtime_status / 诊断用的稳定服务标识。
    var serviceIdentifier: String {
        switch self {
        case .systemone: "typesafe.systemone"
        case .vercelGateway: "vercel.ai_gateway"
        }
    }

    /// runtime_status JSON 里的 api_mode 值（snake_case，与用途键风格一致；
    /// 持久化 rawValue 维持 camelCase，不影响存量设置文件）。
    var statusValue: String {
        switch self {
        case .systemone: "systemone"
        case .vercelGateway: "vercel_gateway"
        }
    }

    /// API Key 输入框的服务名提示。
    var keyPlaceholder: String {
        switch self {
        case .systemone: "粘贴 TypeSafe API Key"
        case .vercelGateway: "粘贴 Vercel AI Gateway API Key"
        }
    }
}

/// Phase 1 内部策略阈值（版本化；调整需升级 policyVersion 并回到 shadow）。
/// v2：真实用量口径——一次长任务工具调用可达数百次，网页循环单目标几十至
/// 上百步，v1 的 6 次/轮、1000 次/日预算在真实负载下必然撞墙；预算保留为
/// 失控熔断，量级按「实践中不触发」放宽。
struct IOSJevPolicy: Codable, Equatable {
    /// 当前策略版本；存量低于该值的策略整体回默认（阈值无 UI 可编辑，重设无损）。
    static let currentPolicyVersion = 2

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policyVersion = try container.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 1
        deadlineMs = try container.decodeIfPresent(Int.self, forKey: .deadlineMs) ?? 1_200
        maxQuestions = try container.decodeIfPresent(Int.self, forKey: .maxQuestions) ?? 32
        maxCandidates = try container.decodeIfPresent(Int.self, forKey: .maxCandidates) ?? 64
        maxStateBytes = try container.decodeIfPresent(Int.self, forKey: .maxStateBytes) ?? 48 * 1_024
        maxRequestBytes = try container.decodeIfPresent(Int.self, forKey: .maxRequestBytes) ?? 64 * 1_024
        maxResponseBytes = try container.decodeIfPresent(Int.self, forKey: .maxResponseBytes) ?? 256 * 1_024
        perTurnRequestBudget = try container.decodeIfPresent(Int.self, forKey: .perTurnRequestBudget) ?? 2_000
        perTurnStateBudgetBytes = try container.decodeIfPresent(Int.self, forKey: .perTurnStateBudgetBytes) ?? 64 * 1_024 * 1_024
        dailyRequestBudget = try container.decodeIfPresent(Int.self, forKey: .dailyRequestBudget) ?? 100_000
        dailyRequestBodyBudgetBytes = try container.decodeIfPresent(Int.self, forKey: .dailyRequestBodyBudgetBytes) ?? 2 * 1_024 * 1_024 * 1_024
        toolDiscoveryMinScore = try container.decodeIfPresent(Double.self, forKey: .toolDiscoveryMinScore) ?? 1.0
        memoryRecallMinScore = try container.decodeIfPresent(Double.self, forKey: .memoryRecallMinScore) ?? 1.0
        contextSelectionMinScore = try container.decodeIfPresent(Double.self, forKey: .contextSelectionMinScore) ?? 1.0
        modelRoutingMinScore = try container.decodeIfPresent(Double.self, forKey: .modelRoutingMinScore) ?? 2.0
        cacheMaxEntries = try container.decodeIfPresent(Int.self, forKey: .cacheMaxEntries) ?? 128
        cacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 300
        cooldownFailureThreshold = try container.decodeIfPresent(Int.self, forKey: .cooldownFailureThreshold) ?? 3
        cooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 60
    }

    private enum CodingKeys: String, CodingKey {
        case policyVersion, deadlineMs, maxQuestions, maxCandidates, maxStateBytes
        case maxRequestBytes, maxResponseBytes, perTurnRequestBudget, perTurnStateBudgetBytes
        case dailyRequestBudget, dailyRequestBodyBudgetBytes, toolDiscoveryMinScore
        case memoryRecallMinScore, contextSelectionMinScore, modelRoutingMinScore
        case cacheMaxEntries, cacheTTLSeconds, cooldownFailureThreshold, cooldownSeconds
    }

    var policyVersion: Int = IOSJevPolicy.currentPolicyVersion
    /// 前台单次判断总 deadline（排队 + 网络 + 重试 + 解析），毫秒。
    var deadlineMs: Int = 1_200
    /// 单请求最多问题数。
    var maxQuestions: Int = 32
    /// 单请求最多候选。
    var maxCandidates: Int = 64
    /// state 上限（UTF-8 字节）。
    var maxStateBytes: Int = 48 * 1_024
    /// 请求体上限（UTF-8 字节）。
    var maxRequestBytes: Int = 64 * 1_024
    /// 响应体上限。
    var maxResponseBytes: Int = 256 * 1_024
    /// 单轮（每个 budget key）最多出站判断请求。熔断量级：覆盖长任务数百次
    /// 工具调用 × 每调用多个用途判断，实践中不触发。
    var perTurnRequestBudget: Int = 2_000
    /// 单轮累计 state 上限（字节）。
    var perTurnStateBudgetBytes: Int = 64 * 1_024 * 1_024
    /// App 日出站请求预算（熔断量级）。
    var dailyRequestBudget: Int = 100_000
    /// App 日累计请求体预算（字节）。
    var dailyRequestBodyBudgetBytes: Int = 2 * 1_024 * 1_024 * 1_024
    /// 工具发现：Jev 最低相关分（0-3 分量表）低于该值视为无足够候选，回退原搜索。
    var toolDiscoveryMinScore: Double = 1.0
    /// 记忆召回：单条候选 Noul/Score 低于该值不进入注入集合。
    var memoryRecallMinScore: Double = 1.0
    /// 上下文筛选：内容块 Score 低于该值且无保留信号时隐藏。
    var contextSelectionMinScore: Double = 1.0
    /// 模型调度：Score 达到该值（0-3 适配量表）才进入 Jev 首选集合。
    var modelRoutingMinScore: Double = 2.0
    /// 缓存条目上限（内存）。
    var cacheMaxEntries: Int = 128
    /// 缓存 TTL（秒）。
    var cacheTTLSeconds: Int = 300
    /// 连续暂时性失败次数达到该值后冷却。
    var cooldownFailureThreshold: Int = 3
    /// 冷却时长（秒）。
    var cooldownSeconds: Int = 60
}

/// 单条指标。默认不存业务原文，只存大小、耗时、结果与用量。
struct IOSJevMetricsRecord: Codable, Equatable, Sendable {
    var timestamp: Date
    var useCase: IOSJevUseCase
    var mode: IOSJevMode
    var modelVersion: String
    /// applied（active 应用）/ observed（shadow 记录）/ skipped / error。
    var outcome: String
    var latencyMs: Int
    var requestBytes: Int
    var responseBytes: Int
    var inputTokens: Int?
    var outputTokens: Int?
    /// 跳过 / 错误的简短原因码（非原文）。
    var reason: String?
    /// shadow/active 记录：Jev 建议的 top1 候选名（工具发现专用，属工具元数据）。
    var suggestedTop1: String?
    /// 同次判断的关键词路径 top1（对比 Jev 是否真的改变排序）。
    var keywordTop1: String?
}

/// 版本化 Jev 设置。revision 随每次更新递增，作为判断身份与缓存失效输入。
struct IOSJevSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    /// 连接测试与实验用 "jev-latest"；active 必须使用经过验收的固定版本。
    var pinnedModelVersion: String?
    /// 出站 API 调用形态（默认 TypeSafe 原生）。vercelGateway 时 endpoint 与
    /// 模型解析切换为 Vercel AI Gateway 契约，同一 Key 字段承载对应服务 Key。
    var apiStyle: IOSJevAPIStyle = .systemone
    /// vercelGateway 模式的评估模型 slug（provider/model，默认 typesafe-ai/jev——
    /// Jev 本体在 Gateway 上的 Model ID）。选择 vercel 形态且为空时由
    /// setAPIStyle 自动填入；显式清空 = 未配置：active 按 shadow 收口，
    /// 出站按 model_unspecified 跳过。
    var vercelModel: String = ""
    var modes: [IOSJevUseCase: IOSJevMode] = [:]
    var dataScopes: [IOSJevUseCase: Set<IOSJevDataScope>] = [:]
    var policy: IOSJevPolicy = IOSJevPolicy()

    static let productionEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Vercel AI Gateway evaluation 端点（@ai-sdk/gateway 契约，核对日期
    /// 2026-09-19）：模型走 ai-model-id header，body {state, questions}；
    /// evaluation 不经 /v1/chat/completions（jev 类模型不产文本输出）。
    static let vercelGatewayEndpoint = URL(string: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model")!
    /// vercelGateway 默认模型：Jev 本体在 Gateway 的 Model ID。
    static let vercelDefaultModel = "typesafe-ai/jev"

    /// 当前 apiStyle 的出站 endpoint。
    var resolvedEndpoint: URL {
        switch apiStyle {
        case .systemone: Self.productionEndpoint
        case .vercelGateway: Self.vercelGatewayEndpoint
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pinnedModelVersion = try container.decodeIfPresent(String.self, forKey: .pinnedModelVersion)
        // 未知 apiStyle（未来新增形态的旧版本读盘）宽容回退 systemone，
        // 与 modes/scopes 的未知值丢弃策略一致，不整份丢设置。
        apiStyle = (try? container.decodeIfPresent(IOSJevAPIStyle.self, forKey: .apiStyle)) ?? .systemone
        vercelModel = (try container.decodeIfPresent(String.self, forKey: .vercelModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModes = try container.decodeIfPresent([String: String].self, forKey: .modes) ?? [:]
        modes = Dictionary(uniqueKeysWithValues: rawModes.compactMap { key, value in
            guard let useCase = IOSJevUseCase(rawValue: key), let mode = IOSJevMode(rawValue: value) else { return nil }
            return (useCase, mode)
        })
        let rawScopes = try container.decodeIfPresent([String: [String]].self, forKey: .dataScopes) ?? [:]
        dataScopes = Dictionary(uniqueKeysWithValues: rawScopes.compactMap { key, values in
            guard let useCase = IOSJevUseCase(rawValue: key) else { return nil }
            return (useCase, Set(values.compactMap(IOSJevDataScope.init(rawValue:))))
        })
        policy = try container.decodeIfPresent(IOSJevPolicy.self, forKey: .policy) ?? IOSJevPolicy()
        // 策略版本迁移：低于 currentPolicyVersion 的存量策略整体回默认。
        // v1→v2 主要变化是预算量级（6→2000/轮，1000→100000/日）；阈值无 UI
        // 可编辑，重置只丢手工改过的值。
        if policy.policyVersion < IOSJevPolicy.currentPolicyVersion {
            policy = IOSJevPolicy()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(pinnedModelVersion, forKey: .pinnedModelVersion)
        try container.encode(apiStyle, forKey: .apiStyle)
        try container.encode(vercelModel, forKey: .vercelModel)
        // enum key 的字典会被 JSONEncoder 编成 array，必须转 String 键。
        try container.encode(
            Dictionary(uniqueKeysWithValues: modes.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: .modes
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: dataScopes.map { ($0.key.rawValue, $0.value.map(\.rawValue).sorted()) }),
            forKey: .dataScopes
        )
        try container.encode(policy, forKey: .policy)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, pinnedModelVersion, apiStyle, vercelModel
        case modes, dataScopes, policy
    }

    // MARK: - Queries

    func mode(for useCase: IOSJevUseCase) -> IOSJevMode {
        modes[useCase] ?? .off
    }

    func allowedScopes(for useCase: IOSJevUseCase) -> Set<IOSJevDataScope> {
        dataScopes[useCase] ?? []
    }

    /// 请求需要的范围全部允许才可发送。
    func canSend(useCase: IOSJevUseCase, required: Set<IOSJevDataScope>) -> Bool {
        allowedScopes(for: useCase).isSuperset(of: required)
    }

    /// active 需要固定模型版本；未验收（无 pinned 版本）时按 shadow 收口。
    /// vercelGateway 下模型 slug 由用户显式填写即为固定版本，空值按 shadow 收口。
    func effectiveMode(for useCase: IOSJevUseCase) -> IOSJevMode {
        let configured = mode(for: useCase)
        guard configured == .active else { return configured }
        switch apiStyle {
        case .systemone:
            guard let pinned = pinnedModelVersion, !pinned.isEmpty, pinned != "jev-latest" else {
                return .shadow
            }
        case .vercelGateway:
            guard !vercelModel.isEmpty else { return .shadow }
        }
        return .active
    }

    /// 当前 apiStyle 下实际出站的模型标识（shadow/active 共用；vercel 空模型
    /// 时返回空串，由协调器按 model_unspecified 跳过、不出网）。
    var activeModelVersion: String {
        switch apiStyle {
        case .systemone:
            if let pinned = pinnedModelVersion, !pinned.isEmpty { return pinned }
            return "jev-latest"
        case .vercelGateway:
            return vercelModel
        }
    }

    /// 当前 apiStyle 下模型是否已配置（runtime_status 的 model_configured）。
    var modelConfigured: Bool { !activeModelVersion.isEmpty }

    /// 手动固定/清除已验收模型版本（systemone 的 active 前提；vercel 的模型
    /// slug 即固定版本，不走这个字段）。空串/空白/浮动别名 jev-latest →
    /// 清除回未验收态（与 acceptVerifiedModelVersion 同口径，避免"存了但无效"）。
    mutating func setPinnedModelVersion(_ version: String?) {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        pinnedModelVersion = (trimmed?.isEmpty == false && trimmed != "jev-latest") ? trimmed : nil
        revision += 1
    }

    /// 连接测试验收：systemone 下把服务端报告的模型版本落为固定版本。
    /// 浮动别名（jev-latest）与空值不验收；vercel 的 slug 即固定版本无需此步。
    mutating func acceptVerifiedModelVersion(_ version: String?) {
        guard apiStyle == .systemone else { return }
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "jev-latest" else { return }
        pinnedModelVersion = trimmed
        revision += 1
    }

    mutating func setMode(_ mode: IOSJevMode, for useCase: IOSJevUseCase) {
        modes[useCase] = mode
        if dataScopes[useCase] == nil { dataScopes[useCase] = useCase.defaultDataScopes }
        revision += 1
    }

    mutating func setScopes(_ scopes: Set<IOSJevDataScope>, for useCase: IOSJevUseCase) {
        dataScopes[useCase] = scopes
        revision += 1
    }

    mutating func setAPIStyle(_ style: IOSJevAPIStyle) {
        apiStyle = style
        // 选 vercel 且模型为空时填默认 slug——用户只需配 Key；显式清空过
        // 的（vercelModel.isEmpty 且用户自己删的）也会被回填，因为空模型在
        // 本形态下无法出站，保留空值没有可用语义。
        if style == .vercelGateway, vercelModel.isEmpty {
            vercelModel = Self.vercelDefaultModel
        }
        revision += 1
    }

    mutating func setVercelModel(_ model: String) {
        vercelModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        revision += 1
    }

    /// 收紧数据范围或清 Key 时由 store 调用：revision 变化自然使缓存失效。
    mutating func bumpRevision() {
        revision += 1
    }
}

// MARK: - Metrics store（上限 7 天 / 5 MiB，可清除）

enum IOSJevMetricsStore {
    private static let key = "app.amber.ios.jevMetrics.v1"
    private static let maxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maxBytes = 5 * 1_024 * 1_024
    private static let maxCount = 2_000

    private static var defaults: UserDefaults { .standard }

    /// load→append→set 的读改写必须原子，否则并发 shadow 判断互相覆盖丢记录。
    private static let lock = NSLock()

    static func load(now: Date = Date()) -> [IOSJevMetricsRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(now: now)
    }

    private static func loadLocked(now: Date) -> [IOSJevMetricsRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([IOSJevMetricsRecord].self, from: data) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        return records.filter { $0.timestamp >= cutoff }
    }

    static func append(_ record: IOSJevMetricsRecord, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked(now: now)
        records.append(record)
        records = records.filter { $0.timestamp >= now.addingTimeInterval(-maxAgeSeconds) }
        if records.count > maxCount {
            records = Array(records.suffix(maxCount))
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        if data.count <= maxBytes {
            defaults.set(data, forKey: key)
            return
        }
        // 超 5 MiB：丢弃最旧一半后重写一次；仍超则放弃本轮记录。
        let trimmed = Array(records.suffix(records.count / 2))
        if let trimmedData = try? JSONEncoder().encode(trimmed), trimmedData.count <= maxBytes {
            defaults.set(trimmedData, forKey: key)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    struct Summary: Equatable {
        var todayRequests: Int
        var todayRequestBytes: Int
        var last24hApplied: Int
        var last24hFallback: Int
        /// 最近一次 error/skipped 记录的原因码（runtime_status 诊断面）。
        var lastErrorReason: String?
    }

    static func summary(now: Date = Date()) -> Summary {
        let records = load(now: now).filter { $0.outcome != "connection_test" }
        let dayStart = Calendar.current.startOfDay(for: now)
        let today = records.filter { $0.timestamp >= dayStart }
        let last24h = records.filter { $0.timestamp >= now.addingTimeInterval(-24 * 60 * 60) }
        // 回退/跳过 = 未应用的判断（skipped / error）——失败回退是主要回退形态。
        let lastErrorReason = last24h.reversed().first(where: {
            ($0.outcome == "error" || $0.outcome == "skipped") && $0.reason?.isEmpty == false
        })?.reason
        return Summary(
            todayRequests: today.count,
            todayRequestBytes: today.reduce(0) { $0 + $1.requestBytes },
            last24hApplied: last24h.filter { $0.outcome == "applied" }.count,
            last24hFallback: last24h.filter { $0.outcome != "applied" && $0.outcome != "observed" }.count,
            lastErrorReason: lastErrorReason
        )
    }
}
