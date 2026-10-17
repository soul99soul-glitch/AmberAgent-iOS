import Foundation
import UIKit

// MARK: - Jev Phase 1 settings
//
// 独立版本化 Codable 设置。非凭据配置进 UserDefaults（经 IOSSharedSettingsStore
// 持久化）；API Key 走 IOSCredentialSideTable（Keychain），绝不写进这里。
// 旧配置（无该 key）默认全用途 off。Jev 不进入普通聊天 provider/模型列表。

/// Jev 用途，均已接线（工具发现/记忆召回 = Phase 1，上下文筛选 = Phase 2，
/// 模型调度/网页操作 = Phase 3，意图路由 = 增强 Phase C，压缩保留/自动批准
/// 复核/完成校验 = v2）；手机用途分别由带验收条件的 phone_act 与 phone_run_goal 驱动。
enum IOSJevUseCase: String, Codable, CaseIterable, Identifiable, Sendable {
    // 声明顺序即设置页行与用量统计的展示顺序（持久化用 rawValue，与顺序无关）。
    case toolDiscovery
    case memoryRecall
    case contextSelection
    /// 旧工具结果移出保留窗口前，判断原文是否仍需保留（不清空）。
    case toolResultRetention
    case modelRouting
    case webActions
    case phoneVerification
    case phoneActions
    case subagentIntent
    case approvalTriage
    /// 自动批准生效时复核高风险调用，只会收紧为人工审批。
    case autoApprovalGate
    /// 本轮改过文件却未运行检查就宣称完成时，提示用户让助手验证。
    case completionCheck
    /// exec 脚本经 `jev` 全局主动调用（只有 active 才注入，shadow 对脚本无意义）。
    case scriptJudgment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toolDiscovery: "工具发现"
        case .memoryRecall: "记忆召回"
        case .contextSelection: "上下文筛选"
        case .modelRouting: "模型调度"
        case .webActions: "网页操作"
        case .phoneVerification: "手机效果检查"
        case .phoneActions: "手机快速操作"
        case .subagentIntent: "意图路由"
        case .approvalTriage: "审批分诊"
        case .scriptJudgment: "脚本判断"
        case .toolResultRetention: "压缩保留"
        case .autoApprovalGate: "自动批准复核"
        case .completionCheck: "完成校验"
        }
    }

    /// 该用途需要外发的数据范围；范围缺一项便不发送。
    var defaultDataScopes: Set<IOSJevDataScope> {
        switch self {
        case .toolDiscovery: [.toolMetadata, .selectedTaskText]
        case .memoryRecall: [.selectedTaskText, .personalMemory]
        case .contextSelection: [.selectedTaskText, .toolOutput]
        case .modelRouting: [.selectedTaskText, .modelMetadata]
        case .webActions: [.webContent, .selectedTaskText]
        case .phoneVerification, .phoneActions: [.selectedTaskText, .phoneContent]
        case .subagentIntent: [.selectedTaskText, .toolMetadata]
        case .approvalTriage: [.toolMetadata, .selectedTaskText]
        case .scriptJudgment: [.toolOutput]
        case .toolResultRetention: [.selectedTaskText, .toolOutput, .toolMetadata]
        case .autoApprovalGate: [.toolMetadata, .selectedTaskText]
        case .completionCheck: [.selectedTaskText, .toolMetadata]
        }
    }
}

/// 每用途三模式。shadow 同样把允许外发的数据发给 TypeSafe，只是不应用结果。
enum IOSJevMode: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum IOSJevDataScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case toolMetadata
    case modelMetadata
    case selectedTaskText
    case personalMemory
    case toolOutput
    case webContent
    case phoneContent
    case phoneScreenshots

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toolMetadata: "工具目录元数据"
        case .modelMetadata: "候选模型与服务商信息"
        case .selectedTaskText: "当前任务文本"
        case .personalMemory: "个人记忆内容"
        case .toolOutput: "文件 / 工具输出"
        case .webContent: "网页内容"
        case .phoneContent: "手机界面文字"
        case .phoneScreenshots: "手机屏幕截图（实验）"
        }
    }
}

/// Jev 同类决策模型的出站形态。
///
/// 同品类 = 送 state + 带类型问句（noul/choice/score），收回概率答案，不生成
/// 文本。可接入的服务差异只有三处：请求体契约（systemone 原生 / Vercel
/// Gateway 的 decision-model）、endpoint、模型 ID。三者都收在 `IOSJevProvider`
/// 注册表里，新增供应商 = 这里加一个 case + 注册表加一条；只有在遇到全新
/// 契约时才需要动客户端的编码分支。
enum IOSJevAPIStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// TypeSafe 原生 `POST /v1/systemone`（Jev）。
    case systemone
    /// Vercel AI Gateway 的 decision-model 契约，模型为 provider/model slug。
    case vercelGateway
    /// Perplexity Decisions API（`POST /v1/decisions`，pplx-decider 系列）。
    case perplexityDecisions
    /// Liquid AI decision models（`POST /decisions/v1/systemone`，d1 / d1-ultra）。
    case liquidSystemone

    var id: String { rawValue }

    var provider: IOSJevProvider { IOSJevProvider.for(self) }
    var displayName: String { provider.displayName }
    /// runtime_status / 诊断用的稳定服务标识。
    var serviceIdentifier: String { provider.serviceIdentifier }
    /// runtime_status JSON 里的 api_mode 值（snake_case，与用途键风格一致；
    /// 持久化 rawValue 维持 camelCase，不影响存量设置文件）。
    var statusValue: String { provider.statusValue }
    /// 模型输入框的占位提示。
    var modelPlaceholder: String { provider.modelPlaceholder }
    /// API Key 输入框的服务名提示。
    var keyPlaceholder: String { provider.keyPlaceholder }
    /// 请求体契约；决定客户端走哪条编码/解析分支。
    var contract: IOSJevProvider.Contract { provider.contract }
    /// box（图片定位）题型只有 TypeSafe 原生契约支持。
    var supportsBoxQuestions: Bool { provider.supportsBoxQuestions }
    /// 是否支持图片输入；新供应商未实现图片编码前不得下发 assets。
    var supportsImages: Bool { provider.supportsImages }
}

/// 一个可选供应商的静态描述。设置页列表、默认模型、endpoint、Key 提示、
/// 诊断标识都从这里取，避免散落在 UI 与客户端的 switch 里。
struct IOSJevProvider: Equatable, Sendable {
    /// 请求体契约。目前只有两种：TypeSafe 原生 schema，与 Vercel AI Gateway
    /// 的 @ai-sdk/gateway decision-model schema。
    enum Contract: String, Sendable {
        case systemone
        case vercelDecisionModel
    }

    var style: IOSJevAPIStyle
    var displayName: String
    var contract: Contract
    var endpoint: URL
    /// 推荐模型 ID。systemone 走 pinnedModelVersion，其余形态在模型为空时用它兜底。
    var defaultModel: String
    var modelPlaceholder: String
    var keyPlaceholder: String
    /// runtime_status / 诊断用的稳定服务标识。
    var serviceIdentifier: String
    /// runtime_status JSON 里的 api_mode 值。
    var statusValue: String
    /// 是否支持 box 题型（图片定位）。
    var supportsBoxQuestions: Bool
    /// 是否支持图片输入（决定能否下发 assets；未实现图片编码的供应商必须为 false）。
    var supportsImages: Bool

    static let all: [IOSJevProvider] = [.typesafe, .vercelGateway, .perplexity, .liquid]

    /// 历史默认模型。早期只有 Gateway 一种非原生形态，存量 `vercelModel` 可能
    /// 仍是这些值；切供应商时按"未自定义"处理，避免把旧 slug 发到新厂商。
    static let legacyDefaultModels: Set<String> = ["typesafe-ai/jev"]

    static func `for`(_ style: IOSJevAPIStyle) -> IOSJevProvider {
        all.first { $0.style == style } ?? .typesafe
    }

    static let typesafe = IOSJevProvider(
        style: .systemone,
        displayName: "TypeSafe 原生",
        contract: .systemone,
        endpoint: URL(string: "https://api.typesafe.ai/v1/systemone")!,
        defaultModel: "jev-1.14.0",
        modelPlaceholder: "固定模型版本，如 jev-1.14.0",
        keyPlaceholder: "粘贴 TypeSafe API Key",
        serviceIdentifier: "typesafe.systemone",
        statusValue: "systemone",
        supportsBoxQuestions: true,
        supportsImages: true
    )

    /// @ai-sdk/gateway decision-model 契约（2026-10-16）：模型走 ai-model-id，
    /// body {stateParts, questions}；图片在 stateParts 中作为 file part。
    /// 注意 Gateway 的 evaluation 不经 OpenAI 兼容端点。
    static let vercelGateway = IOSJevProvider(
        style: .vercelGateway,
        displayName: "Vercel AI Gateway",
        contract: .vercelDecisionModel,
        endpoint: URL(string: "https://ai-gateway.vercel.sh/v4/ai/decision-model")!,
        defaultModel: "typesafe-ai/jev-1.14.0",
        modelPlaceholder: "如 typesafe-ai/jev-1.14.0 或 liquid/d1",
        keyPlaceholder: "粘贴 Vercel AI Gateway API Key",
        serviceIdentifier: "vercel.ai_gateway",
        statusValue: "vercel_gateway",
        supportsBoxQuestions: false,
        supportsImages: true
    )

    /// Perplexity 的 /v1/decisions 与 systemone 同构（body {model, state,
    /// questions}，返回 answers[qid].{noul,choice,score,confidence}），复用同一
    /// 编码/解析分支，只有 endpoint 与模型 ID 不同。
    static let perplexity = IOSJevProvider(
        style: .perplexityDecisions,
        displayName: "Perplexity",
        contract: .systemone,
        endpoint: URL(string: "https://api.perplexity.ai/v1/decisions")!,
        defaultModel: "pplx-decider-v1.2",
        modelPlaceholder: "如 pplx-decider-v1.2",
        keyPlaceholder: "粘贴 Perplexity API Key",
        serviceIdentifier: "perplexity.decisions",
        statusValue: "perplexity_decisions",
        supportsBoxQuestions: false,
        supportsImages: false
    )

    /// Liquid 的 decision models 端点同样是 systemone 契约；模型 d1 / d1-ultra。
    static let liquid = IOSJevProvider(
        style: .liquidSystemone,
        displayName: "Liquid AI",
        contract: .systemone,
        endpoint: URL(string: "https://api.liquid.ai/decisions/v1/systemone")!,
        defaultModel: "d1",
        modelPlaceholder: "如 d1 或 d1-ultra",
        keyPlaceholder: "粘贴 Liquid AI API Key",
        serviceIdentifier: "liquid.decisions",
        statusValue: "liquid_systemone",
        supportsBoxQuestions: false,
        supportsImages: false
    )
}

/// Phase 1 内部策略阈值（版本化；调整需升级 policyVersion 并回到 shadow）。
/// v2：真实用量口径——一次长任务工具调用可达数百次，网页循环单目标几十至
/// 上百步，v1 的 6 次/轮、1000 次/日预算在真实负载下必然撞墙；预算保留为
/// 失控熔断，量级按「实践中不触发」放宽。
struct IOSJevPolicy: Codable, Equatable, Sendable {
    /// A resized phone JPEG fits here without raising the text-only request budget.
    static let maxImageRequestBytes = 2 * 1_024 * 1_024
    /// 当前策略版本；存量低于该值的策略整体回默认（阈值无 UI 可编辑，重设无损）。
    static let currentPolicyVersion = 3
    /// 手机目标循环阈值的独立迁移版本（见 init(from:)）。
    static let currentPhoneLoopRevision = 1

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policyVersion = try container.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 1
        deadlineMs = try container.decodeIfPresent(Int.self, forKey: .deadlineMs) ?? 1_200
        webActionsDeadlineMs = try container.decodeIfPresent(Int.self, forKey: .webActionsDeadlineMs) ?? 2_500
        t1WaitBudgetMs = try container.decodeIfPresent(Int.self, forKey: .t1WaitBudgetMs) ?? 400
        t2WaitBudgetMs = try container.decodeIfPresent(Int.self, forKey: .t2WaitBudgetMs) ?? 400
        t3WaitBudgetMs = try container.decodeIfPresent(Int.self, forKey: .t3WaitBudgetMs) ?? 400
        onDemandWaitBudgetMs = try container.decodeIfPresent(Int.self, forKey: .onDemandWaitBudgetMs) ?? 400
        activePerRunLimit = try container.decodeIfPresent(Int.self, forKey: .activePerRunLimit) ?? 6
        activeAppLimit = try container.decodeIfPresent(Int.self, forKey: .activeAppLimit) ?? 6
        shadowAppLimit = try container.decodeIfPresent(Int.self, forKey: .shadowAppLimit) ?? 2
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
        toolDiscoveryMinConfidence = try container.decodeIfPresent(Double.self, forKey: .toolDiscoveryMinConfidence)
        memoryRecallMinConfidence = try container.decodeIfPresent(Double.self, forKey: .memoryRecallMinConfidence)
        contextSelectionMinConfidence = try container.decodeIfPresent(Double.self, forKey: .contextSelectionMinConfidence)
        modelRoutingMinConfidence = try container.decodeIfPresent(Double.self, forKey: .modelRoutingMinConfidence)
        webActionsMinConfidence = try container.decodeIfPresent(Double.self, forKey: .webActionsMinConfidence) ?? 0.5
        phoneActionsMinConfidence = try container.decodeIfPresent(Double.self, forKey: .phoneActionsMinConfidence) ?? 0.6
        subagentIntentMinConfidence = try container.decodeIfPresent(Double.self, forKey: .subagentIntentMinConfidence)
        memoryInjectionMinProbability = try container.decodeIfPresent(Double.self, forKey: .memoryInjectionMinProbability) ?? 0.8
        cacheMaxEntries = try container.decodeIfPresent(Int.self, forKey: .cacheMaxEntries) ?? 128
        cacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 300
        cooldownFailureThreshold = try container.decodeIfPresent(Int.self, forKey: .cooldownFailureThreshold) ?? 3
        cooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 60
        phoneLoopRevision = try container.decodeIfPresent(Int.self, forKey: .phoneLoopRevision) ?? 0
        // 手机目标循环的定向放宽：不升 policyVersion（那会把全部 active 用途打回 shadow），
        // 只把仍等于旧默认值的字段迁到新默认；手工改过的值原样保留。
        if phoneLoopRevision < Self.currentPhoneLoopRevision {
            if phoneActionsMinConfidence == 0.8 { phoneActionsMinConfidence = 0.6 }
            if activePerRunLimit == 3 { activePerRunLimit = 6 }
            phoneLoopRevision = Self.currentPhoneLoopRevision
        }
    }

    private enum CodingKeys: String, CodingKey {
        case policyVersion, deadlineMs, webActionsDeadlineMs, t1WaitBudgetMs, t2WaitBudgetMs
        case t3WaitBudgetMs, onDemandWaitBudgetMs, activePerRunLimit, activeAppLimit, shadowAppLimit
        case maxQuestions, maxCandidates, maxStateBytes
        case maxRequestBytes, maxResponseBytes, perTurnRequestBudget, perTurnStateBudgetBytes
        case dailyRequestBudget, dailyRequestBodyBudgetBytes, toolDiscoveryMinScore
        case memoryRecallMinScore, contextSelectionMinScore, modelRoutingMinScore
        case toolDiscoveryMinConfidence, memoryRecallMinConfidence, contextSelectionMinConfidence
        case modelRoutingMinConfidence, webActionsMinConfidence, phoneActionsMinConfidence, subagentIntentMinConfidence
        case memoryInjectionMinProbability
        case cacheMaxEntries, cacheTTLSeconds, cooldownFailureThreshold, cooldownSeconds
        case phoneLoopRevision
    }

    var policyVersion: Int = IOSJevPolicy.currentPolicyVersion
    var phoneLoopRevision: Int = IOSJevPolicy.currentPhoneLoopRevision
    /// 前台单次判断总 deadline（排队 + 网络 + 重试 + 解析），毫秒。
    var deadlineMs: Int = 1_200
    /// 网页和手机短目标循环的决策 deadline：一次超时烧掉整轮（观察+决策），
    /// 且移动网络+网关多一跳时尾部超 1.2s 并不少见——给更长视野把
    /// "超时"换成"慢一点的决策"。其余用途保持 1.2s 的轻快判断语义。
    var webActionsDeadlineMs: Int = 2_500
    /// 网络 deadline 与主路径等待预算独立。暂无真实延迟基线时的实验初值。
    var t1WaitBudgetMs: Int = 400
    var t2WaitBudgetMs: Int = 400
    var t3WaitBudgetMs: Int = 400
    var onDemandWaitBudgetMs: Int = 400
    /// 单个 run 同时在途的 active 判断数（并发上限，不是总次数）。手机目标循环串行
    /// 调用，但同一 run 的其它用途可能并发；放宽到与 App 级上限一致，避免排队超时。
    var activePerRunLimit: Int = 6
    var activeAppLimit: Int = 6
    var shadowAppLimit: Int = 2
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
    /// 置信弃权线（0-1）：答案置信低于该值时放弃 Jev 结果、回退原路径。
    /// nil = 不门控（置信缺失也不门控）。默认值由 shadow 期校准数据逐用途确定，
    /// 不采用供应商默认阈值——分桶校准见 IOSJevCalibration。
    var toolDiscoveryMinConfidence: Double? = nil
    var memoryRecallMinConfidence: Double? = nil
    var contextSelectionMinConfidence: Double? = nil
    var modelRoutingMinConfidence: Double? = nil
    /// webActions 置信下限（原循环内硬编码 0.5 收编进版本化 policy）。
    var webActionsMinConfidence: Double = 0.5
    /// 手机目标循环中 Jev 选择的置信下限；低于该值时循环重读界面再问，多次仍低才交回主模型。
    var phoneActionsMinConfidence: Double = 0.6
    /// 意图路由：角色 Choice 的置信弃权线（nil = 不门控）；对齐回执是 Noul，
    /// 无 confidence 字段，以 0.5 概率为分界线，不走该字段。
    var subagentIntentMinConfidence: Double? = nil
    var memoryInjectionMinProbability: Double = 0.8
    /// 缓存条目上限（内存）。
    var cacheMaxEntries: Int = 128
    /// 缓存 TTL（秒）。
    var cacheTTLSeconds: Int = 300
    /// 连续暂时性失败次数达到该值后冷却。
    var cooldownFailureThreshold: Int = 3
    /// 冷却时长（秒）。
    var cooldownSeconds: Int = 60

    /// 各用途 active 调用方实际等待的时长：协调器默认等待与 shadow 的
    /// "预算内返回"指标共用这一口径。不挡主路径的用途（审批分诊、网页
    /// 循环自身）等到网络 deadline；T1/T2/T3 与按需判断用等待预算。
    func activeWaitBudgetMs(for useCase: IOSJevUseCase) -> Int {
        switch useCase {
        case .memoryRecall: t1WaitBudgetMs
        case .contextSelection: t2WaitBudgetMs
        case .modelRouting, .subagentIntent: t3WaitBudgetMs
        case .toolDiscovery: onDemandWaitBudgetMs
        case .approvalTriage, .scriptJudgment, .toolResultRetention, .autoApprovalGate, .completionCheck, .phoneVerification: deadlineMs
        case .webActions, .phoneActions: webActionsDeadlineMs
        }
    }
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
    /// 头条数值：该次决策全部答案中的最大置信（0-1）；跳过/错误为 nil。
    /// 用于生产 shadow 的置信分布监测；逐答案校准明细由分析侧从完整决策重建。
    var topConfidence: Double?
    /// 头条数值：该次决策全部答案中的最高分；跳过/错误为 nil。
    var topScore: Double?
    /// 只存运行标识、数字差异和阶段，不存任务或工具输出原文。
    var runId: String?
    var waitPhase: String?
    var waitedMs: Int?
    var numbers: [String: Double]?
    /// 仅存本地稳定 ID，不存任务文本或工具输出。
    var ids: [String: String]?
}

/// 版本化 Jev 设置。revision 随每次更新递增，作为判断身份与缓存失效输入。
struct IOSJevSettings: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    /// 未验收时使用推荐版本测试；active 仍需显式固定版本。
    var pinnedModelVersion: String?
    /// 出站供应商形态（默认 TypeSafe 原生）。endpoint、默认模型、Key 提示
    /// 都由 IOSJevProvider 注册表给出，切换供应商不需要再改这里的 switch。
    var apiStyle: IOSJevAPIStyle = .systemone
    /// 非 systemone 形态的模型 ID（Gateway 是 provider/model slug，Perplexity /
    /// Liquid 是模型 ID）。选择形态且为空时由 setAPIStyle 自动填入默认值；
    /// 显式清空 = 未配置：active 按 shadow 收口，出站按 model_unspecified 跳过。
    var providerModel: String = ""
    /// providerModel 归属于哪一家供应商。切换供应商时据此判定是否该换成新家默认
    /// 值，避免把上一家的模型 ID 发到新家。nil = 未知（旧设置），按 apiStyle 推断。
    var providerModelStyle: IOSJevAPIStyle?
    var modes: [IOSJevUseCase: IOSJevMode] = [:]
    var dataScopes: [IOSJevUseCase: Set<IOSJevDataScope>] = [:]
    var policy: IOSJevPolicy = IOSJevPolicy()

    static var productionEndpoint: URL { IOSJevProvider.typesafe.endpoint }
    static var recommendedModelVersion: String { IOSJevProvider.typesafe.defaultModel }
    static var vercelGatewayEndpoint: URL { IOSJevProvider.vercelGateway.endpoint }
    /// vercelGateway 默认模型：Jev 本体在 Gateway 的 Model ID。
    static var vercelDefaultModel: String { IOSJevProvider.vercelGateway.defaultModel }

    var recommendedModelForAPI: String {
        apiStyle == .systemone ? Self.recommendedModelVersion : apiStyle.provider.defaultModel
    }

    var supportsPhoneScreenshots: Bool {
        switch apiStyle {
        case .systemone: true
        case .vercelGateway: providerModel == Self.vercelDefaultModel
        default: false
        }
    }

    /// 当前 apiStyle 的出站 endpoint。
    var resolvedEndpoint: URL { apiStyle.provider.endpoint }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pinnedModelVersion = try container.decodeIfPresent(String.self, forKey: .pinnedModelVersion)
        // 未知 apiStyle（未来新增形态的旧版本读盘）宽容回退 systemone，
        // 与 modes/scopes 的未知值丢弃策略一致，不整份丢设置。
        apiStyle = (try? container.decodeIfPresent(IOSJevAPIStyle.self, forKey: .apiStyle)) ?? .systemone
        providerModel = (try container.decodeIfPresent(String.self, forKey: .providerModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 旧设置没有归属字段：槽位语义上就是当前供应商的模型，按 apiStyle 记账。
        // 有值但 rawValue 无法识别时（新版本写入的未知供应商）保持 nil，不猜。
        let ownerRaw: String?? = try? container.decodeIfPresent(String.self, forKey: .providerModelStyle)
        if let raw = ownerRaw ?? nil {
            providerModelStyle = IOSJevAPIStyle(rawValue: raw)
        } else if !providerModel.isEmpty {
            providerModelStyle = apiStyle
        }
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
            for useCase in IOSJevUseCase.allCases where modes[useCase] == .active {
                modes[useCase] = .shadow
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(pinnedModelVersion, forKey: .pinnedModelVersion)
        try container.encode(apiStyle, forKey: .apiStyle)
        try container.encode(providerModel, forKey: .providerModel)
        try container.encodeIfPresent(providerModelStyle, forKey: .providerModelStyle)
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
        case schemaVersion, revision, pinnedModelVersion, apiStyle
        /// 存量设置文件里这个字段叫 vercelModel（当时只有 Gateway 一种非原生
        /// 形态）；映射到 providerModel 后语义扩到所有供应商，磁盘格式不变。
        case providerModel = "vercelModel"
        case providerModelStyle
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

    func canSendPhoneScreenshots(for useCase: IOSJevUseCase) -> Bool {
        supportsPhoneScreenshots
            && (useCase == .phoneActions || useCase == .phoneVerification)
            && canSend(useCase: useCase, required: useCase.defaultDataScopes.union([.phoneScreenshots]))
    }

    static func isPinnedVersion(_ version: String) -> Bool {
        !version.isEmpty && version != "jev-latest" && version != "jev-preview"
    }

    /// active 需要固定模型版本；未验收（无 pinned 版本）时按 shadow 收口。
    /// 非原生供应商下模型 ID 由用户显式填写即为固定版本，空值按 shadow 收口。
    func effectiveMode(for useCase: IOSJevUseCase) -> IOSJevMode {
        let configured = mode(for: useCase)
        guard configured == .active else { return configured }
        switch apiStyle {
        case .systemone:
            guard let pinned = pinnedModelVersion, Self.isPinnedVersion(pinned) else {
                return .shadow
            }
        default:
            guard !providerModel.isEmpty else { return .shadow }
        }
        return .active
    }

    /// 当前 apiStyle 下实际出站的模型标识（shadow/active 共用；非原生形态
    /// 模型为空时返回空串，由协调器按 model_unspecified 跳过、不出网）。
    var activeModelVersion: String {
        switch apiStyle {
        case .systemone:
            if let pinned = pinnedModelVersion, !pinned.isEmpty { return pinned }
            return Self.recommendedModelVersion
        default:
            return providerModel
        }
    }

    /// 当前 apiStyle 下模型是否已配置（runtime_status 的 model_configured）。
    var modelConfigured: Bool { !activeModelVersion.isEmpty }

    /// 手动固定/清除已验收模型版本（systemone 的 active 前提；vercel 的模型
    /// slug 即固定版本，不走这个字段）。空串/空白/浮动别名 latest/preview →
    /// 清除回未验收态（与 acceptVerifiedModelVersion 同口径，避免"存了但无效"）。
    mutating func setPinnedModelVersion(_ version: String?) {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        pinnedModelVersion = trimmed.flatMap { Self.isPinnedVersion($0) ? $0 : nil }
        revision += 1
    }

    /// 连接测试验收：systemone 下把服务端报告的模型版本落为固定版本。
    /// 浮动别名（jev-latest）与空值不验收；vercel 的 slug 即固定版本无需此步。
    mutating func acceptVerifiedModelVersion(_ version: String?) {
        guard apiStyle == .systemone else { return }
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isPinnedVersion(trimmed) else { return }
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
        // 非原生形态必须有模型才能出站：空值、或模型不属于这家（上一家遗留）、
        // 或仍是某家默认值（说明用户没自定义过），都换上新家的默认值。
        if style != .systemone {
            let trimmed = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let isProviderDefault = IOSJevProvider.all.contains { $0.defaultModel == trimmed }
                || IOSJevProvider.legacyDefaultModels.contains(trimmed)
            let ownedByTarget = providerModelStyle == style
            if trimmed.isEmpty || !ownedByTarget || isProviderDefault {
                providerModel = style.provider.defaultModel
                providerModelStyle = style
            }
        }
        revision += 1
    }

    mutating func setProviderModel(_ model: String) {
        providerModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // 记下这家：切到别家时才能分辨"这是他的自定义值"与"上一家遗留"。
        providerModelStyle = apiStyle
        revision += 1
    }

    /// 收紧数据范围或清 Key 时由 store 调用：revision 变化自然使缓存失效。
    mutating func bumpRevision() {
        revision += 1
    }

    /// 推荐配置只开启低风险用途的 shadow 观测，保留其它用途原设置。
    mutating func applyRecommendedConfiguration() {
        for useCase in [IOSJevUseCase.toolDiscovery, .memoryRecall, .contextSelection, .toolResultRetention, .modelRouting, .subagentIntent, .completionCheck] {
            modes[useCase] = .shadow
            dataScopes[useCase] = useCase.defaultDataScopes
        }
        revision += 1
    }
}

// MARK: - Metrics store（上限 7 天 / 5 MiB，可清除）

enum IOSJevMetricsStore {
    private static let key = "app.amber.ios.jevMetrics.v1"
    private static let maxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maxBytes = 5 * 1_024 * 1_024
    private static let maxCount = 2_000
    private static let flushInterval: TimeInterval = 5
    private static let flushCount = 50

    private static var defaults: UserDefaults { .standard }

    /// load→append→set 的读改写必须原子，否则并发 shadow 判断互相覆盖丢记录。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryRecords: [IOSJevMetricsRecord]?
    nonisolated(unsafe) private static var unflushedCount = 0
    nonisolated(unsafe) private static var pendingFlush: DispatchWorkItem?
    nonisolated(unsafe) private static var isInBackground = false
    nonisolated(unsafe) private static let backgroundObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
    ) { _ in
        lock.lock()
        defer { lock.unlock() }
        isInBackground = true
        flushLocked()
    }
    nonisolated(unsafe) private static let foregroundObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: nil
    ) { _ in
        lock.lock()
        defer { lock.unlock() }
        isInBackground = false
    }

    /// 协调器创建时即注册，确保在首条 late 指标出现前已接收后台通知。
    static func startObservingLifecycle() {
        _ = backgroundObserver
        _ = foregroundObserver
    }

    static func setApplicationBackgroundState(_ background: Bool) {
        startObservingLifecycle()
        lock.lock()
        defer { lock.unlock() }
        isInBackground = background
        if background { flushLocked() }
    }

    static func load(now: Date = Date()) -> [IOSJevMetricsRecord] {
        _ = backgroundObserver
        _ = foregroundObserver
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(now: now)
    }

    private static func loadLocked(now: Date) -> [IOSJevMetricsRecord] {
        if memoryRecords == nil {
            if let data = defaults.data(forKey: key),
               let records = try? JSONDecoder().decode([IOSJevMetricsRecord].self, from: data) {
                memoryRecords = records
            } else {
                memoryRecords = []
            }
        }
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        return (memoryRecords ?? []).filter { $0.timestamp >= cutoff }
    }

    static func append(_ record: IOSJevMetricsRecord, now: Date = Date()) {
        _ = backgroundObserver
        _ = foregroundObserver
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked(now: now)
        records.append(record)
        records = records.filter { $0.timestamp >= now.addingTimeInterval(-maxAgeSeconds) }
        if records.count > maxCount {
            records = Array(records.suffix(maxCount))
        }
        memoryRecords = records
        unflushedCount += 1
        if isInBackground || unflushedCount >= flushCount {
            flushLocked()
        } else if pendingFlush == nil {
            let item = DispatchWorkItem { flush() }
            pendingFlush = item
            DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: item)
        }
    }

    static func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private static func flushLocked() {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard unflushedCount > 0, var records = memoryRecords else { return }
        var data = try? JSONEncoder().encode(records)
        while let bytes = data, bytes.count > maxBytes, records.count > 1 {
            records.removeFirst(max(1, records.count / 2))
            data = try? JSONEncoder().encode(records)
        }
        if let data, data.count <= maxBytes {
            memoryRecords = records
            defaults.set(data, forKey: key)
            unflushedCount = 0
        }
    }

    static func clear() {
        _ = backgroundObserver
        _ = foregroundObserver
        lock.lock()
        defer { lock.unlock() }
        pendingFlush?.cancel()
        pendingFlush = nil
        memoryRecords = []
        unflushedCount = 0
        defaults.removeObject(forKey: key)
    }

    struct UseCaseSummary: Equatable {
        var useCase: IOSJevUseCase
        var total: Int
        /// nil 表示尚无可比较的基线/建议，UI 不应显示成 0%。
        var differenceRate: Double?
        var waitP50Ms: Int?
        var waitP95Ms: Int?
        /// shadow 答案在 active 等待预算内返回的比例；nil 表示暂无 shadow 样本。
        var withinActiveWaitRate: Double?
        var completionRate: Double?
        var exposureRatio: Double?
        var newToolUseRate: Double?
        var rereadAfterHideRate: Double?
        var childSucceeded: Int?
        var childFailed: Int?
        var childTimedOut: Int?
        var fallbackReasons: [String: Int]
    }

    static func useCaseSummaries(now: Date = Date()) -> [UseCaseSummary] {
        let records = load(now: now)
        return IOSJevUseCase.allCases.map { useCase in
            let numericRecords = records.filter { $0.useCase == useCase && $0.outcome != "connection_test" }
            let group = numericRecords.filter { $0.outcome != "summary" }
            let comparable = group.filter { $0.suggestedTop1 != nil && $0.keywordTop1 != nil }
            let differences = comparable.filter { $0.suggestedTop1 != $0.keywordTop1 }.count
            let numericDifferences = numericRecords.compactMap { $0.numbers?["difference"] }
            let overlaps = numericRecords.compactMap { $0.numbers?["overlap_ratio"] }
            let projections = numericRecords.filter { $0.outcome == "summary" }
            let hidden = projections.compactMap { $0.numbers?["hidden_characters"] }.reduce(0, +)
            let original = projections.compactMap { $0.numbers?["original_characters"] }.reduce(0, +)
            let shadowHidden = numericRecords.compactMap { $0.numbers?["shadow_hidden_characters"] }.reduce(0, +)
            let shadowOriginal = numericRecords.compactMap { $0.numbers?["shadow_original_characters"] }.reduce(0, +)
            let completions = projections.compactMap { $0.numbers?["web_completed"] }
            let exposureRatios = projections.compactMap { $0.numbers?["exposure_ratio"] }
            let nextToolUses = projections.compactMap { $0.numbers?["next_step_new_tool_used"] }
            var latestProjectionByRun: [String: IOSJevMetricsRecord] = [:]
            for record in projections where record.numbers?["hidden_blocks"] != nil {
                if let runId = record.runId { latestProjectionByRun[runId] = record }
            }
            let hiddenBlockCount = latestProjectionByRun.values.compactMap { $0.numbers?["hidden_blocks"] }.reduce(0, +)
            let rereadCount = latestProjectionByRun.values.compactMap { $0.numbers?["reread_after_hide_count"] }.reduce(0, +)
            let childSuccesses = projections.compactMap { $0.numbers?["child_succeeded"] }
            let childFailures = projections.compactMap { $0.numbers?["child_failed"] }
            let childTimeouts = projections.compactMap { $0.numbers?["child_timed_out"] }
            let hasChildOutcomes = !childSuccesses.isEmpty || !childFailures.isEmpty || !childTimeouts.isEmpty
            let differenceRate: Double?
            if !comparable.isEmpty {
                differenceRate = Double(differences) / Double(comparable.count)
            } else if !numericDifferences.isEmpty {
                differenceRate = numericDifferences.reduce(0, +) / Double(numericDifferences.count)
            } else if !overlaps.isEmpty {
                differenceRate = 1 - overlaps.reduce(0, +) / Double(overlaps.count)
            } else if original > 0 {
                differenceRate = hidden / original
            } else if shadowOriginal > 0 {
                differenceRate = shadowHidden / shadowOriginal
            } else {
                differenceRate = nil
            }
            let activeWaitFits = group.compactMap { $0.numbers?["within_active_wait_budget"] }
            let waits = group.compactMap(\.waitedMs).sorted()
            func percentile(_ fraction: Double) -> Int? {
                guard !waits.isEmpty else { return nil }
                return waits[Int((Double(waits.count - 1) * fraction).rounded(.up))]
            }
            var reasons: [String: Int] = [:]
            for record in group where record.outcome == "skipped" || record.outcome == "error" || record.outcome == "late" || record.outcome == "shadow_dropped" {
                reasons[record.reason ?? record.outcome, default: 0] += 1
            }
            for record in projections where record.numbers?["business_fallback"] == 1 || record.numbers?["handback"] == 1 {
                reasons[record.reason ?? "business_fallback", default: 0] += 1
            }
            return UseCaseSummary(
                useCase: useCase,
                total: group.count,
                differenceRate: differenceRate,
                waitP50Ms: percentile(0.5),
                waitP95Ms: percentile(0.95),
                withinActiveWaitRate: activeWaitFits.isEmpty ? nil : activeWaitFits.reduce(0, +) / Double(activeWaitFits.count),
                completionRate: completions.isEmpty ? nil : completions.reduce(0, +) / Double(completions.count),
                exposureRatio: exposureRatios.isEmpty ? nil : exposureRatios.reduce(0, +) / Double(exposureRatios.count),
                newToolUseRate: nextToolUses.isEmpty ? nil : nextToolUses.reduce(0, +) / Double(nextToolUses.count),
                rereadAfterHideRate: hiddenBlockCount > 0 ? rereadCount / hiddenBlockCount : nil,
                childSucceeded: hasChildOutcomes ? Int(childSuccesses.reduce(0, +)) : nil,
                childFailed: hasChildOutcomes ? Int(childFailures.reduce(0, +)) : nil,
                childTimedOut: hasChildOutcomes ? Int(childTimeouts.reduce(0, +)) : nil,
                fallbackReasons: reasons
            )
        }
    }

    typealias RunSummary = IOSJevRunSummary

    /// 端到端数字以 summary 行保存；全用途 off 时保持零 Jev 指标。
    static func appendRunNumbers(runId: String, numbers: [String: Double], now: Date = Date()) {
        let settings = IOSSharedSettingsStore.loadPersistedJevSettings()
        let enabled = IOSJevUseCase.allCases.contains { settings.effectiveMode(for: $0) != .off }
        guard enabled || load(now: now).contains(where: { $0.runId == runId && $0.outcome != "summary" }) else { return }
        append(IOSJevMetricsRecord(
            timestamp: now, useCase: .toolDiscovery, mode: .off, modelVersion: "",
            outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: nil,
            runId: runId, numbers: numbers
        ), now: now)
    }

    static func runSummary(runId: String, now: Date = Date()) -> RunSummary {
        let records = load(now: now).filter { $0.runId == runId }
        func latestNumber(_ key: String) -> Int? {
            records.reversed().compactMap { $0.numbers?[key] }.first.map(Int.init)
        }
        return RunSummary(
            decisions: records.filter { ["applied", "observed", "late"].contains($0.outcome) }.count,
            memorySelected: latestNumber("memory_selected"),
            memoryInjectionHits: latestNumber("memory_injection_hits"),
            hiddenCharacters: latestNumber("hidden_characters"),
            selectedModelId: records.reversed().compactMap { $0.ids?["selected_model_id"] }.first,
            firstVisibleDeltaMs: latestNumber("first_visible_delta_ms"),
            modelSteps: latestNumber("model_steps"),
            cacheHitRatio: records.reversed().compactMap { $0.numbers?["cache_hit_ratio"] }.first
        )
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
        let records = load(now: now).filter { $0.outcome != "connection_test" && $0.outcome != "summary" }
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
