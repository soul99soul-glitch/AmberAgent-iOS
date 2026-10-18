import SwiftUI

struct ChatAskUserCard: View {
    let request: ChatAskUserRequest
    let onAnswer: (String) -> Void
    let onSkip: () -> Void

    @State private var selectedOption: String?
    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text("回答后会继续当前任务")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            Text(request.question)
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

            if !request.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.options, id: \.self) { option in
                        Button {
                            selectedOption = option
                            customAnswer = ""
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedOption == option
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(selectedOption == option
                                        ? AmberTheme.accent
                                        : AmberTheme.muted)
                                Text(option)
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.foreground)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(
                                selectedOption == option
                                    ? AmberTheme.accentTint
                                    : AmberTheme.surface2.opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .chatApprovalHitTarget()
                    }
                }
            }

            TextField(
                request.options.isEmpty ? "输入你的回答" : "或者输入自己的回答",
                text: $customAnswer,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                AmberTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .onChange(of: customAnswer) { _, value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedOption = nil
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(action: onSkip) {
                    Label("跳过", systemImage: "forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("跳过提问")

                Button {
                    onAnswer(resolvedAnswer)
                } label: {
                    Label("回答", systemImage: "arrow.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(AmberTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.55)
                .accessibilityLabel("提交回答")
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.34), lineWidth: 0.7)
        }
    }

    private var resolvedAnswer: String {
        let custom = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return selectedOption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var canSubmit: Bool {
        !resolvedAnswer.isEmpty
    }
}
