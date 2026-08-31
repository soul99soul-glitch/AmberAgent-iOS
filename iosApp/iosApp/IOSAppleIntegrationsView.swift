import SwiftUI

@MainActor
struct IOSAppleIntegrationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(IOSAppleIntegrationPreferenceKeys.completionNotificationsEnabled)
    private var completionNotificationsEnabled = false
    @State private var isRequestingNotifications = false
    @State private var notificationRequestRevision = 0
    @State private var reminderTitle = ""
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var reminderMessage: String?
    @State private var backendCoordinator = IOSBackendServicesCoordinator.shared

    private let notificationService: IOSLocalNotificationService

    init(
        systemPermissionCoordinator: IOSSystemPermissionCoordinator,
        notificationService: IOSLocalNotificationService? = nil
    ) {
        self.notificationService = notificationService
            ?? IOSLocalNotificationService(permissionCoordinator: systemPermissionCoordinator)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        capabilitySection
                        notificationSection
                        reminderSection
                        shortcutSection
                        backendSection
                        linkSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer()
            Text("Apple 集成")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var capabilitySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "设备能力")
            AmberFormGroup {
                integrationNavigationRow(
                    title: "健康摘要",
                    subtitle: "本机只读步数，不进入模型或同步",
                    icon: "heart.text.clipboard"
                ) { router.navigate(to: .healthSummary) }
                Divider().overlay(AmberTheme.borderSoft).padding(.leading, 56)
                integrationNavigationRow(
                    title: "WeatherKit 天气",
                    subtitle: "城市查询或按需读取当前位置",
                    icon: "cloud.sun"
                ) { router.navigate(to: .weather) }
            }
        }
    }

    private var notificationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "本地通知")
            AmberFormGroup {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("后台任务完成通知")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("只在 App 不活跃且本机任务结束时提醒；不使用远程推送。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isRequestingNotifications {
                        ProgressView()
                            .tint(AmberTheme.accent)
                            .accessibilityLabel("正在请求通知权限")
                            .accessibilityHint("系统权限确认完成后会更新后台任务通知开关")
                    } else {
                        Toggle("", isOn: Binding(
                            get: { completionNotificationsEnabled },
                            set: { updateCompletionNotifications($0) }
                        ))
                        .labelsHidden()
                        .tint(AmberTheme.accent)
                        .accessibilityLabel("后台任务完成通知")
                        .accessibilityHint("只在 Amber 不活跃且本机任务完成时发送本地通知")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var reminderSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "一次提醒")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("提醒标题（可选）", text: $reminderTitle)
                        .textFieldStyle(.plain)
                    Divider().overlay(AmberTheme.borderSoft)
                    reminderDatePicker
                    reminderActions

                    if let reminderMessage {
                        Text(reminderMessage)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private var reminderDatePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("提醒时间")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                DatePicker(
                    "提醒时间",
                    selection: $reminderDate,
                    in: Date().addingTimeInterval(5)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
        } else {
            DatePicker(
                "提醒时间",
                selection: $reminderDate,
                in: Date().addingTimeInterval(5)...,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    @ViewBuilder
    private var reminderActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                cancelReminderButton.frame(maxWidth: .infinity)
                scheduleReminderButton.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                cancelReminderButton
                scheduleReminderButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var cancelReminderButton: some View {
        Button("取消待发提醒") {
            notificationService.cancelManualReminder()
            reminderMessage = "已取消待发提醒。"
        }
        .buttonStyle(.bordered)
        .tint(AmberTheme.muted)
    }

    private var scheduleReminderButton: some View {
        Button("安排提醒") {
            Task { await scheduleReminder() }
        }
        .buttonStyle(.borderedProminent)
        .tint(AmberTheme.accent)
    }

    private var shortcutSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Siri 与快捷指令")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Label("新建 Amber 对话", systemImage: "square.and.pencil")
                    Label("继续最近对话", systemImage: "bubble.left.and.bubble.right")
                    Label("打开当前任务", systemImage: "bolt.horizontal.circle")
                    Text("安装后可在“快捷指令”App、Siri 和系统搜索中使用。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var linkSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "链接")
            AmberFormGroup {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "link")
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("通用链接尚未配置")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("当前使用受控的 amber:// 回退路由。只有配置真实 HTTPS 域名与 AASA 文件后才会启用 Associated Domains。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var backendSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "远程服务边界")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if backendCoordinator.isConfigured {
                        Label("HTTPS 后端已配置", systemImage: "server.rack")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        if let host = backendCoordinator.configuredHost {
                            Text(host)
                                .font(.caption.monospaced())
                                .foregroundStyle(AmberTheme.muted)
                                .textSelection(.enabled)
                        }

                        Divider().overlay(AmberTheme.borderSoft)

                        backendStatusRow(
                            title: "远程推送",
                            icon: "bell.and.waves.left.and.right",
                            state: backendCoordinator.pushState
                        )
                        Button("注册 APNs") {
                            backendCoordinator.startPushRegistration()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!backendCoordinator.canRegisterPush || isWorking(backendCoordinator.pushState))

                        Divider().overlay(AmberTheme.borderSoft)

                        backendStatusRow(
                            title: "App Attest",
                            icon: "checkmark.shield",
                            state: backendCoordinator.appAttestState
                        )
                        Button("验证此设备") {
                            Task { await backendCoordinator.attestDevice() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!backendCoordinator.canAttestDevice || isWorking(backendCoordinator.appAttestState))
                    } else {
                        Label("HTTPS 后端未配置", systemImage: "server.rack")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("Amber 不会注册 APNs、上传设备令牌或生成 App Attest 标识。配置受信任的 HTTPS 后端后，这两条链路才会开放。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private func backendStatusRow(
        title: String,
        icon: String,
        state: IOSBackendServiceState
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(backendStateMessage(state))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isWorking(state) {
                ProgressView().tint(AmberTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func backendStateMessage(_ state: IOSBackendServiceState) -> String {
        switch state {
        case .unavailable(let message), .working(let message), .ready(let message), .failed(let message):
            message
        case .idle:
            "尚未开始"
        }
    }

    private func isWorking(_ state: IOSBackendServiceState) -> Bool {
        if case .working = state { return true }
        return false
    }

    private func integrationNavigationRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(AmberTheme.foreground)
                    Text(subtitle).font(.caption).foregroundStyle(AmberTheme.muted)
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
        .buttonStyle(.plain)
    }

    private func updateCompletionNotifications(_ enabled: Bool) {
        guard enabled else {
            notificationRequestRevision &+= 1
            isRequestingNotifications = false
            completionNotificationsEnabled = false
            Task { await notificationService.cancelTaskCompletionNotifications() }
            return
        }
        guard !isRequestingNotifications else { return }
        notificationRequestRevision &+= 1
        let revision = notificationRequestRevision
        isRequestingNotifications = true
        Task {
            let granted = await notificationService.requestAuthorization()
            guard revision == notificationRequestRevision else { return }
            completionNotificationsEnabled = granted
            isRequestingNotifications = false
        }
    }

    private func scheduleReminder() async {
        if await notificationService.authorization() != .allowed,
           await notificationService.requestAuthorization() == false {
            reminderMessage = "通知权限未开启，未安排提醒。"
            return
        }
        do {
            switch try await notificationService.scheduleManualReminder(
                title: reminderTitle,
                fireDate: reminderDate
            ) {
            case .scheduled:
                reminderMessage = "提醒已安排；重新安排会替换上一条。"
            case .notAuthorized:
                reminderMessage = "通知权限未开启，未安排提醒。"
            case .invalidDate:
                reminderMessage = "请选择至少 5 秒后的时间。"
            }
        } catch {
            reminderMessage = "安排失败：\(error.localizedDescription)"
        }
    }
}
