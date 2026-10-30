import SwiftUI

struct DesktopConversationInsightsView: View {
    @Bindable var workspace: DesktopWorkspace
    /// Embedded in the inspector: no own title/padding/width, no dismiss on pick.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var hiddenResultKinds: Set<DesktopInsightKind> = []

    private var conversation: DesktopConversation? { workspace.selectedConversation }
    private var active: Bool {
        conversation.map { workspace.insights.activeOwners.contains($0.id) } ?? false
    }
    private var actionsDisabled: Bool {
        workspace.isLoading || workspace.isGenerating || workspace.isMutatingBranch || active
            || conversation?.messages.isEmpty != false
    }

    var body: some View {
        let isEmpty = conversation?.messages.isEmpty ?? true
        return VStack(alignment: .leading, spacing: embedded ? 10 : 16) {
            if !embedded { Text("上下文与回顾").font(DesktopTheme.serif(size: 18, weight: .semibold)) }
            if let conversation {
                let prepared = workspace.insights.prepare(messages: conversation.messages, conversationID: conversation.id)
                let tokens = DesktopConversationInsights.estimatedTokens(prepared,
                    extraText: workspace.settings.systemPrompt + workspace.draft
                        + workspace.pendingAttachments.map(\.text).joined())
                if !embedded {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("下次请求约 \(tokens.formatted()) tokens").font(.callout.weight(.medium))
                        Text("包含系统提示与当前草稿，仅为估算。")
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        if let limit = workspace.settings.selectedProvider?.selectedModel?.contextWindowTokens {
                            ProgressView(value: Double(min(tokens, limit)), total: Double(limit))
                                .tint(tokens >= limit ? DesktopTheme.danger : DesktopTheme.accent)
                            Text("模型窗口 \(limit.formatted()) tokens\(tokens >= limit ? "，建议先压缩上下文" : "")")
                                .font(.system(size: 12))
                                .foregroundStyle(tokens >= limit ? DesktopTheme.danger : DesktopTheme.inkTertiary)
                        }
                        if workspace.insights.value(.compact, for: conversation) != nil {
                            Label("已使用较早对话的摘要，原消息仍保留", systemImage: "checkmark.circle")
                                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                            Button("恢复完整上下文") { workspace.insights.clearCompaction(conversation.id) }
                                .font(.system(size: 12))
                                .disabled(actionsDisabled)
                                .help("后续请求重新使用完整消息，保留原有会话回顾和建议")
                        }
                    }
                } else if let limit = workspace.settings.selectedProvider?.selectedModel?.contextWindowTokens {
                    DesktopContextMeterBar(tokens: tokens, limit: limit)
                } else {
                    DesktopContextMeterBar(tokens: tokens)
                }
                if active {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在处理会话辅助内容…").font(.system(size: 12.5))
                        Spacer()
                        Button("停止") { workspace.insights.cancel(conversation.id) }
                    }
                }
                if let error = workspace.insights.errors[conversation.id] {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12.5)).foregroundStyle(DesktopTheme.accent)
                            .textSelection(.enabled)
                        Button("重新读取记录") { workspace.insights.retryLoad(conversation.id) }
                            .disabled(active)
                            .help("重新读取本机会话辅助记录；生成失败可使用对应的生成按钮重试")
                    }
                }
                let sections = VStack(alignment: .leading, spacing: embedded ? 10 : 18) {
                    if embedded {
                        if !isEmpty {
                            embeddedQuickActions(conversation: conversation)
                        } else {
                            Text("发送消息后可一键生成回顾、追问建议或压缩上下文。")
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                        }
                    } else {
                        insightSection(.recap, conversation: conversation)
                        Divider()
                        insightSection(.suggestions, conversation: conversation)
                        Divider()
                        insightSection(.compact, conversation: conversation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if embedded { sections } else { ScrollView { sections }.frame(maxHeight: 400) }
            } else {
                Text("选中一个会话后，可以回顾内容与整理上下文。")
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 420)
    }

    @ViewBuilder
    private func embeddedQuickActions(conversation: DesktopConversation) -> some View {
        let recapValue = workspace.insights.value(.recap, for: conversation)
        let suggestionsValue = workspace.insights.value(.suggestions, for: conversation)
        let compactValue = workspace.insights.value(.compact, for: conversation)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if recapValue != nil {
                        withAnimation(.smooth(duration: 0.22)) {
                            if hiddenResultKinds.contains(.recap) { hiddenResultKinds.remove(.recap) }
                            else { _ = hiddenResultKinds.insert(.recap) }
                        }
                    } else {
                        hiddenResultKinds.remove(.recap)
                        workspace.requestInsight(.recap)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                        Text("回顾")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(recapValue != nil && !hiddenResultKinds.contains(.recap) ? .desktopTintedPill : .desktopActionPill)
                .disabled(actionsDisabled && recapValue == nil)
                .help("提炼当前对话的关键结论与待办")

                Button {
                    if suggestionsValue != nil {
                        withAnimation(.smooth(duration: 0.22)) {
                            if hiddenResultKinds.contains(.suggestions) { hiddenResultKinds.remove(.suggestions) }
                            else { _ = hiddenResultKinds.insert(.suggestions) }
                        }
                    } else {
                        hiddenResultKinds.remove(.suggestions)
                        workspace.requestInsight(.suggestions)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 11))
                        Text("追问")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(suggestionsValue != nil && !hiddenResultKinds.contains(.suggestions) ? .desktopTintedPill : .desktopActionPill)
                .disabled(actionsDisabled && suggestionsValue == nil)
                .help("生成可点击填入输入框的下一步追问")

                Button {
                    if compactValue != nil {
                        withAnimation(.smooth(duration: 0.22)) {
                            if hiddenResultKinds.contains(.compact) { hiddenResultKinds.remove(.compact) }
                            else { _ = hiddenResultKinds.insert(.compact) }
                        }
                    } else {
                        hiddenResultKinds.remove(.compact)
                        workspace.requestInsight(.compact)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10.5))
                        Text("压缩")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(compactValue != nil && !hiddenResultKinds.contains(.compact) ? .desktopTintedPill : .desktopActionPill)
                .disabled(actionsDisabled && compactValue == nil)
                .help("将较早对话压缩为摘要以节省上下文预算，不删除历史消息")
            }

            if let recapValue, !hiddenResultKinds.contains(.recap) {
                insightResultBox(.recap, value: recapValue)
            }
            if let suggestionsValue, !hiddenResultKinds.contains(.suggestions) {
                insightResultBox(.suggestions, value: suggestionsValue)
            }
            if let compactValue, !hiddenResultKinds.contains(.compact) {
                insightResultBox(.compact, value: compactValue)
            }
        }
    }

    @ViewBuilder
    private func insightResultBox(_ kind: DesktopInsightKind, value: DesktopInsightValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                Text(value.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                Button("重新生成") {
                    workspace.requestInsight(kind)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(DesktopTheme.accentInk)
                .disabled(actionsDisabled)

                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        _ = hiddenResultKinds.insert(kind)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("收起\(kind.title)")
            }
            if kind == .suggestions {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(value.suggestions.enumerated()), id: \.offset) { _, suggestion in
                            Button {
                                workspace.draft = suggestion
                                if !embedded { dismiss() }
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(suggestion)
                                        .font(.system(size: 12))
                                        .foregroundStyle(DesktopTheme.ink)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.down.left")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(DesktopTheme.accent)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesktopTheme.hairline))
                            }
                            .buttonStyle(DesktopQuietButtonStyle())
                            .help("填入输入框，可编辑后发送")
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    DesktopMarkdown(text: value.text, fontSize: 12.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 210)
            }
        }
        .padding(10)
        .background(DesktopTheme.paperDeep.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DesktopTheme.hairline))
    }

    @ViewBuilder
    private func insightSection(_ kind: DesktopInsightKind, conversation: DesktopConversation) -> some View {
        let value = workspace.insights.value(kind, for: conversation)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(value == nil ? "生成" : "重新生成") { workspace.requestInsight(kind) }
                    .buttonStyle(.desktopActionPill)
                    .disabled(actionsDisabled)
            }
            if kind == .compact {
                Text("将较早的完整对话压缩成摘要用于后续请求，最近两轮保留原文；不会删除历史消息。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let value {
                if kind == .suggestions {
                    ForEach(Array(value.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        Button {
                            workspace.draft = suggestion
                            if !embedded { dismiss() }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(suggestion).font(.system(size: 13)).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.left")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                        }
                        .buttonStyle(DesktopQuietButtonStyle())
                        .help("填入输入框，可编辑后发送")
                    }
                } else {
                    Text(value.text).font(.system(size: 13)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(value.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            } else {
                Text(kind == .suggestions ? "生成可继续追问的问题，点击建议可填入输入框。" : "尚无当前会话的有效记录。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
        }
    }
}
