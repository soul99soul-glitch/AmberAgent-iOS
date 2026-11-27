import SwiftUI

// MARK: - Cloud Proactive Center Presentation Helpers

enum CloudProactiveCenterPresentation {
    enum OutcomeTone: Equatable, Sendable {
        case success
        case warning
        case neutral
    }

    struct SectionSnapshot: Equatable, Sendable {
        let isWakeupsEmpty: Bool
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
            isWakeupsEmpty: pendingWakeups(from: summary).isEmpty,
            isMonitorsEmpty: summary.monitors.isEmpty,
            isWebhooksEmpty: summary.webhooks.isEmpty,
            isMutedTopicsEmpty: summary.restraint.mutedTopics.isEmpty,
            isRecentRunsEmpty: summary.recentRuns.isEmpty,
            showsDeviceContextHint: !anyDeviceContextSharingEnabled,
            clampedDailyMaxPushes: clampedMax,
            quotaSummaryText: quota
        )
    }

    static func pendingWakeups(from summary: CloudProactiveSummary) -> [CloudProactiveWakeupRecord] {
        summary.wakeups
            .filter { record in
                let status = record.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return status.isEmpty || status == "pending"
            }
            .sorted { lhs, rhs in
                if lhs.triggerAtEpochMs != rhs.triggerAtEpochMs {
                    return lhs.triggerAtEpochMs < rhs.triggerAtEpochMs
                }
                return lhs.id < rhs.id
            }
    }

    static func wakeupSourceLabel(for kind: String) -> String {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "commitment":
            return macGatewayL("从对话记下")
        case "snooze":
            return macGatewayL("稍后提醒")
        case "agent":
            return macGatewayL("Amber 安排")
        default:
            return macGatewayL("定时提醒")
        }
    }

    static func normalizedDeliveryMode(for raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == "digest" ? "digest" : "immediate"
    }

    static func deliveryModeDisplayText(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "digest":
            return macGatewayL("并入晨报")
        case "immediate", "":
            return macGatewayL("即时推送")
        default:
            return trimmed
        }
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
        case "blocked_ssrf":
            return macGatewayL("监控地址已被安全策略拦截")
        case "suppressed":
            return macGatewayL("已暂缓推送")
        case "filtered_l1", "filtered_l2", "dropped_l1", "dropped_low_score", "unchanged", "skipped":
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
        case "error", "failed", "blocked_ssrf", "wakeup_expired", "feedback_mute_topic", "suppressed_quiet_hours", "deferred_budget":
            return .warning
        default:
            return .neutral
        }
    }

    static func monitorStatusText(for monitor: CloudProactiveMonitorRecord) -> String {
        var parts: [String] = [
            monitor.enabled ? macGatewayL("已开启") : macGatewayL("已暂停"),
            deliveryModeDisplayText(for: monitor.deliveryMode),
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
    @StateObject private var store: CloudProactiveStore
    private let gatewayStore: MacGatewayStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var busyWakeupIds: Set<String> = []
    @State private var busyMonitorIds: Set<String> = []
    @State private var busyWebhookIds: Set<String> = []
    @State private var busyMutedTopics: Set<String> = []
    @State private var isUpdatingRestraint = false
    @State private var pendingDeleteMonitor: CloudProactiveMonitorRecord?
    @State private var pendingDeleteWebhook: CloudProactiveWebhookRecord?
    @State private var isPresentingGitHubTemplate = false
    @State private var githubRepoSlug = ""
    @State private var githubDeliveryMode = "digest"
    @State private var isSubmittingGitHubMonitor = false

    init(
        store: CloudProactiveStore? = nil,
        gatewayStore: MacGatewayStore = .shared
    ) {
        self._store = StateObject(wrappedValue: store ?? CloudProactiveStore(gatewayStore: gatewayStore))
        self.gatewayStore = gatewayStore
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let error = store.lastError, !error.isEmpty, !isPresentingGitHubTemplate {
                    errorBanner(error)
                }
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
        .sheet(isPresented: $isPresentingGitHubTemplate) {
            githubReleaseTemplateSheet
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

                if let summary = store.summary {
                    let snapshot = CloudProactiveCenterPresentation.makeSnapshot(
                        summary: summary,
                        anyDeviceContextSharingEnabled: gatewayStore.anyDeviceContextSharingEnabled
                    )
                    let pendingWakeups = CloudProactiveCenterPresentation.pendingWakeups(from: summary)
                    pendingWakeupsSection(pendingWakeups)
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

    // MARK: - Pending Wakeups

    private func pendingWakeupsSection(_ wakeups: [CloudProactiveWakeupRecord]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "待提醒")
            AmberFormGroup {
                if wakeups.isEmpty {
                    emptyRow(macGatewayL("暂无待触发的提醒，对话中约定的事项或稍后提醒会显示在这里。"))
                } else {
                    ForEach(Array(wakeups.enumerated()), id: \.element.id) { index, wakeup in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        pendingWakeupRow(wakeup)
                    }
                }
            }
        }
    }

    private func pendingWakeupRow(_ wakeup: CloudProactiveWakeupRecord) -> some View {
        let isBusy = busyWakeupIds.contains(wakeup.id)
        let sourceLabel = CloudProactiveCenterPresentation.wakeupSourceLabel(for: wakeup.kind)
        let badgeColor: Color = {
            switch wakeup.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "commitment":
                return AmberTheme.accent
            case "snooze":
                return MacDelegationSemanticInk.warning
            default:
                return AmberTheme.muted
            }
        }()
        let triggerText = CloudProactiveCenterPresentation.formatTimestamp(wakeup.triggerAtEpochMs)
        let trimmedDetail = wakeup.detail.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: wakeup.title.isEmpty ? macGatewayL("未命名提醒") : wakeup.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(2)

                    Text(verbatim: sourceLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            badgeColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            in: Capsule(style: .continuous)
                        )
                        .fixedSize()
                }

                if !trimmedDetail.isEmpty {
                    Text(verbatim: trimmedDetail)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineLimit(2)
                }

                if !triggerText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(verbatim: macGatewayL("计划触发") + " \(triggerText)")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(AmberTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .frame(width: 44, height: 36)
            } else {
                MacGatewayCapsuleButton(title: macGatewayL("取消")) {
                    performCancelWakeup(wakeup.id)
                }
                .accessibilityLabel(Text(verbatim: macGatewayL("取消待提醒") + " \(wakeup.title)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Restraint, Quiet Hours, Pulse & Commitment Extraction

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

        let pulseToggleBinding = Binding<Bool>(
            get: { restraint.pulseEnabled },
            set: { newValue in
                guard newValue != restraint.pulseEnabled else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(pulseEnabled: newValue))
            }
        )

        let pulseDateBinding = Binding<Date>(
            get: { CloudProactiveCenterPresentation.parseHourMinute(restraint.pulseTime) },
            set: { newDate in
                let formatted = CloudProactiveCenterPresentation.formatHourMinute(newDate)
                guard formatted != restraint.pulseTime else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(pulseTime: formatted))
            }
        )

        let commitmentToggleBinding = Binding<Bool>(
            get: { restraint.commitmentExtractionEnabled },
            set: { newValue in
                guard newValue != restraint.commitmentExtractionEnabled else { return }
                applyRestraintPatch(CloudProactiveRestraintPatch(commitmentExtractionEnabled: newValue))
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

                MacGatewayRowDivider()
                Toggle(isOn: pulseToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: macGatewayL("每日晨报"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: macGatewayL("有缓冲内容或今日日程时汇总推送一次，无内容不打扰"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                .disabled(isUpdatingRestraint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if restraint.pulseEnabled {
                    MacGatewayRowDivider()
                    HStack {
                        Text(verbatim: macGatewayL("晨报时间"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 8)
                        DatePicker(
                            macGatewayL("晨报时间"),
                            selection: pulseDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .disabled(isUpdatingRestraint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                MacGatewayRowDivider()
                Toggle(isOn: commitmentToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: macGatewayL("自动抽取对话承诺"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: macGatewayL("仅在开启记忆的对话中生效，自动记下的提醒会出现在上方待提醒列表"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
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
                    emptyRow(macGatewayL("暂无网页监控，可直接订阅 GitHub Release 或在云端对话里告诉 Amber 创建。"))
                } else {
                    ForEach(Array(monitors.enumerated()), id: \.element.id) { index, monitor in
                        if index > 0 {
                            MacGatewayRowDivider()
                        }
                        monitorRow(monitor)
                    }
                }

                MacGatewayRowDivider()
                Button {
                    githubRepoSlug = ""
                    githubDeliveryMode = "digest"
                    isPresentingGitHubTemplate = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                        Text(verbatim: macGatewayL("订阅 GitHub Release"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                        Spacer(minLength: 0)
                        Text(verbatim: "owner/repo")
                            .font(.caption.monospaced())
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        let currentDeliveryMode = CloudProactiveCenterPresentation.normalizedDeliveryMode(for: monitor.deliveryMode)
        let deliveryModeBinding = Binding<String>(
            get: { currentDeliveryMode },
            set: { newMode in
                guard newMode != currentDeliveryMode else { return }
                performSetMonitorDeliveryMode(id: monitor.id, mode: newMode)
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
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

            HStack(spacing: 10) {
                Text(verbatim: macGatewayL("投递方式"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                Spacer(minLength: 6)
                Picker(macGatewayL("投递方式"), selection: deliveryModeBinding) {
                    Text(verbatim: macGatewayL("即时推送")).tag("immediate")
                    Text(verbatim: macGatewayL("并入晨报")).tag("digest")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 196)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var githubReleaseTemplateSheet: some View {
        let trimmedSlug = githubRepoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = MacGatewayClient.buildGitHubReleaseFeedURL(from: trimmedSlug)
        let hasInvalidInput = !trimmedSlug.isEmpty && resolvedURL == nil

        return ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    AmberGlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭", size: 40, symbolSize: 16) {
                        isPresentingGitHubTemplate = false
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: macGatewayL("订阅 GitHub Release"))
                        .font(.headline)
                        .foregroundStyle(AmberTheme.foreground)
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(text: "仓库信息")
                        AmberFormGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: macGatewayL("GitHub 仓库（owner/repo）"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AmberTheme.muted)
                                TextField("apple/swift", text: $githubRepoSlug)
                                    .font(.body.monospaced())
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .keyboardType(.asciiCapable)
                                    .disabled(isSubmittingGitHubMonitor)

                                if let resolvedURL {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(MacDelegationSemanticInk.success)
                                            .padding(.top, 1)
                                        Text(verbatim: resolvedURL.absoluteString)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(AmberTheme.foreground2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } else if hasInvalidInput {
                                    Text(verbatim: macGatewayL("格式无效：请输入合法的 owner/repo，不含协议前缀、空格、.. 或非法字符。"))
                                        .font(.caption)
                                        .foregroundStyle(MacDelegationSemanticInk.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(verbatim: macGatewayL("仅生成 https://github.com/{owner}/{repo}/releases.atom 订阅地址。"))
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)

                            MacGatewayRowDivider()

                            HStack(spacing: 10) {
                                Text(verbatim: macGatewayL("投递方式"))
                                    .font(.body)
                                    .foregroundStyle(AmberTheme.foreground)
                                Spacer(minLength: 8)
                                Picker(macGatewayL("投递方式"), selection: $githubDeliveryMode) {
                                    Text(verbatim: macGatewayL("并入晨报")).tag("digest")
                                    Text(verbatim: macGatewayL("即时推送")).tag("immediate")
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 196)
                                .disabled(isSubmittingGitHubMonitor)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        if let error = store.lastError, !error.isEmpty {
                            errorBanner(error)
                                .padding(.top, 8)
                        }

                        Button {
                            performAddGitHubReleaseMonitor()
                        } label: {
                            HStack(spacing: 8) {
                                if isSubmittingGitHubMonitor {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(verbatim: macGatewayL("添加订阅"))
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                (resolvedURL == nil || isSubmittingGitHubMonitor)
                                    ? AmberTheme.accent.opacity(0.4)
                                    : AmberTheme.accent,
                                in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvedURL == nil || isSubmittingGitHubMonitor)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    private func performCancelWakeup(_ id: String) {
        busyWakeupIds.insert(id)
        Task { @MainActor in
            await store.cancelWakeup(id: id)
            busyWakeupIds.remove(id)
        }
    }

    private func performSetMonitorEnabled(id: String, enabled: Bool) {
        busyMonitorIds.insert(id)
        Task { @MainActor in
            await store.setMonitorEnabled(id: id, enabled: enabled)
            busyMonitorIds.remove(id)
        }
    }

    private func performSetMonitorDeliveryMode(id: String, mode: String) {
        busyMonitorIds.insert(id)
        Task { @MainActor in
            await store.setMonitorDeliveryMode(id: id, mode: mode)
            busyMonitorIds.remove(id)
        }
    }

    private func performAddGitHubReleaseMonitor() {
        isSubmittingGitHubMonitor = true
        let slug = githubRepoSlug
        let mode = githubDeliveryMode
        Task { @MainActor in
            let created = await store.addGitHubReleaseMonitor(repoSlug: slug, deliveryMode: mode)
            isSubmittingGitHubMonitor = false
            if created {
                githubRepoSlug = ""
                githubDeliveryMode = "digest"
                isPresentingGitHubTemplate = false
            }
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
