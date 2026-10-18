import SwiftUI

struct NovelSessionForkSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: NovelSessionViewModel
    let branchName: String
    let checkpointID: NovelCheckpointID
    let onCreated: (String) -> Void

    @State private var name: String
    @State private var isSubmitting = false
    @State private var failureMessage: String?
    @State private var imeBank = NovelIMEFieldBank()

    init(
        viewModel: NovelSessionViewModel,
        branchName: String,
        checkpointID: NovelCheckpointID,
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.branchName = branchName
        self.checkpointID = checkpointID
        self.onCreated = onCreated
        self._name = State(initialValue: IOSAppLocalization.formatted(
            "%@ · 新走向",
            defaultValue: "%@ · 新走向",
            arguments: [branchName]
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failureMessage {
                    Section("Fork 未完成") {
                        Label(failureMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AmberTheme.accentRed)
                    }
                }

                Section("新分支") {
                    NovelIMETextField(
                        text: $name,
                        placeholder: IOSAppLocalization.string(
                            "分支名称",
                            defaultValue: "分支名称"
                        ),
                        bank: imeBank
                    )
                    .frame(minHeight: 36)
                }

                Section {
                    Label("从这条创作记录对应的检查点开始", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                } footer: {
                    Text(IOSAppLocalization.string(
                        "新分支只继承该检查点以前的正文、剧情状态、分支设定和创作对话。",
                        defaultValue: "新分支只继承该检查点以前的正文、剧情状态、分支设定和创作对话。"
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle("Fork 剧情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        NovelTextInputCommitter.perform(fieldBank: imeBank) { create() }
                    }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                isSubmitting
                        )
                }
            }
            .overlay {
                if isSubmitting { ProgressView() }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func create() {
        isSubmitting = true
        failureMessage = nil
        viewModel.clearError()
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let branchID = await viewModel.forkFromCheckpoint(checkpointID, name: branchName)
            isSubmitting = false
            guard branchID != nil else {
                failureMessage = viewModel.errorMessage ?? IOSAppLocalization.string(
                    "分支没有创建完成，请重新载入项目后再试。",
                    defaultValue: "分支没有创建完成，请重新载入项目后再试。"
                )
                return
            }
            dismiss()
            onCreated(branchName)
        }
    }
}
