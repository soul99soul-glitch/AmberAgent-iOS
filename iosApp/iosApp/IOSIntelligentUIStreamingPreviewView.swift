import SwiftUI

/// A visible construction preview. It never reads the conversation owner or drafts.
struct IOSIntelligentUIStreamingPreviewView: View {
    let preview: IOSIntelligentUIStreamingPreview
    var generationNamespace: String? = nil
    var isAnimating = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                IOSGenerationActivityIndicator(isActive: isAnimating)
                Text(preview.isRootComplete ? "界面已生成，等待回复完成" : "正在生成任务界面")
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
            if let goal = preview.goal {
                Text(goal).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-preview-goal")
                    .nativeGenerationReveal(key: motionKey("goal"))
            }
            if let question = preview.question {
                Text(question).font(.subheadline).foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .nativeGenerationReveal(key: motionKey("question"))
            }
            if !preview.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview.options) { option in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(option.title).font(.subheadline.weight(.semibold))
                            Text(option.summary).font(.subheadline).foregroundStyle(AmberTheme.foreground2)
                            ForEach(Array((option.tradeoffs ?? []).enumerated()), id: \.offset) { _, tradeoff in
                                Text("• " + tradeoff).font(.footnote).foregroundStyle(AmberTheme.muted)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(10)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                        .nativeGenerationReveal(key: motionKey("option:\(option.id)"))
                    }
                }
            }
            ForEach(preview.components) { component in
                IOSIntelligentUIComponentView(
                    component: component, draftValues: .constant([:]), isEnabled: false, canSubmit: false,
                    generationNamespace: generationNamespace,
                    fieldLabels: fieldLabels,
                    fieldComponents: fieldComponents,
                    requiredFieldIDs: Set(preview.fields.filter(\.required).map(\.id)),
                    onSubmit: {}, onReset: {}
                )
            }
            ForEach(preview.fields.filter { !hasInput($0.id, in: preview.components) }) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label + (field.required ? "（必填）" : ""))
                        .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(field.placeholder ?? "等待界面完成后填写")
                        .font(.subheadline).foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AmberTheme.borderSoft))
                }
                .nativeGenerationReveal(key: motionKey("field:\(field.id)"))
            }
            ForEach(Array(preview.studyPrompts.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(index + 1) 项").font(.caption).foregroundStyle(AmberTheme.muted)
                    Text(item.prompt).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("task-ui-preview-study-\(item.id)")
                .nativeGenerationReveal(key: motionKey("study:\(item.id)"))
            }
            if !counts.isEmpty {
                Text("已收到：" + counts.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-preview-count")
            }
            if let issue = preview.issue {
                Text(issue).font(.footnote).foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("生成预览，暂不可操作")
                .font(.caption).foregroundStyle(AmberTheme.muted)
                .accessibilityIdentifier("task-ui-preview-readonly")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AmberTheme.borderSoft))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-ui-streaming-preview")
    }

    private func motionKey(_ element: String) -> String? { generationNamespace.map { "\($0):\(element)" } }

    private var fieldLabels: [String: String] { Dictionary(uniqueKeysWithValues: preview.fields.map { ($0.id, $0.label) }) }

    private var fieldComponents: [String: IOSIntelligentUIComponent] {
        Dictionary(uniqueKeysWithValues: preview.fields.compactMap { field in
            input(for: field.id, in: preview.components).map { (field.id, $0) }
        })
    }

    private var counts: [String] {
        var result: [String] = []
        if !preview.options.isEmpty { result.append("\(preview.options.count) 个方案") }
        if !preview.fields.isEmpty { result.append("\(preview.fields.count) 个字段") }
        if preview.componentCount > 0 { result.append("\(preview.componentCount) 个组件") }
        if !preview.studyPrompts.isEmpty { result.append("\(preview.studyPrompts.count) 个学习项目") }
        return result
    }

    private func hasInput(_ fieldID: String, in nodes: [IOSIntelligentUIComponent]) -> Bool {
        input(for: fieldID, in: nodes) != nil
    }

    private func input(for fieldID: String, in nodes: [IOSIntelligentUIComponent]) -> IOSIntelligentUIComponent? {
        for node in nodes {
            if node.kind.requiresField && node.fieldID == fieldID { return node }
            if let found = input(for: fieldID, in: node.children ?? []) { return found }
        }
        return nil
    }
}
