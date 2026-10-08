import SwiftUI

struct DeepReadTemplatesView: View {
    let settings: DeepReadSettingsStore
    private let store = IOSDeepReadTemplateStore.shared
    @Bindable private var appearance = DeepReadAppearance.shared
    @State private var editing: IOSDeepReadCustomTemplate?
    @State private var deleting: IOSDeepReadCustomTemplate?

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(DeepReadReaderLayout.allCases) { layout in
                        Button {
                            withAnimation(.snappy) { appearance.readerLayout = layout }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: layout.symbol)
                                    .font(.title3)
                                    .foregroundStyle(DeepReadPalette.accent)
                                    .frame(width: 48, height: 60)
                                    .background(DeepReadPalette.paper, in: .rect(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeepReadPalette.rule))
                                    .symbolEffect(.bounce, value: appearance.readerLayout == layout)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(layout.name).foregroundStyle(.primary)
                                    Text(layout.detail).font(.caption).foregroundStyle(DeepReadPalette.muted)
                                }
                                Spacer()
                                if appearance.readerLayout == layout { Image(systemName: "checkmark").foregroundStyle(DeepReadPalette.accent).transition(.scale.combined(with: .opacity)) }
                            }
                        }
                        .accessibilityAddTraits(appearance.readerLayout == layout ? .isSelected : [])
                    }
                } header: {
                    Text("版式编排")
                } footer: {
                    Text("同一篇文章换一种阅读顺序，可与下面的样式自由组合。")
                }
                Section {
                    ForEach(DeepReadReaderStyle.allCases) { style in
                        Button {
                            withAnimation(.snappy) { appearance.readerStyle = style }
                        } label: {
                            HStack(spacing: 14) {
                                DeepReadStylePreview(style: style)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(style.name).foregroundStyle(.primary)
                                    Text(style.detail).font(.caption).foregroundStyle(DeepReadPalette.muted)
                                }
                                Spacer()
                                if appearance.readerStyle == style { Image(systemName: "checkmark").foregroundStyle(DeepReadPalette.accent).transition(.scale.combined(with: .opacity)) }
                            }
                        }
                        .accessibilityAddTraits(appearance.readerStyle == style ? .isSelected : [])
                    }
                } header: {
                    Text("阅读样式")
                } footer: {
                    Text("作用于所有使用内置版式的文章，也可在文章页右上角切换。")
                }
                Section {
                    ForEach(DeepReadSynthesisTemplate.options, id: \.id) { template in
                        Button {
                            settings.templateId = template.id
                            _ = settings.save()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: template.symbol)
                                    .font(.title3)
                                    .foregroundStyle(DeepReadPalette.accent)
                                    .frame(width: 48, height: 48)
                                    .background(DeepReadPalette.paper, in: .rect(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeepReadPalette.rule))
                                    .symbolEffect(.bounce, value: settings.templateId == template.id)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.name).foregroundStyle(.primary)
                                    Text(template.detail).font(.caption).foregroundStyle(DeepReadPalette.muted)
                                }
                                Spacer()
                                if settings.templateId == template.id { Image(systemName: "checkmark").foregroundStyle(DeepReadPalette.accent).transition(.scale.combined(with: .opacity)) }
                            }
                        }
                        .accessibilityAddTraits(settings.templateId == template.id ? .isSelected : [])
                    }
                } header: {
                    Text("生成模板")
                } footer: {
                    Text("决定多源综述生成什么内容；只给一篇原文时会自动走精读。")
                }
                Section("自定义模板") {
                    ForEach(store.templates) { template in
                        Button { editing = template } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.name).foregroundStyle(.primary)
                                    Text(template.description).font(.caption).foregroundStyle(DeepReadPalette.muted)
                                }
                                Spacer()
                                if settings.templateId == template.id { Image(systemName: "checkmark").foregroundStyle(DeepReadPalette.accent).transition(.scale.combined(with: .opacity)) }
                            }
                        }
                        .accessibilityAddTraits(settings.templateId == template.id ? .isSelected : [])
                        .contextMenu {
                            Button("用于新文章", systemImage: "checkmark") {
                                settings.templateId = template.id
                                _ = settings.save()
                            }
                            Button("删除模板", systemImage: "trash", role: .destructive) { deleting = template }
                        }
                    }
                    Button("新建 HTML 模板", systemImage: "plus") {
                        editing = .init(name: "自定义模板", description: "", html: IOSDeepReadHTMLTemplateRenderer.starterHTML(), createdByAI: false)
                    }
                    NavigationLink("用 AI 生成模板", destination: DeepReadTemplateGeneratorView(settings: settings))
                }
                if let error = settings.errorMessage { Text(error).foregroundStyle(DeepReadPalette.danger) }
                if let error = store.persistenceError { Text(error).foregroundStyle(DeepReadPalette.danger) }
            }
            .listRowBackground(DeepReadPalette.card)
        }
        .scrollContentBackground(.hidden)
        .background { DeepReadPaperBackground() }
        .animation(.snappy, value: settings.templateId)
        .sensoryFeedback(.selection, trigger: settings.templateId)
        .sensoryFeedback(.selection, trigger: appearance.readerStyle)
        .sensoryFeedback(.selection, trigger: appearance.readerLayout)
        .navigationTitle("阅读模板")
        .sheet(item: $editing) { template in
            NavigationStack { DeepReadTemplateEditorView(template: template, settings: settings) }
        }
        .alert("删除模板？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { template in
            Button("删除", role: .destructive) {
                if store.delete(id: template.id), settings.templateId == template.id {
                    settings.templateId = IOSDeepReadTemplate.defaultId
                    _ = settings.save()
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { template in
            Text("删除「\(template.name)」后，使用此模板的历史文章将以默认版式显示。")
        }
    }
}

struct DeepReadTemplateEditorView: View {
    let settings: DeepReadSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var template: IOSDeepReadCustomTemplate
    private let initial: IOSDeepReadCustomTemplate
    @State private var error: String?
    @State private var validation = ""
    @State private var preview: PreviewDocument?
    private let store = IOSDeepReadTemplateStore.shared
    @Bindable private var appearance = DeepReadAppearance.shared

    private struct PreviewDocument: Identifiable {
        let id = UUID()
        let html: String
    }

    init(template: IOSDeepReadCustomTemplate, settings: DeepReadSettingsStore) {
        self.settings = settings
        _template = State(initialValue: template)
        initial = template
    }

    var body: some View {
        Form {
            Section("模板信息") {
                TextField("名称", text: $template.name)
                TextField("描述", text: $template.description, axis: .vertical)
            }
            Section {
                TextEditor(text: $template.html).font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 300).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityLabel("HTML 模板代码")
            } header: { Text("HTML 与 CSS") } footer: {
                Text("保留 title、summary、analysis_html、extended_reading_html 和 font_css 占位符。模板仅支持静态 HTML 与内联 CSS。")
            }
            Section {
                Button("校验模板", systemImage: "checkmark.shield") {
                    let result = IOSDeepReadTemplateValidator.validateHTML(template.html)
                    validation = result.ok ? "校验通过" : result.error ?? "模板无效"
                }
                if !validation.isEmpty { Text(validation).font(.footnote) }
                Button("预览版式", systemImage: "eye") { makePreview() }
            }
            if let error { Section { Text(error).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled) } }
            Section {
                Button("保存并用于新文章", systemImage: "checkmark") {
                    do {
                        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            error = "请填写模板名称。"
                            return
                        }
                        let saved = try store.save(template)
                        settings.templateId = saved.id
                        guard settings.save() else { error = settings.errorMessage; return }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .navigationTitle("编辑模板")
        .navigationBarTitleDisplayMode(.inline)
        // A swipe must not throw away edited HTML; 取消 stays the explicit way out.
        .interactiveDismissDisabled(template != initial)
        .onChange(of: template) { _, _ in
            validation = ""
            error = nil
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .sheet(item: $preview) { document in
            NavigationStack { DeepReadTemplatePreviewView(html: document.html) }
        }
    }

    private func makePreview() {
        let sample = IOSDeepReadTask(
            id: "template-preview", title: "理解一件事，从多个来源开始", status: .succeeded,
            templateId: template.id,
            sources: [.init(kind: .manualText, title: "示例来源", content: "独立事实、完整背景与不同视角，使阅读更有价值。")],
            resultMarkdown: "## 背景\n\n这是一篇模板预览文章。这里展示正文、标题与段落的排版。\n\n## 多元视角\n\n> 阅读不是结论的收集，而是理解的过程。\n\n- 追溯原始资料\n- 区分事实与观点\n- 保留值得继续追问的问题",
            failureMessage: nil, createdAt: 0, updatedAt: 0, completedAt: 0, retryCount: 0
        )
        do {
            let html = try IOSDeepReadHTMLTemplateRenderer.render(task: sample, template: template, fontScale: Float(settings.fontScale), fontModeWireName: settings.fontMode)
            preview = .init(html: html)
        } catch { self.error = error.localizedDescription }
    }
}

private struct DeepReadTemplatePreviewView: View {
    let html: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack {
            if let error { Text(error).foregroundStyle(DeepReadPalette.danger).padding() }
            DeepReadArticleWebView(html: html, error: $error)
        }
        .navigationTitle("模板预览")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

/// A tiny page swatch: the style's paper, ink, accent and title face.
private struct DeepReadStylePreview: View {
    let style: DeepReadReaderStyle

    var body: some View {
        let light = style.canvas(dark: false), dark = style.canvas(dark: true)
        let fg = DeepReadPalette.adaptive(light: light.fg, dark: dark.fg)
        VStack(alignment: style == .scroll || style == .broadsheet ? .center : .leading, spacing: 4) {
            Text("文")
                .font(.system(size: 17, weight: style == .briefing || style == .broadsheet ? .heavy : .semibold,
                              design: style == .briefing ? .default : .serif))
                .foregroundStyle(fg)
            Capsule().fill(DeepReadPalette.accent).frame(width: 18, height: 3)
            Capsule().fill(fg.opacity(0.25)).frame(width: 30, height: 2)
            Capsule().fill(fg.opacity(0.25)).frame(width: 24, height: 2)
        }
        .padding(8)
        .frame(width: 48, height: 60)
        .background(DeepReadPalette.adaptive(light: light.bg, dark: dark.bg), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(DeepReadPalette.adaptive(light: light.border, dark: dark.border))
            if style == .journal {
                // Dot-grid hint for the notebook style.
                Canvas { context, size in
                    for x in stride(from: 6.0, to: size.width, by: 8) {
                        for y in stride(from: 6.0, to: size.height, by: 8) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.gray.opacity(0.35)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}
