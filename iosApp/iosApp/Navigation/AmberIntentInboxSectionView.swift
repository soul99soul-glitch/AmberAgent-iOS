import SwiftUI

// MARK: - Unslop Direction & Design Contract
//
// - Product: Amber 随口意图候选收件箱，把用户在闲聊中顺带提及的延后事项整理为待确认卡片，一键交办后台或忽略。
// - Character: calm, editorial, exact.
// - World: Warm paper and ink workbench (`AmberTheme` neutral ramp: `surface`, `foreground`, `muted`, `border`).
// - Moments: A quiet 2pt vertical quote rule framing the user's original words (`sourceQuote`) above a single primary action.
// - Signature: Tabular-numeral section header count and 0.6pt hairline card chrome matching `AmberDuetTaskCenterCard`.

/// 可嵌入任务面板（`AmberDuetTaskCenterCard`）或对话抽屉的随口意图候选收件箱组件。
/// 当没有待确认候选时自动不占空间（或按需展示安静空态）。
struct AmberIntentInboxSectionView: View {

    var store: AmberIntentInboxStore = .shared
    /// 可选按当前会话过滤（传 nil 则展示全部待确认候选）
    var conversationId: String? = nil
    /// 是否在无待确认项时完全隐藏（嵌入任务面板时默认隐藏，独立展示时可设为 false）
    var hidesWhenEmpty: Bool = true
    /// 用户点击「交办后台」或「设为盯梢」确认转正后的回调，上层据此创建后台子代理或定时任务
    var onAcceptCandidate: ((AmberIntentDispatchPayload) -> Void)? = nil
    /// 用户点击「忽略」后的可选通知回调
    var onDismissCandidate: ((AmberIntentCandidate) -> Void)? = nil

    private var visibleCandidates: [AmberIntentCandidate] {
        store.pendingCandidates(forConversationId: conversationId)
    }

    var body: some View {
        let items = visibleCandidates
        if items.isEmpty {
            if !hidesWhenEmpty {
                emptyStateCard
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(count: items.count)

                VStack(spacing: 8) {
                    ForEach(items) { candidate in
                        AmberIntentCandidateCardView(
                            candidate: candidate,
                            onAccept: {
                                if let payload = store.accept(id: candidate.id) {
                                    onAcceptCandidate?(payload)
                                }
                            },
                            onDismiss: {
                                if store.dismiss(id: candidate.id) {
                                    onDismissCandidate?(candidate)
                                }
                            }
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.duet.intentInbox.section")
        }
    }

    private func sectionHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(IOSAppLocalization.string("顺手记下的候选待办", defaultValue: "顺手记下的候选待办"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AmberTheme.muted)

            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(AmberTheme.muted2)

            Spacer(minLength: 8)

            Text(IOSAppLocalization.string("确认后才会执行", defaultValue: "确认后才会执行"))
                .font(.system(size: 11))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(.horizontal, 4)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(IOSAppLocalization.string("暂无待确认的随口意图", defaultValue: "暂无待确认的随口意图"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AmberTheme.foreground)

            Text(IOSAppLocalization.string(
                "聊天时提到的“回头查下”“顺便留意”会记在这里，未经确认不会自动运行",
                defaultValue: "聊天时提到的“回头查下”“顺便留意”会记在这里，未经确认不会自动运行"
            ))
            .font(.system(size: 12))
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.border, lineWidth: 0.6)
        }
        .accessibilityIdentifier("chat.duet.intentInbox.empty")
    }
}

// MARK: - Single Candidate Card View

struct AmberIntentCandidateCardView: View {

    let candidate: AmberIntentCandidate
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 顶部标签行：建议类型 + 高风险需确认警示（若有）
            metadataRow

            // 2. 意图标题 + 来源原话引用
            VStack(alignment: .leading, spacing: 8) {
                Text(candidate.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.duet.intentInbox.card.title.\(candidate.id)")

                sourceQuoteBlock
            }

            // 3. 高风险边界说明（仅在 requiresApproval 时显示，明确不会直接执行外部写操作）
            if candidate.riskLevel == .requiresApproval {
                approvalNoticeRow
            }

            // 4. 操作栏：一个主操作 + 一个次操作
            actionRow
        }
        .padding(16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    candidate.riskLevel == .requiresApproval
                        ? AmberTheme.statusAmber.opacity(0.45)
                        : AmberTheme.border,
                    lineWidth: 0.6
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.intentInbox.card.\(candidate.id)")
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: candidate.suggestedKind.systemImageName)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 14, height: 14)

                Text(candidate.suggestedKind.badgeTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AmberTheme.foreground2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let riskBadge = candidate.riskLevel.badgeTitle {
                HStack(spacing: 4) {
                    Circle()
                        .fill(AmberTheme.statusAmber)
                        .frame(width: 6, height: 6)

                    Text(riskBadge)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AmberTheme.statusAmber)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    AmberTheme.statusAmber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .accessibilityIdentifier("chat.duet.intentInbox.card.riskBadge.\(candidate.id)")
            }

            Spacer(minLength: 4)
        }
    }

    private var sourceQuoteBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(AmberTheme.border)
                .frame(width: 2)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            Text("“\(candidate.sourceQuote)”")
                .font(.system(size: 12.5))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.duet.intentInbox.card.quote.\(candidate.id)")
        }
    }

    private var approvalNoticeRow: some View {
        Text(IOSAppLocalization.string(
            "涉及外发、修改配置或交易等敏感动作，交办后仅先准备方案，实际执行前需你再次批准",
            defaultValue: "涉及外发、修改配置或交易等敏感动作，交办后仅先准备方案，实际执行前需你再次批准"
        ))
        .font(.system(size: 11.5))
        .foregroundStyle(AmberTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: onAccept) {
                Text(candidate.suggestedKind.primaryActionTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AmberTheme.accentInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.intentInbox.card.accept.\(candidate.id)")

            Button(action: onDismiss) {
                Text(IOSAppLocalization.string("忽略", defaultValue: "忽略"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.intentInbox.card.dismiss.\(candidate.id)")

            Spacer(minLength: 4)
        }
    }
}
