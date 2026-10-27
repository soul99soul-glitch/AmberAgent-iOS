import SwiftUI

struct PreviewSettingsView: View {
    @Bindable var workspace: DesktopWorkspace
    @State private var backupPresented = false
    @State private var storagePresented = false

    var body: some View {
        VStack(spacing: 0) {
            Label("界面预览：设置仅保留本次运行；获取模型、测试连接与登录不可用。", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            DesktopSettingsView(settings: workspace.settings, catalog: UnavailablePreviewCatalog(), oauth: UnavailablePreviewAuthorizer(),
                onOpenBackup: { backupPresented = true }, mcp: workspace.mcp, syncWorkspace: workspace,
                notifications: workspace.notifications, onOpenStorage: { storagePresented = true }, speech: workspace.speech)
        }
        .preferredColorScheme(DesktopTheme.colorScheme(for: workspace.settings.appearance))
        .sheet(isPresented: $backupPresented) { DesktopBackupView(workspace: workspace) }
        .sheet(isPresented: $storagePresented) {
            DesktopStorageUsageView(sources: workspace.storageUsageSources, conversationCount: workspace.summaries.count)
        }
    }
}

@MainActor private struct UnavailablePreviewCatalog: DesktopModelCatalog {
    func models(for configuration: DesktopProviderConfiguration, apiKey: String) async throws -> [DesktopCatalogModel] { throw unavailable }
    func testConnection(for configuration: DesktopProviderConfiguration, apiKey: String) async throws { throw unavailable }
    private var unavailable: DesktopRuntimeError { .message("界面预览不连接模型服务，请使用完整 Amber 应用。") }
}

@MainActor private struct UnavailablePreviewAuthorizer: DesktopCodexAuthorizer {
    func account(providerID: UUID) -> DesktopOAuthAccount? { nil }
    func requestCode(providerID: UUID) async throws -> DesktopDeviceAuthorization { throw unavailable }
    func poll(providerID: UUID, code: DesktopDeviceAuthorization) async throws -> DesktopOAuthAccount { throw unavailable }
    func logout(providerID: UUID) async throws {}
    private var unavailable: DesktopRuntimeError { .message("界面预览不执行登录，请使用完整 Amber 应用。") }
}
