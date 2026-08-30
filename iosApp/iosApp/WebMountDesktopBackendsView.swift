import Foundation
import SwiftUI

@MainActor
struct WebMountDesktopBackendsView: View {
    @Environment(\.dismiss) private var dismiss

    let controller: IOSWebMountController
    let configStore: IOSMcpConfigStore
    let focusedSessionId: String?

    @State private var mcpManager: IOSMcpManager
    @State private var selectedBackend: IOSWebMountBackendKind = .local
    @State private var selectedServerName = ""
    @State private var sessions: [IOSWebMountSessionRecord] = []
    @State private var closingSessionIDs = Set<String>()
    @State private var reconnectingSessionIDs = Set<String>()
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(
        controller: IOSWebMountController = .shared,
        configStore: IOSMcpConfigStore = .shared,
        focusedSessionId: String? = nil
    ) {
        self.controller = controller
        self.configStore = configStore
        self.focusedSessionId = focusedSessionId
        let focusedSession = focusedSessionId.flatMap { controller.sessionStore.record(sessionId: $0) }
        self._selectedBackend = State(initialValue: focusedSession?.backend ?? .local)
        self._selectedServerName = State(initialValue: focusedSession?.mcpServerName ?? "")
        self._mcpManager = State(
            initialValue: IOSMcpManager(serverProvider: { configStore.servers })
        )
    }

    private var eligibleServers: [IOSMcpServerConfig] {
        configStore.servers.filter { server in
            guard server.enabled else { return false }
            guard case .streamableHTTP = server else { return false }
            return (try? IOSWebMountDesktopEndpointPolicy().validate(server)) != nil
        }
    }

    private var selectedServer: IOSMcpServerConfig? {
        eligibleServers.first { $0.name == selectedServerName }
    }

    private var remoteSessions: [IOSWebMountSessionRecord] {
        sessions
            .filter { $0.backend != .local }
            .sorted { lhs, rhs in
                if lhs.id == focusedSessionId { return true }
                if rhs.id == focusedSessionId { return false }
                if lhs.lastActivityMillis != rhs.lastActivityMillis {
                    return lhs.lastActivityMillis > rhs.lastActivityMillis
                }
                return lhs.id < rhs.id
            }
    }

    private var canCreate: Bool {
        !isCreating && (selectedBackend == .local || selectedServer != nil)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        if focusedSessionId != nil {
                            focusedTaskSection
                        } else {
                            introSection
                            backendSection

                            if selectedBackend != .local {
                                serverSection
                            }

                            createSection
                            capabilitySection
                            remoteSessionSection
                            managementNote
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            refreshSessions()
            if let focusedSessionId,
               let focusedSession = sessions.first(where: { $0.id == focusedSessionId }) {
                selectedBackend = focusedSession.backend
                selectedServerName = focusedSession.mcpServerName ?? ""
            }
            await refreshMCP()
            ensureServerSelection()
        }
        .onChange(of: configStore.servers) { _, _ in
            ensureServerSelection()
            Task { await refreshMCP() }
        }
        .onChange(of: controller.sessionStore.recordsRevision) { _, _ in
            refreshSessions()
        }
        .onDisappear {
            mcpManager.disconnectAll()
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(
                systemImage: "chevron.left",
                accessibilityLabel: "返回 WebMount",
                size: 44,
                symbolSize: 20
            ) {
                dismiss()
            }

            Spacer()

            Text(focusedSessionId == nil ? "桌面后端" : "浏览任务")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("为每个 WebMount session 显式选择运行后端。")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)

            Text("本地 WKWebView 是默认的 App 内隐私与登录入口。Moli、Playwright MCP、Steel 只使用已配置的 MCP 服务器，不会在这里复制 endpoint、请求头或 token。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var backendSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "运行后端")
            AmberFormGroup {
                ForEach(Array(IOSWebMountBackendKind.allCases.enumerated()), id: \.element.id) { index, backend in
                    Button {
                        selectedBackend = backend
                        if backend != .local {
                            ensureServerSelection()
                        }
                        errorMessage = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: webMountDesktopBackendIcon(backend))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(AmberTheme.accent)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(webMountDesktopBackendTitle(backend))
                                    .font(.body)
                                    .foregroundStyle(AmberTheme.foreground)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(webMountDesktopBackendSubtitle(backend))
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if selectedBackend == backend {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AmberTheme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 52)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                    .accessibilityLabel("后端 \(webMountDesktopBackendTitle(backend))")
                    .accessibilityValue(selectedBackend == backend ? "已选择" : "未选择")

                    if index < IOSWebMountBackendKind.allCases.count - 1 {
                        Divider()
                            .padding(.leading, 54)
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "MCP 服务器")
            AmberFormGroup {
                if eligibleServers.isEmpty {
                    WebMountDesktopInfoRow(
                        systemImage: "exclamationmark.triangle",
                        tint: AmberTheme.accentAmber,
                        title: "没有符合条件的服务器",
                        subtitle: "仅显示已启用、Streamable HTTP 且通过 HTTPS/远端网关策略的 MCP 服务器。请先在 MCP 服务器设置页完成配置。"
                    )
                } else {
                    ForEach(Array(eligibleServers.enumerated()), id: \.element.id) { index, server in
                        Button {
                            selectedServerName = server.name
                            errorMessage = nil
                        } label: {
                            WebMountDesktopServerRow(
                                server: server,
                                status: mcpManager.statusByServer[server.name] ?? .idle,
                                configuredBackendToolCount: server.tools.filter {
                                    $0.enabled && IOSWebMountDesktopBackendAdapter.safeBrowserToolNames.contains($0.name)
                                }.count,
                                isSelected: selectedServerName == server.name
                            )
                        }
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                        .accessibilityLabel("MCP 服务器 \(server.name)")
                        .accessibilityValue(selectedServerName == server.name ? "已选择" : "未选择")

                        if index < eligibleServers.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }

            Text("这里显示 MCP 通用连接状态与当前后端工具配置；创建 session 后，实际能力由 WebMount 独立连接并验证。")
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    private var createSection: some View {
        VStack(spacing: 10) {
            AmberSectionLabel(text: "创建会话")

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    createSession()
                } label: {
                    HStack(spacing: 8) {
                        if isCreating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isCreating
                             ? IOSAppLocalization.string("创建中…", defaultValue: "创建中…")
                             : createButtonTitle)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 14)
                }
                .foregroundStyle(.white)
                .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                .amberProminentGlass(cornerRadius: 12, tint: AmberTheme.accent)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.55)

                if selectedBackend != .local, selectedServer == nil {
                    Text("选择一个通过安全策略的 MCP 服务器后才能创建远程 session。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage {
                    WebMountDesktopMessage(text: errorMessage, tint: AmberTheme.accentAmber)
                }

                if let successMessage {
                    WebMountDesktopMessage(text: successMessage, tint: AmberTheme.accent)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var capabilitySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "能力对比")
            AmberFormGroup {
                WebMountDesktopCapabilityRow(
                    systemImage: "lock.shield",
                    tint: AmberTheme.accent,
                    title: webMountDesktopBackendTitle(.local),
                    subtitle: IOSAppLocalization.string(
                        "App 内登录、隐私 Cookie、页面截图",
                        defaultValue: "App 内登录、隐私 Cookie、页面截图"
                    )
                )

                if selectedBackend != .local {
                    Divider()
                        .padding(.leading, 54)

                    WebMountDesktopCapabilityRow(
                        systemImage: webMountDesktopBackendIcon(selectedBackend),
                        tint: AmberTheme.accent,
                        title: "\(webMountDesktopBackendTitle(selectedBackend)) · \(selectedServer?.name ?? IOSAppLocalization.string("未选择服务器", defaultValue: "未选择服务器"))",
                        subtitle: selectedBackendCapabilitySubtitle
                    )
                }
            }
        }
    }

    private var remoteSessionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "远程会话")
            AmberFormGroup {
                if remoteSessions.isEmpty {
                    WebMountDesktopInfoRow(
                        systemImage: "rectangle.on.rectangle.slash",
                        tint: AmberTheme.muted2,
                        title: IOSAppLocalization.string("暂无桌面 session", defaultValue: "暂无桌面 session"),
                        subtitle: IOSAppLocalization.string(
                            "创建远程后端 session 后，这里显示状态、重新连接与关闭操作，不会打开本地 WKWebView。",
                            defaultValue: "创建远程后端 session 后，这里显示状态、重新连接与关闭操作，不会打开本地 WKWebView。"
                        )
                    )
                } else {
                    ForEach(Array(remoteSessions.enumerated()), id: \.element.id) { index, session in
                        WebMountDesktopSessionRow(
                            session: session,
                            isFocused: session.id == focusedSessionId,
                            desktopStatus: controller.desktopStatus(sessionId: session.id),
                            capabilities: controller.desktopCapabilities(sessionId: session.id),
                            configurationMatches: desktopConfigurationMatches(session),
                            isClosing: closingSessionIDs.contains(session.id),
                            isReconnecting: reconnectingSessionIDs.contains(session.id),
                            onReconnect: { reconnectSession(session) },
                            onClose: { closeSession(session) }
                        )

                        if index < remoteSessions.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var focusedTaskSection: some View {
        if let focusedSessionId,
           let session = remoteSessions.first(where: { $0.id == focusedSessionId }) {
            WebMountFocusedRemoteTaskView(
                session: session,
                desktopStatus: controller.desktopStatus(sessionId: session.id),
                configurationMatches: desktopConfigurationMatches(session),
                isClosing: closingSessionIDs.contains(session.id),
                isReconnecting: reconnectingSessionIDs.contains(session.id),
                onReconnect: { reconnectSession(session) },
                onHandBack: { handBackSession(session) },
                onClose: { closeSession(session) }
            )

            if let errorMessage {
                WebMountDesktopMessage(text: errorMessage, tint: AmberTheme.statusAmber)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            if let successMessage {
                WebMountDesktopMessage(text: successMessage, tint: AmberTheme.foreground2)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("任务已结束")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text("这个浏览器会话已关闭或不再可用。")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)
        }
    }

    private var managementNote: some View {
        Text("远程网关必须使用 HTTPS；本页只显示 scheme、host 和 port。Token 与请求头继续由 MCP 服务器设置页保管，不在这里重复保存。")
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 14)
    }

    private var createButtonTitle: String {
        if selectedBackend == .local {
            return IOSAppLocalization.string(
                "创建本地 WKWebView 会话",
                defaultValue: "创建本地 WKWebView 会话"
            )
        }
        return IOSAppLocalization.formatted(
            "创建 %@ 会话",
            defaultValue: "创建 %@ 会话",
            arguments: [webMountDesktopBackendTitle(selectedBackend)]
        )
    }

    private var selectedBackendCapabilitySubtitle: String {
        guard let selectedServer else {
            return IOSAppLocalization.string(
                "未选择符合安全策略的 MCP 服务器；远程能力不可用。",
                defaultValue: "未选择符合安全策略的 MCP 服务器；远程能力不可用。"
            )
        }
        let status = mcpManager.statusByServer[selectedServer.name] ?? .idle
        let configuredToolCount = selectedServer.tools.filter {
            $0.enabled && IOSWebMountDesktopBackendAdapter.safeBrowserToolNames.contains($0.name)
        }.count
        let capabilities = configuredToolCount == 0
            ? IOSAppLocalization.string("未配置已启用的后端工具", defaultValue: "未配置已启用的后端工具")
            : IOSAppLocalization.formatted(
                "已配置 %lld 个后端工具",
                defaultValue: "已配置 %lld 个后端工具",
                arguments: [Int64(configuredToolCount)]
            )
        return IOSAppLocalization.formatted(
            "MCP %@ · %@；创建 session 后验证实际能力",
            defaultValue: "MCP %@ · %@；创建 session 后验证实际能力",
            arguments: [status.title, capabilities]
        )
    }

    private func ensureServerSelection() {
        guard selectedBackend != .local else {
            selectedServerName = ""
            return
        }
        if !eligibleServers.contains(where: { $0.name == selectedServerName }) {
            selectedServerName = eligibleServers.first?.name ?? ""
        }
    }

    private func refreshMCP() async {
        mcpManager.refreshServers()
        for server in eligibleServers {
            await mcpManager.sync(serverName: server.name)
        }
    }

    private func refreshSessions() {
        sessions = controller.sessionStore.records.filter { $0.backend != .local }
    }

    private func desktopConfigurationMatches(_ session: IOSWebMountSessionRecord) -> Bool {
        guard let serverName = session.mcpServerName,
              let config = configStore.servers.first(where: { $0.name == serverName }) else {
            return false
        }
        return controller.desktopBackend.allowsCurrentConfiguration(
            config,
            toolName: "wm_open",
            logicalSessionId: session.id
        )
    }

    private func createSession() {
        guard canCreate else { return }

        var arguments: [String: Any] = [
            "backend": selectedBackend.rawValue,
            "mcp_server_name": selectedServerName
        ]
        if selectedBackend != .local, let selectedServer {
            arguments["mcp_server_name"] = selectedServer.name
        }

        isCreating = true
        errorMessage = nil
        successMessage = nil
        Task {
            let result = await controller.execute(
                toolName: "wm_tab_new",
                input: IOSWebMountController.json(arguments),
                isUserInitiated: true
            )
            isCreating = false
            handleCreateResult(result)
        }
    }

    private func closeSession(_ session: IOSWebMountSessionRecord) {
        guard closingSessionIDs.insert(session.id).inserted else { return }
        errorMessage = nil
        successMessage = nil
        Task {
            let result = await controller.execute(
                toolName: "wm_tab_close",
                input: IOSWebMountController.json(["session_id": session.id]),
                isUserInitiated: true
            )
            closingSessionIDs.remove(session.id)
            handleCloseResult(result, session: session)
        }
    }

    private func reconnectSession(_ session: IOSWebMountSessionRecord) {
        guard reconnectingSessionIDs.insert(session.id).inserted else { return }
        errorMessage = nil
        successMessage = nil
        Task {
            let result = await controller.reconnectDesktopSession(sessionId: session.id)
            reconnectingSessionIDs.remove(session.id)
            handleReconnectResult(result, session: session)
        }
    }

    private func handBackSession(_ session: IOSWebMountSessionRecord) {
        do {
            _ = try controller.sessionStore.handBackToAgent(sessionId: session.id)
            successMessage = session.ownerRunId?.nilIfBlank == nil
                ? "已释放浏览器控制权。"
                : "已将浏览器控制权交还 Agent。"
            errorMessage = nil
            refreshSessions()
        } catch {
            successMessage = nil
            errorMessage = "交还失败：\(IOSWebMountRedactor.redactedText(error.localizedDescription))"
        }
    }

    private func handleCreateResult(_ rawResult: String) {
        guard let object = parseObject(rawResult) else {
            errorMessage = "创建失败：服务返回了无法识别的结果。"
            return
        }
        guard object["ok"] as? Bool == true else {
            errorMessage = structuredError(from: object, action: "创建 session")
            refreshSessions()
            return
        }

        guard let session = object["session"] as? [String: Any],
              session["backend"] as? String == selectedBackend.rawValue else {
            errorMessage = "创建未确认：返回结果没有确认所选后端，未打开或回退到本地 WebView。"
            refreshSessions()
            return
        }
        if selectedBackend != .local,
           session["mcp_server_name"] as? String != selectedServerName {
            errorMessage = "创建未确认：返回结果没有确认所选 MCP 服务器。"
            refreshSessions()
            return
        }

        successMessage = "已创建 \(webMountDesktopBackendTitle(selectedBackend)) session。"
        refreshSessions()
    }

    private func handleCloseResult(_ rawResult: String, session: IOSWebMountSessionRecord) {
        guard let object = parseObject(rawResult) else {
            errorMessage = "关闭失败：服务返回了无法识别的结果。"
            return
        }
        guard object["ok"] as? Bool == true else {
            errorMessage = structuredError(from: object, action: "关闭 session")
            refreshSessions()
            return
        }
        successMessage = "已关闭 \(webMountDesktopBackendTitle(session.backend)) session。"
        refreshSessions()
    }

    private func handleReconnectResult(_ rawResult: String, session: IOSWebMountSessionRecord) {
        guard let object = parseObject(rawResult) else {
            errorMessage = "重新连接失败：服务返回了无法识别的结果。"
            return
        }
        guard object["ok"] as? Bool == true else {
            errorMessage = structuredError(from: object, action: "重新连接 session")
            refreshSessions()
            return
        }
        guard object["session_id"] as? String == session.id,
              object["backend"] as? String == session.backend.rawValue else {
            errorMessage = "重新连接未确认：返回结果与当前 session 不匹配。"
            refreshSessions()
            return
        }
        successMessage = "已重新连接 \(webMountDesktopBackendTitle(session.backend)) session。"
        refreshSessions()
    }

    private func structuredError(from object: [String: Any], action: String) -> String {
        let code = (object["error_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "未提供原因"
        let prefix = code.flatMap { $0.isEmpty ? nil : "[\($0)] " } ?? ""
        return "\(action)失败：\(prefix)\(IOSWebMountRedactor.redactedText(reason))"
    }

    private func parseObject(_ rawResult: String) -> [String: Any]? {
        guard let data = rawResult.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private struct WebMountDesktopServerRow: View {
    let server: IOSMcpServerConfig
    let status: IOSMcpConnectionStatus
    let configuredBackendToolCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name.isEmpty
                     ? IOSAppLocalization.string("未命名服务器", defaultValue: "未命名服务器")
                     : server.name)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(webMountDesktopEndpointSummary(server.url)) · \(server.transportTitle)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(IOSAppLocalization.formatted(
                    "MCP %@ · 已配置 %lld 个后端工具",
                    defaultValue: "MCP %@ · 已配置 %lld 个后端工具",
                    arguments: [status.title, Int64(configuredBackendToolCount)]
                ))
                    .font(.caption2)
                    .foregroundStyle(status == .connected ? AmberTheme.accent : AmberTheme.muted2)
                    .lineLimit(2)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 68)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct WebMountDesktopCapabilityRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 58, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct WebMountDesktopInfoRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 64, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct WebMountDesktopMessage: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WebMountFocusedRemoteTaskView: View {
    let session: IOSWebMountSessionRecord
    let desktopStatus: IOSWebMountDesktopBackendStatus
    let configurationMatches: Bool
    let isClosing: Bool
    let isReconnecting: Bool
    let onReconnect: () -> Void
    let onHandBack: () -> Void
    let onClose: () -> Void

    private var displayedStatus: IOSWebMountDesktopBackendStatus {
        if session.needsReopen || session.status == "needs_reopen" || !configurationMatches {
            return .needsReopen
        }
        return desktopStatus
    }

    private var shouldOfferReconnect: Bool {
        switch displayedStatus {
        case .needsReopen, .failed:
            return true
        default:
            return false
        }
    }

    private var title: String {
        session.siteName?.nilIfBlank
            ?? session.title.nilIfBlank
            ?? IOSAppLocalization.string("浏览器任务", defaultValue: "浏览器任务")
    }

    private var pageSummary: String? {
        guard let rawURL = session.redactedURL.nilIfBlank,
              let components = URLComponents(string: rawURL),
              let host = components.host?.nilIfBlank else {
            return session.redactedURL.nilIfBlank
        }
        let path = components.percentEncodedPath
        return path.isEmpty || path == "/" ? host : host + path
    }

    private var backendSummary: String {
        let backend = webMountDesktopBackendTitle(session.backend)
        guard let server = session.mcpServerName?.nilIfBlank else { return backend }
        return "\(backend) · \(server)"
    }

    private var statusTint: Color {
        switch displayedStatus {
        case .needsReopen, .failed:
            AmberTheme.statusAmber
        case .connected, .connecting:
            AmberTheme.accent
        case .idle, .closed:
            AmberTheme.muted2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "globe")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(width: 42, height: 42)
                        .background(AmberTheme.surface2, in: Circle())

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)

                        if let pageSummary {
                            Text(pageSummary)
                                .font(.subheadline)
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 9) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 8, height: 8)
                    Text(displayedStatus.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("状态，\(displayedStatus.title)")

                Divider()
                    .overlay(AmberTheme.borderSoft)

                Label(backendSummary, systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 26)

            if shouldOfferReconnect {
                Button(action: onReconnect) {
                    HStack(spacing: 8) {
                        if isReconnecting {
                            ProgressView()
                                .tint(AmberTheme.accent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isReconnecting ? "正在重新连接…" : "重新连接")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AmberTheme.accentTint, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isReconnecting || isClosing)
                .padding(.horizontal, 24)
            }

            if session.controlOwner == .user {
                Button(action: onHandBack) {
                    Text(session.ownerRunId?.nilIfBlank == nil ? "释放控制" : "交还 Agent")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isClosing || isReconnecting)
                .padding(.horizontal, 24)
            }

            Button(action: onClose) {
                Text(isClosing ? "正在关闭…" : "关闭会话")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isClosing || isReconnecting)
            .padding(.horizontal, 24)
            .padding(.top, shouldOfferReconnect ? 8 : 0)
        }
    }
}

private struct WebMountDesktopSessionRow: View {
    let session: IOSWebMountSessionRecord
    let isFocused: Bool
    let desktopStatus: IOSWebMountDesktopBackendStatus
    let capabilities: [IOSWebMountDesktopCapability]
    let configurationMatches: Bool
    let isClosing: Bool
    let isReconnecting: Bool
    let onReconnect: () -> Void
    let onClose: () -> Void

    private var displayedDesktopStatus: IOSWebMountDesktopBackendStatus {
        if session.needsReopen || session.status == "needs_reopen" {
            return .needsReopen
        }
        if !configurationMatches {
            return .needsReopen
        }
        return desktopStatus
    }

    private var shouldOfferReconnect: Bool {
        switch displayedDesktopStatus {
        case .needsReopen, .failed:
            return true
        default:
            return false
        }
    }

    private var capabilitySummary: String {
        guard configurationMatches else {
            return IOSAppLocalization.string("未确认", defaultValue: "未确认")
        }
        let names = capabilities.filter(\.available).map(\.amberToolName)
        guard !names.isEmpty else {
            return IOSAppLocalization.string("未确认", defaultValue: "未确认")
        }
        return IOSAppLocalization.formatted(
            "已确认 %lld 项",
            defaultValue: "已确认 %lld 项",
            arguments: [Int64(names.count)]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(webMountDesktopBackendTitle(session.backend)) · \(session.mcpServerName ?? IOSAppLocalization.string("未绑定服务器", defaultValue: "未绑定服务器"))")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)

                    if isFocused {
                        Label("当前任务", systemImage: "scope")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                    }

                    Text("状态：\(displayedDesktopStatus.title)")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("控制：\(webMountDesktopControlTitle(session.controlOwner)) · 能力：\(capabilitySummary)")
                        .font(.caption2)
                        .foregroundStyle(displayedDesktopStatus == .needsReopen ? AmberTheme.accentAmber : AmberTheme.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(session.siteName?.nilIfBlank
                 ?? session.title.nilIfBlank
                 ?? IOSAppLocalization.string("未命名页面", defaultValue: "未命名页面"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)

            if let redactedURL = session.redactedURL.nilIfBlank {
                Text(redactedURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("session_id：\(session.id)")
                .font(.caption2.monospaced())
                .foregroundStyle(AmberTheme.muted2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    reconnectButton
                    Spacer(minLength: 0)
                    closeButton
                }
                VStack(alignment: .trailing, spacing: 8) {
                    reconnectButton
                    closeButton
                }
            }
        }
        .frame(minHeight: 82, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isFocused ? AmberTheme.accentTint : Color.clear)
        .accessibilityValue(isFocused ? "当前任务" : "")
    }

    @ViewBuilder
    private var reconnectButton: some View {
        if shouldOfferReconnect {
            Button {
                onReconnect()
            } label: {
                HStack(spacing: 6) {
                    if isReconnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AmberTheme.accent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isReconnecting ? "重新连接中…" : "重新连接")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AmberTheme.accentTint, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isReconnecting || isClosing)
            .accessibilityLabel("重新连接远程 session")
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AmberTheme.accentRed)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭远程 session")
        .disabled(isClosing || isReconnecting)
        .opacity(isClosing ? 0.5 : 1)
    }
}

private func webMountDesktopBackendTitle(_ backend: IOSWebMountBackendKind) -> String {
    backend.title
}

private func webMountDesktopBackendSubtitle(_ backend: IOSWebMountBackendKind) -> String {
    switch backend {
    case .local:
        IOSAppLocalization.string(
            "App 内页面、隐私登录与本地 Cookie",
            defaultValue: "App 内页面、隐私登录与本地 Cookie"
        )
    case .moli, .playwright_mcp, .steel:
        IOSAppLocalization.string(
            "需要符合策略的 MCP 服务器；能力以实际发现工具为准",
            defaultValue: "需要符合策略的 MCP 服务器；能力以实际发现工具为准"
        )
    }
}

private func webMountDesktopBackendIcon(_ backend: IOSWebMountBackendKind) -> String {
    switch backend {
    case .local: "iphone"
    case .moli, .playwright_mcp, .steel: "macwindow.on.rectangle"
    }
}

private func webMountDesktopEndpointSummary(_ rawURL: String) -> String {
    guard let components = URLComponents(string: rawURL),
          let scheme = components.scheme?.nilIfBlank,
          let host = components.host?.nilIfBlank else {
        return IOSAppLocalization.string("地址无效", defaultValue: "地址无效")
    }
    var result = "\(scheme.lowercased())://\(host)"
    if let port = components.port {
        result += ":\(port)"
    }
    return result
}

private func webMountDesktopControlTitle(_ owner: IOSWebMountControlOwner) -> String {
    switch owner {
    case .none:
        IOSAppLocalization.string("空闲", defaultValue: "空闲")
    case .agent: "Agent"
    case .user:
        IOSAppLocalization.string("用户", defaultValue: "用户")
    }
}
