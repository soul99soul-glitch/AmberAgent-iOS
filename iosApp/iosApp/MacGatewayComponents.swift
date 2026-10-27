import SwiftUI

/// Rows shared by Settings › Mac Gateway and the task board, so both pages keep one look.
struct MacGatewayRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    var action: (() -> Void)?
    @ViewBuilder let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(icon: String, title: String, detail: String, action: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(minLength: 0); trailing }
            } else {
                trailing.fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 4)
    }

    private var content: some View {
        HStack(spacing: 12) {
            MacGatewayIconPlate(icon: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(AmberTheme.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

struct MacGatewayIconPlate: View {
    let icon: String
    var tint: Color = AmberTheme.accent

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

struct MacGatewayRowDivider: View {
    var body: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
    }
}

struct MacGatewayChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
    }
}

struct MacGatewayCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
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
}

struct MacGatewaySectionFooter: View {
    let text: String
    var color: Color = AmberTheme.muted

    var body: some View {
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

/// The tool call an Amber scheduled run is waiting on, under its card. High-risk calls can only be denied here.
struct MacGatewayApprovalRow: View {
    let approval: MacGatewayBoardItem.Approval
    let store: MacGatewayStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: approval.tool)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approval.highRisk ? AmberTheme.accentRed : AmberTheme.accent)
            if let detail = approval.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            }
            HStack(spacing: 10) {
                if store.decidingCalls.contains(approval.toolCallId) {
                    ProgressView().frame(minHeight: 44)
                } else {
                    MacGatewayCapsuleButton(title: macGatewayL("拒绝")) { decide(false) }
                    if !approval.highRisk {
                        MacGatewayCapsuleButton(title: macGatewayL("批准")) { decide(true) }
                    }
                }
                Spacer(minLength: 0)
            }
            if approval.highRisk {
                Text(verbatim: macGatewayL("高风险操作，请在 Mac 上核对后批准"))
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private func decide(_ allow: Bool) {
        Task { await store.decide(sessionKey: approval.sessionKey, toolCallId: approval.toolCallId, allow: allow) }
    }
}

func macGatewayL(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
