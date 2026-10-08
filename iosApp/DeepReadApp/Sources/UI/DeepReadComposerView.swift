import SwiftUI
import UniformTypeIdentifiers

struct DeepReadComposerView: View {
    let settings: DeepReadSettingsStore
    let runtime: DeepReadRuntime
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var links = ""
    @State private var files: [IOSDeepReadSource] = []
    @State private var importing = false
    @State private var loadingFiles = false
    @State private var error: String?
    @State private var launched = 0
    @State private var readingMode = ReadingMode.closeReading
    /// This reading's template only; the default lives in Settings.
    @State private var templateId: String

    private enum ReadingMode { case closeReading, originalOnly, synthesis }
    private let templates = IOSDeepReadTemplateStore.shared

    init(settings: DeepReadSettingsStore, runtime: DeepReadRuntime, initialTitle: String = "", initialSources: [IOSDeepReadSource] = [], onCreated: @escaping (String) -> Void) {
        self.settings = settings
        self.runtime = runtime
        self.onCreated = onCreated
        _title = State(initialValue: initialTitle)
        _files = State(initialValue: initialSources)
        _templateId = State(initialValue: settings.templateId)
    }

    /// One link, file or pasted text is read as the article itself; more inputs are a topic synthesis.
    private var singleSource: Bool {
        let linkCount = links.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return files.count + linkCount + (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1) == 1
    }

    private var readsOriginal: Bool { singleSource && readingMode != .synthesis }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("想深入了解什么？", text: $title, axis: .vertical)
                        .font(.system(.title3, design: .serif))
                        .accessibilityIdentifier("deepread.compose.topic")
                } header: { Text("阅读主题") } footer: {
                    Text(readsOriginal ? "精读时可以不填，会使用原文标题。" : "自动从多个角度搜索资料，再结合你提供的来源生成文章。")
                }
                Section("补充来源") {
                    TextField("粘贴文本（可选）", text: $text, axis: .vertical).lineLimit(4...10)
                    TextField("网页链接，每行一个（可选）", text: $links, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).lineLimit(2...5)
                    Button("导入文件", systemImage: "doc.badge.plus") { importing = true }.disabled(loadingFiles)
                    if loadingFiles { ProgressView("正在读取文件…") }
                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(file.title, systemImage: file.kind == .file ? "doc.text" : "link").lineLimit(2)
                                if file.metadata["truncated"] == "true" {
                                    Text("文件较长，已截取前 40,000 字符").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("移除", systemImage: "xmark.circle") { files.removeAll { $0.id == file.id } }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("移除 \(file.title)")
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                if singleSource {
                    Section {
                        Picker("阅读方式", selection: $readingMode) {
                            Text("精读").tag(ReadingMode.closeReading)
                            Text("只读原文").tag(ReadingMode.originalOnly)
                            Text("多源综述").tag(ReadingMode.synthesis)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("阅读方式")
                    } footer: {
                        switch readingMode {
                        case .closeReading: Text("以这份内容为正文，配导读、模板模块和段落批注。")
                        case .originalOnly: Text("只抓取并排版原文，不调用模型；之后可以在文章页生成精读。")
                        case .synthesis: Text("把它当作来源之一，搜索更多资料写成综述。")
                        }
                    }
                    .transition(.opacity)
                }
                // Generation templates shape topic syntheses; a close reading keeps the original's structure.
                if !readsOriginal {
                    Section("版式") {
                        Picker("生成模板", selection: $templateId) {
                            ForEach(DeepReadSynthesisTemplate.options, id: \.id) { Text($0.name).tag($0.id) }
                            ForEach(templates.templates) { template in Text(template.name).tag(template.id) }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled) } }
                Section {
                    Button(action: create) {
                        Label(singleSource && readingMode == .originalOnly ? "打开原文" : "开始深度阅读",
                          systemImage: singleSource && readingMode == .originalOnly ? "doc.plaintext" : "sparkles")
                            .labelStyle(.titleAndIcon)
                            .symbolEffect(.bounce, value: launched)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled((title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readsOriginal) || loadingFiles)
                    .accessibilityIdentifier("deepread.compose.generate")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listRowBackground(DeepReadPalette.card)
        }
        .scrollContentBackground(.hidden)
        .background { DeepReadPaperBackground() }
        .animation(.snappy, value: files.map(\.id))
        .animation(.snappy, value: error)
        .animation(.snappy, value: singleSource)
        .sensoryFeedback(.success, trigger: launched)
        .navigationTitle("创建阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: DeepReadFileImporter.supportedTypes, allowsMultipleSelection: true) { result in
            Task { @MainActor in
                loadingFiles = true
                defer { loadingFiles = false }
                do {
                    for url in try result.get() { files.append(try await DeepReadFileImporter.read(url: url)) }
                } catch { self.error = IOSDeepReadUserFacingText.fromError(error) }
            }
        }
    }

    private func create() {
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var sources = files
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The normalizer titles untitled text by its first line instead of "手动文本".
                sources.append(try IOSDeepReadSourceNormalizer.manualText(title: cleanTitle, text: text))
            }
            for link in links.split(whereSeparator: \.isNewline) {
                let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    error = "网页链接需要完整的 http 或 https 地址：\(value)"
                    return
                }
                sources.append(.init(kind: .searchResult, title: url.host ?? value, content: value, url: value))
            }
            let id = try runtime.create(title: cleanTitle, sources: sources, templateId: templateId, primaryIndex: readsOriginal ? 0 : nil,
                                        originalOnly: singleSource && readingMode == .originalOnly)
            launched += 1
            dismiss()
            onCreated(id)
        } catch { self.error = IOSDeepReadUserFacingText.fromError(error) }
    }
}
