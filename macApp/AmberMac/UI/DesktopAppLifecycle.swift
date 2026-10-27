import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AmberMacAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    weak var workspace: DesktopWorkspace?
    var openMainWindow: (@MainActor () -> Void)?
    var backgroundMode: DesktopBackgroundMode?
    private var isTerminating = false
    private let notificationRouter = DesktopNotificationRouter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DesktopSystemNotificationDelivery.registerCategories()
    }

    /// SwiftUI quits a single-Window app when its window closes; keep running in the menu bar instead when asked to.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(backgroundMode?.keepsRunning ?? false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { backgroundMode?.showDockIcon(); openMainWindow?() }
        return true
    }

    func bind(workspace: DesktopWorkspace, openMainWindow: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.openMainWindow = openMainWindow
        notificationRouter.bind(workspace: workspace) {
            openMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if action == DesktopNotificationAction.approve || action == DesktopNotificationAction.deny {
            guard let workspace, let runID = (info["runID"] as? String).flatMap(UUID.init(uuidString:)),
                  let toolID = info["toolID"] as? String else { return }
            await workspace.agentTasks.decideFromNotification(runID: runID, toolID: toolID,
                allow: action == DesktopNotificationAction.approve)
            return
        }
        guard let id = info["conversationID"] as? String,
              let id = UUID(uuidString: id) else { return }
        await notificationRouter.receive(conversationID: id)?.value
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        workspace.cancelBackup()
        workspace.imageGeneration.cancel()
        workspace.speech.stop()
        workspace.titles.cancelAll()
        workspace.webDAV.cancel()
        workspace.collaborations.cancelAll()
        workspace.recipes.cancelAll()
        workspace.scheduler?.cancelAll(reason: "应用退出，本次运行已中断。")
        workspace.cancelScheduledRuns()
        workspace.gatewayControl?.stop()
        workspace.agentTasks.cancelAll()
        for server in workspace.mcp.store.servers { workspace.mcp.disconnect(id: server.id) }
        workspace.insights.cancelAll()
        workspace.stop()
        Task {
            await workspace.mcp.shutdown()
            await workspace.imageGeneration.shutdown()
            await workspace.titles.flush()
            await workspace.waitUntilBackupFinished()
            await workspace.recipes.flush()
            await workspace.scheduler?.flush()
            await workspace.scheduler?.flushWrites()
            let collaborationsSaved = await workspace.collaborations.flush()
            await workspace.insights.flush()
            let conversationsSaved = await workspace.flush()
            let saved = conversationsSaved && collaborationsSaved
            if !saved {
                workspace.errorMessage = "仍有会话未能保存，已取消退出。请检查磁盘空间或文件权限，并导出重要会话备份。"
                isTerminating = false
                openMainWindow?()
            }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

struct DesktopWindowLifecycleView: View {
    let workspace: DesktopWorkspace
    let delegate: AmberMacAppDelegate
    let searchRequest: Int
    var findRequest = 0
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DesktopWorkspaceView(workspace: workspace, searchRequest: searchRequest, findRequest: findRequest)
            .task {
                delegate.bind(workspace: workspace) {
                    delegate.backgroundMode?.showDockIcon()
                    openWindow(id: windowID)
                }
            }
            .onDisappear {
                // The window closed but the app stays for scheduled tasks: drop the Dock icon, keep the menu bar item.
                if let mode = delegate.backgroundMode, mode.keepsRunning { mode.enterMenuBarOnly() }
            }
    }
}

