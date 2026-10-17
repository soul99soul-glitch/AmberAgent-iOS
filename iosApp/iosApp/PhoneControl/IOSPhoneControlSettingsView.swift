import SwiftUI
import UniformTypeIdentifiers

struct IOSPhoneControlSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: IOSPhoneControlController
    @State private var serviceInspection = IOSPhoneControlServiceInspection()
    @State private var bundleIDDraft = ""
    @State private var presentsPairingImporter = false
    @State private var presentsAppPicker = false
    @State private var operation: Operation?
    @State private var errorMessage: String?
    @State private var advancedPreparationExpanded: Bool

    private enum Operation: Equatable {
        case preparingConnection, importing, pairing, removing, stopping, inspecting, checkingReadiness
    }

    init(controller: IOSPhoneControlController = .shared, advancedPreparationExpanded: Bool = false) {
        _controller = State(initialValue: controller)
        _advancedPreparationExpanded = State(initialValue: advancedPreparationExpanded)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        if let errorMessage {
                            footer(errorMessage, color: AmberTheme.accentRed)
                                .accessibilityIdentifier("phoneControlError")
                        }
                        enableSection
                        statusSection
                        savedTasksSection
                        appsSection
                        preparationSection
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.refreshPreparation() }
            }
        }
        .onDisappear {
            serviceInspection.cancel()
            if operation == .checkingReadiness { controller.cancelReadinessCheck() }
        }
        .sheet(isPresented: $presentsAppPicker) {
            IOSPhoneControlAppPicker(controller: controller)
        }
        .fileImporter(
            isPresented: $presentsPairingImporter,
            allowedContentTypes: [.propertyList, .xml],
            allowsMultipleSelection: false,
            onCompletion: importPairing
        )
    }

    private var isWorking: Bool {
        operation != nil || controller.isPreparingConnection
            || controller.isUpdatingPairing || controller.isLoadingApplications || controller.isCheckingReadiness
    }
    private var canEditPreparation: Bool { !isWorking && !controller.isOccupied }
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
                    rowText("允许手机控制工具", detail: "开启后持续有效，无需逐次授权")
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityIdentifier("phoneControlEnabled")

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)
                Toggle(isOn: Binding(
                    get: { IOSPhoneControlReturnPreference.enabled() },
                    set: { IOSPhoneControlReturnPreference.set($0) }
                )) {
                    rowText("完成后返回 Amber", detail: "任务结束时切回宿主 App；unknown 不抢前台")
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityIdentifier("phoneControlReturnAfterRun")
            }
            footer("优先读取界面元素树；树无法说明界面时才使用截图。界面文字和截图可能发送到你配置的模型。")
            footer("已确定的连续操作优先合并执行。使用默认思考设置时，手机任务执行阶段优先低档（模型支持时）；手动选择的档位保持不变。")
        }
    }

    private var savedTasksSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "常用任务")
            AmberFormGroup {
                NavigationLink(value: Route.phoneSavedTasks) {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 20))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        rowText("管理常用任务", detail: "保存目标和完成条件，下次直接运行")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phoneControlSavedTasks")
            }
        }
    }

    private var preparationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "准备")
            AmberFormGroup {
                Text(IOSAppLocalization.string("连接方式", defaultValue: "连接方式"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                connectionModeRow(.embedded, title: IOSAppLocalization.string("内置本地连接", defaultValue: "内置本地连接"))
                rowDivider
                connectionModeRow(.existingVPN, title: IOSAppLocalization.string("使用现有 VPN", defaultValue: "使用现有 VPN"))
                rowDivider
                HStack(spacing: 12) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 20))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    rowText(localConnectionStatus.title, detail: localConnectionStatus.detail)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phoneControlConnectionStatus")
                if controller.connectionMode == .embedded && (!controller.localTunnel.isPrepared || connectionFailed) {
                    rowDivider
                    actionRow(
                        controller.localTunnel.isPrepared ? "更新连接配置" : "准备本地连接",
                        systemImage: "plus.circle",
                        busy: controller.isPreparingConnection
                    ) {
                        operation = .preparingConnection
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            do { try await controller.prepareConnection() }
                            catch is CancellationError { }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(!canEditPreparation)
                    .accessibilityIdentifier("phoneControlPrepareConnection")
                }
            }
            footer(connectionPreparationFooter)
                .padding(.bottom, 12)
            AmberFormGroup {
                HStack(spacing: 12) {
                    Image(systemName: controller.hasPreparedPairing ? "key.fill" : "key")
                        .font(.system(size: 20))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 24, height: 24)
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
                    .disabled(!canEditPreparation || !controller.isConnectionPrepared || controller.hasPreparedPairing)
                    .accessibilityIdentifier("phoneControlPreparePairing")
                }
            }
            footer("首次配对需要系统允许开发连接。控制 runner 须单独签名安装；保存配置后，请使用上方的检查自动化确认实际连接和界面读取。")
            AmberFormGroup {
                actionRow("高级准备", systemImage: advancedPreparationExpanded ? "chevron.down" : "chevron.right",
                          color: AmberTheme.muted) {
                    advancedPreparationExpanded.toggle()
                }
                .accessibilityIdentifier("phoneControlAdvancedPreparation")
                .accessibilityValue(advancedPreparationExpanded ? "已展开" : "已折叠")
                if advancedPreparationExpanded {
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

                    rowDivider
                    actionRow("导入 USB 准备的配对材料", systemImage: "cable.connector", busy: operation == .importing) {
                        operation = .importing
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            do { try await controller.importUSBPreparedPairing(from: IOSPhoneControlCredentials.usbImportURL) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(!canEditPreparation)
                    .accessibilityIdentifier("phoneControlImportUSBPairing")

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
                    rowDivider
                    actionRow("核对本机开发服务", systemImage: "network") {
                        operation = .inspecting
                        Task { @MainActor in
                            await serviceInspection.inspectAndRecord(source: "settings")
                            operation = nil
                        }
                    }
                    .disabled(isWorking || controller.isOccupied)
                    .accessibilityIdentifier("phoneControlInspectService")
                }
            }
            .padding(.top, 12)
            if advancedPreparationExpanded {
                if controller.connectionMode == .existingVPN {
                    footer(IOSAppLocalization.string(
                        "现有 VPN 的本地回环需将 10.7.0.1 指向本机。",
                        defaultValue: "现有 VPN 的本地回环需将 10.7.0.1 指向本机。"
                    ))
                }
                if let result = serviceInspection.summary {
                    if result.services.isEmpty {
                        footer("未取得可解析的开发服务记录，服务身份仍未知；这不代表服务不存在。")
                    } else {
                        ForEach(Array(result.services.enumerated()), id: \.offset) { _, service in
                            footer("\(service.host):\(service.port) · \(service.addressFamilies.joined(separator: ", ")) · \(service.localAddressMatch == true ? "地址匹配本机" : "本机身份未确认")")
                        }
                    }
                }
            }
        }
    }

    private func connectionModeRow(_ mode: IOSPhoneControlConnectionMode, title: String) -> some View {
        let selected = controller.connectionMode == mode
        return Button {
            errorMessage = nil
            do { try controller.setConnectionMode(mode) }
            catch { errorMessage = error.localizedDescription }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canEditPreparation)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("phoneControlConnectionMode.\(mode.rawValue)")
    }

    private var connectionPreparationFooter: String {
        if controller.connectionMode == .existingVPN {
            return IOSAppLocalization.string(
                "请在现有代理中开启本地回环，并保持 VPN 运行。连接与断开由你管理，Amber 只使用其中的本机开发服务。",
                defaultValue: "请在现有代理中开启本地回环，并保持 VPN 运行。连接与断开由你管理，Amber 只使用其中的本机开发服务。"
            )
        }
        return "仅建立手机内部连接，不转发上网流量。首次添加时需在系统弹窗中允许；之后由任务自动连接和断开。连接时可能中断其他 VPN。"
    }

    private var appsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "允许控制的 App")
            AmberFormGroup {
                appPickerButton
                ForEach(controller.selectedBundleIDs.sorted(), id: \.self) { bundleID in
                    rowDivider
                    HStack(spacing: 8) {
                        // 与上方"从本机选择 App"的 24pt 图标槽 + 12pt 间距对齐（8 + 4 = 12）。
                        Image(systemName: "app")
                            .font(.system(size: 20))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(width: 24, height: 24)
                            .padding(.trailing, 4)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: controller.applicationName(for: bundleID))
                                .font(.body)
                            if controller.applicationName(for: bundleID) != bundleID {
                                Text(verbatim: bundleID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AmberTheme.muted)
                            }
                        }
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
                        .accessibilityLabel("移除 \(controller.applicationName(for: bundleID))")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                }
            }
            footer(appSelectionDetail)
            DisclosureGroup("手动填写 Bundle ID") {
                manualAppEntry
            }
            .font(.subheadline)
            .foregroundStyle(AmberTheme.muted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var appPickerButton: some View {
        actionRow("从本机选择 App", systemImage: "apps.iphone") {
            presentsAppPicker = true
        }
        .disabled(!canEditPreparation || !controller.isConnectionPrepared || !controller.hasPreparedPairing)
        .accessibilityIdentifier("phoneControlChooseApp")
    }

    private var appSelectionDetail: String {
        if !controller.isConnectionPrepared {
            return "先在下方准备本地连接，再读取手机中的 App；无需连接电脑查询 ID。"
        }
        if !controller.hasPreparedPairing {
            return "先完成下方的配对准备，再读取手机中的 App；无需连接电脑查询 ID。"
        }
        if controller.connectionMode == .existingVPN {
            return IOSAppLocalization.string(
                "读取 App 前，请开启支持本地回环的 VPN。添加结果会保存在这里。",
                defaultValue: "读取 App 前，请开启支持本地回环的 VPN。添加结果会保存在这里。"
            )
        }
        return "也可以直接让 Amber 查找并添加需要使用的 App。添加结果会保存在这里；无需连接电脑查询 ID。"
    }

    private var manualAppEntry: some View {
        VStack(spacing: 0) {
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

        }
    }

    private var statusSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "当前状态")
            AmberFormGroup {
                Text(verbatim: currentStatus)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("phoneControlStatus")
                rowDivider
                if controller.isCheckingReadiness {
                    actionRow("取消检查", systemImage: "xmark.circle", color: AmberTheme.muted) {
                        controller.cancelReadinessCheck()
                    }
                    .accessibilityIdentifier("phoneControlCancelReadiness")
                } else {
                    actionRow("检查自动化", systemImage: "checkmark.circle", busy: operation == .checkingReadiness) {
                        operation = .checkingReadiness
                        errorMessage = nil
                        Task {
                            defer { operation = nil }
                            do { try await controller.checkReadiness() }
                            catch is CancellationError { }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(isWorking || controller.isOccupied || !controller.enabled)
                    .accessibilityIdentifier("phoneControlCheckReadiness")
                }
                if let report = controller.readinessReport {
                    rowDivider
                    readinessDetails(report)
                }
                if let runID = controller.ownerRunID, let handoff = controller.handoffState(runID: runID) {
                    rowDivider
                    humanControlRow(runID: runID, state: handoff)
                }
                if controller.isOccupied && !controller.isCheckingReadiness {
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
            footer(controller.connectionMode == .existingVPN
                ? IOSAppLocalization.string(
                    "检查会通过现有 VPN 启动已安装的 runner 并读取当前界面，结束后保持 VPN 运行。",
                    defaultValue: "检查会通过现有 VPN 启动已安装的 runner 并读取当前界面，结束后保持 VPN 运行。"
                )
                : "检查会启动一次临时本地连接和已安装的 runner，读取当前界面后自动关闭连接；不会启动其他 App。")
        }
    }

    @ViewBuilder
    private func humanControlRow(runID: String, state: IOSPhoneControlHandoffState) -> some View {
        switch state {
        case .automated:
            actionRow("我来操作", systemImage: "hand.raised") {
                errorMessage = nil
                do { try controller.requestHumanTakeover(runID: runID) }
                catch { errorMessage = error.localizedDescription }
            }
            .accessibilityIdentifier("phoneControlTakeover")
        case .pausing:
            actionRow("等待在途操作回执", systemImage: "pause.circle", color: AmberTheme.muted, busy: true) {}
                .disabled(true)
                .accessibilityIdentifier("phoneControlPausing")
        case .paused:
            actionRow("继续自动操作", systemImage: "play.circle") {
                errorMessage = nil
                do { try controller.resumeAutomation(runID: runID) }
                catch { errorMessage = error.localizedDescription }
            }
            .accessibilityIdentifier("phoneControlResume")
        case .resuming:
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProgressView().dynamicTypeSize(.large).frame(width: 24, height: 24)
                    rowText("等待重新读取界面", detail: "Amber 会根据新的界面重新规划")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phoneControlResuming")
                rowDivider
                actionRow("我来操作", systemImage: "hand.raised") {
                    errorMessage = nil
                    do { try controller.requestHumanTakeover(runID: runID) }
                    catch { errorMessage = error.localizedDescription }
                }
                .accessibilityIdentifier("phoneControlTakeover")
            }
        }
    }

    private func readinessDetails(_ report: IOSPhoneControlReadinessReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let verified = report.connectionVerifiedAt {
                Text("连接已验证 · \(verified.formatted(date: .omitted, time: .standard))")
                Text("本次检查已收到签名 runner 的有效响应")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            if let read = report.uiReadAt {
                Text("UI 已读取 · \(read.formatted(date: .omitted, time: .standard))")
                Text(verbatim: "\(report.observedBundleID ?? "") · \(report.nodeCount ?? 0) 个界面元素")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            if let stage = report.failureStage, let message = report.failureMessage {
                Text("检查失败：\(stage.title)")
                    .foregroundStyle(AmberTheme.accentRed)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            } else if report.wasCancelled {
                Text("检查已取消")
            } else if report.completedAt == nil {
                Text("正在检查：\(report.stage.title)")
            }
            if let completed = report.completedAt {
                Text("\(readinessCleanupDescription(report)) · \(completed.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .font(.subheadline)
        .foregroundStyle(AmberTheme.foreground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("phoneControlReadinessResult")
    }

    private func readinessCleanupDescription(_ report: IOSPhoneControlReadinessReport) -> String {
        if controller.connectionMode == .existingVPN {
            let key = report.cleanupComplete
                ? "本次检查已结束，现有 VPN 由你管理"
                : "本次检查尚未确认结束，现有 VPN 由你管理"
            return IOSAppLocalization.string(key, defaultValue: key)
        }
        return report.cleanupComplete ? "临时连接已关闭" : "临时连接尚未确认关闭"
    }

    private var rowDivider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 14)
    }

    private var currentStatus: String {
        if let runID = controller.ownerRunID, let handoff = controller.handoffState(runID: runID), handoff != .automated {
            return [handoff.statusMessage, controller.handoffFailure(runID: runID)]
                .compactMap { $0 }.joined(separator: "\n")
        }
        guard controller.phase == .idle else { return controller.statusMessage }
        if !controller.enabled { return "手机控制已关闭" }
        if !controller.isConnectionPrepared { return "手机控制已开启，请先准备下方的本地连接" }
        if !controller.hasPreparedPairing { return "手机控制已开启，请先完成下方的配对准备" }
        if let report = controller.readinessReport, report.uiReadAt != nil, report.cleanupComplete {
            if controller.connectionMode == .existingVPN {
                return IOSAppLocalization.string(
                    "最近检查已读取界面，当前空闲；请保持现有 VPN 运行",
                    defaultValue: "最近检查已读取界面，当前空闲；请保持现有 VPN 运行"
                )
            }
            return "最近检查已读取界面，临时连接已关闭；当前空闲"
        }
        return "配置已保存，当前空闲；请检查自动化确认连接和界面读取"
    }

    private var connectionFailed: Bool {
        if case .failed = controller.localTunnel.state { return true }
        return false
    }

    private var localConnectionStatus: (title: String, detail: String) {
        if controller.connectionMode == .existingVPN {
            let detail = controller.readinessReport?.connectionVerifiedAt == nil
                ? "尚未验证连接；开启支持本地回环的 VPN 后检查自动化"
                : "最近检查已验证连接；请保持现有 VPN 运行"
            return (
                IOSAppLocalization.string("使用现有 VPN", defaultValue: "使用现有 VPN"),
                IOSAppLocalization.string(detail, defaultValue: detail)
            )
        }
        if controller.isPreparingConnection {
            return ("正在准备本地连接", "如系统弹出添加 VPN 配置，请点允许")
        }
        switch controller.localTunnel.state {
        case .unprepared:
            return ("尚未准备本地连接", "首次使用需要允许添加 VPN 配置")
        case .ready:
            let detail = controller.readinessReport?.connectionVerifiedAt == nil
                ? "尚未验证自动化；请使用上方的检查自动化"
                : "最近检查已验证连接；后续任务仍会重新连接"
            return ("连接配置已保存", detail)
        case .connecting:
            return ("正在建立本地连接", "等待连接完成")
        case .connected:
            return ("本地连接已接通", "自动化是否可用，以 runner 启动和新的界面观察为准")
        case .disconnecting:
            return ("正在断开本地连接", "正在结束本次连接")
        case .failed(let message):
            return ("本地连接失败", message)
        }
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
                    ProgressView().dynamicTypeSize(.large).frame(width: 24, height: 24)
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
                        try IOSPhoneControlCredentials.readPairingFile(url)
                    }.value
                    try await controller.importPairing(data)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }


}
