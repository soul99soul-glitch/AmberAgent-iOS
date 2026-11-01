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

// MARK: - Unified Task Row Model (Grouped by Goal & Status, Not Internal Channel)

enum AmberUnifiedTaskPhase: String, Equatable, Sendable {
    case needsAttention
    case running
    case completed
    case timedOutOrFailedTerminal
    case cancelled

    var isRecentTerminal: Bool {
        switch self {
        case .completed, .timedOutOrFailedTerminal, .cancelled:
            return true
        case .needsAttention, .running:
            return false
        }
    }
}

struct AmberUnifiedTaskFollowup: Equatable, Sendable {
    let id: String
    let title: String
    let reason: String?
    let hubId: String?
    let cloudRequestId: String?
}

struct AmberUnifiedTaskItem: Identifiable, Equatable {
    enum SourceKind: Equatable {
        case inChatSegment(ChatTaskRunSegment)
        case localSubAgent(String)
        case cloudTask(String)
        case gatewayBoardItem(String)

        static func == (lhs: SourceKind, rhs: SourceKind) -> Bool {
            switch (lhs, rhs) {
            case (.inChatSegment(let a), .inChatSegment(let b)):
                return a.id == b.id && a.rollupState == b.rollupState
            case (.localSubAgent(let a), .localSubAgent(let b)):
                return a == b
            case (.cloudTask(let a), .cloudTask(let b)):
                return a == b
            case (.gatewayBoardItem(let a), .gatewayBoardItem(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    let id: String
    let title: String
    let subtitle: String
    let statusText: String
    let actionButtonTitle: String?
    let phase: AmberUnifiedTaskPhase
    let hubId: String?
    let updatedAt: Date
    let source: SourceKind

    var statusBadgeText: String { statusText }
    var actionTitle: String? { actionButtonTitle }

    var underlyingSegment: ChatTaskRunSegment? {
        if case .inChatSegment(let seg) = source {
            return seg
        }
        return nil
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        statusText: String,
        actionButtonTitle: String?,
        phase: AmberUnifiedTaskPhase,
        hubId: String?,
        updatedAt: Date = Date(),
        source: SourceKind
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.actionButtonTitle = actionButtonTitle
        self.phase = phase
        self.hubId = hubId
        self.updatedAt = updatedAt
        self.source = source
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        category: AmberUnifiedTaskPhase,
        statusBadgeText: String,
        actionTitle: String? = nil,
        hubId: String? = nil,
        underlyingSegment: ChatTaskRunSegment? = nil,
        cloudTaskId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusBadgeText
        self.actionButtonTitle = actionTitle
        self.phase = category
        self.hubId = hubId
        self.updatedAt = Date()
        if let underlyingSegment {
            self.source = .inChatSegment(underlyingSegment)
        } else if let cloudTaskId {
            self.source = .cloudTask(cloudTaskId)
        } else {
            self.source = .localSubAgent(id)
        }
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

// MARK: - Unified Task Builder (Goals & Status Grouping)

enum AmberUnifiedTaskBuilder {
    @MainActor
    static func buildTasks(
        conversationSegments: [ChatTaskRunSegment],
        gateway: MacGatewayStore,
        subAgentStore: IOSSubAgentActivityStore,
        hubStore: AmberHubStore,
        filterHubId: String? = nil
    ) -> (needsAttention: [AmberUnifiedTaskItem], running: [AmberUnifiedTaskItem], recent: [AmberUnifiedTaskItem]) {
        var all: [AmberUnifiedTaskItem] = []
        let defaultHubId = hubStore.activeHubId

        // 1. In-conversation grouped tool/task segments
        for segment in conversationSegments {
            let rollup = segment.rollupState
            let phase: AmberUnifiedTaskPhase
            let statusText: String
            let subtitle: String
            var actionTitle: String? = nil

            switch rollup {
            case .needsAttention(let failedCount, _, _, let reason):
                phase = .needsAttention
                statusText = failedCount > 1 ? "\(failedCount) 次失败" : "执行失败"
                let cleanReason = Self.compactReason(reason ?? segment.subtitle ?? "操作未生效")
                subtitle = "\(cleanReason) · 本机"
                actionTitle = Self.suggestedActionButtonTitle(for: segment.headline, reason: cleanReason)
            case .approvalPending(let count):
                phase = .needsAttention
                statusText = count > 1 ? "\(count) 项待确认" : "待你确认"
                subtitle = (segment.subtitle ?? "等待确认高风险操作") + " · 本机"
                actionTitle = "去确认"
            case .working(let stepTitle):
                phase = .running
                statusText = "运行中"
                let isDispatched = segment.tools.contains {
                    $0.toolName.contains("subagent") || $0.toolName.contains("cloud")
                }
                let stepNumber = max(1, segment.steps.count)
                if isDispatched {
                    subtitle = stepNumber > 1 ? "云端后台 · 第 \(stepNumber) 步" : "云端后台 · \(stepTitle)"
                } else {
                    subtitle = stepNumber > 1 ? "本机 · 第 \(stepNumber) 步" : stepTitle
                }
            case .completed(let count):
                phase = .completed
                statusText = "已完成"
                subtitle = count > 1 ? "已完成 \(count) 步 · 本机" : "已完成 · 本机"
            case .cancelled:
                phase = .cancelled
                statusText = "已取消"
                subtitle = "已取消 · 本机"
            }

            all.append(
                AmberUnifiedTaskItem(
                    id: "seg:\(segment.id)",
                    title: segment.headline,
                    subtitle: subtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    hubId: defaultHubId,
                    updatedAt: Date(),
                    source: .inChatSegment(segment)
                )
            )
        }

        // 2. Cloud Self tasks (/v2/work-items)
        for record in gateway.cloudTasks {
            let phase: AmberUnifiedTaskPhase
            let statusText: String
            let subtitle: String
            var actionTitle: String? = nil

            if record.needsSubmissionRetry {
                phase = .needsAttention
                statusText = "提交未完成"
                subtitle = (record.lastError ?? "网络超时，请求 ID 已保留") + " · 云端"
                actionTitle = "重试"
            } else if record.state == .failed {
                phase = .needsAttention
                statusText = "执行失败"
                let reason = Self.compactReason(record.detail?.failure ?? record.lastError ?? "云端执行异常")
                subtitle = "\(reason) · 云端"
                actionTitle = Self.suggestedActionButtonTitle(for: record.displayTitle, reason: reason)
            } else if record.state == .cancelled {
                phase = .cancelled
                statusText = "已取消"
                subtitle = "云端后台 · 已取消"
            } else if record.state == .completed {
                phase = .completed
                statusText = "已完成"
                subtitle = "云端后台 · 已完成"
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
                if let progress = record.effectiveWorkItem?.progress, !progress.isEmpty {
                    subtitle = "云端后台 · \(progress)"
                } else {
                    subtitle = "云端后台 · \(record.state?.displayTitle ?? "执行中")"
                }
            }

            let matchedHubId = hubStore.hubs.first(where: { $0.taskIds.contains(record.requestId) })?.id ?? defaultHubId
            all.append(
                AmberUnifiedTaskItem(
                    id: "cloud:\(record.requestId)",
                    title: record.displayTitle,
                    subtitle: subtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    hubId: matchedHubId,
                    updatedAt: record.updatedAt,
                    source: .cloudTask(record.requestId)
                )
            )
        }

        // 3. Local background sub-agents (avoid duplicating segments already shown)
        for item in subAgentStore.items {
            guard !all.contains(where: { $0.title == item.title }) else { continue }
            let phase: AmberUnifiedTaskPhase
            let statusText: String
            var actionTitle: String? = nil
            switch item.status {
            case .queued:
                phase = .running
                statusText = "已受理"
            case .running:
                phase = .running
                statusText = "运行中"
            case .approvalRequired:
                phase = .needsAttention
                statusText = "待你确认"
                actionTitle = "去确认"
            case .completed:
                phase = .completed
                statusText = "已完成"
            case .failed, .timedOut, .interrupted:
                phase = .timedOutOrFailedTerminal
                statusText = "超时"
                actionTitle = "重试"
            case .cancelled:
                phase = .cancelled
                statusText = "已取消"
            }
            let subagentSubtitle = (item.statusDetail?.isEmpty == false)
                ? (item.statusDetail ?? "本机后台")
                : "本机后台 · \(item.statusTitle)"
            all.append(
                AmberUnifiedTaskItem(
                    id: "subagent:\(item.id)",
                    title: item.title,
                    subtitle: subagentSubtitle,
                    statusText: statusText,
                    actionButtonTitle: actionTitle,
                    phase: phase,
                    hubId: defaultHubId,
                    updatedAt: item.endedAt ?? item.startedAt,
                    source: .localSubAgent(item.id)
                )
            )
        }

        // 4. Gateway board items needing user attention
        for boardItem in gateway.needsYouItems {
            guard !all.contains(where: { $0.title == boardItem.title }) else { continue }
            all.append(
                AmberUnifiedTaskItem(
                    id: "board:\(boardItem.id)",
                    title: boardItem.title,
                    subtitle: boardItem.detail,
                    statusText: "待你处理",
                    actionButtonTitle: "去处理",
                    phase: .needsAttention,
                    hubId: defaultHubId,
                    updatedAt: boardItem.updatedAt,
                    source: .gatewayBoardItem(boardItem.id)
                )
            )
        }

        let filtered = filterHubId == nil
            ? all
            : all.filter { $0.hubId == filterHubId }

        let needsAttention = filtered.filter { $0.phase == .needsAttention }
        let running = filtered.filter { $0.phase == .running }
        let recent = filtered.filter { $0.phase.isRecentTerminal }

        return (needsAttention, running, recent)
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
