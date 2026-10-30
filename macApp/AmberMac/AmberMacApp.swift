import AppKit
import SwiftUI

@main
struct AmberMacApp: App {
    @NSApplicationDelegateAdaptor(AmberMacAppDelegate.self) private var appDelegate
    @State private var workspace: DesktopWorkspace
    @State private var backgroundMode: DesktopBackgroundMode
    @State private var searchRequest = 0
    @State private var findRequest = 0
    @State private var commandPaletteRequest = 0
    @State private var backupPresented = false
    @State private var storagePresented = false

    init() {
        let workspace: DesktopWorkspace
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-amber-mac-ui-fixture") { workspace = DesktopWorkspace.uiFixture() }
        else { workspace = DesktopWorkspace() }
        #else
        workspace = DesktopWorkspace()
        #endif
        _workspace = State(initialValue: workspace)
        _backgroundMode = State(initialValue: DesktopBackgroundMode { [weak workspace] in
            guard let scheduler = workspace?.scheduler else { return false }
            return scheduler.enabledCount > 0 || !scheduler.running.isEmpty
        })
    }

    var body: some Scene {
        Window("Amber", id: "main") {
            DesktopWindowLifecycleView(
                workspace: workspace,
                delegate: appDelegate,
                searchRequest: searchRequest,
                findRequest: findRequest,
                commandPaletteRequest: commandPaletteRequest,
                windowID: "main"
            )
                .frame(minWidth: 860, minHeight: 600)
                .tint(DesktopTheme.accent)
                .preferredColorScheme(DesktopTheme.colorScheme(for: workspace.settings.appearance))
                .onAppear { appDelegate.backgroundMode = backgroundMode }
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { workspace.createConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(workspace.isLoading)
                Divider()
                Button("导入会话…") { DesktopFileActions.importConversation(workspace) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(workspace.isLoading)
                Button("导出当前会话…") { DesktopFileActions.exportConversation(workspace) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(workspace.selectedConversation == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("命令面板…") { commandPaletteRequest += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("在会话中查找") { findRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(workspace.selectedConversation?.messages.isEmpty != false)
                Button("搜索会话") { searchRequest += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            SidebarCommands()
        }
        MenuBarExtra(isInserted: Binding(get: { workspace.scheduler != nil && backgroundMode.keepsRunning }, set: { _ in })) {
            if let scheduler = workspace.scheduler {
                DesktopScheduleMenu(scheduler: scheduler, workspace: workspace, backgroundMode: backgroundMode)
            }
        } label: {
            Image(systemName: (workspace.scheduler?.running.isEmpty ?? true) ? "clock" : "clock.badge.checkmark")
                .accessibilityLabel("Amber 定时任务")
        }
        Settings {
            DesktopSettingsView(settings: workspace.settings, catalog: DesktopKMPModelCatalog(),
                oauth: DesktopMacCodexAuthorizer(), onOpenBackup: { backupPresented = true }, mcp: workspace.mcp,
                syncWorkspace: workspace, notifications: workspace.notifications, onOpenStorage: { storagePresented = true }, speech: workspace.speech,
                backgroundMode: workspace.scheduler == nil ? nil : backgroundMode, gateway: workspace.gateway)
                .sheet(isPresented: $backupPresented) { DesktopBackupView(workspace: workspace) }
                .sheet(isPresented: $storagePresented) {
                    DesktopStorageUsageView(sources: workspace.storageUsageSources, conversationCount: workspace.summaries.count)
                }
        }
    }
}
