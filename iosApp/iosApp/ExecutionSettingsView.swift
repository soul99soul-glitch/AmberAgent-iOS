import SwiftUI
import Shared

struct ExecutionSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    var focusedTaskID: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    @AppStorage(IOSExecutionPreferenceKeys.liveActivity) private var liveActivity = true
#if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    @AppStorage(IOSExecutionPreferenceKeys.audioKeepAlive) private var audioKeepAlive = true
    @AppStorage(IOSExecutionPreferenceKeys.backgroundLocationKeepAlive)
    private var backgroundLocationKeepAlive = false
#endif
    @AppStorage(IOSExecutionPreferenceKeys.chatMaxToolResumeCount)
    private var chatMaxToolResumeCount = SettingsStore.defaultChatMaxToolResumeCount
    @AppStorage(IOSExecutionPreferenceKeys.execJavaScriptEnabled)
    private var execJavaScriptEnabled = false
    @State private var taskStore = IOSAdvancedTaskStore.shared
    @State private var isToolLoopPickerPresented = false
    @State private var isJevSettingsPresented = false
    @State private var locationStatusRevision = 0
    @Namespace private var toolLoopTransition
    @ScaledMetric(relativeTo: .body) private var toolLoopValueWidth: CGFloat = 44

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        if focusedTaskID != nil {
                            recentTasksSection
                        }
                        runSection
                        toolLoopSection
                        execJavaScriptSection
                        jevSection
                        if focusedTaskID == nil {
                            recentTasksSection
                        }
                        liveActivitySection
#if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
                        backgroundKeepAliveSection
#endif
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isToolLoopPickerPresented) {
            toolLoopPicker
                .presentationDetents([.height(480), .large])
                .presentationDragIndicator(.visible)
                .navigationTransition(.zoom(sourceID: "toolLoopPicker", in: toolLoopTransition))
        }
        .sheet(isPresented: $isJevSettingsPresented) {
            IOSJevSettingsView(sharedSettings: sharedSettings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberBackgroundLocationKeepAliveChanged)) { _ in
            locationStatusRevision &+= 1
        }
    }

    private var toolLoopPicker: some View {
        VStack(spacing: 0) {
            Text("单轮上限")
                .font(.headline)
                .padding(.vertical, 20)

            ForEach(SettingsStore.chatMaxToolResumeCountOptions, id: \.self) { option in
                Button {
                    chatMaxToolResumeCount = option
                    isToolLoopPickerPresented = false
                } label: {
                    HStack {
                        Text("\(option) 次")
                        Spacer()
                        if option == SettingsStore.clampChatMaxToolResumeCount(chatMaxToolResumeCount) {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == SettingsStore.clampChatMaxToolResumeCount(chatMaxToolResumeCount) ? .isSelected : [])
            }

            Button("取消", role: .cancel) {
                isToolLoopPickerPresented = false
            }
            .buttonStyle(.glass)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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
        .padding(.bottom, 18)
    }

    private var runSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "环境配置")
            AmberFormGroup {
                ExecutionNavigationRow(
                    systemImage: "terminal",
                    title: IOSAppLocalization.string(
                        "Runtime 与任务",
                        defaultValue: "Runtime 与任务"
                    ),
                    subtitle: IOSAppLocalization.string(
                        "默认 Runtime、Remote SSH、iSH 工具与任务记录",
                        defaultValue: "默认 Runtime、Remote SSH、iSH 工具与任务记录"
                    )
                ) {
                    router.navigate(to: .sandbox)
                }
            }
        }
    }

    private var toolLoopSection: some View {
        let clampedCount = SettingsStore.clampChatMaxToolResumeCount(chatMaxToolResumeCount)
        return VStack(spacing: 0) {
            AmberSectionLabel(text: "工具循环")
            AmberFormGroup {
                Button {
                    isToolLoopPickerPresented = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("单轮上限")
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text("达到后自动总结收尾")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // 数字列与箭头宽度固定；24 切到 384 时整行尺寸不变。
                        HStack(spacing: 8) {
                            Text("\(clampedCount)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                                .frame(width: toolLoopValueWidth, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AmberTheme.muted2)
                                .frame(width: 12)
                        }
                    }
                    .frame(minHeight: 58)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                .matchedTransitionSource(id: "toolLoopPicker", in: toolLoopTransition)
                .accessibilityLabel("单轮工具循环上限")
                .accessibilityValue("\(clampedCount) 次")
                .accessibilityHint("打开可选次数面板")
            }
        }
    }

    private var execJavaScriptSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "脚本执行")
            AmberFormGroup {
                ExecutionToggleRow(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    title: IOSAppLocalization.string(
                        "JavaScript 沙箱执行",
                        defaultValue: "JavaScript 沙箱执行"
                    ),
                    subtitle: IOSAppLocalization.string(
                        "允许模型用 exec 工具运行隔离的 JavaScript（默认关闭；无网络、无文件访问）",
                        defaultValue: "允许模型用 exec 工具运行隔离的 JavaScript（默认关闭；无网络、无文件访问）"
                    ),
                    isOn: execJavaScriptEnabled
                ) {
                    execJavaScriptEnabled.toggle()
                }
            }
        }
    }

    private var jevSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "快速判断")
            AmberFormGroup {
                Button {
                    isJevSettingsPresented = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.badge.clock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(IOSAppLocalization.string("Jev 快速判断", defaultValue: "Jev 快速判断"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(IOSAppLocalization.string(
                                "工具发现与记忆召回的语义评分（默认关闭）",
                                defaultValue: "工具发现与记忆召回的语义评分（默认关闭）"
                            ))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
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
                .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                .accessibilityLabel("Jev 快速判断设置")
            }
        }
    }

    private var liveActivitySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "灵动岛")
            AmberFormGroup {
                ExecutionToggleRow(
                    systemImage: "capsule",
                    title: IOSAppLocalization.string(
                        "聊天灵动岛实时活动",
                        defaultValue: "聊天灵动岛实时活动"
                    ),
                    isOn: liveActivity
                ) {
                    liveActivity.toggle()
                    if !liveActivity {
                        Task {
                            await AgentLiveActivityController.shared.stopCurrent()
                        }
                    }
                }

            }
        }
    }

#if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    private var backgroundKeepAliveSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "后台续跑")
            AmberFormGroup {
                ExecutionToggleRow(
                    systemImage: "waveform",
                    title: IOSAppLocalization.string(
                        "音频保活",
                        defaultValue: "音频保活"
                    ),
                    subtitle: IOSAppLocalization.string(
                        "静音播放；任务结束后后台最多保留 60 秒衔接；系统播报期间让出音频。",
                        defaultValue: "静音播放；任务结束后后台最多保留 60 秒衔接；系统播报期间让出音频。"
                    ),
                    isOn: audioKeepAlive
                ) {
                    audioKeepAlive.toggle()
                    BackgroundGenerationKeepAlive.shared.refreshAudioKeepAlive()
                }

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 58)

                let locationKeepAlive = BackgroundLocationKeepAlive.shared
                ExecutionToggleRow(
                    systemImage: "location.fill",
                    title: IOSAppLocalization.string(
                        "定位保活",
                        defaultValue: "定位保活"
                    ),
                    subtitle: locationKeepAlive.statusText,
                    isOn: backgroundLocationKeepAlive
                ) {
                    backgroundLocationKeepAlive.toggle()
                    if backgroundLocationKeepAlive {
                        locationKeepAlive.requestEnable()
                    } else {
                        locationKeepAlive.refreshPreference()
                    }
                }
                .id(locationStatusRevision)
            }
            Text("定位保活需主动授权；不记录或上传位置。任务期间会显示系统定位标志，并可能增加耗电。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
            if backgroundLocationKeepAlive,
               BackgroundLocationKeepAlive.shared.authorizationStatus == .denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(AmberTheme.accent)
                .frame(minHeight: 44)
            }
        }
    }
#endif

    private var recentTasksSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "最近任务")
            AmberFormGroup {
                let recent = taskStore.recent(limit: 6)
                let focusedTask = focusedTaskID.flatMap { taskStore.task(id: $0) }
                let tasks = focusedTask.map { focused in
                    [focused] + Array(recent.filter { $0.id != focused.id }.prefix(5))
                } ?? recent
                if tasks.isEmpty {
                    Text("暂无高级执行任务。SubAgent、模型议会和远程命令运行后会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        ExecutionTaskRow(task: task, isFocused: task.id == focusedTaskID)
                        if index < tasks.count - 1 {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

}

private struct ExecutionTaskRow: View {
    let task: IOSAdvancedTaskRecord
    var isFocused = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text("\(task.kind.title) · \(task.compactSummary)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(task.status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isFocused ? AmberTheme.accent.opacity(0.09) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isFocused ? "由快捷指令打开的任务" : "")
    }

    private var iconName: String {
        switch task.kind {
        case .subAgent: "person.2.wave.2.fill"
        case .modelCouncil: "bubble.left.and.bubble.right.fill"
        case .remoteCommand: "terminal.fill"
        case .embeddedIsh: "shippingbox.fill"
        case .toolApproval: "hand.raised.fill"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        case .approvalRequired: AmberTheme.accentAmber
        default: AmberTheme.accent
        }
    }
}

private struct ExecutionNavigationRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

private struct ExecutionToggleRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ExecutionSwitch(isOn: isOn)
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            isOn
                ? IOSAppLocalization.string("已开启", defaultValue: "已开启")
                : IOSAppLocalization.string("已关闭", defaultValue: "已关闭")
        )
        .accessibilityHint(
            IOSAppLocalization.string("双击切换", defaultValue: "双击切换")
        )
    }
}

private struct ExecutionSwitch: View {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isOn)
    }
}
