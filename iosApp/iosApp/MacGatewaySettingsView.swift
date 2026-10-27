import SwiftUI

struct MacGatewaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var confirmsUnpair = false
    @State private var creatingSchedule = false
    @State private var showsEndedTasks = false

    private let store = MacGatewayStore.shared
    private static let refreshInterval: Duration = .seconds(10)
    private static let visibleTaskLimit = 20

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        if let pending = store.pendingPairing {
                            confirmSection(pending)
                        } else if let connection = store.connection {
                            macSection(connection)
                            if let health = store.status?.health { healthSection(health) }
                            tasksSection
                            schedulesSection
                            unpairSection
                        } else {
                            pairSection
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task(id: store.connection?.gatewayId) {
            guard store.connection != nil else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .sheet(isPresented: $creatingSchedule) { MacGatewayScheduleSheet(store: store) }
        .confirmationDialog(L("取消与这台 Mac 的配对？"), isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button(L("取消配对"), role: .destructive) { Task { await store.unpair() } }
            Button(L("保留"), role: .cancel) {}
        } message: {
            Text(verbatim: L("此设备将不再收到这台 Mac 的推送。"))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: "Mac Gateway")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    // MARK: - Not paired

    private var pairSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "配对")
            AmberFormGroup {
                settingsRow(icon: "qrcode.viewfinder", title: L("扫码配对"),
                            detail: L("在 Mac 终端运行 amber-gateway pair，用系统相机扫描")) {
                    EmptyView()
                }
                rowDivider
                settingsRow(icon: "doc.on.clipboard", title: L("粘贴配对链接"),
                            detail: L("从 AirDrop 或消息复制的 amber:// 链接"),
                            action: { store.pasteLinkFromClipboard() }) {
                    chevron
                }
            }
            noticeFooter(fallback: L("把 Mac 上 Claude Code / Codex 任务的状态推送到手机。推送只含项目名与状态，不含代码与对话内容。"))
        }
    }

    private func confirmSection(_ payload: MacGatewayPairingPayload) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "确认配对")
            AmberFormGroup {
                settingsRow(icon: "desktopcomputer", title: payload.name, detail: payload.addrs.joined(separator: " · ")) {
                    EmptyView()
                }
                rowDivider
                settingsRow(icon: "checkmark.shield", title: L("证书指纹"), detail: payload.fp) {
                    EmptyView()
                }
            }
            sectionFooter(L("请核对与 Mac 终端显示的证书指纹一致。"))
            AmberFormGroup {
                actionRow(L("配对"), color: AmberTheme.accent, isBusy: store.isBusy) {
                    Task { await store.confirmPairing() }
                }
                Divider().overlay(AmberTheme.borderSoft)
                actionRow(L("取消"), color: AmberTheme.muted, isBusy: false) {
                    store.pendingPairing = nil
                }
                .disabled(store.isBusy)
            }
            .padding(.top, 20)
            noticeFooter(fallback: nil)
        }
    }

    // MARK: - Paired

    private func macSection(_ connection: MacGatewayConnection) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac")
            AmberFormGroup {
                settingsRow(icon: "desktopcomputer", title: connection.name, detail: reachabilityText) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityLabel(Text(verbatim: L("刷新")))
                }
                rowDivider
                settingsRow(icon: "bell.badge", title: L("推送通知"), detail: pushDetail) {
                    if store.isSendingTestPush {
                        ProgressView().frame(width: 44, height: 44)
                    } else if store.status?.device.pushRegistered == true {
                        capsuleButton(L("测试")) { Task { await store.sendTestPush() } }
                    } else {
                        capsuleButton(L("开启")) { Task { await store.enablePush() } }
                    }
                }
            }
            noticeFooter(fallback: store.isReachable == false
                ? L("Mac 睡眠、合盖或断网时无法推送，也无法在这里查看状态。")
                : nil)
        }
    }

    private func healthSection(_ health: MacGatewayStatus.Health) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac 状态")
            AmberFormGroup {
                if let bytes = health.diskFreeBytes {
                    valueRow(icon: "internaldrive", title: L("磁盘剩余"),
                             value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal))
                    rowDivider
                }
                if let percent = health.batteryPercent {
                    valueRow(icon: health.onBattery == true ? "battery.50" : "battery.100.bolt", title: L("电量"),
                             value: "\(percent)%" + (health.onBattery == true ? "" : " · " + L("接电源")))
                    rowDivider
                }
                valueRow(icon: "memorychip", title: L("内存压力"), value: Self.levelLabel(health.memoryPressure))
                rowDivider
                valueRow(icon: "thermometer.medium", title: L("温度"), value: Self.levelLabel(health.thermal))
            }
        }
    }

    private var tasksSection: some View {
        let all = Array((store.status?.sessions ?? []).prefix(Self.visibleTaskLimit))
        let open = all.filter(\.isOpen)
        let ended = all.filter { !$0.isOpen }
        return VStack(spacing: 0) {
            AmberSectionLabel(text: "任务")
            AmberFormGroup {
                if let url = store.status?.synaraURL.flatMap(URL.init(string:)) {
                    settingsRow(icon: "bubble.left.and.text.bubble.right", title: L("在 Synara 中回复或确认"),
                                detail: L("在浏览器中打开 Synara，处理其中的任务"), action: { openURL(url) }) {
                        chevron
                    }
                    rowDivider
                }
                if all.isEmpty {
                    settingsRow(icon: "tray", title: L("暂无任务"),
                                detail: L("在 Mac 上使用 Claude Code 或 Codex 后会出现在这里")) {
                        EmptyView()
                    }
                } else if open.isEmpty {
                    settingsRow(icon: "checkmark.circle", title: L("没有进行中的任务"),
                                detail: L("任务运行或等你处理时会出现在这里")) {
                        EmptyView()
                    }
                }
                ForEach(Array(open.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { rowDivider }
                    settingsRow(icon: Self.agentIcon(session.agent), title: session.displayTitle, detail: taskDetail(session)) {
                        Toggle("", isOn: Binding(
                            get: { session.monitored },
                            set: { value in Task { await store.setMonitored(session, value) } }
                        ))
                        .labelsHidden()
                        .tint(AmberTheme.accent)
                        .accessibilityLabel(Text(verbatim: L("推送") + " " + session.displayTitle))
                    }
                    if let approval = session.pendingApproval { approvalRow(approval, sessionKey: session.key) }
                }
                if !ended.isEmpty {
                    rowDivider
                    settingsRow(icon: "clock.arrow.circlepath", title: L("已结束") + " \(ended.count)",
                                detail: L("最近 7 天结束的任务"), action: { withAnimation(.easeOut(duration: 0.2)) { showsEndedTasks.toggle() } }) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                            .rotationEffect(.degrees(showsEndedTasks ? 90 : 0))
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(Text(verbatim: showsEndedTasks ? L("已展开") : L("已收起")))
                    if showsEndedTasks {
                        ForEach(ended) { session in
                            rowDivider
                            settingsRow(icon: Self.agentIcon(session.agent), title: session.displayTitle, detail: taskDetail(session)) {
                                EmptyView()
                            }
                        }
                    }
                }
            }
            if !open.isEmpty {
                sectionFooter(L("关闭开关后，该任务不再推送。"))
            }
        }
    }

    /// Amber scheduled tasks on the Mac: see, switch on/off, run now, add. Approval rules stay on the Mac.
    private var schedulesSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "定时任务")
            AmberFormGroup {
                if let schedules = store.schedules {
                    ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                        if index > 0 { rowDivider }
                        settingsRow(icon: schedule.autoApprovesHighRisk ? "exclamationmark.shield" : "clock",
                                    title: schedule.name, detail: scheduleDetail(schedule)) {
                            HStack(spacing: 6) {
                                if store.busySchedules.contains(schedule.id) || schedule.running {
                                    ProgressView().frame(width: 44, height: 44)
                                } else {
                                    Button { Task { await store.runSchedule(schedule) } } label: {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(AmberTheme.accent)
                                    .accessibilityLabel(Text(verbatim: L("立即运行") + " " + schedule.name))
                                }
                                Toggle("", isOn: Binding(
                                    get: { schedule.enabled },
                                    set: { value in Task { await store.setScheduleEnabled(schedule, value) } }
                                ))
                                .labelsHidden()
                                .tint(AmberTheme.accent)
                                .disabled(store.busySchedules.contains(schedule.id))
                                .accessibilityLabel(Text(verbatim: L("启用") + " " + schedule.name))
                            }
                        }
                    }
                    if !schedules.isEmpty { rowDivider }
                    settingsRow(icon: "plus", title: L("新建定时任务"), detail: L("在 Mac 上按时运行提示词"),
                                action: { creatingSchedule = true }) {
                        chevron
                    }
                } else {
                    settingsRow(icon: "clock", title: L("暂不可用"),
                                detail: store.schedulesError ?? L("正在读取…")) {
                        EmptyView()
                    }
                }
            }
            if store.schedules != nil {
                sectionFooter(L("在手机上新建的任务不会自动批准任何工具；审批规则只能在 Mac 上修改。"))
            }
        }
    }

    private func scheduleDetail(_ schedule: MacGatewaySchedule) -> String {
        var parts = [schedule.rule]
        if schedule.running {
            parts.append(L("运行中"))
        } else if schedule.paused == true {
            parts.append(L("已暂停"))
        } else if !schedule.enabled {
            parts.append(L("已停用"))
        } else if let next = schedule.nextRunAt {
            parts.append(L("下次") + " " + next.formatted(.relative(presentation: .named)))
        }
        switch schedule.lastStatus {
        case "completed": parts.append(L("上次已完成"))
        case "failed": parts.append(L("上次未完成"))
        default: break
        }
        if schedule.autoApprovesHighRisk { parts.append(L("高风险自动批准")) }
        return parts.joined(separator: " · ")
    }

    private var unpairSection: some View {
        AmberFormGroup {
            actionRow(L("取消配对"), color: AmberTheme.accentRed, isBusy: store.isBusy) {
                confirmsUnpair = true
            }
        }
        .padding(.top, 28)
    }

    // MARK: - Text

    private var reachabilityText: String {
        switch store.isReachable {
        case nil: return L("正在连接…")
        case false: return L("无法连接")
        case true:
            guard let sampled = store.status?.health?.sampledAt else { return L("在线") }
            return L("在线") + " · " + L("更新于") + " " + sampled.formatted(.relative(presentation: .named))
        }
    }

    private var pushDetail: String {
        if let error = store.pushError { return error }
        return store.status?.device.pushRegistered == true ? L("已开启，任务需要你时会通知") : L("未开启")
    }

    private func taskDetail(_ session: MacGatewayStatus.Session) -> String {
        let agent = switch session.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "amber": L("Amber 定时任务")
        default: L("任务")
        }
        let state = switch session.state {
        case "running": L("运行中")
        case "waiting": session.waitReason == "permission" ? L("等你确认") : L("等你回复")
        case "stalled": L("可能卡住了")
        case "completed": L("已完成")
        default: session.agent == "amber" ? L("未完成") : session.abnormal ? L("意外中断") : L("已停止")
        }
        return [agent, session.host, state, session.updatedAt.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func agentIcon(_ agent: String) -> String {
        switch agent {
        case "claude": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "amber": "clock"
        default: "terminal"
        }
    }

    private static func levelLabel(_ level: String) -> String {
        switch level {
        case "normal", "nominal": L("正常")
        case "warning", "fair": L("偏高")
        case "serious": L("过高")
        default: L("严重")
        }
    }

    // MARK: - Rows

    /// The tool call an Amber scheduled run is waiting on, under its task row.
    private func approvalRow(_ approval: MacGatewayStatus.PendingApproval, sessionKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: approval.tool)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approval.highRisk ? AmberTheme.accentRed : AmberTheme.accent)
            if let detail = approval.detail {
                Text(verbatim: detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            }
            HStack(spacing: 10) {
                if store.decidingCalls.contains(approval.toolCallId) {
                    ProgressView().frame(minHeight: 44)
                } else {
                    capsuleButton(L("拒绝")) {
                        Task { await store.decide(sessionKey: sessionKey, toolCallId: approval.toolCallId, allow: false) }
                    }
                    if !approval.highRisk {
                        capsuleButton(L("批准")) {
                            Task { await store.decide(sessionKey: sessionKey, toolCallId: approval.toolCallId, allow: true) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if approval.highRisk {
                Text(verbatim: L("高风险操作，请在 Mac 上核对后批准"))
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private var rowDivider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(AmberTheme.accentTint, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AmberTheme.accent)
    }

    private func actionRow(_ title: String, color: Color, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                } else {
                    Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            iconPlate(icon)
            Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value).font(.subheadline).foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
    }

    private func settingsRow<Trailing: View>(icon: String, title: String, detail: String,
        action: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let action {
                Button(action: action) { rowContent(icon: icon, title: title, detail: detail) }
                    .buttonStyle(.plain)
            } else {
                rowContent(icon: icon, title: title, detail: detail)
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(minLength: 0); trailing() }
            } else {
                trailing().fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 4)
    }

    private func rowContent(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            iconPlate(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(verbatim: detail).font(.caption).foregroundStyle(AmberTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func iconPlate(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(AmberTheme.accent)
            .frame(width: 28, height: 28)
            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func noticeFooter(fallback: String?) -> some View {
        if let notice = store.notice {
            sectionFooter(notice.text, color: notice.isError ? .orange : AmberTheme.muted)
        } else if let fallback {
            sectionFooter(fallback)
        }
    }

    private func sectionFooter(_ text: String, color: Color = AmberTheme.muted) -> some View {
        Text(verbatim: text)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// New Amber scheduled task, created on the Mac. Name, prompt and time only.
private struct MacGatewayScheduleSheet: View {
    let store: MacGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MacGatewayScheduleDraft()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("名称"), text: $draft.name)
                    TextField(L("到点后发给模型的内容"), text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section(L("时间")) {
                    Picker(L("规则"), selection: $draft.rule) {
                        Text(verbatim: L("每天")).tag(MacGatewayScheduleDraft.Rule.daily)
                        Text(verbatim: L("工作日")).tag(MacGatewayScheduleDraft.Rule.weekdays)
                        Text(verbatim: L("每周")).tag(MacGatewayScheduleDraft.Rule.weekly)
                        Text(verbatim: L("间隔")).tag(MacGatewayScheduleDraft.Rule.interval)
                    }
                    if draft.rule == .interval {
                        Picker(L("每隔"), selection: $draft.intervalMinutes) {
                            ForEach([15, 30, 60, 120, 180, 360, 720], id: \.self) { value in
                                Text(verbatim: value < 60 ? "\(value) " + L("分钟") : "\(value / 60) " + L("小时")).tag(value)
                            }
                        }
                    } else {
                        DatePicker(L("时刻"), selection: $draft.time, displayedComponents: .hourAndMinute)
                    }
                    if draft.rule == .weekly {
                        HStack(spacing: 6) {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                let on = draft.weekdays.contains(day)
                                Button {
                                    if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                                } label: {
                                    Text(verbatim: Calendar.current.veryShortWeekdaySymbols[day - 1])
                                        .font(.subheadline.weight(on ? .semibold : .regular))
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(on ? AmberTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? AmberTheme.accent.opacity(0.4) : AmberTheme.borderSoft))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(on ? AmberTheme.accent : AmberTheme.foreground)
                                .accessibilityLabel(Text(verbatim: Calendar.current.weekdaySymbols[day - 1]))
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                            }
                        }
                    }
                }
                Section {
                    Text(verbatim: L("任务运行时不会自动批准任何工具，需要批准时会推送到手机。要调整审批规则，请在 Mac 上编辑。"))
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                    if let error {
                        Text(verbatim: error).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(Text(verbatim: L("新建定时任务")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(L("创建")) {
                            saving = true
                            Task {
                                error = await store.createSchedule(draft)
                                saving = false
                                if error == nil { dismiss() }
                            }
                        }
                        .disabled(!draft.isComplete)
                    }
                }
            }
        }
        .tint(AmberTheme.accent)
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
