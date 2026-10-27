import Foundation
import Observation
@preconcurrency import UserNotifications

enum DesktopNotificationOutcome: String, Sendable { case completed, failed }

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
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.sound = .default
        content.userInfo = userInfo
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
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
