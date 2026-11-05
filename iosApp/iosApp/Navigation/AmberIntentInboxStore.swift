import Foundation
import Observation

// MARK: - Amber Intent Candidate Model & Payload

/// 用户在聊天中随口提及、尚未作为正式指令执行的候选意图。
/// 闲聊识别只生成候选待办，绝不自动执行高风险或未经确认的后台动作。
struct AmberIntentCandidate: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 后台调研（摸底、搜集资料、对比方案）
        case backgroundResearch
        /// 持续盯梢（价格窗口、余票/库存、动态跟进、定时巡检）
        case scheduledWatch
        /// 待办事项（稍后整理、备忘、待处理事项）
        case actionTodo

        var id: String { rawValue }

        var badgeTitle: String {
            switch self {
            case .backgroundResearch:
                return IOSAppLocalization.string("建议后台调研", defaultValue: "建议后台调研")
            case .scheduledWatch:
                return IOSAppLocalization.string("建议持续盯梢", defaultValue: "建议持续盯梢")
            case .actionTodo:
                return IOSAppLocalization.string("候选待办", defaultValue: "候选待办")
            }
        }

        var primaryActionTitle: String {
            switch self {
            case .backgroundResearch:
                return IOSAppLocalization.string("交办后台", defaultValue: "交办后台")
            case .scheduledWatch:
                return IOSAppLocalization.string("设为盯梢", defaultValue: "设为盯梢")
            case .actionTodo:
                return IOSAppLocalization.string("交办后台", defaultValue: "交办后台")
            }
        }

        var systemImageName: String {
            switch self {
            case .backgroundResearch:
                return "doc.text.magnifyingglass"
            case .scheduledWatch:
                return "clock.badge"
            case .actionTodo:
                return "checklist"
            }
        }
    }

    enum RiskLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 普通只读调研或盯梢
        case low
        /// 涉及外发、修改配置、花钱、删除等高风险动作，必须在界面显式标明需确认
        case requiresApproval

        var id: String { rawValue }

        var badgeTitle: String? {
            switch self {
            case .low:
                return nil
            case .requiresApproval:
                return IOSAppLocalization.string("需人工确认", defaultValue: "需人工确认")
            }
        }
    }

    enum Status: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 待确认
        case pending
        /// 已转正交办
        case accepted
        /// 已忽略
        case dismissed

        var id: String { rawValue }
    }

    var id: String
    /// 提炼出的精简交办意图，如“摸排海外潜在客户公开联系方式”“跟进下周国内油价调价窗口”
    var title: String
    /// 用户随口提到的原话摘录
    var sourceQuote: String
    var conversationId: String?
    var sourceMessageId: String?
    var suggestedKind: Kind
    /// 用户点击确认后可直接派发给后台子代理或盯梢任务的完整指令描述
    var suggestedPrompt: String
    var riskLevel: RiskLevel
    var status: Status
    var createdAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        sourceQuote: String,
        conversationId: String? = nil,
        sourceMessageId: String? = nil,
        suggestedKind: Kind,
        suggestedPrompt: String,
        riskLevel: RiskLevel = .low,
        status: Status = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sourceQuote = sourceQuote
        self.conversationId = conversationId
        self.sourceMessageId = sourceMessageId
        self.suggestedKind = suggestedKind
        self.suggestedPrompt = suggestedPrompt
        self.riskLevel = riskLevel
        self.status = status
        self.createdAt = createdAt
    }
}

/// 用户在收件箱点击确认交办后返回的派发载荷。
/// 由上层协调器根据 `suggestedKind` 路由至后台子代理（`spawn_agent`）或持续盯梢（`wake_schedule`）。
struct AmberIntentDispatchPayload: Equatable, Sendable {
    let candidateId: String
    let title: String
    let prompt: String
    let kind: AmberIntentCandidate.Kind
    let riskLevel: AmberIntentCandidate.RiskLevel
    let conversationId: String?
    let sourceMessageId: String?
    let sourceQuote: String

    /// 是否需要上层在真正执行外部写操作前强制走人工审批策略
    var requiresExplicitToolApproval: Bool {
        riskLevel == .requiresApproval
    }

    /// 与 `AmberIntentCandidate.suggestedPrompt` 对齐的便捷访问属性
    var suggestedPrompt: String {
        prompt
    }
}

// MARK: - Amber Intent Inbox Store

@MainActor
@Observable
final class AmberIntentInboxStore {

    static let shared = AmberIntentInboxStore()

    nonisolated static let defaultUserDefaultsKey = "amber.duet.intentInbox.candidates.v1"
    nonisolated static let maxRetainedCandidates = 100

    /// 显式交办或定时工具名称集合：当轮如果已经显式触发了这些工具，不再重复生成随口意图候选。
    nonisolated static let explicitDelegationToolNames: Set<String> = [
        "spawn_agent",
        "subagent_spawn",
        "delegate_task",
        "wake_schedule",
        "schedule_wake",
        "wake_create",
        "create_automation",
    ]

    private let userDefaults: UserDefaults?
    private let userDefaultsKey: String
    private let fileURL: URL?

    private(set) var candidates: [AmberIntentCandidate] = []

    /// 当前待确认的候选列表（按创建时间倒序，最新在最前）
    var pendingCandidates: [AmberIntentCandidate] {
        candidates.filter { $0.status == .pending }
    }

    /// 指定会话（或包含全局）的待确认候选列表
    func pendingCandidates(forConversationId conversationId: String?) -> [AmberIntentCandidate] {
        guard let conversationId, !conversationId.isEmpty else {
            return pendingCandidates
        }
        return candidates.filter {
            $0.status == .pending && ($0.conversationId == nil || $0.conversationId == conversationId)
        }
    }

    init(
        userDefaults: UserDefaults? = .standard,
        userDefaultsKey: String = AmberIntentInboxStore.defaultUserDefaultsKey,
        fileURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.userDefaultsKey = userDefaultsKey
        self.fileURL = fileURL
        self.candidates = Self.loadFromStorage(
            userDefaults: userDefaults,
            userDefaultsKey: userDefaultsKey,
            fileURL: fileURL
        )
    }

    /// 从用户消息文本提取并入库随口意图候选。
    /// - Parameters:
    ///   - text: 用户输入原文
    ///   - conversationId: 所属会话 ID
    ///   - sourceMessageId: 来源消息 ID
    ///   - triggeredToolNames: 当轮已显式触发的工具名列表（若含 `spawn_agent` 或 `wake_schedule` 则跳过）
    ///   - now: 当前时间（便于单测注入确定性时间戳）
    /// - Returns: 本次实际新增入库的候选列表
    @discardableResult
    func captureFromUserMessage(
        _ text: String,
        conversationId: String? = nil,
        sourceMessageId: String? = nil,
        triggeredToolNames: Set<String> = [],
        now: Date = Date()
    ) -> [AmberIntentCandidate] {
        guard !Self.hasExplicitDelegationTool(triggeredToolNames) else {
            return []
        }
        let extracted = AmberIntentCandidateExtractor.extractCandidates(
            from: text,
            conversationId: conversationId,
            sourceMessageId: sourceMessageId,
            triggeredToolNames: triggeredToolNames,
            now: now
        )
        return addCandidates(extracted, triggeredToolNames: triggeredToolNames)
    }

    /// 批量或单条去重添加候选。
    /// - 若当轮已显式触发 `spawn_agent` 或 `wake_schedule`，直接过滤不入库；
    /// - 按会话 + 原话/标题规范化指纹去重，避免同一句话重复生成候选。
    @discardableResult
    func addCandidates(
        _ incoming: [AmberIntentCandidate],
        triggeredToolNames: Set<String> = []
    ) -> [AmberIntentCandidate] {
        guard !Self.hasExplicitDelegationTool(triggeredToolNames), !incoming.isEmpty else {
            return []
        }

        var working = candidates
        var added: [AmberIntentCandidate] = []

        for item in incoming {
            let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedQuote = item.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty, !trimmedQuote.isEmpty else { continue }

            if Self.isDuplicate(item, in: working) {
                continue
            }

            var normalizedItem = item
            normalizedItem.title = trimmedTitle
            normalizedItem.sourceQuote = trimmedQuote
            working.insert(normalizedItem, at: 0)
            added.append(normalizedItem)
        }

        guard !added.isEmpty else { return [] }

        if working.count > Self.maxRetainedCandidates {
            working = Array(working.prefix(Self.maxRetainedCandidates))
        }

        if working != candidates {
            candidates = working
            persist()
        }
        return added
    }

    @discardableResult
    func addCandidate(
        _ candidate: AmberIntentCandidate,
        triggeredToolNames: Set<String> = []
    ) -> Bool {
        !addCandidates([candidate], triggeredToolNames: triggeredToolNames).isEmpty
    }

    /// 确认转正一条候选意图：将其状态标记为 `.accepted` 并返回可直接用于派发的载荷。
    /// 注意：本方法只更新收件箱状态并返回派发载荷，绝不自行悄悄执行高风险操作。
    @discardableResult
    func accept(id: String) -> AmberIntentDispatchPayload? {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var working = candidates
        var target = working[index]
        guard target.status == .pending else {
            return AmberIntentDispatchPayload(
                candidateId: target.id,
                title: target.title,
                prompt: target.suggestedPrompt,
                kind: target.suggestedKind,
                riskLevel: target.riskLevel,
                conversationId: target.conversationId,
                sourceMessageId: target.sourceMessageId,
                sourceQuote: target.sourceQuote
            )
        }
        target.status = .accepted
        working[index] = target
        candidates = working
        persist()

        return AmberIntentDispatchPayload(
            candidateId: target.id,
            title: target.title,
            prompt: target.suggestedPrompt,
            kind: target.suggestedKind,
            riskLevel: target.riskLevel,
            conversationId: target.conversationId,
            sourceMessageId: target.sourceMessageId,
            sourceQuote: target.sourceQuote
        )
    }

    /// 忽略一条候选意图。
    @discardableResult
    func dismiss(id: String) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard candidates[index].status != .dismissed else {
            return false
        }
        var working = candidates
        working[index].status = .dismissed
        candidates = working
        persist()
        return true
    }

    /// 清理所有已忽略（`.dismissed`）的候选记录。
    func clearDismissed() {
        let filtered = candidates.filter { $0.status != .dismissed }
        guard filtered != candidates else { return }
        candidates = filtered
        persist()
    }

    /// 重置全部记录（仅供单测或调试清理使用）。
    func removeAll() {
        guard !candidates.isEmpty else { return }
        candidates = []
        persist()
    }

    // MARK: - Deduplication & Filtering Helpers

    nonisolated static func hasExplicitDelegationTool(_ toolNames: Set<String>) -> Bool {
        guard !toolNames.isEmpty else { return false }
        for raw in toolNames {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if explicitDelegationToolNames.contains(normalized) {
                return true
            }
            if normalized.contains("spawn_agent") || normalized.contains("wake_schedule") {
                return true
            }
        }
        return false
    }

    nonisolated static func deduplicationFingerprint(_ text: String) -> String {
        let lowered = text.lowercased()
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(lowered.unicodeScalars.count)
        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private nonisolated static func isDuplicate(
        _ incoming: AmberIntentCandidate,
        in existingList: [AmberIntentCandidate]
    ) -> Bool {
        let incomingQuoteKey = deduplicationFingerprint(incoming.sourceQuote)
        let incomingTitleKey = deduplicationFingerprint(incoming.title)
        guard !incomingQuoteKey.isEmpty, !incomingTitleKey.isEmpty else { return true }

        for existing in existingList {
            let sameConversationScope: Bool
            if let lhs = incoming.conversationId, let rhs = existing.conversationId {
                sameConversationScope = (lhs == rhs)
            } else {
                sameConversationScope = (incoming.conversationId == existing.conversationId)
            }
            guard sameConversationScope else { continue }

            let existingQuoteKey = deduplicationFingerprint(existing.sourceQuote)
            let existingTitleKey = deduplicationFingerprint(existing.title)
            if existingQuoteKey == incomingQuoteKey || existingTitleKey == incomingTitleKey {
                return true
            }
        }
        return false
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(candidates) else { return }

        if let fileURL {
            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
        if let userDefaults {
            userDefaults.set(data, forKey: userDefaultsKey)
        }
    }

    private nonisolated static func loadFromStorage(
        userDefaults: UserDefaults?,
        userDefaultsKey: String,
        fileURL: URL?
    ) -> [AmberIntentCandidate] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([AmberIntentCandidate].self, from: data) {
            return decoded
        }
        if let userDefaults,
           let data = userDefaults.data(forKey: userDefaultsKey),
           let decoded = try? decoder.decode([AmberIntentCandidate].self, from: data) {
            return decoded
        }
        return []
    }
}

// MARK: - Casual Intent Candidate Extractor (Heuristic + Jev Batch Extension)

/// 随口意图识别与提取器。
/// - 纯本地/只读分析用户输入文本中的“随口提及的潜在意图/延后待办/顺手盯梢”；
/// - 绝不自动调用工具或自动启动后台 run；
/// - 涉及外部副作用（发消息、改配置、支付、删除）一律标记为 `.requiresApproval`；
/// - 提供 Jev 批处理扩展接口，支持在 Jev 启用时进一步复核候选分类与风险等级。
enum AmberIntentCandidateExtractor {

    /// 单条消息最多提取的候选数量，防止长文刷屏
    static let maxCandidatesPerMessage = 3

    /// 显式立即执行命令的开头特征（当整句话只是直接命令当前轮立即执行且无延后/顺带线索时，不作为“随口待办”捕捉）
    private static let immediateDirectCommandPrefixes: [String] = [
        "现在立刻帮我",
        "马上帮我调用",
        "立即运行",
        "立刻执行",
        "请直接调用工具",
        "spawn_agent",
        "wake_schedule",
    ]

    /// 随口提及 / 延后待办 / 顺手盯梢的引导词模式（按长度降序优先匹配，便于剥离口语前缀提炼干净标题）
    private static let casualCuePrefixes: [String] = [
        "对了回头得帮我",
        "对了回头帮我",
        "对了有空帮我",
        "回头得帮我",
        "回头帮我",
        "回头我还得",
        "回头还得",
        "回头我得",
        "回头得去",
        "回头得",
        "回头再",
        "回头要",
        "有空得帮我",
        "有空帮我",
        "有空的时候帮我",
        "有时间帮我",
        "抽空帮我",
        "抽空得",
        "晚点得帮我",
        "晚点帮我",
        "晚点我还得",
        "晚点还得",
        "晚点我得",
        "晚点得",
        "晚点再",
        "稍后得",
        "稍后帮我",
        "顺便帮我留意下",
        "顺便留意一下",
        "顺便留意下",
        "顺便帮我盯着点",
        "顺便帮我看看",
        "顺便还得",
        "顺便得",
        "顺带留意下",
        "顺手帮我",
        "另外还得帮我",
        "另外还得",
        "另外我得",
        "另外回头",
        "还得帮我",
        "还得去",
        "还得再",
        "还得",
        "改天得",
        "改天帮我",
        "下周得",
        "下周记得",
        "明天得记得",
        "记得提醒我",
        "别忘了帮我",
        "先记一下",
        "先记个待办",
        "记个待办",
    ]

    /// 句中出现也算随口意图/延后待办的触发短语
    private static let casualInfixMarkers: [String] = [
        "回头得",
        "回头还得",
        "回头再",
        "回头查",
        "回头看",
        "回头摸",
        "回头整理",
        "有空帮我",
        "抽空帮我",
        "晚点得",
        "晚点还得",
        "晚点整理",
        "顺便留意",
        "顺便盯",
        "顺便看看",
        "还得摸一下",
        "还得摸排",
        "还得查下",
        "还得查一下",
        "还得跟进",
        "还得整理",
        "得摸一下",
        "得查一下",
        "得查下",
        "得留意下",
        "得跟进下",
        "帮我盯着",
        "帮我留意",
        "提醒我一下",
        "记个待办",
        "remind me later to ",
        "when you have a chance",
        "keep an eye on ",
        "need to look into ",
        "later i need to ",
    ]

    /// 持续盯梢（`.scheduledWatch`）特征词
    private static let scheduledWatchKeywords: [String] = [
        "留意",
        "盯梢",
        "盯着",
        "盯一下",
        "盯紧",
        "跟进",
        "调价窗口",
        "窗口期",
        "油价",
        "金价",
        "股价",
        "汇率",
        "余票",
        "放票",
        "补货",
        "降价",
        "开售",
        "一有消息",
        "出了结果",
        "有动静",
        "定时",
        "每天",
        "每周",
        "下周",
        "每隔",
        "监控",
        "巡检",
        "动态",
        "keep an eye on",
        "monitor",
        "watch for",
    ]

    /// 后台调研（`.backgroundResearch`）特征词
    private static let backgroundResearchKeywords: [String] = [
        "查下",
        "查一下",
        "查查",
        "摸排",
        "摸一下",
        "摸个底",
        "的底",
        "调研",
        "搜集",
        "收集",
        "盘点",
        "对比",
        "比对",
        "了解下",
        "研究下",
        "研究一下",
        "看看有哪些",
        "看看哪家",
        "看看谁家",
        "找找",
        "检索",
        "背景调查",
        "公开联系方式",
        "报价单",
        "竞品",
        "look into",
        "research",
        "find out",
    ]

    /// 涉及外部副作用（发消息、改配置、支付、删除等）的高风险关键词
    private static let highRiskKeywords: [String] = [
        // 外发消息 / 邮件 / 社媒
        "发邮件", "发送邮件", "群发", "发消息", "发微信", "发飞书", "发钉钉", "发短信",
        "回复客户", "联系客户", "私信", "发推", "发帖", "发布到", "推送给",
        // 修改配置 / 权限 / 生产环境
        "改配置", "修改配置", "线上配置", "生产环境", "改密码", "重置密码", "修改权限", "同步到线上",
        // 资金 / 支付 / 交易
        "付款", "支付", "打款", "转账", "下单", "购买", "充值", "续费", "扣费", "订阅", "买下", "退订",
        // 删除 / 破坏性写操作
        "删除", "清空", "抹掉", "卸载", "销毁", "强制覆盖", "drop ", "delete ",
        "send email", "send message", "pay ", "purchase", "update config",
    ]

    /// 纯粹提取随口意图候选（只读、零副作用）
    nonisolated static func extractCandidates(
        from text: String,
        conversationId: String? = nil,
        sourceMessageId: String? = nil,
        triggeredToolNames: Set<String> = [],
        now: Date = Date()
    ) -> [AmberIntentCandidate] {
        guard !AmberIntentInboxStore.hasExplicitDelegationTool(triggeredToolNames) else {
            return []
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return [] }

        let clauses = splitIntoCandidateClauses(trimmed)
        var results: [AmberIntentCandidate] = []
        var seenFingerprints: Set<String> = []

        for clause in clauses {
            guard results.count < maxCandidatesPerMessage else { break }
            guard let candidate = evaluateClause(
                clause,
                conversationId: conversationId,
                sourceMessageId: sourceMessageId,
                now: now
            ) else {
                continue
            }
            let fp = AmberIntentInboxStore.deduplicationFingerprint(candidate.title)
            guard !fp.isEmpty, !seenFingerprints.contains(fp) else { continue }
            seenFingerprints.insert(fp)
            results.append(candidate)
        }

        return results
    }

    // MARK: - Clause Splitting & Evaluation

    private nonisolated static func splitIntoCandidateClauses(_ text: String) -> [String] {
        // 先按换行、句号、分号、感叹号、问号切分主句
        let sentenceSeparators = CharacterSet(charactersIn: "\n\r。；;！!？?")
        let rawSentences = text.components(separatedBy: sentenceSeparators)
        var clauses: [String] = []

        for sentence in rawSentences {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            // 如果单句内部用逗号连接了前半句闲聊 + 后半句“回头得/顺便/晚点得/还得/有空帮我”等转折，拆出随口子句
            let subParts = splitOnCasualConjunctions(s)
            clauses.append(contentsOf: subParts)
        }
        return clauses
    }

    private nonisolated static func splitOnCasualConjunctions(_ sentence: String) -> [String] {
        let commaParts = sentence.components(separatedBy: CharacterSet(charactersIn: "，,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard commaParts.count > 1 else { return [sentence] }

        var merged: [String] = []
        var current = ""

        for part in commaParts {
            if matchesCasualCue(part) {
                if !current.isEmpty {
                    merged.append(current)
                }
                current = part
            } else if current.isEmpty {
                current = part
            } else {
                current += "，" + part
            }
        }
        if !current.isEmpty {
            merged.append(current)
        }
        return merged
    }

    private nonisolated static func matchesCasualCue(_ clause: String) -> Bool {
        let lowered = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in casualCuePrefixes {
            if lowered.hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        for marker in casualInfixMarkers {
            if lowered.contains(marker.lowercased()) {
                return true
            }
        }
        return false
    }

    private nonisolated static func evaluateClause(
        _ rawClause: String,
        conversationId: String?,
        sourceMessageId: String?,
        now: Date
    ) -> AmberIntentCandidate? {
        let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clause.count >= 5 else { return nil }

        // 排除显式立即执行指令
        let lowered = clause.lowercased()
        for prefix in immediateDirectCommandPrefixes {
            if lowered.hasPrefix(prefix.lowercased()) {
                return nil
            }
        }

        // 必须命中随口提及/延后待办/顺手盯梢特征
        guard matchesCasualCue(clause) else {
            return nil
        }

        // 提炼精简意图标题
        let refinedTitle = refineIntentTitle(from: clause)
        guard refinedTitle.count >= 4 else { return nil }

        // 判定分类与风险等级
        let kind = classifyKind(clause: clause, refinedTitle: refinedTitle)
        let riskLevel = classifyRiskLevel(clause: clause, refinedTitle: refinedTitle)
        let prompt = buildSuggestedPrompt(
            title: refinedTitle,
            sourceQuote: clause,
            kind: kind,
            riskLevel: riskLevel
        )

        return AmberIntentCandidate(
            title: refinedTitle,
            sourceQuote: clause,
            conversationId: conversationId,
            sourceMessageId: sourceMessageId,
            suggestedKind: kind,
            suggestedPrompt: prompt,
            riskLevel: riskLevel,
            status: .pending,
            createdAt: now
        )
    }

    /// 将口语化的随口原话提炼为干净、精简的交办意图标题
    /// 例如：
    /// - “对了，回头得摸一下海外潜在客户公开联系方式的底” → “摸排海外潜在客户公开联系方式”
    /// - “顺便留意下下周国内油价调价窗口” → “跟进下周国内油价调价窗口”
    nonisolated static func refineIntentTitle(from clause: String) -> String {
        var working = clause.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 剥离句首口语语气词与连接词
        let leadingFillers = [
            "对了，", "对了,", "对了",
            "话说，", "话说,", "话说",
            "不过，", "不过,", "不过",
            "另外，", "另外,", "另外",
            "还有，", "还有,", "还有",
            "顺便说一句，", "顺便说下，",
            "哎，", "诶，", "嗯，", "那什么，",
        ]
        var strippedFiller = true
        while strippedFiller {
            strippedFiller = false
            for filler in leadingFillers {
                if working.hasPrefix(filler) {
                    working = String(working.dropFirst(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    strippedFiller = true
                    break
                }
            }
        }

        // 2. 若句中含有“回头得/有空帮我/晚点得/顺便留意下/还得”等引导词，截取引导词及其核心动作部分
        for prefix in casualCuePrefixes {
            if working.lowercased().hasPrefix(prefix.lowercased()) {
                working = String(working.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            } else if let range = working.range(of: prefix, options: [.caseInsensitive]) {
                working = String(working[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 3. 处理第二层辅助前缀（如“帮我”“我去”“去”“再”）
        let secondaryPrefixes = ["帮我去", "帮我再", "帮我", "替我", "我去", "我再", "去把", "先把", "去"]
        for sec in secondaryPrefixes {
            if working.hasPrefix(sec), working.count > sec.count + 2 {
                working = String(working.dropFirst(sec.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 4. 去掉句尾口语助词（“吧”“呀”“哈”“呢”“啊”“先”“才行”）
        let trailingParticles = ["才行", "再说", "一下吧", "一下哈", "一下呢", "吧", "呀", "哈", "呢", "啊", "喔", "哦"]
        for particle in trailingParticles {
            if working.hasSuffix(particle), working.count > particle.count + 2 {
                working = String(working.dropLast(particle.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 5. 口语动作规范化（如“摸一下…的底” → “摸排…”、“留意下…” → “跟进…”、“查下…” → “调研/查询…”）
        if working.hasPrefix("摸一下"), working.hasSuffix("的底") {
            let core = working
                .dropFirst("摸一下".count)
                .dropLast("的底".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !core.isEmpty {
                working = "摸排" + core
            }
        } else if working.hasPrefix("摸一摸"), working.hasSuffix("的底") {
            let core = working
                .dropFirst("摸一摸".count)
                .dropLast("的底".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !core.isEmpty {
                working = "摸排" + core
            }
        } else if working.hasPrefix("留意下") {
            working = "跟进" + String(working.dropFirst("留意下".count))
        } else if working.hasPrefix("留意一下") {
            working = "跟进" + String(working.dropFirst("留意一下".count))
        } else if working.hasPrefix("盯着点") {
            working = "跟进" + String(working.dropFirst("盯着点".count))
        } else if working.hasPrefix("查下") {
            working = "梳理并查询" + String(working.dropFirst("查下".count))
        } else if working.hasPrefix("查一下") {
            working = "梳理并查询" + String(working.dropFirst("查一下".count))
        } else if working.hasPrefix("看看") {
            working = "调研" + String(working.dropFirst("看看".count))
        }

        // 6. 若原句是“顺便留意下…”且开头已被剥离“顺便留意下”，补足动词“跟进”
        if !startsWithActionVerb(working), clause.contains("留意") || clause.contains("盯着") || clause.contains("调价窗口") {
            working = "跟进" + working
        }

        return working.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private nonisolated static func startsWithActionVerb(_ text: String) -> Bool {
        let verbs = [
            "摸排", "跟进", "调研", "梳理", "查询", "整理", "搜集", "收集", "汇总",
            "对比", "比对", "盘点", "核对", "检查", "关注", "盯", "准备", "起草",
            "发", "改", "修改", "更新", "删除", "清空", "购买", "下单", "支付", "续费",
            "look", "research", "check", "monitor", "watch", "prepare", "draft",
        ]
        let lowered = text.lowercased()
        return verbs.contains { lowered.hasPrefix($0) }
    }

    nonisolated static func classifyKind(
        clause: String,
        refinedTitle: String
    ) -> AmberIntentCandidate.Kind {
        let combined = (clause + " " + refinedTitle).lowercased()

        for keyword in scheduledWatchKeywords {
            if combined.contains(keyword.lowercased()) {
                return .scheduledWatch
            }
        }
        for keyword in backgroundResearchKeywords {
            if combined.contains(keyword.lowercased()) {
                return .backgroundResearch
            }
        }
        return .actionTodo
    }

    nonisolated static func classifyRiskLevel(
        clause: String,
        refinedTitle: String
    ) -> AmberIntentCandidate.RiskLevel {
        let combined = (clause + " " + refinedTitle).lowercased()
        for keyword in highRiskKeywords {
            if combined.contains(keyword.lowercased()) {
                return .requiresApproval
            }
        }
        return .low
    }

    nonisolated static func buildSuggestedPrompt(
        title: String,
        sourceQuote: String,
        kind: AmberIntentCandidate.Kind,
        riskLevel: AmberIntentCandidate.RiskLevel
    ) -> String {
        let safetyConstraint: String
        switch riskLevel {
        case .low:
            safetyConstraint = "请仅执行只读检索、分析与整理，不要执行任何外部修改或外发动作。"
        case .requiresApproval:
            safetyConstraint = "【高风险保护】该事项涉及外部副作用（外发、修改配置、支付或删除），请仅准备方案或草稿，在执行任何真实外部动作前必须停下等待用户明确确认。"
        }

        switch kind {
        case .backgroundResearch:
            return "请围绕「\(title)」开展后台调研（背景原话：\"\(sourceQuote)\"），汇总关键事实、来源依据与可执行结论。\(safetyConstraint)"
        case .scheduledWatch:
            return "请持续盯梢并跟进「\(title)」（背景原话：\"\(sourceQuote)\"），关注最新动态与关键时间窗口，有实质变化时向我汇报。\(safetyConstraint)"
        case .actionTodo:
            return "请协助推进待办事项「\(title)」（背景原话：\"\(sourceQuote)\"），先梳理执行步骤与所需材料并给出初稿。\(safetyConstraint)"
        }
    }

    // MARK: - Jev Batch Extension Interface

    static let jevBatchPartId = "casual_intent_inbox"

    /// 构造可并入 Jev 批处理的随口意图复核 Part（可选扩展接口）。
    /// 绝不自动执行后台任务，仅用于辅助校准候选有效性、分类与风险标注。
    @MainActor
    static func makeJevBatchPart(
        candidate: AmberIntentCandidate,
        settings: IOSJevSettings,
        partId: String = jevBatchPartId
    ) -> IOSJevBatchPart {
        let state = [
            "用户原话摘录：\(String(candidate.sourceQuote.prefix(300)))",
            "本地提炼标题：\(String(candidate.title.prefix(120)))",
            "本地建议类型：\(candidate.suggestedKind.rawValue)",
            "本地风险分级：\(candidate.riskLevel.rawValue)",
        ].joined(separator: "\n")

        let kindOptions: [String: String?] = [
            AmberIntentCandidate.Kind.backgroundResearch.rawValue: "后台调研（搜集信息、摸排资料、对比分析）",
            AmberIntentCandidate.Kind.scheduledWatch.rawValue: "持续盯梢（价格窗口、动态跟踪、定时观察）",
            AmberIntentCandidate.Kind.actionTodo.rawValue: "普通待办事项（整理文档、备忘事项）",
            "none": "纯属闲聊感叹，不应记为候选待办",
        ]

        let questions = [
            IOSJevQuestion.choice(
                id: "intent_kind",
                options: kindOptions,
                instructions: "判断该原话是否包含值得记入收件箱的候选待办，并选择最匹配的类型；若纯属无行动意义的闲聊则选 none。"
            ),
            IOSJevQuestion.noul(
                id: "requires_approval",
                instructions: "判断：该事项若执行是否涉及外发消息、修改配置、花钱交易或删除数据等高风险副作用（是=true）。"
            ),
        ]

        return IOSJevBatchPart(
            id: partId,
            useCase: .subagentIntent,
            requiredScopes: [.selectedTaskText],
            state: state,
            questions: questions,
            cacheKey: settings.effectiveMode(for: .subagentIntent) == .active
                ? "casual_intent_inbox" : "casual_intent_inbox_shadow"
        )
    }

    /// 将 Jev 批处理结果安全地合并回候选条目：
    /// - 若 Jev 明确判定为 `none`，返回 `nil`（过滤掉误报闲聊）；
    /// - 风险等级遵循**单向收紧原则**：本地已判定为 `.requiresApproval` 的高风险项，绝不被 Jev 降级为 `.low`。
    nonisolated static func applyJevDecision(
        _ decision: IOSJevDecision,
        to candidate: AmberIntentCandidate,
        approvalProbabilityFloor: Double = 0.5
    ) -> AmberIntentCandidate? {
        var updated = candidate

        if let kindAnswer = decision.answers.first(where: { $0.id == "intent_kind" }),
           kindAnswer.type == "choice",
           let choice = kindAnswer.choice {
            if choice == "none" {
                return nil
            }
            if let refinedKind = AmberIntentCandidate.Kind(rawValue: choice) {
                updated.suggestedKind = refinedKind
            }
        }

        if let riskAnswer = decision.answers.first(where: { $0.id == "requires_approval" }),
           riskAnswer.type == "noul",
           let prob = riskAnswer.noul,
           prob.isFinite,
           prob >= approvalProbabilityFloor {
            updated.riskLevel = .requiresApproval
        }

        // 单向收紧：若原始候选已是 requiresApproval，绝不降级
        if candidate.riskLevel == .requiresApproval {
            updated.riskLevel = .requiresApproval
        }

        if updated.suggestedKind != candidate.suggestedKind || updated.riskLevel != candidate.riskLevel {
            updated.suggestedPrompt = buildSuggestedPrompt(
                title: updated.title,
                sourceQuote: updated.sourceQuote,
                kind: updated.suggestedKind,
                riskLevel: updated.riskLevel
            )
        }
        return updated
    }
}
