import Foundation
import Observation
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

enum IOSAppleIntegrationPreferenceKeys {
    static let completionNotificationsEnabled = "app.amber.ios.notifications.taskCompletionEnabled"
}

enum IOSLocalNotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case allowed
}

struct IOSLocalNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
    let deepLink: URL
}

@MainActor
protocol IOSLocalNotificationCenter: AnyObject {
    func authorization() async -> IOSLocalNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(_ request: IOSLocalNotificationRequest) async throws
    func pendingRequestIdentifiers() async -> [String]
    func removePendingRequests(identifiers: [String])
}

@MainActor
final class IOSUserNotificationCenterAdapter: IOSLocalNotificationCenter {
    private let center: UNUserNotificationCenter
    private let now: () -> Date

    init(center: UNUserNotificationCenter = .current(), now: @escaping () -> Date = Date.init) {
        self.center = center
        self.now = now
    }

    func authorization() async -> IOSLocalNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .allowed
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(_ request: IOSLocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "amber.local"
        content.userInfo = ["deepLink": request.deepLink.absoluteString]

        let interval = max(1, request.fireDate.timeIntervalSince(now()))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePendingRequests(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

enum IOSLocalNotificationScheduleResult: Equatable {
    case scheduled(identifier: String)
    case notAuthorized
    case invalidDate
}

@MainActor
final class IOSLocalNotificationService {
    static let shared = IOSLocalNotificationService()
    static let manualReminderIdentifier = "amber.reminder.manual"
    static let agentReminderIdentifier = "amber.reminder.agent"

    private let center: any IOSLocalNotificationCenter
    private let permissionCoordinator: IOSSystemPermissionCoordinator
    private let now: () -> Date
    private let completionNotificationsEnabled: () -> Bool
    private var completionCancellationRevision = 0
    private var manualReminderCancellationRevision = 0

    init(
        center: any IOSLocalNotificationCenter = IOSUserNotificationCenterAdapter(),
        permissionCoordinator: IOSSystemPermissionCoordinator = IOSSystemPermissionCoordinator(),
        now: @escaping () -> Date = Date.init,
        completionNotificationsEnabled: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: IOSAppleIntegrationPreferenceKeys.completionNotificationsEnabled)
        }
    ) {
        self.center = center
        self.permissionCoordinator = permissionCoordinator
        self.now = now
        self.completionNotificationsEnabled = completionNotificationsEnabled
    }

    func authorization() async -> IOSLocalNotificationAuthorization {
        await center.authorization()
    }

    func requestAuthorization() async -> Bool {
        guard let capability = IOSCapabilityRegistry.capabilities.first(where: {
            $0.id == "ios.notifications.alerts"
        }) else { return false }
        _ = await permissionCoordinator.request(capability)
        return await center.authorization() == .allowed
    }

    func scheduleTaskCompletion(conversationID: String) async throws -> IOSLocalNotificationScheduleResult {
        let cancellationRevision = completionCancellationRevision
        guard completionNotificationsEnabled() else { return .notAuthorized }
        guard await center.authorization() == .allowed else { return .notAuthorized }
        guard let deepLink = IOSAppDeepLink.url(for: .conversation(id: conversationID)) else {
            return .notAuthorized
        }
        let identifier = "amber.task-complete.\(conversationID)"
        guard cancellationRevision == completionCancellationRevision,
              completionNotificationsEnabled() else { return .notAuthorized }
        try await center.add(IOSLocalNotificationRequest(
            identifier: identifier,
            title: "Amber 任务已结束",
            body: "点按查看这段对话的最新结果。",
            fireDate: now().addingTimeInterval(1),
            deepLink: deepLink
        ))
        guard cancellationRevision == completionCancellationRevision,
              completionNotificationsEnabled() else {
            center.removePendingRequests(identifiers: [identifier])
            return .notAuthorized
        }
        return .scheduled(identifier: identifier)
    }

    func scheduleManualReminder(
        title: String,
        fireDate: Date
    ) async throws -> IOSLocalNotificationScheduleResult {
        let cancellationRevision = manualReminderCancellationRevision
        guard fireDate.timeIntervalSince(now()) >= 5 else { return .invalidDate }
        guard await center.authorization() == .allowed else { return .notAuthorized }
        guard let deepLink = IOSAppDeepLink.url(for: .latestConversation) else {
            return .notAuthorized
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cancellationRevision == manualReminderCancellationRevision else {
            return .notAuthorized
        }
        center.removePendingRequests(identifiers: [Self.manualReminderIdentifier])
        try await center.add(IOSLocalNotificationRequest(
            identifier: Self.manualReminderIdentifier,
            title: cleanTitle.isEmpty ? "回到 Amber" : String(cleanTitle.prefix(80)),
            body: "继续最近的对话。",
            fireDate: fireDate,
            deepLink: deepLink
        ))
        guard cancellationRevision == manualReminderCancellationRevision else {
            center.removePendingRequests(identifiers: [Self.manualReminderIdentifier])
            return .notAuthorized
        }
        return .scheduled(identifier: Self.manualReminderIdentifier)
    }

    func cancelManualReminder() {
        manualReminderCancellationRevision &+= 1
        center.removePendingRequests(identifiers: [Self.manualReminderIdentifier])
    }

    func scheduleAgentNotification(
        title: String,
        body: String,
        fireDate: Date
    ) async throws -> IOSLocalNotificationScheduleResult {
        guard fireDate.timeIntervalSince(now()) >= 5 else { return .invalidDate }
        if await center.authorization() != .allowed,
           await requestAuthorization() == false {
            return .notAuthorized
        }
        guard let deepLink = IOSAppDeepLink.url(for: .latestConversation) else { return .notAuthorized }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        center.removePendingRequests(identifiers: [Self.agentReminderIdentifier])
        try await center.add(IOSLocalNotificationRequest(
            identifier: Self.agentReminderIdentifier,
            title: cleanTitle.isEmpty ? "Amber 提醒" : String(cleanTitle.prefix(80)),
            body: cleanBody.isEmpty ? "点按返回最近对话。" : String(cleanBody.prefix(240)),
            fireDate: fireDate,
            deepLink: deepLink
        ))
        return .scheduled(identifier: Self.agentReminderIdentifier)
    }

    func cancelAgentNotification() {
        center.removePendingRequests(identifiers: [Self.agentReminderIdentifier])
    }

    func cancelTaskCompletionNotifications() async {
        completionCancellationRevision &+= 1
        let identifiers = await center.pendingRequestIdentifiers().filter {
            $0.hasPrefix("amber.task-complete.")
        }
        guard !identifiers.isEmpty else { return }
        center.removePendingRequests(identifiers: identifiers)
    }
}

@MainActor
enum IOSNotificationAgentToolExecutor {
    static func execute(
        toolName: String,
        input: String,
        service: IOSLocalNotificationService = .shared
    ) async -> String {
        guard let data = input.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json(["ok": false, "tool": toolName, "reason": "参数不是有效的 JSON 对象。"])
        }
        object.removeValue(forKey: "display_title")
        switch toolName {
        case IOSAppleAgentToolCatalog.notificationSchedule:
            guard Set(object.keys).isSubset(of: ["title", "body", "fire_at"]),
                  let title = object["title"] as? String,
                  let value = object["fire_at"] as? String,
                  let fireDate = parseDate(value) else {
                return json(["ok": false, "tool": toolName, "reason": "需要 title 与 ISO-8601 fire_at。"])
            }
            do {
                let result = try await service.scheduleAgentNotification(
                    title: title,
                    body: object["body"] as? String ?? "",
                    fireDate: fireDate
                )
                switch result {
                case .scheduled(let identifier):
                    return json([
                        "ok": true, "tool": toolName, "identifier": identifier,
                        "fire_at": ISO8601DateFormatter().string(from: fireDate)
                    ])
                case .notAuthorized:
                    return json(["ok": false, "tool": toolName, "reason": "未获得通知权限。"])
                case .invalidDate:
                    return json(["ok": false, "tool": toolName, "reason": "提醒时间至少需要在 5 秒以后。"])
                }
            } catch {
                return json(["ok": false, "tool": toolName, "reason": error.localizedDescription])
            }
        case IOSAppleAgentToolCatalog.notificationCancel:
            guard object.isEmpty else {
                return json(["ok": false, "tool": toolName, "reason": "notification_cancel 不接受参数。"])
            }
            service.cancelAgentNotification()
            return json(["ok": true, "tool": toolName, "cancelled": true])
        default:
            return json(["ok": false, "tool": toolName, "reason": "未知通知工具。"])
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func json(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class IOSDeepLinkInbox {
    static let shared = IOSDeepLinkInbox()

    private var pending: [URL] = []
    private var handler: ((URL) -> Void)?
    private var promptHandoffs: [String: String] = [:]

    func preparePromptHandoff(_ prompt: String) -> IOSAppDeepLink.Destination? {
        guard let prompt = IOSAppDeepLink.normalizedPrompt(prompt) else { return nil }
        let id = UUID().uuidString.lowercased()
        promptHandoffs[id] = prompt
        return .agentPrompt(handoffID: id)
    }

    func consumePromptHandoff(id: String) -> String? {
        promptHandoffs.removeValue(forKey: id.lowercased())
    }

    func submit(_ url: URL) {
        guard IOSAppDeepLink.parse(url) != nil else { return }
        if let handler {
            handler(url)
        } else {
            pending.append(url)
        }
    }

    func installHandler(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let buffered = pending
        pending.removeAll()
        buffered.forEach(handler)
    }

    func removeHandler() {
        handler = nil
    }
}

@MainActor
final class AmberAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        WatchConnectivityBridge.shared.startReceiving(
            actionHandler: WatchTaskCoordinator.shared
        )
        IOSChatBackgroundGenerationCoordinator.shared.prepareForApplicationLaunch()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let value = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: value),
              IOSAppDeepLink.parse(url) != nil else { return }
        await MainActor.run {
            IOSDeepLinkInbox.shared.submit(url)
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await IOSBackendServicesCoordinator.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        IOSBackendServicesCoordinator.shared.didFailRemoteNotificationRegistration(error)
    }
}
