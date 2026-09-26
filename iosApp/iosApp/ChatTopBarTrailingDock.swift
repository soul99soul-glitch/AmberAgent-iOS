import SwiftUI

enum ChatTopBarDockState: Equatable {
    case hidden
    case shelf(count: Int)
    case satellite(notice: ConversationActivityNotice, extraCount: Int)

    static func resolve(
        hasMessages: Bool,
        notices: [ConversationActivityNotice],
        artifactCount: Int = 0
    ) -> Self {
        if let notice = notices.first {
            return .satellite(notice: notice, extraCount: notices.count - 1)
        }
        guard hasMessages else { return .hidden }
        return .shelf(count: artifactCount)
    }
}

struct ChatTopBarTrailingDock: View {
    let state: ChatTopBarDockState
    let onTap: () -> Void
    let onDismiss: (String) -> Void
    let onNewConversation: () -> Void
    let loadPreview: (String) async -> String?
    var previewRevision: (String) -> String? = { _ in nil }
    var onOpenShelf: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedPreview: String?

    private struct PreviewRequest: Hashable {
        let conversationId: String
        let occurredAt: Date
        let revision: String?
    }

    private var notice: ConversationActivityNotice? {
        guard case let .satellite(notice, _) = state else { return nil }
        return notice
    }

    private var previewRequest: PreviewRequest? {
        notice.map { PreviewRequest(conversationId: $0.conversationId, occurredAt: $0.occurredAt, revision: previewRevision($0.conversationId)) }
    }

    var body: some View {
        Group {
            if case .hidden = state {
                EmptyView()
            } else {
                dockButton
            }
        }
        .task(id: previewRequest) {
            guard let previewRequest else {
                loadedPreview = nil
                return
            }
            loadedPreview = nil
            let preview = await loadPreview(previewRequest.conversationId)
            guard !Task.isCancelled else { return }
            loadedPreview = preview
        }
    }

    private var dockButton: some View {
        Group {
            if case let .satellite(notice, _) = state {
                dockButtonContent
                    .highPriorityGesture(dismissGesture)
                    .accessibilityAction(named: Text("关闭提醒")) {
                        onDismiss(notice.conversationId)
                    }
                    .contextMenu {
                        Button("产物架", systemImage: "tray.full", action: onOpenShelf)
                        Button("新对话", systemImage: "plus.message", action: onNewConversation)
                    } preview: {
                        noticePreview(notice)
                    }
            } else {
                dockButtonContent
                    .contextMenu {
                        Button("新对话", systemImage: "plus.message", action: onNewConversation)
                    }
            }
        }
    }

    private var dockButtonContent: some View {
        Button(action: onTap) {
            ZStack {
                dockGlass

                Image(systemName: symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(symbolTint)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(badgeTint, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.86), lineWidth: 1))
                        .frame(width: ChatTopBarLayout.toolbarButtonDiameter,
                               height: ChatTopBarLayout.toolbarButtonDiameter,
                               alignment: .topTrailing)
                        .padding(1)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: ChatTopBarLayout.toolbarButtonDiameter,
                   height: ChatTopBarLayout.toolbarButtonDiameter)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.9, haptic: .lightImpact))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("topbar-dock")
        .animation(dockAnimation, value: state)
    }

    private func noticePreview(_ notice: ConversationActivityNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice.title, systemImage: "bubble.left.fill")
                .font(.headline)
                .lineLimit(1)
            Text(loadedPreview ?? notice.preview ?? "没有可预览的文字")
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(12)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(16)
        .frame(maxHeight: 300, alignment: .topLeading)
    }

    private var dockGlass: some View {
        Circle()
            .fill(AmberTheme.glass.opacity(0.16))
            .overlay {
                if let dockTint {
                    Circle().fill(dockTint.opacity(0.12))
                }
            }
            .overlay {
                if case let .satellite(notice, _) = state,
                   notice.kind == .awaitingUser,
                   !reduceMotion {
                    Circle()
                        .stroke(AmberTheme.accentAmber.opacity(0.52), lineWidth: 1.5)
                        .phaseAnimator([false, true]) { content, phase in
                            content
                                .scaleEffect(phase ? 1.12 : 0.92)
                                .opacity(phase ? 0.18 : 0.72)
                        } animation: { _ in
                            .easeInOut(duration: 1.15)
                        }
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Circle().stroke((dockTint ?? AmberTheme.border).opacity(0.28), lineWidth: 0.5)
            }
            .modifier(ChatTopBarDockGlass())
            .frame(width: ChatTopBarLayout.toolbarButtonDiameter,
                   height: ChatTopBarLayout.toolbarButtonDiameter)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch state {
        case .hidden, .shelf:
            "tray.full"
        case let .satellite(notice, _):
            switch notice.kind {
            case .awaitingUser: "questionmark.bubble.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .completed: "checkmark"
            }
        }
    }

    private var dockTint: Color? {
        guard case let .satellite(notice, _) = state else { return nil }
        return switch notice.kind {
        case .awaitingUser: AmberTheme.accentAmber
        case .failed: AmberTheme.accentRed
        case .completed: AmberTheme.accentGreen
        }
    }

    private var symbolTint: Color {
        dockTint ?? AmberTheme.foreground
    }

    private var badgeText: String? {
        switch state {
        case let .shelf(count):
            count > 0 ? Self.badgeText(count) : nil
        case let .satellite(_, extraCount):
            extraCount > 0 ? Self.badgeText(extraCount + 1) : nil
        case .hidden:
            nil
        }
    }

    private var badgeTint: Color {
        dockTint ?? AmberTheme.accent
    }

    private var accessibilityLabel: String {
        switch state {
        case .hidden:
            ""
        case let .shelf(count):
            "产物架，\(count) 项"
        case let .satellite(notice, _):
            switch notice.kind {
            case .awaitingUser: "等待确认：\(notice.title)"
            case .failed: "对话未完成：\(notice.title)"
            case .completed: "对话已完成：\(notice.title)"
            }
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .hidden:
            ""
        case let .shelf(count):
            "\(count) 项成果"
        case let .satellite(_, extraCount):
            extraCount > 0 ? "还有 \(extraCount) 条提醒" : ""
        }
    }

    private var accessibilityHint: String {
        switch state {
        case .hidden:
            ""
        case .shelf:
            "轻点打开产物架，长按可新建对话"
        case let .satellite(_, extraCount):
            extraCount > 0
                ? "轻点查看提醒列表，向上滑动可关闭当前提醒，长按可预览最后一条消息"
                : "轻点进入对话，向上滑动可关闭提醒，长按可预览最后一条消息"
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                guard value.translation.height < -24,
                      abs(value.translation.height) > abs(value.translation.width) * 1.2,
                      let notice else { return }
                onDismiss(notice.conversationId)
            }
    }

    private var dockAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.28, dampingFraction: 0.78)
    }

    static func badgeText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

private struct ChatTopBarDockGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(AmberTheme.border.opacity(0.28), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}
