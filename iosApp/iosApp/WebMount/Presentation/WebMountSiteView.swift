import Foundation
import SwiftUI
import WebKit

private enum WebMountResultTab: String, CaseIterable, Identifiable {
    case text
    case links
    case interactive
    case visual
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "正文"
        case .links: "链接"
        case .interactive: "交互"
        case .visual: "视觉"
        case .debug: "调试"
        }
    }
}

private enum WebMountSiteSheet: String, Identifiable, Equatable {
    case inspector
    case popup
    case runReport
    case siteMemory

    var id: String { rawValue }
}

private enum WebMountInspectorTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case content = "内容"
    case login = "登录"

    var id: String { rawValue }
}

@MainActor
struct WebMountSiteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    let site: WebMountSiteRoute

    @State private var controller: IOSWebMountController
    @ObservedObject private var runtime: IOSWebMountWKRuntime
    @State private var cookieSummary: IOSWebMountCookieSummary?
    @State private var bridgeState = ""
    @State private var extractText = ""
    @State private var linksText = ""
    @State private var interactiveText = ""
    @State private var visualSnapshotText = ""
    @State private var debugJSONText = ""
    @State private var selectedResultTab: WebMountResultTab = .text
    @State private var getSelector = "body"
    @State private var getText = ""
    @State private var openURLText = ""
    @State private var contentHandoff: IOSWebMountContentHandoff?
    @State private var banner: String?
    @State private var isLoading = false
    @State private var observationRequestID: UUID?
    @State private var presentedSheet: WebMountSiteSheet?
    @State private var popupPresentationQueued = false
    @State private var selectedPopupIdentifier: ObjectIdentifier?
    @State private var lastPresentedSheet: WebMountSiteSheet?
    @FocusState private var isAddressBarFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var inspectorTab: WebMountInspectorTab = .overview
    @State private var rootBrowserHostID = UUID()
    @State private var inspectorBrowserHostID = UUID()
    @State private var popupBrowserHostID = UUID()
    private let hasBoundSession: Bool

    private var registry: IOSWebMountRegistry { controller.registry }
    private var isUnlistedWatchSession: Bool {
        site.mode == .watch && registry.site(id: site.siteId) == nil
    }
    private var resolvedSite: IOSWebMountSite {
        registry.site(id: site.siteId) ?? IOSWebMountSite(
            id: site.siteId,
            displayName: site.name,
            homepageURL: "https://\(site.host)",
            authKind: .anonymous,
            loginCookieName: nil,
            nativeAdapterId: nil,
            iconKey: nil,
            oauthProviderId: nil,
            allowedHosts: [site.host],
            enabled: false,
            addedAtMillis: IOSWebMountClock.nowMillis()
        )
    }

    init(site: WebMountSiteRoute, controller: IOSWebMountController = .shared) {
        self.site = site
        _controller = State(initialValue: controller)
        let boundRuntime: IOSWebMountRuntimeServicing?
        if site.mode == .watch {
            boundRuntime = site.sessionId?.nilIfBlank.flatMap {
                controller.sessionStore.runtimeIfPresent(sessionId: $0)
            }
        } else {
            boundRuntime = controller.sessionStore.runtimeIfPresent(sessionId: site.sessionId)
        }
        if let webRuntime = boundRuntime as? IOSWebMountWKRuntime {
            _runtime = ObservedObject(wrappedValue: webRuntime)
            hasBoundSession = true
        } else {
            _runtime = ObservedObject(wrappedValue: IOSWebMountWKRuntime(sessionId: site.sessionId))
            hasBoundSession = false
        }
    }

    private var isWatchMode: Bool {
        site.mode == .watch
    }

    private var sessionRecord: IOSWebMountSessionRecord? {
        guard hasBoundSession else { return nil }
        let sessionId = isWatchMode ? site.sessionId : runtime.snapshot.sessionId
        guard let sessionId = sessionId?.nilIfBlank else { return nil }
        return controller.sessionStore.record(sessionId: sessionId)
    }

    private var isAgentControlActive: Bool {
        sessionRecord?.controlOwner == .agent
    }

    private var canUserMutate: Bool {
        hasBoundSession && sessionRecord?.controlOwner == .user
    }

    private var hasViewablePage: Bool {
        guard hasBoundSession, let sessionRecord else { return false }
        return !sessionRecord.needsReopen
    }

    private var canReadPage: Bool {
        hasViewablePage && runtime.snapshot.status == .ready
    }

    private var latestPopupIdentifier: ObjectIdentifier? {
        runtime.popupWebViews.last.map { ObjectIdentifier($0) }
    }

    private var siteMemoryHosts: [String] {
        var hosts = resolvedSite.allowedHosts
            .map { IOSWebMountRegistry.memoryHostKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        let homepageHost = IOSWebMountRegistry.memoryHostKey(
            resolvedSite.homepageHost.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !hosts.contains(homepageHost) {
            hosts.append(homepageHost)
        }
        return hosts.reduce(into: [String]()) { result, host in
            if !result.contains(host) { result.append(host) }
        }
    }

    private var siteMemoryInitialHost: String {
        if let currentHost = runtime.snapshot.currentURL
            .flatMap({ URL(string: $0)?.host })
            .map(IOSWebMountRegistry.memoryHostKey),
           siteMemoryHosts.contains(currentHost) {
            return currentHost
        }
        return IOSWebMountRegistry.memoryHostKey(
            resolvedSite.homepageHost.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var activePopup: WKWebView? {
        if let selectedPopupIdentifier,
           let selected = runtime.popupWebViews.first(where: {
               ObjectIdentifier($0) == selectedPopupIdentifier
           }) {
            return selected
        }
        return runtime.popupWebViews.last
    }

    private var displayedBanner: String? {
        if let browserNotice = runtime.browserNotice?.nilIfBlank {
            return browserNotice
        }
        if isWatchMode {
            guard hasBoundSession, let sessionRecord else {
                return "此站点会话不存在或已过期，请返回任务列表。"
            }
            if let banner {
                return banner
            }
            if sessionRecord.needsReopen {
                return "此站点会话需要重新打开；Amber 不会自动恢复旧页面或动作。"
            }
            if runtime.snapshot.status == .idle {
                return "此 session 尚未打开页面；观看不会自动导航。"
            }
            if runtime.snapshot.status == .failed,
               let error = runtime.snapshot.error?.nilIfBlank {
                return "页面加载失败：\(IOSWebMountRedactor.redactedText(error))"
            }
        }
        return banner
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            workspaceBrowserBar

            if let banner = displayedBanner {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(banner)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AmberTheme.surface2)
            }

            webViewSection
        }
        .background(AmberTheme.surface.ignoresSafeArea())
        .overlay {
            if presentedSheet == nil {
                browserDialogOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if openURLText.isEmpty {
                openURLText = runtime.snapshot.currentURL
                    ?? runtime.snapshot.requestedURL
                    ?? resolvedSite.homepageURL
            }
            guard hasBoundSession, sessionRecord != nil else {
                await refreshCookieSummary()
                return
            }
            if isWatchMode {
                if let sessionId = site.sessionId?.nilIfBlank {
                    controller.sessionStore.touch(sessionId: sessionId, makeCurrent: false)
                }
                await refreshCookieSummary()
                return
            }
            controller.sessionStore.touch(sessionId: runtime.snapshot.sessionId, makeCurrent: true)
            if sessionRecord?.controlOwner == IOSWebMountControlOwner.none {
                _ = try? controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
            }
            await refreshCookieSummary()
            if runtime.snapshot.status == .idle && !isAgentControlActive {
                await openSite()
            }
        }
        .sheet(item: $presentedSheet, onDismiss: presentedSheetDidDismiss) { sheet in
            switch sheet {
            case .inspector:
                inspectorSheet
            case .popup:
                popupSheet
            case .runReport:
                WebMountRunReportSheet(sessionRecord: sessionRecord) {
                    presentedSheet = nil
                }
            case .siteMemory:
                WebMountSiteMemorySheet(
                    hosts: siteMemoryHosts,
                    selectedHost: siteMemoryInitialHost,
                    registry: registry
                ) {
                    presentedSheet = nil
                }
            }
        }
        .onChange(of: latestPopupIdentifier) { _, identifier in
            guard let identifier else {
                selectedPopupIdentifier = nil
                popupPresentationQueued = false
                if presentedSheet == .popup {
                    presentedSheet = nil
                }
                Task { await refreshCookieSummary() }
                return
            }

            selectedPopupIdentifier = identifier
            switch presentedSheet {
            case nil:
                if runtime.browserDialog == nil {
                    presentedSheet = .popup
                } else {
                    popupPresentationQueued = true
                }
            case .inspector, .runReport, .siteMemory:
                popupPresentationQueued = true
            case .popup:
                break
            }
        }
        .onChange(of: runtime.browserDialog?.id) { _, dialogID in
            guard dialogID == nil,
                  popupPresentationQueued,
                  presentedSheet == nil,
                  !runtime.popupWebViews.isEmpty else { return }
            popupPresentationQueued = false
            presentedSheet = .popup
        }
        .onChange(of: runtime.snapshot.status) { _, status in
            if status == .ready { Task { await refreshCookieSummary() } }
        }
        .onChange(of: runtime.popupNavigationRevision) { _, _ in
            Task { await refreshCookieSummary() }
        }
        .onChange(of: runtime.snapshot.currentURL) { _, currentURL in
            guard !isAddressBarFocused, !isLoading, let currentURL else { return }
            openURLText = currentURL
        }
        .onAppear {
            if let identifier = latestPopupIdentifier {
                selectedPopupIdentifier = identifier
                if presentedSheet == nil, runtime.browserDialog == nil {
                    presentedSheet = .popup
                } else if presentedSheet == .inspector || presentedSheet == .runReport || presentedSheet == .siteMemory {
                    popupPresentationQueued = true
                }
            }
        }
        .onChange(of: presentedSheet) { _, sheet in
            if let sheet {
                lastPresentedSheet = sheet
            }
        }
        .browserPresentationHost(runtime: runtime, hostID: rootBrowserHostID)
    }

    private var header: some View {
        HStack(spacing: 0) {
            workspaceBrowserButton(systemImage: "chevron.left", accessibilityLabel: "返回站点", isEnabled: true) {
                dismiss()
            }

            Text(resolvedSite.displayName)
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            workspaceBackButton
            workspaceForwardButton
            workspaceBrowserButton(
                systemImage: "brain",
                accessibilityLabel: "站点记忆",
                isEnabled: true
            ) {
                presentedSheet = .siteMemory
            }
            .accessibilityIdentifier("webmount.siteMemory.header")
            pageMenu
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var pageMenu: some View {
        Menu {
            Section {
                Button("打开站点首页", systemImage: "house") {
                    Task { await openSite() }
                }
                .disabled(isLoading || !canUserMutate)
                Button(controlActionTitle, systemImage: controlOwnerImage) {
                    if canUserMutate { handBackToAgent() } else { takeUserControl() }
                }
                .disabled(sessionRecord == nil)
            }
            Section {
                Button("提取正文", systemImage: "doc.text") {
                    inspectorTab = .content
                    presentedSheet = .inspector
                    Task { await extractReadable() }
                }
                .disabled(!canReadPage)
                Button("登录与站点数据", systemImage: "person.crop.circle") {
                    inspectorTab = .login
                    presentedSheet = .inspector
                }
                Button("页面检查器", systemImage: "slider.horizontal.3") {
                    inspectorTab = .overview
                    presentedSheet = .inspector
                }
                Button("站点记忆", systemImage: "brain") {
                    presentedSheet = .siteMemory
                }
                .accessibilityIdentifier("webmount.siteMemory")
                Button("运行报告", systemImage: "chart.bar.xaxis") {
                    presentedSheet = .runReport
                }
                .disabled(sessionRecord == nil)
                .accessibilityIdentifier("webmount.runReport")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("页面菜单")
        .accessibilityIdentifier("webmount.pageMenu")
    }

    private var workspaceBrowserBar: some View {
        HStack(spacing: 8) {
            addressBar
            workspaceControlButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Divider().overlay(AmberTheme.borderSoft)
        }
    }

    private var workspaceBackButton: some View {
        workspaceBrowserButton(
            systemImage: "chevron.left",
            accessibilityLabel: "网页后退",
            isEnabled: runtime.snapshot.canGoBack && canUserMutate
        ) {
            dismissAddressBarKeyboard()
            Task { _ = await runtime.back() }
        }
    }

    private var workspaceForwardButton: some View {
        workspaceBrowserButton(
            systemImage: "chevron.right",
            accessibilityLabel: "网页前进",
            isEnabled: runtime.snapshot.canGoForward && canUserMutate
        ) {
            dismissAddressBarKeyboard()
            Task { _ = await runtime.forward() }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 0) {
            TextField("输入网址", text: $openURLText)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .padding(.leading, 14)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isAddressBarFocused)
                .onSubmit { Task { await openTypedURL() } }
                .disabled(!canUserMutate)
                .accessibilityLabel("网页地址")
                .accessibilityIdentifier("webmount.address")

            workspaceBrowserButton(
                systemImage: isAddressBarFocused ? "arrow.right" : "arrow.clockwise",
                accessibilityLabel: isAddressBarFocused ? "打开网址" : "重新加载当前页面",
                isEnabled: !isLoading && canUserMutate
            ) {
                if isAddressBarFocused {
                    Task { await openTypedURL() }
                } else {
                    reloadCurrentPage()
                }
            }
        }
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func workspaceBrowserButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? AmberTheme.foreground2 : AmberTheme.muted2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var workspaceControlButton: some View {
        Button {
            if sessionRecord?.controlOwner == .user {
                handBackToAgent()
            } else {
                takeUserControl()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: controlOwnerImage)
                    .font(.system(size: 14, weight: .semibold))
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(workspaceControlOwnerLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(controlOwnerTint)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(controlOwnerTint.opacity(0.10), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(sessionRecord == nil)
        .opacity(sessionRecord == nil ? 0.45 : 1)
        .layoutPriority(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IOSAppLocalization.string(workspaceControlAccessibilityLabel))
        .accessibilityValue(controlOwnerBadgeText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("切换页面控制权")
        .accessibilityIdentifier("webmount.control")
    }

    private var inspectorSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("检查器分类", selection: $inspectorTab) {
                    ForEach(WebMountInspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(spacing: 0) {
                        if let banner = displayedBanner {
                            WebMountBanner(text: banner)
                                .padding(.top, 8)
                        }
                        switch inspectorTab {
                        case .overview: runtimeSection
                        case .content: bridgeSection
                        case .login: cookieSection
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .background(AmberTheme.surface2)
            .navigationTitle("页面检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", systemImage: "xmark") { presentedSheet = nil }
                }
            }
        }
        .overlay { browserDialogOverlay }
        .interactiveDismissDisabled(runtime.browserDialog != nil)
        .browserPresentationHost(runtime: runtime, hostID: inspectorBrowserHostID)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var runtimeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "当前页面")
            AmberFormGroup {
                WebMountInfoRow(
                    title: runtime.snapshot.title?.nilIfBlank ?? resolvedSite.displayName,
                    subtitle: statusSubtitle,
                    systemImage: "globe",
                    tint: AmberTheme.foreground2,
                    trailing: statusText
                )
                WebMountDivider()
                controlRow
            }
            AmberSectionLabel(text: "会话")
            AmberFormGroup {
                browserChromeRow
            }
        }
    }

    @ViewBuilder
    private var bridgeActionButtons: some View {
        Button("读取状态", systemImage: "info.circle") { Task { await readState() } }
            .disabled(!canReadPage)
        Button("提取正文", systemImage: "doc.text") { Task { await extractReadable() } }
            .disabled(!canReadPage)
        Button("观察交互元素", systemImage: "cursorarrow") { Task { await self.observePage() } }
            .disabled(!canReadPage || observationRequestID != nil)
        Button("视觉快照", systemImage: "camera") { Task { await visualSnapshot() } }
            .disabled(!canReadPage)
    }

    private var browserChromeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("浏览模式", value: isWatchMode ? "观看模式" : "手动浏览")
            LabeledContent("登录状态", value: loginBadgeText)
            LabeledContent("Agent 访问", value: isUnlistedWatchSession ? "高风险模式" : (resolvedSite.enabled ? "已允许" : "未允许"))
            if let sessionRecord, sessionRecord.persistentOptIn {
                LabeledContent("保留会话", value: "已开启")
            }
            DisclosureGroup("会话标识") {
                Text(runtime.snapshot.sessionId)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .font(.subheadline)
        .foregroundStyle(AmberTheme.foreground2)
        .tint(AmberTheme.muted)
        .padding(16)
    }

    private var webViewSection: some View {
        Group {
            if hasViewablePage {
                WebMountRuntimeWebView(runtime: runtime, isInteractive: canUserMutate)
                    .accessibilityHint(isWatchMode && !canUserMutate ? "观看模式，仅可查看；接管后可操作。" : "")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: sessionRecord?.needsReopen == true ? "arrow.clockwise" : "rectangle.slash")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AmberTheme.muted2)
                    Text(sessionRecord?.needsReopen == true ? "会话需要重新打开" : "会话不存在或已过期")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(sessionRecord?.needsReopen == true
                         ? "接管后可显式打开页面；旧页面和旧动作不会自动恢复。"
                         : "返回 Agent 浏览器任务列表重新打开。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AmberTheme.surface2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmberTheme.surface)
        .layoutPriority(1)
        .overlay(alignment: .bottom) {
            if hasViewablePage && !canUserMutate {
                webViewTakeoverPrompt
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasViewablePage,
               presentedSheet != .popup,
               !runtime.popupWebViews.isEmpty {
                popupWindowMenu()
                    .padding(12)
            }
        }
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView(value: runtime.snapshot.estimatedProgress)
                    .tint(AmberTheme.accent)
            }
        }
    }

    private var popupSheet: some View {
        NavigationStack {
            ZStack {
                AmberThemePageBackground(surface: .app)

                if let popup = activePopup {
                    WebMountRuntimeWebView(webView: popup, isInteractive: canUserMutate)
                        .id(ObjectIdentifier(popup))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if !canUserMutate {
                                webViewTakeoverPrompt
                            }
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(AmberTheme.muted2)
                        Text("登录窗口已关闭")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let browserNotice = runtime.browserNotice?.nilIfBlank {
                    WebMountBanner(text: browserNotice)
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                        .background(AmberTheme.surface)
                }
            }
            .navigationTitle(popupHost)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        closePopupSheet()
                    }
                }
                if runtime.popupWebViews.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        popupWindowMenu(compact: true)
                    }
                }
            }
        }
        .overlay {
            browserDialogOverlay
        }
        .interactiveDismissDisabled(runtime.browserDialog != nil)
        .browserPresentationHost(runtime: runtime, hostID: popupBrowserHostID)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var popupHost: String {
        activePopup?.url?.host?.nilIfBlank
            ?? resolvedSite.homepageHost
    }

    private func popupWindowMenu(compact: Bool = false) -> some View {
        let count = runtime.popupWebViews.count
        return Menu {
            ForEach(Array(runtime.popupWebViews.enumerated()), id: \.offset) { index, popup in
                Button {
                    selectPopup(popup)
                } label: {
                    Label {
                        Text("窗口 \(index + 1)：\(popup.url?.host?.nilIfBlank ?? "登录窗口")")
                    } icon: {
                        Image(systemName: activePopup.map { $0 === popup } == true ? "checkmark" : "macwindow")
                    }
                }
            }
            Divider()
            Button("关闭当前窗口", role: .destructive) {
                closePopupSheet()
            }
        } label: {
            if compact {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                Label("登录窗口 \(count)", systemImage: "macwindow.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择登录窗口，共 \(count) 个")
    }

    private func selectPopup(_ popup: WKWebView) {
        guard runtime.popupWebViews.contains(where: { $0 === popup }) else { return }
        selectedPopupIdentifier = ObjectIdentifier(popup)
        if presentedSheet == nil {
            presentedSheet = .popup
        }
    }

    private func presentedSheetDidDismiss() {
        let dismissedSheet = lastPresentedSheet
        lastPresentedSheet = nil
        if dismissedSheet == .popup {
            runtime.cancelPopupDialogs()
            Task { await refreshCookieSummary() }
        }

        guard popupPresentationQueued, !runtime.popupWebViews.isEmpty else {
            popupPresentationQueued = false
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard presentedSheet == nil, !runtime.popupWebViews.isEmpty else { return }
            guard runtime.browserDialog == nil else {
                popupPresentationQueued = true
                return
            }
            popupPresentationQueued = false
            presentedSheet = .popup
        }
    }

    private func dismissAddressBarKeyboard() {
        isAddressBarFocused = false
    }

    private var webViewTakeoverPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: isAgentControlActive ? "cursorarrow.click.2" : "hand.tap")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AmberTheme.accentAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text(isAgentControlActive ? "Agent 正在控制此页面" : "接管页面后可操作")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text("当前仅可查看，点击、输入和登录需要先接管。")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                takeUserControl()
            } label: {
                Text("接管")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("接管 WebMount 页面并开始操作")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.accentAmber.opacity(0.35), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var browserDialogOverlay: some View {
        if let dialog = runtime.browserDialog, canUserMutate {
            WebMountBrowserDialogOverlay(dialog: dialog) { response in
                runtime.resolveBrowserDialog(response, dialogID: dialog.id)
            }
            .id(dialog.id)
        }
    }

    private func closePopupSheet() {
        guard canUserMutate else {
            presentedSheet = nil
            return
        }
        if let popup = activePopup {
            runtime.closePopup(popup)
            runtime.browserNotice = nil
        }
        if runtime.popupWebViews.isEmpty {
            presentedSheet = nil
        }
    }

    private var bridgeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "页面内容")
            AmberFormGroup {
                HStack {
                    Picker("页面内容", selection: $selectedResultTab) {
                        ForEach(WebMountResultTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(AmberTheme.foreground)
                    Spacer(minLength: 8)
                    Menu {
                        bridgeActionButtons
                    } label: {
                        Label("读取页面", systemImage: "arrow.down.doc")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .disabled(!canReadPage)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                WebMountDivider()

                if let contentHandoff, selectedResultTab == .text {
                    WebMountHandoffActions(
                        handoff: contentHandoff,
                        onChat: {
                            IOSWebMountContentHandoffStore.shared.prepareChat(contentHandoff)
                            router.navigate(to: .chat)
                        },
                        onDeepRead: {
                            IOSWebMountContentHandoffStore.shared.prepareDeepRead(contentHandoff)
                            router.navigate(to: .board)
                        }
                    )
                    WebMountDivider()
                }
                if selectedResultTab == .text {
                    Text(selectedResultText)
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    WebMountCodeBlock(text: selectedResultText)
                }
                WebMountDivider()
                DisclosureGroup("读取指定元素") {
                    HStack(spacing: 8) {
                        TextField("选择器", text: $getSelector)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
                            .autocorrectionDisabled()
                            .disabled(!canReadPage)
                        Button("读取") { Task { await getElement() } }
                            .buttonStyle(.glass)
                            .frame(minHeight: 44)
                            .disabled(!canReadPage)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if !getText.isEmpty {
                    WebMountDivider()
                    WebMountCodeBlock(text: getText)
                }
            }
        }
    }

    private var cookieSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "登录状态")
            AmberFormGroup {
                WebMountInfoRow(
                    title: "Cookie",
                    subtitle: cookieSubtitle,
                    systemImage: "circle.grid.cross",
                    tint: AmberTheme.accentAmber,
                    trailing: cookieSummary.map { "\($0.cookieCount)" } ?? "..."
                )
                WebMountDivider()
                cookieActionButtons
                WebMountDivider()
                Button(role: .destructive) {
                    Task { await clearSession() }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("清除本站登录状态")
                        Spacer()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(!canUserMutate)
                .opacity(canUserMutate ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var cookieActionButtons: some View {
        Button {
            Task { await openSite() }
        } label: {
            Label("打开网页登录", systemImage: "person.badge.key")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .disabled(!canUserMutate)
        WebMountDivider()
        Button {
            Task { await refreshCookieSummary() }
        } label: {
            Label("刷新登录状态", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                controlOwnerDetails
                controlOwnerAction
            }
            VStack(alignment: .leading, spacing: 8) {
                controlOwnerDetails
                HStack {
                    Spacer(minLength: 0)
                    controlOwnerAction
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var controlOwnerDetails: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: controlOwnerImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(controlOwnerTint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(controlOwnerTitle)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(controlOwnerSubtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var controlOwnerAction: some View {
        if sessionRecord != nil, sessionRecord?.controlOwner != .user {
            Button("接管") { takeUserControl() }
                .buttonStyle(.glassProminent)
                .frame(minHeight: 44)
                .accessibilityLabel("接管 WebMount 页面")
        } else if sessionRecord?.controlOwner == .user {
            let hasActiveAgent = sessionRecord?.ownerRunId?.nilIfBlank != nil
            Button(hasActiveAgent ? "恢复自动" : "释放控制") { handBackToAgent() }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
                .accessibilityLabel(hasActiveAgent ? "恢复 Agent 自动浏览" : "释放 WebMount 页面控制权")
        }
    }

    private var statusText: String {
        if !hasBoundSession || sessionRecord == nil {
            return "会话已失效"
        }
        if sessionRecord?.needsReopen == true {
            return "需要重新打开"
        }
        switch runtime.snapshot.status {
        case .idle: return "待打开"
        case .loading: return "正在加载"
        case .ready: return "已就绪"
        case .failed: return "加载失败"
        }
    }

    private var statusSubtitle: String {
        if !hasBoundSession || sessionRecord == nil {
            return "目标 session 不存在或已过期"
        }
        if sessionRecord?.needsReopen == true {
            return sessionRecord?.redactedURL.nilIfBlank ?? "旧页面不会自动恢复"
        }
        return runtime.snapshot.currentURL ?? runtime.snapshot.requestedURL ?? resolvedSite.homepageURL
    }

    private var cookieSubtitle: String {
        guard let cookieSummary else { return "正在读取 Cookie 摘要" }
        let names = cookieSummary.cookieNames.isEmpty ? "无" : cookieSummary.cookieNames.joined(separator: ", ")
        let login = cookieSummary.hasLoginCookie.map { $0 ? "已检测到登录 Cookie" : "未检测到登录 Cookie" } ?? "登录状态未知"
        return "\(login) · \(names)"
    }

    private var selectedResultText: String {
        switch selectedResultTab {
        case .text:
            return extractText.nilIfBlank ?? "尚未提取正文。"
        case .links:
            return linksText.nilIfBlank ?? "尚未读取链接。"
        case .interactive:
            return interactiveText.nilIfBlank ?? "尚未观察可交互元素。"
        case .visual:
            return visualSnapshotText.nilIfBlank ?? "尚未读取视觉快照。"
        case .debug:
            return debugJSONText.nilIfBlank ?? bridgeState.nilIfBlank ?? "尚无调试 JSON。"
        }
    }

    private var loginBadgeText: String {
        guard let cookieSummary else { return "登录状态未知" }
        if cookieSummary.hasLoginCookie == true { return "已登录" }
        if cookieSummary.hasLoginCookie == false { return "未登录" }
        return "登录状态未知"
    }

    private var controlOwnerBadgeText: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent 控制"
        case .user: "用户控制"
        default: "控制权空闲"
        }
    }

    private var controlOwnerTitle: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent 控制中"
        case .user: "你正在控制"
        default: "控制权空闲"
        }
    }

    private var controlOwnerSubtitle: String {
        if !hasBoundSession || sessionRecord == nil {
            return "当前 session 已失效，请返回站点列表重新打开。"
        }
        switch sessionRecord?.controlOwner {
        case .agent:
            return "页面仍可观察；打开、导航和网页交互需先接管。"
        case .user:
            if sessionRecord?.ownerRunId?.nilIfBlank != nil {
                return "完成登录、验证码、CAPTCHA 或支付敏感步骤后点“恢复自动”；Amber 不会自动夺回控制。"
            }
            return "你可以操作页面；当前没有活动 Agent 任务。"
        default:
            return "没有活动控制方。"
        }
    }

    private var controlOwnerImage: String {
        switch sessionRecord?.controlOwner {
        case .agent: "cursorarrow"
        case .user: "person.crop.circle"
        default: "lock.open"
        }
    }

    private var controlOwnerTint: Color {
        switch sessionRecord?.controlOwner {
        case .agent: AmberTheme.accentIndigo
        case .user: AmberTheme.accentGreen
        default: AmberTheme.muted2
        }
    }

    private var workspaceControlOwnerLabel: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent"
        case .user: "用户"
        default: "空闲"
        }
    }

    private var controlActionTitle: String {
        guard canUserMutate else { return "接管页面" }
        return sessionRecord?.ownerRunId?.nilIfBlank == nil ? "释放控制权" : "恢复 Agent 自动浏览"
    }

    private var workspaceControlAccessibilityLabel: String {
        guard sessionRecord?.controlOwner == .user else { return "接管 WebMount 页面" }
        return sessionRecord?.ownerRunId?.nilIfBlank == nil
            ? "释放 WebMount 页面控制权"
            : "恢复 Agent 自动浏览"
    }

    private func openSite() async {
        guard canUserMutate else {
            if isAgentControlActive {
                banner = "Agent 正在控制此页面，请先接管。"
            }
            return
        }
        guard !isLoading else { return }
        if isUnlistedWatchSession {
            await openTypedURL()
            return
        }
        dismissAddressBarKeyboard()
        observationRequestID = nil
        runtime.browserNotice = nil
        isLoading = true
        let snapshot = await controller.openForUser(site: resolvedSite, sessionId: runtime.snapshot.sessionId)
        isLoading = false
        openURLText = snapshot.currentURL ?? snapshot.requestedURL ?? resolvedSite.homepageURL
        if let error = snapshot.error?.nilIfBlank {
            banner = IOSWebMountRedactor.redactedText(error)
        } else {
            banner = nil
        }
    }

    private func openTypedURL() async {
        guard canUserMutate else {
            banner = "Agent 正在控制此页面，请先接管。"
            return
        }
        guard !isLoading else { return }
        dismissAddressBarKeyboard()
        observationRequestID = nil
        runtime.browserNotice = nil
        isLoading = true
        let snapshot = await controller.openForUser(
            site: resolvedSite,
            sessionId: runtime.snapshot.sessionId,
            url: openURLText
        )
        isLoading = false
        if let error = snapshot.error?.nilIfBlank {
            banner = IOSWebMountRedactor.redactedText(error)
        } else {
            openURLText = snapshot.currentURL ?? snapshot.requestedURL ?? openURLText
            banner = nil
        }
    }

    private func reloadCurrentPage() {
        guard !isLoading else { return }
        observationRequestID = nil
        runtime.browserNotice = nil
        let snapshot = controller.reloadForUser(sessionId: runtime.snapshot.sessionId)
        banner = snapshot.error.map(IOSWebMountRedactor.redactedText)?.nilIfBlank
    }

    private func refreshCookieSummary() async {
        cookieSummary = await controller.cookieStore.summary(for: resolvedSite)
    }

    private func readState() async {
        do {
            let state = try await runtime.state()
            bridgeState = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(state))
            debugJSONText = bridgeState
            selectedResultTab = .debug
        } catch {
            bridgeState = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = bridgeState
            selectedResultTab = .debug
        }
    }

    private func extractReadable() async {
        do {
            let result = try await runtime.extract(mode: "readable", maxChars: 4_000, maxLinks: 12)
            let redacted = IOSWebMountRedactor.redactedJSONObject(result)
            extractText = IOSWebMountRedactor.redactedText((result["text"] as? String) ?? "")
            linksText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["links"] ?? []))
            debugJSONText = IOSWebMountController.json(redacted)
            contentHandoff = IOSWebMountContentHandoff.from(
                site: resolvedSite,
                snapshot: runtime.snapshot,
                extraction: result
            )
            IOSWebMountActivityStore.shared.recordExtraction(
                siteName: resolvedSite.displayName,
                title: result["title"] as? String,
                characterCount: extractText.count,
                linkCount: (result["links"] as? [[String: Any]])?.count ?? 0
            )
            selectedResultTab = .text
        } catch {
            extractText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = extractText
            contentHandoff = nil
            selectedResultTab = .debug
        }
    }

    private func observePage() async {
        let requestID = UUID()
        observationRequestID = requestID
        defer {
            if observationRequestID == requestID { observationRequestID = nil }
        }
        do {
            let observation = try await runtime.observe(maxChars: 2_000, maxLinks: 20)
            guard observationRequestID == requestID else { return }
            let visibleText = IOSWebMountRedactor.redactedText((observation["visible_text"] as? String) ?? "")
            extractText = visibleText
            linksText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["links"] ?? []))
            interactiveText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["interactive_elements"] ?? []))
            visualSnapshotText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["visual_candidates"] ?? []))
            debugJSONText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation))
            if let page = observation["page"] as? [String: Any] {
                bridgeState = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(page))
            }
            let extraction: [String: Any] = [
                "text": visibleText,
                "links": observation["links"] ?? [],
                "title": (observation["page"] as? [String: Any])?["title"] as? String ?? "",
                "url": (observation["page"] as? [String: Any])?["url"] as? String ?? ""
            ]
            contentHandoff = IOSWebMountContentHandoff.from(
                site: resolvedSite,
                snapshot: runtime.snapshot,
                extraction: extraction
            )
            IOSWebMountActivityStore.shared.recordExtraction(
                siteName: resolvedSite.displayName,
                title: extraction["title"] as? String,
                characterCount: visibleText.count,
                linkCount: (observation["links"] as? [[String: Any]])?.count ?? 0
            )
            controller.sessionStore.touch(sessionId: runtime.snapshot.sessionId, makeCurrent: false)
            selectedResultTab = .interactive
        } catch {
            guard observationRequestID == requestID else { return }
            debugJSONText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            selectedResultTab = .debug
        }
    }

    private func visualSnapshot() async {
        do {
            let result = try await runtime.extract(mode: "snapshot", maxChars: 4_000, maxLinks: 24)
            visualSnapshotText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["visual_candidates"] ?? result))
            interactiveText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["interactive_nodes"] ?? []))
            debugJSONText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result))
            selectedResultTab = .visual
        } catch {
            visualSnapshotText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = visualSnapshotText
            selectedResultTab = .debug
        }
    }

    private func getElement() async {
        do {
            let result = try await runtime.get(
                selector: getSelector,
                target: nil,
                kind: "text",
                attrName: nil,
                maxChars: 4_000
            )
            getText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result))
            debugJSONText = getText
        } catch {
            getText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = getText
        }
    }

    private func clearSession() async {
        guard canUserMutate else {
            banner = "Agent 正在控制此页面，请先接管。"
            return
        }
        let result = await controller.cookieStore.clearSession(for: resolvedSite)
        banner = "已清除 \(result.deletedCookieCount) 个 Cookie 和 \(result.clearedWebsiteDataRecords) 条网页数据。"
        await refreshCookieSummary()
    }

    private func takeUserControl() {
        do {
            _ = try controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
            runtime.browserNotice = nil
            banner = "已接管此站点页面。"
        } catch {
            banner = "接管失败：\(IOSWebMountRedactor.redactedText(error.localizedDescription))"
        }
    }

    private func handBackToAgent() {
        let resumesAutomation = sessionRecord?.ownerRunId?.nilIfBlank != nil
        do {
            _ = try controller.sessionStore.handBackToAgent(sessionId: runtime.snapshot.sessionId)
            banner = resumesAutomation ? "已恢复 Agent 自动浏览。" : "已释放此站点页面控制权。"
        } catch {
            let action = resumesAutomation ? "恢复自动" : "释放"
            banner = "\(action)失败：\(IOSWebMountRedactor.redactedText(error.localizedDescription))"
        }
    }

}

#Preview("WebMount Site") {
    NavigationStack {
        WebMountSiteView(site: .init(siteId: "hackernews", name: "Hacker News", host: "news.ycombinator.com"))
    }
}
