import SwiftUI

struct NovelGhostwriteProgressBoard: View {
    let progress: NovelGhostwriteProgress?
    let planStatusLabel: String
    let reviewModelLabel: String
    let upcomingArcStatusLabel: String

    var body: some View {
        Section {
            if let progress {
                LabeledContent("状态") {
                    Text(progress.statusLabel)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("进度") {
                    // 进度只报步骤码 + 已收录；章序号留给「状态」，避免两行两套 x/5。
                    Text(progress.boardStepSummary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("本章计划", value: planStatusLabel)
                // 多章时「进度」已有「已收 k/N」；仅待同步计章时单独标出。
                if progress.pendingSyncChapterCredit {
                    let counted = progress.completedChapterCount + 1
                    LabeledContent(
                        "本批已收录",
                        value: IOSAppLocalization.formatted(
                            "%lld 章（待同步计章）",
                            defaultValue: "%lld 章（待同步计章）",
                            arguments: [counted]
                        )
                    )
                } else if progress.targetChapterCount == 1 {
                    LabeledContent(
                        "本批已收录",
                        value: IOSAppLocalization.formatted(
                            "%lld 章",
                            defaultValue: "%lld 章",
                            arguments: [progress.completedChapterCount]
                        )
                    )
                }
                LabeledContent("审稿模型", value: reviewModelLabel)
                LabeledContent("往后几章", value: upcomingArcStatusLabel)
                if let detail = progress.detailMessage, !detail.isEmpty {
                    let detailIsError = progress.phase == .failed
                        || progress.pauseReason == .healBudgetExhausted
                        || (
                            progress.phase == .paused
                                && progress.pauseReason != .userPaused
                                && progress.pauseReason != .cancelled
                        )
                    if detailIsError {
                        // 与同步失败 Label 一致：顶对齐 + 多行可长。
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.accentRed)
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.accentRed)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 2)
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                LabeledContent("本章计划", value: planStatusLabel)
                LabeledContent("审稿模型", value: reviewModelLabel)
                LabeledContent("往后几章", value: upcomingArcStatusLabel)
                Text("先确认本章计划，再开始代笔。可在下方「本章计划」一键根据前文生成草稿；多章时后续计划会自动拟定。")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
            }
        } header: {
            Text("代笔进度")
        } footer: {
            Text("只读；暂时看不到费用明细。")
        }
    }
}
