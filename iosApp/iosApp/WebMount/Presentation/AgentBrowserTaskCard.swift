import Foundation
import SwiftUI
import WebKit

@MainActor
struct AgentBrowserTaskCard: View {
    let record: IOSWebMountSessionRecord
    let onCollapse: (() -> Void)?
    let onHide: (() -> Void)?
    let onOpen: () -> Void

    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        record: IOSWebMountSessionRecord,
        onCollapse: (() -> Void)? = nil,
        onHide: (() -> Void)? = nil,
        onOpen: @escaping () -> Void
    ) {
        self.record = record
        self.onCollapse = onCollapse
        self.onHide = onHide
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                taskIdentity
                Spacer(minLength: 4)
                collapseButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            Divider()
                .overlay(AmberTheme.borderSoft)
                .padding(.leading, 54)

            HStack(spacing: 8) {
                statusBadge
                backendLabel
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text(openLabel)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("\(openLabel)，\(siteTitle)，\(status.label)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
        .simultaneousGesture(collapseGesture)
        .offset(y: min(12, dragTranslation * 0.24))
    }

    @ViewBuilder
    private var collapseButton: some View {
        if onCollapse != nil || onHide != nil {
            HStack(spacing: 2) {
                if onHide != nil {
                    Button(action: hide) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("隐藏浏览器任务")
                    .accessibilityHint("保留网页会话，可从 WebMount 管理页找回")
                }
                if onCollapse != nil {
                    Button(action: collapse) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起浏览器任务")
                    .accessibilityHint("向下拖动或轻点收起")
                }
            }
        }
    }

    private var collapseGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let projected = max(value.translation.height, value.predictedEndTranslation.height)
                guard projected > 44, abs(value.translation.height) > abs(value.translation.width) else { return }
                collapse()
            }
    }

    private func collapse() {
        guard let onCollapse else { return }
        withAnimation(collapseAnimation) {
            onCollapse()
        }
    }

    private func hide() {
        guard let onHide else { return }
        withAnimation(collapseAnimation) {
            onHide()
        }
    }

    private var collapseAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var taskIdentity: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(width: 34, height: 34)
                .background(
                    AmberTheme.surface2,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(siteTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(pageSummary)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: status.image)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 24, height: 24)
                .background(
                    status.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Circle()
                .fill(status.tint)
                .frame(width: 5, height: 5)
            Text(status.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var backendLabel: some View {
        Label(backendTitle, systemImage: record.backend == .local ? "iphone" : "desktopcomputer")
            .font(.caption2)
            .foregroundStyle(AmberTheme.muted)
    }

    private var backendTitle: String {
        record.backend == .local ? "本机浏览器" : record.backend.title
    }

    private var siteTitle: String {
        displayInfo.siteTitle
    }

    private var pageSummary: String {
        displayInfo.pageSummary
    }

    private var openLabel: String {
        if record.needsReopen { return IOSAppLocalization.string("重新打开", defaultValue: "重新打开") }
        return record.backend == .local ? "观看页面" : "查看状态"
    }

    private var status: (label: String, image: String, tint: Color) {
        displayInfo.status
    }

    private var displayInfo: AgentBrowserTaskDisplayInfo {
        AgentBrowserTaskDisplayInfo(record: record)
    }
}

@MainActor
struct AgentBrowserTaskCompactBar: View {
    let record: IOSWebMountSessionRecord
    let runSummary: String?
    let onExpand: () -> Void

    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: displayInfo.status.image)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(displayInfo.status.tint)
                .frame(width: 22, height: 22)
                .background(displayInfo.status.tint.opacity(0.12), in: Circle())

            Text(summary)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AmberTheme.accent)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .agentBrowserSummaryGlass(cornerRadius: 18)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .offset(y: max(-8, dragTranslation * 0.18))
        .onTapGesture(perform: expand)
        .simultaneousGesture(expandGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat-browser-task-compact")
        .accessibilityLabel(summary)
        .accessibilityHint("轻点或向上滑动展开浏览器任务")
        .accessibilityAction(named: "展开浏览器任务", expand)
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = min(0, value.translation.height)
            }
            .onEnded { value in
                let projected = min(value.translation.height, value.predictedEndTranslation.height)
                guard projected < -36, abs(value.translation.height) > abs(value.translation.width) else { return }
                expand()
            }
    }

    private func expand() {
        withAnimation(animation) {
            onExpand()
        }
    }

    private var summary: String {
        runSummary?.nilIfBlank ?? displayInfo.fallbackSummary
    }

    private var displayInfo: AgentBrowserTaskDisplayInfo {
        AgentBrowserTaskDisplayInfo(record: record)
    }

    private var animation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }
}

private extension View {
    @ViewBuilder
    func agentBrowserSummaryGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            background(AmberTheme.accent.opacity(0.08), in: shape)
                .glassEffect(
                    .regular.tint(AmberTheme.accent.opacity(0.28)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.fill(AmberTheme.accent.opacity(0.10))
                }
                .overlay {
                    shape.stroke(AmberTheme.accent.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: AmberTheme.accent.opacity(0.12), radius: 10, y: 3)
        }
    }
}

@MainActor
private struct AgentBrowserTaskDisplayInfo {
    let record: IOSWebMountSessionRecord

    var siteTitle: String {
        record.siteName?.nilIfBlank ?? record.title.nilIfBlank ?? "未命名页面"
    }

    var pageSummary: String {
        guard let rawURL = record.redactedURL.nilIfBlank,
              let components = URLComponents(string: rawURL),
              let host = components.host?.nilIfBlank else {
            return record.redactedURL.nilIfBlank ?? "尚未打开页面"
        }
        let path = components.percentEncodedPath
        return path.isEmpty || path == "/" ? host : host + path
    }

    var fallbackSummary: String {
        [status.label, siteTitle, pageSummary]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { parts, value in
                if parts.last != value { parts.append(value) }
            }
            .joined(separator: " · ")
    }

    var status: (label: String, image: String, tint: Color) {
        if record.needsReopen {
            return ("需要重新打开", "arrow.clockwise", AmberTheme.accentAmber)
        }
        switch record.controlOwner {
        case .user:
            return ("需要你处理", "person.crop.circle.badge.exclamationmark", AmberTheme.accentAmber)
        case .agent:
            return ("Agent 浏览中", "cursorarrow.click.2", AmberTheme.statusAmber)
        case .none:
            break
        }
        switch record.status {
        case IOSWebMountRuntimeStatus.ready.rawValue:
            return (IOSAppLocalization.string("可接管", defaultValue: "可接管"), "hand.tap", AmberTheme.muted)
        case IOSWebMountRuntimeStatus.loading.rawValue:
            return ("正在加载", "arrow.triangle.2.circlepath", AmberTheme.accentAmber)
        case IOSWebMountRuntimeStatus.failed.rawValue:
            return ("浏览失败", "exclamationmark.triangle", AmberTheme.accentRed)
        default:
            return ("等待 Agent", "clock", AmberTheme.muted)
        }
    }
}
