import Foundation
import Observation
@preconcurrency import UserNotifications

enum DesktopNotificationOutcome: String, Sendable { case completed, failed, needsApproval }

/// Notification categories and actions for unattended (scheduled) runs.
enum DesktopNotificationAction {
    static let approvalCategory = "amber.approval"
    /// High-risk tools: only「查看」, so approving always happens in the app after reading the full call.
    static let highRiskApprovalCategory = "amber.approval.high-risk"
    static let approve = "amber.approve"
    static let deny = "amber.deny"
    static let view = "amber.view"

    static func approvalIdentifier(runID: UUID) -> String { "amber.approval." + runID.uuidString.lowercased() }

    /// Body text for an approval prompt: tool name plus a whitespace-collapsed argument excerpt (≤ 120 characters).
    static func approvalBody(_ approval: DesktopToolApproval) -> String {
        let collapsed = approval.arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let excerpt = collapsed.count > 120 ? String(collapsed.prefix(119)) + "…" : collapsed
        let risk = DesktopToolRegistry.isHighRisk(approval.name) ? "（高风险，请打开 Amber 核对后批准）" : ""
        return "工具：\(approval.name)\(risk)" + (excerpt.isEmpty || excerpt == "{}" ? "" : "\n参数：\(excerpt)")
    }
}

@MainActor final class DesktopNotificationRouter {
    private weak var workspace: DesktopWorkspace?
    private var openMainWindow: (@MainActor () -> Void)?
    private var pendingConversationID: UUID?
    private var routingTask: Task<Void, Never>?

    @discardableResult
    func bind(workspace: DesktopWorkspace, openMainWindow: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        self.workspace = workspace
        self.openMainWindow = openMainWindow
        return routePending()
    }

    @discardableResult
    func receive(conversationID: UUID) -> Task<Void, Never>? {
        pendingConversationID = conversationID
        return routePending()
    }

    private func routePending() -> Task<Void, Never>? {
        routingTask?.cancel()
        routingTask = nil
        guard let workspace, let openMainWindow, let id = pendingConversationID else { return nil }
        let task = Task { [weak self] in
            await workspace.waitUntilLoaded()
            guard !Task.isCancelled, let self, self.pendingConversationID == id else { return }
            self.pendingConversationID = nil
            self.routingTask = nil
            openMainWindow()
            if workspace.summaries.contains(where: { $0.id == id }) { workspace.select(id) }
            else { workspace.errorMessage = "通知对应的会话已删除，任务记录仍可在工作台查看。" }
        }
        routingTask = task
        return task
    }
}

@MainActor protocol DesktopNotificationDelivery {
    func requestAuthorization() async throws -> Bool
    func isAuthorized() async -> Bool
    func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws
    func send(identifier: String, title: String, body: String, userInfo: [String: String], category: String?) async throws
    func remove(identifiers: [String])
}

extension DesktopNotificationDelivery {
    func send(identifier: String, title: String, body: String, userInfo: [String: String], category: String?) async throws {
        var info = userInfo
        if let category { info["category"] = category }
        try await send(identifier: identifier, title: title, body: body, userInfo: info)
    }
    func remove(identifiers: [String]) {}
}

@MainActor struct DesktopSystemNotificationDelivery: DesktopNotificationDelivery {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws {
        try await send(identifier: identifier, title: title, body: body, userInfo: userInfo, category: nil)
    }
    func send(identifier: String, title: String, body: String, userInfo: [String: String], category: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
    func remove(identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func registerCategories() {
        let approve = UNNotificationAction(identifier: DesktopNotificationAction.approve, title: "批准", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: DesktopNotificationAction.deny, title: "拒绝", options: [])
        let view = UNNotificationAction(identifier: DesktopNotificationAction.view, title: "查看", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: DesktopNotificationAction.approvalCategory, actions: [approve, deny, view], intentIdentifiers: []),
            UNNotificationCategory(identifier: DesktopNotificationAction.highRiskApprovalCategory, actions: [view], intentIdentifiers: [])
        ])
    }
}

extension DesktopScheduleRunRecord {
    /// Only bother the user when something is new: failures and noteworthy (or not judged) completions notify;
    /// a completion judged not noteworthy stays on the board quietly. Skipped runs never notify.
    var shouldNotify: Bool {
        status == .failed || (status == .completed && noteworthy != false)
    }
}

@MainActor @Observable final class DesktopNotifications {
    private(set) var isRequestingAuthorization = false
    private(set) var authorizationMessage: String?
    private(set) var lastDeliveryError: String?
    @ObservationIgnored private let settings: DesktopSettings
    @ObservationIgnored private let delivery: any DesktopNotificationDelivery
    @ObservationIgnored private var handledRuns: Set<UUID> = []

    init(settings: DesktopSettings, delivery: any DesktopNotificationDelivery = DesktopSystemNotificationDelivery()) {
        self.settings = settings; self.delivery = delivery
    }

    // Permission is requested only by the explicit settings action.
    func setEnabled(_ enabled: Bool) async {
        guard !isRequestingAuthorization else { return }
        lastDeliveryError = nil
        if !enabled { settings.notificationsEnabled = false; return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        do {
            let granted = try await delivery.requestAuthorization()
            settings.notificationsEnabled = granted
            authorizationMessage = granted ? "系统已允许通知。" : "系统未允许通知，可在系统设置中为 Amber 开启。"
        } catch {
            settings.notificationsEnabled = false
            authorizationMessage = "无法请求通知权限，请在系统设置中检查后重试。"
        }
    }

    func refreshAuthorization() async {
        let authorized = await delivery.isAuthorized()
        if authorized { authorizationMessage = "系统已允许通知。" }
        else if settings.notificationsEnabled { authorizationMessage = "系统未允许通知，请在系统设置中为 Amber 开启。" }
        else { authorizationMessage = "启用后会向系统请求授权。" }
    }

    /// A scheduled run is waiting for an approval. High-risk tools get no「批准」button.
    @discardableResult
    func notifyApproval(runID: UUID, conversationID: UUID, taskName: String, approval: DesktopToolApproval) async -> Bool {
        let highRisk = DesktopToolRegistry.isHighRisk(approval.name)
        return await deliver(identifier: DesktopNotificationAction.approvalIdentifier(runID: runID),
            title: "⏱ \(taskName) 等待批准", body: DesktopNotificationAction.approvalBody(approval),
            userInfo: ["runID": runID.uuidString.lowercased(), "conversationID": conversationID.uuidString.lowercased(),
                "toolID": approval.id, "outcome": DesktopNotificationOutcome.needsApproval.rawValue],
            category: highRisk ? DesktopNotificationAction.highRiskApprovalCategory : DesktopNotificationAction.approvalCategory)
    }

    func clearApproval(runID: UUID) {
        delivery.remove(identifiers: [DesktopNotificationAction.approvalIdentifier(runID: runID)])
    }

    /// Finished scheduled run; titled with the task name.
    @discardableResult
    func notifySchedule(taskName: String, record: DesktopScheduleRunRecord) async -> Bool {
        guard record.shouldNotify else { return false }
        var info = ["scheduleRunID": record.id.uuidString.lowercased(), "outcome": record.status.rawValue]
        if let id = record.conversationID { info["conversationID"] = id.uuidString.lowercased() }
        let body = record.status == .completed ? (record.summary ?? "打开 Amber 查看结果。") : (record.error.map { String($0.prefix(120)) } ?? "打开 Amber 查看原因。")
        return await deliver(identifier: "amber.schedule." + record.id.uuidString.lowercased(),
            title: "⏱ \(taskName) " + (record.status == .completed ? "已完成" : "未完成"), body: body, userInfo: info, category: nil)
    }

    private func deliver(identifier: String, title: String, body: String, userInfo: [String: String], category: String?) async -> Bool {
        guard settings.notificationsEnabled else { return false }
        guard await delivery.isAuthorized(), settings.notificationsEnabled else {
            authorizationMessage = "系统未允许通知，可在系统设置中为 Amber 开启。"
            return false
        }
        do {
            try await delivery.send(identifier: identifier, title: title, body: body, userInfo: userInfo, category: category)
            lastDeliveryError = nil
            return true
        } catch {
            lastDeliveryError = "任务结果已保留，但系统通知未能送达。"
            return false
        }
    }

    @discardableResult
    func notify(runID: UUID, conversationID: UUID, outcome: DesktopNotificationOutcome) async -> Bool {
        guard settings.notificationsEnabled, handledRuns.insert(runID).inserted else { return false }
        let authorized = await delivery.isAuthorized()
        guard settings.notificationsEnabled else { return false }
        guard authorized else {
            authorizationMessage = "系统未允许通知，可在系统设置中为 Amber 开启。"
            return false
        }
        do {
            try await delivery.send(identifier: "amber.run." + runID.uuidString.lowercased(),
                title: outcome == .completed ? "任务已完成" : "任务未完成",
                body: "打开 Amber 查看原会话与结果。",
                userInfo: ["runID": runID.uuidString.lowercased(), "conversationID": conversationID.uuidString.lowercased(), "outcome": outcome.rawValue])
            lastDeliveryError = nil
            return true
        } catch {
            lastDeliveryError = "任务结果已保留，但系统通知未能送达。"
            return false
        }
    }
}
