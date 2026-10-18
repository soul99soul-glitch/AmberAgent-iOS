import SwiftUI

struct NovelManualRewriteCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let content: String
    let onConfirm: @MainActor () async -> NovelSessionSheetSubmissionResult

    @State private var isSubmitting = false
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Label(failureMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AmberTheme.accentRed)
                    }

                    Label("这会作为剧情改写保存", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(AmberTheme.foreground2)

                    Text("系统检测到润色候选可能改变剧情事实。保存后分支会进入待同步，正式生成前需要重新同步剧情状态。")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)

                    ChatAssistantMarkdownView(
                        markdown: content,
                        renderCacheNamespace: "novel:manual-rewrite-preview"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(AmberTheme.background)
            .navigationTitle("保存为剧情改写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存改写") { confirm() }
                        .disabled(isSubmitting)
                }
            }
            .overlay {
                if isSubmitting { ProgressView() }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func confirm() {
        isSubmitting = true
        failureMessage = nil
        Task { @MainActor in
            let result = await onConfirm()
            isSubmitting = false
            switch result {
            case .completed:
                dismiss()
            case .pending(let message), .failed(let message):
                failureMessage = message
            }
        }
    }
}
