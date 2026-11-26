import SwiftUI

// MARK: - Cloud Proactive Center Presentation Helpers

enum CloudProactiveCenterPresentation {
    enum OutcomeTone: Equatable, Sendable {
        case success
        case warning
        case neutral
    }

    struct SectionSnapshot: Equatable, Sendable {
        let isMonitorsEmpty: Bool
        let isWebhooksEmpty: Bool
        let isMutedTopicsEmpty: Bool
        let isRecentRunsEmpty: Bool
        let showsDeviceContextHint: Bool
        let clampedDailyMaxPushes: Int
        let quotaSummaryText: String
    }

    static func makeSnapshot(
        summary: CloudProactiveSummary,
        anyDeviceContextSharingEnabled: Bool
    ) -> SectionSnapshot {
        let clampedMax = clampDailyMaxPushes(summary.restraint.dailyMaxPushes)
        let quota = macGatewayL("今日已推送")
            + " \(summary.restraint.pushesToday) / \(clampedMax) · "
            + macGatewayL("剩余")
            + " \(max(0, summary.restraint.remainingToday))"
        return SectionSnapshot(
            isMonitorsEmpty: summary.monitors.isEmpty,
            isWebhooksEmpty: summary.webhooks.isEmpty,
            isMutedTopicsEmpty: summary.restraint.mutedTopics.isEmpty,
            isRecentRunsEmpty: summary.recentRuns.isEmpty,
            showsDeviceContextHint: !anyDeviceContextSharingEnabled,
            clampedDailyMaxPushes: clampedMax,
            quotaSummaryText: quota
        )
    }

    static func clampDailyMaxPushes(_ value: Int) -> Int {
        min(100, max(1, value))
    }

    static func parseHourMinute(_ hhmm: String, calendar: Calendar = .current) -> Date {
        let parts = hhmm.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        let hour = parts.count == 2 ? (Int(parts[0]) ?? 0) : 0
        let minute = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        let safeHour = min(23, max(0, hour))
        let safeMinute = min(59, max(0, minute))
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = safeHour
        components.minute = safeMinute
        components.second = 0
        return calendar.date(from: components) ?? Date()
    }

    static func formatHourMinute(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        return String(format: "%02d:%02d", hour, minute)
    }

    static func formatTopicKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return macGatewayL("未命名话题") }
        if trimmed.hasPrefix("watchtower:") {
            let suffix = String(trimmed.dropFirst("watchtower:".count))
            return macGatewayL("网页监控") + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        if trimmed.hasPrefix("webhook:") {
            let suffix = String(trimmed.dropFirst("webhook:".count))
            return "Webhook" + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        if trimmed.hasPrefix("prep:event:") {
            let suffix = String(trimmed.dropFirst("prep:event:".count))
            return macGatewayL("会前准备") + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        if trimmed.hasPrefix("calendar:") {
            let suffix = String(trimmed.dropFirst("calendar:".count))
            return macGatewayL("日程提醒") + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        if trimmed.hasPrefix("wakeup:") {
            let suffix = String(trimmed.dropFirst("wakeup:".count))
            return macGatewayL("定时提醒") + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        if trimmed.hasPrefix("cron:") {
            let suffix = String(trimmed.dropFirst("cron:".count))
            return macGatewayL("周期提醒") + (suffix.isEmpty ? "" : " · \(suffix)")
        }
        return trimmed
    }

    static func formatMutedUntil(
        _ untilEpochMs: Int64,
        nowEpochMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        timeZone: TimeZone = .current
    ) -> String {
        guard untilEpochMs > 0 else {
            return macGatewayL("到期时间未知")
        }
        if untilEpochMs <= nowEpochMs {
            return macGatewayL("静音已到期")
        }
        let formatted = formatTimestamp(untilEpochMs, timeZone: timeZone)
        return macGatewayL("静音至") + " \(formatted)"
    }

    /// Maps known server outcome strings to readable Chinese labels, and preserves unknown
    /// future outcome strings verbatim for forward compatibility.
    static func outcomeDisplayText(for rawOutcome: String) -> String {
        let trimmed = rawOutcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return macGatewayL("未知") }
        switch trimmed {
        case "pushed", "delivered", "sent":
            return macGatewayL("已推送")
        case "digest":
            return macGatewayL("已转入晨报")
        case "suppressed_quiet_hours", "quiet_hours":
            return macGatewayL("静默时段延后")
        case "deferred_budget", "budget_exceeded":
            return macGatewayL("达上限暂缓")
        case "muted", "suppressed_muted":
            return macGatewayL("话题已静音")
        case "filtered_l1", "filtered_l2", "unchanged", "skipped":
            return macGatewayL("无需打扰")
        case "feedback_opened":
            return macGatewayL("已查看")
        case "feedback_replied":
            return macGatewayL("已交由处理")
        case "feedback_dismiss":
            return macGatewayL("已忽略")
        case "feedback_snooze":
            return macGatewayL("已推迟提醒")
        case "feedback_mute_topic":
            return macGatewayL("已静音话题")
        case "wakeup_expired":
            return macGatewayL("提醒已过期")
        case "error", "failed":
            return macGatewayL("执行失败")
        default:
            return trimmed
        }
    }

    static func outcomeTone(for rawOutcome: String) -> OutcomeTone {
        let trimmed = rawOutcome.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "pushed", "delivered", "sent", "feedback_opened", "feedback_replied":
            return .success
        case "error", "failed", "wakeup_expired", "feedback_mute_topic", "suppressed_quiet_hours", "deferred_budget":
            return .warning
        default:
            return .neutral
        }
    }

    static func monitorStatusText(for monitor: CloudProactiveMonitorRecord) -> String {
        var parts: [String] = [
            monitor.enabled ? macGatewayL("已开启") : macGatewayL("已暂停"),
            macGatewayL("每 \(max(1, monitor.intervalMinutes)) 分钟")
        ]
        if let outcome = monitor.lastOutcome?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outcome.isEmpty {
            parts.append(outcomeDisplayText(for: outcome))
        }
        return parts.joined(separator: " · ")
    }

    static func webhookStatusText(for webhook: CloudProactiveWebhookRecord) -> String {
        var parts: [String] = [
            webhook.enabled ? macGatewayL("已开启") : macGatewayL("已暂停"),
            macGatewayL("已触发 \(max(0, webhook.triggerCount)) 次")
        ]
        let instruction = webhook.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            parts.append(String(instruction.prefix(48)))
        }
        return parts.joined(separator: " · ")
    }

    static func runDisplayTitle(for run: CloudProactiveRunHistoryEntry) -> String {
        let title = run.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let topic = run.topicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { return formatTopicKey(topic) }
        return macGatewayL("未命名运行")
    }

    static func formatTimestamp(_ epochMs: Int64, timeZone: TimeZone = .current) -> String {
        guard epochMs > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        return String(format: "%02d-%02d %02d:%02d", month, day, hour, minute)
    }
}

// MARK: - Lightweight Cloud Proactive Center View

struct CloudProactiveCenterView: View {
    @ObservedObject private var store: CloudProactiveStore
    private let gatewayStore: MacGatewayStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var busyMonitorIds: Set<String> = []
    @State private var busyWebhookIds: Set<String> = []
    @State private var busyMutedTopics: Set<String> = []
    @State private var isUpdatingRestraint = false
    @State private var pendingDeleteMonitor: CloudProactiveMonitorRecord?
    @State private var pendingDeleteWebhook: CloudProactiveWebhookRecord?

    init(
        store: CloudProactiveStore = .shared,
        gatewayStore: MacGatewayStore = .shared
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.gatewayStore = gatewayStore
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                scrollBody
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task {
            await store.refreshSummary()
        }
        .confirmationDialog(
            macGatewayL("删除该网页监控？"),
            isPresented: Binding(
                get: { pendingDeleteMonitor != nil },
                set: { if !$0 { pendingDeleteMonitor = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let monitor = pendingDeleteMonitor {
                Button(macGatewayL("删除"), role: .destructive) {
                    performDeleteMonitor(monitor.id)
                }
            }
            Button(macGatewayL("取消"), role: .cancel) {
                pendingDeleteMonitor = nil
            }
        } message: {
            if let monitor = pendingDeleteMonitor {
                Text(verbatim: monitor.title)
            }
        }
        .confirmationDialog(
            macGatewayL("删除该入站 Webhook？"),
            isPresented: Binding(
                get: { pendingDeleteWebhook != nil },
                set: { if !$0 { pendingDeleteWebhook = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let webhook = pendingDeleteWebhook {
                Button(macGatewayL("删除"), role: .destructive) {
                    performDeleteWebhook(webhook.id)
                }
            }
            Button(macGatewayL("取消"), role: .cancel) {
                pendingDeleteWebhook = nil
            }
        } message: {
            if let webhook = pendingDeleteWebhook {
                Text(verbatim: webhook.name)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: macGatewayL("主动提醒中心"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                Task { await store.refreshSummary() }
            } label: {
                if store.isLoading {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .accessibilityLabel(Text(verbatim: macGatewayL("刷新主动提醒")))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                conversationalCreationBanner

                if !gatewayStore.anyDeviceContextSharingEnabled {
                    deviceContextGentleNotice
                }

                if let error = store.lastError, !error.isEmpty {
                    errorBanner(error)
                }

                if let summary = store.summary {
                    let snapshot = CloudProactiveCenterPresentation.makeSnapshot(
                        summary: summary,
                        anyDeviceContextSharingEnabled: gatewayStore.anyDeviceContextSharingEnabled
                    )
                    restraintSection(summary.restraint, snapshot: snapshot)
                    monitorsSection(summary.monitors)
                    webhooksSection(summary.webhooks)
                    mutedTopicsSection(summary.restraint.mutedTopics)
                    recentRunsSection(summary.recentRuns)
                } else if store.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(verbatim: macGatewayL("正在加载主动提醒配置…"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    emptyUnloadedCard
                }
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await store.refreshSummary()
        }
    }

    private var conversationalCreationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            MacGatewayIconPlate(icon: "sparkles")
            Text(verbatim: macGatewayL("创建网页监控或 Webhook，可直接在云端对话里告诉 Amber"))
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var deviceContextGentleNotice: some View {
        Text(verbatim: macGatewayL("本机只读摘要共享当前处于关闭状态，如需基于日程或待办的主动提醒，可在上一页按需开启。"))
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MacDelegationSemanticInk.warning)
                .padding(.top, 2)
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(macGatewayL("重试")) {
                Task { await store.refreshSummary() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            MacDelegationSemanticInk.warning.opacity(colorScheme == .dark ? 0.16 : 0.1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MacDelegationSemanticInk.warning.opacity(0.4), lineWidth: 0.75)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var emptyUnloadedCard: some View {
        AmberFormGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: macGatewayL("暂未获取到云端主动提醒信息"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(verbatim: macGatewayL("请确认已配对 Amber · 云端且网络畅通，下拉或点击右上角重试。"))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
    }

    // MARK: - Restraint & Quiet Hours

    private func restraintSection(
        _ restraint: CloudProactiveRestraintSnapshot,
        snapshot: CloudProactiveCenterPresentation.SectionSnapshot
    ) -> some View {
        let quietToggleBinding = Binding<Bool>(
            get: { restraint.quietHoursEnabled },
            set: { newValue in
                guard newValue != restraint.quietHoursEnabled else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(quietHoursEnabled: newValue))
            }
        )

        let startDateBinding = Binding<Date>(
            get: { CloudProactiveCenterPresentation.parseHourMinute(restraint.quietHoursStart) },
            set: { newDate in
                let formatted = CloudProactiveCenterPresentation.formatHourMinute(newDate)
                guard formatted != restraint.quietHoursStart else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(quietHoursStart: formatted))
            }
        )

        let endDateBinding = Binding<Date>(
            get: { CloudProactiveCenterPresentation.parseHourMinute(restraint.quietHoursEnd) },
            set: { newDate in
                let formatted = CloudProactiveCenterPresentation.formatHourMinute(newDate)
                guard formatted != restraint.quietHoursEnd else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(quietHoursEnd: formatted))
            }
        )

        let maxPushesBinding = Binding<Int>(
            get: { snapshot.clampedDailyMaxPushes },
            set: { newValue in
                let clamped = CloudProactiveCenterPresentation.clampDailyMaxPushes(newValue)
                guard clamped != restraint.dailyMaxPushes else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(dailyMaxPushes: clamped))
            }
        )

        return VStack(spacing: 0) {
            AmberSectionLabel(text: "节制与静默时段")
            AmberFormGroup {
                Toggle(isOn: quietToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: macGatewayL("启用静默时段"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: macGatewayL("静默时段内普通主动提醒将延后，避免夜间打扰"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                .disabled(isUpdatingRestraint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if restraint.quietHoursEnabled {
                    MacGatewayRowDivider()
                    HStack {
                        Text(verbatim: macGatewayL("开始时间"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 8)
                        DatePicker(
                            macGatewayL("开始时间"),
                            selection: startDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .disabled(isUpdatingRestraint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    MacGatewayRowDivider()
                    HStack {
                        Text(verbatim: macGatewayL("结束时间"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 8)
                        DatePicker(
                            macGatewayL("结束时间"),
                            selection: endDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .disabled(isUpdatingRestraint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                MacGatewayRowDivider()
                Stepper(value: maxPushesBinding, in: 1...100) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: macGatewayL("每日普通推送上限"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: "\(snapshot.clampedDailyMaxPushes) " + macGatewayL("条/天"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                .disabled(isUpdatingRestraint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            MacGatewaySectionFooter(
                text: snapshot.quotaSummaryText
                    + (restraint.zoneId.isEmpty ? "" : " · \(restraint.zoneId)")
            )
        }
    }

    // MARK: - Watchtower Monitors

    private func monitorsSection(_ monitors: [CloudProactiveMonitorRecord]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "网页监控")
            AmberFormGroup {
                if monitors.isEmpty {
                    emptyRow(macGatewayL("暂无网页监控，直接在云端对话里告诉 Amber 即可创建。"))
                } else {
                    ForEach(Array(monitors.enumerated()), id: \.element.id) { index, monitor in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        monitorRow(monitor)
                    }
                }
            }
        }
    }

    private func monitorRow(_ monitor: CloudProactiveMonitorRecord) -> some View {
        let isBusy = busyMonitorIds.contains(monitor.id)
        let toggleBinding = Binding<Bool>(
            get: { monitor.enabled },
            set: { newValue in
                guard newValue != monitor.enabled else { return }
                performSetMonitorEnabled(id: monitor.id, enabled: newValue)
            }
        )

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: monitor.title.isEmpty ? monitor.url : monitor.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                Text(verbatim: monitor.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                Text(verbatim: CloudProactiveCenterPresentation.monitorStatusText(for: monitor))
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: macGatewayL("启停监控") + " \(monitor.title)"))

                Button {
                    pendingDeleteMonitor = monitor
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(MacDelegationSemanticInk.danger)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: macGatewayL("删除监控") + " \(monitor.title)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Inbound Webhooks

    private func webhooksSection(_ webhooks: [CloudProactiveWebhookRecord]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "入站 Webhook")
            AmberFormGroup {
                if webhooks.isEmpty {
                    emptyRow(macGatewayL("暂无入站 Webhook，直接在云端对话里告诉 Amber 即可创建。"))
                } else {
                    ForEach(Array(webhooks.enumerated()), id: \.element.id) { index, webhook in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        webhookRow(webhook)
                    }
                }
            }
        }
    }

    private func webhookRow(_ webhook: CloudProactiveWebhookRecord) -> some View {
        let isBusy = busyWebhookIds.contains(webhook.id)
        let toggleBinding = Binding<Bool>(
            get: { webhook.enabled },
            set: { newValue in
                guard newValue != webhook.enabled else { return }
                performSetWebhookEnabled(id: webhook.id, enabled: newValue)
            }
        )

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: webhook.name.isEmpty ? webhook.id : webhook.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                Text(verbatim: CloudProactiveCenterPresentation.webhookStatusText(for: webhook))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: macGatewayL("启停 Webhook") + " \(webhook.name)"))

                Button {
                    pendingDeleteWebhook = webhook
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(MacDelegationSemanticInk.danger)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: macGatewayL("删除 Webhook") + " \(webhook.name)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Muted Topics

    private func mutedTopicsSection(_ topics: [CloudProactiveMutedTopic]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "已静音话题")
            AmberFormGroup {
                if topics.isEmpty {
                    emptyRow(macGatewayL("当前没有已静音的话题。"))
                } else {
                    ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        mutedTopicRow(topic)
                    }
                }
            }
        }
    }

    private func mutedTopicRow(_ topic: CloudProactiveMutedTopic) -> some View {
        let isBusy = busyMutedTopics.contains(topic.topicKey)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: CloudProactiveCenterPresentation.formatTopicKey(topic.topicKey))
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                Text(verbatim: CloudProactiveCenterPresentation.formatMutedUntil(topic.untilEpochMs))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .frame(width: 44, height: 36)
            } else {
                MacGatewayCapsuleButton(title: macGatewayL("取消静音")) {
                    performUnmute(topicKey: topic.topicKey)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Recent Runs

    private func recentRunsSection(_ runs: [CloudProactiveRunHistoryEntry]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "最近运行记录")
            AmberFormGroup {
                if runs.isEmpty {
                    emptyRow(macGatewayL("暂无主动运行记录。"))
                } else {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        recentRunRow(run)
                    }
                }
            }
        }
    }

    private func recentRunRow(_ run: CloudProactiveRunHistoryEntry) -> some View {
        let outcomeText = CloudProactiveCenterPresentation.outcomeDisplayText(for: run.outcome)
        let tone = CloudProactiveCenterPresentation.outcomeTone(for: run.outcome)
        let badgeColor: Color = {
            switch tone {
            case .success: return MacDelegationSemanticInk.success
            case .warning: return MacDelegationSemanticInk.warning
            case .neutral: return AmberTheme.muted
            }
        }()
        let timestamp = CloudProactiveCenterPresentation.formatTimestamp(run.timestampEpochMs)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: CloudProactiveCenterPresentation.runDisplayTitle(for: run))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: outcomeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        badgeColor.opacity(colorScheme == .dark ? 0.2 : 0.12),
                        in: Capsule(style: .continuous)
                    )
            }

            if !run.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: run.summary)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !timestamp.isEmpty {
                Text(verbatim: timestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func applyRestraintPatch(_ patch: CloudProactiveRestraintPatch) {
        isUpdatingRestraint = true
        Task { @MainActor in
            await store.updateRestraint(patch)
            isUpdatingRestraint = false
        }
    }

    private func performSetMonitorEnabled(id: String, enabled: Bool) {
        busyMonitorIds.insert(id)
        Task { @MainActor in
            await store.setMonitorEnabled(id: id, enabled: enabled)
            busyMonitorIds.remove(id)
        }
    }

    private func performDeleteMonitor(_ id: String) {
        pendingDeleteMonitor = nil
        busyMonitorIds.insert(id)
        Task { @MainActor in
            await store.deleteMonitor(id: id)
            busyMonitorIds.remove(id)
        }
    }

    private func performSetWebhookEnabled(id: String, enabled: Bool) {
        busyWebhookIds.insert(id)
        Task { @MainActor in
            await store.setWebhookEnabled(id: id, enabled: enabled)
            busyWebhookIds.remove(id)
        }
    }

    private func performDeleteWebhook(_ id: String) {
        pendingDeleteWebhook = nil
        busyWebhookIds.insert(id)
        Task { @MainActor in
            await store.deleteWebhook(id: id)
            busyWebhookIds.remove(id)
        }
    }

    private func performUnmute(topicKey: String) {
        busyMutedTopics.insert(topicKey)
        Task { @MainActor in
            await store.unmute(topicKey: topicKey)
            busyMutedTopics.remove(topicKey)
        }
    }
}
