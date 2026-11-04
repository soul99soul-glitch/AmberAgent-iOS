import Shared
import SwiftUI

// MARK: - Argon 3+1 Right-Side Host Switcher Pill (本机 ⇄ 云端)

struct AmberHostSwitcherPill: View {
    let gateway: MacGatewayStore
    let onSelectHost: (Bool) -> Void
    let onOpenPairingSettings: () -> Void

    private var isPaired: Bool {
        gateway.connection != nil
    }

    private var isCloudSelected: Bool {
        isPaired && gateway.isCloudMainDialogueSelected
    }

    private var isCloudReachable: Bool {
        gateway.isReachable != false
    }

    var body: some View {
        Button {
            AmberHaptics.trigger(.selection)
            if isPaired {
                onSelectHost(!isCloudSelected)
            } else {
                onOpenPairingSettings()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCloudSelected ? "icloud" : "iphone")
                    .font(.system(size: 11.5, weight: isCloudSelected ? .semibold : .medium))
                    .foregroundStyle(iconColor)

                Text(
                    isCloudSelected
                        ? IOSAppLocalization.string("云端", defaultValue: "云端")
                        : IOSAppLocalization.string("本机", defaultValue: "本机")
                )
                .font(.system(size: 12.5, weight: isCloudSelected ? .semibold : .medium))
                .foregroundStyle(isPaired || !isCloudSelected ? AmberTheme.foreground : AmberTheme.muted)
                .lineLimit(1)

                if let dotColor = statusDotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 9.5)
            .modifier(DuetBottomCapsuleGlass(isHighlighted: isCloudSelected))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.97, haptic: .none))
        .contentShape(.contextMenuPreview, Capsule(style: .continuous))
        .contextMenu {
            Button {
                AmberHaptics.trigger(.selection)
                onSelectHost(false)
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("📱 本机 Amber", defaultValue: "📱 本机 Amber"))
                    if !isCloudSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                AmberHaptics.trigger(.selection)
                if isPaired {
                    onSelectHost(true)
                } else {
                    onOpenPairingSettings()
                }
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("☁️ 云端真身", defaultValue: "☁️ 云端真身"))
                    if isCloudSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                AmberHaptics.trigger(.selection)
                onOpenPairingSettings()
            } label: {
                Label(
                    IOSAppLocalization.string("云端配对与连接设置…", defaultValue: "云端配对与连接设置…"),
                    systemImage: "slider.horizontal.3"
                )
            }
        }
        .accessibilityLabel(
            isCloudSelected
                ? IOSAppLocalization.string("当前云端对话，点按切回本机，长按打开宿主菜单", defaultValue: "当前云端对话，点按切回本机，长按打开宿主菜单")
                : (isPaired
                    ? IOSAppLocalization.string("当前本机对话，点按切到云端真身，长按打开宿主菜单", defaultValue: "当前本机对话，点按切到云端真身，长按打开宿主菜单")
                    : IOSAppLocalization.string("当前本机对话，点按配对云端，长按打开宿主菜单", defaultValue: "当前本机对话，点按配对云端，长按打开宿主菜单"))
        )
        .accessibilityIdentifier("chat.duet.hostSwitcherPill")
    }

    private var iconColor: Color {
        if isCloudSelected {
            return isCloudReachable ? AmberTheme.accent : AmberTheme.muted
        }
        return isPaired ? AmberTheme.foreground2 : AmberTheme.muted
    }

    private var statusDotColor: Color? {
        if isCloudSelected {
            return isCloudReachable ? AmberTheme.accent : AmberTheme.muted.opacity(0.55)
        }
        if isPaired {
            return isCloudReachable ? AmberTheme.accent.opacity(0.72) : AmberTheme.muted.opacity(0.45)
        }
        return nil
    }
}

// MARK: - Inline Paired Cloud Main Dialogue View (Embedded in ChatView)

struct AmberInlineCloudMainDialogueView: View {
    let store: MacGatewayStore
    let topInset: CGFloat
    let onOpenPairingSettings: () -> Void

    private var sortedProgressItems: [MacGatewayCloudDialogueWorkItemProgress] {
        store.cloudDialogueProgressByWorkItem.values.sorted { $0.lastEventSeq > $1.lastEventSeq }
    }

    private var unmergedFollowups: [MacGatewayCloudDialogueFollowupRecord] {
        store.cloudDialogueFollowups.filter { record in
            !store.cloudDialogueVisibleEvents.contains(where: { $0.id == record.eventId })
        }
    }

    private var scrollTailToken: String {
        let lastEvent = store.cloudDialogueVisibleEvents.last
        let liveSeq = sortedProgressItems.first?.lastEventSeq ?? 0
        return "\(lastEvent?.id ?? "none"):\(lastEvent?.seq ?? 0):\(unmergedFollowups.count):\(liveSeq)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: max(8, topInset))

                    cloudHostHeaderBanner

                    if !sortedProgressItems.isEmpty {
                        liveProgressSection
                    }

                    if store.cloudDialogueVisibleEvents.isEmpty && unmergedFollowups.isEmpty && sortedProgressItems.isEmpty {
                        emptyCloudConversationCard
                    } else {
                        ForEach(store.cloudDialogueVisibleEvents) { event in
                            cloudEventBubble(event)
                                .id("cloud-event-\(event.id)")
                        }

                        ForEach(unmergedFollowups) { followup in
                            followupBubble(followup)
                                .id("cloud-followup-\(followup.requestId)")
                        }
                    }

                    Color.clear
                        .frame(height: 12)
                        .id("cloud-dialogue-bottom-anchor")
                }
                .padding(.horizontal, ChatLayout.contentHorizontalInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                store.startCloudDialoguePollingIfNeeded()
                Task {
                    _ = await store.pollCloudDialogueEvents()
                }
                proxy.scrollTo("cloud-dialogue-bottom-anchor", anchor: .bottom)
            }
            .onChange(of: scrollTailToken) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("cloud-dialogue-bottom-anchor", anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("chat.cloudMainDialogue.inlineView")
    }

    private var cloudHostHeaderBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isReachable != false ? AmberTheme.accent : AmberTheme.muted)
                .frame(width: 6.5, height: 6.5)

            Text(
                store.connection.map { "24h 云端真身 · \($0.name)" }
                    ?? IOSAppLocalization.string("24h 云端真身", defaultValue: "24h 云端真身")
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.foreground2)
            .lineLimit(1)

            Spacer(minLength: 6)

            Button {
                Task {
                    await store.refresh()
                    _ = await store.pollCloudDialogueEvents()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(IOSAppLocalization.string("刷新云端对话", defaultValue: "刷新云端对话"))

            Button {
                onOpenPairingSettings()
            } label: {
                Text(IOSAppLocalization.string("连接设置", defaultValue: "连接设置"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
    }

    private var liveProgressSection: some View {
        VStack(spacing: 8) {
            ForEach(sortedProgressItems) { progress in
                HStack(spacing: 8) {
                    if progress.isLive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: progress.outcome == .completed ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(progress.outcome == .completed ? AmberTheme.accentGreen : AmberTheme.muted)
                    }

                    Text(verbatim: progress.displaySingleLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if progress.isLive {
                        Button(macGatewayL("补充")) {
                            store.selectedCloudDialogueWorkItemId = progress.workItemId
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
                        .buttonStyle(.plain)

                        Button(macGatewayL("停止")) {
                            Task { _ = await store.stopCloudWorkItem(workItemId: progress.workItemId) }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AmberTheme.accentRed.opacity(0.12), in: Capsule(style: .continuous))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(progress.isLive ? AmberTheme.accent.opacity(0.32) : AmberTheme.borderSoft, lineWidth: 0.75)
                }
            }
        }
    }

    private var emptyCloudConversationCard: some View {
        let soul = AgentSoulStore.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                Text("\(soul.displayName) · 云端真身在线")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
            }

            Text(
                IOSAppLocalization.string(
                    "当前主界面已直连 24h 云端真身，共享同一份形象人设。直接在下方输入框发消息即可交代长任务或连续对话；点按右下角「云端」胶囊可随时一键切回本机。",
                    defaultValue: "当前主界面已直连 24h 云端真身，共享同一份形象人设。直接在下方输入框发消息即可交代长任务或连续对话；点按右下角「云端」胶囊可随时一键切回本机。"
                )
            )
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func cloudEventBubble(_ event: MacGatewayCloudDialogueEvent) -> some View {
        let isUser = event.role == "user" || event.kind == .userMessage || event.kind == .followup
        if isUser {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: event.text)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                        }

                    if event.kind == .followup,
                       let followup = store.cloudDialogueFollowups.first(where: {
                           $0.eventId == event.id || ($0.workItemId == event.workItemId && $0.text == event.text)
                       }) {
                        Text(verbatim: followup.state.displayBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: AgentSoulStore.shared.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                    Text("· 云端")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                    if let outcome = event.outcome {
                        Text(verbatim: outcome.displayTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(outcome == .completed ? AmberTheme.accentGreen : AmberTheme.muted)
                    }
                    Spacer()
                }

                Text(verbatim: event.text)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
            }
        }
    }

    private func followupBubble(_ followup: MacGatewayCloudDialogueFollowupRecord) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: followup.text)
                    .font(.subheadline)
                    .foregroundStyle(followup.state == .cancelled ? AmberTheme.muted : AmberTheme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(verbatim: followup.state.displayBadgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
            }
        }
    }
}

// MARK: - Explicit Paired Cloud Main Dialogue Sheet View

struct MacGatewayCloudDialogueSheet: View {
    let store: MacGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var activeRequestId = UUID().uuidString.lowercased()
    @State private var lastAttemptedFingerprint: String?
    @State private var errorMessage: String?
    @State private var isSending = false

    private var currentFingerprint: String {
        "\(store.selectedCloudDialogueWorkItemId ?? "main")\u{0000}\(inputText)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.cloudDialogueProgressByWorkItem.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(store.cloudDialogueProgressByWorkItem.values.sorted(by: { $0.lastEventSeq > $1.lastEventSeq }))) { progress in
                            HStack(spacing: 8) {
                                if progress.isLive {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: progress.outcome == .completed ? "checkmark.circle.fill" : "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(progress.outcome == .completed ? AmberTheme.accentGreen : AmberTheme.muted)
                                }
                                Text(verbatim: progress.displaySingleLine)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AmberTheme.foreground)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if progress.isLive {
                                    Button(macGatewayL("补充")) {
                                        store.selectedCloudDialogueWorkItemId = progress.workItemId
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)

                                    Button(macGatewayL("停止"), role: .destructive) {
                                        Task { _ = await store.stopCloudWorkItem(workItemId: progress.workItemId) }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                List {
                    ForEach(store.cloudDialogueVisibleEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: event.role == "user" ? macGatewayL("你") : "Amber Cloud")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                if let workItemId = event.workItemId {
                                    Text(verbatim: workItemId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(AmberTheme.muted2)
                                }
                                Spacer()
                                if event.kind == .followup,
                                   let followup = store.cloudDialogueFollowups.first(where: { $0.eventId == event.id || ($0.workItemId == event.workItemId && $0.text == event.text) }) {
                                    Text(verbatim: followup.state.displayBadgeText)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                                }
                            }
                            Text(verbatim: event.text)
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(store.cloudDialogueFollowups.filter { record in
                        !store.cloudDialogueVisibleEvents.contains(where: { $0.id == record.eventId })
                    }) { followup in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: macGatewayL("任务补充"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                Spacer()
                                Text(verbatim: followup.state.displayBadgeText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                            }
                            Text(verbatim: followup.text)
                                .font(.subheadline)
                                .foregroundStyle(followup.state == .cancelled ? AmberTheme.muted : AmberTheme.foreground)
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let targetWorkItemId = store.selectedCloudDialogueWorkItemId {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AmberTheme.accent)
                            Text(verbatim: "\(macGatewayL("补充运行中任务"))：\(targetWorkItemId)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.selectedCloudDialogueWorkItemId = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        TextField(
                            store.selectedCloudDialogueWorkItemId == nil
                                ? macGatewayL("发送消息给已配对云主对话…")
                                : macGatewayL("向选中任务追加补充说明…"),
                            text: $inputText,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                        Button(macGatewayL("发送")) {
                            sendInput()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(AmberTheme.surface)
            }
            .navigationTitle(Text(verbatim: macGatewayL("已配对云主对话")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("关闭")) {
                        store.setCloudMainDialogueSelected(false)
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.setCloudMainDialogueSelected(true)
            }
        }
        .tint(AmberTheme.accent)
    }

    private func sendInput() {
        if let lastAttemptedFingerprint, lastAttemptedFingerprint != currentFingerprint {
            activeRequestId = UUID().uuidString.lowercased()
        }
        lastAttemptedFingerprint = currentFingerprint
        let reqId = activeRequestId
        let text = inputText
        let targetWorkItemId = store.selectedCloudDialogueWorkItemId
        isSending = true
        errorMessage = nil

        Task { @MainActor in
            let result: Result<MacGatewayCloudDialogueReceipt, Error>
            if let targetWorkItemId {
                result = await store.sendCloudWorkItemInput(workItemId: targetWorkItemId, text: text, requestId: reqId)
            } else {
                result = await store.sendCloudDialogueMessage(text: text, requestId: reqId)
            }
            isSending = false
            switch result {
            case .success:
                inputText = ""
                activeRequestId = UUID().uuidString.lowercased()
                lastAttemptedFingerprint = nil
                _ = await store.pollCloudDialogueEvents()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
