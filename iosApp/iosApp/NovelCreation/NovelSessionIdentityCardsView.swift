import SwiftUI

struct NovelSessionIdentityCardsView: View {
    let viewModel: NovelSessionViewModel
    let onAcceptSettingProposal: (NovelSettingProposalRecord) -> Void

    var body: some View {
        let facts = viewModel.characterIdentityCardFacts
        let choices = viewModel.characterIdentityChoices
        let hiddenCount = max(0, viewModel.pendingCharacterIdentityMentions.count - facts.count)

        ForEach(facts, id: \.mention.id) { card in
            NovelCharacterIdentityQuestionCard(
                mention: card.mention,
                choices: choices,
                recommended: card.recommended,
                activeProposal: card.activeProposal,
                relatedProposalCount: card.relatedProposalCount,
                isDisabled: viewModel.isBusy || viewModel.isRunning,
                onSelect: { materialID in
                    Task { @MainActor in
                        _ = await viewModel.associateCharacterAlias(
                            card.mention.name,
                            with: materialID
                        )
                    }
                },
                onIgnore: {
                    Task { @MainActor in
                        _ = await viewModel.ignoreCharacterIdentityMention(card.mention.name)
                    }
                },
                onClarify: { clarification in
                    Task { @MainActor in
                        _ = await viewModel.clarifyCharacterIdentityMention(
                            card.mention.name,
                            clarification: clarification
                        )
                    }
                },
                onGenerate: { guidance in
                    Task { @MainActor in
                        _ = await viewModel.startCharacterProposal(
                            for: card.mention.name,
                            guidance: guidance
                        )
                    }
                },
                onOpenProposal: {
                    if let activeProposal = card.activeProposal {
                        onAcceptSettingProposal(activeProposal)
                    }
                }
            )
        }
        if hiddenCount > 0 {
            Text("还有 \(hiddenCount) 个未确认称谓，处理上方条目后会继续出现。")
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }
}

private struct NovelCharacterIdentityQuestionCard: View {
    let mention: NovelCharacterIdentityMention
    let choices: [(material: NovelMaterialRecord, title: String)]
    let recommended: (material: NovelMaterialRecord, title: String)?
    let activeProposal: NovelSettingProposalRecord?
    let relatedProposalCount: Int
    let isDisabled: Bool
    let onSelect: (NovelMaterialID) -> Void
    let onIgnore: () -> Void
    let onClarify: (String) -> Void
    let onGenerate: (String) -> Void
    let onOpenProposal: () -> Void

    @State private var isClarificationFieldPresented = false
    @State private var isProposalFieldPresented = false
    @State private var clarification = ""
    @State private var proposalGuidance = ""
    @State private var imeBank = NovelIMEFieldBank()

    private var normalizedClarification: String {
        clarification.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var otherChoices: [(material: NovelMaterialRecord, title: String)] {
        guard let recommended else { return choices }
        return choices.filter { $0.material.id != recommended.material.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(AmberTheme.accent.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("确认人物身份")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(
                        recommended == nil
                            ? "关联已有角色，或为新人物生成建议"
                            : "已匹配默认角色，可一键确认或新建"
                    )
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
            }

            Text("正文中的“\(mention.name)”对应哪位角色？确认后，已有经历会自动归入同一人物。")
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let activeProposal {
                Button(action: onOpenProposal) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AmberTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(activeProposal.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(relatedProposalCount == 0
                                ? "人物建议已生成，确认后才会建档"
                                : "另有 \(relatedProposalCount) 条关系、世界观或剧情建议")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .background(AmberTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            } else {
                // Primary actions + optional menu; proposal expand sits under
                // this block (proximity) and above secondary 忽略/补充说明.
                Group {
                    if let recommended {
                        HStack(spacing: 10) {
                            Button {
                                onSelect(recommended.material.id)
                            } label: {
                                VStack(spacing: 2) {
                                    Text("确认为")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.white.opacity(0.9))
                                    Text(recommended.title)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(AmberTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isDisabled)
                            .accessibilityLabel("确认人物为\(recommended.title)")

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isProposalFieldPresented.toggle()
                                }
                            } label: {
                                Label("新建人物", systemImage: "person.crop.circle.badge.plus")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AmberTheme.accent)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(AmberTheme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isDisabled)
                        }
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isProposalFieldPresented.toggle()
                            }
                        } label: {
                            Label("新建人物", systemImage: "person.crop.circle.badge.plus")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(AmberTheme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isDisabled)
                    }

                    if !otherChoices.isEmpty {
                        Menu {
                            ForEach(otherChoices, id: \.material.id) { choice in
                                Button(choice.title) {
                                    onSelect(choice.material.id)
                                }
                            }
                        } label: {
                            HStack {
                                Label(
                                    recommended == nil
                                        ? "选择已有角色（\(otherChoices.count)）"
                                        : "选择其他角色（\(otherChoices.count)）",
                                    systemImage: "person.2"
                                )
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(AmberTheme.surface, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .disabled(isDisabled)
                    }

                    if isProposalFieldPresented {
                        VStack(alignment: .trailing, spacing: 8) {
                            NovelIMETextEditor(
                                text: $proposalGuidance,
                                placeholder: IOSAppLocalization.string(
                                    "可选：补充身份、关系或剧情方向",
                                    defaultValue: "可选：补充身份、关系或剧情方向"
                                ),
                                isEnabled: !isDisabled,
                                minHeight: 72,
                                bank: imeBank
                            )
                            .frame(minHeight: 72)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12))

                            Button {
                                NovelTextInputCommitter.perform(fieldBank: imeBank) {
                                    onGenerate(proposalGuidance)
                                }
                            } label: {
                                Label("生成建议", systemImage: "arrow.up")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 16)
                                    .background(AmberTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isDisabled)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .opacity(isDisabled ? 0.55 : 1)
            }

            HStack(spacing: 10) {
                Button(action: onIgnore) {
                    Label("忽略", systemImage: "person.crop.circle.badge.xmark")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AmberTheme.surface, in: Capsule())
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isClarificationFieldPresented.toggle()
                    }
                } label: {
                    Label("补充说明", systemImage: "square.and.pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AmberTheme.accent.opacity(0.10), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.55 : 1)

            if isClarificationFieldPresented {
                VStack(alignment: .trailing, spacing: 8) {
                    NovelIMETextEditor(
                        text: $clarification,
                        placeholder: IOSAppLocalization.string(
                            "例如：一次性路人，不需要建档",
                            defaultValue: "例如：一次性路人，不需要建档"
                        ),
                        isEnabled: !isDisabled,
                        minHeight: 64,
                        bank: imeBank
                    )
                    .frame(minHeight: 64)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12))

                    Button {
                        NovelTextInputCommitter.perform(fieldBank: imeBank) {
                            onClarify(normalizedClarification)
                        }
                    } label: {
                        Label("确认说明", systemImage: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(minHeight: 44)
                            .padding(.horizontal, 14)
                            .background(AmberTheme.accent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled || normalizedClarification.isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isDisabled {
                Text("停止或等待当前任务完成后，即可处理人物身份。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }
}
