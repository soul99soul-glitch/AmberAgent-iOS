import SwiftUI

struct IshHandoffToolApprovalCard: View {
    let request: IshHandoffToolApprovalRequest
    let onApprove: (IshToolApprovalScope) -> Void
    let onDeny: () -> Void
    @State private var showsFullCommand = false
    @State private var approvalScope: IshToolApprovalScope = .once
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var commandNeedsExpansion: Bool {
        request.commandPreview.count > 240
            || request.commandPreview.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accentAmber.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text(request.reason)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.filename)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(request.contextLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsFullCommand {
                    ScrollView(.vertical) {
                        Text(request.commandPreview)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                    .accessibilityLabel("完整命令，共 \(request.commandPreview.count) 个字符")
                } else {
                    Text(request.commandPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(commandNeedsExpansion ? 4 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if commandNeedsExpansion {
                    Button(showsFullCommand ? "收起完整命令" : "展开完整命令") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            showsFullCommand.toggle()
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityHint(request.commandReviewAccessibilityHint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AmberTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            HStack(spacing: 6) {
                WebMountApprovalChip(systemImage: request.primaryChip.systemImage, title: request.primaryChip.title)
                WebMountApprovalChip(systemImage: request.secondaryChip.systemImage, title: request.secondaryChip.title)
                Spacer(minLength: 0)
            }

            if request.mode == .amberShell {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentAmber)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("批准范围")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                        Text("仅这一次")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground2)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(
                    AmberTheme.surface2.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityLabel("批准范围，仅这一次")

                Text("当前策略需要逐次前台审批；开启高风险自动批准后可跳过。")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu {
                    scopeButton(.once)
                    scopeButton(.session)
                    scopeButton(.global)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: approvalScope.systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.accentAmber)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("批准范围")
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                            Text(approvalScope.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground2)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        AmberTheme.surface2.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("批准范围，\(approvalScope.title)")
                .accessibilityHint("选择仅这一次、本次会话或全局自动批准")

                Text(approvalScope.detail)
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if approvalScope == .global {
                    Label(
                        "此设置会持续生效，直到你在设置中关闭；其他高风险工具也可能跳过逐次确认。",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: -4))
                    )
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Label("拒绝", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
                }
                .buttonStyle(IshApprovalPressStyle())
                .chatApprovalHitTarget()
                .accessibilityLabel("拒绝\(request.title)")

                Button {
                    onApprove(approvalScope)
                } label: {
                    Label(approvalScope == .global ? "批准并开启" : "批准", systemImage: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 32)
                        .background(AmberTheme.accent, in: Capsule())
                }
                .buttonStyle(IshApprovalPressStyle())
                .chatApprovalHitTarget()
                .accessibilityLabel(
                    approvalScope == .global
                        ? "批准\(request.title)并开启全局自动批准"
                        : "批准\(request.title)，范围：\(approvalScope.title)"
                )
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accentAmber.opacity(0.38), lineWidth: 0.7)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: approvalScope
        )
    }

    private func scopeButton(_ scope: IshToolApprovalScope) -> some View {
        Button {
            approvalScope = scope
        } label: {
            Label(scope.title, systemImage: approvalScope == scope ? "checkmark" : scope.systemImage)
        }
    }
}

private extension IshToolApprovalScope {
    var title: String {
        switch self {
        case .once: "仅这一次"
        case .session: "本次会话"
        case .global: "全局自动批准"
        }
    }

    var detail: String {
        switch self {
        case .once:
            "只批准当前这一次终端操作。"
        case .session:
            "当前对话后续同类终端操作将自动批准；App 重启后失效。"
        case .global:
            "同步开启设置中的「高风险自动批准」。"
        }
    }

    var systemImage: String {
        switch self {
        case .once: "checkmark.circle"
        case .session: "bubble.left.and.bubble.right"
        case .global: "exclamationmark.shield"
        }
    }
}

private struct IshApprovalPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
