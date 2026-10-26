import SwiftUI

struct DesktopMessageActionItems: View {
    let message: DesktopMessage
    let speech: DesktopSpeechPlayer
    let mutationsDisabled: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    let onSpeechError: (String) -> Void

    var body: some View {
        Group {
            if message.role == .user || message.role == .assistant, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if speech.isSpeaking && speech.currentMessageID == message.id {
                    Button("停止朗读", systemImage: "speaker.slash") { speech.stop() }
                } else {
                    Button("朗读消息", systemImage: "speaker.wave.2") {
                        if !speech.speak(text: message.text, messageID: message.id) {
                            onSpeechError(speech.error ?? "无法开始朗读，请检查系统声音。")
                        }
                    }
                }
            }
            if speech.isSpeaking && speech.currentMessageID != message.id {
                Button("停止朗读", systemImage: "speaker.slash") { speech.stop() }
            }
            if !message.text.isEmpty {
                Button(isPinned ? "从产物架移除" : "固定到产物架", systemImage: isPinned ? "pin.slash" : "pin", action: onTogglePin)
                Button("导出此消息…", systemImage: "square.and.arrow.down", action: onExport)
                Button("分享…", systemImage: "square.and.arrow.up", action: onShare)
            }
            if message.canEdit {
                Button("编辑并重新发送…", systemImage: "pencil", action: onEdit)
                    .disabled(mutationsDisabled)
            }
            if message.role == .assistant {
                Button("重新生成", systemImage: "arrow.clockwise", action: onRegenerate)
                    .disabled(mutationsDisabled)
            }
            Divider()
            Button("删除消息…", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(mutationsDisabled)
        }
    }
}

struct DesktopMessageEditor: View {
    let followingCount: Int
    let canSubmit: Bool
    let onSubmit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(initialText: String, followingCount: Int, canSubmit: Bool, onSubmit: @escaping (String) async -> String?) {
        self.followingCount = followingCount
        self.canSubmit = canSubmit
        self.onSubmit = onSubmit
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑并重新发送").font(DesktopTheme.serif(size: 18, weight: .semibold))
            Text(followingCount > 0
                 ? "重新发送将移除这条消息之后的 \(followingCount) 条消息，并根据修改后的内容重新回复。"
                 : "Amber 将根据修改后的内容重新回复。")
                .font(.system(size: 13))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .frame(minHeight: 180, idealHeight: 240)
                .accessibilityLabel("编辑消息内容")
                .accessibilityIdentifier("message-edit-input")
                .disabled(isSubmitting)
            if let submissionError {
                Text(submissionError)
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("message-edit-error")
            }
            HStack {
                if !canSubmit && !isSubmitting {
                    Text("请回到原会话，并等待当前操作完成。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().controlSize(.mini) }
                        Text(isSubmitting ? "正在保存…" : "重新发送")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("重新发送 ⌘Return")
                .disabled(isSubmitting || !canSubmit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() {
        guard !isSubmitting, canSubmit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmitting = true
        submissionError = nil
        let submittedText = text
        Task { @MainActor in
            let error = await onSubmit(submittedText)
            isSubmitting = false
            if let error { submissionError = error }
            else { dismiss() }
        }
    }
}
