import SwiftUI
import UIKit

enum ChatTopBarPanel: Equatable {
    case shelf
    case shelfCollapsed
    case notices
}

struct ChatTopBarView: View {
    let presentation: ChatIslandPresentation
    let conversationID: String?
    let hasMessages: Bool
    let isGenerating: Bool
    let notices: [ConversationActivityNotice]
    let shelfHeight: CGFloat
    let onBack: () -> Void
    let onIslandTap: (ChatIslandPresentation) -> Void
    let onCancel: () -> Void
    let onOpenConversation: (String) async -> Bool
    let onDismiss: (String) -> Void
    let onNewConversation: () -> Void
    let loadPreview: (String) async -> String?
    let previewRevision: (String) -> String?
    var artifacts = ConversationArtifactIndex(images: [], files: [], webPages: [])
    var snippets: [IOSPinnedSnippet] = []
    var adoptedVersions: [String: String] = [:]
    var conversationTitle = "对话成果"
    var onLocateSnippet: (IOSPinnedSnippet) -> Bool = { _ in false }
    var onUnpinSnippet: (String) -> Void = { _ in }
    var onAdoptVersion: (String, String) -> Void = { _, _ in }
    var onContinueArtifact: (ChatArtifactContinuation) async -> Bool = { _ in false }
    var artifactArrival: ChatArtifactArrival? = nil
    var onLocateArtifact: (ConversationArtifactIndex.Source) -> Bool = { _ in false }
    var dismissShelfRevision = 0
    var onShelfStripHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressedPresentation: ChatIslandPresentation?
    @State var panel: ChatTopBarPanel? = nil
    @State private var arrivalState = ChatTopBarArrivalState()
    @State private var pressedAnnouncementID: String?
    @State private var islandScale: CGFloat = 1
    @State private var flightProgress: CGFloat = 0
    @State private var flightVisible = false
    @State private var artifactFlightProgress: CGFloat = 0
    @State private var artifactFlightVisible = false
    @State private var artifactFlightID: String?
    @State private var dockScale: CGFloat = 1
    @State private var locatedArtifactTitle = "产物架"

    private var arrivalInput: ChatTopBarArrivalState.Input {
        .init(conversationID: conversationID,
              isAwaitingUser: presentation.displayedState.kind == .awaitingUser,
              isGenerating: isGenerating, notices: notices)
    }

    private var announcement: ConversationActivityNotice? {
        isGenerating ? nil : arrivalState.announcement
    }

    private var dockState: ChatTopBarDockState {
        .resolve(hasMessages: hasMessages || !snippets.isEmpty, notices: notices, artifactCount: artifacts.count + snippets.count)
    }

    var body: some View {
        let activeArrival = arrivalState.arrival
        return GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // 两侧玻璃与岛保持独立，避免系统合并玻璃后穿透正文。
                HStack {
                    ChatToolbarIconButton(
                        systemImage: "chevron.left", accessibilityLabel: "返回",
                        size: ChatTopBarLayout.toolbarButtonDiameter, symbolSize: 18, action: onBack
                    )
                    .accessibilityIdentifier("topbar-back")
                    Spacer()
                    ChatTopBarTrailingDock(
                        state: dockState, onTap: tapDock, onDismiss: onDismiss,
                        onNewConversation: onNewConversation, loadPreview: loadPreview,
                        previewRevision: previewRevision,
                        onOpenShelf: { panel = .shelf }
                    )
                    .scaleEffect(reduceMotion ? 1 : dockScale)
                }

                island(maxWidth: ChatTopBarLayout.availableIslandWidth(in: geometry.size.width))
                    .popover(isPresented: panelBinding(.notices), arrowEdge: .top) {
                        noticeList
                            .frame(width: min(340, geometry.size.width))
                            .presentationCompactAdaptation(.popover)
                            .presentationBackground(AmberTheme.background)
                    }

                if flightVisible, !reduceMotion {
                    Circle()
                        .fill(arrivalState.arrival?.kind.tint ?? AmberTheme.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: arrivalState.arrival?.kind.tint ?? AmberTheme.accent, radius: 5)
                        .position(
                            x: geometry.size.width / 2 + (geometry.size.width / 2 - 22) * flightProgress,
                            y: ChatTopBarLayout.controlsHeight - 22 - sin(flightProgress * .pi) * 12
                        )
                        .opacity(1 - flightProgress * 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: ChatTopBarLayout.controlsHeight, alignment: .bottom)
            .overlay(alignment: .topTrailing) {
                if panel == .shelf {
                    ChatArtifactShelfPanel(
                        artifacts: artifacts, maxHeight: shelfHeight,
                        onLocate: locateArtifact, onClose: { panel = nil },
                        snippets: snippets, adoptedVersions: adoptedVersions,
                        conversationTitle: conversationTitle,
                        onLocateSnippet: { snippet in
                            guard onLocateSnippet(snippet) else { return }
                            locatedArtifactTitle = "产物架 · 第 \(snippet.turn) 轮"
                            panel = .shelfCollapsed
                        },
                        onUnpinSnippet: onUnpinSnippet,
                        onAdoptVersion: onAdoptVersion,
                        onContinue: onContinueArtifact
                    )
                    .frame(width: min(340, geometry.size.width - (44 - ChatTopBarLayout.toolbarButtonDiameter)))
                    .frame(height: shelfHeight, alignment: .top)
                    .padding(.trailing, (44 - ChatTopBarLayout.toolbarButtonDiameter) / 2)
                    .padding(.top, ChatTopBarLayout.controlsHeight)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                } else if panel == .shelfCollapsed {
                    ChatArtifactShelfStrip(
                        title: locatedArtifactTitle,
                        onExpand: { panel = .shelf }, onClose: { panel = nil }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        onShelfStripHeightChange(height)
                    }
                    .onDisappear { onShelfStripHeightChange(0) }
                    .frame(width: min(340, geometry.size.width - (44 - ChatTopBarLayout.toolbarButtonDiameter)))
                    .padding(.trailing, (44 - ChatTopBarLayout.toolbarButtonDiameter) / 2)
                    .padding(.top, ChatTopBarLayout.controlsHeight + 8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if artifactFlightVisible, !reduceMotion, let artifactArrival {
                    Image(systemName: artifactArrival.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
                        .scaleEffect(1 - artifactFlightProgress * 0.55)
                        .offset(x: -4 - (1 - artifactFlightProgress) * 32,
                                y: 4 + (1 - artifactFlightProgress) * 84)
                        .opacity(1 - artifactFlightProgress * 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 18)
        .onChange(of: arrivalInput, initial: true) { old, input in
            if old.conversationID != input.conversationID {
                panel = nil
                resetArrivalMotion()
                pressedPresentation = nil
                pressedAnnouncementID = nil
            }
            let arrived = withAnimation(.easeInOut(duration: 0.18)) { arrivalState.update(input) }
            guard let notice = arrived else { return }
            if notice.kind == .awaitingUser {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else if notice.kind == .completed {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if arrivalState.announcement != nil {
                UIAccessibility.post(notification: .announcement,
                                     argument: "\(notice.title)，\(notice.kind.statusTitle)")
            }
        }
        .task(id: activeArrival.map(ChatTopBarArrivalState.Key.init)) {
            guard !Task.isCancelled else { return }
            resetArrivalMotion()
            guard let arrival = activeArrival else { return }
            let key = ChatTopBarArrivalState.Key(arrival)
            defer {
                if arrivalState.arrival.map(ChatTopBarArrivalState.Key.init) == key {
                    resetArrivalMotion()
                    arrivalState.arrival = nil
                    withAnimation(.easeInOut(duration: 0.18)) { arrivalState.announcement = nil }
                }
            }
            if !reduceMotion {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) { islandScale = 1.06 }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                flightVisible = true
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { islandScale = 1 }
                withAnimation(.easeInOut(duration: 0.4)) { flightProgress = 1 }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                flightVisible = false
            }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 2.5 : 1.94)) } catch { return }
        }
        .task(id: artifactArrival?.id) {
            guard !Task.isCancelled else { return }
            artifactFlightID = artifactArrival?.id
            artifactFlightVisible = false
            artifactFlightProgress = 0
            dockScale = 1
            guard let arrival = artifactArrival, !reduceMotion else { return }
            defer {
                if artifactFlightID == arrival.id {
                    artifactFlightVisible = false
                    dockScale = 1
                    artifactFlightID = nil
                }
            }
            artifactFlightVisible = true
            withAnimation(.easeInOut(duration: 0.42)) { artifactFlightProgress = 1 }
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            artifactFlightVisible = false
            withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { dockScale = 1.12 }
            do { try await Task.sleep(for: .milliseconds(130)) } catch { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { dockScale = 1 }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.3, dampingFraction: 0.85), value: panel)
        .onChange(of: dismissShelfRevision) { _, _ in
            if panel == .shelf || panel == .shelfCollapsed { panel = nil }
        }
        .onDisappear {
            resetArrivalMotion()
            arrivalState.arrival = nil
            arrivalState.announcement = nil
            pressedPresentation = nil
            pressedAnnouncementID = nil
        }
        .onChange(of: notices.isEmpty) { _, empty in
            if empty && panel == .notices { panel = nil }
        }
        .onChange(of: hasMessages) { _, hasMessages in
            if !hasMessages && (panel == .shelf || panel == .shelfCollapsed) { panel = nil }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { islandScale = 1; flightVisible = false }
        }
    }

    private func island(maxWidth: CGFloat) -> some View {
        ChatActivityIslandView(presentation: presentation, maxWidth: maxWidth,
                               conversationKey: conversationID, announcement: announcement)
            .frame(height: 44)
            .contentShape(Capsule())
            .scaleEffect(x: reduceMotion ? 1 : islandScale, y: 1)
            .onTapGesture {
                let held = pressedPresentation
                let announcedID = pressedAnnouncementID
                pressedPresentation = nil
                pressedAnnouncementID = nil
                if let announcedID { open(announcedID) }
                else if let held { onIslandTap(held) }
            }
            .onLongPressGesture(minimumDuration: 0.45, pressing: { pressing in
                if pressing {
                    pressedPresentation = presentation
                    pressedAnnouncementID = announcement?.conversationId
                }
            }, perform: {
                guard isGenerating, pressedPresentation != nil else { return }
                pressedPresentation = nil
                pressedAnnouncementID = nil
                onCancel()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("topbar-island")
            .accessibilityHint(announcement != nil ? "轻点进入播报的对话"
                                : (presentation.displayedState.kind == .title ? "当前对话"
                                   : (isGenerating ? "轻点定位当前活动，长按停止生成" : "轻点定位当前活动")))
            .accessibilityAction {
                if let announcement { open(announcement.conversationId) }
                else { onIslandTap(presentation) }
            }
            .accessibilityActions {
                if isGenerating {
                    Button("停止生成") {
                        onCancel()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
            }
    }

    private var noticeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("对话提醒").font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark") { panel = nil }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(notices) { notice in
                        ChatTopBarNoticeRow(notice: notice, onOpen: { open(notice.conversationId) },
                                            onDismiss: { onDismiss(notice.conversationId) })
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .foregroundStyle(AmberTheme.foreground)
        .accessibilityIdentifier("topbar-notice-list")
    }

    private func panelBinding(_ target: ChatTopBarPanel) -> Binding<Bool> {
        Binding(get: { panel == target }, set: { panel = $0 ? target : nil })
    }

    private func resetArrivalMotion() {
        islandScale = 1
        flightProgress = 0
        flightVisible = false
    }

    private func locateArtifact(_ source: ConversationArtifactIndex.Source) {
        guard onLocateArtifact(source) else { return }
        locatedArtifactTitle = "产物架 · 第 \(source.turn) 轮"
        panel = .shelfCollapsed
    }

    private func tapDock() {
        switch dockState {
        case .hidden: break
        case .shelf: panel = .shelf
        case .satellite(let notice, let extraCount):
            if extraCount == 0 { open(notice.conversationId) }
            else { panel = .notices }
        }
    }

    private func open(_ id: String) {
        let wasAwaiting = notices.first { $0.conversationId == id }?.kind == .awaitingUser
        Task {
            if await onOpenConversation(id) {
                panel = nil
                if wasAwaiting { arrivalState.justLeftConversationID = id }
            }
        }
    }
}

extension ConversationActivityNotice.Kind {
    var statusTitle: String {
        switch self {
        case .awaitingUser: "需要确认"
        case .failed: "未完成"
        case .completed: "已完成"
        }
    }

    var tint: Color {
        switch self {
        case .awaitingUser: AmberTheme.accentAmber
        case .failed: AmberTheme.accentRed
        case .completed: AmberTheme.accentGreen
        }
    }
}

private struct ChatTopBarNoticeRow: View {
    let notice: ConversationActivityNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(notice.kind.tint).frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(notice.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(notice.kind.statusTitle).font(.caption).foregroundStyle(notice.kind.tint)
                            .fixedSize().layoutPriority(1)
                    }
                    if let preview = notice.preview {
                        Text(preview).font(.caption).foregroundStyle(AmberTheme.muted).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(notice.title)，\(notice.kind.statusTitle)，\(notice.preview ?? "")")
        .accessibilityAction(named: Text("关闭提醒"), onDismiss)
    }
}
