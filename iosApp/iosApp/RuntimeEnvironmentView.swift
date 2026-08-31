import SwiftUI
import UIKit

struct RuntimeEnvironmentView: View {
    @Bindable var settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var terminalSmokeResult: IOSTerminalJobSnapshot?
    @State private var sshProfileDraft = IOSSSHProfile()
    @State private var sshPasswordDraft = ""
    @State private var loadedSSHPasswordDraft = ""
    @State private var sshPortDraft = "22"
    @State private var sshStatus: SSHStatus = .idle
    @State private var remoteCommand = "echo amber-remote-task"
    @State private var remoteWorkingDirectory = ""
    @State private var remoteCommandResult: IOSTerminalJobSnapshot?
    @State private var remoteCommandJobId: String?
    @State private var remoteCommandTaskId: String?
    @State private var taskStore = IOSAdvancedTaskStore.shared
    @State private var permissionStore = IOSPermissionStore()
    @State private var showsCapabilityMatrix = false
    @State private var activeSheet: RuntimeEnvironmentSheet?
    @State private var selectedTerminalTask: SelectedTerminalTask?
    @State private var showsInteractiveIshTerminal = false
    @State private var interactiveIshTerminal = IOSInteractiveIshTerminalModel()

    private struct SelectedTerminalTask: Identifiable {
        let id: String
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
        .sheet(item: $activeSheet) { sheet in
            RuntimeSheetChrome(title: sheet.title, subtitle: sheet.subtitle) {
                sheetContent(for: sheet)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                    "默认环境会用于聊天命令和测试。运行 AmberShell 前会向你确认。",
                    defaultValue: "默认环境会用于聊天命令和测试。运行 AmberShell 前会向你确认。"
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
                    subtitle: embeddedIshAvailable
                        ? IOSAppLocalization.string(
                            "审批后可运行复杂非 PTY 脚本或异步 Job；外部 iSH 为手动交接",
                            defaultValue: "审批后可运行复杂非 PTY 脚本或异步 Job；外部 iSH 为手动交接"
                        )
                        : IOSAppLocalization.string(
                            "当前 target 未链接内置 iSH；外部 iSH 仅支持手动交接",
                            defaultValue: "当前 target 未链接内置 iSH；外部 iSH 仅支持手动交接"
                        ),
                    value: ishToolsSummary,
                    systemImage: "shippingbox",
                    accent: embeddedIshAvailable ? AmberTheme.accentGreen : AmberTheme.accentAmber
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
                ? "AmberShell、Remote SSH 与 iSH 使用各自能力闸门；AmberShell 始终逐次前台审批。"
                : "稳定 target 提供 Remote SSH 与 AmberShell；AmberShell 始终逐次前台审批，iSH 交接能力在下方单独说明。"
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
                RuntimeTextFieldRow(title: "Host", text: $sshProfileDraft.host, placeholder: "example.com", monospace: true)
                RuntimeDivider()
                RuntimeTextFieldRow(title: "端口", text: $sshPortDraft, placeholder: "22", monospace: true, keyboardType: .numberPad)
                RuntimeDivider()
                RuntimeTextFieldRow(title: "用户名", text: $sshProfileDraft.username, placeholder: "root", monospace: true)
                RuntimeDivider()
                RuntimeSecureFieldRow(title: "密码", text: $sshPasswordDraft, placeholder: "留空则不修改")
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
                    RuntimeActionRow(title: "清除密码", color: AmberTheme.accentRed) {
                        clearSSHPassword()
                    }
                }
            }
            .padding(.top, 10)

            Text("密码会保存在本机钥匙串。留空保存不会覆盖已存密码；新建 Profile 会清空表单，避免误覆盖。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
    }

    private var ishHandoffSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Agent iSH 工具")
            AmberFormGroup {
                RuntimeInfoRow(
                    title: "内置 iSH 执行",
                    subtitle: embeddedIshAvailable
                        ? "聊天中审批后调用 ios_ish_execute；可运行最多 32K 的非 PTY 脚本，前台回传结果，或异步返回 Job ID 供读取、等待和停止。"
                        : "当前 target 未链接 embedded iSH，不会向模型暴露 ios_ish_execute。",
                    value: embeddedIshAvailable ? "可回传" : "未链接",
                    systemImage: embeddedIshAvailable ? "shippingbox" : "lock",
                    accent: embeddedIshAvailable ? AmberTheme.accentGreen : AmberTheme.muted
                )
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
                        ? "Agent 启动执行与停止作业仍需逐次前台审批；异步 Job 没有 PTY 或 stdin，ExperimentalGPL 的持续 PTY 只由你直接操作。"
                        : "两条 iSH 链路都需要前台审批；外部 iSH 不回传结果，稳定 target 不链接内置 PTY。",
                    value: "每次审批",
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

            Text("异步只表示 Agent 不必阻塞等待，并非 iOS 后台常驻：App 重启会把未完成作业标记为已中断。AmberShell 与聊天共用 App 自有 /workspace；Remote SSH 的 cwd 与内置 iSH 的 /workspace 与其隔离，不会自动同步。")
                .runtimeFootnote()
        }
    }

    private var hostFingerprintSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Host 指纹信任")
            HostFingerprintCard(
                status: sshStatus,
                onTrust: trustSSHHost,
                onRetry: testSSHConnection
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
                "为 Remote SSH 添加 host、端口、用户名和密码",
                defaultValue: "为 Remote SSH 添加 host、端口、用户名和密码"
            )
        }
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = host.isEmpty
            ? IOSAppLocalization.string("Host 未填写", defaultValue: "Host 未填写")
            : "\(host):\(profile.port)"
        return user.isEmpty ? endpoint : "\(user)@\(endpoint)"
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
            return IOSAppLocalization.string("已信任", defaultValue: "已信任")
        case .failure:
            return IOSAppLocalization.string("异常", defaultValue: "异常")
        }
    }

    private var sshStatusAccent: Color {
        switch sshStatus {
        case .success:
            return AmberTheme.accentGreen
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
            let started = await IOSTerminalRuntime.shared.startJob(
                command: command,
                runtime: settingsStore.terminalDefaultRuntime,
                experimentalEnabled: settingsStore.terminalExperimentalRuntimesEnabled,
                sshProfile: settingsStore.defaultSSHProfile,
                sshPassword: settingsStore.defaultSSHProfile.flatMap { settingsStore.passwordForSSHProfile(id: $0.id) }
            )
            if started.status == IOSTerminalJobStatus.running.rawValue {
                terminalSmokeResult = await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 65)
                _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
            } else {
                terminalSmokeResult = started
            }
        }
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
        let password = profile.flatMap { settingsStore.passwordForSSHProfile(id: $0.id) }
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
            let started = await IOSTerminalRuntime.shared.startJob(
                command: validatedCommand,
                runtime: .remoteSSH,
                experimentalEnabled: false,
                workingDirectory: workingDirectory,
                sshProfile: profile,
                sshPassword: password,
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

    private func saveSSHProfile() {
        do {
            var draft = sshProfileDraft
            draft.port = Int(sshPortDraft) ?? 0
            let validated = try draft.validated()
            let isExistingProfile = settingsStore.sshProfiles.contains { $0.id == validated.id }
            try settingsStore.upsertSSHProfile(validated, password: nil)
            if sshPasswordDraft.isEmpty || sshPasswordDraft != loadedSSHPasswordDraft {
                settingsStore.clearSSHPassword(profileId: validated.id)
                loadedSSHPasswordDraft = ""
            }
            sshProfileDraft = validated
            sshPortDraft = String(validated.port)
            if !sshPasswordDraft.isEmpty && sshPasswordDraft != loadedSSHPasswordDraft {
                sshStatus = .success("SSH profile saved. Test SSH Connection to verify and save the password.")
            } else {
                sshStatus = .success(isExistingProfile ? "SSH profile saved." : "SSH profile saved. Test SSH Connection before running commands.")
            }
        } catch {
            sshStatus = .failure(error.localizedDescription)
        }
    }

    private func loadSSHProfile(_ profile: IOSSSHProfile) {
        sshProfileDraft = profile
        sshPortDraft = String(profile.port)
        sshPasswordDraft = settingsStore.passwordForSSHProfile(id: profile.id) ?? ""
        loadedSSHPasswordDraft = sshPasswordDraft
        sshStatus = .idle
    }

    private func testSSHConnection() {
        guard sharedSettings.isCapabilityGateEnabled(.remoteRuntime) else {
            sshStatus = .failure(IOSCapabilityGate.remoteRuntime.disabledReason)
            return
        }
        do {
            var draft = sshProfileDraft
            draft.port = Int(sshPortDraft) ?? 0
            let profile = try draft.validated()
            guard !sshPasswordDraft.isEmpty else { throw IOSSSHError.missingPassword }

            sshStatus = .testing
            Task {
                do {
                    let result = try await IOSTerminalRuntime.shared.testSSHConnection(
                        profile: profile,
                        password: sshPasswordDraft
                    )
                    switch result.trustState {
                    case .trusted:
                        guard await verifySSHPassword(profile: profile, password: sshPasswordDraft) else {
                            settingsStore.clearSSHPassword(profileId: profile.id)
                            sshStatus = .failure("Host trusted, but password authentication failed. Check the password and try again.")
                            return
                        }
                        try settingsStore.upsertSSHProfile(profile, password: sshPasswordDraft)
                        loadedSSHPasswordDraft = sshPasswordDraft
                        sshStatus = .success("SSH host trusted and password verified.")
                    case .needsTrust(let fingerprint):
                        try settingsStore.upsertSSHProfile(profile, password: nil)
                        settingsStore.clearSSHPassword(profileId: profile.id)
                        sshStatus = .needsTrust(profileId: profile.id, fingerprint: fingerprint)
                    case .mismatch(let expected, let actual):
                        sshStatus = .failure("Host fingerprint mismatch. Expected \(expected), got \(actual).")
                    }
                } catch {
                    sshStatus = .failure(error.localizedDescription)
                }
            }
        } catch {
            sshStatus = .failure(error.localizedDescription)
        }
    }

    private func trustSSHHost() {
        guard case .needsTrust(let profileId, let fingerprint) = sshStatus else { return }
        do {
            try settingsStore.trustHost(profileId: profileId, fingerprint: fingerprint)
            guard let profile = settingsStore.sshProfiles.first(where: { $0.id == profileId }) else {
                throw IOSSSHError.invalidProfile("SSH profile was not found.")
            }
            sshProfileDraft = profile
            guard !sshPasswordDraft.isEmpty else {
                settingsStore.clearSSHPassword(profileId: profileId)
                sshStatus = .success("Host trusted. Add a password before running remote SSH commands.")
                return
            }
            sshStatus = .testing
            Task {
                guard await verifySSHPassword(profile: profile, password: sshPasswordDraft) else {
                    settingsStore.clearSSHPassword(profileId: profileId)
                    sshStatus = .failure("Host trusted, but password authentication failed. Check the password and try again.")
                    return
                }
                do {
                    try settingsStore.upsertSSHProfile(profile, password: sshPasswordDraft)
                    loadedSSHPasswordDraft = sshPasswordDraft
                    sshStatus = .success("Host trusted and password verified. Remote SSH commands can now run.")
                } catch {
                    sshStatus = .failure(error.localizedDescription)
                }
            }
        } catch {
            sshStatus = .failure(error.localizedDescription)
        }
    }

    private func verifySSHPassword(profile: IOSSSHProfile, password: String) async -> Bool {
        guard sharedSettings.isCapabilityGateEnabled(.remoteRuntime) else { return false }
        let started = await IOSTerminalRuntime.shared.startJob(
            command: "echo amber-terminal-auth-check",
            runtime: .remoteSSH,
            experimentalEnabled: false,
            sshProfile: profile,
            sshPassword: password,
            timeoutSeconds: 15
        )
        let finished = started.status == IOSTerminalJobStatus.running.rawValue
            ? await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 20)
            : started
        let succeeded = finished?.status == IOSTerminalJobStatus.completed.rawValue && finished?.exitCode == 0
        _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
        return succeeded
    }

    private func resetSSHProfileDraft() {
        sshProfileDraft = IOSSSHProfile()
        sshPasswordDraft = ""
        loadedSSHPasswordDraft = ""
        sshPortDraft = "22"
        sshStatus = .idle
    }

    private func clearSSHPassword() {
        settingsStore.clearSSHPassword(profileId: sshProfileDraft.id)
        sshPasswordDraft = ""
        loadedSSHPasswordDraft = ""
        sshStatus = .success("SSH password cleared.")
    }
}

private struct RuntimeSheetChrome<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        AmberGlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭", size: 44, symbolSize: 15) {
                            dismiss()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                    .padding(.bottom, 4)

                    content
                }
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct RuntimeStatusCard: View {
    let defaultRuntime: IOSTerminalRuntimeKind
    let sshProfileName: String?
    let embeddedIshAvailable: Bool
    let externalIshAvailable: Bool
    let experimentalRuntimesLinked: Bool
    let experimentalEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AmberTheme.accentTint, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("当前执行策略")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(strategySummary)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("默认", defaultValue: "默认"),
                    value: defaultRuntime.displayName,
                    color: AmberTheme.accent
                )
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("内置 iSH", defaultValue: "内置 iSH"),
                    value: embeddedIshAvailable
                        ? IOSAppLocalization.string("可回传", defaultValue: "可回传")
                        : IOSAppLocalization.string("未链接", defaultValue: "未链接"),
                    color: embeddedIshAvailable ? AmberTheme.accentGreen : AmberTheme.muted
                )
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("外部 iSH", defaultValue: "外部 iSH"),
                    value: externalIshAvailable
                        ? IOSAppLocalization.string("交接", defaultValue: "交接")
                        : IOSAppLocalization.string("不可用", defaultValue: "不可用"),
                    color: externalIshAvailable ? AmberTheme.accentAmber : AmberTheme.muted
                )
            }
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private var strategySummary: String {
        let profile = sshProfileName
            ?? IOSAppLocalization.string(
                "未选择 SSH Profile",
                defaultValue: "未选择 SSH Profile"
            )
        let experimental: String
        if !experimentalRuntimesLinked {
            experimental = IOSAppLocalization.string(
                "当前构建未链接实验 Runtime",
                defaultValue: "当前构建未链接实验 Runtime"
            )
        } else {
            experimental = experimentalEnabled
                ? IOSAppLocalization.string(
                    "实验 Runtime 已显示",
                    defaultValue: "实验 Runtime 已显示"
                )
                : IOSAppLocalization.string(
                    "实验 Runtime 已隐藏",
                    defaultValue: "实验 Runtime 已隐藏"
                )
        }
        return IOSAppLocalization.formatted(
            "%@ · %@。聊天中的 iSH 工具会单独走前台审批。",
            defaultValue: "%@ · %@。聊天中的 iSH 工具会单独走前台审批。",
            arguments: [profile, experimental]
        )
    }
}

private struct RuntimeStatusMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RuntimeChoiceRow: View {
    let runtime: IOSTerminalRuntimeKind
    let isSelected: Bool
    let isEnabled: Bool
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: runtimeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isEnabled ? runtimeColor : AmberTheme.muted2)
                    .frame(width: 30, height: 30)
                    .background((isEnabled ? runtimeColor : AmberTheme.muted2).opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(runtime.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isEnabled ? AmberTheme.foreground : AmberTheme.muted2)
                        if isRecommended {
                            RuntimePill(
                                text: IOSAppLocalization.string("推荐", defaultValue: "推荐"),
                                color: AmberTheme.accent
                            )
                        }
                        RuntimePill(
                            text: runtimeTier == .stable
                                ? IOSAppLocalization.string("稳定", defaultValue: "稳定")
                                : IOSAppLocalization.string("实验", defaultValue: "实验"),
                            color: runtimeTier == .stable ? AmberTheme.accentGreen : AmberTheme.accentAmber
                        )
                        if !isEnabled {
                            RuntimePill(
                                text: IOSAppLocalization.string("未启用", defaultValue: "未启用"),
                                color: AmberTheme.muted
                            )
                        }
                    }

                    Text(runtimeSummary)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AmberTheme.accent)
                }
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: isEnabled ? 0.985 : 1, haptic: isEnabled ? .selection : nil))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
    }

    private var runtimeTier: IOSTerminalRuntimeTier {
        IOSTerminalRuntimeCapabilities.capability(for: runtime).tier
    }

    private var runtimeSummary: String {
        switch runtime {
        case .remoteSSH:
            return "稳定远程命令主线；需要 SSH Profile、密码和 Host 信任"
        case .localIOSTools:
            #if ENABLE_AMBERSHELL_PYTHON
            return IOSAppLocalization.string(
                "稳定版 AmberShell；受限文件/文本命令、管道、重定向与 CPython 3.14 python -c，无 PTY",
                defaultValue: "稳定版 AmberShell；受限文件/文本命令、管道、重定向与 CPython 3.14 python -c，无 PTY"
            )
            #else
            return IOSAppLocalization.string(
                "AmberShell 文件/文本命令、管道与重定向；ExperimentalGPL 不链接 CPython，无 PTY",
                defaultValue: "AmberShell 文件/文本命令、管道与重定向；ExperimentalGPL 不链接 CPython，无 PTY"
            )
            #endif
        case .remoteMosh:
            return "预留的移动会话方向；当前不建议作为默认环境"
        case .ishExperimental:
            return "内置 iSH 短命令 runner；无 PTY、stdin 和长会话"
        }
    }

    private var runtimeIcon: String {
        switch runtime {
        case .remoteSSH: "desktopcomputer"
        case .localIOSTools: "iphone"
        case .remoteMosh: "antenna.radiowaves.left.and.right"
        case .ishExperimental: "shippingbox"
        }
    }

    private var runtimeColor: Color {
        switch runtime {
        case .remoteSSH: AmberTheme.accent
        case .localIOSTools: AmberTheme.accentGreen
        case .remoteMosh: AmberTheme.accentCyan
        case .ishExperimental: AmberTheme.accentAmber
        }
    }
}

private struct RuntimeToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isEnabled ? AmberTheme.foreground : AmberTheme.muted2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RuntimeSwitch(isOn: isOn)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityValue(isOn ? "开启" : "关闭")
    }
}

private struct RuntimeNavigationRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var accent: Color = AmberTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted2)
                }
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
    }
}

private struct RuntimeValueRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct RuntimeInfoRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var accent: Color = AmberTheme.accentAmber

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct TerminalTaskRow: View {
    let task: IOSAdvancedTaskRecord
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.commandPreview.isEmpty ? task.title : task.commandPreview)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(task.status.title) · \(task.connectionSummary)\n\(summary)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 62)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch task.status {
        case .completed: "checkmark.circle.fill"
        case .failed, .timedOut, .interrupted: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        default: "terminal.fill"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        default: AmberTheme.accentAmber
        }
    }

    private var summary: String {
        if task.status == .running, !task.logTail.isEmpty {
            return task.logTail
        }
        return task.compactSummary
    }
}

private struct RuntimeTextFieldRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var monospace = false
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(monospace ? .system(.subheadline, design: .monospaced) : .body)
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct RuntimeSecureFieldRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            SecureField(placeholder, text: $text)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct RuntimeActionRow: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
    }
}

private struct RuntimeDivider: View {
    var body: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, 14)
    }
}

private struct SmokeResultCard: View {
    let result: IOSTerminalJobSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(result.runtime.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                RuntimePill(
                    text: IOSTerminalJobStatus(rawValue: result.status)?.title ?? result.status,
                    color: statusColor
                )
            }

            Text("退出码 \(result.exitCode.map(String.init) ?? "…")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)

            if !result.outputTail.isEmpty {
                Text(result.outputTail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }

            if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }

    private var statusColor: Color {
        switch IOSTerminalJobStatus(rawValue: result.status) {
        case .completed: AmberTheme.accentGreen
        case .queued, .running: AmberTheme.accentAmber
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        case nil: AmberTheme.accent
        }
    }
}

private struct TerminalTaskDetailView: View {
    @Bindable var taskStore: IOSAdvancedTaskStore
    let taskId: String

    var body: some View {
        RuntimeSheetChrome(
            title: taskStore.task(id: taskId)?.kind == .embeddedIsh ? "内置 iSH Agent 作业" : "Remote SSH 作业",
            subtitle: "进程内作业会保留状态与输出尾部；应用重启后未完成作业会如实标记为已中断。"
        ) {
            if let task = taskStore.task(id: taskId) {
                VStack(spacing: 12) {
                    AmberFormGroup {
                        RemoteTaskDetailRow(title: "状态", value: task.status.title, color: statusColor(task.status))
                        RuntimeDivider()
                        RemoteTaskDetailRow(
                            title: task.kind == .embeddedIsh ? "运行环境" : "连接",
                            value: task.connectionSummary
                        )
                        if let workingDirectory = task.metadata["cwd"]?.nilIfBlank {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "工作目录", value: workingDirectory, monospaced: true)
                        }
                        if let timeout = task.metadata["command_timeout_seconds"]?.nilIfBlank {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "超时", value: "\(timeout) 秒")
                        }
                        if task.kind == .embeddedIsh {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "模式", value: "异步非 PTY · 无 stdin")
                        }
                        RuntimeDivider()
                        RemoteTaskDetailRow(title: "Job ID", value: task.id, monospaced: true)
                    }

                    RemoteTaskTextCard(title: "命令", text: task.commandPreview)
                    if !task.logTail.isEmpty {
                        RemoteTaskTextCard(title: "输出尾部", text: task.logTail)
                    }
                    if let stderr = task.metadata["stderr_tail"]?.nilIfBlank {
                        RemoteTaskTextCard(title: "stderr 尾部", text: stderr, isError: true)
                    }
                    if !task.error.isEmpty {
                        Text(task.error)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 16)
            } else {
                Text("该作业记录已不存在。")
                    .font(.body)
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func statusColor(_ status: IOSAdvancedTaskStatus) -> Color {
        switch status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        case .queued, .running, .approvalRequired: AmberTheme.accentAmber
        }
    }
}

private struct RemoteTaskDetailRow: View {
    let title: String
    let value: String
    var color: Color = AmberTheme.foreground2
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote.weight(.semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct RemoteTaskTextCard: View {
    let title: String
    let text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(isError ? AmberTheme.accentRed : AmberTheme.foreground2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }
}

private struct HostFingerprintCard: View {
    let status: RuntimeEnvironmentView.SSHStatus
    let onTrust: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status {
            case .idle:
                FingerprintTitle(systemImage: "checkmark.shield", title: "尚未验证 Host 指纹", color: AmberTheme.foreground)
                Text("连接前需检查服务器可达性与 host key 指纹。未信任或指纹不匹配时不会发送密码。")
                    .fingerprintDescription()
            case .testing:
                FingerprintTitle(systemImage: "arrow.triangle.2.circlepath", title: "正在连接并获取 host key...", color: AmberTheme.foreground)
                Text("读取服务器公钥的 SHA256 指纹，请稍候。")
                    .fingerprintDescription()
            case .needsTrust(_, let fingerprint):
                FingerprintTitle(systemImage: "exclamationmark.triangle", title: "首次连接此 Host", color: AmberTheme.accentAmber)
                FingerprintHash(label: "SERVER KEY · SHA256", value: fingerprint)
                Text("确认这是你信任的服务器后，显式点击「信任此 Host」才会保存指纹。")
                    .fingerprintDescription()
                HStack {
                    Button {
                        onTrust()
                    } label: {
                        Label("信任此 Host", systemImage: "checkmark")
                    }
                    .buttonStyle(RuntimeFilledButtonStyle())
                    Button("取消", action: onRetry)
                        .buttonStyle(RuntimeGlassButtonStyle())
                }
            case .success(let message):
                FingerprintTitle(systemImage: "checkmark.shield", title: "Host 已信任", color: AmberTheme.accentGreen)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentGreen)
            case .failure(let message):
                FingerprintTitle(systemImage: "xmark.shield", title: "Host 指纹不匹配或连接失败", color: AmberTheme.accentRed)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(cardStroke, lineWidth: isFailure ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
    }

    private var isFailure: Bool {
        if case .failure = status {
            return true
        }
        return false
    }

    private var cardBackground: Color {
        isFailure ? AmberTheme.accentRed.opacity(0.05) : AmberTheme.surface
    }

    private var cardStroke: Color {
        isFailure ? AmberTheme.accentRed : AmberTheme.borderSoft
    }
}

private struct RuntimeMatrixCard: View {
    let capability: IOSTerminalRuntimeCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(capability.runtime.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                RuntimePill(text: capability.tier.displayName, color: capability.tier == .stable ? AmberTheme.accentGreen : AmberTheme.muted)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                RuntimeCapabilityLine(title: "外部 CLI", state: capability.supportsExternalCLIByDefault)
                RuntimeCapabilityLine(title: "PTY", state: capability.supportsPTY)
                RuntimeCapabilityLine(title: "安装软件", state: capability.supportsPackageInstall)
                RuntimeCapabilityLine(title: "长任务", state: capability.supportsLongRunningJobs)
                RuntimeCapabilityLine(title: "交互登录", state: capability.supportsInteractiveLogin)
                RuntimeCapabilityLine(title: "文件同步", state: capability.supportsFileSync)
                RuntimeCapabilityLine(title: "上架安全", state: capability.appStoreSafeByDefault)
            }

            Text("License: \(capability.licenseClass.displayName)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }
}

private struct RuntimeCapabilityLine: View {
    let title: String
    let state: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(state ? AmberTheme.accentGreen : AmberTheme.muted2)
            Text(title)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(state ? "支持" : "不支持")
    }
}

private struct FingerprintTitle: View {
    let systemImage: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
    }
}

private struct FingerprintHash: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted2)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RuntimePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct RuntimeSwitch: View {
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

private struct RuntimeFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .padding(.horizontal, 18)
            .background(AmberTheme.accent, in: Capsule())
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
    }
}

private struct RuntimeGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .frame(minHeight: 44)
            .padding(.horizontal, 18)
            .background(AmberTheme.glass, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.65), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
    }
}

private extension Text {
    func fingerprintDescription() -> some View {
        self
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .lineSpacing(2)
    }

    func runtimeFootnote() -> some View {
        self
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }
}
