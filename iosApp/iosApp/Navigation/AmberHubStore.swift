import Foundation
import Observation
import Shared
import SwiftUI

// MARK: - Amber Hub & Smart Collection Models (iOS Client Seam for Hub / Supertag Architecture)

enum AmberHubMemoryPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Default: prioritizes hub memories while sharing global user preferences.
    case sharedWithGlobal = "SHARED_WITH_GLOBAL"
    /// Strict sandbox: isolated memories for fiction writing, client projects, or sensitive repos.
    case hubIsolated = "HUB_ISOLATED"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .sharedWithGlobal:
            return IOSAppLocalization.string("与全局记忆互通", defaultValue: "与全局记忆互通")
        case .hubIsolated:
            return IOSAppLocalization.string("独立记忆沙箱", defaultValue: "独立记忆沙箱")
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .sharedWithGlobal:
            return IOSAppLocalization.string("互通记忆", defaultValue: "互通记忆")
        case .hubIsolated:
            return IOSAppLocalization.string("独立记忆", defaultValue: "独立记忆")
        }
    }
}

enum AmberHubTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case general = "GENERAL"
    case coding = "CODING"
    case novel = "NOVEL"
    case research = "RESEARCH"

    var id: String { rawValue }
}

struct AmberHubItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var slug: String
    var title: String
    var thesis: String
    var template: AmberHubTemplate
    var memoryPolicy: AmberHubMemoryPolicy
    var pinnedSupertags: [String]
    var conversationIds: [String]
    var taskIds: [String]
    var memoryCountHint: Int
    var documentCountHint: Int
    var statusSummaryOverride: String?
    var createdAtMs: Int64
    var updatedAtMs: Int64

    init(
        id: String = UUID().uuidString.lowercased(),
        slug: String? = nil,
        title: String,
        thesis: String = "",
        template: AmberHubTemplate = .general,
        memoryPolicy: AmberHubMemoryPolicy = .sharedWithGlobal,
        pinnedSupertags: [String] = [],
        conversationIds: [String] = [],
        taskIds: [String] = [],
        memoryCountHint: Int = 0,
        documentCountHint: Int = 0,
        statusSummaryOverride: String? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.id = id
        self.slug = slug ?? Self.makeSlug(from: title)
        self.title = title
        self.thesis = thesis
        self.template = template
        self.memoryPolicy = memoryPolicy
        self.pinnedSupertags = pinnedSupertags
        self.conversationIds = conversationIds
        self.taskIds = taskIds
        self.memoryCountHint = memoryCountHint
        self.documentCountHint = documentCountHint
        self.statusSummaryOverride = statusSummaryOverride
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    static func makeSlug(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(allowed).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "hub-\(UUID().uuidString.prefix(6).lowercased())" : collapsed
    }
}

struct AmberSmartCollectionItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var primaryTag: String
    var itemCount: Int
    var conversationIds: [String]
    var memoryCount: Int
    var digest: String
    var template: AmberHubTemplate
    var promotionSuggested: Bool

    var compactSummaryItem: String {
        "\(title) (\(itemCount))"
    }

    var conversationCount: Int { itemCount }

    var sampleKeywords: [String] {
        [primaryTag, digest].filter { !$0.isEmpty }
    }
}

// MARK: - Unified Task Row Model (Real Delegated / Background / Scheduled Work Only)

enum AmberUnifiedTaskPhase: String, Equatable, Sendable {
    /// Waiting on the user: approval, failure that needs a decision, interruption.
    case needsAttention
    /// Actually executing right now in a durable owner.
    case running
    /// Planned and waiting for its time or event. Not progress, not a failure.
    case scheduled
    case completed
    case timedOutOrFailedTerminal
    case cancelled

    var isRecentTerminal: Bool {
        switch self {
        case .completed, .timedOutOrFailedTerminal, .cancelled:
            return true
        case .needsAttention, .running, .scheduled:
            return false
        }
    }
}

/// What the work is, in the user's words rather than in the transport's.
/// Only these three families belong in the task panel at all.
enum AmberTaskOwnership: String, Equatable, Sendable {
    case delegated
    case backgroundRun
    case scheduledMonitor

    var title: String {
        switch self {
        case .delegated:
            return IOSAppLocalization.string("交办", defaultValue: "交办")
        case .backgroundRun:
            return IOSAppLocalization.string("后台", defaultValue: "后台")
        case .scheduledMonitor:
            return IOSAppLocalization.string("定时", defaultValue: "定时")
        }
    }
}

/// Where a card's tap lands. Every case maps onto a surface that already owns
/// the work, so a card can never open a conversation invented for it.
enum AmberTaskDestination: Equatable, Sendable {
    case cloudTaskDetail(requestId: String)
    case subAgentConversation(conversationId: String)
    case executionRecord(recordId: String)
    case wakeConversation(conversationId: String)
    case macBoard
    case none
}

struct AmberUnifiedTaskFollowup: Equatable, Sendable {
    let id: String
    let title: String
    let reason: String?
    let hubId: String?
    let cloudRequestId: String?
}

/// An in-place decision or recovery action offered on a task card in `等你处理`.
struct AmberTaskQuickDecision: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case approveAndContinue
        case adjustDirection
        case confirmApproval
        case retry
        case openDetail
    }

    let id: String
    let title: String
    let kind: Kind
    /// Concrete follow-up instruction passed to the chat composer when selected.
    let followupInstruction: String?

    init(
        id: String? = nil,
        title: String,
        kind: Kind,
        followupInstruction: String? = nil
    ) {
        self.id = id ?? "\(kind.rawValue):\(title)"
        self.title = title
        self.kind = kind
        self.followupInstruction = followupInstruction
    }

    var isPrimary: Bool {
        switch kind {
        case .approveAndContinue, .confirmApproval, .retry:
            return true
        case .adjustDirection, .openDetail:
            return false
        }
    }
}

/// Structured deliverable summary extracted from a sub-agent or background task's Markdown output.
struct AmberDeliverableSummary: Equatable, Sendable {
    /// Clean single-sentence conclusion stripped of internal headers (`# Settlement Report`, etc.).
    let headline: String?
    /// 1–3 structured key takeaway bullets ready for direct scanning in the task panel.
    let bullets: [String]
    /// Specific question or stage checkpoint awaiting the user's decision, when present.
    let decisionPrompt: String?
    /// True when the output explicitly marks a decision checkpoint (`[待拍板]`, `等待拍板`, `needs_decision`, etc.).
    let needsDecision: Bool
}

struct AmberUnifiedTaskItem: Identifiable, Equatable {
    enum SourceKind: Equatable {
        case cloudTask(String)
        case localSubAgent(String)
        case executionRecord(String)
        case wakeTask(String)
        case gatewayBoardItem(String)
        case gatewaySchedule(String)
    }

    let id: String
    /// The delegated intent, taken from the owning record's own title.
    let title: String
    /// The current stage, in the owning record's real words. Never a made-up percent.
    let subtitle: String
    let statusText: String
    let actionButtonTitle: String?
    let phase: AmberUnifiedTaskPhase
    let ownership: AmberTaskOwnership
    let hubId: String?
    let updatedAt: Date
    /// The most recent real conclusion the owner holds, nil when it has none yet.
    let resultText: String?
    /// Concrete checkpoint question or prior-stage summary awaiting the user's decision.
    let decisionPrompt: String?
    /// Quick decision options offered inline when the task is waiting on the user.
    let quickActions: [AmberTaskQuickDecision]
    /// 1–3 structured deliverable takeaways extracted from the result Markdown/summary.
    let deliverableBullets: [String]
    /// Full raw Markdown report when available, for the single-layer deliverable preview.
    let rawResultMarkdown: String?
    let nextRunAt: Date?
    let destination: AmberTaskDestination
    let source: SourceKind

    var statusBadgeText: String { statusText }
    var actionTitle: String? { actionButtonTitle }

    var isNeedsDecision: Bool {
        statusText == "等我拍板" || (decisionPrompt?.isEmpty == false)
    }

    var hasDeliverablePreview: Bool {
        (resultText?.isEmpty == false)
            || !deliverableBullets.isEmpty
            || (rawResultMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    func applyingQuickDecision(_ decision: AmberTaskQuickDecision) -> AmberUnifiedTaskItem {
        AmberUnifiedTaskItem(
            id: id,
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            actionButtonTitle: decision.followupInstruction ?? decision.title,
            phase: phase,
            ownership: ownership,
            hubId: hubId,
            updatedAt: updatedAt,
            resultText: resultText,
            decisionPrompt: decisionPrompt,
            quickActions: quickActions,
            deliverableBullets: deliverableBullets,
            rawResultMarkdown: rawResultMarkdown,
            nextRunAt: nextRunAt,
            destination: destination,
            source: source
        )
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        statusText: String,
        actionButtonTitle: String? = nil,
        phase: AmberUnifiedTaskPhase,
        ownership: AmberTaskOwnership,
        hubId: String? = nil,
        updatedAt: Date = Date(),
        resultText: String? = nil,
        decisionPrompt: String? = nil,
        quickActions: [AmberTaskQuickDecision] = [],
        deliverableBullets: [String] = [],
        rawResultMarkdown: String? = nil,
        nextRunAt: Date? = nil,
        destination: AmberTaskDestination = .none,
        source: SourceKind
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.actionButtonTitle = actionButtonTitle
        self.phase = phase
        self.ownership = ownership
        self.hubId = hubId
        self.updatedAt = updatedAt
        self.resultText = resultText
        self.decisionPrompt = decisionPrompt
        self.quickActions = quickActions
        self.deliverableBullets = deliverableBullets
        self.rawResultMarkdown = rawResultMarkdown
        self.nextRunAt = nextRunAt
        self.destination = destination
        self.source = source
    }
}

// MARK: - AmberHubStore

@MainActor
@Observable
final class AmberHubStore {
    static let shared = AmberHubStore()

    private enum Keys {
        static let hubs = "app.amber.ios.hubs.v1"
        static let activeHubId = "app.amber.ios.hubs.activeId.v1"
        static let collections = "app.amber.ios.hubs.collections.v1"
        static let negativeTags = "app.amber.ios.hubs.negativeTags.v1"
    }

    var hubs: [AmberHubItem] = []
    var activeHubId: String? {
        didSet {
            if let activeHubId {
                defaults.set(activeHubId, forKey: Keys.activeHubId)
            } else {
                defaults.removeObject(forKey: Keys.activeHubId)
            }
        }
    }
    var smartCollections: [AmberSmartCollectionItem] = []
    private(set) var negativeTagStoplist: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.activeHubId = userDefaults.string(forKey: Keys.activeHubId)
        if let list = userDefaults.stringArray(forKey: Keys.negativeTags) {
            self.negativeTagStoplist = Set(list)
        }
        loadPersistedState()
    }

    convenience init(defaults: UserDefaults) {
        self.init(userDefaults: defaults)
    }

    var activeHub: AmberHubItem? {
        guard let activeHubId else { return nil }
        return hubs.first(where: { $0.id == activeHubId })
    }

    var upgradableCollectionCount: Int {
        smartCollections.filter(\.promotionSuggested).count
    }

    var collapsedCollectionsSummaryText: String {
        guard let first = smartCollections.first else {
            return IOSAppLocalization.string("自动归拢近期同主题对话与记忆", defaultValue: "自动归拢近期同主题对话与记忆")
        }
        if smartCollections.count == 1 {
            return first.compactSummaryItem
        }
        return "\(first.compactSummaryItem) 等 \(smartCollections.count) 项"
    }

    var smartCollectionsSummaryText: String? {
        smartCollections.isEmpty ? nil : collapsedCollectionsSummaryText
    }

    func selectHub(id: String?) {
        activeHubId = id
    }

    func selectHub(_ id: String?) {
        activeHubId = id
    }

    @discardableResult
    func promoteSmartCollectionToHub(
        _ collectionId: String,
        memoryPolicy: AmberHubMemoryPolicy? = nil
    ) -> AmberHubItem? {
        guard let collection = smartCollections.first(where: { $0.id == collectionId }) else {
            return nil
        }
        smartCollections.removeAll { $0.id == collectionId }
        let resolvedPolicy = memoryPolicy ?? (collection.template == .novel ? .hubIsolated : .sharedWithGlobal)
        let hub = AmberHubItem(
            title: collection.title,
            thesis: collection.digest,
            template: collection.template,
            memoryPolicy: resolvedPolicy,
            pinnedSupertags: [collection.primaryTag],
            conversationIds: collection.conversationIds,
            memoryCountHint: max(collection.memoryCount, collection.itemCount)
        )
        hubs.insert(hub, at: 0)
        activeHubId = hub.id
        persistState()
        return hub
    }

    func assignConversation(_ conversationId: String, toHub hubId: String?) {
        guard let hubId else { return }
        bindConversation(conversationId, toHub: hubId)
    }

    func assignTask(_ taskId: String, toHub hubId: String?) {
        guard let hubId else { return }
        bindTask(taskId, toHub: hubId)
    }

    func subtitle(
        for hub: AmberHubItem,
        conversations: [ConversationSummary],
        activeTasks: [AmberUnifiedTaskItem]
    ) -> String {
        subtitle(for: hub, activeTasks: activeTasks)
    }

    @discardableResult
    func createHub(
        title: String,
        thesis: String = "",
        template: AmberHubTemplate = .general,
        memoryPolicy: AmberHubMemoryPolicy = .sharedWithGlobal,
        pinnedSupertags: [String] = [],
        conversationIds: [String] = [],
        memoryCountHint: Int = 0,
        documentCountHint: Int = 0,
        statusSummaryOverride: String? = nil,
        makeActive: Bool = true
    ) -> AmberHubItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hub = AmberHubItem(
            title: cleanTitle.isEmpty ? "新中心" : cleanTitle,
            thesis: thesis.trimmingCharacters(in: .whitespacesAndNewlines),
            template: template,
            memoryPolicy: memoryPolicy,
            pinnedSupertags: pinnedSupertags,
            conversationIds: conversationIds,
            memoryCountHint: memoryCountHint,
            documentCountHint: documentCountHint,
            statusSummaryOverride: statusSummaryOverride
        )
        hubs.insert(hub, at: 0)
        if makeActive {
            activeHubId = hub.id
        }
        persistState()
        return hub
    }

    @discardableResult
    func promoteCollectionToHub(_ collection: AmberSmartCollectionItem) -> AmberHubItem {
        smartCollections.removeAll { $0.id == collection.id }
        let hub = AmberHubItem(
            title: collection.title,
            thesis: collection.digest,
            template: collection.template,
            memoryPolicy: collection.template == .novel ? .hubIsolated : .sharedWithGlobal,
            pinnedSupertags: [collection.primaryTag],
            conversationIds: collection.conversationIds,
            memoryCountHint: max(collection.memoryCount, collection.itemCount)
        )
        hubs.insert(hub, at: 0)
        activeHubId = hub.id
        persistState()
        return hub
    }

    func bindConversation(_ conversationId: String, toHub hubId: String) {
        guard let idx = hubs.firstIndex(where: { $0.id == hubId }) else { return }
        if !hubs[idx].conversationIds.contains(conversationId) {
            hubs[idx].conversationIds.append(conversationId)
            hubs[idx].updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
            persistState()
        }
    }

    func bindTask(_ taskId: String, toHub hubId: String) {
        guard let idx = hubs.firstIndex(where: { $0.id == hubId }) else { return }
        if !hubs[idx].taskIds.contains(taskId) {
            hubs[idx].taskIds.append(taskId)
            hubs[idx].updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
            persistState()
        }
    }

    func dismissCollection(id: String) {
        if let removed = smartCollections.first(where: { $0.id == id }) {
            negativeTagStoplist.insert(removed.primaryTag.lowercased())
            defaults.set(Array(negativeTagStoplist), forKey: Keys.negativeTags)
        }
        smartCollections.removeAll { $0.id == id }
        persistState()
    }

    /// Synthesizes a clean, honest second-line subtitle for a Hub card (`ios-argon-03-hubs-sheet.png`).
    func subtitle(
        for hub: AmberHubItem,
        activeTasks: [AmberUnifiedTaskItem]
    ) -> String {
        if let override = hub.statusSummaryOverride, !override.isEmpty {
            return override
        }
        let hubTasks = activeTasks.filter { $0.hubId == hub.id || (hub.id == activeHubId && $0.hubId == nil) }
        let runningCount = hubTasks.filter { $0.phase == .running || $0.phase == .needsAttention }.count

        if hub.memoryPolicy == .hubIsolated {
            if runningCount > 0 {
                return "\(hub.memoryPolicy.shortBadgeTitle) · \(runningCount) 项任务"
            }
            if hub.documentCountHint > 0 {
                return "\(hub.memoryPolicy.shortBadgeTitle) · \(hub.documentCountHint) 份设定与草稿"
            }
            return "\(hub.memoryPolicy.shortBadgeTitle) · 隔离上下文"
        }

        var parts: [String] = []
        if hub.documentCountHint > 0 {
            parts.append("\(hub.documentCountHint) 份资料")
        } else if hub.memoryCountHint > 0 {
            parts.append("\(hub.memoryCountHint) 条记忆")
        } else if !hub.conversationIds.isEmpty {
            parts.append("\(hub.conversationIds.count) 段对话")
        }

        if runningCount > 0 {
            let hasCloud = hubTasks.contains {
                if case .cloudTask = $0.source { return true }
                return $0.subtitle.contains("云端")
            }
            parts.append(hasCloud ? "\(runningCount) 项云端运行中" : "\(runningCount) 项任务")
        } else if !hub.taskIds.isEmpty {
            parts.append("\(hub.taskIds.count) 项任务")
        }

        if parts.isEmpty {
            return hub.thesis.isEmpty ? "长期空间 · 记忆与任务归拢" : hub.thesis
        }
        return parts.joined(separator: " · ")
    }

    /// Refreshes discovered Smart Collections from real conversation summaries without inventing fake items
    /// when the user already has seeded collections.
    func syncCollectionsFromConversations(_ summaries: [ConversationSummary]) {
        guard smartCollections.isEmpty, hubs.isEmpty else { return }
        var buckets: [String: [ConversationSummary]] = [:]
        for summary in summaries {
            let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let category = Self.inferClusterTopic(from: title)
            guard let category, !negativeTagStoplist.contains(category.tag.lowercased()) else { continue }
            buckets[category.title, default: []].append(summary)
        }
        var discovered: [AmberSmartCollectionItem] = []
        for (clusterTitle, items) in buckets where items.count >= 2 {
            discovered.append(
                AmberSmartCollectionItem(
                    id: "cluster-\(AmberHubItem.makeSlug(from: clusterTitle))",
                    title: clusterTitle,
                    primaryTag: "#\(clusterTitle)",
                    itemCount: items.count,
                    conversationIds: items.map { $0.id.toHexDashString() },
                    memoryCount: 0,
                    digest: "自动聚合 \(items.count) 段相关话题",
                    template: .general,
                    promotionSuggested: items.count >= 3
                )
            )
        }
        if !discovered.isEmpty {
            smartCollections = discovered.sorted { $0.itemCount > $1.itemCount }
            persistState()
        }
    }

    private static func inferClusterTopic(from title: String) -> (title: String, tag: String)? {
        let lower = title.lowercased()
        if lower.contains("ssh") || lower.contains("跳板") || lower.contains("服务器") {
            return ("SSH 运维", "#ops/ssh")
        }
        if lower.contains("京都") || lower.contains("旅行") || lower.contains("行程") || lower.contains("出差") {
            return ("京都旅行", "#life/trip")
        }
        if lower.contains("模型") || lower.contains("训练") || lower.contains("视频") || lower.contains("检测") {
            return ("机房视觉检测", "#dev/vision")
        }
        if lower.contains("小说") || lower.contains("章节") || lower.contains("设定") {
            return ("小说创作", "#creative/novel")
        }
        return nil
    }

    func replaceForPreview(
        hubs: [AmberHubItem],
        activeHubId: String?,
        collections: [AmberSmartCollectionItem]
    ) {
        self.hubs = hubs
        self.activeHubId = activeHubId
        self.smartCollections = collections
        persistState()
    }

    private func loadPersistedState() {
        if let data = defaults.data(forKey: Keys.hubs),
           let decoded = try? JSONDecoder().decode([AmberHubItem].self, from: data) {
            self.hubs = decoded
        }
        if let data = defaults.data(forKey: Keys.collections),
           let decoded = try? JSONDecoder().decode([AmberSmartCollectionItem].self, from: data) {
            self.smartCollections = decoded
        }
    }

    private func persistState() {
        if let data = try? JSONEncoder().encode(hubs) {
            defaults.set(data, forKey: Keys.hubs)
        }
        if let data = try? JSONEncoder().encode(smartCollections) {
            defaults.set(data, forKey: Keys.collections)
        }
    }
}

// MARK: - Unified Task Builder (Real Delegated / Background / Scheduled Work Only)

/// The panel shows work a durable owner actually holds:
/// 用户明确交办的事项、后台编排与执行任务、定时或持续监控任务。
/// An ordinary assistant turn that happens to call several tools is *not* a
/// task; that progress line stays inside the conversation stream.
enum AmberUnifiedTaskBuilder {
    struct Groups: Equatable {
        var needsAttention: [AmberUnifiedTaskItem] = []
        var running: [AmberUnifiedTaskItem] = []
        var scheduled: [AmberUnifiedTaskItem] = []
        var recent: [AmberUnifiedTaskItem] = []

        var isEmpty: Bool {
            needsAttention.isEmpty && running.isEmpty && scheduled.isEmpty && recent.isEmpty
        }

        var activeCount: Int { running.count + scheduled.count }
    }

    @MainActor
    static func buildTasks(
        gateway: MacGatewayStore,
        subAgentStore: IOSSubAgentActivityStore,
        taskStore: IOSAdvancedTaskStore = .shared,
        wakeStore: IOSWakeTaskStore = .shared,
        hubStore: AmberHubStore,
        filterHubId: String? = nil
    ) -> Groups {
        var all: [AmberUnifiedTaskItem] = []
        var seenTitles = Set<String>()
        let defaultHubId = hubStore.activeHubId

        // 1. Cloud work items the user explicitly handed off (/v2/work-items).
        for record in gateway.cloudTasks {
            let rawMarkdown = record.detail?.resultMarkdown
            let progressText = record.effectiveWorkItem?.progress
            let summary = Self.extractDeliverableSummary(from: rawMarkdown ?? progressText)
            let progressDecision = Self.extractDeliverableSummary(from: progressText)
            let isAwaitingDecision = record.state == .waiting
                || summary.needsDecision
                || progressDecision.needsDecision

            let phase: AmberUnifiedTaskPhase
            let statusText: String
            let subtitle: String
            var actionTitle: String? = nil
            var decisionPrompt: String? = nil
            var quickActions: [AmberTaskQuickDecision] = []

            if record.needsSubmissionRetry {
                phase = .needsAttention
                statusText = "提交未完成"
                subtitle = (record.lastError ?? "网络超时，请求 ID 已保留") + " · 云端"
                actionTitle = "重试"
                quickActions = Self.failureQuickActions(primaryTitle: "重试")
            } else if record.state == .failed {
                phase = .needsAttention
                statusText = "执行失败"
                let reason = Self.compactReason(record.detail?.failure ?? record.lastError ?? "云端执行异常")
                subtitle = "\(reason) · 云端"
                let suggested = Self.suggestedActionButtonTitle(for: record.displayTitle, reason: reason)
                actionTitle = suggested
                quickActions = Self.failureQuickActions(primaryTitle: suggested)
            } else if isAwaitingDecision && record.state != .cancelled {
                phase = .needsAttention
                statusText = "等我拍板"
                decisionPrompt = summary.decisionPrompt
                    ?? progressDecision.decisionPrompt
                    ?? summary.headline
                    ?? progressDecision.headline
                    ?? "前序步骤已完成，等待拍板"
                let stageSummary = summary.headline
                    ?? progressDecision.headline
                    ?? progressText
                    ?? "前序阶段已就绪"
                subtitle = "\(stageSummary) · 云端"
                actionTitle = "拍板继续"
                quickActions = Self.decisionQuickActions(decisionPrompt: decisionPrompt)
            } else if record.state == .cancelled {
                phase = .cancelled
                statusText = "已取消"
                subtitle = "云端后台 · 已取消"
            } else if record.state == .completed {
                phase = .completed
                statusText = "已完成"
                if let headline = summary.headline, !headline.isEmpty {
                    subtitle = headline
                } else {
                    subtitle = "云端后台 · 已完成"
                }
            } else if gateway.busyCloudTaskIds.contains(record.requestId) {
                phase = .running
                statusText = "停止请求中"
                subtitle = "云端后台 · 正在等待服务端确认"
            } else if record.state == .queued {
                phase = .running
                statusText = "已受理"
                subtitle = "云端后台 · 已受理待启动"
            } else {
                phase = .running
                statusText = "运行中"
                if let progress = progressText, !progress.isEmpty {
                    subtitle = "云端后台 · \(progress)"
                } else {
                    subtitle = "云端后台 · \(record.state?.displayTitle ?? "执行中")"
                }
            }

            let matchedHubId = hubStore.hubs.first(where: { $0.taskIds.contains(record.requestId) })?.id ?? defaultHubId
            seenTitles.insert(record.displayTitle)
            all.append(
                AmberUnifiedTaskItem(
                    id: "cloud:\(record.requestId)",
                    title: record.displayTitle,
                    subtitle: subtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    ownership: .delegated,
                    hubId: matchedHubId,
                    updatedAt: record.updatedAt,
                    resultText: summary.headline ?? Self.resultPreview(from: rawMarkdown),
                    decisionPrompt: decisionPrompt,
                    quickActions: quickActions,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: rawMarkdown,
                    destination: .cloudTaskDetail(requestId: record.requestId),
                    source: .cloudTask(record.requestId)
                )
            )
        }

        // 2. Local background orchestration runs: durable thread edges and agent
        // runs owned by the orchestration engine, not by the message list.
        for item in subAgentStore.items {
            let backingRecord = subAgentStore.taskRecord(for: item)
            let resolvedTitle = backingRecord?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = (resolvedTitle?.isEmpty == false) ? resolvedTitle! : item.title
            guard seenTitles.insert(displayTitle).inserted else { continue }

            let outcome = backingRecord.flatMap { $0.resultSummary.isEmpty ? nil : $0.resultSummary }
                ?? backingRecord.flatMap { $0.logTail.isEmpty ? nil : $0.logTail }
            let summary = Self.extractDeliverableSummary(from: outcome ?? item.statusDetail)
            let detailSummary = Self.extractDeliverableSummary(from: item.statusDetail)
            let metadataDecision = backingRecord?.metadata["decision_prompt"]
                ?? backingRecord?.metadata["checkpoint"]
            let metadataNeedsDecision = (backingRecord?.metadata["needs_decision"]?.lowercased() == "true")
                || (metadataDecision?.isEmpty == false)
            let hasDecisionCheckpoint = metadataNeedsDecision
                || summary.needsDecision
                || detailSummary.needsDecision

            let phase: AmberUnifiedTaskPhase
            let statusText: String
            var actionTitle: String? = nil
            var decisionPrompt: String? = nil
            var quickActions: [AmberTaskQuickDecision] = []

            switch item.status {
            case .queued:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .running
                    statusText = "已受理"
                }
            case .running:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .running
                    statusText = "运行中"
                }
            case .approvalRequired:
                phase = .needsAttention
                if hasDecisionCheckpoint {
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    statusText = "待你确认"
                    actionTitle = "去确认"
                    quickActions = Self.approvalQuickActions()
                }
            case .interrupted:
                phase = .needsAttention
                statusText = "等我拍板"
                actionTitle = "拍板继续"
            case .completed:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .completed
                    statusText = "已完成"
                }
            case .failed:
                if backingRecord?.retryable == true {
                    phase = .needsAttention
                    statusText = "执行失败"
                    actionTitle = "重试"
                    quickActions = Self.failureQuickActions(primaryTitle: "重试")
                } else {
                    phase = .timedOutOrFailedTerminal
                    statusText = "执行失败"
                    actionTitle = "重试"
                }
            case .timedOut:
                phase = .timedOutOrFailedTerminal
                statusText = item.statusTitle
                actionTitle = "重试"
            case .cancelled:
                phase = .cancelled
                statusText = "已取消"
            }

            if statusText == "等我拍板" {
                decisionPrompt = metadataDecision
                    ?? summary.decisionPrompt
                    ?? detailSummary.decisionPrompt
                    ?? summary.headline
                    ?? detailSummary.headline
                    ?? backingRecord?.objective
                    ?? "前序步骤已完成，等待拍板"
                quickActions = Self.decisionQuickActions(decisionPrompt: decisionPrompt)
            }

            let subagentSubtitle: String
            if statusText == "等我拍板" {
                if let headline = summary.headline, !headline.isEmpty, headline != decisionPrompt {
                    subagentSubtitle = headline
                } else if let objective = backingRecord?.objective.trimmingCharacters(in: .whitespacesAndNewlines),
                          !objective.isEmpty,
                          objective != displayTitle {
                    subagentSubtitle = "\(objective) · 本机后台"
                } else {
                    subagentSubtitle = "前序步骤已就绪 · 本机后台"
                }
            } else if phase == .completed, let headline = summary.headline, !headline.isEmpty {
                subagentSubtitle = headline
            } else if let detail = item.statusDetail, !detail.isEmpty {
                subagentSubtitle = detail
            } else if let objective = backingRecord?.objective.trimmingCharacters(in: .whitespacesAndNewlines),
                      !objective.isEmpty,
                      objective != displayTitle {
                subagentSubtitle = "\(objective) · 本机后台"
            } else {
                subagentSubtitle = "本机后台 · \(item.statusTitle)"
            }

            all.append(
                AmberUnifiedTaskItem(
                    id: "subagent:\(item.id)",
                    title: displayTitle,
                    subtitle: subagentSubtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    ownership: .backgroundRun,
                    hubId: defaultHubId,
                    updatedAt: item.endedAt ?? item.startedAt,
                    resultText: summary.headline ?? Self.resultPreview(from: outcome ?? backingRecord?.error),
                    decisionPrompt: decisionPrompt,
                    quickActions: quickActions,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: outcome,
                    destination: Self.subAgentDestination(taskId: item.taskId),
                    source: .localSubAgent(item.id)
                )
            )
        }

        // 3. Other durable background executions owned by the advanced task
        // store: model council, Remote SSH and embedded iSH jobs. Approval
        // receipts are decisions, not work, so they never become cards here.
        for record in taskStore.tasks
        where record.kind != .subAgent && record.kind != .toolApproval {
            guard seenTitles.insert(record.title).inserted else { continue }
            let outcome = record.resultSummary.isEmpty ? (record.logTail.isEmpty ? nil : record.logTail) : record.resultSummary
            let summary = Self.extractDeliverableSummary(from: outcome)
            let metadataDecision = record.metadata["decision_prompt"] ?? record.metadata["checkpoint"]
            let hasDecisionCheckpoint = (record.metadata["needs_decision"]?.lowercased() == "true")
                || (metadataDecision?.isEmpty == false)
                || summary.needsDecision

            let phase: AmberUnifiedTaskPhase
            let statusText: String
            var actionTitle: String? = record.canRetry ? "重试" : nil
            var decisionPrompt: String? = nil
            var quickActions: [AmberTaskQuickDecision] = []

            switch record.status {
            case .queued, .running:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .running
                    statusText = record.status.title
                }
            case .approvalRequired:
                phase = .needsAttention
                if hasDecisionCheckpoint {
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    statusText = "待你确认"
                    actionTitle = "去确认"
                    quickActions = Self.approvalQuickActions()
                }
            case .interrupted:
                phase = .needsAttention
                statusText = "等我拍板"
                actionTitle = "拍板继续"
            case .completed:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .completed
                    statusText = "已完成"
                }
            case .failed:
                if record.retryable {
                    phase = .needsAttention
                    statusText = "执行失败"
                    actionTitle = "重试"
                    quickActions = Self.failureQuickActions(primaryTitle: "重试")
                } else {
                    phase = .timedOutOrFailedTerminal
                    statusText = "执行失败"
                }
            case .timedOut:
                phase = .timedOutOrFailedTerminal
                statusText = record.status.title
            case .cancelled:
                phase = .cancelled
                statusText = "已取消"
            }

            if statusText == "等我拍板" {
                decisionPrompt = metadataDecision
                    ?? summary.decisionPrompt
                    ?? summary.headline
                    ?? (record.objective.isEmpty ? nil : record.objective)
                    ?? "前序步骤已完成，等待拍板"
                quickActions = Self.decisionQuickActions(decisionPrompt: decisionPrompt)
            }

            let execSubtitle: String
            if phase == .completed, let headline = summary.headline, !headline.isEmpty {
                execSubtitle = headline
            } else if statusText == "等我拍板", let headline = summary.headline, !headline.isEmpty, headline != decisionPrompt {
                execSubtitle = "\(record.kind.title) · \(headline)"
            } else if statusText == "执行失败", !record.error.isEmpty {
                execSubtitle = "\(Self.compactReason(record.error)) · \(record.kind.title)"
            } else {
                execSubtitle = "\(record.kind.title) · \(record.status.title)"
            }

            all.append(
                AmberUnifiedTaskItem(
                    id: "exec:\(record.id)",
                    title: record.title,
                    subtitle: execSubtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    ownership: .backgroundRun,
                    hubId: defaultHubId,
                    updatedAt: record.updatedAt,
                    resultText: summary.headline ?? Self.resultPreview(from: outcome ?? record.error),
                    decisionPrompt: decisionPrompt,
                    quickActions: quickActions,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: outcome,
                    destination: .executionRecord(recordId: record.id),
                    source: .executionRecord(record.id)
                )
            )
        }

        // 4. iOS-local scheduled and event-driven monitoring work.
        for task in wakeStore.tasks {
            let detail = task.lastMessage ?? task.resultText
            let summary = Self.extractDeliverableSummary(from: task.resultText ?? task.lastMessage)
            let hasDecisionCheckpoint = summary.needsDecision

            let phase: AmberUnifiedTaskPhase
            let statusText: String
            var actionTitle: String? = nil
            var decisionPrompt: String? = nil
            var quickActions: [AmberTaskQuickDecision] = []

            switch task.status {
            case .scheduled:
                phase = .scheduled
                statusText = task.status.title
            case .running:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .running
                    statusText = task.status.title
                }
            case .completed:
                if hasDecisionCheckpoint {
                    phase = .needsAttention
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                } else {
                    phase = .completed
                    statusText = "已完成"
                }
            case .failed:
                phase = .timedOutOrFailedTerminal
                statusText = "执行失败"
                actionTitle = "重试"
            case .cancelled:
                phase = .cancelled
                statusText = "已取消"
            case .interrupted:
                phase = .needsAttention
                statusText = "等我拍板"
                actionTitle = hasDecisionCheckpoint ? "拍板继续" : "重新安排"
            }

            if statusText == "等我拍板" {
                decisionPrompt = summary.decisionPrompt
                    ?? summary.headline
                    ?? detail
                    ?? "定时任务中断或跑完前序步骤，等待拍板"
                quickActions = Self.decisionQuickActions(
                    decisionPrompt: decisionPrompt,
                    primaryTitle: actionTitle ?? "拍板继续"
                )
            }

            let subtitle: String
            if phase == .completed, let headline = summary.headline, !headline.isEmpty {
                subtitle = headline
            } else if let detail, !detail.isEmpty {
                subtitle = "\(Self.compactReason(detail)) · 本机定时"
            } else if task.event != nil {
                subtitle = "等待「\(task.event!)」触发 · 本机定时"
            } else {
                subtitle = "本机定时 · \(task.status.title)"
            }
            seenTitles.insert(task.title)
            all.append(
                AmberUnifiedTaskItem(
                    id: "wake:\(task.id)",
                    title: task.title,
                    subtitle: subtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    ownership: .scheduledMonitor,
                    hubId: defaultHubId,
                    updatedAt: task.finishedAt ?? task.startedAt ?? task.createdAt,
                    resultText: summary.headline ?? Self.resultPreview(from: task.resultText),
                    decisionPrompt: decisionPrompt,
                    quickActions: quickActions,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: task.resultText,
                    nextRunAt: phase == .scheduled ? task.fireAt : nil,
                    destination: .wakeConversation(conversationId: task.conversationID),
                    source: .wakeTask(task.id)
                )
            )
        }

        // 5. Mac-owned schedules. `schedules` is authoritative and also covers
        // the disabled ones the board omits, so board schedule rows are skipped.
        for schedule in gateway.schedules ?? [] {
            let phase: AmberUnifiedTaskPhase = schedule.running ? .running
                : (schedule.enabled ? .scheduled : .cancelled)
            let summary = Self.extractDeliverableSummary(from: schedule.lastStatus)
            seenTitles.insert(schedule.name)
            all.append(
                AmberUnifiedTaskItem(
                    id: "schedule:\(schedule.id)",
                    title: schedule.name,
                    subtitle: schedule.enabled
                        ? "\(schedule.rule) · Mac" : "\(schedule.rule) · 已停用",
                    statusText: schedule.running ? "运行中" : (schedule.enabled ? "已排定" : "已停用"),
                    phase: phase,
                    ownership: .scheduledMonitor,
                    hubId: defaultHubId,
                    updatedAt: schedule.lastRunAt ?? schedule.nextRunAt ?? Date(timeIntervalSince1970: 0),
                    resultText: summary.headline ?? schedule.lastStatus,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: schedule.lastStatus,
                    nextRunAt: schedule.enabled ? schedule.nextRunAt : nil,
                    destination: .macBoard,
                    source: .gatewaySchedule(schedule.id)
                )
            )
        }

        // 6. Mac board runs and agent sessions.
        for boardItem in gateway.boardItems where boardItem.kind != .schedule {
            guard seenTitles.insert(boardItem.title).inserted else { continue }
            let summary = Self.extractDeliverableSummary(from: boardItem.detail)
            let phase: AmberUnifiedTaskPhase
            switch boardItem.column {
            case .needsYou: phase = .needsAttention
            case .running: phase = summary.needsDecision ? .needsAttention : .running
            case .scheduled: phase = .scheduled
            case .done:
                if boardItem.failed {
                    phase = .timedOutOrFailedTerminal
                } else if summary.needsDecision {
                    phase = .needsAttention
                } else {
                    phase = .completed
                }
            }
            let statusText: String
            var decisionPrompt: String? = nil
            var quickActions: [AmberTaskQuickDecision] = []
            var actionTitle: String? = nil

            switch phase {
            case .needsAttention:
                if boardItem.approval != nil {
                    statusText = "待你确认"
                    actionTitle = "去确认"
                    quickActions = Self.approvalQuickActions()
                } else {
                    statusText = "等我拍板"
                    actionTitle = "拍板继续"
                    decisionPrompt = summary.decisionPrompt ?? summary.headline ?? (boardItem.detail.isEmpty ? nil : boardItem.detail)
                    quickActions = Self.decisionQuickActions(decisionPrompt: decisionPrompt)
                }
            case .running: statusText = "运行中"
            case .scheduled: statusText = "已排定"
            case .completed: statusText = "已完成"
            case .timedOutOrFailedTerminal: statusText = "执行失败"
            case .cancelled: statusText = "已取消"
            }
            all.append(
                AmberUnifiedTaskItem(
                    id: "board:\(boardItem.id)",
                    title: boardItem.title,
                    subtitle: boardItem.detail.isEmpty ? "Mac" : "\(boardItem.detail) · Mac",
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    ownership: .backgroundRun,
                    hubId: defaultHubId,
                    updatedAt: boardItem.updatedAt,
                    resultText: phase == .completed ? summary.headline : nil,
                    decisionPrompt: decisionPrompt,
                    quickActions: quickActions,
                    deliverableBullets: summary.bullets,
                    rawResultMarkdown: boardItem.detail.isEmpty ? nil : boardItem.detail,
                    nextRunAt: boardItem.nextRunAt,
                    destination: .macBoard,
                    source: .gatewayBoardItem(boardItem.id)
                )
            )
        }

        let filtered = filterHubId == nil
            ? all
            : all.filter { $0.hubId == filterHubId }

        var groups = Groups()
        groups.needsAttention = filtered.filter { $0.phase == .needsAttention }
            .sorted { $0.updatedAt > $1.updatedAt }
        groups.running = filtered.filter { $0.phase == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
        groups.scheduled = filtered.filter { $0.phase == .scheduled }
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        groups.recent = Array(
            filtered.filter { $0.phase.isRecentTerminal }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.recentLimit)
        )
        return groups
    }

    /// A background run is either an orchestration child thread or a legacy
    /// advanced-task record; both already have a real detail surface.
    static func subAgentDestination(taskId: String) -> AmberTaskDestination {
        if taskId.hasPrefix("thread:") {
            return .subAgentConversation(conversationId: String(taskId.dropFirst("thread:".count)))
        }
        if taskId.hasPrefix("task:") {
            return .executionRecord(recordId: String(taskId.dropFirst("task:".count)))
        }
        return .none
    }

    static let recentLimit = 8
    static let resultPreviewLimit = 90
    static let deliverableBulletLimit = 3

    /// Status colour carries meaning only: accent for live work, amber for a
    /// wait on the user, red for a real failure, green for a finished result.
    @MainActor
    static func statusColor(for phase: AmberUnifiedTaskPhase) -> Color {
        switch phase {
        case .needsAttention:
            return AmberTheme.accentAmber
        case .running:
            return AmberTheme.accent
        case .scheduled:
            return AmberTheme.muted2
        case .completed:
            return AmberTheme.accentGreen
        case .timedOutOrFailedTerminal:
            return AmberTheme.accentRed
        case .cancelled:
            return AmberTheme.muted
        }
    }

    @MainActor
    static func statusColor(for item: AmberUnifiedTaskItem) -> Color {
        if item.phase == .needsAttention && item.statusText == "执行失败" {
            return AmberTheme.accentRed
        }
        return statusColor(for: item.phase)
    }

    static func decisionQuickActions(
        decisionPrompt: String?,
        primaryTitle: String = "拍板继续"
    ) -> [AmberTaskQuickDecision] {
        [
            AmberTaskQuickDecision(
                title: primaryTitle,
                kind: .approveAndContinue,
                followupInstruction: "拍板继续，按当前前序结论推进下一步"
            ),
            AmberTaskQuickDecision(
                title: "调整方向",
                kind: .adjustDirection,
                followupInstruction: "调整方向，先按以下补充要求修改"
            )
        ]
    }

    static func approvalQuickActions() -> [AmberTaskQuickDecision] {
        [
            AmberTaskQuickDecision(
                title: "去确认",
                kind: .confirmApproval,
                followupInstruction: "确认授权并继续执行"
            ),
            AmberTaskQuickDecision(
                title: "调整方向",
                kind: .adjustDirection,
                followupInstruction: "暂不授权，先调整执行方向"
            )
        ]
    }

    static func failureQuickActions(primaryTitle: String) -> [AmberTaskQuickDecision] {
        [
            AmberTaskQuickDecision(
                title: primaryTitle,
                kind: .retry,
                followupInstruction: primaryTitle
            ),
            AmberTaskQuickDecision(
                title: "调整方向",
                kind: .adjustDirection,
                followupInstruction: "换一种方案处理"
            )
        ]
    }

    static func recentSummaryText(_ recent: [AmberUnifiedTaskItem]) -> String {
        recentBreakdownText(for: recent)
    }

    static func recentBreakdownText(for recent: [AmberUnifiedTaskItem]) -> String {
        guard !recent.isEmpty else { return "" }
        let completedCount = recent.filter { $0.phase == .completed }.count
        let failedOrTimeoutCount = recent.filter { $0.phase == .timedOutOrFailedTerminal }.count
        let cancelledCount = recent.filter { $0.phase == .cancelled }.count

        var parts: [String] = []
        if completedCount > 0 {
            parts.append("\(completedCount) 项完成")
        }
        if failedOrTimeoutCount > 0 {
            parts.append("\(failedOrTimeoutCount) 项超时")
        }
        if cancelledCount > 0 {
            parts.append("\(cancelledCount) 项取消")
        }
        return parts.joined(separator: " · ")
    }

    private static func compactReason(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colonIdx = text.lastIndex(of: "：") {
            let after = text[text.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { text = after }
        }
        if text.hasPrefix("SSH ") {
            text = String(text.dropFirst(4))
        }
        text = text.replacingOccurrences(of: "格式校验未通过", with: "校验未通过")
        if text.count > 26 {
            return String(text.prefix(26)) + "…"
        }
        return text
    }

    private static func suggestedActionButtonTitle(for title: String, reason: String) -> String {
        let combined = (title + " " + reason).lowercased()
        if combined.contains("密钥") || combined.contains("私钥") || combined.contains("ssh") || combined.contains("key") {
            return "补充密钥"
        }
        if combined.contains("确认") || combined.contains("权限") || combined.contains("审批") {
            return "去确认"
        }
        return "去处理"
    }
}
