import AppKit
import SwiftUI
import WebKit

// MARK: - Controlled WKWebView Host for amber.plugin.v3 Custom Views

struct DesktopPluginWebView: NSViewRepresentable {
    let store: DesktopPluginStore
    let pluginID: String
    let viewID: String
    let entryPath: String
    let reloadRevision: Int
    let isDark: Bool

    func makeCoordinator() -> CoordinatorHolder {
        CoordinatorHolder(pluginID: pluginID, viewID: viewID, store: store)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let schemeHandler = DesktopPluginURLSchemeHandler(store: store)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: DesktopPluginURLSchemeHandler.scheme)

        let userController = WKUserContentController()
        let bootstrapJS = DesktopPluginWebViewBridgeScript.webViewBootstrapJS(
            pluginID: pluginID,
            viewID: viewID,
            isDark: isDark
        )
        let userScript = WKUserScript(
            source: bootstrapJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userController.addUserScript(userScript)
        userController.add(context.coordinator.bridgeCoordinator, name: "amberBridge")
        config.userContentController = userController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator.bridgeCoordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.bridgeCoordinator.webView = webView
        store.registerWebViewCoordinator(context.coordinator.bridgeCoordinator)

        context.coordinator.loadIfNeeded(
            webView: webView,
            pluginID: pluginID,
            entryPath: entryPath,
            revision: reloadRevision,
            isDark: isDark
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(
            webView: webView,
            pluginID: pluginID,
            entryPath: entryPath,
            revision: reloadRevision,
            isDark: isDark
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CoordinatorHolder) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amberBridge")
        coordinator.store?.unregisterWebViewCoordinator(pluginID: coordinator.pluginID, viewID: coordinator.viewID)
    }

    @MainActor
    final class CoordinatorHolder {
        let pluginID: String
        let viewID: String
        weak var store: DesktopPluginStore?
        let bridgeCoordinator: DesktopPluginWebViewCoordinator
        private var loadedURLString: String?
        private var loadedRevision: Int = -1
        private var lastIsDark: Bool?

        init(pluginID: String, viewID: String, store: DesktopPluginStore) {
            self.pluginID = pluginID
            self.viewID = viewID
            self.store = store
            self.bridgeCoordinator = DesktopPluginWebViewCoordinator(pluginID: pluginID, viewID: viewID, store: store)
        }

        func loadIfNeeded(webView: WKWebView, pluginID: String, entryPath: String, revision: Int, isDark: Bool) {
            let cleanEntry = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let effectiveEntry = cleanEntry.isEmpty ? "index.html" : cleanEntry
            let urlString = "\(DesktopPluginURLSchemeHandler.scheme)://\(pluginID)/\(effectiveEntry)"

            if lastIsDark != isDark {
                lastIsDark = isDark
                if let payloadJSON = try? DesktopPluginStore.encodeAnyJSON([
                    "theme": isDark ? "dark" : "light",
                    "isDark": isDark,
                    "css": DesktopPluginThemeCSS.stylesheet(isDark: isDark)
                ]) {
                    bridgeCoordinator.pushEvent(name: "theme:changed", payloadJSON: payloadJSON)
                }
            }

            guard loadedURLString != urlString || loadedRevision != revision else { return }
            loadedURLString = urlString
            loadedRevision = revision
            if let url = URL(string: urlString) {
                webView.load(URLRequest(url: url))
            }
        }
    }
}

// MARK: - Custom Plugin View Container (Header + Hot Reload Button + Notice Banner + WebView)

struct DesktopPluginCustomViewContainer: View {
    @Bindable var workspace: DesktopWorkspace
    let pluginID: String
    let viewID: String
    let title: String
    let subtitle: String
    let symbol: String
    let entryPath: String
    var showHeader: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    private var reloadRevision: Int {
        workspace.plugins.pluginReloadRevisions[pluginID] ?? 0
    }

    private var plugin: DesktopInstalledPlugin? {
        workspace.plugins.plugins.first { $0.id == pluginID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                headerBar
                Rectangle()
                    .fill(DesktopTheme.hairline)
                    .frame(height: 1)
            }

            if let notice = workspace.plugins.latestNotice, notice.pluginID == pluginID {
                noticeBanner(notice)
            }

            if let plugin, (!plugin.manifest.isV3 || workspace.plugins.hasPermission(plugin: plugin, permission: "ui.views")) {
                DesktopPluginWebView(
                    store: workspace.plugins,
                    pluginID: pluginID,
                    viewID: viewID,
                    entryPath: entryPath,
                    reloadRevision: reloadRevision,
                    isDark: colorScheme == .dark
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionMissingFallback
            }
        }
        .background(DesktopTheme.paper)
        .onChange(of: colorScheme, initial: true) { _, nextScheme in
            workspace.plugins.broadcastHostEvent("theme:changed", payload: ["isDark": nextScheme == .dark])
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesktopTheme.honeySoft)
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesktopTheme.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    if let plugin {
                        Text("v\(plugin.manifest.version)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(DesktopTheme.paperDeep))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                try? workspace.plugins.reloadPlugin(id: pluginID)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重载插件")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DesktopTheme.inkSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesktopTheme.paperSide))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesktopTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("热重载插件脚本与静态界面")

            Button {
                workspace.openChatSurface()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 11, weight: .medium))
                    Text("返回对话")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DesktopTheme.inkSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesktopTheme.paperSide))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesktopTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DesktopTheme.paper)
    }

    private func noticeBanner(_ notice: DesktopPluginNoticeBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(notice.kind == .error ? DesktopTheme.danger : DesktopTheme.accent)
            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesktopTheme.ink)
            Spacer()
            Button {
                workspace.plugins.latestNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DesktopTheme.honeySoft)
    }

    private var permissionMissingFallback: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(DesktopTheme.inkTertiary)
            Text("插件尚未获得自定义界面（ui.views）权限")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesktopTheme.ink)
            Text("请在「设置 → 插件」中检查并批准该插件声明的界面权限。")
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Modal Sheet for `amber.ui.openModal`

struct DesktopPluginModalSheet: View {
    @Bindable var workspace: DesktopWorkspace
    let modal: DesktopPluginModalPresentation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(modal.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                Text(modal.pluginName)
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                Button {
                    workspace.plugins.activeModal = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DesktopTheme.paperSide)

            Rectangle()
                .fill(DesktopTheme.hairline)
                .frame(height: 1)

            DesktopPluginWebView(
                store: workspace.plugins,
                pluginID: modal.pluginID,
                viewID: modal.viewID,
                entryPath: modal.entryPath,
                reloadRevision: workspace.plugins.pluginReloadRevisions[modal.pluginID] ?? 0,
                isDark: colorScheme == .dark
            )
            .frame(width: max(360, modal.width), height: max(260, modal.height))
        }
        .background(DesktopTheme.paper)
    }
}

// MARK: - Install / Upgrade Permission Consent Sheet (amber.plugin.v3)

struct DesktopPluginPermissionConsentSheet: View {
    let plan: DesktopPluginInstallPlan
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesktopTheme.honeySoft)
                        .frame(width: 40, height: 40)
                    Image(systemName: plan.manifest.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesktopTheme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.isUpgrade ? "升级插件权限确认" : "安装插件权限确认")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        Text("\(plan.manifest.name) v\(plan.manifest.version)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesktopTheme.accentInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesktopTheme.honeySoft))
                    }
                    Text(plan.manifest.description)
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }
                Spacer()
            }

            Rectangle()
                .fill(DesktopTheme.hairline)
                .frame(height: 1)

            Text(plan.isUpgrade
                 ? "该插件在升级至 v\(plan.manifest.version) 时声明了以下能力权限，确认后方可生效："
                 : "该插件声明了以下能力权限。未声明的能力将被沙箱立即拒绝：")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesktopTheme.inkSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.permissions) { perm in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: perm.isHighRisk ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(perm.isHighRisk ? DesktopTheme.danger : DesktopTheme.accent)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(perm.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(DesktopTheme.ink)
                                    if perm.isHighRisk {
                                        Text("高风险")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(DesktopTheme.danger)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(DesktopTheme.danger.opacity(0.12)))
                                    }
                                    if perm.isNewlyRequested && plan.isUpgrade {
                                        Text("升级新增")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(DesktopTheme.accentInk)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(DesktopTheme.honeySoft))
                                    }
                                }
                                Text(perm.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DesktopTheme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DesktopTheme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DesktopTheme.hairline, lineWidth: 1))
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DesktopTheme.paperSide))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DesktopTheme.hairline, lineWidth: 1))

                Button(plan.isUpgrade ? "批准并升级" : "批准并安装", action: onApprove)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DesktopTheme.accent))
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(DesktopTheme.paper)
    }
}
