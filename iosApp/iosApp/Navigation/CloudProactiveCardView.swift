import SwiftUI

// MARK: - Cloud Proactive Card Presentation Model

enum CloudProactiveCardAction: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case act
    case snooze
    case mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .act:
            return macGatewayL("让 Amber 处理")
        case .snooze:
            return macGatewayL("1 小时后")
        case .mute:
            return macGatewayL("减少此类")
        }
    }

    var systemImage: String {
        switch self {
        case .act:
            return "sparkles"
        case .snooze:
            return "clock"
        case .mute:
            return "bell.slash"
        }
    }

    var successMessage: String {
        switch self {
        case .act:
            return macGatewayL("已交由 Amber 处理")
        case .snooze:
            return macGatewayL("已推迟 1 小时")
        case .mute:
            return macGatewayL("已减少此类提醒")
        }
    }

    var isProminent: Bool {
        self == .act
    }
}

struct CloudProactiveCardPresentation: Equatable, Sendable {
    let signalId: String?
    let sourceLabel: String
    let sourceIconName: String
    let title: String
    let bodyText: String
    let isUrgent: Bool
    let urgentBadgeText: String?
    let isSilent: Bool
    let actions: [CloudProactiveCardAction]
    let hasMetadata: Bool

    init(event: MacGatewayCloudDialogueEvent) {
        let meta = event.proactive
        self.hasMetadata = meta != nil
        self.signalId = Self.resolvedSignalId(for: event)

        let rawSource = meta?.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawSource.isEmpty {
            self.sourceLabel = rawSource
        } else {
            self.sourceLabel = Self.fallbackSourceLabel(forCategory: meta?.category)
        }
        self.sourceIconName = Self.sourceIcon(forCategory: meta?.category)

        let rawTitle = meta?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = rawTitle.isEmpty ? macGatewayL("主动提醒") : rawTitle

        let trimmedBody = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bodyText = trimmedBody.isEmpty ? macGatewayL("暂无详细内容") : trimmedBody

        let normalizedUrgency = meta?.urgency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "normal"
        self.isUrgent = normalizedUrgency == "urgent"
        self.urgentBadgeText = self.isUrgent ? macGatewayL("紧急") : nil
        self.isSilent = meta?.silent ?? false

        if let rawActions = meta?.actions {
            self.actions = Self.parseActions(rawActions)
        } else {
            self.actions = []
        }
    }

    static func fallbackSourceLabel(forCategory rawCategory: String?) -> String {
        let normalized = rawCategory?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch normalized {
        case "CLOCK_CRON":
            return macGatewayL("定时提醒")
        case "EXTERNAL_SENSOR":
            return macGatewayL("外部监控")
        case "EDGE_NODE_EVENT":
            return macGatewayL("设备动态")
        case "MEMORY_COMMITMENT":
            return macGatewayL("承诺跟进")
        case "TASK_LIFECYCLE":
            return macGatewayL("任务动态")
        default:
            return macGatewayL("主动提醒")
        }
    }

    static func sourceIcon(forCategory rawCategory: String?) -> String {
        let normalized = rawCategory?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch normalized {
        case "CLOCK_CRON":
            return "clock.badge"
        case "EXTERNAL_SENSOR":
            return "antenna.radiowaves.left.and.right"
        case "EDGE_NODE_EVENT":
            return "desktopcomputer"
        case "MEMORY_COMMITMENT":
            return "bookmark.circle"
        case "TASK_LIFECYCLE":
            return "checklist"
        default:
            return "sparkles"
        }
    }

    static func parseActions(_ rawActions: [String]) -> [CloudProactiveCardAction] {
        var result: [CloudProactiveCardAction] = []
        var seen = Set<CloudProactiveCardAction>()
        for raw in rawActions {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let action = CloudProactiveCardAction(rawValue: normalized),
                  seen.insert(action).inserted else {
                continue
            }
            result.append(action)
        }
        return result
    }

    static func resolvedSignalId(for event: MacGatewayCloudDialogueEvent) -> String? {
        if let metaId = event.proactive?.signalId.trimmingCharacters(in: .whitespacesAndNewlines),
           MacGatewayClient.isValidProactiveSignalId(metaId) {
            return metaId
        }
        let prefix = "proactive:"
        if event.id.hasPrefix(prefix) {
            let suffix = String(event.id.dropFirst(prefix.count))
            if MacGatewayClient.isValidProactiveSignalId(suffix) {
                return suffix
            }
        }
        return nil
    }
}

// MARK: - Structured Proactive Timeline Card

struct CloudProactiveCardView: View {
    let event: MacGatewayCloudDialogueEvent
    var isHighlighted: Bool = false
    @ObservedObject var store: CloudProactiveStore
    var onActionCompleted: ((CloudProactiveCardAction) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var inFlightAction: CloudProactiveCardAction?
    @State private var completedAction: CloudProactiveCardAction?
    @State private var feedbackMessage: String?
    @State private var isErrorFeedback = false

    init(
        event: MacGatewayCloudDialogueEvent,
        isHighlighted: Bool = false,
        store: CloudProactiveStore = .shared,
        onActionCompleted: ((CloudProactiveCardAction) -> Void)? = nil
    ) {
        self.event = event
        self.isHighlighted = isHighlighted
        self._store = ObservedObject(wrappedValue: store)
        self.onActionCompleted = onActionCompleted
    }

    private var presentation: CloudProactiveCardPresentation {
        CloudProactiveCardPresentation(event: event)
    }

    private var borderColor: Color {
        if isHighlighted {
            return AmberTheme.accent
        }
        if presentation.isUrgent {
            return MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.55 : 0.4)
        }
        return AmberTheme.borderSoft
    }

    private var borderLineWidth: CGFloat {
        isHighlighted ? 1.8 : (presentation.isUrgent ? 1.1 : 0.8)
    }

    private var cardBackground: Color {
        if isHighlighted {
            return AmberTheme.accent.opacity(colorScheme == .dark ? 0.14 : 0.07)
        }
        return AmberTheme.surface
    }

    var body: some View {
        let model = presentation
        VStack(alignment: .leading, spacing: 11) {
            headerSection(model)

            Text(verbatim: model.bodyText)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !model.actions.isEmpty {
                actionBar(model)
            }

            if let feedbackMessage, !feedbackMessage.isEmpty {
                feedbackBanner(feedbackMessage)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderLineWidth)
        }
        .animation(.easeInOut(duration: 0.22), value: isHighlighted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.cloudProactive.card.\(model.signalId ?? event.id)")
    }

    private func headerSection(_ model: CloudProactiveCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: model.sourceIconName)
                        .font(.caption2.weight(.semibold))
                    Text(verbatim: model.sourceLabel)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(AmberTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AmberTheme.accentTint, in: Capsule(style: .continuous))

                if let urgentText = model.urgentBadgeText {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                        Text(verbatim: urgentText)
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(MacDelegationSemanticInk.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: Capsule(style: .continuous)
                    )
                    .accessibilityLabel(Text(verbatim: macGatewayL("紧急提醒")))
                }

                Spacer(minLength: 0)
            }

            Text(verbatim: model.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionBar(_ model: CloudProactiveCardPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(model.actions) { action in
                    actionButton(action, model: model, expandsFullWidth: false)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.actions) { action in
                    actionButton(action, model: model, expandsFullWidth: dynamicTypeSize.isAccessibilitySize)
                }
            }
        }
        .padding(.top, 2)
    }

    private func actionButton(
        _ action: CloudProactiveCardAction,
        model: CloudProactiveCardPresentation,
        expandsFullWidth: Bool
    ) -> some View {
        let isRunning = inFlightAction == action
        let isBusy = inFlightAction != nil
        let isCompleted = completedAction == action && !isErrorFeedback

        let foreground: Color = {
            if action.isProminent {
                return AmberTheme.accentInk
            }
            if isCompleted {
                return MacDelegationSemanticInk.success
            }
            return action == .mute ? AmberTheme.muted : AmberTheme.foreground
        }()

        let fill: Color = {
            if action.isProminent {
                return AmberTheme.accent
            }
            if isCompleted {
                return MacDelegationSemanticInk.success.opacity(colorScheme == .dark ? 0.2 : 0.12)
            }
            return AmberTheme.surface2
        }()

        return Button {
            perform(action, signalId: model.signalId)
        } label: {
            HStack(spacing: 5) {
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foreground)
                } else {
                    Image(systemName: isCompleted ? "checkmark" : action.systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(verbatim: action.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(maxWidth: expandsFullWidth ? .infinity : nil, minHeight: 34)
            .background(fill, in: Capsule(style: .continuous))
            .overlay {
                if !action.isProminent {
                    Capsule(style: .continuous)
                        .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.6)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy && !isRunning ? 0.55 : 1.0)
        .accessibilityIdentifier("chat.cloudProactive.action.\(action.rawValue)")
    }

    private func feedbackBanner(_ message: String) -> some View {
        let tint = isErrorFeedback ? MacDelegationSemanticInk.warning : MacDelegationSemanticInk.success
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isErrorFeedback ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(isErrorFeedback ? tint : AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(colorScheme == .dark ? 0.16 : 0.1),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func perform(_ action: CloudProactiveCardAction, signalId: String?) {
        guard inFlightAction == nil else { return }
        inFlightAction = action
        feedbackMessage = nil
        isErrorFeedback = false

        Task { @MainActor in
            let succeeded: Bool
            switch action {
            case .act:
                succeeded = await store.act(on: event)
            case .snooze:
                if let signalId {
                    succeeded = await store.sendFeedback(signalId: signalId, action: .snooze)
                } else {
                    inFlightAction = nil
                    isErrorFeedback = true
                    feedbackMessage = macGatewayL("缺少有效提醒标识，无法推迟该提醒")
                    return
                }
            case .mute:
                if let signalId {
                    succeeded = await store.sendFeedback(signalId: signalId, action: .muteTopic)
                } else {
                    inFlightAction = nil
                    isErrorFeedback = true
                    feedbackMessage = macGatewayL("缺少有效提醒标识，无法静音此类提醒")
                    return
                }
            }

            inFlightAction = nil
            if succeeded {
                completedAction = action
                isErrorFeedback = false
                feedbackMessage = action.successMessage
                onActionCompleted?(action)
            } else {
                isErrorFeedback = true
                feedbackMessage = store.lastError ?? macGatewayL("操作未能完成，请稍后重试")
            }
        }
    }
}

// MARK: - Reusable Proactive Signal Detail Sheet

struct CloudProactiveSignalDetailSheet: View {
    let signalId: String
    @ObservedObject var store: CloudProactiveStore

    private enum LoadState: Equatable {
        case loading
        case loaded(MacGatewayCloudDialogueEvent)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: LoadState = .loading
    @State private var reloadNonce = 0

    init(signalId: String, store: CloudProactiveStore = .shared) {
        self.signalId = signalId
        self._store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(Text(verbatim: macGatewayL("主动提醒详情")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("关闭")) {
                        clearPendingIfMatching()
                        dismiss()
                    }
                }
            }
        }
        .tint(AmberTheme.accent)
        .task(id: "\(signalId):\(reloadNonce)") {
            await fetchSignal()
        }
        .onDisappear {
            clearPendingIfMatching()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(verbatim: macGatewayL("正在加载主动提醒…"))
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

        case .loaded(let event):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CloudProactiveCardView(event: event, store: store)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)

        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(MacDelegationSemanticInk.warning)

                Text(verbatim: macGatewayL("无法加载提醒详情"))
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    MacGatewayCapsuleButton(title: macGatewayL("重试")) {
                        reloadNonce += 1
                    }
                    Button(macGatewayL("关闭")) {
                        clearPendingIfMatching()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
    }

    private func fetchSignal() async {
        loadState = .loading
        if let event = await store.loadSignal(signalId) {
            loadState = .loaded(event)
        } else {
            let reason = store.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (reason?.isEmpty == false)
                ? reason!
                : macGatewayL("未找到该主动提醒，可能已过期或已被清理。")
            loadState = .failed(message)
        }
    }

    private func clearPendingIfMatching() {
        if store.pendingSignalId == signalId {
            store.pendingSignalId = nil
        }
    }
}
