import SwiftUI
import UniformTypeIdentifiers

struct RuntimeEnvironmentView: View {
    @Bindable var settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let permissionStore: IOSPermissionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var terminalSmokeResult: IOSTerminalJobSnapshot?
    @State var sshProfileDraft = IOSSSHProfile()
    @State var sshPasswordDraft = ""
    @Environment(\.scenePhase) private var scenePhase
    @State var sshPrivateKeyDraft = ""
    @State var sshPassphraseDraft = ""
    @State var sshKeyGenerationType: IOSSSHKeyType = .ed25519
    @State var sshKeyRequireUserPresence = false
    @State var sshPublicKey = ""
    @State var showsSSHPublicKey = false
    @State var showsSSHKeyImporter = false
    @State private var showsSSHKeyManagement = false
    @State var sshProbeSnapshot: SSHProbeSnapshot?
    @State var sshVerificationTask: Task<Void, Never>?
    @State var sshPortDraft = "22"
    @State var sshStatus: SSHStatus = .idle
    @State private var remoteCommand = "echo amber-remote-task"
    @State private var remoteWorkingDirectory = ""
    @State private var remoteCommandResult: IOSTerminalJobSnapshot?
    @State private var remoteCommandJobId: String?
    @State private var remoteCommandTaskId: String?
    @State private var taskStore = IOSAdvancedTaskStore.shared
    @State private var showsCapabilityMatrix = false
    @State private var activeSheet: RuntimeEnvironmentSheet?
    @State private var selectedTerminalTask: SelectedTerminalTask?
    @State private var showsInteractiveIshTerminal = false
    @State private var interactiveIshTerminal = IOSInteractiveIshTerminalModel()

    private struct SelectedTerminalTask: Identifiable {
        let id: String
    }

    struct SSHProbeSnapshot: Equatable {
        let candidate: IOSSSHProfile
        let persistedProfile: IOSSSHProfile?
        let fingerprint: String
        let target: IOSSSHProfile
        let route: [IOSSSHProfile]
        let hopIndex: Int
        let replacesFingerprint: Bool
    }

    private enum RuntimeEnvironmentSheet: String, Identifiable {
        case runtime
        case sshProfile
        case ishTools
        case diagnostics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .runtime:
                IOSAppLocalization.string("选择运行环境", defaultValue: "选择运行环境")
            case .sshProfile: "SSH Profile"
            case .ishTools: "Agent iSH 工具"
            case .diagnostics: "验证与命令"
            }
        }

        var subtitle: String {
            switch self {
            case .runtime:
                IOSAppLocalization.string(
                    "选择 Amber 执行命令的方式。",
                    defaultValue: "选择 Amber 执行命令的方式。"
                )
            case .sshProfile: "编辑 Remote SSH 连接信息，并完成 Host 信任检查。"
            case .ishTools: "查看 Agent 的非 PTY iSH 执行、异步作业与人类 PTY 边界。"
            case .diagnostics: "运行 Smoke Test、查看能力矩阵，或手动触发一次远程命令。"
            }
        }
    }

    enum SSHStatus {
        case idle
        case testing
        case needsTrust(profileId: String, fingerprint: String)
        case success(String)
        case failure(String)

        var isTesting: Bool {
            if case .testing = self {
                return true
            }
            return false
        }
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        intro
                        runtimeStatusSection
                        runtimeOverviewSection
                        connectionOverviewSection
                        agentToolsOverviewSection
                        diagnosticsOverviewSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let selected = settingsStore.defaultSSHProfile {
                loadSSHProfile(selected)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearSSHDrafts() }
        }
        .onDisappear { clearSSHDrafts() }
        .onChange(of: sshProfileDraft.authMethod) { _, _ in
            sshPasswordDraft = ""
            sshPrivateKeyDraft = ""
            sshPublicKey = ""
        }
        .sheet(item: $activeSheet, onDismiss: { clearSSHDrafts() }) { sheet in
            RuntimeSheetChrome(title: sheet.title, subtitle: sheet.subtitle) {
                sheetContent(for: sheet)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .sheet(isPresented: $showsSSHKeyManagement) {
                RuntimeSheetChrome(title: "SSH 密钥管理",
                                   subtitle: "导入或生成私钥，按需查看和复制公钥。") {
                    sshKeyManagementSection
                }
                .fileImporter(isPresented: $showsSSHKeyImporter, allowedContentTypes: [.item]) { result in
                    importSSHPrivateKey(result)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedTerminalTask) { selection in
                TerminalTaskDetailView(taskStore: taskStore, taskId: selection.id)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showsInteractiveIshTerminal) {
                IOSInteractiveIshTerminalView(model: interactiveIshTerminal)
            }
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("运行环境")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var intro: some View {
        Text(
            IOSAppLocalization.string(
                "选择 Amber 执行命令的方式，也可以在这里配置 SSH 和 iSH。",
                defaultValue: "选择 Amber 执行命令的方式，也可以在这里配置 SSH 和 iSH。"
            )
        )
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
    }

    private var runtimeStatusSection: some View {
        RuntimeStatusCard(
            defaultRuntime: settingsStore.terminalDefaultRuntime,
            sshProfileName: settingsStore.defaultSSHProfile?.displayName,
            embeddedIshAvailable: embeddedIshAvailable,
            embeddedIshEnabled: embeddedIshEnabled,
            externalIshAvailable: externalIshAvailable,
            experimentalRuntimesLinked: IOSTerminalBuildPolicy.experimentalRuntimesLinked,
            experimentalEnabled: settingsStore.terminalExperimentalRuntimesEnabled
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var runtimeOverviewSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "默认运行环境")
            AmberFormGroup {
                ForEach(Array(primaryRuntimeChoices.enumerated()), id: \.element.id) { index, runtime in
                    RuntimeChoiceRow(
                        runtime: runtime,
                        isSelected: settingsStore.terminalDefaultRuntime == runtime,
                        isEnabled: runtimeIsEnabled(runtime),
                        isRecommended: runtime == .remoteSSH
                    ) {
                        guard runtimeIsEnabled(runtime) else { return }
                        settingsStore.terminalDefaultRuntime = runtime
                    }

                    if index < primaryRuntimeChoices.count - 1 {
                        RuntimeDivider()
                    }
                }

                if shouldShowRuntimeOptionsRow {
                    RuntimeDivider()
                    RuntimeNavigationRow(
                        title: IOSAppLocalization.string(
                            "更多运行环境",
                            defaultValue: "更多运行环境"
                        ),
                        subtitle: experimentalRuntimeSubtitle,
                        value: experimentalRuntimeValue,
                        systemImage: "sparkles",
                        accent: AmberTheme.accentAmber
                    ) {
                        activeSheet = .runtime
                    }
                }
            }

            Text(
                IOSAppLocalization.string(
                    "默认环境会用于聊天命令和测试。AmberShell 是否询问取决于执行策略。",
                    defaultValue: "默认环境会用于聊天命令和测试。AmberShell 是否询问取决于执行策略。"
                )
            )
                .runtimeFootnote()
        }
    }

    private var connectionOverviewSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "连接配置")
            AmberFormGroup {
                RuntimeNavigationRow(
                    title: IOSAppLocalization.string(
                        "SSH Profile",
                        defaultValue: "SSH Profile"
                    ),
                    subtitle: sshConnectionSummary,
                    value: settingsStore.defaultSSHProfile?.displayName
                        ?? IOSAppLocalization.string("未配置", defaultValue: "未配置"),
                    systemImage: "desktopcomputer",
                    accent: AmberTheme.accent
                ) {
                    activeSheet = .sshProfile
                }
                RuntimeDivider()
                RuntimeNavigationRow(
                    title: IOSAppLocalization.string(
                        "Host 信任",
                        defaultValue: "Host 信任"
                    ),
                    subtitle: IOSAppLocalization.string(
                        "连接前校验 host key；未信任时不会发送密码",
                        defaultValue: "连接前校验 host key；未信任时不会发送密码"
                    ),
                    value: sshStatusValue,
                    systemImage: "checkmark.shield",
                    accent: sshStatusAccent
                ) {
                    activeSheet = .sshProfile
                }
            }
        }
    }

    private var agentToolsOverviewSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "iSH 工具")
            AmberFormGroup {
                RuntimeNavigationRow(
                    title: IOSAppLocalization.string(
                        "iSH 工具能力",
                        defaultValue: "iSH 工具能力"
                    ),
                    subtitle: embeddedIshStatusDescription,
                    value: ishToolsSummary,
                    systemImage: "shippingbox",
                    accent: embeddedIshEnabled ? AmberTheme.accentGreen : AmberTheme.accentAmber
                ) {
                    activeSheet = .ishTools
                }
            }
        }
    }

    private var diagnosticsOverviewSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "验证")
            AmberFormGroup {
                RuntimeNavigationRow(
                    title: IOSAppLocalization.string(
                        "Smoke Test 与远程命令",
                        defaultValue: "Smoke Test 与远程命令"
                    ),
                    subtitle: diagnosticsSummary,
                    value: diagnosticsValue,
                    systemImage: "play.circle",
                    accent: diagnosticsAccent
                ) {
                    activeSheet = .diagnostics
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: RuntimeEnvironmentSheet) -> some View {
        switch sheet {
        case .runtime:
            runtimeSection
        case .sshProfile:
            sshProfileSection
            hostFingerprintSection
        case .ishTools:
            ishHandoffSection
        case .diagnostics:
            diagnosticsSection
            remoteCommandSection
        }
    }

    private var runtimeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "默认运行环境")
            AmberFormGroup {
                ForEach(Array(runtimeChoices.enumerated()), id: \.element.id) { index, runtime in
                    RuntimeChoiceRow(
                        runtime: runtime,
                        isSelected: settingsStore.terminalDefaultRuntime == runtime,
                        isEnabled: runtimeIsEnabled(runtime),
                        isRecommended: runtime == .remoteSSH
                    ) {
                        guard runtimeIsEnabled(runtime) else { return }
                        settingsStore.terminalDefaultRuntime = runtime
                    }

                    if index < runtimeChoices.count - 1 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            .padding(.leading, 14)
                    }
                }
            }

            if IOSTerminalBuildPolicy.experimentalRuntimesLinked {
                AmberFormGroup {
                    RuntimeToggleRow(
                        title: "显示实验 Runtime",
                        subtitle: "允许把已接入的 iSH Experimental 设为默认 Runtime",
                        isOn: settingsStore.terminalExperimentalRuntimesEnabled,
                        isEnabled: true
                    ) {
                        settingsStore.terminalExperimentalRuntimesEnabled.toggle()
                        if !settingsStore.terminalExperimentalRuntimesEnabled,
                           IOSTerminalRuntimeCapabilities.capability(for: settingsStore.terminalDefaultRuntime).tier == .experimental {
                            settingsStore.terminalDefaultRuntime = .remoteSSH
                        }
                    }
                }
                .padding(.top, 10)
            }

            let runtimeGateText = IOSTerminalBuildPolicy.experimentalRuntimesLinked
                ? "AmberShell、Remote SSH 与 iSH 使用各自能力闸门；AmberShell 遵循高风险自动批准设置。"
                : "稳定 target 提供 Remote SSH 与 AmberShell；AmberShell 遵循高风险自动批准设置，iSH 交接能力在下方单独说明。"
            Text(IOSAppLocalization.string(runtimeGateText, defaultValue: runtimeGateText))
                .runtimeFootnote()
        }
    }

    private var sshProfileSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Remote SSH 配置")

            if !settingsStore.sshProfiles.isEmpty {
                AmberFormGroup {
                    Menu {
                        ForEach(settingsStore.sshProfiles) { profile in
                            Button(profile.displayName) {
                                settingsStore.sshDefaultProfileId = profile.id
                                loadSSHProfile(profile)
                            }
                        }
                    } label: {
                        RuntimeValueRow(
                            title: "默认 SSH Profile",
                            subtitle: "Remote SSH Smoke Test 使用此 profile",
                            value: settingsStore.defaultSSHProfile?.displayName ?? "未选择",
                            systemImage: "desktopcomputer"
                        )
                    }
                }
            }

            AmberFormGroup {
                RuntimeTextFieldRow(title: "Profile 名称", text: $sshProfileDraft.name, placeholder: "未命名")
                RuntimeDivider()
                RuntimeTextFieldRow(title: "Host", text: sshHostBinding, placeholder: "example.com", monospace: true)
                RuntimeDivider()
                RuntimeTextFieldRow(title: "端口", text: sshPortBinding, placeholder: "22", monospace: true, keyboardType: .numberPad)
                RuntimeDivider()
                RuntimeTextFieldRow(title: "用户名", text: sshUsernameBinding, placeholder: "root", monospace: true)
                RuntimeDivider()
                sshJumpHostRow
                RuntimeDivider()
                if dynamicTypeSize.isAccessibilitySize {
                    Menu {
                        Picker("认证方式", selection: sshAuthMethodBinding) {
                            ForEach(IOSSSHAuthMethod.allCases) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                    } label: {
                        RuntimeValueRow(title: "认证方式", subtitle: "选择连接认证方式",
                                        value: sshProfileDraft.authMethod.displayName, systemImage: "key.fill")
                    }
                } else {
                    Picker("认证方式", selection: sshAuthMethodBinding) {
                        ForEach(IOSSSHAuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(14)
                }
                if sshProfileDraft.authMethod == .password {
                    RuntimeSecureFieldRow(title: "密码", text: $sshPasswordDraft, placeholder: "留空保留已存密码")
                } else {
                    RuntimeNavigationRow(
                        title: "SSH 私钥",
                        subtitle: sshKeySummary,
                        value: "管理",
                        systemImage: "key.fill",
                        accent: sshKeyStatusAccent
                    ) {
                        showsSSHKeyManagement = true
                    }
                }
            }
            .padding(.top, settingsStore.sshProfiles.isEmpty ? 0 : 10)

            AmberFormGroup {
                RuntimeActionRow(title: "保存 SSH Profile", color: AmberTheme.accent) {
                    saveSSHProfile()
                }
                RuntimeDivider()
                RuntimeActionRow(title: "新建 Profile", color: AmberTheme.accent) {
                    resetSSHProfileDraft()
                }
                if settingsStore.sshProfiles.contains(where: { $0.id == sshProfileDraft.id }) {
                    RuntimeDivider()
                    RuntimeActionRow(title: "清除已存凭证", color: AmberTheme.accentRed) {
                        clearSSHCredential()
                    }
                }
            }
            .padding(.top, 10)

            Text("凭证仅存本机钥匙串，解锁后可读取，不随配置导出或同步。留空保留原凭证；保存新的连接目标或认证方式时，需重新提供凭证。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
        .disabled(sshStatus.isTesting)
    }

    private var ishHandoffSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Agent iSH 工具")
            AmberFormGroup {
                RuntimeInfoRow(
                    title: "内置 iSH 执行",
                    subtitle: embeddedIshStatusDescription,
                    value: embeddedIshAvailable ? (embeddedIshEnabled ? "可回传" : "已禁用") : "未链接",
                    systemImage: embeddedIshEnabled ? "shippingbox" : "lock",
                    accent: embeddedIshEnabled ? AmberTheme.accentGreen : AmberTheme.muted
                )
                if embeddedIshAvailable, let capability = embeddedIshCapability {
                    RuntimeDivider()
                    embeddedIshPolicyPicker(for: capability)
                }
                RuntimeDivider()
                RuntimeInfoRow(
                    title: "外部 iSH 交接",
                    subtitle: "聊天中审批后调用 ish_handoff，复制可粘贴脚本并写入 Documents/ish-handoff；需要你切到 iSH 手动执行。",
                    value: externalIshAvailable ? "手动交接" : "不可用",
                    systemImage: "terminal",
                    accent: AmberTheme.accentAmber
                )
                RuntimeDivider()
                RuntimeInfoRow(
                    title: "安全边界",
                    subtitle: IOSTerminalBuildPolicy.experimentalRuntimesLinked
                        ? "Agent 命令执行与停止作业按所选权限策略审批；异步 Job 没有 PTY 或 stdin，ExperimentalGPL 的持续 PTY 只由你直接操作。"
                        : "两条 iSH 链路都需要前台审批；外部 iSH 不回传结果，稳定 target 不链接内置 PTY。",
                    value: "权限控制",
                    systemImage: "hand.raised",
                    accent: AmberTheme.accentAmber
                )
            }

            if IOSTerminalBuildPolicy.experimentalRuntimesLinked {
                AmberFormGroup {
                    RuntimeActionRow(title: "打开 iSH 交互终端", color: AmberTheme.accentGreen) {
                        showsInteractiveIshTerminal = true
                    }
                }
                .padding(.top, 10)

                Text("交互终端是 ExperimentalGPL 的人类前台会话：支持键盘、Ctrl-C 和窗口 resize；切到后台或关闭页面时会停止，不保存或恢复 shell。")
                    .runtimeFootnote()
            }

            let recentEmbeddedTasks = taskStore.recent(kind: .embeddedIsh, limit: 3)
            if !recentEmbeddedTasks.isEmpty {
                AmberSectionLabel(text: "最近 Agent iSH 作业")
                    .padding(.top, 10)
                AmberFormGroup {
                    ForEach(Array(recentEmbeddedTasks.enumerated()), id: \.element.id) { index, task in
                        Button {
                            selectedTerminalTask = SelectedTerminalTask(id: task.id)
                        } label: {
                            TerminalTaskRow(task: task, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(terminalTaskAccessibilityLabel(task))
                        if index < recentEmbeddedTasks.count - 1 {
                            RuntimeDivider()
                        }
                    }
                }
            }

            Text("异步只表示 Agent 不必阻塞等待，并非 iOS 后台常驻：App 重启会把未完成作业标记为已中断。AmberShell 与聊天共用 App 自有 /workspace；Remote SSH、内置 iSH 和外部 iSH App 的文件与软件包彼此隔离，不会自动同步。")
                .runtimeFootnote()
        }
    }

    private func embeddedIshPolicyPicker(for capability: IOSPlatformCapability) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Agent 执行权限", selection: Binding(
                get: { permissionStore.policy(for: capability) },
                set: { permissionStore.setPolicy($0, for: capability) }
            )) {
                ForEach(permissionStore.availablePolicies(for: capability)) { policy in
                    Text(verbatim: policy.localizedTitle).tag(policy)
                }
            }
            .tint(AmberTheme.accent)
            .frame(minHeight: 44)
            .accessibilityIdentifier("embeddedIshExecutionPolicy")

            Text("选择“每次询问”后，下一条聊天请求即可搜索 ios_ish_execute；未开启高风险自动批准时，执行命令需要你确认。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var hostFingerprintSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Host 指纹信任")
            HostFingerprintCard(
                status: sshStatus,
                hopLabel: sshProbeSnapshot.map { "第 \($0.hopIndex)/\($0.route.count) 跳 · \($0.candidate.displayName)" },
                replacesFingerprint: sshProbeSnapshot?.replacesFingerprint ?? false,
                statusExpectedFingerprint: sshProbeSnapshot?.candidate.knownHostSHA256 ?? "",
                onTrust: trustSSHHost,
                onCancel: cancelSSHProbe
            )

            HStack {
                Button {
                    testSSHConnection()
                } label: {
                    Label(sshStatus.isTesting ? "检查中..." : "检查 Host 指纹", systemImage: "checkmark.shield")
                }
                .buttonStyle(RuntimeGlassButtonStyle())
                .disabled(sshStatus.isTesting)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text("这是连接前的安全闸门。未信任或指纹不匹配时，密码不会被发送，远程命令也不会执行。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
    }

    private var diagnosticsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "验证与诊断")
            HStack(spacing: 10) {
                Button {
                    testTerminalRuntime()
                } label: {
                    Label("运行 Smoke Test", systemImage: "play.fill")
                }
                .buttonStyle(RuntimeFilledButtonStyle())

                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        showsCapabilityMatrix.toggle()
                    }
                } label: {
                    Label(showsCapabilityMatrix ? "收起矩阵" : "能力矩阵", systemImage: "square.grid.2x2")
                }
                .buttonStyle(RuntimeGlassButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if let terminalSmokeResult {
                SmokeResultCard(result: terminalSmokeResult)
                    .padding(.top, 10)
            }

            Text("Smoke Test 会验证当前默认 Runtime：Remote SSH 执行 echo amber-terminal-smoke，AmberShell 与 iSH 执行 pwd。AmberShell 与聊天共用 App 自有 /workspace；iSH 的 /workspace 位于内置 rootfs，Remote SSH 使用远端 cwd。")
                .runtimeFootnote()

            if showsCapabilityMatrix {
                VStack(spacing: 8) {
                    ForEach(IOSTerminalBuildPolicy.selectableRuntimes) { runtime in
                        RuntimeMatrixCard(capability: IOSTerminalRuntimeCapabilities.capability(for: runtime))
                    }
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
    }

    private var remoteCommandSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "远程命令任务")
            AmberFormGroup {
                RuntimeTextFieldRow(
                    title: "命令",
                    text: $remoteCommand,
                    placeholder: "echo amber-remote-task",
                    monospace: true
                )
                RuntimeDivider()
                RuntimeTextFieldRow(
                    title: "工作目录",
                    text: $remoteWorkingDirectory,
                    placeholder: "登录默认目录（可选）",
                    monospace: true
                )
                RuntimeDivider()
                RuntimeValueRow(
                    title: "连接",
                    subtitle: "只使用默认 Remote SSH profile",
                    value: settingsStore.defaultSSHProfile?.displayName ?? "未选择",
                    systemImage: "terminal",
                    showsChevron: false
                )
                RuntimeDivider()
                RuntimeActionRow(
                    title: isRemoteCommandRunning ? "运行中..." : "运行命令",
                    color: isRemoteCommandRunning ? AmberTheme.muted : AmberTheme.accent
                ) {
                    guard !isRemoteCommandRunning else { return }
                    runRemoteCommand()
                }
                if isRemoteCommandRunning {
                    RuntimeDivider()
                    RuntimeActionRow(title: "取消命令", color: AmberTheme.accentRed) {
                        cancelRemoteCommand()
                    }
                }
            }

            if let remoteCommandResult {
                SmokeResultCard(result: remoteCommandResult)
                    .padding(.top, 10)
            }

            let recent = taskStore.recent(kind: .remoteCommand, limit: 3)
            if !recent.isEmpty {
                AmberFormGroup {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, task in
                        Button {
                            selectedTerminalTask = SelectedTerminalTask(id: task.id)
                        } label: {
                            TerminalTaskRow(task: task, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(terminalTaskAccessibilityLabel(task))
                        if index < recent.count - 1 {
                            RuntimeDivider()
                        }
                    }
                }
                .padding(.top, 10)
            }

            Text("远程命令只在前台按钮触发；未信任 host、缺少密码或命中危险命令片段时会失败并记录原因。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
    }

    private var embeddedIshAvailable: Bool {
        !IOSEmbeddedIshToolCatalog.supportedToolNames.isEmpty
    }

    private var embeddedIshCapability: IOSPlatformCapability? {
        IOSCapabilityRegistry.capabilities.first { $0.id == "ios.embedded.ish_runtime" }
    }

    private var embeddedIshEnabled: Bool {
        embeddedIshAvailable && embeddedIshCapability.map { permissionStore.policy(for: $0) != .disabled } == true
    }

    private var embeddedIshStatusDescription: String {
        guard embeddedIshAvailable else {
            return "当前 target 未链接内置 iSH；外部 iSH 仅支持手动交接。"
        }
        guard embeddedIshEnabled else {
            return "当前构建包含内置 iSH，但 Agent 执行权限已禁用，ios_ish_execute 不会进入模型工具目录。可在此调整执行权限。"
        }
        return "聊天中可搜索 ios_ish_execute，执行非 PTY 脚本并回传 stdout、stderr、退出码；也可异步启动作业。实际执行按所选权限策略审批。"
    }

    private var externalIshAvailable: Bool {
        !IOSIshToolCatalog.supportedToolNames.isEmpty
    }

    private var primaryRuntimeChoices: [IOSTerminalRuntimeKind] {
        [.remoteSSH, .localIOSTools]
    }

    private var runtimeChoices: [IOSTerminalRuntimeKind] {
        guard IOSTerminalBuildPolicy.experimentalRuntimesLinked else {
            return [.remoteSSH, .localIOSTools]
        }
        return IOSTerminalBuildPolicy.selectableRuntimes
    }

    private var shouldShowRuntimeOptionsRow: Bool {
        IOSTerminalBuildPolicy.experimentalRuntimesLinked ||
            !primaryRuntimeChoices.contains(settingsStore.terminalDefaultRuntime)
    }

    private var experimentalRuntimeSubtitle: String {
        guard IOSTerminalBuildPolicy.experimentalRuntimesLinked else {
            return IOSAppLocalization.string(
                "当前构建没有链接实验 Runtime",
                defaultValue: "当前构建没有链接实验 Runtime"
            )
        }
        return settingsStore.terminalExperimentalRuntimesEnabled
            ? IOSAppLocalization.string(
                "iSH Experimental 已显示；仅 ExperimentalGPL target，需 GPL 审核",
                defaultValue: "iSH Experimental 已显示；仅 ExperimentalGPL target，需 GPL 审核"
            )
            : IOSAppLocalization.string(
                "iSH Experimental 默认隐藏；仅 ExperimentalGPL target，需 GPL 审核",
                defaultValue: "iSH Experimental 默认隐藏；仅 ExperimentalGPL target，需 GPL 审核"
            )
    }

    private var experimentalRuntimeValue: String {
        if !primaryRuntimeChoices.contains(settingsStore.terminalDefaultRuntime) {
            return settingsStore.terminalDefaultRuntime.displayName
        }
        return settingsStore.terminalExperimentalRuntimesEnabled
            ? IOSAppLocalization.string("已显示", defaultValue: "已显示")
            : IOSAppLocalization.string("已隐藏", defaultValue: "已隐藏")
    }

    private var sshConnectionSummary: String {
        guard let profile = settingsStore.defaultSSHProfile else {
            return IOSAppLocalization.string(
                "为 Remote SSH 添加主机、用户名和密码或私钥",
                defaultValue: "为 Remote SSH 添加主机、用户名和密码或私钥"
            )
        }
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = host.isEmpty
            ? IOSAppLocalization.string("Host 未填写", defaultValue: "Host 未填写")
            : "\(host):\(profile.port)"
        return user.isEmpty ? endpoint : "\(user)@\(endpoint)"
    }

    private var sshKeySummary: String {
        guard sshProfileDraft.authMethod == .privateKey else {
            return "当前使用密码认证"
        }
        if !sshPrivateKeyDraft.isEmpty { return "私钥待保存" }
        var draft = sshProfileDraft
        draft.port = Int(sshPortDraft) ?? 0
        guard let validatedDraft = try? draft.validated(),
              let persisted = settingsStore.sshProfiles.first(where: { $0.id == validatedDraft.id }) else {
            return "尚未保存私钥"
        }
        guard persisted.host == validatedDraft.host,
              persisted.port == validatedDraft.port,
              persisted.username == validatedDraft.username,
              persisted.authMethod == validatedDraft.authMethod else {
            return "连接已变更，需重新保存私钥"
        }
        return settingsStore.hasCredentialForSSHProfile(validatedDraft)
            ? "私钥已保存；不会回填明文"
            : "尚未保存私钥"
    }

    private var sshKeyStatusAccent: Color {
        if sshKeySummary.contains("已保存") { return AmberTheme.accentGreen }
        if sshKeySummary.contains("密码") { return AmberTheme.accentAmber }
        return AmberTheme.accentAmber
    }

    private var sshStatusValue: String {
        switch sshStatus {
        case .idle:
            return settingsStore.defaultSSHProfile?.knownHostSHA256?.isEmpty == false
                ? IOSAppLocalization.string("已保存", defaultValue: "已保存")
                : IOSAppLocalization.string("待检查", defaultValue: "待检查")
        case .testing:
            return IOSAppLocalization.string("检查中", defaultValue: "检查中")
        case .needsTrust:
            return IOSAppLocalization.string("需确认", defaultValue: "需确认")
        case .success:
            return settingsStore.defaultSSHProfile?.knownHostSHA256?.isEmpty == false
                ? IOSAppLocalization.string("已信任", defaultValue: "已信任")
                : IOSAppLocalization.string("待检查", defaultValue: "待检查")
        case .failure:
            return IOSAppLocalization.string("异常", defaultValue: "异常")
        }
    }

    private var sshStatusAccent: Color {
        switch sshStatus {
        case .success:
            return settingsStore.defaultSSHProfile?.knownHostSHA256?.isEmpty == false
                ? AmberTheme.accentGreen
                : AmberTheme.muted
        case .needsTrust, .testing:
            return AmberTheme.accentAmber
        case .failure:
            return AmberTheme.accentRed
        case .idle:
            return settingsStore.defaultSSHProfile?.knownHostSHA256?.isEmpty == false
                ? AmberTheme.accentGreen
                : AmberTheme.muted
        }
    }

    private var ishToolsSummary: String {
        if embeddedIshAvailable && !embeddedIshEnabled {
            return "内置已禁用"
        }
        if embeddedIshAvailable && externalIshAvailable {
            return IOSAppLocalization.string("内置 + 交接", defaultValue: "内置 + 交接")
        }
        if embeddedIshAvailable {
            return IOSAppLocalization.string("内置可用", defaultValue: "内置可用")
        }
        if externalIshAvailable {
            return IOSAppLocalization.string("外部交接", defaultValue: "外部交接")
        }
        return IOSAppLocalization.string("未启用", defaultValue: "未启用")
    }

    private var diagnosticsSummary: String {
        if isRemoteCommandRunning {
            return IOSAppLocalization.string(
                "远程命令正在运行，可进入查看输出或取消",
                defaultValue: "远程命令正在运行，可进入查看输出或取消"
            )
        }
        if let remoteCommandResult {
            return IOSAppLocalization.formatted(
                "最近远程命令：%@",
                defaultValue: "最近远程命令：%@",
                arguments: [terminalStatusTitle(remoteCommandResult.status)]
            )
        }
        if let terminalSmokeResult {
            return IOSAppLocalization.formatted(
                "最近 Smoke Test：%@",
                defaultValue: "最近 Smoke Test：%@",
                arguments: [terminalStatusTitle(terminalSmokeResult.status)]
            )
        }
        return IOSAppLocalization.string(
            "验证当前 Runtime，或手动运行一次 Remote SSH 命令",
            defaultValue: "验证当前 Runtime，或手动运行一次 Remote SSH 命令"
        )
    }

    private var diagnosticsValue: String {
        if isRemoteCommandRunning {
            return IOSAppLocalization.string("运行中", defaultValue: "运行中")
        }
        if let remoteCommandResult {
            return terminalStatusTitle(remoteCommandResult.status)
        }
        if let terminalSmokeResult {
            return terminalStatusTitle(terminalSmokeResult.status)
        }
        return IOSAppLocalization.string("打开", defaultValue: "打开")
    }

    private var diagnosticsAccent: Color {
        if isRemoteCommandRunning {
            return AmberTheme.accentAmber
        }
        let status = remoteCommandResult?.status ?? terminalSmokeResult?.status
        switch IOSTerminalJobStatus(rawValue: status ?? "") {
        case .completed:
            return AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted:
            return AmberTheme.accentRed
        case .cancelled:
            return AmberTheme.muted2
        case .queued, .running:
            return AmberTheme.accentAmber
        case nil:
            return AmberTheme.accent
        }
    }

    private func runtimeIsEnabled(_ runtime: IOSTerminalRuntimeKind) -> Bool {
        guard IOSTerminalBuildPolicy.selectableRuntimes.contains(runtime) else { return false }
        let tier = IOSTerminalRuntimeCapabilities.capability(for: runtime).tier
        return tier == .stable || settingsStore.terminalExperimentalRuntimesEnabled
    }

    private var isRemoteCommandRunning: Bool {
        guard let remoteCommandResult else { return false }
        return remoteCommandResult.status == IOSTerminalJobStatus.running.rawValue
    }

    private func terminalStatusTitle(_ status: String) -> String {
        guard let title = IOSTerminalJobStatus(rawValue: status)?.title else { return status }
        return IOSAppLocalization.string(title, defaultValue: title)
    }

    private func terminalTaskAccessibilityLabel(_ task: IOSAdvancedTaskRecord) -> String {
        let context = task.commandPreview.isEmpty ? task.connectionSummary : task.commandPreview
        return "查看\(task.kind.title)详情：\(task.status.title)，\(String(context.prefix(80)))"
    }

    private func testTerminalRuntime() {
        guard sharedSettings.isCapabilityGateEnabled(.remoteRuntime) else {
            terminalSmokeResult = IOSTerminalJobSnapshot(
                id: "remote-runtime-disabled",
                runtime: settingsStore.terminalDefaultRuntime,
                status: IOSTerminalJobStatus.failed.rawValue,
                exitCode: nil,
                outputTail: "",
                startedAt: Date(),
                updatedAt: Date(),
                error: IOSCapabilityGate.remoteRuntime.disabledReason
            )
            return
        }
        terminalSmokeResult = nil
        let command = switch settingsStore.terminalDefaultRuntime {
        case .localIOSTools, .ishExperimental:
            "pwd"
        case .remoteSSH, .remoteMosh:
            "echo amber-terminal-smoke"
        }
        Task {
            do {
                let profile = settingsStore.defaultSSHProfile
                let credential = settingsStore.terminalDefaultRuntime == .remoteSSH
                    ? try profile.flatMap { try settingsStore.credentialForSSHProfile($0) } : nil
                let started = await IOSTerminalRuntime.shared.startJob(
                    command: command,
                    runtime: settingsStore.terminalDefaultRuntime,
                    experimentalEnabled: settingsStore.terminalExperimentalRuntimesEnabled,
                    sshProfile: settingsStore.defaultSSHProfile,
                    sshCredential: credential
                )
                if started.status == IOSTerminalJobStatus.running.rawValue {
                    terminalSmokeResult = await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 65)
                    _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
                } else {
                    terminalSmokeResult = started
                }
            } catch {
                terminalSmokeResult = sshCredentialFailure(error, runtime: settingsStore.terminalDefaultRuntime)
            }
        }
    }

    private func sshCredentialFailure(_ error: Error, runtime: IOSTerminalRuntimeKind = .remoteSSH) -> IOSTerminalJobSnapshot {
        IOSTerminalJobSnapshot(id: UUID().uuidString, runtime: runtime,
                              status: IOSTerminalJobStatus.failed.rawValue, exitCode: nil,
                              outputTail: "", startedAt: Date(), updatedAt: Date(), error: error.localizedDescription)
    }

    private func runRemoteCommand() {
        let validatedCommand: String
        switch IOSRemoteCommandPolicy.validate(remoteCommand) {
        case .success(let command):
            validatedCommand = command
        case .failure(let message):
            let now = Date()
            let task = taskStore.startTask(
                kind: .remoteCommand,
                title: "Remote SSH · blocked",
                objective: remoteCommand,
                connectionSummary: settingsStore.defaultSSHProfile?.displayName ?? "no profile",
                commandPreview: remoteCommand,
                sourceToolName: "remote_command_run"
            )
            remoteCommandTaskId = task.id
            remoteCommandResult = IOSTerminalJobSnapshot(
                id: task.id,
                runtime: .remoteSSH,
                status: IOSTerminalJobStatus.failed.rawValue,
                exitCode: nil,
                outputTail: message,
                startedAt: now,
                updatedAt: now,
                error: message
            )
            _ = taskStore.updateTask(
                id: task.id,
                status: .failed,
                resultSummary: message,
                logTail: message,
                error: message,
                retryable: true,
                cancelCapability: false
            )
            return
        }

        let profile = settingsStore.defaultSSHProfile
        let workingDirectory = remoteWorkingDirectory.nilIfBlank
        var taskMetadata = ["runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue]
        if let workingDirectory {
            taskMetadata["cwd"] = workingDirectory
        }
        let approvalPayloadDigest = "\(validatedCommand)\n\(workingDirectory ?? "")".hashValue
        let task = taskStore.startTask(
            kind: .remoteCommand,
            title: "Remote SSH · \(validatedCommand.prefix(34))",
            objective: validatedCommand,
            connectionSummary: profile?.displayName ?? "no profile",
            commandPreview: validatedCommand,
            sourceToolName: "remote_command_run",
            metadata: taskMetadata
        )
        remoteCommandTaskId = task.id
        permissionStore.recordApproval(
            capabilityId: "ios.remote.command",
            toolName: "remote_command_run",
            action: .allowed,
            reason: "User started a foreground Remote SSH command.",
            runId: task.id,
            payloadDigest: "\(approvalPayloadDigest)"
        )

        Task {
            let credential: IOSSSHCredential?
            do { credential = try profile.flatMap { try settingsStore.credentialForSSHProfile($0) } }
            catch {
                remoteCommandResult = sshCredentialFailure(error)
                _ = taskStore.updateTask(id: task.id, status: .failed, error: error.localizedDescription,
                                         retryable: true, cancelCapability: false)
                return
            }
            let started = await IOSTerminalRuntime.shared.startJob(
                command: validatedCommand,
                runtime: .remoteSSH,
                experimentalEnabled: false,
                workingDirectory: workingDirectory,
                sshProfile: profile,
                sshCredential: credential,
                timeoutSeconds: 60
            )
            remoteCommandResult = started
            remoteCommandJobId = started.id
            _ = taskStore.updateTask(
                id: task.id,
                status: mapTerminalStatus(started.status),
                resultSummary: started.error ?? started.status,
                logTail: started.outputTail,
                error: started.error ?? "",
                retryable: started.status != IOSTerminalJobStatus.completed.rawValue,
                cancelCapability: started.status == IOSTerminalJobStatus.running.rawValue,
                metadata: ["terminal_job_id": started.id]
            )
            guard started.status == IOSTerminalJobStatus.running.rawValue else { return }

            let deadline = Date().addingTimeInterval(65)
            var finished = IOSTerminalRuntime.shared.readJob(id: started.id)
            while let current = finished,
                  current.status == IOSTerminalJobStatus.running.rawValue,
                  Date() < deadline {
                remoteCommandResult = current
                _ = taskStore.updateTask(
                    id: task.id,
                    status: .running,
                    resultSummary: "",
                    logTail: current.outputTail,
                    error: "",
                    retryable: false,
                    cancelCapability: true
                )
                try? await Task.sleep(nanoseconds: 250_000_000)
                finished = IOSTerminalRuntime.shared.readJob(id: started.id)
            }
            if finished?.status == IOSTerminalJobStatus.running.rawValue {
                finished = await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 0)
            }
            if let finished {
                remoteCommandResult = finished
                _ = taskStore.updateTask(
                    id: task.id,
                    status: mapTerminalStatus(finished.status),
                    resultSummary: finished.error ?? "Remote command finished with status \(finished.status).",
                    logTail: finished.outputTail,
                    error: finished.error ?? "",
                    retryable: finished.status != IOSTerminalJobStatus.completed.rawValue,
                    cancelCapability: false
                )
                _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
            }
        }
    }

    private func cancelRemoteCommand() {
        guard let jobId = remoteCommandJobId else { return }
        let stopped = IOSTerminalRuntime.shared.stopJob(id: jobId)
        if let stopped {
            remoteCommandResult = stopped
        }
        if let remoteCommandTaskId {
            _ = taskStore.updateTask(
                id: remoteCommandTaskId,
                status: .cancelled,
                resultSummary: "Remote command cancelled.",
                logTail: stopped?.outputTail ?? "",
                error: stopped?.error ?? IOSSSHError.commandCancelled.localizedDescription,
                retryable: true,
                cancelCapability: false
            )
            permissionStore.recordApproval(
                capabilityId: "ios.remote.command",
                toolName: "remote_command_cancel",
                action: .allowed,
                reason: "User cancelled a foreground Remote SSH command.",
                runId: remoteCommandTaskId
            )
        }
    }

    private func mapTerminalStatus(_ status: String) -> IOSAdvancedTaskStatus {
        switch IOSTerminalJobStatus(rawValue: status) {
        case .queued:
            return .queued
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .interrupted:
            return .interrupted
        case nil:
            return .failed
        }
    }

}
