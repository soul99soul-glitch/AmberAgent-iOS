import SwiftUI

struct NovelWritingInjectionOverview: View {
    let workspace: NovelCreationViewModel
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity
    @Binding var budgetTokens: Int
    let materialChoices: [NovelMaterialID: NovelWritingMaterialChoice]
    let hasMatchingPreview: Bool

    var body: some View {
        List {
            Section("本次生成") {
                LabeledContent(
                    "模式",
                    value: IOSAppLocalization.string(
                        mode == .writeProse ? "写正文" : "讨论规划",
                        defaultValue: mode == .writeProse ? "写正文" : "讨论规划"
                    )
                )
                if mode == .writeProse {
                    LabeledContent(
                        "粒度",
                        value: IOSAppLocalization.string(
                            granularity == .wholeChapter ? "生成整章" : "续写片段",
                            defaultValue: granularity == .wholeChapter ? "生成整章" : "续写片段"
                        )
                    )
                }
            }

            Section {
                ForEach(NovelWritingMaterialCategory.allCases) { category in
                    NavigationLink(value: NovelWritingContextRoute.materials(category)) {
                        Label {
                            LabeledContent(category.title, value: categorySummary(category))
                        } icon: {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(AmberTheme.accent)
                        }
                    }
                }
            } header: {
                Text("资料注入")
            } footer: {
                Text("进入分类后选择本次加入或排除；不会修改资料的默认注入方式。")
            }

            Section("高级") {
                Slider(
                    value: budgetSliderValue,
                    in: 2_000...64_000,
                    step: 2_000
                ) {
                    Text("上下文长度")
                } currentValueLabel: {
                    Text("约 \(budgetTokens.formatted())")
                } minimumValueLabel: {
                    Text("2K")
                } maximumValueLabel: {
                    Text("64K")
                } tick: { value in
                    Self.budgetTick(for: value)
                }
            }

            if hasMatchingPreview {
                Section {
                    NavigationLink("查看预计上下文", value: NovelWritingContextRoute.preview)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
    }

    private var budgetSliderValue: Binding<Double> {
        Binding(
            get: { Double(budgetTokens) },
            set: { newValue in
                budgetTokens = Int(newValue.rounded())
            }
        )
    }

    private static func budgetTick(for value: Double) -> SliderTick<Double>? {
        let tokens = Int(value.rounded())
        guard [8_000, 16_000, 32_000].contains(tokens) else { return nil }
        return SliderTick(value) {
            Text("\(tokens / 1_000)K")
        }
    }

    private func materials(in category: NovelWritingMaterialCategory) -> [NovelMaterialRecord] {
        workspace.activeMaterials.filter { category.contains($0.kind) }
    }

    private func categorySummary(_ category: NovelWritingMaterialCategory) -> String {
        let categoryMaterials = materials(in: category)
        let adjusted = categoryMaterials.filter {
            (materialChoices[$0.id] ?? .automatic) != .automatic
        }.count
        guard adjusted > 0 else {
            return IOSAppLocalization.formatted(
                "%lld 条",
                defaultValue: "%lld 条",
                arguments: [categoryMaterials.count]
            )
        }
        return IOSAppLocalization.formatted(
            "%lld 条 · 已调整 %lld",
            defaultValue: "%lld 条 · 已调整 %lld",
            arguments: [categoryMaterials.count, adjusted]
        )
    }

}

struct NovelWritingMaterialChoicesView: View {
    let workspace: NovelCreationViewModel
    let category: NovelWritingMaterialCategory
    @Binding var materialChoices: [NovelMaterialID: NovelWritingMaterialChoice]
    let onChoiceChanged: (NovelInjectionOverrides) -> Void

    var body: some View {
        List {
            Section {
                if materials(in: category).isEmpty {
                    ContentUnavailableView(
                        IOSAppLocalization.formatted(
                            "没有%@资料",
                            defaultValue: "没有%@资料",
                            arguments: [category.title]
                        ),
                        systemImage: category.systemImage
                    )
                } else {
                    ForEach(materials(in: category), id: \.id) { material in
                        Picker(materialTitle(material), selection: choiceBinding(material.id)) {
                            ForEach(NovelWritingMaterialChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } footer: {
                Text("按默认会沿用每条资料自己的注入设置。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func materials(in category: NovelWritingMaterialCategory) -> [NovelMaterialRecord] {
        workspace.activeMaterials.filter { category.contains($0.kind) }
    }

    private func choiceBinding(_ materialID: NovelMaterialID) -> Binding<NovelWritingMaterialChoice> {
        Binding(
            get: { materialChoices[materialID] ?? .automatic },
            set: { choice in
                var updatedChoices = materialChoices
                if choice == .automatic {
                    updatedChoices.removeValue(forKey: materialID)
                } else {
                    updatedChoices[materialID] = choice
                }
                materialChoices = updatedChoices
                // 即时回写：勾选/取消即时生效，不需要再点「应用」。
                onChoiceChanged(NovelWritingInjectionSelection.overrides(for: updatedChoices))
            }
        )
    }

    private func materialTitle(_ material: NovelMaterialRecord) -> String {
        guard let project = workspace.projectSnapshot else { return material.kind.displayName }
        return NovelPresentation.effectiveRevision(
            for: material,
            project: project,
            branch: workspace.branchSnapshot
        )?.title ?? material.kind.displayName
    }

}

struct NovelWritingContextPreviewView: View {
    let preview: NovelInjectionPreviewSnapshot?

    @ViewBuilder
    var body: some View {
        if let preview {
            List {
                Section("预计上下文") {
                    LabeledContent("模型", value: preview.resolvedModel.displayName)
                    LabeledContent(
                        "预计输入",
                        value: "\(preview.plan.estimatedInputTokens.formatted()) / \(preview.effectiveInputBudgetTokens.formatted())"
                    )
                }
                Section("注入内容") {
                    ForEach(Array(preview.plan.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.label)
                                .font(.subheadline.weight(.medium))
                            Text("\(section.reason.displayName) · 约 \(section.estimatedTokens) 上下文单位")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle("预计上下文")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("预览已失效", systemImage: "arrow.clockwise")
                .navigationTitle("预计上下文")
        }
    }
}

enum NovelWritingContextTab: String, CaseIterable, Identifiable {
    case preferences
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferences:
            IOSAppLocalization.string("模式与偏好", defaultValue: "模式与偏好")
        case .context:
            IOSAppLocalization.string("上下文注入", defaultValue: "上下文注入")
        }
    }
}

enum NovelWritingMaterialChoice: String, CaseIterable, Identifiable {
    case automatic
    case include
    case exclude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            IOSAppLocalization.string("按默认", defaultValue: "按默认")
        case .include:
            IOSAppLocalization.string("本次加入", defaultValue: "本次加入")
        case .exclude:
            IOSAppLocalization.string("本次排除", defaultValue: "本次排除")
        }
    }
}

enum NovelWritingContextRoute: Hashable {
    case materials(NovelWritingMaterialCategory)
    case preview
}

enum NovelWritingMaterialCategory: String, CaseIterable, Identifiable, Hashable {
    case characters
    case world
    case story
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .characters:
            IOSAppLocalization.string("人物角色", defaultValue: "人物角色")
        case .world:
            IOSAppLocalization.string("世界观", defaultValue: "世界观")
        case .story:
            IOSAppLocalization.string("剧情大纲", defaultValue: "剧情大纲")
        case .other:
            IOSAppLocalization.string("其他资料", defaultValue: "其他资料")
        }
    }

    var systemImage: String {
        switch self {
        case .characters: "person.2"
        case .world: "globe.asia.australia"
        case .story: "point.3.connected.trianglepath.dotted"
        case .other: "doc.text"
        }
    }

    func contains(_ kind: NovelMaterialKind) -> Bool {
        switch (self, kind) {
        case (.characters, .character), (.world, .world), (.story, .masterOutline):
            true
        case (.other, .writingRequirements), (.other, .custom):
            true
        default:
            false
        }
    }
}

@MainActor
enum NovelWritingInjectionSelection {
    static func overrides(for choices: [NovelMaterialID: NovelWritingMaterialChoice]) -> NovelInjectionOverrides {
        NovelInjectionOverrides(
            forceIncludeMaterialIDs: choices.compactMap { id, choice in
                choice == .include ? id : nil
            },
            forceExcludeMaterialIDs: choices.compactMap { id, choice in
                choice == .exclude ? id : nil
            }
        )
    }

    static func matchingPreview(
        workspace: NovelCreationViewModel,
        previewSignature: String?,
        currentSignature: String
    ) -> NovelInjectionPreviewSnapshot? {
        guard let preview = workspace.injectionPreview,
              previewSignature == currentSignature,
              preview.projectID == workspace.selectedProjectID,
              preview.branchID == workspace.selectedBranchID else {
            return nil
        }
        return preview
    }

    static func previewRequest(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity,
        userText: String,
        overrides: NovelInjectionOverrides,
        budgetTokens: Int
    ) -> NovelInjectionPreviewRequest {
        NovelInjectionPreviewRequest(
            projectID: projectID,
            branchID: branchID,
            kind: mode == .writeProse ? .prose : .discussion,
            mode: mode,
            granularity: mode == .writeProse ? granularity : nil,
            userText: userText,
            sourceChapterVersionID: nil,
            injectionOverrides: overrides,
            inputBudgetTokens: budgetTokens
        )
    }

    static func signature(
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity,
        userText: String,
        budgetTokens: Int,
        workspace: NovelCreationViewModel,
        overrides: NovelInjectionOverrides
    ) -> String {
        let included = overrides.forceIncludeMaterialIDs.map(\.description).sorted().joined(separator: ",")
        let excluded = overrides.forceExcludeMaterialIDs.map(\.description).sorted().joined(separator: ",")
        let projectRevision = workspace.projectSnapshot?.project.revision ?? -1
        let configRevision = workspace.projectSnapshot?.project.configRevision ?? -1
        let headRevision = workspace.branchSnapshot?.branch.headRevision ?? -1
        return [
            mode.rawValue,
            mode == .writeProse ? granularity.rawValue : "discussion",
            String(userText.hashValue),
            String(budgetTokens),
            String(projectRevision),
            String(configRevision),
            String(headRevision),
            included,
            excluded
        ].joined(separator: "|")
    }
}
