import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AmberMacAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    weak var workspace: DesktopWorkspace?
    var openMainWindow: (@MainActor () -> Void)?
    private var isTerminating = false
    private let notificationRouter = DesktopNotificationRouter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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
        guard let id = response.notification.request.content.userInfo["conversationID"] as? String,
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
                delegate.bind(workspace: workspace) { openWindow(id: windowID) }
            }
    }
}

