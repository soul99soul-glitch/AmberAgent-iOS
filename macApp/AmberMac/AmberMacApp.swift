import AppKit
import SwiftUI

@main
struct AmberMacApp: App {
    @NSApplicationDelegateAdaptor(AmberMacAppDelegate.self) private var appDelegate
    @State private var workspace: DesktopWorkspace
    @State private var searchRequest = 0
    @State private var backupPresented = false
    @State private var storagePresented = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-amber-mac-ui-fixture") {
            _workspace = State(initialValue: DesktopWorkspace.uiFixture())
            return
        }
        #endif
        _workspace = State(initialValue: DesktopWorkspace())
    }

    var body: some Scene {
        Window("Amber", id: "main") {
            DesktopWindowLifecycleView(workspace: workspace, delegate: appDelegate, searchRequest: searchRequest, windowID: "main")
                .frame(minWidth: 860, minHeight: 600)
                .tint(DesktopTheme.accent)
                .preferredColorScheme(DesktopTheme.colorScheme(for: workspace.settings.appearance))
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
                Button("搜索会话") { searchRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
            }
            SidebarCommands()
        }
        Settings {
            DesktopSettingsView(settings: workspace.settings, catalog: DesktopKMPModelCatalog(),
                oauth: DesktopMacCodexAuthorizer(), onOpenBackup: { backupPresented = true }, mcp: workspace.mcp,
                syncWorkspace: workspace, notifications: workspace.notifications, onOpenStorage: { storagePresented = true }, speech: workspace.speech)
                .sheet(isPresented: $backupPresented) { DesktopBackupView(workspace: workspace) }
                .sheet(isPresented: $storagePresented) {
                    DesktopStorageUsageView(sources: workspace.storageUsageSources, conversationCount: workspace.summaries.count)
                }
        }
    }
}
