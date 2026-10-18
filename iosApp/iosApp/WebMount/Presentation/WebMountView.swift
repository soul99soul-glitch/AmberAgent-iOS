import Foundation
import SwiftUI
import WebKit

@MainActor
struct WebMountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    @State private var controller: IOSWebMountController
    @State private var showAddSite = false
    @State private var addName = ""
    @State private var addURL = ""
    @State private var addNeedsLogin = true
    @State private var addCookieName = ""
    @State private var addSiteError: String?
    @State private var banner: String?
    @State private var showDesktopBackends = false
    @State private var focusedRemoteSessionId: String?

    private var registry: IOSWebMountRegistry { controller.registry }
    private var settings: IOSWebMountSettings { controller.settings }

    init(controller: IOSWebMountController = .shared) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ZStack {
            AmberThemePageBackground(surface: .app)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        if let banner {
                            WebMountBanner(text: banner)
                                .padding(.top, 4)
                        }
                        stationSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAddSite) {
            addSiteSheet
        }
        .sheet(isPresented: $showDesktopBackends, onDismiss: {
            focusedRemoteSessionId = nil
        }) {
            WebMountDesktopBackendsView(
                controller: controller,
                focusedSessionId: focusedRemoteSessionId
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text(IOSAppLocalization.string("WebMount", defaultValue: "WebMount"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(registry.sites.count) 个站点")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
            }

            Spacer()

            Button {
                addSiteError = nil
                showAddSite = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .amberGlass(cornerRadius: 22)
            .accessibilityLabel("添加 WebMount 站点")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var stationSection: some View {
        VStack(spacing: 0) {
            desktopBackendSection
            agentBrowserTaskSection
            AmberSectionLabel(text: "站点")
            AmberFormGroup {
                if registry.sites.isEmpty {
                    Text("还没有 WebMount 站点。添加一个 http(s) 网站，或恢复内置站点。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(registry.sites.enumerated()), id: \.element.id) { index, site in
                        WebMountStationRow(
                            site: site,
                            onOpen: {
                                router.navigate(to: .webMountSite(site: WebMountSiteRoute(
                                    site: site,
                                    sessionId: controller.sessionStore.currentSessionId
                                )))
                            },
                            onToggle: { enabled in
                                registry.setEnabled(id: site.id, enabled: enabled)
                            },
                            onDelete: {
                                delete(site)
                            }
                        )
                        if index < registry.sites.count - 1 {
                            WebMountDivider()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    let restored = registry.restoreMissingSeeds()
                    settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
                    banner = restored == 0 ? "内置站点已是最新。" : "已恢复 \(restored) 个内置站点。"
                } label: {
                    Label("恢复内置站点", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private var desktopBackendSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "浏览器")
            AmberFormGroup {
                AmberFormRow(
                    systemImage: "macwindow.on.rectangle",
                    iconColor: AmberTheme.accent,
                    title: "浏览器与会话",
                    subtitle: "管理本地与桌面浏览器",
                    trailing: "管理",
                    showsChevron: true
                ) {
                    focusedRemoteSessionId = nil
                    showDesktopBackends = true
                }
            }
        }
    }

    private var agentBrowserSessions: [IOSWebMountSessionRecord] {
        controller.sessionStore.records
            .filter { record in
                guard record.ownerConversationId?.nilIfBlank != nil else { return false }
                return record.backend != .local || WebMountSiteRoute(watching: record, registry: registry) != nil
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityMillis != rhs.lastActivityMillis {
                    return lhs.lastActivityMillis > rhs.lastActivityMillis
                }
                return lhs.id < rhs.id
            }
    }

    private var agentBrowserTaskSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Agent 浏览器任务")
            if agentBrowserSessions.isEmpty {
                AmberFormGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无 Agent 浏览任务")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("Agent 开始浏览网页后，可在这里观看或接管页面。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(agentBrowserSessions) { record in
                        AgentBrowserTaskCard(record: record) {
                            openAgentBrowserSession(record.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func openAgentBrowserSession(_ sessionId: String) {
        guard let existingRecord = controller.sessionStore.record(sessionId: sessionId) else {
            banner = "此站点会话不存在或已过期。"
            return
        }
        if existingRecord.needsReopen {
            guard controller.sessionStore.reopen(sessionId: sessionId) != nil else {
                banner = "此站点会话暂时无法重新打开。"
                return
            }
        }
        guard let record = controller.sessionStore.record(sessionId: sessionId) else {
            banner = "此站点会话不存在或已过期。"
            return
        }
        controller.sessionStore.showCard(sessionId: sessionId)
        if record.backend == .local {
            guard let route = WebMountSiteRoute(watching: record, registry: registry) else {
                banner = "此站点会话未绑定可用站点，无法观看。"
                return
            }
            router.navigate(to: .webMountSite(site: route))
        } else {
            focusedRemoteSessionId = record.id
            Task { @MainActor in
                showDesktopBackends = true
            }
        }
    }

    private var addSiteSheet: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        AmberFormGroup {
                            WebMountTextFieldRow(title: "名称", text: $addName, placeholder: "示例")
                            WebMountDivider()
                            WebMountTextFieldRow(title: "网址", text: $addURL, placeholder: "https://example.com")
                            WebMountDivider()
                            WebMountToggleRow(
                                title: "需要登录",
                                subtitle: "保存登录提示，不会自动打开登录流程。",
                                systemImage: "person.badge.key",
                                tint: AmberTheme.accent,
                                isOn: $addNeedsLogin
                            )
                            if addNeedsLogin {
                                WebMountDivider()
                                WebMountTextFieldRow(title: "Cookie 提示", text: $addCookieName, placeholder: "可选")
                            }
                        }

                        if let addSiteError {
                            WebMountBanner(text: addSiteError)
                        }

                        Text("自定义站点会保存在本机，Cookie 内容不会在页面中显示。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    .padding(.top, 16)
                }
            }
            .navigationTitle("添加站点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddSite = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { addSite() }
                }
            }
        }
    }

    private func addSite() {
        do {
            let site = try registry.addCustomSite(
                displayName: addName,
                homepageURL: addURL,
                needsLogin: addNeedsLogin,
                loginCookieName: addCookieName
            )
            settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
            addName = ""
            addURL = ""
            addCookieName = ""
            addNeedsLogin = true
            addSiteError = nil
            showAddSite = false
            banner = "已添加 \(site.displayName)。"
        } catch {
            addSiteError = "添加失败。请填写名称，并使用 http(s) 网址。"
        }
    }

    private func delete(_ site: IOSWebMountSite) {
        if registry.remove(id: site.id) {
            settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
            banner = "已移除 \(site.displayName)。"
        }
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

#Preview {
    NavigationStack {
        WebMountView()
    }
}
