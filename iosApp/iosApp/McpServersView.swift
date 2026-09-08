import SwiftUI
import Shared

struct McpServersView: View {
    let sharedSettings: IOSSharedSettingsStore
    let configStore: IOSMcpConfigStore
    @State private var mcpManager: IOSMcpManager
    @State private var editingServer: IOSMcpServerConfig?
    @State private var editingTab: McpAddTab = .edit
    @State private var pendingDeleteServerName: String?

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss

    init(sharedSettings: IOSSharedSettingsStore, configStore: IOSMcpConfigStore) {
        self.sharedSettings = sharedSettings
        self.configStore = configStore
        self._mcpManager = State(initialValue: IOSMcpManager(sharedSettings: sharedSettings, configStore: configStore))
    }

    private var displayedServers: [IOSMcpServerConfig] {
        let localNames = Set(configStore.servers.map(\.name))
        let shared = sharedSettings.snapshot.mcpServers.compactMap(IOSMcpServerConfig.init)
            .filter { !localNames.contains($0.name) }
        return configStore.servers + shared
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    intro
                    localConfigSection
                    managementSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard sharedSettings.isCapabilityGateEnabled(.mcp) else { return }
            await mcpManager.syncAll()
        }
        .onChange(of: configStore.servers) { oldServers, newServers in
            guard sharedSettings.isCapabilityGateEnabled(.mcp) else { return }
            // Discovering or toggling a tool only changes the tools payload. It
            // must not recursively reconnect every server through this observer.
            guard connectionSnapshot(for: oldServers) != connectionSnapshot(for: newServers) else { return }
            Task { await mcpManager.syncAll() }
        }
        .sheet(item: $editingServer, onDismiss: { editingTab = .edit }) { server in
            McpAddView(
                configStore: configStore,
                editingServer: server,
                mcpManager: mcpManager,
                initialTab: editingTab,
                isReadOnly: !configStore.servers.contains { $0.name == server.name }
            )
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "删除 MCP 服务器？",
            isPresented: Binding(
                get: { pendingDeleteServerName != nil },
                set: { if !$0 { pendingDeleteServerName = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let name = pendingDeleteServerName {
                    configStore.remove(named: name)
                }
                pendingDeleteServerName = nil
            }
            Button("取消", role: .cancel) { pendingDeleteServerName = nil }
        } message: {
            Text("删除后需要重新添加才能使用。")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回技能", size: 44, symbolSize: 20) {
                    dismiss()
                }
            }
            .frame(width: 96, alignment: .leading)

            Text("MCP 服务器")
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                AmberGlassCircleButton(systemImage: "arrow.clockwise", accessibilityLabel: "刷新 MCP 工具", size: 44, symbolSize: 16) {
                    Task { await mcpManager.syncAll() }
                }
                Menu {
                    Button {
                        router.navigate(to: .mcpImport)
                    } label: {
                        Label("导入服务器", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        router.navigate(to: .mcpAdd)
                    } label: {
                        Label("手动添加", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .amberGlass(cornerRadius: 22)
                }
                .accessibilityLabel("添加服务器")
            }
            .frame(width: 96, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var intro: some View {
        Text("添加外部工具服务器，连接后聊天可以使用服务器提供的工具。")
            .font(.subheadline)
            .foregroundStyle(AmberTheme.muted)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 3)
    }

    private var localConfigSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "服务器")
            AmberFormGroup {
                if displayedServers.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 16))
                            .foregroundStyle(AmberTheme.muted2)
                        Text("还没有保存 MCP 服务器。可通过导入或手动添加。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(displayedServers.enumerated()), id: \.element.id) { index, server in
                        let isLocal = configStore.servers.contains { $0.name == server.name }
                        McpServerRow(
                            server: server,
                            status: connectionStatus(for: server),
                            toolCount: toolCount(for: server),
                            isEditable: isLocal,
                            onToggle: { enabled in
                                configStore.setEnabled(named: server.name, enabled: enabled)
                            },
                            onEdit: {
                                editingTab = isLocal ? .edit : .tools
                                editingServer = server
                            },
                            onOpenTools: {
                                editingTab = .tools
                                editingServer = server
                            },
                            onDelete: {
                                pendingDeleteServerName = server.name
                            }
                        )

                        if index < displayedServers.count - 1 {
                            McpDivider()
                        }
                    }
                }
            }
        }
    }

    private var managementSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "管理")
            AmberFormGroup {
                McpActionRow(
                    systemImage: "square.and.arrow.down",
                    iconColor: AmberTheme.accentCyan,
                    title: "导入服务器",
                    subtitle: "粘贴标准 mcpServers JSON，解析后保存到本机配置"
                ) {
                    router.navigate(to: .mcpImport)
                }

                McpDivider()

                McpActionRow(
                    systemImage: "plus",
                    iconColor: AmberTheme.accent,
                    title: "手动添加",
                    subtitle: "填写传输类型、服务器地址与请求头并保存"
                ) {
                    router.navigate(to: .mcpAdd)
                }
            }

            McpNote("导入和手动添加会保存到本机配置。")
        }
    }
    private func connectionStatus(for server: IOSMcpServerConfig) -> IOSMcpConnectionStatus {
        mcpManager.statusByServer[server.name] ?? .idle
    }

    private func toolCount(for server: IOSMcpServerConfig) -> Int {
        mcpManager.servers.first(where: { $0.name == server.name })?.tools.count ?? server.tools.count
    }

    private func connectionSnapshot(for servers: [IOSMcpServerConfig]) -> [McpConnectionSnapshot] {
        servers.map(McpConnectionSnapshot.init)
    }
}

struct McpImportView: View {
    let configStore: IOSMcpConfigStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isJSONEditorFocused: Bool
    @State private var saveError: String?

    @State private var jsonText = """
    {
      "mcpServers": {
        "context7": {
          "transport": "streamableHttp",
          "url": "https://mcp.context7.com/mcp"
        }
      }
    }
    """

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                McpDraftHeader(title: "导入服务器", doneTitle: "保存") {
                    do {
                        guard parsedImport.errors.isEmpty, !parsedImport.servers.isEmpty else { return }
                        try configStore.importServers(json: jsonText)
                        dismiss()
                    } catch {
                        saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }

                ScrollView {
                    VStack(spacing: 0) {
                        introSection
                        jsonSection
                        previewSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: jsonText) { _, _ in
            saveError = nil
        }
    }

    private var introSection: some View {
        VStack(spacing: 0) {
            AmberFormGroup {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentCyan)
                        .frame(width: 34, height: 34)
                        .background(AmberTheme.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("标准 mcpServers JSON")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)

                        Text("粘贴 Claude / Codex 常见的 mcpServers 配置。保存后会写入 iOS 本机 MCP 配置并在服务器列表页同步连接。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
            .padding(.top, 4)
        }
    }

    private var jsonSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "JSON")
            AmberFormGroup {
                TextEditor(text: $jsonText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .scrollContentBackground(.hidden)
                    .focused($isJSONEditorFocused)
                    .frame(minHeight: 220)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AmberTheme.surface2.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                McpDivider()

                Button(action: replaceWithClipboard) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AmberTheme.accent)

                        Text("从剪贴板替换")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)

                        Spacer()
                    }
                    .frame(minHeight: 48)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            McpValidationNote(text: validationText, isWarning: true)
        }
    }

    private var previewSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "文本预览")
            AmberFormGroup {
                McpPreviewRow(title: "根字段文本", value: jsonText.contains("\"mcpServers\"") ? "mcpServers" : "未检测到")
                McpDivider()
                McpPreviewRow(title: "解析条目数", value: "\(parsedImport.servers.count)")
                McpDivider()
                McpPreviewRow(title: "错误条目数", value: "\(parsedImport.errors.count)")
                ForEach(Array(parsedImport.errors.enumerated()), id: \.offset) { _, issue in
                    McpDivider()
                    McpPreviewRow(
                        title: issue.serverName.isEmpty ? "文档错误" : issue.serverName,
                        value: issue.message
                    )
                }
                McpDivider()
                McpPreviewRow(
                    title: "保存结果",
                    value: parsedImport.errors.isEmpty && !parsedImport.servers.isEmpty ? "可保存" : "不会写入配置"
                )
            }
        }
    }

    private var validationText: String {
        if let saveError {
            return saveError
        }

        if !jsonText.contains("\"mcpServers\"") {
            return "未检测到 mcpServers 文本；保存不会写入配置。"
        }

        if !parsedImport.errors.isEmpty {
            return parsedImport.errors.map { issue in
                issue.serverName.isEmpty ? issue.message : "\(issue.serverName)：\(issue.message)"
            }.joined(separator: "\n")
        }

        if parsedImport.servers.isEmpty {
            return "文本包含 mcpServers，但没有解析到服务器条目。"
        }

        return "解析到 \(parsedImport.servers.count) 个服务器；点击保存后写入本机配置。"
    }

    private var parsedImport: IOSMcpImportParseResult {
        configStore.parseImport(json: jsonText)
    }

    private func replaceWithClipboard() {
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            return
        }
        isJSONEditorFocused = false
        jsonText = clipboardText
    }
}

enum McpAddTab: String, CaseIterable, Identifiable {
    case edit
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "编辑"
        case .tools: "工具"
        }
    }
}

private struct McpConnectionSnapshot: Equatable {
    let name: String
    let url: String
    let transport: String
    let headers: [String: String]
    let enabled: Bool

    init(_ server: IOSMcpServerConfig) {
        name = server.name
        url = server.url
        transport = server.transportKey
        headers = server.headers
        enabled = server.enabled
    }
}

struct McpAddView: View {
    let configStore: IOSMcpConfigStore
    let editingServer: IOSMcpServerConfig?
    let mcpManager: IOSMcpManager?
    let isReadOnly: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: McpAddTab
    @State private var name: String
    @State private var transport: McpTransportOption
    @State private var serverURL: String
    @State private var enabled: Bool
    @State private var headers: [McpHeaderDraft]
    @State private var saveError: String?

    init(
        configStore: IOSMcpConfigStore,
        editingServer: IOSMcpServerConfig? = nil,
        mcpManager: IOSMcpManager? = nil,
        initialTab: McpAddTab = .edit,
        isReadOnly: Bool = false
    ) {
        self.configStore = configStore
        self.editingServer = editingServer
        self.mcpManager = mcpManager
        self.isReadOnly = isReadOnly
        self._selectedTab = State(initialValue: initialTab)
        self._name = State(initialValue: editingServer?.name ?? "context7")
        self._transport = State(initialValue: editingServer.map(McpTransportOption.init(server:)) ?? .streamableHTTP)
        self._serverURL = State(initialValue: editingServer?.url ?? "https://mcp.context7.com/mcp")
        self._enabled = State(initialValue: editingServer?.enabled ?? true)
        let headerDrafts = editingServer?.headers
            .sorted { $0.key < $1.key }
            .map { McpHeaderDraft(name: $0.key, value: $0.value) }
        self._headers = State(initialValue: headerDrafts ?? [.init(name: "X-Client", value: "AmberAgent")])
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                McpDraftHeader(title: isReadOnly ? (editingServer?.name ?? "服务器工具") : (editingServer == nil ? "手动添加" : "编辑服务器"), doneTitle: isReadOnly ? "完成" : "保存") {
                    guard !isReadOnly else { dismiss(); return }
                    guard let server = draftServer else {
                        saveError = saveValidationMessage
                        selectedTab = .edit
                        return
                    }
                    guard !configStore.servers.contains(where: {
                        $0.name == server.name && $0.name != editingServer?.name
                    }) else {
                        saveError = "已存在同名服务器，请更换名称。"
                        selectedTab = .edit
                        return
                    }
                    configStore.upsert(server, replacing: editingServer?.name)
                    dismiss()
                }

                if editingServer != nil && !isReadOnly {
                    Picker("MCP 编辑内容", selection: $selectedTab) {
                        ForEach(McpAddTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        if !isReadOnly && (editingServer == nil || selectedTab == .edit) {
                            connectionSection
                            headersSection
                        } else {
                            toolsSection
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: name) { _, _ in saveError = nil }
        .onChange(of: serverURL) { _, _ in saveError = nil }
    }

    private var connectionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "连接")
            AmberFormGroup {
                McpDraftToggleRow(
                    title: "启用服务器",
                    subtitle: "关闭后不会连接，也不会向聊天提供这个服务器的工具。",
                    isOn: enabled
                ) {
                    enabled.toggle()
                }
                McpDivider()
                McpDraftTextFieldRow(title: "名称", text: $name, placeholder: "例如 context7")
                McpDivider()
                Menu {
                    ForEach(McpTransportOption.allCases) { option in
                        Button(option.title) {
                            transport = option
                            serverURL = option.defaultURL
                        }
                    }
                } label: {
                    McpDraftPickerRow(title: "传输类型", value: transport.title)
                }
                McpDivider()
                McpDraftTextFieldRow(title: "服务器 URL", text: $serverURL, placeholder: transport.defaultURL, monospace: true)
            }

            if let saveError {
                McpValidationNote(text: saveError, isWarning: true)
            }

            McpNote("保存后会写入本机配置，并可在服务器列表页同步连接。")
        }
    }

    private var headersSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "请求头")
            AmberFormGroup {
                ForEach(headers.indices, id: \.self) { index in
                    McpHeaderDraftRow(header: $headers[index]) {
                        headers.remove(at: index)
                    }

                    if index < headers.count - 1 {
                        McpDivider()
                    }
                }

                if !headers.isEmpty {
                    McpDivider()
                }

                Button {
                    headers.append(.init(name: "", value: ""))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AmberTheme.accent)

                        Text("添加请求头")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)

                        Spacer()
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            McpValidationNote(text: headerValidationText, isWarning: hasHeaderWarnings)
        }
    }

    private var toolsSection: some View {
        let server = currentServer
        let status = currentStatus

        return VStack(spacing: 0) {
            AmberSectionLabel(text: "工具")
            AmberFormGroup {
                McpToolsConnectionRow(
                    enabled: server?.enabled ?? false,
                    status: status
                )

                if case .error(let message) = status, server?.enabled == true {
                    McpDivider()
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentRed)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                McpDivider()

                if let server, !server.tools.isEmpty {
                    ForEach(Array(server.tools.enumerated()), id: \.element.id) { index, tool in
                        McpToolToggleRow(
                            serverName: server.name,
                            tool: tool,
                            onToggle: { enabled in
                                configStore.setToolEnabled(
                                    serverName: server.name,
                                    toolName: tool.name,
                                    enabled: enabled
                                )
                                mcpManager?.refreshFromCurrentSettings()
                            }
                        )
                        .disabled(isReadOnly)

                        if index < server.tools.count - 1 {
                            McpDivider()
                        }
                    }
                } else {
                    McpEmptyToolsRow(message: emptyToolsMessage(for: server, status: status))
                }
            }

            McpNote(
                isReadOnly
                    ? "此服务器来自共享配置，请在配置来源修改。这里显示当前连接发现的工具。"
                    : (server?.enabled == false
                        ? "这里是已保存的工具选择，启用服务器后生效。"
                        : "工具开关会立即保存到当前服务器；重新连接时会保留你的选择。")
            )
        }
    }

    private var currentServer: IOSMcpServerConfig? {
        guard let editingServer else { return nil }
        return configStore.servers.first(where: { $0.name == editingServer.name })
            ?? mcpManager?.servers.first(where: { $0.name == editingServer.name })
            ?? editingServer
    }

    private var currentStatus: IOSMcpConnectionStatus {
        guard let editingServer else { return .idle }
        return mcpManager?.statusByServer[editingServer.name] ?? .idle
    }

    private var persistedTools: [IOSMcpTool] {
        guard let editingServer else { return [] }
        return configStore.servers.first(where: { $0.name == editingServer.name })?.tools
            ?? editingServer.tools
    }

    private func emptyToolsMessage(for server: IOSMcpServerConfig?, status: IOSMcpConnectionStatus) -> String {
        guard let server else {
            return "服务器已从配置中移除。"
        }
        guard server.enabled else {
            return "服务器已禁用，启用后才会连接并发现工具。"
        }
        switch status {
        case .connecting, .reconnecting:
            return "正在连接服务器并获取工具列表。"
        case .error:
            return "连接失败，暂时没有可用工具。请检查服务器地址和请求头。"
        case .idle:
            return "尚未连接服务器；返回列表页后可刷新连接。"
        case .connected:
            return "服务器已连接，但没有发现可用工具。"
        }
    }

    private var draftServer: IOSMcpServerConfig? {
        let trimmedName = name.trimmed
        let trimmedURL = serverURL.trimmed
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return nil }
        let headerMap = Dictionary(uniqueKeysWithValues: validHeaders.map { ($0.name.trimmed, $0.value.trimmed) })
        // Read the current persisted value so saving connection fields after
        // changing a tool toggle cannot restore the stale sheet snapshot.
        let preservedTools = persistedTools
        switch transport {
        case .streamableHTTP:
            return .streamableHTTP(name: trimmedName, url: trimmedURL, headers: headerMap, enabled: enabled, tools: preservedTools)
        case .sse:
            return .sse(name: trimmedName, url: trimmedURL, headers: headerMap, enabled: enabled, tools: preservedTools)
        }
    }

    private var saveValidationMessage: String {
        if name.trimmed.isEmpty && serverURL.trimmed.isEmpty {
            return "名称和服务器 URL 不能为空。"
        }
        if name.trimmed.isEmpty {
            return "名称不能为空。"
        }
        return "服务器 URL 不能为空。"
    }

    private var validHeaders: [McpHeaderDraft] {
        headers.filter { !$0.name.trimmed.isEmpty && !$0.value.trimmed.isEmpty }
    }

    private var hasHeaderWarnings: Bool {
        headers.contains { $0.name.trimmed.isEmpty || $0.value.trimmed.isEmpty }
    }

    private var headerValidationText: String {
        if hasHeaderWarnings {
            return "空名称或空值不会保存到请求头。"
        }
        return "\(validHeaders.count) 个请求头将随服务器配置保存。"
    }
}

private struct McpPillModel: Identifiable {
    let id = UUID()
    let text: String
    let kind: McpPillKind
}

private enum McpPillKind {
    case network
    case connected
    case idle

    var foreground: Color {
        switch self {
        case .network: AmberTheme.accentCyan
        case .connected: AmberTheme.accentGreen
        case .idle: AmberTheme.muted
        }
    }

    var background: Color {
        switch self {
        case .network: AmberTheme.accentCyan.opacity(0.12)
        case .connected: AmberTheme.accentGreen.opacity(0.12)
        case .idle: AmberTheme.surface2
        }
    }
}

private struct McpToolsConnectionRow: View {
    let enabled: Bool
    let status: IOSMcpConnectionStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 30, height: 30)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(enabled ? status.title : "已禁用")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusDetail: String {
        guard enabled else { return "启用服务器后才会连接并提供工具。" }
        switch status {
        case .connected:
            return "已连接，下面是这个服务器的工具。"
        case .connecting, .reconnecting:
            return "正在连接并获取工具列表。"
        case .error:
            return "服务器连接失败，工具暂不可用。"
        case .idle:
            return "尚未建立连接。"
        }
    }

    private var statusIcon: String {
        guard enabled else { return "pause.circle" }
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        guard enabled else { return AmberTheme.muted2 }
        switch status {
        case .connected: return AmberTheme.accentGreen
        case .connecting, .reconnecting: return AmberTheme.accentCyan
        case .error: return AmberTheme.accentRed
        case .idle: return AmberTheme.muted2
        }
    }
}

private struct McpEmptyToolsRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
                .frame(width: 30, height: 30)

            Text(message)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct McpServerRow: View {
    let server: IOSMcpServerConfig
    let status: IOSMcpConnectionStatus
    let toolCount: Int
    let isEditable: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onOpenTools: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("{ }")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(AmberTheme.accentCyan)
                .frame(width: 32, height: 32)
                .background(AmberTheme.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button(action: onEdit) {
                        Text(server.name.isEmpty ? "未命名" : server.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button(action: onOpenTools) {
                        HStack(spacing: 4) {
                            Text(displayStatus).foregroundStyle(statusColor)
                            Text("·").foregroundStyle(AmberTheme.muted2)
                            Text("\(toolCount) 个工具").foregroundStyle(AmberTheme.accent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AmberTheme.muted2)
                        }
                        .font(.caption2.weight(.medium))
                        .fixedSize()
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(displayStatus)，查看 \(toolCount) 个工具")
                }

                Button(action: onEdit) {
                    Text(server.url)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if case .error(let message) = status, server.enabled {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.accentRed)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isEditable {
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { value in
                        Task { @MainActor in onToggle(value) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(server.name.isEmpty ? "MCP 服务器" : server.name)
                .accessibilityValue(server.enabled ? "开启" : "关闭")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除 MCP 服务器")
            } else {
                Text("共享配置").font(.caption2).foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var displayStatus: String {
        server.enabled ? status.title : "已禁用"
    }

    private var statusColor: Color {
        guard server.enabled else { return AmberTheme.muted2 }
        switch status {
        case .connected:
            return AmberTheme.accentGreen
        case .error:
            return AmberTheme.accentRed
        case .connecting, .reconnecting:
            return AmberTheme.accentCyan
        case .idle:
            return AmberTheme.muted2
        }
    }
}

private struct McpToolToggleRow: View {
    let serverName: String
    let tool: IOSMcpTool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.enabled ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tool.enabled ? AmberTheme.accentGreen : AmberTheme.muted2)
                .frame(width: 30, height: 30)
                .background(
                    (tool.enabled ? AmberTheme.accentGreen : AmberTheme.surface2).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                if let description = tool.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }
                Text(serverName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { value in
                    Task { @MainActor in onToggle(value) }
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(tool.name)
                .accessibilityValue(tool.enabled ? "开启" : "关闭")
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct McpActionRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct McpSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AmberTheme.accent : AmberTheme.surface2)
            .frame(width: 48, height: 28)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .padding(2)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
    }
}

private struct McpDivider: View {
    var body: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
            .padding(.leading, 58)
    }
}

private struct McpNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }
}

private struct McpDraftHeader: View {
    let title: String
    let doneTitle: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回 MCP 服务器", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text(doneTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(height: 36)
                    .padding(.horizontal, 14)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .amberGlass(cornerRadius: AmberTheme.radiusPill)
            .accessibilityLabel(doneTitle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }
}

private enum McpTransportOption: String, CaseIterable, Identifiable {
    case streamableHTTP
    case sse

    var id: String { rawValue }

    init(server: IOSMcpServerConfig) {
        switch server {
        case .streamableHTTP:
            self = .streamableHTTP
        case .sse:
            self = .sse
        }
    }

    var title: String {
        switch self {
        case .streamableHTTP: "Streamable HTTP"
        case .sse: "SSE"
        }
    }

    var defaultURL: String {
        switch self {
        case .streamableHTTP: "https://mcp.context7.com/mcp"
        case .sse: "https://example.com/sse"
        }
    }
}

private struct McpHeaderDraft: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var value: String
}

private struct McpDraftTextFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var monospace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)

            TextField(placeholder, text: $text)
                .font(monospace ? .system(size: 14, weight: .regular, design: .monospaced) : .body)
                .foregroundStyle(AmberTheme.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 58)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }
}

private struct McpDraftPickerRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)

                Text(value)
                    .font(.body)
                    .foregroundStyle(AmberTheme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct McpDraftToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(disabled ? AmberTheme.muted : AmberTheme.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                McpSwitch(isOn: isOn)
                    .opacity(disabled ? 0.5 : 1)
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(disabled ? "不可用" : (isOn ? "开启" : "关闭"))
    }
}

private struct McpHeaderDraftRow: View {
    @Binding var header: McpHeaderDraft
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField("Header", text: $header.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除请求头")
            }

            TextField("Value", text: $header.value)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(AmberTheme.surface2.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct McpPreviewRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct McpValidationNote: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isWarning ? AmberTheme.accentAmber : AmberTheme.accentGreen)
                .padding(.top, 2)

            Text(text)
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 7)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
