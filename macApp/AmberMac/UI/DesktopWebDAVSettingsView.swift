import SwiftUI

struct DesktopWebDAVSettingsView: View {
    @Bindable var workspace: DesktopWorkspace
    @State private var draft = DesktopWebDAVConfiguration()
    @State private var password = ""
    @State private var savedPassword = ""
    @State private var snapshotPassword = ""
    @State private var credentialLoadFailed = false
    @State private var didLoad = false
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var failure: String?
    @State private var deleting: IOSWebDAVResource?
    @State private var preview: RestorePreview?
    @State private var editingConfiguration = false

    private var manager: DesktopWebDAVManager { workspace.webDAV }
    private var dirty: Bool { draft != manager.configuration || password != savedPassword }
    private var busy: Bool { working || manager.isBusy || workspace.isManagingBackup }
    private var canUseRemote: Bool { !busy && !dirty && !credentialLoadFailed }

    private struct RestorePreview: Identifiable {
        let id = UUID()
        let fileName: String
        let data: Data
        let password: String
        let createdAt: Date
        let conversationCount: Int
        let providerCount: Int
        let memoryCount: Int
    }

    var body: some View {
        Form {
            configuration
            operations
            snapshots
            if let failure = failure ?? manager.error {
                Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            }
            if let message {
                Section { Label(message, systemImage: "info.circle").foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .task {
            guard !didLoad else { return }
            didLoad = true
            loadConfiguration()
        }
        .onChange(of: draft) { message = nil }
        .onChange(of: password) {
            message = nil
            if credentialLoadFailed && !password.isEmpty { credentialLoadFailed = false; failure = nil }
        }
        .onDisappear {
            operation?.cancel(); manager.cancel()
            password = ""; savedPassword = ""; snapshotPassword = ""; preview = nil
        }
        .confirmationDialog("移除这个远端快照？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("移除远端快照", role: .destructive) {
                guard let resource = deleting else { return }
                deleting = nil
                perform { try await manager.delete(resource) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("此操作会删除服务器上的快照，本机数据会保留。") }
        .sheet(item: $preview) { item in restorePreview(item) }
        .sheet(isPresented: $editingConfiguration) { configurationEditor }
    }

    private var configuration: some View {
        Section("WebDAV 位置") {
            LabeledContent("服务地址", value: manager.configuration.baseURL.isEmpty ? "尚未配置" : manager.configuration.baseURL)
            LabeledContent("目录", value: manager.configuration.path)
            LabeledContent("用户名", value: manager.configuration.username.isEmpty ? "未填写" : manager.configuration.username)
            Text("账号密码单独保存在本机钥匙串。带认证的连接必须使用 HTTPS；只有点击操作时才会联网。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            Button("编辑同步位置…") { loadConfiguration(); editingConfiguration = true }.disabled(busy)
        }
    }

    private var configurationEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WebDAV 位置").font(DesktopTheme.serif(size: 20, weight: .semibold))
            Form {
                TextField("服务地址", text: $draft.baseURL, prompt: Text("https://example.com/dav"))
                TextField("目录", text: $draft.path)
                TextField("用户名", text: $draft.username)
                SecureField("登录密码", text: $password)
            }
            Text("登录密码保存在本机钥匙串；备份加密密码只用于本次操作。取消会放弃本次位置修改。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if credentialLoadFailed { Button("重新读取钥匙串") { loadConfiguration() } }
                Spacer()
                Button("取消") { editingConfiguration = false; loadConfiguration() }.keyboardShortcut(.cancelAction)
                Button("保存位置") {
                    do {
                        try manager.save(configuration: draft, password: password)
                        draft = manager.configuration; savedPassword = password
                        failure = nil; message = "WebDAV 位置已保存。"
                        editingConfiguration = false
                    } catch { failure = error.localizedDescription }
                }.buttonStyle(.desktopProminent).disabled(busy || credentialLoadFailed)
            }
        }.padding(24).frame(width: 560)
        .interactiveDismissDisabled(dirty)
    }

    private var operations: some View {
        Section("手动备份与恢复") {
            SecureField("备份加密密码", text: $snapshotPassword).disabled(busy)
            Text("上传必须填写备份密码；下载预览和恢复使用原密码。备份不包含钥匙串 API Key、登录凭证或 WebDAV 密码；自定义请求头和请求体作为模型配置随备份保存，请注意其中填写的敏感信息。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("测试连接") { perform { try await manager.testConnection() } }
                Button("刷新快照") { perform { try await manager.list() } }
                Button("上传本机快照", systemImage: "arrow.up.doc") {
                    let secret = snapshotPassword
                    perform {
                        guard !secret.isEmpty else { throw DesktopRuntimeError.message("请填写备份加密密码。") }
                        let data = try await workspace.makeBackupData(password: secret)
                        try Task.checkCancellation()
                        _ = try await manager.push(data: data)
                        message = "加密快照已上传，文件名独立保存，未覆盖已有快照。"
                    }
                }.disabled(snapshotPassword.isEmpty || workspace.isLoading || workspace.isGenerating)
            }.disabled(!canUseRemote)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(manager.status).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if busy { Button("取消") { operation?.cancel(); manager.cancel(); workspace.cancelBackup() }.buttonStyle(.borderless) }
            }
            if dirty { Text("保存位置后再测试、上传或刷新；下方快照属于已保存的位置。 ").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
        }
    }

    private var snapshots: some View {
        Section("远端快照（\(manager.snapshots.count)）") {
            if manager.snapshots.isEmpty {
                Text("刷新后可查看远端快照。下载会先校验并预览内容，确认后才导入副本。")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manager.snapshots, id: \.href) { resource in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "doc.zipper").foregroundStyle(DesktopTheme.inkTertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.fileName).lineLimit(1).help(resource.fileName)
                        HStack(spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: resource.sizeBytes, countStyle: .file))
                            if resource.modifiedAt > 0 { Text(Date(timeIntervalSince1970: Double(resource.modifiedAt) / 1000), format: .dateTime.year().month().day().hour().minute()) }
                        }.font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("下载预览") { downloadPreview(resource) }
                    Button { deleting = resource } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("移除远端快照").accessibilityLabel("移除 \(resource.fileName)")
                }.padding(.vertical, 4).disabled(!canUseRemote)
            }
        }
    }

    private func restorePreview(_ item: RestorePreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认恢复快照").font(DesktopTheme.serif(size: 20, weight: .semibold))
            Text(item.fileName).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(2).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("备份时间"); Text(item.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                GridRow { Text("会话"); Text("\(item.conversationCount) 个") }
                GridRow { Text("服务商配置"); Text("\(item.providerCount) 个") }
                GridRow { Text("记忆"); Text("\(item.memoryCount) 条") }
            }
            Text("将导入为副本，保留本机现有内容。模型配置不含钥匙串凭证，但可能包含自定义请求头和请求体中的敏感信息；恢复的技能与 SOUL 资料需要检查后启用。")
                .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { preview = nil }.keyboardShortcut(.cancelAction)
                Button("确认导入副本") {
                    preview = nil
                    perform {
                        guard let task = workspace.importBackup(data: item.data, password: item.password.isEmpty ? nil : item.password) else {
                            throw DesktopRuntimeError.message(workspace.backupErrorMessage ?? "当前无法开始恢复。")
                        }
                        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                        try Task.checkCancellation()
                        if let error = workspace.backupErrorMessage { throw DesktopRuntimeError.message(error) }
                        message = workspace.backupStatusMessage
                    }
                }.buttonStyle(.desktopProminent)
            }
        }.padding(24).frame(width: 520)
    }

    private func loadConfiguration() {
        draft = manager.configuration
        do {
            password = try manager.storedPassword(); savedPassword = password
            credentialLoadFailed = false; failure = nil
        } catch {
            password = ""; savedPassword = ""; credentialLoadFailed = true
            failure = "读取 WebDAV 密码失败，请解锁钥匙串后重试，或填写新密码后保存。"
        }
    }

    private func downloadPreview(_ resource: IOSWebDAVResource) {
        let secret = snapshotPassword
        perform {
            let data = try await manager.download(resource)
            let decoding = Task.detached { try DesktopBackup.decode(data, password: secret.isEmpty ? nil : secret) }
            let value = try await withTaskCancellationHandler { try await decoding.value } onCancel: { decoding.cancel() }
            try Task.checkCancellation()
            preview = RestorePreview(fileName: resource.fileName, data: data, password: secret,
                createdAt: value.createdAt, conversationCount: value.conversations.count,
                providerCount: value.providers.count, memoryCount: value.memories.count)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; failure = nil; message = nil
        operation = Task {
            defer { working = false; operation = nil }
            do { try await action() }
            catch is CancellationError { message = "操作已取消。上传可能已在远端完成，可刷新列表核对。" }
            catch { failure = error.localizedDescription }
        }
    }
}
