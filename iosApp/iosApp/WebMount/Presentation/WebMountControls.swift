import Foundation
import SwiftUI
import WebKit

private enum WebMountActionLayout {
    static let minimumButtonSpacing: CGFloat = 12
    static let glassInteractionSpacing: CGFloat = 8
}

private struct WebMountBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct WebMountStationRow: View {
    let site: IOSWebMountSite
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.displayName)
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                        Text("\(authKindText) · \(IOSWebMountRedactor.redactedURL(site.homepageURL) ?? site.homepageURL)")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            WebMountAccessibleSwitch(
                isOn: Binding(
                get: { site.enabled },
                set: { value in
                    Task { @MainActor in onToggle(value) }
                }
                ),
                label: "启用 \(site.displayName)",
                hint: site.enabled ? "关闭后 Agent 不再打开此站点" : "打开后允许 Agent 使用此站点"
            )

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(site.displayName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var iconName: String {
        switch site.authKind {
        case .anonymous: "globe"
        case .cookie: "person.badge.key"
        case .oauth: "key"
        }
    }

    private var authKindText: String {
        switch site.authKind {
        case .anonymous: "无需登录"
        case .cookie: "Cookie 登录"
        case .oauth: "OAuth 登录"
        }
    }

    private var iconColor: Color {
        switch site.authKind {
        case .anonymous: AmberTheme.accentGreen
        case .cookie: AmberTheme.accentAmber
        case .oauth: AmberTheme.accentIndigo
        }
    }
}

struct WebMountToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WebMountAccessibleSwitch(isOn: $isOn, label: title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

@MainActor
private struct WebMountAccessibleSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    let label: String
    var hint: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.onTintColor = UIColor(AmberTheme.accent)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.setOn(isOn, animated: false)
        control.onTintColor = UIColor(AmberTheme.accent)
        control.accessibilityLabel = label
        control.accessibilityHint = hint
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func valueChanged(_ sender: UISwitch) {
            isOn.wrappedValue = sender.isOn
        }
    }
}

struct WebMountInfoRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let trailing: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                infoLeading
                infoTrailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                infoLeading
                infoTrailing
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var infoLeading: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var infoTrailing: some View {
        Text(trailing)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .multilineTextAlignment(.trailing)
    }
}

struct WebMountHandoffActions: View {
    let handoff: IOSWebMountContentHandoff
    let onChat: () -> Void
    let onDeepRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已提取 \(handoff.text.count) 个字符，可转入下一步。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(2)

            AmberGlassGroup(spacing: WebMountActionLayout.glassInteractionSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WebMountActionLayout.minimumButtonSpacing) {
                        handoffButtons
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: WebMountActionLayout.minimumButtonSpacing) {
                        handoffButtons
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var handoffButtons: some View {
        Button(action: onChat) {
            Label("转入聊天", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)

        Button(action: onDeepRead) {
            Label("转入深度阅读", systemImage: "book.pages")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
    }
}

struct WebMountTextFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 88, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct WebMountCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground2)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct WebMountDivider: View {
    var body: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, 58)
    }
}

struct WebMountBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(AmberTheme.foreground2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
            .padding(.horizontal, 16)
    }
}
