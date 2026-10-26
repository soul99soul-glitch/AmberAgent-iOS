import SwiftUI

struct DesktopConversationInsightsView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss

    private var conversation: DesktopConversation? { workspace.selectedConversation }
    private var active: Bool {
        conversation.map { workspace.insights.activeOwners.contains($0.id) } ?? false
    }
    private var actionsDisabled: Bool {
        workspace.isLoading || workspace.isGenerating || workspace.isMutatingBranch || active
            || conversation?.messages.isEmpty != false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("上下文与回顾").font(DesktopTheme.serif(size: 18, weight: .semibold))
            if let conversation {
                let prepared = workspace.insights.prepare(messages: conversation.messages, conversationID: conversation.id)
                let tokens = DesktopConversationInsights.estimatedTokens(prepared,
                    extraText: workspace.settings.systemPrompt + workspace.draft
                        + workspace.pendingAttachments.map(\.text).joined())
                VStack(alignment: .leading, spacing: 5) {
                    Text("下次请求约 \(tokens.formatted()) tokens").font(.callout.weight(.medium))
                    Text("包含系统提示与当前草稿，仅为估算。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    if let limit = workspace.settings.selectedProvider?.selectedModel?.contextWindowTokens {
                        ProgressView(value: Double(min(tokens, limit)), total: Double(limit))
                            .tint(tokens >= limit ? DesktopTheme.danger : DesktopTheme.accent)
                        Text("模型窗口 \(limit.formatted()) tokens\(tokens >= limit ? "，建议先压缩上下文" : "")")
                            .font(.system(size: 12))
                            .foregroundStyle(tokens >= limit ? Color.orange : Color.secondary)
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
                if active {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在处理会话辅助内容…").font(.system(size: 13))
                        Spacer()
                        Button("停止") { workspace.insights.cancel(conversation.id) }
                    }
                }
                if let error = workspace.insights.errors[conversation.id] {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13)).foregroundStyle(DesktopTheme.accent)
                            .textSelection(.enabled)
                        Button("重新读取记录") { workspace.insights.retryLoad(conversation.id) }
                            .disabled(active)
                            .help("重新读取本机会话辅助记录；生成失败可使用对应的生成按钮重试")
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        insightSection(.recap, conversation: conversation)
                        Divider()
                        insightSection(.suggestions, conversation: conversation)
                        Divider()
                        insightSection(.compact, conversation: conversation)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 400)
            } else {
                Text("选中一个会话后，可以回顾内容与整理上下文。")
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private func insightSection(_ kind: DesktopInsightKind, conversation: DesktopConversation) -> some View {
        let value = workspace.insights.value(kind, for: conversation)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(value == nil ? "生成" : "重新生成") { workspace.requestInsight(kind) }
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
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(suggestion).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.left")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
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
