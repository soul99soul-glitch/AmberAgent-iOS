import SwiftUI
import UniformTypeIdentifiers

struct IOSPhoneControlSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var controller = IOSPhoneControlController.shared
    @State private var bundleIDDraft = ""
    @State private var durationSeconds = 180
    @State private var presentsPairingImporter = false
    @State private var operation: Operation?
    @State private var errorMessage: String?

    private enum Operation: Equatable {
        case importing, pairing, removing, stopping
    }

    private enum PairingImportError: LocalizedError {
        case tooLarge

        var errorDescription: String? { "配对文件不能超过 1 MB。" }
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let errorMessage {
                    footer(errorMessage, color: AmberTheme.accentRed)
                        .accessibilityIdentifier("phoneControlError")
                }
                ScrollView {
                    VStack(spacing: 0) {
                        enableSection
                        preparationSection
                        appsSection
                        authorizationSection
                        statusSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task { await controller.refreshPreparation() }
        .fileImporter(
            isPresented: $presentsPairingImporter,
            allowedContentTypes: [.propertyList, .xml],
            allowsMultipleSelection: false,
            onCompletion: importPairing
        )
    }

    private var isWorking: Bool { operation != nil || controller.isUpdatingPairing }
    private var canEditPreparation: Bool { !isWorking && !controller.isOccupied }
    private var canAuthorize: Bool {
        controller.enabled && controller.hasPreparedPairing
            && !controller.selectedBundleIDs.isEmpty
            && !controller.isOccupied && !controller.hasPendingAuthorization && !isWorking
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回运行环境", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text("手机自主控制")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var enableSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "控制开关")
            AmberFormGroup {
                Toggle(isOn: Binding(
                    get: { controller.enabled },
                    set: { controller.enabled = $0 }
                )) {
                    rowText("允许手机控制工具", detail: "默认关闭，每次任务还需单独授权")
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .disabled(isWorking)
                .accessibilityIdentifier("phoneControlEnabled")
            }
            footer("优先读取界面元素树；树无法说明界面时才使用截图。界面文字和截图可能发送到你配置的模型。")
        }
    }

    private var preparationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "准备")
            AmberFormGroup {
                HStack(spacing: 12) {
                    Image(systemName: controller.hasPreparedPairing ? "key.fill" : "key")
                        .font(.system(size: 20))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    rowText(
                        controller.hasPreparedPairing ? "已保存配对文件" : "尚未导入配对文件",
                        detail: "凭据仅保存在这部手机的钥匙串"
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                rowDivider
                if controller.isPreparingPairing {
                    actionRow("取消配对", systemImage: "xmark.circle", color: AmberTheme.muted) {
                        controller.cancelPreparation()
                    }
                    .accessibilityIdentifier("phoneControlCancelPairing")
                } else {
                    actionRow("在本机建立配对", systemImage: "link") {
                        operation = .pairing
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            do { try await controller.preparePairing() }
                            catch is CancellationError { }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(!canEditPreparation || controller.hasPreparedPairing)
                    .accessibilityIdentifier("phoneControlPreparePairing")
                }
                rowDivider
                actionRow(
                    controller.hasPreparedPairing ? "更换配对文件" : "导入配对文件",
                    systemImage: "square.and.arrow.down",
                    busy: operation == .importing
                ) {
                    errorMessage = nil
                    presentsPairingImporter = true
                }
                .disabled(!canEditPreparation)
                .accessibilityIdentifier("phoneControlImportPairing")

                if controller.hasPreparedPairing {
                    rowDivider
                    actionRow("移除配对文件", systemImage: "trash", color: AmberTheme.accentRed,
                              busy: operation == .removing) {
                        operation = .removing
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            do { try await controller.removePairing() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(!canEditPreparation)
                }
            }
            footer("首次配对需要系统允许开发连接，也可导入已准备的 RemotePairing plist。控制 runner 仍须开发签名并安装，配对不会代替安装。当前同机启动与后台持续控制仍待验证。")
        }
    }

    private var appsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "允许控制的 App")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App 的 Bundle ID")
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    TextField("如 com.apple.mobilenotes", text: $bundleIDDraft)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(AmberTheme.foreground)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .frame(minHeight: 44)
                        .submitLabel(.done)
                        .onSubmit { addBundleID() }
                        .accessibilityIdentifier("phoneControlBundleID")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .disabled(!canEditPreparation)
                rowDivider
                actionRow("添加 App", systemImage: "plus") { addBundleID() }
                    .disabled(!canEditPreparation || bundleIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("phoneControlAddApp")

                ForEach(controller.selectedBundleIDs.sorted(), id: \.self) { bundleID in
                    rowDivider
                    HStack(spacing: 8) {
                        Text(verbatim: bundleID)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            controller.selectedBundleIDs.remove(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 20))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AmberTheme.accentRed)
                        .disabled(!canEditPreparation)
                        .accessibilityLabel("移除 \(bundleID)")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                }
            }
            footer(controller.selectedBundleIDs.isEmpty
                ? "先添加至少一个 App。任务只获得授权时选中的应用范围。"
                : "仅允许列表中的 App；修改列表会撤销待用授权，开始任务后不能扩大范围。")
        }
    }

    private var authorizationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: controller.isOccupied ? "当前任务授权" : "下一次任务")
            AmberFormGroup {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Text("单次控制时长")
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("单次控制时长", selection: Binding(
                        get: {
                            if controller.hasPendingAuthorization || controller.isOccupied {
                                return controller.authorizedDurationSeconds ?? durationSeconds
                            }
                            return durationSeconds
                        },
                        set: { durationSeconds = $0 }
                    )) {
                        Text("1 分钟").tag(60)
                        Text("3 分钟").tag(180)
                        Text("5 分钟").tag(300)
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("phoneControlDuration")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .disabled(isWorking || controller.isOccupied || controller.hasPendingAuthorization)
                rowDivider
                if controller.isOccupied {
                    rowText("仅本次任务", detail: controller.authorizationTargetSummary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else if controller.hasPendingAuthorization {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已授权下一次任务")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("请在 5 分钟内返回聊天并发送目标。这份授权只供下一次由你发起的任务使用。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("phoneControlPendingAuthorization")
                    rowDivider
                    actionRow("取消这次授权", systemImage: "xmark.circle", color: AmberTheme.muted) {
                        controller.discardPendingAuthorization()
                    }
                    .disabled(isWorking)
                } else {
                    actionRow("授权下一次聊天任务", systemImage: "checkmark.shield") {
                        errorMessage = nil
                        do { try controller.authorizeNextTask(durationSeconds: durationSeconds) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(!canAuthorize)
                    .accessibilityIdentifier("phoneControlAuthorize")
                }
            }
            footer(controller.isOccupied
                ? "任务结束、取消或超时后，控制权限随之收回。下一次任务需要重新授权，系统也可能提前结束后台运行。"
                : "授权不会启动控制。任务结束、取消或超时后，控制权限随之收回。系统可能提前结束后台运行。")
        }
    }

    private var statusSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "当前状态")
            AmberFormGroup {
                Text(verbatim: controller.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("phoneControlStatus")
                if controller.isOccupied {
                    rowDivider
                    actionRow("停止当前控制任务", systemImage: "stop.circle", color: AmberTheme.accentRed,
                              busy: operation == .stopping) {
                        operation = .stopping
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            await controller.stopCurrent()
                        }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("phoneControlStop")
                }
            }
        }
    }

    private var rowDivider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 14)
    }

    private func rowText(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
            Text(verbatim: detail).font(.caption).foregroundStyle(AmberTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ title: String, systemImage: String, color: Color = AmberTheme.accent,
                           busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().frame(width: 24, height: 24)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20))
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footer(_ text: String, color: Color = AmberTheme.muted) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }

    private func addBundleID() {
        guard canEditPreparation else { return }
        let bundleID = bundleIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        guard IOSPhoneControlController.validBundleID(bundleID) else {
            errorMessage = "请输入完整的 App Bundle ID，例如 com.apple.mobilenotes。"
            return
        }
        controller.selectedBundleIDs.insert(bundleID)
        bundleIDDraft = ""
        errorMessage = nil
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError { return }
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard canEditPreparation else {
                errorMessage = "当前正在处理配对或控制任务，请稍后再导入。"
                return
            }
            operation = .importing
            errorMessage = nil
            Task {
                defer { operation = nil }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Self.readPairingFile(url)
                    }.value
                    try await controller.importPairing(data)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private nonisolated static func readPairingFile(_ url: URL) throws -> Data {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw PairingImportError.tooLarge }
        return data
    }
}
