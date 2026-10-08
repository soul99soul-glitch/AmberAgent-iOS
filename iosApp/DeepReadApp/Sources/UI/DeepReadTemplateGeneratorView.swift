import SwiftUI

struct DeepReadTemplateGeneratorView: View {
    let settings: DeepReadSettingsStore
    @State private var name = "我的阅读模板"
    @State private var brief = ""
    @State private var requestId = 0
    @State private var generating = false
    @State private var error: String?
    @State private var draft: IOSDeepReadCustomTemplate?

    var body: some View {
        Form {
            Section("模板要求") {
                TextField("模板名称", text: $name)
                TextField("描述你想要的排版、色彩与阅读风格", text: $brief, axis: .vertical)
                    .lineLimit(5...12)
            }
            Section {
                Button("生成模板草稿", systemImage: "sparkles") {
                    generating = true
                    requestId += 1
                }
                .disabled(generating || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if generating { ProgressView("正在生成并校验模板…") }
            } footer: {
                Text("使用设置中选定的模型生成草稿。校验通过后可以预览、编辑并保存。")
            }
            if let error { Section { Text(error).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled) } }
        }
        .navigationTitle("AI 阅读模板")
        .task(id: requestId) {
            guard requestId > 0 else { return }
            defer { generating = false }
            do {
                guard settings.save(), let selected = settings.resolvedModel else {
                    error = settings.errorMessage ?? "请先在设置中配置并选择可用模型。"
                    return
                }
                let result = try await IOSDeepReadTemplateDraftGenerator.generateDraft(
                    name: name, brief: brief,
                    providerSetting: selected.provider, modelId: selected.model.modelId
                )
                try Task.checkCancellation()
                error = nil
                draft = result
            } catch is CancellationError {
                // Leaving the generator releases this local draft request.
            } catch { self.error = IOSDeepReadUserFacingText.fromError(error) }
        }
        .sheet(item: $draft) { template in
            NavigationStack { DeepReadTemplateEditorView(template: template, settings: settings) }
        }
    }
}
