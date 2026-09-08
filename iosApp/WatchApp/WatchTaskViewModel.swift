import Combine
import Foundation
import SwiftUI
#if os(watchOS)
import WatchKit
#endif

enum WatchRoute: Hashable {
    case compose(String)
    case task(String)
    case recent
    case activity(WatchRecentActivity)
    case conversation(String)
    case note(String)
    case settings
}

enum WatchConnectionPresentationState: Equatable {
    case connecting
    case waitingForPhone
    case connected
    case offline
}

@MainActor
final class WatchTaskViewModel: ObservableObject {
    @Published private(set) var snapshot: WatchTaskSnapshot = .idle
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var noteSyncErrors: [String: String] = [:]
    @Published var draftAnswer = ""
    @Published var path: [WatchRoute] = []
    let store: WatchLocalStore

    private let bridge: WatchConnectivityBridge
    private var lastRequest: WatchTaskActionRequest?
    private var noteTransfers = Set<String>()
    private var refreshTimeoutTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var activeRefreshGeneration: Int?
    private var recoveredRefreshGeneration: Int?
    private var started = false
    private var isPreview = false
    private var hasReceivedSnapshot = false
    private var answerRunId: String?
    private var answerDecisionId: String?
    private enum StatusMessageSource: Equatable {
        case connection
        case sync
        case operation
    }
    private var statusMessageSource: StatusMessageSource?
    private let refreshTimeoutNanoseconds: UInt64
    var isBusy: Bool { isSending || isRefreshing }
    var canControl: Bool { isPhoneReachable && !snapshot.isStale && !isBusy }
    var connectionPresentation: WatchConnectionPresentationState {
        if isRefreshing || isSending {
            return isPhoneReachable ? .waitingForPhone : .connecting
        }
        return isPhoneReachable ? .connected : .offline
    }
    var library: WatchLibrarySnapshot? { snapshot.library }
    var activities: [WatchRecentActivity] {
        WatchActivityPresentation.activities(library: library, notes: store.notes)
    }
    var showsCurrentTask: Bool {
        WatchActivityPresentation.showsCurrentTask(snapshot, activities: activities)
    }

    func openActivity(_ activity: WatchRecentActivity) {
        if activity.kind == "note", activity.id.hasPrefix("note:"),
           store.note(id: String(activity.id.dropFirst(5))) != nil {
            store.markViewed(activity)
            path.append(.note(String(activity.id.dropFirst(5))))
        } else {
            path.append(.activity(activity))
        }
    }

    init(
        bridge: WatchConnectivityBridge = .shared,
        store: WatchLocalStore? = nil,
        refreshTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.bridge = bridge
        self.refreshTimeoutNanoseconds = refreshTimeoutNanoseconds
        #if DEBUG
        let preview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-amber-watch-preview=") }
        self.store = store ?? (preview ? WatchLocalStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-preview-\(UUID().uuidString).json")) : WatchLocalStore())
        #else
        self.store = store ?? WatchLocalStore()
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-amber-watch-preview=") }) {
            isPreview = true
            installPreview(String(argument.dropFirst("-amber-watch-preview=".count)))
            return
        }
        #endif
        bridge.onSnapshotUpdated = { [weak self] in self?.receive($0, completesRefresh: true) }
        bridge.onReachabilityChanged = { [weak self] reachable in
            guard let self else { return }
            self.isPhoneReachable = reachable && self.bridge.isCompanionReachable
            if self.isPhoneReachable {
                self.clearConnectionStatus()
            } else {
                self.recoveredRefreshGeneration = nil
            }
            self.receive(self.bridge.latestSnapshot, completesRefresh: false)
            if self.isPhoneReachable { self.syncNotes() }
        }
        bridge.onConnectionError = { [weak self] message in
            guard let self else { return }
            let currentlyReachable = self.bridge.isCompanionReachable
            self.isPhoneReachable = currentlyReachable
            if let generation = self.activeRefreshGeneration {
                guard !currentlyReachable else {
                    self.clearConnectionStatus()
                    return
                }
                self.finishRefresh(generation: generation)
                self.showSyncStatus(self.localized("本次同步未完成，请重试"))
                return
            }
            guard !currentlyReachable else {
                self.clearConnectionStatus()
                return
            }
            guard self.recoveredRefreshGeneration == nil else { return }
            self.showConnectionStatus(self.localized(message))
        }
        bridge.onActionResult = { [weak self] in self?.receiveResult($0) }
        bridge.configure()
        isPhoneReachable = bridge.isCompanionReachable
        receive(bridge.latestSnapshot, completesRefresh: false)
        refresh()
        syncNotes()
    }

    func resume() {
        guard started, !isPreview else { return }
        isPhoneReachable = bridge.isCompanionReachable
        receive(bridge.latestSnapshot, completesRefresh: false)
        refresh()
        syncNotes()
    }

    func refresh() {
        guard !isBusy, !isPreview else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        activeRefreshGeneration = generation
        recoveredRefreshGeneration = nil
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        clearRecoverableStatus()
        isRefreshing = true
        guard bridge.requestSnapshotFromPhone() else {
            finishRefresh(generation: generation)
            showConnectionStatus(localized("无法连接 iPhone，请稍后重试"))
            receive(bridge.latestSnapshot, completesRefresh: false)
            return
        }
        guard isRefreshing, activeRefreshGeneration == generation else { return }
        refreshTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: self?.refreshTimeoutNanoseconds ?? 0) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.isRefreshing, self.activeRefreshGeneration == generation else { return }
            self.finishRefresh(generation: generation)
            self.showSyncStatus(self.localized("本次同步未完成，请重试"))
        }
    }

    func compose(mode: WatchComposerMode, conversationId: String? = nil, quickAction: WatchQuickAction? = nil) {
        let key = mode == .note ? "note" : quickAction.map { "quick:\($0.id)" }
            ?? conversationId.map { "ask:\($0)" } ?? "ask"
        if let quickAction, let old = store.draft(forKey: key),
           old.pendingRequest == nil, old.text != quickAction.prompt {
            store.removeDraft(key: key)
        }
        _ = store.ensureDraft(key: key, mode: mode, conversationId: conversationId,
                              quickActionId: quickAction?.id, initialText: quickAction?.prompt ?? "")
        guard store.draft(forKey: key) != nil else {
            setStatus(localized(store.storageError ?? "手表本地缓存保存失败，请稍后重试"))
            return
        }
        clearStatus()
        path.append(.compose(key))
    }

    func submitDraft(key: String) {
        guard !isSending else { return }
        guard let draft = store.draft(forKey: key) else {
            setStatus(localized("这份草稿已处理"))
            return
        }
        let clean = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, draft.text.count <= 2_000 else {
            setStatus(localized("请输入 1–2000 个字符"))
            return
        }
        if draft.composerMode == .note {
            let note = WatchNote(id: draft.requestId, text: draft.text, createdAt: draft.createdAt)
            guard store.saveNote(note) else {
                setStatus(localized(store.storageError ?? "手表本地缓存保存失败，请稍后重试"))
                return
            }
            store.removeDraft(key: key)
            setStatus(localized("已存手表，待同步"))
            feedback(.success)
            if !path.isEmpty { path.removeLast() }
            path.append(.note(note.id))
            syncNotes()
            return
        }
        guard isPhoneReachable, !isPreview else {
            setStatus(localized("无法连接 iPhone，问题已保留为草稿"))
            return
        }
        guard library?.isConfigured == true || draft.pendingRequest != nil else {
            setStatus(localized(library?.configurationMessage ?? "请先在 iPhone 完成模型配置"))
            return
        }
        let request = draft.pendingRequest ?? WatchTaskActionRequest(
            requestId: draft.requestId, runId: "", conversationId: draft.conversationId,
            decisionId: nil, action: draft.quickActionId == nil ? .ask : .runQuickAction,
            optionId: draft.quickActionId, text: draft.text, createdAt: Date()
        )
        guard store.beginSending(key: key, request: request) else {
            setStatus(localized(store.storageError ?? "手表本地缓存保存失败，请稍后重试"))
            return
        }
        dispatch(request)
    }

    func syncNotes() {
        guard !isPreview else { return }
        for note in store.unsyncedNotes where !noteTransfers.contains(note.id) {
            guard store.markNoteTransferStarted(id: note.id) else { continue }
            noteTransfers.insert(note.id)
            bridge.sendNote(WatchTaskActionRequest(
                requestId: note.id, runId: "", conversationId: nil, decisionId: nil,
                action: .saveNote, optionId: nil, text: note.text, createdAt: note.createdAt
            ))
        }
    }

    func retryNote(id: String) {
        noteTransfers.remove(id)
        noteSyncErrors.removeValue(forKey: id)
        syncNotes()
    }

    func perform(_ action: WatchInboundAction, optionId: String? = nil,
                 expectedRunId: String, expectedDecisionId: String? = nil) {
        guard snapshot.runId == expectedRunId,
              expectedDecisionId == nil || snapshot.decision?.id == expectedDecisionId else {
            setStatus(localized("这个操作已过期，请从手表重新打开"))
            return
        }
        guard canControl else {
            setStatus(localized("连接 iPhone 后可继续操作"))
            return
        }
        guard snapshot.isActive else { return }
        dispatch(WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: snapshot.runId, conversationId: snapshot.conversationId,
            decisionId: snapshot.decision?.id, action: action, optionId: optionId,
            text: nil, createdAt: Date()
        ))
    }

    func submitAnswer(runId: String, decisionId: String) {
        guard snapshot.runId == runId, snapshot.decision?.id == decisionId else {
            setStatus(localized("这个操作已过期，请从手表重新打开"))
            return
        }
        let text = draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canControl, snapshot.decision?.allowsVoice == true else { return }
        guard !text.isEmpty, text.count <= 2_000 else {
            setStatus(localized("请输入 1–2000 个字符"))
            return
        }
        dispatch(WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: snapshot.runId, conversationId: snapshot.conversationId,
            decisionId: snapshot.decision?.id, action: .answer, optionId: nil, text: text, createdAt: Date()
        ))
    }

    func openConversation(_ id: String) {
        guard isPhoneReachable, !isSending else {
            setStatus(localized("连接 iPhone 后可继续操作"))
            return
        }
        dispatch(WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: "", conversationId: id, decisionId: nil,
            action: .openConversation, optionId: nil, text: nil, createdAt: Date()
        ))
    }

    func handleURL(_ url: URL) {
        let expectedScheme = Bundle.main.object(forInfoDictionaryKey: "AmberWatchURLScheme") as? String ?? "amber-watch"
        guard url.scheme == expectedScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        path = []
        switch components.host {
        case "ask": compose(mode: .ask)
        case "note": compose(mode: .note)
        case "recent": path = [.recent]
        case "task":
            guard let runId = components.queryItems?.first(where: { $0.name == "runId" })?.value else { return }
            path = [.task(runId)]
        default: break
        }
    }

    func clearCache() {
        guard !isSending, draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus(localized("请先处理未发送回答"))
            return
        }
        if store.clearCache() {
            bridge.clearLocalSnapshotCache()
            WatchWidgetCache.clear()
            setStatus(localized("已清除手表本地缓存"))
        } else {
            setStatus(localized(store.storageError ?? "请先处理未同步笔记和未发送草稿"))
        }
    }

    func receiveBackgroundConnectivity() async {
        start()
        guard !isPreview else { return }
        // SwiftUI keeps the WatchConnectivity background task alive until this
        // handler returns. Wait for both WCSession and our MainActor writes.
        repeat {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        } while !bridge.backgroundDeliveryIsDrained && !Task.isCancelled
    }

    private func dispatch(_ request: WatchTaskActionRequest) {
        guard !isPreview else { return }
        lastRequest = request
        isSending = true
        clearStatus()
        bridge.sendAction(request)
    }

    private func receiveResult(_ result: WatchTaskActionResult) {
        if store.note(id: result.requestId) != nil {
            noteTransfers.remove(result.requestId)
            if result.accepted, store.markNoteSynced(id: result.requestId) {
                noteSyncErrors.removeValue(forKey: result.requestId)
                clearConnectionStatus()
            } else {
                noteSyncErrors[result.requestId] = localized(store.storageError ?? result.message ?? "笔记尚未同步，请稍后重试")
            }
            return
        }
        let draft = store.draft(forRequestID: result.requestId)
        if draft != nil { _ = store.applyResult(result) }
        // Late query acknowledgements are still meaningful after an earlier timeout or relaunch.
        let isCurrent = lastRequest?.requestId == result.requestId
        let answeredRequest = isCurrent ? lastRequest : nil
        guard isCurrent || draft != nil else { return }
        if isCurrent { isSending = false; lastRequest = nil }
        setStatus(result.message.map(localized))
        receive(bridge.latestSnapshot, completesRefresh: false)
        if result.accepted {
            if draft != nil {
                path = []
                if !result.runId.isEmpty { path = [.task(result.runId)] }
                else if let id = result.conversationId { path = [.conversation(id)] }
            } else if answeredRequest?.runId == snapshot.runId,
                      answeredRequest?.decisionId == snapshot.decision?.id {
                draftAnswer = ""
            }
            feedback(.success)
        } else { feedback(.failure) }
    }

    private func receive(_ value: WatchTaskSnapshot, completesRefresh: Bool) {
        if completesRefresh {
            recoveredRefreshGeneration = activeRefreshGeneration ?? refreshGeneration
            finishRefresh()
            clearRecoverableStatus()
        }
        isPhoneReachable = bridge.isCompanionReachable
        if isPhoneReachable {
            clearConnectionStatus()
        }
        // Stale presentation hides the decision; it does not change which
        // question owns an unsent answer.
        if answerRunId != value.runId || answerDecisionId != value.decision?.id {
            draftAnswer = ""
        }
        answerRunId = value.runId
        answerDecisionId = value.decision?.id
        if hasReceivedSnapshot, !value.isStale,
           value.runId == snapshot.runId, value.phase != snapshot.phase,
           ["waitingForUser", "completed", "failed"].contains(value.phase) {
            feedback(value.phase == "failed" ? .failure : .notification)
        }
        hasReceivedSnapshot = true
        snapshot = WatchSnapshotFreshnessPolicy.presented(value, isPhoneReachable: isPhoneReachable)
        _ = WatchWidgetCache.save(value)
        freshnessTask?.cancel()
        guard value.isActive, !isPhoneReachable,
              !["completed", "failed", "cancelled", "stale"].contains(value.phase) else { return }
        let remaining = max(0, WatchSnapshotFreshnessPolicy.staleAfter - Date().timeIntervalSince(value.updatedAt))
        freshnessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.snapshot = WatchSnapshotFreshnessPolicy.presented(self.bridge.latestSnapshot, isPhoneReachable: self.bridge.isCompanionReachable)
        }
    }

    enum Feedback { case success, failure, notification }
    private func feedback(_ kind: Feedback) {
        guard store.settings.hapticsEnabled else { return }
        #if os(watchOS)
        guard WKExtension.shared().applicationState == .active else { return }
        WKInterfaceDevice.current().play(kind == .success ? .success : kind == .failure ? .failure : .notification)
        #endif
    }

    func localized(_ key: String) -> String {
        WatchTaskLocalization.string(key, defaultValue: key, languageCode: snapshot.languageCode)
    }

    private func setStatus(_ message: String?, source: StatusMessageSource = .operation) {
        statusMessage = message
        statusMessageSource = message == nil ? nil : source
    }

    private func clearStatus() {
        setStatus(nil)
    }

    private func clearRecoverableStatus() {
        guard statusMessageSource == .connection || statusMessageSource == .sync else { return }
        clearStatus()
    }

    private func clearConnectionStatus() {
        guard statusMessageSource == .connection else { return }
        clearStatus()
    }

    private func showConnectionStatus(_ message: String) {
        guard statusMessageSource != .operation, statusMessageSource != .sync else { return }
        setStatus(message, source: .connection)
    }

    private func showSyncStatus(_ message: String) {
        guard statusMessageSource != .operation else { return }
        setStatus(message, source: .sync)
    }

    private func finishRefresh(generation: Int? = nil) {
        if let generation, activeRefreshGeneration != generation { return }
        activeRefreshGeneration = nil
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        isRefreshing = false
    }

    #if DEBUG
    private func installPreview(_ state: String) {
        var sample = WatchTaskSnapshot.idle
        sample.languageCode = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("-amber-watch-language=") }
            .map { String($0.dropFirst("-amber-watch-language=".count)) } ?? "zh-Hans"
        sample.updatedAt = Date()
        sample.library = WatchLibrarySnapshot(
            assistantName: "Amber", isConfigured: true,
            quickActions: state == "home-actions"
                ? [WatchQuickAction(id: "preview-action", title: "示例快捷动作", prompt: "用三句话解释番茄工作法。")]
                : [],
            recent: [WatchRecentConversation(id: "sample", title: "一次短途旅行", preview: "周末可以先去公园走走，再找一家咖啡店。", updatedAt: Date())], updatedAt: Date()
        )
        if ["home-result", "home-real-result", "home-active", "home-failed", "home-offline", "activity", "activities", "home-long"].contains(state) {
            let result = WatchRecentActivity(id: "run:preview-completed", runId: "preview-completed", conversationId: "sample",
                kind: "chat", phase: "completed", title: "周末行程\n已整理好", summary: "两天安排与出行建议",
                updatedAt: Date().addingTimeInterval(-480))
            sample.library?.activities = [result,
                WatchRecentActivity(id: "run:preview-earlier", runId: "preview-earlier", conversationId: "sample",
                    kind: "chat", phase: "completed", title: "本周工作进展与明天要优先处理的三件事",
                    summary: "已整理进展、待办和需要讨论的问题。", updatedAt: Date().addingTimeInterval(-3600)),
                WatchRecentActivity(id: "run:preview-failed", runId: "preview-failed", conversationId: "sample",
                    kind: "chat", phase: "failed", title: "整理阅读笔记", summary: "连接中断，已保留生成的内容。",
                    updatedAt: Date().addingTimeInterval(-7200))]
            if state == "home-long" {
                sample.library?.activities?[0].title = "请帮我整理一家人周末从上海到苏州的两天一夜行程和交通安排"
                sample.library?.activities?[0].summary = "包含适合孩子的路线、餐饮建议和出发前需要准备的物品。"
            }
            if state == "home-real-result" {
                sample.library?.activities?[0].title = "开发一个扎小人的小应用，尽量精美，有趣"
                sample.library?.activities?[0].resultTitle = "烦恼缝纫铺 v3"
                sample.library?.activities?[0].summary = "已更新小应用：烦恼缝纫铺 v3"
            }
            if state == "home-failed" {
                sample.library?.activities?[0].phase = "failed"
                sample.library?.activities?[0].title = "整理周末行程"
                sample.library?.activities?[0].summary = "连接中断，已保留生成的内容。"
            }
            if state == "activity" { path = [.activity(result)] }
            if state == "activities" { path = [.recent] }
            if state == "home-active" {
                sample.runId = "preview-active"
                sample.phase = "running"
                sample.headline = "正在整理阅读笔记"
                sample.detail = "正在生成内容"
                sample.actions = [.cancel, .openOnPhone]
            }
        }
        if state == "home-empty" { sample.library?.recent = [] }
        if state == "recent" || state == "recent-notes" {
            let titles = [
                "帮我整理今天的工作，列出明天需要优先处理的三件事",
                "晚饭吃什么？",
                "SwiftUI 中 NavigationStack 和 WatchConnectivity 的状态同步问题",
                "周末出行：从上海到苏州，带孩子的两天一夜行程",
                "请把这段英文邮件翻译成自然、礼貌的中文",
                "购物清单 🥚🥛🍞",
                "阅读笔记：如何安排注意力与休息时间",
                "给妈妈的生日祝福",
                "分析本周运动记录，并给出下周的安排建议",
                "Review the watch app layout with long conversation titles"
            ]
            sample.library?.recent = titles.enumerated().map { index, title in
                WatchRecentConversation(id: "preview-recent-\(index)", title: title,
                    preview: index == 1 ? "" : "先整理当前进展，再确认优先级。把任务拆成可以执行的小步骤，并留出休息和调整的时间。",
                    updatedAt: Date().addingTimeInterval(-Double(index + 1) * 3_600))
            }
            store.updateSettings { $0.showContentPreview = ProcessInfo.processInfo.arguments.contains("-amber-watch-content-preview") }
            if state == "recent-notes" {
                sample.library?.recent = []
                _ = store.saveNote(WatchNote(id: "preview-note-pending", text: "明天开会之前，先整理本周进展和需要讨论的问题，带上产品草图。", createdAt: Date()))
                _ = store.saveNote(WatchNote(id: "preview-note-synced", text: "买咖啡豆和牛奶", createdAt: Date().addingTimeInterval(-3_600)))
                store.markNoteSynced(id: "preview-note-synced")
            }
            path = [.recent]
        } else if state == "settings" {
            path = [.settings]
        }
        if state == "waiting" || state == "completed" {
            sample.runId = "preview-run"
            sample.conversationId = "sample"
            sample.phase = state == "waiting" ? "waitingForUser" : "completed"
            sample.headline = "周末出行建议"
            sample.detail = state == "waiting" ? "需要你的回答" : "已完成"
            sample.actions = state == "waiting" ? [.cancel] : [.openOnPhone]
            if state == "waiting" {
                sample.decision = WatchDecision(id: "preview-question", type: .askUser,
                    title: "需要你的回答", body: "你更想在自然里放松，还是去市区逛逛？",
                    options: [WatchDecisionOption(id: "choice-0", title: "去公园，走一段安静的步道", style: .choice),
                              WatchDecisionOption(id: "open-phone", title: "在 iPhone 回答", style: .openOnPhone)],
                    riskLevel: .low, allowsVoice: true)
            } else { sample.summary = "周末可以先去公园走走，再找一家咖啡店。出发前查看天气，带好水和一件薄外套。" }
            path = [.task(sample.runId)]
        }
        snapshot = sample
        isPhoneReachable = state != "offline" && state != "home-offline"
        if state == "note" {
            _ = store.saveNote(WatchNote(id: "preview-note", text: "周末去公园时，带一本书和一瓶水。\n这条记事已保存在手表，连接手机后再同步。", createdAt: Date()))
            isPhoneReachable = false
            path = [.note("preview-note")]
        } else if state == "compose" {
            _ = store.ensureDraft(key: "preview-ask", mode: .ask, initialText: "帮我想一个轻松的周末安排")
            path = [.compose("preview-ask")]
        }
        setStatus("界面预览 · 示例数据")
    }
    #endif
}

/// Presentation only: history comes from durable phone events or saved Watch
/// notes. A conversation preview alone is never evidence of a completed task.
enum WatchActivityPresentation {
    static func activities(library: WatchLibrarySnapshot?, notes: [WatchNote]) -> [WatchRecentActivity] {
        var byID: [String: WatchRecentActivity] = [:]
        for activity in library?.activities ?? [] {
            if byID[activity.id].map({ $0.updatedAt > activity.updatedAt }) != true {
                byID[activity.id] = activity
            }
        }
        for note in notes {
            let id = "note:\(note.id)"
            byID[id] = WatchRecentActivity(id: id, runId: nil, conversationId: nil,
                kind: "note", phase: note.syncedAt == nil ? "pending" : "completed",
                title: String(note.text.split(separator: "\n").first.map(String.init)?.prefix(80) ?? ""),
                summary: String(note.text.prefix(280)), updatedAt: note.createdAt)
        }
        return byID.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    static func showsCurrentTask(_ snapshot: WatchTaskSnapshot, activities: [WatchRecentActivity]) -> Bool {
        guard snapshot.isActive else { return false }
        return !["completed", "failed", "cancelled"].contains(snapshot.phase)
            || !activities.contains { $0.runId == snapshot.runId }
    }
}
