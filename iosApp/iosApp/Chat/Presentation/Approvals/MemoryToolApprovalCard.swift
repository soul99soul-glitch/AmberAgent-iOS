import SwiftUI

struct MemoryToolApprovalCard: View {
    let request: MemoryToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accentAmber.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(cardTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text(request.reason)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Text(bodyPreview)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AmberTheme.surface.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(detailChips) { chip in
                        MemoryToolApprovalChip(chip: chip)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detailChips) { chip in
                        MemoryToolApprovalChip(chip: chip)
                    }
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
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("拒绝记忆写入")

                Button(action: onApprove) {
                    Label(approveLabel, systemImage: approveSystemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(approveColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel(approveLabel)
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cardTint.opacity(0.34), lineWidth: 0.7)
        }
    }

    private var bodyPreview: String {
        if isDestructive {
            if let targetId = request.targetId {
                return "将永久删除 ID 为 \(targetId) 的已保存记忆。\n\(request.contentPreview ?? "此操作不可撤销。")"
            }
            return "将永久删除这条已保存记忆。\n\(request.contentPreview ?? "此操作不可撤销。")"
        }
        if let contentPreview = request.contentPreview {
            return contentPreview
        }
        if let targetId = request.targetId {
            return "目标记忆 ID \(targetId)"
        }
        return "模型请求修改已保存记忆。"
    }

    private var detailChips: [MemoryToolApprovalChipModel] {
        var chips: [MemoryToolApprovalChipModel] = [
            MemoryToolApprovalChipModel(systemImage: "bolt.horizontal", title: actionLabel)
        ]
        if let scope = request.scope {
            chips.append(MemoryToolApprovalChipModel(systemImage: "tray.full", title: scopeLabel(scope)))
        }
        if let kind = request.kind {
            chips.append(MemoryToolApprovalChipModel(systemImage: "tag", title: kindLabel(kind)))
        }
        if let targetId = request.targetId {
            chips.append(MemoryToolApprovalChipModel(systemImage: "number", title: "\(targetId)"))
        }
        return chips
    }

    private var isDestructive: Bool {
        ["delete", "remove"].contains(request.action.lowercased())
    }

    private var isEdit: Bool {
        ["edit", "update"].contains(request.action.lowercased())
    }

    private var actionLabel: String {
        switch request.action.lowercased() {
        case "create", "add", "write": "保存"
        case "edit", "update": "编辑"
        case "delete", "remove": "删除"
        default: request.action
        }
    }

    private var cardTitle: String {
        if isDestructive { return "删除记忆" }
        if isEdit { return "编辑记忆" }
        return request.title
    }

    private var approveLabel: String {
        if isDestructive { return "删除" }
        if isEdit { return "保存修改" }
        return "保存"
    }

    private var approveSystemImage: String { isDestructive ? "trash" : "checkmark" }
    private var approveColor: Color { isDestructive ? AmberTheme.accentRed : AmberTheme.accent }
    private var cardTint: Color { isDestructive ? AmberTheme.accentRed : AmberTheme.accentAmber }

    private func scopeLabel(_ value: String) -> String {
        switch value {
        case "core":
            "核心"
        case "short_term":
            "短期"
        case "long_term":
            "长期"
        default:
            value
        }
    }

    private func kindLabel(_ value: String) -> String {
        switch value {
        case "note":
            "笔记"
        case "user":
            "用户"
        case "feedback":
            "反馈"
        case "project":
            "项目"
        case "reference":
            "参考"
        case "routine":
            "惯例"
        default:
            value
        }
    }
}

private struct MemoryToolApprovalChipModel: Identifiable {
    let systemImage: String
    let title: String

    var id: String { "\(systemImage)-\(title)" }
}

private struct MemoryToolApprovalChip: View {
    let chip: MemoryToolApprovalChipModel

    var body: some View {
        Label(chip.title, systemImage: chip.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AmberTheme.surface2.opacity(0.64), in: Capsule())
    }
}

extension View {
    func chatApprovalHitTarget() -> some View {
        frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
