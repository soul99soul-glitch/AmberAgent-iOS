import SwiftUI

struct NovelGhostwriteRevisionStrategy: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let brief: String
    let isDefault: Bool

    static func continuityOptions(recommendedBrief: String) -> [Self] {
        let trimmed = recommendedBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? "修正审稿指出的前后矛盾，保留与既有正文一致的事实。"
            : trimmed
        return [
            Self(
                id: "minimal",
                title: "按审稿意见最小修复",
                detail: "保留可用段落，只修改已经确认的冲突。",
                brief: base,
                isDefault: true
            ),
            Self(
                id: "explain",
                title: "保留差异并补足解释",
                detail: "不推翻既有事实，在本章补清称谓、时间或制度差异的原因。",
                brief: base + "\n\n处理方向：尽量保留现有差异，通过本章补充清楚、可信的解释消除矛盾。",
                isDefault: false
            ),
            Self(
                id: "rewrite",
                title: "重写冲突桥段",
                detail: "允许重写相关段落，以既有正文和本章计划为准重新衔接。",
                brief: base + "\n\n处理方向：允许重写引发冲突的相关桥段，以既有正文和本章计划为准重新建立因果。",
                isDefault: false
            ),
        ]
    }
}

/// 代笔质量门失败后的人工润修确认面：预填审稿 brief，可选处理方向并编辑后开写。
struct NovelGhostwriteRevisionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recommendedBrief: String
    /// 展示给用户的中断摘要（优先审稿意见，不含离页/重启元信息）。
    let detail: String?
    let strategies: [NovelGhostwriteRevisionStrategy]
    let onCancel: () -> Void
    /// 返回是否已开始；false 时 sheet 留在原地并显示错误。
    let onStart: (String) -> Bool

    @State private var brief: String
    @State private var selectedStrategyID: String?
    @State private var hasCustomized = false
    @State private var startError: String?
    @State private var revisionFieldBank = NovelIMEFieldBank()

    init(
        recommendedBrief: String,
        detail: String?,
        strategies: [NovelGhostwriteRevisionStrategy] = [],
        onCancel: @escaping () -> Void,
        onStart: @escaping (String) -> Bool
    ) {
        self.recommendedBrief = recommendedBrief
        self.detail = detail
        self.strategies = strategies
        self.onCancel = onCancel
        self.onStart = onStart
        _brief = State(initialValue: strategies.first?.brief ?? recommendedBrief)
        _selectedStrategyID = State(initialValue: strategies.first?.id)
    }

    var body: some View {
        let defaultBrief = strategies.first(where: \.isDefault)?.brief ?? recommendedBrief
        NavigationStack {
            Form {
                if let detail, !detail.isEmpty {
                    Section {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("审稿意见")
                    }
                }

                if let startError, !startError.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.footnote)
                            Text(startError)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(AmberTheme.accentRed)
                    }
                }

                if !strategies.isEmpty {
                    Section {
                        ForEach(strategies) { strategy in
                            Button {
                                revisionFieldBank.commitAll()
                                selectedStrategyID = strategy.id
                                brief = strategy.brief
                                startError = nil
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selectedStrategyID == strategy.id
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                        .foregroundStyle(selectedStrategyID == strategy.id
                                            ? AmberTheme.accent
                                            : AmberTheme.muted)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(IOSAppLocalization.string(
                                                strategy.title,
                                                defaultValue: strategy.title
                                            ))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(AmberTheme.foreground)
                                            if strategy.isDefault {
                                                Text("默认")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(AmberTheme.accent)
                                            }
                                        }
                                        Text(IOSAppLocalization.string(
                                            strategy.detail,
                                            defaultValue: strategy.detail
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(AmberTheme.muted)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                strategy.isDefault
                                    ? IOSAppLocalization.formatted(
                                        "%@，默认方案",
                                        defaultValue: "%@，默认方案",
                                        arguments: [IOSAppLocalization.string(
                                            strategy.title,
                                            defaultValue: strategy.title
                                        )]
                                    )
                                    : IOSAppLocalization.string(
                                        strategy.title,
                                        defaultValue: strategy.title
                                    )
                            )
                            .accessibilityValue(
                                IOSAppLocalization.formatted(
                                    "%@，%@",
                                    defaultValue: "%@，%@",
                                    arguments: [
                                        IOSAppLocalization.string(
                                            selectedStrategyID == strategy.id ? "已选择" : "未选择",
                                            defaultValue: selectedStrategyID == strategy.id ? "已选择" : "未选择"
                                        ),
                                        IOSAppLocalization.string(
                                            strategy.detail,
                                            defaultValue: strategy.detail
                                        )
                                    ]
                                )
                            )
                            .accessibilityAddTraits(
                                selectedStrategyID == strategy.id ? .isSelected : []
                            )
                        }
                    } header: {
                        Text("选择处理方向")
                    } footer: {
                        Text(IOSAppLocalization.string(
                            "以下为通用处理方向，可按本次审稿意见选择并继续编辑；确认开始前不会改动候选稿或正文。",
                            defaultValue: "以下为通用处理方向，可按本次审稿意见选择并继续编辑；确认开始前不会改动候选稿或正文。"
                        ))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    NovelIMETextEditor(
                        text: $brief,
                        placeholder: IOSAppLocalization.string(
                            "润修要求",
                            defaultValue: "润修要求"
                        ),
                        isEnabled: true,
                        minHeight: 160,
                        bank: revisionFieldBank
                    )
                    .frame(minHeight: 160)
                    .onChange(of: brief) { _, newValue in
                        hasCustomized = newValue != defaultBrief
                        if let selectedStrategyID,
                           strategies.first(where: { $0.id == selectedStrategyID })?.brief != newValue {
                            self.selectedStrategyID = nil
                        }
                        startError = nil
                    }
                    if hasCustomized, brief != defaultBrief {
                        Button("重置为默认") {
                            NovelTextInputCommitter.perform(fieldBank: revisionFieldBank) {
                                brief = defaultBrief
                                selectedStrategyID = strategies.first(where: \.isDefault)?.id
                                hasCustomized = false
                            }
                        }
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("润修要求")
                } footer: {
                    Text(IOSAppLocalization.string(
                        "会保留上一稿可用部分，按审稿意见修改并重新审核收录。",
                        defaultValue: "会保留上一稿可用部分，按审稿意见修改并重新审核收录。"
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle("按审稿意见润修")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        NovelTextInputCommitter.perform(fieldBank: revisionFieldBank) {
                            onCancel()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始润修") {
                        NovelTextInputCommitter.perform(fieldBank: revisionFieldBank) {
                            let started = onStart(brief)
                            if started {
                                dismiss()
                            } else {
                                startError = IOSAppLocalization.string(
                                    "代笔暂时不能开始，请检查本章计划后重试。",
                                    defaultValue: "代笔暂时不能开始，请检查本章计划后重试。"
                                )
                            }
                        }
                    }
                    .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
    }
}
