import Combine
import Foundation
import Observation
@preconcurrency import Shared

struct ConversationActivityNotice: Identifiable, Equatable {
    enum Kind: Int {
        case completed
        case failed
        case awaitingUser
    }

    var id: String { conversationId }
    let conversationId: String
    let title: String
    let kind: Kind
    let preview: String?
    let occurredAt: Date
}

/// 只投影既有运行账本和会话内容，不持有 run，也不另存提醒。
@MainActor
@Observable
final class ConversationActivityCenter {
    struct RunEvent: Equatable, Sendable {
        let runId: String
        let conversationId: String
        let status: String
        let startedAt: Int64
        let finishedAt: Int64?
        let pendingToken: String?

        var kind: ConversationActivityNotice.Kind? {
            switch status {
            case "awaiting_permission", "waiting_user", "outcome_unknown": .awaitingUser
            case "failed": .failed
            case "completed": .completed
            default: nil
            }
        }
    }

    private struct CachedPreview {
        let event: RunEvent
        let summaryUpdatedAt: KotlinInstant
        let value: String?
    }

    private(set) var notices: [ConversationActivityNotice] = []
    @ObservationIgnored private let conversationStore: IOSConversationStore
    @ObservationIgnored private let dao: AgentRuntimeDao
    @ObservationIgnored private let startedAt: Date
    @ObservationIgnored private var seen: [String: RunEvent] = [:]
    @ObservationIgnored private var latestEventsByConversationId: [String: RunEvent] = [:]
    @ObservationIgnored private var cachedPreviews: [String: CachedPreview] = [:]
    @ObservationIgnored private var visibleTranscriptConversationID: String?
    @ObservationIgnored private var clearedRevision: [String: Int] = [:]
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRunRefresh = false
    @ObservationIgnored private var needsStoreRefresh = false
    @ObservationIgnored private var started = false

    init(
        conversationStore: IOSConversationStore,
        dao: AgentRuntimeDao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao(),
        startedAt: Date = Date()
    ) {
        self.conversationStore = conversationStore
        self.dao = dao
        self.startedAt = startedAt
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [Notification.Name.amberSubAgentRunsDidChange,
                     .amberChatBackgroundJobStateDidChange, .amberChatBackgroundJobDidTerminate] {
            NotificationCenter.default.publisher(for: name).sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.requestRunRefresh() }
            }.store(in: &subscriptions)
        }
        observeConversationStore()
        requestRunRefresh()
    }

    private func observeConversationStore() {
        conversationDidChange()
        withObservationTracking {
            _ = conversationStore.conversationSwitchedRevision
            _ = conversationStore.currentRevision
            _ = conversationStore.backgroundContentRevision
            _ = conversationStore.allSummaries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeConversationStore()
                self?.requestStoreRefresh()
            }
        }
    }

    func conversationDidChange() {
        if let id = conversationStore.currentConversation?.id.toHexDashString() {
            didOpenConversation(id: id, succeeded: true, isTranscript: false)
        }
    }

    func didOpenConversation(id: String, succeeded: Bool, isTranscript: Bool) {
        guard succeeded else { return }
        let id = id.lowercased()
        if isTranscript { visibleTranscriptConversationID = id }
        notices.removeAll { $0.conversationId == id }

        if let event = latestEventsByConversationId[id] {
            if event.kind == .awaitingUser {
                // 等待中的提醒只在页面可见时隐藏；离开后仍需重新出现。
                seen.removeValue(forKey: id)
            } else {
                seen[id] = event
            }
        }
        if isTranscript { requestStoreRefresh() }
    }

    func transcriptConversationDidDisappear(id: String) {
        let id = id.lowercased()
        guard visibleTranscriptConversationID == id else { return }
        visibleTranscriptConversationID = nil
        requestStoreRefresh()
    }

    func dismiss(conversationId: String) {
        clearedRevision[conversationId, default: 0] &+= 1
        notices.removeAll { $0.conversationId == conversationId }
    }

    private func requestRunRefresh() {
        needsRunRefresh = true
        requestRecompute()
    }

    private func requestStoreRefresh() {
        needsStoreRefresh = true
        requestRecompute()
    }

    private func requestRecompute() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // 合并通知并串行读取；只有账本通知才查询全部运行记录。
            while self.needsRunRefresh || self.needsStoreRefresh {
                let shouldReadRuns = self.needsRunRefresh
                let shouldRecompute = self.needsStoreRefresh || shouldReadRuns
                self.needsRunRefresh = false
                self.needsStoreRefresh = false
                if shouldReadRuns { await self.refreshRunEvents() }
                if shouldRecompute { await self.recomputeNotices() }
            }
            self.refreshTask = nil
        }
    }

    private func refreshRunEvents() async {
        do {
            let events: [RunEvent] = try await withCheckedThrowingContinuation { continuation in
                dao.listAllRuns { values, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (values ?? []).compactMap { run in
                        guard IOSDurableRunStore.Descriptor.chatRecoveryAliases.contains(run.agentDescriptorId),
                              let conversationId = run.conversationId else { return nil }
                        return RunEvent(
                            runId: run.runId, conversationId: conversationId.lowercased(),
                            status: run.status, startedAt: run.startedAt,
                            finishedAt: run.finishedAt?.int64Value, pendingToken: run.inputSnapshotRef
                        )
                    })
                }
            }
            latestEventsByConversationId = Self.makeLatestEventsByConversationId(events)
        } catch {
            // 读取失败保留上次缓存，不推断运行终态。
            NSLog("[ConversationActivityCenter] 读取运行状态失败: %@", String(describing: error))
        }
    }

    func reconcile(_ events: [RunEvent]) async {
        latestEventsByConversationId = Self.makeLatestEventsByConversationId(events)
        await recomputeNotices()
    }

    private static func makeLatestEventsByConversationId(_ events: [RunEvent]) -> [String: RunEvent] {
        Dictionary(events.map { ($0.conversationId, $0) }, uniquingKeysWith: { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.runId > rhs.runId ? lhs : rhs }
            return lhs.startedAt > rhs.startedAt ? lhs : rhs
        })
    }

    private func isVisibleConversation(_ id: String) -> Bool {
        id == conversationStore.currentConversation?.id.toHexDashString() ||
            id == visibleTranscriptConversationID
    }

    private func recomputeNotices() async {
        let latest = latestEventsByConversationId
        notices.removeAll { latest[$0.conversationId] == nil }
        for (id, event) in latest {
            let existing = notices.first { $0.conversationId == id }
            let kind = event.kind
            if isVisibleConversation(id) {
                notices.removeAll { $0.conversationId == id }
                if kind == .awaitingUser {
                    // 等待确认需在用户离开会话后重新出现。
                    seen.removeValue(forKey: id)
                } else {
                    seen[id] = event
                }
                continue
            }
            guard let kind else {
                notices.removeAll { $0.conversationId == id }
                cachedPreviews.removeValue(forKey: id)
                seen[id] = event
                continue
            }
            guard seen[id] != event || existing != nil else { continue }
            // 冷启动不把历史已读终态变成新提醒；仍在等待用户的运行可以恢复显示。
            if kind != .awaitingUser,
               Double(event.finishedAt ?? event.startedAt) / 1_000 < startedAt.timeIntervalSince1970 {
                notices.removeAll { $0.conversationId == id }
                seen[id] = event
                continue
            }
            guard let summary = conversationStore.allSummaries.first(where: { $0.id.toHexDashString() == id }) else { continue }
            var preview = cachedPreviews[id].flatMap {
                $0.event == event && $0.summaryUpdatedAt == summary.updateAt ? $0.value : nil
            }
            let revision = clearedRevision[id, default: 0]
            if cachedPreviews[id].map({ $0.event == event && $0.summaryUpdatedAt == summary.updateAt }) != true {
                guard let messages = await conversationStore.messages(for: summary.id) else { continue }
                guard clearedRevision[id, default: 0] == revision else {
                    // await 中用户关闭提醒时消费该事件；进入等待中的会话则保留它。
                    if isVisibleConversation(id) {
                        if kind == .awaitingUser { seen.removeValue(forKey: id) }
                        else { seen[id] = event }
                    } else {
                        seen[id] = event
                    }
                    continue
                }
                guard !isVisibleConversation(id) else {
                    if kind != .awaitingUser { seen[id] = event }
                    else { seen.removeValue(forKey: id) }
                    notices.removeAll { $0.conversationId == id }
                    continue
                }
                preview = Self.preview(messages: messages, event: event)
                cachedPreviews[id] = CachedPreview(event: event, summaryUpdatedAt: summary.updateAt, value: preview)
            }
            guard let currentSummary = conversationStore.allSummaries.first(where: { $0.id.toHexDashString() == id }) else {
                continue
            }
            let changed = seen[id] != event
            let occurredAt = changed
                ? event.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date()
                : existing?.occurredAt ?? Date()
            guard !isVisibleConversation(id) else {
                notices.removeAll { $0.conversationId == id }
                if kind == .awaitingUser { seen.removeValue(forKey: id) }
                else { seen[id] = event }
                continue
            }
            // 读取预览期间可能已成功进入又离开；已消费的终态不能被旧读取重新加入。
            guard seen[id] != event || notices.contains(where: { $0.conversationId == id }) else { continue }
            let notice = ConversationActivityNotice(
                conversationId: id, title: currentSummary.title, kind: kind,
                preview: preview, occurredAt: occurredAt
            )
            notices.removeAll { $0.conversationId == id }
            notices.append(notice)
            seen[id] = event
        }
        notices.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue > $1.kind.rawValue }
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.conversationId < $1.conversationId
        }
    }

    func lastMessage(conversationId: String) async -> UIMessage? {
        guard let summary = conversationStore.allSummaries.first(where: {
            $0.id.toHexDashString() == conversationId
        }), let messages = await conversationStore.messages(for: summary.id) else { return nil }
        return messages.last(where: ChatMessageProjector.isConversationMessage)
    }

    private static func preview(messages: [UIMessage], event: RunEvent) -> String? {
        guard let assistant = messages.last(where: { $0.role == MessageRole.assistant }) else { return nil }
        let toolCallId = event.pendingToken.flatMap {
            $0.hasPrefix("tool_call:") ? String($0.dropFirst("tool_call:".count)) : nil
        }
        let question = event.kind == .awaitingUser ? assistant.parts.compactMap { $0 as? UIMessagePart.Tool }
            .last(where: {
                !$0.isExecuted && $0.toolName == "ask_user" && (toolCallId == nil || $0.toolCallId == toolCallId)
            })
            .flatMap { ChatToolApprovalRequestBuilder.askUser(for: $0)?.question } : nil
        let line = (question ?? assistant.toText()).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(160))
    }
}
