import AppKit
import SwiftUI

struct DesktopRecipesView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedName: String?
    @State private var inputValues: [String: String] = [:]
    @State private var booleanValues: [String: Bool] = [:]
    @State private var editing: DesktopInstalledRecipe?
    @State private var deleting: DesktopInstalledRecipe?
    @State private var error: String?

    private var store: DesktopRecipeStore { workspace.recipes.store }
    private var selected: DesktopInstalledRecipe? { store.recipes.first { $0.id == selectedName } }
    private var operations: [DesktopRecipeOperation] { workspace.recipes.operations.filter { $0.owner == workspace.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recipe 自动流程").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text("固定步骤依次执行，每一步沿用工具原有的确认与取消规则。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                }
                Spacer()
                Button("导入 recipe.json…") { importRecipe() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let loadError = store.loadError {
                HStack(alignment: .top) {
                    Label(loadError, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(DesktopTheme.accent)
                    Spacer()
                    Button("重新读取") { perform { try store.reload() } }
                }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HSplitView {
                List(selection: $selectedName) {
                    ForEach(store.recipes) { recipe in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(recipe.manifest.name).font(.system(size: 13, weight: .semibold))
                            Text(recipe.manifest.version + (recipe.enabled ? " · 已启用" : " · 未启用"))
                                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                            Text(recipe.manifest.description).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(2)
                        }
                        .padding(.vertical, 7).tag(recipe.id)
                        .contextMenu {
                            Button("编辑 JSON") { editing = recipe }
                            Button("删除 Recipe", role: .destructive) { deleting = recipe }
                        }
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                .background(DesktopTheme.sidebar(colorScheme))
                .frame(minWidth: 195, idealWidth: 225, maxWidth: 280)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let selected { recipeForm(selected) }
                        else if store.recipes.isEmpty {
                            ContentUnavailableView("还没有 Recipe", systemImage: "list.number", description: Text("导入 amber.recipe.v1 文件，检查后启用并填写输入。"))
                        } else {
                            Text("选择一个 Recipe 查看步骤与输入。").foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        if !operations.isEmpty {
                            Divider()
                            Text("此会话的运行记录").font(.system(size: 13, weight: .semibold))
                            Text("完整记录与重启后的结果可在任务工作台查看。")
                                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                            ForEach(operations) { operation in operationCard(operation) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(minWidth: 430)
            }
        }
        .padding(24).frame(width: 820, height: 670)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .onAppear { selectedName = store.recipes.first?.id }
        .onChange(of: selectedName) { inputValues = [:]; booleanValues = [:]; error = nil }
        .sheet(item: $editing) { recipe in
            DesktopTextDocumentEditor(title: recipe.id, subtitle: "编辑 recipe.json；name 保持不变，保存时验证步骤与绑定。", initialText: recipe.json) {
                try store.saveRecipe(name: recipe.id, json: $0)
            }
        }
        .confirmationDialog("删除这个 Recipe？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除 Recipe", role: .destructive) {
                if let deleting {
                    perform { try store.deleteRecipe(name: deleting.id) }
                    if selectedName == deleting.id { selectedName = store.recipes.first?.id }
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("已保存的任务记录会保留。") }
    }

    private func recipeForm(_ recipe: DesktopInstalledRecipe) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(recipe.manifest.name).font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle("启用", isOn: Binding(get: { recipe.enabled }, set: { enabled in perform { try store.setEnabled(recipe.id, enabled: enabled) } }))
                    .toggleStyle(.switch).fixedSize()
                Button("编辑 JSON") { editing = recipe }
            }
            Text(recipe.manifest.description).font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme)).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("\(recipe.manifest.steps.count) 个固定步骤") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recipe.manifest.steps, id: \.id) { step in
                        HStack(alignment: .top) {
                            Text(step.id).font(.system(size: 12, weight: .medium))
                            Text(step.tool).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Text("\(step.timeoutSeconds ?? 60) 秒").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                    }
                }.padding(.top, 8)
            }
            ForEach(recipe.manifest.inputs.keys.sorted(), id: \.self) { key in
                if recipe.manifest.inputs[key] == .boolean {
                    Toggle(key, isOn: Binding(get: { booleanValues[key] ?? false }, set: { booleanValues[key] = $0 }))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(key + (recipe.manifest.inputs[key] == .number ? " · 数字" : " · 文本"))
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        TextField(key, text: Binding(get: { inputValues[key] ?? "" }, set: { inputValues[key] = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    }
                }
            }
            Button("运行 Recipe") { start(recipe) }.buttonStyle(.borderedProminent)
                .disabled(!recipe.enabled || store.loadError != nil || workspace.selectedID == nil
                    || operations.contains(where: \.isRunning) || workspace.isLoading || workspace.isManagingBackup
                    || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable)
        }
    }

    private func operationCard(_ operation: DesktopRecipeOperation) -> some View {
        let task = workspace.agentTasks.records.first { $0.id == operation.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(operation.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if operation.isRunning {
                    ProgressView().controlSize(.mini)
                    Button("停止") { workspace.recipes.cancel(operation.id) }
                } else {
                    Text(operation.result?.succeeded == true ? "已完成" : "未完成").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            if let task, task.approval != nil { DesktopToolApprovalCard(task: task, tasks: workspace.agentTasks) }
            if let result = operation.result {
                Text("已完成步骤：" + (result.completedSteps.isEmpty ? "无" : result.completedSteps.joined(separator: "、")))
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                if let failedStep = result.failedStep { Text("停止于步骤：" + failedStep).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
                if !result.outputs.isEmpty {
                    Text(json(result.outputs)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = result.error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            }
            if let error = operation.error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private func start(_ recipe: DesktopInstalledRecipe) {
        perform {
            var inputs: [String: DesktopRecipeJSONValue] = [:]
            for (key, type) in recipe.manifest.inputs {
                switch type {
                case .boolean: inputs[key] = .bool(booleanValues[key] ?? false)
                case .string: inputs[key] = .string(inputValues[key] ?? "")
                case .number:
                    guard let number = Double(inputValues[key] ?? ""), number.isFinite else { throw DesktopRuntimeError.message("\(key) 需要填写有效数字。") }
                    inputs[key] = .number(number)
                }
            }
            guard workspace.runRecipe(name: recipe.id, inputs: inputs) != nil else {
                throw DesktopRuntimeError.message(workspace.errorMessage ?? "请先读取当前会话后再运行 Recipe。")
            }
            error = nil
        }
    }

    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { perform { selectedName = try store.importRecipe(from: url) } }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    private func json(_ outputs: [String: DesktopRecipeJSONValue]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(outputs)) ?? Data(), as: UTF8.self)
    }
}
