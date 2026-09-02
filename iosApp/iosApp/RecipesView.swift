import SwiftUI
import Shared
import UniformTypeIdentifiers

// MARK: - Recipes 管理（Wave B2；§14.1 / §18.1）
//
// 复用 Skill 管理页的视觉结构（AmberFormGroup / AmberSectionLabel /
// amberGlass 详情），展示 active recipe：版本、description、步骤摘要、回退
// 入口。回退复用 store 的 rollback（再验所见 manifest），无 previous 时明确
// 展示不可回退状态。数据来自真实 store + registry snapshot，不用源码锚点。

private func recipeStoreBaseDirectory() -> URL {
    (try? FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )) ?? FileManager.default.temporaryDirectory
}

struct RecipesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    @State private var recipes: [IOSInstalledRecipe] = []

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    recipesSection
                    footnoteSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            Task { await reload() }
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回技能", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("Recipes")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            // 占位：与技能页标题对称，保持布局稳定。
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var recipesSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "本机 Recipes")
            AmberFormGroup {
                if recipes.isEmpty {
                    RecipeEmptyState()
                } else {
                    ForEach(Array(recipes.enumerated()), id: \.element.package.name) { index, recipe in
                        let isValid = recipeValidation(recipe).isValid
                        Button {
                            router.navigate(to: .recipeDetail(name: recipe.package.name))
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(recipe.package.name) · v\(recipe.package.version)")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .minimumScaleFactor(0.8)
                                    if !recipe.manifest.description.isEmpty {
                                        Text(recipe.manifest.description)
                                            .font(.caption)
                                            .foregroundStyle(AmberTheme.muted)
                                            .lineLimit(2)
                                    }
                                    Text("\(recipeStatus(recipe, isValid: isValid)) · \(recipeStepsSummary(recipe))")
                                        .font(.caption2)
                                        .foregroundStyle(isValid ? AmberTheme.muted2 : AmberTheme.accentRed)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted2)
                            }
                            .frame(minHeight: 60)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < recipes.count - 1 {
                            Divider().overlay(AmberTheme.borderSoft).padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var footnoteSection: some View {
        Text("Recipe 是声明式工具组合；只有已启用且校验通过的 Recipe 会从下一模型轮通过 tool_search 暴露为 recipe__<名称>。")
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }

    private func recipeStepsSummary(_ recipe: IOSInstalledRecipe) -> String {
        let steps = recipe.manifest.steps.map(\.tool)
        if steps.isEmpty { return "（无步骤）" }
        if steps.count <= 3 { return steps.joined(separator: " → ") }
        return steps.prefix(3).joined(separator: " → ") + " …（共 \(steps.count) 步）"
    }

    private func recipeValidation(_ recipe: IOSInstalledRecipe) -> IOSRecipeValidationResult {
        IOSRecipeValidator.validate(
            manifest: recipe.manifest,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        )
    }

    private func recipeStatus(_ recipe: IOSInstalledRecipe, isValid: Bool) -> String {
        guard isValid else { return "校验失败 · 未暴露" }
        return recipe.isEnabled ? "已启用" : "已停用"
    }

    private func reload() async {
        recipes = IOSRecipeFileStore(baseDirectory: recipeStoreBaseDirectory()).listInstalledRecipes()
        _ = await IOSDynamicToolRegistry.shared.refresh()
    }
}

private struct RecipeEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AmberTheme.surface2.opacity(0.82))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(width: 52, height: 52)

            VStack(spacing: 4) {
                Text("暂无 Recipes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text("Agent 可先用 recipe_validate 校验，再通过 recipe_import 导入；批准后从下一模型轮生效。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }
}

// MARK: - Recipe 详情（active 版本、步骤摘要、一键回退）

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let recipeName: String
    private let store: IOSRecipeFileStore

    @State private var manifest: IOSRecipeManifest?
    @State private var packageHash: String?
    @State private var isEnabled = false
    @State private var loadError: String?
    @State private var rollbackAvailability: IOSRecipeRollbackAvailability = .unavailable(
        "正在检查可回退版本。"
    )
    @State private var rollbackConfirmationPresented = false
    @State private var deleteConfirmationPresented = false
    @State private var pendingAlert: RecipeDetailAlert?

    init(recipeName: String) {
        let baseDirectory = recipeStoreBaseDirectory()
        self.recipeName = recipeName
        self.store = IOSRecipeFileStore(baseDirectory: baseDirectory)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    hero
                    descriptionSection
                    stepsSection
                    envelopeSection
                    infoSection
                    lifecycleSection
                    rollbackSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert(item: $pendingAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .confirmationDialog(
            "回退上一次导入",
            isPresented: $rollbackConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认回退", role: .destructive) {
                rollbackLastImport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(rollbackAvailability.reason)
        }
        .confirmationDialog(
            "删除 Recipe",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认删除", role: .destructive) {
                deleteRecipe()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机 Recipe 包和它的回退版本；正在执行的调用仍使用已固定的版本完成。")
        }
        .task { loadSnapshot() }
    }

    private var header: some View {
        ZStack {
            Text("Recipe 详情")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            HStack {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回 Recipes", size: 44, symbolSize: 20) {
                    dismiss()
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(AmberTheme.accentAmber)
                .frame(width: 64, height: 64)
                .background(AmberTheme.accentAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                }

            Text(recipeName)
                .font(.title3.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Circle()
                    .fill(manifest != nil && !isManifestValid
                        ? AmberTheme.accentRed
                        : (isEnabled ? AmberTheme.accent : AmberTheme.muted2))
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 22)
    }

    private var descriptionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "描述")
            Text(manifest?.description ?? "未能读取这个 Recipe；请从 Recipes 列表重新进入。")
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
        }
    }

    private var stepsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "步骤")
            AmberFormGroup {
                let steps = manifest?.steps ?? []
                if steps.isEmpty {
                    RecipeDetailRow(title: "步骤", value: "未能读取")
                } else {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        RecipeDetailRow(
                            title: "\(index + 1). \(step.id)",
                            value: step.tool,
                            monospace: true
                        )
                        if index < steps.count - 1 {
                            RecipeDetailDivider()
                        }
                    }
                }
            }

            RecipeDetailFooter("步骤按顺序执行；含副作用步骤时，每次调用都会逐步骤请求批准。")
        }
    }

    private var envelopeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "权限包络")
            AmberFormGroup {
                RecipeDetailRow(title: "效果类别", value: envelopeTitle)
            }

            RecipeDetailFooter("包络是所有步骤效果类别的保守上界；不会绕过既有审批。")
        }
    }

    private var infoSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "信息")
            AmberFormGroup {
                RecipeDetailRow(title: "版本", value: manifest?.version ?? "未读取", monospace: true)
                RecipeDetailDivider()
                RecipeDetailRow(title: "输入", value: inputsSummary, monospace: true)
                RecipeDetailDivider()
                RecipeDetailRow(title: "包哈希", value: packageHash.map { String($0.prefix(12)) } ?? "未读取", monospace: true)
            }

            RecipeDetailFooter(
                loadError
                    ?? "Recipe 本身不下载代码，只编排宿主已注册工具；具体工具仍按各自权限审批。"
            )
        }
    }

    private var rollbackSection: some View {
        VStack(spacing: 0) {
            AmberFormGroup {
                Button {
                    rollbackConfirmationPresented = true
                } label: {
                    Text("回退上一次导入")
                        .font(.body.weight(.medium))
                        .foregroundStyle(
                            rollbackAvailability.canRollback ? AmberTheme.accent : AmberTheme.muted2
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!rollbackAvailability.canRollback)
            }
            .padding(.top, 20)

            RecipeDetailFooter(rollbackAvailability.reason)
        }
    }

    private var lifecycleSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "管理")
            AmberFormGroup {
                Toggle(
                    "启用状态",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .tint(AmberTheme.accent)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .disabled(manifest == nil || (!isEnabled && !isManifestValid))
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

                RecipeDetailDivider()

                Button(role: .destructive) {
                    deleteConfirmationPresented = true
                } label: {
                    Text("删除 Recipe")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(manifest == nil)
            }

            RecipeDetailFooter(lifecycleFooterText)
        }
    }

    private var lifecycleFooterText: String {
        guard manifest != nil else {
            return loadError == nil
                ? "正在读取 Recipe，暂不可管理。"
                : "读取失败，当前不可管理；请返回刷新后重试。"
        }
        guard isManifestValid else {
            return isEnabled
                ? "校验失败，请先停用并重新导入有效版本。"
                : "校验失败，当前不可启用；请重新导入有效版本。"
        }
        return isEnabled
            ? "停用后从下一模型轮停止暴露，并保留本机安装包。"
            : "启用后从下一模型轮生效。"
    }

    private var statusText: String {
        if manifest != nil {
            if !isManifestValid { return "校验失败 · 未暴露" }
            return "\(isEnabled ? "已启用" : "已停用") v\(manifest?.version ?? "?")"
        }
        if loadError != nil {
            return "读取失败"
        }
        return "读取中"
    }

    private var inputsSummary: String {
        guard let manifest, !manifest.inputs.isEmpty else { return "无" }
        return manifest.inputs.sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value.rawValue)" }
            .joined(separator: ", ")
    }

    private var envelopeTitle: String {
        guard let manifest else { return "未读取" }
        let validation = IOSRecipeValidator.validate(
            manifest: manifest,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        )
        guard let envelope = validation.permissionEnvelope else { return "校验失败" }
        return IOSDynamicToolRegistry.permissionSummary(for: envelope)
    }

    private var isManifestValid: Bool {
        guard let manifest else { return false }
        return IOSRecipeValidator.validate(
            manifest: manifest,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
        ).isValid
    }

    private func loadSnapshot() {
        refreshRollbackAvailability()
        do {
            let package = try store.readLiveRecipe(name: recipeName)
            let decoded = try IOSRecipeManifest.decode(package.canonicalJSON)
            manifest = decoded
            packageHash = package.hash
            isEnabled = store.isRecipeEnabled(name: recipeName)
            loadError = nil
        } catch {
            manifest = nil
            packageHash = nil
            isEnabled = false
            loadError = "读取 Recipe 失败：\(error.localizedDescription)"
        }
    }

    private func refreshRollbackAvailability() {
        do {
            rollbackAvailability = try store.rollbackAvailability(name: recipeName)
        } catch {
            rollbackAvailability = .unavailable("检查可回退版本失败：\(error.localizedDescription)")
        }
    }

    private func rollbackLastImport() {
        guard case .available(let expectedManifest) = rollbackAvailability else {
            refreshRollbackAvailability()
            pendingAlert = .operationFailed("可回退版本已经失效，请刷新后重试。")
            return
        }
        do {
            // 再验所见 manifest：store 内部会核对 live hash 与槽位，更新的
            // 导入会替换槽位 → 此处 fail closed（§13.1 / §18.1）。
            _ = try store.rollbackRecipe(name: recipeName, expectedManifest: expectedManifest)
            if expectedManifest.kind == .new {
                Task { @MainActor in
                    _ = await IOSDynamicToolRegistry.shared.refresh()
                    dismiss()
                }
                return
            }
            loadSnapshot()
            Task { @MainActor in
                // 下一模型轮可见（round-boundary refresh 同源）。
                _ = await IOSDynamicToolRegistry.shared.refresh()
            }
        } catch {
            refreshRollbackAvailability()
            pendingAlert = .operationFailed(error.localizedDescription)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard let packageHash else { return }
        do {
            _ = try store.setRecipeEnabled(
                name: recipeName,
                enabled: enabled,
                expectedHash: packageHash
            )
            isEnabled = enabled
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
            }
        } catch {
            loadSnapshot()
            pendingAlert = .operationFailed(error.localizedDescription)
        }
    }

    private func deleteRecipe() {
        guard let packageHash else { return }
        do {
            _ = try store.deleteRecipe(name: recipeName, expectedHash: packageHash)
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
                dismiss()
            }
        } catch {
            loadSnapshot()
            pendingAlert = .operationFailed(error.localizedDescription)
        }
    }
}

private struct RecipeDetailRow: View {
    let title: String
    let value: String
    var monospace = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .layoutPriority(1)

            Text(value)
                .font(monospace ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(0)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct RecipeDetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

private struct RecipeDetailFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }
}

private enum RecipeDetailAlert: Identifiable {
    case operationFailed(String)

    var id: String {
        switch self {
        case .operationFailed(let message): "operationFailed-\(message)"
        }
    }

    var title: String {
        "操作失败"
    }

    var message: String {
        switch self {
        case .operationFailed(let message): message
        }
    }
}

// MARK: - Dynamic plugin center

private struct PluginNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PluginImportCandidate: Identifiable {
    let id = UUID()
    let preparation: IOSPluginPackagePreparation
    let files: [String: Data]
}

struct PluginsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    private let store = IOSPluginFileStore(baseDirectory: recipeStoreBaseDirectory())
    @State private var plugins: [IOSInstalledPlugin] = []
    @State private var isImporting = false
    @State private var pendingImport: PluginImportCandidate?
    @State private var notice: PluginNotice?

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    installedSection
                    publicIndexSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $pendingImport) { candidate in
            PluginImportPreviewSheet(candidate: candidate) {
                applyImport(candidate)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var header: some View {
        ZStack {
            Text("插件中心")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            HStack {
                AmberGlassCircleButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: "返回技能",
                    size: 44,
                    symbolSize: 20
                ) { dismiss() }
                Spacer()
                AmberGlassIconButton(
                    systemImage: "plus",
                    accessibilityLabel: "导入插件",
                    size: 44,
                    symbolSize: 20,
                    tint: AmberTheme.accent,
                    prominent: true
                ) { isImporting = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var installedSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "已安装")
            AmberFormGroup {
                if plugins.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(AmberTheme.muted2)
                        Text("暂无插件")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("点右上角导入 .amberplugin；Agent 也可从 Workspace 预览并申请导入。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                } else {
                    ForEach(Array(plugins.enumerated()), id: \.element.package.manifest.id) { index, plugin in
                        Button {
                            router.navigate(to: .pluginDetail(id: plugin.package.manifest.id))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: plugin.health.isQuarantined
                                    ? "exclamationmark.shield"
                                    : "puzzlepiece.extension")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(pluginStatusColor(plugin))
                                    .frame(width: 32, height: 32)
                                    .background(
                                        pluginStatusColor(plugin).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(plugin.package.manifest.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("v\(plugin.package.manifest.version) · \(pluginStatusText(plugin))")
                                        .font(.caption)
                                        .foregroundStyle(pluginStatusColor(plugin))
                                        .lineLimit(1)
                                    Text("\(plugin.package.tools.count) 个工具 · \(pluginTrustText(plugin.trust))")
                                        .font(.caption2)
                                        .foregroundStyle(AmberTheme.muted2)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted2)
                            }
                            .frame(minHeight: 64)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < plugins.count - 1 { RecipeDetailDivider() }
                    }
                }
            }
            RecipeDetailFooter("自动隔离只影响后续调用；正在执行的工具继续使用其固定版本收口。")
        }
    }

    private var publicIndexSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "公开索引")
            AmberFormGroup {
                RecipeDetailRow(title: "状态", value: "尚未配置服务端")
                RecipeDetailDivider()
                RecipeDetailRow(title: "本机接口", value: "元数据 · 屏蔽 · 举报 · 年龄")
            }
            RecipeDetailFooter("当前不会展示虚构市场；插件包可先携带索引元数据，待服务端接入后复用。")
        }
        .padding(.top, 20)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let prepared = try store.prepareArchive(data: Data(contentsOf: url, options: [.mappedIfSafe]))
            pendingImport = PluginImportCandidate(
                preparation: prepared.preparation,
                files: prepared.files
            )
        } catch {
            notice = PluginNotice(title: "无法预览插件", message: error.localizedDescription)
        }
    }

    private func applyImport(_ candidate: PluginImportCandidate) {
        do {
            let receipt = try store.applyPlugin(
                files: candidate.files,
                expectedBaseHash: candidate.preparation.base?.hash,
                expectedCandidateHash: candidate.preparation.candidate.hash,
                trust: candidate.preparation.candidateTrust
            )
            pendingImport = nil
            Task { @MainActor in
                await reload()
                notice = PluginNotice(
                    title: receipt.changed ? "插件已导入" : "插件未变化",
                    message: receipt.enabled
                        ? "已从下一模型轮生效。"
                        : "插件保持停用；检查权限后可在详情页启用。"
                )
            }
        } catch {
            notice = PluginNotice(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func reload() async {
        plugins = store.listInstalledPlugins()
        _ = await IOSDynamicToolRegistry.shared.refresh()
    }
}

private struct PluginImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidate: PluginImportCandidate
    let apply: () -> Void

    private var package: IOSPluginPackage { candidate.preparation.candidate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 5) {
                        Text(package.manifest.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AmberTheme.foreground)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Text("\(package.manifest.id) · v\(package.manifest.version)")
                            .font(.caption.monospaced())
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    VStack(spacing: 0) {
                        RecipeDetailRow(title: "变更", value: candidate.preparation.base == nil ? "新增" : "更新")
                        RecipeDetailDivider()
                        RecipeDetailRow(title: "信任", value: pluginTrustText(candidate.preparation.candidateTrust))
                        RecipeDetailDivider()
                        RecipeDetailRow(
                            title: "权限",
                            value: IOSDynamicToolRegistry.permissionSummary(for: package.permissionEnvelope)
                        )
                        RecipeDetailDivider()
                        RecipeDetailRow(title: "安装后", value: importStateText)
                    }
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("权限变化")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        ForEach(permissionDiffRows, id: \.self) { row in
                            Text(row)
                                .font(.caption.monospaced())
                                .foregroundStyle(row.hasPrefix("+") ? AmberTheme.accentAmber : AmberTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("注册工具")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        ForEach(package.tools, id: \.toolId) { tool in
                            Text("\(tool.toolId) · \(pluginHandlerText(tool.implementation))")
                                .font(.caption.monospaced())
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: apply).fontWeight(.semibold)
                }
            }
        }
    }

    private var importStateText: String {
        candidate.preparation.base == nil || candidate.preparation.permissionExpanded
            ? "保持停用"
            : "沿用当前状态"
    }

    private var permissionDiffRows: [String] {
        let new = Set(pluginScopeRows(package.manifest.capabilities))
        guard let base = candidate.preparation.base else {
            return new.isEmpty ? ["无额外能力范围"] : new.sorted().map { "+ \($0)" }
        }
        let old = Set(pluginScopeRows(base.manifest.capabilities))
        let added = new.subtracting(old).sorted().map { "+ \($0)" }
        let removed = old.subtracting(new).sorted().map { "− \($0)" }
        return added + removed == [] ? ["权限范围未变化"] : added + removed
    }
}

struct PluginDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let pluginId: String
    private let store = IOSPluginFileStore(baseDirectory: recipeStoreBaseDirectory())
    private let directoryPolicy = IOSPluginDirectoryPolicyStore(baseDirectory: recipeStoreBaseDirectory())

    @State private var plugin: IOSInstalledPlugin?
    @State private var didLoad = false
    @State private var isBlocked = false
    @State private var canRollback = false
    @State private var notice: PluginNotice?
    @State private var deleteConfirmation = false
    @State private var rollbackConfirmation = false
    @State private var reportConfirmation = false

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    hero
                    identitySection
                    toolsSection
                    permissionsSection
                    backgroundSection
                    healthSection
                    directorySection
                    managementSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { load() }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("知道了")))
        }
        .confirmationDialog("删除插件", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { deletePlugin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除当前包、回退槽和诊断记录；在途调用仍按固定快照收口。")
        }
        .confirmationDialog("回退插件", isPresented: $rollbackConfirmation, titleVisibility: .visible) {
            Button("确认回退", role: .destructive) { rollbackPlugin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复上一个已验证包；原权限和启用状态会按回退记录恢复。")
        }
        .confirmationDialog("记录本机举报", isPresented: $reportConfirmation, titleVisibility: .visible) {
            Button("记录举报", role: .destructive) { reportPlugin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前未配置服务端。此操作只在本机记录，不会伪称已提交到市场。")
        }
    }

    private var header: some View {
        ZStack {
            Text("插件详情")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            HStack {
                AmberGlassCircleButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: "返回插件中心",
                    size: 44,
                    symbolSize: 20
                ) { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: plugin?.health.isQuarantined == true
                ? "exclamationmark.shield"
                : "puzzlepiece.extension")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(plugin.map(pluginStatusColor) ?? AmberTheme.muted2)
                .frame(width: 64, height: 64)
                .background(
                    (plugin.map(pluginStatusColor) ?? AmberTheme.muted2).opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            Text(plugin?.package.manifest.name ?? pluginId)
                .font(.title3.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(plugin.map(pluginStatusText) ?? (didLoad ? "未找到" : "读取中"))
                .font(.caption)
                .foregroundStyle(plugin.map(pluginStatusColor) ?? AmberTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }

    private var identitySection: some View {
        pluginSection(title: "包信息") {
            RecipeDetailRow(title: "标识", value: pluginId, monospace: true)
            RecipeDetailDivider()
            RecipeDetailRow(title: "版本", value: plugin?.package.manifest.version ?? "—")
            RecipeDetailDivider()
            RecipeDetailRow(title: "信任", value: plugin.map { pluginTrustText($0.trust) } ?? "—")
            RecipeDetailDivider()
            RecipeDetailRow(title: "包哈希", value: plugin?.package.hash ?? "—", monospace: true)
        }
    }

    private var toolsSection: some View {
        pluginSection(title: "工具") {
            let tools = plugin?.package.tools ?? []
            if tools.isEmpty {
                RecipeDetailRow(title: "工具", value: "未读取")
            } else {
                ForEach(Array(tools.enumerated()), id: \.element.toolId) { index, tool in
                    RecipeDetailRow(
                        title: tool.toolId,
                        value: "\(pluginHandlerText(tool.implementation)) · \(tool.effectClass.rawValue)",
                        monospace: true
                    )
                    if index < tools.count - 1 { RecipeDetailDivider() }
                }
            }
        }
        .padding(.top, 20)
    }

    private var permissionsSection: some View {
        pluginSection(title: "能力范围") {
            let rows = plugin.map { pluginScopeRows($0.package.manifest.capabilities) } ?? []
            if rows.isEmpty {
                RecipeDetailRow(title: "额外范围", value: "无")
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    RecipeDetailRow(title: "范围 \(index + 1)", value: row, monospace: true)
                    if index < rows.count - 1 { RecipeDetailDivider() }
                }
            }
        }
        .padding(.top, 20)
    }

    private var backgroundSection: some View {
        pluginSection(title: "后台") {
            RecipeDetailRow(
                title: "插件声明",
                value: plugin?.package.manifest.backgroundAllowed == true ? "允许" : "未允许"
            )
            RecipeDetailDivider()
            RecipeDetailRow(title: "实际可用", value: backgroundEligibilityText)
        }
        .padding(.top, 20)
    }

    private var healthSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "运行健康")
            AmberFormGroup {
                RecipeDetailRow(
                    title: "连续故障",
                    value: "\(plugin?.health.consecutiveFailures ?? 0) / \(IOSPluginHealthSnapshot.quarantineThreshold)"
                )
                if let reason = plugin?.health.quarantineReason {
                    RecipeDetailDivider()
                    RecipeDetailRow(title: "隔离原因", value: reason)
                }
                let diagnostics = Array((plugin?.health.diagnostics ?? []).reversed())
                ForEach(diagnostics.prefix(8)) { event in
                    RecipeDetailDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.kind.rawValue) · \(event.toolId)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(event.detail)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            RecipeDetailFooter("日志最多保留 50 条，每条 500 字；包版本变化不会继承旧版本故障。")
        }
        .padding(.top, 20)
    }

    private var directorySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "公开索引元数据")
            AmberFormGroup {
                if let metadata = plugin?.package.manifest.directory {
                    RecipeDetailRow(title: "发布者", value: metadata.publisher)
                    RecipeDetailDivider()
                    RecipeDetailRow(title: "年龄", value: metadata.minimumAge.map { "\($0)+" } ?? "未声明")
                    ForEach(directoryLinks(metadata)) { link in
                        RecipeDetailDivider()
                        Button { openURL(link.url) } label: {
                            HStack(spacing: 12) {
                                Text(link.title)
                                    .foregroundStyle(AmberTheme.foreground)
                                Spacer(minLength: 8)
                                Text(link.url.host ?? link.url.absoluteString)
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted2)
                            }
                            .frame(minHeight: 52)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    RecipeDetailRow(title: "状态", value: "未声明")
                }
                RecipeDetailDivider()
                Toggle("屏蔽此索引条目", isOn: Binding(
                    get: { isBlocked },
                    set: { setBlocked($0) }
                ))
                .tint(AmberTheme.accent)
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                RecipeDetailDivider()
                Button(role: .destructive) { reportConfirmation = true } label: {
                    Text("记录本机举报")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.plain)
            }
            RecipeDetailFooter("屏蔽和举报当前只保存为本机策略；尚未接入公开索引服务端。")
        }
        .padding(.top, 20)
    }

    private var managementSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "管理")
            AmberFormGroup {
                Toggle("启用状态", isOn: Binding(
                    get: { plugin?.isConfiguredEnabled ?? false },
                    set: { setEnabled($0) }
                ))
                .tint(AmberTheme.accent)
                .frame(minHeight: 52)
                .padding(.horizontal, 14)
                .disabled(plugin == nil)

                RecipeDetailDivider()
                Button("安全自检") { selfTest() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(plugin == nil ? AmberTheme.muted2 : AmberTheme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .buttonStyle(.plain)
                    .disabled(plugin == nil)

                if plugin?.health.isQuarantined == true {
                    RecipeDetailDivider()
                    Button("解除自动隔离") { restorePlugin() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.accentAmber)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .buttonStyle(.plain)
                }

                RecipeDetailDivider()
                Button("回退上一个版本") { rollbackConfirmation = true }
                    .font(.body.weight(.medium))
                    .foregroundStyle(canRollback ? AmberTheme.accentAmber : AmberTheme.muted2)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .buttonStyle(.plain)
                    .disabled(!canRollback)

                RecipeDetailDivider()
                Button(role: .destructive) { deleteConfirmation = true } label: {
                    Text("删除插件")
                        .font(.body.weight(.medium))
                        .foregroundStyle(plugin == nil ? AmberTheme.muted2 : AmberTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.plain)
                .disabled(plugin == nil)
            }
            RecipeDetailFooter(
                (didLoad && plugin == nil
                    ? "插件不存在或已被删除。"
                    : (canRollback ? "" : "当前没有可回退版本。"))
                    + "安全自检只检查包、签名和声明；实际工具调用仍在聊天中按能力范围和审批策略执行。"
            )
        }
        .padding(.top, 20)
    }

    private func pluginSection<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: title)
            AmberFormGroup { content() }
        }
    }

    private var backgroundEligibilityText: String {
        guard let plugin else { return "—" }
        let eligible = plugin.package.tools.filter { tool in
            guard plugin.package.manifest.backgroundAllowed,
                  tool.effectClass == .pure || tool.effectClass == .networkRead else { return false }
            switch tool.implementation {
            case .recipe, .remote: return true
            case .javascript: return false
            }
        }
        return eligible.isEmpty ? "无" : "\(eligible.count) 个只读工具"
    }

    private struct DirectoryLink: Identifiable {
        let title: String
        let url: URL

        var id: String { title }
    }

    private func directoryLinks(_ metadata: IOSPluginDirectoryMetadata) -> [DirectoryLink] {
        [
            ("主页", metadata.homepageURL),
            ("支持", metadata.supportURL),
            ("隐私", metadata.privacyURL),
        ].compactMap { title, raw in
            guard let raw, let url = URL(string: raw) else { return nil }
            return DirectoryLink(title: title, url: url)
        }
    }

    private func load() {
        plugin = store.listInstalledPlugins().first { $0.package.manifest.id == pluginId }
        canRollback = store.canRollbackPlugin(id: pluginId)
        isBlocked = directoryPolicy.snapshot().blockedPluginIds.contains(pluginId)
        didLoad = true
    }

    private func setEnabled(_ enabled: Bool) {
        guard let current = plugin else { return }
        do {
            _ = try store.setPluginEnabled(id: pluginId, enabled: enabled, expectedHash: current.package.hash)
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
                load()
            }
        } catch {
            load()
            notice = PluginNotice(title: "操作失败", message: error.localizedDescription)
        }
    }

    private func restorePlugin() {
        guard let current = plugin else { return }
        do {
            _ = try store.restorePlugin(id: pluginId, expectedHash: current.package.hash)
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
                load()
                notice = PluginNotice(title: "隔离已解除", message: "插件按当前启用状态从下一模型轮恢复。")
            }
        } catch {
            notice = PluginNotice(title: "恢复失败", message: error.localizedDescription)
        }
    }

    private func selfTest() {
        do {
            _ = try store.readLivePlugin(id: pluginId)
            _ = try store.exportArchive(id: pluginId)
            notice = PluginNotice(title: "自检通过", message: "包路径、schema、工具声明、内容哈希与信任记录均有效。")
        } catch {
            notice = PluginNotice(title: "自检失败", message: error.localizedDescription)
        }
    }

    private func rollbackPlugin() {
        guard let current = plugin else { return }
        do {
            _ = try store.rollbackPlugin(id: pluginId, expectedCurrentHash: current.package.hash)
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
                load()
            }
        } catch {
            notice = PluginNotice(title: "回退失败", message: error.localizedDescription)
        }
    }

    private func deletePlugin() {
        guard let current = plugin else { return }
        do {
            _ = try store.deletePlugin(id: pluginId, expectedHash: current.package.hash)
            Task { @MainActor in
                _ = await IOSDynamicToolRegistry.shared.refresh()
                dismiss()
            }
        } catch {
            notice = PluginNotice(title: "删除失败", message: error.localizedDescription)
        }
    }

    private func setBlocked(_ blocked: Bool) {
        do {
            try directoryPolicy.setBlocked(pluginId: pluginId, blocked: blocked)
            isBlocked = blocked
        } catch {
            load()
            notice = PluginNotice(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func reportPlugin() {
        do {
            try directoryPolicy.recordLocalReport(
                pluginId: pluginId,
                reason: "用户从插件详情页标记此索引条目"
            )
            notice = PluginNotice(title: "已在本机记录", message: "尚未配置服务端，因此没有声称已向市场提交。")
        } catch {
            notice = PluginNotice(title: "记录失败", message: error.localizedDescription)
        }
    }
}

private func pluginStatusText(_ plugin: IOSInstalledPlugin) -> String {
    if plugin.health.isQuarantined { return "已隔离" }
    if !plugin.isConfiguredEnabled { return "已停用" }
    if !plugin.isEnabled { return "校验失败" }
    return "已启用"
}

private func pluginStatusColor(_ plugin: IOSInstalledPlugin) -> Color {
    if plugin.health.isQuarantined || (plugin.isConfiguredEnabled && !plugin.isEnabled) {
        return AmberTheme.accentRed
    }
    return plugin.isEnabled ? AmberTheme.accentGreen : AmberTheme.muted2
}

private func pluginTrustText(_ trust: IOSPluginTrustRecord) -> String {
    switch trust.tier {
    case .builtIn: return "内置"
    case .signed: return "已签名 · \(trust.keyId ?? "未知签名者")"
    case .localUnsigned: return "本地未签名"
    }
}

private func pluginHandlerText(_ implementation: IOSPluginToolImplementation) -> String {
    switch implementation {
    case .recipe: return "Recipe"
    case .javascript: return "受限 JS"
    case .remote(let remote): return remote.kind == .mcp ? "MCP" : "OpenAPI"
    }
}

private func pluginScopeRows(_ capabilities: IOSPluginCapabilities) -> [String] {
    var rows: [String] = []
    rows += capabilities.workspaceReadPrefixes.map { "Workspace 读取：\($0)" }
    rows += capabilities.workspaceWritePrefixes.map { "Workspace 写入：\($0)" }
    rows += capabilities.networkDomains.map { "网络：\($0)" }
    rows += capabilities.webMountActions.map { "WebMount：\($0)" }
    return rows
}
