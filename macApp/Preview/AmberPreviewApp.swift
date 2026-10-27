import SwiftUI

@main
struct AmberPreviewApp: App {
    @NSApplicationDelegateAdaptor(AmberMacAppDelegate.self) private var appDelegate
    @State private var workspace = DesktopWorkspace.uiFixture()
    @State private var searchRequest = 0
    @State private var findRequest = 0

    var body: some Scene {
        Window("Amber · 界面预览", id: "preview") {
            VStack(spacing: 0) {
                DesktopWindowLifecycleView(workspace: workspace, delegate: appDelegate,
                    searchRequest: searchRequest, findRequest: findRequest, windowID: "preview")
                Divider()
                HStack(spacing: 7) {
                    Image(systemName: "eye")
                    Text("界面预览 · 会话仅保留本次运行 · 未连接模型服务")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
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
                Button("在会话中查找") { findRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(workspace.selectedConversation?.messages.isEmpty != false)
                Button("搜索会话") { searchRequest += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            SidebarCommands()
        }
        Settings {
            PreviewSettingsView(workspace: workspace)
        }
    }
}
