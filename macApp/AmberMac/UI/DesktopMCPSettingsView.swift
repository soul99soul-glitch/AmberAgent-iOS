import AppKit
import SwiftUI

struct DesktopMCPSettingsView: View {
    @Bindable var manager: DesktopMCPManager
    @State private var editingServer: DesktopMCPServer?
    @State private var deletingServer: DesktopMCPServer?
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MCP 服务").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("导入 JSON…") { importing = true }
                Button("添加服务", systemImage: "plus") { editingServer = DesktopMCPServer() }
            }
            Text("连接后发现真实工具与参数格式。工具调用会遵循审批规则；只读提示不代表自动授权。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            if let loadError = manager.store.loadError {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(manager.store.servers) { server in serverCard(server) }
                }
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if manager.store.servers.isEmpty {
                    ContentUnavailableView("还没有 MCP 服务", systemImage: "network", description: Text("添加 HTTP、SSE 或本地 stdio 服务，或导入 mcpServers JSON 配置。"))
                }
            }
        }
        .padding(20)
        .sheet(item: $editingServer) { server in
            DesktopMCPServerEditor(server: server) { value in
                try manager.store.upsert(value)
                manager.disconnect(id: value.id)
            }
        }
        .sheet(isPresented: $importing) {
            DesktopMCPJSONImporter { try manager.store.importJSON($0) }
        }
        .confirmationDialog("移除这个 MCP 服务？", isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } }), titleVisibility: .visible) {
            Button("移除服务", role: .destructive) {
                if let server = deletingServer {
                    manager.disconnect(id: server.id)
                    perform { try manager.store.remove(id: server.id) }
                }
                deletingServer = nil
            }
            Button("取消", role: .cancel) { deletingServer = nil }
        } message: { Text("连接将断开，此服务的配置与钥匙串凭据会移除。") }
        .alert("MCP 操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func serverCard(_ server: DesktopMCPServer) -> some View {
        let status = manager.statusByServer[server.id] ?? .idle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(server.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(server.transport == .stdio ? server.command : server.url)
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1).truncationMode(.middle)
                    Text(server.enabled ? status.title : "已停用").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer(minLength: 10)
                Toggle("启用服务", isOn: Binding(get: { server.enabled }, set: { enabled in
                    perform { try manager.store.setEnabled(id: server.id, enabled: enabled) }
                    if !enabled { manager.disconnect(id: server.id) }
                })).labelsHidden().help("启用 \(server.name)")
                if status == .connecting || status == .connected || status == .reconnecting {
                    Button(status == .connected ? "断开" : "取消连接") { manager.disconnect(id: server.id) }
                } else {
                    Button("连接并发现工具") { connect(server.id) }.disabled(!server.enabled)
                }
                Menu {
                    Button("编辑服务", systemImage: "pencil") { editingServer = server }
                    Button("移除服务", systemImage: "trash", role: .destructive) { deletingServer = server }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("MCP 服务操作 \(server.name)")
            }
            if case .error(let reason) = status {
                Text(reason).font(.system(size: 12)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true)
            }
            if !server.tools.isEmpty {
                DisclosureGroup("\(server.tools.filter(\.enabled).count) / \(server.tools.count) 个工具已启用") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(server.tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(tool.name).font(.system(.callout, design: .monospaced).weight(.medium))
                                    Spacer()
                                    Toggle("启用工具", isOn: Binding(get: { tool.enabled }, set: { enabled in
                                        perform { try manager.store.setToolEnabled(serverID: server.id, toolName: tool.name, enabled: enabled) }
                                    })).labelsHidden().help("启用工具 \(tool.name)")
                                }
                                if let description = tool.description, !description.isEmpty {
                                    Text(description).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                                }
                                if let schema = tool.inputSchema {
                                    DisclosureGroup("参数格式") {
                                        Text(schema).font(.system(size: 12, design: .monospaced))
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                                    }.font(.system(size: 12))
                                }
                            }
                        }
                    }.padding(.top, 8)
                }.disabled(!server.enabled)
            }
        }
        .padding(16).background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 10))
    }

    private func connect(_ id: UUID) {
        Task {
            do { try await manager.connect(id: id) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
}

private struct DesktopMCPServerEditor: View {
    let original: DesktopMCPServer
    let onSave: (DesktopMCPServer) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DesktopMCPServer
    @State private var headers: String
    @State private var environment: String
    @State private var arguments: String
    @State private var error: String?
    @State private var confirmsDiscard = false
    private let originalHeaders: String
    private let originalEnvironment: String
    private let originalArguments: String

    init(server: DesktopMCPServer, onSave: @escaping (DesktopMCPServer) throws -> Void) {
        original = server; self.onSave = onSave
        let headers = Self.json(server.headers), environment = Self.json(server.environment), arguments = Self.json(server.arguments)
        originalHeaders = headers; originalEnvironment = environment; originalArguments = arguments
        _draft = State(initialValue: server); _headers = State(initialValue: headers)
        _environment = State(initialValue: environment); _arguments = State(initialValue: arguments)
    }

    private var changed: Bool {
        draft != original || headers != originalHeaders || environment != originalEnvironment || arguments != originalArguments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original.name.isEmpty ? "添加 MCP 服务" : "编辑 MCP 服务").font(DesktopTheme.serif(size: 20, weight: .semibold))
            Form {
                TextField("名称", text: $draft.name)
                Picker("传输", selection: $draft.transport) {
                    Text("HTTP").tag(DesktopMCPServer.Transport.streamableHTTP)
                    Text("SSE").tag(DesktopMCPServer.Transport.sse)
                    Text("stdio").tag(DesktopMCPServer.Transport.stdio)
                }.pickerStyle(.segmented)
                if draft.transport == .stdio {
                    TextField("可执行文件或命令", text: $draft.command)
                    jsonEditor("启动参数（JSON 字符串数组）", text: $arguments)
                    jsonEditor("环境变量（JSON 对象）", text: $environment)
                } else {
                    TextField("服务地址", text: $draft.url)
                    jsonEditor("请求头（JSON 对象）", text: $headers)
                }
                Toggle("启用此服务", isOn: $draft.enabled)
                Text("请求头和环境变量保存在系统钥匙串中。保存不会自动连接或执行工具。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { if changed { confirmsDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(22).frame(width: 660, height: 590)
        .interactiveDismissDisabled(changed)
        .confirmationDialog("放弃尚未保存的配置？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    private func jsonEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .frame(height: 76).padding(5)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesktopTheme.hairlineStrong))
                .accessibilityLabel(title)
        }
    }

    private func save() {
        do {
            var value = draft
            if value.transport == .stdio {
                do { value.environment = try JSONDecoder().decode([String: String].self, from: Data(environment.utf8)) }
                catch { throw DesktopRuntimeError.message("环境变量需要是键值均为字符串的 JSON 对象。") }
                do { value.arguments = try JSONDecoder().decode([String].self, from: Data(arguments.utf8)) }
                catch { throw DesktopRuntimeError.message("启动参数需要是 JSON 字符串数组。") }
            } else {
                do { value.headers = try JSONDecoder().decode([String: String].self, from: Data(headers.utf8)) }
                catch { throw DesktopRuntimeError.message("请求头需要是键值均为字符串的 JSON 对象。") }
            }
            try onSave(value); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
}

private struct DesktopMCPJSONImporter: View {
    let onImport: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var json = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("导入 MCP 配置").font(DesktopTheme.serif(size: 20, weight: .semibold))
                Spacer()
                Button("选择 JSON 文件…") { chooseFile() }
            }
            Text("粘贴包含 mcpServers 的 JSON。已有同名服务会提示处理，不会覆盖。")
                .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
            TextEditor(text: $json).font(.system(size: 12, design: .monospaced)).padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                .accessibilityLabel("MCP JSON 配置")
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") { do { try onImport(json); dismiss() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(.borderedProminent).disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 680, height: 520)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do { json = try String(contentsOf: url, encoding: .utf8) } catch { self.error = "无法读取 JSON 文件，请检查文件格式与权限。" }
    }
}
